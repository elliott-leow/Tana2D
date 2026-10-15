/* Diagnostic, not a passing regression: reports the known difference between
 * transformed NSEvent coordinates and native NSWindow cursor polling.
 * Operates only on its own panel; posts hover events and restores the cursor.
 * Temporarily disable WM focus-follows-mouse for reproducible event delivery. */
#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect*);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform*);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionSetWindowLockedBounds(CFTypeRef,uint32_t,CGRect);
extern void SLSTransactionClearWindowLockedBounds(CFTypeRef,uint32_t);
extern void SLSTransactionSetWindowTransform(CFTypeRef,uint32_t,int,int,CGAffineTransform);
extern void SLSTransactionCommit(CFTypeRef,int);
static NSPanel *panel;
static CGPoint cursor,last;static int events,stage;static CGRect native;
@interface InputProbeView : NSView @end
@implementation InputProbeView
- (void)mouseMoved:(NSEvent *)event { (void)event; }
@end
static void run(void) {
    if(stage==5) {CGWarpMouseCursorPosition(cursor);[panel close];exit(0);}
    int c=SLSMainConnectionID();uint32_t wid=(uint32_t)panel.windowNumber;
    double scales[]={1,.75,.5,.75,.5};double xs[]={native.origin.x,200,400,200,400};double ys[]={native.origin.y,150,250,150,250};
    HwmPlaneTransform target={wid,xs[stage],ys[stage],scales[stage],scales[stage]};
    CFTypeRef tx=SLSTransactionCreate(c);
    if(stage)SLSTransactionSetWindowLockedBounds(tx,wid,CGRectMake(target.x,target.y,native.size.width*target.scale_x,native.size.height*target.scale_y));
    if(stage>=3)SLSTransactionSetWindowTransform(tx,wid,0,0,hwm_plane_transform_matrix(target));
    SLSTransactionCommit(tx,1);CFRelease(tx);
    CGPoint point=CGPointMake(target.x+100*target.scale_x,target.y+(native.size.height-100)*target.scale_y);int before=events;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);CGEventSetFlags(event,0);CGEventPost(kCGHIDEventTap,event);CFRelease(event);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            NSPoint direct=panel.mouseLocationOutsideOfEventStream,converted=[panel convertPointFromScreen:NSEvent.mouseLocation];
            CGAffineTransform final;SLSGetWindowTransformAtPlacement(c,wid,0x7fffff00,NULL,&final);
            printf("stage%d baseUpdate%d scale%.2f events%d local %.1f %.1f outside %.1f %.1f convert %.1f %.1f final %.3f %.1f %.1f expected100,100\n",stage,stage>=3,target.scale_x,events-before,last.x,last.y,direct.x,direct.y,converted.x,converted.y,final.a,final.tx,final.ty);fflush(stdout);++stage;run();
        });
    });
}
int main(void){@autoreleasepool{
    CGEventRef event=CGEventCreate(NULL);cursor=CGEventGetLocation(event);CFRelease(event);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    panel=[[NSPanel alloc]initWithContentRect:NSMakeRect(300,400,400,300) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.title=@"Tana2D input projection diagnostic";panel.acceptsMouseMovedEvents=YES;
    panel.hidesOnDeactivate=NO;panel.level=NSFloatingWindowLevel;
    InputProbeView *view=[[InputProbeView alloc] initWithFrame:NSMakeRect(0,0,400,300)];panel.contentView=view;
    NSTrackingArea *tracking=[[NSTrackingArea alloc] initWithRect:view.bounds options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:view userInfo:nil];
    [view addTrackingArea:tracking];[tracking release];[view release];
    [panel makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent*(NSEvent *e){if(e.windowNumber==panel.windowNumber){last=e.locationInWindow;++events;}return e;}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{SLSGetWindowBounds(SLSMainConnectionID(),(uint32_t)panel.windowNumber,&native);run();});
    [NSApp run];
}}
