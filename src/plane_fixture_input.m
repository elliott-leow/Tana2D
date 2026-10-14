/* Deterministic integration seam for disposable fixture windows only. Events
 * enter the production controllers but are never posted to the OS input stream. */
static uint64_t hwm_fixture_pointer_timestamp;
static CGEventTimestamp hwm_fixture_pointer_next_timestamp(void)
{
    if(++hwm_fixture_pointer_timestamp==0) ++hwm_fixture_pointer_timestamp;
    return hwm_fixture_pointer_timestamp;
}
static void hwm_fixture_pointer(FILE *rsp,char *message)
{
    double id,mode,phase,x,y;
    if(!hwm_number(get_token(&message),&id) || !hwm_number(get_token(&message),&mode) ||
       !hwm_number(get_token(&message),&phase) || !hwm_number(get_token(&message),&x) || !hwm_number(get_token(&message),&y) ||
       id<1 || id>UINT32_MAX || mode<0 || mode>4 || phase<0 || phase>2) { daemon_fail(rsp,"expected fixture id, mode 0..4, phase 0..2, x, y\n"); return; }
    struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)id);
    struct view *view=w?window_manager_find_managed_window(&g_window_manager,w):NULL;
    if(!w || !view || !w->application->name || strcmp(w->application->name,"Tana2DFixture") || hwm_paused || hwm_suspended) {
        daemon_fail(rsp,"pointer replay requires a managed Tana2DFixture window\n"); return;
    }
    CGEventType type=phase==0?kCGEventLeftMouseDown:phase==1?kCGEventLeftMouseDragged:kCGEventLeftMouseUp;
    CGPoint point=CGPointMake(x,y); CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
    if(!event) { daemon_fail(rsp,"cannot allocate fixture event\n"); return; }
    /* Synthetic CGEvents default to timestamp zero, which has no press
     * identity after more than one replay. Give every fixture sample a stable
     * local order so exact-generation lookup exercises the production path. */
    CGEventSetTimestamp(event,hwm_fixture_pointer_next_timestamp());
    hwm_pointer_sample_event(type,event);
    if(mode==2 || mode==3) {
        HWMPlaneResizeInput *input=malloc(sizeof(*input));
        if(input) {
            *input=(HWMPlaneResizeInput){type,point,w->id,mode==2?HANDLE_RIGHT|HANDLE_BOTTOM:HANDLE_LEFT|HANDLE_TOP,hwm_pointer_sample_generation_for_event(type),w->strip_last_offset,w->strip_last_camera_y,w->strip_last_plane_scale};
            atomic_store(&hwm_resize_captured,phase!=2);
            hwm_plane_resize_input(input); hwm_plane_resize_tick(view,hwm_now());
        }
    } else if(mode==1) {
        if(phase==0) {
            hwm_plane_pointer_finish(false); hwm_plane_pick_window=w->id; hwm_plane_pick_origin=point;
            hwm_plane_pick_automatic=true;
            hwm_plane_camera_stop(view,hwm_now());
            hwm_plane_set_camera(view,hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),false);
        } else hwm_plane_pointer(type,point);
    } else {
        if(phase==0) {
            g_mouse_state.window=w; g_mouse_state.down_location=point; g_mouse_state.window_frame=w->frame;
            g_mouse_state.current_action=mode==4?MOUSE_MODE_NONE:MOUSE_MODE_MOVE; hwm_drag_cancelled=false;
            if(mode==4) {
                hwm_mouse_pointer_button=kCGMouseButtonLeft;
                hwm_mouse_pointer_generation=hwm_pointer_sample_generation_for_event_ref(event);
                hwm_drag_point=point;
                hwm_drag_started(w);
                if(hwm_drag_window==w->id) hwm_drag_pointer_generation=hwm_mouse_pointer_generation;
            }
        } else if(phase==1) horizontal_drag(event);
        else { horizontal_drop(w,point); g_mouse_state.window=NULL; g_mouse_state.current_action=MOUSE_MODE_NONE; }
    }
    CFRelease(event); hwm_wake(); fprintf(rsp,"{}\n");
}
