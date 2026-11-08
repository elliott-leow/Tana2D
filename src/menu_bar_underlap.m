/* Windows the plane carries under the macOS menu bar.
 *
 * On macOS 26 and later the menu bar has no background of its own. Once an
 * ordinary application window lies under it, WindowServer fades in a copy of
 * the wallpaper behind the menu items (0.4 s later) and that window looks cut
 * off at the menu bar's lower edge. WindowServer counts only windows that
 * carry its document tag, and checks again on every screen update. So a
 * window reaching under the menu bar loses that tag while it is there, within
 * one check of arriving, and gets it back once it leaves, once Tana2D stops
 * placing it, or when Tana2D pauses or quits. A blurred panel of Tana2D's own,
 * just below the menu bar, keeps the menu items readable over the windows now
 * showing behind them.
 *
 * Nothing changes while the menu bar is hidden: Tana2D's hidden-menu-bar
 * workflow, or macOS hiding it automatically. Windows elsewhere keep their tag.
 * Missing the tag, a window behaves like a floating panel to WindowServer
 * (Spaces and Mission Control), which is why it is taken only while needed. */

enum { HWM_UNDERLAP_MAX=256 };
static double hwm_underlap_checked=-10;  // When windows were last compared with the menu bar.
static bool hwm_underlap_recovered;      // Windows left untagged by an earlier run have been adopted.
static int hwm_underlap_count;           // Windows whose tag Tana2D holds.

/* The menu bar's rectangle on the display Tana2D manages, in global display
 * coordinates; CGRectNull while the menu bar is hidden. Asked at most every
 * two seconds and never while frames are drawn, as hwm_screen is. */
static double hwm_underlap_bar_stamp=-10; // Reset when the display, Space or menu bar changes.
static CGRect hwm_underlap_bar(struct view *view,double now,bool may_refresh)
{
    static uint64_t sid; static CGRect bar={{INFINITY,INFINITY},{0,0}}; // CGRectNull
    if(may_refresh && (view->sid!=sid || now-hwm_underlap_bar_stamp>2)) {
        sid=view->sid; hwm_underlap_bar_stamp=now;
        uint32_t display=space_display_id(view->sid), height=0;
        if(!display || display_manager_menu_bar_hidden() || SLSGetDisplayMenubarHeight(display,&height)!=kCGErrorSuccess || !height) bar=CGRectNull;
        else { bar=CGDisplayBounds(display); bar.size.height=height; }
    }
    return bar;
}

/* Every window Tana2D places: tiles, the secondary windows riding them, and
 * floats. A window off the plane (ordered out, or fullscreen on a Space of
 * its own) cannot be under this menu bar. */
static bool hwm_underlap_candidate(struct window *w)
{
    if(!w || w->strip_ordered_out || w->strip_fullscreen_away) return false;
    return w->strip_initialized || w->strip_owner || (w->strip_remembered && w->is_root && window_check_flag(w,WINDOW_FLOAT));
}

/* AppKit keeps a window at this level below the menu bar; this one belongs
 * exactly there. */
@interface HwmUnderlapPanel : NSPanel
@end
@implementation HwmUnderlapPanel
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { (void)screen; return frame; }
@end
/* Main thread only. */
static NSPanel *hwm_underlap_panel;
static CALayer *hwm_underlap_backdrop;          // The progressive blur, where Core Animation offers one,
static NSVisualEffectView *hwm_underlap_effect; // else AppKit's own material.
static CGImageRef hwm_underlap_blur_ramp;       // Blur strength down the panel.
static unsigned hwm_underlap_ramp_generation;    // Bumped whenever that ramp is rebuilt.
static bool hwm_underlap_panel_wanted;
static bool hwm_underlap_menu_bar_dark(void)
{
    /* Tana2D's status item is drawn the way the menu bar draws its items,
     * but only while it is on screen: macOS can keep it out of the menu bar,
     * and then it stays light. The system setting stands in for it then. */
    NSStatusBarButton *button=hwm_menu.item.button;
    bool shown=button.window && (button.window.occlusionState&NSWindowOcclusionStateVisible);
    NSAppearance *appearance=shown ? button.effectiveAppearance : NSApp.effectiveAppearance;
    NSAppearanceName best=[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua,NSAppearanceNameVibrantLight,NSAppearanceNameVibrantDark]];
    return [best isEqualToString:NSAppearanceNameDarkAqua] || [best isEqualToString:NSAppearanceNameVibrantDark];
}

/* The backdrop has no edge of its own, like the soft scroll edge effect under
 * a toolbar: it is whole behind the menu items, then fades out over the menu
 * bar's lower part and a little below it. The blur thins out as it goes, so
 * whatever lies under it comes back into focus gradually rather than being
 * crossfaded from a blurred copy. */
enum { HWM_UNDERLAP_OVERHANG=18 };
static CGFloat hwm_underlap_strength(CGFloat y,CGFloat height,CGFloat solid) // y in points from the top
{
    CGFloat t=y<=solid ? 0 : fmin(1,(y-solid)/(height-solid));
    return 1-t*t*(3-2*t);
}
/* An alpha ramp at two pixels a point. A layer shows a CGImage upright; the
 * blur filter reads its mask the other way up. */
static CGImageRef hwm_underlap_ramp(CGFloat height,CGFloat solid,bool for_filter)
{
    size_t rows=(size_t)ceil(height*2);
    CGContextRef context=CGBitmapContextCreate(NULL,1,rows,8,0,NULL,(CGBitmapInfo)kCGImageAlphaOnly);
    if(!context) return NULL;
    for(size_t row=0;row<rows;row++) {
        CGFloat y=for_filter ? (row+.5)/2 : (rows-row-.5)/2;
        CGContextSetGrayFillColor(context,0,hwm_underlap_strength(y,height,solid));
        CGContextFillRect(context,CGRectMake(0,row,1,1));
    }
    CGImageRef image=CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}
static NSImage *hwm_underlap_mask(CGFloat height,CGFloat solid) // For AppKit's material.
{
    NSImage *mask=[NSImage imageWithSize:NSMakeSize(1,height) flipped:YES drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        for(CGFloat y=0;y<height;y+=.5) {
            [[NSColor colorWithWhite:0 alpha:hwm_underlap_strength(y,height,solid)] setFill];
            NSRectFill(NSMakeRect(0,y,1,.5));
        }
        return YES;
    }];
    mask.capInsets=NSEdgeInsetsMake(0,0,0,0); mask.resizingMode=NSImageResizingModeStretch;
    return mask;
}

@interface NSObject (HwmCoreAnimationFilter)
+ (id)filterWithType:(NSString *)type;
@end
static Class hwm_underlap_filter_class(void)
{
    Class filter=NSClassFromString(@"CAFilter");
    return filter && [filter respondsToSelector:@selector(filterWithType:)] ? filter : Nil;
}
/* One colour matrix gives the glass its look: saturation up, so colour
 * shows through, and brightness compressed, so the menu items stay readable
 * over anything. Under light items white turns mid-grey; under dark items
 * black does. */
static NSValue *hwm_underlap_tone(float saturation,float scale,float offset)
{
    const float r=.2126f,g=.7152f,b=.0722f,s=saturation,k=scale;
    float m[20]={k*((1-s)*r+s),k*(1-s)*g,k*(1-s)*b,0,offset,
                 k*(1-s)*r,k*((1-s)*g+s),k*(1-s)*b,0,offset,
                 k*(1-s)*r,k*(1-s)*g,k*((1-s)*b+s),0,offset,
                 0,0,0,1,0};
    return [NSValue valueWithBytes:m objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
}
static void hwm_underlap_panel_restyle(void)
{
    bool dark=hwm_underlap_menu_bar_dark(), solid=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    /* Showing the panel restyles it in case the menu bar changed meanwhile.
     * Unchanged, new filters would only make the render server rebuild the
     * blur, each time a window passes under the menu bar. */
    static bool styled, styled_dark, styled_solid; static unsigned styled_ramp;
    if(styled && dark==styled_dark && solid==styled_solid && styled_ramp==hwm_underlap_ramp_generation) return;
    styled=true; styled_dark=dark; styled_solid=solid; styled_ramp=hwm_underlap_ramp_generation;
    if(hwm_underlap_backdrop && hwm_underlap_blur_ramp) {
        Class filter=hwm_underlap_filter_class();
        id blur=[filter filterWithType:@"variableBlur"], tone=[filter filterWithType:@"colorMatrix"];
        [blur setValue:@22 forKey:@"inputRadius"];
        [blur setValue:(id)hwm_underlap_blur_ramp forKey:@"inputMaskImage"];
        [blur setValue:@YES forKey:@"inputNormalizeEdges"];
        // Reduce Transparency leaves little of the content showing.
        [tone setValue:dark ? hwm_underlap_tone(1.6f,solid ? .2f : .5f,0) : hwm_underlap_tone(1.5f,solid ? .2f : .55f,solid ? .78f : .45f) forKey:@"inputColorMatrix"];
        if(blur && tone) hwm_underlap_backdrop.filters=@[blur,tone];
    } else if(hwm_underlap_effect) {
        hwm_underlap_effect.appearance=[NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        hwm_underlap_effect.material=dark ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialMenu;
    }
}
@interface HwmUnderlapAppearanceObserver : NSObject
@end
@implementation HwmUnderlapAppearanceObserver
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{ (void)path; (void)object; (void)change; (void)context; hwm_underlap_panel_restyle(); }
- (void)accessibilityChanged:(NSNotification *)note { (void)note; hwm_underlap_panel_restyle(); }
@end
static void hwm_underlap_panel_create(void)
{
    hwm_underlap_panel=[[HwmUnderlapPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    // Just below the menu bar. A level above normal also leaves this panel
    // without the document tag, so it never brings the wallpaper back itself.
    hwm_underlap_panel.level=NSMainMenuWindowLevel-1;
    hwm_underlap_panel.opaque=NO; hwm_underlap_panel.backgroundColor=NSColor.clearColor; hwm_underlap_panel.hasShadow=NO;
    hwm_underlap_panel.ignoresMouseEvents=YES; hwm_underlap_panel.hidesOnDeactivate=NO; hwm_underlap_panel.releasedWhenClosed=NO;
    // On Tana2D's Space only: a fullscreen application's Space has no menu bar to back.
    hwm_underlap_panel.collectionBehavior=NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenNone;
    Class backdrop=NSClassFromString(@"CABackdropLayer");
    if(backdrop && hwm_underlap_filter_class()) {
        NSView *content=[[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
        content.wantsLayer=YES;
        hwm_underlap_panel.contentView=content;
        hwm_underlap_backdrop=[[backdrop alloc] init];
        // Blur what lies behind the window, as AppKit's own materials do,
        // sampled at half resolution: the blur hides the difference.
        [hwm_underlap_backdrop setValue:@YES forKey:@"windowServerAware"];
        [hwm_underlap_backdrop setValue:@.5 forKey:@"scale"];
        hwm_underlap_backdrop.mask=[CALayer layer];
        hwm_underlap_backdrop.mask.contentsGravity=kCAGravityResize;
        [content.layer addSublayer:hwm_underlap_backdrop];
    } else {
        hwm_underlap_effect=[[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        hwm_underlap_effect.blendingMode=NSVisualEffectBlendingModeBehindWindow;
        hwm_underlap_effect.state=NSVisualEffectStateActive; // Tana2D is rarely the active application.
        hwm_underlap_effect.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        hwm_underlap_panel.contentView=hwm_underlap_effect;
    }
    // Right after launch the status item has not taken the menu bar's
    // appearance yet; follow it as it does, and whenever it changes.
    HwmUnderlapAppearanceObserver *observer=[[HwmUnderlapAppearanceObserver alloc] init];
    [NSApp addObserver:observer forKeyPath:@"effectiveAppearance" options:0 context:NULL];
    [hwm_menu.item.button addObserver:observer forKeyPath:@"effectiveAppearance" options:0 context:NULL];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:observer selector:@selector(accessibilityChanged:)
                                                           name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ hwm_underlap_panel_restyle(); });
}
/* The backdrop fades in and out in its own layer, which the render server
 * animates. Animating the window's alpha instead ran on AppKit threads in
 * this process, a WindowServer transaction every frame, and a pan carries
 * windows under the menu bar and out again many times over. Faded out, the
 * panel stays ordered in, showing nothing, for a little while: the next window
 * to arrive fades it straight back in instead of ordering it in afresh. The
 * fade is linear, as the window's own was. Main thread only. */
enum { HWM_UNDERLAP_LINGER = 2 }; // Seconds ordered in after fading out.
static unsigned hwm_underlap_fade_generation;
static double hwm_underlap_fade_duration(void)
{
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ? 0 : .15;
}
static void hwm_underlap_fade(bool in,double duration)
{
    CALayer *layer=hwm_underlap_backdrop;
    float to=in ? 1 : 0;
    CALayer *shown=layer.presentationLayer;
    float from=shown && [layer animationForKey:@"fade"] ? shown.opacity : layer.opacity;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    layer.opacity=to;
    [layer removeAnimationForKey:@"fade"];
    if(duration>0 && from!=to) {
        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue=@(from); fade.toValue=@(to); fade.duration=duration;
        fade.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [layer addAnimation:fade forKey:@"fade"];
    }
    [CATransaction commit];
}
static void hwm_underlap_panel_show(CGRect bar)
{
    if(!hwm_underlap_panel) hwm_underlap_panel_create();
    CGFloat height=bar.size.height+HWM_UNDERLAP_OVERHANG, solid=round(bar.size.height*.74);
    CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame);
    [hwm_underlap_panel setFrame:NSMakeRect(bar.origin.x,top-CGRectGetMaxY(bar)-HWM_UNDERLAP_OVERHANG,bar.size.width,height) display:NO];
    static CGFloat ramped;
    if(ramped!=height) {
        ramped=height;
        if(hwm_underlap_backdrop) {
            CGImageRelease(hwm_underlap_blur_ramp);
            hwm_underlap_blur_ramp=hwm_underlap_ramp(height,solid,true);
            ++hwm_underlap_ramp_generation;
            CGImageRef fade=hwm_underlap_ramp(height,solid,false);
            hwm_underlap_backdrop.mask.contents=(id)fade;
            CGImageRelease(fade);
        } else hwm_underlap_effect.maskImage=hwm_underlap_mask(height,solid);
    }
    if(hwm_underlap_backdrop) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        hwm_underlap_backdrop.frame=hwm_underlap_panel.contentView.bounds;
        hwm_underlap_backdrop.mask.frame=hwm_underlap_backdrop.bounds;
        [CATransaction commit];
    }
    hwm_underlap_panel_restyle();
    ++hwm_underlap_fade_generation;
    if(hwm_underlap_backdrop) {
        if(!hwm_underlap_panel.visible) {
            hwm_underlap_fade(false,0);
            hwm_underlap_panel.alphaValue=1;
            [hwm_underlap_panel orderFrontRegardless];
        }
        hwm_underlap_fade(true,hwm_underlap_fade_duration());
        return;
    }
    if(!hwm_underlap_panel.visible) { hwm_underlap_panel.alphaValue=0; [hwm_underlap_panel orderFrontRegardless]; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration=hwm_underlap_fade_duration();
        hwm_underlap_panel.animator.alphaValue=1;
    } completionHandler:nil];
}
static void hwm_underlap_panel_hide(void)
{
    if(!hwm_underlap_panel.visible) return;
    unsigned generation=++hwm_underlap_fade_generation;
    if(hwm_underlap_backdrop) {
        double duration=hwm_underlap_fade_duration();
        hwm_underlap_fade(false,duration);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((duration+HWM_UNDERLAP_LINGER)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(generation==hwm_underlap_fade_generation && !hwm_underlap_panel_wanted) [hwm_underlap_panel orderOut:nil];
        });
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration=hwm_underlap_fade_duration();
        hwm_underlap_panel.animator.alphaValue=0;
    } completionHandler:^{ if(!hwm_underlap_panel_wanted) [hwm_underlap_panel orderOut:nil]; }];
}
/* Any thread. Only a change is handed to the main thread. */
static void hwm_underlap_blur(bool show,CGRect bar)
{
    static bool shown; static CGRect shown_bar;
    if(show==shown && (!show || CGRectEqualToRect(bar,shown_bar))) return;
    shown=show; shown_bar=bar;
    dispatch_async(dispatch_get_main_queue(),^{
        hwm_underlap_panel_wanted=show;
        if(show) hwm_underlap_panel_show(bar); else hwm_underlap_panel_hide();
    });
}

/* Queues a tag change into the frame's transaction, or a batch of its own. */
static void hwm_underlap_set(struct window *w,bool documented,bool *batched)
{
    if(!*batched) { hwm_batch_begin_plane(); *batched=true; }
    if(!scripting_addition_set_document(w->id,documented)) return;
    if(w->strip_undocumented==!documented) return;
    w->strip_undocumented=!documented;
    hwm_underlap_count+=documented ? -1 : 1;
}

/* Gives back every tag Tana2D holds and hides the backdrop: on pause, quit,
 * or once the menu bar is hidden. The batch is presented before returning. */
static void hwm_underlap_release_all(void)
{
    bool batched=false;
    if(hwm_underlap_count>0 && scripting_addition_plane_document_supported()) {
        table_for(struct window *w,g_window_manager.window, {
            if(w->strip_undocumented) hwm_underlap_set(w,true,&batched);
        })
    }
    if(batched) hwm_batch_end();
    hwm_underlap_blur(false,CGRectNull);
}

/* Compares the windows Tana2D places with the menu bar. While frames are
 * drawn (frame) it runs at most ten times a second, its tag changes joining
 * the frame's transaction; WindowServer waits 0.4 s before showing the
 * wallpaper, so a window passing under the menu bar never brings it back.
 * At rest it runs only after something moved, or to keep watching the
 * windows whose tag it holds, since an application can tag its window again. */
static void hwm_underlap_sync(struct view *view,double now,bool frame)
{
    if(!view || !hwm_backend_ok) return;
    if(!scripting_addition_plane_document_supported()) return;
    CGRect bar=hwm_underlap_bar(view,now,!frame);
    if(g_window_manager.menubar_opacity<=0 || CGRectIsNull(bar)) {
        if(hwm_underlap_count>0) hwm_underlap_release_all(); else hwm_underlap_blur(false,CGRectNull);
        return;
    }
    if(now-hwm_underlap_checked<(frame ? .1 : .25)) return;
    /* Nothing drawn since the last look: no window can have moved, and only
     * the windows whose tag Tana2D holds need watching. */
    bool watch=!frame && hwm_drawn_time<hwm_underlap_checked && hwm_underlap_recovered;
    if(watch && hwm_underlap_count==0) return;
    hwm_underlap_checked=now;
    uint32_t ids[HWM_UNDERLAP_MAX]; int count=0;
    table_for(struct window *w,g_window_manager.window, {
        if(count<HWM_UNDERLAP_MAX && (w->strip_undocumented || (!watch && hwm_underlap_candidate(w)))) ids[count++]=w->id;
    })
    bool seen[HWM_UNDERLAP_MAX]={false}, under_any=false, batched=false;
    if(count) {
        CFNumberRef numbers[HWM_UNDERLAP_MAX];
        for(int i=0;i<count;i++) numbers[i]=CFNumberCreate(NULL,kCFNumberSInt32Type,&ids[i]);
        CFArrayRef list=CFArrayCreate(NULL,(const void **)numbers,count,&kCFTypeArrayCallBacks);
        for(int i=0;i<count;i++) CFRelease(numbers[i]);
        CFTypeRef query=list ? SLSWindowQueryWindows(g_connection,list,count) : NULL;
        CFTypeRef iterator=query ? SLSWindowQueryResultCopyWindows(query) : NULL;
        while(iterator && SLSWindowIteratorAdvance(iterator)) {
            uint32_t wid=SLSWindowIteratorGetWindowID(iterator);
            struct window *w=window_manager_find_window(&g_window_manager,wid);
            if(!w) continue;
            for(int i=0;i<count;i++) if(ids[i]==wid) { seen[i]=true; break; }
            uint64_t tags=SLSWindowIteratorGetTags(iterator);
            CGRect drawn=SLSWindowIteratorGetScreenRect(iterator), overlap=CGRectIntersection(drawn,bar);
            bool under=hwm_underlap_candidate(w) && !CGRectIsNull(overlap) && overlap.size.width>.5 && overlap.size.height>.5;
            /* A tile with neither the document nor the floating tag lost its
             * document tag to a run of Tana2D that ended without giving it
             * back: hold it as this run's, to be returned as usual. */
            if(!hwm_underlap_recovered && !w->strip_undocumented && w->strip_initialized && w->is_root &&
               !(tags&3) && SLSWindowIteratorGetLevel(iterator)==0) { w->strip_undocumented=true; ++hwm_underlap_count; }
            if(under) {
                under_any=true;
                if(tags&1) hwm_underlap_set(w,false,&batched);
            } else if(w->strip_undocumented) hwm_underlap_set(w,true,&batched);
        }
        if(iterator) CFRelease(iterator);
        if(query) CFRelease(query);
        if(list) CFRelease(list);
        hwm_underlap_recovered=true;
    }
    // Not listed: most likely closed, when WindowServer ignores the change.
    for(int i=0;i<count;i++) {
        struct window *w=seen[i] ? NULL : window_manager_find_window(&g_window_manager,ids[i]);
        if(w && w->strip_undocumented) hwm_underlap_set(w,true,&batched);
    }
    if(batched) hwm_batch_end();
    if(!watch) hwm_underlap_blur(under_any,bar);
}

/* The housekeeping sweep's part: pausing gives every tag back, and at rest
 * the windows are compared again after anything moved. Frames being drawn
 * do this themselves. */
static void hwm_underlap_rest(double now)
{
    if(!hwm_ready || hwm_suspended) return;
    if(hwm_paused) { if(hwm_underlap_count>0) hwm_underlap_release_all(); else hwm_underlap_blur(false,CGRectNull); return; }
    if(hwm_overview_active || mission_control_is_active() || now-hwm_drawn_time<.2) return;
    struct view *view=hwm_view();
    if(view && hwm_view_space_visible(view,now)) hwm_underlap_sync(view,now,false);
}
