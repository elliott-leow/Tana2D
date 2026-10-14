static CGPoint hwm_drag_world_at(struct view *view,CGPoint point)
{
    HWMPlanePoint world=hwm_plane_drag_world((HWMPlanePoint){hwm_drag_world_origin.x,hwm_drag_world_origin.y},
                                             (HWMPlanePoint){point.x,point.y},(HWMPlanePoint){hwm_drag_pointer_origin.x,hwm_drag_pointer_origin.y},
                                             hwm_drag_scale,hwm_offset(view,hwm_now())-hwm_drag_camera_x,
                                             hwm_plane_camera_y(hwm_now())-hwm_drag_camera_y);
    return CGPointMake(world.x,world.y);
}
/* Shared production drag placement: translated native surfaces and magnetic edges. */
static CGPoint hwm_drag_snap(struct view *view,struct window *window,CGPoint raw)
{
    HWMPlaneRect moving={raw.x,raw.y,window->strip_width,window->strip_height};
    HWMPlanePoint best={raw.x,raw.y}; double distance=INFINITY; uint32_t target=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *other=hwm_tile(n->window_list[i]);
        if(!other || other==window || other->strip_close_ghost) continue;
        double range=(other->id==hwm_drag_snap_neighbor?38:24)/hwm_plane_scale;
        HWMPlanePoint candidate;
        if(!hwm_plane_snap_neighbor_target(moving,(HWMPlaneRect){other->strip_world_x,other->strip_world_y,other->strip_width,other->strip_height},view->window_gap,range,&candidate)) continue;
        double d=hypot(candidate.x-raw.x,candidate.y-raw.y);
        if(other->id==hwm_drag_snap_neighbor) d*=.65;
        if(d<distance) { best=candidate; distance=d; target=other->id; }
    }
    double now=hwm_now(),dt=fmax(0,now-hwm_drag_snap_time); hwm_drag_snap_time=now;
    double blend=hwm_drag_finishing || hwm_motion_scale==0 ? 1 : 1-exp(-dt/.045);
    // Once an edge is acquired, ease the displayed position to that edge.
    // Easing the correction alone adds pointer motion a second time when the
    // pointer reaches the exact snap, briefly pushing the window past it.
    if(target && target==hwm_drag_snap_neighbor) {
        hwm_drag_snap_x=window->strip_world_x+(best.x-window->strip_world_x)*blend-raw.x;
        hwm_drag_snap_y=window->strip_world_y+(best.y-window->strip_world_y)*blend-raw.y;
        return CGPointMake(raw.x+hwm_drag_snap_x,raw.y+hwm_drag_snap_y);
    }
    hwm_drag_snap_x+=(best.x-raw.x-hwm_drag_snap_x)*blend;
    hwm_drag_snap_y+=(best.y-raw.y-hwm_drag_snap_y)*blend;
    hwm_drag_snap_neighbor=target;
    return CGPointMake(raw.x+hwm_drag_snap_x,raw.y+hwm_drag_snap_y);
}
static bool hwm_drag_submit_plane(struct view *view,struct window *window,CGPoint world)
{
    if(!view || !window || !isfinite(world.x) || !isfinite(world.y)) return false;
    world=hwm_drag_snap(view,window,world);
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()), camera_y=hwm_plane_camera_y(hwm_now()), scale=hwm_plane_scale;
    CGRect base=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                           round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                           round(hwm_plane_physical_size(window->strip_width)),round(hwm_plane_physical_size(window->strip_height)));
    CGRect projected=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                                round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                                round(hwm_plane_physical_size(window->strip_width*scale)),round(hwm_plane_physical_size(window->strip_height*scale)));
    hwm_batch_begin();
    bool ok=scripting_addition_set_plane_transform(window->id,projected.origin.x,projected.origin.y,scale);
    window->strip_plane_scaled=ok; window->strip_transform_dirty=!ok;
    window->strip_last_plane_scale=scale;
    hwm_batch_end();
    if(!ok) { ++hwm_move_failures; hwm_backend_ok=false; return false; }
    window->strip_world_x=world.x; window->strip_world_y=world.y;
    window->strip_from_x=world.x; window->strip_from_y=world.y;
    window->strip_last_frame=base; window->strip_last_offset=camera_x; window->strip_last_camera_y=camera_y; window->strip_last_shift=0;
    window->strip_start=hwm_now()-hwm_duration;
    return true;
}
