/* Reuse one click-through surface. Moving a snap proposal updates its origin,
 * never its paths, backing store, or pixels. Only size/style changes redraw. */
static CGSize hwm_preview_canvas;
static bool hwm_preview_ordered;
/* Snap mode draws only docking seams; the held window already sits at its
 * landing, so tinting it would only muddy the application's content. */
static bool hwm_preview_snap_mode,hwm_preview_drawn_snap;
static HWMPlaneSnapSeam hwm_preview_seams[HWM_PLANE_SNAP_SEAMS],hwm_preview_drawn_seams[HWM_PLANE_SNAP_SEAMS];
static size_t hwm_preview_seam_count,hwm_preview_drawn_seam_count;
static double hwm_preview_gutter,hwm_preview_drawn_gutter,hwm_preview_drawn_color[4];
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
/* A seam sits in the gutter between the two windows and spans exactly the
 * edge they share. A soft halo keeps it legible on light and dark content. */
static double hwm_preview_seam_width(double gutter) { return fmin(4,fmax(2.5,gutter*.45)); }
static double hwm_preview_margin(double gutter)
{
    return ceil(gutter*.5+(hwm_preview_seam_width(gutter)+6)*.5+1);
}
static void hwm_preview_draw_seams(CGContextRef context,CGSize size,const HWMPlaneSnapSeam *seams,size_t count,double gutter)
{
    CGContextClearRect(context,CGRectMake(0,0,size.width,size.height));
    double margin=hwm_preview_margin(gutter),width=hwm_preview_seam_width(gutter);
    double inner_w=size.width-2*margin,inner_h=size.height-2*margin;
    const double *c=hwm_border_active;
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
static bool hwm_preview_content_changed(void)
{
    if(hwm_preview_drawn_snap!=hwm_preview_snap_mode) return true;
    if(!hwm_preview_snap_mode) return false;
    if(hwm_preview_drawn_gutter!=hwm_preview_gutter || hwm_preview_drawn_seam_count!=hwm_preview_seam_count ||
       memcmp(hwm_preview_drawn_color,hwm_border_active,sizeof(hwm_preview_drawn_color))) return true;
    for(size_t i=0;i<hwm_preview_seam_count;i++) {
        HWMPlaneSnapSeam a=hwm_preview_drawn_seams[i],b=hwm_preview_seams[i];
        if(a.edge!=b.edge || a.from!=b.from || a.to!=b.to) return true;
    }
    return false;
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
    bool redraw=!hwm_preview_context || !CGSizeEqualToSize(frame.size,hwm_preview_canvas) || hwm_preview_content_changed();
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
                if(hwm_preview_snap_mode) hwm_preview_draw_seams(hwm_preview_context,frame.size,hwm_preview_seams,hwm_preview_seam_count,hwm_preview_gutter);
                else hwm_preview_draw(hwm_preview_context,frame.size);
                CGContextFlush(hwm_preview_context); ++hwm_preview_draws;
                hwm_preview_canvas=frame.size; hwm_preview_drawn_snap=hwm_preview_snap_mode;
                hwm_preview_drawn_gutter=hwm_preview_gutter; hwm_preview_drawn_seam_count=hwm_preview_seam_count;
                memcpy(hwm_preview_drawn_seams,hwm_preview_seams,sizeof(hwm_preview_seams));
                memcpy(hwm_preview_drawn_color,hwm_border_active,sizeof(hwm_preview_drawn_color));
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
