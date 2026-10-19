// An app can implement a popup as its own window instead of an AX menu.
// Moving from the invoking control to that window may briefly cross another
// app's window. Hold focus until the popup closes, as we do for AX menus.
//
// This deliberately does not infer a popup from its geometry: a small normal
// document is still a document.  A tracked non-standard AX window is transient
// (dialog, panel, custom picker), while an untracked window must be elevated
// above the normal window level before it can hold focus.
static uint64_t popup_focus_check_time;
static pid_t popup_focus_cached_pid;
static bool popup_focus_cached;

static bool popup_focus_is_transient(pid_t front_pid, pid_t owner_pid,
                                     int layer, struct window *window)
{
    if (owner_pid != front_pid) return false;
    if (window) return !window_is_standard(window);

    // Unknown normal-level windows include ordinary documents that yabai has
    // not discovered yet.  Elevated, front-app surfaces are the conservative
    // fallback for custom popups that do not expose an AX window.
    return layer > CGWindowLevelForKey(kCGNormalWindowLevelKey);
}

extern CGError SLSGetOnScreenWindowList(int cid, int owner, int max, uint32_t *list, int *count);
extern pid_t SLSWindowIteratorGetPID(CFTypeRef iterator);
extern float SLSWindowIteratorGetAlpha(CFTypeRef iterator);
extern CGRect SLSWindowIteratorGetBounds(CFTypeRef iterator);

static bool popup_focus_suppressed(void)
{
    pid_t front_pid = g_process_manager.front_pid;
    // Custom popup controls may clear yabai's focused window id even while the
    // owning application remains frontmost.
    if (!front_pid) return false;

    uint64_t now = read_os_timer();
    double age = (double)(now - popup_focus_check_time) / read_os_freq();
    // A brief positive cache avoids rescanning while the pointer crosses a
    // visible transient. A negative result is kept for one display frame
    // only: hover reports arrive every few milliseconds, and a popup opened
    // since is seen by the next frame's attempt.
    if (popup_focus_cached_pid == front_pid && age < (popup_focus_cached ? 0.075 : 0.016)) return popup_focus_cached;
    bool preserve_cached = popup_focus_cached_pid == front_pid && popup_focus_cached;
    popup_focus_check_time = now;
    popup_focus_cached_pid = front_pid;

    /* The on-screen windows, read in one WindowServer query. A description
     * dictionary per window (CGWindowListCopyWindowInfo) cost several ms on
     * every hover report that crossed into another window, and the public
     * list (CGWindowListCreate) looks up the server's port on every call.
     * This is the same list, in the same order, over our own connection. */
    enum { POPUP_SCAN_MAX = 1024 };
    uint32_t ids[POPUP_SCAN_MAX];
    int count = 0;
    bool listed = SLSGetOnScreenWindowList(g_connection, 0, POPUP_SCAN_MAX, ids, &count) == kCGErrorSuccess;
    if (count < 0) count = 0;
    if (count > POPUP_SCAN_MAX) count = POPUP_SCAN_MAX;
    CFNumberRef *numbers = listed ? malloc(sizeof(*numbers) * (count + 1)) : NULL;
    for (int i = 0; numbers && i < count; ++i) numbers[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &ids[i]);
    CFArrayRef windows = numbers ? CFArrayCreate(NULL, (const void **) numbers, count, &kCFTypeArrayCallBacks) : NULL;
    for (int i = 0; numbers && i < count; ++i) CFRelease(numbers[i]);
    free(numbers);
    if (windows && !count) {
        CFRelease(windows);
        popup_focus_cached = false;
        return false;
    }
    CFTypeRef query = windows ? SLSWindowQueryWindows(g_connection, windows, (int) count) : NULL;
    CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    if (!iterator) {
        if (query) CFRelease(query);
        if (windows) CFRelease(windows);
        popup_focus_cached = preserve_cached;
        return preserve_cached;
    }
    popup_focus_cached = false;

    while (SLSWindowIteratorAdvance(iterator)) {
        if (SLSWindowIteratorGetPID(iterator) != front_pid) continue;
        CGRect bounds = SLSWindowIteratorGetBounds(iterator);
        if (CGRectIsEmpty(bounds) || CGRectIsInfinite(bounds)) continue;
        // Ordered-in surfaces can still be fully transparent. A hidden popup
        // must not leave focus pinned after it disappears.
        if (SLSWindowIteratorGetAlpha(iterator) <= 0) continue;

        struct window *window = window_manager_find_window(&g_window_manager, SLSWindowIteratorGetWindowID(iterator));
        if (popup_focus_is_transient(front_pid, front_pid, SLSWindowIteratorGetLevel(iterator), window)) {
            popup_focus_cached = true;
            break;
        }
    }

    CFRelease(iterator);
    CFRelease(query);
    CFRelease(windows);
    if (popup_focus_cached) debug("popup-focus-guard: preserving front-app transient\n");
    return popup_focus_cached;
}
