"""Live CGEvent two/three-neighbor docking checks; creates disposable fixtures.

Requires a ready Tana2D and built live-tools. Restores camera/focus in finally.
Run from the repository root.
"""
import json,subprocess,time
from pathlib import Path
cli=['build/tana2d','-m'];exe='build/Tana2DFixture.app/Contents/MacOS/plane_fixture'
def cmd(*a):return subprocess.check_output(cli+list(map(str,a)),text=True)
def strip(*a):return cmd('strip',*a)
def state():return json.loads(strip('status'))
def query():return json.loads(cmd('query','--windows'))
def presentation(w):return json.loads(strip('presentation-status',w))
initial=state();q=query();assert not any(w['app']=='Tana2DFixture' for w in q);focus=next((w['id'] for w in q if w.get('has-focus')),None);rows=[];proc=None
try:
 subprocess.run(['open','build/Tana2DFixture.app'],check=True);time.sleep(1);subprocess.run([exe,'new'],check=True);time.sleep(.5)
 ids=sorted(w['id'] for w in query() if w['app']=='Tana2DFixture');assert len(ids)==4
 left,above,right,moving=ids
 for scale in [1,.5]:
  for contacts in [2,3]:
   strip('place',left,10000,10412,400,300);strip('place',above,10412,10100,300,300)
   strip('place',right,10724 if contacts==3 else 15000,10412,400,300)
   strip('place',moving,10440,10480,300,300);cmd('window',moving,'--focus');strip('zoom',scale);strip('camera',9800,9900);time.sleep(.8)
   p=presentation(moving);start=(p['displayedX']+100*scale,p['displayedY']+100*scale)
   proc=subprocess.Popen(['build/plane_pointer_probe',str(start[0]),str(start[1]),str(-23*scale),str(-63*scale),'option','180'])
   samples=[]
   while proc.poll() is None:samples.append(presentation(moving));time.sleep(.018)
   time.sleep(.4);p=presentation(moving);rows.append({'scale':scale,'contacts':contacts,'held':samples,'final':p})
   assert abs(p['worldX']-10412)<.01 and abs(p['worldY']-10412)<.01,p
   assert p['worldWidth']==300 and p['worldHeight']==300,p
   assert any(s['snapContacts']==contacts and s['snapPreviewVisible'] for s in samples),samples
   assert p['snapCommits']>samples[0]['snapCommits']
   assert p['borderVisible'] and abs(p['borderX']-(p['displayedX']-p['borderPad']))<=1,p
   print(scale,contacts,'contacts: position, size, preview, commit, border PASS',flush=True)
finally:
 if proc is not None:proc.wait(timeout=3)
 subprocess.run([exe,'quit']);time.sleep(.3)
 if focus:cmd('window',focus,'--focus')
 strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
 Path('build/multi-snap-live.json').write_text(json.dumps(rows,indent=2))
