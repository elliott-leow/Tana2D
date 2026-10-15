/* A held window follows the pointer exactly. Only its drop proposal is
 * magnetized; releasing near a neighbor commits that proposal. */
static HWMPlaneRect *hwm_drag_snap_neighbors;
static size_t hwm_drag_snap_capacity;
static uint32_t *hwm_drag_snap_ids;
static uint32_t hwm_snap_window,hwm_snap_neighbor;
static int hwm_snap_axis,hwm_snap_side;
static CGPoint hwm_snap_point;
static uint64_t hwm_snap_engagements,hwm_snap_commits;
static void hwm_drag_snap_reset(void) { hwm_snap_window=0; hwm_snap_neighbor=0; }

static bool hwm_drag_snap_proposal(struct view *view,struct window *moving,CGPoint *point,uint32_t *peer,int *edge)
{
    if(!view || !moving || !point || !isfinite(hwm_plane_scale) || hwm_plane_scale<=0) return false;
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
            preferred=(HWMPlaneSnapTarget){{0,0},count,hwm_snap_axis,hwm_snap_side}; has_preferred=true;
        }
        hwm_drag_snap_ids[count]=w->id;
        hwm_drag_snap_neighbors[count++]=(HWMPlaneRect){w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height};
    }
    HWMPlaneSnapTarget choice;
    if(!hwm_plane_snap_choose((HWMPlaneRect){moving->strip_world_x,moving->strip_world_y,moving->strip_width,moving->strip_height},
        hwm_drag_snap_neighbors,count,fmax(0,view->window_gap),12.0/hwm_plane_scale,
        has_preferred?&preferred:NULL,&choice)) return false;
    HWMPlanePoint target=choice.point;
    /* Bound the actual rounded helper submission too, not only world-space
     * arithmetic. Rounding two axes can otherwise exceed a radial limit. */
    double dx=round(bounds.origin.x+(target.x-camera_x)*hwm_plane_scale)-
              round(bounds.origin.x+(moving->strip_world_x-camera_x)*hwm_plane_scale);
    double dy=round(bounds.origin.y+(target.y-camera_y)*hwm_plane_scale)-
              round(bounds.origin.y+(moving->strip_world_y-camera_y)*hwm_plane_scale);
    if(hypot(dx,dy)>12) return false;
    *point=CGPointMake(target.x,target.y);
    if(peer) *peer=hwm_drag_snap_ids[choice.neighbor];
    if(edge) *edge=choice.axis*2+choice.side;
    return true;
}
static bool hwm_drag_snap_target(struct view *view,struct window *moving,CGPoint *point)
{
    return hwm_drag_snap_proposal(view,moving,point,NULL,NULL);
}
static void hwm_drag_preview_update(struct view *view,struct window *window)
{
    CGPoint target; uint32_t peer=0; int edge=0;
    if(hwm_drag_window!=window->id || !hwm_drag_snap_proposal(view,window,&target,&peer,&edge)) {
        hwm_drag_snap_reset(); hwm_preview_hide_immediately(); return;
    }
    bool changed=hwm_snap_window!=window->id || hwm_snap_neighbor!=peer ||
                 hwm_snap_axis!=edge/2 || hwm_snap_side!=edge%2;
    hwm_snap_window=window->id; hwm_snap_neighbor=peer;
    hwm_snap_axis=edge/2; hwm_snap_side=edge%2; hwm_snap_point=target;
    if(changed) { ++hwm_snap_engagements; hwm_haptic(0); }
    CGRect bounds=hwm_bounds(view); double now=hwm_now(),x=hwm_offset(view,now),y=hwm_plane_camera_y(now);
    CGRect shown=CGRectMake(round(bounds.origin.x+(target.x-x)*hwm_plane_scale),
                            round(bounds.origin.y+(target.y-y)*hwm_plane_scale),
                            round(window->strip_width*hwm_plane_scale),round(window->strip_height*hwm_plane_scale));
    // The target is anchored to a neighboring edge, with no lagging spring.
    hwm_preview_snap_show(shown,edge);
}
static void hwm_drag_snap_commit(struct view *view,struct window *window);
