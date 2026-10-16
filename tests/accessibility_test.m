/* Native accessibility contract for custom-drawn command-palette rows. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <stdio.h>

#include "../src/strip_hud.m"

static void test_palette_toggle_filters_commands(void)
{
    TanaPalette *palette=[TanaPalette new];
    NSArray *commands=@[@[@"fit-all",@"Fit all windows",@"Control Return"],
                        @[@"focus-left",@"Focus left",@"Left Arrow"],
                        @[@"overview",@"Window overview",@"Space"]];
    [palette toggleWithCommands:commands run:^(NSString *name) { (void)name; }];
    assert(palette.list.rows.count==3U);
    assert([palette.list.rows[0][0] isEqual:@"fit-all"]);

    palette.field.stringValue=@"overview";
    [palette controlTextDidChange:[NSNotification notificationWithName:@"test" object:palette.field]];
    assert(palette.list.rows.count==1U);
    assert([palette.list.rows[0][0] isEqual:@"overview"]);
    [palette close];
    [palette release];
}

static void test_palette_match_highlight_and_recent(void)
{
    NSMutableIndexSet *matched=[NSMutableIndexSet indexSet];
    assert(hwm_fuzzy_match(@"mvl",@"Move left",matched)>0);
    assert(matched.count==3U && [matched containsIndex:0] && [matched containsIndex:2] && [matched containsIndex:5]);
    assert(hwm_fuzzy_match(@"zz",@"Move left",matched)<0 && matched.count==0U);

    TanaPalette *palette=[TanaPalette new];
    NSArray *commands=@[@[@"fit-all",@"Fit all windows",@"Control Return"],
                        @[@"focus-left",@"Focus left",@"Left Arrow"],
                        @[@"overview",@"Window overview",@"Space"]];
    __block NSString *ran=nil;
    [palette toggleWithCommands:commands run:^(NSString *name) { ran=name; }];
    [palette activate:2];
    assert([ran isEqual:@"overview"]);
    assert(!palette.panel.visible); // Closed before the command ran.
    [palette toggleWithCommands:commands run:^(NSString *name) { (void)name; }];
    assert(palette.panel.visible);
    assert([palette.list.rows[0][0] isEqual:@"overview"]);
    assert([palette.list.rows[1][0] isEqual:@"fit-all"]);
    assert(!palette.highlight.hidden);
    /* Typing still ranks by match, not by recency. */
    palette.field.stringValue=@"focus";
    [palette controlTextDidChange:[NSNotification notificationWithName:@"test" object:palette.field]];
    assert([palette.list.rows[0][0] isEqual:@"focus-left"]);
    [palette close];
    [palette release];
}

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
        test_palette_toggle_filters_commands();
        test_palette_match_highlight_and_recent();
        puts("accessibility tests passed");
    }
    return 0;
}
