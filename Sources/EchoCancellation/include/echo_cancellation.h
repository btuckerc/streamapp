#ifndef STREAMAPP_ECHO_CANCELLATION_H
#define STREAMAPP_ECHO_CANCELLATION_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SAEchoCanceller SAEchoCanceller;

/* Echo mode is fixed for the handle's lifetime; noise reduction is independent. */
SAEchoCanceller *sa_aec_create(int echoEnabled, int noiseReductionEnabled);
void sa_aec_destroy(SAEchoCanceller *handle);
int sa_aec_reset(SAEchoCanceller *handle);
/* Call between processing blocks, never from the output callback. */
int sa_aec_set_noise_reduction(SAEchoCanceller *handle, int enabled);

/* Processes exactly 480 frames of normalized 48 kHz interleaved stereo.
 * Reference may be NULL when echo cancellation is off. Enabled processing emits
 * full-band mono duplicated to stereo; both off copies raw stereo.
 * On failure output is untouched. */
int sa_aec_process(SAEchoCanceller *handle,
                   const float *referenceStereo,
                   const float *microphoneStereo,
                   float *outputStereo);

#ifdef __cplusplus
}
#endif
#endif
