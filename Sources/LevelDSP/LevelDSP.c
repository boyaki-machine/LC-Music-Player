#include "LevelDSP.h"
#include <math.h>
#include <stdlib.h>

/* Independent bilinear K-weighting and windowed-sinc interpolation.
   BS.1770 response constants; no audio, paths, or growing history retained. */
typedef struct { double b[3], a[2], z[2]; } Biquad;
struct LCMPLevelMeter {
    unsigned channels, window, hop, index, phases, history_index;
    uint64_t frames;
    double sum, sample_peak, true_peak;
    double *energy;
    Biquad shelf[2], highpass[2];
    double history[2][64], coefficients[8][32];
};
static double filter(Biquad *b, double x) {
    double y = b->b[0]*x + b->z[0];
    b->z[0] = b->b[1]*x - b->a[0]*y + b->z[1];
    b->z[1] = b->b[2]*x - b->a[1]*y;
    return y;
}
static void coefficients(LCMPLevelMeter *m, double rate) {
    double k = tan(M_PI*1681.974450955532/rate), q = 0.7071752369554193;
    double vh = pow(10, 3.99984385397/20), vb = pow(vh, 0.499666774155);
    double a = 1+k/q+k*k;
    Biquad s = {{(vh+vb*k/q+k*k)/a, 2*(k*k-vh)/a, (vh-vb*k/q+k*k)/a},
                {2*(k*k-1)/a, (1-k/q+k*k)/a}, {0,0}};
    k = tan(M_PI*38.13547087613982/rate); q = 0.5003270373253953; a = 1+k/q+k*k;
    Biquad h = {{1,-2,1}, {2*(k*k-1)/a, (1-k/q+k*k)/a}, {0,0}};
    for (unsigned ch=0; ch<m->channels; ++ch) { m->shelf[ch]=s; m->highpass[ch]=h; }
    m->phases=2;
    while (rate*m->phases < 192000 && m->phases < 8) m->phases*=2;
    for (unsigned p=1;p<m->phases;++p) {
        double total=0, t=15+(double)p/m->phases;
        for (unsigned n=0;n<32;++n) {
            double x=n-t;
            double window=0.42-0.5*cos(2*M_PI*n/31)+0.08*cos(4*M_PI*n/31);
            double c=(fabs(x)<1e-12 ? 1 : sin(M_PI*x)/(M_PI*x))*window;
            m->coefficients[p][n]=c; total+=c;
        }
        for (unsigned n=0;n<32;++n) m->coefficients[p][n]/=total;
    }
}
LCMPLevelMeter *lcmp_level_create(double rate, unsigned channels) {
    if (!isfinite(rate) || rate<32000 || rate>192000 || channels<1 || channels>2) return NULL;
    LCMPLevelMeter *m=calloc(1,sizeof(*m)); if (!m) return NULL;
    m->channels=channels; m->hop=(unsigned)llround(rate/10); m->window=4*m->hop;
    m->energy=calloc(m->window,sizeof(double));
    if (!m->energy) { free(m); return NULL; }
    coefficients(m,rate); return m;
}
void lcmp_level_destroy(LCMPLevelMeter *m) { if (m) { free(m->energy); free(m); } }
static void peak_frame(LCMPLevelMeter *m, const double values[2]) {
    unsigned i=m->history_index;
    for (unsigned ch=0;ch<m->channels;++ch) {
        m->history[ch][i]=m->history[ch][i+32]=values[ch];
        const double *history=m->history[ch]+i+1;
        for (unsigned p=1;p<m->phases;++p) {
            double v=0;
            for (unsigned n=0;n<32;++n) v+=history[n]*m->coefficients[p][n];
            m->true_peak=fmax(m->true_peak,fabs(v));
        }
    }
    m->history_index=(i+1)%32;
}
int lcmp_level_push(LCMPLevelMeter *m, const float *l, const float *r,
                    unsigned count, double *out, unsigned capacity) {
    if (!m || !l || (m->channels==2 && !r) || capacity < count/m->hop+2) return -1;
    unsigned written=0;
    for (unsigned n=0;n<count;++n) {
        double v[2]={l[n], m->channels==2 ? r[n] : 0}, e=0;
        for (unsigned ch=0;ch<m->channels;++ch) {
            if (!isfinite(v[ch])) return -1;
            m->sample_peak=fmax(m->sample_peak,fabs(v[ch]));
            double y=filter(&m->highpass[ch],filter(&m->shelf[ch],v[ch]));
            if (!isfinite(y)) return -1;
            e+=y*y;
        }
        peak_frame(m,v);
        m->sum += e-m->energy[m->index]; m->energy[m->index]=e;
        m->index=(m->index+1)%m->window; ++m->frames;
        if (m->frames>=m->window && (m->frames-m->window)%m->hop==0)
            out[written++]=fmax(0,m->sum/m->window);
    }
    return (int)written;
}
void lcmp_level_flush_peak(LCMPLevelMeter *m) {
    const double zero[2]={0,0}; for (unsigned n=0;n<32;++n) peak_frame(m,zero);
}
double lcmp_level_sample_peak(const LCMPLevelMeter *m) { return m->sample_peak; }
double lcmp_level_true_peak(const LCMPLevelMeter *m) { return fmax(m->sample_peak,m->true_peak); }
uint64_t lcmp_level_frames(const LCMPLevelMeter *m) { return m->frames; }
