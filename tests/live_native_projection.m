/* Opt-in target-Mac test: real CGEvent title-bar drags on this process's own
 * disposable utility window. --helper also tests foreign-window authority. */
#import <Cocoa/Cocoa.h>
#include <pwd.h>
#include "../src/sa_transport.h"
#include "../src/plane_presentation.h"
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform *);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionSetWindowLockedBounds(CFTypeRef,uint32_t,CGRect);
extern void SLSTransactionClearWindowLockedBounds(CFTypeRef,uint32_t);
extern void SLSTransactionSetWindowTransform(CFTypeRef,uint32_t,int,int,CGAffineTransform);
extern void SLSTransactionCommit(CFTypeRef,int);
static BOOL useHelper;
static NSPanel *panel;
static int cycle;
static BOOL project(HwmPlaneTransform target)
{
    if (useHelper) {
        unsigned char bytes[SA_SOCKET_BUFF_LEN]; size_t length;
        if (!hwm_plane_transform_packet_encode(bytes+2,sizeof(bytes)-2,&target,1,&length)) return NO;
        int16_t wireLength=(int16_t)length; memcpy(bytes,&wireLength,2);
        char path[108]; snprintf(path,sizeof(path),"/tmp/tana2d-sa_%s.socket",getpwuid(getuid())->pw_name);
        long long deadline=hwm_sa_monotonic_ms()+1000;
        int fd=hwm_sa_connect(path,deadline); unsigned char ack=0;
        BOOL ok=fd>=0 && hwm_sa_send_all(fd,bytes,length+2,deadline) &&
            hwm_sa_receive_byte(fd,&ack,deadline) && ack==1;
        if(fd>=0)close(fd);
        return ok;
    }
    CGRect native,displayed; bool reset;
    int cid=SLSMainConnectionID();
    if(SLSGetWindowBounds(cid,target.wid,&native)!=0 ||
       !hwm_plane_transform_bounds(target,native,&displayed,&reset)) return NO;
    CFTypeRef tx=SLSTransactionCreate(cid); if(!tx)return NO;
    if(reset) {
        SLSTransactionClearWindowLockedBounds(tx,target.wid);
        SLSTransactionSetWindowTransform(tx,target.wid,0,0,CGAffineTransformMakeTranslation(-native.origin.x,-native.origin.y));
    } else {
        SLSTransactionSetWindowLockedBounds(tx,target.wid,displayed);
    }
    SLSTransactionCommit(tx,1); CFRelease(tx);
    return YES;
}
static BOOL verify(HwmPlaneTransform target, CGRect anchor)
{
    if(!project(target))return NO;
    CGAffineTransform expected=hwm_plane_transform_matrix(target),actual={0};
    CGRect native,public;
    for(int i=0;i<50;i++) {
        if(SLSGetWindowTransformAtPlacement(SLSMainConnectionID(),target.wid,0x7fffff00,NULL,&actual)==0 &&
           fabs(actual.a-expected.a)<.00001 && fabs(actual.d-expected.d)<.00001 &&
           fabs(actual.tx-expected.tx)<.002 && fabs(actual.ty-expected.ty)<.002 &&
           SLSGetWindowBounds(SLSMainConnectionID(),target.wid,&native)==0 && CGRectEqualToRect(native,anchor) &&
           hwm_plane_displayed_frame(target.wid,&public) &&
           fabs(public.origin.x-target.x)<1.1 && fabs(public.origin.y-target.y)<1.1 &&
           fabs(public.size.width-anchor.size.width*target.scale_x)<1.1 &&
           fabs(public.size.height-anchor.size.height*target.scale_y)<1.1)return YES;
        usleep(10000);
    }
    fprintf(stderr,"final projection failed: got (%g,%g,%g) expected (%g,%g,%g)\n",
        actual.a,actual.tx,actual.ty,expected.a,expected.tx,expected.ty);
    return NO;
}
static void finish(BOOL success)
{
    [panel close];
    printf("native drag cycles=%d mode=%s result=%s\n",cycle,useHelper?"helper":"local",success?"PASS":"FAIL");
    fflush(stdout);exit(success?0:1);
}
static void drag(void)
{
    uint32_t wid=(uint32_t)panel.windowNumber;
    CGRect before;
    if(SLSGetWindowBounds(SLSMainConnectionID(),wid,&before)!=0)finish(NO);
    HwmPlaneTransform pre={wid,before.origin.x-30,before.origin.y-20,.8,.7};
    if(!verify(pre,before))finish(NO);
    HwmPlaneTransform reset={wid,before.origin.x,before.origin.y,1,1};
    if(!verify(reset,before))finish(NO);
    dispatch_async(dispatch_get_global_queue(0,0),^{
        for(int i=0;i<=25;i++) {
            CGPoint point=CGPointMake(before.origin.x+200+90*MIN(i,24)/24.0,before.origin.y+12);
            CGEventRef e=CGEventCreateMouseEvent(NULL,i==0?kCGEventLeftMouseDown:i==25?kCGEventLeftMouseUp:kCGEventLeftMouseDragged,point,kCGMouseButtonLeft);
            CGEventSetIntegerValueField(e,kCGMouseEventClickState,1);
            CGEventPost(kCGHIDEventTap,e);CFRelease(e);usleep(16667);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        CGRect anchor;
        if(SLSGetWindowBounds(SLSMainConnectionID(),wid,&anchor)!=0 || fabs(anchor.origin.x-before.origin.x-90)>2)finish(NO);
        for(int i=0;i<12;i++) {
            HwmPlaneTransform target={wid,anchor.origin.x-50+i*5,anchor.origin.y-30+i*3,.5+i*.05,.6+i*.03};
            if(!verify(target,anchor))finish(NO);
        }
        HwmPlaneTransform native={wid,anchor.origin.x,anchor.origin.y,1,1};
        if(!verify(native,anchor))finish(NO);
        ++cycle;
        if(cycle==2)finish(YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{drag();});
    });
}
int main(int argc,const char **argv) { @autoreleasepool {
    useHelper=argc==2 && strcmp(argv[1],"--helper")==0;
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    panel=[[NSPanel alloc]initWithContentRect:NSMakeRect(300,400,400,300)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.title=@"Tana2D native projection regression";
    [panel makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{drag();});
    [NSApp run];
} return 1; }
