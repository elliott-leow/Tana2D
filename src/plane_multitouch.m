/* MultitouchSupport ABI used by TrackMagic and Kivy's macOS provider.
 * Touches are consumed only in memory; no finger positions are logged. */
#include <dlfcn.h>
#include <pthread.h>
#include <pthread/qos.h>
typedef struct { float x,y; } HWM_MTPoint;
typedef struct { HWM_MTPoint position,velocity; } HWM_MTVector;
typedef struct {
    int frame; double timestamp; int identifier,state,finger,hand;
    HWM_MTVector normalized; float size; int reserved;
    float angle,major,minor; HWM_MTVector absolute; int reserved2,reserved3; float density;
} HWM_MTTouch;
typedef struct {
    uintptr_t device; HWMPlaneContact contacts[4]; int count;
    double time,aspect;
} HWMPlaneTouchFrame;
static CFArrayRef hwm_mt_devices;
static _Atomic bool hwm_mt_available;
static uint64_t hwm_mt_frames;
static int (*hwm_mt_dimensions)(void *,int *,int *);
static void (*hwm_mt_stop_device)(void *);
static void (*hwm_mt_unregister)(void *,void *);
/* When the trackpad made a report, on this process's clock. Reports reach this
 * callback bunched and late by varying amounts; stamping them on arrival put
 * that jitter into the pan's speed and its release glide. The device clock is
 * mapped by the smallest delay seen so far, so a report is never placed
 * later than it arrived; a jump of more than a second (sleep, a new device
 * clock) starts the mapping again. */
static double hwm_mt_report_time(double timestamp,double now)
{
    static double offset; static bool known;
    if(!isfinite(timestamp) || timestamp<=0) return now;
    double delay=now-timestamp;
    if(!known || delay<offset || delay-offset>1) { offset=delay; known=true; }
    return timestamp+offset;
}
static int hwm_mt_callback(void *device,HWM_MTTouch *touches,int count,double timestamp,int frame)
{
    (void)frame;
    /* The framework calls back on a thread of its own at the default
     * priority, where a busy CPU holds the reports up and hands them over
     * bunched: the pan then stepped and its speed read wrong. Every report
     * feeds a frame, so the thread is raised to the frame thread's class. */
    qos_class_t qos=QOS_CLASS_DEFAULT;
    if(pthread_get_qos_class_np(pthread_self(),&qos,NULL)==0 && qos!=QOS_CLASS_USER_INTERACTIVE)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    if(!hwm_ready || hwm_paused || hwm_suspended || hwm_overview_active) {
        hwm_contact_pinch=(HWMPlanePinch){0}; atomic_store(&hwm_contact_pinch_state,0);
        return 0;
    }
    double now=hwm_now();
    HWMPlaneTouchFrame sample={.device=(uintptr_t)device,.time=hwm_mt_report_time(timestamp,now),.aspect=.625};
    for(int i=0;i<count;i++) if(touches[i].state==3 || touches[i].state==4) {
        if(sample.count<4) sample.contacts[sample.count]=(HWMPlaneContact){touches[i].identifier,touches[i].normalized.position.x,touches[i].normalized.position.y};
        ++sample.count;
    }
    int width=0,height=0;
    if(sample.count>=2 && hwm_mt_dimensions && !hwm_mt_dimensions(device,&width,&height) && width>0 && height>0)
        sample.aspect=(double)height/width;
    /* Gestures here need three fingers or more. Ordinary pointing and
     * two-finger scrolling would otherwise post an event at the trackpad's
     * report rate, interleaving with frames. Keep forwarding briefly after a
     * three-finger frame (the gesture's lift tolerance is .2 s) and the
     * first empty frame, so every gesture still sees its end. */
    static double last_gesture_frame=-10; static bool owes_lift;
    if(sample.count>=3) { last_gesture_frame=sample.time; owes_lift=true; }
    /* Two fingers are the pinch, read here from the contacts (plane_pinch.h)
     * and posted only while they zoom. A pair left over from a three-finger
     * pan (one finger lifted early) is not a pinch. */
    {
        int pair=sample.count==2 && sample.time-last_gesture_frame<.25 ? 0 : sample.count;
        double delta=0;
        int result=hwm_plane_pinch_sample(&hwm_contact_pinch,sample.device,sample.contacts,pair,sample.time,sample.aspect,&delta);
        atomic_store(&hwm_contact_pinch_state,hwm_contact_pinch.engaged ? 2 : hwm_contact_pinch.tracking ? 1 : 0);
        if(sample.count==2) atomic_store(&hwm_contact_pinch_seen,now);
        if(result==HWM_PINCH_BEGIN || result==HWM_PINCH_CHANGE || result==HWM_PINCH_END) {
            HWMPlanePinchFrame *frame=malloc(sizeof(*frame));
            if(frame) {
                *frame=(HWMPlanePinchFrame){.time=sample.time,.delta=delta,.phase=result==HWM_PINCH_BEGIN ? 1 : result==HWM_PINCH_CHANGE ? 2 : 4};
                event_loop_post(&g_event_loop,HORIZONTAL_INPUT,frame,HWM_PINCH_FRAME);
            }
        }
    }
    if(sample.count<3 && sample.time-last_gesture_frame>=.25 && !(sample.count==0 && owes_lift)) return 0;
    if(sample.count==0) owes_lift=false;
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
