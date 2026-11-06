#!/usr/bin/env python3
"""Record a physical gesture without injecting input or changing the camera."""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=float, default=6)
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('build/physical-gesture-pacing.json'))
args = parser.parse_args()
if not 1 <= args.seconds <= 8:
    parser.error('--seconds must be between 1 and 8 (the frame log is bounded)')
cli = ['/Applications/Tana2D.app/Contents/MacOS/tana2d', '-m', 'strip']
def read(command):
    return json.loads(subprocess.check_output(cli + [command], text=True))
initial = read('status')
if not initial['ready'] or initial['paused'] or not initial['backend']:
    parser.error('Start Tana2D with its window helper ready before recording')
read('pacing-reset')
read('profile-reset')
read('transport-reset')
print('Swipe now using your normal three-finger gesture. Recording input and frame timing only.', flush=True)
time.sleep(args.seconds)
report = {'kind': 'physical input timing; not screen scanout', 'initial': initial,
          'pacing': read('pacing'), 'profile': read('profile'),
          'transport': read('transport'), 'frames': read('frame-log'), 'final': read('status')}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(args.output.resolve())
