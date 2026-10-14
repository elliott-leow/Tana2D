/* A cached native outline moves in the same presentation batch as its window.
 * Translation never redraws pixels or waits for an AppKit/main-queue snapshot. */
// CGSWindow.h documents this separately from the ignore-events tag. Reapply
// after each shape change so the whole transparent canvas stays mouse-inert.
extern CGError SLSSetMouseEventEnableFlags(int,uint32_t,bool);
static uint32_t hwm_plane_border_id,hwm_plane_border_focus;
static CGContextRef hwm_plane_border_context;
static CGRect hwm_plane_border_frame;
static CGSize hwm_plane_border_canvas;
static unsigned hwm_plane_border_generation;
static bool hwm_plane_border_visible;
/* The outer frame batch can reject a transform after this file has returned.
 * strip_layout calls this hook at that acknowledgement boundary. */
static void hwm_plane_border_batch_failed(void)
{
    hwm_plane_border_frame=CGRectNull;
}
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
    // Rasterize at the window's stable world size. Camera zoom and focus
    // travel transform this cached outline instead of reallocating a surface
    // and synchronously flushing a new gradient on every display frame.
    CGSize canvas=CGSizeMake(ceil(fmax(1,frame.size.width/hwm_plane_scale)),ceil(fmax(1,frame.size.height/hwm_plane_scale)));
    if(!view_find_window_node(view,focus->id)) canvas=frame.size;
    bool reshape=!CGSizeEqualToSize(canvas,hwm_plane_border_canvas);
    bool redraw=reshape || hwm_plane_border_generation!=hwm_border_generation;
    if(!redraw && hwm_plane_border_visible && hwm_plane_border_focus==focus->id && CGRectEqualToRect(frame,hwm_plane_border_frame)) return;
    hwm_batch_begin();
    if(redraw || !hwm_plane_border_id) {
        CGRect local=CGRectMake(0,0,canvas.width,canvas.height); CFTypeRef region=NULL;
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
        SLSSetMouseEventEnableFlags(g_connection,hwm_plane_border_id,false);
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
        hwm_plane_border_canvas=canvas;
        hwm_plane_border_generation=hwm_border_generation;
    }
    bool transformed=false;
    if(hwm_plane_border_id) {
        transformed=scripting_addition_set_plane_transform_xy(hwm_plane_border_id,frame.origin.x,frame.origin.y,
                                                               frame.size.width/canvas.width,frame.size.height/canvas.height);
        if(transformed && !hwm_plane_border_visible) SLSOrderWindow(g_connection,hwm_plane_border_id,1,0);
    }
    hwm_batch_end();
    // A queued helper command is not a displayed outline until the batch is
    // acknowledged. Do not cache a requested frame on either failure path:
    // otherwise the equality fast path suppresses every later retry.
    if(!transformed || !hwm_backend_ok) { hwm_plane_border_batch_failed(); return; }
    hwm_plane_border_visible=true; hwm_plane_border_frame=frame; hwm_plane_border_focus=focus->id;
}

/* The held-drag path only translates an existing cached outline. Its command
 * joins the same atomic helper packet as the window, without global suppression. */
static bool hwm_plane_border_drag(uint32_t wid,CGRect projected)
{
    if(!hwm_plane_border_visible || hwm_plane_border_focus!=wid || !hwm_plane_border_id || hwm_border_mode==0) return true;
    double pad=fmax(2,hwm_border_width);
    CGRect frame=CGRectIntegral(CGRectInset(projected,-pad,-pad));
    if(CGRectEqualToRect(frame,hwm_plane_border_frame)) return true;
    bool ok=scripting_addition_set_plane_transform_xy(hwm_plane_border_id,frame.origin.x,frame.origin.y,
        frame.size.width/hwm_plane_border_canvas.width,frame.size.height/hwm_plane_border_canvas.height);
    if(ok) hwm_plane_border_frame=frame;
    return ok;
}
static void hwm_plane_border_drag_failed(void) { hwm_plane_border_batch_failed(); }
