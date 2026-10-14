/* Native edge resizing owns the dragged window until mouse-up. Never animate
 * an AX notification back at the application while its resize loop is active. */
#include "plane_resize_geometry.h"
static uint32_t hwm_edge_window, hwm_edge_neighbor;
static unsigned hwm_edge_direction;
static CGRect hwm_edge_origin;
static double hwm_edge_world_x,hwm_edge_world_y;
static bool hwm_edge_changed,hwm_resize_owned;
static bool hwm_plane_resize_abort_interaction(struct window *window,bool keep_capture_until_up);
static void hwm_drag_release(struct view *view,struct window *window);

static void horizontal_mouse_down(struct window *w, CGPoint p)
{
    /* A physical next press may arrive before the former plane resize's short
     * post-up reconciliation window. Finalize that session before changing the
     * shared edge fields, otherwise its stale pointer delta can target this
     * window on the next display tick. */
    if(hwm_resize_owned) hwm_plane_resize_abort_interaction(NULL,false);
    hwm_edge_window=0; hwm_edge_neighbor=0; hwm_edge_changed=false;
    if(!hwm_ready || hwm_paused || hwm_overview_active || !w) return;
    struct view *v=window_manager_find_managed_window(&g_window_manager,w);
    if(!v || v->layout!=VIEW_STRIP || g_mouse_state.current_action==MOUSE_MODE_MOVE) return;
    if(!window_check_flag(w,WINDOW_RESIZABLE)) return;
    CGRect f=g_mouse_state.window_frame, hit=w->strip_last_frame;
    if(CGRectIsNull(hit)) hit=f;
    double displayed_scale=w->strip_last_plane_scale>0 ? w->strip_last_plane_scale : hwm_plane_scale;
    hit.size.width*=displayed_scale; hit.size.height*=displayed_scale;
    unsigned direction=0;
    if(g_mouse_state.current_action==MOUSE_MODE_RESIZE) {
        direction=(p.x<CGRectGetMidX(hit)?HANDLE_LEFT:HANDLE_RIGHT)|(p.y<CGRectGetMidY(hit)?HANDLE_TOP:HANDLE_BOTTOM);
        g_mouse_state.direction=direction;
    }
    else direction=hwm_plane_resize_hit((HWMPlaneRect){hit.origin.x,hit.origin.y,hit.size.width,hit.size.height},
                                         (HWMPlanePoint){p.x,p.y});
    if(g_mouse_state.current_action==MOUSE_MODE_NONE && displayed_scale>=.70 && (direction&HANDLE_TOP)) return;
    if(!direction) return;
    (void)hwm_ax_cancel_resize(w->id);
    hwm_nav_pending=false; hwm_nav_window=0;
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
    if(!hwm_resize_owned && !hwm_edge_changed && g_mouse_state.current_action==MOUSE_MODE_NONE &&
       fabs(actual.size.width-hwm_edge_origin.size.width)<=2 && fabs(actual.size.height-hwm_edge_origin.size.height)<=2) {
        // A title-bar drag can begin in the narrow top-edge hit band. Wait for
        // real geometry evidence rather than treating every such click as a resize.
        CGRect displayed=CGRectNull;
        bool shown=hwm_plane_displayed_frame(w->id,&displayed);
        if(hypot(actual.origin.x-hwm_edge_origin.origin.x,actual.origin.y-hwm_edge_origin.origin.y)>3 ||
           (shown && hypot(displayed.origin.x-w->strip_last_frame.origin.x,displayed.origin.y-w->strip_last_frame.origin.y)>3)) {
            uint64_t generation=hwm_mouse_pointer_generation;
            CGPoint point;
            if(hwm_mouse_pointer_button==kCGMouseButtonLeft && generation &&
               hwm_pointer_sample_point_for_generation(generation,&point)) {
                hwm_edge_window=0; hwm_edge_neighbor=0;
                hwm_drag_point=point;
                hwm_drag_started(w);
                if(hwm_drag_window==w->id) {
                    hwm_drag_pointer_generation=generation;
                    if(!hwm_pointer_sample_generation_is_active(generation)) hwm_drag_release(v,w);
                }
                return false;
            }
        }
    }
    if(CGSizeEqualToSize(actual.size,hwm_edge_origin.size) && !hwm_edge_changed) {
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
    CGRect projected=CGRectMake(round(bounds.origin.x+(w->strip_world_x-hwm_offset(v,hwm_now()))*hwm_plane_scale),
                                round(bounds.origin.y+(w->strip_world_y-hwm_plane_camera_y(hwm_now()))*hwm_plane_scale),
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
    if(hwm_edge_window!=w->id) return false; // The late frame handed off to native drag.
    hwm_edge_window=0; hwm_edge_neighbor=0;
    // Commit the accepted native size without moving other plane windows.
    w->strip_native_resize_pending=true; w->strip_native_resize_until=hwm_now()+.15;
    w->strip_transform_dirty=true;
    hwm_layout(v,false); hwm_hold_focus(); hwm_wake();
    return true;
}
