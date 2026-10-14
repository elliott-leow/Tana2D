/* Serialized rendering and delayed-notification handling. */
#include "plane_geometry.h"
static bool hwm_view_in_motion(struct view *view,double now);
static double hwm_rendered_offset; // Camera position of the frame last drawn.
static bool hwm_render(struct view *view, double now)
{
    CGRect bounds = hwm_bounds(view);
    double offset = hwm_offset(view, now);
    double camera_y=hwm_plane_camera_y(now), plane_scale=hwm_plane_scale;
    hwm_rendered_offset = offset;
    bool active = hwm_camera_animating || view->strip_scrolling || hwm_plane_y_scrolling;
    bool batched=false;
    // While the strip is travelling, a window that is off screen before and
    // after a frame does not need that frame: only what can be seen is moved.
    // Everything is brought up to date once the strip rests.
    bool travelling=hwm_view_in_motion(view,now);
    if(hwm_shelf_moving(now)) active=true;
    hwm_visibility_prepare(view,now);
    CGRect screen=hwm_screen(view);
    CGRect visible=CGRectInset(bounds,-HSTRIP_OFFSCREEN_MARGIN,-HSTRIP_OFFSCREEN_MARGIN);
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, node->window_list[i]);
            if (!window || !window->strip_initialized || window->id==hwm_drag_window || window->id==hwm_edge_window) continue;
            /* A release deadline ends pointer ownership, not uncertainty about
             * AppKit's final surface. Never overwrite that surface with an old
             * model point while CGWindowList is unavailable. Adopt it using
             * the last displayed camera before applying any newer camera. */
            if(window->strip_native_move_pending) {
                CGRect shown=CGRectNull,native=CGRectNull;
                double old_scale=window->strip_last_plane_scale;
                if(!(old_scale>0) || !hwm_plane_displayed_frame(window->id,&shown) ||
                   SLSGetWindowBounds(g_connection,window->id,&native)!=kCGErrorSuccess) { active=true; continue; }
                window->strip_world_x=window->strip_from_x=(shown.origin.x-bounds.origin.x)/old_scale+window->strip_last_offset;
                window->strip_world_y=window->strip_from_y=(shown.origin.y-bounds.origin.y)/old_scale+window->strip_last_camera_y;
                window->frame=native;
                window->strip_width=window->strip_from_width=native.size.width;
                window->strip_height=window->strip_from_height=native.size.height;
                window->strip_last_frame=native; window->strip_last_frame.origin=shown.origin;
                window->strip_start=now-hwm_duration;
                window->strip_native_move_pending=false; window->strip_transform_dirty=true;
            }
            if(hwm_workflow_tab_hidden(window)) {
                if(!batched) { hwm_batch_begin(); batched=true; }
                hwm_visibility_set(window,true,CGRectNull);
                // Hidden tabs need opacity only. Never move a native anchor
                // offscreen just to park its displayed surface.
                window->strip_tab_parked=true; window->strip_size_pending=false;
                if(now-window->strip_start<hwm_duration+.5) active=true;
                continue;
            }
            if(window->strip_tab_parked && hwm_duration>.01) {
                // A tab arrives in place, so it is revealed with a fade rather than a flight.
                scripting_addition_set_opacity(window->id,0,0);
                scripting_addition_set_opacity(window->id,hwm_window_alpha(window),.16);
            }
            window->strip_tab_parked=false;
            // AX notifications can arrive after mouse-up or during a camera
            // animation. Defer reconciliation while our own resize is in flight,
            // but never discard the application's final accepted geometry.
            if(window->strip_native_resize_pending) {
                active=true;
                bool size_animation=now-window->strip_start<hwm_duration &&
                    (fabs(window->strip_width-window->strip_from_width)>.5 || fabs(window->strip_height-window->strip_from_height)>.5);
                if(!size_animation && !window->strip_size_pending && !hwm_resize_busy(window)) {
                    CGRect measured=CGRectNull;
                    if(SLSGetWindowBounds(g_connection,window->id,&measured)==kCGErrorSuccess &&
                       measured.size.width>=100 && measured.size.height>=100) {
                        window->frame=measured;
                        window->strip_width=window->strip_from_width=measured.size.width;
                        window->strip_height=window->strip_from_height=measured.size.height;
                        window->strip_vel_width=window->strip_vel_height=0;
                        window->strip_last_frame.size=measured.size;
                        window->strip_transform_dirty=true;
                    }
                    window->strip_native_resize_pending=now<window->strip_native_resize_until;
                }
            }
            double elapsed = now-window->strip_start, t = elapsed/hwm_duration, unused;
            double x = hwm_window_sample(window->strip_from_x,window->strip_world_x,window->strip_vel_x,elapsed,hwm_window_zeta,&unused);
            double y = hwm_window_sample(window->strip_from_y,window->strip_world_y,window->strip_vel_y,elapsed,hwm_window_zeta,&unused);
            double height = hwm_window_sample(window->strip_from_height,window->strip_height,window->strip_vel_height,elapsed,1,&unused);
            double width = hwm_window_sample(window->strip_from_width,window->strip_width,window->strip_vel_width,elapsed,1,&unused);
            if (t < 1) active = true;
            /* The application's native frame stays fixed. Only its compositor
             * transform projects it onto the plane, so AppKit cannot clamp a
             * pan back onto the menu-bar edge. strip_last_frame stores displayed
             * origin and unscaled size; it is never a native bounds cache. */
            double own_offset=offset, shift=0;
            CGRect base=CGRectMake(round(hwm_plane_project_physical(x,own_offset,bounds.origin.x,plane_scale)),
                                   round(hwm_plane_project_physical(y,camera_y,bounds.origin.y,plane_scale)),
                                   round(hwm_plane_physical_size(width)),round(hwm_plane_physical_size(height)));
            CGRect frame=CGRectMake(round(hwm_plane_project_physical(x,own_offset,bounds.origin.x,plane_scale)),
                                    round(hwm_plane_project_physical(y,camera_y,bounds.origin.y,plane_scale)),
                                    round(hwm_plane_physical_size(width*plane_scale)),round(hwm_plane_physical_size(height*plane_scale)));
            CGRect last = window->strip_last_frame;
            bool hidden=!CGRectIntersectsRect(frame,screen);
            bool revealing=window->strip_offscreen && !hidden;
            if(hidden && (!window->strip_offscreen || hwm_visibility_companions.count)) {
                if(!batched) { hwm_batch_begin(); batched=true; }
                hwm_visibility_set(window,true,frame);
            }
            bool resize = (CGRectIsNull(last) || fabs(last.size.width-base.size.width) >= 1 || fabs(last.size.height-base.size.height) >= 1);
            // AppKit limits AX size to the room remaining after the native
            // anchor. Relocate that anchor only for an explicit growing resize,
            // then restore the displayed projection in the same hidden batch.
            // Camera movement and dragging never take this path.
            bool anchor_moved=false;
            CGPoint anchor=window->frame.origin;
            if(resize && !CGRectIsNull(last)) {
                if(window->strip_width>window->frame.size.width && anchor.x+window->strip_width>CGRectGetMaxX(screen)) anchor.x=bounds.origin.x;
                if(window->strip_height>window->frame.size.height && anchor.y+window->strip_height>CGRectGetMaxY(screen)) anchor.y=bounds.origin.y;
                if(!CGPointEqualToPoint(anchor,window->frame.origin)) {
                    if(!batched) { hwm_batch_begin(); batched=true; }
                    if(!scripting_addition_move_window(window->id,anchor.x,anchor.y)) {
                        ++hwm_move_failures; hwm_backend_ok=false; hwm_batch_end(); return false;
                    }
                    window->frame.origin=anchor; anchor_moved=true;
                }
            }
            bool move = revealing || resize || CGRectIsNull(last) || !CGPointEqualToPoint(last.origin, base.origin);
            if (move && travelling && !resize && !window->strip_size_pending && !CGRectIsNull(last) &&
                !CGRectIntersectsRect(last,visible) && !CGRectIntersectsRect(frame,visible)) {
                node->area = (struct area) { frame.origin.x, frame.origin.y, frame.size.width, frame.size.height };
                continue;
            }
            if(move || window->strip_transform_dirty || !window->strip_plane_scaled || window->strip_last_plane_scale!=plane_scale) {
                if(!batched) { hwm_batch_begin(); batched=true; }
                if(!scripting_addition_set_plane_transform(window->id,frame.origin.x,frame.origin.y,plane_scale)) {
                    ++hwm_move_failures; hwm_backend_ok=false;
                    hwm_batch_end(); return false;
                }
                window->strip_plane_scaled=true; window->strip_transform_dirty=false;
                window->strip_last_frame=base;
                window->strip_last_offset=own_offset;
                window->strip_last_camera_y=camera_y;
                window->strip_last_shift=shift;
            }
            window->strip_last_plane_scale=plane_scale;
            if(!hidden && (window->strip_offscreen || hwm_visibility_companions.count)) {
                if(!batched) { hwm_batch_begin(); batched=true; }
                hwm_visibility_set(window,false,frame);
            }
            if (resize) {
                if(anchor_moved) hwm_batch_settle();
                ++hwm_resize_operations;
                // Size goes through Accessibility, handed off so that this frame
                // never waits for the application to answer.
                hwm_resize_submit(window,base,CGRectIsNull(last) || fabs(last.size.height-base.size.height)>=1);
                window->strip_size_pending = true;
                window->strip_size_confirmed = false;
                window->strip_size_sent_at = now;
            }
            node->area = (struct area) { frame.origin.x, frame.origin.y, frame.size.width, frame.size.height };
            if (window->strip_size_pending) {
                if (now-window->strip_size_sent_at < .25 || t < 1 || hwm_resize_busy(window)) {
                    active = true;
                } else {
                    window->strip_size_pending = false;
                    CGRect actual = CGRectNull;
                    hwm_batch_settle();
                    bool measured=SLSGetWindowBounds(g_connection,window->id,&actual)==kCGErrorSuccess;
                    if(measured) window->frame=actual;
                    window->strip_transform_dirty=true; active=true;
                    scripting_addition_set_layer(window->id,LAYER_BELOW);
                    if (measured &&
                        isfinite(actual.size.width) && actual.size.width >= 160 &&
                        (fabs(actual.size.width-window->strip_width)>1 || fabs(actual.size.height-window->strip_height)>1)) {
                        // A final AX write can lose to an app's delayed resize
                        // while its origin is moving. Confirm the requested final
                        // size once before treating an intermediate as a limit.
                        if(!window->strip_size_confirmed) {
                            window->strip_size_confirmed=true; window->strip_size_pending=true;
                            window->strip_size_sent_at=now;
                            hwm_resize_submit(window,base,true);
                            active=true; continue;
                        }
                        window->strip_min_width=fmax(window->strip_min_width,actual.size.width);
                        hwm_column_width(view,window,actual.size.width);
                        if(isfinite(actual.size.height) && actual.size.height>=100) window->strip_height=actual.size.height;
                        window->strip_full_width = false;
                        window->strip_last_frame.size = actual.size;
                        if(batched) hwm_batch_end();
                        hwm_layout(view,true);
                        return true;
                    }
                }
            }
        }
    }
    if(batched) hwm_batch_end();
    return active;
}

static bool hwm_view_in_motion(struct view *view,double now)
{
    return hwm_camera_animating || view->strip_scrolling || hwm_plane_y_scrolling || __atomic_load_n(&__pending_gesture,__ATOMIC_ACQUIRE) ||
           now-hwm_last_input<.15 || hwm_shelf_moving(now);
}

static bool horizontal_window_changed(struct window *window, struct view *view, bool resized)
{
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if (hwm_paused || hwm_overview_active) return true;
    if(hwm_workflow_tab_hidden(window)) { hwm_wake(); return true; }
    if (hwm_edge_update(window,view)) return true;
    if (hwm_drag_window==window->id) return true;
    if (!resized && g_mouse_state.window==window && !CGRectIsNull(window->strip_last_frame)) {
        /* A delayed native window notification must follow the left press that
         * owns g_mouse_state, never the newest tap sample from a later right
         * click. A terminal left press has no active sample and cannot reopen
         * a native drag. */
        uint64_t generation=hwm_mouse_pointer_generation;
        CGPoint point;
        if(hwm_mouse_pointer_button==kCGMouseButtonLeft && generation &&
           hwm_pointer_sample_active_point_for_generation(generation,&point)) {
            if (g_mouse_state.current_action==MOUSE_MODE_NONE &&
                hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3) {
                hwm_drag_point=point;
                hwm_drag_started(window);
                if(hwm_drag_window==window->id) {
                    hwm_drag_pointer_generation=generation;
                }
                return true;
            }
        }
    }
    // Accessibility notifications can arrive behind the display-link renderer.
    // They must not restart an in-progress transition with an obsolete frame.
    double now = hwm_now();
    if (hwm_view_in_motion(view,now) || window->strip_size_pending || now-window->strip_start < hwm_duration+.1 || hwm_resize_busy(window)) {
        if(!resized) window->strip_transform_dirty=true;
        hwm_wake();
        return true;
    }
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) != kCGErrorSuccess) return true;
    if (resized && isfinite(actual.size.width) && actual.size.width >= 160 && isfinite(actual.size.height) && actual.size.height >= 100 &&
        (fabs(actual.size.width-window->strip_width)>1 || fabs(actual.size.height-window->strip_height)>1)) {
        hwm_column_width(view,window,actual.size.width);
        window->strip_height=actual.size.height;
        window->strip_full_width = false;
        window->frame=actual; window->strip_native_resize_pending=false;
        window->strip_transform_dirty=true;
        window->strip_last_frame.size = actual.size;
        window->strip_last_offset=hwm_shelf_offset(view,hwm_shelf_of(window),now);
        hwm_layout(view,true);
    } else if (!resized) {
        // Native moves are distinct from the plane projection. Reapply only
        // the absolute transform; never adopt a native origin as a world point.
        window->frame=actual;
        window->strip_transform_dirty=true;
        hwm_wake();
    }
    return true;
}

static bool horizontal_window_moved(struct window *window)
{
    struct view *view = window_manager_find_managed_window(&g_window_manager,window);
    // A floating window is moved by its application; one tick re-seats its border.
    if (hwm_ready && !view && window->id==hwm_feedback_focus_id) hwm_wake();
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if(hwm_view_in_motion(view,hwm_now())) return true;
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) == kCGErrorSuccess)
        window->frame.origin = actual.origin;
    return horizontal_window_changed(window,view,false);
}

/* Called for every Accessibility resize notification, before the engine asks
 * the application anything. While the strip owns a window's geometry those
 * notifications are echoes of its own requests; answering each with further
 * blocking Accessibility queries is what made resizing stutter. Returns true
 * when the notification needs no further handling. */
static bool horizontal_resize_event(struct window *window)
{
    ++window->strip_native_resize_events;
    struct view *view = window_manager_find_managed_window(&g_window_manager,window);
    if (!hwm_ready || hwm_paused || !view || view->layout != VIEW_STRIP) return false;
    if (hwm_overview_active) return true;
    if (window->id==hwm_edge_window) { hwm_edge_update(window,view); hwm_wake(); return true; }
    // Entering native fullscreen is a resize too, and the engine must see it:
    // such a window has already left the strip's Space.
    if (hwm_window_left_strip(window)) return false;
    window->strip_native_resize_pending=true;
    // AppKit may notify before WindowServer publishes the new bounds. Keep
    // sampling briefly so the first, still-old read cannot end reconciliation.
    window->strip_native_resize_until=hwm_now()+.15;
    window->strip_transform_dirty=true;
    // This is work even when the camera is idle. The legacy engine may
    // debounce an AX echo before horizontal_window_changed ever runs.
    hwm_wake();
    return true;
}
