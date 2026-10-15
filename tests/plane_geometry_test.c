#include <assert.h>
#include <float.h>
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
    HWMPlaneEdgePan invalid_scale={0};
    (void)hwm_plane_edge_pan(&invalid_scale,bounds,p,10,1);
    v=hwm_plane_edge_pan(&invalid_scale,bounds,p,11,NAN);
    near(v.x,0); near(v.y,0);
}

static void test_multi_neighbor_snap(void)
{
    HWMPlaneRect neighbor={100,100,100,100};
    HWMPlanePoint snap;
    HWMPlaneRect one[]={neighbor};

    /* Every edge can be selected, while a close perpendicular edge aligns. */
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){215,110,40,50},one,1,12,24,&snap));
    near(snap.x,212); near(snap.y,100);
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){45,110,40,50},one,1,12,24,&snap));
    near(snap.x,48); near(snap.y,100);
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){110,35,40,50},one,1,12,24,&snap));
    near(snap.x,100); near(snap.y,38);
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){110,215,40,50},one,1,12,24,&snap));
    near(snap.x,100); near(snap.y,212);

    /* A 24-point magnet becomes 12 world units at 2x zoom. */
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){223,100,40,50},one,1,12,24.0/2.0,&snap));
    near(snap.x,212);
    assert(!hwm_plane_snap_neighbors_target((HWMPlaneRect){225,100,40,50},one,1,12,24.0/2.0,&snap));

    /* Closest valid target wins, and a reordered window array gives the same tie result. */
    HWMPlaneRect candidates[]={ {100,100,100,100}, {400,100,100,100} };
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){215,100,40,50},candidates,2,12,24,&snap));
    near(snap.x,212); near(snap.y,100);
    HWMPlaneRect symmetric[]={ {88,100,100,100}, {276,100,100,100} };
    HWMPlaneRect reversed[]={ symmetric[1],symmetric[0] };
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){212,100,40,50},symmetric,2,12,24,&snap));
    near(snap.x,200); near(snap.y,100);
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){212,100,40,50},reversed,2,12,24,&snap));
    near(snap.x,200); near(snap.y,100);

    /* The nearby anchor would snap, but its landing rectangle hits a third window. */
    HWMPlaneRect blocked[]={ {100,100,100,100}, {212,100,40,50} };
    assert(!hwm_plane_snap_neighbors_target((HWMPlaneRect){215,100,40,50},blocked,2,12,24,&snap));

    HWMPlaneRect invalid[]={ {NAN,100,100,100}, {100,100,-1,100}, neighbor };
    assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){215,100,40,50},invalid,3,12,24,&snap));
    near(snap.x,212);
    snap=(HWMPlanePoint){7,9};
    assert(!hwm_plane_snap_neighbors_target((HWMPlaneRect){NAN,100,40,50},one,1,12,24,&snap));
    near(snap.x,7); near(snap.y,9);
    assert(!hwm_plane_snap_neighbors_target((HWMPlaneRect){1000,1000,40,50},one,1,12,24,&snap));
}

static void test_snap_can_escape_existing_overlap_and_keeps_edge(void)
{
    HWMPlaneRect stacked[]={{100,100,100,100},{220,90,300,200}};
    HWMPlaneRect moving={215,100,40,50}; HWMPlanePoint point;
    assert(hwm_plane_snap_neighbors_target(moving,stacked,2,12,12,&point));
    near(point.x,212); near(point.y,100);
    assert(hwm_plane_overlap_area((HWMPlaneRect){point.x,point.y,40,50},stacked[1])<hwm_plane_overlap_area(moving,stacked[1]));
    /* An overlapping target stack must work from either side of its edge,
     * including a point that has not yet overshot the ideal docking gap. */
    HWMPlaneRect target_stack[]={{300,100,100,100},{195,90,110,120}};
    for(int offset=-6;offset<=6;offset+=12) {
        assert(hwm_plane_snap_neighbors_target((HWMPlaneRect){188+offset,100,100,100},target_stack,2,12,12,&point));
        near(point.x,188); near(point.y,100);
    }

    HWMPlaneRect peers[]={{88,100,100,100},{276,100,100,100}};
    HWMPlaneSnapTarget preferred={{224,100},1,0,0,0},target;
    assert(hwm_plane_snap_choose((HWMPlaneRect){212,100,40,50},peers,2,12,12,&preferred,&target));
    near(target.point.x,224); assert(target.neighbor==1);
    /* The held edge loses its preference outside the same small radius. */
    assert(hwm_plane_snap_choose((HWMPlaneRect){211,100,40,50},peers,2,12,12,&preferred,&target));
    near(target.point.x,200); assert(target.neighbor==0);
}

static void test_snap_has_radial_bound(void)
{
    const double scales[]={.1,.25,.5,.7,1,2,4};
    HWMPlaneRect neighbor={100,100,100,100};
    for(size_t z=0;z<sizeof(scales)/sizeof(scales[0]);z++) {
        double scale=scales[z],range=12/scale;
        for(int ix=-60;ix<=60;ix++) for(int iy=-60;iy<=60;iy++) {
            HWMPlaneRect moving={212+ix*.25/scale,100+iy*.25/scale,40,50};
            HWMPlanePoint target;
            if(hwm_plane_snap_neighbors_target(moving,&neighbor,1,12,range,&target)) {
                assert(hypot(target.x-moving.x,target.y-moving.y)<=range);
                assert(!hwm_plane_rects_overlap((HWMPlaneRect){target.x,target.y,40,50},neighbor));
            } else { near(target.x,moving.x); near(target.y,moving.y); }
        }
        HWMPlaneRect moving={212+12/scale,100,40,50};
        HWMPlanePoint target;
        assert(hwm_plane_snap_neighbors_target(moving,&neighbor,1,12,range,&target));
        near(target.x,212);
        moving.x+=.001/scale;
        assert(!hwm_plane_snap_neighbors_target(moving,&neighbor,1,12,range,&target));
    }
}

static void test_simultaneous_multi_neighbor_snap(void)
{
    HWMPlaneRect moving={206,206,100,100};
    HWMPlaneSnapTarget target;
    /* A left and an upper neighbor meet at a true two-axis corner. */
    HWMPlaneRect corner[]={ {0,200,188,100}, {200,0,100,188} };
    assert(hwm_plane_snap_choose(moving,corner,2,12,12,NULL,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==2);

    /* Preserve size while fitting exactly between two horizontal peers and a
     * vertical one. All three contact equations share one landing point. */
    HWMPlaneRect triple[]={ {0,200,188,100}, {312,200,100,100}, {200,312,100,100} };
    assert(hwm_plane_snap_choose(moving,triple,3,12,12,NULL,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==3);
    HWMPlaneRect four[]={ {0,200,188,100}, {312,200,100,100}, {200,0,100,188}, {200,312,100,100} };
    HWMPlaneRect reversed[]={ four[3],four[2],four[1],four[0] };
    assert(hwm_plane_snap_choose(moving,four,4,12,12,NULL,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==4);
    assert(hwm_plane_snap_choose(moving,reversed,4,12,12,NULL,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==4);
    HWMPlaneSnapTarget stale={{0,0},99,0,0,0};
    assert(hwm_plane_snap_choose(moving,four,4,12,12,&stale,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==4);

    /* More contacts win over a valid preferred single contact. */
    HWMPlaneRect preference[]={ {0,200,188,100}, {312,200,100,100}, {200,0,100,188}, {318,200,100,100} };
    HWMPlaneSnapTarget preferred={{206,200},3,0,0,0};
    assert(hwm_plane_snap_choose(moving,preference,4,12,12,&preferred,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==3);

    /* A non-contact overlap cannot be introduced merely to complete a fit. */
    HWMPlaneRect blocked[]={ {0,200,188,100}, {312,200,100,100}, {200,312,100,100}, {200,200,100,100} };
    assert(!hwm_plane_snap_choose(moving,blocked,4,12,12,NULL,&target));

    /* Fractional coordinates still share the same radial world bound. */
    HWMPlaneRect fractional[]={ {0.25,200.25,187.5,100}, {200.25,0.25,100,187.5} };
    HWMPlaneRect fractional_moving={204.25,204.25,100,100};
    assert(hwm_plane_snap_choose(fractional_moving,fractional,2,12.5,8,NULL,&target));
    near(target.point.x,200.25); near(target.point.y,200.25);
    assert(hypot(target.point.x-fractional_moving.x,target.point.y-fractional_moving.y)<=8);

    /* Keep the legacy near-span single magnet, but do not let that ten-point
     * final gap masquerade as a second simultaneous contact. */
    HWMPlaneRect soft_and_real[]={ {112,110,100,100}, {0,112,100,100} };
    HWMPlaneRect soft_moving={0,0,100,100};
    assert(hwm_plane_snap_choose(soft_moving,soft_and_real,2,12,12,NULL,&target));
    near(target.point.x,0); near(target.point.y,0); assert(target.contact_count==1);
    HWMPlaneRect soft_only[]={ {112,110,100,100} };
    assert(hwm_plane_snap_choose(soft_moving,soft_only,1,12,12,NULL,&target));
    near(target.point.x,0); near(target.point.y,0); assert(target.contact_count==0);

    /* Floating point tolerance must retain exact large-coordinate fits while
     * refusing a five-point mismatch that used to fall inside a 10-point
     * magnitude-scaled equality window. */
    HWMPlaneRect large_moving={-1000000000,0,100,100};
    HWMPlaneRect large_fit[]={ {-1000000112,0,100,100}, {-999999888,0,100,100} };
    assert(hwm_plane_snap_choose(large_moving,large_fit,2,12,12,NULL,&target));
    near(target.point.x,-1000000000); assert(target.contact_count==2);
    HWMPlaneRect large_mismatch[]={ {-999999888,0,100,100}, {-999999883,0,100,100} };
    assert(hwm_plane_snap_choose(large_moving,large_mismatch,2,12,12,NULL,&target));
    near(target.point.x,-1000000000); assert(target.contact_count==1);

    /* Stacked copies of the same X/Y constraints are equivalent to one
     * landing point, while retaining every genuine contact in the result. */
    HWMPlaneRect dense[80];
    for(size_t i=0;i<40;i++) dense[i]=(HWMPlaneRect){0,200,188,100};
    for(size_t i=40;i<80;i++) dense[i]=(HWMPlaneRect){200,0,100,188};
    assert(hwm_plane_snap_choose(moving,dense,80,12,12,NULL,&target));
    near(target.point.x,200); near(target.point.y,200); assert(target.contact_count==80);
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
    HWMPlaneCamera invalid_from={0,0,0};
    HWMPlaneCamera fallback=hwm_plane_camera_mix(invalid_from,to,1200,900,.5);
    near(fallback.x,to.x); near(fallback.y,to.y); near(fallback.scale,to.scale);
    fallback=hwm_plane_camera_mix(from,to,INFINITY,900,.5);
    near(fallback.x,from.x); near(fallback.y,from.y); near(fallback.scale,from.scale);
    fallback=hwm_plane_camera_mix(from,to,1200,900,NAN);
    near(fallback.x,from.x); near(fallback.y,from.y); near(fallback.scale,from.scale);
    test_edge_pan_hold();
    test_multi_neighbor_snap();
    test_snap_can_escape_existing_overlap_and_keeps_edge();
    test_snap_has_radial_bound();
    test_simultaneous_multi_neighbor_snap();
    HWMPlaneCamera camera={0,0,1};
    camera=hwm_plane_camera_pan(camera,-900,640);
    near(camera.x,-900); near(camera.y,640); /* plane has no walls */
    camera=(HWMPlaneCamera){DBL_MAX,0,1};
    camera=hwm_plane_camera_pan(camera,DBL_MAX,5);
    near(camera.x,DBL_MAX); near(camera.y,5);
    HWMPlaneRect viewport={0,0,1000,700}, world={-600,-350,2800,1400};
    camera=hwm_plane_camera_fit(world,viewport,40);
    assert(camera.scale>0 && camera.scale<1);
    HWMPlaneRect shown=hwm_plane_project(world,camera,viewport);
    assert(shown.x>=39.999 && shown.y>=39.999);
    assert(shown.x+shown.width<=960.001 && shown.y+shown.height<=660.001);
    HWMPlaneCamera revealed={0,0,1}, next;
    assert(hwm_plane_reveal(revealed,(HWMPlaneRect){1300,-400,400,300},viewport,&next));
    near(next.x,700); near(next.y,-400);
    next=(HWMPlaneCamera){7,9,1};
    assert(!hwm_plane_reveal(revealed,(HWMPlaneRect){DBL_MAX,0,DBL_MAX,1},viewport,&next));
    near(next.x,revealed.x); near(next.y,revealed.y); near(next.scale,revealed.scale);
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
    snap=hwm_plane_snap_neighbor((HWMPlaneRect){NAN,7,300,250},neighbor,12,24);
    assert(isnan(snap.x)); near(snap.y,7);
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
