#include "echo_cancellation.h"
#include "api/audio/audio_processing.h"
#include "api/audio/echo_control.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include <array>
#include <cmath>
#include <memory>
#include <stdexcept>

namespace {
constexpr size_t kFrames = 480;
class EchoFactory final : public webrtc::EchoControlFactory {
 public:
  std::unique_ptr<webrtc::EchoControl> Create(int rate, int render, int capture) override {
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
    if (!webrtc::EchoCanceller3Config::Validate(&config)) throw std::runtime_error("Invalid AEC tuning");
    return std::make_unique<webrtc::EchoCanceller3>(config, std::nullopt, rate, render, capture);
  }
};
}

struct SAEchoCanceller {
  webrtc::scoped_refptr<webrtc::AudioProcessing> apm, noise_apm;
  const bool echo_enabled;
  std::array<float, kFrames> left{}, right{}, microphone{}, cleaned{};
  static webrtc::scoped_refptr<webrtc::AudioProcessing> createProcessor(bool echo, bool noise) {
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = echo;
    config.echo_canceller.mobile_mode = false;
    config.echo_canceller.enforce_high_pass_filtering = false;
    config.high_pass_filter.enabled = false;
    config.noise_suppression.enabled = noise;
    config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kLow;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.pre_amplifier.enabled = false;
    config.capture_level_adjustment.enabled = false;
    config.transient_suppression.enabled = false;
    config.pipeline.multi_channel_render = true;
    config.pipeline.multi_channel_capture = false;
    webrtc::AudioProcessingBuilder builder;
    builder.SetConfig(config);
    // A custom factory itself enables AEC upstream, even if the config disables it.
    if (echo) builder.SetEchoControlFactory(std::make_unique<EchoFactory>());
    auto apm = builder.Create();
    webrtc::ProcessingConfig formats;
    formats.input_stream() = formats.output_stream() = webrtc::StreamConfig(48000, 1);
    formats.reverse_input_stream() = formats.reverse_output_stream() = webrtc::StreamConfig(48000, 2);
    if (!apm || apm->Initialize(formats) != 0) throw std::runtime_error("Cannot initialize microphone processor");
    return apm;
  }
  SAEchoCanceller(bool echo, bool noise) : echo_enabled(echo) {
    if (echo) apm = createProcessor(true, false);
    if (noise) noise_apm = createProcessor(false, true);
  }
};

extern "C" SAEchoCanceller* sa_aec_create(int echo, int noise) {
  try { return new SAEchoCanceller(echo != 0, noise != 0); } catch (...) { return nullptr; }
}
extern "C" void sa_aec_destroy(SAEchoCanceller* handle) { delete handle; }
extern "C" int sa_aec_reset(SAEchoCanceller* handle) {
  if (!handle) return -1;
  try {
    if (handle->apm) {
      int result = handle->apm->Initialize();
      if (result) return result;
    }
    return handle->noise_apm ? handle->noise_apm->Initialize() : 0;
  } catch (...) { return -1; }
}
extern "C" int sa_aec_set_noise_reduction(SAEchoCanceller* handle, int enabled) {
  if (!handle) return -1;
  try {
    // Upstream ApplyConfig(NS) triggers a deferred full reinitialization on the
    // next capture block. A separate full-band NS stage preserves learned AEC.
    if (enabled && !handle->noise_apm) {
      handle->noise_apm = SAEchoCanceller::createProcessor(false, true);
    } else if (!enabled) {
      handle->noise_apm = nullptr;
    }
    return 0;
  } catch (...) { return -1; }
}
extern "C" int sa_aec_process(SAEchoCanceller* handle, const float* reference,
                              const float* microphone, float* output) {
  if (!handle || (handle->echo_enabled && !reference) || !microphone || !output) return -1;
  try {
    for (size_t i = 0; i < kFrames; ++i) {
      for (size_t ch = 0; ch < 2; ++ch) {
        if (!std::isfinite(microphone[2*i+ch]) || std::abs(microphone[2*i+ch]) > 1.f) return -2;
        if (handle->echo_enabled &&
            (!std::isfinite(reference[2*i+ch]) || std::abs(reference[2*i+ch]) > 1.f)) return -2;
      }
      if (handle->echo_enabled) {
        handle->left[i] = reference[2*i];
        handle->right[i] = reference[2*i+1];
      }
      handle->microphone[i] = .5f * (microphone[2*i] + microphone[2*i+1]);
    }
    const float* render[] = {handle->left.data(), handle->right.data()};
    float* rendered[] = {handle->left.data(), handle->right.data()};
    const float* capture[] = {handle->microphone.data()};
    float* captured[] = {handle->cleaned.data()};
    const webrtc::StreamConfig renderFormat(48000, 2), captureFormat(48000, 1);
    int result;
    if (handle->echo_enabled) {
      result = handle->apm->ProcessReverseStream(render, renderFormat, renderFormat, rendered);
      if (result) return result;
      result = handle->apm->set_stream_delay_ms(0);
      if (result) return result;
      result = handle->apm->ProcessStream(capture, captureFormat, captureFormat, captured);
      if (result) return result;
    }
    if (handle->noise_apm) {
      const float* noise_input[] = {handle->echo_enabled ? handle->cleaned.data() : handle->microphone.data()};
      result = handle->noise_apm->ProcessStream(noise_input, captureFormat, captureFormat, captured);
      if (result) return result;
    }
    if (!handle->echo_enabled && !handle->noise_apm) {
      for (size_t i = 0; i < kFrames * 2; ++i) output[i] = microphone[i];
      return 0;
    }
    for (float value : handle->cleaned) if (!std::isfinite(value)) return -3;
    // Commit only a complete successful block; caller can preserve raw mic on error.
    for (size_t i = 0; i < kFrames; ++i) output[2*i] = output[2*i+1] = handle->cleaned[i];
    return 0;
  } catch (...) { return -1; }
}
