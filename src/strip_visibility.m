/* AppKit can pull a completely off-screen window back to a display edge after
 * a WindowServer move. Keep it transparent until it has been positioned for
 * re-entry. Do not order it out: that changes application/window lifecycle. */
#include <pthread.h>
#include <stdatomic.h>
#ifndef HWM_VISIBILITY_SCHEDULE
#define HWM_VISIBILITY_SCHEDULE(work) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),work)
#define HWM_VISIBILITY_OWNS_SCHEDULE 1
#endif
static NSMutableDictionary *hwm_visibility_companions;
static NSMutableDictionary *hwm_external_border_surfaces;
static double hwm_visibility_scan=-100, hwm_visibility_frame=-100;
/* Discovery snapshots are immutable. The worker publishes one under this
 * short lock; the render thread retains it, then validates every WindowServer
 * identity before touching a surface. */
static pthread_mutex_t hwm_visibility_snapshot_lock=PTHREAD_MUTEX_INITIALIZER;
static NSArray *hwm_visibility_border_snapshot;
static _Atomic bool hwm_visibility_discovery_pending;
static _Atomic bool hwm_visibility_discovery_ready;

static bool hwm_visibility_owned(uint32_t wid,pid_t pid)
{
    int owner=0; pid_t actual=0;
    return SLSGetWindowOwner(g_connection,wid,&owner)==kCGErrorSuccess &&
           SLSConnectionGetPID(owner,&actual)==kCGErrorSuccess && actual==pid;
}

static void hwm_visibility_record(struct window *w,uint32_t wid,pid_t pid,CGRect frame,CGRect parent)
{
    if(wid==w->id || hwm_visibility_companions[@(wid)]) return;
    float alpha=1;
    if(SLSGetWindowAlpha(g_connection,wid,&alpha)!=kCGErrorSuccess || alpha<=0) return;
    hwm_visibility_companions[@(wid)]=[NSMutableDictionary dictionaryWithDictionary:
        @{@"id":@(wid),@"pid":@(pid),@"parent":@(w->id),@"parentPid":@(w->application->pid),
          @"alpha":@(alpha),@"hidden":@NO,@"dx":@(frame.origin.x-parent.origin.x),@"dy":@(frame.origin.y-parent.origin.y)}];
}

static NSArray *hwm_visibility_discover_borders(void)
{
    CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
    NSMutableArray *snapshot=[NSMutableArray array];
    for(NSDictionary *entry in (NSArray *)list) {
        if(![entry[(id)kCGWindowOwnerName] isEqualToString:@"borders"]) continue;
        NSNumber *wid=entry[(id)kCGWindowNumber],*pid=entry[(id)kCGWindowOwnerPID];
        if(wid && pid) [snapshot addObject:@{@"id":wid,@"pid":pid}];
    }
    if(list) CFRelease(list);
    return [snapshot copy];
}

static void hwm_visibility_publish_borders(NSArray *snapshot)
{
    pthread_mutex_lock(&hwm_visibility_snapshot_lock);
    NSArray *old=hwm_visibility_border_snapshot;
    hwm_visibility_border_snapshot=snapshot;
    pthread_mutex_unlock(&hwm_visibility_snapshot_lock);
    [old release];
}

static NSArray *hwm_visibility_copy_borders(void)
{
    pthread_mutex_lock(&hwm_visibility_snapshot_lock);
    NSArray *snapshot=[hwm_visibility_border_snapshot retain];
    pthread_mutex_unlock(&hwm_visibility_snapshot_lock);
    return snapshot;
}

static void hwm_visibility_discover_async(void)
{
    bool expected=false;
    if(!atomic_compare_exchange_strong(&hwm_visibility_discovery_pending,&expected,true)) return;
    HWM_VISIBILITY_SCHEDULE(^{ @autoreleasepool {
        NSArray *snapshot=hwm_visibility_discover_borders();
        hwm_visibility_publish_borders(snapshot);
        atomic_store(&hwm_visibility_discovery_ready,true);
        atomic_store(&hwm_visibility_discovery_pending,false);
        hwm_wake();
    }});
}

/* Border windows belong to another process and are not returned by
 * SLSCopyAssociatedWindows. Match their concentric padded frames before the
 * first movement, then retain that identity while their positions lag behind.
 * The periodic refresh picks up new borders without scanning each frame. */
static void hwm_visibility_prepare(struct view *view,double now)
{
    /* Discovery enumerates the whole desktop and can block on WindowServer.
     * Keep it outside the pointer-owned path; cached companions still update
     * normally, and the first frame after release refreshes discovery. */
    if(hwm_drag_window) return;
    bool fresh=now-hwm_visibility_frame>.1;
    hwm_visibility_frame=now;
    bool due=fresh || now-hwm_visibility_scan>=.5;
    bool published=atomic_exchange(&hwm_visibility_discovery_ready,false);
    if(!due && !published) return;
    if(due) hwm_visibility_scan=now;
    if(!hwm_visibility_companions) hwm_visibility_companions=[NSMutableDictionary new];
    for(NSNumber *key in [[hwm_visibility_companions.allKeys copy] autorelease]) {
        NSDictionary *entry=hwm_visibility_companions[key];
        if(!hwm_visibility_owned(key.unsignedIntValue,[entry[@"pid"] intValue]) ||
           !hwm_visibility_owned([entry[@"parent"] unsignedIntValue],[entry[@"parentPid"] intValue]))
            [hwm_visibility_companions removeObjectForKey:key];
    }
    if(!hwm_borders_external) return;
    if(due) hwm_visibility_discover_async();
    NSArray *snapshot=hwm_visibility_copy_borders();
    if(!snapshot) return;
    if(!hwm_external_border_surfaces) hwm_external_border_surfaces=[NSMutableDictionary new];
    for(NSDictionary *entry in snapshot) {
        NSNumber *key=entry[@"id"]; uint32_t wid=key.unsignedIntValue;
        pid_t pid=[entry[@"pid"] intValue];
        if(!hwm_visibility_owned(wid,pid)) continue;
        float alpha=0; if(SLSGetWindowAlpha(g_connection,wid,&alpha)!=kCGErrorSuccess) continue;
        NSDictionary *saved=hwm_external_border_surfaces[key];
        if(!saved || [saved[@"pid"] intValue]!=pid)
            hwm_external_border_surfaces[key]=@{@"pid":@(pid),@"alpha":@(alpha)};
        if(alpha>0) scripting_addition_set_opacity(wid,0,0);
    }
    [snapshot release];
    (void)view;

}

static void hwm_visibility_attached(struct window *w,CGRect parent)
{
    if(!hwm_visibility_companions) hwm_visibility_companions=[NSMutableDictionary new];
    CFArrayRef list=SLSCopyAssociatedWindows(g_connection,w->id);
    for(NSNumber *wid in (NSArray *)list) {
        if(wid.unsignedIntValue==w->id || !hwm_visibility_owned(wid.unsignedIntValue,w->application->pid)) continue;
        struct window *other=window_manager_find_window(&g_window_manager,wid.unsignedIntValue);
        if(other && window_manager_find_managed_window(&g_window_manager,other)) continue;
        CGRect frame=CGRectNull;
        if(SLSGetWindowBounds(g_connection,wid.unsignedIntValue,&frame)==kCGErrorSuccess)
            hwm_visibility_record(w,wid.unsignedIntValue,w->application->pid,frame,parent);
    }
    if(list) CFRelease(list);
}

static void hwm_visibility_set(struct window *w,bool hidden,CGRect frame)
{
    if(hidden && !w->strip_offscreen) {
        CGRect actual=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&actual)==kCGErrorSuccess) hwm_visibility_attached(w,actual);
    }
    if(w->strip_offscreen!=hidden) {
        bool old=w->strip_offscreen; w->strip_offscreen=hidden;
        hwm_batch_require_updates();
        if(!scripting_addition_set_opacity(w->id,hidden || w->strip_pop==1 || w->strip_close_pending ? 0 : hwm_window_alpha(w),0)) {
            w->strip_offscreen=old; ++hwm_move_failures; hwm_backend_ok=false;
            // The primary did not change state, so neither may a companion.
            // Otherwise a failed hide leaves a visible app without its border,
            // while a failed reveal can expose a border without its app.
            return;
        }
    }
    for(NSMutableDictionary *entry in hwm_visibility_companions.allValues) {
        if([entry[@"parent"] unsignedIntValue]!=w->id || [entry[@"parentPid"] intValue]!=w->application->pid) continue;
        bool hide=hidden || hwm_overview_active || hwm_plane_fit_active;
        if([entry[@"hidden"] boolValue]==hide) continue;
        uint32_t wid=[entry[@"id"] unsignedIntValue];
        if(!hwm_visibility_owned(wid,[entry[@"pid"] intValue])) continue;
        // A border may still be at the application's constrained edge. Place
        // it beside the window before restoring its alpha in the same batch.
        if(!hide && !CGRectIsNull(frame)) {
            hwm_batch_require_updates();
            if(!scripting_addition_move_window(wid,frame.origin.x+[entry[@"dx"] doubleValue],frame.origin.y+[entry[@"dy"] doubleValue])) {
                ++hwm_move_failures; hwm_backend_ok=false; continue;
            }
        }
        hwm_batch_require_updates();
        if(scripting_addition_set_opacity(wid,hide ? 0 : [entry[@"alpha"] floatValue],0)) entry[@"hidden"]=@(hide);
        else { ++hwm_move_failures; hwm_backend_ok=false; }
    }
}

static void hwm_visibility_restore_all(void)
{
    for(NSNumber *wid in hwm_external_border_surfaces) {
        NSDictionary *saved=hwm_external_border_surfaces[wid];
        if(hwm_visibility_owned(wid.unsignedIntValue,[saved[@"pid"] intValue]))
            scripting_addition_set_opacity(wid.unsignedIntValue,[saved[@"alpha"] floatValue],0);
    }
    [hwm_external_border_surfaces removeAllObjects];
    table_for(struct window *w,g_window_manager.window, {
        hwm_visibility_set(w,false,CGRectNull);
    })
}
#ifdef HWM_VISIBILITY_OWNS_SCHEDULE
#undef HWM_VISIBILITY_SCHEDULE
#undef HWM_VISIBILITY_OWNS_SCHEDULE
#endif
