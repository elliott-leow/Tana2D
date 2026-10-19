/* Reuse only the WindowServer boundary stubs. Exercise the production preview
 * renderer, including movement-cache work and click-through behavior. */
#define main border_boundary_harness_main
#define hwm_now boundary_constant_now
#define hstrip_spring_progress boundary_spring_progress
#define SLSSetMouseEventEnableFlags boundary_mouse_flags
#include "plane_border_test.m"
#undef main
#undef hwm_now
#undef hstrip_spring_progress
#undef SLSSetMouseEventEnableFlags
#include "../src/strip_geometry.h"
#include "../src/plane_geometry.h"

static double preview_clock=1;
static double hwm_now(void) { return preview_clock; }
static double horizontal_ease(double t) { return hstrip_ease(t); }
static double hwm_motion_scale=1;
static CGRect hwm_preview_from,hwm_preview_target,hwm_preview_current;
static double hwm_preview_start,hwm_preview_alpha,hwm_preview_alpha_from,hwm_preview_alpha_start;
static bool hwm_preview_visible,hwm_preview_hiding;
static int mouse_disable_calls;
#define move_calls transform_calls
#define move_ok transform_result
static CGError SLSSetMouseEventEnableFlags(int cid,uint32_t wid,bool enabled)
{ (void)cid; (void)wid; assert(!enabled); ++mouse_disable_calls; return kCGErrorSuccess; }
/* Paints run in place; a deferred mode holds one to test the frame in between. */
static bool defer_preview; static void (*held_preview)(void *);
static void preview_schedule(void (*work)(void *)) { if(defer_preview) held_preview=work; else work(NULL); }
#define HWM_PREVIEW_SCHEDULE(work) preview_schedule(work)
#include "../src/plane_preview.m"

static CGRect outset(CGRect frame) { double m=hwm_preview_margin(12); return CGRectInset(frame,-m,-m); }

int main(void) { @autoreleasepool {
    CGRect frame=CGRectMake(100,100,400,300);
    HWMPlaneSnapSeam right[]={{0,0,300}},corner[]={{0,0,300},{2,40,400}};
    hwm_preview_snap_show(frame,right,1,12);
    assert(hwm_preview_visible && hwm_preview_ordered && hwm_preview_draws==1 && mouse_disable_calls==1);
    assert(CGRectEqualToRect(hwm_preview_current,outset(frame)));
    int shapes=shape_calls; uint64_t draws=hwm_preview_draws;
    for(int i=0;i<240;i++) {
        preview_clock+=1.0/120;
        frame.origin.y+=.5;
        hwm_preview_snap_show(frame,right,1,12);
        assert(CGRectEqualToRect(hwm_preview_current,outset(frame)));
    }
    assert(shape_calls==shapes && hwm_preview_draws==draws && move_calls==241);
    /* A stationary preview does not issue more movement or raster work. */
    for(int i=0;i<120;i++) { preview_clock+=1.0/120; hwm_preview_render(preview_clock); }
    assert(move_calls==241 && hwm_preview_draws==draws);
    /* Gaining a contact paints the other surface off the frame thread. Until
     * that lands the surface on screen keeps following the pointer. */
    uint32_t first=hwm_preview_id;
    defer_preview=true;
    hwm_preview_snap_show(frame,corner,2,12);
    assert(held_preview && hwm_preview_draws==draws && hwm_preview_id==first && hwm_preview_visible);
    frame.origin.x+=3; preview_clock+=1.0/120; hwm_preview_snap_show(frame,corner,2,12);
    assert(hwm_preview_id==first && CGRectEqualToRect(hwm_preview_current,outset(frame)));
    held_preview(NULL); held_preview=NULL; defer_preview=false;
    preview_clock+=1.0/120; hwm_preview_render(preview_clock);
    assert(hwm_preview_draws==draws+1 && hwm_preview_id!=first && mouse_disable_calls==2);
    // The same contacts translated paint nothing.
    frame.origin.x+=3; hwm_preview_snap_show(frame,corner,2,12);
    assert(hwm_preview_draws==draws+1);
    /* Returning to the first contacts reuses the surface that still has them. */
    hwm_preview_snap_show(frame,right,1,12);
    assert(hwm_preview_draws==draws+1 && hwm_preview_id==first);
    move_ok=false; frame.origin.x+=10; hwm_preview_snap_show(frame,corner,2,12);
    assert(!hwm_preview_visible && !hwm_preview_ordered);
    move_ok=true; hwm_preview_snap_show(frame,corner,2,12);
    assert(hwm_preview_visible && hwm_preview_ordered && CGRectEqualToRect(hwm_preview_current,outset(frame)));
    hwm_preview_hide(); preview_clock+=.1; hwm_preview_render(preview_clock);
    assert(!hwm_preview_visible && !hwm_preview_ordered && batch_depth==0);

    /* Rasterize the seams: both bars of a corner are drawn in the gutter,
     * and the docked window's interior is left untinted. */
    hwm_border_active[0]=.40; hwm_border_active[1]=.72; hwm_border_active[2]=1; hwm_border_active[3]=1;
    double m=hwm_preview_margin(12);
    CGSize size=CGSizeMake(400+2*m,300+2*m);
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef canvas=CGBitmapContextCreate(NULL,(size_t)size.width,(size_t)size.height,8,0,colors,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colors); assert(canvas);
    hwm_preview_draw_seams(canvas,size,corner,2,12,true);
    CGImageRef rendered=CGBitmapContextCreateImage(canvas);
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithCGImage:rendered];
    // NSBitmapImageRep is top-down. Right seam: x=m+400+6. Bottom seam: y=m+300+6.
    assert([[bitmap colorAtX:(NSInteger)(m+406) y:(NSInteger)(m+150)] alphaComponent]>.9);
    assert([[bitmap colorAtX:(NSInteger)(m+220) y:(NSInteger)(m+306)] alphaComponent]>.9);
    assert([[bitmap colorAtX:(NSInteger)(m+20) y:(NSInteger)(m+306)] alphaComponent]<.01); // Before the shared span.
    assert([[bitmap colorAtX:(NSInteger)(m+200) y:(NSInteger)(m+150)] alphaComponent]<.01);
    assert([[bitmap colorAtX:(NSInteger)(m-6) y:(NSInteger)(m+150)] alphaComponent]<.01);   // No left contact.
    if(getenv("TANA2D_RENDER_PREVIEW"))
        assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:@"build/snap-preview-seams.png" atomically:YES]);
    [bitmap release]; CGImageRelease(rendered); CGContextRelease(canvas);
    for(int i=0;i<2;i++) if(hwm_preview_surfaces[i].context) CGContextRelease(hwm_preview_surfaces[i].context);
    puts("preview translation cache, multi-contact seams, click-through, retry, and fade tests passed");
} return 0; }
