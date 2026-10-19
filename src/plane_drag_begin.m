#include "plane_presentation.h"
static void hwm_drag_snap_reset(void);
static void hwm_snap_ease_reset(void);
/* Set only from the event that opened a normal titlebar/controller drag.
 * A queued callback is then matched to that original press, not whichever
 * button happened most recently at the event tap. */
static uint64_t hwm_drag_pointer_generation;
static bool hwm_drag_native_recovered;
static bool hwm_drag_native_projected;
static bool hwm_drag_native_unscaled;
static bool hwm_drag_committed;
static int hwm_drag_restore_layer;
static CGRect hwm_drag_native_displayed;
static void hwm_drag_commit_interaction(struct window *window)
{
    if(hwm_drag_committed) return;
    hwm_drag_committed=true;
    hwm_undo_capture();
    bool resizing=window->strip_size_pending || hwm_resize_busy(window);
    (void)hwm_ax_cancel_resize(window->id);
    if(resizing) {
        CGRect native=CGRectNull;
        if(SLSGetWindowBounds(g_connection,window->id,&native)==kCGErrorSuccess &&
           native.size.width>0 && native.size.height>0) {
            window->frame=native;
            window->strip_width=window->strip_from_width=native.size.width;
            window->strip_height=window->strip_from_height=native.size.height;
        }
        window->strip_size_pending=false;
    }
    scripting_addition_set_shadow(window->id,true);
    scripting_addition_set_layer(window->id,LAYER_NORMAL);
}
static void hwm_drag_started(struct window *window)
{
    if(hwm_drag_window) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!view) return;
    // Sample and freeze all camera springs at the displayed frame before grab.
    double now=hwm_now(),cx=hwm_offset(view,now),cy=hwm_plane_camera_y(now);
    hwm_plane_set_camera(view,cx,cy,false);
    hwm_nav_pending=false; hwm_nav_window=0; hwm_settle_pending=false;
    hwm_last_input=now; hwm_hold_focus();
    hwm_drag_committed=false;
    hwm_drag_shadow=window_check_flag(window,WINDOW_SHADOW);
    hwm_drag_restore_layer=window->layer==LAYER_AUTO ? LAYER_BELOW : window->layer;
    hwm_drag_native_moved=false;
    hwm_drag_native_recovered=false;
    hwm_drag_native_projected=false;
    hwm_drag_snap_reset(); hwm_snap_ease_reset();
    /* Assigned by the controller that owns a concrete queued drag event.
     * Other entry points leave this at zero rather than consulting the newest
     * global press, which could belong to a later physical click. */
    hwm_drag_pointer_generation=0;
    hwm_drag_native=g_mouse_state.window==window && g_mouse_state.current_action==MOUSE_MODE_NONE && !hwm_plane_pick_window;
    hwm_drag_native_unscaled=hwm_drag_native && hwm_plane_scale==1 && !window->strip_plane_scaled;
    hwm_drag_window=window->id;
    /* The caller seeded hwm_drag_point from its own queued event/generation.
     * Do not replace it with the event tap's newer global sample here. */
    hwm_drag_pointer_origin=g_mouse_state.window==window ? g_mouse_state.down_location : hwm_drag_point;
    hwm_drag_camera_x=view?hwm_offset(view,hwm_now()):0;
    hwm_drag_camera_y=hwm_plane_camera_y(hwm_now());
    hwm_drag_world_origin=CGPointMake(window->strip_world_x,window->strip_world_y);
    /* This cache stores the last displayed origin and unscaled size. Use it
     * rather than the independent native anchor to keep the grab point stable. */
    CGRect actual=window->strip_last_frame;
    CGRect displayed;
    if(hwm_plane_displayed_frame(window->id,&displayed)) actual=displayed;
    hwm_drag_native_displayed=actual;
    if(view && !CGRectIsNull(actual) && !hwm_drag_native_unscaled) {
        CGRect bounds=hwm_bounds(view);
        hwm_drag_world_origin=CGPointMake((actual.origin.x-bounds.origin.x)/hwm_plane_scale+hwm_drag_camera_x,
                                          (actual.origin.y-bounds.origin.y)/hwm_plane_scale+hwm_drag_camera_y);
    }
    hwm_drag_scale=hwm_plane_scale;
    hwm_drag_tick_time=hwm_now(); hwm_drag_edge_pan=(HWMPlaneEdgePan){0};
    if(!hwm_drag_native) hwm_drag_commit_interaction(window);
}
