/* Synthetic integration input, only for an active Tana2D test session.
 * Pinch encoding: WebKit CoreGraphicsTestSPI.h / LinearMouse GestureKit.
 * https://github.com/linearmouse/linearmouse/tree/main/Modules/GestureKit
 */
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

static CGEventRef pinch(double delta,int phase)
{
    CGEventRef event=CGEventCreate(NULL);
    CGEventSetType(event,(CGEventType)29);
    CGEventSetIntegerValueField(event,(CGEventField)110,8);
    CGEventSetIntegerValueField(event,(CGEventField)132,phase);
    CGEventSetDoubleValueField(event,(CGEventField)113,delta);
    return event;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3) { fprintf(stderr,"usage: plane_gesture_probe pinch|horizontal|vertical|fit-key|describe-pinch <amount>\n"); return 2; }
    char *end=NULL; double amount=strtod(argv[2],&end);
    if(!end || *end || !isfinite(amount)) return 2;
    if(!strcmp(argv[1],"describe-pinch")) {
        CGEventRef event=pinch(amount,2);
        NSEvent *native=[NSEvent eventWithCGEvent:event];
        printf("type=%ld magnification=%.6f phase=%lu\n",(long)native.type,(double)native.magnification,(unsigned long)native.phase);
        BOOL correct=native.type==NSEventTypeMagnify && fabs(native.magnification-amount)<.0001;
        CFRelease(event); return correct?0:1;
    }
    if(!strcmp(argv[1],"fit-key")) {
        for(int pressed=1;pressed>=0;pressed--) {
            CGEventRef event=CGEventCreateKeyboardEvent(NULL,126,pressed);
            CGEventSetFlags(event,kCGEventFlagMaskControl);
            CGEventPost(kCGHIDEventTap,event); CFRelease(event); usleep(30000);
        }
        return 0;
    }
    BOOL magnify=!strcmp(argv[1],"pinch");
    int axis=!strcmp(argv[1],"horizontal")?1:!strcmp(argv[1],"vertical")?2:0;
    if(!magnify && !axis) return 2;
    for(int i=0;i<=31;i++) {
        int phase=i==0?1:i==31?4:2;
        CGEventRef event;
        if(magnify) event=pinch(i==0 || i==31 ? 0 : amount/30,phase);
        else {
            event=CGEventCreate(NULL); CGEventSetType(event,(CGEventType)30);
            CGEventSetIntegerValueField(event,(CGEventField)110,23);
            CGEventSetIntegerValueField(event,(CGEventField)123,axis);
            CGEventSetIntegerValueField(event,(CGEventField)132,phase);
            CGEventSetDoubleValueField(event,(CGEventField)124,amount*fmin(i,30)/30);
        }
        CGEventPost(kCGHIDEventTap,event); CFRelease(event); usleep(8333);
    }
} return 0; }
