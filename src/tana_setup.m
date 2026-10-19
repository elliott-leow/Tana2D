/* Standalone setup. No window management runs until every required check passes. */
#import <ServiceManagement/ServiceManagement.h>
#import <CommonCrypto/CommonDigest.h>
#import <WebKit/WebKit.h>

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
    return scripting_addition_request_handshake(version,sizeof(version),&attributes) && OSAX_VERSION_COMPATIBLE(version) && (attributes & OSAX_ATTRIB_PLANE_TRANSFORM);
}

/* A read-only check for setup's status page. It opens its own connection and
 * leaves the running window manager's capability state and pending frame
 * reply alone, so polling it can never make a live frame fail. */
static BOOL tana_backend_probe(void)
{
    struct passwd *pw=getpwuid(getuid());
    if(!pw) return NO;
    char path[sizeof(g_sa_socket_file)]; snprintf(path,sizeof(path),SA_SOCKET_PATH_FMT,pw->pw_name);
    const char request[]={0x01,0x00,SA_OPCODE_HANDSHAKE};
    char version[256]={0}; uint32_t attributes=0;
    return hwm_sa_handshake(path,request,sizeof(request),version,sizeof(version),&attributes,HWM_SA_TIMEOUT_MS) &&
           OSAX_VERSION_COMPATIBLE(version) && (attributes & OSAX_ATTRIB_PLANE_TRANSFORM);
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

static NSString *tana_run_output(NSString *path,NSArray *arguments)
{
    NSTask *task=[[[NSTask alloc] init] autorelease]; task.launchPath=path; task.arguments=arguments;
    NSPipe *pipe=[NSPipe pipe]; task.standardInput=[NSFileHandle fileHandleWithNullDevice];
    task.standardOutput=pipe; task.standardError=[NSFileHandle fileHandleWithNullDevice];
    if(![task launchAndReturnError:NULL]) return nil;
    NSData *data=[pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    return task.terminationStatus==0 ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
}

/* The stored value, which takes effect on the next boot; kern.bootargs is the current boot. */
static NSArray *tana_stored_boot_args(void);
/* Status is polled every second while setup is open. The stored value only
 * changes when setup writes it, so read it once and again after that write. */
static NSArray *tana_boot_args_cache;
static void tana_boot_args_invalidate(void) { @synchronized(NSArray.class) { [tana_boot_args_cache release]; tana_boot_args_cache=nil; } }
static NSArray *tana_cached_boot_args(void)
{
    @synchronized(NSArray.class) {
        if(!tana_boot_args_cache) tana_boot_args_cache=[tana_stored_boot_args() copy];
        return [[tana_boot_args_cache retain] autorelease];
    }
}
static NSArray *tana_stored_boot_args(void)
{
    NSString *output=tana_run_output(@"/usr/sbin/nvram",@[@"boot-args"]);
    NSRange tab=[output rangeOfString:@"\t"];
    if(tab.location==NSNotFound) return @[];
    NSString *value=[output substringFromIndex:NSMaxRange(tab)];
    NSMutableArray *parts=[NSMutableArray array];
    for(NSString *part in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) if(part.length) [parts addObject:part];
    return parts;
}

/* Appends the helper's boot argument and preserves every existing argument.
 * Runs only as root, only when the user chooses it in setup. */
static int tana_enable_arm64e_boot_arg(void)
{
    if(getuid()!=0) return 1;
    NSArray *parts=tana_stored_boot_args();
    if([parts containsObject:@"-arm64e_preview_abi"]) return 0;
    NSString *value=[[parts arrayByAddingObject:@"-arm64e_preview_abi"] componentsJoinedByString:@" "];
    return tana_run(@"/usr/sbin/nvram",@[[@"boot-args=" stringByAppendingString:value]])==0 ? 0 : 3;
}

static BOOL tana_session_unlocked(void)
{
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();
    BOOL unlocked=session && ![((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue];
    if(session) CFRelease(session);
    return unlocked;
}

/* A configured login item must survive an arbitrarily long locked session.
 * Waiting is not a setup failure; only evaluate setup after the user returns. */
static void tana_startup_wait_for_unlock(BOOL (^is_unlocked)(void),void (^wait_tick)(void))
{
    if(is_unlocked()) return;
    NSLog(@"Tana2D startup: waiting for the desktop to unlock");
    do { @autoreleasepool { wait_tick(); } } while(!is_unlocked());
    NSLog(@"Tana2D startup: desktop unlocked; continuing startup");
}

/* Accessibility grants follow the app's location; a copy in Downloads or a
 * disk image is easily lost or translocated. A bare development binary is exempt. */
static BOOL tana_in_applications(NSString *bundle_path)
{
    if(![bundle_path.pathExtension isEqual:@"app"]) return YES;
    NSString *user=[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/"];
    return [bundle_path hasPrefix:@"/Applications/"] || [bundle_path hasPrefix:user];
}

static NSDictionary *tana_setup_status_with_screens(NSUInteger screens)
{
    BOOL unlocked=tana_session_unlocked();
    int connection=SLSMainConnectionID();
    BOOL separate=SLSGetSpaceManagementMode(connection)==1;
    CFStringRef display=SLSCopyActiveMenuBarDisplayIdentifier(connection);
    uint64_t space=display ? SLSManagedDisplayGetCurrentSpace(connection,display) : 0;
    if(display) CFRelease(display);
    BOOL normal=space && SLSSpaceGetType(connection,space)==0;
    BOOL sip=scripting_addition_is_sip_friendly();
#ifdef __arm64__
    BOOL arm64e=scripting_addition_is_arm64e_enabled();
    BOOL pending=sip && !arm64e && [tana_cached_boot_args() containsObject:@"-arm64e_preview_abi"];
#else
    BOOL arm64e=YES,pending=NO;
#endif
    return @{@"accessibility":@(AXIsProcessTrusted()),@"security":@(tana_security_ready()),@"backend":@(tana_backend_probe()),
        @"sip":@(sip),@"arm64e":@(arm64e),@"bootArgsPending":@(pending),@"inApplications":@(tana_in_applications(NSBundle.mainBundle.bundlePath)),
        @"helperInstalled":@([[NSFileManager defaultManager] isExecutableFileAtPath:TanaHelperPath]),
        @"sessionUnlocked":@(unlocked),@"separateSpaces":@(separate),@"otherManagerPID":@(tana_other_manager()),
        @"normalDesktop":@(normal),@"singleDisplay":@(screens==1)};
}
static NSDictionary *tana_setup_status(void) { return tana_setup_status_with_screens([NSScreen screens].count); }

static BOOL tana_setup_can_start(NSDictionary *status)
{
    return [status[@"accessibility"] boolValue] && [status[@"backend"] boolValue] && [status[@"sessionUnlocked"] boolValue] &&
           [status[@"separateSpaces"] boolValue] && [status[@"singleDisplay"] boolValue] && [status[@"normalDesktop"] boolValue] && ![status[@"otherManagerPID"] intValue];
}

/* Remaining setup steps in the order a person completes them. Each step can
 * only be done once the steps before it are; the Recovery change precedes the
 * boot argument, which precedes its restart, which precedes the helper. */
static NSArray *tana_setup_missing(NSDictionary *s)
{
    NSMutableArray *missing=[NSMutableArray array];
    if(![s[@"inApplications"] boolValue]) [missing addObject:@"move"];
    if(![s[@"accessibility"] boolValue]) [missing addObject:@"accessibility"];
    if(![s[@"backend"] boolValue]) {
        if(![s[@"sip"] boolValue]) [missing addObject:@"recovery"];
        if(![s[@"arm64e"] boolValue]) [missing addObject:[s[@"bootArgsPending"] boolValue] ? @"restart" : @"bootArgs"];
        [missing addObject:@"helper"];
    }
    if(![s[@"separateSpaces"] boolValue]) [missing addObject:@"spaces"];
    if([s[@"otherManagerPID"] intValue]) [missing addObject:@"otherManager"];
    if(![s[@"singleDisplay"] boolValue]) [missing addObject:@"display"];
    if(![s[@"normalDesktop"] boolValue]) [missing addObject:@"fullscreen"];
    if(![s[@"sessionUnlocked"] boolValue]) [missing addObject:@"locked"];
    return missing;
}

static NSString *tana_settings_path(void)
{
    NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    return [[base stringByAppendingPathComponent:@"Tana2D"] stringByAppendingPathComponent:@"config.json"];
}

/* Keyboard & screen reader mode. The values it replaces are kept beside it,
 * so turning it off restores exactly what the person had. */
static NSDictionary *tana_accessible_settings(void)
{
    return @{@"autofocus":@"off",@"focusAfterScroll":@"center",@"showMenuBar":@YES,@"motionStrength":@0,@"haptics":@NO};
}
static NSDictionary *tana_accessible_shortcuts(void)
{
    /* Preserve Spotlight, app Quit, and VoiceOver's Control-Option-P. */
    return @{@"float-alt":@NO,@"utility":@"ctrl+cmd+u",@"utility-mark":@"ctrl+shift+cmd+u",@"float":@"alt+cmd+space",@"close":@"alt+cmd+q",@"commands":@"ctrl+cmd+p"};
}
static BOOL tana_keyboard_mode(NSDictionary *config)
{
    NSDictionary *settings=[config[@"settings"] isKindOfClass:NSDictionary.class] ? config[@"settings"] : nil;
    return [settings[@"keyboardMode"] isKindOfClass:NSNumber.class] && [settings[@"keyboardMode"] boolValue];
}
static NSMutableDictionary *tana_accessible_configuration(NSDictionary *original)
{
    NSMutableDictionary *decoded=[[original mutableCopy] autorelease];
    NSMutableDictionary *settings=[[decoded[@"settings"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *shortcuts=[[decoded[@"shortcuts"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    if(!tana_keyboard_mode(original)) {
        NSMutableDictionary *saved=[NSMutableDictionary dictionary],*savedShortcuts=[NSMutableDictionary dictionary];
        for(NSString *key in tana_accessible_settings()) saved[key]=settings[key] ?: NSNull.null;
        for(NSString *key in tana_accessible_shortcuts()) savedShortcuts[key]=shortcuts[key] ?: NSNull.null;
        settings[@"keyboardModeRestore"]=@{@"settings":saved,@"shortcuts":savedShortcuts};
    }
    [settings addEntriesFromDictionary:tana_accessible_settings()]; settings[@"keyboardMode"]=@YES;
    [shortcuts addEntriesFromDictionary:tana_accessible_shortcuts()];
    decoded[@"settings"]=settings; decoded[@"shortcuts"]=shortcuts;
    return decoded;
}
/* Trackpad style: undo keyboard mode if it is on, and hover to focus. */
static NSMutableDictionary *tana_trackpad_configuration(NSDictionary *original)
{
    NSMutableDictionary *decoded=[[original mutableCopy] autorelease];
    NSMutableDictionary *settings=[[decoded[@"settings"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *shortcuts=[[decoded[@"shortcuts"] mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    NSDictionary *restore=[settings[@"keyboardModeRestore"] isKindOfClass:NSDictionary.class] ? settings[@"keyboardModeRestore"] : nil;
    if(tana_keyboard_mode(original)) {
        NSDictionary *savedSettings=[restore[@"settings"] isKindOfClass:NSDictionary.class] ? restore[@"settings"] : @{};
        NSDictionary *savedShortcuts=[restore[@"shortcuts"] isKindOfClass:NSDictionary.class] ? restore[@"shortcuts"] : @{};
        for(NSString *key in tana_accessible_settings()) { id v=savedSettings[key]; if(v && v!=NSNull.null) settings[key]=v; else [settings removeObjectForKey:key]; }
        for(NSString *key in tana_accessible_shortcuts()) { id v=savedShortcuts[key]; if(v && v!=NSNull.null) shortcuts[key]=v; else [shortcuts removeObjectForKey:key]; }
    }
    [settings removeObjectForKey:@"keyboardMode"]; [settings removeObjectForKey:@"keyboardModeRestore"];
    settings[@"autofocus"]=@"pointer-movement";
    decoded[@"settings"]=settings; decoded[@"shortcuts"]=shortcuts;
    return decoded;
}

static NSDictionary *tana_read_configuration(void)
{
    NSData *data=[NSData dataWithContentsOfFile:tana_settings_path()];
    id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
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

static NSURL *tana_setup_page_url(void)
{
    NSURL *bundled=[NSBundle.mainBundle URLForResource:@"onboarding" withExtension:@"html"];
    if(bundled) return bundled;
    /* Development builds run outside a bundle; use the source tree's page. */
    NSString *source=[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"setup_ui/onboarding.html"];
    if(!source.isAbsolutePath) source=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:source];
    source=source.stringByStandardizingPath;
    return [NSFileManager.defaultManager fileExistsAtPath:source] ? [NSURL fileURLWithPath:source] : nil;
}

static NSString *const TanaSetupStartedKey=@"TanaSetupStarted";
static NSString *const TanaSetupCompletedKey=@"TanaSetupCompleted";
static NSString *const TanaSetupResumeLoginKey=@"TanaSetupResumeLoginItem";

/* The page is drawn edge to edge; this strip keeps the title bar draggable. */
@interface TanaSetupDragStrip : NSView
@end
@implementation TanaSetupDragStrip
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)mouseDown:(NSEvent *)event { if(event.clickCount==2) [self.window performZoom:nil]; else [self.window performWindowDragWithEvent:event]; }
@end

@interface TanaSetup : NSObject <NSWindowDelegate,WKScriptMessageHandler,WKNavigationDelegate>
@property(nonatomic,retain) NSWindow *window;
@property(nonatomic,retain) WKWebView *web;
@property(nonatomic,retain) NSTimer *timer;
@property(nonatomic,retain) NSDictionary *lastState;
@property(nonatomic,copy) NSString *message;
@property(nonatomic) BOOL startup,accepted,busy,preview,loaded,reinstallHelper,gathering,refreshAgain;
+ (instancetype)shared;
- (void)showForStartup:(BOOL)startup preview:(BOOL)preview;
- (NSDictionary *)state;
- (void)close:(id)sender;
@end

@implementation TanaSetup
+ (instancetype)shared { static TanaSetup *instance; if(!instance) instance=[TanaSetup new]; return instance; }
- (void)build
{
    self.window=[[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,920,640) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.window.title=@"Tana2D Setup & Settings"; self.window.delegate=self; self.window.releasedWhenClosed=NO;
    self.window.titlebarAppearsTransparent=YES; self.window.titleVisibility=NSWindowTitleHidden;
    self.window.minSize=NSMakeSize(760,560); self.window.backgroundColor=[NSColor colorWithSRGBRed:.04 green:.05 blue:.10 alpha:1];
    WKWebViewConfiguration *configuration=[[[WKWebViewConfiguration alloc] init] autorelease];
    [configuration.userContentController addScriptMessageHandler:self name:@"tana"];
    NSView *content=self.window.contentView;
    self.web=[[[WKWebView alloc] initWithFrame:content.bounds configuration:configuration] autorelease];
    self.web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; self.web.navigationDelegate=self;
    [self.web setValue:@NO forKey:@"drawsBackground"];
    self.web.accessibilityLabel=@"Tana2D setup";
    [content addSubview:self.web];
    TanaSetupDragStrip *strip=[[[TanaSetupDragStrip alloc] initWithFrame:NSMakeRect(80,content.bounds.size.height-30,content.bounds.size.width-160,30)] autorelease];
    strip.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin; [content addSubview:strip positioned:NSWindowAbove relativeTo:self.web];
    NSURL *page=tana_setup_page_url();
    if(page) [self.web loadFileURL:page allowingReadAccessToURL:page.URLByDeletingLastPathComponent];
    else [self.web loadHTMLString:@"<body style='font:16px system-ui;color:#fff;padding:64px'><h1>Setup files are missing</h1><p>Reinstall Tana2D, then open it again.</p></body>" baseURL:nil];
    [self.window center];
}
- (NSDictionary *)stateWithStatus:(NSDictionary *)s login:(SMAppServiceStatus)login config:(NSDictionary *)config other:(NSString *)other
{
    NSArray *missing=tana_setup_missing(s);
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
#ifdef __arm64__
    NSString *arch=@"arm64";
#else
    NSString *arch=@"x86_64";
#endif
    NSMutableDictionary *state=[[s mutableCopy] autorelease];
    [state addEntriesFromDictionary:@{@"missing":missing,@"step":missing.firstObject ?: @"ready",@"canStart":@(tana_setup_can_start(s)),
        @"startup":@(self.startup),@"preview":@(self.preview),@"busy":@(self.busy),@"message":self.message ?: @"",@"arch":arch,
        @"otherManager":other ?: @"",@"loginEnabled":@(login==SMAppServiceStatusEnabled),@"loginNeedsApproval":@(login==SMAppServiceStatusRequiresApproval),
        @"resumed":@([defaults boolForKey:TanaSetupStartedKey]),@"completed":@([defaults boolForKey:TanaSetupCompletedKey]),
        @"keyboardMode":@(tana_keyboard_mode(config)),
        @"configPath":[tana_settings_path() stringByAbbreviatingWithTildeInPath],
        @"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev"}];
    return state;
}
static NSString *tana_other_manager_name(NSDictionary *s)
{
    pid_t pid=[s[@"otherManagerPID"] intValue];
    return pid ? ([NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName ?: @"another window manager") : @"";
}
- (NSDictionary *)state
{
    NSDictionary *s=tana_setup_status();
    return [self stateWithStatus:s login:SMAppService.mainAppService.status config:tana_read_configuration() other:tana_other_manager_name(s)];
}
- (void)push:(NSDictionary *)state force:(BOOL)force
{
    if(!self.loaded) return;
    if(!force && [state isEqual:self.lastState]) return;
    self.lastState=state;
    NSData *json=[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    NSString *script=[NSString stringWithFormat:@"window.tanaUpdate&&window.tanaUpdate(%@)",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease]];
    [self.web evaluateJavaScript:script completionHandler:nil];
}
/* The status check forks, makes XPC calls and opens the helper socket. Gather
 * it off the main thread so the page never hitches while someone waits on it. */
- (void)refresh:(id)sender
{
    if(!self.loaded) return;
    BOOL force=sender==self;
    if(self.gathering) { if(force) self.refreshAgain=YES; return; }
    self.gathering=YES;
    NSUInteger screens=[NSScreen screens].count;
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSDictionary *s=[tana_setup_status_with_screens(screens) retain];
            SMAppServiceStatus login=SMAppService.mainAppService.status;
            NSDictionary *config=[tana_read_configuration() retain];
            NSString *other=[tana_other_manager_name(s) retain];
            dispatch_async(dispatch_get_main_queue(),^{
                self.gathering=NO;
                [self push:[self stateWithStatus:s login:login config:config other:other] force:force || self.refreshAgain];
                BOOL again=self.refreshAgain; self.refreshAgain=NO;
                [s release]; [config release]; [other release];
                if(again) [self refresh:self];
                [self release];
            });
        }
    });
}
- (void)say:(NSString *)message { self.message=message; [self refresh:self]; }
- (void)showForStartup:(BOOL)startup preview:(BOOL)preview
{
    BOOL reopen=self.window && (self.startup!=startup || self.preview!=preview);
    self.startup=startup; self.preview=preview; self.accepted=NO; self.lastState=nil; self.message=nil;
    tana_setup_menu();
    if(!self.window) [self build];
    else if(reopen) [self.web evaluateJavaScript:@"window.tanaReset&&window.tanaReset()" completionHandler:nil];
    [self refresh:self]; [self.timer invalidate];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark Page bridge

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)controller;
    NSDictionary *body=[message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *action=[body[@"action"] isKindOfClass:NSString.class] ? body[@"action"] : nil; id value=body[@"value"];
    if(!action) return;
    if([action isEqual:@"ready"]) { self.loaded=YES; [self refresh:self]; return; }
    if([action isEqual:@"guide"]) { [self guide]; return; }
    if([action isEqual:@"print"]) { [self print]; return; }
    if([action isEqual:@"close"]) { [self close:nil]; return; }
    if(self.preview) { [self say:@"Preview only. This button does nothing here."]; return; }
    if(self.busy) return;
    self.message=nil;
    if([action isEqual:@"began"]) [NSUserDefaults.standardUserDefaults setBool:YES forKey:TanaSetupStartedKey];
    else if([action isEqual:@"accessibility"]) [self accessibility];
    else if([action isEqual:@"move"]) [self moveToApplications];
    else if([action isEqual:@"shutDownForRecovery"]) [self powerForRecovery];
    else if([action isEqual:@"enableBootArgs"]) [self enableBootArgs];
    else if([action isEqual:@"restart"]) [self power:@"rrst" resume:YES];
    else if([action isEqual:@"installHelper"]) [self installHelper];
    else if([action isEqual:@"openSpaces"]) [self openSettings:@"x-apple.systempreferences:com.apple.Desktop-Settings.extension"];
    else if([action isEqual:@"logOut"]) [self power:@"rlgo" resume:YES];
    else if([action isEqual:@"quitOther"]) [self quitOtherManager];
    else if([action isEqual:@"login"]) [self setLogin:[value boolValue]];
    else if([action isEqual:@"style"]) [self applyStyle:[value isEqual:@"keyboard"]];
    else if([action isEqual:@"openConfig"]) [self configuration];
    else if([action isEqual:@"start"]) [self startTana];
    [self refresh:self];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    (void)webView; NSURL *url=action.request.URL;
    if(url.isFileURL || [url.scheme isEqual:@"about"]) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    if([url.scheme isEqual:@"https"]) [[NSWorkspace sharedWorkspace] openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { self.loaded=NO; [webView reload]; }

#pragma mark Actions

/* Shows the admin prompt after the page has drawn its waiting state. */
- (void)runAdministrator:(NSArray *)arguments waiting:(NSString *)waiting then:(void (^)(BOOL ok,BOOL cancelled,int status))then
{
    self.busy=YES; [self say:waiting];
    NSMutableArray *quoted=[NSMutableArray arrayWithObject:tana_shell_quote(NSBundle.mainBundle.executablePath)];
    for(NSString *argument in arguments) [quoted addObject:tana_shell_quote(argument)];
    NSString *command=[quoted componentsJoinedByString:@" "];
    NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    void (^done)(BOOL,BOOL,int)=[[then copy] autorelease];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSAppleScript *script=[[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]] autorelease];
        NSDictionary *error=nil; BOOL ok=[script executeAndReturnError:&error]!=nil;
        // "do shell script" reports the command's exit status as the error number.
        int status=[error[NSAppleScriptErrorNumber] intValue];
        self.busy=NO; done(ok,status==-128,status);
        [self refresh:self];
    });
}
- (void)accessibility
{
    NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [self openSettings:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
}
- (void)openSettings:(NSString *)url { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]]; }
- (void)guide
{
    NSURL *url=[NSBundle.mainBundle URLForResource:@"SETUP" withExtension:@"html"];
    if(url) [[NSWorkspace sharedWorkspace] openURL:url];
    else [self say:@"The full guide is in docs/SETUP.html in the source folder."];
}
- (void)print
{
    NSPrintOperation *operation=[self.web printOperationWithPrintInfo:NSPrintInfo.sharedPrintInfo];
    operation.view.frame=self.web.bounds;
    [operation runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:NULL];
}
- (void)moveToApplications
{
    NSFileManager *fm=NSFileManager.defaultManager; NSString *source=NSBundle.mainBundle.bundlePath;
    NSString *destination=@"/Applications/Tana2D.app";
    if(![fm isWritableFileAtPath:@"/Applications"]) destination=[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Tana2D.app"];
    [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    if([fm fileExistsAtPath:destination]) {
        NSString *identifier=[NSBundle bundleWithPath:destination].bundleIdentifier;
        if(![identifier isEqual:NSBundle.mainBundle.bundleIdentifier]) { [self say:[NSString stringWithFormat:@"Another app is already at %@. Move it away, then try again.",destination]]; return; }
        NSError *error=nil;
        if(![fm trashItemAtURL:[NSURL fileURLWithPath:destination] resultingItemURL:NULL error:&error]) { [self say:@"The older Tana2D in Applications could not be replaced. Drag it to the Trash, then try again."]; return; }
    }
    NSError *error=nil;
    if(![fm copyItemAtPath:source toPath:destination error:&error]) { [self say:@"Tana2D could not copy itself. Drag Tana2D into your Applications folder in Finder instead."]; return; }
    /* Moving by hand clears quarantine; this copy needs the same so it is not translocated again. */
    tana_run(@"/usr/bin/xattr",@[@"-dr",@"com.apple.quarantine",destination]);
    NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration]; configuration.createsNewApplicationInstance=YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:destination] configuration:configuration completionHandler:^(NSRunningApplication *app,NSError *openError) {
        dispatch_async(dispatch_get_main_queue(),^{
            if(app && !openError) [NSApp terminate:nil];
            else [self say:@"Tana2D is now in Applications. Open it from there to continue."];
        });
    }];
}
/* Setup reopens after the restart only because the person asked to continue. */
- (void)registerResume
{
    if(SMAppService.mainAppService.status==SMAppServiceStatusEnabled) return;
    if([SMAppService.mainAppService registerAndReturnError:NULL]) [NSUserDefaults.standardUserDefaults setBool:YES forKey:TanaSetupResumeLoginKey];
}
- (void)power:(NSString *)event resume:(BOOL)resume
{
    if(resume) [self registerResume];
    NSAppleScript *script=[[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"tell application \"loginwindow\" to «event aevt%@»",event]] autorelease];
    NSDictionary *error=nil;
    if(![script executeAndReturnError:&error]) {
        NSString *menu=[event isEqual:@"rlgo"] ? @"Log Out" : [event isEqual:@"rsdn"] ? @"Shut Down" : @"Restart";
        [self say:[NSString stringWithFormat:@"Choose Apple menu → %@ (top-left corner) to continue.",menu]];
    }
}
- (void)powerForRecovery
{
#ifdef __arm64__
    [self power:@"rsdn" resume:YES];
#else
    [self power:@"rrst" resume:YES];
#endif
}
- (void)enableBootArgs
{
    [self runAdministrator:@[@"--enable-arm64e-boot-arg"] waiting:@"Waiting for your password…" then:^(BOOL ok,BOOL cancelled,int status) {
        tana_boot_args_invalidate();
        if(ok) return;
        if(cancelled) self.message=@"No changes were made. Try again when you are ready.";
        else if(status==3) self.message=@"macOS refused the startup setting. Make sure the Recovery step finished (System Integrity Protection partly off), then try again.";
        else self.message=@"macOS did not accept the change. Make sure the Recovery step finished, then try again.";
    }];
}
- (void)installHelper
{
    void (^connect)(void)=^{
        self.busy=YES; [self say:@"Connecting the window helper…"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            @autoreleasepool { tana_run(@"/usr/bin/sudo",@[@"-n",TanaHelperPath,@"--load-sa"]); }
            BOOL ready=tana_backend_probe();
            dispatch_async(dispatch_get_main_queue(),^{
                self.busy=NO;
                /* An app update leaves the older helper pinned; the next press replaces it. */
                self.reinstallHelper=!ready;
                self.message=ready ? nil : @"The helper did not connect. Press the button again to reinstall it. If that does not work, restart your Mac. No windows were moved.";
                [self refresh:self];
            });
        });
    };
    if([NSFileManager.defaultManager isExecutableFileAtPath:TanaHelperPath] && !self.reinstallHelper) { connect(); return; }
    NSString *uid=[NSString stringWithFormat:@"%u",getuid()];
    [self runAdministrator:@[@"--install-helper",uid] waiting:@"Waiting for your password…" then:^(BOOL ok,BOOL cancelled,int status) {
        if(ok) { connect(); return; }
        switch(cancelled ? -128 : status) {
        case -128: self.message=@"No changes were made. Try again when you are ready."; break;
        case 2: self.message=@"The helper can only be set up for a standard macOS user account. Sign in to your own account and try again."; break;
        case 3: self.message=@"A system folder for helpers has unexpected permissions, so nothing was installed. See Troubleshooting in the full guide."; break;
        case 4: self.message=@"This copy of Tana2D is missing its window helper. Download Tana2D again, replace this copy, and try again."; break;
        case 5: self.message=@"The helper could not be verified or installed, so nothing was changed. Restart your Mac, then try again."; break;
        default: self.message=@"The helper could not be installed. Try again."; break;
        }
    }];
}
- (void)quitOtherManager
{
    pid_t pid=[tana_setup_status()[@"otherManagerPID"] intValue]; if(!pid) return;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!(app && [app terminate])) kill(pid,SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(tana_other_manager()==pid) [self say:@"It is still running. Quit it from its own menu, or turn off its Open at Login setting and restart."];
    });
}
- (void)setLogin:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:TanaSetupResumeLoginKey];
    SMAppService *service=SMAppService.mainAppService; NSError *error=nil;
    BOOL already=service.status==SMAppServiceStatusEnabled;
    BOOL ok=enabled ? (already || [service registerAndReturnError:&error]) : (!already || [service unregisterAndReturnError:&error]);
    if(!ok) self.message=error.localizedDescription ?: @"Could not change login startup.";
    else if(service.status==SMAppServiceStatusRequiresApproval) { [SMAppService openSystemSettingsLoginItems]; self.message=@"Turn on Tana2D in Login Items to finish."; }
}
- (void)configuration
{
    NSString *path=tana_settings_path(); NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        [@"{\n  \"settings\": {},\n  \"shortcuts\": {}\n}\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; chmod(path.fileSystemRepresentation,0600);
    }
    /* Use the editor chosen for JSON files. TextEdit (the fallback for an
     * unknown type) turns straight quotes into curly ones and breaks the file,
     * so when it is the only choice, show the file in Finder instead. */
    NSURL *file=[NSURL fileURLWithPath:path];
    NSURL *editor=[[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:file];
    if(editor && ![[NSBundle bundleWithURL:editor].bundleIdentifier isEqual:@"com.apple.TextEdit"]) [[NSWorkspace sharedWorkspace] openURL:file];
    else {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[file]];
        self.message=@"Shown in Finder. Open it in a code editor; TextEdit's smart quotes break the file. Changes apply when you save.";
    }
}
- (void)applyStyle:(BOOL)keyboard
{
    NSString *path=tana_settings_path(); NSData *data=[NSData dataWithContentsOfFile:path];
    id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : [NSMutableDictionary dictionary];
    if(![decoded isKindOfClass:NSMutableDictionary.class] || (decoded[@"settings"] && ![decoded[@"settings"] isKindOfClass:NSDictionary.class]) || (decoded[@"shortcuts"] && ![decoded[@"shortcuts"] isKindOfClass:NSDictionary.class])) { self.message=@"Your settings file has a mistake in it, so it was left unchanged. Fix it in Edit Settings File."; return; }
    decoded=keyboard ? tana_accessible_configuration(decoded) : tana_trackpad_configuration(decoded);
    NSError *error=nil; NSData *output=[NSJSONSerialization dataWithJSONObject:decoded options:NSJSONWritingPrettyPrinted error:&error];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    if(!output || ![output writeToFile:path options:NSDataWritingAtomic error:&error]) { self.message=error.localizedDescription ?: @"Could not save preferences."; return; }
    chmod(path.fileSystemRepresentation,0600);
}
- (void)startTana
{
    if(self.startup && !tana_setup_can_start(tana_setup_status())) { self.message=@"Something changed. Tana2D needs one more step first."; return; }
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:TanaSetupCompletedKey];
    self.accepted=YES; [self close:nil];
}
- (void)close:(id)sender
{
    (void)sender;
    /* Setup registers itself as a login item only to come back after a
     * restart. Once it is closed without anyone choosing Open at Login,
     * take that registration back. */
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if(!self.preview && [defaults boolForKey:TanaSetupResumeLoginKey] && tana_setup_can_start(tana_setup_status())) {
        [SMAppService.mainAppService unregisterAndReturnError:NULL];
        [defaults removeObjectForKey:TanaSetupResumeLoginKey];
    }
    [self.timer invalidate]; self.timer=nil; [self.window orderOut:nil];
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
        tana_startup_wait_for_unlock(^BOOL { return tana_session_unlocked(); },^{
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.5]];
        });
        if(tana_session_unlocked() && tana_security_ready()) {
            for(int attempt=0;attempt<2 && !tana_backend_ready();attempt++) {
                tana_run(@"/usr/bin/sudo",@[@"-n",TanaHelperPath,@"--load-sa"]);
                if(!tana_backend_ready()) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            }
        }
    }
    NSDictionary *status=tana_setup_status();
    if(!force && tana_setup_can_start(status)) {
        NSLog(@"Tana2D startup: requirements ready; starting window manager");
        return YES;
    }
    NSLog(@"Tana2D startup: opening setup (requested=%d, status=%@)",force,status);
    [[TanaSetup shared] showForStartup:YES preview:preview]; [NSApp run];
    return [TanaSetup shared].accepted;
}
