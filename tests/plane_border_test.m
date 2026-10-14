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
static double hwm_border_active[4]={1,1,1,1},hwm_border_active_end[4]={1,1,1,1};
static bool hwm_border_travel;
static volatile bool __pending_gesture;
static uint32_t hwm_drag_window,hwm_feedback_focus_id;
static uint32_t hwm_border_from_id;
static double hwm_border_travel_start;
static bool hwm_backend_ok=true;
static struct window focus={.id=7};
static CGRect feedback= { {100,100}, {400,300} };
static int transform_calls,batch_depth,order_out_calls;
static bool transform_result=true,batch_ack=true,batch_held;

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

static void hwm_batch_begin(void) { ++batch_depth; }
static void hwm_batch_end(void)
{
    assert(batch_depth>0); --batch_depth;
    if(!batch_depth && !batch_held && !batch_ack) hwm_backend_ok=false;
}
static bool scripting_addition_set_plane_transform_xy(uint32_t id,double x,double y,double sx,double sy)
{
    (void)id; (void)x; (void)y; (void)sx; (void)sy; ++transform_calls;
    return transform_result;
}

static CGError CGSNewRegionWithRect(CGRect *rect,CFTypeRef *region)
{ (void)rect; *region=CFRetain(kCFBooleanTrue); return kCGErrorSuccess; }
static CFTypeRef CGRegionCreateEmptyRegion(void) { return CFRetain(kCFBooleanTrue); }
static CGError SLSNewWindowWithOpaqueShapeAndContext(int connection,int type,CFTypeRef region,CFTypeRef empty,int options,uint64_t *tags,float x,float y,int tag_size,uint32_t *id,void *context)
{
    (void)connection; (void)type; (void)region; (void)empty; (void)options; (void)tags;
    (void)x; (void)y; (void)tag_size; (void)context; *id=77; return kCGErrorSuccess;
}
static void sls_window_disable_shadow(uint32_t id) { (void)id; }
static CGError SLSSetWindowOpacity(int connection,uint32_t id,bool opaque) { (void)connection; (void)id; (void)opaque; return kCGErrorSuccess; }
static CGError SLSSetWindowLevel(int connection,uint32_t id,int level) { (void)connection; (void)id; (void)level; return kCGErrorSuccess; }
static CGContextRef SLWindowContextCreate(int connection,uint32_t id,CFDictionaryRef options)
{ (void)connection; (void)id; (void)options; return NULL; }
static CGError SLSSetWindowShape(int connection,uint32_t id,float x,float y,CFTypeRef region)
{ (void)connection; (void)id; (void)x; (void)y; (void)region; return kCGErrorSuccess; }
static CGError SLSOrderWindow(int connection,uint32_t id,int mode,uint32_t relative)
{ (void)connection; (void)id; (void)relative; if(mode==0) ++order_out_calls; return kCGErrorSuccess; }
static CGError SLSSetMouseEventEnableFlags(int connection,uint32_t id,bool enabled)
{ (void)connection; (void)id; (void)enabled; return kCGErrorSuccess; }

#include "../src/plane_border.m"

/* This is the production batch-release contract proposed for strip_layout:
 * deferred acknowledgement failures invalidate the border cache after tick. */
static void hwm_batch_release(void)
{
    batch_held=false;
    if(!batch_ack) { hwm_backend_ok=false; hwm_plane_border_batch_failed(); }
}

int main(void)
{
    struct view view={0};
    hwm_feedback_focus_id=focus.id;

    hwm_plane_border_tick(&view,1);
    assert(transform_calls==1 && hwm_plane_border_visible);
    assert(hwm_plane_border_frame.origin.x==98);

    /* The helper rejects a title-bar drag update. A same-frame retry must not
     * be hidden by the cached requested position. */
    feedback.origin.x=200; transform_result=false;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==2 && CGRectIsNull(hwm_plane_border_frame));
    transform_result=true;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==3 && hwm_plane_border_frame.origin.x==198);

    /* A queued transform can be accepted locally but rejected when the batch
     * is acknowledged. That path must invalidate the cache too. */
    feedback.origin.x=300; batch_ack=false;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==4 && !hwm_backend_ok && CGRectIsNull(hwm_plane_border_frame));
    hwm_backend_ok=true; batch_ack=true;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==5 && hwm_plane_border_frame.origin.x==298);

    /* The manager normally holds a frame-wide batch. Its acknowledgement comes
     * after border_tick, so release must invalidate this already-cached frame. */
    feedback.origin.x=400; batch_held=true; batch_ack=false;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==6 && hwm_plane_border_frame.origin.x==398);
    hwm_batch_release();
    assert(!hwm_backend_ok && hwm_plane_border_visible && CGRectIsNull(hwm_plane_border_frame));
    hwm_plane_border_hide();
    assert(order_out_calls==1 && !hwm_plane_border_visible);
    hwm_backend_ok=true; batch_ack=true;
    hwm_plane_border_tick(&view,1);
    assert(transform_calls==7 && hwm_plane_border_frame.origin.x==398);
    return 0;
}
