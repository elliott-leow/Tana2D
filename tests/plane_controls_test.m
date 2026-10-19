#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <string.h>
static const char *last_action;
void horizontal_plane_action(const char *name) { last_action=name; }
#include "../src/plane_controls.m"
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    hwm_plane_controls_begin();
    assert(hwm_camera_controls);
    assert(!hwm_camera_controls.panel.visible);
    assert(!hwm_plane_controls_hit(CGPointMake(100,100)));
    NSRect visible=NSScreen.mainScreen.visibleFrame;
    double screenHeight=NSScreen.screens.firstObject.frame.size.height;
    assert(hwm_zoom_workspace_contains(CGPointMake(NSMidX(visible),screenHeight-NSMidY(visible))));
    assert(!hwm_zoom_workspace_contains(CGPointMake(-100,-100)));
    hwm_zoom_shield_update(false);
    assert(!hwm_zoom_shield.visible && !hwm_zoom_shield.canBecomeKeyWindow);
    assert(!hwm_camera_controls.panel.canBecomeKeyWindow);
    NSArray *buttons=hwm_camera_controls.panel.contentView.subviews;
    assert(buttons.count==2);
    const char *actions[]={"fit-all","actual-size"};
    for(NSUInteger i=0;i<buttons.count;i++) {
        NSButton *button=buttons[i];
        assert(button.accessibilityLabel.length>0);
        [button performClick:nil];
        assert(last_action && !strcmp(last_action,actions[i]));
    }
    /* A hidden panel is not relabelled at every percent of a pinch; it
     * shows the current zoom whenever it is shown. */
    hwm_plane_controls_update(false,.42);
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:.05];
    while(until.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:until];
    assert(!hwm_camera_controls.panel.visible);
    hwm_plane_controls_update(true,.42);
    until=[NSDate dateWithTimeIntervalSinceNow:.05];
    while(until.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:until];
    assert([hwm_camera_controls.actualSize.title isEqual:@"42%"] && hwm_camera_controls.panel.visible);
    hwm_plane_controls_update(true,NAN);
    until=[NSDate dateWithTimeIntervalSinceNow:.05];
    while(until.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:until];
    assert([hwm_camera_controls.actualSize.title isEqual:@"100%"]);
    hwm_plane_controls_update(false,1);
    until=[NSDate dateWithTimeIntervalSinceNow:.05];
    while(until.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:until];
    assert(!hwm_camera_controls.panel.visible);
    puts("plane controls tests passed");
} return 0; }
