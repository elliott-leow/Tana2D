/* A lease holds one explicit event shape.  Its saved region is the shape that
 * existed before our first override; it is never re-snapshotted on refresh. */
static pthread_mutex_t input_shape_lock;
static pthread_t input_shape_cleanup_thread;
static HwmInputShapeLease input_shape_lease;
static int input_shape_window_cid;
static CFTypeRef input_shape_original_region;
static CFTypeRef input_shape_override_region;
static CFTypeRef input_shape_previous_override_region;
static bool input_shape_original_default;

enum input_shape_override_state { INPUT_SHAPE_OVERRIDE_MATCHES, INPUT_SHAPE_OVERRIDE_CHANGED, INPUT_SHAPE_OVERRIDE_UNKNOWN };

static long long input_shape_monotonic_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (long long) now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool input_shape_pid_alive(int pid)
{
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

static void input_shape_discard_locked(void)
{
    if (input_shape_original_region) CFRelease(input_shape_original_region);
    if (input_shape_override_region) CFRelease(input_shape_override_region);
    if (input_shape_previous_override_region) CFRelease(input_shape_previous_override_region);
    input_shape_original_region = NULL;
    input_shape_override_region = NULL;
    input_shape_previous_override_region = NULL;
    input_shape_original_default = false;
    input_shape_window_cid = 0;
    memset(&input_shape_lease, 0, sizeof(input_shape_lease));
}

/* CFEqual on CGSRegion is identity-only. Compare the actual private region
 * geometry before undoing our lease so an application's newer shape wins. */
static enum input_shape_override_state input_shape_override_state_locked(void)
{
    if (!input_shape_override_region) return INPUT_SHAPE_OVERRIDE_UNKNOWN;
    CFTypeRef current = NULL;
    CGError result = SLSCopySpecifiedWindowShape(SLSMainConnectionID(), input_shape_lease.wid, 9, &current);
    if (result == 1000 && !current) return INPUT_SHAPE_OVERRIDE_CHANGED;
    if (result != kCGErrorSuccess || !current) {
        if (current) CFRelease(current);
        return INPUT_SHAPE_OVERRIDE_UNKNOWN;
    }
    bool equal = CGRegionEqualToRegion(current, input_shape_override_region) ||
                 (input_shape_previous_override_region && CGRegionEqualToRegion(current, input_shape_previous_override_region));
    if (current) CFRelease(current);
    return equal ? INPUT_SHAPE_OVERRIDE_MATCHES : INPUT_SHAPE_OVERRIDE_CHANGED;
}

/* Window IDs can be reused. Restore only while this exact WindowServer owner
 * still owns the ID; otherwise dropping the lease is safer than altering a
 * newly-created window. */
static bool input_shape_restore_locked(void)
{
    if (!input_shape_lease.active) return true;
    int owner = 0;
    if (SLSGetWindowOwner(SLSMainConnectionID(), input_shape_lease.wid, &owner) != kCGErrorSuccess ||
        owner != input_shape_window_cid) {
        input_shape_discard_locked();
        return false;
    }
    /* A native resize does not prove the application replaced its event
     * shape. If type 9 still equals our retained override, restore the exact
     * saved region; otherwise the app's newer shape wins below. */
    enum input_shape_override_state override_state = input_shape_override_state_locked();
    if (override_state == INPUT_SHAPE_OVERRIDE_CHANGED) {
        input_shape_discard_locked();
        return false;
    }
    /* A read failure is not evidence that the application replaced the shape.
     * Preserve the exact original and let the watchdog retry the restoration. */
    if (override_state == INPUT_SHAPE_OVERRIDE_UNKNOWN) return false;
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return false;
    /* NULL through a transaction restores the WindowServer default. Direct
     * SLSSetWindowEventShape(NULL) does not reliably do so. */
    SLSTransactionSetWindowEventShape(transaction, input_shape_lease.wid,
                                      input_shape_original_default ? NULL : input_shape_original_region);
    SLSTransactionCommit(transaction, 1);
    CFRelease(transaction);
    CFTypeRef restored = NULL;
    CGError restored_error = SLSCopySpecifiedWindowShape(SLSMainConnectionID(), input_shape_lease.wid, 9, &restored);
    bool restored_ok = input_shape_original_default ? (restored_error == 1000 && !restored) :
                       (restored_error == kCGErrorSuccess && restored && CGRegionEqualToRegion(restored, input_shape_original_region));
    if (restored) CFRelease(restored);
    /* Keep all rollback references until a read proves the transaction took
     * effect. The cleanup tick will retry a transient WindowServer failure. */
    if (!restored_ok) return false;
    input_shape_discard_locked();
    return true;
}

static bool input_shape_capture_locked(uint32_t wid)
{
    int owner = 0;
    if (SLSGetWindowOwner(SLSMainConnectionID(), wid, &owner) != kCGErrorSuccess || !owner) return false;
    CFTypeRef region = NULL;
    CGError result = SLSCopySpecifiedWindowShape(SLSMainConnectionID(), wid, 9, &region);
    if (result == kCGErrorSuccess && region) {
        input_shape_original_region = region;
        input_shape_original_default = false;
    } else if (result == 1000 && !region) {
        /* 1000 means default for type 9 only after the owner check above. */
        input_shape_original_default = true;
    } else {
        if (region) CFRelease(region);
        return false;
    }
    input_shape_window_cid = owner;
    CGRect native_bounds;
    if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &native_bounds) != kCGErrorSuccess) {
        input_shape_discard_locked();
        return false;
    }
    return true;
}

static bool input_shape_apply_locked(uint32_t wid, CGRect rect)
{
    /* A refresh may update the rectangle, but never replaces an app-owned
     * shape that appeared since our prior ACK. */
    if (input_shape_lease.active && input_shape_override_region) {
        enum input_shape_override_state old_state = input_shape_override_state_locked();
        if (old_state == INPUT_SHAPE_OVERRIDE_CHANGED) { input_shape_discard_locked(); return false; }
        if (old_state == INPUT_SHAPE_OVERRIDE_UNKNOWN) return false;
    }
    bool had_override = input_shape_override_region != NULL;
    CFTypeRef region = NULL;
    if (CGSNewRegionWithRect(&rect, &region) != kCGErrorSuccess || !region) {
        if (region) CFRelease(region);
        if (!had_override) input_shape_discard_locked();
        return false;
    }
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) {
        CFRelease(region);
        /* On the first acquire no event shape was submitted, so retaining a
         * lease only makes a later clear attempt ambiguous. */
        if (!had_override) input_shape_discard_locked();
        return false;
    }
    /* Retain the intended override before mutation. If the post-commit probe
     * fails, restore can still establish that this was our shape. */
    if (input_shape_previous_override_region) CFRelease(input_shape_previous_override_region);
    input_shape_previous_override_region = input_shape_override_region;
    input_shape_override_region = CFRetain(region);
    SLSTransactionSetWindowEventShape(transaction, wid, region);
    SLSTransactionCommit(transaction, 1);
    CFRelease(transaction);
    /* A successful explicit type-9 read is the only available transaction
     * acknowledgement. Verify it before replying to the client. */
    CFTypeRef applied = NULL;
    CGError result = SLSCopySpecifiedWindowShape(SLSMainConnectionID(), wid, 9, &applied);
    bool success = result == kCGErrorSuccess && applied && CGRegionEqualToRegion(applied, region);
    if (applied) CFRelease(applied);
    if (success && input_shape_previous_override_region) {
        CFRelease(input_shape_previous_override_region);
        input_shape_previous_override_region = NULL;
    }
    CFRelease(region);
    return success;
}

static bool do_window_input_shape(int peer_pid, const unsigned char *message, size_t length)
{
    bool clear = false;
    HwmInputShapeRequest request;
    /* Decode every byte before acquiring a lease or touching WindowServer. */
    if (peer_pid <= 0 || !hwm_input_shape_packet_decode(message, length, &clear, &request)) return false;
    long long now = input_shape_monotonic_ms();
    if (now < 0) return false;
    pthread_mutex_lock(&input_shape_lock);
    if (input_shape_lease.active &&
        (!input_shape_pid_alive(input_shape_lease.owner_pid) || !hwm_input_shape_lease_is_live(&input_shape_lease, now))) {
        if (!input_shape_restore_locked()) { pthread_mutex_unlock(&input_shape_lock); return false; }
    }
    if (clear) {
        bool success = !input_shape_lease.active ||
                       (input_shape_lease.owner_pid == peer_pid && input_shape_restore_locked());
        pthread_mutex_unlock(&input_shape_lock);
        return success;
    }
    if (input_shape_lease.active && input_shape_lease.owner_pid != peer_pid) {
        pthread_mutex_unlock(&input_shape_lock);
        return false;
    }
    if (input_shape_lease.active && input_shape_lease.wid != request.wid) {
        if (!input_shape_restore_locked()) { pthread_mutex_unlock(&input_shape_lock); return false; }
    }
    if (!input_shape_lease.active && !input_shape_capture_locked(request.wid)) {
        pthread_mutex_unlock(&input_shape_lock);
        return false;
    }
    /* Mark the saved target before applying so any post-transaction check
     * failure has a complete restoration record. The mutex keeps this
     * transient state invisible to the expiry thread. */
    if (!input_shape_lease.active) hwm_input_shape_lease_refresh(&input_shape_lease, peer_pid, request.wid, now);
    if (!input_shape_apply_locked(request.wid, request.rect)) {
        input_shape_restore_locked();
        pthread_mutex_unlock(&input_shape_lock);
        return false;
    }
    hwm_input_shape_lease_refresh(&input_shape_lease, peer_pid, request.wid, now);
    pthread_mutex_unlock(&input_shape_lock);
    return true;
}

static void input_shape_cleanup_tick(long long now)
{
    pthread_mutex_lock(&input_shape_lock);
    if (input_shape_lease.active &&
        (!input_shape_pid_alive(input_shape_lease.owner_pid) || !hwm_input_shape_lease_is_live(&input_shape_lease, now))) {
        input_shape_restore_locked();
    }
    pthread_mutex_unlock(&input_shape_lock);
}

static void *__attribute__((unused)) input_shape_cleanup(void *unused)
{
    (void) unused;
    for (;;) {
        struct timespec delay = { 0, 50 * 1000 * 1000 };
        nanosleep(&delay, NULL);
        long long now = input_shape_monotonic_ms();
        if (now < 0) continue;
        input_shape_cleanup_tick(now);
    }
    return NULL;
}
