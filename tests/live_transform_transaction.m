/* Target-Mac ABI check using only this process's disposable native window. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionSetWindowTransform(CFTypeRef,uint32_t,int,int,CGAffineTransform);
extern void SLSTransactionCommit(CFTypeRef,int);
extern CGError SLSGetWindowTransform(int,uint32_t,CGAffineTransform *);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,400,300)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [window orderFront:nil];
    int cid=SLSMainConnectionID(); uint32_t wid=(uint32_t)window.windowNumber;
    CGRect native; assert(SLSGetWindowBounds(cid,wid,&native)==kCGErrorSuccess);
    for(int i=0;i<12;i++) {
        HwmPlaneTransform projection={wid,-400+i*80,-100+i*30,.5+i*.1,.5+i*.1};
        CGAffineTransform expected=hwm_plane_transform_matrix(projection);
        CFTypeRef transaction=SLSTransactionCreate(cid); assert(transaction);
        SLSTransactionSetWindowTransform(transaction,wid,0,0,expected);
        SLSTransactionCommit(transaction,0); CFRelease(transaction);
        [NSThread sleepForTimeInterval:.02];
        CGAffineTransform actual; CGRect anchor;
        assert(SLSGetWindowTransform(cid,wid,&actual)==kCGErrorSuccess);
        assert(SLSGetWindowBounds(cid,wid,&anchor)==kCGErrorSuccess);
        assert(CGRectEqualToRect(native,anchor));
        assert(fabs(actual.a-expected.a)<.00001 && fabs(actual.d-expected.d)<.00001);
        assert(fabs(actual.tx-expected.tx)<.001 && fabs(actual.ty-expected.ty)<.001);
    }
    [window close];
    puts("live transaction projection and fixed native anchors passed");
} return 0; }
