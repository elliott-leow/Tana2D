/* Exercise the production layout/renderer with deterministic OS boundaries.
 * No Accessibility permission, real windows, or running daemon are needed. */
#import <Cocoa/Cocoa.h>
#pragma clang diagnostic ignored "-Wunused-function"
#include <assert.h>
#include <stdio.h>
#include "../src/strip_columns.h"

#define VIEW_STRIP 1
#define VIEW_IS_DIRTY 1
#define LAYER_AUTO 0
#define LAYER_BELOW -1
#define LAYER_NORMAL 0
#define MOUSE_MODE_MOVE 1
#define MOUSE_MODE_RESIZE 2
#define HANDLE_LEFT 1
#define HANDLE_RIGHT 2
#define HANDLE_TOP 4
#define HANDLE_BOTTOM 8
#define WINDOW_MINIMIZE 1
#define WINDOW_FULLSCREEN 2
#define WINDOW_FLOAT 4
#define table_for(declaration,table,body) for(int slot=0;slot<4;slot++) { declaration=&windows[slot]; body; }
#define AX_ENHANCED_UI_WORKAROUND(ref, body) do { (void)(ref); body; } while(0)
struct area { double x,y,w,h; };
struct application { int ref; bool is_hidden; pid_t pid; };
struct window {
    uint32_t id; struct application *application;
    CGRect frame,strip_last_frame;
    uint64_t strip_column;
    double strip_min_width;
    double strip_weight,strip_width,strip_height,strip_world_x,strip_world_y;
    double strip_from_x,strip_from_y,strip_from_width,strip_from_height;
    double strip_vel_x,strip_vel_y,strip_vel_width,strip_vel_height;
    double strip_start,strip_last_offset,strip_last_camera_y,strip_last_plane_scale,strip_size_sent_at;
    double strip_native_resize_until;
    unsigned int strip_native_resize_events;
    bool strip_size_confirmed,strip_native_resize_pending,strip_transform_dirty;
    bool strip_initialized,strip_placed,strip_full_width,strip_size_pending,strip_tab_parked,strip_offscreen;
    int layer;
    bool floating,strip_float_animating,strip_close_pending;
    CGRect strip_float_from,strip_float_last,strip_float_target;
    double strip_float_start,strip_close_start;
    float strip_close_alpha;
    double strip_pop_start; int strip_pop; bool strip_pop_scaled,strip_close_scaled,strip_plane_scaled,strip_close_ghost;
    int strip_shelf; double strip_last_shift; float strip_rule_alpha;
};
struct window_node { int window_count; uint32_t window_list[1]; struct window_node *next; struct area area; };
struct view { int layout,window_gap; struct window_node *root; double strip_offset; bool strip_scrolling; };
static struct { int unused; } g_window_manager;
static struct { struct window *window; CGPoint down_location; CGRect window_frame; int current_action,direction; } g_mouse_state;
static int g_connection;
static bool hwm_ready=true,hwm_paused,hwm_overview_active,hwm_state_pending,hwm_backend_ok=true;
static bool __pending_gesture;
static uint32_t hwm_drag_window,hwm_close_source,hwm_feedback_focus_id;
static double hwm_duration=.24,hwm_close_time,hwm_last_input;
static double hwm_plane_scale=1;
static bool hwm_plane_y_scrolling,hwm_plane_fit_active,hwm_camera_animating;
static double test_camera_y;
static double hwm_plane_camera_y(double now) { (void)now; return test_camera_y; }
static uint64_t hwm_move_failures,hwm_resize_operations;
static struct window windows[4];
static struct window_node nodes[4];
static struct application application;
static struct view view;
static struct view *hwm_view(void) { return &view; }
static CGRect actual[4],projected[4];
static double test_scales[4];
static double clock_now=10;
static int ax_calls,moves,disable_calls,update_depth;
static bool move_fails,clamp_native_sizes;
static float alphas[4];
static int close_calls;
static double hwm_now(void) { return clock_now; }
static double horizontal_ease(double p) { return hstrip_ease(p); }
static void hwm_wake(void) {}
static CGRect hwm_bounds(struct view *v) { (void)v; return CGRectMake(12,51,1200,900); }
static CGRect hwm_screen(struct view *v) { (void)v; return CGRectMake(0,0,1224,963); }
static double hwm_offset(struct view *v,double now) { (void)now; return v->strip_offset; }
static void hwm_scroll(struct view *v,double x,bool animate) { (void)animate; v->strip_offset=x; }
static struct window_node *window_node_find_first_leaf(struct window_node *n) { return n; }
static struct window_node *window_node_find_next_leaf(struct window_node *n) { return n->next; }
static struct window *window_manager_find_window(void *manager,uint32_t id) { (void)manager; return id>=1 && id<=4 ? &windows[id-1] : NULL; }
static struct view *window_manager_find_managed_window(void *manager,struct window *w) { (void)manager; return w->floating?NULL:&view; }
static bool window_check_flag(struct window *w,int flag) { (void)w; (void)flag; return false; }
static CGError SLSGetWindowAlpha(int connection,uint32_t id,float *alpha) { (void)connection; *alpha=alphas[id-1]; return kCGErrorSuccess; }
static double fade_duration[4];
static bool scripting_addition_set_opacity(uint32_t id,float alpha,double duration) { fade_duration[id-1]=duration; alphas[id-1]=alpha; return true; }
static int scale_calls;
static bool scripting_addition_scale_window(uint32_t id,float x,float y,float w,float h) { (void)id; (void)x; (void)y; (void)w; (void)h; ++scale_calls; return true; }
static bool scripting_addition_set_plane_transform(uint32_t id,double x,double y,double scale) {
    ++scale_calls; if(move_fails) return false;
    if(!isfinite(x)) x=actual[id-1].origin.x;
    if(!isfinite(y)) y=actual[id-1].origin.y;
    test_scales[id-1]=scale;
    projected[id-1]=CGRectMake(x,y,actual[id-1].size.width*scale,actual[id-1].size.height*scale);
    return true;
}
static bool window_manager_close_window(struct window *w) { (void)w; ++close_calls; return false; }
static struct window_node *view_find_window_node(struct view *v,uint32_t id) { for(struct window_node *n=v->root;n;n=n->next) if(n->window_list[0]==id) return n; return NULL; }
static void view_clear_flag(struct view *v,int flag) { (void)v; (void)flag; }
static CGError SLSGetWindowBounds(int connection,uint32_t id,CGRect *frame) { (void)connection; *frame=actual[id-1]; return kCGErrorSuccess; }
static void SLSGetCurrentCursorLocation(int connection,CGPoint *point) { (void)connection; *point=CGPointZero; }
static void SLSDisableUpdate(int connection) { (void)connection; assert(update_depth==0); ++update_depth; ++disable_calls; }
static void SLSReenableUpdate(int connection) { (void)connection; assert(update_depth==1); --update_depth; }
static bool scripting_addition_set_layer(uint32_t id,int layer) { (void)id; (void)layer; return true; }
static int sa_batch_depth, sa_batch_flushes;
static void scripting_addition_batch_begin(void) { ++sa_batch_depth; }
static bool scripting_addition_batch_flush(void) { ++sa_batch_flushes; return true; }
static bool scripting_addition_batch_end(void) { assert(sa_batch_depth>0); --sa_batch_depth; return true; }
static bool scripting_addition_move_window(uint32_t id,double x,double y) { ++moves; if(move_fails) return false; actual[id-1].origin=CGPointMake(x,y); return true; }
static void window_manager_set_window_frame(struct window *w,double x,double y,double width,double height) { ++ax_calls; actual[w->id-1]=CGRectMake(x,y,width,height); }
static void window_manager_resize_window(struct window *w,double width,double height) {
    ++ax_calls;
    if(clamp_native_sizes) { width=fmin(width,1224-actual[w->id-1].origin.x); height=fmin(height,963-actual[w->id-1].origin.y); }
    actual[w->id-1].size=CGSizeMake(width,height);
    projected[w->id-1].size=CGSizeMake(width*test_scales[w->id-1],height*test_scales[w->id-1]);
}
static void hwm_column_width(struct view *v,struct window *w,double width) { (void)v; w->strip_width=width; }
static uint32_t hidden_tab;
static __attribute__((unused)) bool hwm_workflow_tab_geometry(struct view *v,struct window *w,double *y,double *height) { (void)v; (void)w; (void)y; (void)height; return false; }
static bool hwm_workflow_tab_hidden(struct window *w) { return w->id==hidden_tab; }
static void hwm_resize_submit(struct window *w,CGRect f,bool full) { (void)full; window_manager_resize_window(w,f.size.width,f.size.height); }
static bool resize_busy;
static bool hwm_resize_busy(struct window *w) { (void)w; return resize_busy; }
static void hwm_close_submit(struct window *w) { window_manager_close_window(w); }
static bool hwm_window_left_strip(struct window *w) { (void)w; return false; }
#include "../src/strip_layout.m"
static bool hwm_borders_external;
static CGError SLSGetWindowOwner(int connection,uint32_t wid,int *owner) { (void)connection; (void)wid; *owner=1; return kCGErrorSuccess; }
static CGError SLSConnectionGetPID(int owner,pid_t *pid) { (void)owner; *pid=application.pid; return kCGErrorSuccess; }
static CFArrayRef SLSCopyAssociatedWindows(int connection,uint32_t wid) { (void)connection; (void)wid; return NULL; }
static CFArrayRef test_border_list(CGWindowListOption option,CGWindowID wid) {
    (void)option; (void)wid;
    CFDictionaryRef bounds=CGRectCreateDictionaryRepresentation(actual[3]);
    NSArray *list=@[@{(id)kCGWindowOwnerName:@"borders",(id)kCGWindowNumber:@4,
                     (id)kCGWindowOwnerPID:@(application.pid),(id)kCGWindowBounds:(id)bounds}];
    CFRelease(bounds); return (CFArrayRef)[list copy];
}
#define CGWindowListCopyWindowInfo test_border_list
#include "../src/strip_visibility.m"
#undef CGWindowListCopyWindowInfo
static int undo_captures;
static void hwm_undo_capture(void) { ++undo_captures; }
static void hwm_hold_focus(void) {}
static CGPoint hwm_drag_world_origin,hwm_drag_pointer_origin,hwm_drag_point,hwm_drag_move;
static double hwm_drag_camera_x,hwm_drag_camera_y,hwm_drag_scale;
static bool hwm_drag_shadow,hwm_drag_move_pending,hwm_drag_cancelled;
static uint64_t hwm_prof_drag_events;
static uint32_t hwm_plane_pick_window;
static CGPoint hwm_plane_pick_origin;
static void scripting_addition_set_shadow(uint32_t id,bool shadow) { (void)id; (void)shadow; }
static void hwm_drag_started(struct window *w) {
    hwm_drag_window=w->id; hwm_undo_capture();
    hwm_drag_world_origin=CGPointMake(w->strip_world_x,w->strip_world_y);
    hwm_drag_camera_x=view.strip_offset; hwm_drag_camera_y=test_camera_y; hwm_drag_scale=hwm_plane_scale;
}
#include "../src/strip_interaction.m"
#include "../src/strip_renderer.m"
#include "../src/window_transitions.m"
static double hwm_drag_snap_x,hwm_drag_snap_y,hwm_drag_snap_time,hwm_motion_scale=1;
static uint32_t hwm_drag_snap_neighbor;
static bool hwm_drag_finishing;
static struct window *hwm_tile(uint32_t id) { return window_manager_find_window(&g_window_manager,id); }
#include "../src/plane_drag.m"
static bool hwm_suspended;
static uint32_t hwm_preserve_focus_window;
static double hwm_preserve_focus_until;
static struct window *hwm_action_window(void) { return &windows[0]; }
static void hwm_plane_set_camera(struct view *v,double x,double y,bool animate) { (void)animate; v->strip_offset=x; test_camera_y=y; }
static void hwm_plane_transition_to(struct view *v,double x,double y,double scale,bool animate) {
    hwm_plane_set_camera(v,x,y,animate); hwm_plane_scale=scale; hwm_plane_fit_active=fabs(scale-1)>.001;
}
static void hwm_plane_actual_size(struct view *v) { hwm_plane_transition_to(v,v->strip_offset,test_camera_y,1,true); }
#include "../src/plane_actions.m"
static bool hwm_plane_selecting,hwm_nav_pending,hwm_magnetic_centering=true;
static uint32_t hwm_nav_window;
static double hwm_nav_time;
static struct window *selection_hit;

static struct window *window_manager_find_window_at_point(void *manager,CGPoint point) { (void)manager; (void)point; return selection_hit; }
static void hwm_feedback_focus(void *old,struct window *next) { (void)old; (void)next; }
#include "../src/plane_selection.m"
static void hwm_plane_camera_stop(struct view *v,double now) { (void)v; (void)now; hwm_camera_animating=false; }
#include "../src/plane_pointer.m"



static void reset(void)
{
    hwm_drag_window=0; hwm_plane_pick_window=0; hwm_drag_move_pending=false; hwm_plane_selecting=false;
    hidden_tab=0; hwm_plane_scale=1; hwm_plane_fit_active=false; test_camera_y=0;
    memset(windows,0,sizeof(windows)); memset(nodes,0,sizeof(nodes));
    view=(struct view){.layout=VIEW_STRIP,.window_gap=12,.root=nodes};
    clock_now=10; hwm_last_input=0; __pending_gesture=false;
    hwm_move_failures=0; hwm_resize_operations=0; ax_calls=0; moves=0; disable_calls=0; update_depth=0;
    hwm_backend_ok=true; move_fails=false; clamp_native_sizes=false;
    hwm_shelf=0; hwm_shelf_from=0; hwm_shelf_start=-100; hwm_shelf_holding=false; memset(hwm_shelf_offsets,0,sizeof(hwm_shelf_offsets));
    g_mouse_state.window=NULL; close_calls=0; hwm_edge_window=0; hwm_edge_neighbor=0; undo_captures=0;
    for(int i=0;i<4;i++) {
        windows[i].id=i+1; windows[i].application=&application;
        windows[i].frame=actual[i]=projected[i]=CGRectMake(100+i*80,100,400,600); test_scales[i]=1;
        windows[i].strip_width=400;
        alphas[i]=.85;
        nodes[i].window_count=1; nodes[i].window_list[0]=i+1;
        nodes[i].next=i<3 ? &nodes[i+1] : NULL;
    }
    hwm_layout(&view,false); hwm_render(&view,clock_now);
    clock_now+=1; hwm_render(&view,clock_now);
    ax_calls=0; moves=0; disable_calls=0; hwm_resize_operations=0;
}
static void test_pan_and_late_notifications(void)
{
    reset(); __pending_gesture=true;
    for(int step=1;step<=80;step++) {
        view.strip_offset=step*11.5;
        clock_now+=1.0/120;
        hwm_last_input=clock_now;
        hwm_render(&view,clock_now);
        for(int i=0;i<4;i++) {
            CGRect cached=windows[i].strip_last_frame;
            actual[i].origin.x+=44; // A stale app notification during live input.
            assert(horizontal_window_moved(&windows[i]));
            assert(horizontal_window_changed(&windows[i],&view,false));
            assert(CGRectEqualToRect(cached,windows[i].strip_last_frame));
            actual[i]=cached;
        }
    }
    assert(ax_calls==0 && hwm_resize_operations==0);
    assert(disable_calls==80 && update_depth==0); // One compositor batch per pan frame.
    // A settled drift correction still works and still does not resize.
    __pending_gesture=false; clock_now+=1;
    actual[0].origin.x+=44;
    assert(horizontal_window_changed(&windows[0],&view,false));
    assert(!CGRectIsNull(windows[0].strip_last_frame));
    hwm_render(&view,clock_now);
    assert(actual[0].origin.x==round(12-view.strip_offset));
    assert(ax_calls==0 && hwm_resize_operations==0);
}
static void test_retarget_during_scroll(void)
{
    reset(); view.strip_offset=200; hwm_render(&view,clock_now);
    double source=windows[0].strip_last_frame.origin.x-12+windows[0].strip_last_offset;
    view.strip_offset=250; // Input advanced since the last displayed frame.
    windows[0].strip_width=650;
    hwm_layout(&view,true);
    assert(windows[0].strip_from_x==source);
    assert(windows[0].strip_from_width==400);
    clock_now+=.12; hwm_render(&view,clock_now);
    double shown=windows[0].strip_last_frame.size.width;
    assert(shown>400 && shown<650);
    windows[0].strip_width=300;
    hwm_layout(&view,true);
    assert(windows[0].strip_from_width==shown); // Reversal starts where it was drawn.
    clock_now+=1; hwm_render(&view,clock_now);
    assert(windows[0].strip_last_frame.size.width==300);
    assert(update_depth==0);
}
static void test_new_window_and_dynamic_stack(void)
{
    reset();
    windows[3].strip_initialized=false;
    actual[3]=CGRectMake(700,250,450,400);
    windows[2].strip_column=3; windows[3].strip_column=3;
    hwm_layout(&view,true);
    assert(windows[3].strip_from_x==688 && windows[3].strip_from_y==199);
    assert(windows[3].strip_from_width==450);
    assert(windows[2].strip_world_x==windows[3].strip_world_x);
    assert(windows[3].strip_world_y>windows[2].strip_world_y);
    clock_now+=.12; hwm_render(&view,clock_now);
    assert(windows[3].strip_last_frame.size.width>400 && windows[3].strip_last_frame.size.width<450);
    clock_now+=1; hwm_render(&view,clock_now);
    assert(windows[3].strip_last_frame.size.height==444);
}
static void test_failure_releases_compositor(void)
{
    reset(); view.strip_offset=200; move_fails=true;
    assert(!hwm_render(&view,clock_now));
    assert(update_depth==0 && hwm_move_failures==1 && !hwm_backend_ok);
}
static void test_floating_reversal_and_close_refusal(void)
{
    reset(); struct window *w=&windows[0]; w->floating=true;
    CGRect target=CGRectMake(300,180,800,650);
    CGRect original=actual[0];
    hwm_float_to(w,target);
    assert(CGRectEqualToRect(w->strip_float_from,original));
    clock_now+=.12; assert(hwm_render_floating(clock_now));
    assert(actual[0].size.width>original.size.width && actual[0].size.width<target.size.width);
    CGRect mid=actual[0];
    hwm_float_to(w,original);
    assert(CGRectEqualToRect(w->strip_float_from,mid));
    clock_now+=1; assert(!hwm_render_floating(clock_now));
    assert(CGRectEqualToRect(actual[0],original));
    hwm_float_to(w,target); g_mouse_state.window=w;
    assert(!hwm_render_floating(clock_now)); // Direct manipulation takes ownership.
    assert(!w->strip_float_animating);
    g_mouse_state.window=NULL;
    hwm_close_animated(w); clock_now+=.07;
    assert(hwm_render_closing(clock_now));
    assert(alphas[0]==0 && fade_duration[0]>0 && close_calls==0); // One fade request, run by the helper.
    clock_now+=.1; assert(!hwm_render_closing(clock_now));
    assert(close_calls==1 && fabs(alphas[0]-.85)<1e-6); // Refused close remains visible.
    hwm_close_animated(w); clock_now+=.07; hwm_render_closing(clock_now);
    hwm_cancel_closing();
    assert(!w->strip_close_pending && fabs(alphas[0]-.85)<1e-6 && close_calls==1);
}
static void test_open_pop_and_close_shrink(void)
{
    reset(); struct window *w=&windows[1]; alphas[1]=1; scale_calls=0;
    hwm_pop_open(w);
    assert(w->strip_pop==1 && alphas[1]==0); // Hidden until its size has landed.
    resize_busy=true; clock_now+=.05; assert(hwm_render_pops(clock_now));
    assert(w->strip_pop==1 && alphas[1]==0 && scale_calls==0);
    resize_busy=false; clock_now+=.02; assert(hwm_render_pops(clock_now));
    assert(w->strip_pop==2 && alphas[1]==1 && fade_duration[1]>0); // The fade-in starts with the size in place.
    assert(w->strip_pop_scaled && scale_calls==1);
    clock_now+=.05; assert(hwm_render_pops(clock_now));
    assert(scale_calls==3); // Each frame resets, then applies the next scale.
    hwm_scale_reset_all(); assert(!w->strip_pop_scaled && scale_calls==4); // Before a frame moves it.
    clock_now+=.02; assert(hwm_render_pops(clock_now)); assert(w->strip_pop_scaled);
    clock_now+=1; assert(!hwm_render_pops(clock_now));
    assert(!w->strip_pop && !w->strip_pop_scaled);
    // An app that never answers is shown anyway.
    alphas[1]=1; hwm_pop_open(w); resize_busy=true; clock_now+=.4; hwm_render_pops(clock_now);
    assert(w->strip_pop==2 && alphas[1]==1); resize_busy=false;
    hwm_cancel_pops(); assert(!w->strip_pop && !w->strip_pop_scaled);
    // Closing shrinks, and a refused close is returned to full size.
    scale_calls=0; hwm_close_animated(w); clock_now+=.07; hwm_render_closing(clock_now);
    assert(w->strip_close_scaled && scale_calls==1);
    clock_now+=.1; hwm_render_closing(clock_now);
    assert(!w->strip_close_scaled && scale_calls==2);
    assert(hwm_content_width==4*400+3*12);
    // A held batch presents a whole frame at once.
    int before=disable_calls; hwm_batch_hold=true;
    view.strip_offset+=40; hwm_render(&view,clock_now); assert(update_depth==1);
    hwm_batch_release(); assert(update_depth==0 && disable_calls==before+1);
}
static void test_close_converges_both_sides(void)
{
    // Columns sit at 0, 412, 824, 1236 in a 1200-wide viewport.
    reset(); view.strip_offset=300;
    hwm_hole_note(&view,&windows[1]); assert(hwm_hole.pending);
    nodes[0].next=&nodes[2]; hwm_layout(&view,true);
    assert(view.strip_offset==300-206 && !hwm_hole.pending); // Half of 400+12: both sides move in.
    assert(windows[2].strip_world_x==412);
    // A hole left of the viewport is absorbed whole: what is on screen stays put.
    reset(); view.strip_offset=900;
    hwm_hole_note(&view,&windows[0]); nodes[0].window_count=0; view.root=&nodes[1]; hwm_layout(&view,true);
    assert(view.strip_offset==900-412);
    // One to the right of the viewport needs no camera movement at all.
    reset(); view.strip_offset=0;
    hwm_hole_note(&view,&windows[3]); nodes[2].next=NULL; hwm_layout(&view,true);
    assert(view.strip_offset==0);
    // A row leaving a stack frees no strip width.
    reset(); windows[1].strip_column=1; windows[0].strip_column=1; hwm_layout(&view,false);
    hwm_hole_note(&view,&windows[1]); assert(!hwm_hole.pending);
    view.root=nodes;
}
static void test_slow_app_and_optimistic_close(void)
{
    // While an application has not answered a size request, its notifications
    // are echoes and the settled size must not be read back as a constraint.
    reset(); windows[0].strip_width=650; hwm_layout(&view,true);
    clock_now+=.05; hwm_render(&view,clock_now);
    resize_busy=true; clock_now+=2; actual[0].size.width=520; // The app is still at an intermediate size.
    assert(hwm_render(&view,clock_now)); // Still active: waiting for the answer.
    assert(windows[0].strip_width==650 && windows[0].strip_size_pending);
    assert(horizontal_resize_event(&windows[0])); // Swallowed without asking the app.
    resize_busy=false; actual[0].size.width=650; clock_now+=.3; hwm_render(&view,clock_now);
    assert(!windows[0].strip_size_pending && windows[0].strip_width==650);
    clock_now+=1; assert(horizontal_resize_event(&windows[0])); // Settled updates still wake reconciliation.
    // A window fading out for a close gives up its place at once, and the
    // camera converges; if the app refuses, clearing the flag restores it.
    reset(); view.strip_offset=300;
    hwm_hole_note(&view,&windows[1]); windows[1].strip_close_ghost=true; hwm_layout(&view,true);
    assert(windows[2].strip_world_x==412 && view.strip_offset==300-206 && hwm_content_width==3*400+2*12);
    hwm_hole_note(&view,&windows[1]); assert(!hwm_hole.pending); // Real removal must not shift twice.
    windows[1].strip_close_ghost=false; hwm_layout(&view,true);
    assert(windows[2].strip_world_x==824 && windows[1].strip_world_x==412);
}
static void test_native_edge_resize(void)
{
    reset(); struct window *w=&windows[1];
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[1];
    g_mouse_state.current_action=0;
    CGRect original=actual[1];
    horizontal_mouse_down(w,CGPointMake(CGRectGetMaxX(original),CGRectGetMidY(original)));
    assert(hwm_edge_window==w->id);
    for(int i=1;i<=30;i++) {
        actual[1].size.width=400+i*5;
        CGRect native=actual[1]; clock_now+=1.0/120;
        assert(horizontal_window_changed(w,&view,true));
        hwm_render(&view,clock_now);
        assert(CGRectEqualToRect(actual[1],native));
        assert(fabs(w->strip_width-native.size.width)<.01);
    }
    assert(undo_captures==1);
    assert(hwm_edge_finish(w,&view));
    clock_now+=1; hwm_render(&view,clock_now);
    assert(actual[1].size.width==550);
    assert(actual[2].origin.x>=CGRectGetMaxX(actual[1])+11);

    reset(); view.strip_offset=300; hwm_render(&view,clock_now);
    w=&windows[1]; original=actual[1];
    g_mouse_state.window=w; g_mouse_state.window_frame=original;
    horizontal_mouse_down(w,CGPointMake(original.origin.x,CGRectGetMidY(original)));
    actual[1].origin.x-=75; actual[1].size.width+=75;
    hwm_edge_update(w,&view); hwm_render(&view,clock_now);
    assert(view.strip_offset==375);
    assert(CGRectGetMaxX(actual[1])==CGRectGetMaxX(original));
    hwm_edge_finish(w,&view);

    reset(); windows[1].strip_column=windows[0].id;
    hwm_layout(&view,false); hwm_render(&view,clock_now);
    w=&windows[0]; g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    horizontal_mouse_down(w,CGPointMake(CGRectGetMidX(actual[0]),CGRectGetMaxY(actual[0])));
    actual[0].size.height+=80;
    hwm_edge_update(w,&view); hwm_render(&view,clock_now);
    assert(fabs(windows[0].strip_height-(444+80))<1);
    assert(fabs(windows[1].strip_height-(444-80))<1);
    assert(undo_captures==1);
    hwm_edge_finish(w,&view);
}

static void test_tab_parking_is_move_only(void)
{
    reset(); hidden_tab=windows[1].id;
    CGSize before=actual[1].size;
    hwm_layout(&view,true); hwm_render(&view,clock_now+.1);
    assert(windows[1].strip_tab_parked);
    assert(CGSizeEqualToSize(actual[1].size,before));
    assert(actual[1].origin.y==51 && actual[1].origin.x<0);
    hidden_tab=0; hwm_layout(&view,true); hwm_render(&view,clock_now);
    assert(!windows[1].strip_tab_parked);
    assert(actual[1].origin.x>=0 && actual[1].origin.y==51);
}

static void test_spring_continuity(void)
{
    double velocity=0;
    double x=hstrip_spring(0,500,1000,.08,22,&velocity);
    double v2=0;
    assert(fabs(hstrip_spring(x,100,velocity,0,22,&v2)-x)<1e-9);
    assert(fabs(v2-velocity)<1e-9);
    assert(fabs(hstrip_spring(x,100,velocity,2,22,&v2)-100)<.001);
}

/* Strips are stacked: each is laid out on its own, keeps its own camera, and
 * the ones out of view sit off the bottom of the screen, never above the top. */
static void test_stacked_strips(void)
{
    reset();
    windows[2].strip_shelf=1; windows[3].strip_shelf=1;
    hwm_shelf_offsets[1]=40;
    hwm_layout(&view,false); clock_now+=1; hwm_render(&view,clock_now);
    // Each strip starts again from the left wall.
    assert(windows[0].strip_world_x==0 && windows[1].strip_world_x==412 && windows[2].strip_world_x==0 && windows[3].strip_world_x==412);
    assert(fabs(hwm_content_width-812)<.001 && fabs(hwm_shelf_content[1]-812)<.001);
    double pitch=900+240;
    assert(actual[0].origin.y==51 && actual[2].origin.y==51+pitch && actual[2].origin.x==12-40 && actual[3].origin.x==12+412-40);
    // Panning the strip in view leaves the other strip where it is.
    int before=moves; view.strip_offset=100; clock_now+=1; hwm_render(&view,clock_now);
    assert(actual[0].origin.x==12-100 && actual[2].origin.x==12-40 && moves==before+2);
    // Going down a strip: both glide, and the one that left upwards ends up parked below.
    hwm_shelf_offsets[0]=view.strip_offset; hwm_shelf_from=0; hwm_shelf=1; hwm_shelf_start=clock_now; view.strip_offset=hwm_shelf_offsets[1];
    clock_now+=hwm_duration*.4; assert(hwm_shelf_moving(clock_now)); bool active=hwm_render(&view,clock_now);
    assert(active && actual[0].origin.y<51 && actual[0].origin.y>51-pitch && actual[2].origin.y>51 && actual[2].origin.y<51+pitch);
    assert(fabs((actual[2].origin.y-actual[0].origin.y)-pitch)<=1);
    clock_now+=hwm_duration; hwm_render(&view,clock_now);
    assert(actual[2].origin.y==51 && actual[0].origin.y==51+pitch && actual[0].origin.x==12-100 && ax_calls==0);
}

static void test_offscreen_constraint_visibility(void)
{
    reset();
    struct window *w=&windows[0];
    view.strip_offset=500; clock_now+=.02; hwm_last_input=clock_now;
    hwm_render(&view,clock_now);
    assert(w->strip_offscreen && alphas[0]==0);
    // AppKit's delayed correction can race the renderer's cached position.
    actual[0].origin.x=-actual[0].size.width+32;
    hwm_render(&view,clock_now+.01);
    assert(alphas[0]==0); // The constrained edge cannot flash onto the screen.
    view.strip_offset=350;
    hwm_render(&view,clock_now+.02);
    assert(!w->strip_offscreen && alphas[0]==1);
    assert(actual[0].origin.x==12-350); // Move precedes revealing.
    assert(ax_calls==0);

    reset(); hwm_shelf_from=0; hwm_shelf=1; hwm_shelf_start=clock_now;
    hwm_render(&view,clock_now+hwm_duration*.8);
    assert(windows[0].strip_offscreen && alphas[0]==0);
    actual[0].origin.y=38;
    hwm_render(&view,clock_now+hwm_duration);
    assert(alphas[0]==0);
    hwm_shelf_from=1; hwm_shelf=0; clock_now+=hwm_duration; hwm_shelf_start=clock_now;
    hwm_render(&view,clock_now+hwm_duration);
    assert(!windows[0].strip_offscreen && alphas[0]==1 && actual[0].origin.y==51);
    assert(ax_calls==0);
    // Pausing/shutdown must hand back even windows hidden at the right edge.
    view.strip_offset=10000; hwm_render(&view,clock_now+1);
    hwm_visibility_restore_all();
    for(int i=0;i<4;i++) assert(!windows[i].strip_offscreen && alphas[i]==1);
}

static void test_companion_visibility(void)
{
    reset();
    [hwm_visibility_companions removeAllObjects];
    actual[3]=CGRectInset(actual[0],-14,-14); alphas[3]=.75;
    windows[3].strip_offscreen=false; // This slot models a border for this test.
    hwm_borders_external=true; hwm_visibility_scan=-100;
    hwm_visibility_prepare(&view,clock_now);
    assert([hwm_visibility_companions[@4][@"parent"] unsignedIntValue]==1);
    hwm_visibility_set(&windows[0],true,CGRectNull);
    assert(alphas[0]==0 && alphas[3]==0);
    actual[0].origin=CGPointMake(20,80); actual[3].origin=CGPointMake(-900,38);
    hwm_visibility_set(&windows[0],false,actual[0]);
    assert(alphas[0]==1 && alphas[3]==.75);
    assert(actual[3].origin.x==6 && actual[3].origin.y==66);
    hwm_overview_active=true;
    hwm_visibility_set(&windows[0],false,actual[0]);
    assert(alphas[0]==1 && alphas[3]==0); // Cards reveal; their borders stay hidden.
    hwm_overview_active=false; hwm_visibility_restore_all();
    assert(alphas[3]==.75);
    hwm_borders_external=false; [hwm_visibility_companions removeAllObjects];
}

static void test_plane_camera_and_fit(void)
{
    reset();
    struct window *w=&windows[0];
    w->strip_world_x=-740; w->strip_world_y=420; w->strip_width=400; w->strip_height=300;
    hwm_layout(&view,false);
    view.strip_offset=-300; clock_now+=1; hwm_render(&view,clock_now);
    assert(projected[0].origin.x==round(12-740+300));
    assert(projected[0].origin.y==round(51+420));
    assert(w->strip_world_x==-740 && w->strip_world_y==420);
    ax_calls=0;
    hwm_plane_fit_active=true; hwm_plane_scale=.5; scale_calls=0;
    clock_now+=.02; hwm_render(&view,clock_now);
    assert(w->strip_plane_scaled && scale_calls>0);
    assert(w->strip_width==400 && w->strip_height==300 && ax_calls==0);
    int before=scale_calls;
    hwm_plane_scale=.8; clock_now+=.02; hwm_render(&view,clock_now);
    assert(scale_calls>before && w->strip_last_plane_scale==.8);
    hwm_plane_fit_active=false; hwm_plane_scale=1;
    test_camera_y=-800;
    clock_now+=.02; hwm_render(&view,clock_now);
    assert(w->strip_plane_scaled); // Unit zoom still has a plane translation.
    assert(projected[0].origin.y==round(51+420+800));
    test_camera_y=100000; clock_now+=1; hwm_render(&view,clock_now);
    assert(w->strip_offscreen && w->strip_world_y==420);
}

static void test_maximize_at_actual_size(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_plane_fit_active=true;
    view.strip_offset=1000; test_camera_y=-200;
    w->strip_world_x=42; w->strip_world_y=67;
    clamp_native_sizes=true;
    hwm_plane_maximize(&view); hwm_render(&view,clock_now);
    assert(hwm_plane_scale==1 && !hwm_plane_fit_active);
    assert(view.strip_offset==42 && test_camera_y==67);
    assert(w->strip_width==1200 && w->strip_height==900);
    clock_now+=1; hwm_render(&view,clock_now); clock_now+=.3; hwm_render(&view,clock_now);
    assert(CGRectEqualToRect(projected[0],hwm_bounds(&view)));
    assert(moves==1 && CGPointEqualToPoint(actual[0].origin,hwm_bounds(&view).origin));
    assert(undo_captures==1 && hwm_preserve_focus_window==w->id);
}
static void test_final_resize_confirmation(void)
{
    reset(); struct window *w=&windows[0];
    w->strip_size_pending=true; w->strip_size_confirmed=false;
    w->strip_size_sent_at=clock_now-1;
    actual[0].size.width=417; clock_now+=1;
    hwm_render(&view,clock_now);
    assert(w->strip_width==400 && w->strip_size_confirmed && w->strip_size_pending);
    assert(actual[0].size.width==400);
    clock_now+=.3; hwm_render(&view,clock_now);
    assert(w->strip_width==400 && !w->strip_size_pending);
}

static void test_drag_submission_and_magnetic_release(void)
{
    const double zooms[]={.5,1,2};
    for(int z=0;z<3;z++) {
        reset(); struct window *w=&windows[0];
        windows[1].strip_world_x=500; windows[1].strip_world_y=0;
        windows[2].strip_world_x=10000; windows[3].strip_world_x=20000;
        w->strip_world_x=0; w->strip_world_y=0;
        hwm_plane_scale=zooms[z]; hwm_plane_fit_active=hwm_plane_scale!=1;
        hwm_drag_snap_x=hwm_drag_snap_y=0; hwm_drag_snap_time=clock_now;
        hwm_drag_snap_neighbor=0; hwm_drag_finishing=false;
        scale_calls=0; ax_calls=0; int before=moves;
        for(int step=1;step<=120;step++) {
            clock_now+=1.0/120;
            assert(hwm_drag_submit_plane(&view,w,CGPointMake(80,0)));
            assert(w->strip_world_x>=80 && w->strip_world_x<=88);
            assert(projected[0].origin.x==round(12+w->strip_world_x*hwm_plane_scale));
        }
        hwm_drag_finishing=true;
        assert(hwm_drag_submit_plane(&view,w,CGPointMake(80,0)));
        hwm_drag_finishing=false;
        assert(fabs(w->strip_world_x+400+12-windows[1].strip_world_x)<.001);
        assert(w->strip_world_y==0 && moves==before && ax_calls==0);
        assert(scale_calls==121);
        clock_now+=1.0/120;
        assert(hwm_drag_submit_plane(&view,w,CGPointMake(88,0)));
        assert(hwm_drag_snap_neighbor==windows[1].id);
        assert(fabs(w->strip_world_x-88)<.001);
        clock_now+=1.0/120;
        assert(hwm_drag_submit_plane(&view,w,CGPointMake(96,0)));
        assert(fabs(w->strip_world_x-88)<.001);
    }
}

static void test_scaled_pan_keeps_transform(void)
{
    reset(); hwm_plane_scale=.5; hwm_plane_fit_active=true;
    clock_now+=2; hwm_render(&view,clock_now);
    int before=scale_calls; ax_calls=0;
    for(int i=1;i<=120;i++) {
        view.strip_offset=i; test_camera_y=i*.5; clock_now+=1.0/120;
        hwm_render(&view,clock_now);
        assert(scale_calls>before && ax_calls==0 && moves==0);
        assert(projected[0].origin.x==round(12+(windows[0].strip_world_x-i)*.5));
        assert(projected[0].origin.y==round(51+(windows[0].strip_world_y-i*.5)*.5));
    }
    hwm_layout(&view,true);
    assert(fabs(windows[0].strip_from_x-windows[0].strip_world_x)<=1);
    assert(fabs(windows[0].strip_from_y-windows[0].strip_world_y)<=1);
}

static void test_position_echo_does_not_resize(void)
{
    reset(); clock_now+=2; hwm_render(&view,clock_now);
    struct window *w=&windows[0];
    double wx=w->strip_world_x,wy=w->strip_world_y;
    actual[0].origin.x+=45; actual[0].origin.y+=30;
    ax_calls=0;
    assert(horizontal_window_changed(w,&view,false));
    clock_now+=.02; hwm_render(&view,clock_now);
    assert(ax_calls==0 && !w->strip_size_pending);
    assert(w->strip_world_x==wx && w->strip_world_y==wy);
    assert(projected[0].origin.x==round(12+wx) && projected[0].origin.y==round(51+wy));
}

static void test_plane_transform_cleanup(void)
{
    reset();
    struct window *w=&windows[0];
    hwm_plane_fit_active=true; hwm_plane_scale=2; scale_calls=0;
    clock_now+=.02; hwm_render(&view,clock_now);
    assert(w->strip_plane_scaled && scale_calls>0);
    int before=scale_calls;
    hwm_plane_reset_transform(w);
    assert(!w->strip_plane_scaled && scale_calls==before+1);

    w->strip_plane_scaled=true; windows[1].strip_plane_scaled=true;
    windows[1].strip_last_frame=CGRectMake(92,72,400,600);
    before=scale_calls;
    hwm_plane_reset_all_transforms();
    assert(!w->strip_plane_scaled && !windows[1].strip_plane_scaled && scale_calls>before);
}

static void test_zoomed_edge_hit(void)
{
    reset(); struct window *w=&windows[0];
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    hwm_plane_scale=.5; hwm_plane_fit_active=true;
    CGRect f=w->strip_last_frame;
    CGPoint edge=CGPointMake(f.origin.x+f.size.width*.5,f.origin.y+f.size.height*.25);
    horizontal_mouse_down(w,edge);
    assert(hwm_edge_window==w->id && (hwm_edge_direction&HANDLE_RIGHT));
    hwm_edge_window=0;
}

static void test_plane_native_initial_sizes(void)
{
    reset();
    windows[0].strip_initialized=false; windows[0].strip_last_frame=CGRectZero;
    actual[0]=CGRectMake(120,150,978,1049);
    hwm_layout(&view,false);
    assert(windows[0].strip_width==978 && windows[0].strip_height==1049);
    assert(windows[0].strip_world_x==108 && windows[0].strip_world_y==99);
    windows[0].strip_initialized=false; windows[0].strip_last_frame=CGRectZero;
    windows[0].frame=CGRectMake(30,60,978,519); actual[0]=CGRectZero;
    hwm_layout(&view,false);
    assert(windows[0].strip_width==978 && windows[0].strip_height==519);
    windows[0].strip_initialized=false; windows[0].strip_placed=true;
    windows[0].strip_world_x=-700; windows[0].strip_world_y=850;
    hwm_layout(&view,false);
    assert(windows[0].strip_world_x==-700 && windows[0].strip_world_y==850);
}

static void test_plane_native_resize(void)
{
    reset(); struct window *w=&windows[1];
    double x=w->strip_world_x,y=w->strip_world_y;
    double other_x=windows[2].strip_world_x,other_y=windows[2].strip_world_y;
    CGRect original=actual[1];
    g_mouse_state.window=w; g_mouse_state.window_frame=original;
    horizontal_mouse_down(w,w->strip_last_frame.origin);
    assert(hwm_edge_window==w->id);
    actual[1].origin.x-=75; actual[1].origin.y-=40;
    actual[1].size.width+=75; actual[1].size.height+=40;
    hwm_edge_update(w,&view);
    assert(w->strip_world_x==x-75 && w->strip_world_y==y-40);
    assert(w->strip_width==original.size.width+75 && w->strip_height==original.size.height+40);
    assert(windows[2].strip_world_x==other_x && windows[2].strip_world_y==other_y);
    assert(view.strip_offset==0 && undo_captures==1);
    hwm_edge_finish(w,&view);
}

static void test_native_anchor_is_independent_of_projection(void)
{
    reset(); CGRect anchors[4]; memcpy(anchors,actual,sizeof(anchors));
    hwm_plane_scale=.75; hwm_plane_fit_active=true; __pending_gesture=true;
    for(int i=0;i<80;i++) {
        view.strip_offset=sin(i*.15)*600; test_camera_y=cos(i*.1)*700;
        clock_now+=1.0/120; hwm_render(&view,clock_now);
        for(int j=0;j<4;j++) assert(CGRectEqualToRect(actual[j],anchors[j]));
    }
    assert(moves==0 && ax_calls==0);
    // Reproduce a native y=38 correction. The displayed surface stays at its
    // projected point; the renderer never moves the anchor back offscreen.
    __pending_gesture=false; clock_now+=2;
    actual[0].origin.y=38;
    horizontal_window_changed(&windows[0],&view,false);
    hwm_render(&view,clock_now);
    assert(actual[0].origin.y==38 && moves==0 && ax_calls==0);
    assert(projected[0].origin.y==round(51+(windows[0].strip_world_y-test_camera_y)*.75));
}

static void test_plane_click_to_center(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_plane_fit_active=true;
    w->strip_world_x=-740; w->strip_world_y=420;
    w->strip_width=400; w->strip_height=300;
    w->strip_last_frame=CGRectMake(50,60,400,300); w->strip_last_plane_scale=.5;
    w->strip_offscreen=false; hwm_plane_selecting=true; selection_hit=NULL;
    for(int i=1;i<4;i++) windows[i].strip_offscreen=true;
    hwm_plane_choose_at(CGPointMake(800,800));
    assert(hwm_plane_selecting); // Empty canvas does not choose a window.
    hwm_plane_choose_at(CGPointMake(100,100));
    assert(!hwm_plane_selecting && hwm_nav_pending && hwm_nav_window==w->id);
    assert(hwm_plane_scale==1 && view.strip_offset==-1140 && test_camera_y==120);
    assert(w->strip_width==400 && w->strip_height==300 && ax_calls==0 && moves==0);
    // A real WindowServer hit selects the topmost window in overlapping surfaces.
    hwm_plane_selecting=true; selection_hit=&windows[1]; windows[1].strip_offscreen=false;
    hwm_plane_choose_at(CGPointMake(100,100));
    assert(!hwm_plane_selecting && hwm_nav_window==windows[1].id);
    selection_hit=NULL;
    hwm_nav_pending=false; hwm_plane_selecting=false;
    hwm_plane_scale=.5; view.strip_offset=50; test_camera_y=80;
    HWMPlaneCamera origin={100,80,.5};
    hwm_plane_magnet_at(&view,CGPointMake(100,100),origin);
    assert(view.strip_offset==50 && test_camera_y==80); // No window, no pull.
    selection_hit=w; hwm_plane_magnet_at(&view,CGPointMake(100,100),origin);
    assert(view.strip_offset==50 && test_camera_y==80); // Far from center: free pan.
    view.strip_offset=-1640; test_camera_y=-330; origin=(HWMPlaneCamera){-1600,-330,.5};
    hwm_plane_magnet_at(&view,CGPointMake(100,100),origin);
    assert(view.strip_offset==-1660 && test_camera_y==-330 && hwm_plane_scale==.5);
    assert(!hwm_nav_pending && ax_calls==0 && moves==0); // 10 display points, no focus or resize.
    view.strip_offset=-1640; origin=(HWMPlaneCamera){-1700,-330,.5};
    hwm_plane_magnet_at(&view,CGPointMake(100,100),origin);
    assert(view.strip_offset==-1640); // Moving away never pulls back.
    hwm_plane_selecting=true; view.strip_offset=50;
    hwm_plane_magnet_at(&view,CGPointMake(100,100),origin); assert(view.strip_offset==50);
    hwm_plane_selecting=false; selection_hit=NULL;
}

static void test_overview_pointer(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_plane_selecting=true; selection_hit=w;
    hwm_motion_scale=0;
    double x=w->strip_world_x,y=w->strip_world_y,width=w->strip_width,height=w->strip_height;
    hwm_plane_pointer(kCGEventLeftMouseDown,CGPointMake(200,200));
    assert(hwm_plane_selecting && !hwm_drag_window);
    hwm_plane_pointer(kCGEventLeftMouseDragged,CGPointMake(202,201));
    assert(!hwm_drag_window);
    hwm_plane_pointer(kCGEventLeftMouseDragged,CGPointMake(350,290));
    assert(hwm_drag_window==w->id && hwm_drag_move_pending && undo_captures==1);
    hwm_plane_pointer(kCGEventLeftMouseUp,CGPointMake(360,300));
    assert(hwm_plane_selecting && !hwm_drag_window && !hwm_plane_pick_window);
    assert(w->strip_world_x==x+320 && w->strip_world_y==y+200);
    assert(w->strip_width==width && w->strip_height==height && ax_calls==0 && moves==0);
    // A later click, without a drag, still centers at 100 percent.
    hwm_plane_pointer(kCGEventLeftMouseDown,CGPointMake(360,300));
    assert(hwm_plane_selecting);
    hwm_plane_pointer(kCGEventLeftMouseUp,CGPointMake(360,300));
    assert(!hwm_plane_selecting && hwm_plane_scale==1 && hwm_nav_window==w->id);
    hwm_motion_scale=1; selection_hit=NULL;
}
static void test_resize_notification_after_release(void)
{
    reset(); struct window *w=&windows[0];
    hwm_plane_scale=.5; hwm_render(&view,clock_now);
    double x=w->strip_world_x,y=w->strip_world_y;
    CGRect before=actual[0];
    g_mouse_state.window=w; g_mouse_state.window_frame=before; g_mouse_state.current_action=0;
    horizontal_mouse_down(w,w->strip_last_frame.origin);
    assert(hwm_edge_window==w->id);
    actual[0].origin.x-=80; actual[0].origin.y-=60;
    actual[0].size.width+=80; actual[0].size.height+=60;
    hwm_edge_update(w,&view);
    assert(w->strip_world_x==x-80 && w->strip_world_y==y-60); // No double zoom conversion.
    hwm_edge_finish(w,&view);
    hwm_render(&view,clock_now);
    // AppKit's final update arrives after mouse-up, during a camera animation.
    actual[0].size.width+=37; actual[0].size.height+=19;
    w->strip_last_plane_scale=.5;
    __pending_gesture=true;
    assert(horizontal_resize_event(w));
    assert(w->strip_native_resize_pending && w->strip_transform_dirty && w->strip_last_plane_scale==.5);
    int before_calls=scale_calls;
    hwm_render(&view,clock_now+.01);
    assert(w->strip_native_resize_pending && scale_calls>before_calls);
    assert(w->strip_width==actual[0].size.width && w->strip_height==actual[0].size.height);
    assert(w->strip_last_frame.size.width==actual[0].size.width);
    assert(ax_calls==0 && moves==0); // No resize echo into the app.
    assert(projected[0].size.width==actual[0].size.width*.5);
    // A notification can precede the native bounds update. The old first read
    // must not discard a second size published on the next frame.
    actual[0].size.width+=23; actual[0].size.height+=17;
    hwm_render(&view,clock_now+.04);
    assert(w->strip_width==actual[0].size.width && w->strip_native_resize_pending);
    hwm_render(&view,clock_now+.2);
    assert(!w->strip_native_resize_pending);
    __pending_gesture=false; g_mouse_state.window=NULL;
}

int main(void)
{
    @autoreleasepool {
    test_overview_pointer();
    test_resize_notification_after_release();
    test_plane_click_to_center();
    test_native_anchor_is_independent_of_projection();
    test_plane_camera_and_fit();
    test_position_echo_does_not_resize();
    test_scaled_pan_keeps_transform();
    test_drag_submission_and_magnetic_release();
    test_maximize_at_actual_size();
    test_final_resize_confirmation();
    test_plane_transform_cleanup();
    test_plane_native_resize();
    test_plane_native_initial_sizes();
    test_zoomed_edge_hit();
    puts("plane runtime tests passed");
    }
}
