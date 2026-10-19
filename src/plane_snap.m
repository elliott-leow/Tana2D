/* Compute magnets from the unmodified pointer proposal. The displayed
 * window can engage both axes without feeding that correction into the grab. */
static HWMPlaneRect *hwm_drag_snap_neighbors;
static size_t hwm_drag_snap_capacity;
static uint32_t *hwm_drag_snap_ids;
static uint32_t hwm_snap_window,hwm_snap_neighbor;
static int hwm_snap_axis,hwm_snap_side;
static size_t hwm_snap_contact_count;
static CGPoint hwm_snap_point;
/* Axes the engaged target actually moved; only these resist release. */
static bool hwm_snap_lock_x,hwm_snap_lock_y;
/* Command held while dragging places the window freely. */
static bool hwm_snap_free;
static uint64_t hwm_snap_engagements,hwm_snap_commits;
/* Engage within 12 screen points; once engaged, hold until 20. */
static const double HWMSnapEngage=12,HWMSnapRelease=20;
/* The magnet eases the window onto its landing rather than leaping there,
 * and eases it back to the pointer when it lets go, with this time constant:
 * an engagement is over in about a tenth of a second and reads as a settle,
 * not a jump. The pointer's own movement is never lagged: what is shown is
 * the pointer position plus the magnet's displacement, and only that
 * displacement eases. While held the window stays exactly on the landing,
 * however the pointer moves inside the magnet's reach. The seams and the
 * commit use the landing itself. */
#define HWM_SNAP_EASE_TAU .04
static CGPoint hwm_snap_shown,hwm_snap_offset; // Shown position; shown less the pointer's position.
static uint32_t hwm_snap_shown_for; static double hwm_snap_eased_time; static bool hwm_snap_easing,hwm_snap_was_snapped;
static CGPoint hwm_snap_ease(uint32_t wid,CGPoint raw,bool snapped,CGPoint landing,double now)
{
    double dt=fmax(0,now-hwm_snap_eased_time); hwm_snap_eased_time=now;
    if(hwm_snap_shown_for!=wid) { hwm_snap_offset=CGPointZero; hwm_snap_shown_for=wid; }
    double k=hwm_motion_scale<=0 ? 1 : 1-exp(-dt/HWM_SNAP_EASE_TAU), px=hwm_plane_scale*hwm_surface_scale;
    if(snapped) {
        // From where it is shown: held on the landing it stays there; just
        // engaged (or the landing moved) it eases over.
        if(!hwm_snap_was_snapped) hwm_snap_shown=CGPointMake(raw.x+hwm_snap_offset.x,raw.y+hwm_snap_offset.y);
        if(!CGPointEqualToPoint(hwm_snap_shown,landing)) {
            hwm_snap_shown.x+=(landing.x-hwm_snap_shown.x)*k; hwm_snap_shown.y+=(landing.y-hwm_snap_shown.y)*k;
            if(hypot(landing.x-hwm_snap_shown.x,landing.y-hwm_snap_shown.y)*px<.5) hwm_snap_shown=landing;
        }
        hwm_snap_easing=!CGPointEqualToPoint(hwm_snap_shown,landing);
        hwm_snap_offset=CGPointMake(hwm_snap_shown.x-raw.x,hwm_snap_shown.y-raw.y);
    } else {
        hwm_snap_offset.x*=1-k; hwm_snap_offset.y*=1-k;
        if(hypot(hwm_snap_offset.x,hwm_snap_offset.y)*px<.5) hwm_snap_offset=CGPointZero;
        hwm_snap_easing=!CGPointEqualToPoint(hwm_snap_offset,CGPointZero);
        hwm_snap_shown=CGPointMake(raw.x+hwm_snap_offset.x,raw.y+hwm_snap_offset.y);
    }
    hwm_snap_was_snapped=snapped;
    return hwm_snap_shown;
}
/* At a drag's start and end only: the magnet letting go mid-drag keeps the
 * shown position, which then eases back to the pointer. */
static void hwm_snap_ease_reset(void) { hwm_snap_shown_for=0; hwm_snap_offset=CGPointZero; hwm_snap_eased_time=hwm_now(); hwm_snap_easing=hwm_snap_was_snapped=false; }
static void hwm_drag_snap_reset(void)
{
    hwm_snap_window=0; hwm_snap_neighbor=0; hwm_snap_contact_count=0;
    hwm_snap_lock_x=hwm_snap_lock_y=false;
}

typedef struct {
    CGPoint point;
    uint32_t peer;
    int edge;
    size_t contacts;
    HWMPlaneSnapSeam seams[HWM_PLANE_SNAP_SEAMS];
    size_t seam_count;
} HWMDragSnap;

static bool hwm_drag_snap_proposal_at(struct view *view,struct window *moving,CGPoint raw,HWMDragSnap *out)
{
    if(!view || !moving || !out || hwm_snap_free || !isfinite(hwm_plane_scale) || hwm_plane_scale<=0) return false;
    size_t needed=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) needed+=n->window_count;
    if(needed>hwm_drag_snap_capacity) {
        HWMPlaneRect *next=realloc(hwm_drag_snap_neighbors,needed*(sizeof(*next)+sizeof(uint32_t)));
        if(!next) return false;
        hwm_drag_snap_neighbors=next; hwm_drag_snap_capacity=needed;
        hwm_drag_snap_ids=(uint32_t *)(next+needed);
    }
    size_t count=0; HWMPlaneSnapTarget preferred={0}; bool has_preferred=false;
    CGRect bounds=hwm_bounds(view),screen=hwm_screen(view);
    double now=hwm_now(),camera_x=hwm_offset(view,now),camera_y=hwm_plane_camera_y(now);
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==moving || !w->strip_initialized || w->strip_close_ghost || w->strip_close_pending ||
           w->application->is_hidden || window_check_flag(w,WINDOW_MINIMIZE) || hwm_workflow_tab_hidden(w)) continue;
        CGRect visible=CGRectMake(bounds.origin.x+(w->strip_world_x-camera_x)*hwm_plane_scale,
                                  bounds.origin.y+(w->strip_world_y-camera_y)*hwm_plane_scale,
                                  w->strip_width*hwm_plane_scale,w->strip_height*hwm_plane_scale);
        if(!CGRectIntersectsRect(visible,screen)) continue;
        if(hwm_snap_window==moving->id && hwm_snap_neighbor==w->id) {
            preferred=(HWMPlaneSnapTarget){{hwm_snap_point.x,hwm_snap_point.y},count,hwm_snap_axis,hwm_snap_side,0}; has_preferred=true;
        }
        hwm_drag_snap_ids[count]=w->id;
        hwm_drag_snap_neighbors[count++]=(HWMPlaneRect){w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height};
    }
    HWMPlaneRect rect={raw.x,raw.y,moving->strip_width,moving->strip_height};
    double gap=fmax(0,view->window_gap),range=HWMSnapEngage/hwm_plane_scale,release=HWMSnapRelease/hwm_plane_scale;
    HWMPlaneSnapTarget choice; bool kept=false;
    if(!hwm_plane_snap_choose_held(rect,hwm_drag_snap_neighbors,count,gap,range,release,
        has_preferred?&preferred:NULL,hwm_snap_lock_x,hwm_snap_lock_y,&choice,&kept)) return false;
    HWMPlanePoint target=choice.point;
    /* Bound the actual rounded helper submission per axis too, not only
     * world-space arithmetic, so rounding cannot exceed the screen limit. */
    double dx=round(bounds.origin.x+(target.x-camera_x)*hwm_plane_scale)-
              round(bounds.origin.x+(raw.x-camera_x)*hwm_plane_scale);
    double dy=round(bounds.origin.y+(target.y-camera_y)*hwm_plane_scale)-
              round(bounds.origin.y+(raw.y-camera_y)*hwm_plane_scale);
    if(fmax(fabs(dx),fabs(dy))>(kept?HWMSnapRelease:HWMSnapEngage)) return false;
    out->point=CGPointMake(target.x,target.y);
    out->peer=hwm_drag_snap_ids[choice.neighbor];
    out->edge=choice.axis*2+choice.side;
    out->contacts=choice.contact_count;
    out->seam_count=hwm_plane_snap_seams(rect,hwm_drag_snap_neighbors,count,gap,kept?release:range,target,
                                         out->seams,HWM_PLANE_SNAP_SEAMS);
    return true;
}
static bool hwm_drag_snap_target(struct view *view,struct window *moving,CGPoint *point)
{
    HWMDragSnap snap;
    if(!moving || !hwm_drag_snap_proposal_at(view,moving,CGPointMake(moving->strip_world_x,moving->strip_world_y),&snap)) return false;
    if(point) *point=snap.point;
    return true;
}
static void hwm_drag_preview_apply(struct view *view,struct window *window,CGPoint raw,const HWMDragSnap *snap)
{
    if(hwm_drag_window!=window->id || !snap) {
        hwm_drag_snap_reset(); hwm_preview_hide_immediately(); return;
    }
    int edge=snap->edge;
    bool engaged=hwm_snap_window==window->id && hwm_snap_neighbor;
    /* Tick once per new attachment: a new primary edge, or an extra contact
     * gained while sliding into a corner. Holding and sliding stay silent. */
    bool changed=!engaged || hwm_snap_neighbor!=snap->peer ||
                 hwm_snap_axis!=edge/2 || hwm_snap_side!=edge%2 || snap->contacts>hwm_snap_contact_count;
    /* An axis stays locked while it keeps its landing coordinate, even if the
     * raw pointer momentarily lands exactly on it. */
    hwm_snap_lock_x=snap->point.x!=raw.x || (engaged && hwm_snap_lock_x && snap->point.x==hwm_snap_point.x);
    hwm_snap_lock_y=snap->point.y!=raw.y || (engaged && hwm_snap_lock_y && snap->point.y==hwm_snap_point.y);
    hwm_snap_window=window->id; hwm_snap_neighbor=snap->peer;
    hwm_snap_axis=edge/2; hwm_snap_side=edge%2; hwm_snap_point=snap->point;
    hwm_snap_contact_count=snap->contacts;
    if(changed) { ++hwm_snap_engagements; hwm_haptic(0); }
    CGRect bounds=hwm_bounds(view); double now=hwm_now(),x=hwm_offset(view,now),y=hwm_plane_camera_y(now);
    CGRect shown=CGRectMake(round(bounds.origin.x+(snap->point.x-x)*hwm_plane_scale),
                            round(bounds.origin.y+(snap->point.y-y)*hwm_plane_scale),
                            round(window->strip_width*hwm_plane_scale),round(window->strip_height*hwm_plane_scale));
    HWMPlaneSnapSeam seams[HWM_PLANE_SNAP_SEAMS];
    for(size_t i=0;i<snap->seam_count;i++)
        seams[i]=(HWMPlaneSnapSeam){snap->seams[i].edge,round(snap->seams[i].from*hwm_plane_scale),round(snap->seams[i].to*hwm_plane_scale)};
    // Every docked edge is marked at once, anchored without a lagging spring.
    hwm_preview_snap_show(shown,seams,snap->seam_count,fmax(0,view->window_gap)*hwm_plane_scale);
}
static void hwm_drag_preview_update_at(struct view *view,struct window *window,CGPoint raw)
{
    HWMDragSnap snap;
    bool valid=hwm_drag_snap_proposal_at(view,window,raw,&snap);
    hwm_drag_preview_apply(view,window,raw,valid?&snap:NULL);
}
static void hwm_drag_preview_update(struct view *view,struct window *window)
{
    hwm_drag_preview_update_at(view,window,CGPointMake(window->strip_world_x,window->strip_world_y));
}
static void hwm_drag_snap_commit(struct view *view,struct window *window);
