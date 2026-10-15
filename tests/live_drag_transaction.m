/* Compare atomic helper movement with and without global update suppression.
 * Uses only this process's unordered disposable window; never synthesizes input. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <pwd.h>
#include "../src/sa_transport.h"
#include "../vendor/yabai/src/misc/plane_transform.h"
extern int SLSMainConnectionID(void);
extern CGError SLSDisableUpdate(int);
extern CGError SLSReenableUpdate(int);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform *);
static double now(void) { return CFAbsoluteTimeGetCurrent()*1000; }
static int compare(const void *a,const void *b) { double x=*(double *)a,y=*(double *)b; return (x>y)-(x<y); }
int main(void) { @autoreleasepool {
 [NSApplication sharedApplication]; NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,100,100) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 int cid=SLSMainConnectionID(); uint32_t wid=(uint32_t)w.windowNumber;
 char path[108];snprintf(path,sizeof(path),"/tmp/tana2d-sa_%s.socket",getpwuid(getuid())->pw_name);
 for(int run=0;run<4;run++) { int mode=run%2;
  double durations[180],total=0;
  for(int i=0;i<180;i++) {
   HwmPlaneTransform t={wid,-2000+i,-2000,1,1};unsigned char bytes[SA_SOCKET_BUFF_LEN];size_t len;
   assert(hwm_plane_transform_packet_encode(bytes+2,sizeof(bytes)-2,&t,1,&len));int16_t n=len;memcpy(bytes,&n,2);
   double start=now();if(mode==0)SLSDisableUpdate(cid);
   long long deadline=hwm_sa_monotonic_ms()+100;int fd=hwm_sa_connect(path,deadline);assert(fd>=0);
   unsigned char ack=0;bool ok=hwm_sa_send_all(fd,bytes,len+2,deadline)&&hwm_sa_receive_byte(fd,&ack,deadline)&&ack==1;close(fd);
   if(mode==0)SLSReenableUpdate(cid);
   assert(ok);durations[i]=now()-start;total+=durations[i];
   CGAffineTransform a;assert(SLSGetWindowTransformAtPlacement(cid,wid,0x7fffff00,NULL,&a)==0 && fabs(a.tx-t.x*-1)<.001);
   usleep(8000);
  }
  qsort(durations,180,sizeof(double),compare);
  printf("%s mean=%.3f median=%.3f p95=%.3f max=%.3f ms\n",mode==0?"freeze+transaction":"transaction only",total/180,durations[90],durations[171],durations[179]);
 }
 [w close];
}return 0;}
