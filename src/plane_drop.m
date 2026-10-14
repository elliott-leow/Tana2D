static bool horizontal_drop(struct window *window, CGPoint point)
{
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    if(hwm_drag_cancelled) { hwm_drag_cancelled=false; hwm_layout(view,true); return true; }
    if(hwm_edge_finish(window,view)) return true;
    if(hwm_drag_window==window->id) {
        (void)point;
        hwm_drag_release(view,window);
    }
    return true;
}
