#ifndef SA_SOCKET_PATH_FMT
#define SA_SOCKET_PATH_FMT      "/tmp/tana2d-sa_%s.socket"
#endif
#define SOCKET_PATH_FMT         "/tmp/tana2d_%s.socket"
#define LCFILE_PATH_FMT         "/tmp/yabai_%s.lock"

#define SCRPT_ADD_LOAD_OPT      "--load-sa"
#define SCRPT_ADD_UNINSTALL_OPT "--uninstall-sa"
#define SERVICE_INSTALL_OPT     "--install-service"
#define SERVICE_UNINSTALL_OPT   "--uninstall-service"
#define SERVICE_START_OPT       "--start-service"
#define SERVICE_RESTART_OPT     "--restart-service"
#define SERVICE_STOP_OPT        "--stop-service"
#define CLIENT_OPT_LONG         "--message"
#define CLIENT_OPT_SHRT         "-m"
#define CONFIG_OPT_LONG         "--config"
#define CONFIG_OPT_SHRT         "-c"
#define DEBUG_VERBOSE_OPT_LONG  "--verbose"
#define DEBUG_VERBOSE_OPT_SHRT  "-V"
#define VERSION_OPT_LONG        "--version"
#define VERSION_OPT_SHRT        "-v"
#define HELP_OPT_LONG           "--help"
#define HELP_OPT_SHRT           "-h"

#define MAJOR  7
#define MINOR  1
#define PATCH 25

struct signal *g_signal_event[SIGNAL_TYPE_COUNT];
struct process_manager g_process_manager;
struct display_manager g_display_manager;
struct window_manager g_window_manager;
struct space_manager g_space_manager;
struct memory_pool g_signal_storage;
struct mouse_state g_mouse_state;
struct event_loop g_event_loop;
void *g_workspace_context;

enum mission_control_mode g_mission_control_mode;
double g_cv_host_clock_frequency;
int g_layer_normal_window_level;
int g_layer_below_window_level;
int g_layer_above_window_level;
uint8_t *g_event_bytes;

char g_sa_socket_file[MAXLEN];
char g_socket_file[MAXLEN];
char g_config_file[4096];
char g_lock_file[MAXLEN];

mach_port_t g_bs_port;
int g_connection;
bool g_verbose;
pid_t g_pid;

static int client_send_message(int argc, char **argv)
{
    if (argc <= 1) {
        error("tana2d-msg: no arguments given! abort..\n");
    }

    char *user = getenv("USER");
    if (!user) {
        error("tana2d-msg: 'env USER' not set! abort..\n");
    }

    int message_length = argc;
    int argl[argc];

    for (int i = 1; i < argc; ++i) {
        argl[i] = strlen(argv[i]);
        message_length += argl[i];
    }

    char *message = malloc(sizeof(int)+message_length);
    char *temp = sizeof(int)+message;

    memcpy(message, &message_length, sizeof(int));
    for (int i = 1; i < argc; ++i) {
        memcpy(temp, argv[i], argl[i]);
        temp += argl[i];
        *temp++ = '\0';
    }
    *temp++ = '\0';

    int sockfd;
    char socket_file[MAXLEN];
    snprintf(socket_file, sizeof(socket_file), SOCKET_PATH_FMT, user);

    if (!socket_open(&sockfd)) {
        error("tana2d-msg: failed to open socket..\n");
    }

    if (!socket_connect(sockfd, socket_file)) {
        error("tana2d-msg: failed to connect to socket..\n");
    }

    if (send(sockfd, message, sizeof(int)+message_length, 0) == -1) {
        error("tana2d-msg: failed to send data..\n");
    }

    shutdown(sockfd, SHUT_WR);
    free(message);

    int result = EXIT_SUCCESS;
    FILE *output = stdout;
    int bytes_read = 0;
    char rsp[BUFSIZ];

    while ((bytes_read = read(sockfd, rsp, sizeof(rsp)-1)) > 0) {
        rsp[bytes_read] = '\0';

        if (rsp[0] == FAILURE_MESSAGE[0]) {
            result = EXIT_FAILURE;
            output = stderr;
            fprintf(output, "%s", rsp + 1);
            fflush(output);
        } else {
            fprintf(output, "%s", rsp);
            fflush(output);
        }
    }

    socket_close(sockfd);
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline bool configure_settings_and_acquire_lock(void)
{
    char *user = getenv("USER");
    if (!user) {
        error("tana2d: 'env USER' not set! abort..\n");
    }

    snprintf(g_sa_socket_file, sizeof(g_sa_socket_file), SA_SOCKET_PATH_FMT, user);
    snprintf(g_socket_file, sizeof(g_socket_file), SOCKET_PATH_FMT, user);
    snprintf(g_lock_file, sizeof(g_lock_file), LCFILE_PATH_FMT, user);

    NSApplicationLoad();
    g_pid = getpid();
    g_event_bytes = malloc(0x100);
    memset(g_event_bytes, 0, 0x100);
    g_connection = SLSMainConnectionID();
    g_cv_host_clock_frequency   = CVGetHostClockFrequency();
    g_layer_normal_window_level = CGWindowLevelForKey(LAYER_NORMAL);
    g_layer_below_window_level  = CGWindowLevelForKey(LAYER_BELOW);
    g_layer_above_window_level  = CGWindowLevelForKey(LAYER_ABOVE);
    CGSGetConnectionPortById    = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", "_CGSGetConnectionPortById");
    SLSPerformAsynchronousBridgedWindowManagementOperation = macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");

    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    CGSetLocalEventsSuppressionInterval(0.0f);
    CGEnableEventStateCombining(false);
    mouse_state_init(&g_mouse_state);
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &g_bs_port);

#if 0
    hook_nsobject_autorelease();
    hook_autoreleasepool_drain();
    hook_autoreleasepool_release();
#endif

    int handle = open(g_lock_file, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    if (handle == -1) {
        error("tana2d: could not create lock-file! abort..\n");
    }

    struct flock lockfd = {
        .l_start  = 0,
        .l_len    = 0,
        .l_pid    = g_pid,
        .l_type   = F_WRLCK,
        .l_whence = SEEK_SET
    };

    return fcntl(handle, F_SETLK, &lockfd) != -1;
}
#pragma clang diagnostic pop

static void parse_arguments(int argc, char **argv)
{
    if (string_equals(argv[1], "--install-helper")) {
        exit(argc==3 ? tana_install_helper(argv[2]) : 2);
    }
    if (string_equals(argv[1], "--enable-arm64e-boot-arg")) {
        exit(argc==2 ? tana_enable_arm64e_boot_arg() : 2);
    }
    if (string_equals(argv[1], "--setup-status")) {
        [NSApplication sharedApplication];
        NSData *json=[NSJSONSerialization dataWithJSONObject:tana_setup_status() options:0 error:NULL];
        fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); exit(0);
    }
    if (string_equals(argv[1], "--check-backend")) {
        struct passwd *user = getpwuid(getuid());
        char version[256] = {0}; uint32_t attributes = 0;
        if (user) snprintf(g_sa_socket_file, sizeof(g_sa_socket_file), SA_SOCKET_PATH_FMT, user->pw_name);
        bool ready = user && scripting_addition_request_handshake(version,sizeof(version),&attributes) && OSAX_VERSION_COMPATIBLE(version);
        fprintf(stdout,"{\"backend\":%s,\"attributes\":%u}\n",ready ? "true" : "false",attributes);
        exit(ready ? EXIT_SUCCESS : EXIT_FAILURE);
    }
    if (string_equals(argv[1], "--check-permissions")) {
        bool trusted = AXIsProcessTrusted();
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        bool unlocked = session && ![((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue];
        if (session) CFRelease(session);
        fprintf(stdout, "{\"accessibility\":%s,\"input_monitoring\":%s,\"session_unlocked\":%s}\n", trusted ? "true" : "false", CGPreflightListenEventAccess() ? "true" : "false", unlocked ? "true" : "false");
        exit(trusted ? EXIT_SUCCESS : EXIT_FAILURE);
    }
    if (string_equals(argv[1], "--request-permissions")) {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        fprintf(stdout, "Accessibility: %s\n", trusted ? "granted" : "grant Tana2D in System Settings > Privacy & Security > Accessibility");
        exit(trusted ? EXIT_SUCCESS : EXIT_FAILURE);
    }
    if ((string_equals(argv[1], HELP_OPT_LONG)) ||
        (string_equals(argv[1], HELP_OPT_SHRT))) {
        fprintf(stdout, "Tana2D — an infinite two-dimensional window plane\n"
                        "  -m strip fit-all                Fit all windows on the plane\n"
                        "  -m strip status                 Inspect layout and backend health\n"
                        "  -m strip left|right|up|down     Focus a window in that direction\n"
                        "  -m strip move-left|move-right   Move the focused window on the plane\n"
                        "  -m strip full|center|float      Change the focused window\n"
                        "  -m strip camera <x> <y>         Set the unbounded camera position\n"
                        "  -m strip pan <dx> <dy>           Move the camera in both axes\n"
                        "  -m strip zoom <scale>            Set camera zoom (1 is actual size)\n"
                        "  -m strip fit-focused            Fit the focused window\n"
                        "  -m strip actual-size            Reset camera zoom to 100%%\n"
                        "  -m strip width <points>         Resize the focused tile\n"
                        "  -m strip home|pause|reflow|quit  Session controls\n"
                        "  --check-permissions             Report access in this launch context\n"
                        "  --check-backend                 Read-only helper connectivity check\n"
                        "  --request-permissions           Open the macOS Accessibility prompt\n"
                        "  --version                       Print version\n"
                        "Open Tana2D.app for guided setup. --setup reopens setup; --setup-status diagnoses requirements.\n");
        exit(EXIT_SUCCESS);
    }

    if ((string_equals(argv[1], VERSION_OPT_LONG)) ||
        (string_equals(argv[1], VERSION_OPT_SHRT))) {
        fprintf(stdout, "tana2d 0.4.0 (yabai %d.%d.%d foundation)\n", MAJOR, MINOR, PATCH);
        exit(EXIT_SUCCESS);
    }

    if ((string_equals(argv[1], CLIENT_OPT_LONG)) ||
        (string_equals(argv[1], CLIENT_OPT_SHRT))) {
        exit(client_send_message(argc-1, argv+1));
    }

    if (string_equals(argv[1], SCRPT_ADD_UNINSTALL_OPT)) {
        exit(scripting_addition_uninstall());
    }

    if (string_equals(argv[1], SCRPT_ADD_LOAD_OPT)) {
        exit(scripting_addition_load());
    }

    if (string_equals(argv[1], SERVICE_INSTALL_OPT)) {
        exit(service_install());
    }

    if (string_equals(argv[1], SERVICE_UNINSTALL_OPT)) {
        exit(service_uninstall());
    }

    if (string_equals(argv[1], SERVICE_START_OPT)) {
        exit(service_start());
    }

    if (string_equals(argv[1], SERVICE_RESTART_OPT)) {
        exit(service_restart());
    }

    if (string_equals(argv[1], SERVICE_STOP_OPT)) {
        exit(service_stop());
    }

    for (int i = 1; i < argc; ++i) {
        char *opt = argv[i];

        if ((string_equals(opt, DEBUG_VERBOSE_OPT_LONG)) ||
            (string_equals(opt, DEBUG_VERBOSE_OPT_SHRT))) {
            g_verbose = true;
        } else if ((string_equals(opt, CONFIG_OPT_LONG)) ||
                   (string_equals(opt, CONFIG_OPT_SHRT))) {
            char *val = i < argc - 1 ? argv[++i] : NULL;
            if (!val) error("tana2d: option '%s|%s' requires an argument!\n", CONFIG_OPT_LONG, CONFIG_OPT_SHRT);
            snprintf(g_config_file, sizeof(g_config_file), "%s", val);
        } else {
            error("tana2d: '%s' is not a valid option!\n", opt);
        }
    }
}

#ifndef TESTS
int main(int argc, char **argv)
{
    BOOL setup=argc==2 && !strcmp(argv[1],"--setup");
    BOOL preview=argc==2 && !strcmp(argv[1],"--setup-preview");
    if (argc > 1 && !setup && !preview) parse_arguments(argc, argv);
    if (!is_root() && !tana_prepare_startup(setup || preview,preview)) return 0;

    if (is_root()) {
        require("tana2d: running as root is not allowed! abort..\n");
    }

    if (!ax_privilege()) {
        require("tana2d: could not access accessibility features! abort..\n");
    }

    if (!(SLSGetSpaceManagementMode(SLSMainConnectionID()) == 1)) {
        require("tana2d: 'display has separate spaces' is disabled! abort..\n");
    }

    if (!ts_init(MEGABYTES(8))) {
        error("tana2d: could not allocate temporary storage! abort..\n");
    }

    if (!memory_pool_init(&g_signal_storage, KILOBYTES(256))) {
        error("tana2d: could not allocate event signal storage! abort..\n");
    }

    if (!configure_settings_and_acquire_lock()) {
        error("tana2d: could not acquire lock-file! abort..\n");
    }

    if (!event_loop_begin(&g_event_loop)) {
        error("tana2d: could not start event loop! abort..\n");
    }

    if (!workspace_event_handler_begin(&g_workspace_context)) {
        error("tana2d: could not start workspace context! abort..\n");
    }

    if (!process_manager_begin(&g_process_manager)) {
        error("tana2d: could not start process manager! abort..\n");
    }

    if (!display_manager_begin(&g_display_manager)) {
        error("tana2d: could not start display manager! abort..\n");
    }

    if (!mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK_FFM)) {
        error("tana2d: could not start mouse handler! abort..\n");
    }

    if (workspace_is_macos_monterey() ||
        workspace_is_macos_ventura() ||
        workspace_is_macos_sonoma() ||
        workspace_is_macos_sequoia() ||
        workspace_is_macos_tahoe()) {
        mission_control_observe();

        if (workspace_is_macos_ventura() ||
            workspace_is_macos_sonoma() ||
            workspace_is_macos_sequoia() ||
            workspace_is_macos_tahoe()) {
            SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1327, NULL);
            SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1328, NULL);
        }
    } else {
        SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1204, NULL);
    }

    SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 808, NULL);
    SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 1202, NULL);

    if (true) {
        SLSRegisterConnectionNotifyProc(g_connection, connection_handler, 804, NULL);
    }

    window_manager_init(&g_window_manager);
    space_manager_begin(&g_space_manager);
    window_manager_begin(&g_space_manager, &g_window_manager);

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    if (!message_loop_begin(g_socket_file)) {
        error("tana2d: could not start message loop! abort..\n");
    }

    event_loop_post(&g_event_loop, HORIZONTAL_BEGIN, NULL, 0);
    if (g_config_file[0]) exec_config_file(g_config_file, sizeof(g_config_file));

    [NSApp run];

    return 0;
}
#endif

PROFILER_END_TRANSLATION_UNIT
