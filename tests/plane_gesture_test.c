#include <assert.h>
#include <stdio.h>
#include "../src/plane_gesture.h"
static void near(double a,double b) { assert(fabs(a-b)<1e-8); }
static void test_selection_swipes(void) {
    for(int direction=-1;direction<=1;direction+=2) {
        HWMPlaneSelectionGesture g={0};
        HWMPlaneContact c[4]={{1,.3,.4},{2,.4,.4},{3,.5,.4},{4,.6,.4}};
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,3,1));
        assert(!g.engaged);
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.01));
        for(int i=0;i<4;i++) c[i].y+=direction*.02;
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.02));
        HWMPlaneContact swap=c[0]; c[0]=c[3]; c[3]=swap;
        for(int i=0;i<4;i++) c[i].y+=direction*.03;
        assert(!hwm_plane_selection_gesture_sample(&g,2,c,4,1.03));
        assert(hwm_plane_selection_gesture_sample(&g,1,c,4,1.03)==direction);
        assert(g.fired && g.engaged);
        for(int i=0;i<4;i++) c[i].y-=direction*.2;
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.04));
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,3,1.05));
        assert(g.engaged); // Lifting fingers cannot turn this gesture into a pan.
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,0,1.06));
        assert(!g.engaged && !g.fired);
        assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.07));
        for(int i=0;i<4;i++) c[i].y+=direction*.06;
        assert(hwm_plane_selection_gesture_sample(&g,1,c,4,1.08)==direction);
    }
    HWMPlaneSelectionGesture g={0};
    HWMPlaneContact c[4]={{1,.3,.4},{2,.4,.4},{3,.5,.4},{4,.6,.4}};
    assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1));
    for(int i=0;i<4;i++) { c[i].x+=.1; c[i].y+=.01; }
    assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.01));
    c[0].id=9; c[0].y+=.5;
    assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,1.02));
    for(int i=0;i<4;i++) c[i].y+=.1;
    assert(!hwm_plane_selection_gesture_sample(&g,1,c,4,2)); // Stale baseline.
    assert(!hwm_plane_selection_gesture_sample(&g,1,c,5,2.01));
}
static void test_release_velocity(void) {
    HWMPlaneVelocity v={0};
    HWMPlanePoint r=hwm_plane_velocity_release(&v,1,0); near(r.x,0); near(r.y,0);
    for(int i=0;i<12;i++) hwm_plane_velocity_add(&v,1+i*.01,i*15.0,-i*5.0);
    r=hwm_plane_velocity_release(&v,1.11,22); near(r.x,1500); near(r.y,-500);
    r=hwm_plane_velocity_release(&v,1.15,22); near(r.x,1500*exp(-22*.04)); near(r.y,-500*exp(-22*.04)); // Uneven lift.
    r=hwm_plane_velocity_release(&v,1.3,22); near(r.x,0); near(r.y,0); // Paused before lifting.
    hwm_plane_velocity_add(&v,.5,0,0); // Time went backwards: a new history.
    r=hwm_plane_velocity_release(&v,.51,22); near(r.x,0);
    hwm_plane_velocity_add(&v,.505,40,0);
    r=hwm_plane_velocity_release(&v,.51,22); near(r.x,0); // Too short to measure.
    hwm_plane_velocity_add(&v,NAN,0,0);
    HWMPlaneVelocity slow={0};
    for(int i=0;i<4;i++) hwm_plane_velocity_add(&slow,i*.2,i*10.0,0);
    r=hwm_plane_velocity_release(&slow,.61,22); near(r.x,0); // Samples too far apart.
}
static void test_scroll_ownership(void) {
    HWMPlaneScrollOwnership s={0};
    assert(!hwm_plane_scroll_claim(&s,1,0,false));
    assert(!hwm_plane_scroll_claim(&s,2,0,true)); // Modifier pressed mid-app scroll.
    assert(!hwm_plane_scroll_claim(&s,4,0,true));
    assert(!hwm_plane_scroll_claim(&s,0,1,true)); // Native momentum stays native.
    assert(!hwm_plane_scroll_claim(&s,0,3,true));
    assert(hwm_plane_scroll_claim(&s,1,0,true));
    assert(hwm_plane_scroll_claim(&s,2,0,false)); // Modifier lifted first.
    assert(hwm_plane_scroll_claim(&s,4,0,false));
    assert(hwm_plane_scroll_claim(&s,0,1,false));
    assert(hwm_plane_scroll_claim(&s,0,3,false));
    assert(!hwm_plane_scroll_claim(&s,2,0,true)); // No begin, no takeover.
    assert(hwm_plane_scroll_claim(&s,1,0,true));
    assert(hwm_plane_scroll_claim(&s,8,0,false)); // Cancel ends ownership.
    assert(!hwm_plane_scroll_claim(&s,2,0,true));
    assert(hwm_plane_scroll_claim(&s,0,0,true)); // Unphased mouse wheel.
    assert(!hwm_plane_scroll_claim(&s,0,0,false));
    assert(hwm_plane_scroll_claim(&s,1,0,true));
    assert(!hwm_plane_scroll_claim(&s,1,0,false)); // Fresh native stream.
}
static void test_zoom_taper_measures_actual_pan_distance(void) {
    // Quick at actual size, gentler (below the fingers' own travel) far out.
    const double scales[]={.25,.5,.75,1};
    double expected[4];
    for(int j=0;j<4;j++) expected[j]=1.55*pow(scales[j],.4);
    assert(fabs(expected[0]-.890241)<1e-6 && fabs(expected[1]-1.17468)<1e-5 && fabs(expected[2]-1.381517)<1e-6);
    for(int j=0;j<4;j++) near(hwm_plane_pan_speed(scales[j]),expected[j]);
    double previous=0;
    for(int j=0;j<4;j++) {
        HWMPlaneGesture g={0};HWMPlaneCamera camera={0,0,scales[j]},out;
        HWMPlaneContact c[3]={{1,.2,.3},{2,.4,.3},{3,.6,.3}};
        assert(hwm_plane_gesture_sample(&g,1,c,3,1,1600,.625,1.3,camera,&out));
        for(int i=0;i<3;i++) {c[i].x+=.05;c[i].y+=.08;}
        assert(hwm_plane_gesture_sample(&g,1,c,3,1.02,1600,.625,1.3,camera,&out));
        double screen_x=-out.x*camera.scale,screen_y=out.y*camera.scale;
        near(screen_x,80*1.3*expected[j]);near(screen_y,screen_x);
        assert(screen_x>previous);previous=screen_x;
        // Ending at this zoom cannot add another movement sample.
        camera=out;assert(hwm_plane_gesture_sample(&g,1,c,0,1.03,1600,.625,1.3,camera,&out));
        near(out.x,camera.x);near(out.y,camera.y);
    }
    assert(fabs(hwm_plane_pan_speed(.9999)-hwm_plane_pan_speed(1))<.0001);
    // Workspace scrolls share the curve; nothing past actual size or below
    // the zoom floor runs away.
    near(hwm_plane_scroll_pan_speed(1)/hwm_plane_scroll_pan_speed(.5),hwm_plane_pan_speed(1)/hwm_plane_pan_speed(.5));
    near(hwm_plane_pan_speed(2),hwm_plane_pan_speed(1));
    assert(hwm_plane_pan_speed(0)>0 && isfinite(hwm_plane_pan_speed(NAN)));
}
int main(void) {
    test_scroll_ownership();
    test_zoom_taper_measures_actual_pan_distance();
    HWMPlaneGesture resting={0}; HWMPlaneCamera still={0,0,1},result;
    HWMPlaneContact restingContacts[3]={{1,.2,.3},{2,.4,.3},{3,.6,.3}};
    assert(hwm_plane_gesture_sample(&resting,1,restingContacts,3,1,1600,.625,1,still,&result));
    for(int i=0;i<3;i++) restingContacts[i].x+=.001;
    assert(hwm_plane_gesture_sample(&resting,1,restingContacts,3,1.01,1600,.625,1,still,&result));
    near(result.x,0); near(result.y,0); // Resting drift has no visible effect.
    for(int i=0;i<3;i++) restingContacts[i].x+=.005;
    assert(hwm_plane_gesture_sample(&resting,1,restingContacts,3,1.02,1600,.625,1,still,&result));
    near(result.x,-.006*1600*hwm_plane_pan_speed(1)); // Initial deliberate travel is preserved.
    HWMPlaneSelectionGesture oneFinger={0};
    HWMPlaneContact four[4]={{1,.2,.3},{2,.4,.3},{3,.6,.3},{4,.8,.3}};
    assert(!hwm_plane_selection_gesture_sample(&oneFinger,1,four,4,1));
    four[0].y+=.3;
    assert(!hwm_plane_selection_gesture_sample(&oneFinger,1,four,4,1.01));
    assert(!oneFinger.fired); // One moving finger is not a four-finger swipe.
    test_release_velocity();
    test_selection_swipes();
    for(int angle=0;angle<360;angle+=15) for(int zoom=0;zoom<2;zoom++) {
        HWMPlaneGesture g={0}; HWMPlaneCamera camera={-900,250,zoom?.5:2},out;
        HWMPlaneContact contacts[3]={{1,.3,.4},{2,.5,.5},{3,.7,.6}};
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        double dx=cos(angle*3.141592653589793/180)*.03,dy=sin(angle*3.141592653589793/180)*.03;
        for(int i=0;i<3;i++) { contacts[i].x+=dx; contacts[i].y+=dy/.625; }
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.01,1600,.625,1,camera,&out));
        near(-(out.x-camera.x)*camera.scale,dx*1600*hwm_plane_pan_speed(camera.scale));
        near(-(out.y-camera.y)*camera.scale,-dy*1600*hwm_plane_pan_speed(camera.scale));
        camera=out;
        // Contact order may change without affecting the camera.
        HWMPlaneContact swap=contacts[0]; contacts[0]=contacts[2]; contacts[2]=swap;
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.02,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        assert(!hwm_plane_gesture_sample(&g,2,contacts,3,1.03,1600,.625,1,camera,&out));
        // A finger lifting or being replaced must not produce a centroid jump.
        // A finger briefly lifting holds the gesture without moving the camera.
        assert(!hwm_plane_gesture_sample(&g,1,contacts,2,1.025,1600,.625,1,camera,&out));
        assert(g.active); near(out.x,camera.x); near(out.y,camera.y);
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.028,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        // A full lift ends it without a centroid jump.
        assert(hwm_plane_gesture_sample(&g,1,contacts,0,1.03,1600,.625,1,camera,&out));
        assert(!g.active); near(out.x,camera.x); near(out.y,camera.y);
        contacts[0].id=9; contacts[0].x=.9;
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.04,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        contacts[1].id=10; contacts[1].x=.1;
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.05,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        contacts[1].x=.8;
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,2,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
    }
    HWMPlaneGesture fast={0}; HWMPlaneCamera camera={0,0,1},out;
    HWMPlaneContact fingers[3]={{1,.1,.2},{2,.2,.3},{3,.3,.4}};
    assert(hwm_plane_gesture_sample(&fast,1,fingers,3,1,1600,.625,1,camera,&out));
    for(int i=0;i<3;i++) fingers[i].x+=.2;
    assert(hwm_plane_gesture_sample(&fast,1,fingers,3,1.01,1600,.625,1,camera,&out));
    near(out.x,-.2*1600*hwm_plane_pan_speed(1));
    puts("plane gesture tests passed: 24 directions, both zooms, fast motion, contact transitions");
}
