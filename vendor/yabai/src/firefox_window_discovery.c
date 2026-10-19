// Firefox tab tear-offs can omit AXCreated. Recover references from AXWindows
// after a left drag, without restarting the daemon or changing window rules.
// Click state runs on the serialized yabai event thread; the AX scan does not.
extern struct window_manager g_window_manager;
static pid_t firefox_discovery_pid;
static bool firefox_discovery_dragged;
static void firefox_discovery_scan(pid_t pid);

static bool firefox_discovery_is_application(struct application *application)
{
    return application && strcasecmp(application->name, "Firefox") == 0;
}

static void firefox_discovery_begin(struct application *application, bool left_button)
{
    firefox_discovery_pid = left_button && firefox_discovery_is_application(application) ? application->pid : 0;
    firefox_discovery_dragged = false;
    if (application) debug("firefox-window-discovery: click app=%s pid=%d left=%d armed=%d\n", application->name, application->pid, left_button, firefox_discovery_pid);
}

static void firefox_discovery_drag(void)
{
    if (firefox_discovery_pid) firefox_discovery_dragged = true;
}

static void firefox_discovery_end(void)
{
    pid_t pid = firefox_discovery_pid;
    bool dragged = firefox_discovery_dragged;
    firefox_discovery_pid = 0;
    firefox_discovery_dragged = false;
    if (!pid || !dragged) return;
    debug("firefox-window-discovery: scheduling pid=%d after drag\n", pid);

    // The native drag-end event can precede creation of the accessible window.
    // Retain only the pid across timers: the app may exit before they fire.
    // The Accessibility round trip runs off the event thread. A busy Firefox
    // took up to seconds to answer, and every frame on that thread waited.
    const double delays[] = {0.0, 0.05, 0.1, 0.15, 0.2};
    for (unsigned i = 0; i < sizeof(delays) / sizeof(delays[0]); ++i) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            firefox_discovery_scan(pid);
        });
    }
}

/* Runs on a utility queue and touches no manager state. WINDOW_CREATED
 * rejects windows that are already tracked, stale refs and other apps. */
static void firefox_discovery_scan(pid_t pid)
{
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    if (!application) return;
    AXUIElementSetMessagingTimeout(application, 0.5f);
    CFTypeRef windows = NULL;
    AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windows);
    CFRelease(application);
    if (!windows) return;
    if (CFGetTypeID(windows) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
            AXUIElementRef ref = (AXUIElementRef) CFArrayGetValueAtIndex(windows, i);
            if (ax_window_id(ref)) event_loop_post(&g_event_loop, WINDOW_CREATED, (void *) CFRetain(ref), 0);
        }
    }
    CFRelease(windows);
}
