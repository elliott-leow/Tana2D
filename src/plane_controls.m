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
    const char *action=sender.tag==1 ? "fit-all" : sender.tag==2 ? "fit-focused" : "actual-size";
    horizontal_plane_action(action);
}
- (void)dealloc { [_panel release]; [_actualSize release]; [super dealloc]; }
@end

static Tana2DCameraControls *hwm_camera_controls;
static _Atomic bool hwm_camera_controls_visible, hwm_camera_controls_pending;
static _Atomic double hwm_camera_controls_scale=1;

static void hwm_plane_controls_apply(void)
{
    if(!hwm_camera_controls) return;
    double scale=atomic_load(&hwm_camera_controls_scale);
    NSString *title=[NSString stringWithFormat:@"%.0f%%",100*scale];
    hwm_camera_controls.actualSize.title=title;
    hwm_camera_controls.actualSize.accessibilityLabel=[NSString stringWithFormat:@"Zoom %@. Reset to actual size",title];
    if(atomic_load(&hwm_camera_controls_visible)) [hwm_camera_controls.panel orderFront:nil];
    else [hwm_camera_controls.panel orderOut:nil];
}

static void hwm_plane_controls_begin(void)
{
    if(hwm_camera_controls) return;
    hwm_camera_controls=[Tana2DCameraControls new];
    NSRect screen=NSScreen.mainScreen.visibleFrame;
    NSRect frame=NSMakeRect(NSMidX(screen)-150,NSMinY(screen)+18,300,44);
    Tana2DCameraPanel *panel=[[[Tana2DCameraPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO] autorelease];
    panel.title=@"Tana2D camera";
    panel.level=NSFloatingWindowLevel;
    panel.opaque=NO; panel.backgroundColor=NSColor.clearColor; panel.hasShadow=YES;
    panel.hidesOnDeactivate=NO; panel.movableByWindowBackground=YES;
    panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary;
    panel.releasedWhenClosed=NO;
    NSVisualEffectView *background=[[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,300,44)] autorelease];
    background.material=NSVisualEffectMaterialHUDWindow;
    background.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    background.state=NSVisualEffectStateActive;
    background.wantsLayer=YES; background.layer.cornerRadius=12;
    panel.contentView=background;
    NSArray *titles=@[@"Fit all",@"Fit window",@"100%"];
    NSArray *help=@[@"Fit every window on the plane (Control + Up)",@"Fit the focused window to the screen",@"Reset the camera to actual size"];
    for(NSUInteger i=0;i<titles.count;i++) {
        NSButton *button=[NSButton buttonWithTitle:titles[i] target:hwm_camera_controls action:@selector(performCameraAction:)];
        button.frame=NSMakeRect(8+i*96,7,92,30);
        button.bezelStyle=NSBezelStyleRounded;
        button.tag=(NSInteger)i+1; button.toolTip=help[i]; button.accessibilityLabel=help[i];
        [background addSubview:button];
        if(i==2) hwm_camera_controls.actualSize=button;
    }
    hwm_camera_controls.panel=panel;
    hwm_plane_controls_apply();
}

static void hwm_plane_controls_update(bool visible,double scale)
{
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
