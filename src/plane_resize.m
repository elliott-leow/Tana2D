/* Own edge drags from press through release. AppKit's native resize loop uses
 * its independent native anchor, so it must not run beside plane resizing. */
#include "plane_resize_geometry.h"
_Static_assert(HANDLE_LEFT==HWM_EDGE_LEFT && HANDLE_TOP==HWM_EDGE_TOP &&
               HANDLE_RIGHT==HWM_EDGE_RIGHT && HANDLE_BOTTOM==HWM_EDGE_BOTTOM,"resize edge flags");
typedef struct { uint32_t id; CGRect frame; double camera_x,camera_y,camera_scale; bool resizable; } HWMPlaneResizeHit;
typedef struct { CGEventType type; CGPoint point; uint32_t id; unsigned direction; uint64_t generation; double camera_x,camera_y,camera_scale; } HWMPlaneResizeInput;
static CGRect hwm_feedback_plane_frame(struct view *view,struct window *w);
static os_unfair_lock hwm_resize_hit_lock=OS_UNFAIR_LOCK_INIT;
static HWMPlaneResizeHit hwm_resize_hits[512];
static size_t hwm_resize_hit_count;
static double hwm_published_scale=1;
/* Below this zoom a click on a window opens it at 100% instead of reaching
 * the app; at or above it the app receives the click. 0 disables. */
static double hwm_zoom_click_threshold=.5;

static _Atomic bool hwm_resize_captured;
static bool hwm_resize_releasing;
static CGPoint hwm_resize_pointer_origin,hwm_resize_pointer;
static CGSize hwm_resize_requested;
static double hwm_resize_scale,hwm_resize_released_at;
static uint64_t hwm_resize_pointer_generation;
enum { HWM_PLANE_RESIZE_RELEASE_GRACE_MS=150, HWM_PLANE_RESIZE_RELEASE_TIMEOUT_MS=750 };

/* Tear down the plane-owned half of an interaction in one place. `true`
 * preserves event-tap capture for cancellation paths that still need to eat
 * the physical mouse-up; a replacement press always clears it. */
static bool hwm_plane_resize_abort_interaction(struct window *window,bool keep_capture_until_up)
{
    uint32_t owned_id=hwm_edge_window;
    bool active=hwm_resize_owned || owned_id;
    struct window *owned=window;
    if(!owned && owned_id) owned=window_manager_find_window(&g_window_manager,owned_id);
    struct view *view=hwm_view();
    if(owned && owned_id==owned->id && view && view_find_window_node(view,owned->id)) {
        hwm_edge_finish(owned,view);
    } else if(owned) {
        owned->strip_native_resize_pending=true;
        owned->strip_native_resize_until=hwm_now()+.15;
        owned->strip_transform_dirty=true;
        hwm_wake();
    }
    hwm_resize_owned=false;
    hwm_resize_releasing=false;
    hwm_resize_released_at=0;
    hwm_resize_pointer_generation=0;
    hwm_edge_window=0;
    hwm_edge_neighbor=0;
    hwm_edge_direction=0;
    hwm_edge_changed=false;
    if(!keep_capture_until_up) atomic_store(&hwm_resize_captured,false);
    return active;
}
static void hwm_plane_resize_publish(struct view *view)
{
    HWMPlaneResizeHit hits[512]; size_t count=0;
    if(view) for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_offscreen || w->strip_close_ghost || hwm_workflow_tab_hidden(w) ||
           CGRectIsNull(w->strip_last_frame)) continue;
        /* Use the same current native-size reconciliation as the visible
         * feedback rectangle.  strip_last_frame supplies the presented
         * origin, while an async resize can make w->frame stale for a frame. */
        CGRect frame=hwm_feedback_plane_frame(view,w);
        if(CGRectIsNull(frame)) continue;
        if(count<512) hits[count++]=(HWMPlaneResizeHit){w->id,frame,w->strip_last_offset,
            w->strip_last_camera_y,w->strip_last_plane_scale,window_check_flag(w,WINDOW_RESIZABLE)};
    }
    os_unfair_lock_lock(&hwm_resize_hit_lock);
    memcpy(hwm_resize_hits,hits,count*sizeof(*hits)); hwm_resize_hit_count=count; hwm_published_scale=hwm_plane_scale;
    os_unfair_lock_unlock(&hwm_resize_hit_lock);
}
/* A click on a far zoomed-out window is a request to open it: the press is
 * captured, a click focuses it and zooms to it at 100%, and a drag moves it.
 * Closer than the threshold, the application receives its own clicks.
 * The event tap reads a published snapshot, never mutable window objects. */
static bool hwm_plane_center_click(CGEventRef event)
{
    if(hwm_suspended || hwm_overview_active || atomic_load(&hwm_resize_captured)) return false;
    os_unfair_lock_lock(&hwm_resize_hit_lock);
    bool low=hwm_published_scale<hwm_zoom_click_threshold;
    os_unfair_lock_unlock(&hwm_resize_hit_lock);
    if(!low) return false;
    CGPoint point=CGEventGetLocation(event),local; uint32_t id=0; int owner=0;
    SLSFindWindowAndOwner(g_connection,0,1,0,&point,&local,&id,&owner);
    if(owner==g_connection) {
        if(id!=hwm_plane_border_id) return false;
        SLSFindWindowAndOwner(g_connection,id,-1,0,&point,&local,&id,&owner);
    }
    bool managed=false;
    os_unfair_lock_lock(&hwm_resize_hit_lock);
    for(size_t i=0;i<hwm_resize_hit_count;i++) if(hwm_resize_hits[i].id==id) { managed=true; break; }
    os_unfair_lock_unlock(&hwm_resize_hit_lock);
    return managed;
}
static bool hwm_plane_resize_event(CGEventType type,CGEventRef event)
{
    bool captured=atomic_load(&hwm_resize_captured);
    /* A new physical left press terminates a predecessor whose up never
     * arrived.  Drop only tap capture here: the queued replacement down owns
     * serialized teardown of the old model session.  If it is not another
     * eligible edge press, its native stream must remain whole. */
    if(captured && type==kCGEventLeftMouseDown) {
        atomic_store(&hwm_resize_captured,false);
        captured=false;
    }
    if(captured && type!=kCGEventLeftMouseDragged && type!=kCGEventLeftMouseUp) return false;
    if(!captured && (type!=kCGEventLeftMouseDown || hwm_paused || hwm_plane_selecting || hwm_overview_active || hwm_suspended ||
       (CGEventGetFlags(event)&(kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskCommand|kCGEventFlagMaskShift)))) return false;
    CGPoint point=CGEventGetLocation(event); uint32_t id=0; unsigned direction=0;
    double camera_x=0,camera_y=0,camera_scale=0;
    if(!captured) {
        CGPoint local; int owner=0;
        SLSFindWindowAndOwner(g_connection,0,1,0,&point,&local,&id,&owner);
        if(owner==g_connection) {
            if(id!=hwm_plane_border_id) return false; // Keep interactive native panels intact.
            SLSFindWindowAndOwner(g_connection,id,-1,0,&point,&local,&id,&owner);
        }
        os_unfair_lock_lock(&hwm_resize_hit_lock);
        for(size_t i=0;i<hwm_resize_hit_count;i++) if(hwm_resize_hits[i].id==id && hwm_resize_hits[i].resizable) {
            CGRect f=hwm_resize_hits[i].frame;
            direction=hwm_plane_resize_hit((HWMPlaneRect){f.origin.x,f.origin.y,f.size.width,f.size.height},(HWMPlanePoint){point.x,point.y});
            camera_x=hwm_resize_hits[i].camera_x;
            camera_y=hwm_resize_hits[i].camera_y;
            camera_scale=hwm_resize_hits[i].camera_scale;
            break;
        }
        os_unfair_lock_unlock(&hwm_resize_hit_lock);
        /* AppKit owns the title bar, including its top band. Capturing that
         * press as resize steals the native drag's mouse-down; a zoomed-out
         * title bar is only a few points tall. Side/bottom edges and
         * zoomed-out top corners remain available. */
        if((direction&HANDLE_TOP) && (camera_scale>=.70 || direction==HANDLE_TOP)) return false;
        if(!direction) return false;
    }
    HWMPlaneResizeInput *input=malloc(sizeof(*input));
    if(!input) { if(type==kCGEventLeftMouseUp) atomic_store(&hwm_resize_captured,false); return captured; }
    *input=(HWMPlaneResizeInput){type,point,id,direction,hwm_pointer_sample_generation_for_event(type),camera_x,camera_y,camera_scale};
    atomic_store(&hwm_resize_captured,type!=kCGEventLeftMouseUp);
    event_loop_post(&g_event_loop,HORIZONTAL_INPUT,input,HWM_PLANE_RESIZE);
    return true;
}
static void hwm_plane_resize_input(HWMPlaneResizeInput *input)
{
    struct view *view=hwm_view();
    if(input->type==kCGEventLeftMouseDown && view) {
        /* The event tap can queue an old press behind a newer one.  A stale
         * press must not tear down the session that superseded it. */
        if(hwm_resize_owned && input->generation && hwm_resize_pointer_generation &&
           input->generation<hwm_resize_pointer_generation) { free(input); return; }
        /* This queued down already claimed the replacement physical press at
         * the tap. Retiring its missing-up predecessor must not clear that new
         * press's capture before its drag and up arrive. */
        if(hwm_resize_owned) hwm_plane_resize_abort_interaction(NULL,true);
        struct window *w=window_manager_find_window(&g_window_manager,input->id);
        if(w && view_find_window_node(view,w->id) && !hwm_paused && !hwm_suspended) {
            (void)hwm_ax_cancel_resize(w->id);
            bool displayed_camera=isfinite(input->camera_x) && isfinite(input->camera_y) &&
                isfinite(input->camera_scale) && input->camera_scale>0;
            if(displayed_camera) hwm_plane_transition_to(view,input->camera_x,input->camera_y,input->camera_scale,false);
            else {
                /* Direct fixture callers from older integrations have no
                 * presentation snapshot; preserve their current-camera path. */
                hwm_plane_camera_stop(view,hwm_now());
                hwm_plane_set_camera(view,hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),false);
            }
            CGRect native=w->frame; SLSGetWindowBounds(g_connection,w->id,&native);
            hwm_edge_window=w->id; hwm_edge_origin=native; hwm_edge_direction=input->direction;
            hwm_edge_world_x=w->strip_world_x; hwm_edge_world_y=w->strip_world_y; hwm_edge_changed=false;
            hwm_nav_pending=false; hwm_nav_window=0;
            hwm_resize_owned=true; hwm_resize_releasing=false;
            hwm_resize_pointer_origin=hwm_resize_pointer=input->point;
            hwm_resize_requested=native.size; hwm_resize_scale=displayed_camera?input->camera_scale:hwm_plane_scale;
            hwm_resize_pointer_generation=input->generation;
            w->strip_size_pending=false; hwm_hold_focus(); hwm_wake();
        }
    } else if(hwm_resize_owned && input->generation==hwm_resize_pointer_generation &&
              !hwm_pointer_sample_generation_is_aborted(input->generation)) {
        hwm_resize_pointer=input->point;
        if(input->type==kCGEventLeftMouseUp) { hwm_resize_releasing=true; hwm_resize_released_at=hwm_now(); }
        hwm_wake();
    }
    free(input);
}
static void hwm_plane_resize_tick(struct view *view,double now)
{
    if(!hwm_resize_owned) return;
    struct window *w=window_manager_find_window(&g_window_manager,hwm_edge_window);
    if(!w || !view || !view_find_window_node(view,w->id) || hwm_paused || hwm_suspended || hwm_overview_active) {
        if(w) { w->strip_native_resize_pending=true; w->strip_native_resize_until=now+.15; w->strip_transform_dirty=true; }
        hwm_plane_resize_abort_interaction(w,true);
        // Keep consuming this press through mouse-up even if management pauses.
        return;
    }
    if(!hwm_resize_releasing) {
        CGPoint point;
        bool active=hwm_resize_pointer_generation &&
            hwm_pointer_sample_active_point_for_generation(hwm_resize_pointer_generation,&point);
        if(active || (hwm_resize_pointer_generation &&
                      hwm_pointer_sample_point_for_generation(hwm_resize_pointer_generation,&point))) {
            /* An up is sampled by the tap before its resize input reaches this
             * queue.  Its terminal point is still this press's final intended
             * size, even though the press is no longer active. */
            hwm_resize_pointer=point;
            if(!active) {
                hwm_resize_releasing=true; hwm_resize_released_at=now;
            }
        } else if(hwm_resize_pointer_generation || !atomic_load(&hwm_resize_captured)) {
            /* A missing/aborted press never substitutes a right click or later
             * left press from the global sample. */
            hwm_resize_releasing=true; hwm_resize_released_at=now;
        }
    }
    HWMPlaneRect target=hwm_plane_resize_target((HWMPlaneRect){hwm_edge_world_x,hwm_edge_world_y,hwm_edge_origin.size.width,hwm_edge_origin.size.height},
        (HWMPlanePoint){hwm_resize_pointer.x-hwm_resize_pointer_origin.x,hwm_resize_pointer.y-hwm_resize_pointer_origin.y},hwm_resize_scale,hwm_edge_direction);
    CGSize size=CGSizeMake(round(target.width),round(target.height));
    if(!CGSizeEqualToSize(size,hwm_resize_requested)) {
        if(!hwm_edge_changed) { hwm_undo_capture(); hwm_edge_changed=true; }
        // Growing near the native display edge needs room for AppKit's size
        // constraint, but the visible projection stays under the same pointer.
        CGRect bounds=hwm_bounds(view),screen=hwm_screen(view); CGPoint anchor=w->frame.origin;
        if(anchor.x+size.width>CGRectGetMaxX(screen)) anchor.x=bounds.origin.x;
        if(anchor.y+size.height>CGRectGetMaxY(screen)) anchor.y=bounds.origin.y;
        if(!CGPointEqualToPoint(anchor,w->frame.origin)) {
            hwm_batch_begin();
            scripting_addition_move_window(w->id,anchor.x,anchor.y);
            scripting_addition_set_plane_transform(w->id,w->strip_last_frame.origin.x,w->strip_last_frame.origin.y,hwm_plane_scale);
            hwm_batch_end(); hwm_batch_settle(); w->frame.origin=anchor;
        }
        hwm_resize_requested=size;
        hwm_resize_submit(w,(CGRect){CGPointZero,size},true);
    }
    hwm_edge_update(w,view);
    if(hwm_resize_releasing && now-hwm_resize_released_at>=HWM_PLANE_RESIZE_RELEASE_GRACE_MS/1000.0 &&
       (!hwm_resize_busy(w) || now-hwm_resize_released_at>=HWM_PLANE_RESIZE_RELEASE_TIMEOUT_MS/1000.0)) {
        hwm_plane_resize_abort_interaction(w,false);
    }
}
