/* Exercise the production native handoff with a deterministic AX boundary. */
#import <Cocoa/Cocoa.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <assert.h>
#define kAXEnhancedUserInterface CFSTR("AXEnhancedUserInterface")
struct application { pid_t pid; AXUIElementRef ref; };
struct area { double x,y,w,h; };
struct window_node { int window_count; uint32_t window_list[1]; struct window_node *next; struct area area; };
struct view { struct window_node *root; bool strip_scrolling; };
struct window {
    uint32_t id; struct application *application; AXUIElementRef ref;
    double strip_world_x,strip_world_y,strip_width,strip_height,strip_last_offset,strip_last_camera_y,strip_last_plane_scale,strip_start;
    double strip_from_width,strip_from_height,strip_size_sent_at;
    bool strip_initialized,strip_plane_scaled,strip_transform_dirty,strip_native_move_pending,strip_size_pending,strip_native_resize_pending,strip_offscreen;
    CGRect frame,strip_last_frame;
    CGPoint strip_server_moved; int strip_native_failures; bool strip_native_riding;
};
static struct { uint32_t focused_window_id; } g_window_manager={1};
static struct application app={.pid=123};
static struct window windows[2];
static struct window_node nodes[2];
static int g_connection;
static uint32_t hwm_drag_window,hwm_edge_window;
static bool hwm_zoom_workspace,hwm_plane_selecting,hwm_plane_fit_active;
static bool hwm_camera_animating,hwm_plane_y_scrolling;
static bool hwm_backend_ok=true;
static double job_clock;
static double hwm_now(void) { return job_clock; }
static double hwm_duration=.36;
static double hwm_rendered_offset;
static unsigned hwm_resize_operations;
static CGRect native[2],shown[2];
static CGPoint app_position[2];
static unsigned deferred_native_reads;
static bool ax_fail,display_disagrees,ax_clamp_top;
static _Atomic unsigned position_calls,size_calls;
static dispatch_queue_t hwm_ax_queue(void) { static dispatch_queue_t q;static dispatch_once_t once;dispatch_once(&once,^{q=dispatch_queue_create("native-zoom-test",DISPATCH_QUEUE_SERIAL);});return q; }
static void hwm_wake(void) {}
static bool shield;
static void hwm_zoom_shield_update(bool visible) { shield=visible; }
static void hwm_batch_begin_plane(void) {}
static void hwm_batch_end(void) {}
static bool hwm_batch_settle(void) { return true; }
static unsigned projections;
static bool scripting_addition_set_plane_transform_xy(uint32_t id,double x,double y,double sx,double sy) {
    ++projections;shown[id-1]=CGRectMake(x+(display_disagrees?80:0),y,native[id-1].size.width*sx,native[id-1].size.height*sy);return true;
}
static CGRect hwm_bounds(struct view *v) { (void)v;return CGRectMake(12,51,1200,900); }
static CGRect hwm_screen(struct view *v) { (void)v;return CGRectMake(0,0,1224,963); }
static double hwm_offset(struct view *v,double t) { (void)v;(void)t;return 0; }
static double hwm_plane_camera_y(double t) { (void)t;return 0; }
static struct window_node *window_node_find_first_leaf(struct window_node *n) { return n; }
static struct window_node *window_node_find_next_leaf(struct window_node *n) { return n->next; }
static struct window *window_manager_find_window(void *m,uint32_t id) { (void)m;return id>=1&&id<=2?&windows[id-1]:NULL; }
static bool hwm_workflow_tab_hidden(struct window *w) { (void)w;return false; }
static void hwm_visibility_prepare(struct view *v,double t) { (void)v;(void)t; }
static void hwm_visibility_set(struct window *w,bool hidden,CGRect f) { (void)f;w->strip_offscreen=hidden; }
static bool hwm_plane_reset_transform(struct window *w) { w->strip_plane_scaled=false;shown[w->id-1]=native[w->id-1];if(display_disagrees)shown[w->id-1].origin.x+=80;return true; }
static void hwm_plane_reset_transforms(struct window **list,int count) { for(int i=0;i<count;i++) (void)hwm_plane_reset_transform(list[i]); }
static CGError SLSGetWindowBounds(int c,uint32_t id,CGRect *out) {
    (void)c;
    if(deferred_native_reads && --deferred_native_reads==0)native[id-1].origin=app_position[id-1];
    *out=native[id-1];return 0;
}
static bool hwm_plane_displayed_frame(uint32_t id,CGRect *out) { *out=shown[id-1];return true; }
static void hwm_plane_displayed_frames(const uint32_t *ids,int count,CGRect *out,bool *found)
{ for(int i=0;i<count;i++) found[i]=hwm_plane_displayed_frame(ids[i],&out[i]); }
#define HWM_ZOOM_READ_BOUNDS
static void hwm_zoom_read_bounds(const uint32_t *ids,int count,CGRect *out,bool *found)
{ for(int i=0;i<count;i++) found[i]=SLSGetWindowBounds(0,ids[i],&out[i])==0; }
static unsigned server_moves;
static void hwm_batch_begin(void) {}
static bool scripting_addition_move_window(uint32_t id,double x,double y) { ++server_moves;native[id-1].origin=CGPointMake(x,y);return true; }
static bool hwm_resize_busy(struct window *w) { (void)w;return false; }
static unsigned indexFor(AXUIElementRef e) { int value=0;assert(CFNumberGetValue((CFNumberRef)e,kCFNumberIntType,&value));assert(value>=1&&value<=2);return (unsigned)value-1; }
static AXError mockTimeout(AXUIElementRef e,float t) { (void)e;assert(t<=.2f);return 0; }
static bool ax_enhanced_userinterface(AXUIElementRef e) { (void)e;return false; }
static AXError mockSet(AXUIElementRef e,CFStringRef attr,CFTypeRef value) {
    if(CFEqual(attr,kAXSizeAttribute)) {
        unsigned i=indexFor(e);CGSize size;assert(AXValueGetValue(value,kAXValueTypeCGSize,&size));
        assert(native[i].origin.x+size.width<=1224&&native[i].origin.y+size.height<=963);
        ++size_calls;native[i].size=size;shown[i].size=size;return 0;
    }
    assert(CFEqual(attr,kAXPositionAttribute));++position_calls;if(ax_fail)return kAXErrorCannotComplete;
    unsigned i=indexFor(e);CGPoint point;assert(AXValueGetValue(value,kAXValueTypeCGPoint,&point));
    if(ax_clamp_top && point.y<51)point.y=51;
    app_position[i]=point;
    if(!deferred_native_reads)native[i].origin=point;
    if(!windows[i].strip_plane_scaled) { shown[i]=native[i];if(display_disagrees)shown[i].origin.x+=80; }return 0;
}
static AXError mockCopy(AXUIElementRef e,CFStringRef attr,CFTypeRef *out) { assert(CFEqual(attr,kAXPositionAttribute));CGPoint point=app_position[indexFor(e)];*out=AXValueCreate(kAXValueTypeCGPoint,&point);return 0; }
#define AXUIElementSetMessagingTimeout mockTimeout
#define AXUIElementSetAttributeValue mockSet
#define AXUIElementCopyAttributeValue mockCopy
#include "../src/native_zoom.m"
#undef AXUIElementSetMessagingTimeout
#undef AXUIElementSetAttributeValue
#undef AXUIElementCopyAttributeValue

static struct view view={.root=nodes};
static void reset(void) {
    hwm_zoom_cancel_native();if(hwm_zoom_group)dispatch_group_wait(hwm_zoom_group,DISPATCH_TIME_FOREVER);[hwm_zoom_jobs removeAllObjects];
    [hwm_zoom_restore_sizes removeAllObjects];
    for(int i=0;i<2;i++) {
        if(windows[i].ref)CFRelease(windows[i].ref);
        int id=i+1;windows[i]=(struct window){.id=id,.application=&app,.strip_initialized=true,.strip_world_x=i*450,.strip_world_y=80,.strip_width=400,.strip_height=600,.strip_from_width=400,.strip_from_height=600,.strip_plane_scaled=true};
        windows[i].ref=(AXUIElementRef)CFNumberCreate(NULL,kCFNumberIntType,&id);
        native[i]=CGRectMake(100+i*50,100,400,600);app_position[i]=native[i].origin;shown[i]=CGRectMake(200,200,200,300);
        nodes[i]=(struct window_node){.window_count=1,.window_list={id},.next=i==0?&nodes[1]:NULL};
    }
    position_calls=0;size_calls=0;ax_fail=false;display_disagrees=false;ax_clamp_top=false;deferred_native_reads=0;job_clock=0;projections=0;
    hwm_zoom_workspace=false;hwm_plane_selecting=true;hwm_plane_fit_active=true;
    hwm_camera_animating=false;hwm_plane_y_scrolling=false;view.strip_scrolling=false;
}
static void drain(void) { assert(dispatch_group_wait(hwm_zoom_group,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0); }
static void test_handoff_waits_and_preserves_sizes(void) {
    reset();assert(hwm_zoom_render_native(&view,10));assert(!hwm_plane_selecting);
    assert(hwm_zoom_waiting_only); // Only placements in flight: they wake the clock themselves.
    drain();assert(!hwm_zoom_render_native(&view,11));assert(!hwm_plane_selecting);
    assert(!hwm_zoom_waiting_only);
    assert(position_calls==2&&size_calls==0);
    for(int i=0;i<2;i++) { assert(!windows[i].strip_plane_scaled&&!windows[i].strip_offscreen);assert(CGRectEqualToRect(native[i],shown[i]));assert(native[i].size.width==400&&native[i].size.height==600); }
    assert(!hwm_zoom_render_native(&view,12));assert(position_calls==2);
}
static void test_native_failure_does_not_block_input(void) {
    reset();assert(hwm_zoom_render_native(&view,10));drain();assert(!hwm_zoom_render_native(&view,11));
    ax_fail=true;windows[0].strip_world_x+=30;shield=true;
    assert(hwm_zoom_render_native(&view,12));assert(!shield);drain();
    shield=true;assert(!hwm_zoom_render_native(&view,13));
    assert(!shield&&!hwm_plane_selecting&&!windows[0].strip_offscreen&&!windows[1].strip_offscreen);
}
static void test_native_job_waits_for_appkit_and_server_agreement(void) {
    reset();windows[0].strip_plane_scaled=false;deferred_native_reads=3;
    CGRect accepted=CGRectNull;CGPoint target=CGPointMake(220,260);
    assert(hwm_zoom_native_position(&windows[0],target,CGSizeZero,CGPointZero,&accepted)==0);drain();
    assert(hwm_zoom_native_position(&windows[0],target,CGSizeZero,CGPointZero,&accepted)==1);
    assert(CGPointEqualToPoint(accepted.origin,target)&&deferred_native_reads==0);
}
static void test_failed_placement_recovers_without_blocking_other_apps(void) {
    reset();ax_fail=true;CGRect accepted;
    CGPoint point=CGPointMake(200,200);
    assert(hwm_zoom_native_position(&windows[0],point,CGSizeZero,CGPointZero,&accepted)==0);drain();
    assert(hwm_zoom_native_position(&windows[0],point,CGSizeZero,CGPointZero,&accepted)==-1);
    ax_fail=false;job_clock=.11;
    assert(hwm_zoom_native_position(&windows[0],point,CGSizeZero,CGPointZero,&accepted)==0);drain();
    assert(hwm_zoom_native_position(&windows[0],point,CGSizeZero,CGPointZero,&accepted)==1);
}
static void test_top_edge_clamp_keeps_the_window_visible(void) {
    reset();server_moves=0;windows[1].strip_world_y=-500;ax_clamp_top=true;
    assert(hwm_zoom_render_native(&view,10));drain();
    // AppKit keeps the title bar below the menu bar; WindowServer puts the
    // native frame where the window is drawn, once.
    assert(hwm_zoom_render_native(&view,11));
    assert(!hwm_zoom_waiting_only); // Nothing will wake the clock for this: keep drawing.
    assert(server_moves==1 && native[1].origin.y==-449 && windows[1].strip_plane_scaled && shown[1].origin.y==-449);
    assert(!hwm_zoom_render_native(&view,12));
    assert(!windows[1].strip_offscreen && !windows[1].strip_plane_scaled && shown[1].origin.y==-449);
    assert(!shield);unsigned writes=position_calls;
    assert(!hwm_zoom_render_native(&view,13));assert(position_calls==writes && server_moves==1);
}
static void test_pixel_rounding_does_not_restart_projection(void) {
    reset();assert(hwm_zoom_render_native(&view,10));drain();assert(!hwm_zoom_render_native(&view,11));
    native[0].origin.x+=.8;native[0].origin.y+=.8;shown[0]=native[0];
    unsigned count=projections;
    for(int i=0;i<8;i++)assert(!hwm_zoom_render_native(&view,12+i*.01));
    assert(projections==count&&!windows[0].strip_plane_scaled&&!shield);
}
static void test_cancelled_queue_never_issues_position(void) {
    reset();dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    dispatch_async(hwm_ax_queue(),^{dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);});
    CGRect accepted;assert(hwm_zoom_native_position(&windows[0],CGPointMake(200,200),CGSizeZero,CGPointMake(12,51),&accepted)==0);
    assert(hwm_zoom_native_busy(1));
    double waitStart=NSProcessInfo.processInfo.systemUptime;
    assert(!hwm_zoom_wait_native(1));
    assert(NSProcessInfo.processInfo.systemUptime-waitStart<.05);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{dispatch_semaphore_signal(gate);});
    double start=NSProcessInfo.processInfo.systemUptime;
    hwm_zoom_cancel_native();assert(NSProcessInfo.processInfo.systemUptime-start<.01);
    assert(hwm_zoom_native_busy(1));drain();assert(position_calls==0&&!hwm_zoom_native_busy(1));dispatch_release(gate);
}
static void test_slow_window_does_not_block_ready_window(void) {
    reset();CGRect accepted;
    assert(hwm_zoom_native_position(&windows[0],CGPointMake(12,131),CGSizeZero,CGPointZero,&accepted)==0);drain();
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    dispatch_async(hwm_ax_queue(),^{dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);});
    assert(hwm_zoom_render_native(&view,12));
    assert(!windows[0].strip_offscreen&&!hwm_plane_selecting&&!shield);
    hwm_zoom_cancel_native();dispatch_semaphore_signal(gate);drain();dispatch_release(gate);
}
static void test_native_camera_animation_keeps_input_live(void) {
    reset();assert(hwm_zoom_render_native(&view,10));drain();assert(!hwm_zoom_render_native(&view,11));
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    dispatch_async(hwm_ax_queue(),^{dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);});
    windows[0].strip_world_x+=30;hwm_camera_animating=true;
    CGRect before=shown[0];
    assert(hwm_zoom_render_native(&view,12));
    assert(!hwm_plane_selecting&&!windows[0].strip_offscreen);
    assert(shown[0].origin.x==before.origin.x+30); // One camera projection stays visible during placement.
    dispatch_semaphore_signal(gate);drain();
    hwm_camera_animating=false;assert(!hwm_zoom_render_native(&view,13));
    assert(shown[0].origin.x==before.origin.x+30&&!windows[0].strip_offscreen);
    dispatch_release(gate);
}
static void test_native_paint_lag_never_hides_or_reissues_placement(void) {
    reset();assert(hwm_zoom_render_native(&view,10));drain();assert(!hwm_zoom_render_native(&view,11));
    unsigned writes=position_calls;
    shown[0].origin.x-=9;
    for(int i=0;i<8;i++) {
        (void)hwm_zoom_render_native(&view,12+i*.008);
        assert(!windows[0].strip_offscreen&&!hwm_plane_selecting);
        assert(position_calls==writes);
    }
    shown[0]=native[0];assert(!hwm_zoom_render_native(&view,13));
    assert(position_calls==writes&&!windows[0].strip_offscreen);
}
static void test_zoom_never_resizes_an_app_changed_window(void) {
    reset();native[0].size=CGSizeMake(420,650);
    assert(hwm_zoom_render_native(&view,10));drain();assert(!hwm_zoom_render_native(&view,11));
    assert(size_calls==0&&windows[0].strip_width==420&&windows[0].strip_height==650);
}
static void test_saved_layout_size_is_restored_explicitly(void) {
    reset();native[0].size=CGSizeMake(420,650);
    windows[0].strip_size_pending=true;
    if(!hwm_zoom_restore_sizes)hwm_zoom_restore_sizes=[NSMutableSet new];
    [hwm_zoom_restore_sizes addObject:@1];
    assert(hwm_zoom_size_restoring(1));native[0].origin=CGPointMake(1100,800);
    assert(hwm_zoom_render_native(&view,10));drain();
    assert(!hwm_zoom_render_native(&view,11));
    assert(size_calls==1&&windows[0].strip_width==400&&native[0].size.width==400);
}
int main(void) { @autoreleasepool {
    test_handoff_waits_and_preserves_sizes();test_native_failure_does_not_block_input();
    test_native_job_waits_for_appkit_and_server_agreement();
    test_failed_placement_recovers_without_blocking_other_apps();
    test_top_edge_clamp_keeps_the_window_visible();
    test_pixel_rounding_does_not_restart_projection();
    test_cancelled_queue_never_issues_position();
    test_zoom_never_resizes_an_app_changed_window();
    test_saved_layout_size_is_restored_explicitly();
    test_slow_window_does_not_block_ready_window();
    test_native_camera_animation_keeps_input_live();
    test_native_paint_lag_never_hides_or_reissues_placement();
    hwm_zoom_cancel_native();puts("native zoom: native input, failure isolation, cancellation, and handoff passed");
    assert(hwm_zoom_native_diagnostics().count>0);
}return 0; }
