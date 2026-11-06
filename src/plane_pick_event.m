typedef struct {
    CGEventType type;
    CGPoint point;
    bool dragged;
    uint64_t generation,drag_serial;
} HWMPlanePickInput;
/* A body press may be a click-to-enter or an application drag. Retain its
 * original native event until intent is known; never synthesize a new anchor. */
static CGEventRef hwm_plane_content_down,hwm_plane_replay_down;
static uint32_t hwm_plane_content_window;
static uint64_t hwm_plane_content_generation;
static bool hwm_plane_content_cancelled;
static void hwm_plane_content_discard(void)
{
    if(hwm_plane_content_down) CFRelease(hwm_plane_content_down);
    hwm_plane_content_down=NULL; hwm_plane_content_window=0;
}
static CGPoint hwm_plane_select_origin;
static bool hwm_plane_select_dragged;
/* The dispatcher arms this only around one accepted queued drag.  The pointer
 * controller consumes it immediately, allowing that pre-up sample through its
 * terminal fence without admitting a later live event. */
static bool hwm_plane_pick_queued_drag_allowed;
static uint64_t hwm_plane_pick_dispatch_generation;
static __attribute__((unused)) bool hwm_plane_pick_take_queued_drag_allowance(void)
{
    bool allowed=hwm_plane_pick_queued_drag_allowed;
    hwm_plane_pick_queued_drag_allowed=false;
    return allowed;
}
static __attribute__((unused)) uint64_t hwm_plane_pick_current_dispatch_generation(void)
{
    return hwm_plane_pick_dispatch_generation;
}
/* One coalesced drag per press may wait in the queue.  Replacing this marker
 * on a new press permits several quick press/release sequences to retain their
 * final drag independently; an older dequeue cannot clear a newer marker. */
static _Atomic uint64_t hwm_plane_pick_drag_generation;
static bool hwm_plane_pick_drag_enqueue(uint64_t generation)
{
    return atomic_exchange(&hwm_plane_pick_drag_generation,generation)==generation;
}
static void hwm_plane_pick_drag_dequeue(uint64_t generation)
{
    uint64_t expected=generation;
    atomic_compare_exchange_strong(&hwm_plane_pick_drag_generation,&expected,0);
}
/* Called by the event-loop HWM_PLANE_PICK dispatcher before it mutates the
 * pointer controller.  It preserves the final physical drag of this press,
 * never converts mouse-up/new-press coordinates into movement, and drops a
 * session synchronously invalidated by the tap-disabled lifecycle handler. */
static bool hwm_plane_pick_input_prepare(HWMPlanePickInput *input)
{
    hwm_plane_pick_queued_drag_allowed=false; hwm_plane_pick_dispatch_generation=0;
    if(!input || hwm_overview_active || hwm_pointer_sample_generation_is_aborted(input->generation)) return false;
    if(input->type==kCGEventLeftMouseDragged) {
        hwm_plane_pick_drag_dequeue(input->generation);
        CGPoint point;
        uint64_t serial;
        if(hwm_pointer_sample_drag_for_generation(input->generation,input->drag_serial,&point,&serial)) {
            input->point=point; input->drag_serial=serial;
        }
        /* The physical up can precede this dequeue. The next controller call
         * may move once using this generation's retained final drag. */
        hwm_plane_pick_queued_drag_allowed=true;
        hwm_plane_pick_dispatch_generation=input->generation;
    }
    return true;
}
static bool hwm_plane_pick_event(CGEventType type,CGEventRef event)
{
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput ||
       type==kCGEventLeftMouseDown) hwm_plane_content_discard();
    if(type==kCGEventLeftMouseDown) hwm_plane_content_cancelled=false;
    if(hwm_plane_content_down && hwm_pointer_sample_generation_is_aborted(hwm_plane_content_generation)) {
        hwm_plane_content_discard(); hwm_plane_content_cancelled=true;
    }
    if(hwm_plane_content_cancelled && (type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp)) {
        if(type==kCGEventLeftMouseUp) { hwm_plane_select_click=false; hwm_plane_content_cancelled=false; }
        return true;
    }
    if(hwm_plane_content_down && type==kCGEventKeyDown && CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53) {
        HWMPlanePickInput *cancel=calloc(1,sizeof(*cancel));
        if(cancel) {
            *cancel=(HWMPlanePickInput){.type=kCGEventLeftMouseUp,.point=hwm_plane_select_origin,.dragged=true,.generation=hwm_plane_content_generation};
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,cancel,HWM_PLANE_PICK);
        }
        hwm_plane_content_discard(); hwm_plane_content_cancelled=true; hwm_plane_select_dragged=true;
        return true; // Keep consuming this press through its terminal up.
    }
    if(hwm_plane_content_down && (type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp)) {
        CGPoint point=CGEventGetLocation(event);
        bool moved=hypot(point.x-hwm_plane_select_origin.x,point.y-hwm_plane_select_origin.y)>=5;
        if(moved) {
            /* Retire the queued selection before the engine sees the native
             * down. This cannot move/zoom the window, even under queue lag. */
            HWMPlanePickInput *cancel=calloc(1,sizeof(*cancel));
            if(!cancel) return true;
            *cancel=(HWMPlanePickInput){.type=kCGEventLeftMouseUp,.point=point,.dragged=true,
                .generation=hwm_pointer_sample_generation_for_event(type)};
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,cancel,HWM_PLANE_PICK);
            hwm_plane_replay_down=hwm_plane_content_down; hwm_plane_content_down=NULL;
            hwm_click_interaction(hwm_plane_content_window,hwm_now()); hwm_plane_content_window=0;
            hwm_plane_select_click=false;
            return false; // The caller replays down before forwarding this event.
        }
        if(type==kCGEventLeftMouseDragged) return true; // Jitter is neither a window drag nor a click.
        hwm_plane_content_discard();
    }
    /* The native overview owns its complete pointer stream.  In particular,
     * an idle plane-selection mode must not reclaim a card press. */
    if(hwm_overview_active) return false;
    if((type==kCGEventLeftMouseDown && (hwm_plane_selecting || atomic_load(&hwm_workspace_browsing) || hwm_plane_center_click(event))) ||
       (hwm_plane_select_click && (type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp))) {
        CGPoint point=CGEventGetLocation(event);
        uint64_t generation=hwm_pointer_sample_generation_for_event(type),drag_serial=0;
        if(type==kCGEventLeftMouseDown) {
            hwm_plane_select_origin=point; hwm_plane_select_dragged=false;
            /* Explicit selection/overview and Fn retain window rearrangement.
             * Ordinary body dragging always belongs to application content. */
            if(!hwm_plane_selecting && !(CGEventGetFlags(event)&kCGEventFlagMaskSecondaryFn) &&
               hwm_plane_content_hit(event,&hwm_plane_content_window))
            {
                hwm_plane_content_down=CGEventCreateCopy(event);
                hwm_plane_content_generation=generation;
            }
        }
        else if(hypot(point.x-hwm_plane_select_origin.x,point.y-hwm_plane_select_origin.y)>=5) hwm_plane_select_dragged=true;
        hwm_plane_select_click=type!=kCGEventLeftMouseUp;
        if(type==kCGEventLeftMouseDragged) {
            CGPoint ignored;
            /* Record the serial that accompanied this exact drag. A later
             * physical drag of the same press may replace it while queued. */
            (void)hwm_pointer_sample_drag_for_generation(generation,0,&ignored,&drag_serial);
            if(hwm_plane_pick_drag_enqueue(generation)) return true;
        }
        HWMPlanePickInput *input=malloc(sizeof(*input));
        if(input) {
            *input=(HWMPlanePickInput){type,point,hwm_plane_select_dragged,generation,drag_serial};
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,input,HWM_PLANE_PICK);
        }
        return true;
    }
    return false;
}
