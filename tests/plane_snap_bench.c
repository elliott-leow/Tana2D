#include <assert.h>
#include <stdio.h>
#include <time.h>
#include "../src/plane_geometry.h"

static double run_sparse(void)
{
    enum { peers=256, proposals=10000 };
    HWMPlaneRect neighbors[peers];
    for(size_t i=0;i<peers;i++) neighbors[i]=(HWMPlaneRect){10000+i*300,10000,100,100};
    neighbors[0]=(HWMPlaneRect){0,200,188,100};
    neighbors[1]=(HWMPlaneRect){312,200,100,100};
    neighbors[2]=(HWMPlaneRect){200,312,100,100};
    HWMPlaneRect moving={206,206,100,100};
    HWMPlaneSnapTarget target;
    clock_t began=clock();
    for(int i=0;i<proposals;i++) {
        assert(hwm_plane_snap_choose(moving,neighbors,peers,12,12,NULL,&target));
        assert(target.contact_count==3 && target.point.x==200 && target.point.y==200);
    }
    double elapsed=1000.0*(double)(clock()-began)/(double)CLOCKS_PER_SEC;
    printf("plane snap sparse: %d proposals over %d peers in %.2f ms\n",proposals,peers,elapsed);
    return elapsed;
}

static double run_dense(void)
{
    enum { peers=256, proposals=10 };
    HWMPlaneRect neighbors[peers];
    for(size_t i=0;i<peers/2;i++) neighbors[i]=(HWMPlaneRect){0,200,188,100};
    for(size_t i=peers/2;i<peers;i++) neighbors[i]=(HWMPlaneRect){200,0,100,188};
    HWMPlaneRect moving={206,206,100,100};
    HWMPlaneSnapTarget target;
    clock_t began=clock();
    for(int i=0;i<proposals;i++) {
        assert(hwm_plane_snap_choose(moving,neighbors,peers,12,12,NULL,&target));
        assert(target.contact_count==peers && target.point.x==200 && target.point.y==200);
    }
    double elapsed=1000.0*(double)(clock()-began)/(double)CLOCKS_PER_SEC;
    printf("plane snap dense: %d proposals over %d stacked peers in %.2f ms\n",proposals,peers,elapsed);
    return elapsed;
}

int main(void)
{
    (void)run_sparse();
    (void)run_dense();
    return 0;
}
