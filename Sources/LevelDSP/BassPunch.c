#include "BassPunch.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* The low band is 30–130Hz (second-order high- and low-pass). Its gain is a fixed part plus a
   punch part that follows the fast envelope's lead over the slow one, which smooths the fast one so
   that a held note's ripple barely counts: it starts at a lead of 1dB and is full at 9dB.
   The whole signal is lowered by a fixed amount for headroom, and a limiter with an instant
   attack and no lookahead keeps samples under −1dBFS. */
typedef struct { double b[3], a[2]; } Coefficients;
typedef struct { double z[2]; } State;
typedef struct { double fixed, punch, level; } Setting;
static const Setting settings[3] = {
    {0, 0, 1},
    {0.30, 0.90, 0.9440608762859234},  /* −0.5dB */
    {0.55, 1.45, 0.8912509381337456},  /* −1dB */
};
static const double ceiling = 0.8912509381337456; /* −1dBFS */
static const double startLead = 1.1220184543019633, fullLead = 2.8183829312644537; /* 1dB, 9dB */

struct LCMPBassPunch {
    unsigned channels;
    _Atomic int strength;
    Coefficients highpass, lowpass;
    State high[2], low[2];
    double fastAttack, fastRelease, slowAttack, slowRelease, punchAttack, punchRelease, glide, release;
    double fast, slow, punch, reduction;
    Setting current;
};

static double filter(const Coefficients *c, State *s, double x) {
    double y = c->b[0]*x + s->z[0];
    s->z[0] = c->b[1]*x - c->a[0]*y + s->z[1];
    s->z[1] = c->b[2]*x - c->a[1]*y;
    return y;
}
static Coefficients butterworth(double frequency, double rate, int high) {
    double k = tan(M_PI*frequency/rate), q = M_SQRT1_2, n = 1/(1 + k/q + k*k);
    double b0 = high ? n : k*k*n;
    return (Coefficients){{b0, high ? -2*b0 : 2*b0, b0}, {2*(k*k - 1)*n, (1 - k/q + k*k)*n}};
}
static double pole(double seconds, double rate) { return 1 - exp(-1/(seconds*rate)); }
static double follow(double value, double input, double attack, double release) {
    return value + (input > value ? attack : release)*(input - value);
}

LCMPBassPunch *lcmp_bass_punch_create(double rate, unsigned channels) {
    if (!isfinite(rate) || rate < 8000 || rate > 768000 || channels < 1 || channels > 2) return NULL;
    LCMPBassPunch *p = calloc(1, sizeof(*p)); if (!p) return NULL;
    p->channels = channels;
    atomic_init(&p->strength, 0);
    p->highpass = butterworth(30, rate, 1); p->lowpass = butterworth(130, rate, 0);
    p->fastAttack = pole(0.001, rate); p->fastRelease = pole(0.060, rate);
    p->slowAttack = pole(0.050, rate); p->slowRelease = pole(0.060, rate);
    p->punchAttack = pole(0.002, rate); p->punchRelease = pole(0.040, rate);
    p->glide = pole(0.015, rate); p->release = pole(0.150, rate);
    lcmp_bass_punch_reset(p);
    return p;
}
void lcmp_bass_punch_destroy(LCMPBassPunch *p) { free(p); }
void lcmp_bass_punch_set_strength(LCMPBassPunch *p, int strength) {
    atomic_store_explicit(&p->strength, strength < 0 ? 0 : strength > 2 ? 2 : strength, memory_order_relaxed);
}
int lcmp_bass_punch_strength(const LCMPBassPunch *p) {
    return atomic_load_explicit(&p->strength, memory_order_relaxed);
}
void lcmp_bass_punch_reset(LCMPBassPunch *p) {
    memset(p->high, 0, sizeof(p->high)); memset(p->low, 0, sizeof(p->low));
    p->fast = p->slow = p->punch = 0; p->reduction = 1;
    p->current = settings[lcmp_bass_punch_strength(p)];
}

static double glide(double value, double target, double rate) {
    value += rate*(target - value);
    return fabs(target - value) < 1e-6 ? target : value;
}

void lcmp_bass_punch_process(LCMPBassPunch *p, const float *const *input, float *const *output,
                             unsigned frames) {
    const Setting target = settings[lcmp_bass_punch_strength(p)];
    /* Off and settled: the filters and envelopes keep running so that turning it on starts warm,
       but the samples pass untouched. */
    const int active = !(target.fixed == 0 && p->current.fixed == 0 && p->current.punch == 0
                         && p->current.level == 1 && p->reduction == 1);
    for (unsigned i = 0; i < frames; ++i) {
        double band[2] = {0, 0}, envelope = 0, x[2] = {0, 0};
        for (unsigned ch = 0; ch < p->channels; ++ch) {
            /* A NaN or infinity (a damaged float file) would stay in the filters and envelopes for
               good: they take silence in its place, and the processed output stays finite. */
            x[ch] = isfinite(input[ch][i]) ? input[ch][i] : 0;
            band[ch] = filter(&p->lowpass, &p->low[ch], filter(&p->highpass, &p->high[ch], x[ch]));
            envelope = fmax(envelope, fabs(band[ch]));
        }
        p->fast = follow(p->fast, envelope, p->fastAttack, p->fastRelease);
        p->slow = follow(p->slow, p->fast, p->slowAttack, p->slowRelease);
        double lead = (p->fast/(p->slow + 1e-12) - startLead)/(fullLead - startLead);
        p->punch = follow(p->punch, lead < 0 ? 0 : lead > 1 ? 1 : lead, p->punchAttack, p->punchRelease);
        if (!active) {
            for (unsigned ch = 0; ch < p->channels; ++ch) output[ch][i] = input[ch][i];
            continue;
        }
        p->current.fixed = glide(p->current.fixed, target.fixed, p->glide);
        p->current.punch = glide(p->current.punch, target.punch, p->glide);
        p->current.level = glide(p->current.level, target.level, p->glide);
        double gain = p->current.fixed + p->current.punch*p->punch, y[2] = {0, 0}, peak = 0;
        for (unsigned ch = 0; ch < p->channels; ++ch) {
            y[ch] = p->current.level*(x[ch] + gain*band[ch]);
            peak = fmax(peak, fabs(y[ch]));
        }
        const int off = target.fixed == 0;
        double reduction = p->reduction + (off ? p->glide : p->release)*(1 - p->reduction);
        if (reduction > 1 - 1e-6) reduction = 1;
        /* Turning off only releases, as fast as the setting glides, so that a loud source cannot
           hold it short of passing through. */
        if (!off && peak*reduction > ceiling) reduction = ceiling/peak;
        p->reduction = reduction;
        for (unsigned ch = 0; ch < p->channels; ++ch) output[ch][i] = (float)(y[ch]*reduction);
    }
}
