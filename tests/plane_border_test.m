/* Production border retry regression. WindowServer and helper boundaries are
 * deterministic; no Accessibility permission or live windows are involved. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdatomic.h>

struct window { uint32_t id; bool strip_no_border; };
struct view { int unused; };

static int g_connection;
static bool hwm_paused,hwm_suspended,hwm_overview_active;
static int hwm_border_mode=1;
static double hwm_border_width=2,hwm_border_radius=12,hwm_plane_scale=.5;
static unsigned hwm_border_generation;
static double hwm_border_active[4]={1,1,1,1},hwm_border_active_end[4]={1,1,1,1};
static bool hwm_border_travel;
static volatile bool __pending_gesture;
static uint32_t hwm_drag_window,hwm_feedback_focus_id;
static uint32_t hwm_border_from_id;
static double hwm_border_travel_start;
static bool hwm_backend_ok=true;
static struct window focus={.id=7};
static CGRect feedback= { {100,100}, {400,300} };
static int transform_calls,batch_depth,order_out_calls,order_in_calls,shape_calls,new_window_calls;
static bool transform_result=true,batch_ack=true,batch_held,order_in_result=true,shape_result=true,new_window_result=true,context_result=true;

static struct window *window_manager_find_window(void *manager,uint32_t id)
{ (void)manager; return id==focus.id ? &focus : NULL; }
static struct { int unused; } g_window_manager;
static CGRect hwm_screen(struct view *view) { (void)view; return CGRectMake(0,0,2000,1200); }
static CGRect hwm_feedback_frame(struct view *view,struct window *window,CGRect screen)
{ (void)view; (void)window; (void)screen; return feedback; }
static double hwm_border_travel_span(void) { return 0; }
static double hwm_now(void) { return 1; }
static double hstrip_spring_progress(double elapsed,double span) { (void)elapsed; (void)span; return 1; }
static struct window *view_find_window_node(struct view *view,uint32_t id)
{ (void)view; return id==focus.id ? &focus : NULL; }

static int full_batches; // Batches that suspend screen updates.
static void hwm_batch_begin(void) { ++batch_depth; ++full_batches; }
static void hwm_batch_begin_plane(void) { ++batch_depth; }
static void hwm_batch_end(void)
{
    assert(batch_depth>0); --batch_depth;
    if(!batch_depth && !batch_held && !batch_ack) hwm_backend_ok=false;
}
static CGError SLSSetWindowResolution(int cid,uint32_t wid,double scale)
{ (void)cid; (void)wid; assert(scale>=1); return kCGErrorSuccess; }
static bool scripting_addition_set_plane_transform_xy(uint32_t id,double x,double y,double sx,double sy)
{
    (void)id; (void)x; (void)y; (void)sx; (void)sy; ++transform_calls;
    return transform_result;
}
/* The helper's in-transaction alpha. Off, rings are ordered in and out. */
static bool alpha_supported,alpha_result=true;
static int alpha_records,alpha_shows,alpha_hides,direct_alpha_calls;
static bool scripting_addition_plane_alpha_supported(void) { return alpha_supported; }
static bool scripting_addition_set_opacity(uint32_t wid,float opacity,float duration)
{
    assert(alpha_supported && wid && duration==0 && batch_depth>0);
    ++alpha_records; if(opacity==1) ++alpha_shows; else { assert(opacity==0); ++alpha_hides; }
    return alpha_result;
}
static CGError SLSSetWindowAlpha(int cid,uint32_t wid,float alpha)
{ (void)cid; (void)wid; assert(alpha>=0 && alpha<=1); ++direct_alpha_calls; return kCGErrorSuccess; }

static CGError CGSNewRegionWithRect(CGRect *rect,CFTypeRef *region)
{ (void)rect; *region=CFRetain(kCFBooleanTrue); return kCGErrorSuccess; }
static CFTypeRef CGRegionCreateEmptyRegion(void) { return CFRetain(kCFBooleanTrue); }
static CGError SLSNewWindowWithOpaqueShapeAndContext(int connection,int type,CFTypeRef region,CFTypeRef empty,int options,uint64_t *tags,float x,float y,int tag_size,uint32_t *id,void *context)
{
    (void)connection; (void)type; (void)region; (void)empty; (void)options; (void)tags;
    (void)x; (void)y; (void)tag_size; (void)context; static uint32_t next=77; *id=next++; ++new_window_calls; return new_window_result?kCGErrorSuccess:kCGErrorFailure;
}
static void sls_window_disable_shadow(uint32_t id) { (void)id; }
static CGError SLSSetWindowOpacity(int connection,uint32_t id,bool opaque) { (void)connection; (void)id; (void)opaque; return kCGErrorSuccess; }
static CGError SLSSetWindowLevel(int connection,uint32_t id,int level) { (void)connection; (void)id; (void)level; return kCGErrorSuccess; }
static CGContextRef SLWindowContextCreate(int connection,uint32_t id,CFDictionaryRef options)
{
    (void)connection; (void)id; (void)options;
    if(!context_result) return NULL;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(NULL,1000,800,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    return context;
}
static CGError SLSSetWindowShape(int connection,uint32_t id,float x,float y,CFTypeRef region)
{ (void)connection; (void)id; (void)x; (void)y; (void)region; ++shape_calls; return shape_result?kCGErrorSuccess:kCGErrorFailure; }
static CGError SLSOrderWindow(int connection,uint32_t id,int mode,uint32_t relative)
{ (void)connection; (void)id; (void)relative; if(mode==0) ++order_out_calls; else ++order_in_calls; return mode==1 && !order_in_result?kCGErrorFailure:kCGErrorSuccess; }
static CGError SLSSetMouseEventEnableFlags(int connection,uint32_t id,bool enabled)
{ (void)connection; (void)id; (void)enabled; return kCGErrorSuccess; }

static bool test_moving;
static double hwm_zoom_pinch_time=-1;
static bool hwm_view_in_motion(struct view *view,double now) { (void)view; (void)now; return test_moving; }

static bool hwm_zoom_landing;
/* Paints run in place: a request is drawn before it returns. */
static int wakes;
static void hwm_wake(void) { ++wakes; }
static bool defer_paints; static void (*deferred_paint)(void *);
static void border_schedule(void (*work)(void *)) { if(defer_paints) deferred_paint=work; else work(NULL); }
#define HWM_BORDER_SCHEDULE(work) border_schedule(work)
#include "../src/plane_border.m"
/* The fixture's ring is drawn as four edge strips: every surface operation
 * happens once per strip. */
enum { S=HWM_BORDER_STRIPS };
static HWMBorderRing *shown_ring(void) { assert(hwm_border_shown>=0); return &hwm_border_rings[hwm_border_shown]; }

/* The old direct clear/gradient renderer is the visual reference. Compare
 * complete backing pixels after production replaces a previously drawn frame. */
static void verify_border_pixels(struct view *view)
{
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef reference=CGBitmapContextCreate(NULL,1000,800,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    for(int trial=0;trial<20;trial++) {
        feedback.size=CGSizeMake(400+trial,300);
        hwm_border_active[0]=.2; hwm_border_active[1]=.5; hwm_border_active[2]=.8; hwm_border_active[3]=.8;
        hwm_border_active_end[0]=.8; hwm_border_active_end[1]=.4; hwm_border_active_end[2]=.2; hwm_border_active_end[3]=.7;
        ++hwm_border_generation; hwm_plane_border_tick(view,1);
        HWMBorderRing *ring=shown_ring();
        assert(ring->generation==hwm_border_generation && hwm_plane_border_visible);
        CGRect local=CGRectMake(0,0,ring->canvas.width,ring->canvas.height);
        CGContextClearRect(reference,local);
        /* The stroke keeps its screen width at any zoom: canvas units per point. */
        double k=ring->canvas.width/hwm_plane_border_frame.size.width;
        assert(k>1.9 && k<2.1); // This fixture draws at 50%.
        CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,1*k,1*k),12,12,NULL);
        CGContextSaveGState(reference); CGContextAddPath(reference,path);
        CGContextSetLineWidth(reference,2*k); CGContextReplacePathWithStrokedPath(reference); CGContextClip(reference);
        CGFloat colors[8]; for(int i=0;i<4;i++) { colors[i]=hwm_border_active[i]; colors[i+4]=hwm_border_active_end[i]; }
        CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,NULL,2);
        CGContextDrawLinearGradient(reference,gradient,CGPointZero,CGPointMake(local.size.width,local.size.height),0);
        CGGradientRelease(gradient); CGPathRelease(path); CGContextRestoreGState(reference);
        /* Each strip holds its own slice of the ring, drawn bottom-up from its
         * surface origin. Gradient rounding may differ by one level. */
        assert(ring->count==S);
        const unsigned char *want=CGBitmapContextGetData(reference);
        size_t row=CGBitmapContextGetBytesPerRow(reference);
        for(int strip=0;strip<S;strip++) {
            CGRect r=ring->strips[strip];
            const unsigned char *got=CGBitmapContextGetData(ring->contexts[strip]);
            int y0=(int)(local.size.height-r.origin.y-r.size.height);
            for(int y=0;y<(int)r.size.height;y++) for(int x=0;x<(int)r.size.width;x++) for(int c=0;c<4;c++) {
                int top=(int)(ring->capacity[strip].height-r.size.height); // Pixels sit at the surface's top.
                int a=want[(size_t)(799-(y0+y))*row+(size_t)((int)r.origin.x+x)*4+c], b=got[(size_t)(799-(top+y))*row+(size_t)x*4+c];
                assert(abs(a-b)<=1);
            }
        }
        // Nothing of the ring lies outside the strips.
        CGRect inner=CGRectInset(local,ring->strips[2].size.width,ring->strips[0].size.height);
        for(int y=(int)inner.origin.y;y<(int)CGRectGetMaxY(inner);y+=7) for(int x=(int)inner.origin.x;x<(int)CGRectGetMaxX(inner);x+=7)
            assert(want[(size_t)(799-y)*row+(size_t)x*4+3]==0);
    }
    CGContextRelease(reference); CGColorSpaceRelease(space);
}

/* This is the production batch-release contract proposed for strip_layout:
 * deferred acknowledgement failures invalidate the border cache after tick. */
static void hwm_batch_release(void)
{
    batch_held=false;
    if(!batch_ack) { hwm_backend_ok=false; hwm_plane_border_batch_failed(); }
}

static void release_rings(void)
{
    for(int r=0;r<HWM_BORDER_RINGS;r++) for(int i=0;i<S;i++)
        if(hwm_border_rings[r].contexts[i]) { CGContextRelease(hwm_border_rings[r].contexts[i]); hwm_border_rings[r].contexts[i]=NULL; }
    memset(hwm_border_rings,0,sizeof(hwm_border_rings)); hwm_border_shown=-1;
    hwm_plane_border_visible=false; hwm_plane_border_frame=CGRectNull; hwm_plane_border_focus=0;
}

/* Retry contracts, for either way of putting a ring on screen. */
static void retries(struct view *view)
{
    hwm_plane_border_tick(view,1);
    assert(transform_calls==1*S && hwm_plane_border_visible);
    assert(hwm_plane_border_frame.origin.x==98);
    assert(order_in_calls==1*S);

    /* The helper rejects a title-bar drag update. A same-frame retry must not
     * be hidden by the cached requested position. */
    feedback.origin.x=200; transform_result=false;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==2*S && CGRectIsNull(hwm_plane_border_frame));
    assert(!hwm_plane_border_visible && order_out_calls==1*S);
    transform_result=true;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==3*S && hwm_plane_border_frame.origin.x==198 && hwm_plane_border_visible);

    /* A queued transform can be accepted locally but rejected when the batch
     * is acknowledged. That path must invalidate the cache too. */
    feedback.origin.x=300; batch_ack=false;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==4*S && !hwm_backend_ok && CGRectIsNull(hwm_plane_border_frame));
    hwm_backend_ok=true; batch_ack=true;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==5*S && hwm_plane_border_frame.origin.x==298);

    /* The manager normally holds a frame-wide batch. Its acknowledgement comes
     * after border_tick, so release must invalidate this already-cached frame. */
    feedback.origin.x=400; batch_held=true; batch_ack=false;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==6*S && hwm_plane_border_frame.origin.x==398);
    hwm_batch_release();
    assert(!hwm_backend_ok && !hwm_plane_border_visible && !hwm_plane_border_focus && CGRectIsNull(hwm_plane_border_frame));
    assert(order_out_calls==3*S);
    hwm_backend_ok=true; batch_ack=true;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==7*S && hwm_plane_border_frame.origin.x==398);

    /* WindowServer can reject the order-in after the helper accepted the
     * transform. Do not cache an invisible border and suppress its retry. */
    hwm_plane_border_hide(); feedback.origin.x=450; order_in_result=false;
    hwm_plane_border_tick(view,1);
    assert(!hwm_plane_border_visible && CGRectIsNull(hwm_plane_border_frame));
    order_in_result=true;
    int transforms=transform_calls;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==transforms+S && hwm_plane_border_visible && hwm_plane_border_frame.origin.x==448);

    /* A style-only config reload must repaint the cached pixels even when the
     * displayed frame and raster dimensions have not changed. It paints a
     * ring nobody sees, which then replaces the one on screen. */
    HWMBorderRing *before=shown_ring(); int shapes=shape_calls;
    ++hwm_border_generation; transforms=transform_calls;
    hwm_plane_border_tick(view,1);
    assert(shown_ring()!=before && shown_ring()->generation==hwm_border_generation);
    assert(transform_calls==transforms+S && shape_calls==shapes+S && hwm_plane_border_visible);
    // The ring it replaced is gone from the screen.
    assert(alpha_supported ? alpha_hides>=S : order_out_calls>=4*S);

    /* A failed shape is equally non-presentable: the ring on screen is
     * stretched to the new frame meanwhile, and the paint is retried rather
     * than a transformed, blank outline being cached. */
    HWMBorderRing *kept=shown_ring();
    feedback.size=CGSizeMake(900,300); shape_result=false; transforms=transform_calls; shapes=shape_calls;
    assert(!hwm_plane_border_tick(view,1)); // A failure alone does not keep the clock running.
    assert(transform_calls==transforms+S && hwm_plane_border_visible && shown_ring()==kept);
    assert(hwm_plane_border_frame.size.width==904 && kept->canvas.width<900);
    assert(shape_calls==shapes+1); // The failed redraw stopped at its first strip.
    shape_result=true;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==transforms+2*S && hwm_plane_border_visible && shape_calls>shapes+1 && shown_ring()!=kept);
    feedback.size=CGSizeMake(400,300);

    /* A created overlay without a drawing context is blank. Keep it invalid
     * until a later tick obtains a context and can redraw it. */
    hwm_plane_border_tick(view,1); assert(hwm_plane_border_visible);
    for(int r=0;r<HWM_BORDER_RINGS;r++) if(hwm_border_rings[r].contexts[0])
        { CGContextRelease(hwm_border_rings[r].contexts[0]); hwm_border_rings[r].contexts[0]=NULL; }
    kept=shown_ring(); context_result=false; feedback.size=CGSizeMake(420,300); transforms=transform_calls;
    hwm_plane_border_tick(view,1);
    assert(shown_ring()==kept && !CGSizeEqualToSize(kept->canvas,CGSizeMake(848,608)));
    context_result=true;
    hwm_plane_border_tick(view,1);
    assert(hwm_plane_border_visible && shown_ring()!=kept && shown_ring()->canvas.width==848);

    /* An API error wins even if WindowServer supplied a nonzero output ID. */
    hwm_plane_border_hide(); release_rings(); feedback.origin.x=500; new_window_result=false;
    hwm_plane_border_tick(view,1);
    assert(!hwm_plane_border_visible && !hwm_border_rings[0].ids[0] && CGRectIsNull(hwm_plane_border_frame));
    new_window_result=true; transforms=transform_calls;
    hwm_plane_border_tick(view,1);
    assert(transform_calls==transforms+S && hwm_plane_border_visible && hwm_plane_border_frame.origin.x==498);
    verify_border_pixels(view);
    feedback=CGRectMake(100,100,400,300);
}

/* Focus moving between windows of sizes already drawn paints nothing. */
static void ring_cache(struct view *view)
{
    CGRect a=CGRectMake(100,100,400,300),b=CGRectMake(600,100,640,300),c=CGRectMake(100,500,300,200);
    feedback=a; hwm_plane_border_tick(view,1);
    feedback=b; hwm_plane_border_tick(view,1);
    HWMBorderRing *ra=NULL,*rb=shown_ring();
    feedback=a; hwm_plane_border_tick(view,1); ra=shown_ring();
    assert(ra!=rb);
    int shapes=shape_calls,windows=new_window_calls,full=full_batches;
    for(int i=0;i<10;i++) {
        feedback=i%2 ? a : b; hwm_plane_border_tick(view,1);
        assert(shown_ring()==(i%2 ? ra : rb) && hwm_plane_border_visible);
    }
    assert(shape_calls==shapes && new_window_calls==windows);
    // The atomic swap never suspends screen updates.
    assert(alpha_supported ? full_batches==full : full_batches==full+10);
    /* A third size takes the spare ring; a fourth evicts the least recently
     * shown, never the ring on screen. */
    feedback=c; hwm_plane_border_tick(view,1);
    HWMBorderRing *rc=shown_ring(); assert(rc!=ra && rc!=rb);
    feedback=CGRectMake(100,500,320,200); hwm_plane_border_tick(view,1);
    HWMBorderRing *rd=shown_ring(); assert(rd!=rc && rd==rb); // a was shown after b.
    feedback=a; shapes=shape_calls; hwm_plane_border_tick(view,1);
    assert(shown_ring()==ra && shape_calls==shapes);
}

/* Within a frame, a border whose window leaves the screen goes in the same
 * transaction, by alpha, and comes back the same way. */
static void conceal(struct view *view)
{
    feedback=CGRectMake(100,100,400,300); hwm_plane_border_tick(view,1); assert(hwm_plane_border_visible);
    int outs=order_out_calls,ins=order_in_calls,hides=alpha_hides,shows=alpha_shows;
    focus.strip_no_border=true; hwm_plane_border_tick(view,1); focus.strip_no_border=false;
    assert(!hwm_plane_border_visible);
    if(alpha_supported) assert(order_out_calls==outs && alpha_hides==hides+S);
    else assert(order_out_calls==outs+S);
    hwm_plane_border_tick(view,1);
    assert(hwm_plane_border_visible);
    if(alpha_supported) assert(order_in_calls==ins && alpha_shows==shows+S);
    else assert(order_in_calls==ins+S);
}

/* Zooming changes the screen-space padding's share of the canvas on nearly
 * every frame. In motion, the cached outline is only transformed; the
 * redraw happens once the camera rests. */
static void zoom(struct view *view)
{
    feedback=CGRectMake(100,100,400,300); hwm_plane_border_tick(view,1);
    int shapes=shape_calls,transforms=transform_calls,windows=new_window_calls;
    HWMBorderRing *rested=shown_ring(); CGSize canvas=rested->canvas;
    test_moving=true;
    for(int i=1;i<=6;i++) {
        hwm_plane_scale=.5-.02*i; feedback.size=CGSizeMake(800*hwm_plane_scale,600*hwm_plane_scale);
        assert(hwm_plane_border_tick(view,1)); // A crisp redraw is still owed.
        assert(shape_calls==shapes && shown_ring()==rested && CGSizeEqualToSize(rested->canvas,canvas));
        assert(transform_calls==transforms+i*S && hwm_plane_border_visible);
    }
    test_moving=false;
    // The frame where motion stops lands every native frame; the redraw waits.
    assert(hwm_plane_border_tick(view,1.05) && shown_ring()==rested);
    assert(!hwm_plane_border_tick(view,1.2));
    // The crisp redraw at rest replaces the stretched ring with a new one.
    assert(shown_ring()!=rested && !CGSizeEqualToSize(shown_ring()->canvas,canvas) && new_window_calls==windows);
    shapes=shape_calls;
    assert(!hwm_plane_border_tick(view,1.2) && shape_calls==shapes);
    hwm_plane_scale=.5;
}

/* Off the frame thread, a paint in flight never holds a frame: the ring on
 * screen follows the new window, stretched, until the new one lands. */
static void async_paint(struct view *view)
{
    feedback=CGRectMake(100,100,400,300); hwm_plane_border_tick(view,1);
    HWMBorderRing *before=shown_ring();
    defer_paints=true;
    feedback=CGRectMake(600,100,500,350);
    assert(hwm_plane_border_tick(view,1)); // A crisp ring is owed.
    assert(deferred_paint && shown_ring()==before && hwm_plane_border_visible && hwm_plane_border_frame.origin.x==598);
    feedback.origin.x=610;
    assert(hwm_plane_border_tick(view,1) && shown_ring()==before && hwm_plane_border_frame.origin.x==608);
    int w=wakes; deferred_paint(NULL); deferred_paint=NULL; assert(wakes==w+1);
    assert(!hwm_plane_border_tick(view,1));
    assert(shown_ring()!=before && shown_ring()->canvas.width==1008 && hwm_plane_border_visible);
    defer_paints=false;
}

static void run(struct view *view,bool atomic)
{
    release_rings(); alpha_supported=atomic; hwm_plane_border_motion_seen=-10;
    transform_calls=order_out_calls=order_in_calls=shape_calls=0;
    retries(view); ring_cache(view); conceal(view); async_paint(view); zoom(view);
    assert(batch_depth==0);
}

int main(void)
{
    struct view view={0};
    hwm_feedback_focus_id=focus.id;
    run(&view,false);
    run(&view,true);
    // An alpha the helper refuses is a failed frame, retried by the next.
    feedback=CGRectMake(100,100,700,300); alpha_result=false; hwm_plane_border_motion_seen=-10;
    hwm_plane_border_tick(&view,1);
    assert(!hwm_plane_border_visible && CGRectIsNull(hwm_plane_border_frame));
    alpha_result=true; hwm_plane_border_tick(&view,1);
    assert(hwm_plane_border_visible);
    release_rings();
    puts("border ring cache, atomic swap, retry, zoom and pixel tests passed");
    return 0;
}
