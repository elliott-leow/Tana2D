/* Installed-helper acceptance: ordered-out/minimized peers and rejection of a
 * stale window ID must not partially apply a packet. Only own utility windows. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <pwd.h>
#include "../src/sa_transport.h"
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform *);
static bool send_projection_packet(HwmPlaneTransform *targets,uint16_t count)
{
    unsigned char bytes[SA_SOCKET_BUFF_LEN]; size_t length;
    if(!hwm_plane_transform_packet_encode(bytes+2,sizeof(bytes)-2,targets,count,&length))return false;
    int16_t n=(int16_t)length;memcpy(bytes,&n,2);
    char path[108];snprintf(path,sizeof(path),"/tmp/tana2d-sa_%s.socket",getpwuid(getuid())->pw_name);
    long long deadline=hwm_sa_monotonic_ms()+1000;
    int fd=hwm_sa_connect(path,deadline);unsigned char ack=0;
    bool ok=fd>=0 && hwm_sa_send_all(fd,bytes,length+2,deadline) &&
        hwm_sa_receive_byte(fd,&ack,deadline) && ack==1;
    if(fd>=0)close(fd);return ok;
}
static bool matches(HwmPlaneTransform target)
{
    CGAffineTransform expected=hwm_plane_transform_matrix(target),actual;
    for(int i=0;i<50;i++) {
        if(SLSGetWindowTransformAtPlacement(SLSMainConnectionID(),target.wid,0x7fffff00,NULL,&actual)==0 &&
           fabs(actual.a-expected.a)<.00001 && fabs(actual.d-expected.d)<.00001 &&
           fabs(actual.tx-expected.tx)<.002 && fabs(actual.ty-expected.ty)<.002)return true;
        usleep(10000);
    } return false;
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSPanel *windows[2];
    for(int i=0;i<2;i++) {
        windows[i]=[[NSPanel alloc]initWithContentRect:NSMakeRect(100+i*250,200,200,150)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow|NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        windows[i].releasedWhenClosed=NO;[windows[i] orderFront:nil];
    }
    [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
    HwmPlaneTransform targets[2]={{(uint32_t)windows[0].windowNumber,350,200,.7,.8},
                                {(uint32_t)windows[1].windowNumber,700,300,.8,.7}};
    [windows[1] orderOut:nil];
    assert(send_projection_packet(targets,2));assert(matches(targets[0]) && matches(targets[1]));
    [windows[1] orderFront:nil];[windows[1] miniaturize:nil];
    [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.4]];
    assert(windows[1].miniaturized);
    targets[0].x+=20;targets[1].y+=20;
    assert(send_projection_packet(targets,2));assert(matches(targets[0]) && matches(targets[1]));
    HwmPlaneTransform invalid[2]={targets[0],targets[1]};
    invalid[0].x+=100;invalid[1].wid=UINT32_MAX;
    assert(!send_projection_packet(invalid,2));assert(matches(targets[0]));
    for(int i=0;i<2;i++)[windows[i] close];
    puts("helper hidden/minimized peers and atomic stale-ID rejection passed");
}return 0;}
