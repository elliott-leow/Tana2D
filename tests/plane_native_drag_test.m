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
    CGPoint held=CGPointMake(first->strip_world_x,first->strip_world_y);
    int commits=test_haptic_commits;
    native_begin(following,CGPointMake(620,230),CGPointMake(820,460));
    assert(first->strip_world_x==held.x && first->strip_world_y==held.y);
    assert(test_haptic_commits==commits);
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
    CGPoint held=CGPointMake(w->strip_world_x,w->strip_world_y);
    int commits=test_haptic_commits;
    /* The runtime CG stub now returns an invalid presentation frame, exactly
     * like an unavailable CGWindowList sample. The hard deadline still ends
     * ownership, but cannot turn that absence into a neighbour snap. */
    presentation_unavailable=true;
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native);
    assert(w->strip_world_x==held.x && w->strip_world_y==held.y);
    assert(test_haptic_commits==commits);
    assert(w->strip_native_move_pending);
    int before=plane_transform_calls[0];
    projected[0].origin=CGPointMake(900,300);
    hwm_render(&view,clock_now+.01);
    assert(plane_transform_calls[0]==before && projected[0].origin.x==900);
    presentation_unavailable=false;
    hwm_render(&view,clock_now+.02);
    assert(!w->strip_native_move_pending);
    assert(projected[0].origin.x==900 && projected[0].origin.y==300);
    assert(w->strip_world_x==888 && w->strip_world_y==249);
}

static void native_press_and_motion(struct window *w,CGPoint point)
{
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[w->id-1];
    g_mouse_state.current_action=MOUSE_MODE_NONE; g_mouse_state.down_location=point;
    CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,point,kCGMouseButtonLeft);
    CGEventSetTimestamp(down,native_timestamp+=10);
    hwm_pointer_sample_event(kCGEventLeftMouseDown,down);
    hwm_mouse_pointer_button=kCGMouseButtonLeft;
    hwm_mouse_pointer_generation=hwm_pointer_sample_generation_for_event_ref(down);
    CFRelease(down);
    horizontal_mouse_down(w,point);
    assert(!hwm_edge_window); // A normal-scale top-band press remains native.
    CGEventRef drag=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDragged,CGPointMake(point.x+20,point.y+10),kCGMouseButtonLeft);
    CGEventSetTimestamp(drag,native_timestamp+=1);
    hwm_pointer_sample_event(kCGEventLeftMouseDragged,drag);
    assert(horizontal_drag(drag)); CFRelease(drag);
    assert(hwm_drag_native && hwm_drag_window==w->id);
}

static void test_display_moves_before_native_anchor(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    CGRect anchor=actual[0],first=projected[0];
    w->layer=7; // An explicit layer survives the temporary drag layer.
    native_press_and_motion(w,CGPointMake(CGRectGetMidX(first),first.origin.y+2));
    assert(!hwm_drag_native_moved && !hwm_drag_committed);
    projected[0].origin=CGPointMake(300,250);
    assert(hwm_drag_native_sync(&view,w));
    assert(CGRectEqualToRect(actual[0],anchor));
    assert(w->strip_world_x==288 && w->strip_world_y==199);
    assert(CGRectEqualToRect(drag_border_frame,projected[0]));
    assert(CGRectEqualToRect(hwm_feedback_plane_frame(&view,w),projected[0]));
    assert(undo_captures==1);
    assert(resize_cancellations==1);
    assert(horizontal_drop(w,CGPointZero));
    clock_now+=.06; hwm_drag_autoscroll(&view,clock_now);
    assert(hwm_drag_native); // An apparently stable early sample is not final.
    projected[0].origin=CGPointMake(340,270);
    clock_now+=.03; hwm_drag_autoscroll(&view,clock_now);
    assert(w->strip_world_x==328 && w->strip_world_y==219);
    clock_now+=.07; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && test_layer[0]==7);
    hwm_render(&view,clock_now);
    assert(projected[0].origin.x==340 && projected[0].origin.y==270);
    view.strip_offset+=80; hwm_render(&view,clock_now+.01);
    assert(projected[0].origin.x==260 && w->strip_world_x==328);
}

static void test_body_selection_is_only_observed(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0]; CGRect shown=projected[0];
    int calls=scale_calls;
    native_press_and_motion(w,CGPointMake(CGRectGetMidX(shown),CGRectGetMidY(shown)));
    assert(!hwm_drag_native_moved && !hwm_drag_committed && undo_captures==0 && resize_cancellations==0);
    assert(horizontal_drop(w,CGPointZero));
    clock_now+=.151; hwm_drag_autoscroll(&view,clock_now);
    hwm_render(&view,clock_now);
    assert(!hwm_drag_window && undo_captures==0 && scale_calls==calls);
    assert(CGRectEqualToRect(projected[0],shown));
}

static void test_border_failure_does_not_discard_native_sample(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    native_press_and_motion(w,CGPointMake(100,80));
    projected[0].origin=CGPointMake(450,300); drag_border_fails=true;
    assert(hwm_drag_native_sync(&view,w));
    assert(w->strip_world_x==438 && w->strip_world_y==249);
    drag_border_fails=false; hwm_drag_force_finalize(&view,false);
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
    clock_now+=.05; hwm_drag_autoscroll(&view,clock_now);
    assert(hwm_drag_window==w->id); // Early stable samples cannot end the grace period.
    actual[0].origin=CGPointMake(610,432); projected[0].origin=CGPointMake(350,203);
    clock_now+=.025; hwm_drag_autoscroll(&view,clock_now);
    assert(w->strip_world_x==338 && w->strip_world_y==152);
    clock_now+=.07; hwm_drag_autoscroll(&view,clock_now);
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

static void test_locked_native_surface_tracks_recorded_pointer(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    CGPoint shown=projected[0].origin;
    native_press_and_motion(w,CGPointMake(shown.x+70,shown.y+14));
    assert(!hwm_drag_native_moved);
    /* AppKit moves its anchor, but a presentation lock leaves the public
     * rectangle unchanged. The native stream must still move the surface. */
    actual[0].origin.x+=30;
    int before=plane_transform_calls[0];
    assert(hwm_drag_native_sync(&view,w));
    assert(hwm_drag_native_projected && plane_transform_calls[0]>before);
    assert(fabs(projected[0].origin.x-shown.x-20)<1);
    assert(fabs(projected[0].origin.y-shown.y-10)<1);
    hwm_drag_force_finalize(&view,false);
}

static void test_locked_native_recovery_uses_anchor_delta(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    CGPoint shown=projected[0].origin;
    native_press_and_motion(w,CGPointMake(shown.x+70,shown.y+14));
    actual[0].origin.x+=30;
    assert(hwm_drag_native_sync(&view,w));
    CGPoint accepted=projected[0].origin;
    physical_left_button_down=true;
    assert(hwm_drag_native_tap_disabled_recover(&view));
    actual[0].origin.x+=40; actual[0].origin.y+=25;
    assert(hwm_drag_native_tap_disabled_recover(&view));
    assert(fabs(projected[0].origin.x-accepted.x-40)<1);
    assert(fabs(projected[0].origin.y-accepted.y-25)<1);
    physical_left_button_down=false;
    assert(hwm_drag_native_tap_disabled_recover(&view));
    clock_now+=.16; hwm_drag_autoscroll(&view,clock_now);
    assert(!hwm_drag_window && !hwm_drag_native);
}

static void test_locked_native_without_pointer_uses_anchor_delta(void)
{
    reset(); hwm_render(&view,clock_now);
    struct window *w=&windows[0]; CGPoint shown=projected[0].origin;
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    g_mouse_state.down_location=CGPointMake(shown.x+70,shown.y+14);
    hwm_drag_point=g_mouse_state.down_location; hwm_drag_started(w);
    assert(!hwm_drag_pointer_generation);
    for(int i=1;i<=3;i++) {
        actual[0].origin.x+=40; actual[0].origin.y+=25;
        assert(hwm_drag_native_sync(&view,w));
        assert(fabs(projected[0].origin.x-shown.x-i*40)<1);
        assert(fabs(projected[0].origin.y-shown.y-i*25)<1);
    }
    hwm_drag_force_finalize(&view,false);
}

static void test_unscaled_native_drag_ignores_camera_paint_lag(void)
{
    reset();hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    w->strip_plane_scaled=false;projected[0]=actual[0];
    CGPoint original=CGPointMake(w->strip_world_x,w->strip_world_y);
    g_mouse_state.window=w;g_mouse_state.window_frame=actual[0];
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    g_mouse_state.down_location=CGPointMake(actual[0].origin.x+70,actual[0].origin.y+14);
    hwm_drag_point=g_mouse_state.down_location;hwm_drag_started(w);
    assert(hwm_drag_native_unscaled);
    actual[0].origin.x+=60;actual[0].origin.y+=30;
    projected[0].origin.x+=50;projected[0].origin.y+=25;
    assert(hwm_drag_native_sync(&view,w));
    assert(w->strip_world_x==original.x+60&&w->strip_world_y==original.y+30);
    hwm_drag_force_finalize(&view,false);
}

int main(void)
{
    test_unscaled_native_drag_ignores_camera_paint_lag();
    test_locked_native_without_pointer_uses_anchor_delta();
    test_locked_native_recovery_uses_anchor_delta();
    test_locked_native_surface_tracks_recorded_pointer();
    @autoreleasepool {
        test_next_native_press_finishes_the_previous_release();
        test_interrupted_native_settle_never_snaps();
        test_native_deadline_does_not_snap_without_a_displayed_sample();
        test_display_moves_before_native_anchor();
        test_body_selection_is_only_observed();
        test_border_failure_does_not_discard_native_sample();
        test_tap_disable_retains_held_native_drag_until_physical_up();
        test_recovered_native_drag_yields_to_next_press();
        test_tap_disable_after_physical_up_clears_legacy_owner();
        test_late_native_sample_commits_once();
        test_native_finish_is_bounded_and_never_edgepans();
        puts("plane native drag tests passed");
    }
}
