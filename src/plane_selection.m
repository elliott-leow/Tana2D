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
    }
#endif
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

#ifdef HWM_NATIVE_ZOOM
typedef struct { uint32_t wid; double started,issued; bool workspace; } HWMHoverTiming;
static HWMHoverTiming hwm_hover_timings[128];
static unsigned hwm_hover_timing_count;
static HWMPlaneHoverIntent hwm_hover_intent;
static uint32_t hwm_zoom_hover_pending,hwm_zoom_input_window;
static CGPoint hwm_zoom_hover_point;
static double hwm_zoom_hover_started;

static void hwm_hover_focus_immediate(struct window *target,double started)
{
    double now=hwm_now();
    hwm_focus_queue_clear(&hwm_nav_window,&hwm_nav_pending,&hwm_nav_automatic);
    hwm_last_input=now;hwm_focus_guard=false;hwm_focus_after_scroll=false;
    hwm_preserve_focus_window=target->id;hwm_preserve_focus_until=now+1;
    horizontal_hover_received(target);
    window_manager_focus_window_immediate(&target->application->psn,target->id,target->ref);
    hwm_hover_timings[hwm_hover_timing_count++%128]=(HWMHoverTiming){target->id,started,hwm_now(),false};
}

/* Set by camera motion at 100%; consumed by the first resting native frame. */
static bool hwm_zoom_rest_focus_armed;
static void hwm_zoom_rest_focus(struct view *view)
{
    if(!hwm_zoom_rest_focus_armed) return;
    hwm_zoom_rest_focus_armed=false;
    if(!view || g_window_manager.ffm_mode==FFM_DISABLED || hwm_plane_pointer_owned() ||
       g_mouse_state.window || menu_focus_suppressed() || popup_focus_suppressed()) return;
    CGPoint cursor;
    if(SLSGetCurrentCursorLocation(g_connection,&cursor)!=kCGErrorSuccess || hwm_plane_controls_hit(cursor) ||
       !hwm_zoom_workspace_contains(cursor)) return;
    struct window *w=hwm_plane_window_at(view,cursor);
    if(!w || !window_manager_is_window_eligible(w) || w->id==g_window_manager.focused_window_id) return;
    hwm_zoom_hover_pending=w->id;hwm_zoom_hover_point=cursor;hwm_zoom_hover_started=hwm_now();
}

static void hwm_zoom_hover_tick(void)
{
    if(!hwm_zoom_hover_pending)return;
    if(hwm_paused || hwm_suspended || g_window_manager.ffm_mode==FFM_DISABLED ||
       __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) {hwm_zoom_hover_pending=0;return;}
    struct window *w=window_manager_find_window(&g_window_manager,hwm_zoom_hover_pending);
    if(!hwm_plane_window_selectable(hwm_view(),w)) {hwm_zoom_hover_pending=0;return;}
    // At 100% wait for the native frame to land; a zoomed-out window is
    // always presented through its transform and can take focus at once.
    if(hwm_plane_scale==1 && w->strip_plane_scaled)return;
    if(w->id!=g_window_manager.focused_window_id)hwm_hover_focus_immediate(w,hwm_zoom_hover_started);
    hwm_zoom_hover_pending=0;
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
    struct window *target=hwm_plane_window_at(view,point);
    if(!target || !window_manager_is_window_eligible(target) || menu_focus_suppressed() || popup_focus_suppressed()) { atomic_fetch_add(&window_manager_hover_epoch,1);hwm_zoom_hover_pending=0;hwm_hover_intent=(HWMPlaneHoverIntent){0};return true; }
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
    // A clipped titlebar can never reach its projected native origin. It
    // must still accept focus immediately, without waiting forever for AX.
    if(hwm_plane_scale==1 && target->strip_plane_scaled &&
       target->strip_last_frame.origin.y<hwm_screen(view).origin.y &&
       target->id!=g_window_manager.focused_window_id &&
       !(target->id==hwm_preserve_focus_window && now-hwm_hover_time<.025))hwm_hover_focus_immediate(target,started);
    // A window still being aligned natively is focused once it lands.
    if(hwm_plane_scale==1 && target->strip_plane_scaled) {
        if(hwm_zoom_hover_pending!=target->id)hwm_zoom_hover_started=started;
        hwm_zoom_hover_pending=target->id;hwm_zoom_hover_point=point;hwm_wake();
    } else hwm_zoom_hover_pending=0;
    // Hover never changes zoom. Zoomed out, the hovered window takes focus
    // (and the border) at once, exactly as a native window does at 100%.
    if((hwm_plane_scale<1 || !target->strip_plane_scaled) &&
       target->id!=g_window_manager.focused_window_id &&
       !(target->id==hwm_preserve_focus_window && now-hwm_hover_time<.025)) hwm_hover_focus_immediate(target,started);
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
    bool glide=hwm_pan_momentum && hwm_motion_scale>0 && hypot(velocity.x,velocity.y)*camera.scale>=250;
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
