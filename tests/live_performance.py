"""Repeatable live render-cost comparison using twelve disposable windows.

Run from the repository root: python3 tests/live_performance.py LABEL
Requires the running manager and make live-tools. Saves reports under build,
then restores the user camera/focus and closes only its fixture application.
"""
import json,subprocess,time,sys
from pathlib import Path
root=Path.cwd(); cli=[str(root/'build/tana2d'),'-m']; exe=str(root/'build/Tana2DFixture.app/Contents/MacOS/plane_fixture')
def cmd(*a):return subprocess.check_output(cli+list(map(str,a)),text=True)
def strip(*a):return cmd('strip',*a)
def state():return json.loads(strip('status'))
def fixtures():return [w['id'] for w in json.loads(cmd('query','--windows')) if w['app']=='Tana2DFixture']
assert len(sys.argv)==2 and sys.argv[1].replace('-','').isalnum(), 'supply an alphanumeric report label'
initial=state();assert initial['ready'] and initial['backend'] and not initial['paused']
focus=next((w['id'] for w in json.loads(cmd('query','--windows')) if w.get('has-focus')),None)
assert not fixtures()
report={'initial':initial,'profiles':[]}; sample=None
try:
 subprocess.run(['open',str(root/'build/Tana2DFixture.app')],check=True);time.sleep(1)
 for i in range(9):subprocess.run([exe,'new'],check=True);time.sleep(.08)
 until=time.monotonic()+8
 while len(fixtures())!=12 and time.monotonic()<until:time.sleep(.1)
 ids=fixtures();assert len(ids)==12,ids
 for i,wid in enumerate(ids):strip('place',wid,10000+(i%4)*420,10000+(i//4)*320,400,300)
 strip('zoom',.7);strip('camera',9900,9900);cmd('window',ids[5],'--focus');strip('camera',9900,9900);time.sleep(1)
 pid=subprocess.check_output(['pgrep','-f','^/Applications/Tana2D.app/Contents/MacOS/tana2d$'],text=True).strip()
 sample=subprocess.Popen(['sample',pid,'12','-file',str(root/'build'/('perf-'+sys.argv[1]+'-sample.txt'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for stage in ('pan','zoom','focus'):
  for trial in range(3):
   strip('zoom',.7);strip('camera',9900,9900);time.sleep(.2);strip('profile-reset');strip('pacing-reset')
   for j in range(8):
    if stage=='pan':strip('pan',160 if j%2==0 else -160,60 if j%2==0 else -60);time.sleep(.27)
    elif stage=='zoom':subprocess.run(['build/plane_gesture_probe','pinch',str(.15 if j%2==0 else -.15)],check=True)
    else:cmd('window',ids[j%12],'--focus');time.sleep(.12)
   time.sleep(.35)
   r={'stage':stage,'trial':trial,'move_failures':state()['move_failures'],'profile':json.loads(strip('profile')),'pacing':json.loads(strip('pacing')),'frames':json.loads(strip('frame-log'))}
   report['profiles'].append(r);print(stage,trial,r['profile'],flush=True)
finally:
 report['before_cleanup']=state()
 subprocess.run([exe,'quit']);time.sleep(.3)
 if focus:cmd('window',focus,'--focus')
 strip('zoom',initial['camera']['scale']);strip('camera',initial['camera']['x'],initial['camera']['y'])
 report['final']=state();(root/'build'/('perf-'+sys.argv[1]+'.json')).write_text(json.dumps(report,indent=2))
 if sample:sample.wait()
