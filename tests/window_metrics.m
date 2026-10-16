/* Read-only, fresh-process WindowServer metrics (avoids per-process caches). */
#import <Cocoa/Cocoa.h>
#include "../src/plane_presentation.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
extern int SLSGetWindowSubLevel(int,uint32_t);
extern CGError SLSGetWindowTransform(int,uint32_t,CGAffineTransform *);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform *);
extern CGError SLSGetWindowAlpha(int,uint32_t,float *);
extern CGError SLSGetWindowOwner(int,uint32_t,int *);
extern CGError SLSConnectionGetPID(int,pid_t *);
extern AXError _AXUIElementGetWindow(AXUIElementRef,uint32_t *);
static NSDictionary *appFrame(uint32_t wid)
{
    int owner=0;pid_t pid=0;CFTypeRef windows=NULL;
    if(SLSGetWindowOwner(SLSMainConnectionID(),wid,&owner) || SLSConnectionGetPID(owner,&pid)) return @{};
    AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,.2f);
    NSMutableDictionary *out=[NSMutableDictionary dictionaryWithObject:@NO forKey:@"app_frame_available"];
    if(AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&windows)==kAXErrorSuccess && windows) {
        for(id candidate in (NSArray *)windows) {
            uint32_t id=0;AXUIElementRef element=(AXUIElementRef)candidate;
            if(_AXUIElementGetWindow(element,&id)!=kAXErrorSuccess || id!=wid) continue;
            CFTypeRef p=NULL,s=NULL;CGPoint point;CGSize size;
            AXError pe=AXUIElementCopyAttributeValue(element,kAXPositionAttribute,&p),se=AXUIElementCopyAttributeValue(element,kAXSizeAttribute,&s);
            if(pe==kAXErrorSuccess && se==kAXErrorSuccess && p && s &&
               AXValueGetValue(p,kAXValueTypeCGPoint,&point) && AXValueGetValue(s,kAXValueTypeCGSize,&size)) {
                out[@"app_frame_available"]=@YES;out[@"app_frame"]=@[@(point.x),@(point.y),@(size.width),@(size.height)];
            }
            if(p)CFRelease(p);if(s)CFRelease(s);break;
        }
    }
    if(windows)CFRelease(windows);CFRelease(app);return out;
}
int main(int argc,char **argv) { @autoreleasepool {
    NSMutableArray *result=[NSMutableArray array];
    NSMutableArray *ids=[NSMutableArray array];
    if(argc==2 && (strcmp(argv[1],"--borders")==0 || strcmp(argv[1],"--visible-borders")==0)) {
        CGWindowListOption option=strcmp(argv[1],"--visible-borders")==0 ? kCGWindowListOptionOnScreenOnly : kCGWindowListOptionAll;
        CFArrayRef list=CGWindowListCopyWindowInfo(option,kCGNullWindowID);
        for(NSDictionary *entry in (NSArray *)list)
            if([entry[(id)kCGWindowOwnerName] isEqualToString:@"borders"])
                [ids addObject:entry[(id)kCGWindowNumber]];
        if(list) CFRelease(list);
    } else for(int i=argc>1&&!strcmp(argv[1],"--app")?2:1;i<argc;i++) [ids addObject:@(strtoul(argv[i],NULL,10))];
    for(NSNumber *identifier in ids) {
        uint32_t wid=identifier.unsignedIntValue; CGRect f=CGRectNull;
        CGError error=SLSGetWindowBounds(SLSMainConnectionID(),wid,&f);
        if(error!=kCGErrorSuccess) return 1;
        CGAffineTransform t;
        if(SLSGetWindowTransform(SLSMainConnectionID(),wid,&t)!=kCGErrorSuccess) return 1;
        CGAffineTransform final;
        if(SLSGetWindowTransformAtPlacement(SLSMainConnectionID(),wid,0x7fffff00,NULL,&final)!=kCGErrorSuccess) return 1;
        CGRect displayed=CGRectNull;
        if(!hwm_plane_displayed_frame(wid,&displayed)) return 1;
        float alpha=0; SLSGetWindowAlpha(SLSMainConnectionID(),wid,&alpha);
        [result addObject:@{@"id":@(wid),@"x":@(f.origin.x),@"y":@(f.origin.y),@"w":@(f.size.width),@"h":@(f.size.height),@"sublevel":@(SLSGetWindowSubLevel(SLSMainConnectionID(),wid)),
            @"a":@(t.a),@"b":@(t.b),@"c":@(t.c),@"d":@(t.d),@"tx":@(t.tx),@"ty":@(t.ty),@"alpha":@(alpha),
            @"final_a":@(final.a),@"final_d":@(final.d),@"final_tx":@(final.tx),@"final_ty":@(final.ty),
            @"public_display_x":@(displayed.origin.x),@"public_display_y":@(displayed.origin.y),
            @"public_display_width":@(displayed.size.width),@"public_display_height":@(displayed.size.height)}];
        if(argc>1&&!strcmp(argv[1],"--app")) {
            NSMutableDictionary *entry=[[result.lastObject mutableCopy]autorelease];[entry addEntriesFromDictionary:appFrame(wid)];
            [result removeLastObject];[result addObject:entry];
        }
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    puts([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
