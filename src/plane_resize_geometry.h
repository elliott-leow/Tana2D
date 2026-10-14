#ifndef TANA2D_PLANE_RESIZE_GEOMETRY_H
#define TANA2D_PLANE_RESIZE_GEOMETRY_H
#include "plane_geometry.h"
enum { HWM_EDGE_TOP=1, HWM_EDGE_BOTTOM=2, HWM_EDGE_LEFT=4, HWM_EDGE_RIGHT=8 };
static inline unsigned hwm_plane_resize_hit(HWMPlaneRect frame,HWMPlanePoint point)
{
    if(point.x<frame.x-3 || point.x>frame.x+frame.width+3 || point.y<frame.y-3 || point.y>frame.y+frame.height+3) return 0;
    unsigned direction=0;
    if(fabs(point.x-frame.x)<=5) direction|=HWM_EDGE_LEFT;
    else if(fabs(point.x-frame.x-frame.width)<=5) direction|=HWM_EDGE_RIGHT;
    if(fabs(point.y-frame.y)<=4) direction|=HWM_EDGE_TOP;
    else if(fabs(point.y-frame.y-frame.height)<=5) direction|=HWM_EDGE_BOTTOM;
    return direction;
}
static inline HWMPlaneRect hwm_plane_resize_target(HWMPlaneRect start,HWMPlanePoint delta,double scale,unsigned direction)
{
    if(!isfinite(scale) || scale<=0 || !isfinite(delta.x) || !isfinite(delta.y)) return start;
    double dx=delta.x/scale,dy=delta.y/scale;
    double width=start.width+((direction&HWM_EDGE_LEFT)?-dx:(direction&HWM_EDGE_RIGHT)?dx:0);
    double height=start.height+((direction&HWM_EDGE_TOP)?-dy:(direction&HWM_EDGE_BOTTOM)?dy:0);
    width=fmin(20000,fmax(160,width)); height=fmin(20000,fmax(100,height));
    return (HWMPlaneRect){start.x+((direction&HWM_EDGE_LEFT)?start.width-width:0),
                         start.y+((direction&HWM_EDGE_TOP)?start.height-height:0),width,height};
}
#endif
