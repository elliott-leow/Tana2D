/* Exercise the installed privileged helper against a foreign-owned bounds
 * lock. This test creates and closes only its own disposable utility window. */
#import <Cocoa/Cocoa.h>
#include <pwd.h>
#include "../src/sa_transport.h"
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
extern CGError SLSGetCatenatedWindowTransform(int,uint32_t,CGAffineTransform *);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionSetWindowLockedBounds(CFTypeRef,uint32_t,CGRect);
extern void SLSTransactionCommit(CFTypeRef,int);
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSPanel *window=[[NSPanel alloc] initWithContentRect:NSMakeRect(100,100,200,150)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    [window orderFront:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
    int cid=SLSMainConnectionID(); uint32_t wid=(uint32_t)window.windowNumber;
    CGRect native;
    if(SLSGetWindowBounds(cid,wid,&native)!=0 || native.size.width<=0) return 2;
    CFTypeRef transaction=SLSTransactionCreate(cid);
    if(!transaction) return 2;
    SLSTransactionSetWindowLockedBounds(transaction,wid,native);
    SLSTransactionCommit(transaction,1); CFRelease(transaction);
    char path[108];
    snprintf(path,sizeof(path),"/tmp/tana2d-sa_%s.socket",getpwuid(getuid())->pw_name);
    HwmPlaneTransform projection={wid,350,200,.7,.7};
    unsigned char bytes[SA_SOCKET_BUFF_LEN]; size_t length=0;
    if(!hwm_plane_transform_packet_encode(bytes+2,sizeof(bytes)-2,&projection,1,&length)) return 2;
    int16_t packetLength=(int16_t)length; memcpy(bytes,&packetLength,2);
    long long deadline=hwm_sa_monotonic_ms()+1000;
    int fd=hwm_sa_connect(path,deadline); unsigned char ack=0;
    bool accepted=fd>=0 && hwm_sa_send_all(fd,bytes,length+2,deadline) &&
        hwm_sa_receive_byte(fd,&ack,deadline) && ack==1;
    if(fd>=0) close(fd);
    CGAffineTransform actual={0},expected=hwm_plane_transform_matrix(projection);
    bool projected=false;
    for(int i=0;i<50 && !projected;i++) {
        projected=SLSGetCatenatedWindowTransform(cid,wid,&actual)==0 &&
            fabs(actual.a-expected.a)<.00001 && fabs(actual.d-expected.d)<.00001 &&
            fabs(actual.tx-expected.tx)<.001 && fabs(actual.ty-expected.ty)<.001;
        if(!projected) usleep(10000);
    }
    [window close];
    printf("helper accepted=%d final projection=%d actual=(%g,%g,%g) expected=(%g,%g,%g)\n",
        accepted,projected,actual.a,actual.tx,actual.ty,expected.a,expected.tx,expected.ty);
    return accepted && projected ? 0 : 1;
} }
