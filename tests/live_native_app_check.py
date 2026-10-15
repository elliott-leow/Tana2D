"""Opt-in global CGEvent native-titlebar check on explicitly selected windows.

Example: python3 tests/live_native_app_check.py --target 6672 420 15 --target 466 250 15
Offsets are relative to the displayed window; choose a known draggable titlebar.
Requires window_metrics and plane_pointer_probe. Restores world frames and camera.
"""
import argparse
import subprocess,json,time,math
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--target',nargs=3,type=float,action='append',required=True,metavar=('WINDOW_ID','GRAB_X','GRAB_Y'))
parser.add_argument('--dx',type=float,default=90)
parser.add_argument('--dy',type=float,default=0)
args=parser.parse_args()
assert math.isfinite(args.dx) and math.isfinite(args.dy) and math.hypot(args.dx,args.dy)>30
wm=str(ROOT/'build/tana2d')
def command(*a):return subprocess.check_output([wm,'-m',*map(str,a)],text=True)
def strip(*a):return command('strip',*a)
def state():return json.loads(strip('status'))
def presentation(w):return json.loads(strip('presentation-status',w))
def metrics(w):return json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),str(w)],text=True))[0]
def settle(w):
 end=time.monotonic()+5
 while time.monotonic()<end:
  p=presentation(w)
  if not any(p[k] for k in ('drag','nativeDrag','edge','navigationPending','sizePending','resizeBusy','nativeMovePending','nativeResizePending','transformDirty')):
   time.sleep(.05);return p
  time.sleep(.02)
 raise AssertionError(('not settled',p))
def checked(w):
 p=settle(w);m=metrics(w)
 assert p['borderVisible'] and p['borderValid'],('border missing',p)
 for a,b in [('public_display_x','displayedX'),('public_display_y','displayedY'),('public_display_width','displayedWidth'),('public_display_height','displayedHeight')]:assert abs(m[a]-p[b])<1.1,(a,b,m,p)
 for value,expected in [(m['final_a'],1/p['cameraScale']),(m['final_d'],1/p['cameraScale']),(-m['final_tx']/m['final_a'],p['displayedX']),(-m['final_ty']/m['final_d'],p['displayedY'])]:assert abs(value-expected)<1.1,(value,expected,m,p)
 for a,b,d in [('borderX','displayedX',-p['borderPad']),('borderY','displayedY',-p['borderPad']),('borderWidth','displayedWidth',2*p['borderPad']),('borderHeight','displayedHeight',2*p['borderPad'])]:assert abs(p[a]-p[b]-d)<1.1,(a,b,p)
 return {'presentation':p,'metrics':m}
initial=state();report=[]
focused=next((w['id'] for w in json.loads(command('query','--windows')) if w.get('has-focus')),None)
assert all(int(wid) in {w['id'] for w in initial['windows']} for wid,_,_ in args.target),'target must be managed'
(ROOT/'build/native-app-start-state.json').write_text(json.dumps(initial,indent=2))
try:
 for target,grab_x,grab_y in args.target:
  wid=int(target)
  command('window',wid,'--focus');strip('zoom',1)
  world=next(w['world'] for w in state()['windows'] if w['id']==wid);v=state()['viewport']
  strip('camera',world['x']-(120-v['x']),world['y']-(51-v['y']));time.sleep(.6)
  entry={'id':wid};report.append(entry)
  before=checked(wid);entry['before']=before;p=before['presentation'];strip('input-trace-start')
  proc=subprocess.Popen([str(ROOT/'build/plane_pointer_probe'),str(p['displayedX']+grab_x),str(p['displayedY']+grab_y),str(args.dx),str(args.dy),'native'])
  samples=[];start=time.monotonic()
  while time.monotonic()-start<1.2:
   sample=presentation(wid);sample['t']=time.monotonic()-start;samples.append(sample);time.sleep(.015)
  assert proc.wait()==0
  released=checked(wid);trace=json.loads(strip('input-trace'));entry.update(samples=samples,released=released,trace=trace)
  assert len(trace)>=20,('no actual global input',trace)
  assert any(s['nativeDrag'] for s in samples),('native controller never owned stream',samples)
  assert math.hypot(released['presentation']['displayedX']-p['displayedX'],released['presentation']['displayedY']-p['displayedY'])>30,('drag did not move',before,released)
  strip('pan',50,30);time.sleep(.6);panned=checked(wid);entry['panned']=panned
  for axis,delta in [('X',50),('Y',30)]:assert abs(panned['presentation']['displayed'+axis]-(released['presentation']['displayed'+axis]-delta))<1.1,('pan stuck',axis,released,panned)
  strip('zoom',.8);time.sleep(.6);zoomed=checked(wid)
  assert abs(zoomed['metrics']['final_a']-1/.8)<.0001,('zoom stuck',zoomed)
  entry['zoomed']=zoomed
finally:
 for w in initial['windows']:
  r=w['world'];strip('place',w['id'],r['x'],r['y'],r['width'],r['height'])
 if focused: command('window',focused,'--focus')
 strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
 time.sleep(.6)
 (ROOT/'build/native-app-check.json').write_text(json.dumps(report,indent=2))
print('PASS real OS native drag, release, pan, zoom and borders for', [r['id'] for r in report])
