/* Read-only high-rate sampling of selected windows' displayed bounds and
 * opacity. Moves, focuses and posts nothing. Usage: probe ms id,id,... */
#import <Cocoa/Cocoa.h>
#include <time.h>
#include <unistd.h>
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowAlpha(int,uint32_t,float *);
static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9; }
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3) return 2;
    double duration=strtod(argv[1],NULL)/1000.;
    if(duration<=0 || duration>4) return 2;
    NSSet *selected=[NSSet setWithArray:[@(argv[2]) componentsSeparatedByString:@","]];
    NSMutableArray *samples=[NSMutableArray array];
    puts("ready"); fflush(stdout);
    double start=now();
    while(now()-start<duration) { @autoreleasepool {
        CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
        NSMutableDictionary *positions=[NSMutableDictionary dictionary];
        for(NSDictionary *row in (__bridge NSArray *)info) {
            NSNumber *identifier=row[(id)kCGWindowNumber];
            if(![selected containsObject:identifier.stringValue]) continue;
            CGRect f=CGRectNull; float a=-1;
            if(CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&f) &&
               SLSGetWindowAlpha(SLSMainConnectionID(),identifier.unsignedIntValue,&a)==kCGErrorSuccess)
                positions[identifier.stringValue]=@[@(f.origin.x),@(f.origin.y),@(a)];
        }
        [samples addObject:@[@(now()-start),positions]];
        if(info) CFRelease(info);
        usleep(1500);
    }}
    NSData *json=[NSJSONSerialization dataWithJSONObject:samples options:0 error:NULL];
    fwrite(json.bytes,1,json.length,stdout); putchar('\n'); return 0;
} }
