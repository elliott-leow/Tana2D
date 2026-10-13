/* AppKit can pull a completely off-screen window back to a display edge after
 * a WindowServer move. Keep it transparent until it has been positioned for
 * re-entry. Do not order it out: that changes application/window lifecycle. */
static NSMutableDictionary *hwm_visibility_companions;
static NSMutableDictionary *hwm_external_border_surfaces;
static double hwm_visibility_scan=-100, hwm_visibility_frame=-100;

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

/* Border windows belong to another process and are not returned by
 * SLSCopyAssociatedWindows. Match their concentric padded frames before the
 * first movement, then retain that identity while their positions lag behind.
 * The periodic refresh picks up new borders without scanning each frame. */
static void hwm_visibility_prepare(struct view *view,double now)
{
    bool fresh=now-hwm_visibility_frame>.1;
    hwm_visibility_frame=now;
    if(!fresh && now-hwm_visibility_scan<.5) return;
    hwm_visibility_scan=now;
    if(!hwm_visibility_companions) hwm_visibility_companions=[NSMutableDictionary new];
    for(NSNumber *key in [[hwm_visibility_companions.allKeys copy] autorelease]) {
        NSDictionary *entry=hwm_visibility_companions[key];
        if(!hwm_visibility_owned(key.unsignedIntValue,[entry[@"pid"] intValue]) ||
           !hwm_visibility_owned([entry[@"parent"] unsignedIntValue],[entry[@"parentPid"] intValue]))
            [hwm_visibility_companions removeObjectForKey:key];
    }
    if(!hwm_borders_external) return;
    if(!hwm_external_border_surfaces) hwm_external_border_surfaces=[NSMutableDictionary new];
    CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
    for(NSDictionary *entry in (NSArray *)list) {
        if(![entry[(id)kCGWindowOwnerName] isEqualToString:@"borders"]) continue;
        NSNumber *key=entry[(id)kCGWindowNumber]; uint32_t wid=key.unsignedIntValue;
        pid_t pid=[entry[(id)kCGWindowOwnerPID] intValue];
        if(!hwm_visibility_owned(wid,pid)) continue;
        float alpha=0; if(SLSGetWindowAlpha(g_connection,wid,&alpha)!=kCGErrorSuccess) continue;
        NSDictionary *saved=hwm_external_border_surfaces[key];
        if(!saved || [saved[@"pid"] intValue]!=pid)
            hwm_external_border_surfaces[key]=@{@"pid":@(pid),@"alpha":@(alpha)};
        if(alpha>0) scripting_addition_set_opacity(wid,0,0);
    }
    if(list) CFRelease(list);
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
        if(!scripting_addition_set_opacity(w->id,hidden || w->strip_pop==1 || w->strip_close_pending ? 0 : hwm_window_alpha(w),0)) {
            w->strip_offscreen=old; ++hwm_move_failures; hwm_backend_ok=false;
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
        if(!hide && !CGRectIsNull(frame) &&
           !scripting_addition_move_window(wid,frame.origin.x+[entry[@"dx"] doubleValue],frame.origin.y+[entry[@"dy"] doubleValue])) {
            ++hwm_move_failures; hwm_backend_ok=false; continue;
        }
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
