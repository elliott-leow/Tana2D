/* Actual setup controller and policy; no privileges, helper installation or WM. */
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pwd.h>
#include <errno.h>
#include <assert.h>
#define MAXLEN 1024
#define SA_SOCKET_PATH_FMT "/tmp/tana2d-test-%s.socket"
#define OSAX_VERSION "0.5.3"
#define OSAX_ATTRIB_PLANE_TRANSFORM 0x80
static char g_sa_socket_file[MAXLEN];
static bool scripting_addition_request_handshake(char *v,size_t n,uint32_t *a) { (void)v;(void)n;(void)a;return false; }
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
        NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *config=[folder stringByAppendingPathComponent:@"config.json"];
        [[NSJSONSerialization dataWithJSONObject:modified options:0 error:NULL] writeToFile:config atomically:YES];
        TanaConfig *reader=[[[TanaConfig alloc] initWithPath:config defaultShortcuts:@{@"float":@"cmd+space",@"float-alt":@"alt+cmd+space",@"commands":@"ctrl+alt+p",@"close":@"cmd+q"}] autorelease];
        assert([reader reload:NULL]); TanaConfigSnapshot *snapshot=[reader copySnapshot];
        assert(snapshot.autofocusMode==TanaAutofocusOff && snapshot.motionStrength==0);
        assert(snapshot.shortcutConflicts.count==0); [snapshot release];
        [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
        [NSApplication sharedApplication];
        TanaSetup *setup=[TanaSetup shared]; [setup showForStartup:NO preview:YES];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.15]];
        [setup.window.contentView layoutSubtreeIfNeeded];
        assert(!setup.start.enabled && !setup.install.enabled && !setup.login.enabled);
        assert([setup.window.title isEqual:@"Tana2D Setup & Settings"]);
        NSView *view=setup.window.contentView;
        NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/setup-preview.png" atomically:YES];
        [setup close:nil];
        (void)tana_prepare_startup;
        puts("setup policy, preferences, and native UI tests passed");
    }
    return 0;
}
