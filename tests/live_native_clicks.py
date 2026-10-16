"""Real native button actions at the unchanged physical cursor, fixture-only WM.

Run only with the isolated fixture build and an unlocked screen.
No cursor warp, event coordinate conversion, or changes to user windows.
"""
import json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
wm=ROOT/'build/tana2d-fixture-only';fx=ROOT/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture'; events=Path('/tmp/tana2d_fixture_native_events.log')
def cmd(*a):return subprocess.check_output([str(wm),'-m',*map(str,a)],text=True)
def strip(*a):return cmd('strip',*a)
def status():return json.loads(strip('status'))
def query():return [w for w in json.loads(cmd('query','--windows')) if w['app']=='Tana2DFixture']
def actions():return [json.loads(l) for l in events.read_text().splitlines() if l.startswith('{"kind":"action"') ] if events.exists() else []
def wait(f,seconds=3):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  r=f()
  if r:return r
  time.sleep(.005)
 raise AssertionError('timeout')
assert json.loads(strip('fixture-only')), 'Refusing to run against the normal desktop manager'
assert not status()['windows'], 'Close previous disposable fixtures first'
permissions=json.loads(subprocess.check_output([str(wm),'--check-permissions'],text=True))
assert permissions['session_unlocked'], 'Unlock the Mac before native input tests'
assert status()['version']=='0.6.5'
ffm=cmd('config','focus_follows_mouse').strip();report=[]
try:
 cmd('config','focus_follows_mouse','off');subprocess.run(['open',str(ROOT/'build/Tana2DFixture.app')],check=True)
 ids=wait(lambda: (v if len(v:=[w['id'] for w in status()['windows']])==3 else None),6)
 strip('zoom',.5)
 for i,wid in enumerate(ids):strip('place',wid,10000+i*560,10200,500,622)
 time.sleep(.5);strip('actual-size');time.sleep(.5)
 vp=status()['viewport']
 cmd('config','focus_follows_mouse','autofocus')
 for i,wid in enumerate(ids):
  cursor=json.loads(strip('focus-status'))['cursor']
  local_y=min(311,cursor[1]-vp['y']-12)
  assert local_y>=28, 'Place the pointer inside the workspace before the native click test'
  strip('camera',10000+i*560+250-(cursor[0]-vp['x']),10200+local_y-(cursor[1]-vp['y']));time.sleep(.6)
  cmd('window',wid,'--sub-layer','above')
  assert not json.loads(strip('hover-status'))['shield'],'Input cover remains at 100%'
  before=len(actions());sent=json.loads(subprocess.check_output([str(ROOT/'build/stationary_hover_probe'),str(wid),'--click'],text=True))
  action=wait(lambda:next((a for a in actions()[before:] if a['window']==wid and a['time']>=sent['started']),None))
  action_ms=(action['time']-sent['started'])*1000;assert action_ms<50,action_ms
  report.append({'window':wid,'action_ms':action_ms,'camera_moving':False})
  before=len(actions());c=status()['camera'];strip('camera',c['x']+30,c['y']);time.sleep(.03)
  sent=json.loads(subprocess.check_output([str(ROOT/'build/stationary_hover_probe'),str(wid),'--click'],text=True))
  action=wait(lambda:next((a for a in actions()[before:] if a['window']==wid and a['time']>=sent['started']),None))
  action_ms=(action['time']-sent['started'])*1000;assert action_ms<50,action_ms
  report.append({'window':wid,'action_ms':action_ms,'camera_moving':True});time.sleep(.25)
 print(json.dumps(report))
finally:
 subprocess.run([str(fx),'quit']);time.sleep(.2);cmd('config','focus_follows_mouse','off' if ffm=='disabled' else ffm)
 (ROOT/'build/native-click-recovery-report.json').write_text(json.dumps(report,indent=2)+'\n')
