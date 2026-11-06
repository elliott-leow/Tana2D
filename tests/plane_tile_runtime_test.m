#define main strip_runtime_harness_main
#include "strip_runtime_test.m"
#undef main

static struct window *tile_scene(double scale)
{
    reset(); hwm_plane_scale=scale;
    for(int i=0;i<4;i++) {
        windows[i].strip_initialized=true; windows[i].strip_width=300; windows[i].strip_height=250;
        windows[i].strip_world_x=10000+i*1000; windows[i].strip_world_y=10000;
    }
    windows[1].strip_world_x=400; windows[1].strip_world_y=200;
    windows[0].strip_world_x=0; windows[0].strip_world_y=200;
    hwm_drag_committed=true;
    hwm_drag_window=windows[0].id; hwm_drag_world_origin=CGPointMake(0,200);
    return &windows[0];
}
static void test_pause_offer_release_resizes_both_halves(void)
{
    for(int i=0;i<3;i++) {
        struct window *w=tile_scene((double[]){.25,.5,1}[i]);
        CGPoint raw=CGPointMake(250,200),landing;
        assert(hwm_drag_submit_plane(&view,w,raw));
        assert(!hwm_tile_offer.armed);
        clock_now+=.14; hwm_drag_preview_update(&view,w);
        assert(!hwm_tile_offer.armed);
        clock_now+=.02; hwm_drag_preview_update(&view,w);
        assert(hwm_tile_offer.armed && test_preview_visible);
        assert(w->strip_world_x==250); // An offer never moves the held surface.
        HWMPlaneTilePlan plan=hwm_tile_offer.plan;
        assert(plan.split && plan.moving.width==594 && plan.peer.width==594);
        assert(hwm_tile_commit_target(&view,w,&landing) && landing.x==plan.moving.x && landing.y==plan.moving.y);
        assert(windows[1].strip_world_x==400 && windows[1].strip_width==300);
        int haptics=test_haptic_engages;
        for(int j=0;j<30;j++) { clock_now+=1.0/120; hwm_drag_preview_update(&view,w); }
        assert(test_haptic_engages==haptics);
        hwm_drag_release(&view,w);
        assert(w->strip_world_x==plan.moving.x && w->strip_world_y==plan.moving.y);
        assert(w->strip_width==594 && w->strip_height==900);
        assert(windows[1].strip_world_x==plan.peer.x && windows[1].strip_world_y==plan.peer.y);
        assert(windows[1].strip_width==594 && windows[1].strip_height==900);
        assert(tile_raise_count==2);
        assert(!hwm_tile_offer.armed && !hwm_drag_window);
    }
}
static void test_crossing_escape_and_bypass(void)
{
    struct window *w=tile_scene(1); CGPoint landing;
    for(int i=0;i<10;i++) {
        clock_now+=.03;
        hwm_drag_submit_plane(&view,w,CGPointMake(250+i*30,200));
        assert(!hwm_tile_offer.armed);
    }
    hwm_drag_release(&view,w); assert(w->strip_world_x==520);
    w=tile_scene(1); hwm_drag_submit_plane(&view,w,CGPointMake(250,200));
    clock_now+=.25; hwm_drag_preview_update(&view,w); assert(hwm_tile_offer.armed);
    hwm_drag_submit_plane(&view,w,CGPointMake(0,200));
    assert(!hwm_tile_offer.armed && !hwm_tile_commit_target(&view,w,&landing));
    w=tile_scene(1); hwm_drag_submit_plane(&view,w,CGPointMake(250,200));
    clock_now+=.25; hwm_drag_preview_update(&view,w); assert(hwm_tile_offer.armed);
    hwm_drag_decline_docking(); hwm_drag_preview_update(&view,w);
    assert(!hwm_tile_offer.armed && !test_preview_visible);
    hwm_drag_release(&view,w); assert(w->strip_world_x==250);
    w=tile_scene(1); hwm_snap_free=true;
    hwm_drag_submit_plane(&view,w,CGPointMake(250,200)); clock_now+=1; hwm_drag_preview_update(&view,w);
    assert(!hwm_tile_offer.armed && !test_preview_visible);
}
static void test_no_collisions_stale_targets_or_forced_commits(void)
{
    struct window *w=tile_scene(1); CGPoint landing;
    windows[2].strip_world_x=88; windows[2].strip_world_y=200;
    hwm_drag_submit_plane(&view,w,CGPointMake(250,200)); clock_now+=.3; hwm_drag_preview_update(&view,w);
    assert(hwm_tile_offer.armed); // Other apps keep their geometry; background overlap is allowed.
    assert(windows[2].strip_world_x==88 && windows[2].strip_width==300);
    w=tile_scene(1); hwm_drag_submit_plane(&view,w,CGPointMake(250,200));
    clock_now+=.25; hwm_drag_preview_update(&view,w); assert(hwm_tile_offer.armed);
    windows[1].strip_close_pending=true;
    assert(!hwm_tile_commit_target(&view,w,&landing));
    w=tile_scene(1); hwm_drag_submit_plane(&view,w,CGPointMake(250,200));
    clock_now+=.25; hwm_drag_preview_update(&view,w); assert(hwm_tile_offer.armed);
    hwm_drag_force_finalize(&view,false); assert(w->strip_world_x==250 && !hwm_tile_offer.armed);
}
static void test_overlap_depth(void)
{
    HWMPlaneRect peer={400,200,300,250},moving={250,200,300,250};
    assert(hwm_plane_tile_overlap(moving,peer,1)==.5);
    moving.x=110; assert(hwm_plane_tile_overlap(moving,peer,1)==0); // A grazing edge is insufficient.
}
static struct window *split_scene(void)
{
    struct window *m=tile_scene(1),*p=&windows[1];
    m->strip_width=900; m->strip_height=800;
    p->strip_world_x=0; p->strip_world_y=0; p->strip_width=1200; p->strip_height=900;
    hwm_drag_world_origin=CGPointMake(-1000,0);
    hwm_drag_committed=true;
    assert(hwm_drag_submit_plane(&view,m,CGPointMake(-200,0)));
    clock_now+=.25; hwm_drag_preview_update(&view,m);
    assert(hwm_tile_offer.armed && hwm_tile_offer.plan.split);
    assert(p->strip_world_x==0 && p->strip_width==1200); // Preview is non-destructive.
    return m;
}
static void test_split_commit_and_minimum_fallback(void)
{
    struct window *m=split_scene(),*p=&windows[1];
    hwm_drag_release(&view,m);
    assert(hwm_tile_split.active && !hwm_drag_window);
    assert(m->strip_world_x==0 && p->strip_world_x==606);
    assert(m->strip_width==594 && p->strip_width==594);
    assert(m->strip_height==900 && p->strip_height==900);
    assert(hwm_plane_scale==1 && view.strip_offset==0 && test_camera_y==0);
    actual[0].size=CGSizeMake(594,900); actual[1].size=CGSizeMake(594,900);
    clock_now+=1;
    assert(!hwm_tile_split_tick(&view,clock_now) && !hwm_tile_split.active);
    m=split_scene(); p=&windows[1]; hwm_drag_release(&view,m);
    actual[0].size=CGSizeMake(800,900); actual[1].size=CGSizeMake(594,900); // App refuses the half-width.
    resize_busy=true; clock_now+=1;
    assert(hwm_tile_split_tick(&view,clock_now) && hwm_tile_split.active);
    assert(p->strip_world_x==606); // Never race an unfinished resize.
    resize_busy=false;
    assert(hwm_tile_split_tick(&view,clock_now) && !hwm_tile_split.active);
    assert(p->strip_world_x==0 && p->strip_world_y==0 && p->strip_width==1200 && p->strip_height==900);
    assert(m->strip_world_x==-200 && m->strip_width==900 && m->strip_height==800);
    m=split_scene(); p=&windows[1]; hwm_drag_release(&view,m);
    m->strip_world_x+=50; clock_now+=1;
    assert(!hwm_tile_split_tick(&view,clock_now) && !hwm_tile_split.active);
    assert(m->strip_world_x==50); // A new placement owns its geometry.
}
static void test_split_stale_preview_and_background_windows(void)
{
    struct window *m=split_scene(); CGPoint target;
    view.strip_offset=20; // Camera geometry no longer matches the shown split.
    assert(!hwm_tile_commit_target(&view,m,&target));
    hwm_drag_force_finalize(&view,false);
    m=tile_scene(1);
    m->strip_width=900; m->strip_height=800;
    windows[1].strip_world_x=0; windows[1].strip_world_y=0; windows[1].strip_width=1200; windows[1].strip_height=900;
    windows[2].strip_world_x=700; windows[2].strip_world_y=100;
    hwm_drag_world_origin=CGPointMake(-1000,0);
    hwm_drag_submit_plane(&view,m,CGPointMake(-200,0)); clock_now+=.3; hwm_drag_preview_update(&view,m);
    assert(hwm_tile_offer.armed && hwm_tile_offer.plan.split);
    hwm_drag_release(&view,m);
    assert(windows[2].strip_world_x==700 && windows[2].strip_world_y==100 && windows[2].strip_width==300);
}
static void test_tiling_intent_is_not_inferred_after_release_or_while_moving(void)
{
    struct window *m=tile_scene(1);
    hwm_drag_submit_plane(&view,m,CGPointMake(250,200));
    atomic_store(&hwm_drag_release_pending,true); clock_now+=1;
    hwm_drag_preview_update(&view,m);
    assert(!hwm_tile_offer.armed); // Native grace time cannot complete an unmade gesture.
    m=tile_scene(1); hwm_drag_submit_plane(&view,m,CGPointMake(250,200));
    clock_now+=.25; hwm_drag_preview_update(&view,m); assert(hwm_tile_offer.armed);
    hwm_drag_submit_plane(&view,m,CGPointMake(225,200));
    assert(!hwm_tile_offer.armed); // Resuming motion withdraws the split offer.
    hwm_drag_release(&view,m);
    assert(m->strip_width==300 && windows[1].strip_width==300);
    m=tile_scene(1); m->strip_world_x=400;hwm_drag_world_origin=CGPointMake(400,200);
    hwm_drag_submit_plane(&view,m,CGPointMake(420,200)); clock_now+=1;hwm_drag_preview_update(&view,m);
    assert(!hwm_tile_offer.armed); // Moving an already overlapping window away is free.
}
static void test_stale_width_hints_do_not_veto_the_overlapping_pair(void)
{
    struct window *m=tile_scene(1),*p=&windows[1];
    // The reported screenshot: a large browser behind a roughly half-width
    // terminal. Prior height reconciliation may have cached their full widths.
    m->strip_width=855;m->strip_height=1061;
    p->strip_world_x=-53;p->strip_world_y=30;p->strip_width=1695;p->strip_height=1019;
    m->strip_min_width=855;p->strip_min_width=1695;
    hwm_drag_world_origin=CGPointMake(1600,30);
    assert(hwm_drag_submit_plane(&view,m,CGPointMake(800,30)));
    clock_now+=.25;hwm_drag_preview_update(&view,m);
    assert(hwm_tile_offer.armed && hwm_tile_offer.plan.split);
    hwm_drag_release(&view,m);
    assert(m->strip_width==594 && p->strip_width==594);
    assert(m->strip_world_x==606 && p->strip_world_x==0);
}
static void test_partial_overlap_can_arm_while_gently_dragging(void)
{
    struct window *m=tile_scene(1),*p=&windows[1];
    m->strip_world_x=280;hwm_drag_world_origin=CGPointMake(280,200);
    assert(hwm_drag_submit_plane(&view,m,CGPointMake(280,200)));
    clock_now+=.1;hwm_drag_submit_plane(&view,m,CGPointMake(300,200));
    clock_now+=.08;hwm_drag_submit_plane(&view,m,CGPointMake(304,200));
    clock_now+=.08;hwm_drag_submit_plane(&view,m,CGPointMake(308,200));
    assert(hwm_tile_offer.armed);
    hwm_drag_release(&view,m);
    assert(m->strip_width==594 && p->strip_width==594);
}
static void test_crossing_the_middle_does_not_erase_retreat_intent(void)
{
    struct window *m=tile_scene(1);
    hwm_drag_submit_plane(&view,m,CGPointMake(250,200));clock_now+=.2;hwm_drag_preview_update(&view,m);
    assert(hwm_tile_offer.armed);
    const double x[]={300,350,400,430,450};
    for(unsigned i=0;i<sizeof(x)/sizeof(*x);i++) {
        clock_now+=.2;hwm_drag_submit_plane(&view,m,CGPointMake(x[i],200));
    }
    clock_now+=.5;hwm_drag_preview_update(&view,m);
    assert(!hwm_tile_offer.armed);
}
int main(void)
{
    test_pause_offer_release_resizes_both_halves();
    test_crossing_escape_and_bypass();
    test_crossing_the_middle_does_not_erase_retreat_intent();
    test_partial_overlap_can_arm_while_gently_dragging();
    test_stale_width_hints_do_not_veto_the_overlapping_pair();
    test_tiling_intent_is_not_inferred_after_release_or_while_moving();
    test_no_collisions_stale_targets_or_forced_commits();
    test_overlap_depth();
    test_split_commit_and_minimum_fallback();
    test_split_stale_preview_and_background_windows();
    puts("overlap tiling dwell, preview, release, bypass, collision and size tests passed");
    return 0;
}
