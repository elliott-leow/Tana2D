static bool horizontal_drag(CGEventRef event)
{
    struct window *window=g_mouse_state.window;
    struct view *view=window?window_manager_find_managed_window(&g_window_manager,window):NULL;
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    CGPoint point; uint64_t generation;
    if(!hwm_pointer_sample_drag_event(event,&point,&generation)) return true;
    /* Mouse-up can reach the tap before this queued drag.  A nonzero
     * generation came from this event's timestamp, so it is the retained
     * final sample of a real press; the global fence still rejects unknown
     * callbacks and autoscroll remains fenced below. */
    /* The legacy release bit belongs only to the left-button stream. Right
     * modifier drags have their own sampler generation and must not inherit a
     * previous left up. */
    bool released=CGEventGetType(event)==kCGEventLeftMouseDragged && atomic_load(&hwm_drag_release_pending);
    if(hwm_drag_cancelled || (released && !generation)) return true;
    if(released) {
        /* Coalescing after mouse-up may leave this callback behind a later
         * drag of the same press. Commit that press's terminal drag, never a
         * newer global cursor or a later press. */
        (void)hwm_pointer_sample_drag_for_generation(generation,0,&point,NULL);
    }
    /* Do this before starting or moving anything. A newer physical press must
     * not overwrite a held session's owner generation. If a native release is
     * still settling, finish its accepted frame before the new press opens. */
    if(hwm_drag_window && hwm_drag_pointer_generation &&
       hwm_drag_pointer_generation!=generation) {
        /* A different press interrupts a native settle before a trustworthy
         * final presentation sample exists. Preserve it, but do not snap it. */
        if(hwm_drag_native_finishing || hwm_drag_native_recovering) {
            /* This callback is already for the next physical press.  Do not
             * let recovery cleanup erase its freshly installed legacy owner. */
            if(hwm_drag_native_recovering) hwm_drag_native_recovered=false;
            hwm_drag_force_finalize(hwm_view(),false);
        }
        else return true;
    }
    hwm_drag_point=point; ++hwm_prof_drag_events;
    if(hwm_edge_window==window->id) {
        if(g_mouse_state.current_action==MOUSE_MODE_RESIZE) {
            double dx=(point.x-g_mouse_state.down_location.x)/hwm_plane_scale,dy=(point.y-g_mouse_state.down_location.y)/hwm_plane_scale;
            window_manager_resize_window_relative_internal(window,hwm_edge_origin,g_mouse_state.direction,dx,dy,false);
        }
        hwm_edge_update(window,view); return true;
    }
    if(g_mouse_state.current_action==MOUSE_MODE_MOVE) {
        bool opened=!hwm_drag_window;
        hwm_drag_started(window);
        if(opened && hwm_drag_window==window->id) hwm_drag_pointer_generation=generation;
        // The input queue is coalesced; read the latest event point and present now.
        // Waiting for the next display callback would add a frame of latency.
    }
    if(!hwm_drag_window && g_mouse_state.current_action==MOUSE_MODE_NONE) {
        CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,window->id,&actual);
        if(!CGRectIsNull(actual) && hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3 &&
           hypot(actual.origin.x-g_mouse_state.window_frame.origin.x,actual.origin.y-g_mouse_state.window_frame.origin.y)>2) {
            bool opened=!hwm_drag_window;
            hwm_drag_started(window);
            if(opened && hwm_drag_window==window->id) hwm_drag_pointer_generation=generation;
        }
    }
    if(hwm_drag_window==window->id && hwm_drag_native) { hwm_drag_native_sync(view,window); hwm_wake(); return true; }
    if(hwm_drag_window==window->id) {
        hwm_drag_move=hwm_drag_world_at(view,point); hwm_drag_move_pending=false;
        hwm_drag_submit_plane(view,window,hwm_drag_move); hwm_wake();
    }
    return true;
}
#include "plane_drop.m"

static void hwm_drag_autoscroll(struct view *view,double now)
{
    if(hwm_plane_pick_window && !hwm_plane_selecting && !hwm_plane_pick_automatic) { hwm_plane_pointer_finish(false); return; }
    double dt=fmin(.04,fmax(0,now-hwm_drag_tick_time)); hwm_drag_tick_time=now;
    struct window *w=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!w || hwm_drag_cancelled) return;
    /* Event-tap disable does not imply AppKit's native title-bar tracking has
     * released. Poll the physical button before any queued-input fences. */
    if(hwm_drag_native_recovering) {
        (void)hwm_drag_native_tap_disabled_recover(view);
        return;
    }
    if(hwm_drag_native_finishing) { hwm_drag_native_finish_tick(view,w,now); return; }
    /* A nonzero owner has a button-specific sampler record. Validate it before
     * every tick: this stops either button at its own up and lets an active
     * right drag run despite an unrelated previous left release. */
    CGPoint cursor;
    bool sampled=false;
    if(hwm_drag_pointer_generation) {
        sampled=hwm_pointer_sample_active_point_for_generation(hwm_drag_pointer_generation,&cursor);
        if(!sampled) return;
    } else {
        if(atomic_load(&hwm_drag_release_pending)) return;
        sampled=hwm_pointer_sample(&cursor);
    }
    /* AppKit owns the native surface. Edge-pan would move the camera while
     * that surface stays under AppKit's pointer, producing a camera-attached
     * window and a stale transform. */
    if(hwm_drag_native) { hwm_drag_native_sync(view,w); return; }
    // The tap publishes every drag before coalescing. Never poll the cursor
    // cache here: consuming drag events can leave that cache frozen.
    if(sampled && (g_mouse_state.window==w || hwm_plane_pick_window==w->id)) {
        hwm_drag_point=cursor;
        if(hwm_plane_pick_window==w->id || g_mouse_state.current_action==MOUSE_MODE_MOVE || g_mouse_state.current_action==MOUSE_MODE_NONE) {
            CGPoint to=hwm_drag_world_at(view,cursor);
            if(hwm_drag_move_pending || w->strip_transform_dirty || !CGPointEqualToPoint(to,hwm_drag_move)) { hwm_drag_move=to; hwm_drag_move_pending=true; }
        }
    }
    CGRect bounds=hwm_bounds(view);
    HWMPlanePoint velocity=hwm_plane_edge_pan(&hwm_drag_edge_pan,
        (HWMPlaneRect){bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height},
        (HWMPlanePoint){hwm_drag_point.x,hwm_drag_point.y},now,hwm_plane_scale);
    if(velocity.x || velocity.y) {
        hwm_drag_camera_owned=true;
        hwm_plane_set_camera(view,view->strip_offset+velocity.x*dt,hwm_plane_y+velocity.y*dt,false);
        hwm_drag_camera_owned=false;
        hwm_drag_move=hwm_drag_world_at(view,hwm_drag_point); hwm_drag_move_pending=true;
    }
    if(hwm_drag_move_pending) { hwm_drag_move_pending=false; hwm_drag_submit_plane(view,w,hwm_drag_move); }
}
