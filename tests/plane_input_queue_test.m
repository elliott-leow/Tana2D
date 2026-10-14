#define main strip_runtime_test_main
#include "strip_runtime_test.m"
#undef main

static CGEventRef pointer_event(CGEventType type,CGPoint point,uint64_t time,CGMouseButton button)
{
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,button);
    assert(event); CGEventSetTimestamp(event,time); return event;
}
static void publish(CGEventType type,CGPoint point,uint64_t time,CGMouseButton button)
{
    CGEventRef event=pointer_event(type,point,time,button);
    hwm_pointer_sample_event(type,event); CFRelease(event);
}
static void expect_point(CGPoint got,CGPoint want)
{
    assert(got.x==want.x && got.y==want.y);
}

/* The final drag is retained for its own press even if release and a later
 * press run ahead of the event-loop callback. */
static void test_delayed_drag_never_remaps_to_right_or_new_left(void)
{
    publish(kCGEventLeftMouseDown,CGPointMake(10,10),10,kCGMouseButtonLeft);
    uint64_t first=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    publish(kCGEventLeftMouseDragged,CGPointMake(30,20),20,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseDragged,CGPointMake(70,40),30,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseUp,CGPointMake(75,42),40,kCGMouseButtonLeft);
    assert(atomic_load(&hwm_drag_release_pending));

    publish(kCGEventRightMouseDown,CGPointMake(900,700),50,kCGMouseButtonRight);
    assert(atomic_load(&hwm_drag_release_pending));
    CGPoint point=CGPointZero,latest=CGPointZero; uint64_t serial=0;
    assert(hwm_pointer_sample(&latest)); expect_point(latest,CGPointMake(900,700));
    assert(hwm_pointer_sample_drag_for_generation(first,1,&point,&serial));
    expect_point(point,CGPointMake(70,40)); assert(serial>1);

    publish(kCGEventLeftMouseDown,CGPointMake(800,600),60,kCGMouseButtonLeft);
    assert(!atomic_load(&hwm_drag_release_pending));
    assert(hwm_pointer_sample_drag_for_generation(first,1,&point,&serial));
    expect_point(point,CGPointMake(70,40));

    CGEventRef delayed=pointer_event(kCGEventLeftMouseDragged,CGPointMake(30,20),20,kCGMouseButtonLeft);
    uint64_t delayed_generation=0;
    assert(hwm_pointer_sample_drag_event(delayed,&point,&delayed_generation));
    expect_point(point,CGPointMake(30,20)); assert(delayed_generation==first);
    CFRelease(delayed);
}
/* Several completed press records survive a queue backlog; every lookup gets
 * the captured drag for its own generation, never the latest sample. */
static void test_three_quick_presses_keep_independent_final_drags(void)
{
    uint64_t generation[3]; CGPoint expected[3]={CGPointMake(101,102),CGPointMake(201,202),CGPointMake(301,302)};
    for(int i=0;i<3;i++) {
        uint64_t base=100+(uint64_t)i*10;
        publish(kCGEventLeftMouseDown,CGPointMake(i,i),base,kCGMouseButtonLeft);
        generation[i]=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
        publish(kCGEventLeftMouseDragged,expected[i],base+1,kCGMouseButtonLeft);
        publish(kCGEventLeftMouseUp,expected[i],base+2,kCGMouseButtonLeft);
    }
    for(int i=0;i<3;i++) {
        CGPoint point=CGPointZero; uint64_t serial=0;
        assert(hwm_pointer_sample_drag_for_generation(generation[i],0,&point,&serial));
        expect_point(point,expected[i]); assert(serial);
    }
}
static void test_terminal_point_stays_with_its_left_generation(void)
{
    publish(kCGEventLeftMouseDown,CGPointMake(11,12),150,kCGMouseButtonLeft);
    uint64_t generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    publish(kCGEventLeftMouseDragged,CGPointMake(31,32),151,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseUp,CGPointMake(41,42),152,kCGMouseButtonLeft);
    publish(kCGEventRightMouseDown,CGPointMake(900,700),153,kCGMouseButtonRight);
    CGPoint point=CGPointZero;
    assert(hwm_pointer_sample_point_for_generation(generation,&point));
    expect_point(point,CGPointMake(41,42));
}

/* Fixture replay supplies its synthetic events with a local monotonic clock.
 * Exact event matching must therefore retain the current press over a prior
 * completed fixture press. */
static void test_monotonic_fixture_timestamps_select_the_current_press(void)
{
    hwm_pointer_sample_reset();
    CGEventRef first=pointer_event(kCGEventLeftMouseDown,CGPointMake(10,10),1,kCGMouseButtonLeft);
    CGEventRef first_up=pointer_event(kCGEventLeftMouseUp,CGPointMake(10,10),2,kCGMouseButtonLeft);
    CGEventRef second=pointer_event(kCGEventLeftMouseDown,CGPointMake(20,20),3,kCGMouseButtonLeft);
    CGEventRef drag=pointer_event(kCGEventLeftMouseDragged,CGPointMake(30,30),4,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,first);
    uint64_t first_generation=hwm_pointer_sample_generation_for_event_ref(first);
    hwm_pointer_sample_event(kCGEventLeftMouseUp,first_up);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,second);
    uint64_t second_generation=hwm_pointer_sample_generation_for_event_ref(second);
    assert(first_generation && second_generation && first_generation!=second_generation);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,drag);
    CGPoint point=CGPointZero; uint64_t generation=0;
    assert(hwm_pointer_sample_drag_event(drag,&point,&generation));
    assert(generation==second_generation); expect_point(point,CGPointMake(30,30));
    CFRelease(first); CFRelease(first_up); CFRelease(second); CFRelease(drag);
}

/* The event loop has a single legacy owner.  A physically active owner blocks
 * a different-button down, while its own up remains the only release that may
 * clear the owner. This is the sampler predicate used by MOUSE_DOWN. */
static void test_active_owner_survives_other_button_events(void)
{
    publish(kCGEventLeftMouseDown,CGPointMake(11,12),160,kCGMouseButtonLeft);
    uint64_t generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    hwm_mouse_pointer_generation=generation;
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    assert(hwm_pointer_sample_generation_is_active(hwm_mouse_pointer_generation));
    assert(hwm_mouse_pointer_button!=kCGMouseButtonRight);
    publish(kCGEventRightMouseDown,CGPointMake(900,700),161,kCGMouseButtonRight);
    assert(hwm_pointer_sample_generation_is_active(generation));
    assert(hwm_mouse_pointer_button==kCGMouseButtonLeft);
    publish(kCGEventLeftMouseUp,CGPointMake(11,12),162,kCGMouseButtonLeft);
    assert(!hwm_pointer_sample_generation_is_active(generation));

    publish(kCGEventRightMouseDown,CGPointMake(900,700),163,kCGMouseButtonRight);
    generation=hwm_pointer_sample_generation_for_event(kCGEventRightMouseDown);
    hwm_mouse_pointer_generation=generation;
    hwm_mouse_pointer_button=kCGMouseButtonRight;
    assert(hwm_pointer_sample_generation_is_active(generation));
    assert(hwm_mouse_pointer_button!=kCGMouseButtonLeft);
    publish(kCGEventLeftMouseDown,CGPointMake(12,13),164,kCGMouseButtonLeft);
    assert(hwm_pointer_sample_generation_is_active(generation));
    assert(hwm_mouse_pointer_button==kCGMouseButtonRight);
    publish(kCGEventRightMouseUp,CGPointMake(900,700),165,kCGMouseButtonRight);
    assert(!hwm_pointer_sample_generation_is_active(generation));
}

static void test_abort_rejects_late_drag(void)
{
    publish(kCGEventLeftMouseDown,CGPointMake(400,400),200,kCGMouseButtonLeft);
    uint64_t generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    publish(kCGEventLeftMouseDragged,CGPointMake(450,440),201,kCGMouseButtonLeft);
    CGEventRef delayed=pointer_event(kCGEventLeftMouseDragged,CGPointMake(450,440),201,kCGMouseButtonLeft);
    hwm_pointer_sample_abort_left_press();
    assert(hwm_pointer_sample_generation_is_aborted(generation));
    CGPoint point=CGPointZero;
    assert(!hwm_pointer_sample_drag_event(delayed,&point,NULL));
    CFRelease(delayed);
}
/* Model the real split: the tap has already observed down/drag/up and a later
 * press, while the event-loop is only now dequeuing the old coalesced drag.
 * The drag must commit exactly once from the final old drag, then the old up
 * must release it. */
static void test_controller_applies_final_queued_drag_after_release(void)
{
    reset(); hwm_plane_selecting=true; selection_hit=&windows[0];
    CGPoint down=CGPointMake(200,200),first=CGPointMake(240,220),last=CGPointMake(320,260);
    CGEventRef event=pointer_event(kCGEventLeftMouseDown,down,4000,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,event);
    assert(hwm_plane_pick_event(kCGEventLeftMouseDown,event)); CFRelease(event);
    HWMPlanePickInput *input=test_input; test_input=NULL;
    assert(hwm_plane_pick_input_prepare(input)); hwm_plane_pointer(input->type,input->point); free(input);

    event=pointer_event(kCGEventLeftMouseDragged,first,4010,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,event);
    assert(hwm_plane_pick_event(kCGEventLeftMouseDragged,event)); CFRelease(event);
    HWMPlanePickInput *first_drag=input=test_input; test_input=NULL;
    uint64_t generation=first_drag->generation;
    assert(hwm_plane_pick_input_prepare(first_drag)); hwm_plane_pointer(first_drag->type,first_drag->point); free(first_drag);
    assert(hwm_drag_window==windows[0].id);
    CGPoint held=CGPointMake(windows[0].strip_world_x,windows[0].strip_world_y);
    /* The owner remains active while an unrelated right press updates the
     * global sample.  Autoscroll must atomically read the left owner point. */
    publish(kCGEventRightMouseDown,CGPointMake(900,700),4015,kCGMouseButtonRight);
    hwm_drag_autoscroll(&view,clock_now+.005);
    expect_point(hwm_drag_point,first);
    publish(kCGEventRightMouseUp,CGPointMake(900,700),4016,kCGMouseButtonRight);
    event=pointer_event(kCGEventLeftMouseDragged,last,4020,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,event);
    assert(hwm_plane_pick_event(kCGEventLeftMouseDragged,event)); CFRelease(event);
    HWMPlanePickInput *drag=input=test_input; test_input=NULL;
    publish(kCGEventLeftMouseUp,last,4030,kCGMouseButtonLeft);
    publish(kCGEventRightMouseDown,CGPointMake(900,700),4040,kCGMouseButtonRight);
    assert(atomic_load(&hwm_drag_release_pending));
    publish(kCGEventLeftMouseDown,CGPointMake(800,600),4050,kCGMouseButtonLeft);
    hwm_drag_autoscroll(&view,clock_now+.01);
    assert(windows[0].strip_world_x==held.x && windows[0].strip_world_y==held.y);

    assert(hwm_plane_pick_input_prepare(drag));
    assert(drag->generation==generation); expect_point(drag->point,last);
    hwm_plane_pointer(drag->type,drag->point); free(drag);
    assert(hwm_drag_window==windows[0].id);
    assert(windows[0].strip_world_x==held.x+(last.x-first.x)/hwm_plane_scale);
    assert(windows[0].strip_world_y==held.y+(last.y-first.y)/hwm_plane_scale);
    HWMPlanePickInput up={kCGEventLeftMouseUp,last,true,generation,0};
    assert(hwm_plane_pick_input_prepare(&up)); hwm_plane_pointer(up.type,up.point);
    assert(!hwm_drag_window && !hwm_plane_pick_window);
    /* The subsequent left press is a new session and cannot revive this one. */
    assert(!hwm_pointer_sample_drag_for_generation(generation,UINT64_MAX,&down,NULL));
}

/* A right-button modifier drag is an independent owner. A completed left
 * click must neither discard its first frame nor freeze its autoscroll tick. */
static void test_right_drag_ignores_prior_left_release(void)
{
    reset(); struct window *w=&windows[0];
    publish(kCGEventLeftMouseDown,CGPointMake(80,80),6000,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseUp,CGPointMake(80,80),6010,kCGMouseButtonLeft);
    assert(atomic_load(&hwm_drag_release_pending));
    CGPoint down=CGPointMake(200,200),drag=CGPointMake(260,240);
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_MOVE;
    CGEventRef event=pointer_event(kCGEventRightMouseDown,down,6020,kCGMouseButtonRight);
    hwm_pointer_sample_event(kCGEventRightMouseDown,event); CFRelease(event);
    event=pointer_event(kCGEventRightMouseDragged,drag,6030,kCGMouseButtonRight);
    hwm_pointer_sample_event(kCGEventRightMouseDragged,event);
    assert(horizontal_drag(event)); CFRelease(event);
    assert(hwm_drag_window==w->id && hwm_drag_pointer_generation);
    hwm_drag_point=CGPointZero;
    hwm_drag_autoscroll(&view,clock_now+.01);
    expect_point(hwm_drag_point,drag);
    publish(kCGEventRightMouseUp,drag,6040,kCGMouseButtonRight);
    hwm_drag_point=CGPointZero;
    hwm_drag_autoscroll(&view,clock_now+.02);
    expect_point(hwm_drag_point,CGPointZero);
}

/* A native window-moved notification can lag the tap. Its drag opening must
 * retain the active left owner, never use a later right pointer or reopen once
 * the left release has reached the tap. */
static void test_native_window_change_uses_active_left_generation(void)
{
    reset(); struct window *w=&windows[0];
    CGPoint down=CGPointMake(180,180),left=CGPointMake(240,220),right=CGPointMake(900,700);
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_NONE;
    publish(kCGEventLeftMouseDown,down,7000,kCGMouseButtonLeft);
    uint64_t generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    hwm_mouse_pointer_generation=generation;
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    publish(kCGEventLeftMouseDragged,left,7010,kCGMouseButtonLeft);
    publish(kCGEventRightMouseDown,right,7020,kCGMouseButtonRight);
    actual[0].origin.x+=40;
    assert(horizontal_window_changed(w,&view,false));
    assert(hwm_drag_window==w->id && hwm_drag_pointer_generation==generation);
    expect_point(hwm_drag_point,left);

    reset(); w=&windows[0];
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_NONE;
    publish(kCGEventLeftMouseDown,down,7100,kCGMouseButtonLeft);
    uint64_t old_generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    hwm_mouse_pointer_generation=old_generation; /* old serialized mouse state */
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    publish(kCGEventLeftMouseDragged,left,7110,kCGMouseButtonLeft);
    /* A newer physical left down arrives before the old native notification.
     * It replaces the sampler active press, but must not be substituted for
     * the old g_mouse_state owner. */
    publish(kCGEventLeftMouseDown,right,7120,kCGMouseButtonLeft);
    publish(kCGEventRightMouseDown,right,7130,kCGMouseButtonRight);
    actual[0].origin.x+=40;
    (void)horizontal_window_changed(w,&view,false);
    assert(!hwm_drag_window);

    reset(); w=&windows[0];
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_NONE;
    publish(kCGEventLeftMouseDown,down,7200,kCGMouseButtonLeft);
    generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    publish(kCGEventLeftMouseDragged,left,7210,kCGMouseButtonLeft);
    /* A right serialized owner cannot reuse an old left generation. */
    hwm_mouse_pointer_generation=generation; hwm_mouse_pointer_button=kCGMouseButtonRight;
    actual[0].origin.x+=40;
    (void)horizontal_window_changed(w,&view,false);
    assert(!hwm_drag_window);
}

/* A left drag can wait in the event loop while a physical right-down updates
 * the tap cache. The production drag initializer must retain the left event
 * point rather than overwrite it with that newer unrelated sample. */
static void test_queued_left_drag_keeps_its_event_point_after_right_down(void)
{
    reset(); struct window *w=&windows[0];
    CGPoint down=CGPointMake(200,200),left=CGPointMake(260,240),right=CGPointMake(900,700);
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_MOVE;
    publish(kCGEventLeftMouseDown,down,8000,kCGMouseButtonLeft);
    CGEventRef event=pointer_event(kCGEventLeftMouseDragged,left,8010,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,event);
    publish(kCGEventRightMouseDown,right,8020,kCGMouseButtonRight);
    assert(horizontal_drag(event)); CFRelease(event);
    assert(hwm_drag_window==w->id);
    expect_point(hwm_drag_point,left);
}

/* The physical tap can reach up and the next down while one prior drag waits
 * in the serialized queue. The later down clears the legacy release bit, but
 * the old queued drag must still use its own final coalesced point. */
static void test_queued_drag_uses_its_generation_after_next_left_down(void)
{
    reset(); struct window *w=&windows[0];
    CGPoint down=CGPointMake(200,200),first=CGPointMake(230,215),last=CGPointMake(290,250),next=CGPointMake(800,600);
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_MOVE;
    publish(kCGEventLeftMouseDown,down,9000,kCGMouseButtonLeft);
    CGEventRef queued=pointer_event(kCGEventLeftMouseDragged,first,9010,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,queued);
    publish(kCGEventLeftMouseDragged,last,9020,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseUp,last,9030,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseDown,next,9040,kCGMouseButtonLeft);
    assert(!atomic_load(&hwm_drag_release_pending));
    assert(horizontal_drag(queued)); CFRelease(queued);
    assert(hwm_drag_window==w->id);
    expect_point(hwm_drag_point,last);
}

/* A MOUSE_DOWN rejected because left owns the legacy state cannot leave its
 * right-button drag queued to move, retag, or replace that left session. */
static void test_rejected_other_button_drag_cannot_move_left_owner(void)
{
    reset(); struct window *w=&windows[0];
    CGPoint down=CGPointMake(200,200),left=CGPointMake(250,230),right=CGPointMake(900,700);
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.down_location=down; g_mouse_state.current_action=MOUSE_MODE_MOVE;
    publish(kCGEventLeftMouseDown,down,9100,kCGMouseButtonLeft);
    hwm_mouse_pointer_generation=hwm_pointer_sample_generation_for_event(kCGEventLeftMouseDown);
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    CGEventRef left_drag=pointer_event(kCGEventLeftMouseDragged,left,9110,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,left_drag);
    assert(horizontal_drag(left_drag)); CFRelease(left_drag);
    assert(hwm_drag_window==w->id);
    uint64_t owner=hwm_drag_pointer_generation;
    CGPoint held=hwm_drag_point;
    double world_x=w->strip_world_x,world_y=w->strip_world_y;

    publish(kCGEventRightMouseDown,right,9120,kCGMouseButtonRight);
    CGEventRef right_drag=pointer_event(kCGEventRightMouseDragged,CGPointMake(940,740),9130,kCGMouseButtonRight);
    hwm_pointer_sample_event(kCGEventRightMouseDragged,right_drag);
    assert(horizontal_drag(right_drag)); CFRelease(right_drag);
    assert(hwm_drag_window==w->id && hwm_drag_pointer_generation==owner);
    expect_point(hwm_drag_point,held);
    assert(w->strip_world_x==world_x && w->strip_world_y==world_y);
}

/* History is deliberately bounded. Once a queued press record is overwritten,
 * its callback must fail rather than impersonate a current press. */
static void test_evicted_drag_generation_fails_closed(void)
{
    hwm_pointer_sample_reset();
    CGEventRef evicted=pointer_event(kCGEventLeftMouseDragged,CGPointMake(20,20),10001,kCGMouseButtonLeft);
    publish(kCGEventLeftMouseDown,CGPointMake(10,10),10000,kCGMouseButtonLeft);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,evicted);
    publish(kCGEventLeftMouseUp,CGPointMake(20,20),10002,kCGMouseButtonLeft);
    for(uint64_t i=0;i<HWM_POINTER_SAMPLE_HISTORY;i++) {
        uint64_t time=10100+i*10;
        publish(kCGEventLeftMouseDown,CGPointMake(i,i),time,kCGMouseButtonLeft);
        publish(kCGEventLeftMouseUp,CGPointMake(i,i),time+1,kCGMouseButtonLeft);
    }
    CGPoint point=CGPointZero; uint64_t generation=UINT64_MAX;
    assert(!hwm_pointer_sample_drag_event(evicted,&point,&generation));
    assert(generation==0);
    CFRelease(evicted);
}

int main(void)
{
    @autoreleasepool {
        test_delayed_drag_never_remaps_to_right_or_new_left();
        test_three_quick_presses_keep_independent_final_drags();
        test_terminal_point_stays_with_its_left_generation();
        test_monotonic_fixture_timestamps_select_the_current_press();
        test_active_owner_survives_other_button_events();
        test_abort_rejects_late_drag();
        test_controller_applies_final_queued_drag_after_release();
        test_right_drag_ignores_prior_left_release();
        test_native_window_change_uses_active_left_generation();
        test_queued_left_drag_keeps_its_event_point_after_right_down();
        test_queued_drag_uses_its_generation_after_next_left_down();
        test_rejected_other_button_drag_cannot_move_left_owner();
        test_evicted_drag_generation_fails_closed();
        puts("plane input queue tests passed");
    }
    return 0;
}
