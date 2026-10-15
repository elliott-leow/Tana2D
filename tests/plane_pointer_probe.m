/* Controlled native drag, Option-drag, or hover input for disposable fixture windows. */
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>

/* This probe records the annotated WindowServer event separately from the
 * manager's trace.  It is fixture diagnostics only; it neither edits nor
 * suppresses an event. */
static FILE *field_trace;
static CFMachPortRef field_tap;

static CGEventRef field_trace_callback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context)
{
    (void)proxy; (void)context;
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) { CGEventTapEnable(field_tap,true); return event; }
    if(type!=kCGEventLeftMouseDown && type!=kCGEventLeftMouseDragged && type!=kCGEventLeftMouseUp) return event;
    CGPoint point=CGEventGetLocation(event);
    fprintf(field_trace,"{\"kind\":\"annotated\",\"type\":%u,\"event\":[%.4f,%.4f],\"field51\":%lld,\"field91\":%lld,\"field92\":%lld,\"time\":%llu}\n",
            type,point.x,point.y,CGEventGetIntegerValueField(event,51),CGEventGetIntegerValueField(event,91),CGEventGetIntegerValueField(event,92),(unsigned long long)CGEventGetTimestamp(event));
    fflush(field_trace); return event;
}

static void field_trace_pump(double milliseconds)
{
    double end=(double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6+milliseconds;
    while((double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6<end)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,.002,true);
}

int main(int argc,char **argv) {
    if(argc!=6 && argc!=7) { fprintf(stderr,"usage: plane_pointer_probe x y dx dy native|option|hover [hold_ms]\n"); return 2; }
    double numbers[4];
    for(int i=0;i<4;i++) { char *end=NULL; numbers[i]=strtod(argv[i+1],&end); if(!end || *end || !isfinite(numbers[i])) return 2; }
    double hold_ms=0;
    if(argc==7) { char *end=NULL; hold_ms=strtod(argv[6],&end); if(!end || *end || !isfinite(hold_ms) || hold_ms<0 || hold_ms>2000) return 2; }
    bool option=!strcmp(argv[5],"option"),hover=!strcmp(argv[5],"hover");
    if(!option && !hover && strcmp(argv[5],"native")) return 2;
    const char *trace_path=getenv("HWM_POINTER_FIELD_TRACE"); if(!trace_path) trace_path="/tmp/tana2d_native_pointer_fields.log";
    field_trace=fopen(trace_path,"w"); if(!field_trace) return 2;
    CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventLeftMouseUp);
    field_tap=CGEventTapCreate(kCGAnnotatedSessionEventTap,kCGTailAppendEventTap,kCGEventTapOptionListenOnly,mask,field_trace_callback,NULL);
    if(field_tap) {
        CFRunLoopSourceRef source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,field_tap,0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(),source,kCFRunLoopCommonModes); CFRelease(source);
    } else fprintf(field_trace,"{\"kind\":\"tap-error\"}\n");
    CGEventRef current=CGEventCreate(NULL); CGPoint original=CGEventGetLocation(current); CFRelease(current);
    for(int i=0;i<=25;i++) {
        double progress=fmin(i,24)/24.;
        CGPoint point=CGPointMake(numbers[0]+numbers[2]*progress,numbers[1]+numbers[3]*progress);
        CGEventType type=hover?kCGEventMouseMoved:i==0?kCGEventLeftMouseDown:i==25?kCGEventLeftMouseUp:kCGEventLeftMouseDragged;
        // A posted event can carry P while the global cursor still remains at
        // a previous point. Native tracking and polling must observe the same
        // position, as they do for hardware input.
        if(CGWarpMouseCursorPosition(point)!=kCGErrorSuccess) {
            CGWarpMouseCursorPosition(original); if(field_tap) CFRelease(field_tap); fclose(field_trace); return 1;
        }
        current=CGEventCreate(NULL); CGPoint cursor=CGEventGetLocation(current); CFRelease(current);
        fprintf(field_trace,"{\"kind\":\"send\",\"type\":%u,\"event\":[%.4f,%.4f],\"cursor\":[%.4f,%.4f]}\n",type,point.x,point.y,cursor.x,cursor.y); fflush(field_trace);
        CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
        CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventSetFlags(event,option?kCGEventFlagMaskAlternate:0);
        CGEventPost(kCGHIDEventTap,event); CFRelease(event);
        field_trace_pump(16.667);
        if(i==24 && !hover && hold_ms>0) field_trace_pump(hold_ms);
    }
    field_trace_pump(80); CGWarpMouseCursorPosition(original);
    if(field_tap) CFRelease(field_tap); fclose(field_trace);
    return 0;
}
