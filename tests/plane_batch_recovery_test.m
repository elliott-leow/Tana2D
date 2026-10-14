#define main strip_runtime_test_main
#include "strip_runtime_test.m"
#undef main

static void test_failed_frame_retries_unchanged_geometry(bool flush)
{
    reset();
    CGRect previous=projected[0];
    hwm_batch_hold=true; view.strip_offset+=40;
    hwm_render(&view,clock_now);
    CGRect requested=projected[0];
    assert(!CGRectEqualToRect(previous,requested));
    assert(!windows[0].strip_transform_dirty && hwm_batch_open);
    sa_batch_fails=true;
    if(flush) hwm_batch_settle();
    hwm_batch_release();
    assert(!hwm_backend_ok && windows[0].strip_transform_dirty);
    // The fake helper applies eagerly; model a rejected transaction's pixels.
    projected[0]=previous;
    sa_batch_fails=false; hwm_backend_ok=true;
    int submissions=scale_calls;
    hwm_layout(&view,false); hwm_render(&view,clock_now+.01);
    assert(scale_calls>submissions);
    assert(CGRectEqualToRect(projected[0],requested));
    assert(!windows[0].strip_transform_dirty);
}

int main(void)
{
    @autoreleasepool {
        test_failed_frame_retries_unchanged_geometry(false);
        test_failed_frame_retries_unchanged_geometry(true);
        puts("plane batch recovery tests passed");
    }
    return 0;
}
