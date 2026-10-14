#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/plane_geometry.h"

static void near(double a,double b) { assert(fabs(a-b)<1e-9); }

static void test_edge_pan_hold(void)
{
    HWMPlaneEdgePan state={0}; HWMPlaneRect bounds={12,51,1686,1049};
    HWMPlanePoint p={500,51},v;
    v=hwm_plane_edge_pan(&state,bounds,p,1000,.5); assert(v.x==0 && v.y==0);
    v=hwm_plane_edge_pan(&state,bounds,p,1000.2,.5); assert(v.y==0);
    v=hwm_plane_edge_pan(&state,bounds,p,1000.4,.5); assert(v.y<0 && v.y>=-1200);
    v=hwm_plane_edge_pan(&state,bounds,(HWMPlanePoint){500,1100},1000.41,.5); assert(v.y==0);
    v=hwm_plane_edge_pan(&state,bounds,(HWMPlanePoint){500,400},1001,.5); assert(v.x==0 && v.y==0);
    v=hwm_plane_edge_pan(&state,bounds,p,2000,.5); assert(v.y==0);
}

int main(void)
{
    HWMPlaneCamera from={-600,300,.2},to={200,-90,1};
    HWMPlaneCamera middle=hwm_plane_camera_mix(from,to,1200,900,.5);
    near(middle.scale,sqrt(.2));
    near(middle.x+1200/(2*middle.scale),((from.x+3000)+(to.x+600))*.5);
    near(middle.y+900/(2*middle.scale),((from.y+2250)+(to.y+450))*.5);
    HWMPlaneCamera start=hwm_plane_camera_mix(from,to,1200,900,0),end=hwm_plane_camera_mix(from,to,1200,900,1);
    near(start.x,from.x); near(start.scale,from.scale); near(end.y,to.y); near(end.scale,1);
    test_edge_pan_hold();
    HWMPlaneCamera camera={0,0,1};
    camera=hwm_plane_camera_pan(camera,-900,640);
    near(camera.x,-900); near(camera.y,640); /* plane has no walls */
    HWMPlaneRect viewport={0,0,1000,700}, world={-600,-350,2800,1400};
    camera=hwm_plane_camera_fit(world,viewport,40);
    assert(camera.scale>0 && camera.scale<1);
    HWMPlaneRect shown=hwm_plane_project(world,camera,viewport);
    assert(shown.x>=39.999 && shown.y>=39.999);
    assert(shown.x+shown.width<=960.001 && shown.y+shown.height<=660.001);
    HWMPlaneCamera revealed={0,0,1}, next;
    assert(hwm_plane_reveal(revealed,(HWMPlaneRect){1300,-400,400,300},viewport,&next));
    near(next.x,700); near(next.y,-400);
    /* Native pointer movement is in screen points.  At both zoom directions
     * it must write the corresponding world delta, including edge pan. */
    HWMPlanePoint dragged=hwm_plane_drag_world((HWMPlanePoint){-80,120},
                                               (HWMPlanePoint){340,180},(HWMPlanePoint){100,60},.5,25,-40);
    near(dragged.x,425); near(dragged.y,320);
    dragged=hwm_plane_drag_world((HWMPlanePoint){-80,120},
                                 (HWMPlanePoint){340,180},(HWMPlanePoint){100,60},2,25,-40);
    near(dragged.x,65); near(dragged.y,140);
    near(hwm_plane_project_physical(1e100,0,12,1),HWM_PLANE_PHYSICAL_LIMIT);
    near(hwm_plane_project_physical(-1e100,0,12,1),-HWM_PLANE_PHYSICAL_LIMIT);
    near(hwm_plane_project_physical(1e100,1e100,12,1),12);
    near(hwm_plane_physical_size(INFINITY),1);
    HWMPlaneRect neighbor={500,200,400,300};
    HWMPlanePoint snap=hwm_plane_snap_neighbor((HWMPlaneRect){925,210,300,250},neighbor,12,24);
    near(snap.x,912); near(snap.y,200);
    snap=hwm_plane_snap_neighbor((HWMPlaneRect){186,190,300,250},neighbor,12,24);
    near(snap.x,188); near(snap.y,200);
    snap=hwm_plane_snap_neighbor((HWMPlaneRect){508,527,300,250},neighbor,12,24);
    near(snap.x,500); near(snap.y,512);
    snap=hwm_plane_snap_neighbor((HWMPlaneRect){950,200,300,250},neighbor,12,24);
    near(snap.x,950); near(snap.y,200); // Outside the magnet releases freely.
    snap=hwm_plane_snap_neighbor((HWMPlaneRect){925,2000,300,250},neighbor,12,24);
    near(snap.x,925); near(snap.y,2000); // An unrelated distant row cannot attract.
    assert(hwm_plane_snap_neighbor_target((HWMPlaneRect){912,200,300,250},neighbor,12,24,&snap));
    near(snap.x,912); near(snap.y,200);
    assert(!hwm_plane_snap_neighbor_target((HWMPlaneRect){925,2000,300,250},neighbor,12,24,&snap));
    double magnet_scales[]={.1,.5,1,2,4};
    for(int i=0;i<5;i++) {
        double z=magnet_scales[i];
        HWMPlaneCamera start={100/z,0,z},end={50/z,0,z};
        HWMPlaneCamera nudged=hwm_plane_magnetic_camera(start,end,(HWMPlanePoint){0,0});
        near((end.x-nudged.x)*z,10);
        assert(hypot(end.x-nudged.x,end.y-nudged.y)*z<=12);
        start.x=20/z;
        nudged=hwm_plane_magnetic_camera(start,end,(HWMPlanePoint){0,0});
        near(nudged.x,end.x); // Escape motion is never opposed.
        nudged=hwm_plane_magnetic_camera(end,end,(HWMPlanePoint){0,0});
        near(nudged.x,end.x); // Touching and lifting cannot ratchet the camera.
    }
    puts("plane geometry tests passed");
    return 0;
}
