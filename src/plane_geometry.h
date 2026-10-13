#ifndef TANA_PLANE_GEOMETRY_H
#define TANA_PLANE_GEOMETRY_H

/* Pure geometry for the unbounded 2D window plane.  World coordinates are
 * never clamped: camera movement is translation, and zoom only changes the
 * projection used to show the existing arrangement. */
#include <math.h>
#include <stdbool.h>
#include "strip_geometry.h"

typedef struct { double x, y, width, height; } HWMPlaneRect;
typedef struct { double x, y, scale; } HWMPlaneCamera;
typedef struct { double x, y; } HWMPlanePoint;

#define HWM_PLANE_PHYSICAL_LIMIT 1000000.0

/* World coordinates can grow without bound; WindowServer coordinates cannot.
 * Clamp only the physical submission, preserving the saved world point. */
static inline double hwm_plane_project_physical(double world,double camera,double origin,double scale)
{
    if(!isfinite(world) || !isfinite(camera) || !isfinite(origin)) return origin;
    double zoom=isfinite(scale) && scale>0 ? scale : 1;
    double limit=HWM_PLANE_PHYSICAL_LIMIT/zoom;
    if(world>=camera) {
        double delta=world-camera;
        if(!isfinite(delta) || delta>=limit) return HWM_PLANE_PHYSICAL_LIMIT;
    } else {
        double delta=camera-world;
        if(!isfinite(delta) || delta>=limit) return -HWM_PLANE_PHYSICAL_LIMIT;
    }
    /* hstrip_project_x is also the final guard against platform IPC limits. */
    return hstrip_project_x((world-camera)*zoom,0,origin,HWM_PLANE_PHYSICAL_LIMIT);
}

static inline double hwm_plane_physical_size(double value)
{
    return isfinite(value) && value>0 ? fmin(HWM_PLANE_PHYSICAL_LIMIT,value) : 1;
}

static inline HWMPlaneCamera hwm_plane_camera_pan(HWMPlaneCamera camera,double dx,double dy)
{
    if(isfinite(dx)) camera.x+=dx;
    if(isfinite(dy)) camera.y+=dy;
    return camera;
}

static inline HWMPlaneRect hwm_plane_project(HWMPlaneRect world,HWMPlaneCamera camera,HWMPlaneRect viewport)
{
    double scale=isfinite(camera.scale) && camera.scale>0 ? camera.scale : 1;
    return (HWMPlaneRect){viewport.x+(world.x-camera.x)*scale,
                          viewport.y+(world.y-camera.y)*scale,
                          world.width*scale,world.height*scale};
}

/* Convert an on-screen drag point into world coordinates.  The origin is
 * captured when the drag begins; camera_delta accounts for edge panning that
 * happens while the pointer remains at the display edge. */
static inline HWMPlanePoint hwm_plane_drag_world(HWMPlanePoint origin,HWMPlanePoint pointer,
                                                 HWMPlanePoint pointer_origin,double scale,
                                                 double camera_dx,double camera_dy)
{
    double zoom=isfinite(scale) && scale>0 ? scale : 1;
    origin.x+=(pointer.x-pointer_origin.x)/zoom+camera_dx;
    origin.y+=(pointer.y-pointer_origin.y)/zoom+camera_dy;
    return origin;
}

/* Fit the tight bounding rectangle inside viewport with `inset` points on
 * each side. The returned camera retains the world geometry unchanged. */
static inline HWMPlaneCamera hwm_plane_camera_fit(HWMPlaneRect world,HWMPlaneRect viewport,double inset)
{
    HWMPlaneCamera camera={world.x,world.y,1};
    if(!isfinite(world.x)||!isfinite(world.y)||!isfinite(world.width)||!isfinite(world.height)||
       !isfinite(viewport.width)||!isfinite(viewport.height)||world.width<=0||world.height<=0||viewport.width<=0||viewport.height<=0) return camera;
    double available_w=fmax(1,viewport.width-fmax(0,inset)*2), available_h=fmax(1,viewport.height-fmax(0,inset)*2);
    camera.scale=fmin(1,fmin(available_w/world.width,available_h/world.height));
    camera.x=world.x-(viewport.width/camera.scale-world.width)*.5;
    camera.y=world.y-(viewport.height/camera.scale-world.height)*.5;
    return camera;
}

static inline bool hwm_plane_reveal(HWMPlaneCamera camera,HWMPlaneRect world,HWMPlaneRect viewport,HWMPlaneCamera *out)
{
    if(!out || camera.scale<=0 || !isfinite(camera.scale)) return false;
    double visible_w=viewport.width/camera.scale, visible_h=viewport.height/camera.scale;
    HWMPlaneCamera next=camera;
    if(world.x<camera.x) next.x=world.x;
    else if(world.x+world.width>camera.x+visible_w) next.x=world.x+world.width-visible_w;
    if(world.y<camera.y) next.y=world.y;
    else if(world.y+world.height>camera.y+visible_h) next.y=world.y+world.height-visible_h;
    *out=next;
    return next.x!=camera.x || next.y!=camera.y;
}

/* Magnetize adjacent edges, with optional top/bottom or left/right alignment.
 * The caller expresses the range in world units, keeping its screen radius
 * consistent at every zoom. Rectangles away from one another stay untouched. */
static inline HWMPlanePoint hwm_plane_snap_neighbor(HWMPlaneRect moving,HWMPlaneRect other,double gap,double range)
{
    HWMPlanePoint best={moving.x,moving.y}; double cost=INFINITY;
    double xs[2]={other.x-moving.width-gap,other.x+other.width+gap};
    double ys[2]={other.y-moving.height-gap,other.y+other.height+gap};
    bool overlap_y=moving.y+moving.height>=other.y-range && moving.y<=other.y+other.height+range;
    bool overlap_x=moving.x+moving.width>=other.x-range && moving.x<=other.x+other.width+range;
    for(int axis=0;axis<2;axis++) for(int side=0;side<2;side++) {
        if(axis==0 ? !overlap_y : !overlap_x) continue;
        double delta=axis==0?xs[side]-moving.x:ys[side]-moving.y;
        if(fabs(delta)>range) continue;
        HWMPlanePoint candidate={axis==0?xs[side]:moving.x,axis==1?ys[side]:moving.y};
        double a=axis==0?other.y-moving.y:other.x-moving.x;
        double b=axis==0?other.y+other.height-moving.height-moving.y:other.x+other.width-moving.width-moving.x;
        double align=fabs(a)<=fabs(b)?a:b;
        if(fabs(align)<=range) { if(axis==0) candidate.y+=align; else candidate.x+=align; }
        double distance=hypot(candidate.x-moving.x,candidate.y-moving.y);
        if(distance<cost) { best=candidate; cost=distance; }
    }
    return best;
}

#endif
