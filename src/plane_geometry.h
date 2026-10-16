#ifndef TANA_PLANE_GEOMETRY_H
#define TANA_PLANE_GEOMETRY_H

/* Pure geometry for the unbounded 2D window plane.  World coordinates are
 * never clamped: camera movement is translation, and zoom only changes the
 * projection used to show the existing arrangement. */
#include <math.h>
#include <float.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "strip_geometry.h"

typedef struct { double x, y, width, height; } HWMPlaneRect;
typedef struct { double x, y, scale; } HWMPlaneCamera;
typedef struct { double x, y; } HWMPlanePoint;

#define HWM_PLANE_MIN_SCALE 0.001
#define HWM_PLANE_MAX_SCALE 1.0

/* The camera may zoom out, but never enlarge windows beyond actual size. */
static inline double hwm_plane_zoom_clamp(double scale)
{
    return isfinite(scale) && scale>0 ? fmin(HWM_PLANE_MAX_SCALE,scale) : 1;
}

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
    /* Translation follows 1/scale rather than time. The one plane point that
     * is shown at the same place before and after then stays still, so a
     * zoom reads as a single scale about that point instead of a pan that
     * drifts sideways while the scale catches up (and swings at the end). */
    double inverse=1/to.scale-1/from.scale, mix=progress;
    if(fabs(inverse)*fmin(from.scale,to.scale)>1e-6) mix=(1/scale-1/from.scale)/inverse;
    double cx=from.x+width/(2*from.scale),cy=from.y+height/(2*from.scale);
    double tx=to.x+width/(2*to.scale),ty=to.y+height/(2*to.scale);
    HWMPlaneCamera mixed={cx+(tx-cx)*mix-width/(2*scale),
                           cy+(ty-cy)*mix-height/(2*scale),scale};
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

static inline double hwm_plane_overlap_area(HWMPlaneRect a,HWMPlaneRect b)
{
    return fmax(0,fmin(a.x+a.width,b.x+b.width)-fmax(a.x,b.x))*
           fmax(0,fmin(a.y+a.height,b.y+b.height)-fmax(a.y,b.y));
}
static inline bool hwm_plane_snap_candidate_clear(HWMPlaneRect moving,HWMPlanePoint point,
                                                  const HWMPlaneRect *neighbors,size_t count,size_t anchor)
{
    HWMPlaneRect candidate={point.x,point.y,moving.width,moving.height};
    for(size_t i=0;i<count;i++) {
        if(!hwm_plane_rect_valid(neighbors[i])) continue;
        /* Windows already stacked with the chosen neighbor are not separate
         * docking obstacles. Otherwise approaching that neighbor from outside
         * would require overshooting its edge before the magnet could engage. */
        if(i!=anchor && hwm_plane_rects_overlap(neighbors[i],neighbors[anchor])) continue;
        /* An existing overlap must not disable docking that reduces it.
         * Reject new or deeper overlap; do not move unrelated windows. */
        double before=hwm_plane_overlap_area(moving,neighbors[i]);
        double after=hwm_plane_overlap_area(candidate,neighbors[i]);
        if(after>before+1e-8) return false;
    }
    return true;
}

typedef struct {
    HWMPlanePoint point;
    size_t neighbor;
    int axis,side;
    /* The primary neighbor remains available to the existing preview seam.
     * contact_count reports edges whose final perpendicular spans overlap. */
    size_t contact_count;
} HWMPlaneSnapTarget;

static inline bool hwm_plane_snap_coordinate_equal(double a,double b,double extent,double range)
{
    /* Target coordinates normally share arithmetic and compare exactly. This
     * only absorbs floating-point accumulation: it is bounded by the smaller
     * span/range, never grows with world position into a docking distance. */
    double smallest=fmin(fmax(extent,1e-6),fmax(range,1e-6));
    double numeric=16*DBL_EPSILON*fmax(1,fmax(fabs(a),fabs(b)));
    double geometric=fmin(1e-5,smallest*1e-6);
    double tolerance=fmin(smallest*.001,fmax(numeric,geometric));
    return fabs(a-b)<=tolerance;
}

/* Is this edge eligible from the raw held point, and where would it land?
 * Keeping this predicate tied to the held point preserves the old "near a
 * compatible span" contract while later candidates may satisfy two axes. */
static inline bool hwm_plane_snap_edge_target(HWMPlaneRect moving,HWMPlaneRect other,
                                              int axis,int side,double gap,double range,double *coordinate)
{
    if(!hwm_plane_rect_valid(other) || !coordinate || (axis!=0 && axis!=1) || (side!=0 && side!=1)) return false;
    bool perpendicular_overlap=axis==0
        ? moving.y+moving.height>=other.y-range && moving.y<=other.y+other.height+range
        : moving.x+moving.width>=other.x-range && moving.x<=other.x+other.width+range;
    if(!perpendicular_overlap) return false;
    double target=axis==0
        ? (side==0 ? other.x-moving.width-gap : other.x+other.width+gap)
        : (side==0 ? other.y-moving.height-gap : other.y+other.height+gap);
    double from=axis==0 ? moving.x : moving.y;
    if(!isfinite(target) || fabs(target-from)>range) return false;
    *coordinate=target;
    return true;
}

/* An anchor retains the established near-span magnet behavior. A contact,
 * below, is stricter and may be counted with other independent contacts. */
static inline bool hwm_plane_snap_anchor_matches(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                                 size_t count,size_t index,double gap,double range,
                                                 HWMPlanePoint point,int axis,int side)
{
    if(index>=count) return false;
    double target=0;
    if(!hwm_plane_snap_edge_target(moving,neighbors[index],axis,side,gap,range,&target)) return false;
    double extent=axis==0 ? moving.width : moving.height;
    return hwm_plane_snap_coordinate_equal(axis==0 ? point.x : point.y,target,extent,range);
}

static inline bool hwm_plane_snap_contact_matches(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                                  size_t count,size_t index,double gap,double range,
                                                  HWMPlanePoint point,int axis,int side)
{
    if(!hwm_plane_snap_anchor_matches(moving,neighbors,count,index,gap,range,point,axis,side)) return false;
    HWMPlaneRect other=neighbors[index];
    return axis==0 ? point.y<other.y+other.height && point.y+moving.height>other.y
                   : point.x<other.x+other.width && point.x+moving.width>other.x;
}

static inline size_t hwm_plane_snap_contact_count(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                                  size_t count,double gap,double range,HWMPlanePoint point)
{
    size_t contacts=0;
    for(size_t i=0;i<count;i++) for(int axis=0;axis<2;axis++) for(int side=0;side<2;side++)
        contacts+=hwm_plane_snap_contact_matches(moving,neighbors,count,i,gap,range,point,axis,side);
    return contacts;
}

static inline bool hwm_plane_snap_candidate_clear_contacts(HWMPlaneRect moving,HWMPlanePoint point,
                                                           const HWMPlaneRect *neighbors,size_t count,
                                                           double gap,double range)
{
    HWMPlaneRect candidate={point.x,point.y,moving.width,moving.height};
    for(size_t i=0;i<count;i++) {
        if(!hwm_plane_rect_valid(neighbors[i])) continue;
        double before=hwm_plane_overlap_area(moving,neighbors[i]);
        double after=hwm_plane_overlap_area(candidate,neighbors[i]);
        if(after<=before+1e-8) continue;
        /* Retain the existing stacked-peer exception for every chosen
         * contact.  The extra scan only runs for an actual new/deeper
         * collision, avoiding all-pairs work in ordinary proposals. */
        bool stacked=false;
        for(size_t j=0;j<count && !stacked;j++) {
            if(i==j || !hwm_plane_rect_valid(neighbors[j])) continue;
            bool contact=false;
            for(int axis=0;axis<2 && !contact;axis++) for(int side=0;side<2;side++)
                if(hwm_plane_snap_anchor_matches(moving,neighbors,count,j,gap,range,point,axis,side)) { contact=true; break; }
            if(contact && hwm_plane_rects_overlap(neighbors[i],neighbors[j])) stacked=true;
        }
        if(!stacked) return false;
    }
    return true;
}

/* Most planes have only a few eligible edges. A fixed cache removes repeated
 * work when many stacked peers describe the identical landing point, without
 * allocating from the drag hot path. Overflow falls back to full evaluation,
 * so it cannot omit a legitimate target. */
enum { HWM_PLANE_SNAP_CANDIDATE_CACHE = 64 };
typedef struct {
    HWMPlanePoint points[HWM_PLANE_SNAP_CANDIDATE_CACHE];
    size_t count;
} HWMPlaneSnapCandidateCache;

static inline bool hwm_plane_snap_candidate_cache_add(HWMPlaneSnapCandidateCache *cache,HWMPlanePoint point)
{
    for(size_t i=0;i<cache->count;i++)
        if(cache->points[i].x==point.x && cache->points[i].y==point.y) return false;
    if(cache->count<HWM_PLANE_SNAP_CANDIDATE_CACHE) cache->points[cache->count++]=point;
    return true;
}

static inline void hwm_plane_snap_consider(HWMPlaneRect moving,const HWMPlaneRect *neighbors,size_t count,
                                           double gap,double range,const HWMPlaneSnapTarget *preferred,
                                           HWMPlanePoint candidate,HWMPlaneSnapTarget *best,double *cost,
                                           bool *best_preferred,HWMPlaneSnapCandidateCache *cache)
{
    /* Each axis is its own magnet: a corner engages whenever both edges are
     * individually in range, not only inside a diagonal circle. */
    if(!isfinite(candidate.x) || !isfinite(candidate.y) ||
       fmax(fabs(candidate.x-moving.x),fabs(candidate.y-moving.y))>range ||
       !hwm_plane_snap_candidate_cache_add(cache,candidate) ||
       !hwm_plane_snap_candidate_clear_contacts(moving,candidate,neighbors,count,gap,range)) return;
    size_t contacts=hwm_plane_snap_contact_count(moving,neighbors,count,gap,range,candidate);
    bool has_preferred=false,have_primary=false;
    size_t primary=0; int primary_axis=0,primary_side=0;
    for(size_t i=0;i<count;i++) for(int axis=0;axis<2;axis++) for(int side=0;side<2;side++) {
        if(!hwm_plane_snap_anchor_matches(moving,neighbors,count,i,gap,range,candidate,axis,side)) continue;
        bool match=preferred && preferred->neighbor==i && preferred->axis==axis && preferred->side==side;
        if(match || (!has_preferred && (!have_primary || axis<primary_axis ||
           (axis==primary_axis && (side<primary_side || (side==primary_side && i<primary)))))) {
            primary=i; primary_axis=axis; primary_side=side; have_primary=true;
        }
        has_preferred|=match;
    }
    if(!have_primary) return;
    double distance=hypot(candidate.x-moving.x,candidate.y-moving.y);
    HWMPlaneSnapTarget choice={candidate,primary,primary_axis,primary_side,contacts};
    if(contacts>best->contact_count || (contacts==best->contact_count &&
       (has_preferred>*best_preferred || (has_preferred==*best_preferred &&
       (distance<*cost || (distance==*cost && (candidate.x<best->point.x ||
       (candidate.x==best->point.x && candidate.y<best->point.y)))))))) {
        *best=choice; *cost=distance; *best_preferred=has_preferred;
    }
}

/* World-space geometry with a radial movement bound. Prefer the engaged edge
 * while it remains valid, so crossing a near-tie cannot flicker the preview. */
static inline bool hwm_plane_snap_choose(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                        size_t count,double gap,double range,
                                        const HWMPlaneSnapTarget *preferred,HWMPlaneSnapTarget *out)
{
    if(!out || !hwm_plane_rect_valid(moving) || (!neighbors && count) ||
       !isfinite(gap) || gap<0 || !isfinite(range) || range<0) return false;
    HWMPlaneSnapTarget best={{moving.x,moving.y},0,0,0,0};
    double cost=INFINITY;
    bool best_preferred=false;
    HWMPlaneSnapCandidateCache candidates={0};
    /* Candidates are edge coordinates, never triples: one X and one Y edge
     * express a corner, a two-sided fit, or a natural four-contact landing.
     * Edges outside the small radial range never enter the paired scan. */
    for(size_t xi=0;xi<count;xi++) for(int xs=0;xs<2;xs++) {
        double x=0;
        if(!hwm_plane_snap_edge_target(moving,neighbors[xi],0,xs,gap,range,&x)) continue;
        double a=neighbors[xi].y-moving.y;
        double b=neighbors[xi].y+neighbors[xi].height-moving.height-moving.y;
        double align=fabs(a)<=fabs(b) ? a : b;
        HWMPlanePoint aligned={x,moving.y+align};
        HWMPlanePoint raw={x,moving.y};
        bool aligned_in_range=fmax(fabs(aligned.x-moving.x),fabs(aligned.y-moving.y))<=range;
        bool aligned_clear=aligned_in_range && hwm_plane_snap_candidate_clear_contacts(moving,aligned,neighbors,count,gap,range);
        /* The historic single-edge target aligned the perpendicular edge when
         * possible. Keep that landing unless raw X holds more contacts. */
        if(!aligned_clear || hwm_plane_snap_contact_count(moving,neighbors,count,gap,range,raw)>
                             hwm_plane_snap_contact_count(moving,neighbors,count,gap,range,aligned))
            hwm_plane_snap_consider(moving,neighbors,count,gap,range,preferred,raw,&best,&cost,&best_preferred,&candidates);
        hwm_plane_snap_consider(moving,neighbors,count,gap,range,preferred,aligned,&best,&cost,&best_preferred,&candidates);
        for(size_t yi=0;yi<count;yi++) if(yi!=xi) for(int ys=0;ys<2;ys++) {
            double y=0;
            if(hwm_plane_snap_edge_target(moving,neighbors[yi],1,ys,gap,range,&y))
                hwm_plane_snap_consider(moving,neighbors,count,gap,range,preferred,(HWMPlanePoint){x,y},&best,&cost,&best_preferred,&candidates);
        }
    }
    /* A y-only proposal is still needed when no horizontal edge is near. */
    for(size_t yi=0;yi<count;yi++) for(int ys=0;ys<2;ys++) {
        double y=0;
        if(!hwm_plane_snap_edge_target(moving,neighbors[yi],1,ys,gap,range,&y)) continue;
        double a=neighbors[yi].x-moving.x;
        double b=neighbors[yi].x+neighbors[yi].width-moving.width-moving.x;
        double align=fabs(a)<=fabs(b) ? a : b;
        HWMPlanePoint aligned={moving.x+align,y};
        HWMPlanePoint raw={moving.x,y};
        bool aligned_in_range=fmax(fabs(aligned.x-moving.x),fabs(aligned.y-moving.y))<=range;
        bool aligned_clear=aligned_in_range && hwm_plane_snap_candidate_clear_contacts(moving,aligned,neighbors,count,gap,range);
        if(!aligned_clear || hwm_plane_snap_contact_count(moving,neighbors,count,gap,range,raw)>
                             hwm_plane_snap_contact_count(moving,neighbors,count,gap,range,aligned))
            hwm_plane_snap_consider(moving,neighbors,count,gap,range,preferred,raw,&best,&cost,&best_preferred,&candidates);
        hwm_plane_snap_consider(moving,neighbors,count,gap,range,preferred,aligned,&best,&cost,&best_preferred,&candidates);
    }
    if(!isfinite(cost)) return false;
    *out=best; return true;
}
/* Release hysteresis. An engaged target keeps each axis it moved until the
 * raw proposal travels `release` from it; engaging still needs `range`, so a
 * pointer resting near the boundary cannot chatter on and off. Only edges that
 * still touch hold: a perpendicular alignment alone never keeps a magnet. */
static inline bool hwm_plane_snap_hold(HWMPlaneRect moving,const HWMPlaneRect *neighbors,size_t count,
                                       double gap,double release,const HWMPlaneSnapTarget *held,
                                       bool lock_x,bool lock_y,HWMPlaneSnapTarget *out)
{
    if(!out || !held || !hwm_plane_rect_valid(moving) || (!neighbors && count) ||
       !isfinite(gap) || gap<0 || !isfinite(release) || release<0) return false;
    HWMPlanePoint point={lock_x && fabs(held->point.x-moving.x)<=release ? held->point.x : moving.x,
                         lock_y && fabs(held->point.y-moving.y)<=release ? held->point.y : moving.y};
    if(point.x==moving.x && point.y==moving.y) return false;
    HWMPlaneSnapTarget best={{moving.x,moving.y},0,0,0,0};
    double cost=INFINITY; bool best_preferred=false;
    HWMPlaneSnapCandidateCache candidates={0};
    hwm_plane_snap_consider(moving,neighbors,count,gap,release,held,point,&best,&cost,&best_preferred,&candidates);
    if(!isfinite(cost)) return false;
    *out=best; return true;
}

/* A fresh target wins only by adding contacts (sliding into a corner);
 * otherwise the held one stays. `kept` reports which bound applies. */
static inline bool hwm_plane_snap_choose_held(HWMPlaneRect moving,const HWMPlaneRect *neighbors,size_t count,
                                              double gap,double range,double release,
                                              const HWMPlaneSnapTarget *held,bool lock_x,bool lock_y,
                                              HWMPlaneSnapTarget *out,bool *kept)
{
    if(kept) *kept=false;
    HWMPlaneSnapTarget fresh,hold;
    bool have_fresh=hwm_plane_snap_choose(moving,neighbors,count,gap,range,held,&fresh);
    bool have_hold=held && release>range &&
        hwm_plane_snap_hold(moving,neighbors,count,gap,release,held,lock_x,lock_y,&hold);
    if(have_hold && (!have_fresh || fresh.contact_count<=hold.contact_count)) {
        if(out) *out=hold;
        if(kept) *kept=true;
        return true;
    }
    if(have_fresh && out) *out=fresh;
    return have_fresh;
}

/* The touching span of every docked edge, relative to the landing origin.
 * edge follows HWMPlaneSnapTarget: axis*2+side. Overlapping spans on one edge
 * (stacked neighbors) merge, so feedback draws one seam per real contact. */
typedef struct { int edge; double from,to; } HWMPlaneSnapSeam;
enum { HWM_PLANE_SNAP_SEAMS = 8 };
static inline size_t hwm_plane_snap_seams(HWMPlaneRect moving,const HWMPlaneRect *neighbors,size_t count,
                                          double gap,double range,HWMPlanePoint point,
                                          HWMPlaneSnapSeam *out,size_t capacity)
{
    size_t n=0;
    if(!out || !capacity || !hwm_plane_rect_valid(moving)) return 0;
    for(size_t i=0;i<count;i++) for(int axis=0;axis<2;axis++) for(int side=0;side<2;side++) {
        if(!hwm_plane_snap_contact_matches(moving,neighbors,count,i,gap,range,point,axis,side)) continue;
        HWMPlaneRect other=neighbors[i];
        HWMPlaneSnapSeam seam={axis*2+side,
            axis==0 ? fmax(point.y,other.y)-point.y : fmax(point.x,other.x)-point.x,
            axis==0 ? fmin(point.y+moving.height,other.y+other.height)-point.y
                    : fmin(point.x+moving.width,other.x+other.width)-point.x};
        if(!(seam.to>seam.from)) continue;
        for(size_t j=0;j<n;) {
            if(out[j].edge==seam.edge && out[j].from<=seam.to && seam.from<=out[j].to) {
                seam.from=fmin(seam.from,out[j].from); seam.to=fmax(seam.to,out[j].to);
                out[j]=out[--n]; j=0; // A wider span can now reach an earlier one.
            } else ++j;
        }
        if(n<capacity) out[n++]=seam;
    }
    return n;
}

static inline bool hwm_plane_snap_neighbors_target(HWMPlaneRect moving,const HWMPlaneRect *neighbors,
                                                   size_t count,double gap,double range,HWMPlanePoint *out)
{
    if(!out) return false;
    if(hwm_plane_rect_valid(moving)) *out=(HWMPlanePoint){moving.x,moving.y};
    HWMPlaneSnapTarget target;
    if(!hwm_plane_snap_choose(moving,neighbors,count,gap,range,NULL,&target)) return false;
    *out=target.point; return true;
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

/* Hover focus has no dwell. Centering is separate: the window must already be
 * near the viewport center, and several pointer samples must approach its
 * interior. Merely crossing an edge or parking the cursor never recenters. */
typedef struct {
    uint32_t window;
    HWMPlanePoint previous;
    double began,approach;
    bool centered;
} HWMPlaneHoverIntent;
static inline bool hwm_plane_hover_intent(HWMPlaneHoverIntent *s,uint32_t window,HWMPlanePoint point,
                                          HWMPlaneRect frame,HWMPlaneRect viewport,double now)
{
    if(!s)return false;
    if(!window || !hwm_plane_rect_valid(frame) || !hwm_plane_rect_valid(viewport) || !isfinite(now)) { *s=(HWMPlaneHoverIntent){0};return false; }
    if(s->window!=window) { *s=(HWMPlaneHoverIntent){.window=window,.previous=point,.began=now};return false; }
    HWMPlanePoint previous=s->previous;s->previous=point;
    double cx=frame.x+frame.width*.5,cy=frame.y+frame.height*.5;
    double near=hypot(cx-viewport.x-viewport.width*.5,cy-viewport.y-viewport.height*.5);
    double dx=point.x-previous.x,dy=point.y-previous.y,step=hypot(dx,dy);
    if(s->centered || near<2 || near>fmin(viewport.width,viewport.height)*.2 || step>80) { s->approach=0;return false; }
    double distance=hypot(cx-previous.x,cy-previous.y);
    if(distance>1) s->approach=fmax(0,s->approach+(dx*(cx-previous.x)+dy*(cy-previous.y))/distance);
    bool interior=point.x>frame.x+frame.width*.12 && point.x<frame.x+frame.width*.88 &&
                  point.y>frame.y+frame.height*.12 && point.y<frame.y+frame.height*.88;
    if(!interior || now-s->began<.09 || s->approach<18)return false;
    s->centered=true;return true;
}

/* Seconds for a camera transition. Short hops (auto-centering, a nearby
 * window) settle quickly; long travel and large zoom changes get a little
 * more time so the eye can follow. Distances are in display points. */
static inline double hwm_plane_camera_duration(HWMPlaneCamera from,HWMPlaneCamera to,double width,double height)
{
    if(!hwm_plane_camera_valid(from) || !hwm_plane_camera_valid(to) ||
       !isfinite(width) || !isfinite(height) || width<=0 || height<=0) return .36;
    double scale=fmin(from.scale,to.scale);
    double cx=(from.x+width/(2*from.scale))-(to.x+width/(2*to.scale));
    double cy=(from.y+height/(2*from.scale))-(to.y+height/(2*to.scale));
    double travel=hypot(cx,cy)*scale/fmax(1,hypot(width,height));
    double zoom=fabs(log2(to.scale/from.scale));
    return fmin(.42,.22+.12*fmin(1,travel)+.05*fmin(2,zoom));
}

/* Camera motion: x and y in plane units per second, zoom in natural-log
 * scale per second. */
typedef struct { double x, y, zoom; } HWMPlaneCameraVelocity;

/* Camera transition progress. A transition that interrupts a moving camera
 * starts at `launch` progress per second instead of from rest, so retargeting
 * mid-flight bends the path rather than stopping dead and restarting. The
 * caller keeps launch below omega, which keeps progress monotonic and never
 * past 1. *rate (optional) receives progress per second. */
static inline double hwm_plane_camera_progress(double elapsed,double duration,double launch,double *rate)
{
    double unused;
    if(!rate) rate=&unused;
    *rate=0;
    double v=isfinite(launch) && launch>0 ? launch : 0;
    if(!isfinite(elapsed) || elapsed<=0) { *rate=v; return 0; }
    if(!isfinite(duration) || elapsed>=duration) return 1;
    double p=hstrip_spring(0,1,v,elapsed,hstrip_spring_omega(duration,1),rate);
    return fmin(1,fmax(0,p));
}

/* Velocity of a transition camera at `progress`, moving at `rate`. */
static inline HWMPlaneCameraVelocity hwm_plane_camera_velocity(HWMPlaneCamera from,HWMPlaneCamera to,
                                                              double width,double height,double progress,double rate)
{
    HWMPlaneCameraVelocity none={0,0,0};
    if(!isfinite(rate) || rate==0 || !isfinite(progress) || progress<0 || progress>=1) return none;
    double step=progress<.999 ? 1e-4 : -1e-4;
    HWMPlaneCamera a=hwm_plane_camera_mix(from,to,width,height,progress),b=hwm_plane_camera_mix(from,to,width,height,progress+step);
    if(!hwm_plane_camera_valid(a) || !hwm_plane_camera_valid(b)) return none;
    HWMPlaneCameraVelocity v={(b.x-a.x)/step*rate,(b.y-a.y)/step*rate,(log(b.scale)-log(a.scale))/step*rate};
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.zoom) ? v : none;
}

/* Initial progress rate for a new transition that continues `velocity`.
 * The motion is projected onto the new path's starting direction measured
 * on screen (points for translation, half the diagonal per e-fold of zoom),
 * so only the part heading the new way is kept. Motion away from the new
 * target starts from rest. Capped at 0.8 omega: no overshoot. */
static inline double hwm_plane_camera_launch(HWMPlaneCamera from,HWMPlaneCamera to,double width,double height,
                                             HWMPlaneCameraVelocity velocity,double duration)
{
    if(!hwm_plane_camera_valid(from) || !hwm_plane_camera_valid(to) || !isfinite(width) || !isfinite(height) ||
       width<=0 || height<=0 || !isfinite(duration) || duration<=0 ||
       !isfinite(velocity.x) || !isfinite(velocity.y) || !isfinite(velocity.zoom)) return 0;
    const double step=1e-4;
    HWMPlaneCamera next=hwm_plane_camera_mix(from,to,width,height,step);
    double zoom_weight=hypot(width,height)*.5;
    double dx=(next.x-from.x)/step*from.scale,dy=(next.y-from.y)/step*from.scale;
    double dz=(log(next.scale)-log(from.scale))/step*zoom_weight;
    double length=dx*dx+dy*dy+dz*dz;
    if(!isfinite(length) || length<1) return 0;
    double along=(velocity.x*from.scale*dx+velocity.y*from.scale*dy+velocity.zoom*zoom_weight*dz)/length;
    if(!isfinite(along) || along<=0) return 0;
    return fmin(along,.8*hstrip_spring_omega(duration,1));
}

/* Camera that centers a plane rectangle at 100%: centered horizontally and
 * vertically when it fits, top-aligned when taller than the viewport. A
 * rectangle wider than the viewport has no single centered view. */
static inline bool hwm_plane_center_camera(HWMPlaneRect window,double width,double height,HWMPlanePoint *out)
{
    if(!out || !hwm_plane_rect_valid(window) || !isfinite(width) || !isfinite(height) ||
       width<=0 || height<=0 || window.width>width) return false;
    *out=(HWMPlanePoint){round(window.x+(window.width-width)*.5),
                         round(window.y-fmax(0,(height-window.height)*.5))};
    return true;
}

/* Auto-centering at 100%. When a pan ends with some window's centered view
 * within `radius` display points, and the pan moved toward that view, the
 * camera finishes the job. Panning away from a centered window, a touch that
 * barely moved, and windows that are already centered are left alone.
 * Returns the index of the chosen candidate, or -1. */
static inline long hwm_plane_auto_center(HWMPlaneCamera start,HWMPlaneCamera end,
                                         const HWMPlanePoint *targets,size_t count,double radius)
{
    if(!targets || !hwm_plane_camera_valid(start) || !hwm_plane_camera_valid(end) ||
       fabs(end.scale-1)>.001 || !isfinite(radius) || radius<=0) return -1;
    if(hypot(end.x-start.x,end.y-start.y)<6) return -1;
    long best=-1; double nearest=radius;
    for(size_t i=0;i<count;i++) {
        double distance=hypot(targets[i].x-end.x,targets[i].y-end.y);
        if(!isfinite(distance) || distance<.5 || distance>=nearest) continue;
        if(hypot(targets[i].x-start.x,targets[i].y-start.y)<distance+4) continue;
        nearest=distance; best=(long)i;
    }
    return best;
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

/* Pinching to exactly 100% by hand is fiddly, and a camera parked at 96%
 * leaves every window slightly soft with projected input. A pinch that was
 * heading toward actual size and rests at or above the detent finishes the
 * zoom, keeping the plane point under `anchor` (display points from the
 * viewport origin) still. Zooming out never snaps back. */
#define HWM_PLANE_ZOOM_DETENT 0.9
static inline bool hwm_plane_zoom_detent(HWMPlaneCamera camera,HWMPlanePoint anchor,bool zooming_in,HWMPlaneCamera *out)
{
    if(!out || !zooming_in || !hwm_plane_camera_valid(camera) || !isfinite(anchor.x) || !isfinite(anchor.y) ||
       camera.scale>=HWM_PLANE_MAX_SCALE || camera.scale<HWM_PLANE_ZOOM_DETENT) return false;
    double x=camera.x+anchor.x/camera.scale-anchor.x,y=camera.y+anchor.y/camera.scale-anchor.y;
    if(!isfinite(x) || !isfinite(y)) return false;
    // Native frames are placed on whole points at 100%.
    *out=(HWMPlaneCamera){round(x),round(y),HWM_PLANE_MAX_SCALE};
    return true;
}

#endif
