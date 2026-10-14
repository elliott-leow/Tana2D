/* Standalone selection eligibility tests.  Reuse the deterministic production
 * harness without changing its shared runtime test. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreturn-type"
#define main plane_selection_runtime_main
#include "strip_runtime_test.m"
#undef main
#pragma clang diagnostic pop

static void selection_reset(void)
{
    reset();
    application.is_hidden=false;
    hwm_nav_pending=false; hwm_nav_window=0; selection_hit=NULL;
    for(int i=1;i<4;i++) windows[i].strip_offscreen=true;
}

static void test_primary_hit_visibility(void)
{
    struct window *w;

    selection_reset(); w=&windows[0]; selection_hit=w;
    assert(hwm_plane_window_at(&view,CGPointMake(100,100))==w);
    hwm_plane_selecting=true; hwm_plane_choose_at(CGPointMake(100,100));
    assert(!hwm_plane_selecting && hwm_nav_pending && hwm_nav_window==w->id);

    selection_reset(); w=&windows[0]; selection_hit=w; w->strip_offscreen=true;
    assert(!hwm_plane_window_at(&view,CGPointMake(100,100)));
    hwm_plane_selecting=true; hwm_plane_choose_at(CGPointMake(100,100));
    assert(hwm_plane_selecting && !hwm_nav_pending);

    selection_reset(); w=&windows[0]; selection_hit=w; w->strip_close_ghost=true;
    assert(!hwm_plane_window_at(&view,CGPointMake(100,100)));

    selection_reset(); w=&windows[0]; selection_hit=w; hidden_tab=w->id;
    assert(!hwm_plane_window_at(&view,CGPointMake(100,100)));

    selection_reset(); w=&windows[0]; selection_hit=w; application.is_hidden=true;
    assert(!hwm_plane_window_at(&view,CGPointMake(100,100)));
}

static void test_displayed_geometry_fallback_visibility(void)
{
    struct window *w;

    selection_reset(); w=&windows[0];
    w->strip_last_frame=CGRectMake(100,100,400,300); w->strip_last_plane_scale=.5;
    assert(hwm_plane_window_at(&view,CGPointMake(250,200))==w);

    selection_reset(); w=&windows[0];
    w->strip_last_frame=CGRectMake(100,100,400,300); w->strip_last_plane_scale=.5;
    w->strip_offscreen=true;
    assert(!hwm_plane_window_at(&view,CGPointMake(250,200)));

    selection_reset(); w=&windows[0];
    w->strip_last_frame=CGRectMake(100,100,400,300); w->strip_last_plane_scale=.5;
    hidden_tab=w->id;
    assert(!hwm_plane_window_at(&view,CGPointMake(250,200)));

    selection_reset(); w=&windows[0];
    w->strip_last_frame=CGRectMake(100,100,400,300); w->strip_last_plane_scale=.5;
    application.is_hidden=true;
    assert(!hwm_plane_window_at(&view,CGPointMake(250,200)));
}

static void test_magnet_ignores_nonselectable_hit(void)
{
    struct window *w;
    HWMPlaneCamera start={-1600,-330,.5};

    selection_reset(); w=&windows[0]; selection_hit=w;
    hwm_plane_scale=.5; view.strip_offset=-1640; test_camera_y=-330;
    w->strip_world_x=-740; w->strip_world_y=420; w->strip_width=400; w->strip_height=300;
    hidden_tab=w->id;
    hwm_plane_magnet_at(&view,CGPointMake(100,100),start);
    assert(view.strip_offset==-1640 && test_camera_y==-330);

    selection_reset(); w=&windows[0]; selection_hit=w;
    hwm_plane_scale=.5; view.strip_offset=-1640; test_camera_y=-330;
    w->strip_world_x=-740; w->strip_world_y=420; w->strip_width=400; w->strip_height=300;
    application.is_hidden=true;
    hwm_plane_magnet_at(&view,CGPointMake(100,100),start);
    assert(view.strip_offset==-1640 && test_camera_y==-330);
}

int main(void)
{
    @autoreleasepool {
        test_primary_hit_visibility();
        test_displayed_geometry_fallback_visibility();
        test_magnet_ignores_nonselectable_hit();
        puts("plane selection visibility tests passed");
    }
}
