"""Compile the production batch sender against a deterministic helper transport."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class BatchBarrierTest(unittest.TestCase):
    def test_partial_publication_is_guarded(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'vendor/yabai/src/sa.m').read_text()
        batch = source.split('static __thread HwmSaPipeline hwm_sa_pipeline;', 1)[1]
        batch = 'static __thread HwmSaPipeline hwm_sa_pipeline;' + batch.split('bool scripting_addition_focus_space', 1)[0]
        harness = r'''
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include "vendor/yabai/src/misc/plane_transform.h"
#include "vendor/yabai/src/misc/input_shape.h"
typedef struct { int unused; } HwmSaPipeline;
#define HWM_SA_TIMEOUT_MS 50
static const char *g_sa_socket_file="unused";
static bool hwm_sa_capabilities_known=true;
static unsigned hwm_sa_capabilities=OSAX_ATTRIB_PLANE_TRANSFORM;
static int barriers,packets,ordinary,shapes,pipeline_flushes,receives,fail_sends;
static bool require_guard,failed,receive_failed,bad_ack;
static void barrier(void) { barriers++; }
static bool hwm_sa_pipeline_flush(HwmSaPipeline *p) { (void)p; pipeline_flushes++; return true; }
static bool hwm_sa_pipeline_send(HwmSaPipeline *p,const char *s,const char *b,size_t n,int t)
{ (void)p;(void)s;(void)b;(void)n;(void)t; assert(barriers); ordinary++; return true; }
static bool hwm_sa_send(const char *s,const char *b,size_t n,int t)
{ (void)s;(void)b;(void)n;(void)t; ordinary++; return true; }
static long long hwm_sa_monotonic_ms(void) { return 1; }
static int hwm_sa_connect(const char *s,long long t) { (void)s;(void)t; return dup(STDERR_FILENO); }
static bool hwm_sa_send_all(int f,const unsigned char *b,size_t n,long long t)
{ (void)f;(void)t; if(require_guard) assert(barriers); int16_t length=0; assert(n>=3); memcpy(&length,b,2); assert(length>0 && (size_t)length==n-2); if(b[2]==SA_OPCODE_WINDOW_INPUT_SHAPE){ bool clear; HwmInputShapeRequest request; assert(hwm_input_shape_packet_decode(b+3,n-3,&clear,&request)); shapes++; } packets++; if(fail_sends>0) { fail_sends--; return false; } return !failed; }
static bool hwm_sa_receive_byte(int f,unsigned char *b,long long t) { (void)f;(void)t; receives++; *b=bad_ack?0:1; return !receive_failed; }
static bool ready; // Whether the helper's reply to an in-flight frame has arrived.
static int hwm_sa_try_receive_byte(int f,unsigned char *b) { (void)f; if(!ready) return -1; receives++; *b=bad_ack?0:1; return receive_failed?0:1; }
static int SLSMainConnectionID(void) { return 0; }
static CGError SLSGetWindowBounds(int c,uint32_t w,CGRect *r) { (void)c;(void)w; *r=CGRectMake(1,2,300,200); return kCGErrorSuccess; }
'''
        checks = r'''
static void reset(void) { assert(!hwm_sa_batch_depth && !hwm_sa_plane_transform_count && !hwm_sa_plane_carried && !hwm_sa_plane_pending_count); barriers=packets=ordinary=shapes=pipeline_flushes=receives=0; require_guard=failed=receive_failed=bad_ack=ready=false; scripting_addition_batch_set_barrier(barrier); }
static void transform(int i) { assert(scripting_addition_set_plane_transform(i+1,i,20,.7)); }
static int thread_stream=-1;
static void *stream_thread(void *unused)
{ (void)unused; scripting_addition_batch_begin(); transform(8); assert(scripting_addition_batch_end()); thread_stream=hwm_sa_plane_stream; return NULL; }
int main(void) {
    reset(); scripting_addition_batch_begin(); transform(1);
    scripting_addition_batch_begin(); transform(2);
    assert(scripting_addition_batch_end() && !packets && !barriers);
    assert(scripting_addition_batch_end() && packets==1 && !barriers);
    reset(); scripting_addition_batch_begin(); transform(1); require_guard=true;
    assert(scripting_addition_batch_flush() && packets==1 && barriers==1);
    transform(2); assert(scripting_addition_batch_end() && packets==2);
    reset(); scripting_addition_batch_begin(); transform(1); require_guard=true;
    char command=0; assert(scripting_addition_send_bytes(&command,1));
    assert(barriers && packets==1 && ordinary==1); assert(scripting_addition_batch_end());
    reset(); scripting_addition_batch_begin(); require_guard=true;
    for(int i=0;i<SA_PLANE_TRANSFORM_MAX_RECORDS+1;i++) transform(i);
    assert(barriers==1 && packets==1); assert(scripting_addition_batch_end() && packets==2);
    reset(); scripting_addition_batch_begin();
    for(int i=0;i<SA_PLANE_TRANSFORM_MAX_RECORDS;i++) transform(i);
    require_guard=failed=true;
    assert(!scripting_addition_set_plane_transform(999,0,0,1));
    assert(barriers==1 && packets==1 && !hwm_sa_plane_transform_count);
    failed=false; assert(scripting_addition_batch_end());
    reset(); scripting_addition_batch_set_barrier(NULL); transform(1);
    assert(packets==1 && !barriers);
    reset(); assert(!scripting_addition_set_input_shape(1,CGRectMake(0,0,100,100)) && !packets);
    hwm_sa_capabilities |= OSAX_ATTRIB_INPUT_SHAPE;
    assert(scripting_addition_set_input_shape(1,CGRectMake(0,0,100,100)) && shapes==1 && pipeline_flushes);
    assert(scripting_addition_clear_input_shape() && shapes==2);
    bad_ack=true; assert(!scripting_addition_clear_input_shape()); bad_ack=false;
    receive_failed=true; assert(!scripting_addition_clear_input_shape()); receive_failed=false;
    failed=true; assert(!scripting_addition_clear_input_shape()); failed=false;
    reset(); scripting_addition_batch_begin(); transform(1); require_guard=true;
    assert(scripting_addition_set_input_shape(1,CGRectMake(0,0,100,100)));
    assert(barriers && packets==2 && shapes==1 && !hwm_sa_plane_transform_count);
    assert(scripting_addition_batch_end());
    /* A deferred frame is sent at once; its reply is read on the next settle. */
    reset(); scripting_addition_batch_begin(); transform(1); transform(2);
    assert(scripting_addition_batch_end_deferred() && packets==1 && !receives && hwm_sa_plane_pending_count==1);
    assert(scripting_addition_settle() && receives==1 && !hwm_sa_plane_pending_count);
    assert(scripting_addition_settle() && receives==1);
    /* A second frame goes out while the first's reply is outstanding; a third
     * is held, its records carried, with the newest record for a window
     * replacing the one carried. Replies that have arrived are read without
     * waiting; the held records go with the next frame once there is room. */
    reset(); scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred() && packets==1 && hwm_sa_plane_pending_count==1);
    scripting_addition_batch_begin(); transform(2);
    assert(scripting_addition_batch_end_deferred() && packets==2 && !receives && hwm_sa_plane_pending_count==2);
    scripting_addition_batch_begin(); transform(3); assert(scripting_addition_set_plane_transform(7,0,0,.5));
    assert(scripting_addition_batch_end_deferred() && packets==2 && hwm_sa_plane_transform_count==2 && hwm_sa_plane_carried==2);
    scripting_addition_batch_begin(); assert(scripting_addition_set_plane_transform(7,9,9,.6)); transform(5);
    assert(hwm_sa_plane_transform_count==3 && hwm_sa_plane_transforms[1].x==9 && hwm_sa_plane_transforms[1].scale_x==.6);
    assert(scripting_addition_batch_end_deferred() && packets==2 && hwm_sa_plane_carried==3 && !receives);
    ready=true; scripting_addition_batch_begin(); transform(6);
    assert(scripting_addition_batch_end_deferred() && receives==2 && packets==3 && !hwm_sa_plane_transform_count && !hwm_sa_plane_carried && hwm_sa_plane_pending_count==1);
    assert(scripting_addition_settle() && receives==3 && !hwm_sa_plane_pending_count);
    /* Held records are applied, and waited for, before anything reads geometry. */
    reset(); scripting_addition_batch_begin(); transform(1); assert(scripting_addition_batch_end_deferred());
    scripting_addition_batch_begin(); transform(2); assert(scripting_addition_batch_end_deferred());
    scripting_addition_batch_begin(); transform(3); assert(scripting_addition_batch_end_deferred() && packets==2 && hwm_sa_plane_carried==1);
    assert(scripting_addition_settle() && packets==3 && receives==3 && !hwm_sa_plane_carried && !hwm_sa_plane_pending_count);
    reset(); scripting_addition_batch_begin(); transform(1); assert(scripting_addition_batch_end_deferred());
    scripting_addition_batch_begin(); transform(2); assert(scripting_addition_batch_end_deferred());
    scripting_addition_batch_begin(); transform(3); assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_carried==1);
    assert(scripting_addition_send_bytes(&command,1) && packets==3 && receives==3 && ordinary==1 && !hwm_sa_plane_carried);
    /* A refused frame among those in flight surfaces at the next deferred end. */
    reset(); scripting_addition_batch_begin(); transform(1); assert(scripting_addition_batch_end_deferred());
    scripting_addition_batch_begin(); transform(2); assert(scripting_addition_batch_end_deferred());
    ready=bad_ack=true; scripting_addition_batch_begin(); transform(3);
    assert(!scripting_addition_batch_end_deferred()); bad_ack=false;
    assert(scripting_addition_settle());
    /* A failed reply surfaces at the next settle. */
    reset(); scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred()); bad_ack=true;
    assert(!scripting_addition_settle()); bad_ack=false;
    /* Anything else sent to the helper first collects the outstanding reply. */
    reset(); scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred() && !receives);
    assert(scripting_addition_send_bytes(&command,1) && receives==1 && ordinary==1);
    reset(); scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred()); bad_ack=ready=true;
    scripting_addition_batch_begin(); transform(2);
    assert(!scripting_addition_batch_end_deferred()); bad_ack=ready=false;
    assert(scripting_addition_settle());
    /* Nested deferred ends only close the batch. */
    reset(); scripting_addition_batch_begin(); scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred() && !packets);
    assert(scripting_addition_batch_end_deferred() && packets==1);
    assert(scripting_addition_settle());
    /* A helper that offers it gets one kept-open connection: a hello the
     * first time, then each frame on it, replies read from it in order. */
    reset(); hwm_sa_capabilities |= OSAX_ATTRIB_PLANE_STREAM;
    scripting_addition_batch_begin(); transform(1);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream>=0 && packets==2 && receives==1);
    assert(hwm_sa_plane_pending_count==1 && hwm_sa_plane_pending_fds[0]==HWM_SA_PLANE_ON_STREAM);
    int stream=hwm_sa_plane_stream;
    scripting_addition_batch_begin(); transform(2);
    assert(scripting_addition_batch_end_deferred() && packets==3 && hwm_sa_plane_stream==stream && hwm_sa_plane_pending_count==2);
    ready=true; assert(scripting_addition_settle() && receives==3 && !hwm_sa_plane_pending_count && hwm_sa_plane_stream==stream);
    assert(scripting_addition_clear_input_shape() && shapes==1 && packets==4 && hwm_sa_plane_stream==stream);
    /* A reply that never comes closes it, so a late one is not read as the
     * next frame's; the next frame opens another. */
    ready=false; scripting_addition_batch_begin(); transform(3); assert(scripting_addition_batch_end_deferred());
    ready=receive_failed=true; assert(!scripting_addition_settle() && hwm_sa_plane_stream<0 && !hwm_sa_plane_pending_count);
    ready=receive_failed=false; packets=0; scripting_addition_batch_begin(); transform(4);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream>=0 && packets==2);
    ready=true; assert(scripting_addition_settle());
    /* A connection Dock closed: the frame goes on one of its own, and the
     * next opens a new connection, behind the frame still waiting. */
    ready=false; fail_sends=1; packets=0; scripting_addition_batch_begin(); transform(5);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream<0 && packets==2);
    assert(hwm_sa_plane_pending_count==1 && hwm_sa_plane_pending_fds[0]>=0);
    scripting_addition_batch_begin(); transform(6);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream>=0 && packets==4);
    assert(hwm_sa_plane_pending_count==2 && hwm_sa_plane_pending_fds[0]>=0 && hwm_sa_plane_pending_fds[1]==HWM_SA_PLANE_ON_STREAM);
    ready=true; assert(scripting_addition_settle() && !hwm_sa_plane_pending_count && hwm_sa_plane_stream>=0);
    /* Another thread has its own, closed when that thread ends. */
    pthread_t thread; assert(!pthread_create(&thread,NULL,stream_thread,NULL) && !pthread_join(thread,NULL));
    assert(thread_stream>=0 && thread_stream!=hwm_sa_plane_stream && fcntl(thread_stream,F_GETFD)==-1);
    /* A refused hello: a connection per frame, without asking again at once. */
    hwm_sa_plane_stream_close(); ready=false; bad_ack=true; packets=0;
    scripting_addition_batch_begin(); transform(7);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream<0 && packets==2 && hwm_sa_plane_pending_fds[0]>=0);
    bad_ack=false; ready=true; assert(scripting_addition_settle());
    packets=0; scripting_addition_batch_begin(); transform(8);
    assert(scripting_addition_batch_end_deferred() && hwm_sa_plane_stream<0 && packets==1);
    assert(scripting_addition_settle());
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'batch.m').write_text(harness + batch + checks)
            subprocess.run(['xcrun', 'clang', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-I', str(root), str(path / 'batch.m'),
                            '-framework', 'Cocoa', '-o', str(path / 'batch')], check=True)
            subprocess.run([str(path / 'batch')], check=True)
