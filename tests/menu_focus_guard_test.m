/* Exercise the production menu and popup guards with deterministic AX and
 * WindowServer seams.  The real APIs are deliberately not queried here. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include "../src/focus_policy.h"

struct menu_probe {
    AXUIElementRef element;
    pid_t pid;
    AXError pid_error, role_error;
    uint32_t wid;
    CGError ordered_error;
    uint8_t ordered;
    bool owner_alive;
};

static struct menu_probe menu_probes[4];
static int menu_probe_count;
static uint64_t menu_test_time;
static int g_connection;
static uint32_t queued_focus_window;
static bool queued_focus_pending, queued_focus_automatic;

static struct menu_probe *menu_probe_for(AXUIElementRef element)
{
    for (int i = 0; i < menu_probe_count; ++i)
        if (menu_probes[i].element == element) return &menu_probes[i];
    return NULL;
}

static uint64_t menu_test_timer(void) { return menu_test_time; }
static uint64_t menu_test_freq(void) { return 1000; }
static void horizontal_cancel_automatic_focus(void)
{
    hwm_focus_queue_cancel_automatic(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic);
}
static AXError menu_test_get_pid(AXUIElementRef element, pid_t *pid)
{
    struct menu_probe *probe = menu_probe_for(element);
    if (!probe) return kAXErrorInvalidUIElement;
    *pid = probe->pid;
    return probe->pid_error;
}
static AXError menu_test_copy_attribute(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value)
{
    (void) attribute;
    struct menu_probe *probe = menu_probe_for(element);
    if (!probe) return kAXErrorInvalidUIElement;
    if (probe->role_error == kAXErrorSuccess) *value = CFRetain(CFSTR("AXMenu"));
    return probe->role_error;
}
static uint32_t menu_test_window_id(AXUIElementRef element)
{
    struct menu_probe *probe = menu_probe_for(element);
    return probe ? probe->wid : 0;
}
static CGError menu_test_ordered_in(int connection, uint32_t wid, uint8_t *ordered)
{
    (void) connection;
    for (int i = 0; i < menu_probe_count; ++i) if (menu_probes[i].wid == wid) {
        *ordered = menu_probes[i].ordered;
        return menu_probes[i].ordered_error;
    }
    return kCGErrorFailure;
}
static int menu_test_kill(pid_t pid, int signal)
{
    (void) signal;
    for (int i = 0; i < menu_probe_count; ++i) if (menu_probes[i].pid == pid) {
        if (menu_probes[i].owner_alive) return 0;
        errno = ESRCH;
        return -1;
    }
    return 0;
}

#define read_os_timer menu_test_timer
#define read_os_freq menu_test_freq
#define AXUIElementGetPid menu_test_get_pid
#define AXUIElementCopyAttributeValue menu_test_copy_attribute
#define ax_window_id menu_test_window_id
#define SLSWindowIsOrderedIn menu_test_ordered_in
#define kill menu_test_kill
#define debug(...) ((void) 0)
#include "../vendor/yabai/src/menu_focus_recovery.c"
#undef debug
#undef kill
#undef SLSWindowIsOrderedIn
#undef ax_window_id
#undef AXUIElementCopyAttributeValue
#undef AXUIElementGetPid
#undef read_os_freq
#undef read_os_timer

struct process_manager { pid_t front_pid; };
struct window_manager { uint32_t focused_window_id; };
struct window { uint32_t id; bool standard; };
static struct process_manager g_process_manager;
static struct window_manager g_window_manager;
static struct window popup_windows[4];
static int popup_window_count, popup_scan_count;
static CFMutableArrayRef popup_window_info;
static uint64_t popup_test_time;
static bool popup_window_list_available;

static uint64_t popup_test_timer(void) { return popup_test_time; }
static uint64_t popup_test_freq(void) { return 1000; }
static struct window *window_manager_find_window(struct window_manager *wm, uint32_t wid)
{
    (void) wm;
    for (int i = 0; i < popup_window_count; ++i)
        if (popup_windows[i].id == wid) return &popup_windows[i];
    return NULL;
}
static bool window_is_standard(struct window *window) { return window->standard; }
static CFArrayRef popup_test_window_list(CGWindowListOption option, CGWindowID wid)
{
    (void) option; (void) wid;
    ++popup_scan_count;
    if (!popup_window_list_available) return NULL;
    return popup_window_info ? CFRetain(popup_window_info) : NULL;
}

#define read_os_timer popup_test_timer
#define read_os_freq popup_test_freq
#define CGWindowListCopyWindowInfo popup_test_window_list
#define debug(...) ((void) 0)
#include "../vendor/yabai/src/popup_focus_guard.c"
#undef debug
#undef CGWindowListCopyWindowInfo
#undef read_os_freq
#undef read_os_timer

static AXUIElementRef menu_probe_add(pid_t pid)
{
    assert(menu_probe_count < 4);
    int index = menu_probe_count++;
    AXUIElementRef element = (AXUIElementRef) CFStringCreateWithFormat(NULL, NULL, CFSTR("menu-%d"), index);
    menu_probes[index] = (struct menu_probe){
        .element = element, .pid = pid, .pid_error = kAXErrorSuccess,
        .role_error = kAXErrorSuccess, .wid = (uint32_t) (101 + index),
        .ordered_error = kCGErrorSuccess, .ordered = 1, .owner_alive = true
    };
    return element;
}

static void menu_reset(void)
{
    if (ffm_menus) { CFRelease(ffm_menus); ffm_menus = NULL; }
    for (int i = 0; i < menu_probe_count; ++i) CFRelease(menu_probes[i].element);
    menu_probe_count = 0;
    hwm_focus_queue_clear(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic);
    menu_test_time = 0;
    ffm_menu_check_time = 0;
}

static void test_menu_identity_and_automatic_cancellation(void)
{
    menu_reset();
    AXUIElementRef menu = menu_probe_add(101);
    hwm_focus_queue_enqueue(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, 41, true);
    menu_focus_open(menu);
    menu_focus_open(menu); /* duplicate AX opens cannot leave a phantom menu */
    assert(!queued_focus_pending && !queued_focus_automatic && queued_focus_window == 0);
    assert(CFArrayGetCount(ffm_menus) == 1 && menu_focus_suppressed());
    menu_focus_close(menu);
    assert(!menu_focus_suppressed() && !hwm_focus_queue_take(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, false));

    hwm_focus_queue_enqueue(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, 42, false);
    menu_focus_open(menu);
    assert(queued_focus_pending && !queued_focus_automatic && queued_focus_window == 42);
    assert(hwm_focus_queue_take(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, true));
    assert(queued_focus_window == 42); /* an explicit key/selection request remains valid */
    menu_focus_close(menu);
}

static void test_nested_unmatched_and_stale_menus(void)
{
    menu_reset();
    AXUIElementRef parent = menu_probe_add(102);
    AXUIElementRef child = menu_probe_add(102);
    menu_focus_open(parent); menu_focus_open(child);
    menu_focus_close(parent); /* a child submenu still protects its owner */
    assert(menu_focus_suppressed());
    menu_focus_close(parent); /* unmatched close has no effect */
    assert(menu_focus_suppressed());
    menu_focus_close(child);
    assert(!menu_focus_suppressed());

    menu_focus_open(parent);
    menu_test_time += 300;
    menu_probes[0].role_error = kAXErrorCannotComplete;
    assert(menu_focus_suppressed()); /* a transient AX failure is not closure */
    menu_test_time += 300;
    menu_probes[0].role_error = kAXErrorSuccess;
    menu_probes[0].owner_alive = false;
    assert(!menu_focus_suppressed()); /* dead owner clears a missed close */
}

static void popup_reset(void)
{
    if (popup_window_info) { CFRelease(popup_window_info); popup_window_info = NULL; }
    popup_window_info = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    popup_window_count = 0;
    popup_scan_count = 0;
    popup_test_time = 1000;
    popup_focus_check_time = 0;
    popup_focus_cached_pid = 0;
    popup_focus_cached = false;
    popup_window_list_available = true;
    g_process_manager.front_pid = 404;
    g_window_manager.focused_window_id = 1;
}

static void popup_add(pid_t pid, uint32_t wid, int layer, bool tracked, bool standard)
{
    CFNumberRef owner = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFNumberRef id = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFNumberRef level = CFNumberCreate(NULL, kCFNumberIntType, &layer);
    CFDictionaryRef bounds = CGRectCreateDictionaryRepresentation(CGRectMake(50, 50, 960, 900));
    const void *keys[] = { kCGWindowOwnerPID, kCGWindowNumber, kCGWindowLayer, kCGWindowBounds };
    const void *values[] = { owner, id, level, bounds };
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayAppendValue(popup_window_info, info);
    CFRelease(info); CFRelease(bounds); CFRelease(level); CFRelease(id); CFRelease(owner);
    if (tracked) popup_windows[popup_window_count++] = (struct window){.id = wid, .standard = standard};
}

static void test_popup_classification_and_cache(void)
{
    popup_reset();
    popup_add(404, 1, 0, true, true);
    assert(!popup_focus_suppressed()); /* ordinary current document */
    popup_add(404, 2, 0, true, false);
    assert(popup_focus_suppressed() && popup_scan_count == 2); /* a new popup cannot hide behind a negative cache */

    popup_reset();
    popup_add(404, 2, 0, true, false);
    assert(popup_focus_suppressed()); /* AX dialog/panel at normal level */

    popup_reset();
    popup_add(404, 3, 0, false, false);
    assert(!popup_focus_suppressed()); /* unknown normal-level window is not guessed */

    popup_reset();
    popup_add(404, 4, 1, false, false);
    assert(popup_focus_suppressed()); /* elevated, front-app custom popup */

    popup_reset();
    popup_add(404, 4, 1, false, false);
    CFMutableDictionaryRef invisible = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(popup_window_info, 0));
    double zero = 0;
    CFNumberRef transparent = CFNumberCreate(NULL, kCFNumberDoubleType, &zero);
    CFDictionarySetValue(invisible, kCGWindowAlpha, transparent);
    CFArraySetValueAtIndex(popup_window_info, 0, invisible);
    assert(!popup_focus_suppressed()); /* an ordered-in transparent popup cannot pin focus */
    CFDictionaryRemoveValue(invisible, kCGWindowAlpha);
    CFDictionaryRef empty = CGRectCreateDictionaryRepresentation(CGRectZero);
    CFDictionarySetValue(invisible, kCGWindowBounds, empty);
    assert(!popup_focus_suppressed()); /* nor can a surface with no visible area */
    CFRelease(empty); CFRelease(transparent); CFRelease(invisible);

    popup_reset();
    popup_add(404, 5, 0, true, false);
    assert(popup_focus_suppressed() && popup_scan_count == 1);
    popup_window_list_available = false;
    popup_test_time += 100;
    assert(popup_focus_suppressed() && popup_scan_count == 2); /* transient enumeration failure retains a positive guard */
    popup_window_list_available = true;
    CFArrayRemoveAllValues(popup_window_info); popup_window_count = 0;
    popup_test_time += 100;
    assert(!popup_focus_suppressed() && popup_scan_count == 3); /* close has no stale handoff */

    popup_reset();
    popup_add(404, 55, 0, true, false);
    assert(popup_focus_suppressed());
    g_process_manager.front_pid = 405;
    popup_window_list_available = false;
    popup_test_time += 100;
    assert(!popup_focus_suppressed() && !popup_focus_suppressed()); /* a failed scan cannot carry a prior app's positive cache */

    popup_reset();
    popup_add(404, 6, 0, true, false);
    hwm_focus_queue_enqueue(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, 61, true);
    assert(popup_focus_suppressed());
    assert(!hwm_focus_queue_take(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, true));
    assert(!queued_focus_pending && queued_focus_window == 0); /* popup before flush drops only automatic focus */

    /* A previously automatic queue cannot leak its intent into an explicit plane selection. */
    hwm_focus_queue_enqueue(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, 62, true);
    hwm_focus_queue_enqueue(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, 63, false);
    assert(hwm_focus_queue_take(&queued_focus_window, &queued_focus_pending, &queued_focus_automatic, true));
    assert(queued_focus_window == 63);
}

int main(void)
{
    @autoreleasepool {
        test_menu_identity_and_automatic_cancellation();
        test_nested_unmatched_and_stale_menus();
        test_popup_classification_and_cache();
        menu_reset();
        if (popup_window_info) CFRelease(popup_window_info);
    }
    puts("menu focus guard tests passed");
    return 0;
}
