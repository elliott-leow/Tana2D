#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include "../vendor/yabai/src/misc/input_shape.h"

/* Only WindowServer, allocation, and process-liveness calls are replaced.
 * Every lease decision below executes the production service implementation. */
static CFTypeRef test_shapes[3];
static int test_owners[3];
static CGRect test_bounds[3];
static int submitted, committed, snapshots, fail_create, fail_region;
static int fail_reads, next_commit_read_failures, skip_commits;
static bool peer_alive;
static bool window_valid(uint32_t wid){return wid>0&&wid<3&&test_owners[wid]>0;}
int SLSMainConnectionID(void){return 1;}
CGError SLSGetWindowOwner(int cid,uint32_t wid,int*out){(void)cid;if(!window_valid(wid))return kCGErrorFailure;*out=test_owners[wid];return 0;}
CGError SLSGetWindowBounds(int cid,uint32_t wid,CGRect*out){(void)cid;if(!window_valid(wid))return kCGErrorFailure;*out=test_bounds[wid];return 0;}
CGError SLSCopySpecifiedWindowShape(int cid,uint32_t wid,int type,CFTypeRef*out){
 (void)cid;assert(type==9);*out=NULL;snapshots++;
 if(fail_reads){fail_reads--;return kCGErrorCannotComplete;}
 if(!window_valid(wid))return kCGErrorFailure;
 if(!test_shapes[wid])return kCGErrorFailure;
 *out=CFRetain(test_shapes[wid]);return 0;
}
CGError CGSNewRegionWithRect(CGRect*rect,CFTypeRef*out){
 *out=NULL;if(fail_region){fail_region--;return kCGErrorCannotComplete;}
 *out=CFRetain((__bridge CFTypeRef)[NSValue valueWithRect:NSRectFromCGRect(*rect)]);return 0;
}
bool CGRegionEqualToRegion(CFTypeRef a,CFTypeRef b){return CFEqual(a,b);}
CFTypeRef SLSTransactionCreate(int cid){
 (void)cid;if(fail_create){fail_create--;return NULL;}
 return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
void SLSTransactionSetWindowEventShape(CFTypeRef transaction,uint32_t wid,CFTypeRef region){
 CFMutableDictionaryRef t=(CFMutableDictionaryRef)transaction;CFNumberRef number=CFNumberCreate(NULL,kCFNumberSInt32Type,&wid);
 CFDictionarySetValue(t,CFSTR("wid"),number);CFRelease(number);CFDictionarySetValue(t,CFSTR("region"),region?:kCFNull);submitted++;
}
static void backend_shape(uint32_t wid,CFTypeRef region){if(test_shapes[wid])CFRelease(test_shapes[wid]);test_shapes[wid]=region?CFRetain(region):NULL;}
void SLSTransactionCommit(CFTypeRef transaction,int synchronous){
 (void)synchronous;CFDictionaryRef t=(CFDictionaryRef)transaction;uint32_t wid=0;
 assert(CFNumberGetValue(CFDictionaryGetValue(t,CFSTR("wid")),kCFNumberSInt32Type,&wid));assert(window_valid(wid));
 if(skip_commits)skip_commits--;else{CFTypeRef r=CFDictionaryGetValue(t,CFSTR("region"));backend_shape(wid,r==kCFNull?NULL:r);committed++;}
 fail_reads=next_commit_read_failures;next_commit_read_failures=0;
}
static int test_kill(pid_t pid,int signal_number){assert(signal_number==0);if(pid==111&&peer_alive)return 0;errno=ESRCH;return -1;}
#define kill test_kill
#include "../vendor/yabai/src/osax/input_shape_service.h"
#undef kill

static void reset_backend(void){
 input_shape_discard_locked();for(int i=1;i<3;i++){backend_shape(i,NULL);test_owners[i]=i+6;test_bounds[i]=CGRectMake(0,0,100,100);}
 submitted=committed=snapshots=fail_create=fail_region=fail_reads=next_commit_read_failures=skip_commits=0;peer_alive=true;
}
static bool set_as(int peer,uint32_t wid,double x){unsigned char bytes[HWM_INPUT_SHAPE_PACKET_SET_BYTES];HwmInputShapeRequest request={wid,CGRectMake(x,2,30,40)};assert(hwm_input_shape_packet_encode(bytes,sizeof(bytes),&request));return do_window_input_shape(peer,bytes+1,sizeof(bytes)-1);}
static bool clear_as(int peer){return do_window_input_shape(peer,(unsigned char[]){HWM_INPUT_SHAPE_CLEAR},1);}
static CFTypeRef region(double x){CGRect r=CGRectMake(x,4,50,60);CFTypeRef out=NULL;assert(!CGSNewRegionWithRect(&r,&out));return out;}
static void expire(void){input_shape_cleanup_tick(input_shape_lease.expires_at_ms);}
static void test_wire_and_validation(void){
 unsigned char packet[HWM_INPUT_SHAPE_PACKET_SET_BYTES],wire[HWM_INPUT_SHAPE_PACKET_SET_BYTES+2];HwmInputShapeRequest request={1,CGRectMake(-12,5,40,30)};bool clear;HwmInputShapeRequest decoded;
 assert(hwm_input_shape_packet_encode(packet,sizeof(packet),&request));assert(hwm_input_shape_packet_decode(packet+1,sizeof(packet)-1,&clear,&decoded));assert(!clear&&decoded.wid==1&&CGRectEqualToRect(decoded.rect,request.rect));
 assert(hwm_input_shape_wire_encode(wire,sizeof(wire),packet,sizeof(packet)));int16_t length;memcpy(&length,wire,2);assert(length==sizeof(packet)&&!memcmp(wire+2,packet,sizeof(packet)));
 assert(!hwm_input_shape_wire_encode(wire,sizeof(wire)-1,packet,sizeof(packet)));
 for(size_t n=0;n<sizeof(packet)-1;n++)assert(!hwm_input_shape_packet_decode(packet+1,n,&clear,&decoded));
 double invalid[]={NAN,INFINITY,-1,0,65537};for(unsigned i=0;i<sizeof(invalid)/sizeof(*invalid);i++){request.rect.size.width=invalid[i];assert(!hwm_input_shape_packet_encode(packet,sizeof(packet),&request));}
 request.rect=CGRectMake(65535,0,2,1);assert(!hwm_input_shape_packet_encode(packet,sizeof(packet),&request));
 unsigned char clear_bytes[2];assert(hwm_input_shape_packet_encode_clear(clear_bytes,sizeof(clear_bytes)));assert(hwm_input_shape_packet_decode(clear_bytes+1,1,&clear,&decoded)&&clear);assert(!hwm_input_shape_packet_decode(clear_bytes+1,2,&clear,&decoded));
 reset_backend();unsigned char malformed[]={HWM_INPUT_SHAPE_SET};assert(!do_window_input_shape(111,malformed,sizeof(malformed)));assert(submitted==0&&snapshots==0&&!input_shape_lease.active);
 request.rect=CGRectMake(1,2,30,40);assert(hwm_input_shape_packet_encode(packet,sizeof(packet),&request));double invalid_x=NAN;memcpy(packet+2+sizeof(uint32_t),&invalid_x,sizeof(invalid_x));assert(!do_window_input_shape(111,packet+1,sizeof(packet)-1)&&submitted==0&&snapshots==0);
}
static void test_acquire_refresh_switch_and_ownership(void){
 reset_backend();CFTypeRef original=region(9);backend_shape(1,original);
 assert(set_as(111,1,1));assert(input_shape_original_region==original);CFTypeRef saved=input_shape_original_region;int old_sets=submitted;
 assert(!set_as(222,2,1)&&!clear_as(222));assert(submitted==old_sets&&input_shape_lease.wid==1);
 assert(set_as(111,1,3)&&input_shape_original_region==saved);assert(set_as(111,2,5));assert(test_shapes[1]==original&&input_shape_lease.wid==2);assert(clear_as(111)&&!test_shapes[2]&&!input_shape_lease.active);CFRelease(original);
}
static void test_expiry_death_resize_and_external_changes(void){
 reset_backend();assert(set_as(111,1,1));long long end=input_shape_lease.expires_at_ms;input_shape_cleanup_tick(end-1);assert(input_shape_lease.active);input_shape_cleanup_tick(end);assert(!input_shape_lease.active&&!test_shapes[1]);
 assert(set_as(111,1,1));peer_alive=false;input_shape_cleanup_tick(input_shape_monotonic_ms());assert(!input_shape_lease.active&&!test_shapes[1]);peer_alive=true;
 CFTypeRef original=region(7),newer=region(8);backend_shape(1,original);assert(set_as(111,1,1));test_bounds[1].size.width+=10;assert(clear_as(111)&&test_shapes[1]==original);
 assert(set_as(111,1,1));backend_shape(1,newer);assert(!clear_as(111)&&!input_shape_lease.active&&test_shapes[1]==newer);
 assert(set_as(111,1,1));backend_shape(1,NULL);assert(!clear_as(111)&&!input_shape_lease.active&&!test_shapes[1]);
 assert(set_as(111,1,1));test_owners[1]++;int before=submitted;assert(!clear_as(111)&&!input_shape_lease.active&&submitted==before);CFRelease(original);CFRelease(newer);
}
static void test_failures_and_retry(void){
 reset_backend();fail_reads=1;assert(!set_as(111,1,1)&&!input_shape_lease.active&&submitted==0);
 reset_backend();fail_create=1;assert(!set_as(111,1,1)&&!input_shape_lease.active&&!test_shapes[1]);
 reset_backend();fail_region=1;assert(!set_as(111,1,1)&&!input_shape_lease.active&&!test_shapes[1]);
 reset_backend();skip_commits=1;assert(!set_as(111,1,1)&&!input_shape_lease.active&&!test_shapes[1]);
 reset_backend();next_commit_read_failures=2;assert(!set_as(111,1,1)&&input_shape_lease.active&&test_shapes[1]);expire();assert(!input_shape_lease.active&&!test_shapes[1]);
 reset_backend();CFTypeRef original=region(9);backend_shape(1,original);assert(set_as(111,1,1));next_commit_read_failures=2;assert(!set_as(111,1,8)&&input_shape_lease.active);expire();assert(!input_shape_lease.active&&test_shapes[1]==original);
 assert(set_as(111,1,1));skip_commits=1;assert(!set_as(111,1,8)&&!input_shape_lease.active&&test_shapes[1]==original);
 assert(set_as(111,1,1));skip_commits=1;assert(!clear_as(111)&&input_shape_lease.active&&test_shapes[1]!=original);expire();assert(!input_shape_lease.active&&test_shapes[1]==original);
 assert(set_as(111,1,1));fail_reads=1;assert(!clear_as(111)&&input_shape_lease.active);expire();assert(!input_shape_lease.active&&test_shapes[1]==original);
 assert(set_as(111,1,1));next_commit_read_failures=1;assert(!clear_as(111)&&input_shape_lease.active&&test_shapes[1]==original);expire();assert(!input_shape_lease.active&&test_shapes[1]==original);CFRelease(original);
}
int main(void){@autoreleasepool{pthread_mutex_init(&input_shape_lock,NULL);test_wire_and_validation();test_acquire_refresh_switch_and_ownership();test_expiry_death_resize_and_external_changes();test_failures_and_retry();reset_backend();pthread_mutex_destroy(&input_shape_lock);}puts("input shape production-path tests passed");return 0;}
