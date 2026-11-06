#ifndef HWM_PLANE_TILE_GEOMETRY_H
#define HWM_PLANE_TILE_GEOMETRY_H
#include "plane_geometry.h"
/* Substantial overlap is measured against the smaller window. */
static inline double hwm_plane_tile_overlap(HWMPlaneRect a,HWMPlaneRect b,double scale)
{
    if(!hwm_plane_rect_valid(a) || !hwm_plane_rect_valid(b) || !isfinite(scale) || scale<=0) return 0;
    double x=fmin(a.x+a.width,b.x+b.width)-fmax(a.x,b.x);
    double y=fmin(a.y+a.height,b.y+b.height)-fmax(a.y,b.y);
    if(x*scale<fmin(24,fmin(a.width,b.width)*scale*.25) ||
       y*scale<fmin(24,fmin(a.height,b.height)*scale*.25)) return 0;
    return fmax(0,x)*fmax(0,y)/fmin(a.width*a.height,b.width*b.height);
}
#endif
