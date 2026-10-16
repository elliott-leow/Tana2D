"""Installed zoom acceptance. Uses only disposable windows and IPC replay.

No pointer movement, input posting, virtual displays, or app injection.
"""
import json
import math
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana2d'
FX=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
APP=ROOT/'build/Tana2DFixture.app'
SNAP=Path('/tmp/tana2d_fixture_app_coordinates.json')

def cmd(*a): return subprocess.check_output([str(WM),'-m',*map(str,a)],text=True)
def strip(*a): return cmd('strip',*a)
def status(): return json.loads(strip('status'))
def query(): return json.loads(cmd('query','--windows'))
def worlds(s): return {w['id']:w['world'] for w in s['windows']}
def metrics(ids): return {w['id']:w for w in json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),*map(str,ids)],text=True))}
def wait(mode,scale=None):
    end=time.monotonic()+7
    while time.monotonic()<end:
        s=status()
        if s.get('zoom_mode')==mode and (scale is None or abs(s['camera']['scale']-scale)<1e-5):
            if mode!='native' or not json.loads(strip('input-status'))['selecting']:return s
        time.sleep(.05)
    raise AssertionError(('mode did not settle',mode,s))
def inspect():
    SNAP.unlink(missing_ok=True)
    subprocess.run([str(FX),'inspect'],check=True)
    end=time.monotonic()+2
    while not SNAP.exists() and time.monotonic()<end:time.sleep(.02)
    return {w['id']:w for w in json.loads(SNAP.read_text())}
def close(a,b): assert abs(a-b)<1.1,(a,b)

permissions=json.loads(subprocess.check_output([str(WM),'--check-permissions'],text=True))
assert permissions['session_unlocked'], 'Unlock the Mac before native input tests'
initial=status();assert initial['version']=='0.6.5'
initial_worlds=worlds(initial)
focused=next((w['id'] for w in query() if w.get('has-focus')),None)
ffm=cmd('config','focus_follows_mouse').strip()
assert not [w for w in query() if w['app']=='Tana2DFixture']
report={'before':initial,'checks':[],'result':'incomplete','pointer_operations':0}
ids=[]
try:
    cmd('config','focus_follows_mouse','off')
    subprocess.run(['open',str(APP)],check=True)
    end=time.monotonic()+6
    while time.monotonic()<end:
        ids=[w['id'] for w in query() if w['app']=='Tana2DFixture']
        if len(ids)==3:break
        time.sleep(.05)
    assert len(ids)==3,ids
    strip('zoom',.5)
    for i,wid in enumerate(ids):strip('place',wid,10000+i*1600,10000,500,622)
    time.sleep(.5)
    baseline=worlds(status());size_before=metrics(ids)
    wid=ids[0]
    for scale in [.25,.5,.75]:
        strip('zoom',scale)
        s=status();vp=s['viewport'];w=worlds(s)[wid]
        strip('camera',w['x']+w['width']/2-vp['width']/(2*scale),w['y']+w['height']/2-vp['height']/(2*scale))
        wait('workspace',scale);time.sleep(.45)
        assert json.loads(strip('input-status'))['selecting']
        m=metrics(ids)
        for id in ids:
            close(m[id]['w'],size_before[id]['w']);close(m[id]['h'],size_before[id]['h'])
        card=m[wid]
        x=card['public_display_x']+card['public_display_width']/2
        y=card['public_display_y']+card['public_display_height']/2
        strip('fixture-pointer',wid,1,0,x,y)
        strip('fixture-pointer',wid,1,2,x,y)
        s=wait('native',1)
        app=inspect()[wid];native=metrics([wid])[wid]
        for actual,expected in zip(app['app_frame'],[native['public_display_x'],native['public_display_y'],native['public_display_width'],native['public_display_height']]):close(actual,expected)
        close(native['x'],native['public_display_x']);close(native['y'],native['public_display_y'])
        for sample in app['samples']:
            px,py=sample['screen']
            expected=[px-native['public_display_x'],native['public_display_height']-(py-native['public_display_y'])]
            for actual,want in zip(sample['local'],expected):close(actual,want)
        assert worlds(s)==baseline
        report['checks'].append({'scale':scale,'native_coordinates':8,'window_sizes_preserved':True,'mode':s['zoom_mode'],'app_frame':app['app_frame']})
    strip('zoom',.5);wait('workspace',.5);time.sleep(.4)
    m=metrics([wid])[wid];x=m['public_display_x']+100;y=m['public_display_y']+100
    before=worlds(status())[wid]
    strip('fixture-pointer',wid,1,0,x,y)
    strip('fixture-pointer',wid,1,1,x+50,y+20)
    strip('fixture-pointer',wid,1,2,x+50,y+20)
    time.sleep(.5)
    after=worlds(status())[wid]
    close(after['x']-before['x'],100);close(after['y']-before['y'],40)
    assert status()['zoom_mode']=='workspace'
    report['checks'].append({'workspace_drag_world_delta':[after['x']-before['x'],after['y']-before['y']]})
    strip('actual-size');wait('native',1)
    # AppKit owns this move. The IPC seam observes its complete native
    # tracking/release path without posting a system pointer event.
    native_wid=ids[-1]
    native_world=worlds(status())[native_wid]
    strip('place',native_wid,native_world['x']+.37,native_world['y']+.61,500,622)
    cmd('window',native_wid,'--focus');time.sleep(.12);strip('actual-size');wait('native',1)
    time.sleep(.45)
    # Start a small camera ease, then grab before it finishes. The native
    # surface is usable during motion; mouse-down must freeze its own frame.
    camera=status()['camera'];strip('camera',camera['x']+40,camera['y']+10);time.sleep(.03)
    m=metrics([native_wid])[native_wid];before=worlds(status())[native_wid]
    x=m['public_display_x']+200;y=m['public_display_y']+12
    strip('fixture-pointer',native_wid,4,0,x,y)
    deadline=time.monotonic()+.05
    while any(j['id']==native_wid and j['running'] for j in json.loads(strip('zoom-status'))):
        assert time.monotonic()<deadline,'native grab cancellation exceeded 50 ms'
    assert worlds(status())[native_wid]==before
    # Sample after the press froze camera movement, exactly as AppKit does
    # for a real titlebar grab, rather than moving from a pre-press frame.
    m=metrics([native_wid])[native_wid]
    subprocess.run([str(FX),'move-window',str(native_wid),str(m['x']+60),str(m['y']+30)],check=True);time.sleep(.1)
    strip('fixture-pointer',native_wid,4,1,x+60,y+30)
    strip('fixture-pointer',native_wid,4,2,x+60,y+30)
    wait('native',1);time.sleep(.25)
    after=worlds(status())[native_wid]
    assert abs(after['x']-before['x']-60)<.02,(before,after)
    assert abs(after['y']-before['y']-30)<.02,(before,after)
    app=inspect()[native_wid];native=metrics([native_wid])[native_wid]
    for actual,expected in zip(app['app_frame'],[native['public_display_x'],native['public_display_y'],native['public_display_width'],native['public_display_height']]):close(actual,expected)
    report['checks'].append({'native_tracking_release_delta':[after['x']-before['x'],after['y']-before['y']],'camera_animation_grab':True,'app_frame':app['app_frame']})
    report['result']='passed'
finally:
    report['last_status']=status()
    if ids:report['last_metrics']=metrics(ids)
    subprocess.run([str(FX),'quit'],check=False);time.sleep(.25)
    if focused:cmd('window',focused,'--focus')
    strip('zoom',initial['camera']['scale'])
    strip('camera',initial['camera']['x'],initial['camera']['y'])
    time.sleep(.7)
    cmd('config','focus_follows_mouse','off' if ffm=='disabled' else ffm)
    report['after']=status()
    report['user_world_frames_preserved']=worlds(report['after'])==initial_worlds
    (ROOT/'build/native-zoom-live-report.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['user_world_frames_preserved'],report
print('PASS: 24 native AppKit coordinate samples, 3 zoom handoffs, canvas drag, native tracking release, user frames preserved')
