/* A cached native outline moves in the same presentation batch as its window.
 * Translation never redraws pixels or waits for an AppKit/main-queue snapshot. */
static uint32_t hwm_plane_border_id;
static CGContextRef hwm_plane_border_context;
static CGRect hwm_plane_border_frame;
static bool hwm_plane_border_visible;
static void hwm_plane_border_hide(void)
{
    if(hwm_plane_border_id && hwm_plane_border_visible) SLSOrderWindow(g_connection,hwm_plane_border_id,0,0);
    hwm_plane_border_visible=false;
}
static void hwm_plane_border_tick(struct view *view,double now)
{
    if(hwm_paused || hwm_suspended || hwm_overview_active || hwm_border_mode==0) { hwm_plane_border_hide(); return; }
    struct window *focus=window_manager_find_window(&g_window_manager,hwm_drag_window?hwm_drag_window:hwm_feedback_focus_id);
    if(!focus || focus->strip_no_border) { hwm_plane_border_hide(); return; }
    CGRect screen=hwm_screen(view),frame=hwm_feedback_frame(view,focus,screen);
    if(CGRectIsNull(frame)) { hwm_plane_border_hide(); return; }
    if(!hwm_drag_window && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) && hwm_border_travel) {
        double span=hwm_border_travel_span(),elapsed=now-hwm_border_travel_start;
        if(elapsed<span && hwm_border_from_id!=focus->id) {
            CGRect from=hwm_feedback_frame(view,window_manager_find_window(&g_window_manager,hwm_border_from_id),screen);
            if(!CGRectIsNull(from)) {
                double p=hstrip_spring_progress(elapsed,span);
                frame=CGRectMake(from.origin.x+(frame.origin.x-from.origin.x)*p,from.origin.y+(frame.origin.y-from.origin.y)*p,
                                 from.size.width+(frame.size.width-from.size.width)*p,from.size.height+(frame.size.height-from.size.height)*p);
            }
        }
    }
    double pad=fmax(2,hwm_border_width);
    frame=CGRectIntegral(CGRectInset(frame,-pad,-pad));
    if(frame.size.width>16384 || frame.size.height>16384) { hwm_plane_border_hide(); return; }
    bool reshape=CGRectIsNull(hwm_plane_border_frame) || !CGSizeEqualToSize(frame.size,hwm_plane_border_frame.size);
    hwm_batch_begin();
    if(reshape || !hwm_plane_border_id) {
        CGRect local=CGRectMake(0,0,frame.size.width,frame.size.height); CFTypeRef region=NULL;
        CGSNewRegionWithRect(&local,&region);
        if(!hwm_plane_border_id) {
            uint64_t tags=(1ULL<<1)|(1ULL<<9); CFTypeRef empty=CGRegionCreateEmptyRegion();
            SLSNewWindowWithOpaqueShapeAndContext(g_connection,2,region,empty,13,&tags,frame.origin.x,frame.origin.y,64,&hwm_plane_border_id,NULL);
            CFRelease(empty);
            sls_window_disable_shadow(hwm_plane_border_id);
            SLSSetWindowOpacity(g_connection,hwm_plane_border_id,0);
            SLSSetWindowLevel(g_connection,hwm_plane_border_id,3);
            hwm_plane_border_context=SLWindowContextCreate(g_connection,hwm_plane_border_id,0);
        }
        SLSSetWindowShape(g_connection,hwm_plane_border_id,0,0,region);
        CFRelease(region);
        if(hwm_plane_border_context) {
            CGContextClearRect(hwm_plane_border_context,local);
            CGRect outline=CGRectInset(local,pad*.5,pad*.5);
            CGPathRef path=CGPathCreateWithRoundedRect(outline,hwm_border_radius,hwm_border_radius,NULL);
            CGContextSaveGState(hwm_plane_border_context);
            CGContextAddPath(hwm_plane_border_context,path);
            CGContextSetLineWidth(hwm_plane_border_context,hwm_border_width);
            CGContextReplacePathWithStrokedPath(hwm_plane_border_context);
            CGContextClip(hwm_plane_border_context);
            CGFloat colors[8]; for(int i=0;i<4;i++) { colors[i]=hwm_border_active[i]; colors[i+4]=hwm_border_active_end[i]; }
            CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
            CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,NULL,2);
            CGContextDrawLinearGradient(hwm_plane_border_context,gradient,CGPointZero,CGPointMake(local.size.width,local.size.height),0);
            CGGradientRelease(gradient); CGColorSpaceRelease(space); CGPathRelease(path);
            CGContextRestoreGState(hwm_plane_border_context); CGContextFlush(hwm_plane_border_context);
        }
    }
    if(hwm_plane_border_id) {
        scripting_addition_move_window(hwm_plane_border_id,frame.origin.x,frame.origin.y);
        if(!hwm_plane_border_visible) SLSOrderWindow(g_connection,hwm_plane_border_id,1,0);
        hwm_plane_border_visible=true; hwm_plane_border_frame=frame;
    }
    hwm_batch_end();
}
