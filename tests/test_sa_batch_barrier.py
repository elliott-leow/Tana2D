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
#include "vendor/yabai/src/misc/plane_transform.h"
typedef struct { int unused; } HwmSaPipeline;
static const char *g_sa_socket_file="unused";
static bool hwm_sa_capabilities_known=true;
static unsigned hwm_sa_capabilities=OSAX_ATTRIB_PLANE_TRANSFORM;
static int barriers,packets,ordinary;
static bool require_guard,failed;
static void barrier(void) { barriers++; }
static bool hwm_sa_pipeline_flush(HwmSaPipeline *p) { (void)p; return true; }
static bool hwm_sa_pipeline_send(HwmSaPipeline *p,const char *s,const char *b,size_t n,int t)
{ (void)p;(void)s;(void)b;(void)n;(void)t; assert(barriers); ordinary++; return true; }
static bool hwm_sa_send(const char *s,const char *b,size_t n,int t)
{ (void)s;(void)b;(void)n;(void)t; ordinary++; return true; }
static long long hwm_sa_monotonic_ms(void) { return 1; }
static int hwm_sa_connect(const char *s,long long t) { (void)s;(void)t; return dup(STDERR_FILENO); }
static bool hwm_sa_send_all(int f,const unsigned char *b,size_t n,long long t)
{ (void)f;(void)b;(void)n;(void)t; if(require_guard) assert(barriers); packets++; return !failed; }
static bool hwm_sa_receive_byte(int f,unsigned char *b,long long t) { (void)f;(void)t; *b=1; return true; }
static int SLSMainConnectionID(void) { return 0; }
static CGError SLSGetWindowBounds(int c,uint32_t w,CGRect *r) { (void)c;(void)w; *r=CGRectMake(1,2,300,200); return kCGErrorSuccess; }
'''
        checks = r'''
static void reset(void) { assert(!hwm_sa_batch_depth && !hwm_sa_plane_transform_count); barriers=packets=ordinary=0; require_guard=failed=false; scripting_addition_batch_set_barrier(barrier); }
static void transform(int i) { assert(scripting_addition_set_plane_transform(i+1,i,20,.7)); }
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
