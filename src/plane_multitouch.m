/* MultitouchSupport ABI used by TrackMagic and Kivy's macOS provider.
 * Touches are consumed only in memory; no finger positions are logged. */
#include <dlfcn.h>
typedef struct { float x,y; } HWM_MTPoint;
typedef struct { HWM_MTPoint position,velocity; } HWM_MTVector;
typedef struct {
    int frame; double timestamp; int identifier,state,finger,hand;
    HWM_MTVector normalized; float size; int reserved;
    float angle,major,minor; HWM_MTVector absolute; int reserved2,reserved3; float density;
} HWM_MTTouch;
typedef struct {
    uintptr_t device; HWMPlaneContact contacts[3]; int count;
    double time,aspect;
} HWMPlaneTouchFrame;
static CFArrayRef hwm_mt_devices;
static _Atomic bool hwm_mt_available;
static uint64_t hwm_mt_frames;
static int (*hwm_mt_dimensions)(void *,int *,int *);
static void (*hwm_mt_stop_device)(void *);
static void (*hwm_mt_unregister)(void *,void *);
static int hwm_mt_callback(void *device,HWM_MTTouch *touches,int count,double timestamp,int frame)
{
    (void)timestamp; (void)frame;
    if(!hwm_ready || hwm_paused || hwm_suspended || hwm_overview_active) return 0;
    HWMPlaneTouchFrame sample={.device=(uintptr_t)device,.time=hwm_now(),.aspect=.625};
    for(int i=0;i<count;i++) if(touches[i].state==3 || touches[i].state==4) {
        if(sample.count<3) sample.contacts[sample.count]=(HWMPlaneContact){touches[i].identifier,touches[i].normalized.position.x,touches[i].normalized.position.y};
        ++sample.count;
    }
    int width=0,height=0;
    if(hwm_mt_dimensions && !hwm_mt_dimensions(device,&width,&height) && width>0 && height>0)
        sample.aspect=(double)height/width;
    HWMPlaneTouchFrame *copy=malloc(sizeof(*copy));
    if(copy) { *copy=sample; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,copy,HWM_TOUCH_FRAME); }
    __atomic_fetch_add(&hwm_mt_frames,1,__ATOMIC_RELAXED);
    return 0;
}
static void hwm_mt_begin(void)
{
    void *library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_NOW|RTLD_LOCAL);
    if(!library) return;
    CFArrayRef (*list)(void)=dlsym(library,"MTDeviceCreateList");
    void (*register_callback)(void *,void *)=dlsym(library,"MTRegisterContactFrameCallback");
    void (*start)(void *,int)=dlsym(library,"MTDeviceStart");
    hwm_mt_stop_device=dlsym(library,"MTDeviceStop");
    hwm_mt_unregister=dlsym(library,"MTUnregisterContactFrameCallback");
    hwm_mt_dimensions=dlsym(library,"MTDeviceGetSensorSurfaceDimensions");
    if(!list || !register_callback || !start) return;
    hwm_mt_devices=list();
    if(!hwm_mt_devices) return;
    for(CFIndex i=0;i<CFArrayGetCount(hwm_mt_devices);i++) {
        void *device=(void *)CFArrayGetValueAtIndex(hwm_mt_devices,i);
        register_callback(device,hwm_mt_callback); start(device,0); hwm_mt_available=true;
    }
}
static void hwm_mt_end(void)
{
    if(!hwm_mt_devices) return;
    for(CFIndex i=0;i<CFArrayGetCount(hwm_mt_devices);i++) {
        void *device=(void *)CFArrayGetValueAtIndex(hwm_mt_devices,i);
        if(hwm_mt_unregister) hwm_mt_unregister(device,hwm_mt_callback);
        if(hwm_mt_stop_device) hwm_mt_stop_device(device);
    }
    CFRelease(hwm_mt_devices); hwm_mt_devices=NULL; hwm_mt_available=false;
}
