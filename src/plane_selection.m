static bool hwm_plane_window_selectable(struct view *view,struct window *w)
{
    return view && w && w->application && view_find_window_node(view,w->id) &&
           !w->strip_close_ghost && !w->strip_offscreen && !hwm_workflow_tab_hidden(w) &&
           !window_check_flag(w,WINDOW_MINIMIZE) && !w->application->is_hidden;
}
/* A surface above the plane that the pointer must not reach through: a menu,
 * popup or panel of an application on the plane, or anything at menu level.
 * Focusing the window beneath one of these dismisses it. */
static bool hwm_plane_surface_blocks(struct view *view,uint32_t wid,int owner)
{
    pid_t pid=0; int level=0;
    if(SLSGetWindowLevel(g_connection,wid,&level)!=kCGErrorSuccess) return false;
    if(level>=CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey)) return true;
    // The desktop (Finder's icons, the wallpaper) is beneath every window.
    if(level<CGWindowLevelForKey(kCGNormalWindowLevelKey)) return false;
    if(SLSConnectionGetPID(owner,&pid)!=kCGErrorSuccess || pid<=0) return false;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(w && w->application && w->application->pid==pid) return true;
    }
    return false;
}
/* The window the pointer is over as drawn: a plane window, or a floating
 * window above the plane (*floating). NULL when a menu or popup is in the way. */
static struct window *hwm_plane_surface_at(struct view *view,CGPoint point,bool *floating)
{
    if(floating) *floating=false;
    if(!view) return NULL;
    struct window *target=NULL;
#ifdef HWM_NATIVE_ZOOM
    /* The workspace input surface and focus border can both be above a card.
     * Walk the displayed stack rather than picking the first model rectangle
     * when cards overlap. */
    uint32_t previous=0,wid=0; int owner=0; CGPoint local=CGPointZero;
    for(int depth=0;depth<32;depth++) {
        if(SLSFindWindowAndOwner(g_connection,previous,depth?-1:1,0,&point,&local,&wid,&owner)!=kCGErrorSuccess || !wid || wid==previous) break;
        previous=wid;
        struct window *candidate=window_manager_find_window(&g_window_manager,wid);
        if(hwm_plane_window_selectable(view,candidate)) { target=candidate; break; }
        if(owner==g_connection) continue; // Our own border and overlays.
        if(candidate && floating && candidate->is_root && !view_find_window_node(view,candidate->id) &&
           window_check_flag(candidate,WINDOW_FLOAT) && !window_check_flag(candidate,WINDOW_MINIMIZE) &&
           !candidate->application->is_hidden && window_manager_is_window_eligible(candidate)) { *floating=true; return candidate; }
        if(hwm_plane_surface_blocks(view,wid,owner)) return NULL;
    }
#endif
    /* The walk above usually finds the window in one WindowServer query.
     * yabai's lookup (several more, and a process-name check for external
     * borders on every call) is needed only when it did not. */
    if(!target) target=window_manager_find_window_at_point(&g_window_manager,point);
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
static struct window *hwm_plane_window_at(struct view *view,CGPoint point)
{
    return hwm_plane_surface_at(view,point,NULL);
}

#ifdef HWM_NATIVE_ZOOM
typedef struct { uint32_t wid; double started,issued; bool workspace; } HWMHoverTiming;
static HWMHoverTiming hwm_hover_timings[128];
static unsigned hwm_hover_timing_count;
static HWMPlaneHoverIntent hwm_hover_intent;
static uint32_t hwm_zoom_hover_pending,hwm_zoom_input_window;
static CGPoint hwm_zoom_hover_point;
static double hwm_zoom_hover_started;

static double hwm_hover_focused_at=-10; // When hover last handed focus on.
/* See hwm_focus_intent_sample. Every hover report is noted; a pointer that
 * goes quiet before settling is looked at again once it has been still. */
static HWMFocusIntent hwm_focus_intent;
static bool hwm_focus_recheck_pending;
static void hwm_hover_recheck(double delay)
{
    if(hwm_focus_recheck_pending) return;
    hwm_focus_recheck_pending=true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup("hover-settle"),HWM_NAMED_ACTION);
    });
}
static uint64_t hwm_hover_rechecks,hwm_hover_recheck_lost,hwm_hover_recheck_reached;
static bool hwm_hover_reached;
static uint64_t hwm_hover_focus_paths[5];
static void hwm_hover_focus_immediate(struct window *target,double started)
{
    double now=hwm_now();
    hwm_focus_queue_clear(&hwm_nav_window,&hwm_nav_pending,&hwm_nav_automatic);
    hwm_last_input=now;hwm_focus_guard=false;hwm_focus_after_scroll=false;
    hwm_preserve_focus_window=target->id;hwm_preserve_focus_until=now+1;
    /* The application switch that follows then knows which window it is for
     * and need not ask the application over Accessibility, a synchronous
     * wait on an app that is slow to answer under load. */
    hwm_requested_focus=target->id;hwm_requested_focus_time=now;hwm_hover_focused_at=now;
    horizontal_hover_received(target);
    window_manager_focus_window_immediate(&target->application->psn,target->id,target->ref);
    // The border leads, as for keyboard navigation; focus reports follow.
    hwm_feedback_focus(NULL,target);
    hwm_hover_timings[hwm_hover_timing_count++%128]=(HWMHoverTiming){target->id,started,hwm_now(),false};
}

/* Set by camera motion at 100%; consumed by the first resting native frame. */
static bool hwm_zoom_rest_focus_armed;
static void hwm_zoom_rest_focus(struct view *view)
{
    if(!hwm_zoom_rest_focus_armed) return;
    hwm_zoom_rest_focus_armed=false;
    if(!view || g_window_manager.ffm_mode==FFM_DISABLED || hwm_plane_pointer_owned() ||
       g_mouse_state.window || menu_focus_suppressed()) return;
    CGPoint cursor;
    if(SLSGetCurrentCursorLocation(g_connection,&cursor)!=kCGErrorSuccess || hwm_plane_controls_hit(cursor) ||
       !hwm_zoom_workspace_contains(cursor)) return;
    struct window *w=hwm_plane_window_at(view,cursor);
    if(!w || !window_manager_is_window_eligible(w) || w->id==g_window_manager.focused_window_id) return;
    // The popup scan copies the whole window list; only a focus change needs it.
    if(popup_focus_suppressed()) return;
    hwm_zoom_hover_pending=w->id;hwm_zoom_hover_point=cursor;hwm_zoom_hover_started=hwm_now();
}

/* Zoomed out, an application still places every menu and panel from its
 * native frame, which AppKit knows only through Accessibility: a dropdown
 * opened from a toolbar appeared far from its button, and apps that read the
 * pointer themselves (Firefox) hovered the wrong element. Keep the hovered
 * window's invisible native frame positioned so that the point under the
 * pointer is at the same place natively as on screen. The drawn window does
 * not move; a popup then opens at the pointer, full size and fully usable. */
static uint32_t hwm_zoom_anchor_wid; // Pointer moved on while its last move was in flight.
static CGPoint hwm_zoom_anchor_point;
static void hwm_zoom_anchor_hover(struct view *view,struct window *w,CGPoint point)
{
    hwm_zoom_anchor_wid=0;
    double scale=w->strip_last_plane_scale;
    if(!hwm_zoom_workspace || !w->strip_plane_scaled || CGRectIsNull(w->strip_last_frame) || !(scale>0) || scale>.999) return;
    // Below the click threshold the press opens the window instead.
    if(scale<hwm_zoom_click_threshold) return;
    CGPoint shown=w->strip_last_frame.origin;
    CGPoint origin=CGPointMake(round(point.x-(point.x-shown.x)/scale),round(point.y-(point.y-shown.y)/scale));
    // AppKit keeps a title bar below the menu bar; ask for what it will accept.
    origin.y=fmax(origin.y,round(hwm_screen(view).origin.y));
    CGRect native=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&native)!=kCGErrorSuccess) return;
    // A little slack: a popup then opens within a few points of the pointer.
    if(fabs(native.origin.x-origin.x)<16 && fabs(native.origin.y-origin.y)<16) return;
    // One move in flight per window; its completion wakes the clock, and the
    // next frame aims at wherever the pointer is by then.
    if(hwm_zoom_native_busy(w->id)) { hwm_zoom_anchor_wid=w->id; hwm_zoom_anchor_point=point; return; }
    CGRect accepted=CGRectNull;
    hwm_zoom_native_position(w,origin,CGSizeZero,origin,&accepted);
}

static void hwm_zoom_hover_tick(void)
{
    if(hwm_zoom_anchor_wid && !hwm_zoom_native_busy(hwm_zoom_anchor_wid)) {
        struct window *w=window_manager_find_window(&g_window_manager,hwm_zoom_anchor_wid);
        struct view *view=hwm_view();
        hwm_zoom_anchor_wid=0;
        if(w && hwm_plane_window_selectable(view,w) && !g_mouse_state.window && !hwm_plane_pointer_owned() &&
           !menu_focus_suppressed() && !popup_focus_suppressed()) hwm_zoom_anchor_hover(view,w,hwm_zoom_anchor_point);
    }
    if(!hwm_zoom_hover_pending)return;
    if(hwm_paused || hwm_suspended || g_window_manager.ffm_mode==FFM_DISABLED ||
       __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) {hwm_zoom_hover_pending=0;return;}
    struct window *w=window_manager_find_window(&g_window_manager,hwm_zoom_hover_pending);
    if(!hwm_plane_window_selectable(hwm_view(),w)) {hwm_zoom_hover_pending=0;return;}
    // At 100% wait for the native frame to land; a zoomed-out window is
    // always presented through its transform and can take focus at once.
    if(hwm_plane_scale==1 && w->strip_plane_scaled)return;
    /* A pending focus (a window landing, or the camera coming to rest under
     * the pointer) waits like hover does while the pointer is still moving fast. */
    double now=hwm_now();
    if(w->id!=g_window_manager.focused_window_id && hwm_focus_intent_speed(&hwm_focus_intent,now)>HWM_FOCUS_SETTLE_SPEED) { hwm_hover_recheck(HWM_FOCUS_SETTLE+.004); return; }
    double wait=hwm_hover_focused_at+HWM_FOCUS_INTERVAL-now;
    if(w->id!=g_window_manager.focused_window_id && wait>0) { hwm_hover_recheck(wait+.002); hwm_wake(); return; }
    if(w->id!=g_window_manager.focused_window_id) { ++hwm_hover_focus_paths[0]; hwm_hover_focus_immediate(w,hwm_zoom_hover_started); }
    hwm_zoom_hover_pending=0;
}

static bool hwm_hover_intends(struct window *target,CGPoint point,double now)
{
    hwm_hover_reached=true;
    if(!hwm_focus_intent_sample(&hwm_focus_intent,target->id,point.x,point.y,now)) { hwm_hover_recheck(HWM_FOCUS_SETTLE+.004); return false; }
    double wait=hwm_hover_focused_at+HWM_FOCUS_INTERVAL-now;
    if(target->id!=g_window_manager.focused_window_id && wait>0) { hwm_hover_recheck(wait+.002); return false; }
    return true;
}
static bool horizontal_native_hover(CGPoint point,uint64_t timestamp);
static void hwm_hover_settle(void)
{
    hwm_focus_recheck_pending=false; ++hwm_hover_rechecks;
    CGPoint cursor; hwm_hover_reached=false;
    if(SLSGetCurrentCursorLocation(g_connection,&cursor)==kCGErrorSuccess) horizontal_native_hover(cursor,0);
    if(hwm_hover_reached) ++hwm_hover_recheck_reached; else ++hwm_hover_recheck_lost;
}
static bool horizontal_native_hover(CGPoint point,uint64_t timestamp)
{
    if(!hwm_ready || hwm_paused || hwm_suspended || hwm_overview_active) return false;
    if(g_window_manager.ffm_mode==FFM_DISABLED || mission_control_is_active() ||
       g_process_manager.front_pid==getpid() ||
       hwm_plane_pointer_owned() || hwm_plane_select_click || g_mouse_state.window ||
       __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) ||
       hwm_plane_controls_hit(point) || !hwm_zoom_workspace_contains(point)) { atomic_fetch_add(&window_manager_hover_epoch,1);hwm_zoom_hover_pending=0;hwm_hover_intent=(HWMPlaneHoverIntent){0};return true; }
    struct view *view=hwm_view();if(!view)return false;
    bool floating=false;
    struct window *target=hwm_plane_surface_at(view,point,&floating);
    /* An open menu or popup holds focus. Over the window that already has it
     * at 100% nothing can change, so the popup scan (a copy of the whole
     * window list) is skipped for every move that stays there. Zoomed out it
     * still runs: anchoring moves that window's native frame, and with it any
     * popup the window has open. */
    bool consequential=target && (target->id!=g_window_manager.focused_window_id || hwm_plane_scale<1);
    if(!target || !window_manager_is_window_eligible(target) ||
       (consequential && (menu_focus_suppressed() || popup_focus_suppressed()))) { atomic_fetch_add(&window_manager_hover_epoch,1);hwm_zoom_hover_pending=0;hwm_hover_intent=(HWMPlaneHoverIntent){0};return true; }
    double now=hwm_now(),started=timestamp ? timestamp/1e9 : now;
    if(started>now || now-started>2)started=now;
    // Hover never steers the camera. Moving windows pass under a stationary
    // pointer and WindowServer reports that as motion; stopping or
    // re-rendering the plane from here made pans halt part-way, drew some
    // windows a frame apart from the rest, and fed back into more hovers.
    // Nor does it change focus mid-motion: windows sliding under a still
    // pointer would each take focus in turn. hwm_zoom_rest_focus focuses the
    // window under the pointer once the camera stops.
    bool moving=hwm_camera_animating || view->strip_scrolling || hwm_plane_y_scrolling ||
                (hwm_plane_scale<1 && now-hwm_zoom_pinch_time<.15);
    if(moving) { hwm_zoom_hover_pending=0;hwm_hover_intent=(HWMPlaneHoverIntent){0};hwm_zoom_rest_focus_armed=true;return true; }
    bool intends=hwm_hover_intends(target,point,now);
    // A floating window is not on the plane: it is focused where it is drawn.
    if(floating) {
        hwm_zoom_hover_pending=0;hwm_hover_intent=(HWMPlaneHoverIntent){0};
        if(intends && target->id!=g_window_manager.focused_window_id && !(target->id==hwm_preserve_focus_window && now-hwm_hover_time<.025))
            { ++hwm_hover_focus_paths[1]; hwm_hover_focus_immediate(target,started); }
        return true;
    }
    if(hwm_plane_scale<1) hwm_zoom_anchor_hover(view,target,point);
    // A clipped titlebar can never reach its projected native origin. It
    // must still accept focus immediately, without waiting forever for AX.
    if(hwm_plane_scale==1 && target->strip_plane_scaled &&
       target->strip_last_frame.origin.y<hwm_screen(view).origin.y &&
       target->id!=g_window_manager.focused_window_id && intends &&
       !(target->id==hwm_preserve_focus_window && now-hwm_hover_time<.025)) { ++hwm_hover_focus_paths[2]; hwm_hover_focus_immediate(target,started); }
    // A window still being aligned natively is focused once it lands.
    if(hwm_plane_scale==1 && target->strip_plane_scaled) {
        if(hwm_zoom_hover_pending!=target->id)hwm_zoom_hover_started=started;
        hwm_zoom_hover_pending=target->id;hwm_zoom_hover_point=point;hwm_wake();
    } else hwm_zoom_hover_pending=0;
    // Hover never changes zoom. Zoomed out, the hovered window takes focus
    // (and the border) at once, exactly as a native window does at 100%.
    if((hwm_plane_scale<1 || !target->strip_plane_scaled) && intends &&
       target->id!=g_window_manager.focused_window_id &&
       !(target->id==hwm_preserve_focus_window && now-hwm_hover_time<.025)) { ++hwm_hover_focus_paths[3]; hwm_hover_focus_immediate(target,started); }
    CGRect frame=target->strip_last_frame,bounds=hwm_bounds(view);
    frame.size.width*=target->strip_last_plane_scale;frame.size.height*=target->strip_last_plane_scale;
    bool center=hwm_plane_hover_intent(&hwm_hover_intent,target->id,
        (HWMPlanePoint){point.x,point.y},(HWMPlaneRect){frame.origin.x,frame.origin.y,frame.size.width,frame.size.height},
        (HWMPlaneRect){bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height},now);
    if(center && hwm_magnetic_centering && !hwm_camera_animating && hwm_motion_scale>0) {
        double x=target->strip_world_x+target->strip_width*.5-bounds.size.width/(2*hwm_plane_scale);
        double y=target->strip_world_y-fmax(0,(bounds.size.height/hwm_plane_scale-target->strip_height)*.5);
        hwm_preserve_focus_window=target->id;hwm_preserve_focus_until=now+1;
        hwm_plane_transition_to(view,x,y,hwm_plane_scale,true);
    }
    return true;
}
#endif

static void hwm_plane_choose_window(struct view *view,struct window *target)
{
    if(!hwm_plane_window_selectable(view,target)) return;
#ifdef HWM_NATIVE_ZOOM
    hwm_zoom_cancel_native();
#endif
    hwm_plane_selecting=false; hwm_hold_focus();
    CGRect bounds=hwm_bounds(view);
    hwm_focus_queue_enqueue(&hwm_nav_window,&hwm_nav_pending,&hwm_nav_automatic,target->id,false); hwm_nav_time=hwm_now();
    hwm_last_input=hwm_now(); hwm_preserve_focus_window=target->id; hwm_preserve_focus_until=hwm_now()+1;
    hwm_feedback_focus(NULL,target);
    hwm_plane_transition_to(view,target->strip_world_x+(target->strip_width-bounds.size.width)*.5,
                           target->strip_world_y-fmax(0,(bounds.size.height-target->strip_height)*.5),1,true);
}
static void hwm_plane_choose_at(CGPoint point)
{
    struct view *view=hwm_view();
    if(hwm_plane_selecting) hwm_plane_choose_window(view,hwm_plane_window_at(view,point));
}
/* A three-finger pan has lifted. A moving release carries on briefly with
 * its own velocity, decaying exponentially (the critically damped camera
 * spring with matching initial velocity). At 100%, when the view would come
 * to rest near some window's centered view, the camera finishes centering
 * it instead. World geometry decides, not the pointer: the intent is the
 * view itself, and nothing here reads or reacts to hover. */
static bool hwm_plane_pan_release(struct view *view,HWMPlaneCamera start,HWMPlanePoint velocity)
{
    if(!view || hwm_plane_selecting || hwm_drag_window || hwm_edge_window) return false;
    double now=hwm_now();
    CGRect bounds=hwm_bounds(view);
    HWMPlaneCamera camera={hwm_offset(view,now),hwm_plane_camera_y(now),hwm_plane_scale};
    double omega=hwm_scroll_omega/fmax(.15,hwm_motion_scale);
    bool carries=hwm_pan_momentum && hwm_motion_scale>0;
    bool glide=carries && hypot(velocity.x,velocity.y)*camera.scale>=250;
    HWMPlanePoint fingers=velocity;
    if(!glide) velocity=(HWMPlanePoint){0,0};
    HWMPlaneCamera landing={camera.x+velocity.x/omega,camera.y+velocity.y/omega,camera.scale};
    bool actual=fabs(camera.scale-1)<=.001;
    if(actual) { landing.x=round(landing.x); landing.y=round(landing.y); }
    HWMPlanePoint target={landing.x,landing.y};
    bool centered=false;
    if(hwm_auto_center && actual) {
        HWMPlanePoint targets[64]; size_t count=0;
        for(struct window_node *n=window_node_find_first_leaf(view->root);n && count<64;n=window_node_find_next_leaf(n))
            for(int i=0;i<n->window_count && count<64;i++) {
                struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
                if(!hwm_plane_window_selectable(view,w)) continue;
                HWMPlaneRect r={w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height};
                if(hwm_plane_center_camera(r,bounds.size.width,bounds.size.height,&targets[count])) ++count;
            }
        long chosen=hwm_plane_auto_center(start,landing,targets,count,hwm_auto_center_radius);
        if(chosen>=0) { target=targets[chosen]; centered=true; }
    }
    if(!centered && !glide) return false;
    /* A slow pan into center hands its own speed to the centering spring
     * rather than stopping dead and starting again from rest. */
    if(centered && carries) velocity=fingers;
    hwm_hold_focus();
    // hwm_plane_set_camera's springs keep these as their initial velocities.
    hwm_scroll_current_velocity=velocity.x; hwm_plane_y_current_velocity=velocity.y;
    hwm_plane_set_camera(view,target.x,target.y,true);
    return true;
}
/* Settle the camera after a pan without activating a window or posting any
 * input. Empty canvas stays where the user left it. */
static void hwm_plane_magnet_at(struct view *view,CGPoint point,HWMPlaneCamera start)
{
    if(!view || !hwm_magnetic_centering || hwm_plane_selecting || hwm_drag_window || hwm_edge_window) return;
    struct window *target=window_manager_find_window_at_point(&g_window_manager,point);
    if(!hwm_plane_window_selectable(view,target)) return;
    CGRect bounds=hwm_bounds(view);
    HWMPlaneCamera camera={hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),hwm_plane_scale};
    HWMPlanePoint centered={target->strip_world_x+target->strip_width*.5-bounds.size.width/(2*hwm_plane_scale),
                            target->strip_world_y+target->strip_height*.5-bounds.size.height/(2*hwm_plane_scale)};
    HWMPlaneCamera next=hwm_plane_magnetic_camera(start,camera,centered);
    if(next.x==camera.x && next.y==camera.y) return;
    hwm_hold_focus();
    hwm_plane_transition_to(view,next.x,next.y,next.scale,true);
}
