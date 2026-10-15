static void hwm_plane_maximize(struct view *view)
{
    struct window *window=hwm_action_window();
    if(!view || !window || hwm_paused || hwm_suspended) return;
    hwm_undo_capture();
    CGRect bounds=hwm_bounds(view);
    if(!view_find_window_node(view,window->id)) {
        hwm_plane_actual_size(view);
        if(!hwm_plane_reset_transform(window)) return;
        hwm_float_to(window,bounds); hwm_wake(); return;
    }
    window->strip_width=bounds.size.width; window->strip_height=bounds.size.height;
    window->strip_full_width=false;
    hwm_plane_transition_to(view,window->strip_world_x,window->strip_world_y,1,true);
    hwm_layout(view,true);
    hwm_preserve_focus_window=window->id; hwm_preserve_focus_until=hwm_now()+1;
}

