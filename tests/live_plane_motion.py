"""Frame-level plane motion at 100%: the jiggle/disappear regression.

Earlier live checks sampled end states and missed what a person sees: windows
moving on different frames, a pan halting part-way when the pointer is over a
window, windows fading out at the top edge, and settling jumps after motion.
This samples every fixture window's actual WindowServer position and opacity
at ~600 Hz through each pan and the settle that follows.

Fixture-only manager and disposable windows only. The pointer is never moved;
the camera is placed so a fixture lies under the unchanged pointer, which
reproduces the synthetic hover WindowServer posts as windows slide beneath it.
"""
import json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana2d-fixture-only';FX=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
PROBE=ROOT/'build/native_stability_probe'
def cmd(*a):return subprocess.check_output([str(WM),'-m',*map(str,a)],text=True)
def strip(*a):return cmd('strip',*a)
def status():return json.loads(strip('status'))
def until(f,timeout=6):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  r=f()
  if r:return r
  time.sleep(.01)
 raise AssertionError('condition timed out')
assert json.loads(strip('fixture-only')),'Refusing to run against the normal desktop manager'
assert json.loads(subprocess.check_output([str(WM),'--check-permissions'],text=True))['session_unlocked']
assert not status()['windows'],'Close previous disposable fixtures first'

def sample(ids,action,ms=1400):
 p=subprocess.Popen([str(PROBE),str(ids[0]),str(ms),','.join(map(str,ids))],stdout=subprocess.PIPE,text=True)
 assert p.stdout.readline().strip()=='ready'
 action()
 rows=json.loads(p.communicate(timeout=ms/1000+3)[0]);assert p.returncode==0 and len(rows)>50
 return rows

def analyse(ids,rows,vp,world_of,camera):
 keys=[str(w) for w in ids if all(str(w) in r[4] for r in rows)]
 assert len(keys)==len(ids),'a fixture window vanished from the window list'
 base={k:(rows[0][4][k][0]-rows[0][4][keys[0]][0],rows[0][4][k][1]-rows[0][4][keys[0]][1]) for k in keys}
 drift=max(abs((r[4][k][a]-r[4][keys[0]][a])-base[k][a]) for r in rows for k in keys for a in (0,1))
 # A sample where some windows moved and others did not, beyond 1px rounding.
 split=0
 for p,r in zip(rows,rows[1:]):
  d=[(r[4][k][0]-p[4][k][0],r[4][k][1]-p[4][k][1]) for k in keys]
  if max(abs(u[a]-v[a]) for u in d for v in d for a in (0,1))>1.1:split+=1
 alpha=min(r[4][k][2] for r in rows for k in keys)
 final=rows[-1][4]
 placement=max(max(abs(final[k][0]-(vp['x']+world_of[int(k)]['x']-camera['x'])),
                   abs(final[k][1]-(vp['y']+world_of[int(k)]['y']-camera['y']))) for k in keys)
 # Settling: once the plane reached its final place, nothing may move again.
 last=rows[-1][4];settled_at=None
 for i,r in enumerate(rows):
  if all(abs(r[4][k][a]-last[k][a])<=1.1 for k in keys for a in (0,1)):
   if settled_at is None:settled_at=i
  else:settled_at=None
 return {'drift_px':drift,'split_frames':split,'alpha_min':alpha,'final_error_px':placement,
         'settled_ms':round(rows[settled_at][0]*1000,1) if settled_at is not None else None,'samples':len(rows)}

report={'result':'incomplete','cases':[]};failures=[]
ffm=cmd('config','focus_follows_mouse').strip()
try:
 cmd('config','focus_follows_mouse','autofocus')
 subprocess.run(['open',str(ROOT/'build/Tana2DFixture.app')],check=True)
 ids=until(lambda:(v if len(v:=[w['id'] for w in status()['windows']])==3 else None))
 strip('zoom',.5)
 for i,w in enumerate(ids):strip('place',w,10000+i*560,10000,500,622)
 time.sleep(.45);strip('actual-size');time.sleep(.6)
 vp=status()['viewport'];cursor=json.loads(strip('focus-status'))['cursor']
 # Put the middle fixture under the unchanged pointer, if the pointer is on screen.
 cx=10560+250-(cursor[0]-vp['x']);cy=10000+200-(cursor[1]-vp['y'])
 cases=[('pointer-over-window',cx,cy,[(80,120),(-80,-120),(300,0),(-300,0)]),
        ('top-edge',10000,9900,[(0,250),(0,-250),(60,400),(-60,-400)]),
        # Physical-gesture path: normalized three-finger swipes (dx, dy, ms).
        ('swipe',cx,cy,[(.08,.05,250),(-.08,-.05,250),(.15,0,180),(-.15,0,180)]),
        ('swipe-top-edge',10000,9900,[(0,-.12,300),(0,.12,300),(.05,-.2,200),(-.05,.2,200)]),
        ('swipe-burst',cx,cy,[('burst',)])]
 def burst():
  # Rapid alternating swipes: each starts while the previous is settling.
  for k in range(6):strip('fixture-swipe',.06*(-1)**k,.04*(-1)**k,120);time.sleep(.17)
 for name,x,y,pans in cases:
  strip('camera',x,y);time.sleep(.8)
  for pan in pans:
   if pan==('burst',):dx,dy='burst','';action=burst;ms=2200
   elif len(pan)==3:dx,dy,dur=pan;action=lambda:strip('fixture-swipe',dx,dy,dur);ms=1400
   else:dx,dy=pan;action=lambda:strip('pan',dx,dy);ms=1400
   rows=sample(ids,action,ms)
   s=status();world={w['id']:w['world'] for w in s['windows']}
   r=analyse(ids,rows,vp,world,s['camera']);r.update(case=name,pan=[dx,dy])
   report['cases'].append(r);print(json.dumps(r),flush=True)
   (ROOT/f'build/plane-motion-{name}-{dx}-{dy}.json').write_text(json.dumps(rows)+'\n')
   if r['drift_px']>1.1:failures.append(f'{name} {dx},{dy}: windows drifted {r["drift_px"]}px apart')
   if r['split_frames']:failures.append(f'{name} {dx},{dy}: {r["split_frames"]} frames moved only some windows')
   if r['alpha_min']<.99:failures.append(f'{name} {dx},{dy}: a window faded to {r["alpha_min"]}')
   if r['final_error_px']>1.1:failures.append(f'{name} {dx},{dy}: rest position off by {r["final_error_px"]}px')
   if r['settled_ms'] is None or r['settled_ms']>(1500 if dx=='burst' else 900):failures.append(f'{name} {dx},{dy}: still moving at {r["settled_ms"]}ms')
 report['result']='failed' if failures else 'passed';report['failures']=failures
finally:
 subprocess.run([str(FX),'quit'],check=False);time.sleep(.25)
 cmd('config','focus_follows_mouse','off' if ffm=='disabled' else ffm)
 (ROOT/'build/plane-motion-live-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'result':report['result'],'failures':failures}))
sys.exit(0 if report['result']=='passed' else 1)
