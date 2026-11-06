#include "plane_tile_intent.h"
/* A substantial overlap offers a landing after a short deliberate pause.
 * Passing across another window never rearranges either application. */
static struct {
    uint32_t moving,peer;
    int side;
    HWMPlaneTileEvidence evidence;
    bool armed;
    HWMPlaneTilePlan plan;
} hwm_tile_offer;
static const char *hwm_tile_reason="idle";
static void hwm_tile_reset(void) { memset(&hwm_tile_offer,0,sizeof(hwm_tile_offer)); }
static bool hwm_tile_candidate(struct view *view,struct window *moving,CGPoint raw,
                               uint32_t *peer_id,int *side,HWMPlaneTilePlan *plan)
{
    if(!view || !moving || hwm_snap_free) { hwm_tile_reason="bypassed"; return false; }
    HWMPlaneRect a={raw.x,raw.y,moving->strip_width,moving->strip_height};
    double best=0; bool ambiguous=false;
    struct window *peer=NULL;
    CGRect screen=hwm_screen(view),bounds=hwm_bounds(view);
    double now=hwm_now(),cx=hwm_offset(view,now),cy=hwm_plane_camera_y(now);
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==moving || !w->strip_initialized || w->strip_close_ghost || w->strip_close_pending ||
           w->application->is_hidden || window_check_flag(w,WINDOW_MINIMIZE) || hwm_workflow_tab_hidden(w)) continue;
        CGRect shown=CGRectMake(bounds.origin.x+(w->strip_world_x-cx)*hwm_plane_scale,
            bounds.origin.y+(w->strip_world_y-cy)*hwm_plane_scale,w->strip_width*hwm_plane_scale,w->strip_height*hwm_plane_scale);
        if(!CGRectIntersectsRect(screen,shown)) continue;
        double overlap=hwm_plane_tile_overlap(a,(HWMPlaneRect){w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height},hwm_plane_scale);
        if(overlap<.25) continue; // Candidate selection only; the trajectory decides intent.
        if(overlap>best+.03) { best=overlap; peer=w; ambiguous=false; }
        else if(fabs(overlap-best)<=.03) ambiguous=true;
    }
    if(!peer || ambiguous) { hwm_tile_reason=ambiguous?"ambiguous-target":"no-overlap"; return false; }
    HWMPlaneRect b={peer->strip_world_x,peer->strip_world_y,peer->strip_width,peer->strip_height};
    int held=hwm_tile_offer.moving==moving->id && hwm_tile_offer.peer==peer->id ? hwm_tile_offer.side : -1;
    int edge=hwm_plane_tile_horizontal_side(a,b,(HWMPlanePoint){hwm_drag_world_origin.x,hwm_drag_world_origin.y},held);
    HWMPlaneRect viewport={cx,cy,bounds.size.width/hwm_plane_scale,bounds.size.height/hwm_plane_scale};
    if(!hwm_plane_tile_plan(a,b,viewport,hwm_plane_scale,edge,view->window_gap,
        window_check_flag(moving,WINDOW_RESIZABLE),window_check_flag(peer,WINDOW_RESIZABLE),plan)) { hwm_tile_reason="cannot-resize-pair"; return false; }
    /* strip_min_width is a heuristic from past resize reconciliation, not
     * an app-declared limit. It must not veto an explicit split; accepted
     * native sizes are checked by the split transaction after release. */
    HWMPlanePoint p={plan->moving.x,plan->moving.y};
    CGRect shown=CGRectMake(bounds.origin.x+(p.x-cx)*hwm_plane_scale,bounds.origin.y+(p.y-cy)*hwm_plane_scale,
        plan->moving.width*hwm_plane_scale,plan->moving.height*hwm_plane_scale);
    CGRect visible=CGRectIntersection(shown,screen);
    if(CGRectIsNull(visible) || visible.size.width*visible.size.height<shown.size.width*shown.size.height*.6) { hwm_tile_reason="landing-offscreen"; return false; }
    /* Other apps keep their geometry. Like ordinary foreground windows,
     * the accepted pair may cover background windows; they do not block a
     * clearly previewed split. */
    *peer_id=peer->id; *side=edge; return true;
}
static bool hwm_tile_preview(struct view *view,struct window *window,CGPoint raw)
{
    uint32_t peer; int side; HWMPlaneTilePlan plan;
    if(hwm_drag_window!=window->id || !hwm_tile_candidate(view,window,raw,&peer,&side,&plan)) {
        hwm_tile_reset(); return false;
    }
    if(hwm_tile_offer.moving!=window->id || hwm_tile_offer.peer!=peer) {
        hwm_tile_reset(); hwm_tile_offer.moving=window->id; hwm_tile_offer.peer=peer;
    }
    // Changing halves must not erase a detected pass-through retreat.
    hwm_tile_offer.side=side;
    double now=hwm_now();
    HWMPlaneRect moving={raw.x,raw.y,window->strip_width,window->strip_height};
    HWMPlaneRect origin={hwm_drag_world_origin.x,hwm_drag_world_origin.y,window->strip_width,window->strip_height};
    struct window *other_window=window_manager_find_window(&g_window_manager,peer);
    HWMPlaneRect other_rect={other_window->strip_world_x,other_window->strip_world_y,other_window->strip_width,other_window->strip_height};
    bool down=!hwm_drag_native_finishing && (hwm_drag_pointer_generation ?
        hwm_pointer_sample_generation_is_active(hwm_drag_pointer_generation) : !atomic_load(&hwm_drag_release_pending));
    bool was_armed=hwm_tile_offer.armed;
    hwm_tile_offer.armed=hwm_plane_tile_evidence_update(&hwm_tile_offer.evidence,now,moving,origin,other_rect,hwm_plane_scale,down);
    if(!hwm_tile_offer.armed) { hwm_tile_reason="waiting-for-drag-intent"; return false; }
    hwm_tile_offer.plan=plan;
    hwm_tile_reason="offering-halves";
    if(!was_armed) hwm_haptic(0);
    hwm_drag_snap_reset();
    CGRect bounds=hwm_bounds(view);
    CGRect target=CGRectMake(bounds.origin.x+(plan.moving.x-hwm_offset(view,now))*hwm_plane_scale,
        bounds.origin.y+(plan.moving.y-hwm_plane_camera_y(now))*hwm_plane_scale,
        plan.moving.width*hwm_plane_scale,plan.moving.height*hwm_plane_scale);
    CGRect other=CGRectMake(bounds.origin.x+(plan.peer.x-hwm_offset(view,now))*hwm_plane_scale,
        bounds.origin.y+(plan.peer.y-hwm_plane_camera_y(now))*hwm_plane_scale,
        plan.peer.width*hwm_plane_scale,plan.peer.height*hwm_plane_scale);
    hwm_preview_split_show(target,other);
    return true;
}
static bool hwm_tile_commit_target(struct view *view,struct window *window,CGPoint *target)
{
    if(!hwm_tile_offer.armed || hwm_tile_offer.moving!=window->id) return false;
    uint32_t peer; int side; HWMPlaneTilePlan plan;
    if(!hwm_tile_candidate(view,window,CGPointMake(window->strip_world_x,window->strip_world_y),&peer,&side,&plan) ||
       peer!=hwm_tile_offer.peer || side!=hwm_tile_offer.side) return false;
    struct window *peer_window=window_manager_find_window(&g_window_manager,peer);
    HWMPlaneRect raw={window->strip_world_x,window->strip_world_y,window->strip_width,window->strip_height};
    HWMPlaneRect origin={hwm_drag_world_origin.x,hwm_drag_world_origin.y,window->strip_width,window->strip_height};
    HWMPlaneRect peer_rect={peer_window->strip_world_x,peer_window->strip_world_y,peer_window->strip_width,peer_window->strip_height};
    if(!hwm_plane_tile_evidence_update(&hwm_tile_offer.evidence,hwm_now(),raw,origin,peer_rect,hwm_plane_scale,false)) {
        hwm_tile_reason="intent-withdrawn"; return false;
    }
    HWMPlaneRect shown=hwm_tile_offer.plan.moving,other=hwm_tile_offer.plan.peer;
    if(plan.split!=hwm_tile_offer.plan.split ||
       fabs(plan.moving.x-shown.x)>1 || fabs(plan.moving.y-shown.y)>1 ||
       fabs(plan.moving.width-shown.width)>1 || fabs(plan.moving.height-shown.height)>1 ||
       fabs(plan.peer.x-other.x)>1 || fabs(plan.peer.y-other.y)>1 ||
       fabs(plan.peer.width-other.width)>1 || fabs(plan.peer.height-other.height)>1) return false;
    *target=CGPointMake(plan.moving.x,plan.moving.y); return true;
}
