#ifndef HWM_PLANE_POINTER_SAMPLE_H
#define HWM_PLANE_POINTER_SAMPLE_H
#include <os/lock.h>

/* Event-tap state runs ahead of the event-loop queue.  Keep pointer samples
 * with the press that produced them: a later press must never rewrite an old
 * queued drag.  The ring deliberately retains several completed presses so a
 * busy queue can still consume the last drag of each press using its original
 * event point. */
#define HWM_POINTER_SAMPLE_HISTORY 32
typedef struct {
    CGPoint last_point,last_drag_point;
    uint64_t generation,down_time,terminal_time,last_drag_serial;
    bool active,aborted,valid_drag;
} HWMPlanePointerPress;
static os_unfair_lock hwm_pointer_sample_lock=OS_UNFAIR_LOCK_INIT;
static CGPoint hwm_pointer_sample_point;
static bool hwm_pointer_sample_valid;
static HWMPlanePointerPress hwm_pointer_sample_press[2][HWM_POINTER_SAMPLE_HISTORY];
static uint64_t hwm_pointer_sample_active[2],hwm_pointer_sample_last[2];
static uint64_t hwm_pointer_sample_next_generation,hwm_pointer_sample_next_serial;

static int hwm_pointer_sample_button(CGEventType type)
{
    if(type==kCGEventLeftMouseDown || type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp) return 0;
    if(type==kCGEventRightMouseDown || type==kCGEventRightMouseDragged || type==kCGEventRightMouseUp) return 1;
    return -1;
}
static HWMPlanePointerPress *hwm_pointer_sample_find_locked(int button,uint64_t generation)
{
    if(button<0 || button>1 || !generation) return NULL;
    HWMPlanePointerPress *press=&hwm_pointer_sample_press[button][generation%HWM_POINTER_SAMPLE_HISTORY];
    return press->generation==generation ? press : NULL;
}
static HWMPlanePointerPress *hwm_pointer_sample_find_generation_locked(uint64_t generation)
{
    for(int button=0;button<2;button++) {
        HWMPlanePointerPress *press=hwm_pointer_sample_find_locked(button,generation);
        if(press) return press;
    }
    return NULL;
}
static HWMPlanePointerPress *hwm_pointer_sample_find_time_locked(int button,uint64_t time)
{
    HWMPlanePointerPress *found=NULL;
    for(size_t i=0;i<HWM_POINTER_SAMPLE_HISTORY;i++) {
        HWMPlanePointerPress *press=&hwm_pointer_sample_press[button][i];
        if(!press->generation || time<press->down_time || (press->terminal_time && time>press->terminal_time)) continue;
        if(!found || press->down_time>found->down_time) found=press;
    }
    return found;
}
/* Capture a queued drag's own event point and its press generation. It returns
 * false only for an explicitly aborted press; callers may separately request
 * that generation's final coalesced drag after physical mouse-up. */
static bool hwm_pointer_sample_drag_event(CGEventRef event,CGPoint *point,uint64_t *generation)
{
    if(!event || !point) return false;
    int button=hwm_pointer_sample_button(CGEventGetType(event));
    if(button<0) return false;
    *point=CGEventGetLocation(event);
    uint64_t time=CGEventGetTimestamp(event),found_generation=0; bool aborted=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_time_locked(button,time);
    if(press) { found_generation=press->generation; aborted=press->aborted; }
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    if(generation) *generation=found_generation;
    return !aborted;
}
static uint64_t hwm_pointer_sample_generation_for_event(CGEventType type)
{
    int button=hwm_pointer_sample_button(type); uint64_t generation=0;
    if(button<0) return 0;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    generation=hwm_pointer_sample_active[button] ?: hwm_pointer_sample_last[button];
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return generation;
}
/* Resolve a queued event by its original timestamp, rather than whichever
 * press is active when the serialized event loop reaches it. */
static uint64_t hwm_pointer_sample_generation_for_event_ref(CGEventRef event)
{
    if(!event) return 0;
    int button=hwm_pointer_sample_button(CGEventGetType(event));
    if(button<0) return 0;
    uint64_t generation=0;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_time_locked(button,CGEventGetTimestamp(event));
    if(press && !press->aborted) generation=press->generation;
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return generation;
}
/* Return a newer drag from this exact press.  A terminal mouse-up has no
 * point-bearing effect here, so the final valid drag remains available. */
static bool hwm_pointer_sample_drag_for_generation(uint64_t generation,uint64_t after_serial,CGPoint *point,uint64_t *serial)
{
    if(!generation || !point) return false;
    bool found=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_locked(0,generation);
    if(press && !press->aborted && press->valid_drag && press->last_drag_serial>after_serial) {
        *point=press->last_drag_point;
        if(serial) *serial=press->last_drag_serial;
        found=true;
    }
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return found;
}
/* Return this exact left press's final physical point. Unlike the drag
 * accessor, mouse-up updates last_point and is intentionally observable for
 * terminal resize/release logic. */
static bool hwm_pointer_sample_point_for_generation(uint64_t generation,CGPoint *point)
{
    if(!generation || !point) return false;
    bool found=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_locked(0,generation);
    if(press && !press->aborted) {
        *point=press->last_point;
        found=true;
    }
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return found;
}
static bool hwm_pointer_sample_generation_is_aborted(uint64_t generation)
{
    if(!generation) return false;
    bool aborted=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_generation_locked(generation);
    if(press) aborted=press->aborted;
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return aborted;
}
/* The serialized event loop uses this before assigning its one legacy mouse
 * owner to another button.  An up event has already made its own press
 * inactive when that handler runs, so this is deliberately separate from the
 * matching-up check. */
static bool hwm_pointer_sample_generation_is_active(uint64_t generation)
{
    if(!generation) return false;
    bool active=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_generation_locked(generation);
    if(press) active=press->active && !press->aborted;
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return active;
}
/* Atomically validate an owning press and read its point.  Autoscroll must use
 * this instead of checking active and then reading the global latest sample:
 * an unrelated right-button callback may arrive between those operations. */
static bool hwm_pointer_sample_active_point_for_generation(uint64_t generation,CGPoint *point)
{
    if(!generation || !point) return false;
    bool active=false;
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    HWMPlanePointerPress *press=hwm_pointer_sample_find_generation_locked(generation);
    if(press && press->active && !press->aborted) {
        *point=press->last_point;
        active=true;
    }
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return active;
}
static void hwm_pointer_sample_abort_locked(int button)
{
    uint64_t generation=hwm_pointer_sample_active[button];
    HWMPlanePointerPress *press=hwm_pointer_sample_find_locked(button,generation);
    if(press) { press->aborted=true; press->active=false; if(!press->terminal_time) press->terminal_time=UINT64_MAX; }
    hwm_pointer_sample_active[button]=0;
}
/* Called synchronously when a tap-disabled/cancellation path owns the
 * interaction.  Queued callbacks can query the generation and become no-ops. */
static __attribute__((unused)) void hwm_pointer_sample_abort_left_press(void)
{
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    hwm_pointer_sample_abort_locked(0);
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    atomic_store(&hwm_drag_release_pending,true);
}
/* Deterministic harness reset; production never calls this while input runs. */
static __attribute__((unused)) void hwm_pointer_sample_reset(void)
{
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    hwm_pointer_sample_point=CGPointZero; hwm_pointer_sample_valid=false;
    memset(hwm_pointer_sample_press,0,sizeof(hwm_pointer_sample_press));
    memset(hwm_pointer_sample_active,0,sizeof(hwm_pointer_sample_active));
    memset(hwm_pointer_sample_last,0,sizeof(hwm_pointer_sample_last));
    hwm_pointer_sample_next_generation=0; hwm_pointer_sample_next_serial=0;
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
}
static void hwm_pointer_sample_event(CGEventType type,CGEventRef event)
{
    int button=hwm_pointer_sample_button(type);
    bool down=type==kCGEventLeftMouseDown || type==kCGEventRightMouseDown;
    bool up=type==kCGEventLeftMouseUp || type==kCGEventRightMouseUp;
    bool drag=type==kCGEventLeftMouseDragged || type==kCGEventRightMouseDragged;
    if(button>=0 && event) {
        CGPoint point=CGEventGetLocation(event); uint64_t time=CGEventGetTimestamp(event);
        os_unfair_lock_lock(&hwm_pointer_sample_lock);
        hwm_pointer_sample_point=point; hwm_pointer_sample_valid=true;
        uint64_t generation=hwm_pointer_sample_active[button];
        if(down) {
            /* A replacement down terminates a missing-up predecessor. This
             * prevents a retained old session from staying active after a
             * later press of the same button owns the physical pointer. */
            HWMPlanePointerPress *previous=hwm_pointer_sample_find_locked(button,generation);
            if(previous && previous->active) {
                previous->active=false;
                previous->terminal_time=time;
            }
            generation=++hwm_pointer_sample_next_generation;
            HWMPlanePointerPress *press=&hwm_pointer_sample_press[button][generation%HWM_POINTER_SAMPLE_HISTORY];
            *press=(HWMPlanePointerPress){.last_point=point,.generation=generation,.down_time=time,.active=true};
            hwm_pointer_sample_active[button]=hwm_pointer_sample_last[button]=generation;
        }
        HWMPlanePointerPress *press=hwm_pointer_sample_find_locked(button,generation);
        if(press) {
            press->last_point=point;
            if(drag) { press->last_drag_point=point; press->last_drag_serial=++hwm_pointer_sample_next_serial; press->valid_drag=true; }
            if(up) { press->active=false; press->terminal_time=time; hwm_pointer_sample_active[button]=0; hwm_pointer_sample_last[button]=generation; }
        }
        os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    }
    /* This fence is solely the active left-button terminal state. A right
     * press must not revive an old left drag. Generation-qualified consumers
     * provide the stronger protection across a subsequent left press. */
    if(type==kCGEventLeftMouseDown) atomic_store(&hwm_drag_release_pending,false);
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        os_unfair_lock_lock(&hwm_pointer_sample_lock);
        hwm_pointer_sample_abort_locked(0); hwm_pointer_sample_abort_locked(1);
        os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    }
    if(type==kCGEventLeftMouseUp || type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) atomic_store(&hwm_drag_release_pending,true);
}
static bool hwm_pointer_sample(CGPoint *point)
{
    os_unfair_lock_lock(&hwm_pointer_sample_lock);
    bool valid=hwm_pointer_sample_valid;
    if(valid) *point=hwm_pointer_sample_point;
    os_unfair_lock_unlock(&hwm_pointer_sample_lock);
    return valid;
}
#endif
