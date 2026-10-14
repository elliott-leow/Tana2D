#ifndef TANA2D_PLANE_PRESENTATION_H
#define TANA2D_PLANE_PRESENTATION_H

/* The WindowServer's displayed rectangle.  This is intentionally separate
 * from SLSGetWindowBounds(): an AppKit title-bar tracking loop can move the
 * presented surface while that native anchor and a prior plane matrix lag. */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

static bool hwm_plane_displayed_frame(uint32_t wid, CGRect *out)
{
    if (!wid || !out) return false;
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
    if (!windows) return false;

    bool found = false;
    for (CFIndex index = 0; index < CFArrayGetCount(windows); ++index) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(windows, index);
        CFTypeRef number = item ? CFDictionaryGetValue(item, kCGWindowNumber) : NULL;
        CFTypeRef bounds = item ? CFDictionaryGetValue(item, kCGWindowBounds) : NULL;
        int64_t value = 0;
        CGRect frame = CGRectNull;
        if (!number || !bounds || CFGetTypeID(number) != CFNumberGetTypeID() ||
            CFGetTypeID(bounds) != CFDictionaryGetTypeID() ||
            !CFNumberGetValue((CFNumberRef)number, kCFNumberSInt64Type, &value) ||
            value < 1 || (uint64_t)value != wid ||
            !CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)bounds, &frame) ||
            !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
            !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
            frame.size.width <= 0 || frame.size.height <= 0) continue;
        *out = frame;
        found = true;
        break;
    }
    CFRelease(windows);
    return found;
}

#endif
