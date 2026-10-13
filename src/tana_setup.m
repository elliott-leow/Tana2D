/* Standalone setup. No window management runs until every required check passes. */
#import <ServiceManagement/ServiceManagement.h>
#import <CommonCrypto/CommonDigest.h>

#define TANA2D_HELPER_PATH "/Library/PrivilegedHelperTools/dev.tana2d.window-helper"
static NSString *const TanaHelperPath=@TANA2D_HELPER_PATH;

static NSString *tana_shell_quote(NSString *value)
{ return [NSString stringWithFormat:@"'%@'",[value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }

static BOOL tana_backend_ready(void)
{
    struct passwd *pw=getpwuid(getuid());
    if(!pw) return NO;
    char version[256]={0}; uint32_t attributes=0;
    snprintf(g_sa_socket_file,sizeof(g_sa_socket_file),SA_SOCKET_PATH_FMT,pw->pw_name);
    return scripting_addition_request_handshake(version,sizeof(version),&attributes) && !strcmp(version,OSAX_VERSION);
}

static BOOL tana_security_ready(void)
{
    if(!scripting_addition_is_sip_friendly()) return NO;
#ifdef __arm64__
    if(!scripting_addition_is_arm64e_enabled()) return NO;
#endif
    return YES;
}

/* The shared lock remains intentional: two window managers must not manipulate
 * the same windows. Merely inspecting it does not create or acquire a lock. */
static pid_t tana_other_manager(void)
{
    struct passwd *pw=getpwuid(getuid()); if(!pw) return 0;
    char path[1024]; snprintf(path,sizeof(path),"/tmp/yabai_%s.lock",pw->pw_name);
    int fd=open(path,O_RDONLY|O_NOFOLLOW); if(fd<0) return 0;
    struct flock lock={.l_type=F_WRLCK,.l_whence=SEEK_SET,.l_start=0,.l_len=0};
    int result=fcntl(fd,F_GETLK,&lock); close(fd);
    return result==0 && lock.l_type!=F_UNLCK ? lock.l_pid : 0;
}

static int tana_run(NSString *path,NSArray *arguments)
{
    NSTask *task=[[[NSTask alloc] init] autorelease]; task.launchPath=path; task.arguments=arguments;
    task.standardInput=[NSFileHandle fileHandleWithNullDevice];
    task.standardOutput=[NSFileHandle fileHandleWithNullDevice]; task.standardError=[NSFileHandle fileHandleWithNullDevice];
    if(![task launchAndReturnError:NULL]) return 127;
    /* A loader must never hold up login indefinitely. */
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(task.running && deadline.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:.05];
    if(task.running) { [task terminate]; return 124; }
    return task.terminationStatus;
}

static BOOL tana_protected_directory(const char *path)
{
    struct stat info;
    if(lstat(path,&info)!=0) { if(errno!=ENOENT || mkdir(path,0755)!=0) return NO; if(lstat(path,&info)!=0) return NO; }
    return S_ISDIR(info.st_mode) && info.st_uid==0 && !(info.st_mode&0022);
}

static BOOL tana_write_fd(int fd,NSData *data,mode_t mode)
{
    const char *bytes=data.bytes; size_t remaining=data.length;
    while(remaining) { ssize_t n=write(fd,bytes,remaining); if(n<0 && errno==EINTR) continue; if(n<=0) return NO; bytes+=n; remaining-=n; }
    return fchown(fd,0,0)==0 && fchmod(fd,mode)==0 && fsync(fd)==0;
}

/* A root-owned immutable copy, not the user-writable app, receives the narrowly
 * scoped sudo rule. It can only load the embedded, fixed-path Tana2D payload. */
static int tana_install_helper(const char *uid_text)
{
    if(getuid()!=0 || !uid_text || !*uid_text) return 1;
    char *end=NULL; errno=0; unsigned long raw=strtoul(uid_text,&end,10);
    if(errno || !end || *end || raw<501 || raw>UINT32_MAX) return 2;
    struct passwd *pw=getpwuid((uid_t)raw); if(!pw) return 2;
    NSString *username=@(pw->pw_name);
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"];
    if(!username.length || [username rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return 2;
    if(!tana_protected_directory("/Library/PrivilegedHelperTools") || !tana_protected_directory("/private/etc/sudoers.d")) return 3;
    NSString *source=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/tana2d-window-helper"];
    NSData *binary=[NSData dataWithContentsOfFile:source]; if(!binary.length || binary.length>UINT32_MAX) return 4;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(binary.bytes,(CC_LONG)binary.length,digest);
    NSMutableString *hash=[NSMutableString string]; for(unsigned i=0;i<sizeof(digest);i++) [hash appendFormat:@"%02x",digest[i]];
    NSString *rule=[NSString stringWithFormat:@"# Tana2D: only load the root-owned window helper.\n%@ ALL=(root) NOPASSWD: sha256:%@ %s --load-sa\n",username,hash,TANA2D_HELPER_PATH];
    char helper_tmp[]="/Library/PrivilegedHelperTools/.tana2d-XXXXXX";
    char rule_tmp[]="/private/etc/sudoers.d/.tana2d-XXXXXX";
    int helper_fd=mkstemp(helper_tmp),rule_fd=mkstemp(rule_tmp); int result=5;
    if(helper_fd<0 || rule_fd<0) goto done;
    if(!tana_write_fd(helper_fd,binary,0755) || !tana_write_fd(rule_fd,[rule dataUsingEncoding:NSUTF8StringEncoding],0440)) goto done;
    if(tana_run(@"/usr/sbin/visudo",@[@"-cf",@(rule_tmp)])!=0) goto done;
    if(tana_run(@"/usr/bin/codesign",@[@"--verify",@"--strict",@(helper_tmp)])!=0) goto done;
    if(rename(helper_tmp,TANA2D_HELPER_PATH)!=0) goto done;
    NSString *rule_path=[NSString stringWithFormat:@"/private/etc/sudoers.d/tana2d-%lu",raw];
    if(rename(rule_tmp,rule_path.fileSystemRepresentation)!=0) goto done;
    result=0;
done:
    if(helper_fd>=0) close(helper_fd); if(rule_fd>=0) close(rule_fd);
    unlink(helper_tmp); unlink(rule_tmp);
    return result;
}

static NSDictionary *tana_setup_status(void)
{
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();
    BOOL unlocked=session && ![((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue];
    if(session) CFRelease(session);
    int connection=SLSMainConnectionID();
    BOOL separate=SLSGetSpaceManagementMode(connection)==1;
    CFStringRef display=SLSCopyActiveMenuBarDisplayIdentifier(connection);
    uint64_t space=display ? SLSManagedDisplayGetCurrentSpace(connection,display) : 0;
    if(display) CFRelease(display);
    BOOL normal=space && SLSSpaceGetType(connection,space)==0;
    return @{@"accessibility":@(AXIsProcessTrusted()),@"security":@(tana_security_ready()),@"backend":@(tana_backend_ready()),
        @"helperInstalled":@([[NSFileManager defaultManager] isExecutableFileAtPath:TanaHelperPath]),
        @"sessionUnlocked":@(unlocked),@"separateSpaces":@(separate),@"otherManagerPID":@(tana_other_manager()),
        @"normalDesktop":@(normal),@"singleDisplay":@([NSScreen screens].count==1)};
}

static BOOL tana_setup_can_start(NSDictionary *status)
{
    return [status[@"accessibility"] boolValue] && [status[@"backend"] boolValue] && [status[@"sessionUnlocked"] boolValue] &&
           [status[@"separateSpaces"] boolValue] && [status[@"singleDisplay"] boolValue] && [status[@"normalDesktop"] boolValue] && ![status[@"otherManagerPID"] intValue];
}

static NSString *tana_settings_path(void)
{
    NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    return [[base stringByAppendingPathComponent:@"Tana2D"] stringByAppendingPathComponent:@"config.json"];
}

static NSMutableDictionary *tana_accessible_configuration(NSDictionary *original)
{
    NSMutableDictionary *decoded=[[original mutableCopy] autorelease];
    NSMutableDictionary *settings=[[decoded[@"settings"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    [settings addEntriesFromDictionary:@{@"autofocus":@"off",@"focusAfterScroll":@"center",@"showMenuBar":@YES,@"motionStrength":@0,@"haptics":@NO}]; decoded[@"settings"]=settings;
    NSMutableDictionary *shortcuts=[[decoded[@"shortcuts"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    /* Preserve Spotlight, app Quit, and VoiceOver's Control-Option-P. */
    shortcuts[@"float-alt"]=@NO; shortcuts[@"utility"]=@"ctrl+cmd+u"; shortcuts[@"utility-mark"]=@"ctrl+shift+cmd+u"; shortcuts[@"float"]=@"alt+cmd+space"; shortcuts[@"close"]=@"alt+cmd+q"; shortcuts[@"commands"]=@"ctrl+cmd+p"; decoded[@"shortcuts"]=shortcuts;
    return decoded;
}

static void tana_setup_menu(void)
{
    if(NSApp.mainMenu) return;
    NSMenu *main=[[[NSMenu alloc] initWithTitle:@"Tana2D"] autorelease];
    NSMenuItem *application=[[[NSMenuItem alloc] initWithTitle:@"Tana2D" action:nil keyEquivalent:@""] autorelease];
    NSMenu *appMenu=[[[NSMenu alloc] initWithTitle:@"Tana2D"] autorelease];
    [appMenu addItemWithTitle:@"Quit Tana2D" action:@selector(terminate:) keyEquivalent:@"q"];
    application.submenu=appMenu; [main addItem:application];
    NSMenuItem *edit=[[[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""] autorelease];
    NSMenu *editMenu=[[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    edit.submenu=editMenu; [main addItem:edit];
    NSMenuItem *window=[[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    NSMenu *windowMenu=[[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [windowMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    window.submenu=windowMenu; [main addItem:window]; NSApp.mainMenu=main;
}

@interface TanaSetup : NSObject <NSWindowDelegate>
@property(nonatomic,retain) NSWindow *window;
@property(nonatomic,retain) NSTextField *status;
@property(nonatomic,retain) NSTextField *detail;
@property(nonatomic,retain) NSButton *start;
@property(nonatomic,retain) NSButton *install;
@property(nonatomic,retain) NSButton *login;
@property(nonatomic,retain) NSTimer *timer;
@property(nonatomic,retain) NSDictionary *lastStatus;
@property(nonatomic) BOOL startup,accepted,busy,preview;
+ (instancetype)shared;
- (void)showForStartup:(BOOL)startup preview:(BOOL)preview;
@end

@implementation TanaSetup
+ (instancetype)shared { static TanaSetup *instance; if(!instance) instance=[TanaSetup new]; return instance; }
- (NSTextField *)label:(NSString *)text size:(CGFloat)size
{
    NSTextField *field=[NSTextField wrappingLabelWithString:text]; field.font=[NSFont systemFontOfSize:size];
    field.textColor=NSColor.labelColor; field.selectable=YES; return field;
}
- (NSButton *)button:(NSString *)title action:(SEL)action
{
    NSButton *button=[NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle=NSBezelStyleRounded; button.accessibilityLabel=title; return button;
}
- (void)build
{
    self.window=[[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,620,650) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.window.title=@"Tana2D Setup & Settings"; self.window.delegate=self; self.window.releasedWhenClosed=NO;
    self.window.minSize=NSMakeSize(500,500);
    NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:self.window.contentView.bounds] autorelease];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; scroll.hasVerticalScroller=YES; scroll.drawsBackground=NO;
    NSStackView *stack=[NSStackView stackViewWithViews:@[]]; stack.orientation=NSUserInterfaceLayoutOrientationVertical;
    stack.alignment=NSLayoutAttributeLeading; stack.spacing=14; stack.edgeInsets=NSEdgeInsetsMake(24,28,24,28);
    scroll.documentView=stack; [self.window.contentView addSubview:scroll]; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active=YES;
    [stack addArrangedSubview:[self label:@"Welcome to Tana2D" size:26]];
    [stack addArrangedSubview:[self label:@"Your windows on an infinite two-dimensional plane. Tana2D includes its own window engine and helper. No Homebrew, yabai, or terminal setup is needed for the app." size:14]];
    self.status=[self label:@"Checking your Mac…" size:14]; self.status.accessibilityLabel=@"Setup requirements"; [stack addArrangedSubview:self.status];
    NSButton *access=[self button:@"Allow Accessibility…" action:@selector(accessibility:)]; [stack addArrangedSubview:access];
    self.install=[self button:@"Set Up Window Helper…" action:@selector(installHelper:)]; [stack addArrangedSubview:self.install];
    [stack addArrangedSubview:[self button:@"Read macOS Setup Guide" action:@selector(guide:)]];
    self.detail=[self label:@"" size:13]; self.detail.textColor=NSColor.secondaryLabelColor; self.detail.accessibilityLabel=@"Setup guidance"; [stack addArrangedSubview:self.detail];
    [stack addArrangedSubview:[self label:@"Make it comfortable" size:18]];
    self.login=[NSButton checkboxWithTitle:@"Open Tana2D when I log in" target:self action:@selector(loginChanged:)]; [stack addArrangedSubview:self.login];
    [stack addArrangedSubview:[self button:@"Use Keyboard & Screen Reader Preferences" action:@selector(accessiblePreferences:)]];
    [stack addArrangedSubview:[self button:@"Open Configuration File" action:@selector(configuration:)]];
    [stack addArrangedSubview:[self label:@"The Tana2D menu lists your current shortcuts. The command palette defaults to Control + Option + P. Swipe with three fingers to move around the plane. Pinch to zoom. Control + Up fits all windows; the camera buttons also fit the focused window or reset to 100%. Tana2D follows macOS Reduce Motion." size:14]];
    self.start=[self button:@"Start Tana2D" action:@selector(startTana:)]; self.start.keyEquivalent=@"\r"; [stack addArrangedSubview:self.start];
    [stack addArrangedSubview:[self button:@"Close" action:@selector(close:)]];
    for(NSView *view in stack.arrangedSubviews) [view.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor constant:-56].active=YES;
    [self.window center];
}
- (void)refresh:(id)sender
{
    (void)sender; if(self.busy) return;
    NSDictionary *s=tana_setup_status();
    self.status.stringValue=[NSString stringWithFormat:@"%@ Accessibility permission\n%@ Window helper\n%@ One connected display\n%@ Displays have separate Spaces",
        [s[@"accessibility"] boolValue]?@"Ready:":@"Needed:",[s[@"backend"] boolValue]?@"Ready:":@"Needed:",
        [s[@"singleDisplay"] boolValue]?@"Ready:":@"Needed:",[s[@"separateSpaces"] boolValue]?@"Ready:":@"Needed:"];
    self.start.enabled=!self.preview && (!self.startup || tana_setup_can_start(s));
    self.install.enabled=!self.preview && [s[@"security"] boolValue] && ![s[@"backend"] boolValue];
    self.login.enabled=!self.preview;
    self.login.state=SMAppService.mainAppService.status==SMAppServiceStatusEnabled ? NSControlStateValueOn:NSControlStateValueOff;
    if([self.lastStatus isEqual:s]) return;
    self.lastStatus=s;
    if(self.preview) self.detail.stringValue=@"Preview only. Window management and privileged setup are disabled.";
    else if(![s[@"security"] boolValue] && ![s[@"backend"] boolValue]) self.detail.stringValue=@"macOS currently blocks the window helper. Keeping live off-screen windows and all animations requires a one-time change in macOS Recovery. Read the guide before deciding; Tana2D never changes these security settings for you.";
    else if([s[@"otherManagerPID"] intValue]) self.detail.stringValue=@"A window manager is already running. Quit it before starting Tana2D. If this is your current Tana2D session, use its menu to open settings.";
    else if(![s[@"singleDisplay"] boolValue]) self.detail.stringValue=@"This version supports one display. Disconnect additional displays before starting.";
    else if(![s[@"separateSpaces"] boolValue]) self.detail.stringValue=@"Enable Displays have separate Spaces in System Settings → Desktop & Dock → Mission Control, then log out and back in.";
    else if(![s[@"normalDesktop"] boolValue]) self.detail.stringValue=@"Leave the full-screen app and switch to an ordinary desktop before starting Tana2D.";
    else if(![s[@"sessionUnlocked"] boolValue]) self.detail.stringValue=@"Unlock your Mac to start Tana2D.";
    else if(![s[@"accessibility"] boolValue]) self.detail.stringValue=@"Allow Tana2D in Privacy & Security → Accessibility. This lets Tana2D move and resize your windows. This page checks again automatically.";
    else if(![s[@"backend"] boolValue]) self.detail.stringValue=@"Set Up Window Helper asks macOS for administrator approval once. It installs Tana2D’s own helper and allows only that helper to reload after login or a Dock restart.";
    else self.detail.stringValue=@"Ready. Start Tana2D to arrange your windows. Quit Tana2D from its menu to restore the windows it still tracks.";
}
- (void)showForStartup:(BOOL)startup preview:(BOOL)preview
{
    self.startup=startup; self.preview=preview; self.accepted=NO; self.lastStatus=nil;
    tana_setup_menu();
    if(!self.window) [self build];
    self.start.title=startup?@"Start Tana2D":@"Done";
    [self refresh:nil]; [self.timer invalidate];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)accessibility:(id)sender
{
    (void)sender; if(self.preview) return;
    NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)guide:(id)sender
{
    (void)sender; NSURL *url=[NSBundle.mainBundle URLForResource:@"SETUP" withExtension:@"html"];
    if(url) [[NSWorkspace sharedWorkspace] openURL:url];
    else self.detail.stringValue=@"See docs/SETUP.html in the source folder, or install the packaged Tana2D app to read the offline guide.";
}
- (void)installHelper:(id)sender
{
    (void)sender; if(self.preview || self.busy) return;
    self.busy=YES; self.install.enabled=NO; self.start.enabled=NO;
    self.detail.stringValue=@"Waiting for macOS administrator approval…";
    NSString *command=[NSString stringWithFormat:@"%@ --install-helper %u",tana_shell_quote(NSBundle.mainBundle.executablePath),getuid()];
    NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSAppleScript *script=[[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]] autorelease];
    NSDictionary *error=nil; NSAppleEventDescriptor *result=[script executeAndReturnError:&error];
    if(!result) { self.busy=NO; [self refresh:nil]; self.detail.stringValue=[NSString stringWithFormat:@"Setup was not completed. %@",error[NSAppleScriptErrorMessage] ?: @"You can retry when ready."]; return; }
    self.detail.stringValue=@"Connecting the window helper…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool { tana_run(@"/usr/bin/sudo",@[@"-n",TanaHelperPath,@"--load-sa"]); }
        dispatch_async(dispatch_get_main_queue(),^{ self.busy=NO; [self refresh:nil];
            if(!tana_backend_ready()) self.detail.stringValue=@"The helper was installed but did not connect. Restart your Mac and reopen Tana2D. If this continues, the helper may not support this macOS version. No windows were moved.";
        });
    });
}
- (void)loginChanged:(NSButton *)sender
{
    if(self.preview) return; NSError *error=nil;
    BOOL ok=sender.state==NSControlStateValueOn ? [SMAppService.mainAppService registerAndReturnError:&error] : [SMAppService.mainAppService unregisterAndReturnError:&error];
    [self refresh:nil]; if(!ok) self.detail.stringValue=error.localizedDescription ?: @"Could not change login startup.";
    else if(SMAppService.mainAppService.status==SMAppServiceStatusRequiresApproval) { [SMAppService openSystemSettingsLoginItems]; self.detail.stringValue=@"Approve Tana2D in Login Items to finish enabling startup."; }
}
- (void)configuration:(id)sender
{
    (void)sender; if(self.preview) return;
    NSString *path=tana_settings_path(); NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        [@"{\n  \"settings\": {},\n  \"shortcuts\": {}\n}\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; chmod(path.fileSystemRepresentation,0600);
    }
    NSURL *editor=[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
    if(editor) [[NSWorkspace sharedWorkspace] openURLs:@[[NSURL fileURLWithPath:path]] withApplicationAtURL:editor configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}
- (void)accessiblePreferences:(id)sender
{
    (void)sender; if(self.preview) return;
    NSString *path=tana_settings_path(); NSData *data=[NSData dataWithContentsOfFile:path];
    id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : [NSMutableDictionary dictionary];
    if(![decoded isKindOfClass:NSMutableDictionary.class] || (decoded[@"settings"] && ![decoded[@"settings"] isKindOfClass:NSDictionary.class]) || (decoded[@"shortcuts"] && ![decoded[@"shortcuts"] isKindOfClass:NSDictionary.class])) { self.detail.stringValue=@"The configuration contains invalid JSON or settings. Fix it before applying preferences; your file has not been replaced."; return; }
    decoded=tana_accessible_configuration(decoded);
    NSError *error=nil; NSData *output=[NSJSONSerialization dataWithJSONObject:decoded options:NSJSONWritingPrettyPrinted error:&error];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    if(!output || ![output writeToFile:path options:NSDataWritingAtomic error:&error]) { self.detail.stringValue=error.localizedDescription ?: @"Could not save preferences."; return; }
    chmod(path.fileSystemRepresentation,0600);
    self.detail.stringValue=@"Saved: reduced motion, keyboard focus, visible menu bar, no haptics. Spotlight and app Quit keep their usual keys. Command palette: Control + Command + P. Other shortcuts remain configurable.";
    NSAccessibilityPostNotificationWithUserInfo(self.window,NSAccessibilityAnnouncementRequestedNotification,@{NSAccessibilityAnnouncementKey:self.detail.stringValue,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityHigh)});
}
- (void)startTana:(id)sender
{
    (void)sender; if(self.preview || (self.startup && !tana_setup_can_start(tana_setup_status()))) { [self refresh:nil]; return; }
    self.accepted=YES; [self close:nil];
}
- (void)close:(id)sender
{
    (void)sender; [self.timer invalidate]; self.timer=nil; [self.window orderOut:nil];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if(self.startup) { [NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO]; }
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self close:nil]; return NO; }
@end

static BOOL tana_prepare_startup(BOOL force,BOOL preview)
{
    [NSApplication sharedApplication];
    if(!force && AXIsProcessTrusted() && [[NSFileManager defaultManager] isExecutableFileAtPath:TanaHelperPath]) {
        // Login Items can launch before the desktop is unlocked. Keep the app
        // responsive and wait before touching the Dock or presenting setup.
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:120];
        while(![tana_setup_status()[@"sessionUnlocked"] boolValue] && deadline.timeIntervalSinceNow>0)
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.5]];
        if([tana_setup_status()[@"sessionUnlocked"] boolValue] && tana_security_ready()) {
            for(int attempt=0;attempt<2 && !tana_backend_ready();attempt++) {
                tana_run(@"/usr/bin/sudo",@[@"-n",TanaHelperPath,@"--load-sa"]);
                if(!tana_backend_ready()) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            }
        }
    }
    if(!force && tana_setup_can_start(tana_setup_status())) return YES;
    [[TanaSetup shared] showForStartup:YES preview:preview]; [NSApp run];
    return [TanaSetup shared].accepted;
}
