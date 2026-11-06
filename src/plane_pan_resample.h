#ifndef TANA_PLANE_PAN_RESAMPLE_H
#define TANA_PLANE_PAN_RESAMPLE_H
#include <stdbool.h>
#include <math.h>
#include <string.h>

/* World-space positions measured by the touch device. This predictor never
 * modifies those positions: its output is only for a display frame. */
enum { HWM_PAN_RESAMPLE_CAPACITY = 64 };
typedef struct { double time, x, y; } HWMPanSample;
typedef struct { HWMPanSample samples[HWM_PAN_RESAMPLE_CAPACITY]; int count; } HWMPanResampler;
typedef struct { double x, y; } HWMPanPosition;

static inline void hwm_pan_resample_reset(HWMPanResampler *r) { r->count=0; }
static inline bool hwm_pan_resample_add(HWMPanResampler *r,double time,double x,double y)
{
    if(!r || !isfinite(time) || !isfinite(x) || !isfinite(y)) return false;
    if(r->count) {
        HWMPanSample prev=r->samples[r->count-1];
        if(time<=prev.time) return false;
        /* A pause or a turn ends the old velocity estimate. The previous
         * point still anchors a new, direction-correct estimate. */
        bool restart=time-prev.time>.05;
        if(r->count>=2) {
            HWMPanSample before=r->samples[r->count-2];
            double dx=x-prev.x,dy=y-prev.y,ox=prev.x-before.x,oy=prev.y-before.y;
            double dot=dx*ox+dy*oy, magnitude=hypot(dx,dy)*hypot(ox,oy);
            if(magnitude>1e-12 && dot < -0.25*magnitude) restart=true;
        }
        if(restart) { r->samples[0]=prev; r->count=1; }
    }
    if(r->count==HWM_PAN_RESAMPLE_CAPACITY) {
        memmove(r->samples,r->samples+1,(HWM_PAN_RESAMPLE_CAPACITY-1)*sizeof(*r->samples));
        --r->count;
    }
    r->samples[r->count++]=(HWMPanSample){time,x,y};
    return true;
}
/* `time` is the intended display time, `refresh` its period in seconds.
 * A stale stream holds its last measurement. Prediction is capped at one
 * refresh plus two report intervals, and never exceeds 50 ms. */
static inline HWMPanPosition hwm_pan_resample_at(const HWMPanResampler *r,double time,double refresh)
{
    HWMPanPosition out={0,0};
    if(!r || !r->count) return out;
    HWMPanSample last=r->samples[r->count-1]; out=(HWMPanPosition){last.x,last.y};
    if(r->count<2 || !isfinite(time) || time<=last.time || time-last.time>.05) return out;
    HWMPanSample prev=r->samples[r->count-2];
    double dx=last.x-prev.x,dy=last.y-prev.y,dt=last.time-prev.time;
    if(dt<=0 || dt>.05) return out;
    double st=0,stt=0,sx=0,sy=0,stx=0,sty=0,oldest=0; int n=0;
    for(int i=r->count-1;i>=0 && last.time-r->samples[i].time<=.05;i--) {
        double t=r->samples[i].time-last.time;
        st+=t; stt+=t*t; sx+=r->samples[i].x; sy+=r->samples[i].y;
        stx+=t*r->samples[i].x; sty+=t*r->samples[i].y; oldest=t; ++n;
    }
    double denominator=n*stt-st*st;
    if(n<3 || -oldest<.012 || denominator<=1e-12) return out;
    double vx=(n*stx-st*sx)/denominator,vy=(n*sty-st*sy)/denominator;
    /* No axis may drift against its most recent motion, or after it stops. */
    if(vx*dx<=0) vx=0;
    if(vy*dy<=0) vy=0;
    if(!isfinite(refresh) || refresh<=0) refresh=1.0/60;
    double horizon=fmin(.05,refresh+2*dt), ahead=fmin(time-last.time,horizon);
    out.x+=vx*ahead; out.y+=vy*ahead;
    return out;
}
#endif
