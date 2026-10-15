"""Opt-in CGEvent docking checks on disposable fixture windows, all four sides.
Requires Tana2DFixture already running. Restores its worlds, camera and focus.
"""
import argparse
import json
import subprocess
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--outside',action='store_true',help='Approach without overshooting the docking edge')
parser.add_argument('--stacked',action='store_true',help='Include an existing window overlapping the target neighbor')
args=parser.parse_args()
def cmd(*args):return subprocess.check_output([str(ROOT/'build/tana2d'),'-m',*map(str,args)],text=True)
def strip(*args):return cmd('strip',*args)
def state():return json.loads(strip('status'))
def present(wid):return json.loads(strip('presentation-status',wid))
def near(a,b,tolerance=1.1):assert abs(a-b)<=tolerance,(a,b,tolerance)
initial=state();windows=json.loads(cmd('query','--windows'));fixtures=[w['id'] for w in windows if w['app']=='Tana2DFixture']
assert len(fixtures)==3,'Launch Tana2DFixture first'
moving=next(w['id'] for w in windows if w['app']=='Tana2DFixture' and w['title']=='Tana2D Test 3')
peer,obstacle=[wid for wid in fixtures if wid!=moving]
focused=next((w['id'] for w in windows if w.get('has-focus') and w['app']!='Tana2DFixture'),None)
report={'result':'incomplete','checks':[]};proc=None
try:
    for w in initial['windows']:
        if w['id'] not in fixtures:
            r=w['world'];assert r['x']+r['width']<8000 or r['x']>12000 or r['y']+r['height']<8000 or r['y']>12000
    cmd('window',moving,'--focus');strip('zoom',1)
    targets=[(9688,10000),(10412,10000),(10000,9788),(10000,10312)]
    for edge,(x,y) in enumerate(targets):
        strip('place',obstacle,-50000,-50000,400,300);strip('place',peer,10000,10000,400,300)
        if args.stacked:
            backgrounds=[(9703,9990,300,320),(10397,9990,300,320),(9990,9803,320,200),(9990,10297,320,200)]
            strip('place',obstacle,*backgrounds[edge])
        axis=edge//2;direction=1 if edge%2==0 else -1
        start=[x,y];start[axis]-=direction*60
        strip('place',moving,*start,300,200);strip('camera',9412,9651);time.sleep(.6)
        before=present(moving);raw=[x,y];raw[axis]+=direction*(-6 if args.outside else 6);raw[1-axis]+=3
        strip('input-trace-start')
        proc=subprocess.Popen([str(ROOT/'build/plane_pointer_probe'),str(before['displayedX']+180),str(before['displayedY']+15),str(raw[0]-start[0]),str(raw[1]-start[1]),'native'])
        samples=[];preview=[]
        while proc.poll() is None:
            p=present(moving);samples.append(p)
            if p['snapActive'] and p['snapPreviewVisible']:
                m=json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),str(p['snapPreviewWindow'])],text=True))[0]
                preview.append({'state':p,'metrics':m})
            time.sleep(.008)
        assert proc.returncode==0;proc=None;time.sleep(.35)
        after=present(moving);trace=json.loads(strip('input-trace'))
        entry={'edge':edge,'before':before,'after':after,'samples':samples,'preview':preview,'trace':trace};report['checks'].append(entry)
        assert len(trace)>=20 and any(p['nativeDrag'] for p in samples),'native input not observed'
        assert preview,'no presented snap indication while held'
        p=preview[-1]['state'];m=preview[-1]['metrics']
        assert p['snapEdge']==edge and p['snapNeighbor']==peer
        near(m['public_display_x'],12+(x-9412));near(m['public_display_y'],51+(y-9651))
        near(m['public_display_width'],300);near(m['public_display_height'],200)
        near(after['worldX'],x,.01);near(after['worldY'],y,.01)
        assert after['snapEngagements']==before['snapEngagements']+1 and after['snapCommits']==before['snapCommits']+1
        assert not after['snapActive'] and not after['snapPreviewVisible'] and after['hapticsEnabled']
        print('PASS native snap edge',edge,flush=True)
    assert state()['move_failures']==initial['move_failures']
    report['result']='pass'
finally:
    if proc is not None:proc.wait(timeout=5)
    for w in initial['windows']:
        if w['id'] in fixtures:
            r=w['world'];strip('place',w['id'],r['x'],r['y'],r['width'],r['height'])
    if focused:cmd('window',focused,'--focus')
    strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
    (ROOT/('build/native-snap-feedback'+('-stacked' if args.stacked else '')+('-outside' if args.outside else '')+'-live.json')).write_text(json.dumps(report,indent=2))
