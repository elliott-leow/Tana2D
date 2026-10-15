#ifndef HWM_FOCUS_POLICY_H
#define HWM_FOCUS_POLICY_H

#include <stdbool.h>
#include <stdint.h>

/* A delayed focus target is either automatic (camera/gesture follow) or an
 * explicit request (keyboard/selection).  Suppression may discard only the
 * former.  Keep this small state transition shared by Tana and its tests. */
static inline void hwm_focus_queue_enqueue(uint32_t *window, bool *pending,
                                           bool *automatic, uint32_t target,
                                           bool is_automatic)
{
    *window = target;
    *pending = true;
    *automatic = is_automatic;
}

static inline void hwm_focus_queue_clear(uint32_t *window, bool *pending,
                                         bool *automatic)
{
    *window = 0;
    *pending = false;
    *automatic = false;
}

static inline bool hwm_focus_queue_cancel_automatic(uint32_t *window,
                                                     bool *pending,
                                                     bool *automatic)
{
    if (!*pending || !*automatic) return false;
    hwm_focus_queue_clear(window, pending, automatic);
    return true;
}

/* Returns true when the caller should deliver the saved target.  An explicit
 * request remains deliverable even while a menu or popup is open. */
static inline bool hwm_focus_queue_take(uint32_t *window, bool *pending,
                                        bool *automatic, bool suppressed)
{
    if (!*pending) return false;
    bool is_automatic = *automatic;
    *pending = false;
    *automatic = false;
    if (is_automatic && suppressed) {
        *window = 0;
        return false;
    }
    return true;
}

#endif
