#!/usr/bin/env python3
"""Run-local TLC launch adapter; same durable budgeted API, larger state filesystem.

The MCP start tool cannot set TLC_STATE_DIR. The default /tmp quota failed in
continuation C2. This adapter changes only that environment setting and freezes
the exact model/config for each run. Use wait_tlc with the returned task IDs.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
OUT = HERE.parent
FRAME = HERE.parents[4]
sys.path.insert(0, str(FRAME / 'src'))
from specula.tlc_tasks import start_tlc, status

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=['start', 'collect'])
    ap.add_argument('name')
    ap.add_argument('config', nargs='?', default='MC.cfg')
    ap.add_argument('--heap', default='8G')
    ap.add_argument('--offheap', default='16G')
    ap.add_argument('--workers', default='8')
    ap.add_argument('--simulation', action='store_true')
    ap.add_argument('--spec-file', default='MC.tla')
    a = ap.parse_args()
    os.environ['SPECULA_WORK_DIR'] = str(OUT)
    os.environ.setdefault('SPECULA_TLC_TOOL_OWNER', str(OUT/'spec-validation.log'))
    os.environ['SPECULA_TLC_MEMORY_LIMIT'] = '64G'
    os.environ['SPECULA_TLC_WORKER_LIMIT'] = '16'
    state_root = OUT / '.tlc-state'
    state_root.mkdir(exist_ok=True)
    os.environ['TLC_STATE_DIR'] = str(state_root)
    directory = HERE/'output'/a.name
    if a.mode == 'start':
        if Path(a.spec_file).name != a.spec_file or not a.spec_file.endswith('.tla'):
            raise SystemExit('Expected a local TLA module filename.')
        directory.mkdir()
        for f in dict.fromkeys(['base.tla', 'MC.tla', a.spec_file, a.config]):
            shutil.copy2(HERE/f, directory/f)
        options = ['-m',a.heap,'-M',a.offheap,'-w',a.workers,'-t','30',
                   '-j',str(directory/'counterexample.json')]
        if a.simulation:
            options += ['-S','-n','999999999','-p','100']
        manifest = {'name':a.name, 'config':a.config,'spec_file':a.spec_file,'options':options,
                    'state_directory':str(state_root),
                    'sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in directory.iterdir()}}
        task = asyncio.run(start_tlc(str(directory),a.spec_file,a.config,options))
        manifest['task'] = task
        (directory/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(json.dumps(task))
    else:
        manifest=json.loads((directory/'manifest.json').read_text())
        outcome=status(manifest['task']['task_id'])
        if outcome['status'] in ('running','starting'):
            raise SystemExit('Task still running; use wait_tlc before collect.')
        for source,target in [('log_path','tlc.out'),('launcher_log_path','launcher.log'),('result_path','result.json')]:
            shutil.copy2(outcome[source],directory/target)
        print(json.dumps(outcome))

if __name__ == '__main__':
    main()
