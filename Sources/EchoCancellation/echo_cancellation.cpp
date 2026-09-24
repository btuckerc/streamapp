// Header inline code must match scripts/build-aec.py's arm64 NEON library.
#if defined(__aarch64__)
#define WEBRTC_ARCH_ARM64
#define WEBRTC_HAS_NEON
#endif
#include "echo_cancellation.h"
#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/high_pass_filter.h"
#include "modules/audio_processing/ns/noise_suppressor.h"
#include "system_wrappers/include/denormal_disabler.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <stdexcept>

// Drives AEC3, the high-pass filter and noise suppression directly in upstream
// AudioProcessing capture order, without APM's per-call format checks, level
// analysis, statistics, locking or the render-output copy.
namespace {
constexpr size_t kFrames = 480;
constexpr int kRate = 48000;

std::unique_ptr<webrtc::EchoCanceller3> makeEcho() {
  webrtc::EchoCanceller3Config config;
  // Prefer speech preservation over maximum residual-echo suppression.
  auto& detector = config.suppressor.dominant_nearend_detection;
  detector.enr_threshold = 1.f;
  detector.snr_threshold = 10.f;
  detector.trigger_threshold = 4;
  for (auto* tuning : {&config.suppressor.normal_tuning, &config.suppressor.nearend_tuning}) {
    tuning->mask_lf.enr_transparent *= 32.f;
    tuning->mask_lf.enr_suppress *= 32.f;
    tuning->mask_hf.enr_transparent *= 32.f;
    tuning->mask_hf.enr_suppress *= 32.f;
  }
  config.suppressor.conservative_hf_suppression = true;
  // The delay estimator dominates AEC3 cost; 2 kHz decimation keeps its
  // ~500 ms search window at half the matched-filter work.
  config.delay.down_sampling_factor = 8;
  if (!webrtc::EchoCanceller3Config::Validate(&config)) throw std::runtime_error("Invalid AEC tuning");
  auto echo = std::make_unique<webrtc::EchoCanceller3>(config, std::nullopt, kRate, 2, 1);
  // The mixer already aligns reference and microphone host timestamps, so
  // start the delay search at zero rather than AEC3's 20 ms default; with the
  // default, sub-5 ms residual delays never converge.
  echo->SetAudioBufferDelay(0);
  return echo;
}

std::unique_ptr<webrtc::NoiseSuppressor> makeNoise() {
  webrtc::NsConfig config;
  config.target_level = webrtc::NsConfig::SuppressionLevel::k6dB;
  return std::make_unique<webrtc::NoiseSuppressor>(config, kRate, 1);
}

// AEC3 clamps to [-1, 1] on input; only NaN would reach and poison its state.
inline float finite(float value) { return std::isnan(value) ? 0.f : value; }
}

struct SAEchoCanceller {
  std::unique_ptr<webrtc::EchoCanceller3> echo;
  std::unique_ptr<webrtc::NoiseSuppressor> noise;
  webrtc::HighPassFilter highPass{kRate, 1};
  webrtc::AudioBuffer render{kRate, 2, kRate, 2, kRate, 2};
  webrtc::AudioBuffer capture{kRate, 1, kRate, 1, kRate, 1};
  std::array<float, kFrames> left{}, right{}, microphone{};
};

extern "C" SAEchoCanceller* sa_aec_create(int echo, int noise) {
  try {
    auto handle = std::make_unique<SAEchoCanceller>();
    if (echo) handle->echo = makeEcho();
    if (noise) handle->noise = makeNoise();
    return handle.release();
  } catch (...) { return nullptr; }
}
extern "C" void sa_aec_destroy(SAEchoCanceller* handle) { delete handle; }
extern "C" int sa_aec_set_noise_reduction(SAEchoCanceller* handle, int enabled) {
  if (!handle) return -1;
  try {
    // Noise suppression runs after AEC on its output, so toggling it never
    // alters the learned echo path.
    if (enabled && !handle->noise) handle->noise = makeNoise();
    else if (!enabled) handle->noise = nullptr;
    return 0;
  } catch (...) { return -1; }
}
extern "C" int sa_aec_process(SAEchoCanceller* handle, const float* reference,
                              const float* microphone, float* output) {
  if (!handle || (handle->echo && !reference) || !microphone || !output) return -1;
  if (!handle->echo && !handle->noise) {
    std::copy(microphone, microphone + 2 * kFrames, output);
    return 0;
  }
  try {
    webrtc::DenormalDisabler denormals;
    const webrtc::StreamConfig mono(kRate, 1), stereo(kRate, 2);
    auto& mic = handle->microphone;
    for (size_t i = 0; i < kFrames; ++i) mic[i] = .5f * (finite(microphone[2*i]) + finite(microphone[2*i+1]));
    if (handle->echo) {
      for (size_t i = 0; i < kFrames; ++i) {
        handle->left[i] = finite(reference[2*i]);
        handle->right[i] = finite(reference[2*i+1]);
      }
      const float* render[] = {handle->left.data(), handle->right.data()};
      handle->render.CopyFrom(render, stereo);
      handle->render.SplitIntoFrequencyBands();
      handle->echo->AnalyzeRender(&handle->render);
    }
    const float* capture[] = {mic.data()};
    auto& buffer = handle->capture;
    buffer.CopyFrom(capture, mono);
    handle->highPass.Process(&buffer, /*use_split_band_data=*/false);
    if (handle->echo) handle->echo->AnalyzeCapture(&buffer);
    buffer.SplitIntoFrequencyBands();
    if (handle->echo) handle->echo->ProcessCapture(&buffer, /*level_change=*/false);
    if (handle->noise) {
      handle->noise->Analyze(buffer);
      handle->noise->Process(&buffer);
    }
    buffer.MergeFrequencyBands();
    float* cleaned[] = {mic.data()};
    buffer.CopyTo(mono, cleaned);
    for (float value : mic) if (!std::isfinite(value)) return -3;
    // Commit only a complete successful block; caller can preserve raw mic on error.
    for (size_t i = 0; i < kFrames; ++i) output[2*i] = output[2*i+1] = mic[i];
    return 0;
  } catch (...) { return -1; }
}
