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
 * so distances are in widths of the trackpad (about 16 cm). The pair's
 * motion since it was last at rest is split into spread, the change in the
 * fingers' separation, and travel, the distance their midpoint has moved.
 * A scroll is nearly all travel; a pinch is mostly spread, however much the
 * fingers also drift.
 *
 * The pair reads as a pinch when the spread is at least HWM_PINCH_SHARE of
 * the travel, both since the rest and over the most recent HWM_PINCH_RECENT
 * of motion (or the latter half of it, when there is less), and the two
 * together reach HWM_PINCH_DECIDE. At a share of 1 the fingers must part
 * at least as fast as they move together: a thumb that rests, or drifts
 * along at under a third of the index finger's speed, is a pinch; fingers
 * moving the same way at different speeds are a scroll. A scroll often starts with one finger a
 * few millimetres ahead of the other, which at that moment is exactly a
 * thumb-anchored pinch; only what follows tells them apart. The trailing
 * finger catches up within a few frames, after which the recent motion is
 * all travel. So the pair zooms only once it has read as a pinch for
 * HWM_PINCH_CONFIRM without a break. The change so far is not lost: it is
 * paid out over the next HWM_PINCH_CATCH_UP on top of the fingers' own
 * motion, so the zoom starts a little ahead of the fingers' rate and then
 * matches it, rather than leaping by a jump that grows with the speed of
 * the pinch. Fingers moving against each other, each by at least
 * HWM_PINCH_OPPOSE of the spread, cannot be a scroll's lead: that pair zooms
 * at a spread of HWM_PINCH_CLEAR that is HWM_PINCH_CLEAR_SHARE of the
 * travel, after the shorter HWM_PINCH_CONFIRM_OPPOSED, so a clean pinch
 * answers early. The system's own recogniser reports a magnify only when
 * the fingers move against each other, which a scroll never does: the
 * caller notes its reports in system_pinch, and an undecided pair the
 * system has called a pinch within HWM_PINCH_SYSTEM zooms at once.
 *
 * A pair that has reached the decision point reading as a scroll both since
 * the rest and recently is a scroll until it lifts, so it never turns into
 * a zoom part-way; a zoom's drift never scrolls. A pair that is ambiguous
 * stays undecided, scrolling the application meanwhile, until the motion
 * settles it either way.
 *
 * While undecided, a pair whose fingers have both stayed within
 * HWM_PINCH_REST of where they were for HWM_PINCH_REST_TIME is measured
 * afresh from where it rests: fingers settling as they land, or resting
 * before the gesture, do not count toward the decision. */
#define HWM_PINCH_CLEAR .01
#define HWM_PINCH_CLEAR_SHARE 1.5
#define HWM_PINCH_OPPOSE .3
#define HWM_PINCH_DECIDE .02
#define HWM_PINCH_SHARE 1
#define HWM_PINCH_RECENT .01
#define HWM_PINCH_CONFIRM .06
#define HWM_PINCH_CONFIRM_OPPOSED .03
#define HWM_PINCH_SYSTEM .15
#define HWM_PINCH_CATCH_UP .06
#define HWM_PINCH_REST .001
#define HWM_PINCH_REST_TIME .1
#define HWM_PINCH_MIN_SEPARATION .005
/* Frames kept since the rest, for the recent-motion window: about 0.4 s at
 * the trackpad's report rate. A window reaching further back ends at the
 * oldest frame kept. */
#define HWM_PINCH_HISTORY 48
typedef struct { double separation,x,y; } HWMPlanePinchSample;
/* What the last undecided frame measured, for diagnostics: distances in
 * sensor widths, since the rest. */
typedef struct {
    double spread,travel,recent_spread,recent_travel,since_rest;
    bool opposed,share,recent,system;
} HWMPlanePinchReading;
typedef struct {
    bool tracking,engaged,scroll,blocked;
    uintptr_t device;
    HWMPlaneContact contacts[2];
    double time,aspect,pair_time;
    double separation;                    // last frame's, once engaged
    HWMPlaneContact origin[2];            // where the pair was last at rest
    double origin_separation,origin_x,origin_y;
    HWMPlaneContact still[2]; double still_time; // where the fingers last moved to, and when
    double pinch_since;                   // when the pair began reading as a pinch without a break, or -1
    bool pinch_opposed;                   // ...with the fingers moving against each other throughout
    double backlog,backlog_rate;          // zoom accrued before the pair engaged, still to pay out, and how fast
    double system_pinch;                  // set by the caller: when the system last reported a magnify, on the frame clock
    double rest_time;                     // when the pair was last at rest
    HWMPlanePinchReading reading;
    HWMPlanePinchSample history[HWM_PINCH_HISTORY]; int history_count,history_next;
} HWMPlanePinch;
enum { HWM_PINCH_NONE, HWM_PINCH_HOLD, HWM_PINCH_BEGIN, HWM_PINCH_CHANGE, HWM_PINCH_END };
/* A click/drag owns these contacts until every finger lifts. Discard the
 * pending zoom too: releasing the button is not a new pinch gesture. */
static inline void hwm_plane_pinch_cancel(HWMPlanePinch *p)
{
    *p=(HWMPlanePinch){.blocked=true};
}
static inline double hwm_plane_pinch_separation(const HWMPlaneContact *c,double aspect)
{
    return hypot(c[0].x-c[1].x,(c[0].y-c[1].y)*aspect);
}
static inline void hwm_plane_pinch_record(HWMPlanePinch *p,double separation,double x,double y)
{
    p->history[p->history_next]=(HWMPlanePinchSample){separation,x,y};
    p->history_next=(p->history_next+1)%HWM_PINCH_HISTORY;
    if(p->history_count<HWM_PINCH_HISTORY) ++p->history_count;
}
static inline void hwm_plane_pinch_rebase(HWMPlanePinch *p,const HWMPlaneContact *contacts,double separation,double time)
{
    p->origin[0]=contacts[0]; p->origin[1]=contacts[1];
    p->origin_separation=separation;
    p->origin_x=(contacts[0].x+contacts[1].x)*.5; p->origin_y=(contacts[0].y+contacts[1].y)*.5;
    p->still[0]=contacts[0]; p->still[1]=contacts[1]; p->still_time=time;
    p->pinch_since=-1; p->pinch_opposed=false; p->rest_time=time;
    p->history_count=0; p->history_next=0;
    hwm_plane_pinch_record(p,separation,p->origin_x,p->origin_y);
}
/* The part of the backlog due over `since` seconds, taken off it. */
static inline double hwm_plane_pinch_drain(HWMPlanePinch *p,double since)
{
    if(p->backlog==0) return 0;
    double give=p->backlog_rate*fmax(0,since);
    if(fabs(give)>=fabs(p->backlog)) give=p->backlog;
    p->backlog-=give;
    return give;
}
/* The pair starts zooming: the change since the rest goes into the backlog
 * and this frame's share of it into *delta. */
static inline int hwm_plane_pinch_engage(HWMPlanePinch *p,double separation,double since,double *delta)
{
    double d=log(separation/p->origin_separation);
    if(!isfinite(d)) return HWM_PINCH_NONE;
    p->engaged=true; p->separation=separation;
    p->backlog=d; p->backlog_rate=d/HWM_PINCH_CATCH_UP;
    if(delta) *delta=hwm_plane_pinch_drain(p,since);
    return HWM_PINCH_BEGIN;
}
/* The contact among the two matching c's id, or the other if neither does. */
static inline const HWMPlaneContact *hwm_plane_pinch_match(const HWMPlaneContact *pair,const HWMPlaneContact *c,int i)
{
    return pair[i].id==c->id ? &pair[i] : &pair[1-i];
}
/* Feed one contact frame. BEGIN and CHANGE carry the zoom to apply in
 * *delta, as the natural log of the separation ratio; END means the fingers
 * lifted (or a third landed) after a zoom; HOLD means a zoom is in hand but
 * this frame moved nothing (a momentary one-finger frame while lifting, or
 * steady fingers). A pair decided as a scroll reports NONE until it lifts. */
static inline int hwm_plane_pinch_sample(HWMPlanePinch *p,uintptr_t device,const HWMPlaneContact *contacts,int count,
                                         double time,double aspect,double *delta)
{
    if(delta) *delta=0;
    if(!p || !isfinite(time)) return HWM_PINCH_NONE;
    if(p->blocked || p->scroll) {
        if(count==0) *p=(HWMPlanePinch){0};
        return HWM_PINCH_NONE;
    }
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
    if(!continuous) {
        // A new pair (or a replaced finger): measure from here.
        *p=(HWMPlanePinch){.tracking=true,.device=device,.time=time,.aspect=aspect,.pair_time=time,.separation=separation};
        p->contacts[0]=contacts[0]; p->contacts[1]=contacts[1];
        hwm_plane_pinch_rebase(p,contacts,separation,time);
        return was_engaged ? HWM_PINCH_END : HWM_PINCH_NONE;
    }
    double since=time-p->time;
    p->time=time; p->contacts[0]=contacts[0]; p->contacts[1]=contacts[1];
    if(p->engaged) {
        double d=0;
        if(separation>=HWM_PINCH_MIN_SEPARATION && p->separation>=HWM_PINCH_MIN_SEPARATION) {
            d=log(separation/p->separation);
            if(!isfinite(d)) d=0;
        }
        p->separation=separation;
        d+=hwm_plane_pinch_drain(p,since);
        if(d==0) return HWM_PINCH_HOLD;
        if(delta) *delta=d;
        return HWM_PINCH_CHANGE;
    }
    if(p->scroll) return HWM_PINCH_NONE;
    // Fingers that have held still long enough rest here: start over.
    bool moved=false;
    for(int i=0;i<2 && !moved;i++) {
        const HWMPlaneContact *s=hwm_plane_pinch_match(p->still,&contacts[i],i);
        if(hypot(contacts[i].x-s->x,(contacts[i].y-s->y)*aspect)>=HWM_PINCH_REST) moved=true;
    }
    if(moved) { p->still[0]=contacts[0]; p->still[1]=contacts[1]; p->still_time=time; }
    else if(time-p->still_time>=HWM_PINCH_REST_TIME) { hwm_plane_pinch_rebase(p,contacts,separation,time); return HWM_PINCH_NONE; }
    double cx=(contacts[0].x+contacts[1].x)*.5,cy=(contacts[0].y+contacts[1].y)*.5;
    double signed_spread=separation-p->origin_separation,spread=fabs(signed_spread);
    double travel=hypot(cx-p->origin_x,(cy-p->origin_y)*aspect);
    /* Rotation is another two-finger gesture. Once angular motion dominates,
     * incidental separation changes must not turn it into workspace zoom.
     * Match identities so a reordered contact array is not a half-turn. */
    const HWMPlaneContact *a=hwm_plane_pinch_match(contacts,&p->origin[0],0);
    const HWMPlaneContact *b=hwm_plane_pinch_match(contacts,&p->origin[1],1);
    double ox=p->origin[1].x-p->origin[0].x,oy=(p->origin[1].y-p->origin[0].y)*aspect;
    double nx=b->x-a->x,ny=(b->y-a->y)*aspect;
    double angle=fabs(atan2(ox*ny-oy*nx,ox*nx+oy*ny));
    double arc=fmin(separation,p->origin_separation)*angle;
    if(angle>=.12 && arc>=HWM_PINCH_CLEAR && arc>1.5*spread) {
        p->scroll=true; return HWM_PINCH_NONE;
    }
    double motion=hypot(spread,travel);
    /* The recent window: back to the latest frame at which the motion was
     * at most HWM_PINCH_RECENT short of now, or half of now when that is
     * less, so the window is never empty. Spread in it counts only the way
     * the separation has changed overall. */
    double reach=fmax(motion-HWM_PINCH_RECENT,motion*.5);
    const HWMPlanePinchSample *from=NULL;
    for(int k=0;k<p->history_count;k++) {
        const HWMPlanePinchSample *s=&p->history[(p->history_next-1-k+HWM_PINCH_HISTORY)%HWM_PINCH_HISTORY];
        from=s;
        double s_spread=fabs(s->separation-p->origin_separation),s_travel=hypot(s->x-p->origin_x,(s->y-p->origin_y)*aspect);
        if(hypot(s_spread,s_travel)<=reach) break;
    }
    hwm_plane_pinch_record(p,separation,cx,cy);
    double recent_spread=0,recent_travel=0;
    if(from) {
        recent_spread=(separation-from->separation)*(signed_spread<0 ? -1 : 1);
        recent_travel=hypot(cx-from->x,(cy-from->y)*aspect);
    }
    bool recent=recent_spread>=HWM_PINCH_REST && recent_spread>=HWM_PINCH_SHARE*recent_travel;
    // Each finger's movement along the line between them, since the rest.
    bool opposed=false;
    if(p->origin_separation>=HWM_PINCH_MIN_SEPARATION) {
        double ux=(p->origin[1].x-p->origin[0].x)/p->origin_separation,uy=(p->origin[1].y-p->origin[0].y)*aspect/p->origin_separation;
        double along[2];
        for(int i=0;i<2;i++) {
            const HWMPlaneContact *o=hwm_plane_pinch_match(p->origin,&contacts[i],i);
            along[i]=(contacts[i].x-o->x)*ux+(contacts[i].y-o->y)*aspect*uy;
            if(o==&p->origin[1]) along[i]=-along[i]; // toward the other finger is positive for both
        }
        opposed=along[0]*along[1]>0 && fmin(fabs(along[0]),fabs(along[1]))>=HWM_PINCH_OPPOSE*fabs(along[0]+along[1]);
    }
    bool share=spread>=HWM_PINCH_SHARE*travel;
    bool clear=opposed && spread>=HWM_PINCH_CLEAR && spread>=HWM_PINCH_CLEAR_SHARE*travel;
    bool decide=motion>=HWM_PINCH_DECIDE;
    bool apart=separation>=HWM_PINCH_MIN_SEPARATION && p->origin_separation>=HWM_PINCH_MIN_SEPARATION;
    bool system=p->system_pinch>=p->pair_time && p->system_pinch>0 && fabs(time-p->system_pinch)<=HWM_PINCH_SYSTEM;
    p->reading=(HWMPlanePinchReading){spread,travel,recent_spread,recent_travel,time-p->rest_time,opposed,share,recent,system};
    if(system && apart && spread>=HWM_PINCH_REST) return hwm_plane_pinch_engage(p,separation,since,delta);
    bool pinch=(clear || (decide && share)) && recent && apart;
    if(!pinch) {
        p->pinch_since=-1; p->pinch_opposed=false;
        if(decide && !share && !recent) p->scroll=true;
        return HWM_PINCH_NONE;
    }
    if(p->pinch_since<0) { p->pinch_since=time; p->pinch_opposed=true; }
    if(!clear) p->pinch_opposed=false;
    double confirm=p->pinch_opposed ? HWM_PINCH_CONFIRM_OPPOSED : HWM_PINCH_CONFIRM;
    if(time-p->pinch_since<confirm) return HWM_PINCH_NONE;
    return hwm_plane_pinch_engage(p,separation,since,delta);
}
#endif
