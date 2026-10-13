/* Exercise the production adapter against the helper's actual toggle contract. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
static CGRect native;
static CGAffineTransform transform;
static struct { float x,y,w,h; } queued[16];
static int count;
static int SLSMainConnectionID(void) { return 1; }
static CGError SLSGetWindowBounds(int cid,uint32_t wid,CGRect *out) { (void)cid;(void)wid;*out=native;return 0; }
CGError SLSGetWindowTransform(int cid,uint32_t wid,CGAffineTransform *out) { (void)cid;(void)wid;*out=transform;return 0; }
static bool scripting_addition_scale_window(uint32_t wid,float x,float y,float w,float h) {
    (void)wid; assert(count<16); queued[count++]=(typeof(queued[0])){x,y,w,h}; return true;
}
static bool scripting_addition_batch_flush(void) {
    for(int i=0;i<count;i++) {
        CGAffineTransform identity=CGAffineTransformMakeTranslation(-native.origin.x,-native.origin.y);
        if(!CGAffineTransformEqualToTransform(transform,identity)) { transform=identity; continue; }
        int width=queued[i].w/4, height=width/(native.size.width/native.size.height);
        double sx=native.size.width/width,sy=native.size.height/height;
        transform=CGAffineTransformTranslate(CGAffineTransformMakeScale(sx,sy),-(queued[i].x+queued[i].w)+width,-queued[i].y);
    }
    count=0; return true;
}
#include "../vendor/yabai/src/misc/plane_transform.h"
static void verify(double x,double y,double scale) {
    assert(scripting_addition_set_plane_transform(1,x,y,scale)); scripting_addition_batch_flush();
    assert(fabs(-transform.tx/transform.a-x)<.01 && fabs(-transform.ty/transform.d-y)<.01);
    assert(fabs(native.size.width/transform.a-native.size.width*scale)<=.6);
    assert(fabs(native.size.height/transform.d-native.size.height*scale)<1.5);
}
int main(void) {
    native=CGRectMake(110,90,1001,713);
    transform=CGAffineTransformMakeTranslation(-110,-90);
    verify(40,60,.5); verify(40,60,.5); // Repeating a target must never toggle it off.
    verify(55,75,.8); verify(-250,100,2); // Both zoom directions and translated camera.
    assert(scripting_addition_set_plane_transform(1,NAN,NAN,1)); scripting_addition_batch_flush();
    assert(CGAffineTransformEqualToTransform(transform,CGAffineTransformMakeTranslation(-110,-90)));
    verify(40,60,.5);
    native.origin=CGPointMake(800,600); // Native placement may invalidate prior state.
    verify(100,120,.5);
    assert(!scripting_addition_set_plane_transform(1,0,0,0));
    puts("absolute plane transform tests passed");
}
