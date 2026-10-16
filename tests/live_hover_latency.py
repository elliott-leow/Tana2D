"""Installed hover handoff and actual AppKit key-window receipt.

Only disposable fixtures are arranged. IPC and guarded stationary OS motion
exercise the production hover handler; the physical cursor is neither moved nor
remapped. Sensor/driver latency is not measured. AppKit receipt is independent.
"""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
APP = ROOT / 'build/Tana2DFixture.app'
FX = APP / 'Contents/MacOS/plane_fixture'
EVENTS = Path('/tmp/tana2d_fixture_native_events.log')
SNAP = Path('/tmp/tana2d_fixture_app_coordinates.json')

def cmd(*args):
    return subprocess.check_output([str(WM), '-m', *map(str, args)], text=True)
def strip(*args): return cmd('strip', *args)
def status(): return json.loads(strip('status'))
def query(): return json.loads(cmd('query', '--windows'))
def worlds(s): return {w['id']: w['world'] for w in s['windows']}
def metrics(ids):
    return {w['id']: w for w in json.loads(subprocess.check_output(
        [str(ROOT / 'build/window_metrics'), *map(str, ids)], text=True))}
def until(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result: return result
        time.sleep(.005)
    raise AssertionError('condition timed out')
def inspect():
    SNAP.unlink(missing_ok=True)
    subprocess.run([str(FX), 'inspect'], check=True)
    until(SNAP.exists)
    return {w['id']: w for w in json.loads(SNAP.read_text())}
def close(a, b): assert abs(a-b) < 1.1, (a, b)

permissions=json.loads(subprocess.check_output([str(WM),'--check-permissions'],text=True))
assert permissions['session_unlocked'], 'Unlock the Mac before native input tests'
initial = status()
assert initial['version'] == '0.6.5'
assert not [w for w in query() if w['app'] == 'Tana2DFixture']
initial_focus = next((w['id'] for w in query() if w.get('has-focus')), None)
initial_ffm = cmd('config', 'focus_follows_mouse').strip()
report = {'result': 'incomplete', 'checks': [], 'pointer_operations': 0,
          'measurement': 'production hover handler entry through AppKit key-window notification'}
ids = []

def hover(wid, workspace, moving=False):
    m = metrics([wid])[wid]
    x = m['public_display_x'] + m['public_display_width']/2
    y = m['public_display_y'] + m['public_display_height']/2
    prior = json.loads(strip('hover-status'))['samples']
    strip('fixture-hover', wid, x, y)
    s = until(lambda: (v if (v := status())['zoom_mode'] == 'native' else None))
    samples = until(lambda: (v if len(v := json.loads(strip('hover-status'))['samples'])>len(prior) else None))
    assert len(samples) > len(prior), (wid, samples, prior)
    timing = samples[-1]
    assert timing['id'] == wid and timing['workspace'] == workspace, timing
    def receipt():
        if not EVENTS.exists(): return None
        rows = [json.loads(line) for line in EVENTS.read_text().splitlines() if line.startswith('{"kind":"key"')]
        return next((r for r in rows if r.get('kind') == 'key' and
                     r['window'] == wid and r['time'] >= timing['started']), None)
    key = until(receipt, 1)
    actual_ms = (key['time']-timing['started'])*1000
    assert timing['ms'] < 50 and actual_ms < 50, (timing, actual_ms)
    input_state=json.loads(strip('hover-status'))
    assert not input_state['shield'] or input_state['inputWindow']==wid
    m = metrics([wid])[wid]
    app = inspect()[wid]
    expected = app['displayed_frame'] if moving else [m['public_display_x'], m['public_display_y'],
                m['public_display_width'], m['public_display_height']]
    for a, b in zip(app['app_frame'], expected): close(a, b)
    for sample in app['samples']:
        px, py = sample['screen']
        for a, b in zip(sample['local'], [px-expected[0], expected[3]-(py-expected[1])]): close(a, b)
    report['checks'].append({'id': wid, 'workspace': workspace, 'handoff_ms': timing['ms'],
                             'app_key_ms': actual_ms, 'native_coordinate_samples': 8})
    return s

try:
    cmd('config', 'focus_follows_mouse', 'off')
    subprocess.run(['open', str(APP)], check=True)
    ids = until(lambda: (v if len(v := [w['id'] for w in query() if w['app'] == 'Tana2DFixture']) == 3 else None))
    strip('zoom', .5)
    for i, wid in enumerate(ids): strip('place', wid, 10000+i*560, 10200, 500, 622)
    time.sleep(.45)
    # An explicit request returns to native size with an animation. Hover
    # itself must leave zoom and the camera unchanged.
    strip('actual-size')
    time.sleep(.5)
    strip('camera', 10000, 10000)
    time.sleep(.5)
    if json.loads(strip('fixture-only')):
        for id in ids: cmd('window',id,'--sub-layer','above')
    cmd('config', 'focus_follows_mouse', 'autofocus')
    for i in range(12):
        before=status()['camera']
        after=hover(ids[1+i % 2], False)['camera']
        assert before == after, (before, after)
    # Include event posting, event-tap delivery, queueing and actual AppKit
    # focus. This posts at the unchanged physical point only over a fixture.
    cursor=json.loads(strip('focus-status'))['cursor']
    vp=status()['viewport']; w=worlds(status())[ids[1]]
    # Move the disposable row beneath the cursor with the ordinary camera
    # animation. Never move the physical cursor to make a test hit a window.
    local_y=min(311,cursor[1]-vp['y']-12)
    assert local_y>=28, 'Place the pointer inside the workspace before native hover checks'
    strip('camera',w['x']+250-(cursor[0]-vp['x']),w['y']+local_y-(cursor[1]-vp['y']))
    time.sleep(.5)
    cursor=json.loads(strip('focus-status'))['cursor']
    hit=next((wid for wid,m in metrics(ids).items() if
              m['public_display_x']<=cursor[0]<m['public_display_x']+m['w'] and
              m['public_display_y']<=cursor[1]<m['public_display_y']+m['h']),None)
    if hit is not None:
        report['stationary_os_events']=[]
        for _ in range(3):
            other=next(wid for wid,m in metrics(ids).items() if wid!=hit and m['alpha']>0 and
                       vp['x']<m['public_display_x']+250<vp['x']+vp['width'] and
                       vp['y']<m['public_display_y']+311<vp['y']+vp['height'])
            hover(other,False)
            sent=json.loads(subprocess.check_output([str(ROOT/'build/stationary_hover_probe'),str(hit)],text=True))
            def os_receipt():
                rows=[json.loads(line) for line in EVENTS.read_text().splitlines() if line.startswith('{"kind":"key"')]
                return next((r for r in rows if r['window']==hit and r['time']>=sent['started']),None)
            key=until(os_receipt,1)
            ms=(key['time']-sent['started'])*1000
            assert ms<50,(sent,key,ms)
            report['stationary_os_events'].append({'app_key_ms':ms,'point':sent['point'],'window':hit})
    else:
        report['stationary_os_events_skipped']='Physical cursor is outside the disposable fixtures; no cursor movement requested.'
    strip('camera',10000,10000)
    time.sleep(.5)
    # Hover never moves the camera. Approaching the middle window used to
    # start centering, which slid other windows under a still pointer.
    wid=ids[1];m=metrics([wid])[wid]
    x=m['public_display_x']+100;y=m['public_display_y']+311
    monitor=subprocess.Popen([str(ROOT/'build/native_stability_probe'),str(wid),'600',','.join(map(str,ids))],stdout=subprocess.PIPE,text=True)
    assert monitor.stdout.readline().strip()=='ready'
    before=status()['camera']
    for dx in (0,10,30):
        strip('fixture-hover',wid,x+dx,y);time.sleep(.05)
    sampled=json.loads(monitor.communicate(timeout=3)[0]);assert monitor.returncode==0 and len(sampled)>50
    assert status()['camera']==before,'hover moved the camera'
    still=max(abs(r[4][str(i)][a]-sampled[0][4][str(i)][a]) for r in sampled for i in ids for a in (0,1))
    assert still<=1.1,('a window moved on hover',still)
    assert min(pos[2] for r in sampled for pos in r[4].values())>.99,'a window disappeared on hover'
    report['hover_camera_still']={'samples':len(sampled),'max_window_motion_px':still}
    # Hover during camera motion neither freezes the camera nor steals focus
    # mid-motion; the window under the pointer is focused once it lands.
    camera=status()['camera'];target=camera['x']+30
    cmd('window',ids[0],'--focus');time.sleep(.2)
    strip('camera',target,camera['y']);time.sleep(.03)
    m=metrics([ids[2]])[ids[2]]
    started=time.time()
    strip('fixture-hover',ids[2],m['public_display_x']+m['public_display_width']/2,m['public_display_y']+m['public_display_height']/2)
    until(lambda:abs(status()['camera']['x']-target)<1,2)
    report['moving_hover']={'camera_reached_target':True}
    report['result'] = 'passed'
finally:
    report['last_status'] = status()
    report['last_hover'] = json.loads(strip('hover-status'))
    report['last_jobs'] = json.loads(strip('zoom-status'))
    report['last_focus'] = json.loads(strip('focus-status'))
    if ids: report['last_fixture_metrics'] = metrics(ids)
    cmd('config', 'focus_follows_mouse', 'off')
    subprocess.run([str(FX), 'quit'], check=False)
    time.sleep(.2)
    if initial_focus: cmd('window', initial_focus, '--focus')
    strip('zoom', initial['camera']['scale'])
    strip('camera', initial['camera']['x'], initial['camera']['y'])
    time.sleep(.6)
    cmd('config', 'focus_follows_mouse', 'off' if initial_ffm == 'disabled' else initial_ffm)
    report['user_world_frames_preserved'] = worlds(status()) == worlds(initial)
    if report['checks']:
        report['max_app_key_ms'] = max(c['app_key_ms'] for c in report['checks'])
        report['max_handoff_ms'] = max(c['handoff_ms'] for c in report['checks'])
    (ROOT/'build/hover-latency-live-report.json').write_text(json.dumps(report, indent=2)+'\n')
    assert report['user_world_frames_preserved'], 'user window geometry changed'
print(json.dumps({k:report[k] for k in ['result','max_app_key_ms','max_handoff_ms','user_world_frames_preserved']}))
