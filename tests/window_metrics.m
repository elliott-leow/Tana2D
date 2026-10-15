/* Read-only, fresh-process WindowServer metrics (avoids per-process caches). */
#import <Cocoa/Cocoa.h>
#include "../src/plane_presentation.h"
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int,uint32_t,CGRect *);
extern int SLSGetWindowSubLevel(int,uint32_t);
extern CGError SLSGetWindowTransform(int,uint32_t,CGAffineTransform *);
extern CGError SLSGetWindowTransformAtPlacement(int,uint32_t,int,int*,CGAffineTransform *);
extern CGError SLSGetWindowAlpha(int,uint32_t,float *);
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
    } else for(int i=1;i<argc;i++) [ids addObject:@(strtoul(argv[i],NULL,10))];
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
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    puts([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
