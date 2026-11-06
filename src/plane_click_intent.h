#ifndef HWM_PLANE_CLICK_INTENT_H
#define HWM_PLANE_CLICK_INTENT_H

#include <stdbool.h>
#include <stdint.h>
#include <math.h>

/* State represents deliberate actions, never passive focus or pointer hover.
 * Its owner must serialize access, including decision and completion events. */
typedef struct {
    uint32_t interacted_window;
    double interaction_time;
    double navigation_time;
    bool has_interaction;
    bool browsing;
} HWMPlaneClickIntent;

typedef struct {
    uint32_t window;
    double now;
    double scale;
    double far_threshold;
    /* True only for a managed window's unmodified, primary, single body
     * click; native controls, titlebars, edges and other gestures are false. */
    bool eligible;
} HWMPlaneClickContext;

/* A bounded history avoids interpreting a much later ordinary click as part
 * of a stale browsing session. Clock rollback invalidates history as well. */
#define HWM_PLANE_CLICK_HISTORY_SECONDS 30.0

static inline bool hwm_plane_click_recent(double now, double then)
{
    return isfinite(now) && isfinite(then) && now >= then &&
           now - then <= HWM_PLANE_CLICK_HISTORY_SECONDS;
}

/* Call only for actual camera navigation (pan, pinch, or equivalent), not
 * camera animation caused by selecting a window. */
static inline void hwm_plane_click_note_navigation(HWMPlaneClickIntent *state, double now)
{
    state->browsing = isfinite(now);
    state->navigation_time = now;
}

/* Call after a completed deliberate app interaction OR completed selection.
 * Call neither for hover nor for a cancelled press. */
static inline void hwm_plane_click_note_interaction(HWMPlaneClickIntent *state,
                                                     uint32_t window, double now)
{
    state->browsing = false;
    state->has_interaction = window != 0 && isfinite(now);
    state->interacted_window = window;
    state->interaction_time = now;
}

static inline void hwm_plane_click_reset(HWMPlaneClickIntent *state)
{
    *state = (HWMPlaneClickIntent){0};
}

/* Decide on mouse-down using a stable snapshot. If true, capture the gesture;
 * commit selection only on mouse-up. A drag or cancellation must not commit a
 * selection. A false result leaves the entire gesture to the application. */
static inline bool hwm_plane_click_should_select(const HWMPlaneClickIntent *state,
                                                  HWMPlaneClickContext context)
{
    if (!context.eligible || !context.window || !isfinite(context.scale) ||
        context.scale <= 0.0 || context.scale >= 1.0) return false;
    // Preserve the existing opt-out from automatic click-to-enter.
    if(isfinite(context.far_threshold) && context.far_threshold<=0.0) return false;
    if (isfinite(context.far_threshold) && context.scale < context.far_threshold)
        return true;
    if (state->browsing && hwm_plane_click_recent(context.now, state->navigation_time))
        return true;
    return state->has_interaction &&
           hwm_plane_click_recent(context.now, state->interaction_time) &&
           state->interacted_window != context.window;
}

#endif
