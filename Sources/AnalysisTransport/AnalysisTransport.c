#include "AnalysisTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <math.h>
struct LCMPPCMQueue {
    uint32_t capacity, max_frames;
    _Atomic uint64_t read_index, write_index, dropped;
    _Atomic uint32_t high_water;
    LCMPPCMStamp *stamps;
    float *samples;
    double render_rate, output_latency, tick_seconds;
    uint64_t render_sequence;
};
LCMPPCMQueue *lcmp_pcm_create(uint32_t capacity, uint32_t max_frames) {
    if (capacity < 2 || capacity > 64 || !max_frames || max_frames > 65536) return NULL;
    LCMPPCMQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->capacity = capacity; q->max_frames = max_frames;
    atomic_init(&q->read_index, 0); atomic_init(&q->write_index, 0); atomic_init(&q->dropped, 0);
    atomic_init(&q->high_water, 0);
    q->stamps = calloc(capacity, sizeof(*q->stamps));
    q->samples = calloc((size_t)capacity * 2 * max_frames, sizeof(float));
    if (!q->stamps || !q->samples) { lcmp_pcm_destroy(q); return NULL; }
    // Allocation-free push/pop must not fall back to hidden atomic locks.
    if (!atomic_is_lock_free(&q->write_index) || !atomic_is_lock_free(&q->read_index) ||
        !atomic_is_lock_free(&q->dropped) || !atomic_is_lock_free(&q->high_water)) { lcmp_pcm_destroy(q); return NULL; }
    return q;
}
void lcmp_pcm_destroy(LCMPPCMQueue *q) {
    if (!q) return;
    free(q->stamps); free(q->samples); free(q);
}
bool lcmp_pcm_push(LCMPPCMQueue *q, const float *left, const float *right, LCMPPCMStamp stamp) {
    uint64_t w = atomic_load_explicit(&q->write_index, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&q->read_index, memory_order_acquire);
    if (!left || !stamp.frames || stamp.frames > q->max_frames || w-r >= q->capacity) {
        atomic_fetch_add_explicit(&q->dropped, 1, memory_order_relaxed); return false;
    }
    size_t slot = w % q->capacity;
    float *dest = q->samples + slot * 2 * q->max_frames;
    memcpy(dest, left, stamp.frames * sizeof(float));
    memcpy(dest + q->max_frames, right ? right : left, stamp.frames * sizeof(float));
    q->stamps[slot] = stamp;
    uint32_t pending = (uint32_t)(w - r + 1);
    if (pending > atomic_load_explicit(&q->high_water, memory_order_relaxed))
        atomic_store_explicit(&q->high_water, pending, memory_order_relaxed);
    atomic_store_explicit(&q->write_index, w+1, memory_order_release);
    return true;
}
bool lcmp_pcm_pop(LCMPPCMQueue *q, float *left, float *right, LCMPPCMStamp *stamp) {
    uint64_t r = atomic_load_explicit(&q->read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&q->write_index, memory_order_acquire);
    if (r == w) return false;
    size_t slot = r % q->capacity;
    *stamp = q->stamps[slot];
    const float *src = q->samples + slot * 2 * q->max_frames;
    memcpy(left, src, stamp->frames * sizeof(float));
    memcpy(right, src + q->max_frames, stamp->frames * sizeof(float));
    atomic_store_explicit(&q->read_index, r+1, memory_order_release);
    return true;
}
uint64_t lcmp_pcm_dropped(LCMPPCMQueue *q) {
    return atomic_load_explicit(&q->dropped, memory_order_relaxed);
}
uint32_t lcmp_pcm_high_water(LCMPPCMQueue *q) {
    return atomic_load_explicit(&q->high_water, memory_order_relaxed);
}

void lcmp_copy_finite(const float *input, float *output, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) output[i] = isfinite(input[i]) ? input[i] : 0;
}

static OSStatus capture(void *context, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || (*flags & kAudioUnitRenderAction_PostRenderError)) return noErr;
    LCMPPCMQueue *q = context;
    q->render_sequence++;
    if (!data || !data->mNumberBuffers || data->mBuffers[0].mNumberChannels != 1 ||
        data->mBuffers[0].mDataByteSize < frames * sizeof(float)) {
        atomic_fetch_add_explicit(&q->dropped, 1, memory_order_relaxed); return noErr;
    }
    const float *right = NULL;
    if (data->mNumberBuffers > 1) {
        if (data->mBuffers[1].mNumberChannels != 1 || data->mBuffers[1].mDataByteSize < frames * sizeof(float)) return noErr;
        right = data->mBuffers[1].mData;
    }
    LCMPPCMStamp stamp = {0};
    stamp.sample_rate = q->render_rate;
    stamp.frames = frames;
    stamp.sequence = q->render_sequence;
    stamp.sample_time_valid = (time->mFlags & kAudioTimeStampSampleTimeValid) != 0;
    stamp.sample_time = time->mSampleTime;
    stamp.host_time_valid = (time->mFlags & kAudioTimeStampHostTimeValid) != 0;
    stamp.host_seconds = time->mHostTime * q->tick_seconds;
    stamp.output_latency = q->output_latency;
    stamp.latency_valid = isfinite(q->output_latency) && q->output_latency >= 0;
    lcmp_pcm_push(q, data->mBuffers[0].mData, right, stamp);
    return noErr;
}
OSStatus lcmp_pcm_attach(LCMPPCMQueue *q, AudioUnit unit, double rate, double latency) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                         kAudioUnitScope_Output, 0, &format, &size);
    if (status != noErr) return status;
    if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
        !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) || format.mBitsPerChannel != 32 ||
        !isfinite(rate) || rate < 8000 || format.mSampleRate != rate) return kAudio_ParamError;
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    q->tick_seconds = (double)info.numer / info.denom / 1e9;
    q->render_rate = rate;
    q->output_latency = latency;
    return AudioUnitAddRenderNotify(unit, capture, q);
}
OSStatus lcmp_pcm_detach(LCMPPCMQueue *q, AudioUnit unit) {
    return AudioUnitRemoveRenderNotify(unit, capture, q);
}
