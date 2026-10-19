#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "../src/plane_pinch.h"

/* Two fingers (ids 1 and 2) at the given sensor positions; aspect .625. */
static int feed(HWMPlanePinch *p,double t,double ax,double ay,double bx,double by,double *delta)
{
    HWMPlaneContact c[2]={{1,ax,ay},{2,bx,by}};
    return hwm_plane_pinch_sample(p,1,c,2,t,.625,delta);
}
static int lift(HWMPlanePinch *p,double t,int count)
{
    HWMPlaneContact c[2]={{1,.5,.5},{2,.5,.5}};
    double d; return hwm_plane_pinch_sample(p,1,c,count,t,.625,&d);
}

/* Fingers moving straight against each other: the classic pinch. */
static void test_opposing(void)
{
    HWMPlanePinch p={0}; double d; double total=0;
    assert(feed(&p,1,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.397,.5,.603,.5,&d)==HWM_PINCH_NONE); // 0.6% wider: still undecided
    assert(feed(&p,1.02,.393,.5,.607,.5,&d)==HWM_PINCH_BEGIN);  // 1.4% wider, no shared travel
    assert(d>0 && fabs(d-log(.214/.2))<1e-9); total+=d;
    assert(feed(&p,1.03,.38,.5,.62,.5,&d)==HWM_PINCH_CHANGE); assert(d>0); total+=d;
    assert(fabs(total-log(.24/.2))<1e-9);
    assert(feed(&p,1.04,.38,.5,.62,.5,&d)==HWM_PINCH_HOLD && d==0);
    assert(feed(&p,1.05,.39,.5,.61,.5,&d)==HWM_PINCH_CHANGE && d<0);
    assert(lift(&p,1.06,1)==HWM_PINCH_HOLD);  // one finger left first
    assert(lift(&p,1.07,0)==HWM_PINCH_END);
    assert(!p.tracking && !p.engaged);
}

/* The thumb rests while the index finger moves away: the fingers' shared
 * travel is half the spread, which the system's recogniser read as a scroll. */
static void test_thumb_anchored(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    int result=HWM_PINCH_NONE; double seen=0;
    for(int i=1;i<=10 && result!=HWM_PINCH_BEGIN;i++) {
        result=feed(&p,1+i*.01,.40,.5,.50+i*.005,.5,&d);
        assert(result==HWM_PINCH_NONE || result==HWM_PINCH_BEGIN);
        seen=.1+i*.005;
    }
    assert(result==HWM_PINCH_BEGIN);
    assert(fabs(d-log(seen/.1))<1e-9);
    assert(feed(&p,1.2,.40,.5,.20,.5,&d)==HWM_PINCH_CHANGE && d>0);
}

/* Both fingers move the same way, one faster: a natural pinch with a drift. */
static void test_same_direction(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.4,.50,.6,&d)==HWM_PINCH_NONE);
    int result=HWM_PINCH_NONE;
    for(int i=1;i<=12 && result!=HWM_PINCH_BEGIN;i++) {
        // Both move right and up; the second finger twice as fast.
        result=feed(&p,1+i*.01,.40+i*.004,.4+i*.004,.50+i*.008,.6+i*.008,&d);
        assert(result==HWM_PINCH_NONE || result==HWM_PINCH_BEGIN);
    }
    assert(result==HWM_PINCH_BEGIN && d>0);
    assert(!p.scroll);
}

/* Two fingers moving together, with a little wobble: a scroll, never a zoom,
 * even once the wobble has summed past the start threshold. */
static void test_scroll_locked(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=40;i++) {
        double wobble=.001*i; // separation drifts 4% of the travel
        assert(feed(&p,1+i*.01,.40,.5+i*.01,.50+wobble,.5+i*.01,&d)==HWM_PINCH_NONE);
    }
    assert(p.scroll && !p.engaged);
    // Even a clear spread now does not zoom: the pair is a scroll until it lifts.
    assert(feed(&p,1.41,.30,.9,.70,.9,&d)==HWM_PINCH_NONE);
    assert(lift(&p,1.42,0)==HWM_PINCH_NONE);
    // A fresh pair may zoom again.
    assert(feed(&p,2,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,2.01,.35,.5,.55,.5,&d)==HWM_PINCH_BEGIN && d>0);
}

/* A third finger ends a zoom; a replaced finger measures afresh; a stale
 * pair starts over; the wrong device is ignored. */
static void test_interruptions(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.35,.5,.65,.5,&d)==HWM_PINCH_BEGIN);
    HWMPlaneContact three[3]={{1,.35,.5},{2,.65,.5},{3,.5,.7}};
    assert(hwm_plane_pinch_sample(&p,1,three,3,1.02,.625,&d)==HWM_PINCH_END);
    assert(!p.tracking);

    assert(feed(&p,2,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,2.01,.35,.5,.65,.5,&d)==HWM_PINCH_BEGIN);
    HWMPlaneContact replaced[2]={{1,.35,.5},{7,.65,.5}};
    assert(hwm_plane_pinch_sample(&p,1,replaced,2,2.02,.625,&d)==HWM_PINCH_END);
    assert(p.tracking && !p.engaged && p.contacts[1].id==7);

    HWMPlanePinch stale={0};
    assert(feed(&stale,3,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&stale,3.5,.30,.5,.70,.5,&d)==HWM_PINCH_NONE); // half a second later: a new baseline
    assert(fabs(stale.origin_separation-.4)<1e-9);

    HWMPlanePinch other={0};
    HWMPlaneContact c[2]={{1,.4,.5},{2,.6,.5}};
    assert(hwm_plane_pinch_sample(&other,1,c,2,4,.625,&d)==HWM_PINCH_NONE);
    c[0].x=.3; c[1].x=.7;
    assert(hwm_plane_pinch_sample(&other,2,c,2,4.01,.625,&d)==HWM_PINCH_NONE);
    assert(!other.tracking);
}

/* Separation is measured in sensor widths, so a vertical pinch on a wide
 * sensor engages by the same physical distance as a horizontal one. */
static void test_aspect(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.5,.40,.5,.60,&d)==HWM_PINCH_NONE);
    // .2 of the height is .125 widths; a .03-of-height change is .019 widths.
    assert(feed(&p,1.01,.5,.385,.5,.615,&d)==HWM_PINCH_BEGIN);
    assert(fabs(d-log(.23/.2))<1e-9);
}

int main(void)
{
    test_opposing();
    test_thumb_anchored();
    test_same_direction();
    test_scroll_locked();
    test_interruptions();
    test_aspect();
    puts("plane_pinch_test: ok");
    return 0;
}
