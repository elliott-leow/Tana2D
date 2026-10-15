/* Reuse the deterministic runtime boundary harness; this target adds only
 * snap-specific release coverage. */
#define main strip_runtime_harness_main
#include "strip_runtime_test.m"
#undef main

static void snap_scene(double scale,double offset)
{
    reset();
    hwm_plane_scale=scale;
    for(int i=0;i<4;i++) {
        windows[i].strip_initialized=true;
        windows[i].strip_width=100;
        windows[i].strip_height=100;
        windows[i].strip_world_x=10000+i*1000;
        windows[i].strip_world_y=10000;
    }
    /* Window one is the anchor.  Window zero's left-adjacent target is 188. */
    windows[1].strip_world_x=300;
    windows[1].strip_world_y=100;
    windows[0].strip_world_x=188+offset;
    windows[0].strip_world_y=100;
    hwm_drag_window=windows[0].id;
}

static void multi_snap_scene(double scale,double offset)
{
    reset();
    hwm_plane_scale=scale;
    for(int i=0;i<4;i++) {
        windows[i].strip_initialized=true;
        windows[i].strip_width=100;
        windows[i].strip_height=100;
    }
    /* Window zero can preserve its size at (200,200), fitting between the
     * left/right peers and above the lower peer with the normal 12-point gap. */
    windows[0].strip_world_x=200+offset; windows[0].strip_world_y=200+offset;
    windows[1].strip_world_x=0; windows[1].strip_world_y=200; windows[1].strip_width=188;
    windows[2].strip_world_x=312; windows[2].strip_world_y=200;
    windows[3].strip_world_x=200; windows[3].strip_world_y=312;
    hwm_drag_window=windows[0].id;
}

static void test_runtime_multi_neighbor_snap(void)
{
    const double scales[]={.7,1,2};
    for(size_t i=0;i<sizeof(scales)/sizeof(scales[0]);i++) {
        double scale=scales[i],offset=4/scale,raw=200+offset;
        multi_snap_scene(scale,offset);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(raw,raw)));
        /* Held movement remains exact; the common three-contact point is only
         * previewed until release. */
        assert(moving->strip_world_x==raw && moving->strip_world_y==raw);
        CGPoint target;
        assert(hwm_drag_snap_target(&view,moving,&target));
        assert(target.x==200 && target.y==200 && test_preview_visible && hwm_snap_contact_count==3);
        double sx=round(12+target.x*scale)-round(12+raw*scale);
        double sy=round(51+target.y*scale)-round(51+raw*scale);
        assert(hypot(sx,sy)<=12);
        hwm_drag_release(&view,moving);
        assert(moving->strip_world_x==200 && moving->strip_world_y==200);
        assert(hwm_snap_contact_count==0);
        assert(windows[1].strip_world_x+windows[1].strip_width==188);
        assert(moving->strip_world_x-(windows[1].strip_world_x+windows[1].strip_width)==12);
        assert(windows[2].strip_world_x-(moving->strip_world_x+moving->strip_width)==12);
        assert(windows[3].strip_world_y-(moving->strip_world_y+moving->strip_height)==12);
        assert(test_haptic_engages==1 && test_haptic_commits==1);
    }
}

static void test_held_drag_and_preview_target(void)
{
    const double scales[]={.5,1,2};
    for(size_t i=0;i<sizeof(scales)/sizeof(scales[0]);i++) {
        double scale=scales[i],raw=188+6/scale;
        snap_scene(scale,6/scale);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(raw,100)));
        /* The held surface follows the pointer; preview computation cannot move it. */
        assert(moving->strip_world_x==raw && moving->strip_world_y==100);
        assert(projected[0].origin.x==round(12+raw*scale));
        CGPoint preview;
        assert(hwm_drag_snap_target(&view,moving,&preview));
        assert(preview.x==188 && preview.y==100);
        assert(test_preview_visible);
        assert(CGRectEqualToRect(test_preview_frame,CGRectMake(round(12+188*scale),round(51+100*scale),round(100*scale),round(100*scale))));
    }
}

static void test_release_commits_gap_at_each_zoom(void)
{
    const double scales[]={.5,1,2};
    for(size_t i=0;i<sizeof(scales)/sizeof(scales[0]);i++) {
        double scale=scales[i],raw=188+6/scale;
        snap_scene(scale,6/scale);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(raw,100)));
        hwm_drag_release(&view,moving);
        assert(!hwm_drag_window && !test_preview_visible);
        assert(moving->strip_world_x==188 && moving->strip_world_y==100);
        assert(windows[1].strip_world_x-(moving->strip_world_x+moving->strip_width)==12);
    }
}

static void test_snap_feedback_engages_once_and_clears(void)
{
    snap_scene(1,6);
    struct window *moving=&windows[0];
    for(int i=0;i<50;i++) {
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100+i%3)));
        assert(test_preview_visible && test_preview_edge==0);
    }
    assert(test_haptic_engages==1 && test_haptic_commits==0);
    assert(hwm_snap_neighbor==windows[1].id);
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(214,100)));
    assert(!test_preview_visible && !hwm_snap_neighbor);
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    assert(test_haptic_engages==2);
    hwm_drag_release(&view,moving);
    assert(test_haptic_commits==1 && !hwm_snap_neighbor && !test_preview_visible);
    assert(moving->strip_world_x==188);
}

static void test_runtime_snap_reduces_existing_overlap(void)
{
    snap_scene(1,6);
    struct window *moving=&windows[0];
    windows[2].strip_world_x=195; windows[2].strip_world_y=90;
    windows[2].strip_width=100; windows[2].strip_height=120;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    assert(test_preview_visible);
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==188);
    snap_scene(1,-6); moving=&windows[0];
    windows[2].strip_world_x=195; windows[2].strip_world_y=90;
    windows[2].strip_width=110; windows[2].strip_height=120;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(182,100)));
    assert(test_preview_visible);
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==188);
}

static void test_missed_and_blocked_releases_do_not_snap(void)
{
    snap_scene(1,25); /* Well beyond the 12-screen-point radius. */
    struct window *moving=&windows[0];
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(213,100)));
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==213 && moving->strip_world_y==100);

    snap_scene(1,6);
    moving=&windows[0];
    /* Landing left of window one would collide with this third window. */
    windows[2].strip_world_x=188;
    windows[2].strip_world_y=100;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==194 && moving->strip_world_y==100);
}

static void test_snap_ignores_offscreen_neighbors_and_bounds_rounding(void)
{
    snap_scene(1,6);
    struct window *moving=&windows[0];
    /* World-near windows on a different part of the plane are not magnets. */
    moving->strip_world_x+=10000; windows[1].strip_world_x+=10000;
    CGPoint target;
    assert(!hwm_drag_snap_target(&view,moving,&target));
    const double scales[]={.5,.7,1,2};
    for(size_t z=0;z<sizeof(scales)/sizeof(scales[0]);z++) {
        double scale=scales[z];
        for(int dx=-24;dx<=24;dx++) for(int dy=-24;dy<=24;dy++) {
            snap_scene(scale,dx*.5/scale);
            moving=&windows[0]; moving->strip_world_y+=dy*.5/scale;
            if(hwm_drag_snap_target(&view,moving,&target)) {
                double sx=round(12+target.x*scale)-round(12+moving->strip_world_x*scale);
                double sy=round(51+target.y*scale)-round(51+moving->strip_world_y*scale);
                assert(hypot(sx,sy)<=12);
            }
        }
    }
}

static void test_native_release_waits_to_snap_and_interrupt_does_not(void)
{
    snap_scene(1,6);
    struct window *moving=&windows[0];
    double raw=moving->strip_world_x;
    hwm_drag_native=true;
    hwm_drag_native_moved=true;
    g_mouse_state.window_frame=actual[0];
    actual[0]=CGRectMake(12+raw,151,100,100);
    projected[0].origin=actual[0].origin;
    projected[0].size=actual[0].size;
    hwm_drag_release(&view,moving);
    assert(hwm_drag_native && hwm_drag_window==moving->id);
    assert(moving->strip_world_x==raw); /* Release only begins settling. */
    clock_now+=.06; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(hwm_drag_native && moving->strip_world_x==raw);
    clock_now+=.01; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(hwm_drag_native && moving->strip_world_x==raw);
    clock_now+=.09; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(!hwm_drag_native && !hwm_drag_window);
    assert(moving->strip_world_x==188 && moving->strip_world_y==100);

    snap_scene(1,6);
    moving=&windows[0]; raw=moving->strip_world_x;
    hwm_drag_force_finalize(&view,false);
    assert(!hwm_drag_window && !hwm_drag_native);
    assert(moving->strip_world_x==raw && moving->strip_world_y==100);
}

int main(void)
{
    @autoreleasepool {
        test_held_drag_and_preview_target();
        test_runtime_multi_neighbor_snap();
        test_snap_feedback_engages_once_and_clears();
        test_runtime_snap_reduces_existing_overlap();
        test_release_commits_gap_at_each_zoom();
        test_missed_and_blocked_releases_do_not_snap();
        test_snap_ignores_offscreen_neighbors_and_bounds_rounding();
        test_native_release_waits_to_snap_and_interrupt_does_not();
        puts("plane snap runtime tests passed");
    }
    return 0;
}
