/* Real WindowServer validation against a hidden window owned by this process.
 * No user window, cursor, camera, focus, or display state is changed. */
#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <spawn.h>
#include <sys/wait.h>
#include <assert.h>
#include "../vendor/yabai/src/misc/input_shape.h"
extern char **environ;
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowOwner(int,uint32_t,int*);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect*);
extern CGError SLSCopySpecifiedWindowShape(int,uint32_t,int,CFTypeRef*);
extern CGError CGSNewRegionWithRect(CGRect*,CFTypeRef*);
extern bool CGRegionEqualToRegion(CFTypeRef,CFTypeRef);
extern CFTypeRef SLSTransactionCreate(int);
extern void SLSTransactionSetWindowEventShape(CFTypeRef,uint32_t,CFTypeRef);
extern void SLSTransactionCommit(CFTypeRef,int);
#include "../vendor/yabai/src/osax/input_shape_service.h"
static uint32_t target;
static int checked;
static CFTypeRef makeRegion(CGRect rect){CFTypeRef region=NULL;assert(!CGSNewRegionWithRect(&rect,&region)&&region);return region;}
static void setRegion(CFTypeRef region){CFTypeRef t=SLSTransactionCreate(SLSMainConnectionID());assert(t);SLSTransactionSetWindowEventShape(t,target,region);SLSTransactionCommit(t,1);CFRelease(t);}
static bool isRegion(CFTypeRef expected){CFTypeRef region=NULL;CGError e=SLSCopySpecifiedWindowShape(SLSMainConnectionID(),target,9,&region);bool match=expected?(e==0&&region&&CGRegionEqualToRegion(expected,region)):(e==1000&&!region);if(region)CFRelease(region);return match;}
static bool requestSet(pid_t peer){unsigned char bytes[HWM_INPUT_SHAPE_PACKET_SET_BYTES];HwmInputShapeRequest request={target,CGRectMake(-300,-400,1300,1600)};assert(hwm_input_shape_packet_encode(bytes,sizeof(bytes),&request));return do_window_input_shape(peer,bytes+1,sizeof(bytes)-1);}
static bool requestClear(pid_t peer){unsigned char bytes[HWM_INPUT_SHAPE_PACKET_CLEAR_BYTES];assert(hwm_input_shape_packet_encode_clear(bytes,sizeof(bytes)));return do_window_input_shape(peer,bytes+1,sizeof(bytes)-1);}
static void passed(const char*name){checked++;printf("OWNED-SERVICE case=%s pass=1\n",name);fflush(stdout);}
int main(){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 NSPanel *window=[[NSPanel alloc]initWithContentRect:NSMakeRect(250,300,360,260) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];target=(uint32_t)window.windowNumber;assert(target);assert(!window.visible);pthread_mutex_init(&input_shape_lock,NULL);
 assert(isRegion(NULL));assert(requestSet(getpid()));assert(requestClear(getpid()));assert(isRegion(NULL)&&!input_shape_lease.active);passed("default-restore");
 CFTypeRef custom=makeRegion(CGRectMake(30,40,220,180));setRegion(custom);assert(requestSet(getpid()));assert(requestClear(getpid()));assert(isRegion(custom));passed("custom-restore");
 assert(requestSet(getpid()));input_shape_cleanup_tick(input_shape_lease.expires_at_ms);assert(isRegion(custom)&&!input_shape_lease.active);passed("expiry-restore");
 assert(requestSet(getpid()));assert(!requestClear(getppid())&&input_shape_lease.active);assert(requestClear(getpid())&&isRegion(custom));passed("foreign-peer-rejected");
 pid_t child=0;char*args[]={"/bin/sleep","10",NULL};assert(!posix_spawn(&child,args[0],NULL,NULL,args,environ));assert(requestSet(child));kill(child,SIGTERM);waitpid(child,NULL,0);input_shape_cleanup_tick(input_shape_monotonic_ms());assert(isRegion(custom)&&!input_shape_lease.active);passed("dead-peer-restore");
 CFTypeRef newer=makeRegion(CGRectMake(15,20,300,210));assert(requestSet(getpid()));setRegion(newer);assert(!requestClear(getpid()));assert(isRegion(newer)&&!input_shape_lease.active);passed("newer-custom-preserved");
 assert(requestSet(getpid()));setRegion(NULL);assert(!requestClear(getpid()));assert(isRegion(NULL)&&!input_shape_lease.active);passed("newer-default-preserved");
 setRegion(custom);assert(requestSet(getpid()));NSRect resized=window.frame;resized.size.width+=10;[window setFrame:resized display:NO];assert(requestClear(getpid()));assert(isRegion(custom)&&!input_shape_lease.active);passed("resize-clears-override");
 setRegion(NULL);CFRelease(custom);CFRelease(newer);[window close];pthread_mutex_destroy(&input_shape_lock);printf("OWNED-SERVICE total=%d all_pass=1 hidden=1\n",checked);return 0;
}}
