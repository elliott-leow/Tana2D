/* Secondary windows follow their owner tile (src/plane_satellite.m), with
 * WindowServer, Accessibility and the renderer replaced by a small model. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>

enum { WINDOW_FULLSCREEN=0x02, WINDOW_MINIMIZE=0x04, WINDOW_FLOAT=0x08, WINDOW_STICKY=0x10, WINDOW_RULE_MANAGED=0x01 };
enum { LAYER_ABOVE=3 };
typedef enum { HWM_PLANE_INTERRUPT_UNMANAGE } HWMPlaneInterruptReason;
struct application { bool is_hidden; };
struct window_node { int window_count; uint32_t window_list[4]; struct window_node *next; };
struct view { struct window_node *root; };
struct window {
    uint32_t id; struct application *application; uint8_t flags,rule_flags;
    bool is_root,is_child,is_modal,role,standard,dialog,movable,normal_level;
    double strip_world_x,strip_world_y,strip_last_plane_scale,strip_start;
    CGRect strip_last_frame;
    bool strip_initialized,strip_offscreen,strip_close_ghost,strip_sticky,strip_plane_scaled,strip_native_riding,strip_float_animating;
    uint32_t strip_owner; CGPoint strip_owner_delta,strip_sat_shown; double strip_sat_scale,strip_sat_moved;
    bool strip_sat_synced; uint8_t strip_sat_failures;
};

/* The model: tile 1 (main window), satellite 2 (its dialog), tile 3 of another app. */
static struct application app_a,app_b;
static struct window windows[3];
static CGRect native[3];
static uint32_t parents[3];
static bool managed[3];
static struct window_node node={2,{1,3},NULL};
static struct view plane={&node};
static double clock_now=10,hwm_plane_scale=1,hwm_duration=.3;
static bool in_motion,hwm_ready=true,job_busy;
static int job_state=1,ax_moves,reset_calls,rides,transforms,alpha_changes,floated,hwm_move_failures,layer_calls;
static uint32_t hwm_drag_window;
static struct { struct window *window; } g_mouse_state;
static struct { uint32_t focused_window_id; int window; } g_window_manager;
static int g_space_manager,g_connection;

#define table_for(it,table,code) for(int table_i=0;table_i<3;table_i++) { it=&windows[table_i]; code; }
static bool window_check_flag(struct window *w,uint8_t f) { return (w->flags&f)!=0; }
static void window_set_flag(struct window *w,uint8_t f) { w->flags|=f; }
static bool window_check_rule_flag(struct window *w,uint8_t f) { return (w->rule_flags&f)!=0; }
static bool window_has_window_role(struct window *w) { return w->role; }
static bool window_is_standard(struct window *w) { return w->role && w->standard; }
static bool window_is_dialog(struct window *w) { return w->dialog; }
static bool window_can_move(struct window *w) { return w->movable; }
static bool window_level_is_standard(struct window *w) { return w->normal_level; }
static bool window_is_sticky(uint32_t id) { (void)id; return false; }
static bool window_is_real(struct window *w) { return w->role; }
#include "../vendor/yabai/src/window_admission.h"
static struct window *window_manager_find_window(void *m,uint32_t id) { (void)m; return id>=1 && id<=3 ? &windows[id-1] : NULL; }
static struct view *window_manager_find_managed_window(void *m,struct window *w) { (void)m; return managed[w->id-1] ? &plane : NULL; }
static struct window_node *window_node_find_first_leaf(struct window_node *n) { return n; }
static struct window_node *window_node_find_next_leaf(struct window_node *n) { return n->next; }
static bool hwm_workflow_tab_hidden(struct window *w) { (void)w; return false; }
static uint32_t window_parent(uint32_t id) { return parents[id-1]; }
static int window_level(uint32_t id) { (void)id; return 0; }
static CGError SLSGetWindowBounds(int c,uint32_t id,CGRect *out) { (void)c; *out=native[id-1]; return kCGErrorSuccess; }
static struct view *hwm_view(void) { return &plane; }
static double hwm_now(void) { return clock_now; }
static CGRect hwm_bounds(struct view *v) { (void)v; return CGRectMake(12,51,1686,1049); }
static CGRect hwm_screen(struct view *v) { (void)v; return CGRectMake(0,38,1710,1074); }
static double hwm_offset(struct view *v,double t) { (void)v; (void)t; return 0; }
static double hwm_plane_camera_y(double t) { (void)t; return 0; }
static double hwm_plane_project_physical(double world,double camera,double origin,double scale) { return origin+(world-camera)*scale; }
static bool hwm_view_in_motion(struct view *v,double t) { (void)v; (void)t; return in_motion; }
static void hwm_wake(void) {}
static void debug(const char *f,...) { (void)f; }
static void hwm_batch_begin_plane(void) {}
static void hwm_batch_end(void) {}
static bool scripting_addition_plane_native_supported(void) { return true; }
/* A ride moves the native frame; a transform only moves what is shown. */
static bool scripting_addition_set_plane_native(uint32_t id,double x,double y) { ++rides; native[id-1].origin=CGPointMake(x,y); return true; }
static bool scripting_addition_set_plane_transform(uint32_t id,double x,double y,double s) { (void)id; (void)x; (void)y; (void)s; ++transforms; return true; }
static bool scripting_addition_set_layer(uint32_t id,int layer) { (void)id; assert(layer==LAYER_ABOVE); ++layer_calls; return true; }
static void hwm_visibility_set(struct window *w,bool hidden,CGRect f) { (void)f; if(w->strip_offscreen!=hidden) ++alpha_changes; w->strip_offscreen=hidden; }
static bool hwm_zoom_native_busy(uint32_t id) { (void)id; return job_busy; }
static int hwm_zoom_native_position(struct window *w,CGPoint target,CGSize size,CGPoint origin,CGRect *accepted) {
    (void)size; (void)origin; ++ax_moves; if(job_state>0) native[w->id-1].origin=target; *accepted=native[w->id-1]; return job_state;
}
static bool hwm_plane_reset_transform(struct window *w) { ++reset_calls; w->strip_plane_scaled=false; return true; }
static void hwm_plane_abort_interaction(struct window *w,HWMPlaneInterruptReason r) { (void)w; (void)r; }
static void window_manager_make_window_floating(void *sm,void *wm,struct window *w,bool f,bool force) { (void)sm; (void)wm; (void)force; assert(f); managed[w->id-1]=false; w->flags|=WINDOW_FLOAT; ++floated; }
static void hwm_layout(struct view *v,bool a) { (void)v; (void)a; }
#define CGWindowLevelForKey(key) 8
#include "../src/plane_satellite.m"

static void reset(void)
{
    struct window main={.id=1,.application=&app_a,.is_root=true,.role=true,.standard=true,.movable=true,.normal_level=true,
        .strip_world_x=100,.strip_world_y=40,.strip_last_plane_scale=1,.strip_last_frame=CGRectMake(112,91,800,600),.strip_initialized=true};
    struct window dialog=main; dialog.id=2; dialog.standard=false; dialog.dialog=true; dialog.flags=WINDOW_FLOAT;
    dialog.strip_last_frame=CGRectNull; dialog.strip_initialized=false;
    struct window other=main; other.id=3; other.application=&app_b; other.strip_last_frame=CGRectMake(1000,91,500,600);
    windows[0]=main; windows[1]=dialog; windows[2]=other;
    native[0]=CGRectMake(112,91,800,600); native[1]=CGRectMake(312,191,400,200); native[2]=CGRectMake(1000,91,500,600);
    parents[0]=parents[1]=parents[2]=0; managed[0]=managed[2]=true; managed[1]=false;
    in_motion=false; hwm_plane_scale=1; job_state=1; job_busy=false; clock_now=10;
    ax_moves=reset_calls=rides=transforms=alpha_changes=floated=layer_calls=0; hwm_drag_window=0; g_mouse_state.window=NULL;
    g_window_manager.focused_window_id=1;
}
/* The tile renderer drawing the owner at a new place this frame. */
static void owner_drawn(double x,double y,double scale) { windows[0].strip_last_frame.origin=CGPointMake(x,y); windows[0].strip_last_plane_scale=scale; }

static void test_owner_and_pan(void)
{
    reset();
    struct window *d=&windows[1];
    hwm_satellite_adopt(d);
    assert(d->strip_owner==1 && d->strip_owner_delta.x==200 && d->strip_owner_delta.y==100 && d->strip_sat_synced);
    // At rest nothing is sent.
    assert(!hwm_render_satellites(&plane,clock_now) && !rides && !transforms && !ax_moves);
    // The camera pans 300 points left at 100%: the dialog rides with its owner.
    in_motion=true; owner_drawn(-188,91,1); clock_now+=.016;
    assert(hwm_render_satellites(&plane,clock_now));
    assert(rides==1 && native[1].origin.x==12 && native[1].origin.y==191 && !d->strip_plane_scaled && !d->strip_sat_synced);
    // At rest AppKit is given that frame, once.
    in_motion=false; clock_now+=.2;
    hwm_render_satellites(&plane,clock_now);
    assert(ax_moves==1 && d->strip_sat_synced);
    hwm_render_satellites(&plane,clock_now+1); assert(ax_moves==1);
}

static void test_zoom_and_visibility(void)
{
    reset();
    struct window *d=&windows[1];
    hwm_satellite_adopt(d);
    // Zoomed to 50%: shown by transform at half the offset, native untouched.
    hwm_plane_scale=.5; in_motion=true; owner_drawn(112,91,.5);
    hwm_render_satellites(&plane,clock_now+=.016);
    assert(transforms==1 && rides==0 && d->strip_plane_scaled && d->strip_sat_shown.x==212 && d->strip_sat_shown.y==141);
    assert(ax_moves==0); // Never placed natively while zoomed out.
    // The owner panned off screen: the dialog goes with it, hidden.
    owner_drawn(-3000,91,.5); windows[0].strip_offscreen=true;
    hwm_render_satellites(&plane,clock_now+=.016);
    assert(d->strip_offscreen && alpha_changes==1);
    // Back at 100% on screen: placed, then revealed, then synced and untransformed.
    hwm_plane_scale=1; windows[0].strip_offscreen=false; owner_drawn(112,91,1);
    hwm_render_satellites(&plane,clock_now+=.016);
    assert(!d->strip_offscreen && alpha_changes==2 && rides==1 && native[1].origin.x==312);
    in_motion=false; hwm_render_satellites(&plane,clock_now+=.2);
    assert(d->strip_sat_synced && !d->strip_plane_scaled);
}

static void test_user_move_and_top_edge(void)
{
    reset();
    struct window *d=&windows[1];
    hwm_satellite_adopt(d);
    // Dragged by the user: never fought while the button is down.
    g_mouse_state.window=d; native[1].origin=CGPointMake(500,300);
    hwm_render_satellites(&plane,clock_now+=.1); assert(!rides && !ax_moves);
    // Released and settled: its new place is kept beside the owner.
    g_mouse_state.window=NULL; hwm_render_satellites(&plane,clock_now+=.5);
    assert(d->strip_owner_delta.x==388 && d->strip_owner_delta.y==209 && !rides && !ax_moves);
    in_motion=true; owner_drawn(12,91,1); hwm_render_satellites(&plane,clock_now+=.016);
    assert(native[1].origin.x==400 && native[1].origin.y==300);
    // Carried above the menu bar: drawn by transform; AppKit's clamp makes
    // the native placement fail, which is tried a few times and then left.
    owner_drawn(12,-300,1); hwm_render_satellites(&plane,clock_now+=.016);
    assert(d->strip_plane_scaled && transforms==1);
    in_motion=false; job_state=-1; int before=ax_moves;
    for(int i=0;i<8;i++) hwm_render_satellites(&plane,clock_now+=.2);
    assert(ax_moves-before==3 && d->strip_sat_synced && d->strip_plane_scaled && !reset_calls);
}

static void test_release_and_late_parent(void)
{
    reset();
    struct window *d=&windows[1];
    hwm_satellite_adopt(d);
    // The owner closing or leaving the plane lets the dialog stay where it is.
    d->strip_plane_scaled=true; managed[0]=false;
    hwm_render_satellites(&plane,clock_now+=.016);
    assert(!d->strip_owner && reset_calls==1);
    // No tile of its application under it or focused: no owner.
    reset(); g_window_manager.focused_window_id=3; native[1].origin=CGPointMake(1300,700);
    hwm_satellite_adopt(&windows[1]); assert(!windows[1].strip_owner);
    // A tile found to have a WindowServer parent after it was first seen
    // leaves the plane and follows that parent.
    reset();
    struct window *c=&windows[2]; c->application=&app_a; parents[2]=1;
    hwm_satellite_refresh_parent(c,parents[2]);
    assert(c->is_child && floated==1 && !managed[2] && layer_calls==1 && c->strip_owner==1);
    hwm_satellite_refresh_parent(c,parents[2]); assert(floated==1); // Once.
}

int main(void)
{
    @autoreleasepool {
        test_owner_and_pan(); test_zoom_and_visibility(); test_user_move_and_top_edge(); test_release_and_late_parent();
        puts("plane satellite tests passed");
    }
    return 0;
}
