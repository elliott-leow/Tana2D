/* Opt-in native-menu fixture for tests/live_menu_focus.py.  It owns both
 * windows, never invokes a menu item, and accepts only open/dismiss/quit
 * commands addressed to its PID through a distributed notification. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <time.h>
#include <unistd.h>

static NSString *const HWMMenuFixtureNotification = @"dev.tana2d.live-menu-fixture";
static void stamp_event(CGEventRef event) { CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); }

@interface HWMMenuFixture : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic,retain) NSString *statusPath;
@property(nonatomic,retain) NSWindow *window;
@property(nonatomic,retain) NSMenu *menu;
@property(nonatomic,retain) NSDictionary *menuBounds;
@property(nonatomic,retain) NSString *highlightedTitle;
@property(nonatomic,retain) NSArray *menuCandidates;
@property(nonatomic,retain) NSMenuItem *submenuItem;
@property(nonatomic,retain) NSPanel *popup;
@property(nonatomic,assign) BOOL menuOpen, submenuOpen;
@property(nonatomic,assign) NSTimeInterval showMenuEnteredAt, menuWillOpenAt;
@property(nonatomic,assign) pid_t frontPIDAtShowMenuEntry;
@end

@implementation HWMMenuFixture
- (void)writeStatus {
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMutableDictionary *status=[@{ @"pid":@(NSProcessInfo.processInfo.processIdentifier),
                                    @"menuOpen":@(self.menuOpen), @"submenuOpen":@(self.submenuOpen),
                                    @"frontPid":@(front.processIdentifier),
                                    @"showMenuEnteredAt":@(self.showMenuEnteredAt), @"menuWillOpenAt":@(self.menuWillOpenAt),
                                    @"frontPIDAtShowMenuEntry":@(self.frontPIDAtShowMenuEntry),
                                    @"windowNumber":@(self.window.windowNumber) } mutableCopy];
    if (self.popup) {
        NSRect frame=self.popup.frame;
        status[@"popupPresent"]=@YES;
        status[@"popupVisible"]=@(self.popup.visible);
        status[@"popupAlpha"]=@(self.popup.alphaValue);
        status[@"popupBounds"]=@{ @"x":@(frame.origin.x),
            @"y":@(NSScreen.screens.firstObject.frame.size.height-NSMaxY(frame)),
            @"width":@(frame.size.width), @"height":@(frame.size.height) };
    } else status[@"popupPresent"]=@NO;
    if (self.window) {
        NSRect frame=[self.window convertRectToScreen:self.window.contentView.bounds];
        status[@"windowBounds"]=@{ @"x":@(frame.origin.x), @"y":@(NSScreen.screens.firstObject.frame.size.height-NSMaxY(frame)),
                                    @"width":@(frame.size.width), @"height":@(frame.size.height) };
    }
    if (self.menuBounds) status[@"menuBounds"]=self.menuBounds;
    if (self.highlightedTitle) status[@"highlightedTitle"]=self.highlightedTitle;
    if (self.menuCandidates) status[@"menuCandidates"]=self.menuCandidates;
    if (self.submenuItem) {
        NSRect frame=self.submenuItem.accessibilityFrame;
        if (!NSIsEmptyRect(frame)) status[@"submenuPoint"]=@{ @"x":@(NSMidX(frame)),
            @"y":@(NSScreen.screens.firstObject.frame.size.height-NSMidY(frame)) };
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:0 error:NULL];
    [data writeToFile:self.statusPath atomically:YES];
    [status release];
}
- (void)sampleMenuBounds {
    if (!self.menuOpen) return;
    CFArrayRef windows=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    NSDictionary *best=nil;
    NSMutableArray *candidates=[NSMutableArray array];
    for (NSDictionary *info in (NSArray *)windows) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != NSProcessInfo.processInfo.processIdentifier) continue;
        if ([info[(id)kCGWindowNumber] intValue] == self.window.windowNumber) continue;
        NSDictionary *bounds=info[(id)kCGWindowBounds];
        if (bounds) [candidates addObject:@{ @"number":info[(id)kCGWindowNumber] ?: @0,
            @"layer":info[(id)kCGWindowLayer] ?: @0, @"bounds":bounds }];
        if (bounds && (!best || [bounds[@"Height"] doubleValue] < [best[@"Height"] doubleValue])) best=bounds;
    }
    self.menuCandidates=candidates;
    if (best) {
        self.menuBounds=@{ @"x":best[@"X"], @"y":best[@"Y"], @"width":best[@"Width"], @"height":best[@"Height"] };
        [self writeStatus];
    }
    if (windows) CFRelease(windows);
}
- (void)showMenu {
    if (self.menuOpen) return;
    self.showMenuEnteredAt=NSDate.timeIntervalSinceReferenceDate;
    self.frontPIDAtShowMenuEntry=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSMenu *root=[[NSMenu alloc] initWithTitle:@"Fixture menu"];
    for (NSUInteger i=0; i<3; i++) {
        NSMenuItem *safe=[[NSMenuItem alloc] initWithTitle:@"No action" action:nil keyEquivalent:@""];
        safe.enabled=NO; [root addItem:safe]; [safe release];
    }
    NSMenuItem *more=[[NSMenuItem alloc] initWithTitle:@"More" action:nil keyEquivalent:@""];
    NSMenu *submenu=[[NSMenu alloc] initWithTitle:@"More"];
    submenu.delegate=self;
    NSMenuItem *safe=[[NSMenuItem alloc] initWithTitle:@"No action" action:nil keyEquivalent:@""];
    safe.enabled=NO; [submenu addItem:safe]; [safe release];
    more.submenu=submenu; [submenu release]; self.submenuItem=more; [root addItem:more]; [more release];
    for (NSUInteger i=0; i<3; i++) {
        NSMenuItem *safe=[[NSMenuItem alloc] initWithTitle:@"No action" action:nil keyEquivalent:@""];
        safe.enabled=NO; [root addItem:safe]; [safe release];
    }
    root.delegate=self; self.menu=root; [root release];
    self.menuOpen=YES; self.submenuOpen=NO; self.menuBounds=nil; self.menuCandidates=nil; self.highlightedTitle=nil; [self writeStatus];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{ [self sampleMenuBounds]; });
    [self.menu popUpMenuPositioningItem:self.menu.itemArray.firstObject atLocation:NSMakePoint(60,100) inView:self.window.contentView];
    self.menuOpen=NO; self.submenuOpen=NO; self.menu=nil; self.submenuItem=nil; self.menuBounds=nil; self.menuCandidates=nil; [self writeStatus];
}
- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.menu) {
        self.menuWillOpenAt=NSDate.timeIntervalSinceReferenceDate;
        [self.submenuItem.submenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(300,100) inView:self.window.contentView];
    } else self.submenuOpen=YES;
    [self writeStatus];
}
- (void)menuDidClose:(NSMenu *)menu { if (menu != self.menu) self.submenuOpen=NO; [self writeStatus]; }
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item { if (menu == self.menu) self.highlightedTitle=item.title; [self writeStatus]; }
- (void)showPopupHidden:(BOOL)hidden {
    if (!self.popup) {
        // Leave the owned target's display-centre hover point uncovered.
        // A partially offscreen popup still has a real on-screen surface.
        NSRect screen=NSScreen.screens.firstObject.frame;
        self.popup=[[[NSPanel alloc] initWithContentRect:NSMakeRect(NSMinX(screen)-450,NSMinY(screen)+100,1000,850)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO] autorelease];
        self.popup.level=NSPopUpMenuWindowLevel; self.popup.opaque=NO; self.popup.backgroundColor=[NSColor colorWithWhite:.12 alpha:.96];
        self.popup.hidesOnDeactivate=NO; self.popup.title=@"Tana2D popup fixture";
        NSTextField *label=[NSTextField labelWithString:@"Large transient popup fixture — no actions"];
        label.frame=NSMakeRect(36,780,760,32); label.font=[NSFont systemFontOfSize:22]; label.textColor=NSColor.whiteColor;
        [self.popup.contentView addSubview:label];
    }
    self.popup.alphaValue=hidden?0:1; [self.popup orderFrontRegardless]; [self writeStatus];
}
- (void)closePopup { [self.popup orderOut:nil]; self.popup=nil; [self writeStatus]; }
- (void)command:(NSNotification *)note {
    NSDictionary *info=note.userInfo;
    if ([info[@"pid"] intValue] != NSProcessInfo.processInfo.processIdentifier) return;
    NSString *command=info[@"command"];
    if ([command isEqual:@"open"]) dispatch_async(dispatch_get_main_queue(), ^{ [self showMenu]; });
    if ([command isEqual:@"open-delayed"]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{ [self showMenu]; });
    if ([command isEqual:@"popup-open"]) dispatch_async(dispatch_get_main_queue(), ^{ [self showPopupHidden:NO]; });
    if ([command isEqual:@"popup-alpha-zero"]) dispatch_async(dispatch_get_main_queue(), ^{ [self showPopupHidden:YES]; });
    if ([command isEqual:@"popup-close"]) dispatch_async(dispatch_get_main_queue(), ^{ [self closePopup]; });
    if ([command isEqual:@"quit"]) [NSApp terminate:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.window=[[[NSWindow alloc] initWithContentRect:NSMakeRect(180,180,460,300)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.window.title=@"Tana2D Menu Fixture";
    NSTextField *label=[NSTextField labelWithString:@"Native menu focus fixture"];
    label.frame=NSMakeRect(35,125,320,32); label.font=[NSFont systemFontOfSize:22]; [self.window.contentView addSubview:label];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(command:) name:HWMMenuFixtureNotification object:nil];
    [self writeStatus];
    NSTimer *timer=[NSTimer timerWithTimeInterval:.03 repeats:YES block:^(NSTimer *unused) { (void)unused; [self sampleMenuBounds]; [self writeStatus]; }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
@end

static void post_command(pid_t pid, NSString *command) {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:HWMMenuFixtureNotification object:nil
        userInfo:@{ @"pid":@(pid), @"command":command } deliverImmediately:YES];
}
static void post_move(CGFloat x, CGFloat y) {
    if (CGWarpMouseCursorPosition(CGPointMake(x,y))!=kCGErrorSuccess) exit(1);
    CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointMake(x,y),kCGMouseButtonLeft);
    stamp_event(event); CGEventPost(kCGHIDEventTap,event); CFRelease(event);
}
static void post_click(CGFloat x, CGFloat y) {
    if (CGWarpMouseCursorPosition(CGPointMake(x,y))!=kCGErrorSuccess) exit(1);
    CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,CGPointMake(x,y),kCGMouseButtonLeft);
    CGEventRef up=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,CGPointMake(x,y),kCGMouseButtonLeft);
    stamp_event(down); CGEventPost(kCGHIDEventTap,down); usleep(2000); stamp_event(up); CGEventPost(kCGHIDEventTap,up); CFRelease(up); CFRelease(down);
}
static void post_escape(void) {
    CGEventRef down=CGEventCreateKeyboardEvent(NULL,53,true), up=CGEventCreateKeyboardEvent(NULL,53,false);
    stamp_event(down); CGEventPost(kCGHIDEventTap,down); stamp_event(up); CGEventPost(kCGHIDEventTap,up); CFRelease(up); CFRelease(down);
}
static void post_key(CGKeyCode code) {
    CGEventRef down=CGEventCreateKeyboardEvent(NULL,code,true), up=CGEventCreateKeyboardEvent(NULL,code,false);
    stamp_event(down); CGEventPost(kCGHIDEventTap,down); stamp_event(up); CGEventPost(kCGHIDEventTap,up); CFRelease(up); CFRelease(down);
}
static void post_submenu(void) { post_key(125); post_key(124); }

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc==2 && !strcmp(argv[1],"pointer")) {
        CGEventRef event=CGEventCreate(NULL); if (!event) return 1;
        CGPoint point=CGEventGetLocation(event); CFRelease(event);
        printf("{\"x\":%.17g,\"y\":%.17g}\n",point.x,point.y); return 0;
    }
    if (argc==4 && !strcmp(argv[1],"warp")) {
        CGPoint point=CGPointMake(atof(argv[2]),atof(argv[3]));
        if (!isfinite(point.x) || !isfinite(point.y)) return 64;
        return CGWarpMouseCursorPosition(point)==kCGErrorSuccess?0:1;
    }
    if (argc==4 && !strcmp(argv[1],"command")) { post_command((pid_t)atoi(argv[2]),[NSString stringWithUTF8String:argv[3]]); return 0; }
    if (argc==4 && !strcmp(argv[1],"move")) { post_move(atof(argv[2]),atof(argv[3])); return 0; }
    if (argc==4 && !strcmp(argv[1],"click")) { post_click(atof(argv[2]),atof(argv[3])); return 0; }
    if (argc==2 && !strcmp(argv[1],"escape")) { post_escape(); return 0; }
    if (argc==2 && !strcmp(argv[1],"submenu")) { post_submenu(); return 0; }
    if (argc!=2) { fprintf(stderr,"usage: %s STATUS_PATH | command PID open|quit | move X Y | click X Y | submenu | escape\n",argv[0]); return 64; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    HWMMenuFixture *fixture=[HWMMenuFixture new]; fixture.statusPath=@(argv[1]); NSApp.delegate=fixture; [NSApp run]; [fixture release];
} return 0; }
