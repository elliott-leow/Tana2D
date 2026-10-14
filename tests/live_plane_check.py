"""Live Tana2D acceptance using disposable windows; restores camera and focus.

Build plane_fixture and window_metrics first. Run only with Tana2D active.
This measures WindowServer geometry. It does not establish physical gesture feel.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--fixture-running', action='store_true', help='Use an already launched disposable fixture')
parser.add_argument('--generated-input', action='store_true', help='Also inject drag/swipe/pinch/keyboard events')
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
FIXTURE = ROOT / 'build/Tana2DFixture.app'
METRICS = ROOT / 'build/window_metrics'


def command(*parts):
    return subprocess.check_output([str(WM), '-m', *map(str, parts)], text=True)


def strip(*parts):
    return command('strip', *parts)


def status():
    return json.loads(strip('status'))


def metrics(ids):
    return {w['id']: w for w in json.loads(subprocess.check_output([str(METRICS), *map(str, ids)], text=True))}


def settle():
    time.sleep(.75)


def close(a, b, tolerance=1.2):
    assert abs(a-b) <= tolerance, (a, b)


initial = status()
assert initial['ready'] and initial['backend'] and not initial['paused'] and initial['plane'], initial
assert not json.loads(strip('input-status'))['suspended']
focused = next((w['id'] for w in json.loads(command('query', '--windows')) if w.get('has-focus')), None)
checks = []
ids = []
report = {'checks': checks, 'result': 'incomplete'}
try:
    if not args.fixture_running:
        subprocess.run(['open', str(FIXTURE)], check=True)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        managed = {w['id'] for w in status()['windows']}
        ids = [w['id'] for w in json.loads(command('query', '--windows'))
               if w['app'] == 'Tana2DFixture' and w['id'] in managed]
        if len(ids) >= 3:
            break
        time.sleep(.1)
    assert len(ids) == 3, ids
    strip('actual-size')
    for wid, (x, y) in zip(ids, [(-1200, -800), (200, 100), (1300, 1000)]):
        strip('place', wid, x, y, 400, 300)
    settle()
    worlds = {w['id']: w['world'] for w in status()['windows'] if w['id'] in ids}
    assert worlds[ids[0]]['x'] == -1200 and worlds[ids[0]]['y'] == -800
    checks.append('windows retain independent signed 2D positions')

    for x, y in [(-100000, -100000), (100000, 100000), (-100000, 100000), (100000, -100000)]:
        strip('camera', x, y)
        settle()
        camera = status()['camera']
        close(camera['x'], x)
        close(camera['y'], y)
    checks.append('camera travels beyond content in all four quadrants without walls')

    strip('camera', -1300, -900)
    settle()
    before = metrics([ids[0]])[ids[0]]
    strip('pan', 60, 40)
    settle()
    after = metrics([ids[0]])[ids[0]]
    close(-after['tx']/after['a']+before['tx']/before['a'], -60)
    close(-after['ty']/after['d']+before['ty']/before['d'], -40)
    close(after['x'], before['x'], .001)
    close(after['y'], before['y'], .001)
    checks.append('two-axis camera movement translates the compositor and leaves native anchors fixed')

    viewport = status()['viewport']
    first = worlds[ids[0]]
    strip('camera', first['x']+first['width']/2-viewport['width']/2,
          first['y']+first['height']/2-viewport['height']/2)
    settle()
    for scale in [.5, 2, 1]:
        strip('zoom', scale)
        settle()
        close(status()['camera']['scale'], scale, .0001)
        m = metrics([ids[0]])[ids[0]]
        close(m['w']/m['a'], m['w']*scale, 1.1)
        close(m['h']/m['d'], m['h']*scale, 1.5)
    checks.append('zoom out and in change native window transforms; actual size restores unit scale')
    strip('zoom', .5); settle()
    before = metrics([ids[0]])[ids[0]]
    strip('pan', 80, 60); settle()
    after = metrics([ids[0]])[ids[0]]
    close(-after['tx']/after['a']+before['tx']/before['a'], -40)
    close(-after['ty']/after['d']+before['ty']/before['d'], -30)
    close(after['x'], before['x'], .001)
    close(after['y'], before['y'], .001)
    close(after['a'], before['a'], .00001)
    close(after['d'], before['d'], .00001)
    checks.append('panning at half zoom preserves scale and native anchors')
    strip('actual-size'); settle()

    command('window', ids[0], '--focus')
    settle()
    before_move = next(w['world'] for w in status()['windows'] if w['id'] == ids[0])
    strip('move-up')
    settle()
    moved_world = next(w['world'] for w in status()['windows'] if w['id'] == ids[0])
    assert moved_world['y'] < before_move['y'] and moved_world['x'] == before_move['x']
    strip('undo')
    settle()
    assert next(w['world'] for w in status()['windows'] if w['id'] == ids[0]) == before_move
    checks.append('directional placement and undo preserve plane coordinates')

    if args.generated_input:
        strip('zoom', .5)
        settle()
        for mode in ('option', 'native'):
            state = status()
            r = next(w['world'] for w in state['windows'] if w['id'] == ids[0])
            viewport = state['viewport']
            strip('camera', r['x']+r['width']/2-viewport['width'], r['y']+r['height']/2-viewport['height'])
            settle()
            state = status(); camera = state['camera']; scale = camera['scale']
            x = viewport['x']+(r['x']-camera['x']+r['width']/2)*scale
            y = viewport['y']+(r['y']-camera['y'])*scale+(r['height']*scale/2 if mode=='option' else 5)
            subprocess.run([str(ROOT/'build/plane_pointer_probe'), str(x), str(y), '60', '40', mode], check=True)
            settle()
            new = next(w['world'] for w in status()['windows'] if w['id'] == ids[0])
            close(new['x']-r['x'], 60/scale, 3)
            close(new['y']-r['y'], 40/scale, 3)
            close(new['width'], r['width'])
            close(new['height'], r['height'])
        worlds = {w['id']: w['world'] for w in status()['windows'] if w['id'] in ids}
        checks.append('Option and native title-bar drags preserve world sizes and divide screen movement by zoom')

        probe = ROOT / 'build/plane_gesture_probe'
        strip('actual-size')
        settle()
        for direction, amount in [('horizontal', .08), ('vertical', .08), ('horizontal', -.08), ('vertical', -.08)]:
            before_camera = status()['camera']
            subprocess.run([str(probe), direction, str(amount)], check=True)
            settle()
            after_camera = status()['camera']
            axis = 'x' if direction == 'horizontal' else 'y'
            assert abs(after_camera[axis]-before_camera[axis]) > 5, (direction, before_camera, after_camera)
            assert not json.loads(strip('input-status'))['overview']
        checks.append('native three-finger event streams pan in all four directions without opening overview')
        for amount in [-.25, .35]:
            before_scale = status()['camera']['scale']
            subprocess.run([str(probe), 'pinch', str(amount)], check=True)
            settle()
            after_scale = status()['camera']['scale']
            assert (after_scale-before_scale)*amount > 0, (amount, before_scale, after_scale)
        checks.append('native pinch event stream zooms out and in through the event tap')

        subprocess.run([str(probe), 'fit-key', '0'], check=True)
    else:
        strip('fit-all')
    settle()
    state = status()
    camera, viewport = state['camera'], state['viewport']
    assert camera['scale'] > 0
    for w in state['windows']:
        r = w['world']
        x, y = (r['x']-camera['x'])*camera['scale'], (r['y']-camera['y'])*camera['scale']
        assert x >= -1 and y >= -1, (w, camera)
        assert x+r['width']*camera['scale'] <= viewport['width']+1, (w, camera)
        assert y+r['height']*camera['scale'] <= viewport['height']+1, (w, camera)
    for w in state['windows']:
        if w['id'] in worlds:
            assert w['world'] == worlds[w['id']], (w, worlds[w['id']])
    for m in metrics(ids).values():
        assert m['alpha'] > 0, m
        close(m['a'], 1/camera['scale'], .01)
        close(m['d'], 1/camera['scale'], .03)
        r = next(w['world'] for w in state['windows'] if w['id']==m['id'])
        close(m['w'], r['width'])
        close(m['h'], r['height'])
        close(-m['tx']/m['a'], viewport['x']+(r['x']-camera['x'])*camera['scale'], 2)
        close(-m['ty']/m['d'], viewport['y']+(r['y']-camera['y'])*camera['scale'], 2)
        close(m['w']/m['a'], r['width']*camera['scale'], 2)
        close(m['h']/m['d'], r['height']*camera['scale'], 2)
    checks.append('Fit all contains every plane window without changing world geometry')
    key_camera = camera.copy()
    strip('actual-size')
    strip('fit-all')
    settle()
    for key in ('x', 'y', 'scale'):
        close(status()['camera'][key], key_camera[key], .01)
    checks.append('Fit all returns to the same camera after actual-size reset')

    strip('actual-size')
    settle()
    for m in metrics(ids).values():
        close(m['a'], 1, .001)
        close(m['d'], 1, .001)
    checks.append('actual size restores unit scale while retaining canvas translation')
    command('window', ids[0], '--focus'); settle()
    strip('zoom', .5); settle()
    strip('maximize'); settle()
    full = status()
    close(full['camera']['scale'], 1, .00001)
    w = next(w['world'] for w in full['windows'] if w['id']==ids[0])
    m = metrics([ids[0]])[ids[0]]
    close(w['width'], viewport['width']); close(w['height'], viewport['height'])
    close(-m['tx']/m['a'], viewport['x']); close(-m['ty']/m['d'], viewport['y'])
    close(m['w'], viewport['width']); close(m['h'], viewport['height'])
    close(m['a'], 1, .001); close(m['d'], 1, .001)
    checks.append('maximize resets zoom to 100 percent and fills the usable screen with the active window')
    # Resizes originate in AppKit, including updates while the camera is moving.
    # The fixture's last-created window is the only target of this test command.
    target = next(w['id'] for w in json.loads(command('query', '--windows'))
                  if w['app']=='Tana2DFixture' and w['title']=='Tana2D Test 3')
    command('window', target, '--focus'); settle()
    for scale, width, height in [(1,640,440),(.5,720,480),(.5,460,330),(1,540,380)]:
        r = next(w['world'] for w in status()['windows'] if w['id']==target)
        strip('zoom', scale)
        strip('camera', r['x']+r['width']/2-viewport['width']/(2*scale),
                        r['y']+r['height']/2-viewport['height']/(2*scale))
        subprocess.run([str(FIXTURE / 'Contents/MacOS/plane_fixture'),'resize',str(width),str(height)],check=True)
        settle()
        r = next(w['world'] for w in status()['windows'] if w['id']==target)
        profile=json.loads(strip('profile'))
        measured=metrics([target,profile['border_window']])
        m=measured[target]; border=measured[profile['border_window']]
        close(m['w'],width); close(m['h'],height)
        close(r['width'],width); close(r['height'],height)
        close(m['a'],1/scale,.001); close(m['d'],1/scale,.001)
        camera=status()['camera']
        close(-m['tx']/m['a'],viewport['x']+(r['x']-camera['x'])*scale)
        close(-m['ty']/m['d'],viewport['y']+(r['y']-camera['y'])*scale)
        # The outline surrounds the current native surface, not its stale size.
        pad_x=(-m['tx']/m['a'])-(-border['tx']/border['a'])
        pad_y=(-m['ty']/m['d'])-(-border['ty']/border['d'])
        assert 1 <= pad_x <= 6 and 1 <= pad_y <= 6, (pad_x,pad_y)
        close(border['w']/border['a'],m['w']/m['a']+2*pad_x,2)
        close(border['h']/border['d'],m['h']/m['d']+2*pad_y,2)
    checks.append('four app-originated resizes at full and half zoom update world size, projection, and border bounds')
    assert status()['move_failures'] == initial['move_failures']
    assert json.loads(strip('input-status'))['tap_enabled']
    report['result'] = 'pass'
finally:
    subprocess.run([str(FIXTURE / 'Contents/MacOS/plane_fixture'), 'quit'], check=False)
    time.sleep(.5)
    if focused:
        subprocess.run([str(WM), '-m', 'window', str(focused), '--focus'], capture_output=True)
    strip('zoom', initial['camera']['scale'])
    strip('camera', initial['camera']['x'], initial['camera']['y'])
    (ROOT / 'build/plane-check.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
