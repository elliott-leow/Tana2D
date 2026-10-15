"""Bounded real-CGEvent multi-snap matrix using only disposable fixtures.

Checks actual held multi-edge positions, released landings, independent public
presentation bounds, and unchanged user geometry. Two no-dwell cases separately
check fast releases. Run after make live-tools with a ready manager.
"""
import json
import math
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana2d'
FIXTURE=ROOT/'build/Tana2DFixture.app'
FIXTURE_CTL=FIXTURE/'Contents/MacOS/plane_fixture'
PROBE=ROOT/'build/plane_pointer_probe'
HIT_PROBE=ROOT/'build/plane_hit_probe'
METRICS=ROOT/'build/window_metrics'
REPORT=ROOT/'build/multi-snap-matrix.json'

def command(*args): return subprocess.check_output([str(WM),'-m',*map(str,args)],text=True)
def strip(*args): return command('strip',*args)
def status(): return json.loads(strip('status'))
def windows(): return json.loads(command('query','--windows'))
def present(wid): return json.loads(strip('presentation-status',wid))
def metrics(wid): return json.loads(subprocess.check_output([str(METRICS),str(wid)],text=True))[0]
def fixture_ids(): return [w['id'] for w in windows() if w['app']=='Tana2DFixture']
def near(a,b,tol=1.25): return abs(a-b)<=tol

def settle(wid,deadline=4):
    previous=None
    end=time.monotonic()+deadline
    while time.monotonic()<end:
        p=present(wid)
        sig=tuple(p.get(k) for k in ('worldX','worldY','displayedX','displayedY','cameraX','cameraY','cameraScale','drag','nativeDrag'))
        if not p.get('drag') and not p.get('nativeDrag') and not p.get('nativeMovePending') and sig==previous:
            return p
        previous=sig
        time.sleep(.025)
    return present(wid)

def gap_ok(final,configured_rects,actual_rects,target):
    """Check each configured contact against measured peer and landing bounds."""
    x,y=final['worldX'],final['worldY']
    fw,fh=final['worldWidth'],final['worldHeight']
    tx,ty=target
    checks=[]
    for (_,cx,cy,cw,ch),(rx,ry,rw,rh) in zip(configured_rects,actual_rects):
        if near(cx+cw+12,tx,.05): checks.append(near(x-(rx+rw),12,.35))
        if near(cx-300-12,tx,.05): checks.append(near(rx-(x+fw),12,.35))
        if near(cy+ch+12,ty,.05): checks.append(near(y-(ry+rh),12,.35))
        if near(cy-300-12,ty,.05): checks.append(near(ry-(y+fh),12,.35))
    return bool(checks) and all(checks)

def pointer_start(before,scale,mode,moving):
    """Use the displayed surface and prove WindowServer will target this fixture."""
    x=before['displayedX']+before['displayedWidth']/2
    y=before['displayedY']+(before['displayedHeight']/2 if mode=='option' else 15*scale)
    start=(x,y)
    hit=subprocess.check_output([str(HIT_PROBE),f'{x:.4f}',f'{y:.4f}'],text=True).strip()
    first=hit.splitlines()[0] if hit else ''
    if f'id={moving} ' not in first:
        raise AssertionError(f'displayed start does not hit fixture {moving}: {start} -> {first}')
    return start,first

def trace_timestamps_ok(trace):
    times=[row.get('time',0) for row in trace]
    return len(times)>=20 and all(isinstance(t,int) and t>0 for t in times) and all(b>=a for a,b in zip(times,times[1:]))

def sample_drag(moving,start,delta,mode,hold_ms=180):
    args=[str(PROBE),f'{start[0]:.4f}',f'{start[1]:.4f}',f'{delta[0]:.4f}',f'{delta[1]:.4f}',mode]
    if hold_ms: args.append(str(hold_ms))
    proc=subprocess.Popen(args)
    samples=[]
    try:
        while proc.poll() is None:
            p=present(moving)
            if p.get('snapPreviewVisible'):
                try: p['_previewMetrics']=metrics(p['snapPreviewWindow'])
                except subprocess.CalledProcessError: pass
            samples.append(p); time.sleep(.009)
    finally:
        proc.wait(timeout=3)
    time.sleep(.32)
    return proc.returncode,samples

def projected(p,x,y):
    return (round(12+(x-p['cameraX'])*p['cameraScale']),round(51+(y-p['cameraY'])*p['cameraScale']))

def configure(moving,peers,target,scale,source_sign=(1,1),partial_camera=False):
    """Place only fixtures. peers is [(id,x,y,w,h), ...]."""
    for wid,x,y,w,h in peers: strip('place',wid,x,y,w,h)
    used={wid for wid,*_ in peers}
    for wid in FIXTURES:
        if wid not in used and wid!=moving: strip('place',wid,-50000-wid,-50000,300,300)
    sx,sy=source_sign
    start=(target[0]+sx*60/scale,target[1]+sy*60/scale)
    strip('place',moving,start[0],start[1],300,300)
    command('window',moving,'--focus'); time.sleep(.08)
    strip('zoom',scale)
    if partial_camera:
        camera=(target[0]+(12 if partial_camera=='offscreen' else -20)/scale,target[1]-149/scale)
    else:
        camera=(target[0]-843/scale,target[1]-524.5/scale)
    strip('camera',*camera); time.sleep(.18)
    return settle(moving)

def positive_case(label,peers,target,scale,mode,source_sign=(1,1),contacts=2,partial_camera=False,hold_ms=180,require_held=True):
    moving=FIXTURES[-1]
    before=configure(moving,peers,target,scale,source_sign,partial_camera)
    raw=(target[0]+source_sign[0]*6/scale,target[1]+source_sign[1]*6/scale)
    start,hit=pointer_start(before,scale,mode,moving)
    delta=((raw[0]-before['worldX'])*scale,(raw[1]-before['worldY'])*scale)
    strip('input-trace-start')
    rc,samples=sample_drag(moving,start,delta,mode,hold_ms)
    final=settle(moving)
    preview=[p for p in samples if p.get('snapPreviewVisible')]
    max_contacts=max((p.get('snapContacts',0) for p in preview),default=0)
    trace=json.loads(strip('input-trace'))
    held=[p for p in samples if p.get('drag') or p.get('nativeDrag')]
    held_error=None if not held else math.hypot(held[-1]['worldX']-raw[0],held[-1]['worldY']-raw[1])
    held_target=any(p.get('snapContacts',0)>=contacts and near(p['worldX'],target[0],.35) and near(p['worldY'],target[1],.35)
                    for p in preview if p.get('drag') or p.get('nativeDrag'))
    preview_public=None
    metric_preview=next((p for p in reversed(preview) if '_previewMetrics' in p),None)
    if metric_preview:
        p=metric_preview; m=p['_previewMetrics']; px,py=projected(p,p['snapX'],p['snapY'])
        preview_public={'x':m['public_display_x'],'y':m['public_display_y'],'w':m['public_display_width'],'h':m['public_display_height'],
                        'expected':(px,py,round(300*scale),round(300*scale))}
    surface=metrics(moving)
    border=metrics(final['borderWindow'])
    landed=near(final['worldX'],target[0],.35) and near(final['worldY'],target[1],.35)
    size_ok=near(final['worldWidth'],300,.01) and near(final['worldHeight'],300,.01)
    preview_ok=bool(preview) and max_contacts>=contacts
    public_ok=preview_public is not None and all(near(a,b,1.1) for a,b in zip(
        (preview_public['x'],preview_public['y'],preview_public['w'],preview_public['h']),preview_public['expected']))
    pad=final['borderPad']
    border_ok=final.get('borderVisible') and all(near(actual,expected,1.5) for actual,expected in zip(
        (border['public_display_x'],border['public_display_y'],border['public_display_width'],border['public_display_height']),
        (surface['public_display_x']-pad,surface['public_display_y']-pad,surface['public_display_width']+2*pad,surface['public_display_height']+2*pad)))
    haptics={'engagements':final['snapEngagements']-before['snapEngagements'],'commits':final['snapCommits']-before['snapCommits']}
    actual_peers=[present(wid) for wid,*_ in peers]
    actual_rects=[(p['worldX'],p['worldY'],p['worldWidth'],p['worldHeight']) for p in actual_peers]
    checks={'process':rc==0,'input_trace':len(trace)>=20,'input_trace_timestamps':trace_timestamps_ok(trace),
            'landed':landed,'size':size_ok,'gaps':gap_ok(final,peers,actual_rects,target),'border':border_ok,
            'haptic_engagement':haptics['engagements']>=1,'haptic_commit':haptics['commits']>=1}
    if require_held:
        checks.update(preview=preview_ok,held_target=held_target,preview_public=public_ok)
    return {'label':label,'kind':'positive','scale':scale,'mode':mode,'expectedContacts':contacts,'target':target,'raw':raw,
            'checks':checks,'pass':all(checks.values()),'maxPreviewContacts':max_contacts,'haptics':haptics,
            'holdMs':hold_ms,'heldTargetRequired':require_held,'heldPointerErrorDiagnostic':held_error,'heldTargetWhilePreviewActive':held_target,'before':before,'final':final,'traceCount':len(trace),
            'start':start,'windowServerHit':hit,'previewPublic':preview_public,'borderPublic':border,'surfacePublic':surface,'trace':trace,'samples':samples[-8:]}

def negative_case(label,peers,target,scale,source_sign,kind):
    moving=FIXTURES[-1]
    before=configure(moving,peers,target,scale,source_sign,partial_camera='offscreen' if kind=='offscreen' else False)
    raw=(target[0]+source_sign[0]*6/scale,target[1]+source_sign[1]*6/scale)
    start,hit=pointer_start(before,scale,'native',moving)
    delta=((raw[0]-before['worldX'])*scale,(raw[1]-before['worldY'])*scale)
    strip('input-trace-start')
    rc,samples=sample_drag(moving,start,delta,'native'); final=settle(moving)
    trace=json.loads(strip('input-trace'))
    preview=any(p.get('snapPreviewVisible') for p in samples)
    commits=final['snapCommits']-before['snapCommits']
    checks={'process':rc==0,'input_trace':len(trace)>=20,'input_trace_timestamps':trace_timestamps_ok(trace),
            'no_preview':not preview,'no_commit':commits==0,'size':near(final['worldWidth'],300,.01) and near(final['worldHeight'],300,.01)}
    return {'label':label,'kind':kind,'scale':scale,'target':target,'raw':raw,'checks':checks,'pass':all(checks.values()),
            'start':start,'windowServerHit':hit,'before':before,'final':final,'trace':trace,'samples':samples[-8:]}

def safe_case(label,fn,*args):
    try: return fn(label,*args)
    except Exception as exc:
        return {'label':label,'kind':'harness-case-error','pass':False,'checks':{'exception':False},
                'error':{'type':type(exc).__name__,'message':str(exc),'traceback':traceback.format_exc()}}

initial=status(); initial_windows=windows(); assert not fixture_ids(),'Tana2DFixture already running'
focused=next((w['id'] for w in initial_windows if w.get('has-focus')),None)
def user_geometry(ws):
    result={}
    managed={w['id'] for w in status()['windows']}
    for w in ws:
        if w['app']=='Tana2DFixture' or w['id'] not in managed: continue
        p=present(w['id'])
        result[str(w['id'])]={'app':w['app'],'world':{k:p[k] for k in ('worldX','worldY','worldWidth','worldHeight')}}
    return result
initial_user_geometry=user_geometry(initial_windows)
report={'started':time.time(),'version':initial['version'],'initialCamera':initial['camera'],'initialFocus':focused,'initialUserGeometry':initial_user_geometry,'magneticHeldTargetRequired':True,'cases':[],'result':'incomplete'}
FIXTURES=[]
probe=None
try:
    subprocess.run(['open',str(FIXTURE)],check=True); time.sleep(.8)
    subprocess.run([str(FIXTURE_CTL),'new'],check=True); time.sleep(.3)
    FIXTURES=fixture_ids(); assert len(FIXTURES)==4,FIXTURES
    target=(10412,10412); left=(10000,10412,400,300); right=(10724,10412,400,300); above=(10412,10000,300,400); below=(10412,10724,300,400)
    corner_defs=[('corner-left-above',[left,above],(1,1)),('corner-left-below',[left,below],(1,-1)),
                 ('corner-right-above',[right,above],(-1,1)),('corner-right-below',[right,below],(-1,-1))]
    # All quadrants at normal and Option drags at 1x/.5x, then native 2x.
    for label,rects,sign in corner_defs:
        for scale,mode in ((1,'native'),(1,'option'),(.5,'native'),(.5,'option'),(2,'native')):
            peers=[(FIXTURES[i],*rect) for i,rect in enumerate(rects)]
            report['cases'].append(safe_case(label,positive_case,peers,target,scale,mode,sign,2))
    # Same-size three-neighbor fits with opposite vertical constraints.
    for label,vertical,sign in (('fit-left-right-above',above,(1,1)),('fit-left-right-below',below,(1,-1))):
        for scale,mode in ((1,'native'),(1,'option'),(.5,'option')):
            peers=[(FIXTURES[0],*left),(FIXTURES[1],*right),(FIXTURES[2],*vertical)]
            report['cases'].append(safe_case(label,positive_case,peers,target,scale,mode,sign,3))
    # Screenshot-like staggered peers: short horizontal overlap, unequal sizes.
    staggered_target=(10412,10595)
    staggered_left=(9449,9656,951,1048)
    staggered_above=(10436,9534,978,1049)
    for mode in ('native',):
        peers=[(FIXTURES[0],*staggered_left),(FIXTURES[1],*staggered_above)]
        report['cases'].append(safe_case('staggered-screenshot',positive_case,peers,staggered_target,1,mode,(1,1),2))
    peers=[(FIXTURES[0],*left),(FIXTURES[1],*above)]
    report['cases'].append(safe_case('partial-screen-corner',positive_case,peers,target,1,'native',(1,1),2,True))
    # These intentionally release immediately: release landing is required but
    # a sampled preview/held magnetic target is not, because no dwell occurs.
    report['cases'].append(safe_case('fast-release-corner',positive_case,[(FIXTURES[0],*left),(FIXTURES[1],*above)],target,1,'native',(1,1),2,False,0,False))
    report['cases'].append(safe_case('fast-release-three-peer',positive_case,[(FIXTURES[0],*left),(FIXTURES[1],*right),(FIXTURES[2],*below)],target,1,'native',(1,-1),3,False,0,False))
    # The target is occupied, so the otherwise-valid two-edge landing is rejected.
    blocked=(10412,10412,300,300)
    peers=[(FIXTURES[0],*left),(FIXTURES[1],*above),(FIXTURES[2],*blocked)]
    report['cases'].append(safe_case('blocked-corner',negative_case,peers,target,1,(1,1),'blocked'))
    # Left peer ends just outside the displayed screen while the title bar remains usable.
    off_left=(10000,10412,400,300)
    peers=[(FIXTURES[0],*off_left)]
    report['cases'].append(safe_case('offscreen-peer',negative_case,peers,target,1,(1,1),'offscreen'))
    report['result']='pass' if all(case['pass'] for case in report['cases']) else 'fail'
except Exception as exc:
    report['harnessError']={'type':type(exc).__name__,'message':str(exc),'traceback':traceback.format_exc()}
    report['result']='harness-error'
finally:
    try:
        subprocess.run([str(FIXTURE_CTL),'quit'],check=False); time.sleep(.35)
        if focused: command('window',focused,'--focus'); time.sleep(.12)
        strip('zoom',initial['camera']['scale']); strip('camera',initial['camera']['x'],initial['camera']['y']); time.sleep(.25)
        final_user_geometry=user_geometry(windows())
        changed={wid:{'before':before,'after':final_user_geometry.get(wid)} for wid,before in initial_user_geometry.items() if final_user_geometry.get(wid)!=before}
        report['restored']={'fixtures':fixture_ids(),'camera':status()['camera'],'focused':next((w['id'] for w in windows() if w.get('has-focus')),None),'userGeometryChanged':changed}
    except Exception as exc:
        report['restoreError']=str(exc)
    restored=report.get('restored',{})
    restored_camera=restored.get('camera',{})
    if ('restoreError' in report or not restored or restored.get('fixtures') or
        restored.get('userGeometryChanged') or restored.get('focused')!=focused or
        any(abs(restored_camera.get(k,float('inf'))-v)>.002 for k,v in initial['camera'].items())):
        report['result']='restore-error'
    report['finished']=time.time()
    REPORT.write_text(json.dumps(report,indent=2)+'\n')

passed=sum(1 for case in report['cases'] if case.get('pass'))
print(json.dumps({'result':report['result'],'passed':passed,'total':len(report['cases']),'report':str(REPORT),'restored':report.get('restored')},indent=2))

sys.exit(0 if report['result']=='pass' else 1)
