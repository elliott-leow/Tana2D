static CGRect hwm_feedback_plane_frame(struct view *view,struct window *w)
{
    if(w->id==hwm_drag_window && hwm_drag_native) return hwm_drag_native_displayed;
    if(w->strip_native_move_pending) {
        CGRect shown;
        return hwm_plane_displayed_frame(w->id,&shown) ? shown : CGRectNull;
    }
    CGRect frame=w->strip_last_frame;
    if(CGRectIsNull(frame) || w->strip_offscreen) return CGRectNull;
    (void)view;
    // Translation never changes native size. Use the last accepted dimensions
    // instead of synchronously asking WindowServer about every tile each frame.
    frame.size=w->frame.size;
    // While an asynchronous resize is pending, its requested size is not yet
    // the visible size. This is the only path that needs a fresh measurement.
    if(w->strip_size_pending || w->strip_native_resize_pending) {
        CGRect native=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&native)==kCGErrorSuccess && native.size.width>0 && native.size.height>0)
            frame.size=native.size;
    }
    double scale=w->strip_last_plane_scale>0?w->strip_last_plane_scale:hwm_plane_scale;
    frame.size.width*=scale; frame.size.height*=scale;
    return frame;
}
