/* Native accessibility contract for custom-drawn command-palette rows. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <stdio.h>

#include "../src/strip_hud.m"

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        (void)hwm_hud; /* The integrated build calls this private helper. */
        TanaPalette *palette=[TanaPalette shared];
        __block NSString *ran=nil;
        palette.run=^(NSString *name) { ran=[name copy]; };
        palette.list=[[[TanaPaletteList alloc] initWithFrame:NSMakeRect(0,0,400,200)] autorelease];
        palette.list.owner=palette;
        palette.list.rows=@[@[@"focus-left",@"Focus left",@"Left Arrow"],@[@"overview",@"Window overview",@"Space"]];
        palette.list.selected=1;

        assert([[palette.list accessibilityRole] isEqual:NSAccessibilityListRole]);
        assert([[palette.list accessibilityLabel] isEqual:@"Tana2D commands"]);
        NSArray *rows=[palette.list accessibilityChildren];
        assert(rows.count==2U);
        TanaPaletteRowAccessibilityElement *row=rows[1];
        assert([[row accessibilityRole] isEqual:NSAccessibilityButtonRole]);
        assert([[row accessibilityLabel] isEqual:@"Window overview, Space"]);
        assert([row accessibilitySelected]);
        assert([row accessibilityPerformPress]);
        assert([ran isEqual:@"overview"]);
        /* A VoiceOver client can retain an old element while filtering replaces rows. */
        palette.list.rows=@[@[@"focus-right",@"Focus right",@"Right Arrow"]];
        assert([[row accessibilityLabel] isEqual:@""]);
        assert([palette.list accessibilityChildren].count==1U);
        [ran release];
        puts("accessibility tests passed");
    }
    return 0;
}
