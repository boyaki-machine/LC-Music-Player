#ifndef LCMP_LEVEL_DSP_H
#define LCMP_LEVEL_DSP_H
#include <stddef.h>
#include <stdint.h>
typedef struct LCMPLevelMeter LCMPLevelMeter;
LCMPLevelMeter *lcmp_level_create(double sample_rate, unsigned channels);
void lcmp_level_destroy(LCMPLevelMeter *meter);
/* Worker-only. Returns block count, or -1 for invalid input/capacity. */
int lcmp_level_push(LCMPLevelMeter *meter, const float *left, const float *right,
                    unsigned frames, double *energies, unsigned capacity);
void lcmp_level_flush_peak(LCMPLevelMeter *meter);
double lcmp_level_sample_peak(const LCMPLevelMeter *meter);
double lcmp_level_true_peak(const LCMPLevelMeter *meter);
uint64_t lcmp_level_frames(const LCMPLevelMeter *meter);
/* Largest absolute sample of count samples spaced by stride. Float variants
   return 0 when any sample is NaN or infinite. Integers are full-scale normalized. */
int lcmp_peak_f32(const float *samples, size_t count, size_t stride, double *peak);
int lcmp_peak_f64(const double *samples, size_t count, size_t stride, double *peak);
double lcmp_peak_i16(const int16_t *samples, size_t count, size_t stride);
double lcmp_peak_i32(const int32_t *samples, size_t count, size_t stride);
/* Signed integers of `bits` in `width` bytes (≤ 4), frame_bytes apart. */
double lcmp_peak_packed(const uint8_t *samples, size_t count, size_t frame_bytes,
                        unsigned width, unsigned bits, int big_endian, int aligned_high);
#endif
