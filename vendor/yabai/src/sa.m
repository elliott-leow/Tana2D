#include "sa.h"
#include "../../../src/sa_transport.h"
#include "misc/plane_transform.h"
#include "misc/input_shape.h"
extern int csr_get_active_config(uint32_t *config);
#define CSR_ALLOW_UNRESTRICTED_FS 0x02
#define CSR_ALLOW_TASK_FOR_PID    0x04

extern char g_sa_socket_file[MAXLEN];
static bool hwm_sa_capabilities_known;
static uint32_t hwm_sa_capabilities;

static char osax_base_dir[MAXLEN];
static char osax_contents_dir[MAXLEN];
static char osax_contents_macos_dir[MAXLEN];
static char osax_contents_res_dir[MAXLEN];
static char osax_info_plist[MAXLEN];
static char osax_payload_dir[MAXLEN];
static char osax_payload_contents_dir[MAXLEN];
static char osax_payload_contents_macos_dir[MAXLEN];
static char osax_payload_plist[MAXLEN];
static char osax_bin_payload[MAXLEN];
static char osax_bin_loader[MAXLEN];

static char sa_plist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\">\n"
    "<dict>\n"
    "<key>CFBundleDevelopmentRegion</key>\n"
    "<string>en</string>\n"
    "<key>CFBundleExecutable</key>\n"
    "<string>loader</string>\n"
    "<key>CFBundleIdentifier</key>\n"
    "<string>dev.tana2d.window-helper</string>\n"
    "<key>CFBundleInfoDictionaryVersion</key>\n"
    "<string>6.0</string>\n"
    "<key>CFBundleName</key>\n"
    "<string>Tana2D</string>\n"
    "<key>CFBundlePackageType</key>\n"
    "<string>osax</string>\n"
    "<key>CFBundleShortVersionString</key>\n"
    "<string>"OSAX_VERSION"</string>\n"
    "<key>CFBundleVersion</key>\n"
    "<string>"OSAX_VERSION"</string>\n"
    "<key>NSHumanReadableCopyright</key>\n"
    "<string>Copyright © 2019 Åsmund Vikane. All rights reserved.</string>\n"
    "<key>OSAXHandlers</key>\n"
    "<dict>\n"
    "</dict>\n"
    "</dict>\n"
    "</plist>";

static char sa_bundle_plist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\">\n"
    "<dict>\n"
    "<key>CFBundleDevelopmentRegion</key>\n"
    "<string>en</string>\n"
    "<key>CFBundleExecutable</key>\n"
    "<string>payload</string>\n"
    "<key>CFBundleIdentifier</key>\n"
    "<string>dev.tana2d.window-payload</string>\n"
    "<key>CFBundleInfoDictionaryVersion</key>\n"
    "<string>6.0</string>\n"
    "<key>CFBundleName</key>\n"
    "<string>payload</string>\n"
    "<key>CFBundlePackageType</key>\n"
    "<string>BNDL</string>\n"
    "<key>CFBundleShortVersionString</key>\n"
    "<string>"OSAX_VERSION"</string>\n"
    "<key>CFBundleVersion</key>\n"
    "<string>"OSAX_VERSION"</string>\n"
    "<key>NSHumanReadableCopyright</key>\n"
    "<string>Copyright © 2019 Åsmund Vikane. All rights reserved.</string>\n"
    "<key>NSPrincipalClass</key>\n"
    "<string></string>\n"
    "</dict>\n"
    "</plist>";

static void scripting_addition_set_path(void)
{
    snprintf(osax_base_dir, sizeof(osax_base_dir), "%s", "/Library/ScriptingAdditions/tana2d.osax");

    snprintf(osax_contents_dir, sizeof(osax_contents_dir), "%s/%s", osax_base_dir, "Contents");
    snprintf(osax_contents_macos_dir, sizeof(osax_contents_macos_dir), "%s/%s", osax_contents_dir, "MacOS");
    snprintf(osax_contents_res_dir, sizeof(osax_contents_res_dir), "%s/%s", osax_contents_dir, "Resources");
    snprintf(osax_info_plist, sizeof(osax_info_plist), "%s/%s", osax_contents_dir, "Info.plist");

    snprintf(osax_payload_dir, sizeof(osax_payload_dir), "%s/%s", osax_contents_res_dir, "payload.bundle");
    snprintf(osax_payload_contents_dir, sizeof(osax_payload_contents_dir), "%s/%s", osax_payload_dir, "Contents");
    snprintf(osax_payload_contents_macos_dir, sizeof(osax_payload_contents_macos_dir), "%s/%s", osax_payload_contents_dir, "MacOS");
    snprintf(osax_payload_plist, sizeof(osax_payload_plist), "%s/%s", osax_payload_contents_dir, "Info.plist");

    snprintf(osax_bin_loader, sizeof(osax_bin_loader), "%s/%s", osax_contents_macos_dir, "loader");
    snprintf(osax_bin_payload, sizeof(osax_bin_payload), "%s/%s", osax_payload_contents_macos_dir, "payload");
}

static bool scripting_addition_create_directory(void)
{
    struct stat parent;
    if(mkdir("/Library/ScriptingAdditions",0755)!=0 && errno!=EEXIST) return false;
    if(lstat("/Library/ScriptingAdditions",&parent)!=0 || !S_ISDIR(parent.st_mode) || parent.st_uid!=0 || (parent.st_mode&0022)) return false;
    if (mkdir(osax_base_dir, 0755))                   goto err;
    if (mkdir(osax_contents_dir, 0755))               goto err;
    if (mkdir(osax_contents_macos_dir, 0755))         goto err;
    if (mkdir(osax_contents_res_dir, 0755))           goto err;
    if (mkdir(osax_payload_dir, 0755))                goto err;
    if (mkdir(osax_payload_contents_dir, 0755))       goto err;
    if (mkdir(osax_payload_contents_macos_dir, 0755)) goto err;
    return true;
err:
    return false;
}

static bool scripting_addition_write_file(char *buffer, unsigned int size, char *file, char *file_mode)
{
    FILE *handle = fopen(file, file_mode);
    if (!handle) return false;

    size_t bytes = fwrite(buffer, size, 1, handle);
    bool result = bytes == 1;
    fclose(handle);

    return result;
}

static bool scripting_addition_prepare_binaries(void)
{
    if(chmod(osax_bin_loader,0755)!=0 || chmod(osax_bin_payload,0755)!=0) return false;
    char cmd[MAXLEN];
    snprintf(cmd,sizeof(cmd),"/usr/bin/codesign -f -s - %s 2>/dev/null",osax_bin_loader);
    if(system(cmd)!=0) return false;
    snprintf(cmd,sizeof(cmd),"/usr/bin/codesign -f -s - %s 2>/dev/null",osax_bin_payload);
    return system(cmd)==0;
}

static void scripting_addition_restart_dock(void)
{
    NSArray *dock = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    [dock makeObjectsPerformSelector:@selector(terminate)];
}

static bool scripting_addition_set_socket_path(void)
{
    const char *sudo_uid = getenv("SUDO_UID");

    uid_t uid = getuid();
    assert(uid == 0);

    if (sudo_uid == NULL)                  return false;
    if (sscanf(sudo_uid, "%u", &uid) != 1) return false;

    struct passwd *pw = getpwuid(uid);
    if (!pw) return false;

    snprintf(g_sa_socket_file, sizeof(g_sa_socket_file), SA_SOCKET_PATH_FMT, pw->pw_name);
    return true;
}

static bool scripting_addition_is_installed(void)
{
    if (osax_base_dir[0] == 0) scripting_addition_set_path();

    DIR *dir = opendir(osax_base_dir);
    if (!dir) return false;

    closedir(dir);
    return true;
}

static int scripting_addition_check(void)
{
    bool result = 0;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (scripting_addition_is_installed()) {
        NSString *payload_path = [NSString stringWithUTF8String:osax_payload_dir];
        NSBundle *payload_bundle = [NSBundle bundleWithPath:payload_path];
        NSString *ns_version = [payload_bundle objectForInfoDictionaryKey:@"CFBundleVersion"];

        bool status = string_equals([ns_version UTF8String], OSAX_VERSION);
        result = status ? 0 : 1;
    } else {
        result = 1;
    }

    [pool drain];
    return result;
}

static bool scripting_addition_remove(void)
{
    char cmd[MAXLEN];
    snprintf(cmd, sizeof(cmd), "%s %s %s", "/bin/rm -rf", osax_base_dir, "2>/dev/null");

    int code = system(cmd);
    return code == 0;
}

static int scripting_addition_install(void)
{
    umask(S_IWGRP | S_IWOTH);

    if ((scripting_addition_is_installed()) && (!scripting_addition_remove())) {
        return 1;
    }

    if (!scripting_addition_create_directory()) {
        goto cleanup;
    }

    if (!scripting_addition_write_file(sa_plist, strlen(sa_plist), osax_info_plist, "w")) {
        goto cleanup;
    }

    if (!scripting_addition_write_file(sa_bundle_plist, strlen(sa_bundle_plist), osax_payload_plist, "w")) {
        goto cleanup;
    }

    if (!scripting_addition_write_file((char *) __src_osax_loader, __src_osax_loader_len, osax_bin_loader, "wb")) {
        goto cleanup;
    }

    if (!scripting_addition_write_file((char *) __src_osax_payload, __src_osax_payload_len, osax_bin_payload, "wb")) {
        goto cleanup;
    }

    if(!scripting_addition_prepare_binaries()) goto cleanup;
    return 0;

cleanup:
    scripting_addition_remove();
    return 2;
}

/* Dock serves the socket on one thread and can pause it for tens of
 * milliseconds while WindowServer is busy. Allow for that rather than
 * report a slow reply as a lost helper. */
#define HWM_SA_TIMEOUT_MS 250
static bool hwm_sa_plane_settle(void);

static bool scripting_addition_request_handshake(char *version, size_t capacity, uint32_t *attrib)
{
    const char bytes[] = { 0x01, 0x00, SA_OPCODE_HANDSHAKE };
    (void) hwm_sa_plane_settle();
    bool result = hwm_sa_handshake(g_sa_socket_file, bytes, sizeof(bytes), version, capacity, attrib, HWM_SA_TIMEOUT_MS);
    hwm_sa_capabilities_known = result;
    hwm_sa_capabilities = result ? *attrib : 0;
    return result;
}

static int scripting_addition_perform_validation(void)
{
    uint32_t attrib = 0;
    char version[SA_SOCKET_BUFF_LEN] = {0};
    bool is_latest_version_installed = scripting_addition_check() == 0;

    if (!scripting_addition_request_handshake(version, sizeof(version), &attrib)) {
        notify("scripting-addition", "connection failed!");
        return 1;
    }

    if (string_equals(version, OSAX_VERSION)) {
        if ((attrib & OSAX_ATTRIB_ALL) == OSAX_ATTRIB_ALL) {
            notify("scripting-addition", "payload v%s", version);
            return 0;
        }

        notify("scripting-addition", "payload (0x%X) doesn't support this macOS version!", attrib);
        return 1;
    }

    if (!is_latest_version_installed) {
        notify("scripting-addition", "payload is outdated, updating..");
        return scripting_addition_install();
    }

    notify("scripting-addition", "payload is outdated, restarting Dock.app..");
    scripting_addition_restart_dock();
    return 0;
}

static bool scripting_addition_is_sip_friendly(void)
{
    uint32_t config = 0;
    csr_get_active_config(&config);

    if (!(config & CSR_ALLOW_UNRESTRICTED_FS)) {
        return false;
    }

    if (!(config & CSR_ALLOW_TASK_FOR_PID)) {
        return false;
    }

    return true;
}

#ifdef __arm64__
static bool scripting_addition_is_arm64e_enabled(void)
{
    char bootargs[2048];
    size_t len = sizeof(bootargs) - 1;

    if (sysctlbyname("kern.bootargs", bootargs, &len, NULL, 0) == 0) {
        if (strnstr(bootargs, "-arm64e_preview_abi", len)) {
            return true;
        }
    }

    return false;
}
#endif

static bool mach_loader_inject_payload(void)
{
    FILE *handle = popen("/Library/ScriptingAdditions/tana2d.osax/Contents/MacOS/loader", "r");
    if (!handle) return false;

    int result = pclose(handle);
    if (WIFEXITED(result)) {
        return WEXITSTATUS(result) == 0;
    } else if (WIFSIGNALED(result)) {
        return false;
    } else if (WIFSTOPPED(result)) {
        return false;
    }

    return false;
}

int scripting_addition_uninstall(void)
{
    if (!scripting_addition_is_sip_friendly()) {
        warn("Tana2D: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n");
        notify("scripting-addition", "System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!");
        return 1;
    }

    if (!is_root()) {
        warn("Tana2D: scripting-addition must be uninstalled as root!\n");
        notify("scripting-addition", "must be uninstalled as root!");
        return 1;
    }

    if (!scripting_addition_is_installed()) return  0;
    if (!scripting_addition_remove())       return -1;
    return 0;
}

int scripting_addition_load(void)
{
    int result = 0;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (!is_root()) {
        warn("Tana2D: scripting-addition must be loaded as root!\n");
        notify("scripting-addition", "must be loaded as root!");
        result = 1;
        goto out;
    }

    if (!scripting_addition_is_sip_friendly()) {
        warn("Tana2D: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n");
        notify("scripting-addition", "System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!");
        result = 1;
        goto out;
    }

    if (scripting_addition_check() != 0) {
        result = scripting_addition_install();
        if (result != 0) goto out;
    }

#ifdef __arm64__
    if (!scripting_addition_is_arm64e_enabled()) {
        warn("Tana2D: missing required nvram boot-arg '-arm64e_preview_abi'!\n");
        notify("scripting-addition", "missing required nvram boot-arg '-arm64e_preview_abi'!");
        result = 1;
        goto out;
    }
#endif

    if (!mach_loader_inject_payload()) {
        warn("Tana2D: scripting-addition failed to inject payload into Dock.app!\n");
        notify("scripting-addition", "failed to inject payload into Dock.app!");
        result = 1;
        goto out;
    }

    if (scripting_addition_set_socket_path()) {
        result = scripting_addition_perform_validation();
    }

out:
    [pool drain];
    return result;
}

#define sa_payload_init() char bytes[SA_SOCKET_BUFF_LEN]; int16_t length = 1+sizeof(length)
#define pack(v) memcpy(bytes+length, &v, sizeof(v)); length += sizeof(v)
#define sa_payload_send(op) *(int16_t*)bytes = length-sizeof(length), bytes[sizeof(length)] = op, scripting_addition_send_bytes(bytes, length)

// Between begin and end, commands sent from this thread are handed to the
// helper without waiting for each one; end waits for all of them together.
static __thread HwmSaPipeline hwm_sa_pipeline;
static __thread int hwm_sa_batch_depth;
static __thread void (*hwm_sa_batch_barrier)(void);
static __thread HwmPlaneTransform hwm_sa_plane_transforms[SA_PLANE_TRANSFORM_MAX_RECORDS];
static __thread uint16_t hwm_sa_plane_transform_count;
/* A plane-only frame does not wait for its acknowledgement: the helper's one
 * transaction is atomic, so the frame is already whole. The reply is read
 * before anything else talks to the helper, at most one packet behind. */
static __thread int hwm_sa_plane_pending_fd = -1;
static __thread long long hwm_sa_plane_pending_deadline;
static __thread bool hwm_sa_plane_defer;
static bool hwm_sa_plane_flush(void);


static bool hwm_sa_plane_settle(void)
{
    int fd = hwm_sa_plane_pending_fd;
    if (fd < 0) return true;
    hwm_sa_plane_pending_fd = -1;
    unsigned char acknowledgement = 0;
    bool success = hwm_sa_receive_byte(fd, &acknowledgement, hwm_sa_plane_pending_deadline) && acknowledgement == 1;
    close(fd);
    return success;
}

// Wait for a frame submitted with scripting_addition_batch_end_deferred.
bool scripting_addition_settle(void)
{
    return hwm_sa_plane_settle();
}

void scripting_addition_batch_begin(void)
{
    ++hwm_sa_batch_depth;
}

void scripting_addition_batch_set_barrier(void (*barrier)(void))
{
    hwm_sa_batch_barrier=barrier;
}

// Wait until everything queued so far has been applied, leaving the batch open.
bool scripting_addition_batch_flush(void)
{
    if(hwm_sa_batch_depth>0 && hwm_sa_batch_barrier) hwm_sa_batch_barrier();
    bool settled = hwm_sa_plane_settle();
    return hwm_sa_plane_flush() && hwm_sa_pipeline_flush(&hwm_sa_pipeline) && settled;
}

bool scripting_addition_batch_end(void)
{
    if (hwm_sa_batch_depth > 0) --hwm_sa_batch_depth;
    return hwm_sa_batch_depth > 0 ? true : scripting_addition_batch_flush();
}

/* As batch_end, but a closing batch of transforms alone is handed over without
 * waiting for its reply. The result covers the previous deferred packet and
 * the hand-over of this one; scripting_addition_settle collects the rest. */
bool scripting_addition_batch_end_deferred(void)
{
    if (hwm_sa_batch_depth > 1) { --hwm_sa_batch_depth; return true; }
    if (hwm_sa_batch_depth > 0) --hwm_sa_batch_depth;
    bool settled = hwm_sa_plane_settle();
    if (!hwm_sa_pipeline_flush(&hwm_sa_pipeline)) { hwm_sa_plane_transform_count = 0; return false; }
    hwm_sa_plane_defer = true;
    bool sent = hwm_sa_plane_flush();
    hwm_sa_plane_defer = false;
    return sent && settled;
}

static bool scripting_addition_send_bytes(char *bytes, int length)
{
    if (length <= 0) return false;
    if(hwm_sa_batch_depth>0 && hwm_sa_batch_barrier) hwm_sa_batch_barrier();
    /* An ordinary command following transforms must not overtake their
     * absolute transaction on the helper socket. */
    if (!hwm_sa_plane_settle() || !hwm_sa_plane_flush()) return false;
    if (hwm_sa_batch_depth > 0) return hwm_sa_pipeline_send(&hwm_sa_pipeline, g_sa_socket_file, bytes, (size_t) length, HWM_SA_TIMEOUT_MS);
    return hwm_sa_send(g_sa_socket_file, bytes, (size_t) length, HWM_SA_TIMEOUT_MS);
}

/* The plane payload replies with one byte: 1 after its single absolute
 * transform transaction is submitted, 0 for malformed input or failure to
 * create the transaction. Unlike legacy commands, this makes backend failure observable. */
static bool hwm_sa_plane_send(const unsigned char *bytes, size_t length, bool defer)
{
    if (!hwm_sa_plane_settle()) return false;
    long long start = hwm_sa_monotonic_ms();
    if (!bytes || !length || start < 0 || start > LLONG_MAX - HWM_SA_TIMEOUT_MS) return false;
    long long deadline = start + HWM_SA_TIMEOUT_MS;
    int fd = hwm_sa_connect(g_sa_socket_file, deadline);
    if (fd < 0) return false;
    bool success = hwm_sa_send_all(fd, bytes, length, deadline);
    if (success && defer) {
        hwm_sa_plane_pending_fd = fd;
        hwm_sa_plane_pending_deadline = deadline;
        return true;
    }
    unsigned char acknowledgement = 0;
    if (success) success = hwm_sa_receive_byte(fd, &acknowledgement, deadline) && acknowledgement == 1;
    close(fd);
    return success;
}

/* Input-shape packets are intentionally unbatched: each is a 500ms lease and
 * needs its ACK before the caller can rely on the native hit target. */
static bool hwm_sa_input_shape_send(const unsigned char *bytes, size_t length)
{
    if (!bytes || !length || length > INT16_MAX) return false;
    unsigned char wire[SA_SOCKET_BUFF_LEN];
    if (!hwm_input_shape_wire_encode(wire, sizeof(wire), bytes, length)) return false;
    return hwm_sa_plane_send(wire, length + sizeof(int16_t), false);
}

static bool hwm_sa_plane_flush(void)
{
    if (!hwm_sa_plane_transform_count) return true;
    /* All earlier ordinary commands must reach Dock before an absolute
     * compositor transaction is committed. */
    if (!hwm_sa_pipeline_flush(&hwm_sa_pipeline)) {
        hwm_sa_plane_transform_count = 0;
        return false;
    }
    while (hwm_sa_plane_transform_count) {
        uint16_t count = hwm_sa_plane_transform_count;
        unsigned char bytes[SA_SOCKET_BUFF_LEN];
        size_t payload_length = 0;
        if (!hwm_plane_transform_packet_encode(bytes + sizeof(int16_t), sizeof(bytes) - sizeof(int16_t),
                                               hwm_sa_plane_transforms, count, &payload_length) ||
            payload_length > INT16_MAX) {
            hwm_sa_plane_transform_count = 0;
            return false;
        }
        int16_t wire_length = (int16_t) payload_length;
        memcpy(bytes, &wire_length, sizeof(wire_length));
        if (!hwm_sa_plane_send(bytes, payload_length + sizeof(wire_length), hwm_sa_plane_defer)) {
            hwm_sa_plane_transform_count = 0;
            return false;
        }
        hwm_sa_plane_transform_count = 0;
    }
    return true;
}

bool scripting_addition_plane_supported(void)
{
    return hwm_sa_capabilities_known && (hwm_sa_capabilities & OSAX_ATTRIB_PLANE_TRANSFORM);
}

bool scripting_addition_input_shape_supported(void)
{
    return hwm_sa_capabilities_known && (hwm_sa_capabilities & OSAX_ATTRIB_INPUT_SHAPE);
}

bool scripting_addition_set_input_shape(uint32_t wid, CGRect local_rect)
{
    unsigned char bytes[HWM_INPUT_SHAPE_PACKET_SET_BYTES];
    HwmInputShapeRequest request = { wid, local_rect };
    if (!scripting_addition_input_shape_supported() || !hwm_input_shape_packet_encode(bytes, sizeof(bytes), &request)) return false;
    /* Unknown/old helpers leave the capability clear and return false here;
     * callers retain their existing no-input-shape fallback. */
    if (hwm_sa_batch_depth > 0 && hwm_sa_batch_barrier) hwm_sa_batch_barrier();
    /* Drain ordinary commands and queued transforms before this unbatched
     * lease command opens a separate ACK socket. */
    if (!hwm_sa_pipeline_flush(&hwm_sa_pipeline) || !hwm_sa_plane_flush()) return false;
    return hwm_sa_input_shape_send(bytes, sizeof(bytes));
}

bool scripting_addition_clear_input_shape(void)
{
    unsigned char bytes[HWM_INPUT_SHAPE_PACKET_CLEAR_BYTES];
    if (!scripting_addition_input_shape_supported() || !hwm_input_shape_packet_encode_clear(bytes, sizeof(bytes))) return false;
    if (hwm_sa_batch_depth > 0 && hwm_sa_batch_barrier) hwm_sa_batch_barrier();
    if (!hwm_sa_pipeline_flush(&hwm_sa_pipeline) || !hwm_sa_plane_flush()) return false;
    return hwm_sa_input_shape_send(bytes, sizeof(bytes));
}

bool scripting_addition_set_plane_transform_xy(uint32_t wid, double x, double y, double scale_x, double scale_y)
{
    if (!scripting_addition_plane_supported() || !wid || !isfinite(scale_x) || scale_x <= 0 ||
        !isfinite(scale_y) || scale_y <= 0) return false;
    if (isnan(x) || isnan(y)) {
        CGRect native = CGRectNull;
        if (!(isnan(x) && isnan(y)) || scale_x != 1 || scale_y != 1 ||
            SLSGetWindowBounds(SLSMainConnectionID(), wid, &native) != kCGErrorSuccess ||
            !isfinite(native.origin.x) || !isfinite(native.origin.y)) return false;
        x = native.origin.x;
        y = native.origin.y;
    }
    HwmPlaneTransform transform = { wid, x, y, scale_x, scale_y };
    if (!hwm_plane_transform_valid(transform)) return false;
    if (hwm_sa_plane_transform_count == SA_PLANE_TRANSFORM_MAX_RECORDS) {
        if(hwm_sa_batch_barrier) hwm_sa_batch_barrier();
        if(!hwm_sa_plane_flush()) return false;
    }
    hwm_sa_plane_transforms[hwm_sa_plane_transform_count++] = transform;
    return hwm_sa_batch_depth > 0 || hwm_sa_plane_flush();
}

bool scripting_addition_set_plane_transform(uint32_t wid, double x, double y, double scale)
{
    return scripting_addition_set_plane_transform_xy(wid, x, y, scale, scale);
}


bool scripting_addition_focus_space(uint64_t sid)
{
    if (hwm_sa_capabilities_known && !(hwm_sa_capabilities & OSAX_ATTRIB_DOCK_SPACES)) return false;
    sa_payload_init();
    pack(sid);
    return sa_payload_send(SA_OPCODE_SPACE_FOCUS);
}

bool scripting_addition_create_space(uint64_t sid)
{
    sa_payload_init();
    pack(sid);
    return sa_payload_send(SA_OPCODE_SPACE_CREATE);
}

bool scripting_addition_destroy_space(uint64_t sid)
{
    sa_payload_init();
    pack(sid);
    return sa_payload_send(SA_OPCODE_SPACE_DESTROY);
}

bool scripting_addition_move_space_to_display(uint64_t src_sid, uint64_t dst_sid, uint64_t src_prev_sid, bool focus)
{
    sa_payload_init();
    pack(src_sid);
    pack(dst_sid);
    pack(src_prev_sid);
    pack(focus);
    return sa_payload_send(SA_OPCODE_SPACE_MOVE);
}

bool scripting_addition_move_space_after_space(uint64_t src_sid, uint64_t dst_sid, bool focus)
{
    uint64_t dummy_sid = 0;
    sa_payload_init();
    pack(src_sid);
    pack(dst_sid);
    pack(dummy_sid);
    pack(focus);
    return sa_payload_send(SA_OPCODE_SPACE_MOVE);
}

bool scripting_addition_move_window(uint32_t wid, int x, int y)
{
    sa_payload_init();
    pack(wid);
    pack(x);
    pack(y);
    return sa_payload_send(SA_OPCODE_WINDOW_MOVE);
}

bool scripting_addition_set_opacity(uint32_t wid, float opacity, float duration)
{
    sa_payload_init();
    pack(wid);
    pack(opacity);
    pack(duration);
    return sa_payload_send(duration > 0.0f ? SA_OPCODE_WINDOW_OPACITY_FADE : SA_OPCODE_WINDOW_OPACITY);
}

bool scripting_addition_set_layer(uint32_t wid, int layer)
{
    sa_payload_init();
    pack(wid);
    pack(layer);
    return sa_payload_send(SA_OPCODE_WINDOW_LAYER);
}

bool scripting_addition_set_sticky(uint32_t wid, bool sticky)
{
    sa_payload_init();
    pack(wid);
    pack(sticky);
    return sa_payload_send(SA_OPCODE_WINDOW_STICKY);
}

bool scripting_addition_set_shadow(uint32_t wid, bool shadow)
{
    sa_payload_init();
    pack(wid);
    pack(shadow);
    return sa_payload_send(SA_OPCODE_WINDOW_SHADOW);
}

bool scripting_addition_focus_window(uint32_t wid)
{
    sa_payload_init();
    pack(wid);
    return sa_payload_send(SA_OPCODE_WINDOW_FOCUS);
}

bool scripting_addition_scale_window(uint32_t wid, float x, float y, float w, float h)
{
    sa_payload_init();
    pack(wid);
    pack(x);
    pack(y);
    pack(w);
    pack(h);
    return sa_payload_send(SA_OPCODE_WINDOW_SCALE);
}


bool scripting_addition_swap_window_proxy_in(struct window_animation *animation_list, int animation_count)
{
    uint32_t dummy_wid = 0;
    sa_payload_init();
    pack(animation_count);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&animation_list[i].skip, __ATOMIC_RELAXED)) {
            pack(dummy_wid);
        } else {
            pack(animation_list[i].wid);
            pack(animation_list[i].proxy.id);
        }
    }
    return sa_payload_send(SA_OPCODE_WINDOW_SWAP_PROXY_IN);
}

bool scripting_addition_swap_window_proxy_out(struct window_animation *animation_list, int animation_count)
{
    uint32_t dummy_wid = 0;
    sa_payload_init();
    pack(animation_count);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&animation_list[i].skip, __ATOMIC_RELAXED)) {
            pack(dummy_wid);
        } else {
            pack(animation_list[i].wid);
            pack(animation_list[i].proxy.id);
        }
    }
    return sa_payload_send(SA_OPCODE_WINDOW_SWAP_PROXY_OUT);
}

bool scripting_addition_order_window(uint32_t a_wid, int order, uint32_t b_wid)
{
    sa_payload_init();
    pack(a_wid);
    pack(order);
    pack(b_wid);
    return sa_payload_send(SA_OPCODE_WINDOW_ORDER);
}

extern int g_connection;
bool scripting_addition_order_window_in(uint32_t *window_list, int window_count)
{
    uint32_t dummy_wid = 0;
    uint8_t ordered_in = 0;

    sa_payload_init();
    pack(window_count);
    for (int i = 0; i < window_count; ++i) {
        SLSWindowIsOrderedIn(g_connection, window_list[i], &ordered_in);
        if (ordered_in) {
            pack(dummy_wid);
        } else {
            pack(window_list[i]);
        }
    }
    return sa_payload_send(SA_OPCODE_WINDOW_ORDER_IN);
}

bool scripting_addition_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count)
{
    sa_payload_init();
    pack(sid);
    pack(window_count);
    for (int i = 0; i < window_count; ++i) {
        pack(window_list[i]);
    }
    return sa_payload_send(SA_OPCODE_WINDOW_LIST_TO_SPACE);
}

bool scripting_addition_move_window_to_space(uint64_t sid, uint32_t wid)
{
    sa_payload_init();
    pack(sid);
    pack(wid);
    return sa_payload_send(SA_OPCODE_WINDOW_TO_SPACE);
}

#undef sa_payload_init
#undef pack
#undef sa_payload_send
