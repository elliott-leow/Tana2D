/* Primary visibility failures must not separate an app window from a recorded
 * companion border.  This keeps the test at the visibility seam rather than
 * depending on a live WindowServer/helper failure. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>

struct application { pid_t pid; };
struct window {
    uint32_t id;
    struct application *application;
    bool strip_offscreen,strip_close_pending;
    int strip_pop;
};
struct view { int unused; };

static struct application application={.pid=4242};
static struct window windows[2]={{.id=1,.application=&application},{.id=2,.application=&application}};
static struct { int unused; } g_window_manager;
static int g_connection;
static bool hwm_borders_external,hwm_overview_active,hwm_plane_fit_active,hwm_backend_ok=true;
static uint64_t hwm_move_failures;
static uint32_t hwm_drag_window;
static int desktop_scans;
static float alpha[3]={0,1,.75f};
static CGRect frames[3];
static int primary_opacity_failures,companion_moves;

#define table_for(declaration,table,body) for(int slot=0;slot<2;slot++) { declaration=&windows[slot]; body; }

static float hwm_window_alpha(struct window *w) { (void)w; return 1; }
static void hwm_batch_require_updates(void) {}
static void hwm_wake(void) {}
static bool hwm_visibility_owned(uint32_t wid,pid_t pid);
static struct window *window_manager_find_window(void *manager,uint32_t wid)
{ (void)manager; return wid>=1 && wid<=2 ? &windows[wid-1] : NULL; }
static struct view *window_manager_find_managed_window(void *manager,struct window *window)
{ (void)manager; (void)window; return NULL; }
static CGError SLSGetWindowOwner(int connection,uint32_t wid,int *owner)
{ (void)connection; (void)wid; *owner=1; return kCGErrorSuccess; }
static CGError SLSConnectionGetPID(int owner,pid_t *pid)
{ (void)owner; *pid=application.pid; return kCGErrorSuccess; }
static CGError SLSGetWindowAlpha(int connection,uint32_t wid,float *out)
{ (void)connection; *out=alpha[wid]; return kCGErrorSuccess; }
static CGError SLSGetWindowBounds(int connection,uint32_t wid,CGRect *out)
{ (void)connection; *out=frames[wid]; return kCGErrorSuccess; }
static CFArrayRef SLSCopyAssociatedWindows(int connection,uint32_t wid)
{ (void)connection; (void)wid; return NULL; }
static CFArrayRef test_window_list(CGWindowListOption option,CGWindowID wid)
{ (void)option; (void)wid; ++desktop_scans; return NULL; }
static bool plane_alpha_supported;
static bool scripting_addition_plane_alpha_supported(void) { return plane_alpha_supported; }
static bool scripting_addition_set_opacity(uint32_t wid,float value,float duration)
{
    (void)duration;
    if(wid==1 && primary_opacity_failures) { --primary_opacity_failures; return false; }
    alpha[wid]=value;
    return true;
}
static bool scripting_addition_move_window(uint32_t wid,double x,double y)
{
    ++companion_moves;
    frames[wid].origin=CGPointMake(x,y);
    return true;
}

#define CGWindowListCopyWindowInfo test_window_list
#define HWM_VISIBILITY_SCHEDULE(work) (work)()
static void scripting_addition_batch_begin(void) {}
static bool scripting_addition_batch_end(void) { return true; }
static void hwm_batch_failed(void) {}
#include "../src/strip_visibility.m"
#undef HWM_VISIBILITY_SCHEDULE
#undef CGWindowListCopyWindowInfo

static void reset_scene(bool hidden)
{
    windows[0].strip_offscreen=hidden;
    windows[0].strip_pop=0;
    windows[0].strip_close_pending=false;
    alpha[1]=hidden ? 0 : 1;
    alpha[2]=hidden ? 0 : .75f;
    frames[1]=CGRectMake(20,80,400,300);
    frames[2]=CGRectMake(6,66,428,328);
    primary_opacity_failures=0;
    companion_moves=0;
    hwm_backend_ok=true;
    hwm_move_failures=0;
    hwm_overview_active=false;
    hwm_plane_fit_active=false;
    if(!hwm_visibility_companions) hwm_visibility_companions=[NSMutableDictionary new];
    [hwm_visibility_companions removeAllObjects];
    hwm_visibility_companions[@2]=[NSMutableDictionary dictionaryWithDictionary:@{
        @"id":@2,@"pid":@(application.pid),@"parent":@1,@"parentPid":@(application.pid),
        @"alpha":@(.75f),@"hidden":@(hidden),@"dx":@(-14),@"dy":@(-14)}];
}

static void test_failed_hide_keeps_companion_visible(void)
{
    reset_scene(false);
    primary_opacity_failures=1;
    hwm_visibility_set(&windows[0],true,CGRectNull);
    assert(!windows[0].strip_offscreen && alpha[1]==1 && alpha[2]==.75f);
    assert(![hwm_visibility_companions[@2][@"hidden"] boolValue]);
    assert(!companion_moves && !hwm_backend_ok && hwm_move_failures==1);
}

static void test_failed_reveal_keeps_companion_hidden(void)
{
    reset_scene(true);
    frames[2].origin=CGPointMake(-900,38);
    primary_opacity_failures=1;
    hwm_visibility_set(&windows[0],false,frames[1]);
    assert(windows[0].strip_offscreen && alpha[1]==0 && alpha[2]==0);
    assert([hwm_visibility_companions[@2][@"hidden"] boolValue]);
    assert(!companion_moves && !hwm_backend_ok && hwm_move_failures==1);
}

int main(void)
{
    @autoreleasepool {
        test_failed_hide_keeps_companion_visible();
        test_failed_reveal_keeps_companion_hidden();
        hwm_borders_external=true; hwm_drag_window=1;
        for(int i=0;i<240;i++) hwm_visibility_prepare(NULL,10+i/120.0);
        assert(desktop_scans==0);
        hwm_drag_window=0; hwm_visibility_prepare(NULL,12);
        assert(desktop_scans==1);
        puts("plane visibility failure tests passed");
    }
    return 0;
}
