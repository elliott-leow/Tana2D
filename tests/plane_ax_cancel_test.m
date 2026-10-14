/* Cancellation boundary tests for coalesced asynchronous AX resizes. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static AXError test_AXUIElementSetAttributeValue(AXUIElementRef element,CFStringRef attribute,CFTypeRef value);
static bool test_ax_enhanced_userinterface(AXUIElementRef app);
static uint64_t test_read_os_timer(void);
static uint64_t test_read_os_freq(void);
static const CFStringRef kAXEnhancedUserInterface=CFSTR("AXEnhancedUserInterface");

#define HWM_AX_TESTING 1
#define AXUIElementSetAttributeValue test_AXUIElementSetAttributeValue
#define ax_enhanced_userinterface test_ax_enhanced_userinterface
#define read_os_timer test_read_os_timer
#define read_os_freq test_read_os_freq
#include "../src/strip_ax_async.m"
#undef read_os_freq
#undef read_os_timer
#undef ax_enhanced_userinterface
#undef AXUIElementSetAttributeValue

static dispatch_semaphore_t claimed,allow_claim,issued,allow_issue;
static _Atomic unsigned size_calls;
static CGSize last_size;

static AXError test_AXUIElementSetAttributeValue(AXUIElementRef element,CFStringRef attribute,CFTypeRef value)
{
    (void)element;
    if(CFEqual(attribute,kAXSizeAttribute)) {
        assert(AXValueGetValue((AXValueRef)value,kAXValueTypeCGSize,&last_size));
        ++size_calls;
        dispatch_semaphore_signal(issued);
        dispatch_semaphore_wait(allow_issue,DISPATCH_TIME_FOREVER);
    }
    return kAXErrorSuccess;
}

static bool test_ax_enhanced_userinterface(AXUIElementRef app) { (void)app; return false; }
static uint64_t test_read_os_timer(void) { return 0; }
static uint64_t test_read_os_freq(void) { return 1; }

static void expect_signal(dispatch_semaphore_t semaphore)
{
    assert(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
}

static void wait_idle(uint32_t wid)
{
    for(unsigned attempt=0;attempt<2000;attempt++) {
        if(!hwm_ax_resize_busy(wid)) return;
        usleep(1000);
    }
    assert(!"AX worker did not drain");
}

static void reset_ax(void)
{
    hwm_ax_test_before_issue=nil;
    os_unfair_lock_lock(&hwm_ax_lock);
    [hwm_ax_jobs release]; hwm_ax_jobs=nil;
    os_unfair_lock_unlock(&hwm_ax_lock);
    claimed=dispatch_semaphore_create(0);
    allow_claim=dispatch_semaphore_create(0);
    issued=dispatch_semaphore_create(0);
    allow_issue=dispatch_semaphore_create(0);
    atomic_store(&size_calls,0);
    last_size=CGSizeZero;
}

static void submit(uint32_t wid,CGSize size)
{
    AXUIElementRef window=AXUIElementCreateApplication(getpid());
    assert(window);
    hwm_ax_resize(wid,window,NULL,size);
    CFRelease(window);
}

static void test_pending_cancel(void)
{
    reset_ax();
    const uint32_t wid=91;
    os_unfair_lock_lock(&hwm_ax_lock);
    hwm_ax_jobs=[NSMutableDictionary new];
    TanaAXJob *job=[TanaAXJob new];
    job->epoch=1; job->pending=YES;
    hwm_ax_jobs[@(wid)]=job;
    [job release];
    os_unfair_lock_unlock(&hwm_ax_lock);
    assert(hwm_ax_cancel_resize(wid));
    os_unfair_lock_lock(&hwm_ax_lock);
    job=hwm_ax_jobs[@(wid)];
    assert(!job->pending && job->cancel_through==1 && !job->issued);
    os_unfair_lock_unlock(&hwm_ax_lock);
}

static void test_dequeued_cancel(void)
{
    reset_ax();
    hwm_ax_test_before_issue=^(uint64_t epoch) {
        assert(epoch==1); dispatch_semaphore_signal(claimed);
        dispatch_semaphore_wait(allow_claim,DISPATCH_TIME_FOREVER);
    };
    submit(92,CGSizeMake(410,300));
    expect_signal(claimed);
    assert(hwm_ax_cancel_resize(92));
    dispatch_semaphore_signal(allow_claim);
    wait_idle(92);
    assert(atomic_load(&size_calls)==0);
}

static void test_new_resize_after_cancel(void)
{
    reset_ax();
    hwm_ax_test_before_issue=^(uint64_t epoch) {
        assert(epoch==1 || epoch==2); dispatch_semaphore_signal(claimed);
        dispatch_semaphore_wait(allow_claim,DISPATCH_TIME_FOREVER);
    };
    submit(93,CGSizeMake(410,300));
    expect_signal(claimed);
    assert(hwm_ax_cancel_resize(93));
    submit(93,CGSizeMake(620,480));
    dispatch_semaphore_signal(allow_claim); // Let the cancelled epoch reach its fence.
    expect_signal(claimed);                 // The new epoch must survive cancellation.
    dispatch_semaphore_signal(allow_claim);
    expect_signal(issued);
    dispatch_semaphore_signal(allow_issue);
    wait_idle(93);
    assert(atomic_load(&size_calls)==1);
    assert(CGSizeEqualToSize(last_size,CGSizeMake(620,480)));
}

static void test_issued_resize_is_not_cancellable(void)
{
    reset_ax();
    submit(94,CGSizeMake(700,500));
    expect_signal(issued); // The worker set `issued` before entering this stub.
    assert(!hwm_ax_cancel_resize(94));
    dispatch_semaphore_signal(allow_issue);
    wait_idle(94);
    assert(atomic_load(&size_calls)==1);
}

int main(void)
{
    @autoreleasepool {
        test_pending_cancel();
        test_dequeued_cancel();
        test_new_resize_after_cancel();
        test_issued_resize_is_not_cancellable();
        puts("plane AX cancel tests passed");
    }
    return 0;
}
