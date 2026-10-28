#ifndef LCMP_BASS_PUNCH_H
#define LCMP_BASS_PUNCH_H
/* Bass emphasis that favours attacks: the low band is added back louder while its fast envelope
   runs ahead of its slow one (kicks, toms), less while a note sustains. No lookahead and no
   buffering, so the output is not delayed; strength 0 passes the input through bit for bit. */
typedef struct LCMPBassPunch LCMPBassPunch;
LCMPBassPunch *lcmp_bass_punch_create(double sample_rate, unsigned channels);
void lcmp_bass_punch_destroy(LCMPBassPunch *punch);
/* 0 off, 1 light, 2 strong. Any thread; the render glides to it over about 50ms. */
void lcmp_bass_punch_set_strength(LCMPBassPunch *punch, int strength);
int lcmp_bass_punch_strength(const LCMPBassPunch *punch);
/* Render thread only. Non-interleaved channels; output may be the input. */
void lcmp_bass_punch_process(LCMPBassPunch *punch, const float *const *input, float *const *output,
                             unsigned frames);
void lcmp_bass_punch_reset(LCMPBassPunch *punch);
#endif
