"""Check the empty-desktop stop and scrolling reversals with Tana2D running.

Uses real WindowServer geometry and restores the original camera and focus.
Leave the pointer idle. Build tests/window_metrics.m before running.
"""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output([str(ROOT / 'build/tana2d'), '-m', *map(str, args)], text=True)


def status():
    return json.loads(command('strip', 'status'))


def metrics(ids):
    return json.loads(subprocess.check_output(
        [str(ROOT / 'build/window_metrics'), *map(str, ids)], text=True))


initial = status()
assert initial['ready'] and initial['backend'] and not initial['paused']
inputs = json.loads(command('strip', 'input-status'))
assert not inputs['overview'] and not inputs['suspended']
tiles = [w for w in initial['windows'] if w['strip'] == initial['strip']]
assert tiles
ids = [w['id'] for w in tiles]
windows = json.loads(command('query', '--windows'))
focused = next((w['id'] for w in windows if w['has-focus']), None)
display_id = next(w['display'] for w in windows if w['id'] == ids[0])
display = next(d['frame'] for d in json.loads(command('query', '--displays')) if d['index'] == display_id)
report = {'checks': []}

try:
    command('strip', 'scroll', 0)
    time.sleep(.7)
    baseline = status()
    sizes = {w['id']: (w['w'], w['h']) for w in metrics(ids)}
    for cycle in range(3):
        # Reverse while the first movement is still in progress.
        command('strip', 'scroll', 1000000)
        time.sleep(.07)
        command('strip', 'scroll', 0)
        time.sleep(.07)
        command('strip', 'scroll', 1000000)
        time.sleep(.8)
        end = status()
        actual = metrics(ids)
        assert end['backend'] and end['move_failures'] == baseline['move_failures'], end
        assert {w['id'] for w in end['windows']} == {w['id'] for w in initial['windows']}
        for w in actual:
            # Reserve enough space for native shadows and attached borders.
            assert w['x'] + w['w'] <= display['x'] - 100, w
            assert (w['w'], w['h']) == sizes[w['id']], w
            assert abs(w['a'] - 1) < .00001 and abs(w['d'] - 1) < .00001, w
        command('strip', 'scroll', 1000000)
        time.sleep(.4)
        repeated = status()
        assert abs(repeated['offset'] - end['offset']) < 1, ('right boundary is not stable', end, repeated)
        report['checks'].append({'cycle': cycle + 1, 'offset': end['offset'],
                                 'rightmost_edge': max(w['x'] + w['w'] for w in actual)})
        command('strip', 'scroll', 0)
        time.sleep(.6)
        assert abs(status()['offset']) < 1, 'left boundary changed'
    assert status()['resize_operations'] == baseline['resize_operations'], 'panning resized windows'
    report['pan_resize_operations'] = 0
    (ROOT / 'build/scroll-boundary-check.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
finally:
    if focused:
        command('window', focused, '--focus')
    command('strip', 'scroll', initial['offset'])
