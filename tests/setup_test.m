/* Actual setup controller and policy; no privileges, helper installation or WM. */
#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pwd.h>
#include <errno.h>
#include <assert.h>
#define MAXLEN 1024
#define SA_SOCKET_PATH_FMT "/tmp/tana2d-test-%s.socket"
#define OSAX_VERSION "0.5.3"
#define OSAX_VERSION_COMPATIBLE(v) (!strcmp((v),OSAX_VERSION))
#define OSAX_ATTRIB_PLANE_TRANSFORM 0x80
static char g_sa_socket_file[MAXLEN];
static bool scripting_addition_request_handshake(char *v,size_t n,uint32_t *a) { (void)v;(void)n;(void)a;return false; }
#define SA_OPCODE_HANDSHAKE 0x01
#define HWM_SA_TIMEOUT_MS 250
static bool hwm_sa_handshake(const char *p,const void *r,size_t l,char *v,size_t n,uint32_t *a,int t) { (void)p;(void)r;(void)l;(void)v;(void)n;(void)a;(void)t;return false; }
static bool scripting_addition_is_sip_friendly(void) { return false; }
#ifdef __arm64__
static bool scripting_addition_is_arm64e_enabled(void) { return false; }
#endif
static int SLSMainConnectionID(void) { return 0; }
static CFStringRef SLSCopyActiveMenuBarDisplayIdentifier(int c) { (void)c; return CFRetain(CFSTR("test")); }
static uint64_t SLSManagedDisplayGetCurrentSpace(int c,CFStringRef d) { (void)c;(void)d;return 1; }
static int SLSSpaceGetType(int c,uint64_t s) { (void)c;(void)s;return 0; }
static int SLSGetSpaceManagementMode(int c) { (void)c; return 1; }
#include "../src/tana_setup.m"
#import "../src/tana_config.m"

int main(void)
{
    @autoreleasepool {
        __block unsigned polls=0;
        /* 1,200 half-second ticks model ten minutes locked: the former
         * 120-second deadline would leave this launch stuck in setup. */
        tana_startup_wait_for_unlock(^BOOL { return polls>=1200; },^{ ++polls; });
        assert(polls==1200);
        tana_startup_wait_for_unlock(^BOOL { return YES; },^{ assert(!"already-unlocked startup must not wait"); });
        assert(getuid()!=0); // This test never runs privileged installation.
        assert(tana_install_helper("501")==1);
        assert([tana_shell_quote(@"a'b $HOME `pwd`") isEqual:@"'a'\\''b $HOME `pwd`'"]);
        NSMutableDictionary *ready=[@{@"accessibility":@YES,@"backend":@YES,@"sessionUnlocked":@YES,@"separateSpaces":@YES,@"singleDisplay":@YES,@"normalDesktop":@YES,@"otherManagerPID":@0} mutableCopy];
        assert(tana_setup_can_start(ready));
        for(NSString *key in @[@"accessibility",@"backend",@"sessionUnlocked",@"separateSpaces",@"singleDisplay",@"normalDesktop"]) {
            ready[key]=@NO; assert(!tana_setup_can_start(ready)); ready[key]=@YES;
        }
        ready[@"otherManagerPID"]=@123; assert(!tana_setup_can_start(ready)); [ready release];
        NSDictionary *original=@{@"settings":@{@"gaps":@{@"inner":@17}},@"shortcuts":@{@"left":@"cmd+l"},@"appRules":@{@"com.example.App":@{@"floating":@YES}}};
        NSDictionary *modified=tana_accessible_configuration(original);
        assert([modified[@"settings"][@"autofocus"] isEqual:@"off"]);
        assert([modified[@"settings"][@"gaps"] isEqual:original[@"settings"][@"gaps"]]);
        assert([modified[@"appRules"] isEqual:original[@"appRules"]]);
        assert([modified[@"shortcuts"][@"left"] isEqual:@"cmd+l"]);
        assert(!original[@"settings"][@"motionStrength"]);
        /* Keyboard mode is marked explicitly and turning it off restores
         * exactly what it replaced; the trackpad style turns on hover focus. */
        NSDictionary *mine=@{@"settings":@{@"autofocus":@"after-scroll",@"gaps":@{@"inner":@17}},@"shortcuts":@{@"close":@"cmd+w"}};
        NSDictionary *keyboard=tana_accessible_configuration(mine);
        assert(tana_keyboard_mode(keyboard) && !tana_keyboard_mode(mine) && !tana_keyboard_mode(original));
        assert([tana_accessible_configuration(keyboard)[@"settings"][@"keyboardModeRestore"] isEqual:keyboard[@"settings"][@"keyboardModeRestore"]]);
        NSDictionary *restored=tana_trackpad_configuration(keyboard);
        assert(!tana_keyboard_mode(restored) && !restored[@"settings"][@"keyboardModeRestore"]);
        assert([restored[@"settings"][@"autofocus"] isEqual:@"pointer-movement"] && !restored[@"settings"][@"motionStrength"]);
        assert([restored[@"shortcuts"][@"close"] isEqual:@"cmd+w"] && !restored[@"shortcuts"][@"commands"]);
        assert([restored[@"settings"][@"gaps"] isEqual:mine[@"settings"][@"gaps"]]);
        NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *config=[folder stringByAppendingPathComponent:@"config.json"];
        [[NSJSONSerialization dataWithJSONObject:modified options:0 error:NULL] writeToFile:config atomically:YES];
        TanaConfig *reader=[[[TanaConfig alloc] initWithPath:config defaultShortcuts:@{@"float":@"cmd+space",@"float-alt":@"alt+cmd+space",@"commands":@"ctrl+alt+p",@"close":@"cmd+q"}] autorelease];
        assert([reader reload:NULL]); TanaConfigSnapshot *snapshot=[reader copySnapshot];
        assert(snapshot.autofocusMode==TanaAutofocusOff && snapshot.motionStrength==0);
        assert(snapshot.shortcutConflicts.count==0); [snapshot release];
        [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
        NSMutableDictionary *fresh=[@{@"inApplications":@NO,@"accessibility":@NO,@"backend":@NO,@"sip":@NO,@"arm64e":@NO,@"bootArgsPending":@NO,
            @"separateSpaces":@YES,@"otherManagerPID":@0,@"singleDisplay":@YES,@"normalDesktop":@YES,@"sessionUnlocked":@YES} mutableCopy];
        assert([tana_setup_missing(fresh) isEqual:(@[@"move",@"accessibility",@"recovery",@"bootArgs",@"helper"])]);
        fresh[@"inApplications"]=@YES; fresh[@"accessibility"]=@YES; fresh[@"sip"]=@YES; fresh[@"bootArgsPending"]=@YES;
        assert([tana_setup_missing(fresh) isEqual:(@[@"restart",@"helper"])]);
        fresh[@"arm64e"]=@YES; fresh[@"separateSpaces"]=@NO; fresh[@"otherManagerPID"]=@42;
        assert([tana_setup_missing(fresh) isEqual:(@[@"helper",@"spaces",@"otherManager"])]);
        fresh[@"backend"]=@YES; fresh[@"sip"]=@NO; fresh[@"arm64e"]=@NO; // a connected helper needs no security steps
        fresh[@"separateSpaces"]=@YES; fresh[@"otherManagerPID"]=@0;
        assert(tana_setup_missing(fresh).count==0); [fresh release];
        assert(tana_in_applications(@"/Applications/Tana2D.app") && tana_in_applications(@"/Users/x/build/tana2d"));
        assert(!tana_in_applications(@"/Volumes/Tana2D/Tana2D.app") && !tana_in_applications(@"/private/var/folders/x/AppTranslocation/y/d/Tana2D.app"));
        assert(tana_enable_arm64e_boot_arg()==1); // refuses without root
        [NSApplication sharedApplication];
        TanaSetup *setup=[TanaSetup shared]; [setup showForStartup:NO preview:YES];
        assert([setup.window.title isEqual:@"Tana2D Setup & Settings"]);
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];
        while(!setup.loaded && deadline.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        assert(setup.loaded); // the page loaded and reached the native bridge
        NSDictionary *state=[setup state];
        assert([state[@"preview"] boolValue] && ![state[@"startup"] boolValue] && [state[@"missing"] isKindOfClass:NSArray.class]);
        /* Preview never performs an action, even one sent by the page. */
        __block BOOL evaluated=NO;
        [setup.web evaluateJavaScript:@"send('installHelper'); send('start'); 1" completionHandler:^(id r,NSError *e){ (void)r; (void)e; evaluated=YES; }];
        while(!evaluated) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];
        assert(!setup.busy && !setup.accepted && [setup.message hasPrefix:@"Preview only"]);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        __block BOOL shot=NO;
        [setup.web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image,NSError *e){
            (void)e; NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/setup-preview.png" atomically:YES]; shot=YES; }];
        while(!shot) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        [setup close:nil];
        (void)tana_prepare_startup;
        puts("setup policy, step order, preferences, and setup page tests passed");
    }
    return 0;
}
