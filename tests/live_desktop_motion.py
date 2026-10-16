"""Plane motion at 100% with the user's real applications.

Fixture windows answer Accessibility instantly and never reposition
themselves, so they could not reproduce the reported jiggle. Real apps
(browsers, terminals, Electron) are slow, constrain their own frames and
publish moves late. This drives replayed three-finger swipes and camera pans
through `build/tana2d-replay` managing the real desktop, and samples every
managed window's displayed position and opacity at ~600 Hz.

It changes only the camera, which it restores. World layout, sizes and focus
are not modified, and the pointer is never moved.
"""
import json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana2d-replay';PROBE=ROOT/'build/desktop_motion_probe'
def cmd(*a):return subprocess.check_output([str(WM),'-m',*map(str,a)],text=True)
def strip(*a):return cmd('strip',*a)
def status():return json.loads(strip('status'))
assert json.loads(subprocess.check_output([str(WM),'--check-permissions'],text=True))['session_unlocked']
assert not json.loads(strip('fixture-only')),'Use the replay build managing the real desktop'

def intersects(a,b):return a[0]<b[0]+b[2] and b[0]<a[0]+a[2] and a[1]<b[1]+b[3] and b[1]<a[1]+a[3]
def expected(s,w):
 vp,c=s['viewport'],s['camera']
 return (vp['x']+w['world']['x']-c['x'],vp['y']+w['world']['y']-c['y'],w['world']['width'],w['world']['height'])

def run(action,ms):
 before=status();ids=[w['id'] for w in before['windows']]
 p=subprocess.Popen([str(PROBE),str(ms),','.join(map(str,ids))],stdout=subprocess.PIPE,text=True)
 assert p.stdout.readline().strip()=='ready'
 action()
 rows=json.loads(p.communicate(timeout=ms/1000+3)[0])
 after=status();vp=after['viewport'];screen=(vp['x'],vp['y'],vp['width'],vp['height'])
 world={w['id']:w for w in after['windows']}
 # Windows on screen both before and after the motion must stay visible and
 # move together. Offscreen windows are legitimately hidden.
 seen=[str(i) for i in ids if i in world and intersects(expected(before,world[i]),screen) and intersects(expected(after,world[i]),screen)
       and all(str(i) in r[1] for r in rows)]
 out={'windows':len(seen),'samples':len(rows)}
 if len(seen)>=1:
  ref=seen[0]
  base={k:(rows[0][1][k][0]-rows[0][1][ref][0],rows[0][1][k][1]-rows[0][1][ref][1]) for k in seen}
  out["drift_px"]=max(abs((r[1][k][a]-r[1][ref][a])-base[k][a]) for r in rows for k in seen for a in (0,1))
  split=0
  for p_,r in zip(rows,rows[1:]):
   # Windows that moved by different amounts in the same sample.
   d=[(r[1][k][0]-p_[1][k][0],r[1][k][1]-p_[1][k][1]) for k in seen]
   if max(abs(u[a]-v[a]) for u in d for v in d for a in (0,1))>1.1:split+=1
  out['split_frames']=split
  out['alpha_min']=min(r[1][k][2] for r in rows for k in seen)
  last=rows[-1][1];settled=None
  for i,r in enumerate(rows):
   if all(abs(r[1][k][a]-last[k][a])<=1.1 for k in seen for a in (0,1)):
    settled=i if settled is None else settled
   else:settled=None
  out['settled_ms']=round(rows[settled][0]*1000,1) if settled is not None else None
  out['final_error_px']=max(max(abs(last[k][0]-expected(after,world[int(k)])[0]),abs(last[k][1]-expected(after,world[int(k)])[1])) for k in seen)
 return out,rows

initial=status();report={'result':'incomplete','cases':[]};failures=[]
try:
 c=initial['camera']
 cases=[('pan',lambda:strip('pan',90,60),1500),('pan',lambda:strip('pan',-90,-60),1500),
        ('swipe',lambda:strip('fixture-swipe',.07,.04,260),1500),('swipe',lambda:strip('fixture-swipe',-.07,-.04,260),1500),
        ('swipe-vertical',lambda:strip('fixture-swipe',0,-.1,220),1500),('swipe-vertical',lambda:strip('fixture-swipe',0,.1,220),1500)]
 def burst():
  for k in range(6):strip('fixture-swipe',.05*(-1)**k,.03*(-1)**k,110);time.sleep(.16)
 cases.append(('swipe-burst',burst,2400))
 for name,action,ms in cases:
  r,rows=run(action,ms);r['case']=name;report['cases'].append(r);print(json.dumps(r),flush=True)
  (ROOT/f'build/desktop-motion-{len(report["cases"])}.json').write_text(json.dumps(rows)+'\n')
  limit=1900 if name=='swipe-burst' else 1000
  if r.get('drift_px',0)>1.1:failures.append(f'{name}: windows drifted {r["drift_px"]}px apart')
  if r.get('split_frames'):failures.append(f'{name}: {r["split_frames"]} frames moved only some windows')
  if r.get('alpha_min',1)<.99:failures.append(f'{name}: a visible window faded to {r["alpha_min"]}')
  if r.get('final_error_px',0)>1.1:failures.append(f'{name}: rest position off by {r["final_error_px"]}px')
  if r.get('windows') and (r.get('settled_ms') is None or r['settled_ms']>limit):failures.append(f'{name}: still moving at {r.get("settled_ms")}ms')
  time.sleep(.4)
 report['result']='failed' if failures else 'passed';report['failures']=failures
finally:
 c=initial['camera'];strip('camera',c['x'],c['y']);time.sleep(.8)
 report['user_world_frames_preserved']={w['id']:w['world'] for w in status()['windows']}=={w['id']:w['world'] for w in initial['windows']}
 (ROOT/'build/desktop-motion-live-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'result':report['result'],'failures':failures,'world_preserved':report['user_world_frames_preserved']}))
sys.exit(0 if report['result']=='passed' and report['user_world_frames_preserved'] else 1)
