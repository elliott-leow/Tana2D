/* Native fullscreen hand-off (src/plane_fullscreen.m), with WindowServer,
 * Accessibility and the plane replaced by a small model. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <string.h>

enum { WINDOW_FULLSCREEN=0x02 };
enum { VIEW_STRIP=4 };
typedef enum { HWM_PLANE_INTERRUPT_UNMANAGE, HWM_PLANE_INTERRUPT_FULLSCREEN } HWMPlaneInterruptReason;
struct view { int layout; };
struct window {
    uint32_t id; AXUIElementRef ref; uint8_t flags; CGRect frame;
    double strip_world_x,strip_world_y,strip_width,strip_height,strip_native_resize_until;
    bool strip_size_pending,strip_native_resize_pending,strip_native_move_pending,strip_transform_dirty,strip_full_width;
    bool strip_fullscreen_away,strip_fullscreen_probe;
    CGRect strip_fullscreen_world; CGSize strip_fullscreen_checked;
};

/* The model: three windows on a 1710x1112 display, plane Space 1. */
static struct window windows[3];
static CGRect bounds[3];
static uint64_t spaces[3];
static bool ax_fullscreen[3],ax_settable[3]={true,true,true},managed[3];
static int ax_queries,ax_sets,aborts,resets,untiles,retiles,layouts,focused_calls,cancels,menus;
static CFBooleanRef ax_set_value;
static NSString *last_hud;
static struct view plane={VIEW_STRIP};
static uint64_t hwm_space=1;
static bool plane_visible=true,hwm_ready=true;
static _Atomic bool hwm_plane_hidden;
static double clock_now=100;
static struct { uint32_t focused_window_id; int window; } g_window_manager;
static int g_space_manager,g_connection;
static const CFStringRef kAXFullscreenAttribute=CFSTR("AXFullScreen");

static int index_of(uint32_t id) { return id>=1 && id<=3 ? (int)id-1 : -1; }
#define table_for(it,table,code) for(int table_i=0;table_i<3;table_i++) { it=&windows[table_i]; code; }
static void window_set_flag(struct window *w,uint8_t f) { w->flags|=f; }
static void window_clear_flag(struct window *w,uint8_t f) { w->flags&=~f; }
static bool window_check_flag(struct window *w,uint8_t f) { return (w->flags&f)!=0; }
static struct window *window_manager_find_window(void *m,uint32_t id) { (void)m; int i=index_of(id); return i<0?NULL:&windows[i]; }
static struct view *window_manager_find_managed_window(void *m,struct window *w) { (void)m; return managed[w->id-1]?&plane:NULL; }
static void window_manager_remove_managed_window(void *m,uint32_t id) { (void)m; managed[id-1]=false; }
static void window_manager_add_managed_window(void *m,struct window *w,struct view *v) { (void)m; managed[w->id-1]=v!=NULL; }
static void space_manager_untile_window(struct view *v,struct window *w) { (void)v; (void)w; ++untiles; }
static struct view *space_manager_tile_window_on_space(void *sm,struct window *w,uint64_t sid) { (void)sm; (void)w; assert(sid==hwm_space); ++retiles; return &plane; }
static bool window_manager_should_manage_window(struct window *w) { return !window_check_flag(w,WINDOW_FULLSCREEN); }
static uint64_t window_space(uint32_t id) { return spaces[id-1]; }
static bool space_is_visible(uint64_t sid) { return sid==hwm_space ? plane_visible : !plane_visible; }
static bool hwm_window_left_strip(struct window *w) { return hwm_space && window_space(w->id)!=hwm_space; }
static CGError SLSGetWindowBounds(int c,uint32_t id,CGRect *out) { (void)c; *out=bounds[id-1]; return kCGErrorSuccess; }
static bool window_is_fullscreen(struct window *w) { ++ax_queries; return ax_fullscreen[w->id-1]; }
static AXError mock_settable(AXUIElementRef e,CFStringRef a,Boolean *out) { (void)a; *out=ax_settable[(int)(intptr_t)e-1]; return kAXErrorSuccess; }
static AXError mock_set(AXUIElementRef e,CFStringRef a,CFTypeRef v) { (void)a; ++ax_sets; ax_set_value=(CFBooleanRef)v; ax_fullscreen[(int)(intptr_t)e-1]=CFBooleanGetValue(v); return kAXErrorSuccess; }
#define AXUIElementIsAttributeSettable mock_settable
#define AXUIElementSetAttributeValue mock_set
static CGError mock_displays(CGPoint p,uint32_t max,CGDirectDisplayID *out,uint32_t *count) { (void)max; *count=CGRectContainsPoint(CGRectMake(0,0,1710,1112),p)?1:0; if(*count) *out=1; return kCGErrorSuccess; }
static CGRect mock_display_bounds(CGDirectDisplayID d) { (void)d; return CGRectMake(0,0,1710,1112); }
#define CGGetDisplaysWithPoint mock_displays
#define CGDisplayBounds mock_display_bounds
static void hwm_plane_abort_interaction(struct window *w,HWMPlaneInterruptReason r) { (void)w; assert(r==HWM_PLANE_INTERRUPT_FULLSCREEN); ++aborts; }
static bool hwm_plane_reset_transform(struct window *w) { (void)w; ++resets; return true; }
static struct view *hwm_view(void) { return &plane; }
static void hwm_layout(struct view *v,bool animate) { (void)v; (void)animate; ++layouts; }
static void hwm_wake(void) {}
static double hwm_now(void) { return clock_now; }
static void horizontal_focused(struct window *w,struct view *v) { (void)w; assert(v==&plane); ++focused_calls; }
static void hwm_workspace_cancel(void) { ++cancels; }
static void hwm_menu_status(void) { ++menus; }
static void hwm_hud(NSString *text) { last_hud=text; }
static void debug(const char *format,...) { (void)format; }
#include "../src/plane_fullscreen.m"

static void reset(void)
{
    for(int i=0;i<3;i++) {
        windows[i]=(struct window){.id=(uint32_t)i+1,.ref=(AXUIElementRef)(intptr_t)(i+1),
            .strip_world_x=400.0*i,.strip_world_y=20,.strip_width=500,.strip_height=600};
        bounds[i]=CGRectMake(12+520*i,51,500,600); spaces[i]=1; ax_fullscreen[i]=false; ax_settable[i]=true; managed[i]=true;
    }
    ax_queries=ax_sets=aborts=resets=untiles=retiles=layouts=focused_calls=cancels=menus=0;
    hwm_fullscreen_probe_count=0; plane_visible=true; atomic_store(&hwm_plane_hidden,false); last_hud=nil;
    g_window_manager.focused_window_id=1;
}

/* Entering: the tile leaves the plane at once and keeps its world rect. */
static void test_enter(void)
{
    reset();
    struct window *w=&windows[0];
    // An ordinary resize never asks the application about fullscreen.
    bounds[0].size=CGSizeMake(640,700);
    assert(!hwm_fullscreen_began(w,&plane) && ax_queries==0 && managed[0]);
    // The green button: a display-sized frame (below a notch) that reports fullscreen.
    bounds[0]=CGRectMake(0,38,1710,1074); ax_fullscreen[0]=true;
    assert(hwm_fullscreen_began(w,&plane));
    assert(ax_queries==1 && !managed[0] && untiles==1 && aborts==1 && resets==1);
    assert(window_check_flag(w,WINDOW_FULLSCREEN) && w->strip_fullscreen_away);
    assert(CGRectEqualToRect(w->strip_fullscreen_world,CGRectMake(0,20,500,600)));
    assert(CGRectEqualToRect(w->frame,bounds[0])); // The engine sees leaving as a change.
    // Its later notifications are not the plane's.
    assert(!hwm_fullscreen_began(w,window_manager_find_managed_window(NULL,w)));
    // A tile that has moved to the fullscreen Space is asked even before
    // its frame reaches display size.
    struct window *v=&windows[1]; spaces[1]=7; ax_fullscreen[1]=true;
    assert(hwm_fullscreen_began(v,&plane) && !managed[1]);
}

/* The renderers never adopt a fullscreen frame as the tile's size, and an
 * ordinary display-sized window is asked once and then adopted. */
static void test_renderer_probe(void)
{
    reset();
    struct window *w=&windows[0];
    assert(hwm_fullscreen_frame_adoptable(w,CGRectMake(12,51,900,700)) && !hwm_fullscreen_probe_count);
    // Zoomed with Option and the green button: as large as fullscreen, but windowed.
    CGRect zoomed=CGRectMake(0,38,1710,1074); bounds[0]=zoomed;
    assert(!hwm_fullscreen_frame_adoptable(w,zoomed) && hwm_fullscreen_probe_count==1 && w->strip_fullscreen_probe);
    assert(!hwm_fullscreen_frame_adoptable(w,zoomed) && hwm_fullscreen_probe_count==1); // Queued once.
    assert(ax_queries==0); // No Accessibility inside a frame.
    hwm_fullscreen_probe_drain();
    assert(ax_queries==1 && managed[0] && !w->strip_fullscreen_probe);
    assert(hwm_fullscreen_frame_adoptable(w,zoomed) && !hwm_fullscreen_probe_count);
    assert(!hwm_fullscreen_began(w,&plane) && ax_queries==1); // Known windowed size: not asked again.
    // The same tile then entering fullscreen is still caught once it leaves the Space.
    spaces[0]=7; ax_fullscreen[0]=true;
    assert(hwm_fullscreen_began(w,&plane) && ax_queries==2 && !managed[0]);
    // A fullscreen frame met first by the renderer leaves at the drain.
    struct window *v=&windows[1]; bounds[1]=zoomed; ax_fullscreen[1]=true;
    assert(!hwm_fullscreen_frame_adoptable(v,zoomed));
    hwm_fullscreen_probe_drain();
    assert(!managed[1] && v->strip_fullscreen_away && v->strip_width==500 && v->strip_height==600);
}

/* Leaving: the tile returns to its world rect at the restored size. */
static void test_exit(void)
{
    reset();
    struct window *w=&windows[0];
    bounds[0]=CGRectMake(0,38,1710,1074); ax_fullscreen[0]=true; spaces[0]=7;
    assert(hwm_fullscreen_began(w,&plane));
    w->strip_world_x=-9999; w->strip_width=1710; // Whatever happened meanwhile.
    // The engine re-tiles it after its exit resize, then hands it back.
    ax_fullscreen[0]=false; spaces[0]=1; window_clear_flag(w,WINDOW_FULLSCREEN); managed[0]=true;
    horizontal_fullscreen_exited(w);
    assert(!w->strip_fullscreen_away && w->strip_world_x==0 && w->strip_world_y==20 && w->strip_width==500 && w->strip_height==600);
    assert(w->strip_native_resize_pending && w->strip_native_resize_until>clock_now && w->strip_transform_dirty);
    assert(focused_calls==1 && layouts>=2);
    horizontal_fullscreen_exited(w); assert(focused_calls==1); // Once only.

    // The exit notification read fullscreen still: the sweep finds it back.
    reset(); w=&windows[1]; g_window_manager.focused_window_id=1;
    bounds[1]=CGRectMake(0,38,1710,1074); ax_fullscreen[1]=true; spaces[1]=7;
    assert(hwm_fullscreen_began(w,&plane));
    hwm_fullscreen_sweep(); assert(!managed[1] && w->strip_fullscreen_away); // Still in fullscreen.
    spaces[1]=1; ax_fullscreen[1]=false; bounds[1]=CGRectMake(532,51,500,600);
    hwm_fullscreen_sweep();
    assert(managed[1] && retiles==1 && !w->strip_fullscreen_away && !window_check_flag(w,WINDOW_FULLSCREEN));
    assert(w->strip_world_x==400 && focused_calls==0); // Not focused: the camera stays.
}

/* While the fullscreen Space is in front, gestures and the pointer are
 * macOS's; tiles found on it are handed off; coming back restores both. */
static void test_space_change(void)
{
    reset();
    spaces[2]=7; ax_fullscreen[2]=true; plane_visible=false;
    hwm_fullscreen_space_changed();
    assert(atomic_load(&hwm_plane_hidden) && cancels==1 && menus==1);
    assert(!managed[2] && windows[2].strip_fullscreen_away && managed[0] && managed[1]);
    hwm_fullscreen_space_changed(); assert(cancels==1); // Entering is noted once.
    spaces[2]=1; ax_fullscreen[2]=false; plane_visible=true;
    hwm_fullscreen_space_changed();
    assert(!atomic_load(&hwm_plane_hidden) && managed[2] && !windows[2].strip_fullscreen_away);
    // A missed Space notification is corrected by the sweep.
    plane_visible=false; hwm_fullscreen_sweep(); assert(atomic_load(&hwm_plane_hidden));
    plane_visible=true; hwm_fullscreen_sweep(); assert(!atomic_load(&hwm_plane_hidden));
}

/* F11 toggles the focused window like its green button. */
static void test_toggle(void)
{
    reset();
    hwm_fullscreen_toggle();
    assert(ax_sets==1 && ax_set_value==kCFBooleanTrue && ax_fullscreen[0] && resets==1);
    hwm_fullscreen_toggle();
    assert(ax_sets==2 && ax_set_value==kCFBooleanFalse && !ax_fullscreen[0]);
    ax_settable[0]=false; hwm_fullscreen_toggle();
    assert(ax_sets==2 && [last_hud isEqual:@"This window has no full screen mode"]);
    g_window_manager.focused_window_id=0; hwm_fullscreen_toggle();
    assert(ax_sets==2 && [last_hud isEqual:@"No window to make full screen"]);
}

int main(void)
{
    @autoreleasepool {
        test_enter(); test_renderer_probe(); test_exit(); test_space_change(); test_toggle();
        puts("plane fullscreen tests passed");
    }
    return 0;
}
