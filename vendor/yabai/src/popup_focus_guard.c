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

static bool popup_focus_suppressed(void)
{
    pid_t front_pid = g_process_manager.front_pid;
    // Custom popup controls may clear yabai's focused window id even while the
    // owning application remains frontmost.
    if (!front_pid) return false;

    uint64_t now = read_os_timer();
    // A negative result is never cached: a popup can appear between adjacent
    // focus attempts.  A brief positive cache avoids rescanning while the
    // pointer crosses a visible transient.
    if (popup_focus_cached_pid == front_pid && popup_focus_cached &&
        (double)(now - popup_focus_check_time) / read_os_freq() < 0.075) return true;
    bool preserve_cached = popup_focus_cached_pid == front_pid && popup_focus_cached;
    popup_focus_check_time = now;
    popup_focus_cached_pid = front_pid;

    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!windows) {
        popup_focus_cached = preserve_cached;
        return preserve_cached;
    }
    popup_focus_cached = false;

    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; ++i) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, i);
        CFNumberRef pid_ref = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CFNumberRef id_ref = CFDictionaryGetValue(info, kCGWindowNumber);
        CFNumberRef layer_ref = CFDictionaryGetValue(info, kCGWindowLayer);
        CFDictionaryRef bounds_ref = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!pid_ref || !id_ref || !layer_ref || !bounds_ref) continue;

        pid_t pid;
        uint32_t id;
        int layer;
        CGRect bounds;
        if (!CFNumberGetValue(pid_ref, kCFNumberIntType, &pid) || pid != front_pid ||
            !CFNumberGetValue(id_ref, kCFNumberSInt32Type, &id) ||
            !CFNumberGetValue(layer_ref, kCFNumberIntType, &layer) ||
            !CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds) ||
            CGRectIsEmpty(bounds) || CGRectIsInfinite(bounds)) continue;
        // Ordered-in surfaces can still be fully transparent. A hidden popup
        // must not leave focus pinned after it disappears.
        CFNumberRef alpha_ref = CFDictionaryGetValue(info, kCGWindowAlpha);
        double alpha = 1;
        if (alpha_ref && CFNumberGetValue(alpha_ref, kCFNumberDoubleType, &alpha) && alpha <= 0) continue;

        struct window *window = window_manager_find_window(&g_window_manager, id);
        if (popup_focus_is_transient(front_pid, pid, layer, window)) {
            popup_focus_cached = true;
            break;
        }
    }

    CFRelease(windows);
    if (popup_focus_cached) debug("popup-focus-guard: preserving front-app transient\n");
    return popup_focus_cached;
}
