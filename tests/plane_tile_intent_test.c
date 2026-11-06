#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/plane_tile_intent.h"
static void near(double a,double b) { assert(fabs(a-b)<1e-9); }
static void test_evidence(void)
{
    HWMPlaneRect p={400,100,300,250},o={280,100,300,250},m=o;
    HWMPlaneTileEvidence e={0};
    /* Already partially overlapping: a gentle approach and small motion
     * throughout the interval arms without a precise stationary pause. */
    assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x=300; assert(!hwm_plane_tile_evidence_update(&e,.10,m,o,p,1,true));
    m.x=304; assert(!hwm_plane_tile_evidence_update(&e,.18,m,o,p,1,true));
    m.x=308; assert(hwm_plane_tile_evidence_update(&e,.26,m,o,p,1,true));
    m.x=304; assert(hwm_plane_tile_evidence_update(&e,.30,m,o,p,1,true));
    m.x=285; assert(!hwm_plane_tile_evidence_update(&e,.35,m,o,p,1,true));
    /* A slow continued retreat must not re-arm between distance thresholds. */
    for(int i=0;i<20;i++) {
        m.x=284-i;
        assert(!hwm_plane_tile_evidence_update(&e,.40+i*.1,m,o,p,1,true));
    }
    /* A new, closer approach can start fresh evidence. */
    m.x=313; assert(!hwm_plane_tile_evidence_update(&e,2.5,m,o,p,1,true));
    assert(!hwm_plane_tile_evidence_update(&e,2.6,m,o,p,1,true));
    assert(hwm_plane_tile_evidence_update(&e,2.76,m,o,p,1,true));
    hwm_plane_tile_evidence_reset(&e);
    /* Too little movement cannot arm, even after a long hold. */
    m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x+=10; assert(!hwm_plane_tile_evidence_update(&e,1,m,o,p,1,true));
    assert(!hwm_plane_tile_evidence_update(&e,2,m,o,p,1,true));
    hwm_plane_tile_evidence_reset(&e);
    /* A fast pass through the peer never settles and cannot arm. */
    o.x=0; m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x=280; assert(!hwm_plane_tile_evidence_update(&e,.1,m,o,p,1,true));
    m.x=400; assert(!hwm_plane_tile_evidence_update(&e,.2,m,o,p,1,true));
    m.x=520; assert(!hwm_plane_tile_evidence_update(&e,.3,m,o,p,1,true));
    hwm_plane_tile_evidence_reset(&e);
    o.x=280; m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x=300; assert(!hwm_plane_tile_evidence_update(&e,.1,m,o,p,1,true));
    assert(!hwm_plane_tile_evidence_update(&e,.5,m,o,p,1,false));
    assert(!hwm_plane_tile_evidence_update(&e,.7,m,o,p,1,true));
    hwm_plane_tile_evidence_reset(&e);
    m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x=300; assert(!hwm_plane_tile_evidence_update(&e,.1,m,o,p,1,true));
    assert(hwm_plane_tile_evidence_update(&e,.26,m,o,p,1,true));
    m.x=280; assert(!hwm_plane_tile_evidence_update(&e,.27,m,o,p,1,false));
    /* Release latches the offer but later frames still cancel an outward move. */
    hwm_plane_tile_evidence_reset(&e);
    m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x=300; assert(!hwm_plane_tile_evidence_update(&e,.1,m,o,p,1,true));
    assert(hwm_plane_tile_evidence_update(&e,.26,m,o,p,1,true));
    assert(hwm_plane_tile_evidence_update(&e,.27,m,o,p,1,false));
    m.x=297; assert(hwm_plane_tile_evidence_update(&e,.30,m,o,p,1,false));
    m.x=280; assert(!hwm_plane_tile_evidence_update(&e,.35,m,o,p,1,false));
    m.x=300; assert(!hwm_plane_tile_evidence_update(&e,.5,m,o,p,1,false));
    /* Exactly stacked windows can express intent with a larger move and
     * longer settling interval, while small adjustments do not arm. */
    hwm_plane_tile_evidence_reset(&e);
    o=p; m=o; assert(!hwm_plane_tile_evidence_update(&e,0,m,o,p,1,true));
    m.x+=20; assert(!hwm_plane_tile_evidence_update(&e,.1,m,o,p,1,true));
    assert(!hwm_plane_tile_evidence_update(&e,.4,m,o,p,1,true));
    m.x=434; assert(!hwm_plane_tile_evidence_update(&e,.5,m,o,p,1,true));
    m.x=436; assert(!hwm_plane_tile_evidence_update(&e,.6,m,o,p,1,true));
    assert(hwm_plane_tile_evidence_update(&e,.71,m,o,p,1,true));
    m.x=450; assert(!hwm_plane_tile_evidence_update(&e,.8,m,o,p,1,true));
}
int main(void)
{
    test_evidence();
    HWMPlaneRect v={100,50,1200,900},m={0,100,300,250},p={400,100,300,250};
    HWMPlaneTilePlan plan,sentinel={0};
    /* A small pair at 100% still means two resized halves, never native-size
     * docking. Initial dimensions and approach from above do not change that. */
    for(int side=0;side<2;side++) {
        assert(hwm_plane_tile_plan(m,p,v,1,side,12,true,true,&plan));
        assert(plan.split);
        HWMPlaneRect a=side?plan.peer:plan.moving,b=side?plan.moving:plan.peer;
        near(a.x,100);near(a.y,50);near(a.width,594);near(a.height,900);
        near(b.x,706);near(b.width,594);near(b.height,900);
    }
    for(int i=0;i<3;i++) {
        double scale=(double[]){.25,.5,1}[i];
        HWMPlaneRect world={0,0,1200/scale,900/scale};
        assert(hwm_plane_tile_plan(m,p,world,scale,0,12,true,true,&plan));
        near(plan.moving.width,594);near(plan.peer.width,594);
        near(plan.moving.height,900);near(plan.peer.height,900);
        near(plan.peer.x-plan.moving.x,606);
    }
    assert(!hwm_plane_tile_plan(m,p,v,1,2,12,true,true,&plan));
    assert(!hwm_plane_tile_plan(m,p,v,1,0,12,false,true,&plan));
    assert(!hwm_plane_tile_plan(m,p,v,1,0,12,true,false,&plan));
    assert(!hwm_plane_tile_plan(m,p,(HWMPlaneRect){0,0,400,300},1,0,12,true,true,&plan));
    assert(!hwm_plane_tile_plan(m,p,v,NAN,0,12,true,true,&sentinel));
    assert(!hwm_plane_tile_plan(m,p,v,1,0,-1,true,true,&sentinel));
    assert(!sentinel.split);
    HWMPlaneRect moved={250,100,300,250};
    assert(hwm_plane_tile_horizontal_side(moved,p,(HWMPlanePoint){0,0},-1)==0);
    assert(hwm_plane_tile_horizontal_side((HWMPlaneRect){400,-100,300,250},p,(HWMPlanePoint){800,0},-1)==1);
    assert(hwm_plane_tile_horizontal_side((HWMPlaneRect){410,100,300,250},p,(HWMPlanePoint){0,0},0)==0);
    puts("overlap drag intention and equal side-by-side half-screen plans passed");
}
