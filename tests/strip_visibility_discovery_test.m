/* Exercises the production desktop-discovery handoff without a live WM. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdatomic.h>

struct application { pid_t pid; };
struct window { uint32_t id; struct application *application; bool strip_offscreen,strip_close_pending; int strip_pop; };
struct view { int unused; };
static struct application app={.pid=77};
static struct window windows[1]={{.id=1,.application=&app}};
static struct { int unused; } g_window_manager;
static int g_connection,desktop_scans,wakes;
static uint32_t listed_wid=2;
static bool hwm_borders_external,hwm_overview_active,hwm_plane_fit_active,hwm_backend_ok=true;
static uint64_t hwm_move_failures;
static uint32_t hwm_drag_window;
static float alpha[5]={0,1,.8,.7,.6};
static dispatch_block_t scheduled_work;

#define table_for(declaration,table,body) for(int slot=0;slot<1;slot++) { declaration=&windows[slot]; body; }
#define HWM_VISIBILITY_SCHEDULE(work) (scheduled_work=[work copy])

static void hwm_wake(void) { ++wakes; }
static void hwm_batch_require_updates(void) {}
static float hwm_window_alpha(struct window *w) { (void)w; return 1; }
static CGError SLSGetWindowOwner(int connection,uint32_t wid,int *owner) { (void)connection; (void)wid; *owner=1; return kCGErrorSuccess; }
static CGError SLSConnectionGetPID(int owner,pid_t *pid) { (void)owner; *pid=app.pid; return kCGErrorSuccess; }
static CGError SLSGetWindowAlpha(int connection,uint32_t wid,float *out) { (void)connection; *out=alpha[wid]; return kCGErrorSuccess; }
static CGError SLSGetWindowBounds(int connection,uint32_t wid,CGRect *out) { (void)connection; (void)wid; *out=CGRectZero; return kCGErrorSuccess; }
static CFArrayRef SLSCopyAssociatedWindows(int connection,uint32_t wid) { (void)connection; (void)wid; return NULL; }
static struct window *window_manager_find_window(void *manager,uint32_t wid) { (void)manager; (void)wid; return NULL; }
static struct view *window_manager_find_managed_window(void *manager,struct window *window) { (void)manager; (void)window; return NULL; }
static bool scripting_addition_set_opacity(uint32_t wid,float value,float duration) { (void)duration; alpha[wid]=value; return true; }
static bool scripting_addition_move_window(uint32_t wid,double x,double y) { (void)wid; (void)x; (void)y; return true; }
static CFArrayRef test_window_list(CGWindowListOption option,CGWindowID wid)
{
    (void)option; (void)wid; ++desktop_scans;
    return (CFArrayRef)[@[@{(id)kCGWindowOwnerName:@"borders",(id)kCGWindowNumber:@(listed_wid),(id)kCGWindowOwnerPID:@(app.pid)}] copy];
}

#define CGWindowListCopyWindowInfo test_window_list
#include "../src/strip_visibility.m"
#undef CGWindowListCopyWindowInfo
#undef HWM_VISIBILITY_SCHEDULE

int main(void)
{
    @autoreleasepool {
        hwm_borders_external=true;
        hwm_visibility_prepare(NULL,1);
        assert(scheduled_work && desktop_scans==0 && alpha[2]==.8f);
        hwm_visibility_prepare(NULL,1.6);
        assert(desktop_scans==0); /* bounded: the in-flight discovery is reused */
        scheduled_work(); [scheduled_work release]; scheduled_work=nil;
        assert(desktop_scans==1 && wakes==1);
        listed_wid=3; /* Published data is immutable, not a borrowed desktop list. */
        hwm_visibility_prepare(NULL,1.61);
        assert(alpha[2]==0 && alpha[3]==.7f && !scheduled_work);
        /* Publication is consumed on the next frame, not delayed until the
         * next half-second discovery interval or another desktop scan. */
        hwm_visibility_prepare(NULL,2.2);
        assert(alpha[2]==0 && alpha[3]==.7f && scheduled_work);
        scheduled_work(); [scheduled_work release]; scheduled_work=nil;
        hwm_visibility_restore_all();
        [hwm_visibility_border_snapshot release]; hwm_visibility_border_snapshot=nil;
        puts("strip visibility discovery tests passed");
    }
    return 0;
}
