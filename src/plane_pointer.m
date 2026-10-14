/* Overview pointer ownership lasts from press to release. The ordinary app
 * never receives a half-click; movement is coalesced by the usual drag tick. */
static void hwm_plane_pointer_finish(bool choose)
{
    struct view *view=hwm_view();
    struct window *w=window_manager_find_window(&g_window_manager,hwm_plane_pick_window);
    bool dragged=w && hwm_drag_window==w->id;
    if(dragged) {
        hwm_drag_finishing=true;
        if(view) hwm_drag_submit_plane(view,w,hwm_drag_world_at(view,hwm_drag_point));
        hwm_drag_finishing=false; hwm_drag_move_pending=false; hwm_drag_snap_neighbor=0;
        hwm_drag_window=0;
        scripting_addition_set_shadow(w->id,hwm_drag_shadow);
        scripting_addition_set_layer(w->id,LAYER_BELOW);
        hwm_layout(view,false); hwm_hold_focus(); hwm_wake();
    }
    hwm_plane_pick_window=0;
    if(choose && !dragged && hwm_plane_selecting) hwm_plane_choose_window(view,w);
}
static void hwm_plane_pointer(CGEventType type,CGPoint point)
{
    struct view *view=hwm_view();
    if(!view) { hwm_plane_pointer_finish(false); return; }
    if(type==kCGEventLeftMouseDown) {
        hwm_plane_pointer_finish(false);
        struct window *w=hwm_plane_window_at(view,point);
        hwm_plane_pick_window=w?w->id:0; hwm_plane_pick_origin=point;
        // Freeze the view at the frame being grabbed, including a fit animation.
        hwm_plane_camera_stop(view,hwm_now());
        hwm_plane_set_camera(view,hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),false);
        return;
    }
    struct window *w=window_manager_find_window(&g_window_manager,hwm_plane_pick_window);
    if(!w) return;
    if(type==kCGEventLeftMouseDragged && hwm_plane_selecting) {
        if(!hwm_drag_window && hypot(point.x-hwm_plane_pick_origin.x,point.y-hwm_plane_pick_origin.y)>=5) {
            hwm_drag_cancelled=false;
            hwm_drag_started(w); hwm_drag_pointer_origin=hwm_plane_pick_origin;
        }
        if(hwm_drag_window==w->id) {
            hwm_drag_point=point; hwm_drag_move=hwm_drag_world_at(view,point);
            hwm_drag_move_pending=true; ++hwm_prof_drag_events; hwm_wake();
        }
    }
    if(type==kCGEventLeftMouseUp) { hwm_drag_point=point; hwm_plane_pointer_finish(true); }
}
