/* CGWindowList-only regression coverage for displayed-frame sampling. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>

static CFArrayRef test_window_list;
static CGWindowListOption test_options;
static CGWindowID test_relative;
static CFArrayRef test_copy_window_info(CGWindowListOption options, CGWindowID relative)
{
    test_options = options; test_relative = relative;
    return test_window_list ? CFRetain(test_window_list) : NULL;
}
#define CGWindowListCopyWindowInfo test_copy_window_info
#include "../src/plane_presentation.h"
#undef CGWindowListCopyWindowInfo

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
        assert(test_options == kCGWindowListOptionIncludingWindow && test_relative == 6672);
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
        puts("plane presentation tests passed");
    }
}
