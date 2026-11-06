/* This transaction outlives the pointer session while app sizes settle. If an
 * app enforces a larger minimum, restore both released frames
 * rather than leaving an overlapping, half-completed screen split. */
static struct {
    bool active;
    uint32_t moving,peer;
    int side;
    double began;
    HWMPlaneTilePlan plan;
    HWMPlaneRect original_moving,original_peer;
} hwm_tile_split;
static HWMPlaneRect hwm_tile_world_rect(struct window *w)
{
    return (HWMPlaneRect){w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height};
}
static void hwm_tile_assign(struct window *w,HWMPlaneRect r)
{
    w->strip_world_x=r.x; w->strip_world_y=r.y;
    w->strip_width=r.width; w->strip_height=r.height;
    w->strip_full_width=false;
    w->strip_native_move_pending=false; w->strip_native_resize_pending=false;
    w->strip_transform_dirty=true;
}
static bool hwm_tile_commit(struct view *view,struct window *moving,bool *split)
{
    CGPoint landing;
    if(!hwm_tile_commit_target(view,moving,&landing)) return false;
    struct window *peer=window_manager_find_window(&g_window_manager,hwm_tile_offer.peer);
    if(!peer || !view_find_window_node(view,peer->id)) return false;
    *split=hwm_tile_offer.plan.split;
    hwm_tile_split.active=true; hwm_tile_split.moving=moving->id; hwm_tile_split.peer=peer->id;
    hwm_tile_split.began=hwm_now(); hwm_tile_split.side=hwm_tile_offer.side;
    hwm_tile_split.plan=hwm_tile_offer.plan;
    hwm_tile_split.original_moving=hwm_tile_world_rect(moving);
    hwm_tile_split.original_peer=hwm_tile_world_rect(peer);
    (void)hwm_ax_cancel_resize(moving->id); (void)hwm_ax_cancel_resize(peer->id);
    hwm_tile_assign(moving,hwm_tile_offer.plan.moving);
    hwm_tile_assign(peer,hwm_tile_offer.plan.peer);
    return true;
}
static bool hwm_drag_snap_commit(struct view *view,struct window *window)
{
    if(hwm_snap_free) return false;
    CGPoint target; bool split=false;
    if(hwm_tile_offer.armed) {
        if(hwm_tile_commit(view,window,&split)) { ++hwm_snap_commits; hwm_haptic(1); return split; }
        return false; // Never substitute a different operation for a stale preview.
    }
    if((hwm_snap_window==window->id && hwm_snap_contact_count && (target=hwm_snap_point,true)) ||
       hwm_drag_snap_target(view,window,&target)) {
        bool accepted=(target.x==window->strip_world_x && target.y==window->strip_world_y) ||
                      hwm_drag_present_plane(view,window,target,false);
        if(accepted) { ++hwm_snap_commits; hwm_haptic(1); }
    }
    return false;
}
static void hwm_tile_raise_pair(void)
{
    (void)scripting_addition_order_window(hwm_tile_split.peer,1,0);
    (void)scripting_addition_order_window(hwm_tile_split.moving,1,0);
}
static bool hwm_tile_split_tick(struct view *view,double now)
{
    if(!hwm_tile_split.active) return false;
    struct window *m=window_manager_find_window(&g_window_manager,hwm_tile_split.moving);
    struct window *p=window_manager_find_window(&g_window_manager,hwm_tile_split.peer);
    if(!view || !m || !p || !view_find_window_node(view,m->id) || !view_find_window_node(view,p->id) ||
       m->strip_close_pending || p->strip_close_pending ||
       hwm_drag_window==m->id || hwm_drag_window==p->id ||
       hwm_edge_window==m->id || hwm_edge_window==p->id || hwm_paused) {
        hwm_tile_split.active=false; return false;
    }
    HWMPlaneTilePlan plan=hwm_tile_split.plan;
    // A new user placement owns the geometry; never roll it back.
    if(fabs(m->strip_world_x-plan.moving.x)>.5 || fabs(m->strip_world_y-plan.moving.y)>.5 ||
       fabs(p->strip_world_x-plan.peer.x)>.5 || fabs(p->strip_world_y-plan.peer.y)>.5) {
        hwm_tile_split.active=false; return false;
    }
    if(now-hwm_tile_split.began<.65 || m->strip_size_pending || p->strip_size_pending ||
       hwm_resize_busy(m) || hwm_resize_busy(p)) return true;
#ifdef HWM_NATIVE_ZOOM
    if(hwm_zoom_native_busy(m->id) || hwm_zoom_native_busy(p->id)) return true;
#endif
    CGRect a=CGRectNull,b=CGRectNull;
    if(SLSGetWindowBounds(g_connection,m->id,&a)!=kCGErrorSuccess ||
       SLSGetWindowBounds(g_connection,p->id,&b)!=kCGErrorSuccess) {
        if(now-hwm_tile_split.began<2) return true;
        hwm_tile_split.active=false; return false;
    }
    if(!isfinite(a.size.width) || !isfinite(a.size.height) || a.size.width<=0 || a.size.height<=0 ||
       !isfinite(b.size.width) || !isfinite(b.size.height) || b.size.width<=0 || b.size.height<=0) {
        hwm_tile_split.active=false; return false;
    }
    hwm_tile_split.active=false;
    if(a.size.width<=plan.moving.width+1 && a.size.height<=plan.moving.height+1 &&
       b.size.width<=plan.peer.width+1 && b.size.height<=plan.peer.height+1) return false;
    HWMPlaneRect original=hwm_tile_split.original_peer,held=hwm_tile_split.original_moving;
    hwm_tile_assign(p,original); hwm_tile_assign(m,held);
    hwm_layout(view,true);
    hwm_hud(@"These apps cannot fit in equal halves — kept their previous sizes");
    return true;
}
