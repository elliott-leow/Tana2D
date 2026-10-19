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
        /* Both axes engage while held, without changing the native size. */
        assert(moving->strip_world_x==200 && moving->strip_world_y==200);
        assert(moving->strip_width==100 && moving->strip_height==100);
        CGPoint target;
        assert(hwm_drag_snap_target(&view,moving,&target));
        assert(target.x==200 && target.y==200 && test_preview_visible && hwm_snap_contact_count==3);
        double sx=round(12+target.x*scale)-round(12+raw*scale);
        double sy=round(51+target.y*scale)-round(51+raw*scale);
        assert(fabs(sx)<=12 && fabs(sy)<=12);
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

static void test_held_magnet_releases_without_accumulating(void)
{
    for(int z=0;z<3;z++) {
        double scale=(double[]){.5,1,2}[z];
        multi_snap_scene(scale,4/scale);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+4/scale,200+4/scale)));
        assert(moving->strip_world_x==200 && moving->strip_world_y==200);
        for(int i=0;i<40;i++) {
            /* Motion inside the radius holds both axes; no cumulative offset. */
            double d=(i%3+3)/scale;
            assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+d,200+d)));
            assert(moving->strip_world_x==200 && moving->strip_world_y==200);
        }
        CGPoint escaped=CGPointMake(200+30/scale,200+30/scale);
        assert(hwm_drag_submit_plane(&view,moving,escaped));
        assert(moving->strip_world_x==escaped.x && moving->strip_world_y==escaped.y);
        assert(!hwm_snap_contact_count && !test_preview_visible);
        hwm_drag_release(&view,moving);
        assert(moving->strip_world_x==escaped.x && moving->strip_world_y==escaped.y);
        assert(moving->strip_width==100 && moving->strip_height==100);
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
        assert(moving->strip_world_x==188 && moving->strip_world_y==100);
        assert(projected[0].origin.x==round(12+188*scale));
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
                assert(fabs(sx)<=12 && fabs(sy)<=12);
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
    assert(moving->strip_world_x==188); /* Held snap survives native settling. */
    clock_now+=.06; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(hwm_drag_native && moving->strip_world_x==188);
    clock_now+=.01; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(hwm_drag_native && moving->strip_world_x==188);
    clock_now+=.09; hwm_drag_native_finish_tick(&view,moving,clock_now);
    assert(!hwm_drag_native && !hwm_drag_window);
    assert(moving->strip_world_x==188 && moving->strip_world_y==100);

    snap_scene(1,6);
    moving=&windows[0]; raw=moving->strip_world_x;
    hwm_drag_force_finalize(&view,false);
    assert(!hwm_drag_window && !hwm_drag_native);
    assert(moving->strip_world_x==raw && moving->strip_world_y==100);
}

static void test_release_hysteresis_holds_then_lets_go(void)
{
    const double scales[]={.5,1,2};
    for(size_t z=0;z<sizeof(scales)/sizeof(scales[0]);z++) {
        double s=scales[z];
        snap_scene(s,6/s);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(188+6/s,100)));
        assert(moving->strip_world_x==188 && test_haptic_engages==1);
        /* Beyond the 12-point engage radius but inside the 20-point hold. */
        for(int i=0;i<20;i++) {
            assert(hwm_drag_submit_plane(&view,moving,CGPointMake(188+(13+i%7)/s,100+i%5)));
            assert(moving->strip_world_x==188 && test_preview_visible);
            double sx=round(12+188*s)-round(12+(188+(13+i%7)/s)*s);
            assert(fabs(sx)<=20);
        }
        assert(test_haptic_engages==1);
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(188+21/s,100)));
        assert(moving->strip_world_x==188+21/s && !test_preview_visible && !hwm_snap_neighbor);
        /* Coming back, the wider hold no longer applies: re-engage at 12. */
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(188+16/s,100)));
        assert(moving->strip_world_x==188+16/s && !test_preview_visible);
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(188+11/s,100)));
        assert(moving->strip_world_x==188 && test_haptic_engages==2);
        hwm_drag_release(&view,moving);
        assert(moving->strip_world_x==188 && test_haptic_commits==1);
    }
}

static bool seam_present(int edge,double from,double to)
{
    for(size_t i=0;i<test_preview_seam_count;i++)
        if(test_preview_seams[i].edge==edge && test_preview_seams[i].from==from && test_preview_seams[i].to==to) return true;
    return false;
}

static void test_every_contact_gets_a_seam(void)
{
    const double scales[]={.5,1,2};
    for(size_t z=0;z<sizeof(scales)/sizeof(scales[0]);z++) {
        double s=scales[z];
        multi_snap_scene(s,4/s);
        struct window *moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+4/s,200+4/s)));
        /* Left, right and bottom contacts are all marked at once. */
        assert(test_preview_seam_count==3 && test_preview_gutter==12*s);
        assert(seam_present(1,0,round(100*s)) && seam_present(0,0,round(100*s)) && seam_present(2,0,round(100*s)));
        /* A corner shows a vertical and a horizontal bar simultaneously. */
        multi_snap_scene(s,4/s);
        windows[2].strip_world_x=20000; moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+4/s,200+4/s)));
        assert(moving->strip_world_x==200 && moving->strip_world_y==200);
        assert(test_preview_seam_count==2 && seam_present(1,0,round(100*s)) && seam_present(2,0,round(100*s)));
        /* 9 points off on both axes is 12.7 diagonally: still both bars. */
        multi_snap_scene(s,9/s); windows[2].strip_world_x=20000; moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+9/s,200+9/s)));
        assert(moving->strip_world_x==200 && moving->strip_world_y==200 && hwm_snap_contact_count==2);
        assert(test_preview_seam_count==2 && seam_present(1,0,round(100*s)) && seam_present(2,0,round(100*s)));
        hwm_drag_release(&view,moving);
        /* Sliding into the corner from one contact ticks again for the second. */
        multi_snap_scene(s,0); windows[2].strip_world_x=20000; moving=&windows[0];
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+4/s,200-40/s)));
        assert(test_preview_seam_count==1 && test_haptic_engages==1);
        assert(hwm_drag_submit_plane(&view,moving,CGPointMake(200+4/s,200+4/s)));
        assert(test_preview_seam_count==2 && test_haptic_engages==2);
        hwm_drag_release(&view,moving);
    }
    /* A shorter neighbor marks only the span the two windows share. */
    snap_scene(1,6);
    windows[1].strip_world_y=140; windows[1].strip_height=200;
    assert(hwm_drag_submit_plane(&view,&windows[0],CGPointMake(194,100)));
    assert(test_preview_seam_count==1 && seam_present(0,40,100));
}

static void test_command_places_freely(void)
{
    snap_scene(1,6);
    struct window *moving=&windows[0];
    hwm_snap_free=true;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    assert(moving->strip_world_x==194 && !test_preview_visible && !test_haptic_engages);
    hwm_snap_free=false;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    assert(moving->strip_world_x==188 && test_preview_visible);
    hwm_snap_free=true;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(194,100)));
    assert(moving->strip_world_x==194 && !test_preview_visible);
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==194 && test_haptic_commits==0);
    hwm_snap_free=false;
}

/* With motion on, the magnet eases the window onto its landing over a few
 * frames and holds it there exactly; letting go eases it back to the pointer. */
static void test_magnet_eases_onto_landing(void)
{
    hwm_motion_scale=1; multi_snap_scene(1,4); clock_now=100; hwm_drag_snap_reset(); hwm_snap_ease_reset();
    struct window *moving=&windows[0];
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(204,204)));
    assert(moving->strip_world_x==204 && hwm_snap_easing && hwm_snap_contact_count==3);
    clock_now+=.02;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(204,204)));
    assert(moving->strip_world_x>200 && moving->strip_world_x<204 && hwm_snap_easing);
    clock_now+=.5;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(205,203)));
    assert(moving->strip_world_x==200 && moving->strip_world_y==200 && !hwm_snap_easing);
    /* Held exactly, however the pointer moves inside the magnet's reach. */
    for(int i=0;i<10;i++) { clock_now+=.004; assert(hwm_drag_submit_plane(&view,moving,CGPointMake(203+i%3,201+i%2))); assert(moving->strip_world_x==200 && moving->strip_world_y==200); }
    /* Letting go: the pointer's jump is followed at once, the magnet's
     * displacement (last held at raw 203,202) eases out from there. */
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(230,230)));
    assert(moving->strip_world_x==227 && moving->strip_world_y==228 && hwm_snap_easing && !hwm_snap_contact_count);
    clock_now+=.02;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(231,230)));
    assert(moving->strip_world_x>228 && moving->strip_world_x<231 && hwm_snap_easing);
    clock_now+=.5;
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(230,230)));
    assert(moving->strip_world_x==230 && moving->strip_world_y==230 && !hwm_snap_easing);
    hwm_drag_release(&view,moving);
    assert(moving->strip_world_x==230 && moving->strip_world_y==230);
    /* Motion off: the magnet places at once. */
    hwm_motion_scale=0; multi_snap_scene(1,4); hwm_drag_snap_reset(); hwm_snap_ease_reset();
    assert(hwm_drag_submit_plane(&view,moving,CGPointMake(204,204)));
    assert(moving->strip_world_x==200 && moving->strip_world_y==200 && !hwm_snap_easing);
    hwm_drag_release(&view,moving);
}

int main(void)
{
    hwm_motion_scale=0; // These check where the magnet places, not how it gets there.
    test_magnet_eases_onto_landing();
    @autoreleasepool {
        test_held_magnet_releases_without_accumulating();
        test_held_drag_and_preview_target();
        test_runtime_multi_neighbor_snap();
        test_snap_feedback_engages_once_and_clears();
        test_runtime_snap_reduces_existing_overlap();
        test_release_commits_gap_at_each_zoom();
        test_missed_and_blocked_releases_do_not_snap();
        test_snap_ignores_offscreen_neighbors_and_bounds_rounding();
        test_native_release_waits_to_snap_and_interrupt_does_not();
        test_release_hysteresis_holds_then_lets_go();
        test_every_contact_gets_a_seam();
        test_command_places_freely();
        puts("plane snap runtime tests passed");
    }
    return 0;
}
