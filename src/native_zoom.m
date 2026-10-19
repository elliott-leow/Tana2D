/* Align AppKit frames behind the shared camera image at 100%. Native input
 * is never covered while another application is being placed. */
@interface TanaNativeZoomJob : NSObject {
@public
    AXUIElementRef element;
    AXUIElementRef application;
    uint64_t epoch;
    pid_t pid;
    CGPoint target;
    CGPoint resizeOrigin;
    CGSize requestedSize;
    CGRect accepted;
    bool running, success;
    double completedAt;
    AXError error;
    dispatch_group_t completion;
}
@end
@implementation TanaNativeZoomJob
- (void)dealloc { if(element) CFRelease(element); if(application)CFRelease(application); if(completion)dispatch_release(completion);[super dealloc]; }
@end

static os_unfair_lock hwm_zoom_lock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *hwm_zoom_jobs;
static NSMutableSet *hwm_zoom_restore_sizes;
static _Atomic uint64_t hwm_zoom_epoch=1;
static dispatch_group_t hwm_zoom_group;
static bool hwm_zoom_size_restoring(uint32_t wid) { return [hwm_zoom_restore_sizes containsObject:@(wid)]; }

static bool hwm_zoom_native_busy(uint32_t wid)
{
    os_unfair_lock_lock(&hwm_zoom_lock);
    TanaNativeZoomJob *job=hwm_zoom_jobs[@(wid)];bool busy=job && job->running;
    os_unfair_lock_unlock(&hwm_zoom_lock);return busy;
}

static void hwm_zoom_cancel_native(void)
{
    atomic_fetch_add(&hwm_zoom_epoch,1);
    // An application can be busy. Cancellation must never wait for its AX
    // round trip on the input/render loop. A superseding placement waits only
    // for this window's runner and checks the accepted frame before reveal.
}

/* A press during camera motion fences only its own in-flight placement.
 * Never wait on another app, and never hold this lock during an AX request. */
static bool hwm_zoom_wait_native(uint32_t wid)
{
    os_unfair_lock_lock(&hwm_zoom_lock);
    TanaNativeZoomJob *job=hwm_zoom_jobs[@(wid)];
    dispatch_group_t completion=job && job->running ? job->completion : NULL;
    if(completion)dispatch_retain(completion);
    os_unfair_lock_unlock(&hwm_zoom_lock);
    if(!completion)return true;
    bool done=dispatch_group_wait(completion,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_MSEC))==0;
    dispatch_release(completion);return done;
}

/* 0 is pending, 1 is verified, -1 failed. A queued placement is never treated
 * as a completed placement. Only the worker accesses Accessibility. */
static int hwm_zoom_native_position(struct window *w,CGPoint target,CGSize requestedSize,CGPoint resizeOrigin,CGRect *accepted)
{
    uint64_t epoch=atomic_load(&hwm_zoom_epoch);
    os_unfair_lock_lock(&hwm_zoom_lock);
    if(!hwm_zoom_jobs) hwm_zoom_jobs=[NSMutableDictionary new];
    TanaNativeZoomJob *job=hwm_zoom_jobs[@(w->id)];
    if(job && job->epoch==epoch && job->pid==w->application->pid &&
       CFEqual(job->element,w->ref) && CGPointEqualToPoint(job->target,target) &&
       (CGSizeEqualToSize(requestedSize,CGSizeZero) || CGSizeEqualToSize(job->requestedSize,requestedSize)) &&
       (job->running || job->success || hwm_now()-job->completedAt<.1)) {
        int state=job->running ? 0 : job->success ? 1 : -1;
        if(state==1) *accepted=job->accepted;
        os_unfair_lock_unlock(&hwm_zoom_lock); return state;
    }
    if(job && job->running) { os_unfair_lock_unlock(&hwm_zoom_lock); return 0; }
    job=[[[TanaNativeZoomJob alloc]init]autorelease];
    job->element=CFRetain(w->ref); job->epoch=epoch; job->pid=w->application->pid;
    if(w->application->ref)job->application=CFRetain(w->application->ref);
    job->target=target; job->running=true;
    job->completion=dispatch_group_create();dispatch_group_enter(job->completion);
    job->requestedSize=requestedSize;job->resizeOrigin=resizeOrigin;
    if(requestedSize.width>0)++hwm_resize_operations;
    hwm_zoom_jobs[@(w->id)]=job;
    if(!hwm_zoom_group) hwm_zoom_group=dispatch_group_create();
    uint32_t wid=w->id;
    os_unfair_lock_unlock(&hwm_zoom_lock);
    dispatch_group_async(hwm_zoom_group,hwm_ax_queue(),^{ @autoreleasepool {
        bool ok=false; CGRect native=CGRectNull;AXError finalError=kAXErrorFailure;
        if(job->epoch==atomic_load(&hwm_zoom_epoch)) {
            AXUIElementSetMessagingTimeout(job->element,.2f);
            AXError error=kAXErrorSuccess;
            if(job->requestedSize.width>0) {
                if(job->application)AXUIElementSetMessagingTimeout(job->application,.2f);
                bool enhanced=job->application && ax_enhanced_userinterface(job->application);
                if(enhanced)AXUIElementSetAttributeValue(job->application,kAXEnhancedUserInterface,kCFBooleanFalse);
                AXValueRef origin=AXValueCreate(kAXValueTypeCGPoint,&job->resizeOrigin);
                error=origin ? AXUIElementSetAttributeValue(job->element,kAXPositionAttribute,origin) : kAXErrorFailure;
                if(origin)CFRelease(origin);
                if(error==kAXErrorSuccess && job->epoch==atomic_load(&hwm_zoom_epoch)) {
                    AXValueRef size=AXValueCreate(kAXValueTypeCGSize,&job->requestedSize);
                    error=size ? AXUIElementSetAttributeValue(job->element,kAXSizeAttribute,size) : kAXErrorFailure;
                    if(size)CFRelease(size);
                }
                /* Keep the safe anchor until the application's actual size
                 * lands. Moving it back early can constrain a deferred resize. */
                if(error==kAXErrorSuccess) {
                    bool landed=false;
                    // Polled finely: each window hands over as soon as it lands,
                    // not on the next 10 ms boundary. The total wait is unchanged.
                    for(int i=0;i<200 && job->epoch==atomic_load(&hwm_zoom_epoch);i++) {
                        if(SLSGetWindowBounds(g_connection,wid,&native)==kCGErrorSuccess &&
                           fabs(native.size.width-job->requestedSize.width)<1.1 && fabs(native.size.height-job->requestedSize.height)<1.1) {landed=true;break;}
                        usleep(2000);
                    }
                    if(!landed)error=kAXErrorCannotComplete;
                }
                if(enhanced)AXUIElementSetAttributeValue(job->application,kAXEnhancedUserInterface,kCFBooleanTrue);
            }
            if(error==kAXErrorSuccess && job->epoch==atomic_load(&hwm_zoom_epoch)) {
                AXValueRef value=AXValueCreate(kAXValueTypeCGPoint,&job->target);
                error=value ? AXUIElementSetAttributeValue(job->element,kAXPositionAttribute,value) : kAXErrorFailure;
                if(value)CFRelease(value);
            }
            CFTypeRef position=NULL; CGPoint point=CGPointZero;
            if(error==kAXErrorSuccess && AXUIElementCopyAttributeValue(job->element,kAXPositionAttribute,&position)==kAXErrorSuccess &&
               position && CFGetTypeID(position)==AXValueGetTypeID() && AXValueGetValue(position,kAXValueTypeCGPoint,&point)) {
                /* Verify AppKit against native bounds while the card may
                 * still have locked presentation bounds. Reveal separately
                 * checks the untransformed surface. */
                for(int i=0;i<60;i++) {
                    if(SLSGetWindowBounds(g_connection,wid,&native)==kCGErrorSuccess &&
                       fabs(native.origin.x-point.x)<1.1 && fabs(native.origin.y-point.y)<1.1) { ok=true; break; }
                    usleep(2000);
                }
            }
            if(position) CFRelease(position);
            finalError=error;
        }
        os_unfair_lock_lock(&hwm_zoom_lock);
        job->success=ok && job->epoch==atomic_load(&hwm_zoom_epoch); job->accepted=native; job->error=finalError; job->completedAt=hwm_now();job->running=false;
        os_unfair_lock_unlock(&hwm_zoom_lock);
        dispatch_group_leave(job->completion);
        hwm_wake();
    }});
    return 0;
}

static NSArray *hwm_zoom_native_diagnostics(void)
{
    NSMutableArray *rows=[NSMutableArray array];os_unfair_lock_lock(&hwm_zoom_lock);
    for(NSNumber *wid in hwm_zoom_jobs) {
        TanaNativeZoomJob *job=hwm_zoom_jobs[wid];
        [rows addObject:@{@"id":wid,@"running":@(job->running),@"success":@(job->success),@"error":@(job->error),
            @"requestedSize":@[@(job->requestedSize.width),@(job->requestedSize.height)],
            @"acceptedSize":@[@(job->accepted.size.width),@(job->accepted.size.height)]}];
    }
    os_unfair_lock_unlock(&hwm_zoom_lock);return rows;
}

/* Set by the last native render: what remains is only placements still in
 * flight. Each one wakes the clock when it finishes, so there is no need to
 * keep drawing frames (and reading every window's bounds) until then. */
static bool hwm_zoom_waiting_only;
static void hwm_zoom_native_adopt(struct window *w,CGRect native,double now)
{
    w->strip_native_failures=0;w->strip_native_riding=false;
    w->frame=native;w->strip_last_frame=native;
    w->strip_width=native.size.width;w->strip_height=native.size.height;
    w->strip_transform_dirty=false;w->strip_native_move_pending=false;w->strip_size_pending=false;w->strip_native_resize_pending=false;
    w->strip_from_width=w->strip_width;w->strip_from_height=w->strip_height;
    [hwm_zoom_restore_sizes removeObject:@(w->id)];w->strip_start=now-hwm_duration;
}

/* The compositor owns motion for the entire plane. At rest, place native
 * AppKit frames behind their unchanged locked bounds, then clear each lock
 * only when doing so cannot move or hide a visible pixel. */
/* Native bounds of the windows a native frame places, one query a frame
 * rather than two or three round trips per window: at 100% a drag, a pinch
 * coming to rest and every landing frame run this on each display refresh. */
#ifndef HWM_ZOOM_READ_BOUNDS
#define hwm_zoom_read_bounds hwm_plane_native_bounds
#endif
static bool hwm_zoom_bounds_lookup(const uint32_t *ids,const CGRect *bounds,const bool *found,int count,uint32_t wid,CGRect *out)
{
    for(int i=0;i<count;i++) if(ids[i]==wid) { if(!found[i]) return false; *out=bounds[i]; return true; }
    return SLSGetWindowBounds(g_connection,wid,out)==kCGErrorSuccess; // Not in the snapshot: ask.
}
static double hwm_rendered_camera_y; // With hwm_rendered_offset: the camera of the frame last drawn.
static bool hwm_zoom_render_native(struct view *view,double now)
{
    hwm_plane_selecting=false;hwm_plane_fit_active=false;
    hwm_zoom_shield_update(false);
    bool pending=false,unready=false,batched=false,waiting=false;
    CGRect bounds=hwm_bounds(view),screen=hwm_screen(view);
    double camera_x=hwm_offset(view,now),camera_y=hwm_plane_camera_y(now);
    hwm_rendered_offset=camera_x;hwm_rendered_camera_y=camera_y;hwm_visibility_prepare(view,now);
    uint32_t snap_ids[64];CGRect snap_bounds[64];bool snap_found[64];int snap_count=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n && snap_count<64;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count && snap_count<64;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(w && w->strip_initialized && w->id!=hwm_drag_window && w->id!=hwm_edge_window) snap_ids[snap_count++]=w->id;
    }
    hwm_zoom_read_bounds(snap_ids,snap_count,snap_bounds,snap_found);
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || !w->strip_initialized || w->id==hwm_drag_window || w->id==hwm_edge_window)continue;
        // Whole points, as native frames are. At 100% the camera comes to rest
        // on whole points (hwm_plane_set_camera), where hwm_render agrees.
        CGRect desired=CGRectMake(round(bounds.origin.x)+round(w->strip_world_x)-round(camera_x),
                                  round(bounds.origin.y)+round(w->strip_world_y)-round(camera_y),w->strip_width,w->strip_height);
        bool hidden=hwm_workflow_tab_hidden(w) || !CGRectIntersectsRect(desired,screen);
        if(hidden) { hwm_visibility_set(w,true,CGRectNull);continue; }
        CGRect native=CGRectNull;
        if(!hwm_zoom_bounds_lookup(snap_ids,snap_bounds,snap_found,snap_count,w->id,&native)) {pending=unready=true;continue;}
        if(![hwm_zoom_restore_sizes containsObject:@(w->id)] && !hwm_resize_busy(w) &&
           fabs(w->strip_from_width-w->strip_width)<1 && fabs(w->strip_from_height-w->strip_height)<1 &&
           (fabs(native.size.width-w->strip_width)>1 || fabs(native.size.height-w->strip_height)>1)) {
            w->strip_width=desired.size.width=native.size.width;w->strip_height=desired.size.height=native.size.height;
        }
        bool project=w->strip_plane_scaled ?
            !CGRectEqualToRect(w->strip_last_frame,desired) || w->strip_last_plane_scale!=1 :
            fabs(native.origin.x-desired.origin.x)>1.1 || fabs(native.origin.y-desired.origin.y)>1.1 ||
            fabs(native.size.width-desired.size.width)>1.1 || fabs(native.size.height-desired.size.height)>1.1;
        if(project) {
            if(!batched) {hwm_batch_begin_plane();batched=true;}
            if(!scripting_addition_set_plane_transform_xy(w->id,desired.origin.x,desired.origin.y,
                 desired.size.width/native.size.width,desired.size.height/native.size.height)) {hwm_backend_ok=false;pending=unready=true;continue;}
            w->strip_plane_scaled=true;
        }
        w->strip_last_frame=desired;w->strip_last_offset=camera_x;w->strip_last_camera_y=camera_y;w->strip_last_plane_scale=1;
        hwm_visibility_set(w,false,desired);
        n->area=(struct area){desired.origin.x,desired.origin.y,desired.size.width,desired.size.height};
    }
    if(batched)hwm_batch_end();
    /* All visible projections must be committed before any app can move its
     * native frame underneath them. Only this frame's own projections need
     * waiting for: settling whatever else the frame holds (a drag's move)
     * made every drag frame wait on Dock's reply. */
    if(batched && !hwm_batch_settle())return true;
    struct window *resets[64];CGRect reset_frames[64];int reset_count=0;
    // Landed windows whose displayed surface must be checked, all in one query.
    struct window *checks[64];CGRect check_frames[64];uint32_t check_ids[64];int check_count=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || !w->strip_initialized || w->strip_offscreen || w->id==hwm_drag_window || w->id==hwm_edge_window)continue;
        CGRect desired=w->strip_last_frame,native=CGRectNull,accepted=CGRectNull;
        // The projections above move no native frame: the snapshot still holds.
        if(!hwm_zoom_bounds_lookup(snap_ids,snap_bounds,snap_found,snap_count,w->id,&native) || hwm_resize_busy(w)) {pending=unready=true;continue;}
        bool resize=(fabs(native.size.width-desired.size.width)>1 || fabs(native.size.height-desired.size.height)>1) &&
            ([hwm_zoom_restore_sizes containsObject:@(w->id)] || fabs(w->strip_from_width-w->strip_width)>1 || fabs(w->strip_from_height-w->strip_height)>1);
        int state=hwm_zoom_native_position(w,desired.origin,resize?desired.size:CGSizeZero,bounds.origin,&accepted);
        if(state==0) {waiting=unready=true;continue;}
        if(state<0) {
            unready|=w->strip_plane_scaled;
            /* A busy application misses the AX timeout. Left alone, the window
             * stayed drawn away from its native frame (or, after riding, away
             * from where AppKit believes it is) until the camera next moved,
             * and every menu or panel it opened appeared detached. */
            if((w->strip_plane_scaled || w->strip_native_riding) && w->strip_native_failures<6) {
                int64_t delay=(int64_t)(100*NSEC_PER_MSEC)<<w->strip_native_failures; ++w->strip_native_failures;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay),dispatch_get_main_queue(),^{ hwm_wake(); });
            }
            continue;
        }
        /* Settled windows report a landed placement on every frame. Where the
         * snapshot already has the window exactly in place that answer
         * stands; anything else is measured afresh, since a move may have
         * landed since, and a clamp must never be decided from a stale read. */
        bool aligned=fabs(native.origin.x-desired.origin.x)<=1.1 && fabs(native.origin.y-desired.origin.y)<=1.1 &&
            fabs(native.size.width-desired.size.width)<=1.1 && fabs(native.size.height-desired.size.height)<=1.1;
        if(!aligned && SLSGetWindowBounds(g_connection,w->id,&native)!=kCGErrorSuccess) {pending=unready=true;continue;}
        if(w->strip_plane_scaled) {
            // AppKit can clamp an above-screen native titlebar. Keep that
            // window visible at its correct plane position until it can align.
            // A clamp is not a reason to hide it or retry the same AX move.
            if(fabs(native.origin.x-desired.origin.x)>1.1 || fabs(native.origin.y-desired.origin.y)>1.1 ||
               fabs(native.size.width-desired.size.width)>1.1 || fabs(native.size.height-desired.size.height)>1.1) {
                /* WindowServer itself places a window past that clamp. Left
                 * clamped, the native frame sat below the drawn one: menus
                 * and panels opened detached from the window, and a
                 * background blur sampled the wrong part of the desktop. */
                bool clamped=fabs(native.origin.x-desired.origin.x)<=1.1 && native.origin.y>desired.origin.y+1.1 &&
                    desired.origin.y<screen.origin.y-.5 && fabs(native.size.width-desired.size.width)<=1.1 && fabs(native.size.height-desired.size.height)<=1.1;
                if(clamped && !CGPointEqualToPoint(w->strip_server_moved,desired.origin)) {
                    hwm_batch_begin();
                    if(scripting_addition_move_window(w->id,desired.origin.x,desired.origin.y)) w->strip_server_moved=desired.origin;
                    hwm_batch_end(); pending=true;
                }
                unready=true;continue;
            }
            // Checked and cleared below with every other window that landed this frame.
            if(check_count<64) {checks[check_count]=w;check_frames[check_count]=native;check_ids[check_count++]=w->id;}
            else pending=true;
            continue;
        }
        hwm_zoom_native_adopt(w,native,now);
    }
    /* The displayed surface must already sit on the native frame, or clearing
     * its transform would move a visible pixel. One window list for all. */
    CGRect shown[64];bool listed[64];
    hwm_plane_displayed_frames(check_ids,check_count,shown,listed);
    for(int i=0;i<check_count;i++) {
        CGRect native=check_frames[i];
        if(!listed[i] || fabs(shown[i].origin.x-native.origin.x)>1.1 || fabs(shown[i].origin.y-native.origin.y)>1.1 ||
           fabs(shown[i].size.width-native.size.width)>1.1 || fabs(shown[i].size.height-native.size.height)>1.1) {pending=unready=true;continue;}
        resets[reset_count]=checks[i];reset_frames[reset_count++]=native;
    }
    if(reset_count) {
        /* One compositor transaction and one acknowledgement for every window
         * whose native frame landed, so they hand over together. */
        hwm_plane_reset_transforms(resets,reset_count);
        for(int i=0;i<reset_count;i++) {
            if(resets[i]->strip_plane_scaled) {pending=unready=true;continue;}
            hwm_zoom_native_adopt(resets[i],reset_frames[i],now);
        }
    }
    hwm_plane_selecting=false;hwm_plane_fit_active=false;
    (void)unready;
    // Camera motion and another application can never cover native input.
    hwm_zoom_shield_update(false);
    hwm_zoom_waiting_only=waiting && !pending;
    return pending || waiting;
}
