/* Native-titlebar release regressions. Reuse the production-file harness but
 * do not run its legacy main: this test owns the post-release timing. */
#import <Cocoa/Cocoa.h>
static bool test_left_button_down(CGEventSourceStateID state,CGMouseButton button);
#define CGEventSourceButtonState test_left_button_down
#define main strip_runtime_test_main
#include "strip_runtime_test.m"
#undef main
#undef CGEventSourceButtonState

static uint64_t native_timestamp=1000;
static bool physical_left_button_down;
static bool test_left_button_down(CGEventSourceStateID state,CGMouseButton button)
{
    assert(state==kCGEventSourceStateCombinedSessionState && button==kCGMouseButtonLeft);
    return physical_left_button_down;
}
static void native_begin(struct window *w,CGPoint shown,CGPoint anchor)
{
    size_t index=w->id-1;
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[index];
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    g_mouse_state.down_location=CGPointMake(shown.x+70,shown.y+14);
    CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,g_mouse_state.down_location,kCGMouseButtonLeft);
    CGEventSetTimestamp(down,native_timestamp+=10);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,down); CFRelease(down);
    actual[index].origin=anchor; projected[index].origin=shown;
    CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDragged,
        CGPointMake(g_mouse_state.down_location.x+8,g_mouse_state.down_location.y+6),kCGMouseButtonLeft);
    CGEventSetTimestamp(event,native_timestamp+=1);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,event);
    assert(horizontal_drag(event)); CFRelease(event);
    assert(hwm_drag_native && hwm_drag_window==w->id);
}

static void test_next_native_press_finishes_the_previous_release(void)
{
    for(size_t next=0;next<2;next++) {
        reset(); hwm_render(&view,clock_now);
        struct window *first=&windows[0],*following=&windows[next];
        native_begin(first,CGPointMake(220,170),CGPointMake(530,410));
        uint64_t previous=hwm_drag_pointer_generation;
        assert(previous);
        atomic_store(&hwm_drag_release_pending,true);
        assert(horizontal_drop(first,CGPointZero));
        assert(hwm_drag_native_finishing && hwm_drag_window==first->id);
        native_begin(following,CGPointMake(620,230),CGPointMake(820,460));
        assert(hwm_drag_window==following->id && hwm_drag_native && !hwm_drag_native_finishing);
        assert(hwm_drag_pointer_generation && hwm_drag_pointer_generation!=previous);
        hwm_drag_force_finalize(&view,false);
    }
}

static void test_interrupted_native_settle_never_snaps(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *first=&windows[0],*following=&windows[1];
    /* This is deliberately within the neighbour snap threshold. */
    native_begin(first,CGPointMake(22,170),CGPointMake(530,410));
    following->strip_initialized=true;
    windows[2].strip_initialized=windows[3].strip_initialized=false;
    following->strip_width=400; following->strip_height=600;
    following->strip_world_x=first->strip_world_x+first->strip_width+view.window_gap+10;
    following->strip_world_y=first->strip_world_y;
    CGPoint unsnapped=CGPointMake(first->strip_world_x,first->strip_world_y),target;
    assert(hwm_drag_snap_target(&view,first,&target));
    assert(!CGPointEqualToPoint(target,unsnapped));
    atomic_store(&hwm_drag_release_pending,true);
    assert(horizontal_drop(first,CGPointZero));
    native_begin(following,CGPointMake(620,230),CGPointMake(820,460));
    assert(first->strip_world_x==unsnapped.x && first->strip_world_y==unsnapped.y);
    hwm_drag_force_finalize(&view,false);
}

static void test_native_deadline_does_not_snap_without_a_displayed_sample(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    native_begin(w,CGPointMake(22,170),CGPointMake(530,410));
    windows[1].strip_initialized=true;
    windows[2].strip_initialized=windows[3].strip_initialized=false;
    windows[1].strip_width=400; windows[1].strip_height=600;
    windows[1].strip_world_x=w->strip_world_x+w->strip_width+view.window_gap+10;
    windows[1].strip_world_y=w->strip_world_y;
    CGPoint unsnapped=CGPointMake(w->strip_world_x,w->strip_world_y),target;
    assert(hwm_drag_snap_target(&view,w,&target));
    assert(!CGPointEqualToPoint(target,unsnapped));
    atomic_store(&hwm_drag_release_pending,true);
    assert(horizontal_drop(w,CGPointZero));
    /* The runtime CG stub now returns an invalid presentation frame, exactly
     * like an unavailable CGWindowList sample. The hard deadline still ends
     * ownership, but cannot turn that absence into a neighbour snap. */
    presentation_unavailable=true;
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native);
    assert(w->strip_world_x==unsnapped.x && w->strip_world_y==unsnapped.y);
}

static void test_tap_disable_retains_held_native_drag_until_physical_up(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    native_begin(w,CGPointMake(220,170),CGPointMake(530,410));
    g_mouse_state.direction=99;
    hwm_mouse_pointer_generation=88;
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    physical_left_button_down=true;
    assert(hwm_drag_native_tap_disabled_recover(&view));
    assert(hwm_drag_native_recovering && hwm_drag_window==w->id && !hwm_drag_native_finishing);
    /* AppKit keeps moving after the tap was disabled; no queued drag is used. */
    atomic_store(&hwm_drag_release_pending,true);
    actual[0].origin=CGPointMake(601,428); projected[0].origin=CGPointMake(341,199);
    clock_now+=.02; hwm_drag_autoscroll(&view,clock_now);
    assert(hwm_drag_window==w->id && w->strip_world_x==329 && w->strip_world_y==148);
    physical_left_button_down=false;
    clock_now+=.01; hwm_drag_autoscroll(&view,clock_now);
    assert(hwm_drag_native_finishing && hwm_drag_window==w->id);
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native && !hwm_drag_native_recovering);
    assert(!g_mouse_state.window && g_mouse_state.current_action==MOUSE_MODE_NONE && !g_mouse_state.direction);
    assert(!hwm_mouse_pointer_generation && hwm_mouse_pointer_button==-1);
}

/* The physical-state poll can miss an up/down pair between display ticks.
 * The new press must replace the recovered native owner instead of waiting
 * for that second press to release. */
static void test_recovered_native_drag_yields_to_next_press(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    native_begin(w,CGPointMake(220,170),CGPointMake(530,410));
    uint64_t previous=hwm_drag_pointer_generation;
    physical_left_button_down=true;
    hwm_pointer_sample_abort_left_press();
    assert(hwm_drag_native_tap_disabled_recover(&view));
    assert(hwm_drag_native_recovering && hwm_drag_native_recovered);
    /* The first physical up is not observed until after this new press. */
    native_begin(w,CGPointMake(360,240),CGPointMake(730,450));
    assert(hwm_drag_window==w->id && hwm_drag_native && !hwm_drag_native_recovering);
    assert(hwm_drag_pointer_generation && hwm_drag_pointer_generation!=previous);
    hwm_drag_force_finalize(&view,false);
}

static void test_tap_disable_after_physical_up_clears_legacy_owner(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    native_begin(w,CGPointMake(220,170),CGPointMake(530,410));
    g_mouse_state.direction=99;
    physical_left_button_down=false;
    assert(hwm_drag_native_tap_disabled_recover(&view));
    assert(hwm_drag_native_finishing && hwm_drag_native_recovered);
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !g_mouse_state.window &&
           g_mouse_state.current_action==MOUSE_MODE_NONE && !g_mouse_state.direction);
}

static void test_late_native_sample_commits_once(void)
{
    reset();
    struct window *w=&windows[0]; hwm_plane_scale=1; hwm_render(&view,clock_now);
    native_begin(w,CGPointMake(220,170),CGPointMake(530,410));
    atomic_store(&hwm_drag_release_pending,true);
    assert(horizontal_drop(w,CGPointZero));
    assert(hwm_drag_native && hwm_drag_window==w->id);
    /* The visible terminal frame arrives after queued mouse-up. */
    actual[0].origin=CGPointMake(601,428); projected[0].origin=CGPointMake(341,199);
    clock_now+=.012; hwm_drag_autoscroll(&view,clock_now);
    assert(w->strip_world_x==329 && w->strip_world_y==148);
    clock_now+=.025; hwm_drag_autoscroll(&view,clock_now);
    clock_now+=.025; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native);
    CGRect held=projected[0]; int before_render=scale_calls;
    hwm_render(&view,clock_now+.01);
    /* Completion dirties the stale native matrix even when the cache origin
     * already equals the displayed frame, so this must submit once. */
    assert(scale_calls>before_render);
    int settled_calls=scale_calls;
    hwm_render(&view,clock_now+.02);
    assert(scale_calls==settled_calls);
    assert(CGPointEqualToPoint(projected[0].origin,held.origin));
}

static void test_native_finish_is_bounded_and_never_edgepans(void)
{
    reset();
    struct window *w=&windows[0]; hwm_plane_scale=1; view.strip_offset=173; hwm_render(&view,clock_now);
    native_begin(w,CGPointMake(16,180),CGPointMake(500,420));
    hwm_drag_point=CGPointMake(12,180); double camera=view.strip_offset;
    clock_now+=.04; hwm_drag_autoscroll(&view,clock_now);
    assert(view.strip_offset==camera);
    atomic_store(&hwm_drag_release_pending,true);
    assert(horizontal_drop(w,CGPointZero));
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native);
}

int main(void)
{
    @autoreleasepool {
        test_next_native_press_finishes_the_previous_release();
        test_interrupted_native_settle_never_snaps();
        test_native_deadline_does_not_snap_without_a_displayed_sample();
        test_tap_disable_retains_held_native_drag_until_physical_up();
        test_recovered_native_drag_yields_to_next_press();
        test_tap_disable_after_physical_up_clears_legacy_owner();
        test_late_native_sample_commits_once();
        test_native_finish_is_bounded_and_never_edgepans();
        puts("plane native drag tests passed");
    }
}
