/* NSScreen's display link follows ProMotion; the legacy CoreVideo callback
 * can stay at 60 Hz on a 120 Hz screen. All callbacks only enqueue a tick.
 *
 * The link runs on its own real-time-ish thread, so AppKit work on the main
 * thread (HUD, menus, feedback layers) can never delay a frame. It pauses
 * whenever a tick ends idle, letting a ProMotion panel drop its refresh rate,
 * and hwm_wake() resumes it for the next vsync. */
@interface TanaPlaneClock : NSObject
- (void)frame:(CADisplayLink *)link;
@end
static CADisplayLink *hwm_ca_link;
static TanaPlaneClock *hwm_ca_target;
static CFRunLoopRef hwm_ca_runloop;
static NSThread *hwm_ca_thread;
static bool hwm_ca_paused;
@implementation TanaPlaneClock
- (void)frame:(CADisplayLink *)link
{
    hwm_ca_target_time=link.targetTimestamp;
    double interval=link.targetTimestamp-link.timestamp;
    if(interval>0) hwm_display_hz=1.0/interval;
    if(!__atomic_load_n(&hwm_active,__ATOMIC_SEQ_CST) && !hwm_stop_requested && !__atomic_load_n(&hwm_tick_pending,__ATOMIC_SEQ_CST)) {
        // Publish the pause before re-checking, so a concurrent hwm_wake()
        // either sees it and resumes the link or is seen here.
        __atomic_store_n(&hwm_ca_paused,true,__ATOMIC_SEQ_CST);
        if(!__atomic_load_n(&hwm_active,__ATOMIC_SEQ_CST)) { link.paused=YES; return; }
        __atomic_store_n(&hwm_ca_paused,false,__ATOMIC_SEQ_CST);
    }
    hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
}
- (void)run:(NSScreen *)screen
{
    @autoreleasepool {
        hwm_ca_runloop=CFRunLoopGetCurrent();
        hwm_ca_link=[[screen displayLinkWithTarget:self selector:@selector(frame:)] retain];
        if(!hwm_ca_link) { hwm_ca_runloop=NULL; return; }
        float rate=fmax(1,screen.maximumFramesPerSecond);
        hwm_display_max_hz=screen.maximumFramesPerSecond;
        // Ask for the panel's full rate while moving, but let a ProMotion
        // display settle lower when the system needs to.
        hwm_ca_link.preferredFrameRateRange=CAFrameRateRangeMake(fmin(rate,60),rate,rate);
        [hwm_ca_link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        hwm_ca_clock_running=hwm_ca_link!=nil;
    }
    while(!NSThread.currentThread.isCancelled) @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,1e10,false);
    }
}
@end
/* Resume a paused link. Safe from any thread; costs one atomic when running. */
static void hwm_ca_resume(void)
{
    if(!__atomic_exchange_n(&hwm_ca_paused,false,__ATOMIC_SEQ_CST)) return;
    CFRunLoopRef loop=hwm_ca_runloop;
    if(!loop) return;
    CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,^{ hwm_ca_link.paused=NO; });
    CFRunLoopWakeUp(loop);
    /* An unpaused link first fires two or three refreshes later, while the
     * animation that woke it is already running: its first frame jumped a
     * third of the way. Draw that first frame now; the link paces the rest. */
    hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
}
/* The panel the plane is drawn on, which paces every frame. */
static NSScreen *hwm_ca_screen(void)
{
    uint32_t did=hwm_space ? space_display_id(hwm_space) : 0;
    for(NSScreen *screen in NSScreen.screens)
        if(did && [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==did) return screen;
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}
static CGDirectDisplayID hwm_ca_display;
static void hwm_ca_start(void)
{
    if(hwm_ca_thread) return;
    NSScreen *screen=hwm_ca_screen();
    if(!screen) return;
    hwm_ca_display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    double scale=fmax(1,screen.backingScaleFactor);
    if(scale!=hwm_surface_scale) { hwm_surface_scale=scale; ++hwm_surface_scale_generation; }
    hwm_ca_target=[TanaPlaneClock new];
    hwm_ca_thread=[[NSThread alloc] initWithTarget:hwm_ca_target selector:@selector(run:) object:screen];
    hwm_ca_thread.name=@"Tana2D frame clock";
    hwm_ca_thread.qualityOfService=NSQualityOfServiceUserInteractive;
    [hwm_ca_thread start];
}
static void hwm_ca_stop(void)
{
    hwm_ca_clock_running=false;
    CFRunLoopRef loop=hwm_ca_runloop;
    if(loop) {
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,^{
            [hwm_ca_link invalidate]; [hwm_ca_link release]; hwm_ca_link=nil;
            [NSThread.currentThread cancel];
            CFRunLoopStop(CFRunLoopGetCurrent());
            dispatch_semaphore_signal(done);
        });
        CFRunLoopWakeUp(loop);
        dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
        dispatch_release(done);
    }
    hwm_ca_runloop=NULL;
    [hwm_ca_thread release]; hwm_ca_thread=nil;
    [hwm_ca_target release]; hwm_ca_target=nil;
}
/* Displays came or went, or the plane moved to another one: rebind the clock
 * to the plane's panel so frames follow its refresh rate and vsync phase.
 * Main thread only. */
static void hwm_ca_rebind(void)
{
    NSScreen *screen=hwm_ca_screen();
    CGDirectDisplayID did=screen ? [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : 0;
    if(hwm_ca_thread && did==hwm_ca_display && fmax(1,screen.backingScaleFactor)==hwm_surface_scale) return;
    if(hwm_ca_thread) hwm_ca_stop();
    hwm_ca_start();
    hwm_wake();
}
