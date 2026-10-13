"""Catch transient AppKit edge clamping, not just settled window geometry.

Run with Tana2D and window_metrics built and the pointer idle. Restores the
original strip, horizontal camera and focus, without changing window layout.
"""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def command(*parts):
    return subprocess.check_output([str(ROOT / 'build/tana2d'), '-m', *map(str, parts)], text=True)


def status():
    return json.loads(command('strip', 'status'))


def metrics(ids):
    return json.loads(subprocess.check_output([str(ROOT / 'build/window_metrics'), *map(str, ids)], text=True))


initial = status()
assert initial['ready'] and initial['backend'] and not initial['paused']
assert not json.loads(command('strip', 'input-status'))['overview']
ids = [w['id'] for w in initial['windows'] if w['strip'] == initial['strip']]
assert ids
focused = next((w['id'] for w in json.loads(command('query', '--windows')) if w['has-focus']), None)
other_strip = 2 if initial['strip'] == 1 else 1
report = {'checks': []}


def hidden_samples(label, border_ids, duration=.45):
    samples = []
    started = time.monotonic()
    while time.monotonic() - started < duration:
        actual = metrics(ids + border_ids)
        assert all(w['alpha'] == 0 for w in actual), (label, actual)
        samples.append({'time': round(time.monotonic() - started, 3),
                        'frames': [{k: w[k] for k in ('id', 'x', 'y', 'alpha')} for w in actual]})
    report['checks'].append({'transition': label, 'hidden_samples': samples})


try:
    command('strip', 'scroll', 0)
    time.sleep(.7)
    baseline = status()
    before = metrics(ids)
    # Match only borders belonging to the tested strip, including off-screen ones.
    borders = metrics(['--borders'])
    border_ids = [b['id'] for b in borders if any(
        abs(b['x'] + b['w']/2 - w['x'] - w['w']/2) < 2 and
        abs(b['y'] + b['h']/2 - w['y'] - w['h']/2) < 2 and
        0 <= b['w'] - w['w'] <= 128 and abs(b['w'] - w['w'] - b['h'] + w['h']) < 2
        for w in before)]
    for cycle in range(2):
        command('strip', f'strip-{other_strip}')
        time.sleep(.2)
        hidden_samples(f'vertical-{cycle + 1}', border_ids)
        command('strip', f'strip-{initial["strip"]}')
        time.sleep(.7)
        command('strip', 'scroll', 1000000)
        time.sleep(.55)
        hidden_samples(f'right-edge-{cycle + 1}', border_ids, .25)
        command('strip', 'scroll', 0)
        time.sleep(.7)
        # Reverse a vertical transition before it has finished leaving.
        command('strip', f'strip-{other_strip}')
        time.sleep(.06)
        command('strip', f'strip-{initial["strip"]}')
        time.sleep(.7)
        for a, b in zip(before, metrics(ids)):
            for key in ('x', 'y', 'w', 'h'):
                assert abs(a[key] - b[key]) < 1, (key, a, b)
            assert abs(a['alpha'] - b['alpha']) < .001, (a, b)
    end = status()
    assert end['move_failures'] == baseline['move_failures'], end
    assert end['resize_operations'] == baseline['resize_operations'], 'edge transitions resized windows'
    assert {w['id'] for w in end['windows']} == {w['id'] for w in initial['windows']}
    report['result'] = 'pass'
    report['windows'] = len(ids)
    report['borders'] = len(border_ids)
    (ROOT / 'build/edge-visibility-check.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'checks'}))
finally:
    command('strip', f'strip-{initial["strip"]}')
    if focused:
        command('window', focused, '--focus')
    command('strip', 'scroll', initial['offset'])
