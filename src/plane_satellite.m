/* Secondary windows travel with the window they belong to.
 *
 * Dialogs, utility panels, attached child windows and modal windows are not
 * tiles (window_admission.h), but they are not part of the screen either:
 * each keeps its place beside its owner tile as the camera pans and zooms,
 * the owner is dragged, or the owner moves to another spot. A satellite
 * records its offset from the owner's world origin and is drawn there with
 * the owner's scale: at 100% its native frame rides in the frame's plane
 * transaction like a tile's, otherwise a compositor transform projects it.
 * At rest at 100% an Accessibility move gives AppKit the same frame, so its
 * hover tracking, cursor queries and popups agree with what is on screen.
 * The user (or the application) moving it records a new offset.
 *
 * The owner is the window's WindowServer parent when it has one; otherwise
 * the application's tile under it, preferring the focused one. */

static bool hwm_satellite_valid(struct window *w)
{
    return w->is_root && window_check_flag(w,WINDOW_FLOAT) && !window_check_flag(w,WINDOW_MINIMIZE) &&
           !window_check_flag(w,WINDOW_FULLSCREEN) && !window_check_flag(w,WINDOW_STICKY) && !w->strip_sticky &&
           !w->application->is_hidden && !window_manager_find_managed_window(&g_window_manager,w) &&
           window_manager_is_secondary_window(w);
}

/* Where the owner tile is drawn now. Off screen during travel the renderer
 * may not refresh its record, so it is projected from the world instead. */
static CGPoint hwm_satellite_base(struct view *view,struct window *owner,double now,double *scale)
{
    *scale=owner->strip_last_plane_scale>0 ? owner->strip_last_plane_scale : hwm_plane_scale;
    if(!owner->strip_offscreen && !CGRectIsNull(owner->strip_last_frame)) return owner->strip_last_frame.origin;
    CGRect bounds=hwm_bounds(view); *scale=hwm_plane_scale;
    return CGPointMake(round(hwm_plane_project_physical(owner->strip_world_x,hwm_offset(view,now),bounds.origin.x,*scale)),
                       round(hwm_plane_project_physical(owner->strip_world_y,hwm_plane_camera_y(now),bounds.origin.y,*scale)));
}

static struct window *hwm_satellite_owner_for(struct window *w,struct view *view,CGRect frame)
{
    // An attached window belongs to its parent, or to whatever that belongs to.
    struct window *p=window_manager_find_window(&g_window_manager,window_parent(w->id));
    for(int depth=0;p && depth<4 && window_manager_find_managed_window(&g_window_manager,p)!=view;depth++)
        p=p->strip_owner ? window_manager_find_window(&g_window_manager,p->strip_owner) : NULL;
    if(p) return p;
    struct window *focused=window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    struct window *best=NULL; double best_area=0;
    CGPoint center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *t=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!t || t->application!=w->application || t->strip_close_ghost || hwm_workflow_tab_hidden(t) || CGRectIsNull(t->strip_last_frame)) continue;
        double scale=t->strip_last_plane_scale>0 ? t->strip_last_plane_scale : 1;
        CGRect shown=t->strip_last_frame; shown.size.width*=scale; shown.size.height*=scale;
        if(!CGRectContainsPoint(shown,center)) continue;
        CGRect overlap=CGRectIntersection(shown,frame);
        double area=(CGRectIsNull(overlap) ? 0 : overlap.size.width*overlap.size.height)+(t==focused ? 1e9 : 0);
        if(area>best_area) { best_area=area; best=t; }
    }
    if(best) return best;
    // A dialog opened away from its window still belongs to the one in use.
    return focused && focused->application==w->application && window_manager_find_managed_window(&g_window_manager,focused)==view ? focused : NULL;
}

/* A secondary window found an owner: from now on it keeps its place there. */
static void hwm_satellite_adopt(struct window *w)
{
    struct view *view=hwm_view();
    if(!hwm_ready || !view || w->strip_owner || !hwm_satellite_valid(w)) return;
    // Menus, tooltips and other raised surfaces are the application's to place.
    if(window_level(w->id)>CGWindowLevelForKey(kCGModalPanelWindowLevelKey)) return;
    CGRect native=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&native)!=kCGErrorSuccess || CGRectIsNull(native)) return;
    struct window *owner=hwm_satellite_owner_for(w,view,native);
    if(!owner || owner==w) return;
    double scale; CGPoint base=hwm_satellite_base(view,owner,hwm_now(),&scale);
    w->strip_owner=owner->id;
    w->strip_owner_delta=CGPointMake((native.origin.x-base.x)/scale,(native.origin.y-base.y)/scale);
    w->strip_sat_shown=native.origin; w->strip_sat_scale=scale;
    // AppKit already has this frame unless the window is drawn transformed.
    w->strip_sat_synced=!w->strip_plane_scaled; w->strip_sat_moved=hwm_now();
    debug("tana2d: %d follows %d at %.0f,%.0f\n",w->id,owner->id,w->strip_owner_delta.x,w->strip_owner_delta.y);
    hwm_wake();
}

static void hwm_satellite_release(struct window *w)
{
    if(!w->strip_owner) return;
    w->strip_owner=0; w->strip_native_riding=false;
    if(w->strip_plane_scaled) (void)hwm_plane_reset_transform(w);
    if(w->strip_offscreen) hwm_visibility_set(w,false,CGRectNull);
}

/* A WindowServer parent can be attached after the window is first seen.
 * Such a window is an attached child: it leaves the plane and follows. */
static void hwm_satellite_refresh_parent(struct window *w,uint32_t parent)
{
    if(w->is_child || !parent || !w->is_root) return;
    w->is_child=true;
    struct view *view=window_manager_find_managed_window(&g_window_manager,w);
    if(view) {
        hwm_plane_abort_interaction(w,HWM_PLANE_INTERRUPT_UNMANAGE);
        (void)hwm_plane_reset_transform(w);
        window_manager_make_window_floating(&g_space_manager,&g_window_manager,w,true,true);
        if(w->strip_offscreen) hwm_visibility_set(w,false,CGRectNull);
        hwm_layout(view,true);
    } else if(!window_check_flag(w,WINDOW_FLOAT)) {
        window_set_flag(w,WINDOW_FLOAT);
    }
    scripting_addition_set_layer(w->id,LAYER_ABOVE);
    hwm_satellite_adopt(w);
}

/* Once a frame, after the tiles have been drawn. */
static bool hwm_render_satellites(struct view *view,double now)
{
    bool active=false,batched=false;
    struct window *resets[16]; int reset_count=0;
    CGRect bounds=hwm_bounds(view),screen=hwm_screen(view);
    bool resting=hwm_plane_scale==1 && !hwm_view_in_motion(view,now);
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_owner) continue;
        struct window *owner=window_manager_find_window(&g_window_manager,w->strip_owner);
        if(!hwm_satellite_valid(w) || !owner || window_manager_find_managed_window(&g_window_manager,owner)!=view ||
           !owner->strip_initialized || owner->strip_close_ghost) { hwm_satellite_release(w); continue; }
        // The user dragging it, or a rule animating it, owns its position.
        if(g_mouse_state.window==w || w->strip_float_animating) { w->strip_sat_synced=true; w->strip_sat_moved=now; continue; }
        CGRect native=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&native)!=kCGErrorSuccess || CGRectIsNull(native)) continue;
        double scale; CGPoint base=hwm_satellite_base(view,owner,now,&scale);
        bool owner_moving=hwm_drag_window==owner->id || now-owner->strip_start<hwm_duration;
        /* Moved natively since it was last placed and settled (dragged, or
         * repositioned by its application): that is its new place. */
        if(resting && !owner_moving && !w->strip_plane_scaled && w->strip_sat_synced && now-w->strip_sat_moved>.3 &&
           !hwm_zoom_native_busy(w->id) &&
           (fabs(native.origin.x-w->strip_sat_shown.x)>1.5 || fabs(native.origin.y-w->strip_sat_shown.y)>1.5)) {
            w->strip_owner_delta=CGPointMake(native.origin.x-base.x,native.origin.y-base.y);
            w->strip_sat_shown=native.origin;
        }
        CGPoint to=CGPointMake(round(base.x+w->strip_owner_delta.x*scale),round(base.y+w->strip_owner_delta.y*scale));
        CGRect frame=CGRectMake(to.x,to.y,native.size.width*scale,native.size.height*scale);
        bool hidden=owner->strip_offscreen || !CGRectIntersectsRect(frame,screen);
        // Above the menu bar AppKit would push a native frame back down.
        bool ride=scale==1 && !hidden && to.y>=screen.origin.y-.5 && scripting_addition_plane_native_supported();
        bool moved=!CGPointEqualToPoint(to,w->strip_sat_shown) || w->strip_sat_scale!=scale;
        if(!hidden && (moved || (ride ? w->strip_plane_scaled : !w->strip_plane_scaled))) {
            if(!batched) { hwm_batch_begin_plane(); batched=true; }
            if(ride ? !scripting_addition_set_plane_native(w->id,to.x,to.y) : !scripting_addition_set_plane_transform(w->id,to.x,to.y,scale)) {
                // Usually a window closing under us, not a lost helper: the
                // tiles' own commands report a helper that stopped answering.
                ++hwm_move_failures; w->strip_owner=0; continue;
            }
            w->strip_plane_scaled=!ride; w->strip_native_riding=ride;
            w->strip_sat_shown=to; w->strip_sat_scale=scale; w->strip_sat_synced=false; w->strip_sat_moved=now; w->strip_sat_failures=0;
        }
        if(hidden!=w->strip_offscreen) {
            if(!batched) { hwm_batch_begin_plane(); batched=true; }
            hwm_visibility_set(w,hidden,frame);
            if(hidden) { w->strip_sat_shown=CGPointMake(NAN,NAN); w->strip_sat_synced=true; }
        }
        if(hidden || w->strip_sat_synced) continue;
        if(!resting || owner_moving || now-w->strip_sat_moved<.1) { active=true; continue; }
        // At rest: give AppKit the frame that is shown.
        CGRect accepted=CGRectNull;
        int state=hwm_zoom_native_position(w,to,CGSizeZero,bounds.origin,&accepted);
        if(state==0) continue; // The placement wakes the clock when it lands.
        // A placement cancelled by input is tried again; AppKit's top-edge
        // clamp fails every time and leaves the presentation transform.
        if(state<0 && ++w->strip_sat_failures<3) { w->strip_sat_moved=now; active=true; continue; }
        w->strip_sat_failures=0; w->strip_sat_synced=true; w->strip_native_riding=false;
        if(state>0 && w->strip_plane_scaled && reset_count<16) resets[reset_count++]=w;
    })
    if(batched) hwm_batch_end();
    for(int i=0;i<reset_count;i++) (void)hwm_plane_reset_transform(resets[i]);
    return active;
}
