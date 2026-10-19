/* A cached native outline moves in the same presentation batch as its window.
 * Translation never redraws pixels or waits for an AppKit/main-queue snapshot.
 *
 * A ring is four thin surfaces, one per edge band (top and bottom span the
 * full width and carry the corners). A single window-sized Retina surface
 * cost ~25 ms to reshape and repaint plus as long again for WindowServer to
 * take it, on every focus change; the bands are a few percent of that area.
 *
 * Several rings are kept, each drawn for one size. Focus moving back to a
 * size already drawn (two windows of a column width, say) shows that ring
 * without painting anything. A new size is painted off the frame thread,
 * into a ring nobody sees: finishing a paint waits for WindowServer to take
 * the surface, 15-80 ms while windows are moving, and doing that on the frame
 * thread dropped frames on every focus change, worst when hover moved focus
 * across many windows. Until the paint lands, the ring on screen is
 * stretched to the new window, exactly as it is through a zoom.
 *
 * With a helper that sets alpha in its transaction, every ring stays ordered
 * in and a swap is alpha changes in the frame's own transaction: nothing
 * suspends screen updates or waits for the helper's reply. Older helpers
 * order rings in and out with updates suspended. */
// CGSWindow.h documents this separately from the ignore-events tag. Reapply
// after each shape change so the whole transparent canvas stays mouse-inert.
extern CGError SLSSetMouseEventEnableFlags(int,uint32_t,bool);
#include <stdatomic.h>
enum { HWM_BORDER_STRIPS=4, HWM_BORDER_RINGS=3 };
#ifdef HWM_PROF_BORDER_PAINT_ENABLED
#define HWM_BORDER_PROF(...) __VA_ARGS__
#else
#define HWM_BORDER_PROF(...)
#endif
/* Paints run one at a time on this queue; tests run them in place. */
#ifndef HWM_BORDER_SCHEDULE
#define HWM_BORDER_SCHEDULE(work) dispatch_async_f(hwm_border_queue(),NULL,work)
static dispatch_queue_t hwm_border_queue(void)
{
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("dev.tana2d.border",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0)); });
    return queue;
}
#endif
typedef struct {
    uint32_t ids[HWM_BORDER_STRIPS];
    CGContextRef contexts[HWM_BORDER_STRIPS];
    /* Each strip surface keeps some spare room, so a ring drawn for a window
     * of a different size repaints in place instead of reshaping four
     * surfaces. The strip's pixels sit at the surface's top-left; the rest
     * stays clear. */
    CGSize capacity[HWM_BORDER_STRIPS];
    CGRect strips[HWM_BORDER_STRIPS]; // Canvas rects, top-down.
    int count;                        // Strips the drawn ring uses; 0 until drawn.
    CGSize canvas; double k;          // What it was drawn for.
    unsigned generation,scale_generation;
    uint32_t drawn_for;
    bool ordered;                     // In the window list (at alpha 0 unless shown).
    double used;
} HWMBorderRing;
/* Everything a paint needs, copied on the frame thread: the painter reads no
 * other shared state, and touches only the ring it was given. */
typedef struct {
    int ring;
    CGSize canvas; double k,pad,width,radius,scale;
    CGFloat colors[8];
    unsigned generation,scale_generation;
    CGPoint origin;
} HWMBorderPaint;
static HWMBorderRing hwm_border_rings[HWM_BORDER_RINGS];
static HWMBorderPaint hwm_border_paint_job;
static _Atomic int hwm_border_painting=-1; // The ring the painter owns, or -1.
static _Atomic bool hwm_border_painted;    // It has finished with that ring.
static _Atomic bool hwm_border_paint_ok;   // And drew it.
/* The last paint failed: the next frame retries, but a failure alone does not
 * keep the frame clock running. */
static bool hwm_border_paint_failed;
static int hwm_border_shown=-1; // The ring on screen, or the last one to be.
static unsigned hwm_border_uses;
static uint32_t hwm_plane_border_focus;
static double hwm_plane_border_motion_seen=-10;
static CGRect hwm_plane_border_frame;
static bool hwm_plane_border_visible;
static CGSize hwm_plane_border_room(CGSize needed,CGSize have)
{
    bool fits=needed.width<=have.width && needed.height<=have.height &&
              have.width<=needed.width*2+64 && have.height<=needed.height*2+64;
    return fits ? have : CGSizeMake(ceil(needed.width/64)*64,ceil(needed.height/64)*64);
}
static HWMBorderRing *hwm_plane_border_ring(void) { return &hwm_border_rings[hwm_border_shown<0 ? 0 : hwm_border_shown]; }
// Strip 0 of the current ring stands for the outline in hit tests and diagnostics.
#define hwm_plane_border_id (hwm_plane_border_ring()->ids[0])
static bool hwm_plane_border_owns(uint32_t id)
{
    for(int r=0;r<HWM_BORDER_RINGS;r++) for(int i=0;i<HWM_BORDER_STRIPS;i++) if(id && hwm_border_rings[r].ids[i]==id) return true;
    return false;
}
/* Backing scale for the outline and preview surfaces. Set on the main thread
 * when the frame clock starts; a 1x surface looks soft beside Retina windows. */
#ifndef HWM_SURFACE_SCALE_DEFINED
#define HWM_SURFACE_SCALE_DEFINED
static double hwm_surface_scale=1;
static inline double hwm_pixel(double v) { return round(v*hwm_surface_scale)/hwm_surface_scale; }
#endif
/* The outline sits on the same device-pixel grid as the windows it rings. */
static CGRect hwm_pixel_rect(CGRect r)
{
    double x0=hwm_pixel(CGRectGetMinX(r)),y0=hwm_pixel(CGRectGetMinY(r)),x1=hwm_pixel(CGRectGetMaxX(r)),y1=hwm_pixel(CGRectGetMaxY(r));
    return CGRectMake(x0,y0,x1-x0,y1-y0);
}
static unsigned hwm_surface_scale_generation;
/* A surface made at another backing scale gets the new one and a fresh
 * context, then redraws. Returns true when the caller must redraw. */
static bool hwm_surface_rescale(uint32_t id,CGContextRef *context,unsigned *generation)
{
    if(*generation==hwm_surface_scale_generation) return false;
    *generation=hwm_surface_scale_generation;
    if(!id) return false;
    SLSSetWindowResolution(g_connection,id,hwm_surface_scale);
    if(*context) { CGContextRelease(*context); *context=NULL; }
    return true;
}
/* Whether rings swap by alpha inside the helper's transaction. */
static bool hwm_plane_border_atomic(void) { return scripting_addition_plane_alpha_supported(); }
/* The painter's ring, which nothing else touches until it is collected. */
static bool hwm_plane_border_busy(int r) { return atomic_load_explicit(&hwm_border_painting,memory_order_acquire)==r; }
static void hwm_plane_border_order_out(HWMBorderRing *ring)
{
    if(ring->ordered) for(int i=0;i<HWM_BORDER_STRIPS;i++)
        if(ring->ids[i]) SLSOrderWindow(g_connection,ring->ids[i],0,0);
    ring->ordered=false;
}
static void hwm_plane_border_hide(void);
/* The outer frame batch can reject a transform after this file has returned.
 * strip_layout calls this hook at that acknowledgement boundary. Which alphas
 * landed is unknown, so every ring leaves the screen and is shown afresh.
 * The ring being painted was never shown and is left to its painter. */
static void hwm_plane_border_batch_failed(void)
{
    for(int r=0;r<HWM_BORDER_RINGS;r++) if(!hwm_plane_border_busy(r)) hwm_plane_border_order_out(&hwm_border_rings[r]);
    hwm_plane_border_visible=false;
    hwm_plane_border_frame=CGRectNull;
    hwm_plane_border_focus=0;
}
static void hwm_plane_border_hide(void)
{
    if(hwm_plane_border_visible) for(int r=0;r<HWM_BORDER_RINGS;r++)
        if(!hwm_plane_border_busy(r)) hwm_plane_border_order_out(&hwm_border_rings[r]);
    hwm_plane_border_visible=false;
}
/* Within a frame: the outline leaves in the same transaction as whatever made
 * it go (its window panning off screen, say), and stays ordered in. */
static void hwm_plane_border_conceal(void)
{
    if(!hwm_plane_border_visible) return;
    HWMBorderRing *ring=hwm_plane_border_ring();
    if(!hwm_plane_border_atomic() || !ring->ordered) { hwm_plane_border_hide(); return; }
    bool ok=true;
    hwm_batch_begin_plane();
    for(int i=0;i<ring->count;i++) ok=scripting_addition_set_opacity(ring->ids[i],0,0) && ok;
    hwm_batch_end();
    hwm_plane_border_visible=false;
    if(!ok || !hwm_backend_ok) hwm_plane_border_batch_failed();
}
/* Place every strip for a ring shown at `frame`, stretched from its canvas. */
static bool hwm_plane_border_place(HWMBorderRing *ring,CGRect frame)
{
    double sx=frame.size.width/ring->canvas.width,sy=frame.size.height/ring->canvas.height; bool ok=true;
    for(int i=0;i<ring->count;i++) {
        CGRect r=ring->strips[i];
        ok=scripting_addition_set_plane_transform_xy(ring->ids[i],hwm_pixel(frame.origin.x+r.origin.x*sx),
                                                     hwm_pixel(frame.origin.y+r.origin.y*sy),sx,sy) && ok;
    }
    return ok;
}
/* A drawn ring that can go on screen as it is. */
static bool hwm_plane_border_drawn(const HWMBorderRing *ring)
{
    bool drawn=ring->count>0;
    for(int i=0;i<ring->count;i++) drawn=drawn && ring->ids[i];
    return drawn;
}
/* Paint the ring for job->canvas into its ring, which is not on screen. The
 * canvas is in world units and is scaled down by the zoom; k is canvas units
 * per screen point, so the stroke keeps its on-screen width at every zoom.
 * Runs on the border queue. */
static bool hwm_plane_border_paint(const HWMBorderPaint *job)
{
    HWMBorderRing *ring=&hwm_border_rings[job->ring];
    CGSize canvas=job->canvas; double k=job->k,pad=job->pad;
    if(ring->scale_generation!=job->scale_generation) {
        for(int i=0;i<HWM_BORDER_STRIPS;i++) {
            if(ring->ids[i]) SLSSetWindowResolution(g_connection,ring->ids[i],job->scale);
            if(ring->contexts[i]) { CGContextRelease(ring->contexts[i]); ring->contexts[i]=NULL; }
        }
        ring->scale_generation=job->scale_generation;
    }
    int previous=ring->count;
    ring->count=0; // Not a usable ring until every strip is drawn.
    double band=ceil(pad*k+job->radius+2);
    int count=1; CGRect strips[HWM_BORDER_STRIPS]={{{0,0},canvas}};
    if(2*band<canvas.width && 2*band<canvas.height) {
        strips[0]=CGRectMake(0,0,canvas.width,band);
        strips[1]=CGRectMake(0,canvas.height-band,canvas.width,band);
        strips[2]=CGRectMake(0,band,band,canvas.height-2*band);
        strips[3]=CGRectMake(canvas.width-band,band,band,canvas.height-2*band);
        count=4;
    }
    // A ring that changes its strips is ordered in afresh, all of it, when shown.
    if(count!=previous) hwm_plane_border_order_out(ring);
    HWM_BORDER_PROF(double paint_start=0; double paint_ms=0; double shape_start=hwm_now());
    CGRect local=CGRectMake(0,0,canvas.width,canvas.height);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,pad*.5*k,pad*.5*k),job->radius,job->radius,NULL);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient=CGGradientCreateWithColorComponents(space,job->colors,NULL,2);
    bool drawable=true;
    for(int i=0;i<count && drawable;i++) {
        CGRect strip=strips[i];
        uint32_t *id=&ring->ids[i]; CGContextRef *context=&ring->contexts[i];
        CGSize room=*id && *context ? hwm_plane_border_room(strip.size,ring->capacity[i]) : hwm_plane_border_room(strip.size,CGSizeZero);
        bool reshape=!*id || !*context || !CGSizeEqualToSize(room,ring->capacity[i]);
        CGRect size=CGRectMake(0,0,room.width,room.height); CFTypeRef region=NULL;
        if(reshape && (CGSNewRegionWithRect(&size,&region)!=kCGErrorSuccess || !region)) { drawable=false; break; }
        if(!*id) {
            uint64_t tags=(1ULL<<1)|(1ULL<<9); CFTypeRef empty=CGRegionCreateEmptyRegion();
            if(!empty || SLSNewWindowWithOpaqueShapeAndContext(g_connection,2,region,empty,13,&tags,job->origin.x,job->origin.y,64,id,NULL)!=kCGErrorSuccess || !*id) {
                *id=0; drawable=false;
            } else {
                sls_window_disable_shadow(*id);
                SLSSetWindowResolution(g_connection,*id,job->scale);
                SLSSetWindowOpacity(g_connection,*id,0);
                SLSSetWindowLevel(g_connection,*id,3);
                ring->ordered=false; // Ordered in, with the rest, when shown.
            }
            if(empty) CFRelease(empty);
        }
        if(drawable && !*context) *context=SLWindowContextCreate(g_connection,*id,0);
        if(drawable && !*context) drawable=false;
        if(drawable && reshape) {
            if(SLSSetWindowShape(g_connection,*id,0,0,region)!=kCGErrorSuccess) drawable=false;
            else { SLSSetMouseEventEnableFlags(g_connection,*id,false); ring->capacity[i]=room; }
        }
        if(region) CFRelease(region);
        if(!drawable) { ring->capacity[i]=CGSizeZero; break; }
        HWM_BORDER_PROF(if((hwm_now()-shape_start)*1000>hwm_prof[HWM_PROF_BORDER_SHAPE]) hwm_prof[HWM_PROF_BORDER_SHAPE]=(hwm_now()-shape_start)*1000);
        /* One transparency layer per strip: its clear and gradient reach
         * the backing store in a single synchronization. The full ring
         * path is drawn shifted so this strip's slice lands in its own
         * bottom-up surface. */
        HWM_BORDER_PROF(paint_start=hwm_now());
        CGContextSaveGState(*context);
        CGContextSetBlendMode(*context,kCGBlendModeCopy);
        CGContextBeginTransparencyLayerWithRect(*context,size,NULL);
        CGContextClearRect(*context,size);
        CGContextTranslateCTM(*context,-strip.origin.x,(room.height-strip.size.height)-(canvas.height-strip.origin.y-strip.size.height));
        CGContextAddPath(*context,path);
        CGContextSetLineWidth(*context,job->width*k);
        CGContextReplacePathWithStrokedPath(*context);
        CGContextClip(*context);
        CGContextDrawLinearGradient(*context,gradient,CGPointZero,CGPointMake(canvas.width,canvas.height),0);
        CGContextEndTransparencyLayer(*context);
        CGContextRestoreGState(*context); CGContextFlush(*context);
        HWM_BORDER_PROF(paint_ms+=(hwm_now()-paint_start)*1000);
    }
    HWM_BORDER_PROF(if(paint_ms>hwm_prof[HWM_PROF_BORDER_PAINT]) hwm_prof[HWM_PROF_BORDER_PAINT]=paint_ms);
    CGGradientRelease(gradient); CGColorSpaceRelease(space); CGPathRelease(path);
    if(!drawable) return false;
    memcpy(ring->strips,strips,sizeof(strips)); ring->count=count;
    ring->canvas=canvas; ring->k=k; ring->generation=job->generation;
    return true;
}
static void hwm_plane_border_paint_work(void *unused)
{
    (void)unused;
    bool ok=hwm_plane_border_paint(&hwm_border_paint_job);
    /* Swapping by alpha needs the ring ordered in. Done here, at alpha 0, it
     * shows nothing and keeps those WindowServer round trips off frames. */
    HWMBorderRing *ring=&hwm_border_rings[hwm_border_paint_job.ring];
    if(ok && hwm_plane_border_atomic() && !ring->ordered) {
        for(int i=0;i<ring->count;i++) {
            SLSSetWindowAlpha(g_connection,ring->ids[i],0);
            ok=SLSOrderWindow(g_connection,ring->ids[i],1,0)==kCGErrorSuccess && ok;
        }
        ring->ordered=ok;
    }
    atomic_store_explicit(&hwm_border_paint_ok,ok,memory_order_relaxed);
    atomic_store_explicit(&hwm_border_painted,true,memory_order_release);
    hwm_wake();
}
/* Collect a finished paint: its ring is the frame thread's again. */
static void hwm_plane_border_collect(void)
{
    if(atomic_load_explicit(&hwm_border_painting,memory_order_acquire)<0 ||
       !atomic_load_explicit(&hwm_border_painted,memory_order_acquire)) return;
    hwm_border_paint_failed=!atomic_load_explicit(&hwm_border_paint_ok,memory_order_relaxed);
    atomic_store_explicit(&hwm_border_painted,false,memory_order_relaxed);
    atomic_store_explicit(&hwm_border_painting,-1,memory_order_release);
}
/* Bring `ring` on screen at `frame`, replacing whatever ring was shown. */
static bool hwm_plane_border_swap(HWMBorderRing *ring,CGRect frame)
{
    HWMBorderRing *old=hwm_plane_border_visible && hwm_border_shown>=0 ? &hwm_border_rings[hwm_border_shown] : NULL;
    if(old==ring) old=NULL;
    bool atomic=hwm_plane_border_atomic(),ok=true;
    if(!atomic) {
        // Suspend updates: the order-in and the transform must land together.
        hwm_batch_begin();
        ok=hwm_plane_border_place(ring,frame);
        if(ok) for(int i=0;i<ring->count;i++) ok=SLSOrderWindow(g_connection,ring->ids[i],1,0)==kCGErrorSuccess && ok;
        ring->ordered=true;
        if(old) hwm_plane_border_order_out(old);
        hwm_batch_end();
        return ok;
    }
    /* An ordered-out ring comes in at alpha 0, which shows nothing; it then
     * appears in the transaction that places it. */
    if(!ring->ordered) {
        for(int i=0;i<ring->count;i++) {
            SLSSetWindowAlpha(g_connection,ring->ids[i],0);
            ok=SLSOrderWindow(g_connection,ring->ids[i],1,0)==kCGErrorSuccess && ok;
        }
        ring->ordered=true;
        if(!ok) return false;
    }
    hwm_batch_begin_plane();
    ok=hwm_plane_border_place(ring,frame);
    for(int i=0;i<ring->count;i++) ok=scripting_addition_set_opacity(ring->ids[i],1,0) && ok;
    if(old && old->ordered) for(int i=0;i<old->count;i++) ok=scripting_addition_set_opacity(old->ids[i],0,0) && ok;
    hwm_batch_end();
    return ok;
}
static bool hwm_plane_border_fits(const HWMBorderRing *ring,CGSize canvas,double k)
{
    return hwm_plane_border_drawn(ring) && ring->generation==hwm_border_generation &&
           ring->scale_generation==hwm_surface_scale_generation &&
           CGSizeEqualToSize(ring->canvas,canvas) && fabs(ring->k-k)<1e-3;
}
/* A ring already drawn for this size, or NULL. */
static HWMBorderRing *hwm_plane_border_find(CGSize canvas,double k)
{
    for(int r=0;r<HWM_BORDER_RINGS;r++)
        if(!hwm_plane_border_busy(r) && hwm_plane_border_fits(&hwm_border_rings[r],canvas,k)) return &hwm_border_rings[r];
    return NULL;
}
/* Start painting this size into a ring nobody sees: an empty slot first,
 * then the least recently shown. Never the ring on screen, nor the one just
 * replaced, whose alpha change may still be on its way. False while the
 * painter is busy with another size. */
static bool hwm_plane_border_request(CGSize canvas,double k,double pad,CGPoint origin)
{
    if(atomic_load_explicit(&hwm_border_painting,memory_order_acquire)>=0) return false;
    int current=hwm_plane_border_visible ? hwm_border_shown : -1, spare=-1;
    for(int r=0;r<HWM_BORDER_RINGS;r++) {
        HWMBorderRing *ring=&hwm_border_rings[r];
        if(r==current) continue;
        if(spare<0 || (hwm_border_rings[spare].count && (!ring->count || ring->used<hwm_border_rings[spare].used))) spare=r;
    }
    HWMBorderPaint *job=&hwm_border_paint_job;
    *job=(HWMBorderPaint){.ring=spare,.canvas=canvas,.k=k,.pad=pad,.width=hwm_border_width,.radius=hwm_border_radius,
                          .scale=hwm_surface_scale,.generation=hwm_border_generation,
                          .scale_generation=hwm_surface_scale_generation,.origin=origin};
    for(int i=0;i<4;i++) { job->colors[i]=hwm_border_active[i]; job->colors[i+4]=hwm_border_active_end[i]; }
    atomic_store_explicit(&hwm_border_painted,false,memory_order_relaxed);
    atomic_store_explicit(&hwm_border_painting,spare,memory_order_release);
    HWM_BORDER_SCHEDULE(hwm_plane_border_paint_work);
    return true;
}
/* Returns true while the outline on screen is only stretched to fit, or a
 * paint is in flight: a crisp ring is still owed. */
static bool hwm_plane_border_tick(struct view *view,double now)
{
    hwm_plane_border_collect();
    if(hwm_paused || hwm_suspended || hwm_overview_active || hwm_border_mode==0) { hwm_plane_border_hide(); return false; }
    struct window *focus=window_manager_find_window(&g_window_manager,hwm_drag_window?hwm_drag_window:hwm_feedback_focus_id);
    if(!focus || focus->strip_no_border) { hwm_plane_border_conceal(); return false; }
    CGRect screen=hwm_screen(view),frame=hwm_feedback_frame(view,focus,screen);
    if(CGRectIsNull(frame)) { hwm_plane_border_conceal(); return false; }
    CGRect landing=frame; // Where a travelling outline comes to rest.
    bool travelling=false;
    if(!hwm_drag_window && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) && hwm_border_travel) {
        double span=hwm_border_travel_span(),elapsed=now-hwm_border_travel_start;
        if(elapsed<span && hwm_border_from_id!=focus->id) {
            CGRect from=hwm_feedback_frame(view,window_manager_find_window(&g_window_manager,hwm_border_from_id),screen);
            if(!CGRectIsNull(from)) {
                double p=hstrip_spring_progress(elapsed,span); travelling=true;
                frame=CGRectMake(from.origin.x+(frame.origin.x-from.origin.x)*p,from.origin.y+(frame.origin.y-from.origin.y)*p,
                                 from.size.width+(frame.size.width-from.size.width)*p,from.size.height+(frame.size.height-from.size.height)*p);
            }
        }
    }
    double pad=fmax(2,hwm_border_width);
    frame=hwm_pixel_rect(CGRectInset(frame,-pad,-pad));
    landing=hwm_pixel_rect(CGRectInset(landing,-pad,-pad));
    if(frame.size.width>16384 || frame.size.height>16384) { hwm_plane_border_conceal(); return false; }
    // Rasterize at the window's stable world size. Camera zoom and focus
    // travel transform this cached outline instead of reallocating a surface
    // and synchronously flushing a new gradient on every display frame.
    /* A travelling outline is drawn once, at its landing size, when it sets
     * off. Its stretch then shrinks to nothing as it arrives, instead of the
     * departing window's outline stretching all the way and popping crisp. */
    CGSize canvas=CGSizeMake(ceil(fmax(1,landing.size.width/hwm_plane_scale)),ceil(fmax(1,landing.size.height/hwm_plane_scale)));
    if(!view_find_window_node(view,focus->id)) canvas=landing.size;
    double k=landing.size.width>0 ? canvas.width/landing.size.width : 1;
    HWMBorderRing *shown=hwm_border_shown>=0 && !hwm_plane_border_busy(hwm_border_shown) ? &hwm_border_rings[hwm_border_shown] : NULL;
    if(shown && !hwm_plane_border_drawn(shown)) shown=NULL;
    /* The padding is in screen points, so the canvas changes on nearly every
     * zoom frame. In motion, stretch the cached outline and redraw once at
     * rest rather than painting a ring per frame. */
    bool moving=travelling || hwm_view_in_motion(view,now) || now-hwm_zoom_pinch_time<.15;
    /* Native placement after a gesture: keep the stretched outline briefly
     * while windows land, and up to half a second while native frames do. */
    if(moving) hwm_plane_border_motion_seen=now;
    double still=now-hwm_plane_border_motion_seen;
    bool settling=moving || still<.1 || (hwm_zoom_landing && still<.5);
    HWMBorderRing *ring=shown && hwm_plane_border_fits(shown,canvas,k) ? shown : NULL;
    bool owed=false;
    // A travelling outline wants its landing ring; a zoom waits until rest.
    if(!ring && !(shown && settling && !(travelling && shown->drawn_for!=focus->id))) {
        ring=hwm_plane_border_find(canvas,k);
        if(!ring) {
            if(hwm_plane_border_request(canvas,k,pad,frame.origin)) hwm_plane_border_collect(); // Done already, if painted in place.
            ring=hwm_plane_border_find(canvas,k);
        }
    }
    if(!ring) {
        owed=!hwm_border_paint_failed;
        // Nothing drawn yet to stretch: the outline appears once painted.
        if(!shown) return owed;
        ring=shown;
    }
    if(ring!=shown || hwm_plane_border_fits(ring,canvas,k)) ring->drawn_for=focus->id;
    if(ring==shown && hwm_plane_border_visible && hwm_plane_border_focus==focus->id && CGRectEqualToRect(frame,hwm_plane_border_frame)) return owed;
    bool ok;
    if(ring==shown && hwm_plane_border_visible) {
        hwm_batch_begin_plane(); ok=hwm_plane_border_place(ring,frame); hwm_batch_end();
    } else ok=hwm_plane_border_swap(ring,frame);
    hwm_border_shown=(int)(ring-hwm_border_rings); ring->used=++hwm_border_uses;
    // A queued helper command is not a displayed outline until the batch is
    // acknowledged. Do not cache a requested frame on either failure path:
    // otherwise the equality fast path suppresses every later retry.
    if(!ok || !hwm_backend_ok) { hwm_plane_border_batch_failed(); return false; }
    hwm_plane_border_visible=true; hwm_plane_border_frame=frame; hwm_plane_border_focus=focus->id;
    return owed;
}

/* The held-drag path only translates an existing cached outline. Its command
 * joins the same atomic helper packet as the window, without global suppression. */
static bool hwm_plane_border_drag(uint32_t wid,CGRect projected)
{
    if(!hwm_plane_border_visible || hwm_plane_border_focus!=wid || hwm_border_mode==0) return true;
    HWMBorderRing *ring=hwm_plane_border_ring();
    if(!ring->count) return true;
    double pad=fmax(2,hwm_border_width);
    CGRect frame=hwm_pixel_rect(CGRectInset(projected,-pad,-pad));
    if(CGRectEqualToRect(frame,hwm_plane_border_frame)) return true;
    bool ok=hwm_plane_border_place(ring,frame);
    if(ok) hwm_plane_border_frame=frame;
    return ok;
}
static void hwm_plane_border_drag_failed(void) { hwm_plane_border_batch_failed(); }
