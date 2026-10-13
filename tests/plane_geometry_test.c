#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/plane_geometry.h"

static void near(double a,double b) { assert(fabs(a-b)<1e-9); }

int main(void)
{
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
    puts("plane geometry tests passed");
    return 0;
}
