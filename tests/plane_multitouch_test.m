/* Exercise the production raw-touch callback with a native mouse owner. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdatomic.h>
#include "../src/plane_pinch.h"
static bool hwm_ready=true,hwm_paused,hwm_suspended,hwm_overview_active;
static HWMPlanePinch hwm_contact_pinch;
static _Atomic int hwm_contact_pinch_state;
static _Atomic double hwm_contact_pinch_seen,hwm_contact_pinch_system;
static _Atomic uint64_t hwm_pinch_interrupt_generation;
typedef struct {
    double time,delta; int phase; uint64_t generation;
    CGPoint pointer; bool has_pointer;
} HWMPlanePinchFrame;
static double clock_now;
static double hwm_now(void) { return clock_now; }
static bool gesture_allowed=true;
static _Atomic bool hwm_workspace_touch_owned,hwm_native_touch_active;
static bool hwm_workspace_gesture_allowed(void) { return gesture_allowed; }
static bool button_down;
static bool hwm_pinch_button_down(void) { return button_down; }
enum { HORIZONTAL_INPUT,HWM_PINCH_FRAME,HWM_TOUCH_FRAME };
static int g_event_loop,posted,touch_posted;
static HWMPlanePinchFrame last_posted;
static void event_loop_post(void *loop,int type,void *context,int action)
{
    (void)loop; assert(type==HORIZONTAL_INPUT);
    if(action==HWM_PINCH_FRAME) { ++posted; last_posted=*(HWMPlanePinchFrame *)context; }
    else if(action==HWM_TOUCH_FRAME) ++touch_posted;
    free(context);
}
#include "../src/plane_multitouch.m"

static void sample(int count,double spread)
{
    clock_now+=.01;
    HWM_MTTouch touches[3]={0};
    for(int i=0;i<3;i++) {
        touches[i].identifier=i+1; touches[i].state=4;
        touches[i].normalized.position=(HWM_MTPoint){.5+(i ? 1 : -1)*spread/2,.5};
    }
    hwm_mt_callback((void *)1,touches,count,0,0);
}
static void reset(void)
{
    button_down=false; gesture_allowed=true; sample(0,.2); clock_now+=1;
    posted=0; atomic_store(&hwm_contact_pinch_system,0);
}
static void pinch(void)
{
    for(int i=0;i<12;i++) sample(2,.2+i*.01);
}
int main(void)
{
    @autoreleasepool {
        // A lower arrival delay must not reverse the mapped report clock.
        double first=hwm_mt_report_time(88,10,20);
        double second=hwm_mt_report_time(88,10.001,20.0005);
        assert(second>=first && second<=20.0005);
        assert(hwm_mt_report_time(99,100,20.001)==20.001); // Independent device clock.
        assert(hwm_mt_report_time(88,10.003,20.002)>=second);
        reset(); button_down=true;
        pinch();
        assert(posted==0 && !atomic_load(&hwm_workspace_touch_owned));
        button_down=false; // Mouse-up alone does not relinquish the contacts.
        sample(1,.2); pinch();
        assert(posted==0 && !atomic_load(&hwm_workspace_touch_owned));
        sample(3,.2); sample(2,.3); // Nor may the pan-tail filter clear it.
        assert(posted==0 && !atomic_load(&hwm_workspace_touch_owned));
        reset(); pinch(); assert(posted>0);

        // A held button discovered without the event tap fences queued zoom.
        uint64_t queued=last_posted.generation;
        button_down=true; sample(2,.4);
        assert(queued!=atomic_load(&hwm_pinch_interrupt_generation));
        int before=posted;
        button_down=false; pinch(); assert(posted==before);
        sample(0,.2);
        assert(queued!=atomic_load(&hwm_pinch_interrupt_generation));

        // Even a complete click between touch reports cancels an active pair.
        reset(); sample(2,.2);
        atomic_fetch_add(&hwm_pinch_interrupt_generation,1);
        pinch(); assert(posted==0 && !atomic_load(&hwm_workspace_touch_owned));

        // An old mouse click while no fingers were down does not block a new pinch.
        reset(); atomic_fetch_add(&hwm_pinch_interrupt_generation,1);
        pinch(); assert(posted>0 && last_posted.generation==atomic_load(&hwm_pinch_interrupt_generation));
        // Bare native pinch stays native even if Fn is pressed mid-contact.
        reset(); gesture_allowed=false; pinch();
        assert(posted==0 && !atomic_load(&hwm_workspace_touch_owned));
        gesture_allowed=true; pinch(); assert(posted==0);
        reset(); pinch(); assert(posted>0);

        // Releasing Fn invalidates queued zoom, and re-press cannot reclaim.
        queued=last_posted.generation;
        gesture_allowed=false; sample(2,.4);
        assert(queued!=atomic_load(&hwm_pinch_interrupt_generation));
        before=posted; gesture_allowed=true; pinch(); assert(posted==before);

        // A native mouse press fences three/four-finger movement as well.
        reset(); button_down=true; before=touch_posted;
        sample(3,.2); sample(3,.3); assert(touch_posted==before);
        button_down=false; sample(3,.4); assert(touch_posted==before);
        reset(); sample(3,.2); assert(touch_posted>before);
        before=touch_posted; atomic_fetch_add(&hwm_pinch_interrupt_generation,1);
        sample(3,.3); assert(!atomic_load(&hwm_workspace_touch_owned));
        sample(3,.4); assert(touch_posted==before+1); // One cancellation only.
        reset();
        puts("plane_multitouch_test: ok");
    }
    return 0;
}
