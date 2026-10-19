/* Tana2D. MIT license; see LICENSE. */
#include <math.h>
#include <stdatomic.h>
#include "strip_geometry.h"
#include "plane_geometry.h"
#include "strip_columns.h"
#include "focus_policy.h"
#include "window_overview.m"
#include "tana_config.m"
#include "strip_workflow.h"

extern struct window_manager g_window_manager;
extern struct space_manager g_space_manager;
extern struct mouse_state g_mouse_state;
extern struct event_loop g_event_loop;
extern volatile bool __pending_gesture;
extern volatile uint64_t __last_gesture_time;

static _Atomic bool hwm_ready, hwm_paused;
static double hwm_screen_stamp=-10; // Usable-screen cache; reset whenever the display, Dock or menu bar reports a change.
static double hwm_display_left;
static bool hwm_backend_ok = true;
static uint64_t hwm_space;
static CVDisplayLinkRef hwm_display_link;
static _Atomic bool hwm_ca_clock_running;
static _Atomic double hwm_ca_target_time,hwm_display_max_hz;
static void hwm_ca_stop(void);
static void hwm_ca_rebind(void);
static dispatch_source_t hwm_fallback_timer;
static _Atomic bool hwm_suspended;
static _Atomic bool hwm_overview_active;
static _Atomic double hwm_overview_progress;
static _Atomic uint64_t hwm_overview_generation;
static _Atomic unsigned hwm_overview_window_count;
static void hwm_overview_tick(void);
static bool hwm_vertical_swiping;
static uint64_t hwm_vertical_swipe_time;
static double hwm_vertical_last_progress;
static void hwm_start_clock(void);
static bool hwm_tick_pending, hwm_active;
static bool hwm_reconcile_pending;
static bool hwm_swiping; // Only accessed by the main-thread event tap.
static uint64_t hwm_swipe_time;
static bool hwm_keys[128];
static bool hwm_tab_click;
static double hwm_duration = 0.36; // Settle horizon of the tile springs.
static double hwm_scroll_omega = 22;
static double hwm_rubber; // Signed overscroll shown while a finger holds the strip past an end.
/* Finger reports and display refreshes are not in step: a frame can follow one
 * report, two, or none, so a steady swipe drawn straight from the latest
 * report advances in uneven steps. Each frame of a held swipe is instead drawn
 * where the fingers are at that frame, carried on from the latest report at
 * the speed they were moving, for no longer than about one report interval. */
static double hwm_held_velocity, hwm_held_time, hwm_held_lead;
/* How far past the newest report a frame may be drawn. The frame is shown at
 * the vsync the clock named, a whole refresh after the tick; a fixed 12 ms
 * covered that on a 120 Hz panel but left a 60 Hz panel's frames drawn for
 * a moment 5 to 10 ms before they appeared, so the strip trailed the fingers
 * by that much. One refresh plus a report interval's slack, bounded so a
 * reversal never overshoots by more than a frame or two of travel. */
static _Atomic double hwm_display_hz;
static double hwm_held_lead_max(void)
{
    double hz=hwm_display_hz, interval=hz>1 ? 1/hz : 1.0/60;
    return fmax(.012,fmin(.022,interval+.004));
}
#define HWMHeldLeadMax hwm_held_lead_max()
/* A speed is read from at least three reports spread over this long. The
 * first reports of a gesture often arrive bunched within a millisecond; a
 * line through two of them read as a huge speed, and the first frames of a
 * pinch leapt ahead of the fingers and then stood still while they caught up. */
static const double HWMHeldLeadSpan=.02;
/* The last few reports of the swipe in hand. Reports reach this process
 * bunched and late by varying amounts, so one report and its neighbour are a
 * poor measure of speed; a line through the last twentieth of a second is not. */
enum { HWM_HELD_SAMPLES=6 };
static struct { double time, offset; } hwm_held_samples[HWM_HELD_SAMPLES];
static int hwm_held_count;
static void hwm_held_note(double time,double offset)
{
    if(hwm_held_count==HWM_HELD_SAMPLES) memmove(hwm_held_samples,hwm_held_samples+1,(HWM_HELD_SAMPLES-1)*sizeof(*hwm_held_samples));
    else ++hwm_held_count;
    hwm_held_samples[hwm_held_count-1].time=time; hwm_held_samples[hwm_held_count-1].offset=offset;
}
/* Where the fingers have brought the strip by `time`, less the latest report. */
static double hwm_held_lead_at(double time,double latest)
{
    if(hwm_held_count<2) return 0;
    double newest=hwm_held_samples[hwm_held_count-1].time, st=0, sx=0, stt=0, stx=0; int n=0;
    double oldest=0;
    for(int i=hwm_held_count-1;i>=0 && newest-hwm_held_samples[i].time<=.05;i--) {
        double t=hwm_held_samples[i].time-newest, x=hwm_held_samples[i].offset;
        st+=t; sx+=x; stt+=t*t; stx+=t*x; ++n; oldest=t;
    }
    double spread=n*stt-st*st;
    if(n<3 || -oldest<HWMHeldLeadSpan || !(spread>1e-9)) return 0;
    double speed=(n*stx-st*sx)/spread, at_newest=(sx-speed*st)/n;
    hwm_held_velocity=speed;
    double ahead=fmax(0,fmin(HWMHeldLeadMax,time-newest));
    // Never further from the latest report than the fingers could have travelled since.
    double lead=at_newest+speed*ahead-latest, limit=fabs(speed)*(HWMHeldLeadMax+.004);
    return fmax(-limit,fmin(limit,lead));
}
/* The plane's three-finger pan, resampled the same way on both axes. The
 * camera the gesture integrates is the latest report (hwm_pan_raw); each frame
 * is drawn at that plus how far the fingers have moved by the frame's vsync. */
static bool hwm_pan_raw_valid;
static double hwm_pan_raw_x,hwm_pan_raw_y;
static struct { double time,x,y; } hwm_pan_samples[HWM_HELD_SAMPLES];
static int hwm_pan_count;
static void hwm_pan_note(double time,double x,double y)
{
    if(hwm_pan_count==HWM_HELD_SAMPLES) memmove(hwm_pan_samples,hwm_pan_samples+1,(HWM_HELD_SAMPLES-1)*sizeof(*hwm_pan_samples));
    else ++hwm_pan_count;
    hwm_pan_samples[hwm_pan_count-1].time=time; hwm_pan_samples[hwm_pan_count-1].x=x; hwm_pan_samples[hwm_pan_count-1].y=y;
}
static void hwm_pan_lead_at(double time,double *lead_x,double *lead_y)
{
    *lead_x=*lead_y=0;
    if(hwm_pan_count<2) return;
    double newest=hwm_pan_samples[hwm_pan_count-1].time,st=0,stt=0,sx=0,stx=0,sy=0,sty=0; int n=0;
    double oldest=0;
    for(int i=hwm_pan_count-1;i>=0 && newest-hwm_pan_samples[i].time<=.05;i--) {
        double t=hwm_pan_samples[i].time-newest;
        st+=t; stt+=t*t; sx+=hwm_pan_samples[i].x; stx+=t*hwm_pan_samples[i].x; sy+=hwm_pan_samples[i].y; sty+=t*hwm_pan_samples[i].y; ++n; oldest=t;
    }
    double spread=n*stt-st*st;
    if(n<3 || -oldest<HWMHeldLeadSpan || !(spread>1e-9)) return;
    double ahead=fmax(0,fmin(HWMHeldLeadMax,time-newest));
    double vx=(n*stx-st*sx)/spread,vy=(n*sty-st*sy)/spread;
    double ax=(sx-vx*st)/n+vx*ahead-hwm_pan_raw_x,ay=(sy-vy*st)/n+vy*ahead-hwm_pan_raw_y;
    // Never further from the latest report than the fingers could have travelled since.
    double lx=fabs(vx)*(HWMHeldLeadMax+.004),ly=fabs(vy)*(HWMHeldLeadMax+.004);
    *lead_x=fmax(-lx,fmin(lx,ax)); *lead_y=fmax(-ly,fmin(ly,ay));
}
/* When a trackpad report was made, rather than when this thread got to it. */
static double hwm_event_time(CGEventRef event,double now)
{
    double stamp=(double)CGEventGetTimestamp(event)/1e9;
    return stamp<=now && now-stamp<.05 ? stamp : now;
}
static bool hwm_swiping_columns; // A swipe has already found its first column.
static int hwm_snap = 2; // 0 free, 1 column edges, 2 centre the nearest column
static double hwm_magnet = .1; // Pull toward a centred column while the strip is held.
static double hwm_snap_threshold = .15; // Share of the way to the next column that commits a swipe to it.
static double hwm_swipe_gain = 1.15; // Strip travel per unit of finger travel.
static double hwm_pinch_gain = 1.35; // Zoom (in log scale) per unit of trackpad magnification.
static double hwm_snap_origin; // Where the strip rested when the current swipe began.
static int hwm_focus_follow = 2; // After the strip is moved: 0 leave focus, 1 focus the window brought to the centre, 2 the one under the pointer.
static void hwm_focus_follow_to(struct view *view,double offset);
static bool hwm_settle_pending; // A wheel pan has no release event; settle when it goes quiet.
static int hwm_new_placement; // 0 centre gap, 1 beside focused, 2 strip end
static uint32_t hwm_nav_window; // Keyboard navigation cursor; leads the reported focus.
static double hwm_nav_time;
static bool hwm_nav_pending;
static bool hwm_nav_automatic;
static void hwm_nav_flush(void);
static void hwm_preview_show(CGRect target,CGRect start,bool animate);
static bool hwm_move_column(struct view *view,struct window *window,int mode);
static bool hwm_place(struct view *view,uint32_t source,uint32_t target,HStripPlacement placement,bool commit,CGRect *preview);
static double hwm_snap_target(struct view *view,double desired,double viewport,bool swipe);
static NSString *hwm_terminal_command, *hwm_browser_command;
static double hwm_config_mtime;
static void hwm_config_poll(void);
static void hwm_alpha_sync(bool restore);
static _Atomic double hwm_motion_scale=1;
static double hwm_scroll_initial_velocity,hwm_scroll_current_velocity;
static bool hwm_release_velocity;
/* The x camera remains in view->strip_offset for compatibility with the
 * vendored manager.  The independent y camera makes the managed space a
 * plane; neither axis has an edge or a shelf boundary. */
static double hwm_plane_y, hwm_plane_y_from, hwm_plane_y_target, hwm_plane_y_start;
static double hwm_plane_y_initial_velocity, hwm_plane_y_current_velocity;
static bool hwm_plane_y_scrolling;
#include "plane_gesture.h"
#include "plane_pinch.h"
static HWMPlaneGesture hwm_plane_gesture;
/* The two-finger pinch read from the raw contacts (plane_pinch.h). The
 * recogniser runs on the multitouch thread; what the event tap needs to know
 * is shared through these. hwm_contact_pinch_state: 0 no pair in hand, 1 a
 * pair still undecided, 2 zooming. hwm_contact_pinch_seen: when a pair was
 * last reported, on this process's clock. */
static HWMPlanePinch hwm_contact_pinch;
static _Atomic int hwm_contact_pinch_state;
static _Atomic double hwm_contact_pinch_seen=-10;
typedef struct { double time,delta; int phase; } HWMPlanePinchFrame;
static HWMPlaneCamera hwm_plane_pan_origin;
static HWMPlaneVelocity hwm_plane_pan_velocity;
static HWMPlaneSelectionGesture hwm_selection_gesture;
static double hwm_plane_scale=1;
static bool hwm_camera_animating;
static HWMPlaneCamera hwm_camera_from,hwm_camera_target;
static double hwm_camera_start,hwm_camera_width,hwm_camera_height,hwm_camera_duration=.36;
// Progress per second the current transition started with (see hwm_plane_camera_launch).
static double hwm_camera_launch,hwm_camera_rate;
static _Atomic bool hwm_plane_selecting;
/* Browsing owns input; live app windows are always native and unscaled. */
#define HWM_NATIVE_ZOOM 1
static bool hwm_zoom_workspace;
static uint32_t hwm_zoom_buttons;
static bool hwm_zoom_render_native(struct view *view,double now);
static void hwm_zoom_hover_tick(void);
static bool hwm_zoom_rest_focus_armed;
static double hwm_zoom_pinch_time=-1; // Last pinch sample; hover waits for the zoom to rest.
// The last pinch moved toward 100% at hwm_zoom_detent_point; see hwm_plane_zoom_detent.
static bool hwm_zoom_detent_armed;
static CGPoint hwm_zoom_detent_point;
static void hwm_zoom_rest_focus(struct view *view);
static void hwm_zoom_cancel_native(void);
static bool hwm_zoom_native_busy(uint32_t wid);
static bool hwm_zoom_wait_native(uint32_t wid);
static bool hwm_zoom_size_restoring(uint32_t wid);
static bool hwm_zoom_waiting_only; // See native_zoom.m.
static bool hwm_zoom_landing; // Native frames are still being placed after motion.
static bool hwm_plane_select_click;
static bool hwm_plane_pick_automatic;
static uint32_t hwm_plane_pick_window;
static CGPoint hwm_plane_pick_origin;
static void hwm_plane_pointer(CGEventType type,CGPoint point);
static void hwm_plane_pointer_finish(bool choose);
static void hwm_plane_transition_to(struct view *view,double x,double y,double scale,bool animate);
static bool hwm_plane_fit_active;
static bool hwm_magnetic_centering=false;
static bool hwm_auto_center=true,hwm_pan_momentum=true;
static double hwm_auto_center_radius=180;
static void hwm_plane_set_camera(struct view *view,double x,double y,bool animate);
static void hwm_plane_fit_all(struct view *view);
static void hwm_plane_fit_focused(struct view *view);
static void hwm_plane_actual_size(struct view *view);
static void hwm_plane_arrange_grid(struct view *view);
static void hwm_feedback_navigation(bool wall);
static void hwm_feedback_focus(struct window *previous,struct window *next);
static void hwm_feedback_tick(struct view *view,double now);
static void hwm_feedback_hide(void);
static _Atomic bool hwm_pointer_focus=false;
static uint64_t hwm_frames, hwm_slow_frames, hwm_move_failures, hwm_resize_operations;
static _Atomic uint64_t hwm_key_actions;
static double hwm_max_frame_ms;
static double hwm_last_input;
static uint32_t hwm_resize_window;
static _Atomic uint32_t hwm_drag_window;
static uint32_t hwm_drop_target;
static HStripPlacement hwm_drop_placement;
static CGPoint hwm_drag_point;
static double hwm_drag_tick_time;
static bool hwm_drag_camera_owned;
static bool hwm_plane_pointer_owned(void);
static HWMPlaneEdgePan hwm_drag_edge_pan;
static bool hwm_drag_cancelled,hwm_drag_shadow;
/* Worst time per tick section since the last `profile-reset`, in ms. */
enum { HWM_PROF_DRAG, HWM_PROF_RENDER, HWM_PROF_EXTRAS, HWM_PROF_PREVIEW, HWM_PROF_FEEDBACK, HWM_PROF_TICK_DRAGGING, HWM_PROF_BORDER, HWM_PROF_RELEASE, HWM_PROF_HOVER, HWM_PROF_BORDER_PAINT, HWM_PROF_BORDER_SHAPE, HWM_PROF_COUNT };
static double hwm_prof[HWM_PROF_COUNT];
static uint64_t hwm_prof_drag_ticks, hwm_prof_drag_events;
static double hwm_now(void);
static double hwm_prof_mark(int slot,double since) { double t=hwm_now(), ms=(t-since)*1000; if(ms>hwm_prof[slot]) hwm_prof[slot]=ms; return t; }
/* Frame pacing, as opposed to frame cost: how long a tick waited to run after
 * the display asked for it, how often an animating strip missed a refresh, and
 * which other event-loop work held the frame thread up meanwhile. */
static uint64_t hwm_tick_posted;
static uint64_t hwm_tick_late, hwm_frames_dropped, hwm_stalls;
static double hwm_tick_latency_max_ms, hwm_tick_latency_total_ms, hwm_frame_gap_max_ms, hwm_stall_max_ms;
static double hwm_tick_previous; static bool hwm_tick_previous_active;
static double hwm_drawn_time; // When a frame was last actually drawn.
static int hwm_stall_type=-1;
static struct { uint64_t count; double total_ms, max_ms; } hwm_event_prof[64];
static const char *hwm_event_names[] = {
#define EVENT_TYPE_ENTRY(value) #value,
    EVENT_TYPE_LIST
#undef EVENT_TYPE_ENTRY
};
enum { HWM_FRAME_LOG=1024 };
static struct { double time, offset, tick_ms, latency_ms, camera_y, scale; } hwm_frame_log[HWM_FRAME_LOG];
static struct { double time, offset; } hwm_input_log[HWM_FRAME_LOG];
static uint64_t hwm_frame_log_count, hwm_input_log_count;
static double hwm_helper_due; // When to run the helper's loader after a Dock restart; 0 for never.
/* Whether the strip's Space is the one on screen. Asking costs WindowServer
 * round trips on every frame; the answer changes only with the events that
 * reset hwm_space_visible_stamp, and is checked twice a second regardless. */
static double hwm_space_visible_stamp=-10;
static uint64_t hwm_space_visible_sid;
static bool hwm_space_visible;
static bool hwm_view_space_visible(struct view *view,double now)
{
    if(view->sid!=hwm_space_visible_sid || now-hwm_space_visible_stamp>.5) {
        hwm_space_visible_sid=view->sid; hwm_space_visible_stamp=now;
        hwm_space_visible=space_is_visible(view->sid);
    }
    return hwm_space_visible;
}
static void horizontal_event_timed(int type,double ms)
{
    if(type<0 || type>=64) return;
    if((type>=DISPLAY_ADDED && type<=DISPLAY_CHANGED) || type==SPACE_CHANGED || type==DOCK_DID_RESTART || type==MENU_BAR_HIDDEN_CHANGED ||
       type==DOCK_DID_CHANGE_PREF || type==SYSTEM_WOKE) hwm_screen_stamp=hwm_space_visible_stamp=-10;
    if((type>=DISPLAY_ADDED && type<=DISPLAY_CHANGED) || type==SPACE_CHANGED || type==SYSTEM_WOKE)
        dispatch_async(dispatch_get_main_queue(),^{ if(hwm_ready) hwm_ca_rebind(); });
    // The helper went with the old Dock; give the new one a moment to come up.
    if(type==DOCK_DID_RESTART) hwm_helper_due=hwm_now()+1.5;
    ++hwm_event_prof[type].count; hwm_event_prof[type].total_ms+=ms;
    if(ms>hwm_event_prof[type].max_ms) hwm_event_prof[type].max_ms=ms;
    // Anything but a frame that takes this long while the strip is animating delays the next frame.
    if(type!=HORIZONTAL_TICK && ms>2 && hwm_tick_previous_active) {
        ++hwm_stalls;
        if(ms>hwm_stall_max_ms) { hwm_stall_max_ms=ms; hwm_stall_type=type; }
    }
}
static double hwm_tick_note(double now)
{
    uint64_t posted=__atomic_load_n(&hwm_tick_posted,__ATOMIC_RELAXED);
    double latency=posted ? (now-(double)posted/(double)read_os_freq())*1000 : 0;
    if(latency<0 || latency>1000) latency=0;
    hwm_tick_latency_total_ms+=latency;
    if(latency>4) ++hwm_tick_late;
    if(latency>hwm_tick_latency_max_ms) hwm_tick_latency_max_ms=latency;
    if(hwm_tick_previous_active) {
        double gap=(now-hwm_tick_previous)*1000;
        // A frame is dropped when the gap exceeds one and a half refresh
        // intervals of the panel actually driving the clock (60 or 120 Hz).
        double period=hwm_display_hz>1 ? 1000/hwm_display_hz : 1000/60.0;
        if(gap>period*1.5 && gap<1000) ++hwm_frames_dropped;
        if(gap<1000 && gap>hwm_frame_gap_max_ms) hwm_frame_gap_max_ms=gap;
    }
    hwm_tick_previous=now;
    return latency;
}
static CGPoint hwm_drag_move;
static bool hwm_drag_move_pending,hwm_drag_native_moved;
static CGPoint hwm_drag_world_origin, hwm_drag_pointer_origin;
static double hwm_drag_camera_x, hwm_drag_camera_y, hwm_drag_scale;
static uint64_t hwm_drag_present_count;
static double hwm_drag_present_total_ms,hwm_drag_present_max_ms;
static _Atomic bool hwm_plane_pick_drag_queued;
static void hwm_drag_autoscroll(struct view *view,double now);
static void hwm_cancel_drag(void);
static double hwm_focus_guard_time;
static CGPoint hwm_focus_guard_point;
static bool hwm_focus_guard;
static pid_t hwm_hover_pid;
static double hwm_hover_time;
static uint32_t hwm_close_source, hwm_close_target;
static double hwm_close_screen_x, hwm_close_time;
static uint32_t hwm_preserve_focus_window;
static uint32_t hwm_requested_focus; static double hwm_requested_focus_time; // See horizontal_expected_focus.
static double hwm_preserve_focus_until;
static uint32_t hwm_previous_focus;
static double hwm_previous_focus_time,hwm_previous_focus_offset;
static CGRect hwm_preview_from, hwm_preview_target, hwm_preview_current;
static double hwm_preview_start;
static bool hwm_preview_visible;
static bool hwm_preview_hiding;
static double hwm_preview_alpha, hwm_preview_alpha_from, hwm_preview_alpha_start;
static bool hwm_preview_render(double now);
static void hwm_preview_hide(void);
static void hwm_preview_hide_immediately(void);
static double hwm_last_backend_retry;
static bool hwm_focus_after_scroll;
static volatile sig_atomic_t hwm_stop_requested;
static void hwm_shutdown(void);
static void hwm_save_state(void);
static void hwm_save_state_now(bool wait);
static void hwm_load_state(void);
static bool hwm_state_pending;
static bool hwm_resume_load_state;
static void hwm_hold_focus(void);
static void hwm_undo_capture(void);
static bool hwm_undo_restore(void);
static bool hwm_named_action(const char *name);
static TanaConfig *hwm_config;
static NSArray *hwm_width_presets(void);
static bool hwm_config_reload(bool announce);
static bool hwm_hot_reload=true;
static NSArray *hwm_config_problems;
static double hwm_overview_duration=.34, hwm_overview_dim=.38;
static void hwm_spawn(NSString *command);
static void hwm_apply_app_rule(struct window *window);
static void hwm_apply_app_rule_now(struct window *window);
static void hwm_config_begin(void);
static void hwm_menu_refresh_bindings(void);
static struct window *hwm_tile(uint32_t wid);
static double hwm_rendered_offset, hwm_rendered_camera_y; // The camera of the frame last drawn.
static int hwm_shelf_limit(struct view *view);
static NSString *hwm_shelf_label(int shelf);
static struct window_node *hwm_slot(struct window_node *node);
static void hwm_shelf_go(int target,bool focus);
static void hwm_shelf_gesture(CGEventRef event);
static bool hwm_render_shelf_floats(struct view *view,double now);
static int hwm_vertical_mode; // 0: a vertical swipe opens the overview. 1: it changes strip. 2: the same, reversed.
static double hwm_feedback_shelf_time;
static bool hwm_extras_action(const char *name);
static void hwm_ipc_layout(struct view *view);
static _Atomic int hwm_key_capture; // The next key press names a mark: 1 to set it, 2 to go to it.
static _Atomic uint64_t hwm_key_capture_time;
static bool hwm_mark_apply(int code,int mode);
static void hwm_attention_apps(NSArray *pids);
static void hwm_attention_seen(struct window *focused);
static void hwm_attention_poll(double now);
static void hwm_helper_reload(void);
static void hwm_helper_tick(double now);
static int hwm_helper_attempts;
static bool hwm_auto_pip=true;
static double hwm_center_target(struct view *view,struct window *w);
static void hwm_place_unplaced(struct view *view);
static void hwm_action(int action);
static bool hwm_feedback_animating(double now);
static void hwm_focus_any(struct window *w);
static struct window *hwm_action_window(void);
static void hwm_arrangement_window_opened(void);

enum hwm_action { HWM_EVENT, HWM_TOUCH_FRAME, HWM_PINCH_FRAME, HWM_PLANE_PICK, HWM_PLANE_RESIZE, HWM_PLANE_INTERRUPT, HWM_LEFT, HWM_RIGHT, HWM_MOVE_LEFT, HWM_MOVE_RIGHT,
                  HWM_FLOAT, HWM_FULL, HWM_CENTER, HWM_HOME, HWM_PAUSE, HWM_REFLOW, HWM_QUIT, HWM_CLOSE, HWM_TERMINAL, HWM_BROWSER,
                  HWM_MOVE_FIRST, HWM_MOVE_LAST, HWM_OVERVIEW_FILTER, HWM_OVERVIEW_DRAG, HWM_OVERVIEW_HIGHLIGHT, HWM_OVERVIEW, HWM_OVERVIEW_GESTURE, HWM_OVERVIEW_CANCEL, HWM_OVERVIEW_POINTER, HWM_OVERVIEW_KEY, HWM_CANCEL_DRAG, HWM_NAMED_ACTION, HWM_APPLY_RULE, HWM_TAB_SELECT, HWM_MARK_KEY, HWM_ATTENTION };

static double hwm_now(void) { return (double) read_os_timer() / (double) read_os_freq(); }
#include "plane_multitouch.m"
/* Animations are sampled for the moment the frame will be on screen, not for
 * whenever this thread happened to wake. The display link supplies that
 * moment; sampling at it gives evenly spaced motion however late a tick runs. */
static uint64_t hwm_vsync_host;
static double hwm_presented; // The time the last frame was sampled for.
static double hwm_frame_time(double now)
{
    static mach_timebase_info_data_t base;
    if(!base.denom) mach_timebase_info(&base);
    double target=hwm_ca_clock_running ? hwm_ca_target_time : (double)__atomic_load_n(&hwm_vsync_host,__ATOMIC_RELAXED)*base.numer/base.denom/1e9;
    return target>now && target-now<.05 ? target : now;
}
/* "Now" for anything that restarts an animation: never earlier than the frame
 * already shown, or the restart would step backwards in time. */
static double hwm_clock(void) { double now=hwm_now(); return now>hwm_presented ? now : hwm_presented; }
static double horizontal_ease(double t)
{
    return hstrip_ease(t);
}

static void hwm_ca_resume(void);
static void hwm_menu_status(void);
static bool hwm_helper_lost_shown;
/* Every wake bumps a generation. A tick that ends idle only lets the clock
 * sleep if nothing woke it meanwhile, so a wake from another thread (a title
 * arriving, a helper reply) is never lost to the tick's own idle store. */
static uint64_t hwm_wake_generation;
static void hwm_wake(void)
{
    __atomic_add_fetch(&hwm_wake_generation,1,__ATOMIC_SEQ_CST);
    __atomic_store_n(&hwm_active, true, __ATOMIC_SEQ_CST); hwm_ca_resume();
}
static void hwm_tick_idle(uint64_t generation)
{
    __atomic_store_n(&hwm_active,false,__ATOMIC_SEQ_CST);
    if(__atomic_load_n(&hwm_wake_generation,__ATOMIC_SEQ_CST)!=generation) {
        // The clock may have paused in the instant active read false.
        __atomic_store_n(&hwm_active,true,__ATOMIC_SEQ_CST); hwm_ca_resume();
    }
}
static uint64_t hwm_tick_wake_generation; // The generation the running tick began with.
static struct view *hwm_view(void)
{
    if (!hwm_space) return NULL;
    return space_manager_find_view(&g_space_manager, hwm_space);
}
/* The usable screen rectangle takes half a dozen WindowServer and Dock round
 * trips to work out, and it is wanted many times in every frame. It changes
 * only when the Dock, menu bar or display does, so it is remembered briefly. */
static CGRect hwm_screen(struct view *view)
{
    static uint64_t sid; static CGRect frame;
    double now=hwm_now();
    // Never in the middle of a swipe or a glide: the answer cannot change
    // there, and asking costs a frame's worth of round trips.
    bool moving=hwm_camera_animating || view->strip_scrolling || hwm_plane_y_scrolling || g_mouse_state.window || hwm_drag_window ||
                __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED);
    if(view->sid!=sid || (now-hwm_screen_stamp>2 && !(moving && hwm_screen_stamp>0))) {
        sid=view->sid; hwm_screen_stamp=now;
        uint32_t display=space_display_id(view->sid);
        frame=display_bounds_constrained(display, false);
        hwm_display_left=CGDisplayBounds(display).origin.x;
    }
    return frame;
}
static CGRect hwm_bounds(struct view *view)
{
    CGRect frame = hwm_screen(view);
    frame.origin.x += view->left_padding;
    frame.origin.y += view->top_padding;
    frame.size.width = fmax(100, frame.size.width-view->left_padding-view->right_padding);
    frame.size.height = fmax(100, frame.size.height-view->top_padding-view->bottom_padding);
    return frame;
}
static double hwm_content_width;
static double hwm_max_offset(void)
{
    /* A plane has no final column and no left edge. Kept as a compatibility
     * hook for older feedback code, whose callers naturally become unbounded. */
    return INFINITY;
}
static double hwm_clamp_offset(double offset)
{
    return isfinite(offset) ? offset : 0;
}
/* The displayed camera position. It may lie slightly past either end: a finger
 * holding the strip there is resisted, and a fling into an end bounces off it.
 * view->strip_offset is always the clamped, in-bounds value. */
static void hwm_plane_camera_sample(struct view *view,double now)
{
    if(!view || !hwm_camera_animating) return;
    double duration=hwm_camera_duration*fmax(0,hwm_motion_scale);
    double elapsed=fmax(0,now-hwm_camera_start);
    double progress=duration<=0 ? 1 : hwm_plane_camera_progress(elapsed,duration,hwm_camera_launch,&hwm_camera_rate);
    HWMPlaneCamera camera=hwm_plane_camera_mix(hwm_camera_from,hwm_camera_target,hwm_camera_width,hwm_camera_height,progress);
    view->strip_offset=camera.x; hwm_plane_y=camera.y; hwm_plane_scale=hwm_plane_zoom_clamp(camera.scale);
    hwm_plane_fit_active=fabs(camera.scale-1)>.001;
    if(progress>=1) { hwm_camera_animating=false; hwm_camera_rate=0; }
}
static void hwm_plane_camera_stop(struct view *view,double now)
{
    if(!hwm_camera_animating) return;
    hwm_plane_camera_sample(view,now); hwm_camera_animating=false; hwm_camera_rate=0;
    view->strip_target_offset=view->strip_offset; hwm_plane_y_target=hwm_plane_y;
    hwm_scroll_current_velocity=0; hwm_plane_y_current_velocity=0;
}
static double hwm_offset(struct view *view, double now)
{
    hwm_plane_camera_sample(view,now);
    if (!view->strip_scrolling) {
        if(hwm_held_lead==0 || hwm_rubber || !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) return view->strip_offset+hwm_rubber;
        return view->strip_offset+hwm_held_lead;
    }
    double elapsed=now-view->strip_scroll_start;
    double value=hstrip_spring(view->strip_from_offset,view->strip_target_offset,hwm_scroll_initial_velocity,
                              elapsed,hwm_scroll_omega/fmax(.15,hwm_motion_scale),&hwm_scroll_current_velocity);
    view->strip_offset=hwm_clamp_offset(value);
    if(hwm_motion_scale==0 || (fabs(value-view->strip_target_offset)<.25 && fabs(hwm_scroll_current_velocity)<3) || elapsed>1.2) {
        view->strip_offset=view->strip_target_offset; view->strip_scrolling=false; hwm_scroll_current_velocity=0;
        return view->strip_offset;
    }
    return value;
}
static void hwm_scroll(struct view *view, double target, bool animate)
{
    if (!view || !isfinite(target) || (hwm_plane_pointer_owned() && !hwm_drag_camera_owned)) return;
    hwm_state_pending = true;
    double now = hwm_clock();
    hwm_plane_camera_stop(view,now);
    double release=hwm_scroll_current_velocity;
    view->strip_from_offset = hwm_offset(view, now);
    hwm_rubber=0;
    hwm_scroll_initial_velocity=hwm_release_velocity?release:hwm_scroll_current_velocity;
    hwm_release_velocity=false;
    hwm_feedback_navigation(target<0 || target>hwm_max_offset());
    // A placement aimed at the old camera must not land during the new motion.
    if(fabs(hwm_clamp_offset(target)-view->strip_target_offset)>.25) hwm_zoom_cancel_native();
    view->strip_target_offset = hwm_clamp_offset(target);
    view->strip_scroll_start = now;
    view->strip_scrolling = animate && fabs(view->strip_target_offset-view->strip_from_offset) > .25;
    if (!view->strip_scrolling) { view->strip_offset = view->strip_target_offset; hwm_scroll_current_velocity=0; }
    hwm_wake();
}

static double hwm_plane_camera_y(double now)
{
    hwm_plane_camera_sample(hwm_view(),now);
    if(!hwm_plane_y_scrolling) return hwm_plane_y;
    double velocity=0, value=hstrip_spring(hwm_plane_y_from,hwm_plane_y_target,hwm_plane_y_initial_velocity,
                                           now-hwm_plane_y_start,hwm_scroll_omega/fmax(.15,hwm_motion_scale),&velocity);
    hwm_plane_y=value; hwm_plane_y_current_velocity=velocity;
    if(hwm_motion_scale==0 || (fabs(value-hwm_plane_y_target)<.25 && fabs(velocity)<3) || now-hwm_plane_y_start>1.2) {
        hwm_plane_y=hwm_plane_y_target; hwm_plane_y_initial_velocity=hwm_plane_y_current_velocity=0; hwm_plane_y_scrolling=false;
    }
    return hwm_plane_y;
}

/* Translation intentionally never clamps.  An empty quadrant is a valid part
 * of the plane, and negative coordinates are ordinary saved coordinates. */
static void hwm_plane_set_camera(struct view *view,double x,double y,bool animate)
{
    if(!view || !isfinite(x) || !isfinite(y) || (hwm_plane_pointer_owned() && !hwm_drag_camera_owned)) return;
    /* At 100% an animated camera lands on whole points: native AppKit frames
     * are whole points, so a fractional rest would make every window hop a
     * pixel when the handoff to native frames follows. */
    if(animate && hwm_plane_scale==1) { x=round(x); y=round(y); }
    double now=hwm_clock();
    hwm_scroll(view,x,animate);
    if(fabs(y-hwm_plane_y_target)>.25) hwm_zoom_cancel_native();
    hwm_plane_y_from=hwm_plane_camera_y(now); hwm_plane_y_target=y;
    hwm_plane_y_initial_velocity=animate ? hwm_plane_y_current_velocity : 0;
    hwm_plane_y_start=now;
    hwm_plane_y_scrolling=animate && fabs(y-hwm_plane_y_from)>.25;
    if(!hwm_plane_y_scrolling) { hwm_plane_y=y; hwm_plane_y_initial_velocity=hwm_plane_y_current_velocity=0; }
    hwm_state_pending=true; hwm_wake();
}

static void hwm_plane_transition_to(struct view *view,double x,double y,double scale,bool animate)
{
    if(!view || hwm_plane_pointer_owned() || !isfinite(x) || !isfinite(y) || !isfinite(scale) || scale<=0) return;
    scale=hwm_plane_zoom_clamp(scale);
    if(animate && scale==1) { x=round(x); y=round(y); } // See hwm_plane_set_camera.
    hwm_zoom_workspace=scale<1; hwm_zoom_detent_armed=false;
    double now=hwm_clock();
    double current_x=hwm_offset(view,now),current_y=hwm_plane_camera_y(now);
    /* Whatever the camera is doing now (a transition, a glide, a settle)
     * carries into this one, so a retarget bends the path instead of
     * stopping dead and restarting. Sampled after hwm_offset above. */
    HWMPlaneCameraVelocity moving={0,0,0};
    if(hwm_camera_animating)
        moving=hwm_plane_camera_velocity(hwm_camera_from,hwm_camera_target,hwm_camera_width,hwm_camera_height,
            hwm_plane_camera_progress(now-hwm_camera_start,hwm_camera_duration*fmax(0,hwm_motion_scale),hwm_camera_launch,NULL),hwm_camera_rate);
    else {
        if(view->strip_scrolling) moving.x=hwm_scroll_current_velocity;
        if(hwm_plane_y_scrolling) moving.y=hwm_plane_y_current_velocity;
    }
    hwm_camera_from=(HWMPlaneCamera){current_x,current_y,hwm_plane_scale};
    hwm_camera_target=(HWMPlaneCamera){x,y,scale};
    hwm_zoom_cancel_native();
    CGRect bounds=hwm_bounds(view);
    hwm_camera_width=bounds.size.width; hwm_camera_height=bounds.size.height;
    hwm_camera_duration=hwm_plane_camera_duration(hwm_camera_from,hwm_camera_target,hwm_camera_width,hwm_camera_height);
    hwm_camera_launch=hwm_plane_camera_launch(hwm_camera_from,hwm_camera_target,hwm_camera_width,hwm_camera_height,
                                              moving,hwm_camera_duration*fmax(0,hwm_motion_scale));
    hwm_camera_rate=hwm_camera_launch;
    hwm_camera_start=now;
    view->strip_scrolling=false; hwm_plane_y_scrolling=false;
    hwm_scroll_initial_velocity=hwm_scroll_current_velocity=0;
    hwm_plane_y_initial_velocity=hwm_plane_y_current_velocity=0;
    view->strip_target_offset=x; hwm_plane_y_target=y;
    hwm_camera_animating=animate && hwm_motion_scale>0;
    if(!hwm_camera_animating) {
        view->strip_offset=x; hwm_plane_y=y; hwm_plane_scale=scale;
        hwm_plane_fit_active=fabs(scale-1)>.001;
    }
    hwm_state_pending=true; hwm_wake();
}

static bool hwm_plane_displayed_frame(uint32_t wid,CGRect *out);
static void hwm_zoom_native_press(struct view *view,struct window *w)
{
    if(!view || !w || hwm_plane_scale!=1 ||
       (!w->strip_plane_scaled && !hwm_camera_animating && !view->strip_scrolling && !hwm_plane_y_scrolling && !hwm_zoom_native_busy(w->id))) return;
    // Freeze at the native frame actually grabbed, rather than a camera
    // sample whose AX placements have not painted yet. Otherwise the first
    // drag incorrectly counts the remaining camera travel as user movement.
    CGRect frame=g_mouse_state.window_frame,bounds=hwm_bounds(view);
    if(CGRectIsNull(frame) || frame.size.width<=0)return;
    hwm_zoom_cancel_native();
    (void)hwm_zoom_wait_native(w->id);
    if(SLSGetWindowBounds(g_connection,w->id,&frame)==kCGErrorSuccess)g_mouse_state.window_frame=frame;
    CGRect shown=frame;
    if(w->strip_plane_scaled && !hwm_plane_displayed_frame(w->id,&shown))shown=w->strip_last_frame;
    double x=w->strip_world_x-(shown.origin.x-bounds.origin.x);
    double y=w->strip_world_y-(shown.origin.y-bounds.origin.y);
    hwm_plane_set_camera(view,x,y,false);
    hwm_plane_selecting=false;hwm_zoom_workspace=false;
    w->frame=frame;w->strip_last_frame=shown;w->strip_last_plane_scale=1;
    w->strip_last_offset=x;w->strip_last_camera_y=y;
}

static HWMPlaneRect hwm_plane_bounds(struct view *view,bool focused_only)
{
    HWMPlaneRect result={0,0,0,0}; bool any=false;
    uint32_t focused=g_window_manager.focused_window_id;
    for(struct window_node *n=view?window_node_find_first_leaf(view->root):NULL;n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_close_ghost || hwm_workflow_tab_hidden(w) || (focused_only && w->id!=focused)) continue;
        HWMPlaneRect r={w->strip_world_x,w->strip_world_y,fmax(1,w->strip_width),fmax(1,w->strip_height)};
        if(!any) { result=r; any=true; continue; }
        double right=fmax(result.x+result.width,r.x+r.width), bottom=fmax(result.y+result.height,r.y+r.height);
        result.x=fmin(result.x,r.x); result.y=fmin(result.y,r.y); result.width=right-result.x; result.height=bottom-result.y;
    }
    return result;
}

static void hwm_plane_fit(struct view *view,bool focused)
{
    if(!view || hwm_plane_pointer_owned() || g_mouse_state.window) return;
    CGRect bounds=hwm_bounds(view); HWMPlaneRect world=hwm_plane_bounds(view,focused);
    if(world.width<=0 || world.height<=0) return;
    HWMPlaneCamera camera=hwm_plane_camera_fit(world,(HWMPlaneRect){0,0,bounds.size.width,bounds.size.height},36);
    hwm_plane_transition_to(view,camera.x,camera.y,camera.scale,true);
    hwm_zoom_workspace=true;
}
static void hwm_plane_fit_all(struct view *view) { hwm_plane_fit(view,false); }
static void hwm_plane_fit_focused(struct view *view) { hwm_plane_actual_size(view); }
static void hwm_plane_actual_size(struct view *view)
{
    if(!view || hwm_plane_pointer_owned() || g_mouse_state.window) return;
    // Sample rather than stop: a transition in flight hands its motion on.
    double now=hwm_clock(); hwm_plane_camera_sample(view,now);
    CGRect bounds=hwm_bounds(view);
    struct window *w=hwm_action_window();
    double x=w ? w->strip_world_x+(w->strip_width-bounds.size.width)*.5 : view->strip_offset;
    double y=w ? w->strip_world_y-fmax(0,(bounds.size.height-w->strip_height)*.5) : hwm_plane_camera_y(now);
    hwm_zoom_cancel_native();
    hwm_plane_transition_to(view,x,y,1,true);
}
/* pointer is where the pinch happened: the event's own location. A location
 * off the screen (some forwarded gestures carry none) falls back to asking
 * WindowServer, which costs a round trip on every pinch sample. */
static CGPoint hwm_plane_zoom_point(CGRect bounds,CGPoint pointer)
{
    CGPoint cursor;
    if(CGRectContainsPoint(bounds,pointer)) return pointer;
    if(SLSGetCurrentCursorLocation(g_connection,&cursor)==kCGErrorSuccess && CGRectContainsPoint(bounds,cursor)) return cursor;
    return CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
}
/* The camera that keeps screen point p over the same world point while
 * `from` changes to scale. */
static HWMPlaneCamera hwm_plane_zoom_about(HWMPlaneCamera from,double scale,CGRect bounds,CGPoint p)
{
    double wx=from.x+(p.x-bounds.origin.x)/from.scale;
    double wy=from.y+(p.y-bounds.origin.y)/from.scale;
    HWMPlaneCamera to={wx-(p.x-bounds.origin.x)/scale,wy-(p.y-bounds.origin.y)/scale,scale};
    // Native frames are placed on whole points at 100%.
    if(scale==1) { to.x=round(to.x); to.y=round(to.y); }
    return to;
}
/* Zoom to scale about the pinch point, from `from` (the camera's target when
 * NULL). 0: refused, 1: already at that scale, 2: zoomed. The point used is
 * stored in *anchor when zooming. */
static int hwm_plane_zoom_from(struct view *view,const HWMPlaneCamera *from,double scale,CGPoint pointer,CGPoint *anchor)
{
    if(!view || hwm_plane_pointer_owned() || g_mouse_state.window || !isfinite(scale)) return 0;
    scale=hwm_plane_zoom_clamp(fmax(HWM_PLANE_MIN_SCALE,fmin(1,scale)));
    if(scale==(from ? from->scale : hwm_plane_scale)) return 1;
    /* Zoom stays anchored at the pointer all the way to 100%. Jumping to the
     * focused window at the end of a pinch read as a stutter. */
    hwm_zoom_workspace=scale<1;
    hwm_plane_camera_stop(view,hwm_now());
    CGRect bounds=hwm_bounds(view); CGPoint point=hwm_plane_zoom_point(bounds,pointer);
    if(anchor) *anchor=point;
    HWMPlaneCamera start=from ? *from : (HWMPlaneCamera){view->strip_target_offset,hwm_plane_y_target,hwm_plane_scale};
    HWMPlaneCamera next=hwm_plane_zoom_about(start,scale,bounds,point);
    hwm_plane_scale=scale; hwm_plane_fit_active=fabs(hwm_plane_scale-1)>.001;
    hwm_plane_set_camera(view,next.x,next.y,false);
    return 2;
}
/* Pinch reports arrive unevenly and slower than a ProMotion panel draws, so a
 * pinch drawn straight from them zoomed in uneven steps. As with the pan,
 * each frame is drawn where the fingers are at its vsync: the latest report
 * carried on at the rate the zoom was changing (in log scale, so steady
 * fingers give a steady zoom), for no longer than about one report interval.
 * Reports integrate onto the latest report (hwm_pinch_raw), never onto a
 * resampled frame. Anything else that moves the camera ends the resampling,
 * leaving the camera where it was last drawn. */
static bool hwm_pinch_raw_valid;
static HWMPlaneCamera hwm_pinch_raw,hwm_pinch_shown;
/* How far out a pinch may take the camera: until every window fits on screen
 * with room to spare, and never closer than HWM_PINCH_FLOOR allows. Beyond
 * that a pinch only shrank everything into empty plane, and a quick pinch got
 * there before the fingers could stop it. Set when a pinch begins. */
#define HWM_PINCH_FLOOR .2
static double hwm_pinch_floor=HWM_PINCH_FLOOR;
static bool hwm_plane_window_selectable(struct view *view,struct window *w);
static double hwm_pinch_floor_for(struct view *view)
{
    double x0=INFINITY,y0=INFINITY,x1=-INFINITY,y1=-INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!hwm_plane_window_selectable(view,w) || !(w->strip_width>0) || !(w->strip_height>0)) continue;
        x0=fmin(x0,w->strip_world_x); y0=fmin(y0,w->strip_world_y);
        x1=fmax(x1,w->strip_world_x+w->strip_width); y1=fmax(y1,w->strip_world_y+w->strip_height);
    }
    CGRect bounds=hwm_bounds(view);
    if(!(x1>x0) || !(y1>y0) || bounds.size.width<=0 || bounds.size.height<=0) return HWM_PINCH_FLOOR;
    double fit=.85*fmin(bounds.size.width/(x1-x0),bounds.size.height/(y1-y0));
    return fmax(HWM_PLANE_MIN_SCALE,fmin(HWM_PINCH_FLOOR,fit));
}
// The floor never pulls a camera that is already further out back in.
static double hwm_pinch_limit(double scale,double from)
{
    return fmax(scale,fmin(hwm_pinch_floor,from));
}
/* After the newest report the lead carries on for one report interval, then
 * runs back to nothing over this long: the zoom comes to rest exactly where
 * the fingers left it. Holding the extrapolated scale when they stopped left
 * a quick pinch further out than the fingers had taken it. */
#define HWM_PINCH_SETTLE .03
/* When the fingers lift (the gesture's ended phase), nothing more is coming:
 * the remaining lead goes within a frame, so a pinch stopped abruptly does
 * not show the zoom carrying on past the fingers and easing back. */
static double hwm_pinch_ended=-1;
static CGPoint hwm_pinch_anchor;
static struct { double time,log_scale; } hwm_pinch_samples[HWM_HELD_SAMPLES];
static int hwm_pinch_count;
static void hwm_pinch_reset(void) { hwm_pinch_raw_valid=false; hwm_pinch_count=0; }
static bool hwm_pinch_intact(struct view *view)
{
    return !hwm_camera_animating && !view->strip_scrolling && !hwm_plane_y_scrolling && !hwm_plane_gesture.active &&
           !hwm_plane_pointer_owned() && !g_mouse_state.window &&
           view->strip_offset==hwm_pinch_shown.x && hwm_plane_y==hwm_pinch_shown.y && hwm_plane_scale==hwm_pinch_shown.scale;
}
static void hwm_pinch_note(double time,double log_scale)
{
    if(hwm_pinch_count && time<hwm_pinch_samples[hwm_pinch_count-1].time) time=hwm_pinch_samples[hwm_pinch_count-1].time;
    if(hwm_pinch_count==HWM_HELD_SAMPLES) memmove(hwm_pinch_samples,hwm_pinch_samples+1,(HWM_HELD_SAMPLES-1)*sizeof(*hwm_pinch_samples));
    else ++hwm_pinch_count;
    hwm_pinch_samples[hwm_pinch_count-1].time=time; hwm_pinch_samples[hwm_pinch_count-1].log_scale=log_scale;
}
/* How far the fingers have zoomed by `time` beyond the latest report, in log scale. */
static double hwm_pinch_lead_at(double time)
{
    if(hwm_pinch_count<2) return 0;
    double newest=hwm_pinch_samples[hwm_pinch_count-1].time,st=0,stt=0,ss=0,sts=0; int n=0;
    double oldest=0;
    for(int i=hwm_pinch_count-1;i>=0 && newest-hwm_pinch_samples[i].time<=.05;i--) {
        double t=hwm_pinch_samples[i].time-newest,v=hwm_pinch_samples[i].log_scale;
        st+=t; stt+=t*t; ss+=v; sts+=t*v; ++n; oldest=t;
    }
    double spread=n*stt-st*st;
    if(n<3 || -oldest<HWMHeldLeadSpan || !(spread>1e-9)) return 0;
    double rate=(n*sts-st*ss)/spread,at_newest=(ss-rate*st)/n;
    double ahead=fmax(0,fmin(HWMHeldLeadMax,time-newest));
    // Never further from the latest report than the fingers could have zoomed since.
    double lead=at_newest+rate*ahead-log(hwm_pinch_raw.scale),limit=fabs(rate)*(HWMHeldLeadMax+.004);
    return fmax(-limit,fmin(limit,lead));
}
static void hwm_pinch_report(struct view *view,double delta,CGPoint pointer,double time)
{
    bool resume=hwm_pinch_raw_valid && hwm_pinch_intact(view);
    if(!resume) { hwm_pinch_reset(); hwm_pinch_floor=hwm_pinch_floor_for(view); hwm_pinch_ended=-1; }
    CGPoint anchor=hwm_pinch_anchor;
    double from=resume ? hwm_pinch_raw.scale : hwm_plane_scale;
    int zoomed=hwm_plane_zoom_from(view,resume ? &hwm_pinch_raw : NULL,hwm_pinch_limit(from*exp(delta),from),pointer,&anchor);
    if(!zoomed) { hwm_pinch_reset(); return; }
    if(zoomed==2 || !resume) hwm_pinch_raw=(HWMPlaneCamera){view->strip_target_offset,hwm_plane_y_target,hwm_plane_scale};
    if(zoomed==1 && !resume) {
        CGRect bounds=hwm_bounds(view);
        anchor=CGRectContainsPoint(bounds,pointer) ? pointer : CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    }
    hwm_pinch_anchor=anchor;
    hwm_pinch_shown=(HWMPlaneCamera){view->strip_offset,hwm_plane_y,hwm_plane_scale};
    hwm_pinch_note(time,log(hwm_pinch_raw.scale));
    hwm_pinch_raw_valid=true;
}
/* One pinch sample, from the contacts or from a magnify event: delta is the
 * zoom in log scale before pinchGain; phase is 1 began, 2 changed, 4 ended,
 * 8 cancelled. */
static void hwm_pinch_input(struct view *view,double delta,CGPoint pointer,int phase,double time,double now)
{
    if(phase&1) hwm_pinch_ended=-1;
    hwm_pinch_report(view,delta*hwm_pinch_gain,pointer,time);
    if(phase&(4|8)) hwm_pinch_ended=now;
    hwm_zoom_pinch_time=now;
    if(delta) { hwm_zoom_detent_armed=delta>0 && hwm_plane_scale<1; hwm_zoom_detent_point=pointer; }
    hwm_last_input=now;
}
/* Draw this frame's zoom; time is the frame's vsync. */
static void hwm_pinch_present(struct view *view,double time)
{
    if(!hwm_pinch_raw_valid) return;
    // Something else took the camera: stay where drawn.
    if(!hwm_pinch_intact(view)) { hwm_pinch_reset(); return; }
    double since=time-hwm_pinch_samples[hwm_pinch_count-1].time;
    double carry=fmax(0,fmin(1,1-(since-HWMHeldLeadMax)/HWM_PINCH_SETTLE));
    if(hwm_pinch_ended>=0) carry=fmin(carry,fmax(0,1-(time-hwm_pinch_ended)/.016));
    double scale=hwm_pinch_raw.scale*exp(hwm_pinch_lead_at(time)*carry);
    scale=hwm_plane_zoom_clamp(fmax(HWM_PLANE_MIN_SCALE,fmin(1,hwm_pinch_limit(scale,hwm_pinch_raw.scale))));
    // At rest: drawn at the latest report itself, and done.
    if(carry<=0) hwm_pinch_reset();
    HWMPlaneCamera next=hwm_plane_zoom_about(hwm_pinch_raw,scale,hwm_bounds(view),hwm_pinch_anchor);
    if(next.x==view->strip_offset && next.y==hwm_plane_y && next.scale==hwm_plane_scale) return;
    hwm_zoom_workspace=next.scale<1;
    hwm_plane_scale=next.scale; hwm_plane_fit_active=fabs(hwm_plane_scale-1)>.001;
    hwm_plane_set_camera(view,next.x,next.y,false);
    hwm_pinch_shown=(HWMPlaneCamera){view->strip_offset,hwm_plane_y,hwm_plane_scale};
}

#include "strip_ax_async.m"
#include "strip_hud.m"
#include "strip_signals.m"
#include "plane_controls.m"
static void hwm_resize_submit(struct window *w,CGRect frame,bool full) { (void)full; hwm_ax_resize(w->id,w->ref,w->application->ref,frame.size); }
static bool hwm_resize_busy(struct window *w) { return hwm_ax_resize_busy(w->id); }
static void hwm_close_submit(struct window *w) { horizontal_removing(w,false); hwm_ax_close(w->ref); }
static bool hwm_window_left_strip(struct window *w) { return hwm_space && window_space(w->id)!=hwm_space; }
static void hwm_plane_border_batch_failed(void);
#include "strip_layout.m"
/* The strip in view. */
static size_t hwm_items(struct view *view, CGRect bounds, HStripColumnItem **out) { return hwm_shelf_items(view,bounds,hwm_shelf,out); }
static void hwm_column_width(struct view *view,struct window *window,double width)
{
    uint64_t column=window->strip_column;
    table_for(struct window *w,g_window_manager.window, {
        if (w==window || (column && w->strip_column==column && window_manager_find_managed_window(&g_window_manager,w)==view)) {
            w->strip_width=width; w->strip_full_width=false;
        }
    })
}

static bool horizontal_flush_node(struct window_node *node)
{
    struct window_node *root = node;
    while (root && root->parent) root = root->parent;
    table_for (struct view *view, g_space_manager.view, {
        if (view->layout == VIEW_STRIP && view->root == root) {
            // A window that has just become a tile is given its place before it is first drawn.
            hwm_place_unplaced(view);
            hwm_layout(view, true);
            return true;
        }
    })
    return false;
}

#include "plane_drag_begin.m"

static uint32_t hwm_edge_window;
#include "strip_feedback.m"
static bool hwm_view_in_motion(struct view *view,double now);
#define HWM_PROF_BORDER_PAINT_ENABLED 1
#include "plane_border.m"
#include "strip_interaction.m"
#include "strip_visibility.m"
#include "strip_renderer.m"
#include "window_transitions.m"
#include "native_zoom.m"
#include "plane_resize.m"
static bool hwm_plane_pointer_owned(void) { return hwm_drag_window || hwm_edge_window || hwm_resize_owned; }
#include "plane_pick_event.m"
/* A removal path can already have freed a feedback node before it reaches the
 * managed-window hook. Compare addresses while walking the live view trees;
 * never dereference the stored pointer until that check succeeds. */
static bool hwm_plane_feedback_node_is_live(struct window_node *candidate)
{
    if(!candidate) return false;
    table_for(struct view *view,g_space_manager.view, {
        if(!view->root) continue;
        for(struct window_node *node=window_node_find_first_leaf(view->root);node;node=window_node_find_next_leaf(node)) {
            if(node==candidate) return true;
        }
    })
    return false;
}
static void hwm_plane_clear_legacy_pointer(struct window *window)
{
    if(window && g_mouse_state.window!=window) return;
    struct window_node *feedback=g_mouse_state.feedback_node;
    if(hwm_plane_feedback_node_is_live(feedback)) {
        feedback->insert_dir=0;
        insert_feedback_destroy(feedback);
    }
    g_mouse_state.feedback_node=NULL;
    g_mouse_state.window=NULL;
    g_mouse_state.current_action=MOUSE_MODE_NONE;
    g_mouse_state.direction=0;
    hwm_mouse_pointer_generation=0;
    hwm_mouse_pointer_button=-1;
}
#include "plane_interaction_lifecycle.m"
/* Collect the reply to the last frame handed to the helper, so every handler
 * still starts with all earlier presentation applied. It has almost always
 * arrived by now; the frame itself no longer waits for it. */
static void horizontal_event_settle(void)
{
    if(!scripting_addition_settle()) hwm_batch_failed();
}
/* A held pan or pinch reports every few milliseconds, each moving only the
 * camera. Waiting on the frame just handed to Dock before each one put Dock's
 * commit time between every report and the next frame. Paths that go on to
 * read window geometry settle there instead. */
static bool horizontal_event_settles(int type,void *context,int param1)
{
    if(type==WINDOW_MOVED) return false; // horizontal_window_moved settles before reading.
    /* Hover hit-tests what is displayed and only changes focus. A frame still
     * in Dock's hands at worst places a window one frame behind, and hover
     * does nothing while the camera moves. */
    if(type==MOUSE_MOVED) return false;
    /* The housekeeping sweep settles itself before it asks WindowServer
     * anything, and it does not while frames are being drawn; a title
     * change reads no geometry at all. Both arrive throughout a gesture. */
    if(type==HORIZONTAL_RECONCILE || type==WINDOW_TITLE_CHANGED) return false;
    /* A frame of a held pan or pinch moves the camera over windows whose
     * geometry it already knows. Waiting for Dock to acknowledge the previous
     * frame before drawing the next made every frame wait on Dock's
     * scheduling: under load that wait was most of a refresh, the tick
     * missed its vsync, and the gesture fell behind. The renderer settles
     * itself at the two places a frame does read geometry (an application's
     * own move or resize). Anything pointer-owned keeps the wait. */
    if(type==HORIZONTAL_TICK && (__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) || hwm_pinch_raw_valid) &&
       !hwm_drag_window && !hwm_edge_window && !hwm_resize_owned && !g_mouse_state.window) return false;
    if(type!=HORIZONTAL_INPUT) return true;
    if(param1==HWM_TOUCH_FRAME || param1==HWM_PINCH_FRAME) return false;
    return !(param1==HWM_EVENT && context && CGEventGetType((CGEventRef)context)==29 &&
             CGEventGetIntegerValueField((CGEventRef)context,110)==8);
}
static int hwm_backend_misses;
static void horizontal_tick(void)
{
    __atomic_store_n(&hwm_tick_pending, false, __ATOMIC_RELEASE);
    uint64_t wake_generation=__atomic_load_n(&hwm_wake_generation,__ATOMIC_SEQ_CST);
    hwm_tick_wake_generation=wake_generation;
    if (hwm_stop_requested) { hwm_shutdown(); return; }
    // The camera panel is no longer shown; zoom is driven by gestures and shortcuts.
    hwm_plane_controls_update(false,hwm_plane_scale);
    if(hwm_resize_owned && (hwm_paused || hwm_suspended || hwm_overview_active)) hwm_plane_resize_tick(hwm_view(),hwm_now());
    if (!hwm_ready || hwm_paused || hwm_suspended || mission_control_is_active()) {
        // Paused, locked or not started: nothing is drawn, so the display
        // clock may sleep. Resuming lays out and wakes it again.
        if(!hwm_resize_owned && (!hwm_ready || hwm_paused || hwm_suspended)) hwm_tick_idle(wake_generation);
        return;
    }
    double start = hwm_now(), latency = hwm_tick_note(start);
    if(hwm_overview_active) { hwm_drawn_time=start; hwm_overview_tick(); hwm_tick_previous_active=hwm_active; return; }
    hwm_tick_previous_active=false;
    struct view *view = hwm_view();
    if (!view || !hwm_view_space_visible(view,start)) {
        // Nothing can be drawn (a native fullscreen Space is in front). Returning
        // to the strip wakes the clock again; until then it should not keep ticking.
        hwm_tick_idle(wake_generation);
        return;
    }
    hwm_drawn_time=start;
    if (!hwm_backend_ok) {
        // A failed command is usually one slow reply, not a lost helper: ask
        // again at once and carry on if it answers. Only a helper that keeps
        // not answering is reloaded.
        // Between retries the housekeeping timer keeps ticking; the display
        // clock may sleep.
        if (hwm_backend_misses && start-hwm_last_backend_retry < .5) { hwm_tick_idle(wake_generation); return; }
        hwm_last_backend_retry = start;
        hwm_backend_ok = tana_backend_ready();
        if (!hwm_backend_ok) { if (++hwm_backend_misses >= 3) hwm_helper_reload(); hwm_tick_idle(wake_generation); return; }
        hwm_backend_misses = 0;
        if(hwm_helper_attempts || hwm_helper_lost_shown) { hwm_helper_attempts=0; hwm_helper_lost_shown=false; hwm_hud(@"Window helper reconnected"); hwm_menu_status(); }
        hwm_layout(view, false);
    }
    if (__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) && start-view->strip_last_time > .8) {
        __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
        hwm_plane_gesture.active=false;
        hwm_focus_after_scroll = true;
    }
    // Where the fingers are as this frame is drawn; see hwm_held_velocity.
    hwm_held_lead=0;
    if(hwm_plane_gesture.active && hwm_pan_raw_valid && __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) {
        double lead_x,lead_y; hwm_pan_lead_at(hwm_frame_time(start),&lead_x,&lead_y);
        hwm_plane_set_camera(view,hwm_pan_raw_x+lead_x,hwm_pan_raw_y+lead_y,false);
    }
    hwm_pinch_present(view,hwm_frame_time(start));
    // Use the same unpredicted camera sample on both axes during held input.
    // Applied once the keys or fingers rest; a swipe still in progress may yet go further.
    if(hwm_nav_pending && start-hwm_nav_time>.07 && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) hwm_nav_flush();
    // A wheel pan that has been quiet for 90 ms is taken as "this is where I want to be".
    if(hwm_settle_pending && start-hwm_last_input>.09) {
        hwm_settle_pending=false;
        if(!hwm_drag_window && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) {
            hwm_scroll(view,hwm_snap_target(view,view->strip_offset,hwm_bounds(view).size.width,false),true);
            hwm_focus_follow_to(view,view->strip_target_offset);
        }
    }
    // A pinch toward 100% that rests just short of it finishes the zoom.
    if(hwm_zoom_detent_armed && start-hwm_zoom_pinch_time>=.15) {
        hwm_zoom_detent_armed=false;
        HWMPlaneCamera camera={view->strip_offset,hwm_plane_y,hwm_plane_scale},next;
        CGRect bounds=hwm_bounds(view); CGPoint p=hwm_zoom_detent_point;
        if(!CGRectContainsPoint(bounds,p)) p=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
        if(!hwm_camera_animating && !view->strip_scrolling && !hwm_plane_y_scrolling && !g_mouse_state.window &&
           !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) &&
           hwm_plane_zoom_detent(camera,(HWMPlanePoint){p.x-bounds.origin.x,p.y-bounds.origin.y},true,&next))
            hwm_plane_transition_to(view,next.x,next.y,next.scale,true);
    }
    // Content can shrink under a parked camera; glide back inside the strip.
    if(!view->strip_scrolling && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) &&
       (view->strip_offset>hwm_max_offset()+.5 || hwm_rubber)) hwm_scroll(view,fmin(view->strip_offset,hwm_max_offset()),true);
    bool dragging=hwm_drag_window!=0;
    double mark=hwm_now(), frame=hwm_frame_time(start);
    hwm_presented=frame;
    // Everything this frame changes is presented together.
    hwm_batch_hold=true;
    hwm_scale_reset_all();
    hwm_drag_autoscroll(view,start);
    hwm_plane_resize_tick(view,start);
    struct window *edge=window_manager_find_window(&g_window_manager,hwm_edge_window);
    if(edge && !hwm_resize_owned) hwm_edge_update(edge,view);
    mark=hwm_prof_mark(HWM_PROF_DRAG,mark);
    bool active = hwm_render(view, frame) || edge!=NULL || hwm_drag_window!=0;
    mark=hwm_prof_mark(HWM_PROF_RENDER,mark);
    active |= hwm_render_shelf_floats(view,frame);
    active |= hwm_render_transitions(frame);
    mark=hwm_prof_mark(HWM_PROF_EXTRAS,mark);
    // PREVIEW spans this whole block; its border, batch release and hover
    // parts are also kept apart, to tell which one cost a slow frame.
    active |= hwm_preview_render(frame);
    double segment=hwm_now();
    active |= hwm_plane_border_tick(view,frame);
    segment=hwm_prof_mark(HWM_PROF_BORDER,segment);
    hwm_plane_resize_publish(view);
    hwm_batch_release();
    hwm_visibility_flush_reveals();
    segment=hwm_prof_mark(HWM_PROF_RELEASE,segment);
    hwm_zoom_hover_tick();
    hwm_prof_mark(HWM_PROF_HOVER,segment);
    mark=hwm_prof_mark(HWM_PROF_PREVIEW,mark);
    active |= hwm_nav_pending || hwm_settle_pending || hwm_zoom_detent_armed;
    if(hwm_close_source && start-hwm_close_time>1.0) { hwm_close_source=0; hwm_close_target=0; }
    if (hwm_close_target && !hwm_close_source && start-hwm_close_time>.04) {
        if(hwm_plane_pointer_owned()) {
            // Do not deliver a delayed focus handoff into a window whose
            // pointer interaction began after the close was requested.
            hwm_close_target=0;
        } else {
            struct window *target=window_manager_find_window(&g_window_manager,hwm_close_target);
            hwm_preserve_focus_window=hwm_close_target; hwm_preserve_focus_until=start+.6;
            hwm_close_target=0;
            hwm_last_input=start;
            if(target) window_manager_focus_window_with_raise(&target->application->psn,target->id,target->ref);
        }
    }
    if(hwm_close_target) active=true;
    if (__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) active = true;
    hwm_feedback_tick(view,start);
    active |= hwm_feedback_animating(start);
    hwm_prof_mark(HWM_PROF_FEEDBACK,mark);
    if(dragging) { ++hwm_prof_drag_ticks; hwm_prof_mark(HWM_PROF_TICK_DRAGGING,start); }
    if (!active && hwm_focus_after_scroll && hwm_backend_ok) {
        hwm_focus_after_scroll = false;
        if(hwm_pointer_focus) { hwm_hold_focus(); }
        // This is focus inferred from a completed gesture, never an explicit
        // click.  Do not let it dismiss a just-opened menu or popup.
        if (!menu_focus_suppressed() && !popup_focus_suppressed()) {
            CGPoint cursor; SLSGetCurrentCursorLocation(g_connection,&cursor);
            struct window *target = window_manager_find_window_at_point(&g_window_manager,cursor);
            if (!hwm_pointer_focus && !hwm_focus_follow && target && window_manager_is_window_eligible(target)) {
                hwm_last_input = start; // A partially visible hover must not snap the viewport.
                window_manager_focus_window_without_raise(&target->application->psn,target->id);
            }
        }
    }
    if (!active && hwm_state_pending) { hwm_ipc_layout(view); hwm_save_state(); }
    double elapsed = (hwm_now()-start)*1000;
    ++hwm_frames;
    if (elapsed > (hwm_display_hz>1 ? 1000/hwm_display_hz : 8.34)) ++hwm_slow_frames;
    if (elapsed > hwm_max_frame_ms) hwm_max_frame_ms = elapsed;
    hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].time=start; hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].offset=hwm_rendered_offset;
    hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].camera_y=hwm_plane_y; hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].scale=hwm_plane_scale;
    hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].tick_ms=elapsed; hwm_frame_log[hwm_frame_log_count++%HWM_FRAME_LOG].latency_ms=latency;
    hwm_tick_previous_active=active;
    // One failed command is retried on the very next frame, as one slow reply
    // usually is. A helper that keeps missing is retried by the housekeeping
    // timer: keeping the display clock awake for it would hold a ProMotion
    // panel at full refresh for as long as the helper is gone.
    if(active || (!hwm_backend_ok && !hwm_backend_misses)) __atomic_store_n(&hwm_active,true,__ATOMIC_RELEASE);
    else hwm_tick_idle(wake_generation);
}

static CVReturn hwm_display_tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags inFlags, CVOptionFlags *outFlags, void *context)
{
    (void)link; (void)now; (void)inFlags; (void)outFlags; (void)context;
    if(out) __atomic_store_n(&hwm_vsync_host,out->hostTime,__ATOMIC_RELAXED);
    bool expected = false;
    if ((__atomic_load_n(&hwm_active, __ATOMIC_ACQUIRE) || hwm_stop_requested) &&
        __atomic_compare_exchange_n(&hwm_tick_pending, &expected, true, false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        __atomic_store_n(&hwm_tick_posted, read_os_timer(), __ATOMIC_RELAXED);
        event_loop_post(&g_event_loop, HORIZONTAL_TICK, NULL, 0);
    }
    return kCVReturnSuccess;
}

static void hwm_hold_focus(void)
{
    hwm_focus_guard=true; hwm_focus_guard_time=hwm_now();
    SLSGetCurrentCursorLocation(g_connection,&hwm_focus_guard_point);
    hwm_focus_after_scroll=false;
}
/* Called directly from the AX menu-open path.  It only clears focus inferred
 * from strip motion; keyboard navigation, clicks, and close handoffs retain
 * their explicit user intent. */
static void horizontal_cancel_automatic_focus(void)
{
    hwm_focus_after_scroll=false;
    hwm_focus_queue_cancel_automatic(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic);
}
static bool horizontal_hover_allowed(CGPoint point)
{
    if (hwm_overview_active || hwm_plane_selecting) return false;
    if (!hwm_ready || !hwm_focus_guard) return true;
    if (hypot(point.x-hwm_focus_guard_point.x,point.y-hwm_focus_guard_point.y)<.01) return false;
    hwm_focus_guard=false; return true;
}
static void horizontal_hover_received(struct window *window)
{
    hwm_hover_pid=window->application->pid; hwm_hover_time=hwm_now();
}
static void horizontal_activated(struct application *application)
{
    if (!hwm_ready) return;
    if(application->pid==hwm_hover_pid && hwm_now()-hwm_hover_time<.3) return;
    struct window *hover=window_manager_find_window(&g_window_manager,g_mouse_state.ffm_window_id);
    if (hover && hover->application==application) return;
    hwm_hold_focus(); hwm_last_input=0;
}
static void horizontal_focused(struct window *window, struct view *view)
{
    if (!hwm_ready || hwm_paused || hwm_overview_active) return;
#ifdef HWM_TEST_FIXTURE_ONLY
    if(!window_manager_is_window_eligible(window)) return;
#endif
    hwm_workflow_note_explicit_focus(window,view);
    hwm_hold_focus();
    int layer=window->layer==LAYER_AUTO ? (window_check_flag(window,WINDOW_FLOAT)?LAYER_ABOVE:LAYER_BELOW) : window->layer;
    scripting_addition_set_layer(window->id,layer);
    // Focus that lands on another strip (the Dock, Command-Tab, a mark) brings that strip into view.
    if (!hwm_plane_pointer_owned() && hwm_shelf_of(window)!=hwm_shelf && ((view && view->layout==VIEW_STRIP && view_find_window_node(view,window->id)) || window->strip_float_homed)) {
        hwm_shelf_go(hwm_shelf_of(window),false);
        if (view && hwm_shelf==hwm_shelf_of(window) && view_find_window_node(view,window->id)) hwm_scroll(view,hwm_center_target(view,window),true);
        return;
    }
    // Keyboard navigation has already aimed the camera at its cursor. Focus
    // reports for windows it passed on the way must not pull the camera back.
    if (hwm_nav_window && hwm_now()-hwm_nav_time<.6) return;
    // A camera transition already in flight was asked for explicitly. Revealing
    // from here would stop it, freezing a zoom part-way at a fractional scale.
    if ((window->id==hwm_preserve_focus_window && hwm_now()<hwm_preserve_focus_until) || !view || view->layout!=VIEW_STRIP || hwm_close_target || hwm_plane_pointer_owned() ||
        hwm_camera_animating || __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) || hwm_now()-hwm_last_input<.15) return;
    CGRect bounds=hwm_bounds(view); HWMPlaneCamera current={view->strip_target_offset,hwm_plane_camera_y(hwm_now()),hwm_plane_scale}, next;
    HWMPlaneRect world={window->strip_world_x,window->strip_world_y,window->strip_width,window->strip_height};
    if(hwm_plane_reveal(current,world,(HWMPlaneRect){0,0,bounds.size.width,bounds.size.height},&next))
        hwm_plane_set_camera(view,next.x,next.y,true);
}
static void horizontal_unmanaging(struct window *window)
{
    if(hwm_ready && window) hwm_plane_abort_interaction(window,HWM_PLANE_INTERRUPT_UNMANAGE);
}
static void horizontal_removing(struct window *window, bool whole_app)
{
    if (!hwm_ready || !window) return;
    hwm_plane_abort_interaction(window,HWM_PLANE_INTERRUPT_DESTROY);
    if(hwm_paused) return;
    if(hwm_nav_window==window->id) hwm_focus_queue_clear(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic);
    hwm_hole_note(window_manager_find_managed_window(&g_window_manager,window),window);
    if (whole_app && hwm_close_target) {
        struct window *anchor=window_manager_find_window(&g_window_manager,hwm_close_target);
        if(anchor && anchor->application!=window->application) return;
    }
    if (hwm_close_source==window->id) return;
    bool just_lost_focus=window->id==hwm_previous_focus && hwm_now()-hwm_previous_focus_time<.4;
    if (window->id!=g_window_manager.focused_window_id && !just_lost_focus && !hwm_close_target) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!view || view->layout!=VIEW_STRIP || hwm_shelf_of(window)!=hwm_shelf) return;
    struct window *best=NULL; double distance=INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==window || hwm_shelf_of(w)!=hwm_shelf_of(window) || w->strip_close_ghost || (whole_app && w->application==window->application)) continue;
        double d=fabs(w->strip_world_x-window->strip_world_x)+fabs(w->strip_world_y-window->strip_world_y)*.1;
        if(d<distance) { best=w; distance=d; }
    }
    if(best) {
        hwm_close_source=window->id; hwm_close_target=best->id; hwm_close_time=hwm_now();
        // The camera is already gliding to its resting place around a vacated window.
        hwm_close_screen_x=best->strip_world_x-(window->strip_close_ghost?view->strip_target_offset:just_lost_focus?hwm_previous_focus_offset:hwm_offset(view,hwm_now()));
        hwm_hold_focus(); hwm_wake();
    }
}

static struct window_node *hwm_focused_node(struct view *view)
{
    return view ? view_find_window_node(view, g_window_manager.focused_window_id) : NULL;
}
static uint64_t hwm_column_of(struct window *w) { return w->strip_full_width ? ((uint64_t)w->id<<32)|w->id : (w->strip_column ? w->strip_column : w->id); }
/* Camera offset that centres a tile; one wider than the viewport shows its left edge. */
static double hwm_center_target(struct view *view,struct window *w)
{
    double viewport=hwm_bounds(view).size.width/hwm_plane_scale;
    return w->strip_width>=viewport ? w->strip_world_x : hstrip_center_offset(w->strip_world_x,w->strip_width,viewport);
}
/* The visible window of the column one step left (-1) or right (+1). */
static struct window *hwm_neighbor_column(struct view *view,struct window *from,int direction)
{
    uint64_t own=hwm_column_of(from), found=0; bool seen=false;
    struct window *result=NULL;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]); if(!w || w->strip_close_ghost) continue;
        uint64_t column=hwm_column_of(w);
        if(column==own) { seen=true; if(direction<0) return result; continue; }
        if(direction<0) {
            // Remember the latest column to the left, preferring its shown tab / top row.
            if(column!=found) { found=column; result=w; }
            else if(hwm_workflow_tab_hidden(result) && !hwm_workflow_tab_hidden(w)) result=w;
        } else if(seen) {
            if(!found) { found=column; result=w; }
            else if(column!=found) return result;
            else if(hwm_workflow_tab_hidden(result) && !hwm_workflow_tab_hidden(w)) result=w;
        }
    }
    return direction>0 ? result : NULL;
}
/* Keyboard navigation aims the camera and the border immediately and applies
 * the real focus once the keys rest. Activating every window passed on the way
 * is what made quick presses stutter. */
static void hwm_nav_flush(void)
{
    if(hwm_plane_pointer_owned()) { hwm_focus_queue_clear(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic); return; }
    if(!hwm_nav_pending) return;
    bool suppressed = hwm_nav_automatic && (menu_focus_suppressed() || popup_focus_suppressed());
    uint32_t target = hwm_nav_window;
    if(!hwm_focus_queue_take(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic, suppressed)) {
        // A strip motion may have queued focus before the user opened a menu.
        // Drop it instead of firing after dismissal; the next real hover can
        // choose a target normally.
        return;
    }
    struct window *w=window_manager_find_window(&g_window_manager,target);
    if(!w) return;
    hwm_preserve_focus_window=w->id; hwm_preserve_focus_until=hwm_now()+.6;
    hwm_workflow_note_explicit_focus(w,hwm_view());
    window_manager_focus_window_with_raise(&w->application->psn,w->id,w->ref);
}
static struct window *hwm_nav_base(struct view *view)
{
    if(!view) return window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    struct window *w=hwm_nav_window && hwm_now()-hwm_nav_time<.6 ? window_manager_find_window(&g_window_manager,hwm_nav_window) : NULL;
    if(w && view && view_find_window_node(view,w->id)) return w;
    return window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
}
/* The window a command should act on: the navigation cursor while it leads
 * the reported focus, otherwise the focused window. */
static struct window *hwm_action_window(void)
{
    struct view *view=hwm_view(); struct window *w=hwm_nav_base(view);
    // A tile of a strip that is out of view is not something a command should reach.
    return w && view && hwm_shelf_of(w)!=hwm_shelf && view_find_window_node(view,w->id) ? NULL : w;
}
static void hwm_nav_to(struct view *view,struct window *target)
{
    if(hwm_plane_pointer_owned()) return;
    double now=hwm_now();
    hwm_focus_queue_enqueue(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic, target->id, false); hwm_nav_time=now; hwm_last_input=now;
    hwm_hold_focus();
    hwm_plane_set_camera(view,hwm_center_target(view,target),target->strip_world_y+target->strip_height*.5-hwm_bounds(view).size.height/(2*hwm_plane_scale),true);
    hwm_feedback_focus(NULL,target);
}

#include "plane_selection.m"
/* When the strip is moved under a still pointer, the window that ends up
 * beneath it takes focus without the pointer having to move. Which window
 * that will be is known the moment the camera is given its destination
 * `offset`, so focus does not wait for the strip to arrive. (In centre mode
 * the window brought to the middle of the screen is chosen instead.) Empty
 * desktop under the pointer changes nothing. This reuses the navigation
 * cursor: the border leads and activation follows once the gesture is over. */
static void hwm_focus_follow_to(struct view *view,double offset)
{
    if(!hwm_focus_follow || !view || hwm_drag_window || hwm_overview_active) return;
    CGRect bounds=hwm_bounds(view);
    CGPoint pointer=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    if(hwm_focus_follow==2) {
        if(SLSGetCurrentCursorLocation(g_connection,&pointer)!=kCGErrorSuccess) return;
        // A floating window under the pointer stays in charge: it does not move with the strip.
        bool covered=false;
        table_for(struct window *f,g_window_manager.window, {
            CGRect frame=CGRectNull;
            if(!covered && f->is_root && window_check_flag(f,WINDOW_FLOAT) && !window_check_flag(f,WINDOW_MINIMIZE) && !f->application->is_hidden &&
               window_manager_is_window_eligible(f) && SLSGetWindowBounds(g_connection,f->id,&frame)==kCGErrorSuccess && CGRectContainsPoint(frame,pointer)) covered=true;
        })
        if(covered) return;
    }
    double x=offset+(pointer.x-bounds.origin.x)/hwm_plane_scale, y=hwm_plane_y_target+(pointer.y-bounds.origin.y)/hwm_plane_scale, gap=view->window_gap*.5;
    struct window *target=NULL;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n && !target;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(!w || w->strip_close_ghost || !w->strip_initialized || hwm_workflow_tab_hidden(w)) continue;
        // Half the gap on each side belongs to the nearer window, so the pointer is rarely over nothing.
        if(x<w->strip_world_x-gap || x>w->strip_world_x+w->strip_width+gap) continue;
        if(y<w->strip_world_y-gap || y>w->strip_world_y+w->strip_height+gap) continue;
        target=w; break;
    }
    struct window *current=hwm_action_window();
    if(!target || target==current) return;
    // In centre mode, staying within the focused column keeps the row already in use.
    if(hwm_focus_follow==1 && current && view_find_window_node(view,current->id) && hwm_column_of(current)==hwm_column_of(target)) return;
    // Do this only after finding a possible target.  Native menu notification
    // state is cheap to check; popup enumeration is then avoided for empty
    // canvas movement and neither automatic border nor queue changes occur.
    if(menu_focus_suppressed() || popup_focus_suppressed()) return;
    hwm_focus_queue_enqueue(&hwm_nav_window, &hwm_nav_pending, &hwm_nav_automatic, target->id, true); hwm_nav_time=hwm_now();
    hwm_hold_focus();
    hwm_feedback_focus(NULL,target);
}
static void hwm_commit_order(struct view *view,HStripColumnItem *items,size_t count)
{
    struct window_node *slot=hwm_slot(window_node_find_first_leaf(view->root));
    for(size_t i=0;i<count && slot;i++) {
        struct window_node *found=view_find_window_node(view,(uint32_t)items[i].id);
        if(!found) continue;
        if(found!=slot) window_node_swap_window_list(found,slot);
        slot=hwm_slot(window_node_find_next_leaf(slot));
    }
}
/* Move the focused window's whole column: -1/+1 swap it with the neighbouring
 * column, -2/+2 send it to the start or end of the strip. Stacks travel intact. */
static bool hwm_move_column(struct view *view,struct window *window,int mode)
{
    CGRect bounds=hwm_bounds(view); HStripColumnItem *items=NULL;
    size_t count=hwm_items(view,bounds,&items); if(!items) return false;
    HStripColumnItem *mine=calloc(count?count:1,sizeof(*mine)),*rest=calloc(count?count:1,sizeof(*rest));
    size_t mine_count=0,rest_count=0,position=0; uint64_t own=hwm_column_of(window); bool ok=mine && rest;
    for(size_t i=0;ok && i<count;i++) {
        if(hstrip_columns_key(&items[i])==own) { if(!mine_count) position=rest_count; mine[mine_count++]=items[i]; }
        else rest[rest_count++]=items[i];
    }
    size_t insert=position;
    if(ok && mine_count) {
        if(mode==-2) insert=0;
        else if(mode==2) insert=rest_count;
        else if(mode<0 && position>0) {
            uint64_t key=hstrip_columns_key(&rest[position-1]); insert=position-1;
            while(insert>0 && hstrip_columns_key(&rest[insert-1])==key) --insert;
        } else if(mode>0 && position<rest_count) {
            uint64_t key=hstrip_columns_key(&rest[position]); insert=position+1;
            while(insert<rest_count && hstrip_columns_key(&rest[insert])==key) ++insert;
        }
    }
    ok=ok && mine_count && insert!=position;
    if(ok) {
        hwm_undo_capture();
        memcpy(items,rest,insert*sizeof(*items));
        memcpy(items+insert,mine,mine_count*sizeof(*items));
        memcpy(items+insert+mine_count,rest+insert,(rest_count-insert)*sizeof(*items));
        hwm_commit_order(view,items,count);
        hwm_layout(view,true);
        // Follow the window: it stays under the user's eyes while the strip rearranges.
        hwm_scroll(view,hwm_center_target(view,window),true);
        hwm_hold_focus();
    }
    free(items); free(mine); free(rest);
    return ok;
}
static void hwm_spawn(NSString *command)
{
    if(!command.length) return;
    hwm_hold_focus();
    NSString *copy=[command copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task=[[[NSTask alloc] init] autorelease]; task.launchPath=@"/bin/sh";
        task.arguments=@[@"-c",copy];
        NSError *error=nil;
        if(![task launchAndReturnError:&error]) { warn("Tana2D: launch failed: %s\n",error.localizedDescription.UTF8String); hwm_hud([NSString stringWithFormat:@"Could not run: %@",copy]); }
        [copy release];
    });
}
#include "overview_runtime.m"

static void hwm_action(int action)
{
    if(action==HWM_CANCEL_DRAG) { hwm_cancel_drag(); return; }
    if(action==HWM_OVERVIEW) {
        if(hwm_zoom_workspace) hwm_plane_actual_size(hwm_view());
        else hwm_plane_fit_all(hwm_view());
        return;
    }
    if(action==HWM_OVERVIEW_CANCEL) { hwm_plane_actual_size(hwm_view()); return; }
    if (action==HWM_TERMINAL || action==HWM_BROWSER) {
        hwm_spawn(action==HWM_TERMINAL ? (hwm_terminal_command ?: @"open -na Ghostty")
                                       : (hwm_browser_command ?: @"open -b org.mozilla.firefox"));
        return;
    }
    if (action == HWM_QUIT) { hwm_shutdown(); return; }
    struct view *view = hwm_view();
    struct window *window = hwm_action_window();
    struct window_node *node = view && window ? view_find_window_node(view, window->id) : NULL;
    if (action == HWM_PAUSE) {
        horizontal_overview_done();
        hwm_cancel_closing();
        hwm_cancel_pops();
        hwm_paused = !hwm_paused;
        if(hwm_paused) { hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_PAUSE); hwm_plane_reset_all_transforms(); hwm_visibility_restore_all(); }
        hwm_alpha_sync(hwm_paused);
        hwm_hud(hwm_paused ? @"Tana2D paused. Windows stay where they are." : @"Tana2D resumed");
        hwm_menu_status();
        __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
        if (!hwm_paused) {
            table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
            hwm_layout(view,true);
        }
        return;
    }
    if (hwm_paused || !view) return;
    if (action == HWM_HOME) { hwm_plane_set_camera(view,0,0,true); hwm_focus_follow_to(view,0); return; }
    if (action == HWM_REFLOW) {
        table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
        hwm_layout(view,true); return;
    }
    if (!window) return;
    if(action==HWM_CLOSE) {
        if(node && !window->strip_close_pending && !window->strip_close_ghost) {
            // Give up the window's place now: its neighbours close in while it
            // fades, instead of waiting for the application to finish closing.
            hwm_hole_note(view,window);
            window->strip_close_ghost=true; window->strip_ghost_time=hwm_now();
            hwm_layout(view,true);
        }
        hwm_close_animated(window); return;
    }
    if (action == HWM_FLOAT) {
        bool should_float = !window_check_flag(window, WINDOW_FLOAT);
        if (should_float) {
            CGRect bounds = hwm_bounds(view);
            if(!hwm_plane_reset_transform(window)) return;
            hwm_hole_note(view,window);
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,window,true,true);
            double width = fmin(window->strip_width > 0 ? window->strip_width : 800,bounds.size.width*.8);
            CGRect target=CGRectMake(bounds.origin.x+(bounds.size.width-width)/2,bounds.origin.y+bounds.size.height*.12,width,bounds.size.height*.76);
            // A window that has floated before returns to where it floated.
            CGRect saved=window->strip_float_saved;
            if(saved.size.width>=200 && saved.size.height>=160 && CGRectIntersectsRect(saved,CGRectInset(bounds,40,40))) target=saved;
            hwm_float_to(window,target);
            scripting_addition_set_layer(window->id,LAYER_ABOVE);
        } else {
            CGRect current=window->strip_float_animating ? window->strip_float_target : CGRectNull;
            if(!CGRectIsNull(current) || SLSGetWindowBounds(g_connection,window->id,&current)==kCGErrorSuccess) window->strip_float_saved=current;
            window->strip_float_animating=false; window->strip_float_full=false;
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,window,false,true);
            hwm_layout(view,true);
            horizontal_focused(window,view);
        }
        return;
    }
    if (!node) {
        if (action == HWM_FULL) {
            CGRect bounds = hwm_bounds(view);
            if (!window->strip_float_full) {
                SLSGetWindowBounds(g_connection,window->id,&window->strip_float_restore);
                hwm_float_to(window,bounds);
            } else {
                CGRect f=window->strip_float_restore;
                hwm_float_to(window,f);
            }
            window->strip_float_full=!window->strip_float_full;
        }
        return;
    }
    if (action == HWM_FULL) {
        if (!window->strip_full_width) window->strip_saved_width = window->strip_width;
        window->strip_full_width = !window->strip_full_width;
        if (!window->strip_full_width) window->strip_width = window->strip_saved_width;
        hwm_layout(view,true);
        hwm_scroll(view, window->strip_world_x, true);
    } else if (action == HWM_CENTER) {
        CGRect bounds = hwm_bounds(view);
        hwm_plane_set_camera(view,window->strip_world_x+(window->strip_width-bounds.size.width/hwm_plane_scale)*.5,
                             window->strip_world_y+(window->strip_height-bounds.size.height/hwm_plane_scale)*.5,true);
    } else if (action == HWM_LEFT || action == HWM_RIGHT) {
        struct window *base=hwm_nav_base(view);
        struct window *next=base && view_find_window_node(view,base->id) ? hwm_neighbor_column(view,base,action==HWM_LEFT?-1:1) : NULL;
        if (next) hwm_nav_to(view,next);
        else if (base && view_find_window_node(view,base->id)) { hwm_feedback_navigation(true); hwm_scroll(view,hwm_center_target(view,base),true); }
    } else if (action == HWM_MOVE_LEFT || action == HWM_MOVE_RIGHT || action == HWM_MOVE_FIRST || action == HWM_MOVE_LAST) {
        double step=fmax(80,view->window_gap+80);
        if(action==HWM_MOVE_LEFT) window->strip_world_x-=step;
        else if(action==HWM_MOVE_RIGHT) window->strip_world_x+=step;
        else if(action==HWM_MOVE_FIRST) window->strip_world_x=view->strip_target_offset;
        else window->strip_world_x=view->strip_target_offset+hwm_bounds(view).size.width-window->strip_width;
        hwm_layout(view,true);
    }
}

/* The action bound to a key press, if any. */
static NSString *hwm_shortcut_action(CGEventRef event,int code)
{
    CGEventFlags flags=CGEventGetFlags(event);
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    NSString *name=[snapshot actionForKeyCode:(unsigned short)code modifiers:(NSUInteger)flags];
    // macOS tags physical arrow keys with Function even without an Fn chord.
    if(!name && code>=123 && code<=126) name=[snapshot actionForKeyCode:(unsigned short)code modifiers:((NSUInteger)flags&~NSEventModifierFlagFunction)];
    name=[[name retain] autorelease];
    [snapshot release];
    return name;
}
typedef struct { CGEventType type; CGPoint event,cursor; double dx,dy; uint64_t time; } HWMInputTrace;
static HWMInputTrace hwm_input_trace[1024];
static size_t hwm_input_trace_count;
static pthread_mutex_t hwm_input_trace_lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool hwm_input_trace_enabled;
static void horizontal_input_trace(CGEventType type,CGEventRef event)
{
    if(!atomic_load(&hwm_input_trace_enabled) || (type!=kCGEventLeftMouseDown && type!=kCGEventLeftMouseDragged && type!=kCGEventLeftMouseUp)) return;
    HWMInputTrace row={.type=type,.event=CGEventGetLocation(event),.time=CGEventGetTimestamp(event),
        .dx=CGEventGetDoubleValueField(event,kCGMouseEventDeltaX),.dy=CGEventGetDoubleValueField(event,kCGMouseEventDeltaY)};
    SLSGetCurrentCursorLocation(g_connection,&row.cursor);
    pthread_mutex_lock(&hwm_input_trace_lock);
    hwm_input_trace[hwm_input_trace_count++%1024]=row;
    pthread_mutex_unlock(&hwm_input_trace_lock);
}
static bool horizontal_event(CGEventType type, CGEventRef event)
{
    if (!hwm_ready) return false;
    if(atomic_load(&hwm_resize_captured) && hwm_plane_resize_event(type,event)) {
        hwm_plane_interaction_tap_note_plane_event(type); return true;
    }
    if(hwm_plane_interaction_tap_consume_aborted_up(type)) return true;
    // Native setup and palette editing must keep ordinary app keyboard/mouse behavior.
    if(NSApp.keyWindow && (NSApp.keyWindow==[TanaSetup shared].window || NSApp.keyWindow==[TanaPalette shared].panel)) return false;
    if(hwm_overview_active && (type==kCGEventKeyDown || type==kCGEventKeyUp) &&
       (CGEventGetFlags(event)&(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate))==(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate)) return false;
    // Let the engine's own Space-recovery gesture reach Dock.
    if ((type == 29 || type == 30) && CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID) == getpid()) return false;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        (void)hwm_plane_interaction_tap_abort();
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_PLANE_INTERRUPT);
        hwm_swiping = false;
        hwm_vertical_swiping=false;
        if(hwm_overview_active) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_OVERVIEW_CANCEL);
        __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
        return false;
    }
    if (type == kCGEventKeyUp) {
        int code = (int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if (code >= 0 && code < 128 && hwm_keys[code]) { hwm_keys[code] = false; return true; }
    }
    if(type==kCGEventRightMouseUp || type==kCGEventOtherMouseUp || type==kCGEventRightMouseDragged || type==kCGEventOtherMouseDragged) {
        unsigned button=(unsigned)CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
        if(button<32 && (hwm_zoom_buttons&(1u<<button))) {
            if(type==kCGEventRightMouseUp || type==kCGEventOtherMouseUp) hwm_zoom_buttons&=~(1u<<button);
            return true;
        }
    }
    if (hwm_paused) return false;
    if(!hwm_plane_select_click && [NSRunLoop.currentRunLoop.currentMode isEqualToString:NSEventTrackingRunLoopMode]) return false;
    if(hwm_plane_selecting && !hwm_plane_select_click &&
       (type==kCGEventLeftMouseDown || type==kCGEventLeftMouseUp || type==kCGEventRightMouseDown || type==kCGEventRightMouseUp || type==kCGEventScrollWheel) &&
       !hwm_zoom_workspace_contains(CGEventGetLocation(event))) return false;
    if(hwm_plane_controls_hit(CGEventGetLocation(event)) && !hwm_plane_select_click &&
       (type==kCGEventLeftMouseDown || type==kCGEventLeftMouseUp || type==kCGEventMouseMoved)) return false;
    if(hwm_plane_pick_event(type,event)) { hwm_plane_interaction_tap_note_plane_event(type); return true; }
    if(hwm_plane_resize_event(type,event)) { hwm_plane_interaction_tap_note_plane_event(type); return true; }
    if(type==kCGEventKeyDown && CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53 && hwm_drag_window && !hwm_drag_native) {
        hwm_keys[53]=true; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_CANCEL_DRAG); return true;
    }
    if(hwm_plane_selecting && (hwm_plane_scale<.999 || hwm_camera_animating) && type==kCGEventKeyDown &&
       (CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53 || CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==36)) {
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        hwm_keys[code]=true;
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup("actual-size"),HWM_NAMED_ACTION); return true;
    }
    if(hwm_tab_click && type==kCGEventLeftMouseUp) { hwm_tab_click=false; return true; }
    if(!hwm_overview_active && type==kCGEventLeftMouseDown) {
        NSDictionary *tab=[[TanaFeedback shared] tabAt:CGEventGetLocation(event)];
        if(tab) { hwm_tab_click=true; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,[tab retain],HWM_TAB_SELECT); return true; }
    }
    if(type==kCGEventKeyDown && hwm_key_capture) {
        int mode=atomic_exchange(&hwm_key_capture,0), code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        // Asked for and never answered: after a few seconds the key is an ordinary key again.
        if(mode && code>=0 && code<128 && (double)(read_os_timer()-hwm_key_capture_time)/(double)read_os_freq()<4) {
            hwm_keys[code]=true;
            if(code!=53) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)(uintptr_t)(code|(mode<<8)),HWM_MARK_KEY);
            return true;
        }
    }
    if(hwm_overview_active && (type==kCGEventLeftMouseDown || type==kCGEventMouseMoved ||
       type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp)) {
        // Fully transparent AppKit pixels are click-through. Route the global
        // pointer stream to the selector before ordinary app/drag handling.
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_OVERVIEW_POINTER);
        return true;
    }
    if(hwm_overview_active && type==30 && CGEventGetIntegerValueField(event,110)==23) return true;
    if(hwm_overview_active && type==kCGEventKeyDown) {
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if(code>=0 && code<128) hwm_keys[code]=true;
        // The shortcuts that open the overview also close it; every other key belongs to the overview itself.
        NSString *bound=hwm_shortcut_action(event,code);
        if([bound hasPrefix:@"overview"]) {
            if(!CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(bound.UTF8String),HWM_NAMED_ACTION);
            return true;
        }
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_OVERVIEW_KEY);
        return true;
    }
    if (type == kCGEventKeyDown) {
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags modifiers=flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskShift);
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        // Reserve Control-Up for the same animated chooser as Control-Return.
        if(code==126 && modifiers==kCGEventFlagMaskControl) {
            hwm_keys[code]=true;
            if(!CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)) {
                ++hwm_key_actions;
                event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup("select-window"),HWM_NAMED_ACTION);
            }
            return true;
        }
        if(code==53 && hwm_drag_window && !hwm_drag_native) {
            hwm_keys[code]=true;
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_CANCEL_DRAG); return true;
        }
        (void)modifiers;
        NSString *name=hwm_shortcut_action(event,code);
        // With no overview to close, the key keeps its usual meaning.
        if([name isEqualToString:@"overview-close"]) name=nil;
        if(name) {
            bool repeat=CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat);
            bool allow=[@[@"left",@"right",@"up",@"down",@"move-left",@"move-right",@"swap-left",@"swap-right"] containsObject:name];
            if(!repeat || allow) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(name.UTF8String),HWM_NAMED_ACTION);
            ++hwm_key_actions; if(code>=0 && code<128) hwm_keys[code]=true;
            return true;
        }
    }
    /* A pinch read from the contacts that the system's recogniser took for
     * a scroll: its scroll events would scroll the application under the
     * pointer (or pan the zoomed plane) while the plane zooms, and its
     * momentum would carry on after the fingers lift. The scroll stream is
     * dropped from the moment the zoom engages until that stream ends. */
    if(type==kCGEventScrollWheel) {
        static bool swallowing;
        if(atomic_load(&hwm_contact_pinch_state)==2) { swallowing=true; return true; }
        if(swallowing) {
            int64_t scroll_phase=CGEventGetIntegerValueField(event,kCGScrollWheelEventScrollPhase);
            int64_t momentum=CGEventGetIntegerValueField(event,kCGScrollWheelEventMomentumPhase);
            if(momentum || scroll_phase==kCGScrollPhaseEnded || scroll_phase==kCGScrollPhaseCancelled) return true;
            swallowing=false;
        }
    }
    if (type == kCGEventScrollWheel && (CGEventGetFlags(event)&kCGEventFlagMaskAlternate)) {
        if (CGEventGetFlags(event)&(kCGEventFlagMaskCommand|kCGEventFlagMaskControl)) return false;
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_EVENT);
        return true;
    }
    if(hwm_plane_selecting && !hwm_overview_active) {
        if(type==kCGEventScrollWheel) {
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_EVENT); return true;
        }
        if(type==kCGEventRightMouseDown || type==kCGEventOtherMouseDown) {
            unsigned button=(unsigned)CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber);
            if(button<32) hwm_zoom_buttons|=1u<<button;
        }
        if(type==kCGEventKeyDown) {
            int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
            if(code>=0 && code<128) hwm_keys[code]=true;
        }
        if(type==kCGEventRightMouseDown || type==kCGEventRightMouseUp ||
           type==kCGEventRightMouseDragged || type==kCGEventOtherMouseDown || type==kCGEventOtherMouseUp ||
           type==kCGEventOtherMouseDragged || type==kCGEventKeyDown || type==kCGEventKeyUp) return true;
    }
    /* GestureKit/LinearMouse forwards a real trackpad pinch as a type-29
     * gesture: field 110 is IOHID zoom (8), field 113 is an incremental
     * magnification. Claim it so the focused application does not zoom too. */
    if(type==29 && CGEventGetIntegerValueField(event,110)==8) {
        /* While two fingers are on the trackpad the pinch is read from the
         * contacts; the recogniser's own magnify events for the same fingers
         * (and the tail it reports after they lift) would zoom twice. Magnify
         * events with no fingers down, such as a replayed pinch, still zoom. */
        if(atomic_load(&hwm_contact_pinch_state) || hwm_now()-atomic_load(&hwm_contact_pinch_seen)<.3) return true;
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_EVENT);
        return true;
    }
    if (type == 30 && CGEventGetIntegerValueField(event,110) == 23 &&
        (CGEventGetIntegerValueField(event,123) == 1 || CGEventGetIntegerValueField(event,123) == 2)) {
        int phase = (int)CGEventGetIntegerValueField(event,132);
        if (phase == 1) hwm_swiping = true;
        if (!hwm_swiping) return false;
        hwm_swipe_time = read_os_timer();
        // Raw contacts own three-finger pan and four-finger selection.
        if (phase == 4 || phase == 8) hwm_swiping = false;
        return true;
    }
    // Dock emits a companion gesture stream. Only swallow it during the claimed
    // horizontal gesture, never pinch, rotate, or ordinary two-finger scrolling.
    if (type == 29 && hwm_swiping) {
        if ((double)(read_os_timer()-hwm_swipe_time)/read_os_freq() > 1) hwm_swiping = false;
        return hwm_swiping;
    }
    return false;
}

/* Column extents in strip order; the caller frees both arrays. */
static size_t hwm_columns(struct view *view,double **lefts_out,double **widths_out)
{
    size_t capacity=0,count=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) capacity+=n->window_count;
    double *lefts=calloc(capacity?capacity:1,sizeof(double)),*widths=calloc(capacity?capacity:1,sizeof(double));
    if(lefts && widths) for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(!w || w->strip_close_ghost || !w->strip_initialized || (count && lefts[count-1]==w->strip_world_x)) continue;
        lefts[count]=w->strip_world_x; widths[count++]=w->strip_width;
    }
    *lefts_out=lefts; *widths_out=widths;
    return lefts && widths ? count : 0;
}
/* Where the strip should come to rest near `desired`: a column centred (or
 * flush, in column mode). The decision is made the instant the fingers lift,
 * from where the release velocity was already taking the strip. After a swipe
 * it is directional: going a modest share of the way toward the next column
 * commits to it, so changing window takes a short flick, not a long drag. */
static double hwm_snap_target(struct view *view,double desired,double viewport,bool swipe)
{
    if(!hwm_snap) return desired;
    double *lefts,*widths; size_t count=hwm_columns(view,&lefts,&widths);
    double end=hwm_max_offset(), result=desired;
    if(hwm_snap==2 && count) {
        // Resting offsets in ascending order: each column centred, then the empty end.
        double *rests=calloc(count+1,sizeof(double)); size_t n=0;
        if(rests) {
            for(size_t i=0;i<count;i++) {
                double c=hstrip_snap_center(lefts[i]+widths[i]*.5-viewport*.5,viewport,lefts+i,widths+i,1);
                if(!n || c>rests[n-1]+.5) rests[n++]=c;
            }
            if(isfinite(end) && end>rests[n-1]+.5) rests[n++]=end;
            result=swipe ? hstrip_snap_directional(hwm_snap_origin,desired,rests,n,hwm_snap_threshold)
                         : hstrip_snap_directional(desired,desired,rests,n,hwm_snap_threshold);
            free(rests);
        }
    } else if(count) {
        result=hstrip_snap_offset(desired,viewport,lefts,widths,count,viewport*.5);
        // The empty desktop past the last window is a resting place too.
        if(isfinite(end) && fabs(end-desired)<fabs(result-desired)) result=end;
    }
    free(lefts); free(widths);
    return result;
}
/* While held, the strip leans weakly toward the nearest centred column. */
static double hwm_magnetize(struct view *view,double raw,double viewport)
{
    if(hwm_snap!=2 || !(hwm_magnet>0) || hwm_motion_scale==0) return raw;
    double *lefts,*widths; size_t count=hwm_columns(view,&lefts,&widths);
    double rest=count ? hstrip_snap_center(raw,viewport,lefts,widths,count) : raw;
    free(lefts); free(widths);
    // A detent each time the fingers carry the strip from one column's pull into the next.
    static double last_rest;
    if(count && fabs(rest-last_rest)>1) { if(hwm_swiping_columns) hwm_haptic(0); last_rest=rest; hwm_swiping_columns=true; }
    return hstrip_magnet(raw,rest,viewport*.16,hwm_magnet);
}

static void horizontal_input(void *context, int action)
{
    if(action==HWM_TAB_SELECT) {
        NSDictionary *tab=context; struct window *w=window_manager_find_window(&g_window_manager,[tab[@"id"] unsignedIntValue]);
        if(!hwm_plane_pointer_owned() && w && w->application->pid==[tab[@"pid"] intValue]) window_manager_focus_window_with_raise(&w->application->psn,w->id,w->ref);
        [tab release]; return;
    }
    if(action==HWM_MARK_KEY) { hwm_mark_apply((int)((uintptr_t)context&0xff),(int)((uintptr_t)context>>8)); hwm_wake(); return; }
    if(action==HWM_ATTENTION) { NSArray *pids=context; hwm_attention_apps(pids); [pids release]; return; }
    if(action==HWM_APPLY_RULE) { hwm_apply_app_rule_now(window_manager_find_window(&g_window_manager,(uint32_t)(uintptr_t)context)); return; }
    if(action==HWM_NAMED_ACTION) { hwm_named_action(context); free(context); return; }
    if(action==HWM_OVERVIEW_KEY) {
        CGEventRef event=context; uint64_t generation=hwm_overview_generation;
        dispatch_async(dispatch_get_main_queue(),^{
            if(hwm_overview_active && generation==hwm_overview_generation)
                [[HorizontalWindowOverview sharedOverview] keyEvent:[NSEvent eventWithCGEvent:event]];
            CFRelease(event);
        }); return;
    }
    if(action==HWM_OVERVIEW_HIGHLIGHT) { hwm_overview_highlight((uint32_t)(uintptr_t)context); return; }
    if(action==HWM_OVERVIEW_FILTER) { NSArray *dimmed=context; hwm_overview_filter(dimmed); [dimmed release]; return; }
    if(action==HWM_OVERVIEW_DRAG) {
        NSArray *drag=context;
        hwm_overview_drag([drag[0] unsignedIntValue],[drag[1] intValue],CGPointMake([drag[2] doubleValue],[drag[3] doubleValue]));
        [drag release]; return;
    }
    if(action==HWM_OVERVIEW_POINTER) {
        CGEventRef event=context;
        CGPoint point=CGEventGetLocation(event);
        CGEventType kind=CGEventGetType(event);
        uint64_t generation=hwm_overview_generation;
        NSPoint local=NSMakePoint(point.x-hwm_overview_screen.origin.x,point.y-hwm_overview_screen.origin.y);
        dispatch_async(dispatch_get_main_queue(), ^{
            if(hwm_overview_active && generation==hwm_overview_generation) {
                HorizontalWindowOverview *overview=[HorizontalWindowOverview sharedOverview];
                if(kind==kCGEventLeftMouseDown) [overview pressAt:local];
                else if(kind==kCGEventLeftMouseDragged) [overview dragAt:local];
                else if(kind==kCGEventLeftMouseUp) [overview releaseAt:local];
                else [overview mouseAt:local];
            }
        });
        CFRelease(event); return;
    }
    if(action==HWM_OVERVIEW_GESTURE) {
        if(hwm_vertical_mode && !hwm_overview_active) hwm_shelf_gesture((CGEventRef)context); else hwm_overview_gesture((CGEventRef)context);
        CFRelease(context); return;
    }
    if(action==HWM_PLANE_INTERRUPT) { hwm_plane_abort_interaction(NULL,(HWMPlaneInterruptReason)(intptr_t)context); return; }
    if(action==HWM_PLANE_RESIZE) { hwm_plane_resize_input(context); return; }
    if(action==HWM_PLANE_PICK) {
        HWMPlanePickInput *input=context;
        if(hwm_paused || hwm_suspended || !hwm_plane_pick_input_prepare(input)) { free(input); return; }
        if(input->type==kCGEventLeftMouseUp) hwm_plane_pointer_finish(!input->dragged);
        else hwm_plane_pointer(input->type,input->point);
        free(input); return;
    }
    if(action==HWM_PINCH_FRAME) {
        HWMPlanePinchFrame *frame=context;
        struct view *view=hwm_view();
        /* The pointer does not move during a two-finger gesture; it is asked
         * of WindowServer once, when the zoom engages. */
        static CGPoint pointer;
        if(view && !hwm_paused && !hwm_suspended && !hwm_resize_owned && !hwm_drag_window && !g_mouse_state.window &&
           !mission_control_is_active() && !hwm_plane_gesture.active) {
            if((frame->phase&1) || !CGRectContainsPoint(hwm_bounds(view),pointer)) {
                CGRect bounds=hwm_bounds(view);
                if(SLSGetCurrentCursorLocation(g_connection,&pointer)!=kCGErrorSuccess) pointer=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
            }
            hwm_pinch_input(view,frame->delta,pointer,frame->phase,frame->time,hwm_now());
        }
        free(frame); return;
    }
    if(action==HWM_TOUCH_FRAME) {
        HWMPlaneTouchFrame *sample=context;
        struct view *view=hwm_view();
        if(view && !hwm_paused && !hwm_suspended && !hwm_resize_owned && !hwm_drag_window && !g_mouse_state.window && !mission_control_is_active()) {
            int select=hwm_plane_selection_gesture_sample(&hwm_selection_gesture,sample->device,sample->contacts,sample->count,sample->time);
            if(select || hwm_selection_gesture.engaged || sample->count>=4) {
                horizontal_event_settle();
                hwm_plane_gesture.active=false;
                __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
                if(select) {
                    hwm_plane_pointer_finish(false);
                    if(select>0) { hwm_hold_focus(); hwm_plane_fit_all(view); }
                    else hwm_plane_choose_window(view,hwm_action_window());
                }
                free(sample); return;
            }
            double now=hwm_now(); CGRect bounds=hwm_bounds(view);
            if(sample->count==3 && !hwm_plane_gesture.active) {
                // Panning at 100% browses native windows; it never enters
                // card selection, which would consume Return, Escape and clicks.
                if(hwm_plane_scale<1) hwm_zoom_workspace=true;
                hwm_zoom_cancel_native();
            }
            HWMPlaneCamera camera={hwm_offset(view,now),hwm_plane_camera_y(now),hwm_plane_scale},target;
            if(!hwm_plane_gesture.active && sample->count==3) { hwm_plane_pan_origin=camera; hwm_plane_pan_velocity=(HWMPlaneVelocity){0}; hwm_pan_count=0; hwm_pan_raw_valid=false; }
            // Integrate reports onto the last report, never onto a resampled frame.
            if(hwm_plane_gesture.active && hwm_pan_raw_valid) { camera.x=hwm_pan_raw_x; camera.y=hwm_pan_raw_y; }
            if(hwm_plane_gesture_sample(&hwm_plane_gesture,sample->device,sample->contacts,sample->count,
                                        sample->time,bounds.size.width,sample->aspect,hwm_swipe_gain,camera,&target)) {
                hwm_held_lead=0; hwm_held_count=0; hwm_rubber=0;
                hwm_scroll_current_velocity=0; hwm_plane_y_current_velocity=0; hwm_release_velocity=false;
                /* Lifting: the frame on screen was drawn where the fingers
                 * would be at its vsync, a little ahead of the last report.
                 * Releasing from the report itself stepped the plane back by
                 * that lead, up to a frame or two of travel at speed, before
                 * the glide set off. The glide starts from what is drawn. */
                if(!hwm_plane_gesture.active && hwm_pan_raw_valid) { target.x=hwm_rendered_offset; target.y=hwm_rendered_camera_y; }
                hwm_plane_set_camera(view,target.x,target.y,false);
                if(hwm_plane_gesture.active) {
                    hwm_plane_velocity_add(&hwm_plane_pan_velocity,sample->time,target.x,target.y);
                    hwm_pan_raw_x=target.x; hwm_pan_raw_y=target.y; hwm_pan_raw_valid=true;
                    hwm_pan_note(sample->time,target.x,target.y);
                } else { hwm_pan_raw_valid=false; hwm_pan_count=0; }
                view->strip_last_time=sample->time; hwm_last_input=now;
                __atomic_store_n(&__pending_gesture,hwm_plane_gesture.active,__ATOMIC_RELEASE);
                if(!hwm_plane_gesture.active) {
                    horizontal_event_settle(); // The release may look up windows.
                    hwm_focus_after_scroll=false;
                    __atomic_store_n(&__last_gesture_time,read_os_timer(),__ATOMIC_RELEASE);
                    CGPoint pointer;
                    HWMPlanePoint velocity=hwm_plane_velocity_release(&hwm_plane_pan_velocity,sample->time,
                                                                        hwm_scroll_omega/fmax(.15,hwm_motion_scale));
                    if(!hwm_plane_pan_release(view,hwm_plane_pan_origin,velocity) &&
                       SLSGetCurrentCursorLocation(g_connection,&pointer)==kCGErrorSuccess) hwm_plane_magnet_at(view,pointer,hwm_plane_pan_origin);
                    // A pan released without a glide stays where the fingers
                    // left it; at 100%, ease the last fraction of a point onto
                    // the whole-point grid native frames use.
                    double rest_x=hwm_offset(view,now),rest_y=hwm_plane_camera_y(now);
                    if(hwm_plane_scale==1 && !view->strip_scrolling && !hwm_plane_y_scrolling && !hwm_camera_animating &&
                       (rest_x!=round(rest_x) || rest_y!=round(rest_y))) hwm_plane_set_camera(view,rest_x,rest_y,true);
                }
                hwm_input_log[hwm_input_log_count%HWM_FRAME_LOG].time=sample->time;
                hwm_input_log[hwm_input_log_count++%HWM_FRAME_LOG].offset=target.x;
            }
        } else { hwm_plane_gesture.active=false; hwm_selection_gesture=(HWMPlaneSelectionGesture){0}; __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE); }
        free(sample); return;
    }
    if (action != HWM_EVENT) { hwm_action(action); return; }
    CGEventRef event = context;
    struct view *view = hwm_view();
    if (!view || hwm_paused) { CFRelease(event); return; }
    double now = hwm_now();
    if(CGEventGetType(event)==29 && CGEventGetIntegerValueField(event,110)==8) {
        double delta=CGEventGetDoubleValueField(event,113);
        if(isfinite(delta) && fabs(delta)<4)
            hwm_pinch_input(view,delta,CGEventGetLocation(event),(int)CGEventGetIntegerValueField(event,132),hwm_event_time(event,now),now);
        hwm_last_input=now; CFRelease(event); return;
    }
    if (CGEventGetType(event) == kCGEventScrollWheel) {
        double dx = CGEventGetDoubleValueField(event,kCGScrollWheelEventPointDeltaAxis2);
        double dy = CGEventGetDoubleValueField(event,kCGScrollWheelEventPointDeltaAxis1);
        if(hwm_plane_selecting) {
            hwm_zoom_workspace=true;
            hwm_plane_set_camera(view,view->strip_target_offset+dx/hwm_plane_scale,hwm_plane_y_target+dy/hwm_plane_scale,false);
            hwm_last_input=now; CFRelease(event); return;
        }
        if (CGEventGetFlags(event)&kCGEventFlagMaskShift) {
            hwm_scroll(view,view->strip_offset+(fabs(dx)>fabs(dy)?dx:dy),false);
            hwm_settle_pending=true;
        } else {
            if (now-hwm_last_input > .25 || !hwm_resize_window) { hwm_undo_capture(); hwm_resize_window = g_window_manager.focused_window_id; }
            struct window *window = window_manager_find_window(&g_window_manager,hwm_resize_window);
            if (window && isfinite(dx) && isfinite(dy)) {
                if (window_manager_find_managed_window(&g_window_manager,window)) {
                    window->strip_full_width = false;
                    hwm_column_width(view,window,hstrip_resize_width(window->strip_width,(fabs(dx)>fabs(dy)?dx:-dy)*2,240,hwm_bounds(view).size.width));
                    hwm_layout(view,true);
                } else {
                    CGRect f=window->strip_float_animating ? window->strip_float_target : window->frame;
                    if(!window->strip_float_animating) SLSGetWindowBounds(g_connection,window->id,&f);
                    f.size=CGSizeMake(fmax(200,f.size.width-dx*2),fmax(160,f.size.height-dy*2));
                    hwm_float_to(window,f);
                }
            }
        }
        hwm_last_input = now;
    }
    CFRelease(event);
}

#include "plane_preview.m"
static void hwm_preview_set(CGRect target,CGRect start) { hwm_preview_show(target,start,true); }
static bool hwm_place(struct view *view,uint32_t source,uint32_t target,HStripPlacement placement,bool commit,CGRect *preview)
{
    if(!view) return false;
    CGRect bounds=hwm_bounds(view);
    HStripColumnItem *items; size_t count=hwm_items(view,bounds,&items),from=count,to=count;
    if(!items) return false;
    for(size_t i=0;i<count;i++) { if(items[i].id==source) from=i; if(items[i].id==target) to=i; }
    bool valid=hstrip_columns_place(items,count,from,to,placement);
    if(valid && preview) {
        HStripColumnFrame *frames=calloc(count,sizeof(*frames));
        if(!frames) { free(items); return false; }
        hstrip_columns_layout(items,count,view->window_gap,bounds.size.height,frames);
        for(size_t i=0;i<count;i++) if(frames[i].id==source)
            *preview=CGRectMake(bounds.origin.x+frames[i].x-view->strip_offset,bounds.origin.y+frames[i].y,frames[i].width,frames[i].height);
        free(frames);
    }
    if(valid && commit) {
        struct window_node *slot=hwm_slot(window_node_find_first_leaf(view->root));
        for(size_t i=0;i<count;i++) {
            struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)items[i].id);
            if(!w->strip_full_width || w->id==source || w->id==target) w->strip_column=items[i].column;
            w->strip_weight=items[i].weight;
            w->strip_width=items[i].width;
            if(w->id==source || w->id==target) w->strip_full_width=false;
            struct window_node *found=view_find_window_node(view,w->id);
            if(found && slot) { if(found!=slot) window_node_swap_window_list(found,slot); slot=hwm_slot(window_node_find_next_leaf(slot)); }
        }
        hwm_layout(view,true);
    }
    free(items); return valid;
}
#include "strip_workflow.m"
#include "strip_extras.m"

/* Choose the drop zone under the pointer and show where the window will land.
 * Neighbours stay where they are until the drop: rearranging live windows
 * mid-drag costs Accessibility resizes and moves the very rectangles the
 * pointer is being tested against, which makes the choice oscillate. */
static void hwm_drag_update(struct view *view,struct window *window,CGPoint point)
{
    CGRect bounds=hwm_bounds(view); double offset=hwm_offset(view,hwm_now());
    struct window *target=NULL; HStripPlacement placement=HSTRIP_AFTER_COLUMN;
    CGRect zone=CGRectNull; double nearest=INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(!w || w==window || hwm_workflow_tab_hidden(w)) continue;
        CGRect f=CGRectMake(bounds.origin.x+w->strip_world_x-offset,bounds.origin.y+w->strip_world_y,w->strip_width,w->strip_height);
        if(f.size.width<=0 || f.size.height<=0) continue;
        double dx=fmax(f.origin.x-point.x,fmax(0,point.x-CGRectGetMaxX(f)));
        double dy=fmax(f.origin.y-point.y,fmax(0,point.y-CGRectGetMaxY(f)));
        double distance=hypot(dx,dy);
        if(distance>=nearest) continue;
        nearest=distance; target=w; zone=f;
        double rx=(point.x-f.origin.x)/f.size.width;
        if(rx<.2) placement=HSTRIP_BEFORE_COLUMN;
        else if(rx>.8) placement=HSTRIP_AFTER_COLUMN;
        else placement=point.y<CGRectGetMidY(f)?HSTRIP_ABOVE:HSTRIP_BELOW;
        if(w->id==hwm_drop_target) {
            // Hysteresis: a zone, once chosen, is kept slightly past its boundary.
            double ry=(point.y-f.origin.y)/f.size.height;
            if((hwm_drop_placement==HSTRIP_BEFORE_COLUMN && rx<.27) ||
               (hwm_drop_placement==HSTRIP_AFTER_COLUMN && rx>.73) ||
               (hwm_drop_placement==HSTRIP_ABOVE && rx>.13 && rx<.87 && ry<.58) ||
               (hwm_drop_placement==HSTRIP_BELOW && rx>.13 && rx<.87 && ry>.42)) placement=hwm_drop_placement;
        }
    }
    if(!target) { hwm_drop_target=0; hwm_preview_hide(); return; }
    bool changed=hwm_drop_target!=target->id || hwm_drop_placement!=placement;
    // Validity depends only on the pair and the placement, so test it once per zone.
    if(changed && !hwm_place(view,window->id,target->id,placement,false,NULL)) { hwm_drop_target=0; hwm_preview_hide(); return; }
    if(changed) hwm_haptic(0);
    hwm_drop_target=target->id; hwm_drop_placement=placement;
    double gap=view->window_gap; CGRect preview;
    if(placement==HSTRIP_BEFORE_COLUMN) preview=CGRectMake(zone.origin.x-gap*.5-2,bounds.origin.y,4,bounds.size.height);
    else if(placement==HSTRIP_AFTER_COLUMN) preview=CGRectMake(CGRectGetMaxX(zone)+gap*.5-2,bounds.origin.y,4,bounds.size.height);
    else preview=CGRectMake(zone.origin.x,placement==HSTRIP_ABOVE?zone.origin.y:CGRectGetMidY(zone),zone.size.width,zone.size.height*.5);
    preview=CGRectIntegral(preview);
    hwm_preview_show(preview,CGRectInset(preview,preview.size.width>8?preview.size.width*.08:0,preview.size.height*.08),changed);
}
/* A title-bar drag is reported in display points while a zoomed tile lives in
 * world points. Convert through the scale captured at drag start, then add
 * any camera travel caused by edge autoscroll so the tile remains under the
 * pointer. The real window retains its unscaled size; only its compositor
 * transform changes. */
#include "plane_snap.m"
#include "plane_drag.m"
static void hwm_drag_snap_commit(struct view *view,struct window *window)
{
    CGPoint target;
    if(hwm_snap_free) return;
    if((hwm_snap_window==window->id && hwm_snap_contact_count && (target=hwm_snap_point,true)) ||
       hwm_drag_snap_target(view,window,&target)) {
        bool accepted=(target.x==window->strip_world_x && target.y==window->strip_world_y) ||
                      hwm_drag_present_plane(view,window,target,false);
        if(accepted) { ++hwm_snap_commits; hwm_haptic(1); }
    }
}
#include "plane_pointer.m"
static bool horizontal_owns_native_drag(void)
{
    return hwm_ready && !hwm_paused && hwm_drag_window!=0 && !hwm_drag_native;
}
#include "plane_motion.m"
static void hwm_cancel_drag(void)
{
    struct window *w=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!w) return;
    hwm_pointer_sample_abort_left_press();
    hwm_drag_force_finalize(hwm_view(),false);
    hwm_plane_pick_window=0; hwm_plane_pick_automatic=false;
    hwm_drag_cancelled=true;
    hwm_undo_restore(); hwm_hold_focus();
}

static uint64_t horizontal_destination(struct window *window, uint64_t sid)
{
    if (!hwm_ready || !hwm_space || !space_is_user(sid) || !space_is_user(hwm_space)) return sid;
    if (sid != hwm_space && !scripting_addition_move_window_to_space(hwm_space,window->id)) return sid;
    return hwm_space;
}
static void horizontal_space_changed(void)
{
    if (!hwm_ready || hwm_paused || !hwm_space) return;
    if (!space_is_user(hwm_space)) hwm_space = space_manager_active_space();
    // Native fullscreen is a temporary OS mode; return to the strip when it exits.
    if (space_is_user(g_space_manager.current_space_id) && g_space_manager.current_space_id != hwm_space)
        space_manager_focus_space(hwm_space);
    hwm_wake();
}

static bool hwm_number(struct token token, double *out)
{
    if (token.length < 1 || token.length > 63) return false;
    char text[64]; memcpy(text,token.text,token.length); text[token.length] = 0;
    char *end = NULL; *out = strtod(text,&end);
    return end && *end == 0 && isfinite(*out);
}
#include "plane_fixture_input.m"
static void horizontal_command(FILE *rsp, char *message)
{
    struct token command = get_token(&message);
    if(token_equals(command,"fixture-only")) {
#ifdef HWM_TEST_FIXTURE_ONLY
        fprintf(rsp,"true\n");
#else
        fprintf(rsp,"false\n");
#endif
        return;
    }
    if(token_equals(command,"zoom-status")) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:hwm_zoom_native_diagnostics() options:0 error:NULL];
        fwrite(data.bytes,1,data.length,rsp);fputc('\n',rsp);return;
    }
    if(token_equals(command,"hover-status")) {
        NSMutableArray *rows=[NSMutableArray array];
        unsigned count=MIN(hwm_hover_timing_count,128);
        for(unsigned i=0;i<count;i++) {
            HWMHoverTiming t=hwm_hover_timings[(hwm_hover_timing_count-count+i)%128];
            [rows addObject:@{@"id":@(t.wid),@"started":@(t.started),@"issued":@(t.issued),@"ms":@((t.issued-t.started)*1000),@"workspace":@(t.workspace)}];
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"samples":rows,@"shield":@(atomic_load(&hwm_zoom_shield_requested)),@"inputWindow":@(hwm_zoom_input_window)} options:0 error:NULL];
        fwrite(data.bytes,1,data.length,rsp);fputc('\n',rsp);return;
    }
    if(token_equals(command,"fixture-hover")) {
        double id,x,y;
        if(!hwm_number(get_token(&message),&id) || !hwm_number(get_token(&message),&x) || !hwm_number(get_token(&message),&y) || id<1 || id>UINT32_MAX) { daemon_fail(rsp,"expected fixture id x y\n");return; }
        struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)id);
        if(!w || !w->application->name || strcmp(w->application->name,"Tana2DFixture")) { daemon_fail(rsp,"hover replay requires a managed Tana2DFixture window\n");return; }
        horizontal_native_hover(CGPointMake(x,y),(uint64_t)(hwm_now()*1e9));fprintf(rsp,"{}\n");return;
    }
    if(token_equals(command,"fixture-pointer")) { hwm_fixture_pointer(rsp,message); return; }
#if defined(HWM_TEST_FIXTURE_ONLY) || defined(HWM_TEST_INPUT_REPLAY)
    if(token_equals(command,"fixture-swipe")) { hwm_fixture_swipe(rsp,message); return; }
#endif
    if(token_equals(command,"subscribe")) {
        if(!hwm_ipc_subscribe(rsp)) { daemon_fail(rsp,"too many subscribers\n"); return; }
        fprintf(rsp,"{\"event\":\"subscribed\",\"version\":\"0.6.5\",\"strip\":%d}\n",hwm_shelf+1); fflush(rsp);
        hwm_ipc_layout(hwm_view()); return;
    }
    if(token_equals(command,"mark") || token_equals(command,"jump-mark")) {
        // With a key named the mark is used at once; without one the next key press names it.
        struct token key=get_token(&message);
        if(key.length>0 && key.length<16) {
            char text[16]; memcpy(text,key.text,key.length); text[key.length]=0;
            int code=hwm_key_code(@(text));
            if(code<0 || !hwm_mark_apply(code,token_equals(command,"mark")?1:2)) daemon_fail(rsp,"no such mark\n");
            return;
        }
    }
    if(token_equals(command,"jump")) {
        struct token app=get_token(&message);
        if(app.length<1 || app.length>199) { daemon_fail(rsp,"expected an application bundle identifier\n"); return; }
        NSString *bundle=[[[NSString alloc] initWithBytes:app.text length:app.length encoding:NSUTF8StringEncoding] autorelease];
        struct token launch=get_token(&message);
        NSString *command_text=launch.length ? [[[NSString alloc] initWithBytes:launch.text length:launch.length encoding:NSUTF8StringEncoding] autorelease] : nil;
        if(bundle) hwm_jump(bundle,command_text);
        return;
    }
    if(token_equals(command,"layout-list")) {
        NSData *json=[NSJSONSerialization dataWithJSONObject:hwm_arrangement_names() options:0 error:NULL];
        fwrite(json.bytes,1,json.length,rsp); fputc('\n',rsp); return;
    }
    if(token_equals(command,"layout-save") || token_equals(command,"layout-load")) {
        struct token label=get_token(&message);
        NSString *name=label.length ? [[[NSString alloc] initWithBytes:label.text length:label.length encoding:NSUTF8StringEncoding] autorelease] : nil;
        bool ok=name && (token_equals(command,"layout-save") ? hwm_arrangement_save(name) : hwm_arrangement_load(name));
        if(!ok) daemon_fail(rsp,token_equals(command,"layout-save") ? "layout names use letters, digits, spaces, - and _\n" : "no such layout\n");
        else if(token_equals(command,"layout-save")) hwm_hud([NSString stringWithFormat:@"Layout saved as “%@”",name]);
        return;
    }
    if(token_equals(command,"camera") || token_equals(command,"pan")) {
        if(hwm_plane_pointer_owned()) { daemon_fail(rsp,"finish the active pointer interaction before moving the camera\n"); return; }
        double x,y;
        if(!hwm_number(get_token(&message),&x) || !hwm_number(get_token(&message),&y)) { daemon_fail(rsp,"expected x y\n"); return; }
        struct view *view=hwm_view();
        if(!view) { daemon_fail(rsp,"plane unavailable\n"); return; }
        if(token_equals(command,"pan")) { x+=view->strip_target_offset; y+=hwm_plane_y_target; }
        hwm_plane_set_camera(view,x,y,true); return;
    }
    if(token_equals(command,"zoom")) {
        if(hwm_plane_pointer_owned()) { daemon_fail(rsp,"finish the active pointer interaction before zooming\n"); return; }
        double scale; if(!hwm_number(get_token(&message),&scale) || scale<HWM_PLANE_MIN_SCALE || scale>HWM_PLANE_MAX_SCALE) { daemon_fail(rsp,"zoom must be between 0.001 and 1 (100%%)\n"); return; }
        struct view *view=hwm_view(); if(!view) return;
        if(scale==1) { hwm_plane_actual_size(view); return; }
        hwm_zoom_cancel_native(); hwm_zoom_workspace=true;
        /* Finish sampling the previous zoom before assigning the new scale.
         * Otherwise hwm_scroll's camera stop restores the old animated scale. */
        hwm_plane_camera_stop(view,hwm_now());
        CGRect b=hwm_bounds(view); double old=hwm_plane_scale;
        double cx=view->strip_target_offset+b.size.width/(2*old), cy=hwm_plane_y_target+b.size.height/(2*old);
        hwm_plane_scale=scale; hwm_plane_fit_active=fabs(scale-1)>.001;
        hwm_plane_set_camera(view,cx-b.size.width/(2*scale),cy-b.size.height/(2*scale),true); return;
    }
    if(token_equals(command,"place")) {
        double id,x,y,width=NAN,height=NAN;
        if(!hwm_number(get_token(&message),&id) || !hwm_number(get_token(&message),&x) || !hwm_number(get_token(&message),&y)) { daemon_fail(rsp,"expected id x y [width height]\n"); return; }
        if(id<1 || id>UINT32_MAX || floor(id)!=id) { daemon_fail(rsp,"invalid window ID\n"); return; }
        struct token maybe_width=get_token(&message);
        if(maybe_width.length && (!hwm_number(maybe_width,&width) || !hwm_number(get_token(&message),&height))) { daemon_fail(rsp,"width and height must be supplied together\n"); return; }
        if(maybe_width.length && (width<160 || height<100 || width>20000 || height>20000)) { daemon_fail(rsp,"window size out of range\n"); return; }
        struct view *view=hwm_view(); struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)id);
        if(!view || !w || !view_find_window_node(view,w->id)) { daemon_fail(rsp,"unknown plane window\n"); return; }
        hwm_undo_capture(); w->strip_world_x=x; w->strip_world_y=y;
        if(isfinite(width) && width>=160 && height>=100) { w->strip_width=width; w->strip_height=height; }
        hwm_layout(view,true); return;
    }
    if(command.length>0 && command.length<80) {
        char name[80]; memcpy(name,command.text,command.length); name[command.length]=0;
        if(hwm_named_action(name)) return;
    }
    if(token_equals(command,"input-trace-start") || token_equals(command,"input-trace")) {
        bool start=token_equals(command,"input-trace-start");
        atomic_store(&hwm_input_trace_enabled,false);
        pthread_mutex_lock(&hwm_input_trace_lock);
        if(start) hwm_input_trace_count=0;
        fprintf(rsp,"[");
        for(size_t i=hwm_input_trace_count>1024?hwm_input_trace_count-1024:0;i<hwm_input_trace_count;i++) {
            HWMInputTrace r=hwm_input_trace[i%1024];
            fprintf(rsp,"%s{\"type\":%u,\"time\":%llu,\"event\":[%.4f,%.4f],\"cursor\":[%.4f,%.4f],\"delta\":[%.4f,%.4f]}",i==(hwm_input_trace_count>1024?hwm_input_trace_count-1024:0)?"":",",r.type,(unsigned long long)r.time,r.event.x,r.event.y,r.cursor.x,r.cursor.y,r.dx,r.dy);
        }
        fprintf(rsp,"]\n"); pthread_mutex_unlock(&hwm_input_trace_lock);
        atomic_store(&hwm_input_trace_enabled,start); return;
    }
    if(token_equals(command,"focus-status")) {
        CGPoint cursor=CGPointZero; SLSGetCurrentCursorLocation(g_connection,&cursor);
        NSMutableArray *menus=[NSMutableArray array];
        if(ffm_menus) for(id item in (NSArray *)ffm_menus) {
            AXUIElementRef menu=(AXUIElementRef)item; pid_t owner=0;
            AXError owner_error=AXUIElementGetPid(menu,&owner);
            uint32_t wid=ax_window_id(menu); uint8_t ordered=0;
            CGError error=wid?SLSWindowIsOrderedIn(g_connection,wid,&ordered):kCGErrorFailure;
            [menus addObject:@{@"pid":@(owner),@"pidError":@(owner_error),@"window":@(wid),@"ordered":@(ordered),@"orderError":@(error)}];
        }
        NSDictionary *state=@{@"focusedWindow":@(g_window_manager.focused_window_id),@"frontPid":@(g_process_manager.front_pid),
            @"hoverFocusPending":@(g_mouse_state.ffm_window_id),@"focusGuard":@(hwm_focus_guard),
            @"focusGuardAge":@(hwm_now()-hwm_focus_guard_time),@"focusGuardPoint":@[@(hwm_focus_guard_point.x),@(hwm_focus_guard_point.y)],
            @"cursor":@[@(cursor.x),@(cursor.y)],@"menus":menus,
            @"menuSuppressed":@(menu_focus_suppressed()),@"popupSuppressed":@(popup_focus_suppressed()),
            @"hoverRechecks":@(hwm_hover_rechecks),@"hoverRechecksReached":@(hwm_hover_recheck_reached),@"hoverRechecksLost":@(hwm_hover_recheck_lost),
            @"hoverFocusPaths":@[@(hwm_hover_focus_paths[0]),@(hwm_hover_focus_paths[1]),@(hwm_hover_focus_paths[2]),@(hwm_hover_focus_paths[3])],@"frontSwitches":@(hwm_event_prof[APPLICATION_FRONT_SWITCHED].count)};
        NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
        fwrite(data.bytes,1,data.length,rsp); fputc('\n',rsp); return;
    }
    if(token_equals(command,"presentation-status")) {
        double identifier;
        if(!hwm_number(get_token(&message),&identifier) || identifier<1 || identifier>UINT32_MAX) { daemon_fail(rsp,"expected window id\n"); return; }
        struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)identifier);
        if(!w) { daemon_fail(rsp,"window not found\n"); return; }
        CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,w->id,&actual);
        CGRect displayed=CGRectZero,border=CGRectZero;
        bool displayedValid=hwm_plane_displayed_frame(w->id,&displayed);
        bool borderVisible=hwm_plane_border_visible && hwm_plane_border_focus==w->id;
        bool borderValid=borderVisible && hwm_plane_displayed_frame(hwm_plane_border_id,&border);
        if(borderValid) border=hwm_plane_border_frame; // The ring is several strips; report the whole.
        struct view *view=window_manager_find_managed_window(&g_window_manager,w);
        NSDictionary *state=@{@"id":@(w->id),@"displayedValid":@(displayedValid),@"borderValid":@(borderValid),@"borderVisible":@(borderVisible),
            @"displayedX":@(displayed.origin.x),@"displayedY":@(displayed.origin.y),@"displayedWidth":@(displayed.size.width),@"displayedHeight":@(displayed.size.height),
            @"borderX":@(border.origin.x),@"borderY":@(border.origin.y),@"borderWidth":@(border.size.width),@"borderHeight":@(border.size.height),
            @"borderWindow":@(hwm_plane_border_id),
            @"borderPad":@(fmax(2,hwm_border_width)),@"cameraX":@(view?hwm_offset(view,hwm_now()):0),@"cameraY":@(hwm_plane_camera_y(hwm_now())),@"cameraScale":@(hwm_plane_scale),
            @"navigationPending":@(hwm_nav_pending),@"navigationWindow":@(hwm_nav_window),@"focusedWindow":@(g_window_manager.focused_window_id),
            @"nativeX":@(actual.origin.x),@"nativeY":@(actual.origin.y),@"nativeWidth":@(actual.size.width),@"nativeHeight":@(actual.size.height),
            @"worldWidth":@(w->strip_width),@"worldHeight":@(w->strip_height),@"nativeResizeEvents":@(w->strip_native_resize_events),
            @"worldX":@(w->strip_world_x),@"worldY":@(w->strip_world_y),@"cachedX":@(w->strip_last_frame.origin.x),@"cachedY":@(w->strip_last_frame.origin.y),
            @"nativeResizePending":@(w->strip_native_resize_pending),@"nativeMovePending":@(w->strip_native_move_pending),@"sizePending":@(w->strip_size_pending),@"resizeBusy":@(hwm_resize_busy(w)),
            @"snapActive":@(hwm_snap_window==w->id && hwm_snap_neighbor!=0),@"snapNeighbor":@(hwm_snap_window==w->id?hwm_snap_neighbor:0),
            @"snapEdge":@(hwm_snap_axis*2+hwm_snap_side),@"snapX":@(hwm_snap_point.x),@"snapY":@(hwm_snap_point.y),@"snapContacts":@(hwm_snap_contact_count),
            @"snapEngagements":@(hwm_snap_engagements),@"snapCommits":@(hwm_snap_commits),@"hapticsEnabled":@(hwm_haptics),
            @"snapPreviewVisible":@(hwm_preview_visible && hwm_preview_ordered && !hwm_preview_hiding),@"snapPreviewWindow":@(hwm_preview_id),
            @"snapSeams":@(hwm_preview_snap_mode?hwm_preview_seam_count:0),@"snapPreviewMargin":@(hwm_preview_snap_mode?hwm_preview_margin(hwm_preview_gutter):0),@"snapFree":@(hwm_snap_free),@"previewDraws":@(hwm_preview_draws),@"previewMoves":@(hwm_preview_moves),
            @"transformDirty":@(w->strip_transform_dirty),@"scale":@(w->strip_last_plane_scale),@"edge":@(hwm_edge_window==w->id),
            @"drag":@(hwm_drag_window==w->id),@"nativeDrag":@(hwm_drag_window==w->id && hwm_drag_native),@"hiddenTab":@(hwm_workflow_tab_hidden(w)),@"layout":@(view?view->layout:0)};
        NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
        fwrite(data.bytes,1,data.length,rsp); fputc('\n',rsp); return;
    }
    if(token_equals(command,"config-status")) {
        TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"path":hwm_config.path,@"motionStrength":@(snapshot.motionStrength),@"effectiveMotionStrength":@(hwm_motion_scale),@"showStripMap":@(snapshot.showStripMap),@"autofocus":g_window_manager.ffm_mode==FFM_DISABLED?@"off":hwm_pointer_focus?@"pointer-movement":@"after-scroll",@"shortcutConflicts":snapshot.shortcutConflicts,@"error":hwm_config.lastError ?: @"",@"problems":hwm_config_problems ?: @[],@"hotReload":@(hwm_hot_reload),@"snap":@(hwm_snap),@"border":@(hwm_border_on()),@"inactiveOpacity":@(hwm_inactive_alpha),@"windowDuration":@(hwm_duration)} options:0 error:NULL];
        fwrite(json.bytes,1,json.length,rsp); fputc('\n',rsp); [snapshot release]; return;
    }
    if(token_equals(command,"profile") || token_equals(command,"profile-reset")) {
        fprintf(rsp,"{\"ax_resizes\":%llu,\"ax_resizes_coalesced\":%llu,\"ax_resize_max_ms\":%.3f,\"drag_presentations\":%llu,\"drag_present_avg_ms\":%.3f,\"drag_present_max_ms\":%.3f,\"drag_ms\":%.3f,\"render_ms\":%.3f,\"extras_ms\":%.3f,\"preview_ms\":%.3f,\"feedback_ms\":%.3f,\"tick_while_dragging_ms\":%.3f,\"drag_ticks\":%llu,\"drag_events\":%llu,\"overlay_refreshes\":%llu,\"overlay_refresh_max_ms\":%.3f,\"max_frame_ms\":%.3f,\"border_window\":%u,\"display_hz\":%.2f,\"border_ms\":%.3f,\"release_ms\":%.3f,\"hover_ms\":%.3f,\"border_paint_ms\":%.3f,\"border_shape_ms\":%.3f,\"border_atomic\":%s}\n",
                (unsigned long long)hwm_ax_resizes_sent,(unsigned long long)hwm_ax_resizes_coalesced,(double)hwm_ax_resize_max_ms,(unsigned long long)hwm_drag_present_count,hwm_drag_present_count?hwm_drag_present_total_ms/hwm_drag_present_count:0,hwm_drag_present_max_ms,hwm_prof[HWM_PROF_DRAG],hwm_prof[HWM_PROF_RENDER],hwm_prof[HWM_PROF_EXTRAS],hwm_prof[HWM_PROF_PREVIEW],hwm_prof[HWM_PROF_FEEDBACK],hwm_prof[HWM_PROF_TICK_DRAGGING],
                (unsigned long long)hwm_prof_drag_ticks,(unsigned long long)hwm_prof_drag_events,(unsigned long long)hwm_feedback_shows,(double)hwm_feedback_show_max_ms,hwm_max_frame_ms,hwm_plane_border_id,(double)hwm_display_hz,hwm_prof[HWM_PROF_BORDER],hwm_prof[HWM_PROF_RELEASE],hwm_prof[HWM_PROF_HOVER],hwm_prof[HWM_PROF_BORDER_PAINT],hwm_prof[HWM_PROF_BORDER_SHAPE],hwm_plane_border_atomic()?"true":"false");
        if(token_equals(command,"profile-reset")) { memset(hwm_prof,0,sizeof(hwm_prof)); hwm_drag_present_count=0; hwm_drag_present_total_ms=hwm_drag_present_max_ms=0; hwm_prof_drag_ticks=0; hwm_prof_drag_events=0; hwm_feedback_shows=0; hwm_feedback_show_max_ms=0; hwm_ax_resizes_sent=0; hwm_ax_resizes_coalesced=0; hwm_ax_resize_max_ms=0; hwm_max_frame_ms=0; hwm_slow_frames=0; hwm_frames=0; }
        return;
    }
    if(token_equals(command,"pacing") || token_equals(command,"pacing-reset")) {
        fprintf(rsp,"{\"frames\":%llu,\"frames_over_8ms\":%llu,\"max_frame_ms\":%.3f,\"tick_latency_avg_ms\":%.3f,\"tick_latency_max_ms\":%.3f,\"ticks_late_over_4ms\":%llu,\"frames_dropped\":%llu,\"frame_gap_max_ms\":%.3f,\"stalls_over_2ms\":%llu,\"stall_max_ms\":%.3f,\"stall_event\":\"%s\",\"events\":{",
                (unsigned long long)hwm_frames,(unsigned long long)hwm_slow_frames,hwm_max_frame_ms,hwm_event_prof[HORIZONTAL_TICK].count?hwm_tick_latency_total_ms/(double)hwm_event_prof[HORIZONTAL_TICK].count:0,hwm_tick_latency_max_ms,
                (unsigned long long)hwm_tick_late,(unsigned long long)hwm_frames_dropped,hwm_frame_gap_max_ms,(unsigned long long)hwm_stalls,hwm_stall_max_ms,hwm_stall_type>=0?hwm_event_names[hwm_stall_type]:"");
        bool first=true;
        for(int i=0;i<(int)(sizeof(hwm_event_names)/sizeof(*hwm_event_names)) && i<64;i++) if(hwm_event_prof[i].count) {
            fprintf(rsp,"%s\"%s\":{\"count\":%llu,\"avg_ms\":%.3f,\"max_ms\":%.3f}",first?"":",",hwm_event_names[i],(unsigned long long)hwm_event_prof[i].count,hwm_event_prof[i].total_ms/(double)hwm_event_prof[i].count,hwm_event_prof[i].max_ms);
            first=false;
        }
        fprintf(rsp,"}}\n");
        if(token_equals(command,"pacing-reset")) {
            memset(hwm_event_prof,0,sizeof(hwm_event_prof)); hwm_tick_late=0; hwm_frames_dropped=0; hwm_stalls=0; hwm_stall_type=-1;
            hwm_tick_latency_max_ms=0; hwm_tick_latency_total_ms=0; hwm_frame_gap_max_ms=0; hwm_stall_max_ms=0;
            hwm_frames=0; hwm_slow_frames=0; hwm_max_frame_ms=0; hwm_frame_log_count=0; hwm_input_log_count=0;
        }
        return;
    }
    if(token_equals(command,"frame-log")) {
        // The most recent frames and held-swipe samples, oldest first.
        uint64_t frames=hwm_frame_log_count<HWM_FRAME_LOG?hwm_frame_log_count:HWM_FRAME_LOG, inputs=hwm_input_log_count<HWM_FRAME_LOG?hwm_input_log_count:HWM_FRAME_LOG;
        fprintf(rsp,"{\"frames\":[");
        for(uint64_t i=0;i<frames;i++) { uint64_t k=(hwm_frame_log_count-frames+i)%HWM_FRAME_LOG;
            // Camera y and zoom come last, so readers of the first four fields are unchanged.
            fprintf(rsp,"%s[%.5f,%.2f,%.3f,%.3f,%.2f,%.5f]",i?",":"",hwm_frame_log[k].time,hwm_frame_log[k].offset,hwm_frame_log[k].tick_ms,hwm_frame_log[k].latency_ms,
                    hwm_frame_log[k].camera_y,hwm_frame_log[k].scale); }
        fprintf(rsp,"],\"inputs\":[");
        for(uint64_t i=0;i<inputs;i++) { uint64_t k=(hwm_input_log_count-inputs+i)%HWM_FRAME_LOG;
            fprintf(rsp,"%s[%.5f,%.2f]",i?",":"",hwm_input_log[k].time,hwm_input_log[k].offset); }
        fprintf(rsp,"],\"raw_touch_available\":%s,\"raw_touch_frames\":%llu}\n",hwm_mt_available?"true":"false",(unsigned long long)__atomic_load_n(&hwm_mt_frames,__ATOMIC_RELAXED)); return;
    }
    if(token_equals(command,"overview")) { hwm_action(HWM_OVERVIEW); return; }
    if(token_equals(command,"overview-cancel")) { hwm_action(HWM_OVERVIEW_CANCEL); return; }
    if(token_equals(command,"overview-progress")) {
        daemon_fail(rsp,"overview-progress was replaced by workspace zoom; use zoom, fit-all, or actual-size\n");
        return;
    }
    if (token_equals(command,"close")) { hwm_action(HWM_CLOSE); return; }
    if (token_equals(command,"quit")) { hwm_stop_requested = 1; hwm_wake(); return; }
    struct view *view = hwm_view();
    if (token_equals(command,"input-status")) {
        CFMachPortRef tap=__atomic_load_n(&g_mouse_state.handle,__ATOMIC_RELAXED);
        fprintf(rsp,"{\"tap_enabled\":%s,\"key_actions\":%llu,\"suspended\":%s,\"selecting\":%s,\"overview\":%s,\"overview_renderer\":\"native\",\"overview_windows\":%u,\"overview_frames\":%llu,\"overview_frames_over_8ms\":%llu,\"overview_max_frame_ms\":%.3f,\"overview_queue_max_ms\":%.3f,\"overview_flush_max_ms\":%.3f,\"overview_present_max_ms\":%.3f,\"overview_begin_ms\":%.3f,\"vertical_progress\":%.4f,\"overview_closing\":%s,\"overview_animating\":%s,\"overview_gesture_active\":%s,\"mission_control\":%s}\n",tap&&CGEventTapIsEnabled(tap)?"true":"false",(unsigned long long)hwm_key_actions,hwm_suspended?"true":"false",hwm_plane_selecting?"true":"false",hwm_overview_active?"true":"false",(unsigned)hwm_overview_window_count,(unsigned long long)hwm_overview_frames,(unsigned long long)hwm_overview_slow_frames,hwm_overview_max_frame_ms,hwm_overview_queue_max_ms,hwm_overview_flush_max_ms,hwm_overview_present_max_ms,hwm_overview_begin_ms,hwm_vertical_last_progress,hwm_overview_closing?"true":"false",hwm_overview_animating?"true":"false",hwm_overview_gesture_active?"true":"false",mission_control_is_active()?"true":"false"); return;
    }
    if (token_equals(command,"status")) {
        CGRect viewport=view?hwm_bounds(view):CGRectZero;
        fprintf(rsp,"{\"version\":\"0.6.5\",\"zoom_mode\":\"%s\",\"plane\":true,\"ready\":%s,\"paused\":%s,\"backend\":%s,\"space\":%llu,\"camera\":{\"x\":%.3f,\"y\":%.3f,\"scale\":%.5f},\"viewport\":{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f},\"autofocus\":%s,\"frames\":%llu,\"frames_over_8ms\":%llu,\"max_frame_ms\":%.3f,\"move_failures\":%llu,\"resize_operations\":%llu,\"windows\":[",hwm_zoom_workspace?"workspace":hwm_plane_selecting?"preparing":"native",hwm_ready?"true":"false",hwm_paused?"true":"false",hwm_backend_ok?"true":"false",(unsigned long long)hwm_space,view?view->strip_target_offset:0,hwm_plane_y_target,hwm_plane_scale,viewport.origin.x,viewport.origin.y,viewport.size.width,viewport.size.height,g_window_manager.ffm_mode==FFM_AUTOFOCUS?"true":"false",(unsigned long long)hwm_frames,(unsigned long long)hwm_slow_frames,hwm_max_frame_ms,(unsigned long long)hwm_move_failures,(unsigned long long)hwm_resize_operations);
        bool comma = false;
        if (view) for (struct window_node *n = window_node_find_first_leaf(view->root); n; n = window_node_find_next_leaf(n)) {
            for (int i=0;i<n->window_count;++i) {
                struct window *w = window_manager_find_window(&g_window_manager,n->window_list[i]);
                if (!w) continue;
                fprintf(rsp,"%s{\"id\":%u,\"world\":{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f}}",comma?",":"",w->id,w->strip_world_x,w->strip_world_y,w->strip_width,w->strip_height); comma=true;
            }
        }
        fprintf(rsp,"]}\n"); return;
    }
    if(token_equals(command,"preview-off")) { hwm_preview_hide(); return; }
    if(token_equals(command,"place") || token_equals(command,"preview")) {
        double source,target; struct token position;
        if(!hwm_number(get_token(&message),&source) || !hwm_number(get_token(&message),&target) || source<1 || source>UINT32_MAX || target<1 || target>UINT32_MAX) { daemon_fail(rsp,"expected source and target window IDs\n"); return; }
        position=get_token(&message); int placement=-1;
        if(token_equals(position,"left")) placement=HSTRIP_BEFORE_COLUMN;
        if(token_equals(position,"right")) placement=HSTRIP_AFTER_COLUMN;
        if(token_equals(position,"above")) placement=HSTRIP_ABOVE;
        if(token_equals(position,"below")) placement=HSTRIP_BELOW;
        bool commit=token_equals(command,"place"); CGRect preview=CGRectNull;
        if(commit) hwm_undo_capture();
        if(placement<0 || !hwm_place(view,(uint32_t)source,(uint32_t)target,placement,commit,commit?NULL:&preview)) daemon_fail(rsp,"invalid placement\n");
        else if(!commit) {
            CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,(uint32_t)source,&actual);
            hwm_preview_set(preview,actual);
        }
        return;
    }
    if (token_equals(command,"scroll") || token_equals(command,"width")) {
        double value;
        if (!hwm_number(get_token(&message),&value)) { daemon_fail(rsp,"expected a finite number\n"); return; }
        if (token_equals(command,"scroll")) { hwm_scroll(view,value,true); hwm_focus_follow_to(view,view->strip_target_offset); }
        else {
            struct window *w = window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
            if (!w || !hwm_focused_node(view)) { daemon_fail(rsp,"focus a tiled window first\n"); return; }
            if (value<240 || value>hwm_bounds(view).size.width) { daemon_fail(rsp,"width must be between 240 and the viewport width\n"); return; }
            hwm_undo_capture(); hwm_column_width(view,w,value); hwm_layout(view,true);
        }
        return;
    }
    char *names[] = {"left","right","move-left","move-right","float","full","center","home","pause","reflow"};
    int actions[] = {HWM_LEFT,HWM_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_FLOAT,HWM_FULL,HWM_CENTER,HWM_HOME,HWM_PAUSE,HWM_REFLOW};
    for (int i=0;i<10;++i) if (token_equals(command,names[i])) { hwm_action(actions[i]); return; }
    daemon_fail(rsp,"strip commands: status, config-status, subscribe, left, right, move-left, move-right, move-first, move-last, float, sticky, full, center, home, scroll <offset>, width <points>, fit-visible, equalize, strip-up, strip-down, strip-<1-9>, send-strip-up, send-strip-down, send-strip-<1-9>, mark [key], jump-mark [key], jump <bundle id> [launch command], layout-save <name>, layout-load <name>, layout-list, overview, commands, reload-config, pause, reflow, quit\n");
}

void horizontal_plane_action(const char *name)
{
    if(!name || (strcmp(name,"fit-all") && strcmp(name,"fit-focused") && strcmp(name,"actual-size"))) return;
    event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(name),HWM_NAMED_ACTION);
}

/* One list feeds both the menu and the command palette. */
static NSArray *hwm_command_sections(void)
{
    return @[
      @[@"Workspace",@[@[@"select-window",@"Show workspace"],@[@"actual-size",@"Return to window (100%)"],@[@"home",@"Return to origin"]]],
      @[@"Navigate",@[@[@"left",@"Focus left"],@[@"right",@"Focus right"],@[@"up",@"Focus above"],@[@"down",@"Focus below"],@[@"previous",@"Previous window"],@[@"center",@"Center window"]]],
      @[@"Arrange",@[@[@"move-left",@"Move left"],@[@"move-right",@"Move right"],@[@"move-up",@"Move up"],@[@"move-down",@"Move down"],@[@"arrange-grid",@"Arrange in grid"],@[@"preset-width",@"Cycle window width"],@[@"undo",@"Undo arrangement"]]],
      @[@"Window",@[@[@"maximize",@"Fill screen at 100%"],@[@"float",@"Float / tile"],@[@"close",@"Close window"],@[@"terminal",@"New terminal"],@[@"browser",@"Open browser"]]],
      @[@"Tana2D",@[@[@"setup",@"Setup & Settings…"],@[@"reload-config",@"Reload config file"],@[@"pause",@"Pause / resume"]]]];
}
static NSArray *hwm_palette_commands(void)
{
    NSMutableArray *commands=[NSMutableArray array];
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    for(NSArray *section in hwm_command_sections()) for(NSArray *entry in section[1])
        [commands addObject:@[entry[0],[NSString stringWithFormat:@"%@: %@",section[0],entry[1]],TanaBindingDescription(snapshot.shortcuts[entry[0]])]];
    [commands addObject:@[@"quit",@"Tana2D: Quit and restore windows",@""]];
    [snapshot release];
    return commands;
}
/* A menu key equivalent for a binding, or nil when AppKit cannot display it. */
static NSString *hwm_key_equivalent(TanaShortcutBinding *binding)
{
    static NSDictionary *special;
    if(!special) special=[@{@"left":[NSString stringWithFormat:@"%C",(unichar)NSLeftArrowFunctionKey],@"right":[NSString stringWithFormat:@"%C",(unichar)NSRightArrowFunctionKey],
        @"up":[NSString stringWithFormat:@"%C",(unichar)NSUpArrowFunctionKey],@"down":[NSString stringWithFormat:@"%C",(unichar)NSDownArrowFunctionKey],
        @"return":@"\r",@"space":@" ",@"tab":@"\t",@"escape":@"\e",@"delete":@"\b"} retain];
    for(NSString *candidate in [[tana_key_codes() allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if([tana_key_codes()[candidate] unsignedShortValue]!=binding.keyCode || [candidate isEqual:@"enter"] || [candidate isEqual:@"esc"]) continue;
        return special[candidate] ?: candidate;
    }
    return nil;
}
@interface TanaApplicationDelegate : NSObject <NSApplicationDelegate>
@end
@implementation TanaApplicationDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{ (void)app; (void)visible; [[TanaSetup shared] showForStartup:NO preview:NO]; return YES; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{ (void)app; if(!hwm_ready) return NSTerminateNow; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup("quit"),HWM_NAMED_ACTION); return NSTerminateCancel; }
@end
static TanaApplicationDelegate *tana_application_delegate;

@interface HorizontalMenu : NSObject
@property(nonatomic, retain) NSStatusItem *item;
- (void)named:(NSMenuItem *)sender;
@end
@implementation HorizontalMenu
- (void)named:(NSMenuItem *)sender { event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup([sender.representedObject UTF8String]),HWM_NAMED_ACTION); }
@end
static HorizontalMenu *hwm_menu;
/* The menu bar icon carries the state a fading HUD cannot: paused, or the
 * window helper lost. Callable from any thread. */
static void hwm_menu_status(void)
{
    bool paused=hwm_paused,lost=hwm_helper_lost_shown;
    dispatch_async(dispatch_get_main_queue(),^{
        if(!hwm_menu) return;
        NSString *name=lost ? @"exclamationmark.triangle" : paused ? @"pause.circle" : @"square.grid.2x2";
        NSString *label=lost ? @"Tana2D: window helper disconnected" : paused ? @"Tana2D: paused" : @"Tana2D window manager";
        NSImage *symbol=[NSImage imageWithSystemSymbolName:name accessibilityDescription:label];
        if(symbol) { symbol.template=YES; hwm_menu.item.button.image=symbol; }
        hwm_menu.item.button.accessibilityLabel=label;
        hwm_menu.item.button.toolTip=lost ? @"Tana2D — the window helper is disconnected. Open Setup to reconnect." :
                                      paused ? @"Tana2D — paused. Choose Resume Tana2D to continue." : @"Tana2D — an open two-dimensional workspace";
        for(NSMenuItem *item in hwm_menu.item.menu.itemArray) {
            if([item.representedObject isEqual:@"pause"]) item.title=paused ? @"Resume Tana2D" : @"Pause Tana2D";
            if([item.representedObject isEqual:@"setup"] && item.tag==1) item.title=lost ? @"Reconnect Window Helper…" : @"Setup & Settings…";
        }
    });
}
static void hwm_menu_refresh_bindings(void)
{
    if(!hwm_menu) return;
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    for(NSMenuItem *item in hwm_menu.item.menu.itemArray) {
        if(![item.representedObject isKindOfClass:[NSString class]]) continue;
        TanaShortcutBinding *binding=snapshot.shortcuts[item.representedObject];
        NSString *key=binding ? hwm_key_equivalent(binding) : nil;
        // Real key equivalents: AppKit right-aligns them like any other menu.
        item.keyEquivalent=key ?: @"";
        item.keyEquivalentModifierMask=key ? (binding.modifiers&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl|NSEventModifierFlagShift)) : 0;
    }
    [snapshot release];
}
static void hwm_menu_begin(void)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    tana_application_delegate=[TanaApplicationDelegate new]; NSApp.delegate=tana_application_delegate;
    hwm_menu = [HorizontalMenu new];
    hwm_menu.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *symbol=[NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:@"Tana2D"];
    if(symbol) { symbol.template=YES; hwm_menu.item.button.image=symbol; } else hwm_menu.item.button.title = @"↔";
    hwm_menu.item.button.toolTip = @"Tana2D — an open two-dimensional workspace";
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Tana2D"] autorelease];
    NSMenuItem *palette=[[[NSMenuItem alloc] initWithTitle:@"Command Palette…" action:@selector(named:) keyEquivalent:@""] autorelease];
    palette.target=hwm_menu; palette.representedObject=@"commands"; [menu addItem:palette];
    NSMenuItem *setup=[[[NSMenuItem alloc] initWithTitle:@"Setup & Settings…" action:@selector(named:) keyEquivalent:@""] autorelease];
    setup.target=hwm_menu; setup.representedObject=@"setup"; setup.tag=1; [menu addItem:setup];
    hwm_menu.item.button.accessibilityLabel=@"Tana2D window manager";
    for(NSArray *section in hwm_command_sections()) {
        [menu addItem:[NSMenuItem separatorItem]];
        if(@available(macOS 14.0,*)) [menu addItem:[NSMenuItem sectionHeaderWithTitle:section[0]]];
        for(NSArray *entry in section[1]) {
            if([entry[0] isEqual:@"setup"]) continue; // Already first in the menu.
            NSMenuItem *item=[[[NSMenuItem alloc] initWithTitle:[entry[0] isEqual:@"pause"] ? @"Pause Tana2D" : entry[1] action:@selector(named:) keyEquivalent:@""] autorelease];
            item.target=hwm_menu; item.representedObject=entry[0]; [menu addItem:item];
        }
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit=[[[NSMenuItem alloc] initWithTitle:@"Quit Tana2D" action:@selector(named:) keyEquivalent:@""] autorelease];
    quit.target=hwm_menu; quit.representedObject=@"quit"; [menu addItem:quit];
    hwm_menu.item.menu = menu;
    hwm_menu_refresh_bindings();
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.apple.screenIsLocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n; hwm_suspended=true;
        (void)hwm_plane_interaction_tap_abort();
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)(intptr_t)HWM_PLANE_INTERRUPT_SUSPEND,HWM_PLANE_INTERRUPT);
        [[HorizontalWindowOverview sharedOverview] dismissImmediately];
        event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_DONE,NULL,0);
    }];
    [[NSWorkspace sharedWorkspace].notificationCenter addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n; event_loop_post(&g_event_loop,HORIZONTAL_RESUME,NULL,0);
    }];
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ event_loop_post(&g_event_loop,HORIZONTAL_RESUME,NULL,0); });
    }];
}

/* Bring every window's opacity in line with the dim setting, or (restore) hand
 * back full opacity to those Tana2D changed. Untouched windows are left alone. */
static void hwm_alpha_sync(bool restore)
{
    table_for(struct window *w,g_window_manager.window, {
        if(!w->is_root || w->strip_pop || w->strip_close_pending || !window_manager_is_window_eligible(w) || !window_is_standard(w)) continue;
        float current=w->strip_alpha>0 ? w->strip_alpha : 1;
        float target=restore ? 1 : hwm_window_alpha(w);
        if(fabsf(current-target)<.001f) continue;
        scripting_addition_set_opacity(w->id,target,.16f);
        w->strip_alpha=target;
    })
}

static NSString *hwm_state_path(void)
{
#ifdef HWM_TEST_FIXTURE_ONLY
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"tana2d-fixture-only-layout.json"];
#endif
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tana2D/layout.json"];
}
static long long hwm_boot_time(void)
{
    struct timeval boot = {0}; size_t length = sizeof(boot);
    sysctlbyname("kern.boottime",&boot,&length,NULL,0);
    return boot.tv_sec;
}
static void hwm_save_state_now(bool wait)
{
    struct view *view = hwm_view(); if (!view || hwm_resume_load_state) return;
    NSMutableArray *order = [NSMutableArray array];
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n))
        for (int i=0;i<n->window_count;++i) [order addObject:@(n->window_list[i])];
    NSMutableArray *windows = [NSMutableArray array];
    table_for (struct window *w,g_window_manager.window, {
        if (!window_manager_is_window_eligible(w) || !window_is_standard(w)) continue;
        [windows addObject:(@{@"id":@(w->id),@"pid":@(w->application->pid),@"x":@(w->strip_world_x),@"y":@(w->strip_world_y),@"width":@(w->strip_width),@"height":@(w->strip_height),@"restore_width":@(w->strip_saved_width),@"floating":@(window_check_flag(w,WINDOW_FLOAT)),@"sticky":@(w->strip_sticky)})];
    })
    NSMutableArray *offsets=[NSMutableArray array]; NSMutableDictionary *marks=[NSMutableDictionary dictionary];
    for(int i=0;i<HWM_SHELVES;i++) [offsets addObject:@(i==hwm_shelf ? view->strip_target_offset : hwm_shelf_offsets[i])];
    for(int i=0;i<128;i++) if(hwm_workflow_live(hwm_marks[i])) marks[@(i).stringValue]=@{@"id":@(hwm_marks[i].id),@"pid":@(hwm_marks[i].pid)};
    NSDictionary *state=@{@"version":@3,@"boot":@(hwm_boot_time()),@"camera":@{@"x":@(view->strip_target_offset),@"y":@(hwm_plane_y_target),@"scale":@(hwm_plane_scale)},@"order":order,@"windows":windows,@"marks":marks};
    NSString *path=hwm_state_path();
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    if(!data) { warn("Tana2D: layout could not be saved.\n"); return; }
    hwm_state_pending=false;
    // The snapshot is taken here; the disk is touched on its own queue, in
    // order, so a save after every settled animation never costs a frame.
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("tana2d.state",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0)); });
    void (^write)(void)=^{
        NSError *error=nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
        if ([data writeToFile:path options:NSDataWritingAtomic error:&error])
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
        else warn("Tana2D: layout could not be saved: %s\n",error.localizedDescription.UTF8String);
    };
    if(wait) dispatch_sync(queue,write); else dispatch_async(queue,write);
}
static void hwm_save_state(void) { hwm_save_state_now(false); }
static void hwm_load_state(void)
{
    NSData *data=[NSData dataWithContentsOfFile:hwm_state_path()];
    if (!data) return;
    id state=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:[NSDictionary class]] || ![state[@"version"] isKindOfClass:[NSNumber class]] || ![state[@"boot"] isKindOfClass:[NSNumber class]] || ([state[@"version"] intValue]!=2 && [state[@"version"] intValue]!=3) || [state[@"boot"] longLongValue]!=hwm_boot_time()) return;
    if (![state[@"windows"] isKindOfClass:[NSArray class]] || ![state[@"order"] isKindOfClass:[NSArray class]]) return;
    NSMutableSet *matched=[NSMutableSet set];
    for (id entry in state[@"windows"]) {
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"id"] isKindOfClass:[NSNumber class]] || ![entry[@"pid"] isKindOfClass:[NSNumber class]]) continue;
        struct window *w=window_manager_find_window(&g_window_manager,[entry[@"id"] unsignedIntValue]);
        if (!w || w->application->pid != [entry[@"pid"] intValue] || !window_is_standard(w)) continue;
        double width=[entry[@"width"] isKindOfClass:[NSNumber class]] ? [entry[@"width"] doubleValue] : 0;
        if ([state[@"version"] intValue]>=3 && isfinite(width) && width>=160 && width<=20000) w->strip_width=width;
        double height=[entry[@"height"] isKindOfClass:[NSNumber class]] ? [entry[@"height"] doubleValue] : 0;
        if ([state[@"version"] intValue]>=3 && isfinite(height) && height>=100 && height<=20000) w->strip_height=height;
        if(!hwm_zoom_restore_sizes) hwm_zoom_restore_sizes=[NSMutableSet new];
        [hwm_zoom_restore_sizes addObject:@(w->id)];
        double x=[entry[@"x"] isKindOfClass:[NSNumber class]] ? [entry[@"x"] doubleValue] : NAN;
        double y=[entry[@"y"] isKindOfClass:[NSNumber class]] ? [entry[@"y"] doubleValue] : NAN;
        if(isfinite(x) && isfinite(y)) { w->strip_world_x=x; w->strip_world_y=y; w->strip_initialized=true; }
        double saved=[entry[@"restore_width"] isKindOfClass:[NSNumber class]] ? [entry[@"restore_width"] doubleValue] : 0;
        w->strip_column=w->id;
        w->strip_saved_width=isfinite(saved) && saved>=240 && saved<=20000 ? saved : 800;
        w->strip_full_width=false; w->strip_weight=1; w->strip_shelf=0;
        w->strip_sticky=[entry[@"sticky"] isKindOfClass:[NSNumber class]] && [entry[@"sticky"] boolValue];
        if ([entry[@"floating"] isKindOfClass:[NSNumber class]])
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,w,[entry[@"floating"] boolValue],true);
        [matched addObject:entry[@"id"]];
    }
    struct view *view=hwm_view();
    struct window_node *slot=window_node_find_first_leaf(view->root);
    for (id identifier in state[@"order"]) {
        if (![identifier isKindOfClass:[NSNumber class]] || ![matched containsObject:identifier] || !slot) continue;
        struct window_node *found=view_find_window_node(view,[identifier unsignedIntValue]);
        if (!found) continue;
        // Bubble instead of swap to preserve the order of newly created windows.
        while (found != slot) {
            struct window_node *previous=window_node_find_prev_leaf(found);
            if (!previous) break;
            window_node_swap_window_list(previous,found); found=previous;
        }
        [matched removeObject:identifier];
        slot=window_node_find_next_leaf(slot);
    }
    if ([state[@"marks"] isKindOfClass:[NSDictionary class]]) for (NSString *key in state[@"marks"]) {
        NSDictionary *mark=state[@"marks"][key]; int code=[key isKindOfClass:[NSString class]] ? key.intValue : -1;
        if (code<0 || code>=128 || ![mark isKindOfClass:[NSDictionary class]] || ![mark[@"id"] isKindOfClass:[NSNumber class]] || ![mark[@"pid"] isKindOfClass:[NSNumber class]]) continue;
        hwm_marks[code]=(HWMWorkflowIdentity){[mark[@"id"] unsignedIntValue],[mark[@"pid"] intValue]};
    }
    NSDictionary *camera=[state[@"camera"] isKindOfClass:[NSDictionary class]] ? state[@"camera"] : nil;
    double x=[camera[@"x"] isKindOfClass:[NSNumber class]] ? [camera[@"x"] doubleValue] : 0;
    double y=[camera[@"y"] isKindOfClass:[NSNumber class]] ? [camera[@"y"] doubleValue] : 0;
    double scale=[camera[@"scale"] isKindOfClass:[NSNumber class]] ? [camera[@"scale"] doubleValue] : 1;
    if(isfinite(scale) && scale>0) { hwm_plane_scale=hwm_plane_zoom_clamp(scale); hwm_plane_fit_active=fabs(hwm_plane_scale-1)>.001; }
    hwm_zoom_workspace=hwm_plane_scale<1; hwm_plane_selecting=false;
    hwm_plane_set_camera(view,isfinite(x)?x:0,isfinite(y)?y:0,false);
}
static void hwm_signal_stop(int signal_number) { (void)signal_number; hwm_stop_requested = 1; }
static void hwm_remember(struct window *window)
{
    if (window->strip_remembered) return;
    window->strip_remembered = true;
    window->strip_original_frame = window->frame;
    window->strip_original_space = window_space(window->id);
    int raw_layer = window_sub_level(window->id);
    window->strip_original_layer = LAYER_NORMAL;
    for (int key=0;key<kCGNumberOfWindowLevelKeys;++key) {
        if (CGWindowLevelForKey((CGWindowLevelKey)key)==raw_layer) {
            window->strip_original_layer=key; break;
        }
    }
}
static void horizontal_window_added(struct window *window)
{
    if (!window->is_root || !window_manager_is_window_eligible(window)) return;
    hwm_remember(window);
    if (!hwm_ready) return;
    window->strip_added=hwm_now(); window->strip_shelf=hwm_shelf;
    horizontal_destination(window,window_space(window->id));
    hwm_apply_app_rule(window);
    if (window_check_flag(window,WINDOW_FLOAT)) scripting_addition_set_layer(window->id,LAYER_ABOVE);
}
static void hwm_shutdown(void)
{
    if (!hwm_ready) return;
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_SHUTDOWN);
    if(hwm_zoom_group)dispatch_group_wait(hwm_zoom_group,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
    dispatch_sync(dispatch_get_main_queue(), ^{ hwm_mt_end(); hwm_ca_stop(); });
    horizontal_overview_done();
    hwm_preview_hide_immediately();
    hwm_feedback_hide();
    hwm_cancel_closing();
    hwm_cancel_pops();
    hwm_plane_reset_all_transforms();
    hwm_visibility_restore_all();
    hwm_alpha_sync(true);
    hwm_plane_controls_update(false,1);
    hwm_zoom_shield_update(false);
    hwm_save_state_now(true); // On disk before the process goes away.
    window_manager_set_menubar_opacity(&g_window_manager,1.0f);
    hwm_ready = false;
    __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
    if(hwm_display_link) CVDisplayLinkStop(hwm_display_link);
    if(hwm_fallback_timer) dispatch_source_cancel(hwm_fallback_timer);
    // Restore geometry before releasing the lock. No window remains stranded
    // offscreen when the app quits normally or receives SIGTERM/SIGINT.
    table_for (struct window *window, g_window_manager.window, {
        if (!window->strip_remembered || !window_manager_is_window_eligible(window) || window_check_flag(window,WINDOW_FULLSCREEN) || !space_is_user(window->strip_original_space)) continue;
        CGRect f = window->strip_original_frame;
        if (space_is_user(window->strip_original_space))
            scripting_addition_move_window_to_space(window->strip_original_space,window->id);
        window_manager_set_window_frame(window,f.origin.x,f.origin.y,f.size.width,f.size.height);
        scripting_addition_move_window(window->id,f.origin.x,f.origin.y);
        // The helper accepts CGWindowLevelKey, not a raw WindowServer sublevel.
        scripting_addition_set_layer(window->id,window->strip_original_layer);
    })
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
static void horizontal_begin(void)
{
    hwm_space = space_manager_active_space();
    if (!space_is_user(hwm_space)) error("Tana2D: start from a normal desktop, not native fullscreen.\n");
    char helper_version[256] = {0}; uint32_t helper_attributes = 0;
    // Direct WindowServer placement does not depend on Dock's optional
    // set-front-window signature. AX supplies window activation separately.
    hwm_backend_ok = scripting_addition_request_handshake(helper_version,sizeof(helper_version),&helper_attributes) &&
                     OSAX_VERSION_COMPATIBLE(helper_version) && (helper_attributes & OSAX_ATTRIB_PLANE_TRANSFORM);
    if (!hwm_backend_ok) error("Tana2D: window helper is unavailable; no windows were moved. Open Tana2D Setup & Settings to reconnect.\n");
    hwm_config_begin();
    hwm_ready = true;
    dispatch_async(dispatch_get_main_queue(), ^{ hwm_mt_begin(); });
    signal(SIGTERM, hwm_signal_stop);
    signal(SIGINT, hwm_signal_stop);
    // New windows always join this one strip, independent of their app's saved Space.
    table_for (struct window *window, g_window_manager.window, {
        hwm_remember(window);
        window->strip_placed=true; // Already somewhere; only windows opened from now on are given a place.
        if (window->is_root && window_manager_is_window_eligible(window) && space_is_user(window_space(window->id))) {
            if (window_space(window->id) != hwm_space) window_manager_send_window_to_space(&g_space_manager,&g_window_manager,window,hwm_space,false);
            if (window_check_flag(window,WINDOW_FLOAT)) scripting_addition_set_layer(window->id,LAYER_ABOVE);
            uint8_t ordered=0; SLSWindowIsOrderedIn(g_connection,window->id,&ordered);
            // A window closed but kept by its application (Slack, say) joins when shown again.
            if (!ordered) window->strip_ordered_out=true;
            if (ordered && window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager,window)) {
                struct view *view = space_manager_tile_window_on_space(&g_space_manager,window,hwm_space);
                window_manager_add_managed_window(&g_window_manager,window,view);
            }
        }
    })
    update_window_notifications();
    table_for(struct window *w,g_window_manager.window,{ horizontal_ordered(w->id); })
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();
    if(session) { hwm_suspended=[((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue]; CFRelease(session); }
    hwm_start_clock();
    int observed=0;
    table_for(struct application *a,g_window_manager.application,{ (void)a; ++observed; })
    hwm_resume_load_state=observed==0;
    if(!hwm_resume_load_state) {
        if([[NSFileManager defaultManager] fileExistsAtPath:hwm_state_path()]) hwm_load_state();
        else { hwm_layout(hwm_view(),false); hwm_plane_arrange_grid(hwm_view()); }
    }
    hwm_layout(hwm_view(),true);
    hwm_external_borders_refresh();
    hwm_alpha_focus=hwm_feedback_focus_id=g_window_manager.focused_window_id;
    hwm_alpha_sync(false);
    dispatch_async(dispatch_get_main_queue(), ^{
        // An agent with no windows of its own is a candidate for App Nap,
        // which throttles exactly the timers and threads that draw frames.
        static id activity;
        if(!activity) activity=[[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Window management must respond to input without delay"] retain];
        hwm_menu_begin();
        hwm_plane_controls_begin();
        hwm_plane_controls_update(true,hwm_plane_scale);
        [[HorizontalWindowOverview sharedOverview] prepareForScreenFrame:CGDisplayBounds(CGMainDisplayID())];
    });
}

static void horizontal_resume(void)
{
    hwm_plane_abort_interaction(NULL,HWM_PLANE_INTERRUPT_RESUME);
    if(!hwm_ready) return;
    float menu_alpha=space_is_fullscreen(space_manager_active_space()) ? 1.0f : g_window_manager.menubar_opacity;
    SLSSetMenuBarInsetAndAlpha(g_connection,0,1,menu_alpha);
    hwm_cancel_closing();
    hwm_suspended=false;
    hwm_start_clock();
    table_for(struct process *process,g_process_manager.process, {
        if (!window_manager_find_application(&g_window_manager,process->pid) && workspace_application_is_observable(process))
            EVENT_HANDLER_APPLICATION_LAUNCHED(process,0);
    })
    space_manager_refresh_application_windows(&g_space_manager);
    table_for(struct window *w,g_window_manager.window, {
        if(w->is_root && window_manager_is_window_eligible(w) && space_is_user(window_space(w->id))) {
            horizontal_destination(w,window_space(w->id));
            if(window_manager_should_manage_window(w) && !window_manager_find_managed_window(&g_window_manager,w)) {
                struct view *view=space_manager_tile_window_on_space(&g_space_manager,w,hwm_space);
                window_manager_add_managed_window(&g_window_manager,w,view);
            }
            w->strip_last_frame=CGRectNull;
        }
    })
    if(hwm_resume_load_state) { hwm_resume_load_state=false;
        if([[NSFileManager defaultManager] fileExistsAtPath:hwm_state_path()]) hwm_load_state();
        else { hwm_layout(hwm_view(),false); hwm_plane_arrange_grid(hwm_view()); }
    }
    hwm_layout(hwm_view(),true);
    struct window *focus=window_manager_focused_window(&g_window_manager);
    if(focus) horizontal_focused(focus,window_manager_find_managed_window(&g_window_manager,focus));
}

#include "plane_clock.m"
static void hwm_start_clock(void)
{
    if(!hwm_fallback_timer) {
        hwm_fallback_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(hwm_fallback_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/10,10*NSEC_PER_MSEC);
        __block double last_reconcile=0; __block bool fast=false;
        dispatch_source_set_event_handler(hwm_fallback_timer,^{
            double now=hwm_now(); bool expected=false;
            if(now-last_reconcile>.095 && __atomic_compare_exchange_n(&hwm_reconcile_pending,&expected,true,false,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) {
                last_reconcile=now; event_loop_post(&g_event_loop,HORIZONTAL_RECONCILE,NULL,0);
            }
            // With the display clock running this timer only paces the
            // housekeeping sweep. It becomes the frame clock, at frame rate,
            // only for as long as the display clock is not running.
            bool stand_in=hwm_stop_requested || (!hwm_ca_clock_running && (!hwm_display_link || !CVDisplayLinkIsRunning(hwm_display_link)));
            if(stand_in!=fast) {
                fast=stand_in;
                dispatch_source_set_timer(hwm_fallback_timer,dispatch_time(DISPATCH_TIME_NOW,0),fast?NSEC_PER_SEC/120:NSEC_PER_SEC/10,(fast?1:10)*NSEC_PER_MSEC);
            }
            if(stand_in) hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
            else if(hwm_ready && !hwm_backend_ok && !__atomic_load_n(&hwm_active,__ATOMIC_ACQUIRE)) {
                // Retry a helper that is not answering at the sweep's pace.
                bool idle=false;
                if(__atomic_compare_exchange_n(&hwm_tick_pending,&idle,true,false,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) event_loop_post(&g_event_loop,HORIZONTAL_TICK,NULL,0);
            }
        });
        dispatch_resume(hwm_fallback_timer);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ hwm_ca_start(); });
}

static void horizontal_ordered(uint32_t wid)
{
    if(!hwm_ready || hwm_suspended) return;
    struct window *w=window_manager_find_window(&g_window_manager,wid);
    if(!w || window_check_flag(w,WINDOW_FULLSCREEN)) return;
    uint8_t ordered=0;
    if(SLSWindowIsOrderedIn(g_connection,wid,&ordered)!=kCGErrorSuccess) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,w);
    if(!ordered && view && view->layout==VIEW_STRIP) {
        if(!hwm_plane_reset_transform(w)) return;
        horizontal_removing(w,false);
        w->strip_ordered_out=true;
        space_manager_untile_window(view,w);
        window_manager_remove_managed_window(&g_window_manager,wid);
    } else if(!ordered && !view && w->is_root) {
        // Hidden while unmanaged (its app hidden, say): still adopt it when it returns.
        w->strip_ordered_out=true;
    } else if(ordered && w->strip_ordered_out) {
        w->strip_ordered_out=false;
        if(window_manager_should_manage_window(w) && !view) {
            view=space_manager_tile_window_on_space(&g_space_manager,w,hwm_space);
            window_manager_add_managed_window(&g_window_manager,w,view);
        }
    }
}

/* An application's window-created notification can be lost, or arrive before
 * the window answers Accessibility (Chrome, opening a window while busy). Such
 * a window is never tracked, so it stays where it opened while the plane moves
 * past it. WindowServer still lists it: ask its application again, backing off
 * for windows that never resolve (helper surfaces with no Accessibility). */
static bool hwm_adopt_in_flight;
static void hwm_adopt_missed_windows(double now)
{
    enum { MISSED = 64 };
    static struct { uint32_t wid; double next, delay; } missed[MISSED];
    int count=0;
    uint32_t *list=space_window_list(hwm_space,&count,false);
    if(!list) return;
    // Forget windows that closed or left this desktop.
    for(int j=0;j<MISSED;++j) {
        bool listed=false;
        for(int i=0;i<count && !listed;++i) listed=list[i]==missed[j].wid;
        if(!listed) missed[j].wid=0;
    }
    for(int i=0;i<count;++i) {
        uint32_t wid=list[i];
        if(window_manager_find_window(&g_window_manager,wid)) continue;
        int slot=-1,free_slot=-1;
        for(int j=0;j<MISSED;++j) {
            if(missed[j].wid==wid) { slot=j; break; }
            if(free_slot<0 && (!missed[j].wid || window_manager_find_window(&g_window_manager,missed[j].wid))) free_slot=j;
        }
        if(slot<0) {
            if(free_slot<0) continue;
            slot=free_slot; missed[slot].wid=wid; missed[slot].delay=.5; missed[slot].next=now+.5; continue;
        }
        if(now<missed[slot].next) continue;
        missed[slot].delay=fmin(missed[slot].delay*2,60); missed[slot].next=now+missed[slot].delay;
        int connection=0; pid_t pid=0;
        if(SLSGetWindowOwner(g_connection,wid,&connection)!=kCGErrorSuccess || SLSConnectionGetPID(connection,&pid)!=kCGErrorSuccess) continue;
        if(!window_manager_find_application(&g_window_manager,pid)) continue;
        /* The busy application this targets can hold an Accessibility query
         * for the full global timeout. Ask it off the event loop, which also
         * runs the frames, with a short timeout of its own. The slot keeps its
         * backoff: a window yabai then declines to manage is asked again
         * only at the backed-off pace, and the slot is reused once tracked. */
        if(__atomic_exchange_n(&hwm_adopt_in_flight,true,__ATOMIC_ACQ_REL)) continue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            AXUIElementRef app=AXUIElementCreateApplication(pid);
            CFTypeRef windows=NULL;
            if(app) {
                AXUIElementSetMessagingTimeout(app,.25f);
                AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&windows);
                CFRelease(app);
            }
            if(windows && CFGetTypeID(windows)==CFArrayGetTypeID()) {
                for(CFIndex k=0;k<CFArrayGetCount(windows);++k) {
                    AXUIElementRef ref=CFArrayGetValueAtIndex(windows,k);
                    if(ax_window_id(ref)!=wid) continue;
                    event_loop_post(&g_event_loop,WINDOW_CREATED,(void *)CFRetain(ref),0);
                    break;
                }
            }
            if(windows) CFRelease(windows);
            __atomic_store_n(&hwm_adopt_in_flight,false,__ATOMIC_RELEASE);
        });
    }
}

extern CGRect SLSWindowIteratorGetBounds(CFTypeRef iterator);
static void horizontal_reconcile(void)
{
    __atomic_store_n(&hwm_reconcile_pending,false,__ATOMIC_RELEASE);
    if(hwm_ready && !hwm_suspended) { hwm_config_poll(); hwm_helper_tick(hwm_now()); hwm_attention_poll(hwm_now()); }
    if(!hwm_ready || hwm_suspended || hwm_paused || hwm_overview_active || mission_control_is_active()) return;
    double now=hwm_now();
    // This sweep asks WindowServer about every window. It waits while frames
    // are being drawn: the round trips come out of the same thread's time, and
    // WindowServer reports ordering changes as they happen in any case.
    if(now-hwm_drawn_time<.2) return;
    // Promptly for a second after anything moved, which is when a correction
    // can be needed; twice a second while the desktop is at rest.
    static double last_sweep;
    if(now-hwm_drawn_time>1 && now-last_sweep<.5) return;
    last_sweep=now;
    horizontal_event_settle(); // Everything drawn has landed before WindowServer is asked.
    hwm_adopt_missed_windows(now);
    if(hwm_borders_external) hwm_visibility_prepare(hwm_view(),now);
    /* Settled tiles whose native frame is compared below. Their bounds come
     * from one WindowServer query rather than a round trip per window, which
     * was half of this sweep's cost twice a second at rest. */
    enum { HWM_SWEEP_MAX=256 };
    uint32_t sweep[HWM_SWEEP_MAX]; int swept=0;
    // Retained Cocoa windows can close without an AX destruction notification.
    // WindowServer ordering catches that case without polling Accessibility.
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_close_ghost && !w->strip_close_pending && now-w->strip_ghost_time>1.0) {
            // The application kept the window (a save prompt, say): give it its place back.
            w->strip_close_ghost=false;
            struct view *home=window_manager_find_managed_window(&g_window_manager,w);
            if(home && home->layout==VIEW_STRIP) hwm_layout(home,true);
        }
        if(w->strip_initialized || w->strip_ordered_out) horizontal_ordered(w->id);
        struct view *view=window_manager_find_managed_window(&g_window_manager,w);
        if(w->strip_offscreen && (!view || view->layout!=VIEW_STRIP) && !w->strip_float_homed)
            hwm_visibility_set(w,false,CGRectNull);
        if(view && view->layout==VIEW_STRIP && w->strip_initialized &&
           !w->strip_ordered_out && !hwm_workflow_tab_hidden(w) && w->id!=hwm_drag_window && g_mouse_state.window!=w &&
           !hwm_view_in_motion(view,now) && !w->strip_size_pending &&
           now-w->strip_start>hwm_duration+.1 && !CGRectIsNull(w->strip_last_frame)) {
            if(swept<HWM_SWEEP_MAX) sweep[swept++]=w->id;
        }
    })
    if(!swept) return;
    CFNumberRef numbers[HWM_SWEEP_MAX];
    for(int i=0;i<swept;i++) numbers[i]=CFNumberCreate(NULL,kCFNumberSInt32Type,&sweep[i]);
    CFArrayRef ids=CFArrayCreate(NULL,(const void **)numbers,swept,&kCFTypeArrayCallBacks);
    for(int i=0;i<swept;i++) CFRelease(numbers[i]);
    CFTypeRef query=ids ? SLSWindowQueryWindows(g_connection,ids,swept) : NULL;
    CFTypeRef iterator=query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    while(iterator && SLSWindowIteratorAdvance(iterator)) {
        struct window *w=window_manager_find_window(&g_window_manager,SLSWindowIteratorGetWindowID(iterator));
        if(!w) continue;
        // AppKit can constrain an off-screen window after our final move.
        // A delayed notification may have been suppressed during animation;
        // compare settled WindowServer positions instead of trusting the cache.
        // These are the native bounds SLSGetWindowBounds reports, presentation
        // bounds notwithstanding.
        CGRect actual=SLSWindowIteratorGetBounds(iterator);
        if(!(actual.size.width>0) || !(actual.size.height>0)) continue;
        bool resized=actual.size.width>=100 && actual.size.height>=100 &&
            (fabs(actual.size.width-w->strip_width)>.5 || fabs(actual.size.height-w->strip_height)>.5);
        if(resized || fabs(actual.origin.x-w->frame.origin.x)>.5 || fabs(actual.origin.y-w->frame.origin.y)>.5) {
            // Apps do not always emit AX resize notifications. Reconcile
            // the final native size as well as its independent anchor.
            w->frame=actual; w->strip_native_resize_pending|=resized;
            w->strip_transform_dirty=true;
            hwm_wake();
        }
    }
    if(iterator) CFRelease(iterator);
    if(query) CFRelease(query);
    if(ids) CFRelease(ids);
}

/* Tana2D named the window when it asked for an activation, so the report that
 * the application came forward need not ask the application which window it
 * focused. That question is a blocking Accessibility round trip to an
 * application busy activating, on the thread drawing the settle animation.
 * The application's own focus notification still follows and corrects this
 * should it have chosen otherwise. */
static uint32_t horizontal_expected_focus(struct application *application)
{
    if(!hwm_ready || !hwm_requested_focus || hwm_now()-hwm_requested_focus_time>.5) return 0;
    struct window *window=window_manager_find_window(&g_window_manager,hwm_requested_focus);
    return window && window->application==application && !window_check_flag(window,WINDOW_MINIMIZE) ? window->id : 0;
}

static void horizontal_focus_requested(uint32_t wid)
{
    hwm_requested_focus=wid; hwm_requested_focus_time=hwm_now();
    struct window *window=window_manager_find_window(&g_window_manager,wid);
    if(window) horizontal_focused(window,window_manager_find_managed_window(&g_window_manager,window));
}

static void horizontal_focus_transition(struct window *previous,struct window *next)
{
    if(!hwm_ready || !previous || previous==next) return;
    // While paused, remember the focus for resume without waking the clock.
    if(!hwm_paused) hwm_feedback_focus(previous,next);
    else if(next) hwm_feedback_focus_id=next->id;
    if(next) {
        hwm_alpha_focus=next->id; if(hwm_inactive_alpha<1 && !hwm_paused) hwm_alpha_sync(false);
        hwm_attention_seen(next);
        if(hwm_ipc_count) hwm_ipc_send(@{@"event":@"focus",@"id":@(next->id),@"pid":@(next->application->pid),
            @"app":next->application->name ? @(next->application->name) : @"",@"strip":@(hwm_shelf_of(next)+1)});
    }
    hwm_previous_focus=previous->id; hwm_previous_focus_time=hwm_now();
    struct view *view=hwm_view();
    hwm_previous_focus_offset=view?hwm_offset(view,hwm_now()):0;
    /* Focus leaving a window can mean it closed without saying so. Not when
     * Tana2D moved focus itself (hover, navigation): the pointer has only
     * left it. That check is a WindowServer round trip on every hover
     * handoff; the housekeeping sweep still looks at every window. */
    bool requested=next && next->id==hwm_requested_focus && hwm_now()-hwm_requested_focus_time<.5;
    if(!requested) horizontal_ordered(previous->id);
}

#include "strip_config_runtime.m"
