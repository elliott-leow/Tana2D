/* Read-only high-rate position/opacity sampling for a disposable fixture. */
#import <Cocoa/Cocoa.h>
#include <time.h>
#include <unistd.h>
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowAlpha(int,uint32_t,float *);
static double clockSeconds(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9; }
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3 && argc!=4)return 2;
    uint32_t wid=(uint32_t)strtoul(argv[1],NULL,10);
    double duration=strtod(argv[2],NULL)/1000.;
    if(!wid || duration<=0 || duration>3)return 2;
    NSMutableArray *samples=[NSMutableArray array];
    NSSet *selected=argc==4 ? [NSSet setWithArray:[@(argv[3]) componentsSeparatedByString:@","]] : [NSSet setWithObject:@(argv[1])];
    CFArrayRef initial=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    bool fixture=initial && CFArrayGetCount(initial) &&
        [[(NSDictionary *)CFArrayGetValueAtIndex(initial,0) objectForKey:(id)kCGWindowOwnerName] isEqualToString:@"Tana2DFixture"];
    if(initial)CFRelease(initial);if(!fixture)return 3;
    puts("ready");fflush(stdout);
    double start=clockSeconds();
    while(clockSeconds()-start<duration) { @autoreleasepool {
        CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
        CGRect frame=CGRectNull;float alpha=-1;NSMutableDictionary *positions=[NSMutableDictionary dictionary];
        for(NSDictionary *row in (NSArray *)info) {
            NSNumber *identifier=row[(id)kCGWindowNumber];if(![selected containsObject:identifier.stringValue])continue;
            CGRect f=CGRectNull;float a=-1;
            if(CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)row[(id)kCGWindowBounds],&f) &&
               SLSGetWindowAlpha(SLSMainConnectionID(),identifier.unsignedIntValue,&a)==kCGErrorSuccess) {
                positions[identifier.stringValue]=@[@(f.origin.x),@(f.origin.y),@(a)];
                if(identifier.unsignedIntValue==wid) {frame=f;alpha=a;}
            }
        }
        if(!CGRectIsNull(frame))[samples addObject:@[@(clockSeconds()-start),@(frame.origin.x),@(frame.origin.y),@(alpha),positions]];
        if(info)CFRelease(info);usleep(1500);
    }}
    NSData *json=[NSJSONSerialization dataWithJSONObject:samples options:0 error:NULL];
    fwrite(json.bytes,1,json.length,stdout);putchar('\n');return 0;
} }
