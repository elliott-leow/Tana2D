/* One owner for abandoning a plane pointer session.  This is deliberately
 * separate from the event-tap capture: a cancelled press may still need its
 * eventual mouse-up consumed, but it must never retain model ownership. */
typedef enum {
    HWM_PLANE_INTERRUPT_TAP_DISABLED,
    HWM_PLANE_INTERRUPT_PAUSE,
    HWM_PLANE_INTERRUPT_SUSPEND,
    HWM_PLANE_INTERRUPT_SHUTDOWN,
    HWM_PLANE_INTERRUPT_UNMANAGE,
    HWM_PLANE_INTERRUPT_DESTROY,
    HWM_PLANE_INTERRUPT_RESUME,
    HWM_PLANE_INTERRUPT_MISSION_CONTROL,
} HWMPlaneInterruptReason;

/* Event-tap ownership is intentionally distinct from manager ownership.  The
 * tap writes only these atomics; all window/model fields remain event-loop
 * owned. */
static _Atomic bool hwm_plane_tap_captured;
static _Atomic bool hwm_plane_tap_aborted_up_pending;

/* These helpers live beside the subsystem whose final displayed state they
 * understand.  The lifecycle owner decides when they must run. */
static void hwm_drag_force_finalize(struct view *view,bool snap);
static bool hwm_drag_native_tap_disabled_recover(struct view *view);
static bool hwm_plane_resize_abort_interaction(struct window *window,bool keep_capture_until_up);
static void hwm_pointer_sample_abort_left_press(void);
/* Implemented by the integration owner against yabai's event-loop-only
 * mouse state. Passing NULL clears any abandoned legacy pointer session;
 * passing a window clears only that window's session. */
static void hwm_plane_clear_legacy_pointer(struct window *window);

/* Call on the event-tap thread only after a plane pick/resize event was
 * claimed. Native title-bar drags must never call this. */
static void hwm_plane_interaction_tap_note_plane_event(CGEventType type)
{
    if(type==kCGEventLeftMouseDown) atomic_store(&hwm_plane_tap_captured,true);
    if(type==kCGEventLeftMouseUp) { atomic_store(&hwm_plane_tap_captured,false); atomic_store(&hwm_plane_tap_aborted_up_pending,false); }
}

/* Tap-disabled is asynchronous to the manager.  It may invalidate the
 * generation/capture fence here, but must queue hwm_plane_abort_interaction()
 * to the serialized event loop for every model or WindowServer mutation. */
static bool hwm_plane_interaction_tap_abort(void)
{
    bool captured=atomic_exchange(&hwm_plane_tap_captured,false);
    hwm_pointer_sample_abort_left_press();
    /* Do not leave the legacy resize fast-path owning a later native up.  The
     * independent terminal-up fence below is the only ownership which
     * survives the interruption. */
    atomic_store(&hwm_resize_captured,false);
    if(captured) atomic_store(&hwm_plane_tap_aborted_up_pending,true);
    return captured;
}

/* The event tap uses this only after normal plane pick/resize mouse-up routing
 * declined the event. It therefore eats a late terminal up from a cancelled
 * plane capture, never an AppKit title-bar release. */
static bool hwm_plane_interaction_tap_consume_aborted_up(CGEventType type)
{
    if(type==kCGEventLeftMouseDown) atomic_store(&hwm_plane_tap_aborted_up_pending,false);
    if(type!=kCGEventLeftMouseUp) return false;
    return atomic_exchange(&hwm_plane_tap_aborted_up_pending,false);
}

static bool hwm_plane_interaction_matches(struct window *window,uint32_t identifier)
{
    return identifier && (!window || identifier==window->id);
}

/* Preserve the already presented position.  Interrupts are never undo: a
 * timeout, lock, or window lifecycle event is not a user request to rewind a
 * drag.  This must be called before the caller removes `window` from the
 * manager, while the helper can still restore its shadow and layer. */
static void hwm_plane_abort_interaction(struct window *window,HWMPlaneInterruptReason reason)
{
    (void)reason;
    bool drag=hwm_plane_interaction_matches(window,hwm_drag_window);
    bool pick=hwm_plane_interaction_matches(window,hwm_plane_pick_window);
    bool edge=hwm_plane_interaction_matches(window,hwm_edge_window);
    if(window && !drag && !pick && !edge) {
        /* Removal/minimize can interrupt an ordinary yabai mouse press even
         * when no plane owner was created. */
        hwm_plane_clear_legacy_pointer(window);
        return;
    }

    /* Tap-disabled has already invalidated synchronously. Other serialized
     * lifecycle paths still need the same generation fence. */
    if(reason!=HWM_PLANE_INTERRUPT_TAP_DISABLED) {
        (void)hwm_plane_interaction_tap_abort();
    }

    /* AppKit continues tracking a native title-bar drag while the event tap is
     * disabled.  Keep that ownership intact and let its physical-button poll
     * begin the normal bounded native release; forcing layout here would race
     * AppKit's final presentation update. */
    bool retained_native_recovery=false;
    if(drag) {
        if(reason==HWM_PLANE_INTERRUPT_TAP_DISABLED && atomic_load(&hwm_drag_native)) {
            retained_native_recovery=hwm_drag_native_tap_disabled_recover(hwm_view());
            /* The native window can disappear before recovery polls it. Do not
             * leave its former ID owning the plane when recovery has nothing
             * to retain. */
            if(!retained_native_recovery) hwm_drag_force_finalize(hwm_view(),false);
        } else {
            hwm_drag_force_finalize(hwm_view(),false);
        }
    }
    if(edge) (void)hwm_plane_resize_abort_interaction(window,true);

    if(pick) hwm_plane_pick_window=0;
    if(!window || pick || drag || edge) {
        hwm_plane_pick_automatic=false;
        hwm_plane_select_click=false;
        atomic_store(&hwm_plane_pick_drag_queued,false);
        hwm_drop_target=0;
        hwm_drag_cancelled=false;
    }
    /* There is no reliable synthetic mouse-up after a disabled tap. Clear the
     * legacy event-loop owner once this serialized interruption owns it. A
     * native title-bar drag deliberately keeps it through agent2's physical
     * button recovery and clears it when that recovery completes. */
    if(!retained_native_recovery) hwm_plane_clear_legacy_pointer(window);
}

static void horizontal_mission_control_enter(void)
{
    /* Mission Control can consume the terminal mouse-up. Retire the current
     * session at entry so it cannot own input after Mission Control exits. */
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_MISSION_CONTROL);
}
