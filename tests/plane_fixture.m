#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

static const char *fixture_event_log_path="/tmp/tana2d_fixture_native_events.log";

static void fixture_event_log(NSEvent *event,NSWindow *window)
{
    if(event.type!=NSEventTypeLeftMouseDown && event.type!=NSEventTypeLeftMouseDragged && event.type!=NSEventTypeLeftMouseUp) return;
    FILE *file=fopen(fixture_event_log_path,"a"); if(!file) return;
    NSPoint local=event.locationInWindow,screen=[window convertPointToScreen:local];
    CGEventRef cg=event.CGEvent;
    CGPoint global=cg?CGEventGetLocation(cg):CGPointZero;
    fprintf(file,"{\"type\":%lu,\"window\":%ld,\"local\":[%.4f,%.4f],\"screen\":[%.4f,%.4f],\"global\":[%.4f,%.4f],\"field51\":%lld,\"field91\":%lld,\"field92\":%lld,\"frame\":[%.4f,%.4f,%.4f,%.4f]}\n",
            (unsigned long)event.type,(long)window.windowNumber,local.x,local.y,screen.x,screen.y,global.x,global.y,
            cg?CGEventGetIntegerValueField(cg,51):0,cg?CGEventGetIntegerValueField(cg,91):0,cg?CGEventGetIntegerValueField(cg,92):0,
            window.frame.origin.x,window.frame.origin.y,window.frame.size.width,window.frame.size.height);
    fclose(file);
}

@interface FixtureWindow : NSWindow @end
@implementation FixtureWindow
- (void)sendEvent:(NSEvent *)event { fixture_event_log(event,self); [super sendEvent:event]; }
@end
@interface Fixture : NSObject
@property(nonatomic,retain) NSMutableArray *windows;
- (void)command:(NSNotification *)notification;
- (void)add;
@end
@implementation Fixture
- (void)add {
    NSUInteger i=self.windows.count;
    NSWindow *w=[[FixtureWindow alloc] initWithContentRect:NSMakeRect(160+i*50,180+i*50,500,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    w.title=[NSString stringWithFormat:@"Tana2D Test %lu",(unsigned long)i+1];
    w.minSize=NSMakeSize(240,180); w.releasedWhenClosed=NO;
    NSView *view=w.contentView; view.wantsLayer=YES;
    view.layer.backgroundColor=[[NSColor colorWithHue:i*.23 saturation:.15 brightness:.95 alpha:1] CGColor];
    NSTextField *label=[NSTextField labelWithString:w.title];
    label.font=[NSFont systemFontOfSize:24 weight:NSFontWeightMedium]; label.frame=NSMakeRect(30,50,360,80); [view addSubview:label];
    [self.windows addObject:w]; [w makeKeyAndOrderFront:nil];
}
- (void)command:(NSNotification *)n {
    NSString *command=n.userInfo[@"command"];
    if ([command isEqual:@"trace-reset"]) { unlink(fixture_event_log_path); return; }
    if ([command isEqual:@"new"]) [self add];
    if ([command isEqual:@"move"]) {
        NSWindow *w=self.windows.lastObject;
        [w setFrameTopLeftPoint:NSMakePoint([n.userInfo[@"x"] doubleValue],
            NSScreen.screens.firstObject.frame.size.height-[n.userInfo[@"y"] doubleValue])];
    }
    if ([command isEqual:@"resize"]) {
        NSWindow *w=self.windows.lastObject;
        NSSize size=NSMakeSize([n.userInfo[@"width"] doubleValue],[n.userInfo[@"height"] doubleValue]);
        if(size.width>=240 && size.height>=180) {
            NSRect frame=w.frame; frame.origin.y+=frame.size.height-size.height; frame.size=size;
            [w setFrame:frame display:YES];
        }
    }
    if ([command isEqual:@"close"]) { [self.windows.lastObject close]; [self.windows removeLastObject]; }
    if ([command isEqual:@"minimize"]) [self.windows.lastObject miniaturize:nil];
    if ([command isEqual:@"restore"]) [self.windows.lastObject deminiaturize:nil];
    if ([command isEqual:@"quit"]) [NSApp terminate:nil];
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    if (argc==2 || (argc==4 && (!strcmp(argv[1],"resize") || !strcmp(argv[1],"move")))) {
        NSMutableDictionary *info=[NSMutableDictionary dictionaryWithObject:@(argv[1]) forKey:@"command"];
        if(argc==4) {
            bool move=!strcmp(argv[1],"move");
            info[move?@"x":@"width"]=@(atof(argv[2])); info[move?@"y":@"height"]=@(atof(argv[3]));
        }
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"dev.tana2d.fixture" object:nil userInfo:info deliverImmediately:YES]; return 0;
    }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    Fixture *fixture=[Fixture new]; fixture.windows=[NSMutableArray array];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:fixture selector:@selector(command:) name:@"dev.tana2d.fixture" object:nil];
    for(int i=0;i<3;++i) [fixture add];
    [NSApp activateIgnoringOtherApps:YES]; [NSApp run];
} return 0; }
