#ifndef TANA2D_PLANE_TRANSFORM_H
#define TANA2D_PLANE_TRANSFORM_H
/* Adapt the installed helper's toggle protocol to an absolute plane transform.
 * Flush before observing: queued moves invalidate transform state. Never infer
 * native geometry or toggle state from an optimistic renderer cache. */
extern CGError SLSGetWindowTransform(int, uint32_t, CGAffineTransform *);
bool scripting_addition_set_plane_transform(uint32_t wid,double x,double y,double scale)
{
    if(!isfinite(scale) || scale<=0 || !scripting_addition_batch_flush()) return false;
    CGRect native=CGRectNull; CGAffineTransform current;
    if(SLSGetWindowBounds(SLSMainConnectionID(),wid,&native)!=kCGErrorSuccess || native.size.width<=0 || native.size.height<=0 ||
       SLSGetWindowTransform(SLSMainConnectionID(),wid,&current)!=kCGErrorSuccess) return false;
    CGAffineTransform identity=CGAffineTransformMakeTranslation(-native.origin.x,-native.origin.y);
    if(!CGAffineTransformEqualToTransform(current,identity)) {
        if(!scripting_addition_scale_window(wid,native.origin.x-3*native.size.width,native.origin.y,4*native.size.width,native.size.height) ||
           !scripting_addition_batch_flush()) return false;
    }
    if(!isfinite(x)) x=native.origin.x;
    if(!isfinite(y)) y=native.origin.y;
    if(scale==1 && fabs(x-native.origin.x)<.01 && fabs(y-native.origin.y)<.01) return true;
    double width=fmax(1,round(native.size.width*scale));
    return scripting_addition_scale_window(wid,x-3*width,y,4*width,native.size.height*scale);
}

#endif
