/* Click-through snap proposal. Moving one is a helper transform in the
 * windows' own packet, never a redraw. A new landing size or new seams are
 * painted off the frame thread into the one of two surfaces nobody sees: a
 * window-sized Retina paint waits for WindowServer to take it, and on the
 * frame thread that stalled the first frames of every drag beside a
 * neighbour. Until it lands, the surface on screen is stretched to the new
 * proposal, as it already is while the proposal springs into place. */
#include <stdatomic.h>
#ifndef HWM_PREVIEW_SCHEDULE
#define HWM_PREVIEW_SCHEDULE(work) dispatch_async_f(hwm_preview_queue(),NULL,work)
static dispatch_queue_t hwm_preview_queue(void)
{
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("dev.tana2d.preview",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0)); });
    return queue;
}
#endif
/* What a surface shows. Snap mode draws only docking seams; the held window
 * already sits at its landing, so tinting it would only muddy the
 * application's content. */
typedef struct {
    bool snap;
    HWMPlaneSnapSeam seams[HWM_PLANE_SNAP_SEAMS];
    size_t seam_count;
    double gutter,color[4];
} HWMPreviewContent;
typedef struct {
    uint32_t id;
    CGContextRef context;
    CGSize room,canvas;     // Surface size, and the proposal drawn at its top-left.
    HWMPreviewContent drawn;
    bool painted,ordered;
    unsigned scale_generation;
    double alpha_sent;
} HWMPreviewSurface;
typedef struct { int surface; CGSize canvas; HWMPreviewContent content; double scale; unsigned scale_generation; CGPoint origin; } HWMPreviewPaint;
static HWMPreviewSurface hwm_preview_surfaces[2]={{.alpha_sent=-1},{.alpha_sent=-1}};
static int hwm_preview_front=-1;
static HWMPreviewPaint hwm_preview_job;
static _Atomic int hwm_preview_painting=-1;
static _Atomic bool hwm_preview_painted;
static HWMPreviewSurface *hwm_preview_surface(void) { return &hwm_preview_surfaces[hwm_preview_front<0 ? 0 : hwm_preview_front]; }
#define hwm_preview_id (hwm_preview_surface()->id)
static bool hwm_preview_ordered;
static bool hwm_preview_snap_mode;
static HWMPlaneSnapSeam hwm_preview_seams[HWM_PLANE_SNAP_SEAMS];
static size_t hwm_preview_seam_count;
static double hwm_preview_gutter;
static _Atomic uint64_t hwm_preview_draws;
static uint64_t hwm_preview_moves;
static bool hwm_preview_busy(int s) { return atomic_load_explicit(&hwm_preview_painting,memory_order_acquire)==s; }
static void hwm_preview_order_out(HWMPreviewSurface *s)
{
    if(s->id && s->ordered) SLSOrderWindow(g_connection,s->id,0,0);
    s->ordered=false; s->alpha_sent=-1;
}
static void hwm_preview_hide(void)
{
    if(!hwm_preview_visible || hwm_preview_hiding) return;
    hwm_preview_alpha_from=hwm_preview_alpha;
    hwm_preview_alpha_start=hwm_now(); hwm_preview_hiding=true; hwm_wake();
}
static void hwm_preview_hide_immediately(void)
{
    hwm_preview_visible=false; hwm_preview_hiding=false; hwm_preview_alpha=0;
    // The surface being painted was never shown and is left to its painter.
    for(int i=0;i<2;i++) if(!hwm_preview_busy(i)) hwm_preview_order_out(&hwm_preview_surfaces[i]);
    hwm_preview_ordered=false;
}
/* A seam sits in the gutter between the two windows and spans exactly the
 * edge they share. A soft halo keeps it legible on light and dark content. */
static double hwm_preview_seam_width(double gutter) { return fmin(4,fmax(2.5,gutter*.45)); }
static double hwm_preview_margin(double gutter)
{
    return ceil(gutter*.5+(hwm_preview_seam_width(gutter)+6)*.5+1);
}
static void hwm_preview_stroke_seams(CGContextRef context,CGSize size,const HWMPlaneSnapSeam *seams,size_t count,double gutter,const double c[4])
{
    double margin=hwm_preview_margin(gutter),width=hwm_preview_seam_width(gutter);
    double inner_w=size.width-2*margin,inner_h=size.height-2*margin;
    CGContextSetLineCap(context,kCGLineCapRound);
    for(int pass=0;pass<2;pass++) {
        if(pass==0) { CGContextSetRGBStrokeColor(context,c[0],c[1],c[2],.28); CGContextSetLineWidth(context,width+6); }
        else { CGContextSetRGBStrokeColor(context,c[0],c[1],c[2],1); CGContextSetLineWidth(context,width); }
        for(size_t i=0;i<count;i++) {
            double length=seams[i].to-seams[i].from;
            if(!(length>0)) continue;
            double inset=fmin(8,length*.15),from=seams[i].from+inset,to=seams[i].to-inset;
            CGPoint a,b; // Seam spans are top-down; CGContext is bottom-up.
            if(seams[i].edge<2) {
                double x=seams[i].edge==0 ? margin+inner_w+gutter*.5 : margin-gutter*.5;
                a=CGPointMake(x,margin+inner_h-from); b=CGPointMake(x,margin+inner_h-to);
            } else {
                double y=seams[i].edge==2 ? margin-gutter*.5 : margin+inner_h+gutter*.5;
                a=CGPointMake(margin+from,y); b=CGPointMake(margin+to,y);
            }
            CGContextMoveToPoint(context,a.x,a.y); CGContextAddLineToPoint(context,b.x,b.y);
        }
        CGContextStrokePath(context);
    }
}
static void hwm_preview_draw_seams(CGContextRef context,CGSize size,const HWMPlaneSnapSeam *seams,size_t count,double gutter,bool full)
{
    (void)full; // Each paint is a whole surface the painter owns.
    CGContextClearRect(context,CGRectMake(0,0,size.width,size.height));
    hwm_preview_stroke_seams(context,size,seams,count,gutter,hwm_border_active);
}
static void hwm_preview_draw(CGContextRef context,CGSize size)
{
    CGRect local=CGRectMake(0,0,size.width,size.height);
    CGContextClearRect(context,local);
    CGFloat radius=fmin(10,fmin(size.width,size.height)*.25);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,2,2),radius,radius,NULL);
    CGContextSetRGBFillColor(context,.16,.48,1,.20);
    CGContextSetRGBStrokeColor(context,.22,.58,1,.95);
    CGContextSetLineWidth(context,2);
    CGContextAddPath(context,path); CGContextDrawPath(context,kCGPathFillStroke);
    CGPathRelease(path);
}
static HWMPreviewContent hwm_preview_wanted(void)
{
    HWMPreviewContent c={.snap=hwm_preview_snap_mode};
    if(c.snap) {
        c.seam_count=hwm_preview_seam_count; c.gutter=hwm_preview_gutter;
        memcpy(c.seams,hwm_preview_seams,sizeof(c.seams)); memcpy(c.color,hwm_border_active,sizeof(c.color));
    }
    return c;
}
static bool hwm_preview_same(const HWMPreviewContent *a,const HWMPreviewContent *b)
{
    if(a->snap!=b->snap) return false;
    if(!a->snap) return true;
    if(a->gutter!=b->gutter || a->seam_count!=b->seam_count || memcmp(a->color,b->color,sizeof(a->color))) return false;
    for(size_t i=0;i<a->seam_count;i++)
        if(a->seams[i].edge!=b->seams[i].edge || a->seams[i].from!=b->seams[i].from || a->seams[i].to!=b->seams[i].to) return false;
    return true;
}
static bool hwm_preview_fits(const HWMPreviewSurface *s,CGSize canvas,const HWMPreviewContent *content)
{
    return s->painted && s->id && s->scale_generation==hwm_surface_scale_generation &&
           CGSizeEqualToSize(s->canvas,canvas) && hwm_preview_same(&s->drawn,content);
}
/* Runs on the preview queue, on a surface nothing else touches meanwhile. */
static bool hwm_preview_paint(const HWMPreviewPaint *job)
{
    HWMPreviewSurface *s=&hwm_preview_surfaces[job->surface];
    s->painted=false;
    if(s->scale_generation!=job->scale_generation) {
        if(s->id) SLSSetWindowResolution(g_connection,s->id,job->scale);
        if(s->context) { CGContextRelease(s->context); s->context=NULL; }
        s->scale_generation=job->scale_generation;
    }
    CGSize canvas=job->canvas;
    // Spare room: the next proposal of a nearby size repaints in place.
    bool fits=s->id && s->context && canvas.width<=s->room.width && canvas.height<=s->room.height &&
              s->room.width<=canvas.width*1.5+64 && s->room.height<=canvas.height*1.5+64;
    CGSize room=fits ? s->room : CGSizeMake(ceil(canvas.width/64)*64,ceil(canvas.height/64)*64);
    if(!fits) {
        CGRect local=CGRectMake(0,0,room.width,room.height); CFTypeRef region=NULL;
        if(CGSNewRegionWithRect(&local,&region)!=kCGErrorSuccess || !region) return false;
        bool ok=true;
        if(!s->id) {
            uint64_t tags=(1ULL<<1)|(1ULL<<9); CFTypeRef empty=CGRegionCreateEmptyRegion();
            ok=empty && SLSNewWindowWithOpaqueShapeAndContext(g_connection,2,region,empty,13,&tags,job->origin.x,job->origin.y,64,&s->id,NULL)==kCGErrorSuccess && s->id;
            if(empty) CFRelease(empty);
            if(ok) {
                sls_window_disable_shadow(s->id);
                SLSSetWindowResolution(g_connection,s->id,job->scale);
                SLSSetWindowOpacity(g_connection,s->id,0);
                SLSSetWindowLevel(g_connection,s->id,3);
            } else s->id=0;
        }
        if(ok && !s->context) s->context=SLWindowContextCreate(g_connection,s->id,0);
        ok=ok && s->context && SLSSetWindowShape(g_connection,s->id,0,0,region)==kCGErrorSuccess &&
           SLSSetMouseEventEnableFlags(g_connection,s->id,false)==kCGErrorSuccess;
        CFRelease(region);
        if(!ok) { s->room=CGSizeZero; return false; }
        s->room=room;
    }
    // The proposal sits at the surface's top-left; the rest stays clear.
    CGContextRef context=s->context;
    CGContextSaveGState(context);
    CGContextClearRect(context,CGRectMake(0,0,room.width,room.height));
    CGContextTranslateCTM(context,0,room.height-canvas.height);
    if(job->content.snap) hwm_preview_stroke_seams(context,canvas,job->content.seams,job->content.seam_count,job->content.gutter,job->content.color);
    else hwm_preview_draw(context,canvas);
    CGContextRestoreGState(context);
    CGContextFlush(context);
    atomic_fetch_add(&hwm_preview_draws,1);
    s->canvas=canvas; s->drawn=job->content; s->painted=true;
    /* Ordered in now, at alpha 0, so showing it is only an alpha change in
     * the frame's own transaction. */
    if(!s->ordered) {
        SLSSetWindowAlpha(g_connection,s->id,0); s->alpha_sent=0;
        s->ordered=SLSOrderWindow(g_connection,s->id,1,0)==kCGErrorSuccess;
    }
    return true;
}
static void hwm_preview_paint_work(void *unused)
{
    (void)unused;
    hwm_preview_paint(&hwm_preview_job);
    atomic_store_explicit(&hwm_preview_painted,true,memory_order_release);
    hwm_wake();
}
static void hwm_preview_collect(void)
{
    if(atomic_load_explicit(&hwm_preview_painting,memory_order_acquire)<0 ||
       !atomic_load_explicit(&hwm_preview_painted,memory_order_acquire)) return;
    atomic_store_explicit(&hwm_preview_painted,false,memory_order_relaxed);
    atomic_store_explicit(&hwm_preview_painting,-1,memory_order_release);
}
static bool hwm_preview_request(int surface,CGSize canvas,const HWMPreviewContent *content,CGPoint origin)
{
    if(atomic_load_explicit(&hwm_preview_painting,memory_order_acquire)>=0) return false;
    hwm_preview_job=(HWMPreviewPaint){surface,canvas,*content,hwm_surface_scale,hwm_surface_scale_generation,origin};
    atomic_store_explicit(&hwm_preview_painted,false,memory_order_relaxed);
    atomic_store_explicit(&hwm_preview_painting,surface,memory_order_release);
    HWM_PREVIEW_SCHEDULE(hwm_preview_paint_work);
    return true;
}
/* Alpha joins the frame's transaction where the helper supports it. */
static bool hwm_preview_set_alpha(HWMPreviewSurface *s,double alpha)
{
    if(alpha==s->alpha_sent) return true;
    bool ok=scripting_addition_plane_alpha_supported() ? scripting_addition_set_opacity(s->id,(float)alpha,0) :
                                                       SLSSetWindowAlpha(g_connection,s->id,(float)alpha)==kCGErrorSuccess;
    if(ok) s->alpha_sent=alpha;
    return ok;
}
static bool hwm_preview_render(double now)
{
    hwm_preview_collect();
    if(!hwm_preview_visible) return false;
    double fade=hwm_motion_scale<=0?1:(now-hwm_preview_alpha_start)/.08;
    hwm_preview_alpha=hwm_preview_alpha_from+((hwm_preview_hiding?0:1)-hwm_preview_alpha_from)*horizontal_ease(fade);
    if(hwm_preview_hiding && fade>=1) { hwm_preview_hide_immediately(); return false; }
    double span=fmax(.001,.18*hwm_motion_scale),elapsed=now-hwm_preview_start;
    double progress=hstrip_spring_progress(elapsed,span);
    CGRect a=hwm_preview_from,b=hwm_preview_target;
    CGRect frame=CGRectMake(a.origin.x+(b.origin.x-a.origin.x)*progress,a.origin.y+(b.origin.y-a.origin.y)*progress,
                            a.size.width+(b.size.width-a.size.width)*progress,a.size.height+(b.size.height-a.size.height)*progress);
    bool active=elapsed<span || fade<1;
    if(!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
       frame.size.width<1 || frame.size.height<1 || frame.size.width>16384 || frame.size.height>16384) {
        hwm_preview_hide_immediately(); return false;
    }
    /* Rasterize once at the landing size; while the proposal grows into
     * place the drawn surface is stretched by the same helper transform
     * packet that moves the windows. */
    CGSize canvas=b.size;
    if(canvas.width<1 || canvas.height<1 || canvas.width>16384 || canvas.height>16384) canvas=frame.size;
    HWMPreviewContent wanted=hwm_preview_wanted();
    int front=hwm_preview_front>=0 && !hwm_preview_busy(hwm_preview_front) && hwm_preview_surfaces[hwm_preview_front].painted ? hwm_preview_front : -1;
    int other=front<0 ? 0 : 1-front;
    int target=front>=0 && hwm_preview_fits(&hwm_preview_surfaces[front],canvas,&wanted) ? front : -1;
    if(target<0 && !hwm_preview_busy(other) && hwm_preview_fits(&hwm_preview_surfaces[other],canvas,&wanted)) target=other;
    if(target<0 && hwm_preview_request(other,canvas,&wanted,frame.origin)) {
        hwm_preview_collect(); // Painted already, where painting runs in place.
        if(hwm_preview_fits(&hwm_preview_surfaces[other],canvas,&wanted)) target=other;
    }
    bool owed=target<0;
    if(owed) {
        // The new proposal is being painted; the old one follows meanwhile.
        if(front<0) return true;
        target=front;
    }
    HWMPreviewSurface *s=&hwm_preview_surfaces[target];
    if(target==hwm_preview_front && hwm_preview_ordered && CGRectEqualToRect(frame,hwm_preview_current)) {
        hwm_batch_begin_plane(); bool ok=hwm_preview_set_alpha(s,hwm_preview_alpha); hwm_batch_end();
        if(!ok || !hwm_backend_ok) { hwm_preview_hide_immediately(); hwm_preview_current=CGRectNull; return false; }
        return active || owed;
    }
    hwm_batch_begin_plane();
    bool ok=s->ordered || (SLSSetWindowAlpha(g_connection,s->id,0)==kCGErrorSuccess &&
                           (s->alpha_sent=0, s->ordered=SLSOrderWindow(g_connection,s->id,1,0)==kCGErrorSuccess));
    ok=ok && scripting_addition_set_plane_transform_xy(s->id,frame.origin.x,frame.origin.y,
                                                       frame.size.width/s->canvas.width,frame.size.height/s->canvas.height);
    if(ok) { ++hwm_preview_moves; ok=hwm_preview_set_alpha(s,hwm_preview_alpha); }
    // The surface it replaces goes in the same transaction.
    if(ok && hwm_preview_front>=0 && hwm_preview_front!=target) {
        HWMPreviewSurface *old=&hwm_preview_surfaces[hwm_preview_front];
        if(old->ordered && !hwm_preview_busy(hwm_preview_front)) ok=hwm_preview_set_alpha(old,0);
    }
    hwm_batch_end();
    hwm_preview_front=target;
    if(!ok || !hwm_backend_ok) { hwm_preview_hide_immediately(); hwm_preview_current=CGRectNull; return false; }
    hwm_preview_current=frame; hwm_preview_ordered=true;
    return active || owed;
}
static void hwm_preview_show(CGRect target,CGRect start,bool animate)
{
    hwm_preview_snap_mode=false;
    if(hwm_preview_visible && !hwm_preview_hiding && CGRectEqualToRect(target,hwm_preview_target)) return;
    double now=hwm_now();
    if(hwm_preview_visible && !hwm_preview_hiding && !animate) {
        hwm_preview_from=hwm_preview_target=target;
        hwm_preview_start=now-1; hwm_wake(); return;
    }
    hwm_preview_alpha_from=hwm_preview_visible?hwm_preview_alpha:0;
    hwm_preview_alpha_start=now; hwm_preview_hiding=false;
    hwm_preview_from=animate?(hwm_preview_visible?hwm_preview_current:start):target;
    if(!hwm_preview_visible) hwm_preview_current=CGRectNull;
    hwm_preview_target=target; hwm_preview_start=animate?now:now-1;
    hwm_preview_visible=true; hwm_wake();
}
/* frame is the docked window. The surface extends past it by the gutter so
 * each seam can sit between the two windows rather than over either. */
static void hwm_preview_snap_show(CGRect frame,const HWMPlaneSnapSeam *seams,size_t count,double gutter)
{
    if(!isfinite(gutter) || gutter<0) gutter=0;
    count=seams ? (count<HWM_PLANE_SNAP_SEAMS ? count : HWM_PLANE_SNAP_SEAMS) : 0;
    double margin=hwm_preview_margin(gutter);
    hwm_preview_show(CGRectInset(frame,-margin,-margin),frame,false);
    hwm_preview_snap_mode=true; hwm_preview_gutter=gutter; hwm_preview_seam_count=count;
    if(count) memcpy(hwm_preview_seams,seams,count*sizeof(*seams));
    // Present alongside the accepted pointer sample, without waiting a tick.
    hwm_preview_render(hwm_now());
}
