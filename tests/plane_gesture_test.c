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
int main(void) {
    test_selection_swipes();
    for(int angle=0;angle<360;angle+=15) for(int zoom=0;zoom<2;zoom++) {
        HWMPlaneGesture g={0}; HWMPlaneCamera camera={-900,250,zoom?.5:2},out;
        HWMPlaneContact contacts[3]={{1,.3,.4},{2,.5,.5},{3,.7,.6}};
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        double dx=cos(angle*3.141592653589793/180)*.03,dy=sin(angle*3.141592653589793/180)*.03;
        for(int i=0;i<3;i++) { contacts[i].x+=dx; contacts[i].y+=dy/.625; }
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.01,1600,.625,1,camera,&out));
        near(-(out.x-camera.x)*camera.scale,dx*1600);
        near(-(out.y-camera.y)*camera.scale,-dy*1600);
        camera=out;
        // Contact order may change without affecting the camera.
        HWMPlaneContact swap=contacts[0]; contacts[0]=contacts[2]; contacts[2]=swap;
        assert(hwm_plane_gesture_sample(&g,1,contacts,3,1.02,1600,.625,1,camera,&out));
        near(out.x,camera.x); near(out.y,camera.y);
        assert(!hwm_plane_gesture_sample(&g,2,contacts,3,1.03,1600,.625,1,camera,&out));
        // A finger lifting or being replaced must not produce a centroid jump.
        assert(hwm_plane_gesture_sample(&g,1,contacts,2,1.03,1600,.625,1,camera,&out));
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
    near(out.x,-320);
    puts("plane gesture tests passed: 24 directions, both zooms, fast motion, contact transitions");
}
