"""Native file drag acceptance using disposable fixture windows only.

Requires an unlocked desktop, the current installed build, and `make live-tools`.
Changes camera temporarily; restores it and closes fixtures in finally.
"""
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
FX = ROOT / 'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
LOG = Path('/tmp/tana2d_fixture_native_events.log')
RECEIVED = Path('/tmp/tana2d_hci_drag_received.txt')


def command(*args):
    return subprocess.check_output([str(WM), '-m', *map(str, args)], text=True)


def strip(*args):
    return command('strip', *args)


def state():
    return json.loads(strip('status'))


def wait(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('Timed out waiting for native fixture acceptance')


permissions = json.loads(subprocess.check_output([str(WM), '--check-permissions'], text=True))
assert permissions['session_unlocked'], 'Unlock the Mac before native input tests'
assert not [w for w in json.loads(command('query', '--windows')) if w['app'] == 'Tana2DFixture'], 'Close existing fixtures first'
initial = state()
assert initial['ready'] and initial['backend']
assert all(w['world']['x'] + w['world']['width'] < 9000 or w['world']['x'] > 13000 or
           w['world']['y'] + w['world']['height'] < 9000 or w['world']['y'] > 13000 for w in initial['windows'])
report = []
try:
    subprocess.run(['open', str(ROOT / 'build/Tana2DFixture.app')], check=True)
    ids = wait(lambda: (v if len(v := [w['id'] for w in json.loads(command('query', '--windows')) if w['app'] == 'Tana2DFixture']) == 3 else None))
    source, target, other = ids
    subprocess.run([str(FX), 'drag-mode'], check=True)
    time.sleep(.2)
    for scale in (.4, .7):
        strip('place', source, 10000, 10000, 500, 400)
        strip('place', target, 10600, 10000, 500, 400)
        strip('place', other, 20000, 20000, 500, 400)
        strip('zoom', scale)
        strip('camera', 10000 - 200 / scale, 10000 - 200 / scale)
        time.sleep(.7)
        before = {w['id']: w['world'] for w in state()['windows']}
        shown = json.loads(strip('presentation-status', source))
        dest = json.loads(strip('presentation-status', target))
        point = (shown['displayedX'] + shown['displayedWidth'] / 2,
                 shown['displayedY'] + shown['displayedHeight'] / 2)
        end = (dest['displayedX'] + dest['displayedWidth'] / 2,
               dest['displayedY'] + dest['displayedHeight'] / 2)
        assert abs(shown['cameraScale'] - scale) < .001
        RECEIVED.unlink(missing_ok=True)
        start_line = len(LOG.read_text().splitlines()) if LOG.exists() else 0
        subprocess.run([str(ROOT / 'build/plane_pointer_probe'), *map(str, point),
                        str(end[0] - point[0]), str(end[1] - point[1]), 'native', '150'], check=True)
        wait(lambda: RECEIVED.exists())
        rows = [json.loads(line) for line in LOG.read_text().splitlines()[start_line:]]
        assert any(r.get('kind') == 'file-drop' and r.get('window') == target and r.get('copied') for r in rows), rows
        assert RECEIVED.read_text() == 'Tana2D native file drag verification\n'
        time.sleep(.3)
        after = state()
        for w in after['windows']:
            if w['id'] in (source, target):
                for key in ('x', 'y', 'width', 'height'):
                    assert abs(w['world'][key] - before[w['id']][key]) < .6, (before[w['id']], w)
        assert abs(after['camera']['scale'] - scale) < .001
        report.append({'scale': scale, 'native_file_copied': True, 'source_and_target_unchanged': True})
        print(report[-1], flush=True)
finally:
    subprocess.run([str(FX), 'quit'])
    time.sleep(.3)
    camera = initial['camera']
    strip('zoom', camera['scale'])
    time.sleep(.3)
    strip('camera', camera['x'], camera['y'])
    time.sleep(.5)
    (ROOT / 'build/content-drag-report.json').write_text(json.dumps(report, indent=2) + '\n')
