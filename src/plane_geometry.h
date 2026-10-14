#ifndef TANA_PLANE_GEOMETRY_H
#define TANA_PLANE_GEOMETRY_H

/* Pure geometry for the unbounded 2D window plane.  World coordinates are
 * never clamped: camera movement is translation, and zoom only changes the
 * projection used to show the existing arrangement. */
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include "strip_geometry.h"

typedef struct { double x, y, width, height; } HWMPlaneRect;
typedef struct { double x, y, scale; } HWMPlaneCamera;
typedef struct { double x, y; } HWMPlanePoint;

static inline bool hwm_plane_camera_valid(HWMPlaneCamera camera)
{
    return isfinite(camera.x) && isfinite(camera.y) && isfinite(camera.scale) && camera.scale>0;
}

static inline HWMPlaneCamera hwm_plane_camera_fallback(HWMPlaneCamera from,HWMPlaneCamera to)
{
    if(hwm_plane_camera_valid(from)) return from;
    if(hwm_plane_camera_valid(to)) return to;
    return (HWMPlaneCamera){0,0,1};
}

static inline bool hwm_plane_rect_valid(HWMPlaneRect rect)
{
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) &&
           rect.width > 0 && rect.height > 0 && isfinite(rect.x+rect.width) && isfinite(rect.y+rect.height);
}

/* Interpolate world-space viewport centers and logarithmic zoom together.
 * This keeps a zoom's path smooth even when the two endpoint scales differ
 * greatly; interpolating top-left coordinates would make it arc off target. */
static inline HWMPlaneCamera hwm_plane_camera_mix(HWMPlaneCamera from,HWMPlaneCamera to,
                                                  double width,double height,double progress)
{
    HWMPlaneCamera fallback=hwm_plane_camera_fallback(from,to);
    if(!hwm_plane_camera_valid(from) || !hwm_plane_camera_valid(to) ||
       !isfinite(width) || !isfinite(height) || width<=0 || height<=0 || !isfinite(progress)) return fallback;
    if(progress<=0) return from;
    if(progress>=1) return to;
    double scale=exp(log(from.scale)+(log(to.scale)-log(from.scale))*progress);
    double cx=from.x+width/(2*from.scale),cy=from.y+height/(2*from.scale);
    double tx=to.x+width/(2*to.scale),ty=to.y+height/(2*to.scale);
    HWMPlaneCamera mixed={cx+(tx-cx)*progress-width/(2*scale),
                           cy+(ty-cy)*progress-height/(2*scale),scale};
    return hwm_plane_camera_valid(mixed) ? mixed : fallback;
}

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
    if(isfinite(dx)) { double next=camera.x+dx; if(isfinite(next)) camera.x=next; }
    if(isfinite(dy)) { double next=camera.y+dy; if(isfinite(next)) camera.y=next; }
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
    if(!out) return false;
    *out=camera;
    if(!hwm_plane_camera_valid(camera) || !hwm_plane_rect_valid(world) || !hwm_plane_rect_valid(viewport)) return false;
    double visible_w=viewport.width/camera.scale, visible_h=viewport.height/camera.scale;
    if(!isfinite(visible_w) || !isfinite(visible_h) ||
       !isfinite(camera.x+visible_w) || !isfinite(camera.y+visible_h)) return false;
    HWMPlaneCamera next=camera;
    if(world.x<camera.x) next.x=world.x;
    else if(world.x+world.width>camera.x+visible_w) next.x=world.x+world.width-visible_w;
    if(world.y<camera.y) next.y=world.y;
    else if(world.y+world.height>camera.y+visible_h) next.y=world.y+world.height-visible_h;
    if(!hwm_plane_camera_valid(next)) return false;
    *out=next;
    return next.x!=camera.x || next.y!=camera.y;
}

/* Rectangles which only touch at an edge do not overlap. */
static inline bool hwm_plane_rects_overlap(HWMPlaneRect a,HWMPlaneRect b)
{
    return a.x < b.x+b.width && a.x+a.width > b.x &&
           a.y < b.y+b.height && a.y+a.height > b.y;
}

static inline bool hwm_plane_snap_candidate_clear(HWMPlaneRect moving,HWMPlanePoint point,
                                                  const HWMPlaneRect *neighbors,size_t count)
{
    HWMPlaneRect candidate={point.x,point.y,moving.width,moving.height};
    for(size_t i=0;i<count;i++)
        if(hwm_plane_rect_valid(neighbors[i]) && hwm_plane_rects_overlap(candidate,neighbors[i])) return false;
    return true;
}

/* Choose the closest adjacent edge among all neighbors.  `range` and `gap`
 * are world-space distances. The Euclidean displacement, including optional
 * perpendicular alignment, never exceeds range. Candidates colliding with
 * any neighbor are rejected.
 */
static inline bool hwm_plane_snap_neighbors_target(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                                   size_t count,double gap,double range,HWMPlanePoint *out)
{
    if(!out || !hwm_plane_rect_valid(moving) || (!neighbors && count) ||
       !isfinite(gap) || gap < 0 || !isfinite(range) || range < 0) return false;
    HWMPlanePoint best={moving.x,moving.y};
    /* Preserve the single-neighbor contract: a missed magnet returns the
     * original position, while the boolean tells callers that no snap won. */
    *out=best;
    double cost=INFINITY;
    for(size_t i=0;i<count;i++) {
        HWMPlaneRect other=neighbors[i];
        if(!hwm_plane_rect_valid(other)) continue;
        double xs[2]={other.x-moving.width-gap,other.x+other.width+gap};
        double ys[2]={other.y-moving.height-gap,other.y+other.height+gap};
        bool overlap_y=moving.y+moving.height>=other.y-range && moving.y<=other.y+other.height+range;
        bool overlap_x=moving.x+moving.width>=other.x-range && moving.x<=other.x+other.width+range;
        for(int axis=0;axis<2;axis++) for(int side=0;side<2;side++) {
            if(axis==0 ? !overlap_y : !overlap_x) continue;
            double delta=axis==0 ? xs[side]-moving.x : ys[side]-moving.y;
            if(!isfinite(delta) || fabs(delta)>range) continue;
            HWMPlanePoint candidate={axis==0 ? xs[side] : moving.x,axis==1 ? ys[side] : moving.y};
            double a=axis==0 ? other.y-moving.y : other.x-moving.x;
            double b=axis==0 ? other.y+other.height-moving.height-moving.y : other.x+other.width-moving.width-moving.x;
            double align=fabs(a)<=fabs(b) ? a : b;
            if(hypot(delta,align)<=range) { if(axis==0) candidate.y+=align; else candidate.x+=align; }
            if(!isfinite(candidate.x) || !isfinite(candidate.y) ||
               !hwm_plane_snap_candidate_clear(moving,candidate,neighbors,count)) continue;
            double distance=hypot(candidate.x-moving.x,candidate.y-moving.y);
            if(distance>range) continue;
            /* Lexicographic ties make selection stable even if the window list is reordered. */
            if(distance<cost || (distance==cost &&
               (candidate.x<best.x || (candidate.x==best.x && candidate.y<best.y)))) {
                best=candidate; cost=distance;
            }
        }
    }
    if(!isfinite(cost)) return false;
    *out=best;
    return true;
}

/* Compatibility wrapper for existing callers with one neighbor. */
static inline bool hwm_plane_snap_neighbor_target(HWMPlaneRect moving,HWMPlaneRect other,double gap,double range,HWMPlanePoint *out)
{
    return hwm_plane_snap_neighbors_target(moving,&other,1,gap,range,out);
}

static inline HWMPlanePoint hwm_plane_snap_neighbor(HWMPlaneRect moving,HWMPlaneRect other,double gap,double range)
{
    HWMPlanePoint result={moving.x,moving.y};
    hwm_plane_snap_neighbor_target(moving,other,gap,range,&result);
    return result;
}

typedef struct { int side; double began; } HWMPlaneEdgePan;
static inline HWMPlanePoint hwm_plane_edge_pan(HWMPlaneEdgePan *state,HWMPlaneRect bounds,HWMPlanePoint pointer,double now,double scale)
{
    const double band=16;
    if(!state || !hwm_plane_rect_valid(bounds) || !isfinite(pointer.x) || !isfinite(pointer.y) ||
       !isfinite(now) || !isfinite(scale) || scale<=0) return (HWMPlanePoint){0,0};
    double x=0,y=0;
    if(pointer.x<bounds.x+band) x=-fmin(1,(bounds.x+band-pointer.x)/band);
    else if(pointer.x>bounds.x+bounds.width-band) x=fmin(1,(pointer.x-bounds.x-bounds.width+band)/band);
    if(pointer.y<bounds.y+band) y=-fmin(1,(bounds.y+band-pointer.y)/band);
    else if(pointer.y>bounds.y+bounds.height-band) y=fmin(1,(pointer.y-bounds.y-bounds.height+band)/band);
    int side=(x<0?-1:x>0?1:0)+(y<0?-3:y>0?3:0);
    if(!side || side!=state->side || !isfinite(state->began)) { state->side=side; state->began=now; }
    double held=now-state->began;
    if(!side || held<=.25) return (HWMPlanePoint){0,0};
    double rate=600*fmin(1,(held-.25)/.3)/scale;
    return (HWMPlanePoint){x*rate,y*rate};
}

/* A release can gently approach center, but cannot pull against an escape pan.
 * Distances and the 12-point cap are in display points at every zoom. */
static inline HWMPlaneCamera hwm_plane_magnetic_camera(HWMPlaneCamera start,HWMPlaneCamera end,HWMPlanePoint center)
{
    if(end.scale<=0 || !isfinite(end.scale)) return end;
    double dx=(center.x-end.x)*end.scale,dy=(center.y-end.y)*end.scale;
    double distance=hypot(dx,dy),previous=hypot(center.x-start.x,center.y-start.y)*end.scale;
    if(distance>=120 || distance<.01 || distance>previous-2 || hypot(end.x-start.x,end.y-start.y)*end.scale<2) return end;
    double strength=.2*fmin(1,(120-distance)/56),step=fmin(12,distance*strength);
    end.x+=dx/distance*step/end.scale; end.y+=dy/distance*step/end.scale;
    return end;
}

#endif
