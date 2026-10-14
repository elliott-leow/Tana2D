static CGPoint hwm_drag_world_at(struct view *view,CGPoint point)
{
    HWMPlanePoint world=hwm_plane_drag_world((HWMPlanePoint){hwm_drag_world_origin.x,hwm_drag_world_origin.y},
                                             (HWMPlanePoint){point.x,point.y},(HWMPlanePoint){hwm_drag_pointer_origin.x,hwm_drag_pointer_origin.y},
                                             hwm_drag_scale,hwm_offset(view,hwm_now())-hwm_drag_camera_x,
                                             hwm_plane_camera_y(hwm_now())-hwm_drag_camera_y);
    return CGPointMake(world.x,world.y);
}
/* Pointer-owned movement has no spring, magnet, layout pass, or display-link
 * gate. The helper presents the native surface and existing outline together. */
static bool hwm_drag_submit_plane(struct view *view,struct window *window,CGPoint world)
{
    if(!view || !window || !isfinite(world.x) || !isfinite(world.y)) return false;
    double began=hwm_now();
    CGRect bounds=hwm_bounds(view); double camera_x=hwm_offset(view,hwm_now()), camera_y=hwm_plane_camera_y(hwm_now()), scale=hwm_plane_scale;
    CGRect base=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                           round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                           round(hwm_plane_physical_size(window->strip_width)),round(hwm_plane_physical_size(window->strip_height)));
    CGRect projected=CGRectMake(round(hwm_plane_project_physical(world.x,camera_x,bounds.origin.x,scale)),
                                round(hwm_plane_project_physical(world.y,camera_y,bounds.origin.y,scale)),
                                round(hwm_plane_physical_size(window->strip_width*scale)),round(hwm_plane_physical_size(window->strip_height*scale)));
    bool own_batch=!hwm_batch_open;
    if(own_batch) scripting_addition_batch_begin();
    bool ok=scripting_addition_set_plane_transform(window->id,projected.origin.x,projected.origin.y,scale);
    if(ok) ok=hwm_plane_border_drag(window->id,projected);
    if(own_batch) ok=scripting_addition_batch_end() && ok;
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
    return true;
}
