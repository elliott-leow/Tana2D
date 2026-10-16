/* Send one stationary motion through the real event tap. Never warp or
 * reconstruct the pointer. Refuse unless the current point hits a fixture. */
#import <Cocoa/Cocoa.h>
#include <time.h>
extern CGError SLSFindWindowAndOwner(int,uint32_t,int,int,CGPoint *,CGPoint *,uint32_t *,int *);
extern int SLSMainConnectionID(void);
static NSString *owner(uint32_t wid)
{
    CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    NSString *name=nil;
    if(info && CFArrayGetCount(info)) name=[[(NSDictionary *)CFArrayGetValueAtIndex(info,0) objectForKey:(id)kCGWindowOwnerName] retain];
    if(info)CFRelease(info);return [name autorelease];
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 && !(argc==3 && !strcmp(argv[2],"--click")))return 2;
    bool click=argc==3;
    uint32_t expected=(uint32_t)strtoul(argv[1],NULL,10),wid=0,previous=0;int cid=0;
    CGEventRef sample=CGEventCreate(NULL);CGPoint point=CGEventGetLocation(sample);CFRelease(sample);
    CGPoint local=CGPointZero;
    for(int i=0;i<16;i++) {
        if(SLSFindWindowAndOwner(SLSMainConnectionID(),previous,i?-1:1,0,&point,&local,&wid,&cid)!=kCGErrorSuccess || !wid || wid==previous)return 3;
        if(wid==expected)break;
        if(click) { // A click must hit the fixture directly, without an overlay.
            fprintf(stderr,"click refused: expected=%u top=%u owner=%s point=%.2f,%.2f\n",expected,wid,owner(wid).UTF8String,point.x,point.y);return 3;
        }
        if(![owner(wid) isEqualToString:@"Tana2D"])return 3;
        previous=wid;
    }
    if(wid!=expected || ![owner(wid) isEqualToString:@"Tana2DFixture"])return 3;
    sample=CGEventCreate(NULL);CGPoint latest=CGEventGetLocation(sample);CGEventFlags flags=CGEventGetFlags(sample);CFRelease(sample);
    if(hypot(latest.x-point.x,latest.y-point.y)>.01)return 4;
    CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);
    uint64_t timestamp=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CGEventSetTimestamp(event,timestamp);CGEventSetFlags(event,flags);
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);
    if(click) {
        for(int i=0;i<2;i++) {
            CGEventRef press=CGEventCreateMouseEvent(NULL,i?kCGEventLeftMouseUp:kCGEventLeftMouseDown,point,kCGMouseButtonLeft);
            CGEventSetFlags(press,flags);CGEventPost(kCGHIDEventTap,press);CFRelease(press);
        }
    }
    printf("{\"started\":%.9f,\"window\":%u,\"point\":[%.4f,%.4f]}\n",timestamp/1e9,wid,point.x,point.y);
    return 0;
} }
