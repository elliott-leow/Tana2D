/* MultitouchSupport ABI used by TrackMagic and Kivy's macOS provider.
 * Touches are consumed only in memory; no finger positions are logged. The
 * pinch recogniser's decisions are logged with the distances the fingers
 * moved (`log show --predicate 'process == "tana2d" AND eventMessage
 * CONTAINS "pinch"'`), never where they were. */
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
    double time,aspect,arrival_time;
    uint64_t generation; bool allowed;
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
static double hwm_mt_report_time(uintptr_t device,double timestamp,double now)
{
    typedef struct { uintptr_t device; double offset,last; bool known; } Clock;
    static Clock clocks[8];
    Clock *clock=NULL;
    for(size_t i=0;i<8;i++) if(clocks[i].known && clocks[i].device==device) { clock=&clocks[i]; break; }
    if(!clock) for(size_t i=0;i<8;i++) if(!clocks[i].known) { clock=&clocks[i]; break; }
    if(!clock) clock=&clocks[device%8];
    if(!isfinite(timestamp) || timestamp<=0) return now;
    double delay=now-timestamp;
    if(!clock->known || clock->device!=device) *clock=(Clock){.device=device,.offset=delay,.last=now,.known=true};
    else if(delay<clock->offset || delay-clock->offset>1) clock->offset=delay;
    // A better delay estimate must never put a newer report before the
    // preceding one. That used to discard motion and reset pan recognition.
    double mapped=fmin(now,fmax(clock->last,timestamp+clock->offset));
    clock->last=mapped;
    return mapped;
}
static int hwm_mt_callback(void *device,HWM_MTTouch *touches,int count,double timestamp,int frame)
{
    (void)frame;
    static uintptr_t owner_device;
    static bool tracking,blocked;
    static uint64_t owner_generation;

    /* The framework calls back on a thread of its own at the default
     * priority, where a busy CPU holds the reports up and hands them over
     * bunched: the pan then stepped and its speed read wrong. Every report
     * feeds a frame, so the thread is raised to the frame thread's class. */
    qos_class_t qos=QOS_CLASS_DEFAULT;
    if(pthread_get_qos_class_np(pthread_self(),&qos,NULL)==0 && qos!=QOS_CLASS_USER_INTERACTIVE)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    if(!hwm_ready || hwm_paused || hwm_suspended || hwm_overview_active) {
        hwm_contact_pinch=(HWMPlanePinch){0}; atomic_store(&hwm_contact_pinch_state,0);
        atomic_store(&hwm_workspace_touch_owned,false);
        blocked=true;
        if(count>0) { tracking=true; owner_device=(uintptr_t)device; }
        else tracking=false;
        atomic_store(&hwm_native_touch_active,count>0);
        return 0;
    }
    double now=hwm_now();
    HWMPlaneTouchFrame sample={.device=(uintptr_t)device,.time=hwm_mt_report_time((uintptr_t)device,timestamp,now),.aspect=.625,.arrival_time=now};
    for(int i=0;i<count;i++) if(touches[i].state==3 || touches[i].state==4) {
        if(sample.count<4) sample.contacts[sample.count]=(HWMPlaneContact){touches[i].identifier,touches[i].normalized.position.x,touches[i].normalized.position.y};
        ++sample.count;
    }
    /* Decide ownership at first contact, and keep native input native through
     * full lift. Releasing the clutch or any mouse interaction cancels every
     * kind of workspace motion, not just pinch. Queued frames carry the same
     * generation fence as queued magnify reports. */
    if(tracking && owner_device!=sample.device) return 0;
    uint64_t interrupt=atomic_load(&hwm_pinch_interrupt_generation);
    bool eligible=hwm_workspace_gesture_allowed() && !hwm_pinch_button_down();
    if(!tracking && sample.count) {
        tracking=true; owner_device=sample.device;
        owner_generation=interrupt; blocked=!eligible;
    }
    bool was_owned=atomic_load(&hwm_workspace_touch_owned);
    if(tracking && (!eligible || owner_generation!=interrupt)) blocked=true;
    sample.allowed=tracking && !blocked;
    sample.generation=interrupt;
    atomic_store(&hwm_native_touch_active,tracking && blocked && sample.count>0);
    atomic_store(&hwm_workspace_touch_owned,sample.allowed && sample.count>0);
    if(!sample.allowed) {
        hwm_contact_pinch=(HWMPlanePinch){0};
        atomic_store(&hwm_contact_pinch_state,0);
        atomic_store(&hwm_contact_pinch_system,0);
        if(was_owned) {
            atomic_fetch_add(&hwm_pinch_interrupt_generation,1);
            HWMPlaneTouchFrame *cancel=malloc(sizeof(*cancel));
            if(cancel) { *cancel=sample; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,cancel,HWM_TOUCH_FRAME); }
        }
        if(!sample.count) { tracking=false; blocked=false; }
        return 0;
    }
    if(!sample.count) { tracking=false; blocked=false; }
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
        static uint64_t last_interrupt;
        uint64_t generation=atomic_load(&hwm_pinch_interrupt_generation);
        if(!hwm_contact_pinch.blocked && ((sample.count && hwm_pinch_button_down()) ||
           (generation!=last_interrupt && hwm_contact_pinch.tracking))) {
            hwm_plane_pinch_cancel(&hwm_contact_pinch);
            // Also fence frames when the raw callback observes the held button
            // before (or without) its down event reaching our event tap.
            generation=atomic_fetch_add(&hwm_pinch_interrupt_generation,1)+1;
        }
        last_interrupt=generation;
        bool was_scroll=hwm_contact_pinch.scroll;
        hwm_contact_pinch.system_pinch=atomic_load(&hwm_contact_pinch_system);
        // A partial lift after a pan must not clear a native gesture's lock.
        if(hwm_contact_pinch.blocked || hwm_contact_pinch.scroll) pair=sample.count;
        int result=hwm_plane_pinch_sample(&hwm_contact_pinch,sample.device,sample.contacts,pair,sample.time,sample.aspect,&delta);
        atomic_store(&hwm_contact_pinch_state,hwm_contact_pinch.blocked ? 4 : hwm_contact_pinch.engaged ? 2 : hwm_contact_pinch.scroll ? 3 : hwm_contact_pinch.tracking ? 1 : 0);
        if(result==HWM_PINCH_BEGIN || (hwm_contact_pinch.scroll && !was_scroll)) {
            const HWMPlanePinchReading *r=&hwm_contact_pinch.reading;
            NSLog(@"Tana2D pinch: %s after %.0f ms: spread %.1f mm, travel %.1f mm, recent %.1f/%.1f mm, opposed %d, share %d, recent %d, system %d",
                  result==HWM_PINCH_BEGIN ? "zoom" : "scroll",r->since_rest*1000,r->spread*160,r->travel*160,r->recent_spread*160,r->recent_travel*160,
                  r->opposed,r->share,r->recent,r->system);
        }
        if(sample.count==2) atomic_store(&hwm_contact_pinch_seen,now);
        if(result==HWM_PINCH_BEGIN || result==HWM_PINCH_CHANGE || result==HWM_PINCH_END) {
            HWMPlanePinchFrame *frame=malloc(sizeof(*frame));
            if(frame) {
                *frame=(HWMPlanePinchFrame){.time=sample.time,.delta=delta,.phase=result==HWM_PINCH_BEGIN ? 1 : result==HWM_PINCH_CHANGE ? 2 : 4,.generation=generation};
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
