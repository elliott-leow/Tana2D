#include "plane_presentation.h"

static CGPoint hwm_drag_world_at(struct view *view,CGPoint point)
{
    HWMPlanePoint world=hwm_plane_drag_world((HWMPlanePoint){hwm_drag_world_origin.x,hwm_drag_world_origin.y},
                                             (HWMPlanePoint){point.x,point.y},(HWMPlanePoint){hwm_drag_pointer_origin.x,hwm_drag_pointer_origin.y},
                                             hwm_drag_scale,hwm_offset(view,hwm_now())-hwm_drag_camera_x,
                                             hwm_plane_camera_y(hwm_now())-hwm_drag_camera_y);
    return CGPointMake(world.x,world.y);
}
/* Snap the raw pointer proposal before submitting the surface and outline
 * together. The grab origin stays raw, so moving away releases the magnet. */
static bool hwm_drag_present_plane(struct view *view,struct window *window,CGPoint world,bool magnet)
{
    if(!view || !window || !isfinite(world.x) || !isfinite(world.y)) return false;
    HWMDragSnap snap; CGPoint raw=world;
    bool snapped=magnet && hwm_drag_window==window->id &&
        hwm_drag_snap_proposal_at(view,window,world,&snap);
    if(magnet) world=hwm_snap_ease(window->id,raw,snapped,snapped ? snap.point : raw,hwm_now());
    double began=hwm_now();
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()), camera_y=hwm_plane_camera_y(hwm_now()), scale=hwm_plane_scale;
    CGRect base=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                           round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                           round(hwm_plane_physical_size(window->strip_width)),round(hwm_plane_physical_size(window->strip_height)));
    // The same device-pixel rule as hwm_render, so a dragged window and its
    // neighbours share one grid.
    CGRect projected=CGRectMake(hwm_pixel(hwm_plane_project_physical(hwm_pixel(world.x*scale)/scale,hwm_pixel(camera_x*scale)/scale,bounds.origin.x,scale)),
                                hwm_pixel(hwm_plane_project_physical(hwm_pixel(world.y*scale)/scale,hwm_pixel(camera_y*scale)/scale,bounds.origin.y,scale)),
                                round(hwm_plane_physical_size(window->strip_width*scale)),round(hwm_plane_physical_size(window->strip_height*scale)));
    bool own_batch=!hwm_batch_open;
    if(own_batch) scripting_addition_batch_begin();
    bool ok=scripting_addition_set_plane_transform(window->id,projected.origin.x,projected.origin.y,scale);
    if(ok) ok=hwm_plane_border_drag(window->id,projected);
    // Pointer samples arrive faster than frames; do not wait for each reply.
    if(own_batch) ok=scripting_addition_batch_end_deferred() && ok;
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
    if(magnet) hwm_drag_preview_apply(view,window,raw,snapped?&snap:NULL);
    return true;
}

static bool hwm_drag_submit_plane(struct view *view,struct window *window,CGPoint world)
{
    return hwm_drag_present_plane(view,window,world,true);
}

/* AppKit retains the complete native input stream. If its native anchor moves
 * beneath our presentation bounds, keep the surface attached to the pointer
 * through the same projection path as a plane drag. A stationary native
 * anchor alone is not evidence of a drag: body selections remain untouched. */
static bool hwm_drag_native_finishing;
static bool hwm_drag_native_recovering;
static double hwm_drag_native_finish_began,hwm_drag_native_finish_deadline;
static CGRect hwm_drag_native_finish_frame;
static unsigned hwm_drag_native_finish_stable;

static double hwm_drag_native_sampled_at=-10;
static bool hwm_drag_native_sync(struct view *view,struct window *window)
{
    hwm_drag_native_sampled_at=hwm_now();
    CGRect frame=CGRectNull,presented=CGRectNull;
    /* Do not recover the displayed frame from SLSGetWindowTransform: AppKit
     * can retain the old requested plane matrix after it has moved the
     * displayed titlebar surface. Keep the last accepted position and retry
     * on the next tick. */
    if(!view || !hwm_plane_window_frames(window->id,&frame,&presented) || CGRectIsNull(frame) ||
       !isfinite(frame.size.width) || !isfinite(frame.size.height) || frame.size.width<=0 || frame.size.height<=0 ||
       !hwm_plane_rect_drawn(presented)) {
        hwm_drag_native_displayed=CGRectNull; return false;
    }
    CGPoint displayed=presented.origin;
    if(!isfinite(displayed.x) || !isfinite(displayed.y)) return false;
    hwm_drag_native_displayed=presented;
    window->strip_native_move_pending=false;
    /* A native drag is an observation session, including when AppKit has not
     * published its first move yet. A body selection must not become a drop.
     * Native anchors and displayed origins are independent; test both only
     * after obtaining a real presentation sample. */
    if(!hwm_drag_native_moved && CGPointEqualToPoint(frame.origin,g_mouse_state.window_frame.origin) &&
       (hwm_drag_native_unscaled || CGPointEqualToPoint(displayed,window->strip_last_frame.origin))) return true;
    bool observed_native_move=hwm_drag_native_moved;
    hwm_drag_commit_interaction(window);
    hwm_drag_native_moved=true;
    bool native_anchor_moved=!CGPointEqualToPoint(frame.origin,g_mouse_state.window_frame.origin);
    if(!hwm_drag_native_finishing &&
       (hwm_drag_native_projected || (!observed_native_move && native_anchor_moved &&
        CGPointEqualToPoint(displayed,window->strip_last_frame.origin)))) {
        CGPoint point,world;
        bool pointer=!hwm_drag_native_recovering && hwm_drag_pointer_generation &&
            !hwm_pointer_sample_generation_is_aborted(hwm_drag_pointer_generation) &&
            hwm_pointer_sample_drag_for_generation(hwm_drag_pointer_generation,0,&point,NULL);
        if(pointer) {
            hwm_drag_point=point;
            world=hwm_drag_world_at(view,point);
        } else {
            /* No usable tap sample (programmatic move or tap recovery): the
             * native anchor still records AppKit's movement under the lock.
             * Continue from the last accepted anchor, never a stale cursor. */
            CGPoint anchor=hwm_drag_native_projected ? window->frame.origin : g_mouse_state.window_frame.origin;
            CGPoint origin=hwm_drag_native_projected ? CGPointMake(window->strip_world_x,window->strip_world_y) : hwm_drag_world_origin;
            world=CGPointMake(origin.x+(frame.origin.x-anchor.x)/hwm_drag_scale,
                              origin.y+(frame.origin.y-anchor.y)/hwm_drag_scale);
        }
        hwm_drag_native_projected=true;
        window->frame=frame;
        window->strip_width=window->strip_from_width=frame.size.width;
        window->strip_height=window->strip_from_height=frame.size.height;
        if(window->strip_transform_dirty || world.x!=window->strip_world_x || world.y!=window->strip_world_y ||
           !CGSizeEqualToSize(frame.size,window->strip_last_frame.size)) {
            hwm_drag_move=world;
            return hwm_drag_submit_plane(view,window,world);
        }
        return true;
    }
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()),camera_y=hwm_plane_camera_y(hwm_now());
    // Native bounds retain an independent anchor when the camera transformed
    // the window. Persist the compositor origin, not that native anchor.
    CGPoint world=CGPointMake((displayed.x-bounds.origin.x)/hwm_plane_scale+camera_x,
                              (displayed.y-bounds.origin.y)/hwm_plane_scale+camera_y);
    if(hwm_drag_native_unscaled && !hwm_drag_native_projected) {
        // During native camera motion, AppKit's frame and the painted frame
        // can be one refresh apart. The user's movement is the native delta
        // from the press, not that transient paint lag plus camera travel.
        world=CGPointMake(hwm_drag_world_origin.x+frame.origin.x-g_mouse_state.window_frame.origin.x,
                          hwm_drag_world_origin.y+frame.origin.y-g_mouse_state.window_frame.origin.y);
    }
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
    HWMDragSnap snap;
    if(!hwm_drag_native_finishing && !hwm_drag_native_recovering &&
       hwm_drag_snap_proposal_at(view,window,world,&snap)) {
        hwm_drag_native_projected=true;
        return hwm_drag_submit_plane(view,window,world);
    }
    /* A projected native release must retain the target computed from the
     * raw pointer. Re-scoring the magnetized origin can chain a second snap. */
    if(!hwm_drag_native_projected || !hwm_drag_native_finishing)
        hwm_drag_preview_update(view,window);
    CGRect visible=presented;
    bool own_batch=!hwm_batch_open; if(own_batch) scripting_addition_batch_begin();
    bool ok=hwm_plane_border_drag(window->id,visible);
    if(own_batch) ok=scripting_addition_batch_end() && ok;
    if(!ok) hwm_plane_border_drag_failed();
    /* Presentation acceptance and border delivery are independent facts. */
    return true;
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
    if(native && hwm_drag_native_moved && !window->strip_native_move_pending) {
        /* AppKit changed the native anchor while keeping an old compositor
         * matrix. Submit the accepted displayed world point again on the next
         * renderer frame before any camera motion can use that stale matrix. */
        window->strip_transform_dirty=true;
    }
    if(snap && (!native || hwm_drag_native_moved)) hwm_drag_snap_commit(view,window);
    hwm_drag_window=0; hwm_drag_native=false;
    if(recovered_native && g_mouse_state.window==window) {
        g_mouse_state.window=NULL;
        g_mouse_state.current_action=MOUSE_MODE_NONE;
        g_mouse_state.direction=0;
        hwm_mouse_pointer_generation=0;
        hwm_mouse_pointer_button=-1;
    }
    if(hwm_drag_committed) {
        scripting_addition_set_shadow(window->id,hwm_drag_shadow);
        scripting_addition_set_layer(window->id,hwm_drag_restore_layer);
        if(view) hwm_layout(view,false);
    }
    hwm_drag_committed=false;
    hwm_drop_target=0; hwm_drag_snap_reset(); hwm_snap_ease_reset(); hwm_preview_hide(); hwm_hold_focus(); hwm_wake();
}

/* A title-bar release is not immediately trustworthy: AppKit can publish the
 * terminal move after its mouse-up has reached our serialized event loop.
 * Retain native ownership for the entire 150 ms grace period. Two identical
 * early samples do not establish that AppKit has published its terminal move. */
static void hwm_drag_native_finish_tick(struct view *view,struct window *window,double now)
{
    if(!hwm_drag_native_finishing || !window || hwm_drag_window!=window->id || !hwm_drag_native) return;
    bool sampled=hwm_drag_native_sync(view,window);
    if(sampled && CGRectEqualToRect(window->strip_last_frame,hwm_drag_native_finish_frame)) ++hwm_drag_native_finish_stable;
    else if(sampled) { hwm_drag_native_finish_frame=window->strip_last_frame; hwm_drag_native_finish_stable=0; }
    if(now>=hwm_drag_native_finish_deadline) {
        /* A deadline keeps ownership bounded, but it is not evidence that
         * CGWindowList accepted a final displayed frame. Never snap an
         * unsampled native release. */
        window->strip_native_move_pending=!sampled;
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
    if(hwm_drag_native) window->strip_native_move_pending=!hwm_drag_native_sync(view,window);
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
        if(hwm_drag_native_finishing) { hwm_drag_native_sync(view,window); hwm_wake(); return; }
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
    hwm_drag_complete(view,window,true);
}
