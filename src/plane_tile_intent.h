#ifndef HWM_PLANE_TILE_INTENT_H
#define HWM_PLANE_TILE_INTENT_H
#include "plane_tile_geometry.h"

typedef struct { bool split; HWMPlaneRect moving,peer; } HWMPlaneTilePlan;

/* Reset when a drag starts or the candidate peer changes. Samples use raw
 * moving geometry and monotonic seconds, including a final button-up sample.
 * Once released, further samples cannot newly arm this tracker. */
typedef struct {
    bool sampled, timing, armed, released, retreated;
    double last_time, last_x, last_y, best_distance, since;
} HWMPlaneTileEvidence;

static inline void hwm_plane_tile_evidence_reset(HWMPlaneTileEvidence *state)
{
    if(state) *state=(HWMPlaneTileEvidence){0};
}

static inline bool hwm_plane_tile_evidence_update(HWMPlaneTileEvidence *state,double now,
                                                  HWMPlaneRect moving,HWMPlaneRect origin,
                                                  HWMPlaneRect peer,double scale,bool button_down)
{
    if(!state) return false;
    if(state->released || !button_down) {
        /* Release can cancel a stale offer, but can never create one. */
        if(state->armed) {
            if(!hwm_plane_rect_valid(moving) || !hwm_plane_rect_valid(peer) ||
               !isfinite(scale) || scale<=0) state->armed=false;
            else {
                double d=hypot(moving.x+moving.width*.5-peer.x-peer.width*.5,
                               moving.y+moving.height*.5-peer.y-peer.height*.5)*scale;
                if(!isfinite(d) || d>state->best_distance+12 ||
                   hwm_plane_tile_overlap(moving,peer,scale)<.25) state->armed=false;
            }
        }
        state->released=true; return state->armed;
    }
    if(!isfinite(now) || !isfinite(scale) || scale<=0 ||
       !hwm_plane_rect_valid(moving) || !hwm_plane_rect_valid(origin) ||
       !hwm_plane_rect_valid(peer) || (state->sampled && now<state->last_time)) {
        hwm_plane_tile_evidence_reset(state);
        return false;
    }
    double px=peer.x+peer.width*.5,py=peer.y+peer.height*.5;
    double distance=hypot(moving.x+moving.width*.5-px,moving.y+moving.height*.5-py)*scale;
    double initial=hypot(origin.x+origin.width*.5-px,origin.y+origin.height*.5-py)*scale;
    double travel=hypot(moving.x-origin.x,moving.y-origin.y)*scale;
    double overlap=hwm_plane_tile_overlap(moving,peer,scale);
    if(!isfinite(distance) || !isfinite(initial) || !isfinite(travel)) {
        hwm_plane_tile_evidence_reset(state); return false;
    }
    bool stacked=initial<=12 && hwm_plane_tile_overlap(origin,peer,scale)>=.8;
    double speed=0;
    if(state->sampled) {
        double dt=now-state->last_time;
        double step=hypot(moving.x-state->last_x,moving.y-state->last_y)*scale;
        speed=dt>0?step/dt:(step>0?INFINITY:0);
    } else state->best_distance=stacked?distance:initial;
    state->sampled=true;
    state->last_time=now; state->last_x=moving.x; state->last_y=moving.y;
    if(state->retreated) {
        if(distance>=state->best_distance-4) return false;
        state->retreated=false;
    }
    if(stacked && !state->timing && !state->armed) state->best_distance=distance;
    if(distance<state->best_distance) state->best_distance=distance;
    /* Allow small jitter, but invalidate a sustained retreat from the closest
     * approach. A fast sweep restarts the settling interval. */
    if(distance>state->best_distance+12) {
        state->armed=false; state->timing=false; state->retreated=true;
        return false;
    }
    if(overlap<.25) {
        state->armed=false; state->timing=false;
        return false;
    }
    if(state->armed) return true;
    bool approaching=initial-distance>=4;
    bool stacked_move=stacked && travel>=32 && overlap>=.6;
    if(travel<18 || overlap<.38 || (!approaching && !stacked_move) || speed>450) {
        state->timing=false;
        return false;
    }
    if(!state->timing) { state->timing=true; state->since=now; }
    if(now-state->since>=(stacked?.20:.15)) state->armed=true;
    return state->armed;
}

/* Horizontal only, with hysteresis around the middle. A vertical approach
 * still produces side-by-side halves; its original x chooses a stable side. */
static inline int hwm_plane_tile_horizontal_side(HWMPlaneRect moving,HWMPlaneRect peer,
                                                HWMPlanePoint origin,int held)
{
    double dx=moving.x+moving.width*.5-peer.x-peer.width*.5;
    double band=peer.width*.1;
    if(held==0 && dx<=band) return 0;
    if(held==1 && dx>=-band) return 1;
    if(fabs(dx)<=band) dx=origin.x+moving.width*.5-peer.x-peer.width*.5;
    return dx<=0?0:1;
}

/* A deliberate overlap always means equal side-by-side halves. At 100% these
 * fill the usable screen. Zoomed out, keep that native screen-sized pair
 * around the target instead of requesting enormous, unreadable app frames. */
static inline bool hwm_plane_tile_plan(HWMPlaneRect moving,HWMPlaneRect peer,
                                       HWMPlaneRect viewport,double scale,int side,double gap,
                                       bool moving_resizable,bool peer_resizable,HWMPlaneTilePlan *out)
{
    if(!out || !hwm_plane_rect_valid(moving) || !hwm_plane_rect_valid(peer) ||
       !hwm_plane_rect_valid(viewport) || !isfinite(scale) || scale<=0 || scale>1 ||
       !isfinite(gap) || gap<0 || side<0 || side>1 || !moving_resizable || !peer_resizable) return false;
    HWMPlaneRect region=viewport;
    if(scale<1) {
        region.width=viewport.width*scale; region.height=viewport.height*scale;
        double cx=peer.x+peer.width*.5,cy=peer.y+peer.height*.5;
        /* Blend the anchoring near 100% so crossing 100% does not switch the
         * proposal from the target to the screen abruptly. */
        double follow=fmin(1,(1-scale)/.1);
        double screen_x=viewport.x+(viewport.width-region.width)*.5;
        double screen_y=viewport.y+(viewport.height-region.height)*.5;
        region.x=round(screen_x+(cx-region.width*.5-screen_x)*follow);
        region.y=round(screen_y+(cy-region.height*.5-screen_y)*follow);
    }
    double left=floor((region.width-gap)/2),right=region.width-gap-left;
    if(left<240 || right<240 || region.height<180) return false;
    HWMPlaneRect a={region.x,region.y,left,region.height};
    HWMPlaneRect b={region.x+left+gap,region.y,right,region.height};
    if(!hwm_plane_rect_valid(a) || !hwm_plane_rect_valid(b)) return false;
    *out=(HWMPlaneTilePlan){true,side==0?a:b,side==0?b:a};
    return true;
}
#endif
