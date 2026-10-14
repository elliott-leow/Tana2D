static bool hwm_plane_window_selectable(struct view *view,struct window *w)
{
    return view && w && w->application && view_find_window_node(view,w->id) &&
           !w->strip_close_ghost && !w->strip_offscreen && !hwm_workflow_tab_hidden(w) &&
           !window_check_flag(w,WINDOW_MINIMIZE) && !w->application->is_hidden;
}
static struct window *hwm_plane_window_at(struct view *view,CGPoint point)
{
    if(!view) return NULL;
    struct window *target=window_manager_find_window_at_point(&g_window_manager,point);
    if(!hwm_plane_window_selectable(view,target)) target=NULL;
    // Empty space keeps selection open. Use displayed geometry so a click
    // during the zoom animation selects the surface actually under the pointer.
    for(struct window_node *n=window_node_find_first_leaf(view->root);!target && n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!hwm_plane_window_selectable(view,w)) continue;
        CGRect frame=w->strip_last_frame;
        frame.size.width*=w->strip_last_plane_scale; frame.size.height*=w->strip_last_plane_scale;
        if(CGRectContainsPoint(frame,point)) { target=w; break; }
    }
    return target;
}
static void hwm_plane_choose_window(struct view *view,struct window *target)
{
    if(!hwm_plane_window_selectable(view,target)) return;
    hwm_plane_selecting=false; hwm_hold_focus();
    CGRect bounds=hwm_bounds(view);
    hwm_nav_window=target->id; hwm_nav_time=hwm_now(); hwm_nav_pending=true;
    hwm_last_input=hwm_now(); hwm_preserve_focus_window=target->id; hwm_preserve_focus_until=hwm_now()+1;
    hwm_feedback_focus(NULL,target);
    hwm_plane_transition_to(view,target->strip_world_x+(target->strip_width-bounds.size.width)*.5,
                           target->strip_world_y+(target->strip_height-bounds.size.height)*.5,1,true);
}
static void hwm_plane_choose_at(CGPoint point)
{
    struct view *view=hwm_view();
    if(hwm_plane_selecting) hwm_plane_choose_window(view,hwm_plane_window_at(view,point));
}
/* Settle the camera after a pan without activating a window or posting any
 * input. Empty canvas stays where the user left it. */
static void hwm_plane_magnet_at(struct view *view,CGPoint point,HWMPlaneCamera start)
{
    if(!view || !hwm_magnetic_centering || hwm_plane_selecting || hwm_drag_window || hwm_edge_window) return;
    struct window *target=window_manager_find_window_at_point(&g_window_manager,point);
    if(!target || !view_find_window_node(view,target->id) || target->strip_offscreen || target->strip_close_ghost) return;
    CGRect bounds=hwm_bounds(view);
    HWMPlaneCamera camera={hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),hwm_plane_scale};
    HWMPlanePoint centered={target->strip_world_x+target->strip_width*.5-bounds.size.width/(2*hwm_plane_scale),
                            target->strip_world_y+target->strip_height*.5-bounds.size.height/(2*hwm_plane_scale)};
    HWMPlaneCamera next=hwm_plane_magnetic_camera(start,camera,centered);
    if(next.x==camera.x && next.y==camera.y) return;
    hwm_hold_focus();
    hwm_plane_transition_to(view,next.x,next.y,next.scale,true);
}
