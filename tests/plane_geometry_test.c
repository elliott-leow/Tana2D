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
    puts("plane geometry tests passed");
    return 0;
}
