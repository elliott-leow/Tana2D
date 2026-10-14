#include "plane_presentation.h"

static CGPoint hwm_drag_world_at(struct view *view,CGPoint point)
{
    HWMPlanePoint world=hwm_plane_drag_world((HWMPlanePoint){hwm_drag_world_origin.x,hwm_drag_world_origin.y},
                                             (HWMPlanePoint){point.x,point.y},(HWMPlanePoint){hwm_drag_pointer_origin.x,hwm_drag_pointer_origin.y},
                                             hwm_drag_scale,hwm_offset(view,hwm_now())-hwm_drag_camera_x,
                                             hwm_plane_camera_y(hwm_now())-hwm_drag_camera_y);
    return CGPointMake(world.x,world.y);
}
/* Pointer-owned movement has no spring, magnet, layout pass, or display-link
 * gate. The helper presents the native surface and existing outline together. */
static bool hwm_drag_submit_plane(struct view *view,struct window *window,CGPoint world)
{
    if(!view || !window || !isfinite(world.x) || !isfinite(world.y)) return false;
    double began=hwm_now();
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()), camera_y=hwm_plane_camera_y(hwm_now()), scale=hwm_plane_scale;
    CGRect base=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                           round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                           round(hwm_plane_physical_size(window->strip_width)),round(hwm_plane_physical_size(window->strip_height)));
    CGRect projected=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                                round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                                round(hwm_plane_physical_size(window->strip_width*scale)),round(hwm_plane_physical_size(window->strip_height*scale)));
    bool own_batch=!hwm_batch_open;
    if(own_batch) scripting_addition_batch_begin();
    bool ok=scripting_addition_set_plane_transform(window->id,projected.origin.x,projected.origin.y,scale);
    if(ok) ok=hwm_plane_border_drag(window->id,projected);
    if(own_batch) ok=scripting_addition_batch_end() && ok;
    double ms=(hwm_now()-began)*1000;
    ++hwm_drag_present_count; hwm_drag_present_total_ms+=ms;
    if(ms>hwm_drag_present_max_ms) hwm_drag_present_max_ms=ms;
    window->strip_plane_scaled=ok; window->strip_transform_dirty=!ok;
    window->strip_last_plane_scale=scale;
    if(!ok) { hwm_plane_border_drag_failed(); ++hwm_move_failures; hwm_backend_ok=false; return false; }
    window->strip_world_x=world.x; window->strip_world_y=world.y;
    window->strip_from_x=world.x; window->strip_from_y=world.y;
    window->strip_last_frame=base; window->strip_last_offset=camera_x; window->strip_last_camera_y=camera_y; window->strip_last_shift=0;
    window->strip_start=hwm_now()-hwm_duration;
    hwm_drag_preview_update(view,window);
    return true;
}

/* A title-bar drag already belongs to AppKit. Do not intercept its drag
 * events or transform its surface while its native tracking loop is active.
 * Observe the frame that AppKit moved, then move only our outline to it. */
static bool hwm_drag_native_finishing;
static bool hwm_drag_native_recovering;
static double hwm_drag_native_finish_began,hwm_drag_native_finish_deadline;
static CGRect hwm_drag_native_finish_frame;
static unsigned hwm_drag_native_finish_stable;

static bool hwm_drag_native_sync(struct view *view,struct window *window)
{
    CGRect frame=CGRectNull;
    if(!view || SLSGetWindowBounds(g_connection,window->id,&frame)!=kCGErrorSuccess || CGRectIsNull(frame)) return false;
    if(!hwm_drag_native_moved && CGPointEqualToPoint(frame.origin,g_mouse_state.window_frame.origin)) return true;
    CGRect presented=CGRectNull;
    /* Do not recover this from SLSGetWindowTransform: AppKit can retain the
     * old requested plane matrix after it has moved the displayed titlebar
     * surface. Keep the last accepted position and retry on the next tick. */
    if(!hwm_plane_displayed_frame(window->id,&presented)) return false;
    CGPoint displayed=presented.origin;
    if(!isfinite(displayed.x) || !isfinite(displayed.y)) return false;
    hwm_drag_native_moved=true;
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()),camera_y=hwm_plane_camera_y(hwm_now());
    // Native bounds retain an independent anchor when the camera transformed
    // the window. Persist the compositor origin, not that native anchor.
    CGPoint world=CGPointMake((displayed.x-bounds.origin.x)/hwm_plane_scale+camera_x,
                              (displayed.y-bounds.origin.y)/hwm_plane_scale+camera_y);
    window->frame=frame;
    window->strip_world_x=window->strip_from_x=world.x;
    window->strip_world_y=window->strip_from_y=world.y;
    window->strip_width=window->strip_from_width=frame.size.width;
    window->strip_height=window->strip_from_height=frame.size.height;
    window->strip_vel_x=window->strip_vel_y=window->strip_vel_width=window->strip_vel_height=0;
    window->strip_last_frame=frame; window->strip_last_frame.origin=displayed;
    window->strip_last_offset=camera_x; window->strip_last_camera_y=camera_y;
    window->strip_last_plane_scale=hwm_drag_scale; window->strip_plane_scaled=true; window->strip_transform_dirty=false;
    window->strip_start=hwm_now()-hwm_duration;
    hwm_drag_move=world; hwm_drag_move_pending=false;
    hwm_drag_preview_update(view,window);
    CGRect visible=window->strip_last_frame; visible.size.width*=hwm_drag_scale; visible.size.height*=hwm_drag_scale;
    bool own_batch=!hwm_batch_open; if(own_batch) scripting_addition_batch_begin();
    bool ok=hwm_plane_border_drag(window->id,visible);
    if(own_batch) ok=scripting_addition_batch_end() && ok;
    if(!ok) hwm_plane_border_drag_failed();
    return ok;
}

/* The parent supplies the placement policy. It runs once, after the final
 * native sample is accepted, never on forced interruption. */
static void hwm_drag_snap_commit(struct view *view,struct window *window);

static void hwm_drag_complete(struct view *view,struct window *window,bool snap)
{
    if(!window || hwm_drag_window!=window->id) return;
    bool native=hwm_drag_native;
    bool recovered_native=native && hwm_drag_native_recovered;
    hwm_drag_move_pending=false;
    hwm_drag_native_finishing=false;
    hwm_drag_native_recovering=false;
    hwm_drag_native_recovered=false;
    if(native) {
        /* AppKit changed the native anchor while keeping an old compositor
         * matrix. Submit the accepted displayed world point again on the next
         * renderer frame before any camera motion can use that stale matrix. */
        window->strip_transform_dirty=true;
    }
    if(snap) hwm_drag_snap_commit(view,window);
    hwm_drag_window=0; hwm_drag_native=false;
    if(recovered_native && g_mouse_state.window==window) {
        g_mouse_state.window=NULL;
        g_mouse_state.current_action=MOUSE_MODE_NONE;
        g_mouse_state.direction=0;
        hwm_mouse_pointer_generation=0;
        hwm_mouse_pointer_button=-1;
    }
    scripting_addition_set_shadow(window->id,hwm_drag_shadow);
    scripting_addition_set_layer(window->id,LAYER_BELOW);
    if(view) hwm_layout(view,false);
    hwm_drop_target=0; hwm_preview_hide(); hwm_hold_focus(); hwm_wake();
}

/* A title-bar release is not immediately trustworthy: AppKit can publish the
 * terminal move after its mouse-up has reached our serialized event loop.
 * Retain native ownership until two identical presented samples after a short
 * grace period, with a hard 150 ms ceiling. */
static void hwm_drag_native_finish_tick(struct view *view,struct window *window,double now)
{
    if(!hwm_drag_native_finishing || !window || hwm_drag_window!=window->id || !hwm_drag_native) return;
    bool sampled=hwm_drag_native_sync(view,window);
    if(sampled && CGRectEqualToRect(window->strip_last_frame,hwm_drag_native_finish_frame)) ++hwm_drag_native_finish_stable;
    else if(sampled) { hwm_drag_native_finish_frame=window->strip_last_frame; hwm_drag_native_finish_stable=0; }
    if(now>=hwm_drag_native_finish_deadline ||
       (now-hwm_drag_native_finish_began>=.05 && sampled && hwm_drag_native_finish_stable>=2)) {
        /* A deadline keeps ownership bounded, but it is not evidence that
         * CGWindowList accepted a final displayed frame. Never snap an
         * unsampled native release. */
        hwm_drag_complete(view,window,sampled);
    } else {
        hwm_wake();
    }
}

/* Used by lifecycle interruption handling. It preserves the last sampled
 * native location but deliberately does not commit a neighbour snap. */
static void hwm_drag_force_finalize(struct view *view,bool snap)
{
    struct window *window=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!window) { hwm_drag_native_finishing=false; hwm_drag_native_recovering=false; hwm_drag_native_recovered=false; hwm_drag_window=0; hwm_drag_native=false; return; }
    if(hwm_drag_native) hwm_drag_native_sync(view,window);
    hwm_drag_complete(view,window,snap);
}

static void hwm_drag_release(struct view *view,struct window *window);
/* A disabled event tap is not a native title-bar mouse-up. AppKit may still
 * own the tracking loop, so retain the drag while the real left button is
 * down and keep accepting displayed-frame updates. Once the session reports
 * up, enter the ordinary bounded release settle without needing a queued up. */
static bool hwm_drag_native_tap_disabled_recover(struct view *view)
{
    struct window *window=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!window || !hwm_drag_native) return false;
    /* A disabled tap owns legacy cleanup even if the release beat this first
     * recovery poll.  Completion must clear that otherwise stale session. */
    hwm_drag_native_recovered=true;
    if(CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)) {
        hwm_drag_native_recovering=true;
        (void)hwm_drag_native_sync(view,window);
        hwm_wake();
        return true;
    }
    hwm_drag_native_recovering=false;
    hwm_drag_release(view,window);
    return true;
}

/* Release is a commit of the last displayed position, never a new pointer
 * movement. Plane drags can complete immediately; native title-bar drags keep
 * ownership briefly so a late AppKit frame becomes the committed location. */
static void hwm_drag_release(struct view *view,struct window *window)
{
    hwm_drag_move_pending=false;
    if(hwm_drag_native) {
        bool recovered=hwm_drag_native_recovering || hwm_drag_native_recovered;
        hwm_drag_native_sync(view,window);
        hwm_drag_native_recovering=false;
        if(!recovered) hwm_drag_native_recovered=false;
        hwm_drag_native_finishing=true;
        hwm_drag_native_finish_began=hwm_now();
        hwm_drag_native_finish_deadline=hwm_drag_native_finish_began+.15;
        hwm_drag_native_finish_frame=window->strip_last_frame;
        hwm_drag_native_finish_stable=0;
        hwm_wake();
        return;
    }
    if(view) hwm_drag_submit_plane(view,window,CGPointMake(window->strip_world_x,window->strip_world_y));
    hwm_drag_complete(view,window,true);
}
