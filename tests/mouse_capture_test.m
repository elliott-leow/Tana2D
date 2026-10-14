/* No event-tap posting: exercises the retained capture state directly. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
/* mouse_handler.h normally follows yabai's model declarations. The capture
 * helpers under test need none of their definitions. */
struct window;
struct window_node;
struct window_manager;
struct view;
struct space_manager;
enum window_node_split { TEST_WINDOW_NODE_SPLIT };
enum window_node_child { TEST_WINDOW_NODE_CHILD };
#include "../vendor/yabai/src/mouse_handler.h"

static CGEventRef mouse_event(CGEventType type, CGMouseButton button)
{
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,CGPointZero,button);
    assert(event); return event;
}

static void test_disabled_left_capture_eats_only_late_left_up(void)
{
    struct mouse_state state={0};
    CGEventRef left_down=mouse_event(kCGEventLeftMouseDown,kCGMouseButtonLeft);
    CGEventRef right_up=mouse_event(kCGEventRightMouseUp,kCGMouseButtonRight);
    CGEventRef left_up=mouse_event(kCGEventLeftMouseUp,kCGMouseButtonLeft);
    mouse_capture_begin(&state,left_down);
    assert(state.consume_mouse_click && state.consumed_button==kCGMouseButtonLeft && state.consumed_event);
    mouse_capture_cancel(&state);
    assert(!state.consume_mouse_click && !state.drag_detected && !state.consumed_event);
    assert(state.consume_mouse_up_pending && state.consume_mouse_up_button==kCGMouseButtonLeft);
    assert(!mouse_capture_consume_late_up(&state,right_up));
    assert(state.consume_mouse_up_pending);
    assert(mouse_capture_consume_late_up(&state,left_up));
    assert(!state.consume_mouse_up_pending);
    CFRelease(left_down); CFRelease(right_up); CFRelease(left_up);
}

static void test_fresh_same_button_down_clears_only_its_stale_fence(void)
{
    struct mouse_state state={.consume_mouse_up_pending=true,.consume_mouse_up_button=kCGMouseButtonLeft};
    CGEventRef right_down=mouse_event(kCGEventRightMouseDown,kCGMouseButtonRight);
    CGEventRef left_down=mouse_event(kCGEventLeftMouseDown,kCGMouseButtonLeft);
    mouse_capture_note_down(&state,right_down);
    assert(state.consume_mouse_up_pending); /* unrelated right click cannot revive left tail */
    mouse_capture_note_down(&state,left_down);
    assert(!state.consume_mouse_up_pending); /* any fresh matching native down is safe */
    CFRelease(right_down); CFRelease(left_down);
}

static void test_opposite_up_does_not_finish_active_capture(void)
{
    struct mouse_state state={0};
    CGEventRef left_down=mouse_event(kCGEventLeftMouseDown,kCGMouseButtonLeft);
    CGEventRef left_up=mouse_event(kCGEventLeftMouseUp,kCGMouseButtonLeft);
    CGEventRef right_up=mouse_event(kCGEventRightMouseUp,kCGMouseButtonRight);
    mouse_capture_begin(&state,left_down);
    assert(!mouse_capture_matches_up(&state,right_up));
    assert(state.consume_mouse_click && state.consumed_event);
    assert(mouse_capture_matches_up(&state,left_up));
    assert(mouse_capture_should_replay(&state));
    mouse_capture_finish(&state);
    assert(!state.consume_mouse_click && !state.consumed_event);
    CFRelease(left_down); CFRelease(left_up); CFRelease(right_up);
}

int main(void)
{
    @autoreleasepool {
        test_disabled_left_capture_eats_only_late_left_up();
        test_fresh_same_button_down_clears_only_its_stale_fence();
        test_opposite_up_does_not_finish_active_capture();
        puts("mouse capture tests passed");
    }
    return 0;
}
