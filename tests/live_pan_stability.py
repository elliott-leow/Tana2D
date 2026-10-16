"""Shared camera pan and top-edge visibility, using only disposable fixtures.

Samples actual WindowServer geometry and opacity. This is IPC camera replay,
not a measurement of physical trackpad feel.
"""
import json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana2d';FX=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
def cmd(*a):return subprocess.check_output([str(WM),'-m',*map(str,a)],text=True)
def strip(*a):return cmd('strip',*a)
def status():return json.loads(strip('status'))
def query():return json.loads(cmd('query','--windows'))
def worlds(s):return {w['id']:w['world'] for w in s['windows']}
def until(f,timeout=6):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  r=f()
  if r:return r
  time.sleep(.01)
 raise AssertionError('condition timed out')
assert json.loads(subprocess.check_output([str(WM),'--check-permissions'],text=True))['session_unlocked']
initial=status();ffm=cmd('config','focus_follows_mouse').strip()
focused=next((w['id'] for w in query() if w.get('has-focus')),None)
assert not [w for w in query() if w['app']=='Tana2DFixture']
report={'result':'incomplete','checks':[],'pointer_operations':0};ids=[]
try:
 cmd('config','focus_follows_mouse','off')
 subprocess.run(['open',str(ROOT/'build/Tana2DFixture.app')],check=True)
 ids=until(lambda:(v if len(v:=[w['id'] for w in status()['windows'] if any(q['id']==w['id'] and q['app']=='Tana2DFixture' for q in query())])==3 else None))
 strip('zoom',.5)
 for i,w in enumerate(ids):strip('place',w,10000+i*560,10000,500,622)
 time.sleep(.45);strip('actual-size');time.sleep(.5);strip('camera',10000,9900);time.sleep(.5)
 vp=status()['viewport']
 for dx,dy in [(80,120),(-80,-120),(0,400),(0,-400)]:
  primary=ids[1]
  p=subprocess.Popen([str(ROOT/'build/native_stability_probe'),str(primary),'1000',','.join(map(str,ids))],stdout=subprocess.PIPE,text=True)
  assert p.stdout.readline().strip()=='ready'
  strip('pan',dx,dy)
  rows=json.loads(p.communicate(timeout=3)[0]);assert p.returncode==0 and len(rows)>50
  offsets={str(w):[rows[0][4][str(w)][a]-rows[0][a+1] for a in [0,1]] for w in ids}
  error=max(abs(r[4][str(w)][a]-r[a+1]-offsets[str(w)][a]) for r in rows for w in ids for a in [0,1])
  assert error<=1.1,('relative drift',dx,dy,error)
  assert min(v[2] for r in rows for v in r[4].values())>.99,('window disappeared',dx,dy)
  camera=status()['camera'];assert camera['scale']==1
  assert not json.loads(strip('hover-status'))['shield'],'Native input was covered'
  for w in ids:
   world=worlds(status())[w]
   actual=rows[-1][4][str(w)]
   assert abs(actual[0]-(vp['x']+world['x']-camera['x']))<=1.1
   assert abs(actual[1]-(vp['y']+world['y']-camera['y']))<=1.1
  report['checks'].append({'pan':[dx,dy],'samples':len(rows),'relative_error_px':error,'alpha_min':1,'shown_y':rows[-1][2]})
  (ROOT/f'build/pan-stability-{dx}-{dy}.json').write_text(json.dumps(rows)+'\n')
 # A clipped native titlebar must not leave keyboard focus waiting on AX.
 for w in ids:cmd('window',w,'--sub-layer','above')
 strip('camera',10000,10000+vp['y']+90);time.sleep(.5)
 cmd('config','focus_follows_mouse','autofocus')
 report['clipped_focus_ms']=[]
 events=Path('/tmp/tana2d_fixture_native_events.log')
 for w in ids[1:]:
  x=vp['x']+worlds(status())[w]['x']-10000+250
  before=status()['camera'];strip('fixture-hover',w,x,200)
  timing=json.loads(strip('hover-status'))['samples'][-1];assert timing['id']==w
  def receipt():
   rows=[json.loads(l) for l in events.read_text().splitlines() if l.startswith('{"kind":"key"')]
   return next((r for r in rows if r['window']==w and r['time']>=timing['started']),None)
  key=until(receipt,1);ms=(key['time']-timing['started'])*1000
  assert ms<50 and status()['camera']==before,(ms,before,status()['camera'])
  report['clipped_focus_ms'].append(ms)
  assert not json.loads(strip('hover-status'))['shield']
 report['result']='passed' 
finally:
 subprocess.run([str(FX),'quit'],check=False);time.sleep(.25)
 if focused:cmd('window',focused,'--focus')
 strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y']);time.sleep(.6)
 cmd('config','focus_follows_mouse','off' if ffm=='disabled' else ffm)
 report['user_world_frames_preserved']=worlds(status())==worlds(initial)
 (ROOT/'build/pan-stability-live-report.json').write_text(json.dumps(report,indent=2)+'\n')
 assert report['user_world_frames_preserved']
print(json.dumps(report))
