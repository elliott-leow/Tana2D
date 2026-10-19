#ifndef TANA2D_PLANE_PINCH_H
#define TANA2D_PLANE_PINCH_H
#include "plane_gesture.h"
#include <math.h>
/* A two-finger pinch read from the raw contacts rather than from the
 * system's magnify events. The system's recogniser only reports a pinch
 * when the fingers move against each other; a natural pinch, where the
 * thumb rests or both fingers drift the same way while they part, it reads
 * as a scroll. Here the zoom is the change in the fingers' separation, which
 * a shared drift does not touch.
 *
 * Contacts are normalised to the sensor; y is scaled by the sensor's aspect
 * so distances are in widths of the trackpad (about 16 cm). A pair is
 * undecided until the separation has changed by HWM_PINCH_CLEAR with little
 * shared travel, or by HWM_PINCH_START while still a fair share of that
 * travel: then it zooms, catching up on the change so far. Shared travel of
 * HWM_PINCH_SCROLL with the separation steady is a scroll, and the pair
 * stays one until it lifts. */
#define HWM_PINCH_CLEAR .012
#define HWM_PINCH_START .02
#define HWM_PINCH_SCROLL .02
#define HWM_PINCH_SHARE .3
#define HWM_PINCH_MIN_SEPARATION .005
typedef struct {
    bool tracking,engaged,scroll;
    uintptr_t device;
    HWMPlaneContact contacts[2];
    double time,aspect;
    double separation;                    // last frame's, once engaged
    double origin_separation,origin_x,origin_y; // where the pair was first seen
} HWMPlanePinch;
enum { HWM_PINCH_NONE, HWM_PINCH_HOLD, HWM_PINCH_BEGIN, HWM_PINCH_CHANGE, HWM_PINCH_END };
static inline double hwm_plane_pinch_separation(const HWMPlaneContact *c,double aspect)
{
    return hypot(c[0].x-c[1].x,(c[0].y-c[1].y)*aspect);
}
/* Feed one contact frame. BEGIN and CHANGE carry the zoom to apply in
 * *delta, as the natural log of the separation ratio; END means the fingers
 * lifted (or a third landed) after a zoom; HOLD means a zoom is in hand but
 * this frame moved nothing (a momentary one-finger frame while lifting, or
 * steady fingers). */
static inline int hwm_plane_pinch_sample(HWMPlanePinch *p,uintptr_t device,const HWMPlaneContact *contacts,int count,
                                         double time,double aspect,double *delta)
{
    if(delta) *delta=0;
    if(!p || !isfinite(time)) return HWM_PINCH_NONE;
    if(!(aspect>0) || !isfinite(aspect)) aspect=.625;
    bool was_engaged=p->engaged;
    if(count!=2 || (p->tracking && device!=p->device)) {
        if(was_engaged && count==1 && device==p->device && time>=p->time && time-p->time<.2) return HWM_PINCH_HOLD;
        *p=(HWMPlanePinch){0};
        return was_engaged ? HWM_PINCH_END : HWM_PINCH_NONE;
    }
    for(int i=0;i<2;i++) if(!isfinite(contacts[i].x) || !isfinite(contacts[i].y)) return was_engaged ? HWM_PINCH_HOLD : HWM_PINCH_NONE;
    bool continuous=p->tracking && time>=p->time && time-p->time<.2;
    if(continuous) {
        bool same=(contacts[0].id==p->contacts[0].id && contacts[1].id==p->contacts[1].id) ||
                  (contacts[0].id==p->contacts[1].id && contacts[1].id==p->contacts[0].id);
        if(!same) continuous=false;
    }
    double separation=hwm_plane_pinch_separation(contacts,aspect);
    double cx=(contacts[0].x+contacts[1].x)*.5,cy=(contacts[0].y+contacts[1].y)*.5;
    if(!continuous) {
        // A new pair (or a replaced finger): measure from here.
        *p=(HWMPlanePinch){.tracking=true,.device=device,.time=time,.aspect=aspect,
                           .separation=separation,.origin_separation=separation,.origin_x=cx,.origin_y=cy};
        p->contacts[0]=contacts[0]; p->contacts[1]=contacts[1];
        return was_engaged ? HWM_PINCH_END : HWM_PINCH_NONE;
    }
    p->time=time; p->contacts[0]=contacts[0]; p->contacts[1]=contacts[1];
    if(p->engaged) {
        if(separation<HWM_PINCH_MIN_SEPARATION || p->separation<HWM_PINCH_MIN_SEPARATION) { p->separation=separation; return HWM_PINCH_HOLD; }
        double d=log(separation/p->separation);
        p->separation=separation;
        if(!isfinite(d) || d==0) return HWM_PINCH_HOLD;
        if(delta) *delta=d;
        return HWM_PINCH_CHANGE;
    }
    if(p->scroll) return HWM_PINCH_NONE;
    double spread=fabs(separation-p->origin_separation);
    double travel=hypot(cx-p->origin_x,(cy-p->origin_y)*aspect);
    bool clear=spread>=HWM_PINCH_CLEAR && spread>=1.5*travel;
    bool natural=spread>=HWM_PINCH_START && spread>=HWM_PINCH_SHARE*travel;
    if((clear || natural) && separation>=HWM_PINCH_MIN_SEPARATION && p->origin_separation>=HWM_PINCH_MIN_SEPARATION) {
        double d=log(separation/p->origin_separation);
        if(isfinite(d)) {
            p->engaged=true; p->separation=separation;
            if(delta) *delta=d;
            return HWM_PINCH_BEGIN;
        }
    }
    if(travel>=HWM_PINCH_SCROLL && spread<HWM_PINCH_SHARE*travel) p->scroll=true;
    return HWM_PINCH_NONE;
}
#endif
