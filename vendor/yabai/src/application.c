#include <os/lock.h>

extern struct event_loop g_event_loop;
extern volatile bool __pending_window_focus;

/*
 * Moves, resizes and title changes name an element, not its window, and
 * asking the application which window that is is a synchronous round trip
 * into it. These notifications arrive on the main thread, which also runs
 * the event tap that every key, click and scroll on the system passes
 * through: an application slow to answer held up all input, and at 100%
 * every window the plane carries reports a move on every frame of a pan.
 *
 * So the answer for an element is kept for a second, or until the element is
 * destroyed, and an element not known yet is asked about off the main thread:
 * on one of a few serial queues, chosen by process so that one application's
 * answers stay in order and a slow application holds up only its own. Its
 * notification is posted once the answer comes. The handlers of these three
 * read the window's current state, not the notification's, so they do not
 * depend on arriving in step with other events. Focus changes keep their
 * synchronous lookup: their order against other events matters.
 */
enum { AX_WINDOW_ID_CACHE = 128, AX_WINDOW_ID_QUEUES = 8 };
static struct { AXUIElementRef element; CFHashCode hash; uint32_t wid; uint64_t expires; } ax_window_id_cache[AX_WINDOW_ID_CACHE];
static os_unfair_lock ax_window_id_lock = OS_UNFAIR_LOCK_INIT;

static bool ax_window_id_known(AXUIElementRef element, CFHashCode hash, uint32_t *wid)
{
    bool known = false;
    uint64_t now = read_os_timer();
    os_unfair_lock_lock(&ax_window_id_lock);
    unsigned slot = (unsigned) (hash % AX_WINDOW_ID_CACHE);
    if (ax_window_id_cache[slot].element && ax_window_id_cache[slot].hash == hash && now < ax_window_id_cache[slot].expires &&
        CFEqual(ax_window_id_cache[slot].element, element)) {
        *wid = ax_window_id_cache[slot].wid;
        known = true;
    }
    os_unfair_lock_unlock(&ax_window_id_lock);
    return known;
}

static void ax_window_id_remember(AXUIElementRef element, CFHashCode hash, uint32_t wid)
{
    if (!wid) return;
    CFRetain(element);
    os_unfair_lock_lock(&ax_window_id_lock);
    unsigned slot = (unsigned) (hash % AX_WINDOW_ID_CACHE);
    AXUIElementRef previous = ax_window_id_cache[slot].element;
    ax_window_id_cache[slot].element = element;
    ax_window_id_cache[slot].hash = hash;
    ax_window_id_cache[slot].wid = wid;
    ax_window_id_cache[slot].expires = read_os_timer() + read_os_freq();
    os_unfair_lock_unlock(&ax_window_id_lock);
    if (previous) CFRelease(previous);
}

static void ax_window_id_forget(AXUIElementRef element)
{
    CFHashCode hash = CFHash(element);
    AXUIElementRef previous = NULL;
    os_unfair_lock_lock(&ax_window_id_lock);
    unsigned slot = (unsigned) (hash % AX_WINDOW_ID_CACHE);
    if (ax_window_id_cache[slot].element && ax_window_id_cache[slot].hash == hash && CFEqual(ax_window_id_cache[slot].element, element)) {
        previous = ax_window_id_cache[slot].element;
        ax_window_id_cache[slot].element = NULL;
    }
    os_unfair_lock_unlock(&ax_window_id_lock);
    if (previous) CFRelease(previous);
}

static void ax_window_event_post(enum event_type type, uint32_t wid)
{
    if (type == WINDOW_MOVED && !horizontal_moved_claim(wid)) return;
    event_loop_post(&g_event_loop, type, (void *)(intptr_t) wid, 0);
}

/* Main thread only. */
static void ax_window_event(enum event_type type, AXUIElementRef element)
{
    static dispatch_queue_t queues[AX_WINDOW_ID_QUEUES];
    CFHashCode hash = CFHash(element);
    uint32_t wid = 0;
    if (ax_window_id_known(element, hash, &wid)) { ax_window_event_post(type, wid); return; }
    pid_t pid = 0;
    AXUIElementGetPid(element, &pid);
    unsigned index = (unsigned) pid % AX_WINDOW_ID_QUEUES;
    if (!queues[index]) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        queues[index] = dispatch_queue_create("dev.tana2d.window-ids", attributes);
    }
    CFRetain(element);
    dispatch_async(queues[index], ^{
        uint32_t id = 0;
        // An earlier notification for this element may have asked already.
        bool known = ax_window_id_known(element, hash, &id);
        if (!known) id = ax_window_id(element);
        ax_window_event_post(type, id);
        // Remembered only after posting, so a later notification answered
        // from memory on the main thread cannot overtake this one.
        if (!known) ax_window_id_remember(element, hash, id);
        CFRelease(element);
    });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static OBSERVER_CALLBACK(application_notification_handler)
{
    if (CFEqual(notification, kAXCreatedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_CREATED, (void *) CFRetain(element), 0);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        __atomic_store_n(&__pending_window_focus, true, __ATOMIC_RELEASE);
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXWindowMovedNotification)) {
        ax_window_event(WINDOW_MOVED, element);
    } else if (CFEqual(notification, kAXWindowResizedNotification)) {
        ax_window_event(WINDOW_RESIZED, element);
    } else if (CFEqual(notification, kAXTitleChangedNotification)) {
        ax_window_event(WINDOW_TITLE_CHANGED, element);
    } else if (CFEqual(notification, kAXMenuOpenedNotification)) {
        event_loop_post(&g_event_loop, MENU_OPENED, (void *) CFRetain(element), 0);
    } else if (CFEqual(notification, kAXMenuClosedNotification)) {
        event_loop_post(&g_event_loop, MENU_CLOSED, (void *) CFRetain(element), 0);
    } else if (CFEqual(notification, kAXWindowMiniaturizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_MINIMIZED, context, 0);
    } else if (CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_DEMINIMIZED, context, 0);
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        ax_window_id_forget(element);
        struct window *window = context;

        //
        // NOTE(asmvik): Flag events that are already queued, but not yet processed,
        // so that they will be ignored; the memory we allocated is still valid and will
        // be freed when this event is handled.
        //

        if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, NULL)) return;

        event_loop_post(&g_event_loop, WINDOW_DESTROYED, window, 0);
    }
}
#pragma clang diagnostic pop

bool application_observe(struct application *application)
{
    if (AXObserverCreate(application->pid, application_notification_handler, &application->observer_ref) == kAXErrorSuccess) {
        for (int i = 0; i < array_count(ax_application_notification); ++i) {
            AXError result = AXObserverAddNotification(application->observer_ref, application->ref, ax_application_notification[i], application);
            if (result == kAXErrorSuccess || result == kAXErrorNotificationAlreadyRegistered) {
                application->notification |= 1 << i;
            } else {
                if (result == kAXErrorCannotComplete) application->ax_retry = true;
                debug("%s: error '%s' for application '%s' and notification '%s'\n", __FUNCTION__, ax_error_str[-result], application->name, ax_application_notification_str[i]);
            }
        }

        application->is_observing = true;
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(application->observer_ref), kCFRunLoopDefaultMode);
    }

    return (application->notification & AX_APPLICATION_ALL) == AX_APPLICATION_ALL;
}

void application_unobserve(struct application *application)
{
    if (application->is_observing) {
        for (int i = 0; i < array_count(ax_application_notification); ++i) {
            if (!(application->notification & (1 << i))) continue;

            AXObserverRemoveNotification(application->observer_ref, application->ref, ax_application_notification[i]);
            application->notification &= ~(1 << i);
        }

        application->is_observing = false;
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(application->observer_ref));
        CFRelease(application->observer_ref);
    }
}

uint32_t application_main_window(struct application *application)
{
    CFTypeRef window_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXMainWindowAttribute, &window_ref);
    if (!window_ref) return 0;

    uint32_t window_id = ax_window_id(window_ref);
    CFRelease(window_ref);

    return window_id;
}

uint32_t application_focused_window(struct application *application)
{
    CFTypeRef window_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXFocusedWindowAttribute, &window_ref);
    if (!window_ref) return 0;

    uint32_t window_id = ax_window_id(window_ref);
    CFRelease(window_ref);

    return window_id;
}

bool application_is_frontmost(struct application *application)
{
    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);
    return psn_equals(&psn, &application->psn);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool application_is_hidden(struct application *application)
{
    return IsProcessVisible(&application->psn) == 0;
}
#pragma clang diagnostic pop

CFArrayRef application_window_list(struct application *application)
{
    CFTypeRef window_list_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXWindowsAttribute, &window_list_ref);
    return window_list_ref;
}

struct application *application_create(struct process *process)
{
    struct application *application = malloc(sizeof(struct application));
    memset(application, 0, sizeof(struct application));

    application->ref = AXUIElementCreateApplication(process->pid);
    application->psn = process->psn;
    application->pid = process->pid;
    application->name = process->name;
    application->is_hidden = application_is_hidden(application);
    SLSGetConnectionIDForPSN(g_connection, &application->psn, &application->connection);

    return application;
}

void application_destroy(struct application *application)
{
    CFRelease(application->ref);
    free(application);
}
