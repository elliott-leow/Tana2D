"""Actual CGEvent hover across disposable windows at reduced zoom.

Requires a running Tana2DFixture. Verifies focus, compositor border geometry,
and unchanged camera in ordinary and selection modes.
Restores fixture worlds, camera, and focus in finally; posts no clicks.
"""
import json
import math
import subprocess
import time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def command(*args):
    return subprocess.check_output([str(ROOT/'build/tana2d'),'-m',*map(str,args)],text=True)
def strip(*args): return command('strip',*args)
def state(): return json.loads(strip('status'))
def present(wid): return json.loads(strip('presentation-status',wid))
def near(a,b,tolerance=1.1): assert abs(a-b)<=tolerance,(a,b)
initial=state()
assert initial['ready'] and initial['backend'] and not initial['paused']
assert json.loads(strip('config-status'))['autofocus']=='pointer-movement'
assert not json.loads(strip('input-status'))['selecting']
windows=json.loads(command('query','--windows'))
fixtures=[w['id'] for w in windows if w['app']=='Tana2DFixture']
assert len(fixtures)==3,'Launch Tana2DFixture first'
focused=next((w['id'] for w in windows if w.get('has-focus')),None)
report={'result':'incomplete','checks':[]}
try:
    for i,wid in enumerate(fixtures): strip('place',wid,10000+i*500,10000,400,300)
    command('window',fixtures[0],'--focus')
    time.sleep(.7)
    for selecting in (False,True):
        if selecting: strip('select-window')
        for scale in (.1,.25,.5,1):
            if selecting:
                strip('zoom',scale)
            else:
                delta=math.log(scale/state()['camera']['scale'])
                subprocess.run([str(ROOT/'build/plane_gesture_probe'),'pinch',str(delta)],check=True)
                near(state()['camera']['scale'],scale,.0001)
            strip('camera',10000-100/scale,10000-180/scale)
            time.sleep(.8)
            camera=state()['camera']
            strip('profile-reset')
            for wid in fixtures:
                before=present(wid)
                x=before['displayedX']+before['displayedWidth']/2
                y=before['displayedY']+before['displayedHeight']/2
                subprocess.run([str(ROOT/'build/plane_pointer_probe'),str(x-8),str(y),'8','0','hover'],check=True)
                deadline=time.monotonic()+3
                while True:
                    p=present(wid)
                    aligned=p['borderVisible'] and p['borderValid'] and abs(p['borderX']-(p['displayedX']-p['borderPad']))<=1.1
                    if p['focusedWindow']==wid and aligned: break
                    assert time.monotonic()<deadline,('hover did not transfer border',selecting,scale,wid,p)
                    time.sleep(.02)
                assert json.loads(strip('input-status'))['selecting']==selecting
                for key in ('x','y','scale'): near(state()['camera'][key],camera[key],.01)
                for axis in ('X','Y'): near(p['border'+axis],p['displayed'+axis]-p['borderPad'])
                for dimension in ('Width','Height'): near(p['border'+dimension],p['displayed'+dimension]+2*p['borderPad'],2.1)
                m=json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),str(p['borderWindow'])],text=True))[0]
                near(m['public_display_x'],p['borderX']);near(m['public_display_y'],p['borderY'])
                near(m['public_display_width'],p['borderWidth']);near(m['public_display_height'],p['borderHeight'])
                report['checks'].append({'selecting':selecting,'scale':scale,'window':wid,'border':m,'camera':camera})
            report.setdefault('profiles',[]).append(json.loads(strip('profile')))
    report['result']='pass'
finally:
    strip('fit-all')
    for w in initial['windows']:
        if w['id'] in fixtures:
            r=w['world'];strip('place',w['id'],r['x'],r['y'],r['width'],r['height'])
    if focused: command('window',focused,'--focus')
    strip('zoom',initial['camera']['scale'])
    strip('camera',initial['camera']['x'],initial['camera']['y'])
    (ROOT/'build/border-hover-live.json').write_text(json.dumps(report,indent=2))
print('PASS',len(report['checks']),'actual hover focus/border checks')
