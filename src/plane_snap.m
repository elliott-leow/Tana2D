/* A held window follows the pointer exactly. Only its drop proposal is
 * magnetized; releasing near a neighbor commits that proposal. */
static HWMPlaneRect *hwm_drag_snap_neighbors;
static size_t hwm_drag_snap_capacity;
static bool hwm_drag_snap_target(struct view *view,struct window *moving,CGPoint *point)
{
    if(!view || !moving || !point || !isfinite(hwm_plane_scale) || hwm_plane_scale<=0) return false;
    size_t needed=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) needed+=n->window_count;
    if(needed>hwm_drag_snap_capacity) {
        HWMPlaneRect *next=realloc(hwm_drag_snap_neighbors,needed*sizeof(*next));
        if(!next) return false;
        hwm_drag_snap_neighbors=next; hwm_drag_snap_capacity=needed;
    }
    size_t count=0;
    CGRect bounds=hwm_bounds(view),screen=hwm_screen(view);
    double now=hwm_now(),camera_x=hwm_offset(view,now),camera_y=hwm_plane_camera_y(now);
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==moving || !w->strip_initialized || w->strip_close_ghost || w->strip_close_pending ||
           w->application->is_hidden || window_check_flag(w,WINDOW_MINIMIZE) || hwm_workflow_tab_hidden(w)) continue;
        CGRect visible=CGRectMake(bounds.origin.x+(w->strip_world_x-camera_x)*hwm_plane_scale,
                                  bounds.origin.y+(w->strip_world_y-camera_y)*hwm_plane_scale,
                                  w->strip_width*hwm_plane_scale,w->strip_height*hwm_plane_scale);
        if(!CGRectIntersectsRect(visible,screen)) continue;
        hwm_drag_snap_neighbors[count++]=(HWMPlaneRect){w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height};
    }
    HWMPlanePoint target;
    if(!hwm_plane_snap_neighbors_target((HWMPlaneRect){moving->strip_world_x,moving->strip_world_y,moving->strip_width,moving->strip_height},
        hwm_drag_snap_neighbors,count,fmax(0,view->window_gap),12.0/hwm_plane_scale,&target)) return false;
    /* Bound the actual rounded helper submission too, not only world-space
     * arithmetic. Rounding two axes can otherwise exceed a radial limit. */
    double dx=round(bounds.origin.x+(target.x-camera_x)*hwm_plane_scale)-
              round(bounds.origin.x+(moving->strip_world_x-camera_x)*hwm_plane_scale);
    double dy=round(bounds.origin.y+(target.y-camera_y)*hwm_plane_scale)-
              round(bounds.origin.y+(moving->strip_world_y-camera_y)*hwm_plane_scale);
    if(hypot(dx,dy)>12) return false;
    *point=CGPointMake(target.x,target.y); return true;
}
static void hwm_drag_preview_update(struct view *view,struct window *window)
{
    CGPoint target;
    if(hwm_drag_window!=window->id || !hwm_drag_snap_target(view,window,&target)) { hwm_preview_hide_immediately(); return; }
    CGRect bounds=hwm_bounds(view); double now=hwm_now(),x=hwm_offset(view,now),y=hwm_plane_camera_y(now);
    CGRect shown=CGRectMake(round(bounds.origin.x+(target.x-x)*hwm_plane_scale),
                            round(bounds.origin.y+(target.y-y)*hwm_plane_scale),
                            round(window->strip_width*hwm_plane_scale),round(window->strip_height*hwm_plane_scale));
    // The target is anchored to a neighboring edge, with no lagging spring.
    hwm_preview_show(shown,shown,false);
}
static void hwm_drag_snap_commit(struct view *view,struct window *window);
