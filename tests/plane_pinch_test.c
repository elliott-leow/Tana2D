#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "../src/plane_pinch.h"

/* Two fingers (ids 1 and 2) at the given sensor positions; aspect .625.
 * Frames are 10 ms apart unless a test says otherwise: a frame index i is
 * at time 1+i*.01. */
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
/* Every frame up to `frames` reports NONE or, once, BEGIN; the frame index
 * of the BEGIN is returned, or -1. Finger a moves by (adx,ady) per frame and
 * b by (bdx,bdy), from the given start, with frame 0 at time t0. */
static int begins(HWMPlanePinch *p,double t0,double ax,double ay,double bx,double by,
                  double adx,double ady,double bdx,double bdy,int frames,double *delta)
{
    for(int i=0;i<=frames;i++) {
        int result=feed(p,t0+i*.01,ax+i*adx,ay+i*ady,bx+i*bdx,by+i*bdy,delta);
        assert(result==HWM_PINCH_NONE || result==HWM_PINCH_BEGIN);
        if(result==HWM_PINCH_BEGIN) return i;
    }
    return -1;
}
/* The fingers hold at the given positions for 100 ms from t: the zoom accrued
 * before the pair engaged is paid out over the first 60 ms and the rest of
 * the frames hold. Returns the total paid out, `first` being the BEGIN's. */
static double catch_up(HWMPlanePinch *p,double t,double ax,double ay,double bx,double by,double first)
{
    double total=first,d;
    for(int i=1;i<=10;i++) {
        int result=feed(p,t+i*.01,ax,ay,bx,by,&d);
        assert(result==HWM_PINCH_CHANGE || result==HWM_PINCH_HOLD);
        if(i>=8) assert(result==HWM_PINCH_HOLD && d==0);
        total+=d;
    }
    assert(p->backlog==0);
    return total;
}

/* Fingers moving straight against each other: the classic pinch. It reads
 * as a pinch at 1.4% of the sensor width, and zooms 30 ms later, catching
 * up on the whole change. */
static void test_opposing(void)
{
    HWMPlanePinch p={0}; double d; double total=0;
    assert(feed(&p,1,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.397,.5,.603,.5,&d)==HWM_PINCH_NONE); // 0.6% wider: not yet a pinch
    assert(feed(&p,1.02,.393,.5,.607,.5,&d)==HWM_PINCH_NONE); // 1.4% wider, no shared travel: a pinch, unconfirmed
    assert(p.pinch_since==1.02 && p.pinch_opposed);
    assert(feed(&p,1.03,.39,.5,.61,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.04,.388,.5,.612,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.055,.386,.5,.614,.5,&d)==HWM_PINCH_BEGIN);
    // The BEGIN pays out this frame's quarter of the 60 ms catch-up (15 ms since the last frame).
    assert(d>0 && fabs(d-log(.228/.2)*.25)<1e-9);
    total=catch_up(&p,1.055,.386,.5,.614,.5,d);
    assert(fabs(total-log(.228/.2))<1e-9);
    assert(feed(&p,1.165,.38,.5,.62,.5,&d)==HWM_PINCH_CHANGE); assert(d>0); total+=d;
    assert(fabs(total-log(.24/.2))<1e-9);
    assert(feed(&p,1.175,.38,.5,.62,.5,&d)==HWM_PINCH_HOLD && d==0);
    assert(feed(&p,1.185,.39,.5,.61,.5,&d)==HWM_PINCH_CHANGE && d<0);
    assert(lift(&p,1.195,1)==HWM_PINCH_HOLD);  // one finger left first
    assert(lift(&p,1.205,0)==HWM_PINCH_END);
    assert(!p.tracking && !p.engaged);
}

/* Closing the fingers is a pinch the same way. */
static void test_closing(void)
{
    HWMPlanePinch p={0}; double d;
    int at=begins(&p,1,.40,.5,.60,.5,.004,0,-.004,0,10,&d);
    assert(at>=0 && at<=6 && d<0);
    double total=catch_up(&p,1+at*.01,.40+at*.004,.5,.60-at*.004,.5,d);
    assert(fabs(total-log((.2-at*.008)/.2))<1e-9);
}

/* The thumb rests while the index finger moves away: the fingers' shared
 * travel is half the spread, which the system's recogniser read as a scroll.
 * A scroll's leading finger looks the same, so this takes about 3 mm and
 * 60 ms more; the zoom then catches up on the whole spread. */
static void test_thumb_anchored(void)
{
    HWMPlanePinch p={0}; double d;
    int at=begins(&p,1,.40,.5,.50,.5,0,0,.005,0,20,&d);
    assert(at>=4 && at<=10 && d>0);
    double total=catch_up(&p,1+at*.01,.40,.5,.50+at*.005,.5,d);
    assert(fabs(total-log((.1+at*.005)/.1))<1e-9);
    assert(feed(&p,1+(at+11)*.01,.40,.5,.20,.5,&d)==HWM_PINCH_CHANGE && d>0);
}

/* Both fingers move the same way, one twice as fast: the spread is under
 * the travel, so this is a scroll, however far it goes. */
static void test_same_direction(void)
{
    HWMPlanePinch p={0}; double d;
    // Both move right and up; the second finger twice as fast.
    assert(begins(&p,1,.40,.4,.50,.6,.004,.004,.008,.008,40,&d)<0);
    assert(p.scroll && !p.engaged);
}

/* The thumb drifts along after the index finger at a quarter of its speed:
 * the spread is still more than the travel, so a slower pinch also zooms. */
static void test_drifting_thumb(void)
{
    HWMPlanePinch p={0}; double d;
    int at=begins(&p,1,.40,.5,.50,.5,.0015,0,.006,0,30,&d);
    assert(at>=0 && at<=14 && d>0 && !p.scroll);
}

/* The system's recogniser has called an undecided pair a pinch: it zooms
 * on the next frame with any spread at all. A pair already decided a
 * scroll stays one. */
static void test_system_hint(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.40,.5,.503,.5,&d)==HWM_PINCH_NONE);
    p.system_pinch=1.015;
    assert(feed(&p,1.02,.40,.5,.506,.5,&d)==HWM_PINCH_BEGIN && d>0);
    assert(p.reading.system);
    assert(fabs(catch_up(&p,1.02,.40,.5,.506,.5,d)-log(.106/.1))<1e-9);
    HWMPlanePinch s={0};
    assert(feed(&s,2,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=5;i++) assert(feed(&s,2+i*.01,.40,.5+i*.01,.50,.5+i*.01,&d)==HWM_PINCH_NONE);
    assert(s.scroll);
    s.system_pinch=2.05;
    assert(feed(&s,2.06,.40,.55,.52,.55,&d)==HWM_PINCH_NONE && !s.engaged);
    // A stale report does nothing either.
    HWMPlanePinch t={0};
    assert(feed(&t,3,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    t.system_pinch=2.5;
    assert(feed(&t,3.01,.40,.5,.503,.5,&d)==HWM_PINCH_NONE && !t.engaged);
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
    assert(begins(&p,2,.40,.5,.50,.5,-.005,0,.005,0,10,&d)>=0 && d>0);
}

/* A scroll whose fingers part at nearly half its speed, as a loose hand's
 * do, is decided a scroll within about 3 mm and stays one. */
static void test_diverging_scroll(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=30;i++) assert(feed(&p,1+i*.01,.40,.5+i*.01,.50+i*.003,.5+i*.01,&d)==HWM_PINCH_NONE);
    assert(p.scroll && !p.engaged);
    // Decided early: within the first 4 frames (about 3 mm).
    HWMPlanePinch q={0};
    assert(feed(&q,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=4;i++) feed(&q,1+i*.01,.40,.5+i*.01,.50+i*.003,.5+i*.01,&d);
    assert(q.scroll);
}

/* A scroll along the line between the fingers (a horizontal scroll with
 * the fingers side by side) in which one finger sets off 3 mm ahead of the
 * other. Until the second finger moves this is a thumb-anchored pinch; once
 * it does the pair is a scroll, and must never zoom. */
static void test_leading_finger(void)
{
    double d;
    // A fast scroll: 1 mm a frame, the lead over three frames.
    HWMPlanePinch p={0};
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=3;i++) assert(feed(&p,1+i*.01,.40,.5,.50+i*.00625,.5,&d)==HWM_PINCH_NONE);
    assert(p.pinch_since>=0 && !p.pinch_opposed); // reads as a pinch so far, unconfirmed
    for(int i=4;i<=30;i++) assert(feed(&p,1+i*.01,.40+(i-3)*.00625,.5,.50+i*.00625,.5,&d)==HWM_PINCH_NONE);
    assert(p.scroll && !p.engaged);
    // A slow one: 0.5 mm a frame, the lead over six frames (60 ms).
    HWMPlanePinch q={0};
    assert(feed(&q,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=6;i++) assert(feed(&q,1+i*.01,.40,.5,.50+i*.003125,.5,&d)==HWM_PINCH_NONE);
    for(int i=7;i<=60;i++) assert(feed(&q,1+i*.01,.40+(i-6)*.003125,.5,.50+i*.003125,.5,&d)==HWM_PINCH_NONE);
    assert(q.scroll && !q.engaged);
    // The same lead in a vertical scroll with the fingers on a diagonal.
    HWMPlanePinch r={0};
    assert(feed(&r,1,.40,.45,.50,.55,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=3;i++) assert(feed(&r,1+i*.01,.40,.45,.50,.55+i*.01,&d)==HWM_PINCH_NONE);
    for(int i=4;i<=30;i++) assert(feed(&r,1+i*.01,.40,.45+(i-3)*.01,.50,.55+i*.01,&d)==HWM_PINCH_NONE);
    assert(r.scroll && !r.engaged);
}

/* The second finger's contact grows as it lands, shifting it 2.5 mm along
 * the line between the fingers over three frames, and the scroll starts at
 * once: not a zoom. */
static void test_landing_shift(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=3;i++) assert(feed(&p,1+i*.01,.40,.5,.50+i*.0052,.5,&d)==HWM_PINCH_NONE);
    for(int i=4;i<=30;i++) assert(feed(&p,1+i*.01,.40,.5+(i-3)*.01,.5156,.5+(i-3)*.01,&d)==HWM_PINCH_NONE);
    assert(p.scroll && !p.engaged);
}

/* Fingers settle as they land, shifting the pair 2 mm with no spread, and
 * the pinch starts straight away: the settle is not read as a scroll. */
static void test_landing_settle(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.404,.5,.504,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.02,.408,.5,.508,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.03,.412,.5,.512,.5,&d)==HWM_PINCH_NONE);
    assert(!p.scroll);
    int at=begins(&p,1.04,.412,.5,.517,.5,0,0,.005,0,20,&d);
    assert(at>=0 && at<=14 && d>0);
}

/* A pair that moves a little, rests, and moves again is measured from the
 * rest: the stale motion neither decides a scroll nor counts as zoom. */
static void test_rest(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    // 2.5 mm of travel, then still for 150 ms, then 2.5 mm more.
    for(int i=1;i<=3;i++) assert(feed(&p,1+i*.01,.40,.5+i*.005,.50,.5+i*.005,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=15;i++) assert(feed(&p,1.03+i*.01,.40,.515,.50,.515,&d)==HWM_PINCH_NONE);
    assert(fabs(p.origin_y-.515)<1e-9);
    for(int i=1;i<=3;i++) assert(feed(&p,1.18+i*.01,.40,.515+i*.005,.50,.515+i*.005,&d)==HWM_PINCH_NONE);
    assert(!p.scroll);
    // After another rest the separation at rest is the zoom's baseline.
    for(int i=1;i<=15;i++) assert(feed(&p,1.21+i*.01,.40,.53,.50,.53,&d)==HWM_PINCH_NONE);
    int at=begins(&p,1.37,.40,.53,.53,.53,0,0,0,0,10,&d);
    assert(at>=1 && at<=8);
    assert(fabs(catch_up(&p,1.37+at*.01,.40,.53,.53,.53,d)-log(.13/.1))<1e-9);
    // A rest after a decision changes nothing: a scroll stays a scroll.
    HWMPlanePinch s={0};
    assert(feed(&s,1,.40,.5,.50,.5,&d)==HWM_PINCH_NONE);
    for(int i=1;i<=5;i++) assert(feed(&s,1+i*.01,.40,.5+i*.01,.50,.5+i*.01,&d)==HWM_PINCH_NONE);
    assert(s.scroll);
    for(int i=1;i<=15;i++) assert(feed(&s,1.05+i*.01,.40,.55,.50,.55,&d)==HWM_PINCH_NONE);
    assert(feed(&s,1.21,.30,.55,.60,.55,&d)==HWM_PINCH_NONE && s.scroll && !s.engaged);
}

/* A pinch that stops, 2 mm in, before its confirmation is up still zooms:
 * the fingers did part. */
static void test_short_pinch(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,1,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
    assert(feed(&p,1.01,.394,.5,.606,.5,&d)==HWM_PINCH_NONE);
    int at=begins(&p,1.02,.394,.5,.606,.5,0,0,0,0,10,&d);
    assert(at>=0 && at<=4);
    assert(fabs(catch_up(&p,1.02+at*.01,.394,.5,.606,.5,d)-log(.212/.2))<1e-9);
}

/* A third finger ends a zoom; a replaced finger measures afresh; a stale
 * pair starts over; the wrong device is ignored. */
static void test_interruptions(void)
{
    HWMPlanePinch p={0}; double d;
    assert(begins(&p,1,.40,.5,.60,.5,-.01,0,.01,0,10,&d)>=0);
    HWMPlaneContact three[3]={{1,.35,.5},{2,.65,.5},{3,.5,.7}};
    assert(p.backlog!=0);
    assert(hwm_plane_pinch_sample(&p,1,three,3,1.2,.625,&d)==HWM_PINCH_END && d==0);
    assert(!p.tracking && p.backlog==0);

    assert(begins(&p,2,.40,.5,.60,.5,-.01,0,.01,0,10,&d)>=0);
    HWMPlaneContact replaced[2]={{1,.35,.5},{7,.65,.5}};
    assert(hwm_plane_pinch_sample(&p,1,replaced,2,2.2,.625,&d)==HWM_PINCH_END);
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
    assert(feed(&p,1.01,.5,.385,.5,.615,&d)==HWM_PINCH_NONE);
    assert(p.pinch_since==1.01 && p.pinch_opposed);
    int at=begins(&p,1.02,.5,.385,.5,.615,0,0,0,0,10,&d);
    assert(at>=0 && at<=3);
    assert(fabs(catch_up(&p,1.02+at*.01,.5,.385,.5,.615,d)-log(.23/.2))<1e-9);
}

/* A screenshot selection, text selection, or native drag can separate the
 * fingers exactly like a real pinch. Input ownership must override geometry,
 * including after button-up, a partial lift, or a replacement contact. */
static void test_native_drag_owns_contacts(void)
{
    for(int engaged=0;engaged<2;engaged++) {
        HWMPlanePinch p={0}; double d;
        if(engaged) assert(begins(&p,1,.40,.5,.60,.5,-.01,0,.01,0,10,&d)>=0);
        else assert(feed(&p,1,.40,.5,.60,.5,&d)==HWM_PINCH_NONE);
        hwm_plane_pinch_cancel(&p);
        assert(p.blocked && !p.engaged && p.backlog==0);
        for(int i=1;i<=20;i++) {
            p.system_pinch=2+i*.01;
            assert(feed(&p,2+i*.01,.40-i*.004,.5,.60+i*.004,.5,&d)==HWM_PINCH_NONE && d==0);
        }
        assert(lift(&p,2.21,1)==HWM_PINCH_NONE && p.blocked);
        HWMPlaneContact replaced[2]={{1,.3,.5},{7,.7,.5}};
        assert(hwm_plane_pinch_sample(&p,1,replaced,2,3,.625,&d)==HWM_PINCH_NONE && p.blocked);
        assert(lift(&p,3.01,0)==HWM_PINCH_NONE && !p.blocked);
        assert(begins(&p,4,.40,.5,.60,.5,-.01,0,.01,0,10,&d)>=0);
    }
}

static void test_scroll_partial_lift(void)
{
    HWMPlanePinch p={0}; double d;
    assert(begins(&p,1,.4,.4,.6,.4,0,.01,0,.01,10,&d)<0 && p.scroll);
    assert(lift(&p,1.11,1)==HWM_PINCH_NONE && p.scroll);
    HWMPlaneContact c[2]={{1,.3,.5},{7,.7,.5}};
    assert(hwm_plane_pinch_sample(&p,1,c,2,1.12,.625,&d)==HWM_PINCH_NONE && p.scroll);
    p.system_pinch=1.13;
    assert(feed(&p,1.14,.25,.5,.75,.5,&d)==HWM_PINCH_NONE && d==0);
    assert(lift(&p,1.15,0)==HWM_PINCH_NONE && !p.scroll);
    assert(begins(&p,2,.4,.5,.6,.5,-.01,0,.01,0,10,&d)>=0);
}

static void test_rotation_with_separation_wobble(void)
{
    for(int direction=-1;direction<=1;direction+=2) {
        HWMPlanePinch p={0}; double d;
        assert(feed(&p,1,.4,.5,.6,.5,&d)==HWM_PINCH_NONE);
        for(int i=1;i<=30;i++) {
            double angle=direction*i*.035,radius=.1+i*.0007;
            HWMPlaneContact c[2]={{1,.5-radius*cos(angle),.5-radius*sin(angle)/.625},
                                  {2,.5+radius*cos(angle),.5+radius*sin(angle)/.625}};
            if(i%2) { HWMPlaneContact swap=c[0]; c[0]=c[1]; c[1]=swap; }
            assert(hwm_plane_pinch_sample(&p,1,c,2,1+i*.01,.625,&d)==HWM_PINCH_NONE && d==0);
        }
        assert(p.scroll && !p.engaged);
        assert(lift(&p,1.31,0)==HWM_PINCH_NONE);
        assert(begins(&p,2,.4,.5,.6,.5,-.01,0,.01,0,10,&d)>=0);
    }
}

static void test_hint_from_previous_pair(void)
{
    HWMPlanePinch p={0}; double d;
    assert(feed(&p,2,.4,.5,.6,.5,&d)==HWM_PINCH_NONE);
    p.system_pinch=1.99; // Recent, but predates this pair.
    assert(feed(&p,2.01,.4,.5,.603,.5,&d)==HWM_PINCH_NONE && !p.engaged);
}

int main(void)
{
    test_opposing();
    test_closing();
    test_thumb_anchored();
    test_same_direction();
    test_drifting_thumb();
    test_system_hint();
    test_scroll_locked();
    test_diverging_scroll();
    test_leading_finger();
    test_landing_shift();
    test_landing_settle();
    test_rest();
    test_short_pinch();
    test_interruptions();
    test_aspect();
    test_native_drag_owns_contacts();
    test_scroll_partial_lift();
    test_rotation_with_separation_wobble();
    test_hint_from_previous_pair();
    puts("plane_pinch_test: ok");
    return 0;
}
