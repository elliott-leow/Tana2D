/* Controlled native drag, Option-drag, or hover input for disposable fixture windows. */
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc!=6) { fprintf(stderr,"usage: plane_pointer_probe x y dx dy native|option|hover\n"); return 2; }
    double numbers[4];
    for(int i=0;i<4;i++) { char *end=NULL; numbers[i]=strtod(argv[i+1],&end); if(!end || *end || !isfinite(numbers[i])) return 2; }
    bool option=!strcmp(argv[5],"option"),hover=!strcmp(argv[5],"hover");
    if(!option && !hover && strcmp(argv[5],"native")) return 2;
    CGEventRef current=CGEventCreate(NULL); CGPoint original=CGEventGetLocation(current); CFRelease(current);
    for(int i=0;i<=25;i++) {
        double progress=fmin(i,24)/24.;
        CGPoint point=CGPointMake(numbers[0]+numbers[2]*progress,numbers[1]+numbers[3]*progress);
        CGEventType type=hover?kCGEventMouseMoved:i==0?kCGEventLeftMouseDown:i==25?kCGEventLeftMouseUp:kCGEventLeftMouseDragged;
        CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
        CGEventSetFlags(event,option?kCGEventFlagMaskAlternate:0);
        CGEventPost(kCGHIDEventTap,event); CFRelease(event); usleep(16667);
    }
    usleep(80000); CGWarpMouseCursorPosition(original);
    return 0;
}
