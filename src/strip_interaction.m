/* Native edge resizing owns the dragged window until mouse-up. Never animate
 * an AX notification back at the application while its resize loop is active. */
static uint32_t hwm_edge_window, hwm_edge_neighbor;
static unsigned hwm_edge_direction;
static CGRect hwm_edge_origin;
static double hwm_edge_world_x,hwm_edge_world_y;
static bool hwm_edge_changed;

static void horizontal_mouse_down(struct window *w, CGPoint p)
{
    hwm_edge_window=0; hwm_edge_neighbor=0; hwm_edge_changed=false;
    if(!hwm_ready || hwm_paused || hwm_overview_active || !w) return;
    struct view *v=window_manager_find_managed_window(&g_window_manager,w);
    if(!v || v->layout!=VIEW_STRIP || g_mouse_state.current_action==MOUSE_MODE_MOVE) return;
    CGRect f=g_mouse_state.window_frame, hit=w->strip_last_frame;
    if(CGRectIsNull(hit)) hit=f;
    hit.size.width*=hwm_plane_scale; hit.size.height*=hwm_plane_scale;
    unsigned direction=0;
    if(g_mouse_state.current_action==MOUSE_MODE_RESIZE) {
        direction=(p.x<CGRectGetMidX(hit)?HANDLE_LEFT:HANDLE_RIGHT)|(p.y<CGRectGetMidY(hit)?HANDLE_TOP:HANDLE_BOTTOM);
        g_mouse_state.direction=direction;
    }
    else {
        if(fabs(p.x-CGRectGetMinX(hit))<=9) direction|=HANDLE_LEFT;
        if(fabs(p.x-CGRectGetMaxX(hit))<=9) direction|=HANDLE_RIGHT;
        if(fabs(p.y-CGRectGetMinY(hit))<=6) direction|=HANDLE_TOP;
        if(fabs(p.y-CGRectGetMaxY(hit))<=9) direction|=HANDLE_BOTTOM;
    }
    if(!direction) return;
    hwm_edge_window=w->id; hwm_edge_origin=f; hwm_edge_direction=direction;
    hwm_edge_world_x=w->strip_world_x; hwm_edge_world_y=w->strip_world_y;
    v->strip_scrolling=false;
    w->strip_size_pending=false; hwm_hold_focus(); hwm_wake();
}

static bool hwm_edge_update(struct window *w, struct view *v)
{
    if(!w || w->id!=hwm_edge_window) return false;
    CGRect actual=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&actual)!=kCGErrorSuccess || !isfinite(actual.size.width) || actual.size.width<100) return true;
    if(CGSizeEqualToSize(actual.size,hwm_edge_origin.size) && !hwm_edge_changed) {
        // A title-bar drag can begin in the narrow top-edge hit band. Wait for
        // real geometry evidence rather than treating every such click as a resize.
        if(g_mouse_state.current_action!=MOUSE_MODE_RESIZE &&
           hypot(actual.origin.x-hwm_edge_origin.origin.x,actual.origin.y-hwm_edge_origin.origin.y)>3) {
            hwm_edge_window=0; hwm_edge_neighbor=0; hwm_drag_started(w);
            return false;
        }
        return true;
    }
    if(!hwm_edge_changed) { hwm_undo_capture(); hwm_edge_changed=true; }
    w->strip_width=fmax(160,actual.size.width);
    w->strip_height=fmax(100,actual.size.height);
    // Native dimensions are world points, even while zoomed out. Keep the
    // opposite edge fixed instead of interpreting native anchor motion as a
    // screen delta (which applied the zoom conversion twice).
    w->strip_world_x=hwm_edge_world_x+((hwm_edge_direction&HANDLE_LEFT)?hwm_edge_origin.size.width-actual.size.width:0);
    w->strip_world_y=hwm_edge_world_y+((hwm_edge_direction&HANDLE_TOP)?hwm_edge_origin.size.height-actual.size.height:0);
    CGRect bounds=hwm_bounds(v);
    CGRect projected=CGRectMake(bounds.origin.x+(w->strip_world_x-hwm_offset(v,hwm_now()))*hwm_plane_scale,
                                bounds.origin.y+(w->strip_world_y-hwm_plane_camera_y(hwm_now()))*hwm_plane_scale,
                                actual.size.width,actual.size.height);
    w->frame=actual;
    w->strip_last_frame=projected; w->strip_last_offset=v->strip_offset;
    w->strip_last_camera_y=hwm_plane_camera_y(hwm_now());
    w->strip_last_plane_scale=hwm_plane_scale;
    scripting_addition_set_plane_transform(w->id,projected.origin.x,projected.origin.y,hwm_plane_scale);
    w->strip_plane_scaled=true; w->strip_transform_dirty=false;
    w->strip_size_pending=false;
    hwm_layout(v,false);
    return true;
}

static bool hwm_edge_finish(struct window *w,struct view *v)
{
    if(w->id!=hwm_edge_window) return false;
    hwm_edge_update(w,v);
    hwm_edge_window=0; hwm_edge_neighbor=0;
    // Commit the accepted native size without moving other plane windows.
    w->strip_native_resize_pending=true; w->strip_native_resize_until=hwm_now()+.15;
    w->strip_transform_dirty=true;
    hwm_layout(v,false); hwm_hold_focus(); hwm_wake();
    return true;
}
