"""Installed-app overlap offer and native titlebar release in disposable windows."""
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
FX = ROOT / 'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'


def command(*args):
    return subprocess.check_output([str(WM), '-m', *map(str, args)], text=True)


def strip(*args):
    return command('strip', *args)


def state():
    return json.loads(strip('status'))


def presented(wid):
    return json.loads(strip('presentation-status', wid))


def wait(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('Timed out waiting for overlap tiling acceptance')


assert json.loads(subprocess.check_output([str(WM), '--check-permissions'], text=True))['session_unlocked']
assert not [w for w in json.loads(command('query', '--windows')) if w['app'] == 'Tana2DFixture']
initial = state()
assert all(w['world']['x'] + w['world']['width'] < 9000 or w['world']['x'] > 13000 or
           w['world']['y'] + w['world']['height'] < 9000 or w['world']['y'] > 13000 for w in initial['windows'])
probe = None
report = {}
try:
    subprocess.run(['open', str(ROOT / 'build/Tana2DFixture.app')], check=True)
    ids = wait(lambda: (v if len(v := [w['id'] for w in json.loads(command('query', '--windows')) if w['app'] == 'Tana2DFixture']) == 3 else None))
    moving, peer, other = ids
    strip('place', moving, 9300, 10000, 500, 400)
    strip('place', peer, 10000, 10000, 500, 400)
    strip('place', other, 20000, 20000, 500, 400)
    strip('zoom', .5)
    strip('camera', 9100, 9600)
    time.sleep(.7)
    before = presented(moving)
    anchor = presented(peer)
    x, y = before['displayedX'] + 40, before['displayedY'] + 5
    probe = subprocess.Popen([str(ROOT / 'build/plane_pointer_probe'), str(x), str(y), '225', '0', 'native', '2000'])
    offer = wait(lambda: (p if (p := presented(moving))['tileOffer'] else None), 1.5)
    assert offer['nativeDrag'] and offer['tilePeer'] == peer, offer
    assert offer['snapPreviewVisible'], offer
    assert abs(offer['worldX'] - 9750) < 4, offer
    vp = initial['viewport']
    width, height = vp['width'], vp['height']
    left_width = (width - 12) // 2
    split_x = round(anchor['worldX'] + anchor['worldWidth'] / 2 - width / 2)
    split_y = round(anchor['worldY'] + anchor['worldHeight'] / 2 - height / 2)
    def painted_preview():
        p = presented(moving)
        if not p['tileOffer'] or not p['snapPreviewVisible']:
            return None
        m = json.loads(subprocess.check_output([str(ROOT / 'build/window_metrics'), str(p['snapPreviewWindow'])], text=True))[0]
        return m if m['alpha'] > .9 and abs(m['public_display_x'] - (vp['x'] + (split_x - 9100) * .5)) < 1 and width * .5 <= m['public_display_width'] <= width * .5 + 64 and abs(m['final_a'] - 1) < .01 else None
    preview = wait(painted_preview, 1)
    probe.wait(timeout=5)
    after = wait(lambda: (p if not (p := presented(moving))['drag'] else None))
    assert abs(after['worldX'] - split_x) < 1 and abs(after['worldY'] - split_y) < 1, after
    stationary = presented(peer)
    assert after['worldWidth'] == left_width and after['worldHeight'] == height
    assert stationary['worldWidth'] == width - 12 - left_width and stationary['worldHeight'] == height
    assert abs(stationary['worldX'] - after['worldX'] - left_width - 12) < 1
    report = {'native_titlebar_drag': True, 'offer_visible_while_held': True, 'preview_matches_landing': True,
              'release_tiles': True, 'both_resized_to_equal_halves': True}
    print(json.dumps(report), flush=True)
finally:
    if probe and probe.poll() is None:
        probe.wait(timeout=5)
    subprocess.run([str(FX), 'quit'])
    time.sleep(.3)
    camera = initial['camera']
    strip('zoom', camera['scale'])
    time.sleep(.3)
    strip('camera', camera['x'], camera['y'])
    time.sleep(.5)
    (ROOT / 'build/overlap-tiling-report.json').write_text(json.dumps(report, indent=2) + '\n')
