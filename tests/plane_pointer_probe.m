/* Controlled native drag, Option-drag, or hover input for disposable fixture windows. */
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
int main(int argc,char **argv) {
    if(argc!=6 && argc!=7) { fprintf(stderr,"usage: plane_pointer_probe x y dx dy native|option|hover [hold_ms]\n"); return 2; }
    double numbers[4];
    for(int i=0;i<4;i++) { char *end=NULL; numbers[i]=strtod(argv[i+1],&end); if(!end || *end || !isfinite(numbers[i])) return 2; }
    double hold_ms=0;
    if(argc==7) { char *end=NULL; hold_ms=strtod(argv[6],&end); if(!end || *end || !isfinite(hold_ms) || hold_ms<0 || hold_ms>2000) return 2; }
    bool option=!strcmp(argv[5],"option"),hover=!strcmp(argv[5],"hover");
    if(!option && !hover && strcmp(argv[5],"native")) return 2;
    CGEventRef current=CGEventCreate(NULL); CGPoint original=CGEventGetLocation(current); CFRelease(current);
    for(int i=0;i<=25;i++) {
        double progress=fmin(i,24)/24.;
        CGPoint point=CGPointMake(numbers[0]+numbers[2]*progress,numbers[1]+numbers[3]*progress);
        CGEventType type=hover?kCGEventMouseMoved:i==0?kCGEventLeftMouseDown:i==25?kCGEventLeftMouseUp:kCGEventLeftMouseDragged;
        // A posted event can carry P while the global cursor still remains at
        // a previous point. Native tracking and polling must observe the same
        // position, as they do for hardware input.
        if(CGWarpMouseCursorPosition(point)!=kCGErrorSuccess) {
            CGWarpMouseCursorPosition(original); return 1;
        }
        CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
        CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventSetFlags(event,option?kCGEventFlagMaskAlternate:0);
        CGEventPost(kCGHIDEventTap,event); CFRelease(event);
        usleep(16667);
        if(i==24 && !hover && hold_ms>0) usleep((useconds_t)(hold_ms*1000));
    }
    usleep(80000); CGWarpMouseCursorPosition(original);
    return 0;
}
