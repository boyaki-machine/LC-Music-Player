#ifndef LCMP_ANALYSIS_TRANSPORT_H
#define LCMP_ANALYSIS_TRANSPORT_H
#include <stdint.h>
#include <stdbool.h>
#include <AudioToolbox/AudioToolbox.h>
typedef struct LCMPPCMQueue LCMPPCMQueue;
typedef struct {
    double sample_rate;
    double sample_time;
    double host_seconds;
    double output_latency;
    uint32_t frames;
    bool sample_time_valid;
    bool host_time_valid;
    bool latency_valid;
    uint64_t sequence;
} LCMPPCMStamp;
// Single producer (audio tap), single consumer (serial analysis queue).
LCMPPCMQueue *lcmp_pcm_create(uint32_t capacity, uint32_t max_frames);
void lcmp_pcm_destroy(LCMPPCMQueue *queue);
bool lcmp_pcm_push(LCMPPCMQueue *queue, const float *left, const float *right,
                   LCMPPCMStamp stamp);
bool lcmp_pcm_pop(LCMPPCMQueue *queue, float *left, float *right, LCMPPCMStamp *stamp);
uint64_t lcmp_pcm_dropped(LCMPPCMQueue *queue);
uint32_t lcmp_pcm_high_water(LCMPPCMQueue *queue);
// Worker-side finite sanitization, before vector operations; not a render effect.
void lcmp_copy_finite(const float *input, float *output, uint32_t count);
// Owner must unregister before destroying queue or AudioUnit. One producer only.
OSStatus lcmp_pcm_attach(LCMPPCMQueue *queue, AudioUnit unit, double sample_rate, double output_latency);
OSStatus lcmp_pcm_detach(LCMPPCMQueue *queue, AudioUnit unit);
#endif
