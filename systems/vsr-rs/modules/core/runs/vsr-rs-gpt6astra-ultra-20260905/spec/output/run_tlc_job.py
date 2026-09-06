#!/usr/bin/env python3
"""One isolated, budgeted hunt using the installed resource-aware TLC wrapper."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('config')
parser.add_argument('mode', choices=['bfs', 'simulation'])
parser.add_argument('--suffix', default='')
args = parser.parse_args()
spec = Path(__file__).resolve().parent.parent
runner = Path('/home/ubuntu/specula-vsr-runner-20260905')
directory = spec / 'output' / (Path(args.config).stem + '_' + args.mode + args.suffix)
directory.mkdir(exist_ok=False)
inputs = [spec/'base.tla', spec/'MC.tla', spec/args.config]
for path in inputs:
    shutil.copy2(path, directory/path.name)
command = [str(runner/'scripts/infra/run_model_check.sh'), '-s', 'MC.tla',
           '-c', args.config, '-o', 'tlc.out', '-t', '30', '-w', '5',
           '-m', '4G' if args.mode == 'bfs' else '8G',
           '-M', '16G' if args.mode == 'bfs' else '4G',
           '-j', 'counterexample.json']
if args.mode == 'simulation':
    command += ['-S', '-n', '999999999', '-p', '100']
record = dict(config=args.config, mode=args.mode, command=command, cwd=str(directory),
              source_revision='3ac0104a567092139534c9022205d02281a2da41',
              sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
              started_utc=datetime.now(timezone.utc).isoformat(), timeout_seconds=1800,
              outer_timeout_seconds=1860)
meta = directory/'run.json'
meta.write_text(json.dumps(record, indent=2)+'\n')
env = os.environ | {'TLC_STATE_DIR': str(spec/'output/tlc-tmp')}
started = time.monotonic()
with (directory/'launch.out').open('w') as stream:
    proc = subprocess.run(['timeout', '1860s', *command], cwd=directory,
                          env=env, stdout=stream, stderr=subprocess.STDOUT)
elapsed = time.monotonic()-started
text = (directory/'tlc.out').read_text() if (directory/'tlc.out').exists() else ''
launch = (directory/'launch.out').read_text()
record.update(returncode=proc.returncode, elapsed_seconds=round(elapsed, 3),
              finished_utc=datetime.now(timezone.utc).isoformat(),
              errors=[line for line in text.splitlines() if line.startswith('Error:')],
              progress=[line for line in text.splitlines() if line.startswith('Progress')],
              footer=text.splitlines()[-15:])
violation = re.search(r'(?:Invariant (.+?) is violated|Temporal property (.+?) was violated)', text)
record['violation'] = next((x for x in violation.groups() if x), None) if violation else None
record['complete_without_error'] = proc.returncode == 0 and 'No error has been found' in text
record['budget_elapsed_without_error'] = (proc.returncode == 124 and 1795 <= elapsed < 1860
                                          and not record['errors'] and 'Progress' in text)
record['interpretation'] = ('Counterexample requires Case A/B/C analysis' if record['violation']
                            else 'No violation observed within budget; incomplete exploration'
                            if record['budget_elapsed_without_error'] else
                            'Completed search without a violation' if record['complete_without_error']
                            else 'Run requires inspection; not a pass')
meta.write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps({k: record[k] for k in ['config','mode','returncode','elapsed_seconds','violation','interpretation']}, indent=2))
