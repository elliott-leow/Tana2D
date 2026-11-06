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
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    FILE *file=fopen(fixture_event_log_path,"a");if(file) {
        fprintf(file,"{\"kind\":\"key\",\"window\":%ld,\"time\":%.9f}\n",(long)self.windowNumber,NSProcessInfo.processInfo.systemUptime);fclose(file);
    }
}
- (void)sendEvent:(NSEvent *)event { fixture_event_log(event,self); [super sendEvent:event]; }
@end
/* Opt-in native file drag/drop surface. Existing click tests keep their
 * original button until the disposable fixture receives drag-mode. */
@interface FixtureFileDragView : NSView <NSDraggingSource,NSDraggingDestination>
@property BOOL dragging;
@end
@implementation FixtureFileDragView
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}
- (void)drawRect:(NSRect)rect {
    [[NSColor colorWithRed:.15 green:.3 blue:.5 alpha:1] setFill]; NSRectFill(rect);
    [@"Drag this test file to another fixture window" drawAtPoint:NSMakePoint(24,80)
      withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:18],NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)event { (void)event; self.dragging=NO; }
- (void)mouseDragged:(NSEvent *)event {
    if(self.dragging) return; self.dragging=YES;
    NSString *path=@"/tmp/tana2d_hci_drag_source.txt";
    [@"Tana2D native file drag verification\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSDraggingItem *item=[[NSDraggingItem alloc] initWithPasteboardWriter:[NSURL fileURLWithPath:path]];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    [item setDraggingFrame:NSMakeRect(p.x,p.y,48,48) contents:[[NSWorkspace sharedWorkspace]iconForFile:path]];
    [self beginDraggingSessionWithItems:@[item] event:event source:self]; [item release];
    FILE *f=fopen(fixture_event_log_path,"a"); if(f) { fprintf(f,"{\"kind\":\"file-drag-begin\",\"window\":%ld}\n",(long)self.window.windowNumber);fclose(f); }
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session; (void)context; return NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)session; (void)point; (void)operation; self.dragging=NO;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { (void)sender; return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { (void)sender; return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *urls=[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    NSURL *url=urls.firstObject;
    if(![url.path isEqual:@"/tmp/tana2d_hci_drag_source.txt"]) return NO;
    NSString *destination=@"/tmp/tana2d_hci_drag_received.txt";
    [[NSFileManager defaultManager]removeItemAtPath:destination error:NULL];
    BOOL copied=[[NSFileManager defaultManager]copyItemAtPath:url.path toPath:destination error:NULL];
    FILE *f=fopen(fixture_event_log_path,"a");if(f) { fprintf(f,"{\"kind\":\"file-drop\",\"window\":%ld,\"copied\":%s}\n",(long)self.window.windowNumber,copied?"true":"false");fclose(f); }
    return copied;
}
@end
@interface Fixture : NSObject
@property(nonatomic,retain) NSMutableArray *windows;
@property(nonatomic,retain) NSMutableArray *extras;
- (void)command:(NSNotification *)notification;
- (void)add;
- (void)button:(NSButton *)sender;
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
    NSButton *button=[NSButton buttonWithTitle:@"Test native click" target:self action:@selector(button:)];
    button.bordered=NO;
    button.frame=view.bounds;button.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [view addSubview:button];
    [self.windows addObject:w]; [w makeKeyAndOrderFront:nil];
}
- (void)button:(NSButton *)sender {
    FILE *file=fopen(fixture_event_log_path,"a");if(file) {
        fprintf(file,"{\"kind\":\"action\",\"window\":%ld,\"time\":%.9f}\n",(long)sender.window.windowNumber,NSProcessInfo.processInfo.systemUptime);fclose(file);
    }
}
- (void)command:(NSNotification *)n {
    NSString *command=n.userInfo[@"command"];
    if([command isEqual:@"inspect"]) {
        NSMutableArray *rows=[NSMutableArray array];
        double height=NSScreen.screens.firstObject.frame.size.height;
        for(NSWindow *w in self.windows) {
            NSRect f=w.frame;
            CGRect shown=CGRectNull;
            CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,(CGWindowID)w.windowNumber);
            if(info && CFArrayGetCount(info)) {
                CFDictionaryRef row=CFArrayGetValueAtIndex(info,0);
                CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(row,kCGWindowBounds),&shown);
            }
            if(info)CFRelease(info);
            /* Firefox uses this same zero-rect AppKit conversion after
             * polling the native screen pointer. Sample eight screen points
             * explicitly, without moving or posting any pointer input. */
            NSMutableArray *samples=[NSMutableArray array];
            const double fractions[][2]={{.02,.02},{.5,.02},{.98,.02},{.02,.5},{.98,.5},{.02,.98},{.5,.98},{.98,.98}};
            for(int i=0;i<8;i++) {
                NSPoint local=NSMakePoint(f.size.width*fractions[i][0],f.size.height*(1-fractions[i][1]));
                NSPoint screen=NSMakePoint(f.origin.x+local.x,f.origin.y+local.y);
                NSPoint converted=[w convertRectFromScreen:NSMakeRect(screen.x,screen.y,0,0)].origin;
                [samples addObject:@{@"screen":@[@(screen.x),@(height-screen.y)],@"local":@[@(converted.x),@(converted.y)],@"expected":@[@(local.x),@(local.y)]}];
            }
            [rows addObject:@{@"id":@(w.windowNumber),@"app_frame":@[@(f.origin.x),@(height-NSMaxY(f)),@(f.size.width),@(f.size.height)],
                @"displayed_frame":@[@(shown.origin.x),@(shown.origin.y),@(shown.size.width),@(shown.size.height)],@"samples":samples}];
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL];
        [data writeToFile:@"/tmp/tana2d_fixture_app_coordinates.json" atomically:YES];return;
    }
    if ([command isEqual:@"trace-reset"]) { unlink(fixture_event_log_path); return; }
    if([command isEqual:@"drag-mode"]) {
        for(NSWindow *w in self.windows) {
            FixtureFileDragView *v=[[FixtureFileDragView alloc]initWithFrame:w.contentView.bounds];
            w.contentView=v; [v release];
        }
        return;
    }
    if ([command isEqual:@"new"]) [self add];
    if ([command isEqual:@"move"]) {
        NSWindow *w=self.windows.lastObject;
        if(n.userInfo[@"id"]) {
            w=nil;
            for(NSWindow *candidate in self.windows) if(candidate.windowNumber==[n.userInfo[@"id"] integerValue]) { w=candidate; break; }
        }
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
    /* Native fullscreen through AppKit, the same path as the green button
     * and View > Enter Full Screen. */
    if ([command isEqual:@"fullscreen"]) [self.windows.lastObject toggleFullScreen:nil];
    /* Secondary windows that belong to a main window and must stay out of
     * the plane: a dialog panel, a utility panel, an attached child window
     * and an app-modal window. They are kept apart from self.windows so the
     * plane commands above keep addressing main windows only. */
    if ([command isEqual:@"dialog"] || [command isEqual:@"panel"] || [command isEqual:@"child"] || [command isEqual:@"modal"]) {
        NSWindow *parent=self.windows.lastObject;
        NSRect frame=NSMakeRect(NSMinX(parent.frame)+40,NSMaxY(parent.frame)-260,320,200);
        NSWindow *w;
        if([command isEqual:@"dialog"])
            w=[[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        else if([command isEqual:@"panel"]) {
            NSPanel *p=[[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
            p.floatingPanel=NO; p.hidesOnDeactivate=NO; w=p; // Normal level: only its role marks it secondary.
        } else
            w=[[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        w.title=[NSString stringWithFormat:@"Tana2D Test %@",command]; w.releasedWhenClosed=NO;
        if(!self.extras) self.extras=[NSMutableArray array];
        [self.extras addObject:w]; [w release];
        if([command isEqual:@"child"]) [parent addChildWindow:w ordered:NSWindowAbove];
        if([command isEqual:@"modal"]) { [w center]; dispatch_async(dispatch_get_main_queue(),^{ [NSApp runModalForWindow:w]; }); }
        else [w makeKeyAndOrderFront:nil];
        return;
    }
    if ([command isEqual:@"close-extras"]) {
        if([NSApp modalWindow]) [NSApp stopModal];
        for(NSWindow *w in self.extras) { [w.parentWindow removeChildWindow:w]; [w close]; }
        [self.extras removeAllObjects]; return;
    }
    if ([command isEqual:@"close"]) { [self.windows.lastObject close]; [self.windows removeLastObject]; }
    if ([command isEqual:@"minimize"]) [self.windows.lastObject miniaturize:nil];
    if ([command isEqual:@"restore"]) [self.windows.lastObject deminiaturize:nil];
    if ([command isEqual:@"quit"]) [NSApp terminate:nil];
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    if(argc==5 && !strcmp(argv[1],"move-window")) {
        NSDictionary *info=@{@"command":@"move",@"id":@(strtoul(argv[2],NULL,10)),@"x":@(atof(argv[3])),@"y":@(atof(argv[4]))};
        [[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"dev.tana2d.fixture" object:nil userInfo:info deliverImmediately:YES];return 0;
    }
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
    const char *count=getenv("TANA2D_FIXTURE_WINDOWS");
    int windows=count?atoi(count):3; if(windows<1 || windows>8) windows=3;
    for(int i=0;i<windows;++i) [fixture add];
    [NSApp activateIgnoringOtherApps:YES]; [NSApp run];
} return 0; }
