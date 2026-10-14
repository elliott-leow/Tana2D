/* Standalone lifecycle regression for src/plane_interaction_lifecycle.m. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

struct window { uint32_t id; };
struct view { int unused; };
static struct view view;
static struct view *hwm_view(void) { return &view; }

static uint32_t hwm_drag_window,hwm_plane_pick_window,hwm_edge_window,hwm_drop_target;
static bool hwm_plane_pick_automatic,hwm_plane_select_click,hwm_drag_cancelled;
static _Atomic bool hwm_drag_native,hwm_resize_captured;
static _Atomic bool hwm_plane_pick_drag_queued;
static int drag_finalizations,native_recoveries,resize_aborts,pointer_aborts;
static bool native_recovery_retained;
static struct window *last_resize_window;
static bool last_resize_kept_capture;
static struct window *legacy_window;
static int legacy_action,legacy_direction,legacy_clears;
static uint64_t legacy_pointer_generation;
static int legacy_pointer_button;
static bool legacy_feedback_live,legacy_feedback_present;
static int legacy_feedback_destroys;

static void hwm_drag_force_finalize(struct view *v,bool snap)
{
    assert(v==&view && !snap);
    ++drag_finalizations;
    hwm_drag_window=0;
    atomic_store(&hwm_drag_native,false);
}
static bool hwm_drag_native_tap_disabled_recover(struct view *v)
{
    assert(v==&view);
    ++native_recoveries;
    return native_recovery_retained;
}
static bool hwm_plane_resize_abort_interaction(struct window *w,bool keep_capture_until_up)
{
    ++resize_aborts; last_resize_window=w; last_resize_kept_capture=keep_capture_until_up;
    hwm_edge_window=0;
    return true;
}
static void hwm_pointer_sample_abort_left_press(void) { ++pointer_aborts; }
static void hwm_plane_clear_legacy_pointer(struct window *w)
{
    if(w && legacy_window!=w) return;
    if(!legacy_window && !legacy_action && !legacy_direction && !legacy_feedback_present) return;
    if(legacy_feedback_present && legacy_feedback_live) ++legacy_feedback_destroys;
    legacy_feedback_present=false;
    legacy_window=NULL; legacy_action=legacy_direction=0; ++legacy_clears;
    legacy_pointer_generation=0; legacy_pointer_button=-1;
}

#include "../src/plane_interaction_lifecycle.m"

static void reset(void)
{
    hwm_drag_window=hwm_plane_pick_window=hwm_edge_window=hwm_drop_target=0;
    hwm_plane_pick_automatic=hwm_plane_select_click=hwm_drag_cancelled=false;
    atomic_store(&hwm_plane_pick_drag_queued,false);
    atomic_store(&hwm_drag_native,false);
    atomic_store(&hwm_resize_captured,false);
    atomic_store(&hwm_plane_tap_captured,false);
    atomic_store(&hwm_plane_tap_aborted_up_pending,false);
    drag_finalizations=native_recoveries=resize_aborts=pointer_aborts=0;
    native_recovery_retained=true;
    last_resize_window=NULL; last_resize_kept_capture=false;
    legacy_window=NULL; legacy_action=legacy_direction=legacy_clears=0;
    legacy_pointer_generation=0; legacy_pointer_button=-1;
    legacy_feedback_live=legacy_feedback_present=false; legacy_feedback_destroys=0;
}

static void test_tap_disabled_invalidates_on_tap_and_finalizes_on_event_loop(void)
{
    reset(); struct window w={.id=7};
    hwm_drag_window=hwm_plane_pick_window=hwm_edge_window=w.id;
    hwm_drop_target=99; hwm_plane_pick_automatic=hwm_plane_select_click=true;
    hwm_drag_cancelled=true; atomic_store(&hwm_plane_pick_drag_queued,true);
    legacy_window=&w; legacy_action=1; legacy_direction=3;
    legacy_pointer_generation=44; legacy_pointer_button=0;
    legacy_feedback_live=legacy_feedback_present=true;
    hwm_plane_interaction_tap_note_plane_event(kCGEventLeftMouseDown);
    atomic_store(&hwm_resize_captured,true);
    assert(hwm_plane_interaction_tap_abort());
    assert(!atomic_load(&hwm_resize_captured));
    /* The tap did not touch event-loop-owned drag/window state. */
    assert(!drag_finalizations && !resize_aborts && hwm_drag_window==w.id);
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_TAP_DISABLED);
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_TAP_DISABLED);
    assert(drag_finalizations==1 && resize_aborts==1 && pointer_aborts==1);
    assert(!hwm_drag_window && !hwm_plane_pick_window && !hwm_edge_window && !hwm_drop_target);
    assert(!hwm_plane_pick_automatic && !hwm_plane_select_click && !hwm_drag_cancelled);
    assert(!atomic_load(&hwm_plane_pick_drag_queued));
    assert(last_resize_window==&w && last_resize_kept_capture);
    assert(legacy_clears==1 && !legacy_window && !legacy_action && !legacy_direction);
    assert(!legacy_pointer_generation && legacy_pointer_button==-1);
    assert(!legacy_feedback_present && legacy_feedback_destroys==1);
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseDragged));
    assert(hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseUp));
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseUp));
    /* A fresh down clears only the old terminal-up fence, so its native up
     * reaches AppKit even when the prior plane up never arrived. */
    hwm_plane_interaction_tap_note_plane_event(kCGEventLeftMouseDown);
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseUp));
    /* A native title-bar drag was never plane-captured, so its up passes. */
    reset(); assert(!hwm_plane_interaction_tap_abort());
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseUp));
}

static void test_tap_disabled_native_drag_defers_finalization_to_native_recovery(void)
{
    reset(); struct window w={.id=7};
    hwm_drag_window=w.id;
    atomic_store(&hwm_drag_native,true);
    legacy_window=&w;
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_TAP_DISABLED);
    assert(native_recoveries==1 && drag_finalizations==0);
    assert(hwm_drag_window==w.id && atomic_load(&hwm_drag_native));
    assert(!legacy_clears);

    /* A real lifecycle boundary still owns an immediate model finalization. */
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_SUSPEND);
    assert(drag_finalizations==1 && !hwm_drag_window);
    assert(legacy_clears==1 && !legacy_window);
}

static void test_tap_disabled_native_drag_finalizes_when_recovery_loses_window(void)
{
    reset(); struct window w={.id=7};
    hwm_drag_window=w.id;
    atomic_store(&hwm_drag_native,true);
    legacy_window=&w;
    native_recovery_retained=false;
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_TAP_DISABLED);
    assert(native_recoveries==1 && drag_finalizations==1);
    assert(!hwm_drag_window && !atomic_load(&hwm_drag_native));
    assert(legacy_clears==1 && !legacy_window);
}

static void test_repeated_cleanup_and_unrelated_removal_are_idempotent(void)
{
    reset(); struct window w={.id=7},other={.id=8};
    hwm_drag_window=hwm_plane_pick_window=hwm_edge_window=w.id;
    hwm_plane_abort_interaction(&other,HWM_PLANE_INTERRUPT_UNMANAGE);
    assert(!drag_finalizations && !resize_aborts && !pointer_aborts && !legacy_clears);
    assert(hwm_drag_window==w.id && hwm_plane_pick_window==w.id && hwm_edge_window==w.id);
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_UNMANAGE);
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_DESTROY);
    assert(drag_finalizations==1 && resize_aborts==1 && pointer_aborts==1);
    assert(!hwm_drag_window && !hwm_plane_pick_window && !hwm_edge_window);
}

static void test_unmanage_clears_its_legacy_pointer_without_touching_other_window(void)
{
    reset(); struct window w={.id=7},other={.id=8};
    legacy_window=&w; legacy_action=1; legacy_direction=3;
    legacy_pointer_generation=45; legacy_pointer_button=0;
    hwm_plane_abort_interaction(&other,HWM_PLANE_INTERRUPT_UNMANAGE);
    assert(legacy_window==&w && !legacy_clears);
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_UNMANAGE);
    assert(!legacy_window && !legacy_action && !legacy_direction && legacy_clears==1);
    assert(!legacy_pointer_generation && legacy_pointer_button==-1);
}

static void test_legacy_feedback_cleanup_never_dereferences_a_removed_node(void)
{
    reset(); struct window w={.id=7};
    legacy_window=&w; legacy_feedback_live=legacy_feedback_present=true;
    hwm_plane_abort_interaction(&w,HWM_PLANE_INTERRUPT_UNMANAGE);
    assert(!legacy_feedback_present && legacy_feedback_destroys==1);

    reset(); legacy_feedback_live=false; legacy_feedback_present=true;
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_PAUSE);
    assert(!legacy_feedback_present && !legacy_feedback_destroys);
}

static void test_restart_resume_does_not_reanimate_a_cancelled_press(void)
{
    reset(); struct window w={.id=7};
    hwm_drag_window=hwm_plane_pick_window=w.id;
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_SUSPEND);
    assert(drag_finalizations==1 && !hwm_drag_window && !hwm_plane_pick_window);
    /* Resume itself must not consume the next fresh press. */
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_RESUME);
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseDown));
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseUp));
}

static void test_mission_control_retires_native_owner_without_mouse_up(void)
{
    reset(); struct window w={.id=7};
    hwm_drag_window=w.id; atomic_store(&hwm_drag_native,true);
    legacy_window=&w; legacy_pointer_generation=45; legacy_pointer_button=0;
    horizontal_mission_control_enter();
    assert(drag_finalizations==1 && !native_recoveries && !hwm_drag_window);
    assert(!legacy_window && !legacy_pointer_generation && legacy_pointer_button==-1);
    horizontal_mission_control_enter();
    assert(drag_finalizations==1);
    assert(!hwm_plane_interaction_tap_consume_aborted_up(kCGEventLeftMouseDown));
}

int main(void)
{
    @autoreleasepool {
        test_tap_disabled_invalidates_on_tap_and_finalizes_on_event_loop();
        test_tap_disabled_native_drag_defers_finalization_to_native_recovery();
        test_tap_disabled_native_drag_finalizes_when_recovery_loses_window();
        test_repeated_cleanup_and_unrelated_removal_are_idempotent();
        test_unmanage_clears_its_legacy_pointer_without_touching_other_window();
        test_legacy_feedback_cleanup_never_dereferences_a_removed_node();
        test_restart_resume_does_not_reanimate_a_cancelled_press();
        test_mission_control_retires_native_owner_without_mouse_up();
        puts("plane lifecycle tests passed");
    }
}
