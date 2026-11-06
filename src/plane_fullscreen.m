/* Native fullscreen.
 *
 * macOS gives a fullscreen window a Space of its own, sized to the display.
 * The plane lets it go there whole: its tile leaves the plane, so nothing
 * reserves, resizes, moves or transforms the fullscreen frame, and the tile's
 * world rect is kept so that leaving fullscreen puts the window back where it
 * was. While that Space is in front the plane cannot be seen, and trackpad
 * gestures and the pointer belong to macOS and the application
 * (hwm_plane_hidden): a three-finger swipe goes back to the desktop, a pinch
 * zooms the page, and Mission Control opens as usual.
 *
 * AppKit sends no fullscreen notification of its own; entering and leaving
 * are resizes. The renderer absorbs its tiles' resize notifications (nearly
 * all are echoes of its own requests), so a tile is asked about fullscreen
 * only when its frame could be a fullscreen one: it covers its display, or it
 * has left the plane's Space. The Space change and the housekeeping sweep
 * check again, in case every notification was absorbed. */

/* Whether a native frame spans the whole of its display, as a fullscreen
 * window does. A notched display keeps fullscreen windows below the camera
 * housing, so the height may fall a little short. */
static bool hwm_frame_covers_display(CGRect frame)
{
    if(CGRectIsNull(frame) || !(frame.size.width>0) || !(frame.size.height>0)) return false;
    CGDirectDisplayID display=0; uint32_t count=0;
    CGPoint center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
    if(CGGetDisplaysWithPoint(center,1,&display,&count)!=kCGErrorSuccess || !count) return false;
    CGRect screen=CGDisplayBounds(display);
    return frame.size.width>=screen.size.width-1 && frame.size.height>=screen.size.height*.85;
}

/* A display-sized size the application has already said is an ordinary
 * window (zoomed with Option and the green button, say). */
static bool hwm_fullscreen_checked_size(struct window *w,CGSize size)
{
    return fabs(w->strip_fullscreen_checked.width-size.width)<.5 && fabs(w->strip_fullscreen_checked.height-size.height)<.5;
}

/* Cheap WindowServer checks, before any Accessibility round trip. */
static bool hwm_fullscreen_frame_possible(struct window *w)
{
    if(hwm_window_left_strip(w)) return true;
    CGRect actual=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&actual)!=kCGErrorSuccess || CGRectIsNull(actual)) return false;
    return hwm_frame_covers_display(actual) && !hwm_fullscreen_checked_size(w,actual.size);
}

/* The renderers run inside a frame and must not make Accessibility round
 * trips or untile. A display-sized frame they meet is queued and asked
 * about once the frame's batch is released (hwm_fullscreen_probe_drain);
 * until then it is neither adopted as the tile's size nor placed. */
static uint32_t hwm_fullscreen_probes[8];
static int hwm_fullscreen_probe_count;
static bool hwm_fullscreen_frame_adoptable(struct window *w,CGRect native)
{
    if(!hwm_frame_covers_display(native) || hwm_fullscreen_checked_size(w,native.size)) { w->strip_fullscreen_probe=false; return true; }
    if(!w->strip_fullscreen_probe && hwm_fullscreen_probe_count<8) {
        hwm_fullscreen_probes[hwm_fullscreen_probe_count++]=w->id;
        w->strip_fullscreen_probe=true;
    }
    return !w->strip_fullscreen_probe;
}

/* The tile leaves the plane, keeping the world rect it returns to. */
static void hwm_fullscreen_leave(struct window *w,struct view *view)
{
    window_set_flag(w,WINDOW_FULLSCREEN);
    if(!w->strip_fullscreen_away)
        w->strip_fullscreen_world=CGRectMake(w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height);
    w->strip_fullscreen_away=true;
    hwm_plane_abort_interaction(w,HWM_PLANE_INTERRUPT_FULLSCREEN);
    // A zoomed-out tile must not carry its scale onto the fullscreen Space.
    (void)hwm_plane_reset_transform(w);
    w->strip_size_pending=false; w->strip_native_resize_pending=false; w->strip_native_move_pending=false;
    w->strip_fullscreen_probe=false;
    // Leaving fullscreen must read as a change of frame to the engine.
    CGRect actual=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&actual)==kCGErrorSuccess && !CGRectIsNull(actual)) w->frame=actual;
    if(view) {
        space_manager_untile_window(view,w);
        window_manager_remove_managed_window(&g_window_manager,w->id);
        hwm_layout(view,true);
    }
    debug("tana2d: %d entered native fullscreen; its tile is held at %.0f,%.0f\n",w->id,
          w->strip_fullscreen_world.origin.x,w->strip_fullscreen_world.origin.y);
    hwm_wake();
}

/* Called for a managed tile whose frame changed. True when it has gone into
 * native fullscreen and has been handed to macOS. */
static bool hwm_fullscreen_began(struct window *w,struct view *view)
{
    if(!w || !view || view->layout!=VIEW_STRIP || w->strip_fullscreen_away) return false;
    if(!hwm_fullscreen_frame_possible(w) || !window_is_fullscreen(w)) return false;
    hwm_fullscreen_leave(w,view);
    return true;
}

static void hwm_fullscreen_probe_drain(void)
{
    uint32_t probes[8]; int count=hwm_fullscreen_probe_count;
    memcpy(probes,hwm_fullscreen_probes,sizeof(*probes)*count); hwm_fullscreen_probe_count=0;
    for(int i=0;i<count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,probes[i]);
        if(!w || !w->strip_fullscreen_probe) continue;
        w->strip_fullscreen_probe=false;
        struct view *view=window_manager_find_managed_window(&g_window_manager,w);
        if(!view || hwm_fullscreen_began(w,view)) continue;
        // An ordinary window that happens to fill the display: adopt its size.
        CGRect actual=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&actual)==kCGErrorSuccess && !CGRectIsNull(actual) && !hwm_window_left_strip(w))
            w->strip_fullscreen_checked=actual.size;
        w->strip_transform_dirty=true;
    }
    hwm_wake();
}

/* The window is back on the plane's Space as an ordinary window: its tile
 * returns to the world rect it left, at the size AppKit restored, and comes
 * into view if it has focus. Called once the engine has tiled it again. */
static void horizontal_fullscreen_exited(struct window *w)
{
    if(!w || !w->strip_fullscreen_away) return;
    w->strip_fullscreen_away=false;
    if(!hwm_ready) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,w);
    if(!view || view->layout!=VIEW_STRIP) return;
    CGRect world=w->strip_fullscreen_world;
    if(isfinite(world.origin.x) && isfinite(world.origin.y)) { w->strip_world_x=world.origin.x; w->strip_world_y=world.origin.y; }
    if(world.size.width>=100 && world.size.height>=100) { w->strip_width=world.size.width; w->strip_height=world.size.height; }
    w->strip_full_width=false;
    // Adopt the windowed size AppKit restored once it has landed.
    w->strip_native_resize_pending=true; w->strip_native_resize_until=hwm_now()+.3;
    w->strip_transform_dirty=true;
    hwm_layout(view,true);
    if(w->id==g_window_manager.focused_window_id) horizontal_focused(w,view);
    debug("tana2d: %d left native fullscreen\n",w->id);
    hwm_wake();
}

/* A window whose leaving was not seen by its resize notification (the
 * attribute can still read fullscreen when the frame changes back). */
static void hwm_fullscreen_return(struct window *w)
{
    if(!w->strip_fullscreen_away || !window_check_flag(w,WINDOW_FULLSCREEN) || !hwm_space) return;
    if(window_space(w->id)!=hwm_space || window_is_fullscreen(w)) return;
    window_clear_flag(w,WINDOW_FULLSCREEN);
    if(window_manager_should_manage_window(w) && !window_manager_find_managed_window(&g_window_manager,w)) {
        struct view *view=space_manager_tile_window_on_space(&g_space_manager,w,hwm_space);
        window_manager_add_managed_window(&g_window_manager,w,view);
    }
    horizontal_fullscreen_exited(w);
}

/* Tiles already in fullscreen on the Space now in front, and windows back
 * from it. Space changes are rare; each asks WindowServer per window. */
static void hwm_fullscreen_scan(bool hidden)
{
    struct view *view=hwm_view();
    enum { HWM_FULLSCREEN_SCAN_MAX=256 };
    uint32_t ids[HWM_FULLSCREEN_SCAN_MAX]; int count=0;
    table_for(struct window *w,g_window_manager.window, {
        if(count<HWM_FULLSCREEN_SCAN_MAX && (w->strip_fullscreen_away || (hidden && view && window_manager_find_managed_window(&g_window_manager,w)==view)))
            ids[count++]=w->id;
    })
    for(int i=0;i<count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,ids[i]);
        if(!w) continue;
        if(w->strip_fullscreen_away) hwm_fullscreen_return(w);
        else if(view && hwm_window_left_strip(w) && window_is_fullscreen(w)) hwm_fullscreen_leave(w,view);
    }
}

/* SPACE_CHANGED, on the event loop. */
static void hwm_fullscreen_space_changed(void)
{
    bool hidden=hwm_space && !space_is_visible(hwm_space);
    bool was=atomic_exchange(&hwm_plane_hidden,hidden);
    if(hidden && !was) {
        // Nothing the plane was doing with the pointer outlives this.
        hwm_workspace_cancel();
        hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_FULLSCREEN);
        hwm_menu_status();
    }
    hwm_fullscreen_scan(hidden);
}

/* The housekeeping sweep, twice a second at rest. */
static void hwm_fullscreen_sweep(void)
{
    if(hwm_space) {
        bool hidden=!space_is_visible(hwm_space);
        if(atomic_load(&hwm_plane_hidden)!=hidden) { hwm_fullscreen_space_changed(); return; }
    }
    uint32_t away[8]; int count=0;
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_fullscreen_away && count<8) away[count++]=w->id;
    })
    for(int i=0;i<count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,away[i]);
        if(w) hwm_fullscreen_return(w);
    }
}

/* "fullscreen" (F11): the focused window enters or leaves native fullscreen,
 * exactly as its green button or View > Enter Full Screen would. */
static void hwm_fullscreen_toggle(void)
{
    struct window *w=window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    if(!w || !w->ref) { hwm_hud(@"No window to make full screen"); return; }
    Boolean settable=false;
    if(AXUIElementIsAttributeSettable(w->ref,kAXFullscreenAttribute,&settable)!=kAXErrorSuccess || !settable) {
        hwm_hud(@"This window has no full screen mode"); return;
    }
    bool entering=!window_is_fullscreen(w);
    if(entering && window_manager_find_managed_window(&g_window_manager,w)) (void)hwm_plane_reset_transform(w);
    AXError error=AXUIElementSetAttributeValue(w->ref,kAXFullscreenAttribute,entering?kCFBooleanTrue:kCFBooleanFalse);
    if(error!=kAXErrorSuccess) hwm_hud(entering ? @"Could not enter full screen" : @"Could not leave full screen");
}
