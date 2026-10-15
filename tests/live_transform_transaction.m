/* Target-Mac ABI check using only this process's disposable native window. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionClearWindowLockedBounds(CFTypeRef,uint32_t);
extern void SLSTransactionSetWindowTransform(CFTypeRef,uint32_t,int,int,CGAffineTransform);
extern void SLSTransactionCommit(CFTypeRef,int);
extern void SLSTransactionSetWindowLockedBounds(CFTypeRef,uint32_t,CGRect);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform*);
extern CGError SLSGetWindowTransform(int,uint32_t,CGAffineTransform *);
extern CGError SLSGetCatenatedWindowTransform(int,uint32_t,CGAffineTransform *);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,400,300)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [window orderFront:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
    int cid=SLSMainConnectionID(); uint32_t wid=(uint32_t)window.windowNumber;
    CGRect native; assert(SLSGetWindowBounds(cid,wid,&native)==kCGErrorSuccess);
    assert(native.size.width>0 && native.size.height>0);
    /* Reproduce the native-move failure against WindowServer itself: a
     * successful base-transform write does not release a bounds lock. */
    CFTypeRef locked=SLSTransactionCreate(cid); assert(locked);
    SLSTransactionSetWindowLockedBounds(locked,wid,native);
    CGAffineTransform displaced=CGAffineTransformMake(.7,0,0,.7,-400,-200);
    SLSTransactionSetWindowTransform(locked,wid,0,0,displaced);
    SLSTransactionCommit(locked,1); CFRelease(locked);
    CGAffineTransform base,final;
    assert(SLSGetWindowTransform(cid,wid,&base)==kCGErrorSuccess);
    assert(SLSGetCatenatedWindowTransform(cid,wid,&final)==kCGErrorSuccess);
    assert(fabs(base.a-displaced.a)<.00001);
    assert(fabs(final.a-base.a)>.1);
    for(int i=0;i<12;i++) {
        HwmPlaneTransform projection={wid,-400+i*80,-100+i*30,.5+i*.1,.5+i*.1};
        CGAffineTransform expected=hwm_plane_transform_matrix(projection);
        CFTypeRef transaction=SLSTransactionCreate(cid); assert(transaction);
        CGRect displayed; bool reset;
        assert(hwm_plane_transform_bounds(projection,native,&displayed,&reset));
        assert(!reset);
        SLSTransactionSetWindowLockedBounds(transaction,wid,displayed);
        SLSTransactionCommit(transaction,0); CFRelease(transaction);
        [NSThread sleepForTimeInterval:.02];
        CGAffineTransform actual; CGRect anchor;
        assert(SLSGetWindowTransform(cid,wid,&actual)==kCGErrorSuccess);
        assert(SLSGetWindowBounds(cid,wid,&anchor)==kCGErrorSuccess);
        assert(CGRectEqualToRect(native,anchor));
        assert(SLSGetWindowTransformAtPlacement(cid,wid,0x7fffff00,NULL,&final)==kCGErrorSuccess);
        assert(fabs(final.a-expected.a)<.00001 && fabs(final.d-expected.d)<.00001);
        assert(fabs(final.tx-expected.tx)<.001 && fabs(final.ty-expected.ty)<.001);
    }
    [window close];
    puts("live bounds-lock reproduction, final projection, and fixed native anchors passed");
} return 0; }
