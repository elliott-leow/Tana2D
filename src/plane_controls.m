/* Native camera controls. AppKit stays on the main thread; model actions are
 * serialized by horizontal_plane_action on the window-manager event loop. */
#import <Cocoa/Cocoa.h>
#include <stdatomic.h>
#include <math.h>

void horizontal_plane_action(const char *name);

@interface Tana2DCameraPanel : NSPanel
@end
@implementation Tana2DCameraPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface Tana2DCameraControls : NSObject
@property(nonatomic,retain) Tana2DCameraPanel *panel;
@property(nonatomic,retain) NSButton *actualSize;
- (void)performCameraAction:(NSButton *)sender;
@end
@implementation Tana2DCameraControls
- (void)performCameraAction:(NSButton *)sender
{
    const char *action=sender.tag==1 ? "fit-all" : "actual-size";
    horizontal_plane_action(action);
}
- (void)dealloc { [_panel release]; [_actualSize release]; [super dealloc]; }
@end

static Tana2DCameraControls *hwm_camera_controls;
static Tana2DCameraPanel *hwm_zoom_shield;
static _Atomic bool hwm_zoom_shield_requested;
static _Atomic int hwm_zoom_shield_mode;
static _Atomic bool hwm_camera_controls_visible, hwm_camera_controls_pending;
static _Atomic double hwm_camera_controls_scale=1;

static void hwm_plane_controls_apply(void)
{
    if(!hwm_camera_controls) return;
    double scale=atomic_load(&hwm_camera_controls_scale);
    NSString *title=[NSString stringWithFormat:@"%.0f%%",100*scale];
    hwm_camera_controls.actualSize.title=title;
    hwm_camera_controls.actualSize.accessibilityLabel=[NSString stringWithFormat:@"Workspace zoom %@. Return to window at actual size",title];
    if(atomic_load(&hwm_camera_controls_visible)) [hwm_camera_controls.panel orderFront:nil];
    else [hwm_camera_controls.panel orderOut:nil];
}

static void hwm_plane_controls_begin(void)
{
    if(hwm_camera_controls) return;
    hwm_camera_controls=[Tana2DCameraControls new];
    NSRect screen=NSScreen.mainScreen.visibleFrame;
    NSRect frame=NSMakeRect(NSMidX(screen)-102,NSMinY(screen)+18,204,44);
    Tana2DCameraPanel *panel=[[[Tana2DCameraPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO] autorelease];
    panel.title=@"Tana2D camera";
    panel.level=NSFloatingWindowLevel;
    panel.opaque=NO; panel.backgroundColor=NSColor.clearColor; panel.hasShadow=YES;
    panel.hidesOnDeactivate=NO; panel.movableByWindowBackground=YES;
    panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary;
    panel.releasedWhenClosed=NO;
    NSVisualEffectView *background=[[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,204,44)] autorelease];
    background.material=NSVisualEffectMaterialHUDWindow;
    background.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    background.state=NSVisualEffectStateActive;
    background.wantsLayer=YES; background.layer.cornerRadius=12;
    panel.contentView=background;
    NSArray *titles=@[@"Workspace",@"100%"];
    NSArray *help=@[@"Show the workspace (Control + Up)",@"Return to the focused window at actual size (Escape)"];
    for(NSUInteger i=0;i<titles.count;i++) {
        NSButton *button=[NSButton buttonWithTitle:titles[i] target:hwm_camera_controls action:@selector(performCameraAction:)];
        button.frame=NSMakeRect(8+i*96,7,92,30);
        button.bezelStyle=NSBezelStyleRounded;
        button.tag=(NSInteger)i+1; button.toolTip=help[i]; button.accessibilityLabel=help[i];
        [background addSubview:button];
        if(i==1) hwm_camera_controls.actualSize=button;
    }
    hwm_camera_controls.panel=panel;
    hwm_zoom_shield=[[Tana2DCameraPanel alloc]initWithContentRect:NSScreen.mainScreen.visibleFrame
        styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    hwm_zoom_shield.title=@"Tana2D workspace";
    hwm_zoom_shield.level=NSFloatingWindowLevel-1;
    hwm_zoom_shield.backgroundColor=[NSColor.blackColor colorWithAlphaComponent:.02];
    hwm_zoom_shield.opaque=NO; hwm_zoom_shield.hasShadow=NO;
    hwm_zoom_shield.hidesOnDeactivate=NO; hwm_zoom_shield.acceptsMouseMovedEvents=YES;
    hwm_zoom_shield.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary;
    hwm_zoom_shield.releasedWhenClosed=NO;
    hwm_plane_controls_apply();
}

/* Let every physical motion reach WindowServer unchanged. This native input
 * surface receives AppKit tracking instead of the transformed app below it. */
static void hwm_zoom_shield_update(bool visible)
{
    atomic_store(&hwm_zoom_shield_requested,visible);
    if(atomic_exchange(&hwm_zoom_shield_mode,visible?1:0)==(visible?1:0)) return;
    void (^apply)(void)=^{
        if(visible) {
            if(!hwm_zoom_shield.visible) {
                [hwm_zoom_shield setFrame:NSScreen.mainScreen.visibleFrame display:NO];
                [hwm_zoom_shield orderFront:nil];
            }
        } else [hwm_zoom_shield orderOut:nil];
    };
    if(NSThread.isMainThread) apply();
    else dispatch_sync(dispatch_get_main_queue(),apply);
}

static bool hwm_plane_controls_hit(CGPoint point)
{
    if(!hwm_camera_controls.panel.visible) return false;
    NSRect frame=hwm_camera_controls.panel.frame;
    double height=NSScreen.screens.firstObject.frame.size.height;
    return NSPointInRect(NSMakePoint(point.x,height-point.y),frame);
}

static bool hwm_zoom_workspace_contains(CGPoint point)
{
    double height=NSScreen.screens.firstObject.frame.size.height;
    return NSPointInRect(NSMakePoint(point.x,height-point.y),NSScreen.mainScreen.visibleFrame);
}

static void hwm_plane_controls_update(bool visible,double scale)
{
    if(!visible) hwm_zoom_shield_update(false);
    if(!isfinite(scale) || scale<=0) scale=1;
    bool previous=atomic_exchange(&hwm_camera_controls_visible,visible);
    double oldScale=atomic_exchange(&hwm_camera_controls_scale,scale);
    if(previous==visible && lround(oldScale*100)==lround(scale*100)) return;
    if(atomic_exchange(&hwm_camera_controls_pending,true)) return;
    dispatch_async(dispatch_get_main_queue(),^{
        atomic_store(&hwm_camera_controls_pending,false);
        hwm_plane_controls_apply();
    });
}
