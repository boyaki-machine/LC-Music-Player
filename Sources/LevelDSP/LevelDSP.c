#include "LevelDSP.h"
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Independent bilinear K-weighting and windowed-sinc interpolation.
   BS.1770 response constants; no audio, paths, or growing history retained. */
typedef struct { double b[3], a[2], z[2]; } Biquad;
typedef double double2 __attribute__((ext_vector_type(2)));
struct LCMPLevelMeter {
    unsigned channels, window, hop, index, phases, line_capacity;
    uint64_t frames;
    double sum, sample_peak, true_peak;
    double *energy;
    /* Each channel's samples of one push behind its last 31 samples, so that the interpolation
       window of every frame lies in one line. */
    double *line;
    Biquad shelf[2], highpass[2];
    double tail[2][31], coefficients[8][32];
};
static double filter(Biquad *b, double x) {
    double y = b->b[0]*x + b->z[0];
    b->z[0] = b->b[1]*x - b->a[0]*y + b->z[1];
    b->z[1] = b->b[2]*x - b->a[1]*y;
    return y;
}
/* The same filter on both channels in the two lanes of a vector: each lane does what `filter` does. */
typedef struct { double2 z[2]; } Biquad2;
static inline double2 filter2(const Biquad *b, Biquad2 *s, double2 x) {
    double2 y = b->b[0]*x + s->z[0];
    s->z[0] = b->b[1]*x - b->a[0]*y + s->z[1];
    s->z[1] = b->b[2]*x - b->a[1]*y;
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
void lcmp_level_destroy(LCMPLevelMeter *m) { if (m) { free(m->energy); free(m->line); free(m); } }
static int reserve(LCMPLevelMeter *m, unsigned count) {
    if (count <= m->line_capacity) return 1;
    double *line=realloc(m->line, 2*((size_t)count+31)*sizeof(double));
    if (!line) return 0;
    m->line=line; m->line_capacity=count; return 1;
}
static inline double2 load2(const double *p) { double2 v; memcpy(&v,p,sizeof v); return v; }
static inline double max2(double2 v) { return fmax(fabs(v.x),fabs(v.y)); }
/* The interpolated values between the samples of `count` frames. `line` holds the 31 samples
   before them, then theirs; frame j's window is line[j...j+31], oldest first. Each value is summed
   in the same order, and with a separate multiply and add, as one frame at a time, so the result
   does not change by a bit. Sixteen frames go at once in vector lanes: their sums are independent. */
static void true_peaks(LCMPLevelMeter *m, const double *line, unsigned count) {
    #pragma clang fp contract(off)
    double peak=m->true_peak;
    for (unsigned p=1;p<m->phases;++p) {
        const double *c=m->coefficients[p];
        unsigned j=0;
        for (;j+16<=count;j+=16) {
            const double *h=line+j;
            double2 v0=0,v1=0,v2=0,v3=0,v4=0,v5=0,v6=0,v7=0;
            for (unsigned n=0;n<32;++n) {
                double2 k=c[n];
                v0+=load2(h+n)*k; v1+=load2(h+n+2)*k; v2+=load2(h+n+4)*k; v3+=load2(h+n+6)*k;
                v4+=load2(h+n+8)*k; v5+=load2(h+n+10)*k; v6+=load2(h+n+12)*k; v7+=load2(h+n+14)*k;
            }
            peak=fmax(peak,fmax(fmax(fmax(max2(v0),max2(v1)),fmax(max2(v2),max2(v3))),
                                fmax(fmax(max2(v4),max2(v5)),fmax(max2(v6),max2(v7)))));
        }
        for (;j<count;++j) {
            double v=0;
            for (unsigned n=0;n<32;++n) v+=line[j+n]*c[n];
            peak=fmax(peak,fabs(v));
        }
    }
    m->true_peak=peak;
}
int lcmp_level_push(LCMPLevelMeter *m, const float *l, const float *r,
                    unsigned count, double *out, unsigned capacity) {
    if (!m || !l || (m->channels==2 && !r) || capacity < count/m->hop+2 || !reserve(m,count)) return -1;
    double *line[2]={m->line, m->line+m->line_capacity+31};
    for (unsigned ch=0;ch<m->channels;++ch) memcpy(line[ch],m->tail[ch],sizeof(m->tail[ch]));
    unsigned written=0;
    if (m->channels==2) {
        /* Both channels' filters in one vector; the energy adds left then right, as below. */
        Biquad2 shelf={{(double2){m->shelf[0].z[0],m->shelf[1].z[0]}, (double2){m->shelf[0].z[1],m->shelf[1].z[1]}}};
        Biquad2 high={{(double2){m->highpass[0].z[0],m->highpass[1].z[0]}, (double2){m->highpass[0].z[1],m->highpass[1].z[1]}}};
        int failed=0;
        for (unsigned n=0;n<count;++n) {
            double2 v={l[n],r[n]};
            if (!isfinite(v.x) || !isfinite(v.y)) { failed=1; break; }
            m->sample_peak=fmax(m->sample_peak,fabs(v.x)); m->sample_peak=fmax(m->sample_peak,fabs(v.y));
            double2 y=filter2(&m->highpass[0],&high,filter2(&m->shelf[0],&shelf,v));
            if (!isfinite(y.x) || !isfinite(y.y)) { failed=1; break; }
            double e=0;
            e+=y.x*y.x;
            e+=y.y*y.y;
            line[0][31+n]=v.x; line[1][31+n]=v.y;
            m->sum += e-m->energy[m->index]; m->energy[m->index]=e;
            m->index=(m->index+1)%m->window; ++m->frames;
            if (m->frames>=m->window && (m->frames-m->window)%m->hop==0)
                out[written++]=fmax(0,m->sum/m->window);
        }
        for (unsigned ch=0;ch<2;++ch) {
            m->shelf[ch].z[0]=shelf.z[0][ch]; m->shelf[ch].z[1]=shelf.z[1][ch];
            m->highpass[ch].z[0]=high.z[0][ch]; m->highpass[ch].z[1]=high.z[1][ch];
        }
        if (failed) return -1;
    } else for (unsigned n=0;n<count;++n) {
        double v[2]={l[n], m->channels==2 ? r[n] : 0}, e=0;
        for (unsigned ch=0;ch<m->channels;++ch) {
            if (!isfinite(v[ch])) return -1;
            m->sample_peak=fmax(m->sample_peak,fabs(v[ch]));
            double y=filter(&m->highpass[ch],filter(&m->shelf[ch],v[ch]));
            if (!isfinite(y)) return -1;
            e+=y*y;
            line[ch][31+n]=v[ch];
        }
        m->sum += e-m->energy[m->index]; m->energy[m->index]=e;
        m->index=(m->index+1)%m->window; ++m->frames;
        if (m->frames>=m->window && (m->frames-m->window)%m->hop==0)
            out[written++]=fmax(0,m->sum/m->window);
    }
    for (unsigned ch=0;ch<m->channels;++ch) {
        true_peaks(m,line[ch],count);
        memcpy(m->tail[ch],line[ch]+count,sizeof(m->tail[ch]));
    }
    return (int)written;
}
/* Interpolates past the last sample through 32 frames of silence. */
void lcmp_level_flush_peak(LCMPLevelMeter *m) {
    double line[31+32]={0};
    for (unsigned ch=0;ch<m->channels;++ch) {
        memcpy(line,m->tail[ch],sizeof(m->tail[ch]));
        true_peaks(m,line,32);
        memset(m->tail[ch],0,sizeof(m->tail[ch]));
    }
}
double lcmp_level_sample_peak(const LCMPLevelMeter *m) { return m->sample_peak; }
double lcmp_level_true_peak(const LCMPLevelMeter *m) { return fmax(m->sample_peak,m->true_peak); }
uint64_t lcmp_level_frames(const LCMPLevelMeter *m) { return m->frames; }

/* Native sample peaks. Branch-free so -O2 vectorizes them; a NaN or infinity
   clears the returned flag instead of ending the loop early. */
int lcmp_peak_f32(const float *s, size_t count, size_t stride, double *peak) {
    float m=0; int finite=1;
    for (size_t i=0;i<count;++i) { float a=fabsf(s[i*stride]); finite&=(a<=FLT_MAX); m=a>m ? a : m; }
    *peak=m; return finite;
}
int lcmp_peak_f64(const double *s, size_t count, size_t stride, double *peak) {
    double m=0; int finite=1;
    for (size_t i=0;i<count;++i) { double a=fabs(s[i*stride]); finite&=(a<=DBL_MAX); m=a>m ? a : m; }
    *peak=m; return finite;
}
double lcmp_peak_i16(const int16_t *s, size_t count, size_t stride) {
    int m=0;
    for (size_t i=0;i<count;++i) { int a=abs((int)s[i*stride]); m=a>m ? a : m; }
    return m/32768.0;
}
double lcmp_peak_i32(const int32_t *s, size_t count, size_t stride) {
    int64_t m=0;
    for (size_t i=0;i<count;++i) { int64_t a=llabs((int64_t)s[i*stride]); m=a>m ? a : m; }
    return (double)m/2147483648.0;
}
double lcmp_peak_packed(const uint8_t *s, size_t count, size_t frame_bytes,
                        unsigned width, unsigned bits, int big_endian, int aligned_high) {
    if (!bits || bits > 32 || bits > width*8) return 0;
    uint64_t mask=(1ULL<<bits)-1, sign=1ULL<<(bits-1);
    int64_t m=0;
    for (size_t i=0;i<count;++i) {
        const uint8_t *b=s+i*frame_bytes; uint64_t x=0;
        for (unsigned k=0;k<width;++k) x|=(uint64_t)b[k]<<(big_endian ? (width-1-k)*8 : k*8);
        if (aligned_high) x>>=width*8-bits;
        x&=mask;
        int64_t v=(x&sign) ? (int64_t)x-(int64_t)(1ULL<<bits) : (int64_t)x, a=v<0 ? -v : v;
        m=a>m ? a : m;
    }
    return (double)m/(double)(1ULL<<(bits-1));
}
