"""Replay captured pointer samples through production controllers on fixture windows.

Never posts OS input. Tests real native sizes and compositor transforms; does not
measure physical input-to-photon latency. Launch Tana2DFixture before running.
"""
import json
import argparse
import subprocess
import time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--scales',nargs='+',type=float,default=[.25,.5,.7,1])
parser.add_argument('--modes',nargs='+',type=int,choices=range(5),default=list(range(5)))
args=parser.parse_args()
WM=ROOT/'build/tana2d'
METRICS=ROOT/'build/window_metrics'
def command(*parts):
    return subprocess.check_output([str(WM),'-m',*map(str,parts)],text=True)
def strip(*parts): return command('strip',*parts)
def status(): return json.loads(strip('status'))
def world(wid): return next(w['world'] for w in status()['windows'] if w['id']==wid)
def metrics(wid): return json.loads(subprocess.check_output([str(METRICS),str(wid)],text=True))[0]
def close(a,b,tolerance=1.2): assert abs(a-b)<=tolerance,(a,b,tolerance)
def pointer(wid,mode,phase,p): strip('fixture-pointer',wid,mode,phase,*p)
def presentation(wid): return json.loads(strip('presentation-status',wid))
def assert_interaction_guards(wid):
    before=presentation(wid); initial_world=world(wid)
    assert before['drag'] or before['edge'],before
    commands=[('camera',before['cameraX']+101,before['cameraY']+77),('pan',81,63),
              ('zoom',1 if before['cameraScale']!=1 else .5),('right',),('move-right',),
              ('fit-all',),('fit-focused',),('actual-size',)]
    for parts in commands:
        subprocess.run([str(WM),'-m','strip',*map(str,parts)],capture_output=True,text=True,check=False)
        after=presentation(wid)
        for key in ('cameraX','cameraY','cameraScale'): close(after[key],before[key],.0001)
        assert after['focusedWindow']==before['focusedWindow'],(parts,before,after)
        assert not after['navigationPending'],(parts,after)
        for key,value in initial_world.items(): close(world(wid)[key],value,.01)

PRESENTATION_KEYS=('displayedX','displayedY','displayedWidth','displayedHeight',
                   'borderX','borderY','borderWidth','borderHeight',
                   'cameraX','cameraY','cameraScale')
def presentation_snapshot(wid,allow_drag=False):
    """Compare public displayed bounds, daemon geometry, and the actual border."""
    s=status(); w=next(w['world'] for w in s['windows'] if w['id']==wid)
    m=metrics(wid); p=presentation(wid)
    missing=[key for key in PRESENTATION_KEYS if key not in p]
    assert not missing,('presentation-status lacks replay geometry',missing,p)
    assert p['displayedValid'] and p['borderValid'] and p['borderVisible'],p
    if not allow_drag:
        assert not (p['drag'] or p['nativeDrag'] or p['edge'] or p['nativeResizePending'] or p['transformDirty']),p
    public=(m['public_display_x'],m['public_display_y'],m['public_display_width'],m['public_display_height'])
    sls=(-m['final_tx']/m['final_a'],-m['final_ty']/m['final_d'],m['w']*p['cameraScale'],m['h']*p['cameraScale'])
    # Verify the final compositor matrix, not merely an accepted base write.
    close(sls[0],public[0],.75); close(sls[1],public[1],.75)
    # CGWindowList is the displayed surface (and screenshot oracle).
    # These are separate cross-process CGWindowList samples, so permit one
    # compositor pixel while still catching the historical large SLS mismatch.
    close(p['displayedX'],public[0],.75); close(p['displayedY'],public[1],.75)
    close(p['displayedWidth'],public[2],.75); close(p['displayedHeight'],public[3],.75)
    # The outline is a public WindowServer rectangle around the displayed surface.
    pad=p['borderPad']
    close(p['borderX'],p['displayedX']-pad,.5); close(p['borderY'],p['displayedY']-pad,.5)
    close(p['borderWidth'],p['displayedWidth']+2*pad,.5); close(p['borderHeight'],p['displayedHeight']+2*pad,.5)
    return {'world':w,'metrics':m,'presentation':p,'public':public,'sls':sls}
def settled_snapshot(wid,deadline=5):
    """Wait for two equal presentation samples; never sleep a guessed duration."""
    previous=None; last_error=None
    while time.monotonic()<deadline:
        try:
            sample=presentation_snapshot(wid)
        except AssertionError as error:
            # A camera/size command is asynchronous. Only accept a valid,
            # stable frame; retain the final failure if it never settles.
            last_error=error.args; previous=None
            time.sleep(.02)
            continue
        signature=(sample['world']['x'],sample['world']['y'],sample['world']['width'],sample['world']['height'],
                   *sample['public'],sample['metrics']['w'],sample['metrics']['h'],
                   sample['presentation']['cameraX'],sample['presentation']['cameraY'],sample['presentation']['cameraScale'])
        if signature==previous: return sample
        previous=signature
        time.sleep(.02)
    raise AssertionError(('presentation did not settle',previous,last_error))
def input_trace(): return json.loads(strip('input-trace'))
initial=status()
focused=next((w['id'] for w in json.loads(command('query','--windows')) if w.get('has-focus') and w['app']!='Tana2DFixture'),None)
ids=[w['id'] for w in json.loads(command('query','--windows')) if w['app']=='Tana2DFixture']
assert ids,'Launch Tana2DFixture first'
wid=next(w['id'] for w in json.loads(command('query','--windows'))
         if w['app']=='Tana2DFixture' and w['title']=='Tana2D Test 3')
fixture_ids=[w['id'] for w in json.loads(command('query','--windows')) if w['app']=='Tana2DFixture']
trace=json.loads((ROOT/'tests/fixtures/drag_cursor_stall.json').read_text())
origin=trace[0]['event']
checks=[]
report={'result':'incomplete','checks':checks,'window':wid}
active_mode=None; last=(0,0)
try:
    # Only disposable fixture windows move. Keep peers far enough away that a
    # release snap cannot turn a free-pointer replay into a placement test.
    for index,fixture_id in enumerate(fixture_ids):
        x,y=(10000,10000) if fixture_id==wid else (-50000-index*5000,-50000-index*5000)
        strip('place',fixture_id,x,y,400,300)
    for other in status()['windows']:
        if other['id'] in fixture_ids: continue
        w=other['world']
        assert (w['x']+w['width']<8000 or w['x']>12500 or
                w['y']+w['height']<8000 or w['y']>12500),('non-fixture window near replay area',other)
    strip('input-trace-start')
    command('window',wid,'--focus')
    strip('actual-size')
    for scale in args.scales:
        for mode in [m for m in args.modes if m<4]:
            strip('place',wid,10000,10000,400,300)
            strip('zoom',scale)
            viewport=status()['viewport']
            strip('camera',10200-viewport['width']/(2*scale),10150-viewport['height']/(2*scale))
            snap=settled_snapshot(wid,time.monotonic()+5)
            before,native,presented,left,top,shown_w,shown_h=snap['world'],snap['metrics'],snap['presentation'],*snap['public']
            assert abs(before['x']-10000)<.01 and abs(before['y']-10000)<.01,(before,snap)
            assert abs(native['w']-400)<.01 and abs(native['h']-300)<.01,native
            assert abs(presented['cameraScale']-scale)<.00001,presented
            assert abs(native['final_a']-1/scale)<.0001,native
            if mode==2: down=(left+shown_w,top+shown_h)
            elif mode==3: down=(left,top)
            else: down=(left+100*scale,top+30*scale)
            start_world=dict(before); start_shown=(left,top); start_camera=(presented['cameraX'],presented['cameraY'],presented['cameraScale'])
            pointer(wid,mode,0,down)
            active_mode=mode; last=down; guards_checked=False
            for row in trace[1:]:
                if row['type']!=6: continue
                factor=.2 if mode>=2 else 1
                delta=[(row['event'][i]-origin[i])*factor for i in (0,1)]
                p=[down[i]+delta[i] for i in (0,1)]
                pointer(wid,mode,1,p)
                if mode<2:
                    if mode==1 and sum(d*d for d in delta)<25:
                        continue
                    sample=presentation_snapshot(wid,allow_drag=True)
                    w=sample['world']; m=sample['metrics']; state=sample['presentation']
                    # Free pointer movement is raw and one-to-one from the
                    # captured start snapshot; target-camera status is never an oracle.
                    close(w['x'],start_world['x']+delta[0]/scale,1.1/scale)
                    close(w['y'],start_world['y']+delta[1]/scale,1.1/scale)
                    close(m['public_display_x'],start_shown[0]+delta[0])
                    close(m['public_display_y'],start_shown[1]+delta[1])
                    close(state['cameraX'],start_camera[0],.0001); close(state['cameraY'],start_camera[1],.0001)
                    close(state['cameraScale'],start_camera[2],.0001)
                    close(m['w'],native['w'],.001); close(m['h'],native['h'],.001)
                else:
                    sign=1 if mode==2 else -1
                    expected=(round(native['w']+sign*delta[0]/scale),round(native['h']+sign*delta[1]/scale))
                    deadline=time.monotonic()+.5
                    while True:
                        w=world(wid); m=metrics(wid)
                        if (abs(m['w']-expected[0])<=1.2 and abs(m['h']-expected[1])<=1.2 and
                            abs(w['width']-expected[0])<=1.2 and abs(w['height']-expected[1])<=1.2): break
                        assert time.monotonic()<deadline,('resize did not follow event',mode,scale,m,expected)
                        time.sleep(.01)
                    sample=presentation_snapshot(wid,allow_drag=True)
                    w=sample['world']; m=sample['metrics']
                    report['last_motion']={'mode':mode,'scale':scale,'native':m,'world':w,'status':status(),
                                           'presentation':presentation(wid),'before':native,'point':p,'left':left,'top':top}
                    close(w['width'],m['w']); close(w['height'],m['h'])
                    if mode==2:
                        close(m['public_display_x'],left); close(m['public_display_y'],top)
                        close(m['public_display_x']+m['public_display_width'],p[0],2)
                        close(m['public_display_y']+m['public_display_height'],p[1],2)
                    else:
                        close(m['public_display_x']+m['public_display_width'],left+shown_w,2)
                        close(m['public_display_y']+m['public_display_height'],top+shown_h,2)
                        close(m['public_display_x'],p[0],2); close(m['public_display_y'],p[1],2)
                if not guards_checked:
                    assert_interaction_guards(wid); guards_checked=True
                last=p
            held=metrics(wid); held_world=world(wid); held_status=status()
            pointer(wid,mode,2,last)
            active_mode=None
            # Away from peers, mouse-up cannot legitimately snap. Its camera,
            # surface, outline, and world geometry must all remain identical.
            for _ in range(3):
                release=settled_snapshot(wid,time.monotonic()+5); m=release['metrics']; w=release['world']; state=release['presentation']
                report['last_release']={'mode':mode,'scale':scale,'held':held,'after':m,'held_status':held_status,'after_status':status()}
                close(m['public_display_x'],held['public_display_x'],.01)
                close(m['public_display_y'],held['public_display_y'],.01)
                close(m['public_display_width'],held['public_display_width'],.01)
                close(m['public_display_height'],held['public_display_height'],.01)
                close(m['w'],held['w'],.01); close(m['h'],held['h'],.01)
                for key in ('x','y','width','height'): close(w[key],held_world[key],.01)
                close(state['cameraX'],start_camera[0],.0001); close(state['cameraY'],start_camera[1],.0001); close(state['cameraScale'],scale,.0001)
            checks.append({'mode':['normal drag','overview drag','bottom-right resize','top-left resize'][mode],'scale':scale,'samples':sum(r['type']==6 for r in trace),'release_stable':True,'held_command_guards':True})
            print(json.dumps(checks[-1]),flush=True)
    # This is a controller/native-bounds synchronization check. It does not
    # claim to reproduce physical AppKit title-bar input.
    fixture=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
    for scale in args.scales if 4 in args.modes else []:
        strip('place',wid,10000,10000,400,300); strip('zoom',scale)
        viewport=status()['viewport']; strip('camera',10200-viewport['width']/(2*scale),10150-viewport['height']/(2*scale))
        start=settled_snapshot(wid,time.monotonic()+5)
        before=start['metrics']; camera=start['presentation']; left,top,shown_w,shown_h=start['public']
        last=(left+80*scale,top+20*scale)
        pointer(wid,4,0,last); active_mode=4
        assert_interaction_guards(wid)
        # Keep anchors on screen and ensure the first command really moves,
        # including reruns that end at one of these fixed destinations.
        targets=[(460,350),(520,390),(400,300),(620,410)]
        if (before['x'],before['y'])==targets[0]: targets=targets[1:]+targets[:1]
        for x,y in targets:
            subprocess.check_call([str(fixture),'move',str(x),str(y)])
            pointer(wid,4,1,last) # Drive the controller after the fixture bound update.
            deadline=time.monotonic()+.5
            expected=(left+x-before['x'],top+y-before['y'])
            while True:
                try:
                    sample=presentation_snapshot(wid,allow_drag=True)
                except AssertionError as error:
                    # The fixture moves asynchronously in its own AppKit loop.
                    # Require valid geometry within the same bounded deadline.
                    assert time.monotonic()<deadline,('native presentation did not synchronize',error.args)
                    time.sleep(.01)
                    continue
                m=sample['metrics']; w=sample['world']; p=sample['presentation']
                shown=sample['public'][:2]
                saved=(viewport['x']+(w['x']-p['cameraX'])*p['cameraScale'],
                       viewport['y']+(w['y']-p['cameraY'])*p['cameraScale'])
                if (abs(m['x']-x)<.01 and abs(m['y']-y)<.01 and
                    all(abs(saved[i]-shown[i])<.03 for i in (0,1))): break
                assert time.monotonic()<deadline,('native model did not follow compositor',m,w,saved,shown)
                time.sleep(.01)
            for i in (0,1): close(shown[i],expected[i],.01)
        held=metrics(wid); held_world=world(wid)
        pointer(wid,4,2,last); active_mode=None
        for _ in range(3):
            sample=settled_snapshot(wid,time.monotonic()+5); m=sample['metrics']; w=sample['world']
            close(m['public_display_x'],held['public_display_x'],.01)
            close(m['public_display_y'],held['public_display_y'],.01)
            close(m['public_display_width'],held['public_display_width'],.01)
            close(m['public_display_height'],held['public_display_height'],.01)
            for key in ('x','y','width','height'): close(w[key],held_world[key],.01)
        checks.append({'mode':'programmatic native-bounds controller sync','scale':scale,'samples':4,'release_stable':True,'held_command_guards':True})
        print(json.dumps(checks[-1]),flush=True)
    assert status()['move_failures']==initial['move_failures']
    assert not input_trace(),'external pointer input interfered with fixture-only replay'
    report['result']='pass'
except BaseException as error:
    report['error']=repr(error)
    raise
finally:
    try:
        if active_mode is not None:
            pointer(wid,active_mode,2,last)
            settled_snapshot(wid,time.monotonic()+5)
        if focused: subprocess.run([str(WM),'-m','window',str(focused),'--focus'],capture_output=True)
        strip('zoom',initial['camera']['scale']); strip('camera',initial['camera']['x'],initial['camera']['y'])
    finally:
        # A failed cleanup must never leave an older passing report in place.
        (ROOT/'build/pointer-replay-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
