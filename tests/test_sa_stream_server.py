"""Run the helper's connection loop over real sockets, with a stub command handler."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class StreamServerTest(unittest.TestCase):
    def test_kept_open_connections(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'vendor/yabai/src/osax/payload.m').read_text()
        server = source.split('static inline bool read_message', 1)[1]
        server = 'static inline bool read_message' + server.split('static TABLE_HASH_FUNC(hash_wid)', 1)[0]
        harness = r'''
#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <semaphore.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include "vendor/yabai/src/osax/common.h"
#include "src/sa_transport.h"
static int daemon_sockfd;
static unsigned char served[64]; static int served_count;
static dispatch_semaphore_t gate_entered, gate_open;
/* Records each packet's second byte; 0 is refused, 99 holds the thread. */
static bool handle_message(int sockfd, int peer_pid, char *message, size_t length)
{
    (void)sockfd; assert(length >= 2 && peer_pid == getpid());
    unsigned char value = (unsigned char) message[1];
    served[served_count++] = value;
    if (value == 99) { dispatch_semaphore_signal(gate_entered); dispatch_semaphore_wait(gate_open, DISPATCH_TIME_FOREVER); }
    return value != 0;
}
'''
        checks = r'''
static char path[104];
static const unsigned char hello[] = { 1, 0, SA_OPCODE_PLANE_STREAM };
static long long later(void) { return hwm_sa_monotonic_ms() + 2000; }
static int stream_open(unsigned char *acknowledgement)
{
    int fd = hwm_sa_connect(path, later());
    assert(fd >= 0 && hwm_sa_send_all(fd, hello, sizeof(hello), later()));
    assert(hwm_sa_receive_byte(fd, acknowledgement, later()));
    return fd;
}
static void put(int fd, unsigned char opcode, unsigned char value)
{
    const unsigned char packet[] = { 2, 0, opcode, value };
    assert(hwm_sa_send_all(fd, packet, sizeof(packet), later()));
}
static unsigned char reply(int fd) { unsigned char byte = 9; assert(hwm_sa_receive_byte(fd, &byte, later())); return byte; }
static bool closed(int fd) { unsigned char byte; return !hwm_sa_receive_byte(fd, &byte, later()); }
static unsigned char once(unsigned char value)
{
    int fd = hwm_sa_connect(path, later()); put(fd, SA_OPCODE_WINDOW_PLANE_TRANSFORM, value);
    unsigned char byte = reply(fd); assert(closed(fd)); close(fd); return byte;
}
static void gate(void) { dispatch_semaphore_wait(gate_entered, DISPATCH_TIME_FOREVER); }

int main(void)
{
    gate_entered = dispatch_semaphore_create(0); gate_open = dispatch_semaphore_create(0);
    snprintf(path, sizeof(path), "/tmp/tana2d-stream-%d.socket", getpid());
    unlink(path);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);
    daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(daemon_sockfd >= 0 && !bind(daemon_sockfd, (struct sockaddr *) &address, sizeof(address)) && !listen(daemon_sockfd, SOMAXCONN));
    pthread_t thread; assert(!pthread_create(&thread, NULL, handle_connection, NULL));

    /* A packet on a connection of its own: one reply, then closed, as before. */
    assert(once(7) == 1 && once(0) == 0 && served_count == 2);

    /* Kept open: packets sent back to back are applied and answered in order. */
    unsigned char acknowledgement = 0;
    int stream = stream_open(&acknowledgement); assert(acknowledgement == 1);
    put(stream, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 1); put(stream, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 0);
    put(stream, SA_OPCODE_WINDOW_INPUT_SHAPE, 3);
    assert(reply(stream) == 1 && reply(stream) == 0 && reply(stream) == 1);
    assert(served_count == 5 && served[2] == 1 && served[3] == 0 && served[4] == 3);
    /* Anything answered in another shape is refused there and not run. */
    put(stream, SA_OPCODE_WINDOW_ORDER, 5); assert(reply(stream) == 0 && served_count == 5);
    put(stream, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 6); assert(reply(stream) == 1 && served_count == 6);

    /* A packet already on a kept-open connection goes before a connection
     * made after it. */
    int held = hwm_sa_connect(path, later()); put(held, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 99); gate();
    put(stream, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 10);
    int after = hwm_sa_connect(path, later()); put(after, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 11);
    dispatch_semaphore_signal(gate_open);
    assert(reply(held) == 1 && reply(stream) == 1 && reply(after) == 1);
    assert(served[6] == 99 && served[7] == 10 && served[8] == 11);
    close(held); close(after);

    /* A bounded number are kept; a closed one frees its place. */
    int streams[PLANE_STREAM_MAX]; streams[0] = stream;
    for (int index = 1; index < PLANE_STREAM_MAX; ++index) { streams[index] = stream_open(&acknowledgement); assert(acknowledgement == 1); }
    int refused = stream_open(&acknowledgement); assert(acknowledgement == 0 && closed(refused)); close(refused);
    close(streams[3]);
    streams[3] = stream_open(&acknowledgement); assert(acknowledgement == 1);
    for (int index = 0; index < PLANE_STREAM_MAX; ++index) { put(streams[index], SA_OPCODE_WINDOW_PLANE_TRANSFORM, 20); assert(reply(streams[index]) == 1); }

    /* The manager closing its end before a reply is written costs nothing:
     * no SIGPIPE, and the next packet is served. */
    held = hwm_sa_connect(path, later()); put(held, SA_OPCODE_WINDOW_PLANE_TRANSFORM, 99); gate();
    put(streams[0], SA_OPCODE_WINDOW_PLANE_TRANSFORM, 30); close(streams[0]);
    close(held);
    dispatch_semaphore_signal(gate_open);
    assert(once(31) == 1);

    /* A peer that stops partway through a packet is dropped, not waited on. */
    const unsigned char header[] = { 2, 0 };
    assert(hwm_sa_send_all(streams[1], header, sizeof(header), later()));
    assert(closed(streams[1]));
    assert(once(32) == 1);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'server.c').write_text(harness + server + checks)
            subprocess.run(['xcrun', 'clang', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                            '-Wno-unused-function', '-fsanitize=address,undefined', '-I', str(root),
                            str(path / 'server.c'), '-o', str(path / 'server')], check=True)
            subprocess.run([str(path / 'server')], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
