/* Reuse one click-through surface. Moving a snap proposal updates its origin,
 * never its paths, backing store, or pixels. Only size/style changes redraw. */
static CGSize hwm_preview_canvas;
static bool hwm_preview_ordered;
static int hwm_preview_snap_edge=-1,hwm_preview_drawn_edge=-2;
static uint64_t hwm_preview_draws,hwm_preview_moves;
static double hwm_preview_sent_alpha=-1;
static void hwm_preview_apply_alpha(void)
{
    if(hwm_preview_alpha!=hwm_preview_sent_alpha &&
       SLSSetWindowAlpha(g_connection,hwm_preview_id,hwm_preview_alpha)==kCGErrorSuccess)
        hwm_preview_sent_alpha=hwm_preview_alpha;
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
    if(hwm_preview_id && hwm_preview_ordered) SLSOrderWindow(g_connection,hwm_preview_id,0,0);
    hwm_preview_ordered=false;
}
static void hwm_preview_draw(CGContextRef context,CGSize size,int edge)
{
    CGRect local=CGRectMake(0,0,size.width,size.height);
    CGContextClearRect(context,local);
    CGFloat radius=fmin(10,fmin(size.width,size.height)*.25);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,2,2),radius,radius,NULL);
    CGContextSetRGBFillColor(context,.16,.48,1,edge>=0?.09:.20);
    CGContextSetRGBStrokeColor(context,.22,.58,1,.95);
    CGContextSetLineWidth(context,2);
    CGContextAddPath(context,path); CGContextDrawPath(context,kCGPathFillStroke);
    CGPathRelease(path);
    if(edge>=0) {
        /* Bright seam on the side facing the neighbor. Geometry, not color
         * alone, shows which edge docks; the outline shows the full landing. */
        double inset=fmin(12,fmin(size.width,size.height)*.2);
        CGPoint a,b;
        if(edge<2) {
            double x=edge==0?size.width-3:3;
            a=CGPointMake(x,inset); b=CGPointMake(x,size.height-inset);
        } else {
            double y=edge==2?3:size.height-3; // CGContext is bottom-up.
            a=CGPointMake(inset,y); b=CGPointMake(size.width-inset,y);
        }
        CGContextSetRGBStrokeColor(context,.32,.72,1,1);
        CGContextSetLineWidth(context,5); CGContextSetLineCap(context,kCGLineCapRound);
        CGContextMoveToPoint(context,a.x,a.y); CGContextAddLineToPoint(context,b.x,b.y);
        CGContextStrokePath(context);
    }
}
static bool hwm_preview_render(double now)
{
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
    bool redraw=!hwm_preview_context || !CGSizeEqualToSize(frame.size,hwm_preview_canvas) || hwm_preview_drawn_edge!=hwm_preview_snap_edge;
    if(!redraw && hwm_preview_ordered && CGRectEqualToRect(frame,hwm_preview_current)) {
        hwm_preview_apply_alpha();
        return active;
    }
    hwm_batch_begin();
    bool ok=true;
    if(redraw) {
        CGRect local=CGRectMake(0,0,frame.size.width,frame.size.height); CFTypeRef region=NULL;
        ok=CGSNewRegionWithRect(&local,&region)==kCGErrorSuccess && region;
        if(ok && !hwm_preview_id) {
            uint64_t tags=(1ULL<<1)|(1ULL<<9); CFTypeRef empty=CGRegionCreateEmptyRegion();
            ok=empty && SLSNewWindowWithOpaqueShapeAndContext(g_connection,2,region,empty,13,&tags,frame.origin.x,frame.origin.y,64,&hwm_preview_id,NULL)==kCGErrorSuccess && hwm_preview_id;
            if(empty) CFRelease(empty);
            if(ok) {
                sls_window_disable_shadow(hwm_preview_id);
                SLSSetWindowResolution(g_connection,hwm_preview_id,1);
                SLSSetWindowOpacity(g_connection,hwm_preview_id,0);
                SLSSetWindowLevel(g_connection,hwm_preview_id,3);
            } else hwm_preview_id=0;
        }
        if(ok && !hwm_preview_context) hwm_preview_context=SLWindowContextCreate(g_connection,hwm_preview_id,0);
        ok=ok && hwm_preview_context && SLSSetWindowShape(g_connection,hwm_preview_id,0,0,region)==kCGErrorSuccess;
        if(region) CFRelease(region);
        if(ok) {
            ok=SLSSetMouseEventEnableFlags(g_connection,hwm_preview_id,false)==kCGErrorSuccess;
            if(ok) {
                hwm_preview_draw(hwm_preview_context,frame.size,hwm_preview_snap_edge);
                CGContextFlush(hwm_preview_context); ++hwm_preview_draws;
                hwm_preview_canvas=frame.size; hwm_preview_drawn_edge=hwm_preview_snap_edge;
            }
        }
    }
    if(ok) ok=SLSMoveWindow(g_connection,hwm_preview_id,&frame.origin)==kCGErrorSuccess;
    if(ok) {
        ++hwm_preview_moves;
        hwm_preview_apply_alpha();
        if(!hwm_preview_ordered) ok=SLSOrderWindow(g_connection,hwm_preview_id,1,0)==kCGErrorSuccess;
    }
    hwm_batch_end();
    if(!ok) { hwm_preview_hide_immediately(); hwm_preview_current=CGRectNull; return false; }
    hwm_preview_current=frame; hwm_preview_ordered=true;
    return active;
}
static void hwm_preview_show(CGRect target,CGRect start,bool animate)
{
    hwm_preview_snap_edge=-1;
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
static void hwm_preview_snap_show(CGRect frame,int edge)
{
    hwm_preview_show(frame,frame,false);
    hwm_preview_snap_edge=edge;
    // Present alongside the accepted pointer sample, without waiting a tick.
    hwm_preview_render(hwm_now());
}
