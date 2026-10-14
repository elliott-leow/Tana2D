/* Plane edge-resize ownership regression tests. Reuse the production runtime
 * harness and exercise the short period between a captured mouse-up and final
 * native reconciliation. */
#define main strip_runtime_test_main
#include "strip_runtime_test.m"
#undef main

static void begin_resized_release(struct window *w)
{
    hwm_plane_resize_publish(&view);
    CGPoint down=CGPointMake(CGRectGetMaxX(w->strip_last_frame),CGRectGetMidY(w->strip_last_frame));
    test_hit_id=w->id;
    assert(resize_event(kCGEventLeftMouseDown,down,0));
    test_cursor=CGPointMake(down.x+40,down.y);
    assert(resize_event(kCGEventLeftMouseDragged,test_cursor,0));
    hwm_plane_resize_tick(&view,clock_now);
    assert(hwm_resize_owned && hwm_edge_window==w->id);
    assert(resize_event(kCGEventLeftMouseUp,test_cursor,0));
    assert(hwm_resize_releasing && !atomic_load(&hwm_resize_captured));
}

static void test_fast_interior_press_finishes_old_session(void)
{
    reset(); struct window *first=&windows[0],*second=&windows[1];
    begin_resized_release(first);
    g_mouse_state.window=second;
    g_mouse_state.window_frame=second->frame;
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    horizontal_mouse_down(second,CGPointMake(CGRectGetMidX(second->strip_last_frame),CGRectGetMidY(second->strip_last_frame)));
    assert(!hwm_resize_owned && !hwm_resize_releasing && hwm_edge_window==0);
    assert(first->strip_native_resize_pending && first->strip_transform_dirty);
}

static void test_fast_edge_press_does_not_inherit_old_delta(void)
{
    reset(); struct window *first=&windows[0],*second=&windows[1];
    begin_resized_release(first);
    int before=ax_calls;
    g_mouse_state.window=second;
    g_mouse_state.window_frame=second->frame;
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    CGPoint edge=CGPointMake(CGRectGetMaxX(second->strip_last_frame),CGRectGetMidY(second->strip_last_frame));
    horizontal_mouse_down(second,edge);
    assert(!hwm_resize_owned && hwm_edge_window==second->id);
    hwm_plane_resize_tick(&view,clock_now+.01);
    assert(ax_calls==before && second->strip_width==400 && second->strip_height==600);
}

static void test_plane_second_press_replaces_releasing_session(void)
{
    reset(); struct window *first=&windows[0],*second=&windows[1];
    begin_resized_release(first);
    hwm_plane_resize_publish(&view);
    test_hit_id=second->id;
    CGPoint down=CGPointMake(CGRectGetMaxX(second->strip_last_frame),CGRectGetMidY(second->strip_last_frame));
    assert(resize_event(kCGEventLeftMouseDown,down,0));
    assert(hwm_resize_owned && hwm_edge_window==second->id && !hwm_resize_releasing);
    assert(first->strip_native_resize_pending && first->strip_transform_dirty);
}

static void test_busy_release_has_deadline(void)
{
    reset(); struct window *w=&windows[0];
    begin_resized_release(w);
    resize_busy=true;
    hwm_plane_resize_tick(&view,clock_now+.2);
    assert(hwm_resize_owned && hwm_edge_window==w->id);
    hwm_plane_resize_tick(&view,clock_now+1.0);
    assert(!hwm_resize_owned && !hwm_resize_releasing && hwm_edge_window==0);
    assert(w->strip_native_resize_pending && w->strip_transform_dirty);
}

static void test_native_and_plane_edge_policy_match(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_render(&view,clock_now);
    CGRect shown=w->strip_last_frame;
    shown.size.width*=w->strip_last_plane_scale;
    shown.size.height*=w->strip_last_plane_scale;
    CGPoint p=CGPointMake(CGRectGetMinX(shown)+HWM_PLANE_RESIZE_EDGE_SLOP,CGRectGetMinY(shown)+HWM_PLANE_RESIZE_EDGE_SLOP);
    unsigned expected=hwm_plane_resize_hit((HWMPlaneRect){shown.origin.x,shown.origin.y,shown.size.width,shown.size.height},(HWMPlanePoint){p.x,p.y});
    g_mouse_state.window=w; g_mouse_state.window_frame=w->frame; g_mouse_state.current_action=MOUSE_MODE_NONE;
    horizontal_mouse_down(w,p);
    assert(expected==hwm_edge_direction && hwm_edge_window==w->id);
}

static void test_pending_native_size_uses_displayed_edge_hit(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_render(&view,clock_now);
    /* The WindowServer has accepted a wider native surface before the cached
     * frame catches up.  The point at its displayed right edge must begin an
     * owned resize, rather than fall outside a hit rect made from w->frame. */
    actual[0].size.width+=160;
    w->strip_size_pending=true;
    hwm_plane_resize_publish(&view);
    test_hit_id=w->id;
    CGPoint edge=CGPointMake(w->strip_last_frame.origin.x+actual[0].size.width*w->strip_last_plane_scale,
                             CGRectGetMidY(w->strip_last_frame));
    assert(resize_event(kCGEventLeftMouseDown,edge,0));
    assert(hwm_resize_owned && hwm_edge_window==w->id && (hwm_edge_direction&HANDLE_RIGHT));
}

static void test_resize_begin_uses_pressed_display_camera(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; view.strip_offset=120; test_camera_y=60;
    hwm_render(&view,clock_now); hwm_plane_resize_publish(&view);
    CGPoint down=CGPointMake(w->strip_last_frame.origin.x+w->strip_last_frame.size.width*w->strip_last_plane_scale,
                             CGRectGetMidY(w->strip_last_frame));
    /* The hit was published at .5x, then a fit animation advances before the
     * serialized input runs. Resize must restore the frame under the press. */
    hwm_plane_scale=.8; view.strip_offset=300; test_camera_y=200; hwm_camera_animating=true;
    test_hit_id=w->id;
    assert(resize_event(kCGEventLeftMouseDown,down,0));
    assert(hwm_plane_scale==.5 && view.strip_offset==120 && test_camera_y==60);
    assert(resize_event(kCGEventLeftMouseDragged,CGPointMake(down.x+75,down.y),0));
    hwm_plane_resize_tick(&view,clock_now);
    assert(w->strip_width==550);
}

static void test_right_button_cannot_resize_left_owned_session(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_resize_publish(&view);
    CGPoint down=CGPointMake(CGRectGetMaxX(w->strip_last_frame),CGRectGetMidY(w->strip_last_frame));
    assert(resize_event(kCGEventLeftMouseDown,down,0));
    assert(resize_event(kCGEventLeftMouseDragged,CGPointMake(down.x+40,down.y),0));
    hwm_plane_resize_tick(&view,clock_now);
    double width=w->strip_width,height=w->strip_height; int submits=ax_calls;
    CGEventRef right=CGEventCreateMouseEvent(NULL,kCGEventRightMouseDown,CGPointMake(900,700),kCGMouseButtonRight);
    hwm_pointer_sample_event(kCGEventRightMouseDown,right); CFRelease(right);
    hwm_plane_resize_tick(&view,clock_now+.01);
    assert(w->strip_width==width && w->strip_height==height && ax_calls==submits);
}

static void test_terminal_up_point_commits_before_queued_up(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_resize_publish(&view);
    CGPoint down=CGPointMake(CGRectGetMaxX(w->strip_last_frame),CGRectGetMidY(w->strip_last_frame));
    CGPoint drag=CGPointMake(down.x+24,down.y),up=CGPointMake(down.x+80,down.y);
    assert(resize_event(kCGEventLeftMouseDown,down,0));
    assert(resize_event(kCGEventLeftMouseDragged,drag,0));
    hwm_plane_resize_tick(&view,clock_now);
    /* The tap has already observed up P2, but its queued resize-up has not
     * run.  A tick must commit P2, never the older routed drag P1. */
    CGEventRef terminal=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,up,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseUp,terminal); CFRelease(terminal);
    atomic_store(&hwm_resize_captured,false);
    hwm_plane_resize_tick(&view,clock_now+.01);
    assert(hwm_resize_releasing);
    assert(w->strip_width==480);
    hwm_plane_resize_tick(&view,clock_now+.2);
    assert(!hwm_resize_owned);
}

static void test_old_queued_up_cannot_release_new_resize_press(void)
{
    reset(); struct window *first=&windows[0],*second=&windows[1];
    hwm_plane_resize_publish(&view);
    CGPoint first_down=CGPointMake(CGRectGetMaxX(first->strip_last_frame),CGRectGetMidY(first->strip_last_frame));
    test_hit_id=first->id;
    assert(resize_event(kCGEventLeftMouseDown,first_down,0));
    uint64_t first_generation=hwm_resize_pointer_generation;
    CGEventRef old_up=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,first_down,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseUp,old_up); CFRelease(old_up);
    CGPoint second_down=CGPointMake(CGRectGetMaxX(second->strip_last_frame),CGRectGetMidY(second->strip_last_frame));
    CGEventRef next_down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,second_down,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,next_down); CFRelease(next_down);
    uint64_t second_generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    HWMPlaneResizeInput *second_input=malloc(sizeof(*second_input));
    assert(second_input);
    *second_input=(HWMPlaneResizeInput){.type=kCGEventLeftMouseDown,.point=second_down,.id=second->id,.direction=HANDLE_RIGHT,.generation=second_generation};
    hwm_plane_resize_input(second_input);
    assert(hwm_resize_owned && hwm_edge_window==second->id && hwm_resize_pointer_generation==second_generation);
    HWMPlaneResizeInput *late_up=malloc(sizeof(*late_up));
    assert(late_up);
    *late_up=(HWMPlaneResizeInput){.type=kCGEventLeftMouseUp,.point=first_down,.generation=first_generation};
    hwm_plane_resize_input(late_up);
    assert(hwm_resize_owned && !hwm_resize_releasing && hwm_edge_window==second->id);
}

int main(void)
{
    @autoreleasepool {
        test_fast_interior_press_finishes_old_session();
        test_fast_edge_press_does_not_inherit_old_delta();
        test_plane_second_press_replaces_releasing_session();
        test_busy_release_has_deadline();
        test_native_and_plane_edge_policy_match();
        test_pending_native_size_uses_displayed_edge_hit();
        test_resize_begin_uses_pressed_display_camera();
        test_right_button_cannot_resize_left_owned_session();
        test_terminal_up_point_commits_before_queued_up();
        test_old_queued_up_cannot_release_new_resize_press();
        puts("plane resize session tests passed");
    }
    return 0;
}
