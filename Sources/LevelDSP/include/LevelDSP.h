#ifndef LCMP_LEVEL_DSP_H
#define LCMP_LEVEL_DSP_H
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
#endif
