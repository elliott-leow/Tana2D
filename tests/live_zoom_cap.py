"""Check the installed 100% camera cap with disposable fixture windows.

Run after make live-tools. Posts generated pinch events and restores the fresh
camera, focused window, autofocus mode, and user-window worlds on completion.
"""
import json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; WM=ROOT/'build/tana2d'; FX=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
def cmd(*a):return subprocess.check_output([str(WM),'-m',*map(str,a)],text=True)
def strip(*a):return cmd('strip',*a)
def status():return json.loads(strip('status'))
def windows():return json.loads(cmd('query','--windows'))
def own():return [w['id'] for w in windows() if w['app']=='Tana2DFixture']
def wait_camera(scale=None,timeout=5):
 end=time.monotonic()+timeout;prev=None
 while time.monotonic()<end:
  s=status();c=s['camera'];sig=tuple(c.values())
  if sig==prev and (scale is None or abs(c['scale']-scale)<.00001):return s
  prev=sig;time.sleep(.04)
 raise AssertionError(('camera did not settle',scale,s))
def gesture(amount):
 p=subprocess.Popen(['build/plane_gesture_probe','pinch',str(amount)])
 samples=[]
 while p.poll() is None:samples.append(status()['camera']);time.sleep(.009)
 assert p.wait()==0
 samples.append(wait_camera()['camera']);assert all(0<c['scale']<=1 for c in samples),samples
 return samples
initial=status();focused=next((w['id'] for w in windows() if w.get('has-focus')),None);ffm=cmd('config','focus_follows_mouse').strip()
assert not own()
report={'before':initial,'checks':[]}
try:
 cmd('config','focus_follows_mouse','off')
 subprocess.run(['open',str(ROOT/'build/Tana2DFixture.app')],check=True)
 end=time.monotonic()+6
 while not own() and time.monotonic()<end:time.sleep(.05)
 ids=own();assert ids
 wid=ids[0]
 for i,w in enumerate(ids):strip('place',w,10000+i*1000,10000,300,200)
 cmd('window',wid,'--focus');strip('zoom',.5);strip('camera',9900,9900);wait_camera(.5)
 samples=gesture(2)
 assert status()['camera']['scale']==1,status()['camera']
 report['checks'].append({'name':'large pinch stops at 100%','samples':samples})
 before=status()['camera'];samples=gesture(1)
 assert status()['camera']==before,(before,status()['camera'])
 report['checks'].append({'name':'pinch at cap leaves camera fixed','samples':samples})
 samples=gesture(-.3)
 assert 0<status()['camera']['scale']<1,status()['camera']
 report['checks'].append({'name':'negative pinch still zooms out','samples':samples})
 strip('fit-focused');fitted=wait_camera(1)
 assert fitted['camera']['scale']==1
 vp=fitted['viewport'];c=fitted['camera'];world=next(w['world'] for w in fitted['windows'] if w['id']==wid)
 assert abs(c['x']+vp['width']/2-(world['x']+world['width']/2))<.02
 assert abs(c['y']+vp['height']/2-(world['y']+world['height']/2))<.02
 report['checks'].append({'name':'fit small focused window stays at actual size and centered','camera':c,'world':world})
 report['result']='passed'
finally:
 subprocess.run([str(FX),'quit'],check=False);time.sleep(.3)
 if focused:cmd('window',focused,'--focus')
 strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y']);wait_camera(initial['camera']['scale'])
 cmd('config','focus_follows_mouse','off' if ffm=='disabled' else ffm)
 final=status();report['after']=final
 assert {w['id']:w['world'] for w in final['windows']}=={w['id']:w['world'] for w in initial['windows']}
 assert final['camera']==initial['camera'],(final['camera'],initial['camera'])
 report['restored']=True
 (ROOT/'build/zoom-cap-live.json').write_text(json.dumps(report,indent=2))
print('PASS',len(report['checks']),'live zoom-cap checks; workspace restored')
