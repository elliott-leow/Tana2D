/* Transient HUD and the command palette. AppKit is confined to the main queue. */
static bool hwm_hud_enabled=true;

static BOOL hwm_accessibility_high_contrast(void)
{
    return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast];
}
static BOOL hwm_accessibility_reduce_transparency(void)
{
    return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceTransparency];
}

@interface TanaKeyPanel : NSPanel
@end
@implementation TanaKeyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSScreen *hwm_pointer_screen(void)
{
    NSPoint p=[NSEvent mouseLocation];
    for(NSScreen *screen in [NSScreen screens]) if(NSPointInRect(p,screen.frame)) return screen;
    return [NSScreen mainScreen] ?: [[NSScreen screens] firstObject];
}

static NSVisualEffectView *hwm_glass(NSRect frame,CGFloat radius)
{
    NSVisualEffectView *glass=[[[NSVisualEffectView alloc] initWithFrame:frame] autorelease];
    BOOL opaque=hwm_accessibility_reduce_transparency();
    glass.appearance=[NSAppearance appearanceNamed:hwm_accessibility_high_contrast() ? NSAppearanceNameAccessibilityHighContrastDarkAqua : NSAppearanceNameDarkAqua];

    glass.material=opaque ? NSVisualEffectMaterialWindowBackground : NSVisualEffectMaterialHUDWindow;
    glass.blendingMode=opaque ? NSVisualEffectBlendingModeWithinWindow : NSVisualEffectBlendingModeBehindWindow;
    glass.state=NSVisualEffectStateActive; glass.wantsLayer=YES;
    glass.layer.cornerRadius=radius; glass.layer.masksToBounds=YES;
    if(opaque) glass.layer.backgroundColor=[NSColor colorWithCalibratedWhite:.12 alpha:1].CGColor;
    glass.layer.borderWidth=hwm_accessibility_high_contrast() ? 2 : 1;
    glass.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:hwm_accessibility_high_contrast() ? .72 : .14].CGColor;
    glass.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    return glass;
}

/* One short line near the bottom of the screen: width presets, pause state,
 * configuration results. It never takes focus or mouse input. */
@interface TanaHUD : NSObject
@property(nonatomic,retain) NSPanel *panel;
@property(nonatomic,retain) NSTextField *label;
@property(nonatomic) uint64_t generation;
+ (instancetype)shared;
- (void)show:(NSString *)text;
@end
@implementation TanaHUD
+ (instancetype)shared { static TanaHUD *instance; if(!instance) instance=[TanaHUD new]; return instance; }
- (void)show:(NSString *)text
{
    if(!text.length) return;
    if(!self.panel) {
        self.panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,200,40) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO] autorelease];
        self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES;
        self.panel.ignoresMouseEvents=YES; self.panel.level=NSStatusWindowLevel;
        self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *glass=hwm_glass(NSMakeRect(0,0,200,40),14);
        self.panel.contentView=glass;
        self.label=[NSTextField labelWithString:@""];
        self.label.font=[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]; self.label.textColor=NSColor.whiteColor;
        self.label.alignment=NSTextAlignmentCenter; self.label.lineBreakMode=NSLineBreakByTruncatingMiddle;
        [glass addSubview:self.label];
    }
    NSScreen *screen=hwm_pointer_screen(); NSRect visible=screen.visibleFrame;
    self.label.stringValue=text;
    CGFloat width=fmax(1,fmin(fmax(1,visible.size.width-24),ceil([self.label.attributedStringValue size].width)+44));
    NSRect frame=NSMakeRect(NSMidX(visible)-width/2,NSMinY(visible)+56,width,40);
    self.label.frame=NSMakeRect(16,10,width-32,20);
    BOOL reduce=[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    BOOL visibleNow=self.panel.visible && self.panel.alphaValue>.05;
    if(!visibleNow) { [self.panel setFrame:(reduce ? frame : NSOffsetRect(frame,0,-10)) display:YES]; self.panel.alphaValue=0; }
    [self.panel orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration=reduce ? 0 : .18; context.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
        [[self.panel animator] setFrame:frame display:YES]; [[self.panel animator] setAlphaValue:1];
    } completionHandler:nil];
    uint64_t generation=++self.generation;
    double hold=fmin(4,1.3+text.length*.03);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(hold*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(self.generation!=generation) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration=reduce ? 0 : .22; [[self.panel animator] setAlphaValue:0];
        } completionHandler:^{ if(self.generation==generation) [self.panel orderOut:nil]; }];
    });
}
@end

static void hwm_hud(NSString *text)
{
    if(!hwm_hud_enabled || !text.length) return;
    NSString *copy=[text copy];
    dispatch_async(dispatch_get_main_queue(),^{ [[TanaHUD shared] show:copy]; [copy release]; });
}

/* Subsequence match. Higher is better; negative means no match. Consecutive
 * letters and word starts are rewarded so "mvl" finds "Move left". */
static NSInteger hwm_fuzzy_score(NSString *query,NSString *candidate)
{
    NSString *q=query.lowercaseString,*c=candidate.lowercaseString;
    if(!q.length) return 0;
    NSInteger score=0; NSUInteger at=0; NSInteger last=-2;
    for(NSUInteger i=0;i<q.length;i++) {
        unichar wanted=[q characterAtIndex:i]; if(wanted==' ') continue;
        BOOL found=NO;
        for(;at<c.length;at++) if([c characterAtIndex:at]==wanted) {
            score+=10;
            if((NSInteger)at==last+1) score+=8;
            if(at==0 || [c characterAtIndex:at-1]==' ' || [c characterAtIndex:at-1]=='/') score+=6;
            last=(NSInteger)at; at++; found=YES; break;
        }
        if(!found) return -1;
    }
    return score-(NSInteger)c.length/4;
}

@class TanaPalette;
@class TanaPaletteList;
@interface TanaPaletteRowAccessibilityElement : NSAccessibilityElement
@property(nonatomic,assign) TanaPaletteList *list;
@property(nonatomic) NSInteger row;
@end
@interface TanaPaletteList : NSView
@property(nonatomic,retain) NSArray *rows; /* @[name,title,hint] */
@property(nonatomic,retain) NSArray *axElements;
@property(nonatomic) NSInteger selected;
@property(nonatomic,assign) TanaPalette *owner;
- (NSInteger)first;
@end

@interface TanaPalette : NSObject <NSTextFieldDelegate>
@property(nonatomic,retain) TanaKeyPanel *panel;
@property(nonatomic,retain) NSTextField *field;
@property(nonatomic,retain) TanaPaletteList *list;
@property(nonatomic,retain) NSArray *commands; /* @[name,title,hint] */
@property(nonatomic,copy) void (^run)(NSString *name);
+ (instancetype)shared;
- (void)toggleWithCommands:(NSArray *)commands run:(void (^)(NSString *name))run;
- (void)activate:(NSInteger)row;
- (void)close;
@end

static const CGFloat TanaPaletteRow=34, TanaPaletteWidth=560, TanaPaletteHeader=56;
static const NSInteger TanaPaletteVisible=9;

@implementation TanaPaletteRowAccessibilityElement
- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel
{
    if(self.row<0 || self.row>=(NSInteger)self.list.rows.count) return @"";
    NSArray *entry=self.list.rows[self.row];
    NSString *title=entry.count>1 ? entry[1] : @"Command";
    NSString *hint=entry.count>2 ? entry[2] : @"";
    return hint.length ? [NSString stringWithFormat:@"%@, %@",title,hint] : title;
}
- (NSString *)accessibilityHelp { return @"Runs this Tana2D command"; }
- (id)accessibilityParent { return self.list; }
- (NSRect)accessibilityFrame
{
    NSInteger first=[self.list first];
    if(self.row<first || self.row>=first+TanaPaletteVisible) return NSZeroRect;
    NSRect local=NSMakeRect(8,(self.row-first)*TanaPaletteRow,MAX(1,self.list.bounds.size.width-16),TanaPaletteRow-2);
    return [self.list.window convertRectToScreen:[self.list convertRect:local toView:nil]];
}
- (BOOL)accessibilitySelected { return self.row==self.list.selected; }
- (BOOL)accessibilityPerformPress
{
    if(self.row<0 || self.row>=(NSInteger)self.list.rows.count) return NO;
    [self.list.owner activate:self.row]; return YES;
}
@end

@implementation TanaPaletteList
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityRole { return NSAccessibilityListRole; }
- (NSString *)accessibilityLabel { return @"Tana2D commands"; }
- (NSArray *)accessibilityChildren
{
    if(!self.axElements || self.axElements.count!=self.rows.count) {
        NSMutableArray *children=[NSMutableArray arrayWithCapacity:self.rows.count];
        for(NSInteger row=0;row<(NSInteger)self.rows.count;row++) {
            TanaPaletteRowAccessibilityElement *element=[[[TanaPaletteRowAccessibilityElement alloc] init] autorelease];
            element.list=self; element.row=row; [children addObject:element];
        }
        self.axElements=children;
    }
    return self.axElements;
}
- (NSArray *)accessibilitySelectedChildren
{
    if(self.selected<0 || self.selected>=(NSInteger)self.rows.count) return @[];
    for(TanaPaletteRowAccessibilityElement *element in self.accessibilityChildren)
        if(element.row==self.selected) return @[element];
    return @[];
}
- (void)setRows:(NSArray *)rows { [_rows release]; _rows=[rows retain]; self.axElements=nil; [self setNeedsDisplay:YES]; NSAccessibilityPostNotification(self,NSAccessibilityLayoutChangedNotification); }
- (void)setSelected:(NSInteger)selected
{
    if(_selected==selected) return;
    _selected=selected; [self setNeedsDisplay:YES];
    NSAccessibilityPostNotification(self,NSAccessibilitySelectedChildrenChangedNotification);
    NSAccessibilityPostNotification(self,NSAccessibilityLayoutChangedNotification);
}
- (NSInteger)first { return MAX(0,MIN(self.selected-TanaPaletteVisible/2,(NSInteger)self.rows.count-TanaPaletteVisible)); }
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    NSDictionary *title=@{NSFontAttributeName:[NSFont systemFontOfSize:14],NSForegroundColorAttributeName:NSColor.whiteColor};
    NSDictionary *hint=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:1 alpha:hwm_accessibility_high_contrast() ? .9 : .65]};
    NSInteger first=[self first];
    for(NSInteger i=first;i<(NSInteger)self.rows.count && i<first+TanaPaletteVisible;i++) {
        NSRect row=NSMakeRect(8,(i-first)*TanaPaletteRow,self.bounds.size.width-16,TanaPaletteRow-2);
        if(i==self.selected) {
            [[NSColor colorWithCalibratedRed:.36 green:.66 blue:1 alpha:hwm_accessibility_high_contrast() ? .62 : .32] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        }
        NSArray *entry=self.rows[i];
        [entry[1] drawAtPoint:NSMakePoint(NSMinX(row)+12,NSMinY(row)+7) withAttributes:title];
        NSSize size=[entry[2] sizeWithAttributes:hint];
        [entry[2] drawAtPoint:NSMakePoint(NSMaxX(row)-12-size.width,NSMinY(row)+9) withAttributes:hint];
    }
    if(!self.rows.count) [@"No matching command" drawAtPoint:NSMakePoint(20,8) withAttributes:hint];
}
- (void)mouseDown:(NSEvent *)event
{
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row=[self first]+(NSInteger)floor(p.y/TanaPaletteRow);
    if(row>=0 && row<(NSInteger)self.rows.count) [self.owner activate:row];
}
@end

@implementation TanaPalette
+ (instancetype)shared { static TanaPalette *instance; if(!instance) instance=[TanaPalette new]; return instance; }
- (void)build
{
    self.panel=[[[TanaKeyPanel alloc] initWithContentRect:NSMakeRect(0,0,TanaPaletteWidth,TanaPaletteHeader) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES;
    self.panel.level=NSStatusWindowLevel+2; self.panel.floatingPanel=YES; self.panel.hidesOnDeactivate=NO;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle;
    NSVisualEffectView *glass=hwm_glass(NSMakeRect(0,0,TanaPaletteWidth,TanaPaletteHeader),16);
    self.panel.contentView=glass;
    self.field=[[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    self.field.bordered=NO; self.field.drawsBackground=NO; self.field.focusRingType=NSFocusRingTypeNone;
    self.field.font=[NSFont systemFontOfSize:20 weight:NSFontWeightLight]; self.field.textColor=NSColor.whiteColor;
    self.field.placeholderString=@"Run a Tana2D command…"; self.field.delegate=self;
    self.field.accessibilityLabel=@"Search Tana2D commands";
    self.field.accessibilityHelp=@"Type to filter commands. Use Up and Down Arrow to choose a command, then Return to run it.";
    self.field.autoresizingMask=NSViewMinYMargin|NSViewWidthSizable;
    [glass addSubview:self.field];
    self.list=[[[TanaPaletteList alloc] initWithFrame:NSZeroRect] autorelease];
    self.list.owner=self; self.list.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [glass addSubview:self.list];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:self.panel queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { (void)n; [self close]; }];
}
- (void)layoutAnimated:(BOOL)animated
{
    NSInteger rows=MIN(TanaPaletteVisible,MAX(1,(NSInteger)self.list.rows.count));
    CGFloat height=TanaPaletteHeader+rows*TanaPaletteRow+8;
    NSRect visible=hwm_pointer_screen().visibleFrame;
    CGFloat width=fmax(1,fmin(TanaPaletteWidth,fmax(1,visible.size.width-24)));
    height=fmin(height,fmax(TanaPaletteHeader,visible.size.height-24));
    CGFloat top=MIN(NSMaxY(visible)-12,NSMaxY(visible)-visible.size.height*.22);
    NSRect frame=NSMakeRect(NSMidX(visible)-width/2,MAX(NSMinY(visible)+12,top-height),width,height);
    if(animated && ![NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration=.14; context.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
            [[self.panel animator] setFrame:frame display:YES];
        } completionHandler:nil];
    } else [self.panel setFrame:frame display:YES];
    self.field.frame=NSMakeRect(20,height-TanaPaletteHeader+14,MAX(1,width-40),28);
    self.list.frame=NSMakeRect(0,4,width,MIN(rows*TanaPaletteRow,MAX(1,height-TanaPaletteHeader-4)));
}
- (void)filter
{
    NSString *query=self.field.stringValue;
    NSMutableArray *scored=[NSMutableArray array];
    for(NSArray *command in self.commands) {
        NSInteger score=MAX(hwm_fuzzy_score(query,command[1]),hwm_fuzzy_score(query,command[0])-2);
        if(score>=0) [scored addObject:@[@(score),command]];
    }
    if(query.length) [scored sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a,NSArray *b) { return [b[0] compare:a[0]]; }];
    self.list.rows=[scored valueForKey:@"lastObject"]; self.list.selected=0;
    NSString *announcement=self.list.rows.count ? [NSString stringWithFormat:@"%ld commands available",(long)self.list.rows.count] : @"No matching commands";
    NSAccessibilityPostNotificationWithUserInfo(self.field,NSAccessibilityAnnouncementRequestedNotification,@{NSAccessibilityAnnouncementKey:announcement,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityLow)});
    [self layoutAnimated:self.panel.visible];
}
- (void)toggleWithCommands:(NSArray *)commands run:(void (^)(NSString *))run
{
    if(self.panel.visible) { [self close]; return; }
    if(!self.panel) [self build];
    self.commands=commands; self.run=run; self.field.stringValue=@"";
    [self filter];
    BOOL reduce=[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    NSRect frame=self.panel.frame;
    if(!reduce) { [self.panel setFrame:NSOffsetRect(frame,0,12) display:YES]; self.panel.alphaValue=0; }
    [self.panel makeKeyAndOrderFront:nil]; [self.panel makeFirstResponder:self.field];
    self.panel.accessibilityLabel=@"Tana2D command palette";
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration=reduce ? 0 : .16; context.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
        [[self.panel animator] setFrame:frame display:YES]; [[self.panel animator] setAlphaValue:1];
    } completionHandler:nil];
}
- (void)close
{
    if(!self.panel.visible) return;
    [self.panel orderOut:nil]; self.run=nil;
}
- (void)activate:(NSInteger)row
{
    if(row<0 || row>=(NSInteger)self.list.rows.count) return;
    NSString *name=[[self.list.rows[row][0] retain] autorelease];
    void (^run)(NSString *)=[[self.run copy] autorelease];
    [self close];
    if(run) run(name);
}
- (void)controlTextDidChange:(NSNotification *)note { (void)note; [self filter]; }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    (void)control; (void)textView;
    NSInteger count=(NSInteger)self.list.rows.count;
    if(command==@selector(moveDown:) || command==@selector(insertTab:)) { if(count) self.list.selected=(self.list.selected+1)%count; return YES; }
    if(command==@selector(moveUp:) || command==@selector(insertBacktab:)) { if(count) self.list.selected=(self.list.selected+count-1)%count; return YES; }
    if(command==@selector(insertNewline:)) { [self activate:self.list.selected]; return YES; }
    if(command==@selector(cancelOperation:)) { [self close]; return YES; }
    return NO;
}
@end
