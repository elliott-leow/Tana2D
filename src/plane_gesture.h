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
    if(continuous && hypot(dx,dy)<.15) {
        out->x-=dx*width*gain/camera.scale;
        out->y+=dy*width*aspect*gain/camera.scale;
    }
    g->active=true; g->device=device; g->time=time;
    for(int i=0;i<3;i++) g->contacts[i]=contacts[i];
    return true;
}
#endif
