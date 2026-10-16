// Exercise the production render callback while a control thread replaces and frees queues.
// Include the C implementation to test its private callback without adding a product test API.
#include "../Sources/AnalysisTransport/AnalysisTransport.c"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static LCMPRenderSource source;
static _Atomic bool running;
static _Atomic uint64_t calls;
static void *render(void *unused) {
    (void)unused;
    float samples[64] = {0};
    AudioBufferList data = {.mNumberBuffers = 1, .mBuffers = {{.mNumberChannels = 1,
        .mDataByteSize = sizeof(samples), .mData = samples}}};
    AudioTimeStamp time = {.mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = 0};
    while (atomic_load(&running)) {
        AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_PostRender;
        capture(&source, &flags, &time, 0, 64, &data);
        atomic_fetch_add(&calls, 1);
    }
    return NULL;
}
int main(void) {
    atomic_init(&source.queue, NULL); atomic_init(&source.readers, 0);
    atomic_init(&running, true); atomic_init(&calls, 0);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, render, NULL) == 0);
    uint64_t overlaps = 0;
    for (int index = 0; index < 50000; ++index) {
        LCMPPCMQueue *queue = lcmp_pcm_create(2, 128);
        assert(queue);
        queue->render_rate = 48000; queue->tick_seconds = 1e-9;
        atomic_store(&source.queue, queue);
        sched_yield();
        if (atomic_load(&source.readers)) overlaps++;
        lcmp_render_source_clear(&source, queue);
        assert(atomic_load(&source.queue) == NULL);
        lcmp_pcm_destroy(queue);
    }
    atomic_store(&running, false);
    assert(pthread_join(producer, NULL) == 0);
    assert(overlaps > 0 && atomic_load(&calls) > 1000);
    printf("render source lifetime: 50000 replacements, %llu overlapping callbacks, %llu calls\n",
           (unsigned long long)overlaps, (unsigned long long)atomic_load(&calls));
}
