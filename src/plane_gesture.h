#ifndef TANA2D_PLANE_GESTURE_H
#define TANA2D_PLANE_GESTURE_H
#include "plane_geometry.h"
#include <stdint.h>
typedef struct { int id; double x,y; } HWMPlaneContact;
typedef struct {
    bool active;
    uintptr_t device;
    HWMPlaneContact contacts[3];
    double time;
} HWMPlaneGesture;
/* Track identities, not the centroid of a changing finger set. Coordinates
 * increase right/up on the sensor; screen coordinates increase right/down. */
static inline bool hwm_plane_gesture_sample(HWMPlaneGesture *g,uintptr_t device,const HWMPlaneContact *contacts,int count,
                                            double time,double width,double aspect,double gain,HWMPlaneCamera camera,
                                            HWMPlaneCamera *out)
{
    if(!g || !out || !isfinite(time) || camera.scale<=0 || !isfinite(camera.scale)) return false;
    *out=camera;
    if(g->active && device!=g->device) return false;
    /* Fingers rarely land or lift together. A momentary one- or two-finger
     * frame holds the gesture without moving the camera; ending it there made
     * the renderer start native placement mid-swipe, then resume panning over
     * windows that were still being moved. Only a full lift (or a stale
     * pause) ends it. Matching identities on return avoids a centroid jump. */
    if(count!=3) {
        if(!g->active) return false;
        if(count>0 && count<3 && time>=g->time && time-g->time<.2) return false;
        g->active=false; return true;
    }
    for(int i=0;i<3;i++) if(!isfinite(contacts[i].x) || !isfinite(contacts[i].y)) return false;
    double dx=0,dy=0; bool continuous=g->active && time>=g->time && time-g->time<.2;
    if(continuous) for(int i=0;i<3;i++) {
        int found=-1;
        for(int j=0;j<3;j++) if(contacts[i].id==g->contacts[j].id) found=j;
        if(found<0) { continuous=false; break; }
        dx+=(contacts[i].x-g->contacts[found].x)/3;
        dy+=(contacts[i].y-g->contacts[found].y)/3;
    }
    if(continuous) {
        out->x-=dx*width*gain/camera.scale;
        out->y+=dy*width*aspect*gain/camera.scale;
    }
    g->active=true; g->device=device; g->time=time;
    for(int i=0;i<3;i++) g->contacts[i]=contacts[i];
    return true;
}
/* Camera velocity at release, from the last few pan samples. A pause before
 * lifting, or too short a history, reads as zero: only a moving release
 * carries on. Units are plane points per second. */
typedef struct { double time[8],x[8],y[8]; unsigned count; } HWMPlaneVelocity;
static inline void hwm_plane_velocity_add(HWMPlaneVelocity *v,double time,double x,double y)
{
    if(!v || !isfinite(time) || !isfinite(x) || !isfinite(y)) return;
    if(v->count && time<v->time[(v->count-1)%8]) v->count=0;
    unsigned i=v->count++%8; v->time[i]=time; v->x[i]=x; v->y[i]=y;
}
static inline HWMPlanePoint hwm_plane_velocity_release(const HWMPlaneVelocity *v,double now,double omega)
{
    HWMPlanePoint zero={0,0};
    if(!v || v->count<2 || !isfinite(now)) return zero;
    unsigned last=(v->count-1)%8;
    if(now-v->time[last]>.06) return zero;
    unsigned available=v->count<8 ? v->count : 8, oldest=last;
    for(unsigned k=1;k<available;k++) {
        unsigned i=(v->count-1-k)%8;
        if(v->time[last]-v->time[i]>.1) break;
        oldest=i;
    }
    double dt=v->time[last]-v->time[oldest];
    if(oldest==last || dt<.012) return zero;
    /* Fingers rarely lift together, and a partial lift holds the camera.
     * Release with the velocity the glide would have reached by now had it
     * begun at the last sample, so motion resumes without a jolt. */
    double decay=isfinite(omega) && omega>0 ? exp(-omega*fmax(0,now-v->time[last])) : 1;
    HWMPlanePoint out={(v->x[last]-v->x[oldest])/dt*decay,(v->y[last]-v->y[oldest])/dt*decay};
    return isfinite(out.x) && isfinite(out.y) ? out : zero;
}
/* A four-finger vertical swipe selects once, then stays latched until all
 * contacts lift. Contact replacement and stale frames establish a new baseline. */
typedef struct {
    bool tracking,fired,engaged;
    uintptr_t device;
    HWMPlaneContact contacts[4];
    double time,dx,dy;
} HWMPlaneSelectionGesture;
/* Returns +1 for up (overview), -1 for down (active window), or 0. */
static inline int hwm_plane_selection_gesture_sample(HWMPlaneSelectionGesture *g,uintptr_t device,
                                                       const HWMPlaneContact *contacts,int count,double time)
{
    if(!g || !isfinite(time)) return false;
    if(g->engaged && device!=g->device) return false;
    if(count==0) { *g=(HWMPlaneSelectionGesture){0}; return false; }
    if(count!=4) { g->tracking=false; return false; }
    for(int i=0;i<4;i++) if(!isfinite(contacts[i].x) || !isfinite(contacts[i].y)) return false;
    bool continuous=g->tracking && time>=g->time && time-g->time<.2;
    double dx=0,dy=0;
    if(continuous) for(int i=0;i<4;i++) {
        int found=-1;
        for(int j=0;j<4;j++) if(contacts[i].id==g->contacts[j].id) found=j;
        if(found<0) { continuous=false; break; }
        dx+=(contacts[i].x-g->contacts[found].x)/4;
        dy+=(contacts[i].y-g->contacts[found].y)/4;
    }
    if(continuous) { g->dx+=dx; g->dy+=dy; } else { g->dx=0; g->dy=0; }
    g->tracking=true; g->engaged=true; g->device=device; g->time=time;
    for(int i=0;i<4;i++) g->contacts[i]=contacts[i];
    if(!g->fired && fabs(g->dy)>=.045 && fabs(g->dy)>fabs(g->dx)*1.3) { g->fired=true; return g->dy>0 ? 1 : -1; }
    return false;
}
#endif
