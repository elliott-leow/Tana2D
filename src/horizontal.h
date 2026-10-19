#ifndef HORIZONTAL_WM_H
#define HORIZONTAL_WM_H
#include <stdatomic.h>
// All model mutations run on yabai's serialized event loop. The event tap and
// display link only enqueue input/ticks; neither performs Accessibility work.
static bool horizontal_flush_node(struct window_node *node);
static void horizontal_tick(void);
static void horizontal_input(void *context, int action);
static bool horizontal_event(CGEventType type, CGEventRef event);
static void horizontal_focused(struct window *window, struct view *view);
static bool horizontal_drop(struct window *window, CGPoint point);
static bool horizontal_drag(CGEventRef event);
static bool horizontal_owns_native_drag(void);
static uint64_t horizontal_destination(struct window *window, uint64_t sid);
static void horizontal_space_changed(void);
static void horizontal_command(FILE *rsp, char *message);
static double horizontal_ease(double t);
static void horizontal_begin(void);
static void horizontal_window_added(struct window *window);
static bool horizontal_window_changed(struct window *window, struct view *view, bool resized);
static bool horizontal_window_moved(struct window *window);
/* Used by the compact plane controls; it only queues a normal manager action. */
void horizontal_plane_action(const char *name);
#endif

static bool horizontal_hover_allowed(CGPoint point);
static bool horizontal_native_hover(CGPoint point, uint64_t timestamp);
static void horizontal_activated(struct application *application);
static void horizontal_unmanaging(struct window *window);
static void horizontal_removing(struct window *window, bool whole_app);

static void horizontal_resume(void);
static void horizontal_mission_control_enter(void);

static void horizontal_hover_received(struct window *window);

static void horizontal_ordered(uint32_t wid);

static void horizontal_reconcile(void);

static void horizontal_focus_requested(uint32_t wid);

static void horizontal_focus_transition(struct window *previous,struct window *next);
static void horizontal_overview_select(uint32_t wid, pid_t pid);
static void horizontal_overview_done(void);
static void horizontal_event_timed(int type,double ms);
static void horizontal_event_settle(void);
/* Whether an event must wait for the last frame's helper reply before it is
 * handled. Input that only moves the camera, and position echoes that are
 * ignored while the camera moves, settle themselves if they read geometry. */
static bool horizontal_event_settles(int type, void *context, int param1);
/* At most one move notification per window waits in the queue: its handler
 * reads current geometry, never the notification's, so a second one adds
 * nothing but queue time ahead of the next frame. A slot taken by another
 * window just lets the notification through. */
static _Atomic uint32_t horizontal_moved_slots[1024];
static inline bool horizontal_moved_claim(uint32_t wid)
{
    if(!wid) return true;
    uint32_t expected=0;
    if(atomic_compare_exchange_strong(&horizontal_moved_slots[wid&1023],&expected,wid)) return true;
    return expected!=wid;
}
static inline void horizontal_moved_release(uint32_t wid)
{
    uint32_t expected=wid;
    if(wid) atomic_compare_exchange_strong(&horizontal_moved_slots[wid&1023],&expected,0);
}
static uint32_t horizontal_expected_focus(struct application *application);

static void horizontal_mouse_down(struct window *window, CGPoint point);
static bool horizontal_resize_event(struct window *window);
/* Set while a pointer event of that kind is queued; coalesce each mouse
 * button independently so an in-flight right drag never drops a left drag. */
static _Atomic bool horizontal_moved_queued, horizontal_dragged_queued[2];
static pthread_mutex_t horizontal_hover_sample_lock=PTHREAD_MUTEX_INITIALIZER;
static CGPoint horizontal_hover_point;
static uint64_t horizontal_hover_timestamp;
static _Atomic bool hwm_drag_release_pending;
/* Read by the event loop before horizontal.m's implementation is included. */
static _Atomic bool hwm_drag_native;
/* The serialized mouse state is tied to this exact button-down generation. */
static uint64_t hwm_mouse_pointer_generation;
static int hwm_mouse_pointer_button=-1;
#include "plane_pointer_sample.h"
static void horizontal_title_changed(struct window *window);

static void horizontal_input_trace(CGEventType type,CGEventRef event);
