"""Fixture-only docking/feedback acceptance against the installed controller.

No global input is posted. Run with Tana2DFixture open; native CGEvent coverage
is separate. Restores fixture worlds, focus, and camera in finally.
"""
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
parser=argparse.ArgumentParser()
parser.add_argument('--outside',action='store_true',help='Approach without overshooting the docking edge')
args=parser.parse_args()
def command(*args):
    return subprocess.check_output([str(WM), '-m', *map(str,args)], text=True)
def strip(*args): return command('strip', *args)
def state(): return json.loads(strip('status'))
def present(wid): return json.loads(strip('presentation-status', wid))
def metrics(wid):
    return json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'), str(wid)], text=True))[0]
def near(a,b,tolerance=1.1): assert abs(a-b)<=tolerance,(a,b,tolerance)
def settled(wid):
    deadline=time.monotonic()+5; previous=None
    while time.monotonic()<deadline:
        p=present(wid)
        signature=tuple(p[key] for key in ('displayedX','displayedY','displayedWidth','displayedHeight','cameraX','cameraY','cameraScale'))
        expected=(viewport['x']+(p['worldX']-p['cameraX'])*p['cameraScale'],viewport['y']+(p['worldY']-p['cameraY'])*p['cameraScale'])
        if not any(p[key] for key in ('drag','nativeDrag','edge','navigationPending','sizePending','resizeBusy','transformDirty')) and signature==previous and abs(p['displayedX']-expected[0])<=.6 and abs(p['displayedY']-expected[1])<=.6:
            return p
        previous=signature
        time.sleep(.02)
    raise AssertionError(('not settled',p))
def pointer(phase,point): strip('fixture-pointer',moving,0,phase,*point)
def preview_matches(p):
    assert p['snapActive'] and p['snapPreviewVisible'] and p['snapNeighbor']==peer,p
    m=metrics(p['snapPreviewWindow']);margin=p['snapPreviewMargin']
    # The seam surface extends into the gutter on every side of the landing.
    assert p['snapSeams']>=1,p
    near(m['public_display_x'],round(viewport['x']+(p['snapX']-p['cameraX'])*p['cameraScale'])-margin)
    near(m['public_display_y'],round(viewport['y']+(p['snapY']-p['cameraY'])*p['cameraScale'])-margin)
    near(m['public_display_width'],round(p['worldWidth']*p['cameraScale'])+2*margin)
    near(m['public_display_height'],round(p['worldHeight']*p['cameraScale'])+2*margin)

initial=state()
windows=json.loads(command('query','--windows'))
fixtures=[w['id'] for w in windows if w['app']=='Tana2DFixture']
assert len(fixtures)==3,'Launch Tana2DFixture first'
moving=next(w['id'] for w in windows if w['app']=='Tana2DFixture' and w['title']=='Tana2D Test 3')
peer,obstacle=[wid for wid in fixtures if wid!=moving]
focused=next((w['id'] for w in windows if w.get('has-focus') and w['app']!='Tana2DFixture'),None)
viewport=initial['viewport']; active=False; last=(0,0)
report={'result':'incomplete','checks':[]}
try:
    for w in initial['windows']:
        if w['id'] not in fixtures:
            r=w['world']; assert r['x']+r['width']<8000 or r['x']>12000 or r['y']+r['height']<8000 or r['y']>12000
    command('window',moving,'--focus')
    targets=[(9688,10000),(10412,10000),(10000,9788),(10000,10312)]
    for scale in (.25,.5,1):
        for edge,(x,y) in enumerate(targets):
            strip('place',obstacle,-50000,-50000,400,300)
            strip('place',peer,10000,10000,400,300)
            axis=edge//2; direction=1 if edge%2==0 else -1
            start=[x,y]; start[axis]-=direction*60/scale
            strip('place',moving,*start,300,200);strip('zoom',scale)
            left=min(x,10000);top=min(y,10000)
            right=max(x+300,10400);bottom=max(y+200,10300)
            strip('camera',(left+right)/2-viewport['width']/(2*scale),(top+bottom)/2-viewport['height']/(2*scale))
            before=settled(moving);last=(before['displayedX']+100*scale,before['displayedY']+20*scale)
            pointer(0,last);active=True
            raw=[x,y];raw[axis]+=direction*(-6 if args.outside else 6)/scale;raw[1-axis]+=3/scale
            last=(last[0]+(raw[0]-start[0])*scale,last[1]+(raw[1]-start[1])*scale)
            pointer(1,last);held=present(moving)
            report['current']={'before':before,'held':held,'raw':raw,'scale':scale,'edge':edge}
            near(held['worldX'],raw[0],1/scale);near(held['worldY'],raw[1],1/scale)
            preview_matches(held);assert held['snapEdge']==edge
            assert held['snapEngagements']==before['snapEngagements']+1 and held['hapticsEnabled']
            # Repeated motion samples on the same target must not buzz/redraw.
            for _ in range(5): pointer(1,last)
            same=present(moving)
            assert same['snapEngagements']==held['snapEngagements'] and same['previewDraws']==held['previewDraws']
            pointer(2,last);active=False;released=settled(moving)
            near(released['worldX'],x,.01);near(released['worldY'],y,.01)
            assert released['snapCommits']==before['snapCommits']+1 and not released['snapActive']
            report['checks'].append({'scale':scale,'edge':edge,'preview':True,'single_engagement':True,'committed':True})
            print(report['checks'][-1],flush=True)
    # Existing overlap is reduced rather than preventing a nearby side snap.
    strip('place',peer,10000,10000,400,300);strip('place',obstacle,9703,9990,300,320)
    strip('place',moving,9600,10000,300,200);strip('zoom',1);strip('camera',9400,9800)
    before=settled(moving);last=(before['displayedX']+100,before['displayedY']+15)
    pointer(0,last);active=True;last=(last[0]+(82 if args.outside else 94),last[1]+3);pointer(1,last)
    preview_matches(present(moving));pointer(2,last);active=False;released=settled(moving)
    near(released['worldX'],9688,.01);near(released['worldY'],10000,.01)
    report['checks'].append({'existing_overlap':'reduced and docked'})
    # Slide along one neighboring edge: reuse the same raster at 120 Hz input.
    strip('place',obstacle,-50000,-50000,400,300);strip('place',peer,10000,10000,400,600)
    strip('place',moving,9694,10050,300,200);strip('camera',9400,9800)
    before=settled(moving);last=(before['displayedX']+100,before['displayedY']+15)
    pointer(0,last);active=True;last=(last[0],last[1]+1);pointer(1,last)
    held=present(moving);preview_matches(held);strip('profile-reset')
    began=time.monotonic()
    for i in range(120):
        last=(last[0],last[1]+.5);pointer(1,last)
        remaining=began+(i+1)/120-time.monotonic()
        if remaining>0:time.sleep(remaining)
    end=present(moving);preview_matches(end)
    assert end['previewDraws']==held['previewDraws'] and end['snapEngagements']==held['snapEngagements']
    assert end['previewMoves']-held['previewMoves']>=59
    report['profile']=json.loads(strip('profile'));report['input_duration']=time.monotonic()-began
    report['checks'].append({'sliding_samples':120,'extra_raster_draws':end['previewDraws']-held['previewDraws'],'extra_haptic_engagements':end['snapEngagements']-held['snapEngagements']})
    pointer(2,last);active=False;settled(moving)
    assert state()['move_failures']==initial['move_failures']
    report['result']='pass'
finally:
    if active:pointer(2,last)
    for w in initial['windows']:
        if w['id'] in fixtures:
            r=w['world'];strip('place',w['id'],r['x'],r['y'],r['width'],r['height'])
    if focused:command('window',focused,'--focus')
    strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
    (ROOT/('build/snap-feedback'+('-outside' if args.outside else '')+'-live.json')).write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
