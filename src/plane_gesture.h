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
    if(count!=3) { bool was=g->active; g->active=false; return was; }
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
/* A four-finger vertical swipe selects once, then stays latched until all
 * contacts lift. Contact replacement and stale frames establish a new baseline. */
typedef struct {
    bool tracking,fired,engaged;
    uintptr_t device;
    HWMPlaneContact contacts[4];
    double time,dx,dy;
} HWMPlaneSelectionGesture;
static inline bool hwm_plane_selection_gesture_sample(HWMPlaneSelectionGesture *g,uintptr_t device,
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
    if(!g->fired && fabs(g->dy)>=.045 && fabs(g->dy)>fabs(g->dx)*1.3) { g->fired=true; return true; }
    return false;
}
#endif
