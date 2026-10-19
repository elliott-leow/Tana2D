#ifndef TANA2D_PLANE_PRESENTATION_H
#define TANA2D_PLANE_PRESENTATION_H

/* The WindowServer's displayed rectangle.  This is intentionally separate
 * from SLSGetWindowBounds(): an AppKit title-bar tracking loop can move the
 * presented surface while that native anchor and a prior plane matrix lag. */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/* One WindowServer query for where windows are drawn: SLSWindowIteratorGet-
 * ScreenRect is the rectangle CGWindowList reports as kCGWindowBounds,
 * presentation transforms included, without building and serializing a
 * description dictionary per window. A drag asks on every pointer event and
 * every frame. Fills ids/rects with the windows WindowServer knows, in any
 * order, and returns how many. Tests replace this with their own. */
#ifndef HWM_PRESENTATION_SCREEN_RECTS
extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef windows, int count);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef query);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern CGRect SLSWindowIteratorGetScreenRect(CFTypeRef iterator);
extern int SLSMainConnectionID(void);
static int hwm_plane_screen_rects(const uint32_t *wids, int count, uint32_t *ids, CGRect *rects)
{
    if (count <= 0) return 0;
    CFNumberRef stack[16], *numbers = count <= 16 ? stack : malloc(sizeof(*numbers) * (size_t)count);
    if (!numbers) return 0;
    for (int i = 0; i < count; ++i) numbers[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &wids[i]);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)numbers, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; ++i) CFRelease(numbers[i]);
    if (numbers != stack) free(numbers);
    if (!list) return 0;
    CFTypeRef query = SLSWindowQueryWindows(SLSMainConnectionID(), list, count);
    CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    int found = 0;
    while (iterator && found < count && SLSWindowIteratorAdvance(iterator)) {
        ids[found] = SLSWindowIteratorGetWindowID(iterator);
        rects[found++] = SLSWindowIteratorGetScreenRect(iterator);
    }
    if (iterator) CFRelease(iterator);
    if (query) CFRelease(query);
    CFRelease(list);
    return found;
}
extern CGRect SLSWindowIteratorGetBounds(CFTypeRef iterator);
/* The native bounds (what SLSGetWindowBounds reports) of several windows in
 * one query. found[i] says whether wids[i] was listed. */
static void hwm_plane_native_bounds(const uint32_t *wids, int count, CGRect *out, bool *found)
{
    for (int i = 0; i < count; ++i) { found[i] = false; out[i] = CGRectNull; }
    if (count <= 0) return;
    CFNumberRef stack[64], *numbers = count <= 64 ? stack : malloc(sizeof(*numbers) * (size_t)count);
    if (!numbers) return;
    for (int i = 0; i < count; ++i) numbers[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &wids[i]);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)numbers, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; ++i) CFRelease(numbers[i]);
    if (numbers != stack) free(numbers);
    if (!list) return;
    CFTypeRef query = SLSWindowQueryWindows(SLSMainConnectionID(), list, count);
    CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    while (iterator && SLSWindowIteratorAdvance(iterator)) {
        uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
        CGRect bounds = SLSWindowIteratorGetBounds(iterator);
        for (int i = 0; i < count; ++i) if (!found[i] && wids[i] == wid) { out[i] = bounds; found[i] = true; break; }
    }
    if (iterator) CFRelease(iterator);
    if (query) CFRelease(query);
    CFRelease(list);
}
/* A window's native bounds (what SLSGetWindowBounds reports) and where it is
 * drawn, from one query. A held drag reads both every pointer event and
 * every frame. */
static bool hwm_plane_window_frames(uint32_t wid, CGRect *native, CGRect *displayed)
{
    if (!wid || !native || !displayed) return false;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef list = number ? CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks) : NULL;
    if (number) CFRelease(number);
    if (!list) return false;
    CFTypeRef query = SLSWindowQueryWindows(SLSMainConnectionID(), list, 1);
    CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    bool found = iterator && SLSWindowIteratorAdvance(iterator) && SLSWindowIteratorGetWindowID(iterator) == wid;
    if (found) { *native = SLSWindowIteratorGetBounds(iterator); *displayed = SLSWindowIteratorGetScreenRect(iterator); }
    if (iterator) CFRelease(iterator);
    if (query) CFRelease(query);
    CFRelease(list);
    return found;
}
#endif

static bool hwm_plane_rect_drawn(CGRect frame)
{
    return isfinite(frame.origin.x) && isfinite(frame.origin.y) &&
           isfinite(frame.size.width) && isfinite(frame.size.height) &&
           frame.size.width > 0 && frame.size.height > 0;
}

static bool hwm_plane_displayed_frame(uint32_t wid, CGRect *out)
{
    if (!wid || !out) return false;
    uint32_t id = 0; CGRect frame = CGRectNull;
    if (hwm_plane_screen_rects(&wid, 1, &id, &frame) != 1 || id != wid || !hwm_plane_rect_drawn(frame)) return false;
    *out = frame;
    return true;
}

/* The displayed rectangles of several windows in one WindowServer round trip.
 * found[i] says whether wids[i] was listed; out[i] is its rectangle. */
static void hwm_plane_displayed_frames(const uint32_t *wids, int count, CGRect *out, bool *found)
{
    for (int i = 0; i < count; ++i) { found[i] = false; out[i] = CGRectNull; }
    if (count <= 0) return;
    uint32_t stack_ids[16]; CGRect stack_rects[16];
    uint32_t *ids = count <= 16 ? stack_ids : malloc(sizeof(*ids) * (size_t)count);
    CGRect *rects = count <= 16 ? stack_rects : malloc(sizeof(*rects) * (size_t)count);
    int listed = ids && rects ? hwm_plane_screen_rects(wids, count, ids, rects) : 0;
    for (int k = 0; k < listed; ++k) {
        if (!hwm_plane_rect_drawn(rects[k])) continue;
        for (int i = 0; i < count; ++i) if (!found[i] && wids[i] == ids[k]) { out[i] = rects[k]; found[i] = true; break; }
    }
    if (ids != stack_ids) free(ids);
    if (rects != stack_rects) free(rects);
}

#endif
