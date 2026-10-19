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

static void test_snap_hold_and_seams(void)
{
    HWMPlaneRect right={300,100,100,100};
    HWMPlaneSnapTarget held={{188,100},0,0,0,1},target; bool kept=false;
    /* 16 points out: a fresh magnet would not engage, the held one does. */
    assert(!hwm_plane_snap_choose((HWMPlaneRect){204,100,100,100},&right,1,12,12,NULL,&target));
    assert(hwm_plane_snap_choose_held((HWMPlaneRect){204,100,100,100},&right,1,12,12,20,&held,true,false,&target,&kept));
    near(target.point.x,188); near(target.point.y,100); assert(kept);
    assert(!hwm_plane_snap_choose_held((HWMPlaneRect){209,100,100,100},&right,1,12,12,20,&held,true,false,&target,&kept));
    /* An unlocked axis never holds, and alignment alone is not a contact. */
    assert(!hwm_plane_snap_choose_held((HWMPlaneRect){204,100,100,100},&right,1,12,12,20,&held,false,true,&target,&kept));
    /* 9 points off on both axes (12.7 diagonal) still docks the corner. */
    HWMPlaneRect corner_only[]={{300,100,100,100},{188,212,100,100}};
    assert(hwm_plane_snap_choose((HWMPlaneRect){197,91,100,100},corner_only,2,12,12,NULL,&target));
    near(target.point.x,188); near(target.point.y,100); assert(target.contact_count==2);
    /* A fresh target with more contacts wins over the held one. */
    HWMPlaneRect corner[]={{300,100,100,100},{188,212,100,100}};
    assert(hwm_plane_snap_choose_held((HWMPlaneRect){192,104,100,100},corner,2,12,12,20,&held,true,false,&target,&kept));
    near(target.point.x,188); near(target.point.y,100); assert(target.contact_count==2);

    HWMPlaneSnapSeam seams[HWM_PLANE_SNAP_SEAMS];
    HWMPlaneRect moving={188,100,100,100};
    assert(hwm_plane_snap_seams(moving,corner,2,12,12,(HWMPlanePoint){188,100},seams,HWM_PLANE_SNAP_SEAMS)==2);
    bool vertical=false,horizontal=false;
    for(int i=0;i<2;i++) {
        if(seams[i].edge==0) { vertical=true; near(seams[i].from,0); near(seams[i].to,100); }
        if(seams[i].edge==2) { horizontal=true; near(seams[i].from,0); near(seams[i].to,100); }
    }
    assert(vertical && horizontal);
    HWMPlaneRect shorter={300,150,100,100};
    assert(hwm_plane_snap_seams(moving,&shorter,1,12,12,(HWMPlanePoint){188,100},seams,HWM_PLANE_SNAP_SEAMS)==1);
    near(seams[0].from,50); near(seams[0].to,100);
    /* Stacked neighbors along one edge read as one continuous seam. */
    HWMPlaneRect stacked[]={{300,100,100,60},{300,140,100,100}};
    assert(hwm_plane_snap_seams(moving,stacked,2,12,12,(HWMPlanePoint){188,100},seams,HWM_PLANE_SNAP_SEAMS)==1);
    near(seams[0].from,0); near(seams[0].to,100);
    /* Separate neighbors with a break between them keep separate seams. */
    HWMPlaneRect split[]={{300,60,100,60},{300,150,100,100}};
    assert(hwm_plane_snap_seams(moving,split,2,12,12,(HWMPlanePoint){188,100},seams,HWM_PLANE_SNAP_SEAMS)==2);
}

static void test_snap_has_axis_bound(void)
{
    const double scales[]={.1,.25,.5,.7,1,2,4};
    HWMPlaneRect neighbor={100,100,100,100};
    for(size_t z=0;z<sizeof(scales)/sizeof(scales[0]);z++) {
        double scale=scales[z],range=12/scale;
        for(int ix=-60;ix<=60;ix++) for(int iy=-60;iy<=60;iy++) {
            HWMPlaneRect moving={212+ix*.25/scale,100+iy*.25/scale,40,50};
            HWMPlanePoint target;
            if(hwm_plane_snap_neighbors_target(moving,&neighbor,1,12,range,&target)) {
                assert(fabs(target.x-moving.x)<=range && fabs(target.y-moving.y)<=range);
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

/* A quick sweep focuses nothing on the way; slowing, stopping or staying does. */
static void test_focus_intent(void)
{
    HWMFocusIntent s={0}; double t=10,x=0;
    // 4800 points per second, a report every 8 ms, across windows 1..4.
    // The sweep starts in window 1, already focused; it crosses 2, 3 and 4.
    for(int i=0;i<40;i++) { t+=.008; x+=38.4; bool go=hwm_focus_intent_sample(&s,1+(uint32_t)(i/10),x,300,t); if(i>=2) assert(!go); }
    // The pointer stops in window 4: nothing more is reported, and a check
    // after the settle interval focuses it.
    assert(!hwm_focus_intent_settled(&s,4,t+.01));
    assert(hwm_focus_intent_settled(&s,4,t+HWM_FOCUS_SETTLE+.002));
    assert(!hwm_focus_intent_settled(&s,3,t+HWM_FOCUS_SETTLE+.002)); // Only the window it stopped in.
    // Decelerating onto window 5 focuses it while still moving slowly.
    HWMFocusIntent d={0}; t=20; x=0; bool focused=false;
    for(int i=0;i<6;i++) { t+=.008; x+=32; hwm_focus_intent_sample(&d,4,x,300,t); } // Arriving at 4000 points per second.
    for(int i=0;i<30 && !focused;i++) { t+=.008; double v=4000*pow(.82,i); x+=v*.008; focused=hwm_focus_intent_sample(&d,5,x,300,t); if(focused) assert(v<1200); }
    assert(focused);
    // A slow, deliberate move focuses at once.
    HWMFocusIntent w={0}; t=30;
    assert(hwm_focus_intent_sample(&w,6,0,0,t));
    t+=.008; assert(hwm_focus_intent_sample(&w,7,2,0,t)); // 250 points per second.
    // Staying in a window long enough focuses it even while moving fast.
    HWMFocusIntent f={0}; t=40; x=0; bool dwell=false;
    for(int i=0;i<6;i++) { t+=.008; x+=40; hwm_focus_intent_sample(&f,7,x,0,t); }
    for(int i=0;i<120;i++) { t+=.008; x+=40; dwell=hwm_focus_intent_sample(&f,8,x,0,t); if(i<98) assert(!dwell); }
    assert(dwell);
    // A quick back-and-forth reverses in each window without settling there.
    HWMFocusIntent r={0}; t=60; x=0; double v=3000;
    for(int i=0;i<60;i++) { t+=.008; x+=v*.008; if(x>400 || x<0) { v=-v; x+=2*v*.008; }
        bool go=hwm_focus_intent_sample(&r,x<200?10:11,x,0,t); if(i>=4) assert(!go); }
    // Bunched reports carry no speed and do not count as slow.
    HWMFocusIntent b={0}; t=50;
    hwm_focus_intent_note(&b,0,0,t); assert(!hwm_focus_intent_sample(&b,9,30,0,t+.001));
}

static void test_auto_center(void)
{
    HWMPlanePoint target;
    assert(hwm_plane_center_camera((HWMPlaneRect){1000,300,600,400},1200,900,&target));
    near(target.x,700); near(target.y,50);
    assert(hwm_plane_center_camera((HWMPlaneRect){1000,300,600,1400},1200,900,&target));
    near(target.y,300); // Taller than the viewport: top-aligned.
    assert(!hwm_plane_center_camera((HWMPlaneRect){1000,300,1600,400},1200,900,&target));
    HWMPlanePoint targets[]={{700,50},{1400,50}};
    HWMPlaneCamera start={400,50,1};
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){640,80,1},targets,2,120)==0);
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){1300,50,1},targets,2,120)==1);
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){500,50,1},targets,2,120)==-1); // Too far.
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){640,80,.5},targets,2,120)==-1); // Zoomed out.
    assert(hwm_plane_auto_center((HWMPlaneCamera){700,50,1},(HWMPlaneCamera){760,50,1},targets,2,120)==-1); // Escape.
    assert(hwm_plane_auto_center((HWMPlaneCamera){640,50,1},(HWMPlaneCamera){642,50,1},targets,2,120)==-1); // A touch.
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){700,50,1},targets,2,120)==-1); // Already centered.
    assert(hwm_plane_auto_center(start,(HWMPlaneCamera){640,80,1},NULL,2,120)==-1);
}


/* A retargeted camera transition continues the motion it interrupts. */
static void test_camera_launch(void)
{
    const double w=1200,h=900,d=.3;
    HWMPlaneCamera from={0,0,1},right={1000,0,1},left={-1000,0,1};
    /* At rest, or with no motion, a transition starts from rest. */
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){0,0,0},d),0);
    /* Heading the same way: progress rate is speed over distance. */
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){2000,0,0},d),2);
    /* Heading away from the new target never pushes progress backwards. */
    near(hwm_plane_camera_launch(from,left,w,h,(HWMPlaneCameraVelocity){2000,0,0},d),0);
    /* Perpendicular motion carries nothing along the new path. */
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){0,3000,0},d),0);
    /* A violent fling is capped below the spring's frequency. */
    double cap=.8*hstrip_spring_omega(d,1);
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){1e7,0,0},d),cap);
    /* Zoom motion counts toward a zoom-only transition. */
    HWMPlaneCamera out={-300,-225,.5};
    HWMPlaneCameraVelocity zooming=hwm_plane_camera_velocity(from,out,w,h,.3,3);
    assert(zooming.zoom<0);
    double launch=hwm_plane_camera_launch(hwm_plane_camera_mix(from,out,w,h,.3),out,w,h,zooming,d);
    assert(launch>0 && launch<=cap);
    /* Invalid input starts from rest. */
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){NAN,0,0},d),0);
    near(hwm_plane_camera_launch((HWMPlaneCamera){0,0,0},right,w,h,(HWMPlaneCameraVelocity){1,0,0},d),0);
    near(hwm_plane_camera_launch(from,right,w,h,(HWMPlaneCameraVelocity){1,0,0},0),0);
    near(hwm_plane_camera_launch(from,from,w,h,(HWMPlaneCameraVelocity){1000,0,0},d),0);
    /* Progress is monotonic, ends exactly at 1, and starts at the launch rate. */
    double rate;
    near(hwm_plane_camera_progress(0,d,cap,&rate),0); near(rate,cap);
    near(hwm_plane_camera_progress(d,d,cap,&rate),1);
    near(hwm_plane_camera_progress(NAN,d,cap,NULL),0);
    for(int l=0;l<3;l++) {
        double launch_rate=(double[]){0,2,cap}[l],previous=0;
        for(double t=.001;t<d;t+=.001) {
            double p=hwm_plane_camera_progress(t,d,launch_rate,&rate);
            assert(p>=previous && p<=1 && rate>=-1e-9); previous=p;
        }
        assert(previous>.999);
    }
    /* Without a launch it matches the original ease. */
    for(double t=0;t<=d;t+=.01) near(hwm_plane_camera_progress(t,d,0,NULL),hstrip_spring_progress(t,d));
    /* A transition's velocity matches its finite difference, and continuing
     * it into the same target keeps the speed it had. */
    HWMPlaneCameraVelocity v=hwm_plane_camera_velocity(from,right,w,h,.5,2);
    assert(fabs(v.x-2000)<1e-3 && fabs(v.y)<1e-9 && fabs(v.zoom)<1e-9);
    HWMPlaneCamera mid=hwm_plane_camera_mix(from,right,w,h,.5);
    assert(fabs(hwm_plane_camera_launch(mid,right,w,h,v,d)-4)<1e-3);
    v=hwm_plane_camera_velocity(from,right,w,h,1,2); near(v.x,0);
    v=hwm_plane_camera_velocity(from,right,w,h,.5,0); near(v.x,0);
}

/* A pinch resting just short of 100% finishes about the pinch point. */
static void test_zoom_detent(void)
{
    HWMPlaneCamera camera={100,50,.95},out={0,0,0};
    HWMPlanePoint anchor={600,300};
    assert(hwm_plane_zoom_detent(camera,anchor,true,&out));
    near(out.scale,1);
    /* The plane point under the anchor stays under it. */
    assert(fabs((camera.x+anchor.x/camera.scale)-(out.x+anchor.x))<=.5);
    assert(fabs((camera.y+anchor.y/camera.scale)-(out.y+anchor.y))<=.5);
    near(out.x,round(out.x)); near(out.y,round(out.y));
    near(hwm_plane_zoom_detent((HWMPlaneCamera){0,0,HWM_PLANE_ZOOM_DETENT},anchor,true,&out),1);
    /* Zooming out, below the detent, already at 100%, or invalid: no snap. */
    assert(!hwm_plane_zoom_detent(camera,anchor,false,&out));
    assert(!hwm_plane_zoom_detent((HWMPlaneCamera){0,0,.85},anchor,true,&out));
    assert(!hwm_plane_zoom_detent((HWMPlaneCamera){0,0,1},anchor,true,&out));
    assert(!hwm_plane_zoom_detent((HWMPlaneCamera){0,0,NAN},anchor,true,&out));
    assert(!hwm_plane_zoom_detent(camera,(HWMPlanePoint){INFINITY,0},true,&out));
    assert(!hwm_plane_zoom_detent(camera,anchor,true,NULL));
}

int main(void)
{
    const double requested_zooms[]={.000001,.001,.1,.25,.5,1,1.001,2,4,DBL_MAX};
    for(size_t i=0;i<sizeof(requested_zooms)/sizeof(requested_zooms[0]);i++)
        near(hwm_plane_zoom_clamp(requested_zooms[i]),fmin(1,requested_zooms[i]));
    near(hwm_plane_zoom_clamp(0),1);
    near(hwm_plane_zoom_clamp(NAN),1);
    near(hwm_plane_zoom_clamp(INFINITY),1);
    HWMPlaneCamera from={-600,300,.2},to={200,-90,1};
    HWMPlaneCamera middle=hwm_plane_camera_mix(from,to,1200,900,.5);
    near(middle.scale,sqrt(.2));
    double mix=(1/sqrt(.2)-5)/(1-5);
    near(middle.x+1200/(2*middle.scale),(from.x+3000)+((to.x+600)-(from.x+3000))*mix);
    near(middle.y+900/(2*middle.scale),(from.y+2250)+((to.y+450)-(from.y+2250))*mix);
    /* The point shown at the same screen place at both ends never moves. */
    double fixed_x=(from.x*from.scale-to.x*to.scale)/(from.scale-to.scale);
    for(double t=.1;t<1;t+=.1) {
        HWMPlaneCamera c=hwm_plane_camera_mix(from,to,1200,900,t);
        near((fixed_x-c.x)*c.scale,(fixed_x-from.x)*from.scale);
    }
    /* Pure translation is still linear in progress. */
    HWMPlaneCamera pan=hwm_plane_camera_mix((HWMPlaneCamera){0,0,1},(HWMPlaneCamera){100,-40,1},1200,900,.25);
    near(pan.x,25); near(pan.y,-10); near(pan.scale,1);
    double hop=hwm_plane_camera_duration((HWMPlaneCamera){0,0,1},(HWMPlaneCamera){40,0,1},1200,900);
    double trip=hwm_plane_camera_duration((HWMPlaneCamera){0,0,1},(HWMPlaneCamera){4000,0,1},1200,900);
    double zoom=hwm_plane_camera_duration(from,to,1200,900);
    assert(hop>=.22 && hop<.26 && trip>hop && trip<=.42 && zoom>hop && zoom<=.42);
    near(hwm_plane_camera_duration((HWMPlaneCamera){0,0,0},to,1200,900),.36);
    test_auto_center();
    test_focus_intent();
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
    test_camera_launch();
    test_zoom_detent();
    test_multi_neighbor_snap();
    test_snap_can_escape_existing_overlap_and_keeps_edge();
    test_snap_has_axis_bound();
    test_snap_hold_and_seams();
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
    HWMPlaneRect small={100,200,160,100};
    HWMPlaneCamera fitted=hwm_plane_camera_fit(small,viewport,36);
    near(fitted.scale,1);
    near(fitted.x+viewport.width/2,small.x+small.width/2);
    near(fitted.y+viewport.height/2,small.y+small.height/2);
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
    HWMPlaneHoverIntent intention={0};
    HWMPlaneRect near_window={360,200,400,300}, far_window={760,200,400,300};
    HWMPlaneRect hover_view={0,0,1000,700};
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){425,350},near_window,hover_view,1));
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){425,350},near_window,hover_view,2)); // Dwell alone.
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){432,350},near_window,hover_view,2.01));
    assert(hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){452,350},near_window,hover_view,2.02));
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){480,350},near_window,hover_view,2.2)); // Once per entry.
    assert(!hwm_plane_hover_intent(&intention,2,(HWMPlanePoint){825,350},far_window,hover_view,3));
    assert(!hwm_plane_hover_intent(&intention,2,(HWMPlanePoint){855,350},far_window,hover_view,3.2)); // Distant windows.
    intention=(HWMPlaneHoverIntent){0};
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){480,350},near_window,hover_view,4));
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){452,350},near_window,hover_view,4.2)); // Moving away.
    assert(!hwm_plane_hover_intent(&intention,1,(HWMPlanePoint){600,350},near_window,hover_view,4.21)); // Fast pass-through.
    assert(!hwm_plane_hover_intent(&intention,3,(HWMPlanePoint){452,350},near_window,hover_view,5)); // New target resets intent.
    puts("plane geometry tests passed");
    return 0;
}
