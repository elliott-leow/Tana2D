/* NSScreen's display link follows ProMotion; the legacy CoreVideo callback
 * can stay at 60 Hz on a 120 Hz screen. All callbacks only enqueue a tick. */
@interface TanaPlaneClock : NSObject
- (void)frame:(CADisplayLink *)link;
@end
@implementation TanaPlaneClock
- (void)frame:(CADisplayLink *)link
{
    hwm_ca_target_time=link.targetTimestamp;
    double interval=link.targetTimestamp-link.timestamp;
    if(interval>0) hwm_display_hz=1.0/interval;
    hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
}
@end
static CADisplayLink *hwm_ca_link;
static TanaPlaneClock *hwm_ca_target;
static void hwm_ca_start(void)
{
    if(hwm_ca_link) return;
    NSScreen *screen=NSScreen.screens.firstObject;
    if(!screen) return;
    hwm_ca_target=[TanaPlaneClock new];
    hwm_ca_link=[[screen displayLinkWithTarget:hwm_ca_target selector:@selector(frame:)] retain];
    float rate=fmin(120,fmax(1,screen.maximumFramesPerSecond));
    hwm_display_max_hz=screen.maximumFramesPerSecond;
    hwm_ca_link.preferredFrameRateRange=CAFrameRateRangeMake(rate,rate,rate);
    [hwm_ca_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    hwm_ca_clock_running=hwm_ca_link!=nil;
}
static void hwm_ca_stop(void)
{
    [hwm_ca_link invalidate]; [hwm_ca_link release]; hwm_ca_link=nil;
    [hwm_ca_target release]; hwm_ca_target=nil; hwm_ca_clock_running=false;
}
