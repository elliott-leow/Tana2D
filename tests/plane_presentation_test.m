/* Regression coverage for displayed-frame sampling over the batched query. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>

static CFArrayRef test_window_list;
static int test_queries, test_last_count;
static uint32_t test_last_wids[8];
/* WindowServer's batched query, answered from the fixture's descriptions:
 * only windows asked about, in the list's own order. */
static int test_screen_rects(const uint32_t *wids, int count, uint32_t *ids, CGRect *rects)
{
    ++test_queries; test_last_count = count;
    for (int i = 0; i < count && i < 8; ++i) test_last_wids[i] = wids[i];
    if (!test_window_list) return 0;
    int found = 0;
    for (CFIndex k = 0; k < CFArrayGetCount(test_window_list); ++k) {
        NSDictionary *item = ((NSArray *)test_window_list)[k];
        uint32_t wid = [item[(id)kCGWindowNumber] unsignedIntValue];
        for (int i = 0; i < count; ++i) if (wids[i] == wid) {
            ids[found] = wid;
            CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)item[(id)kCGWindowBounds], &rects[found]);
            ++found; break;
        }
    }
    return found;
}
#define HWM_PRESENTATION_SCREEN_RECTS
#define hwm_plane_screen_rects test_screen_rects
#include "../src/plane_presentation.h"
#undef hwm_plane_screen_rects

static NSDictionary *entry(uint32_t wid, CGRect frame)
{
    CFDictionaryRef bounds = CGRectCreateDictionaryRepresentation(frame);
    NSDictionary *result = @{(id)kCGWindowNumber:@(wid), (id)kCGWindowBounds:(id)bounds};
    CFRelease(bounds);
    return result;
}

static void set_list(NSArray *items)
{
    test_window_list = (CFArrayRef)[items retain];
}

static void clear_list(void) { [(NSArray *)test_window_list release]; test_window_list = NULL; }

int main(void)
{
    @autoreleasepool {
        CGRect frame = CGRectMake(-99, 22, 951, 1054), out = CGRectMake(1, 2, 3, 4);
        set_list(@[entry(40, CGRectMake(8, 9, 10, 11)), entry(6672, frame)]);
        assert(hwm_plane_displayed_frame(6672, &out));
        assert(CGRectEqualToRect(out, frame));
        assert(test_last_count == 1 && test_last_wids[0] == 6672);
        clear_list();
        out = CGRectMake(1, 2, 3, 4);
        set_list(@[entry(6672, CGRectMake(0, 0, 0, 10))]);
        assert(!hwm_plane_displayed_frame(6672, &out));
        assert(CGRectEqualToRect(out, CGRectMake(1, 2, 3, 4)));
        clear_list();
        assert(!hwm_plane_displayed_frame(6672, &out));
        assert(CGRectEqualToRect(out, CGRectMake(1, 2, 3, 4)));
        assert(!hwm_plane_displayed_frame(0, &out));
        assert(!hwm_plane_displayed_frame(6672, NULL));
        // Several windows in one query; a window missing from the list is reported as such.
        uint32_t wids[3] = {6672, 40, 99};
        CGRect frames[3]; bool found[3];
        set_list(@[entry(40, CGRectMake(8, 9, 10, 11)), entry(6672, frame), entry(7, CGRectMake(0, 0, 5, 5))]);
        hwm_plane_displayed_frames(wids, 3, frames, found);
        int queries = test_queries;
        assert(test_last_count == 3 && test_last_wids[1] == 40); // One query for all three.
        assert(found[0] && CGRectEqualToRect(frames[0], frame));
        assert(found[1] && CGRectEqualToRect(frames[1], CGRectMake(8, 9, 10, 11)));
        assert(!found[2] && CGRectIsNull(frames[2]));
        clear_list();
        hwm_plane_displayed_frames(wids, 3, frames, found);
        assert(!found[0] && !found[1] && !found[2]);
        hwm_plane_displayed_frames(wids, 0, frames, found);
        assert(test_queries == queries + 1); // Nothing to ask about asks nothing.
        puts("plane presentation tests passed");
    }
}
