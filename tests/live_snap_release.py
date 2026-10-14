"""Fixture-only release snapping and camera independence on a running Tana2D.
No OS input is posted; this is not a physical title-bar input test.
"""
import json
import subprocess
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def cmd(*args):
    return subprocess.check_output([str(ROOT/'build/tana2d'),'-m',*map(str,args)],text=True)
def strip(*args): return cmd('strip',*args)
def status(): return json.loads(strip('status'))
def world(wid): return next(w['world'] for w in status()['windows'] if w['id']==wid)
def present(wid): return json.loads(strip('presentation-status',wid))
def near(a,b,tol=.6): assert abs(a-b)<=tol,(a,b,tol)
def settled(wid):
    until=time.monotonic()+5; previous=None
    while time.monotonic()<until:
        p=present(wid)
        sig=tuple(p[k] for k in ('displayedX','displayedY','cameraX','cameraY','cameraScale'))
        if not(p['drag'] or p['edge'] or p['transformDirty']) and sig==previous:
            assert p['borderVisible'] and p['borderValid'],p
            near(p['borderX'],p['displayedX']-p['borderPad']);near(p['borderY'],p['displayedY']-p['borderPad'])
            near(p['borderWidth'],p['displayedWidth']+2*p['borderPad']);near(p['borderHeight'],p['displayedHeight']+2*p['borderPad'])
            return p
        previous=sig;time.sleep(.02)
    raise AssertionError(('did not settle',p))
windows=json.loads(cmd('query','--windows'))
fixtures=[w for w in windows if w['app']=='Tana2DFixture']
moving=next(w['id'] for w in fixtures if w['title']=='Tana2D Test 3')
peer=next(w['id'] for w in fixtures if w['id']!=moving)
initial=status();focused=next((w['id'] for w in windows if w.get('has-focus') and w['app']!='Tana2DFixture'),None)
checks=[];active=False;last=(0,0);mode=0
try:
    for other in initial['windows']:
        if other['id'] in [w['id'] for w in fixtures]: continue
        w=other['world'];assert w['x']+w['width']<8000 or w['x']>12500 or w['y']+w['height']<8000 or w['y']>12500,other
    cmd('window',moving,'--focus')
    for scale in (.5,1,2):
        for mode in (0,4):
            for i,w in enumerate(fixtures): strip('place',w['id'],-50000-i*5000,-50000-i*5000,400,300)
            strip('place',peer,10412,10000,400,300)
            strip('place',moving,9700,10000,400,300)
            strip('zoom',scale);v=status()['viewport']
            strip('camera',10206-v['width']/(2*scale),10150-v['height']/(2*scale))
            start=settled(moving)
            last=(start['displayedX']+100*scale,start['displayedY']+16*scale)
            strip('fixture-pointer',moving,mode,0,*last);active=True
            if mode==0:
                last=(last[0]+300*scale+8,last[1]+3)
            else:
                subprocess.check_call([str(ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'),'move',str(start['nativeX']+300*scale+8),str(start['nativeY']+3)])
                time.sleep(.05)
            strip('fixture-pointer',moving,mode,1,*last)
            held=world(moving);near(held['x'],10000+8/scale,1/scale);near(held['y'],10000+3/scale,1/scale)
            if scale==.5 and mode==0:subprocess.check_call(['screencapture','-x',str(ROOT/'build/snap-held.png')])
            strip('fixture-pointer',moving,mode,2,*last);active=False
            released=settled(moving);w=world(moving)
            near(w['x'],10000,.01);near(w['y'],10000,.01)
            near(world(peer)['x']-(w['x']+w['width']),12,.01)
            if scale==.5 and mode==0:subprocess.check_call(['screencapture','-x',str(ROOT/'build/snap-released.png')])
            strip('pan',80,40);panned=settled(moving)
            near(panned['displayedX'],released['displayedX']-80*scale)
            near(panned['displayedY'],released['displayedY']-40*scale)
            assert world(moving)==w
            if scale==.5 and mode==0:subprocess.check_call(['screencapture','-x',str(ROOT/'build/snap-panned.png')])
            checks.append({'scale':scale,'mode':mode,'held_unsnapped':True,'release_gap':12,'pan_independent':True})
            print(json.dumps(checks[-1]),flush=True)
finally:
    if active: strip('fixture-pointer',moving,mode,2,*last)
    for i,w in enumerate(fixtures): strip('place',w['id'],-50000-i*5000,-50000-i*5000,400,300)
    if focused:cmd('window',focused,'--focus')
    strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
    (ROOT/'build/snap-release-report.json').write_text(json.dumps(checks,indent=2)+'\n')
assert len(checks)==6
