/* Own edge drags from press through release. AppKit's native resize loop uses
 * its independent native anchor, so it must not run beside plane resizing. */
#include "plane_resize_geometry.h"
_Static_assert(HANDLE_LEFT==HWM_EDGE_LEFT && HANDLE_TOP==HWM_EDGE_TOP &&
               HANDLE_RIGHT==HWM_EDGE_RIGHT && HANDLE_BOTTOM==HWM_EDGE_BOTTOM,"resize edge flags");
typedef struct { uint32_t id; CGRect frame; } HWMPlaneResizeHit;
typedef struct { CGEventType type; CGPoint point; uint32_t id; unsigned direction; } HWMPlaneResizeInput;
static os_unfair_lock hwm_resize_hit_lock=OS_UNFAIR_LOCK_INIT;
static HWMPlaneResizeHit hwm_resize_hits[512];
static size_t hwm_resize_hit_count;
static _Atomic bool hwm_resize_captured;
static bool hwm_resize_releasing;
static CGPoint hwm_resize_pointer_origin,hwm_resize_pointer;
static CGSize hwm_resize_requested;
static double hwm_resize_scale,hwm_resize_released_at;
static void hwm_plane_resize_publish(struct view *view)
{
    HWMPlaneResizeHit hits[512]; size_t count=0;
    if(view) for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_offscreen || w->strip_close_ghost || hwm_workflow_tab_hidden(w) ||
           !window_check_flag(w,WINDOW_RESIZABLE) || CGRectIsNull(w->strip_last_frame)) continue;
        CGRect frame=w->strip_last_frame; double scale=w->strip_last_plane_scale;
        if(scale<=0) continue;
        frame.size.width=w->frame.size.width*scale; frame.size.height=w->frame.size.height*scale;
        if(count<512) hits[count++]=(HWMPlaneResizeHit){w->id,frame};
    }
    os_unfair_lock_lock(&hwm_resize_hit_lock);
    memcpy(hwm_resize_hits,hits,count*sizeof(*hits)); hwm_resize_hit_count=count;
    os_unfair_lock_unlock(&hwm_resize_hit_lock);
}
static bool hwm_plane_resize_event(CGEventType type,CGEventRef event)
{
    bool captured=atomic_load(&hwm_resize_captured);
    if(captured && type!=kCGEventLeftMouseDragged && type!=kCGEventLeftMouseUp) return false;
    if(!captured && (type!=kCGEventLeftMouseDown || hwm_paused || hwm_plane_selecting || hwm_overview_active || hwm_suspended ||
       (CGEventGetFlags(event)&(kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskCommand|kCGEventFlagMaskShift)))) return false;
    CGPoint point=CGEventGetLocation(event); uint32_t id=0; unsigned direction=0;
    if(!captured) {
        CGPoint local; int owner=0;
        SLSFindWindowAndOwner(g_connection,0,1,0,&point,&local,&id,&owner);
        if(owner==g_connection) {
            if(id!=hwm_plane_border_id) return false; // Keep interactive native panels intact.
            SLSFindWindowAndOwner(g_connection,id,-1,0,&point,&local,&id,&owner);
        }
        os_unfair_lock_lock(&hwm_resize_hit_lock);
        for(size_t i=0;i<hwm_resize_hit_count;i++) if(hwm_resize_hits[i].id==id) {
            CGRect f=hwm_resize_hits[i].frame;
            direction=hwm_plane_resize_hit((HWMPlaneRect){f.origin.x,f.origin.y,f.size.width,f.size.height},(HWMPlanePoint){point.x,point.y});
            break;
        }
        os_unfair_lock_unlock(&hwm_resize_hit_lock);
        if(!direction) return false;
    }
    HWMPlaneResizeInput *input=malloc(sizeof(*input));
    if(!input) { if(type==kCGEventLeftMouseUp) atomic_store(&hwm_resize_captured,false); return captured; }
    *input=(HWMPlaneResizeInput){type,point,id,direction};
    atomic_store(&hwm_resize_captured,type!=kCGEventLeftMouseUp);
    event_loop_post(&g_event_loop,HORIZONTAL_INPUT,input,HWM_PLANE_RESIZE);
    return true;
}
static void hwm_plane_resize_input(HWMPlaneResizeInput *input)
{
    struct view *view=hwm_view();
    if(input->type==kCGEventLeftMouseDown && view) {
        struct window *w=window_manager_find_window(&g_window_manager,input->id);
        if(w && view_find_window_node(view,w->id) && !hwm_paused && !hwm_suspended) {
            hwm_plane_camera_stop(view,hwm_now());
            hwm_plane_set_camera(view,hwm_offset(view,hwm_now()),hwm_plane_camera_y(hwm_now()),false);
            CGRect native=w->frame; SLSGetWindowBounds(g_connection,w->id,&native);
            hwm_edge_window=w->id; hwm_edge_origin=native; hwm_edge_direction=input->direction;
            hwm_edge_world_x=w->strip_world_x; hwm_edge_world_y=w->strip_world_y; hwm_edge_changed=false;
            hwm_resize_owned=true; hwm_resize_releasing=false;
            hwm_resize_pointer_origin=hwm_resize_pointer=input->point;
            hwm_resize_requested=native.size; hwm_resize_scale=hwm_plane_scale;
            w->strip_size_pending=false; hwm_hold_focus(); hwm_wake();
        }
    } else if(hwm_resize_owned) {
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
        hwm_resize_owned=false; hwm_resize_releasing=false; hwm_edge_window=0;
        // Keep consuming this press through mouse-up even if management pauses.
        return;
    }
    if(!hwm_resize_releasing) {
        SLSGetCurrentCursorLocation(g_connection,&hwm_resize_pointer);
        if(!atomic_load(&hwm_resize_captured)) { hwm_resize_releasing=true; hwm_resize_released_at=now; }
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
    if(hwm_resize_releasing && now-hwm_resize_released_at>=.15 && !hwm_resize_busy(w)) {
        hwm_edge_finish(w,view); hwm_resize_owned=false; hwm_resize_releasing=false;
    }
}
