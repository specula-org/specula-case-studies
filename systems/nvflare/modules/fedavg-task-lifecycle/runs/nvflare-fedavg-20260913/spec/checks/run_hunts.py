#!/usr/bin/env python3
"""Await independent TLC hunts, preserving exact inputs and execution receipts."""
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path('/home/ubuntu/nvflare-runs-20260913/specula')
SPEC = Path(__file__).resolve().parents[1]

def now():
    return datetime.now(timezone.utc).isoformat()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

async def one(cfg, label, simulate):
    dest = SPEC / 'output' / label / cfg.stem
    dest.mkdir(parents=True, exist_ok=False)
    for p in [SPEC / 'base.tla', SPEC / 'MC.tla', cfg]:
        shutil.copy2(p, dest / p.name)
    command = ['timeout', '--kill-after=15s', '31m',
               str(ROOT / 'scripts/infra/run_model_check.sh'),
               '-s', 'MC.tla', '-c', cfg.name, '-m', '4G', '-M', '6G', '-w', '3',
               '-t', '30', '-o', 'tlc.out', '-j', 'counterexample.json']
    if simulate:
        command += ['-S', '-n', '999999999', '-p', '100']
    receipt = dict(config=cfg.name, mode='simulation' if simulate else 'BFS', start=now(),
                   command=command, work_dir=str(dest),
                   hashes={p.name: digest(p) for p in dest.iterdir()},
                   heap='4G', offheap='6G', workers=3, budget_seconds=1800,
                   status='running')
    (dest / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    with (dest / 'wrapper.log').open('w') as log:
        process = await asyncio.create_subprocess_exec(*command, cwd=dest, stdout=log, stderr=asyncio.subprocess.STDOUT)
        receipt['pid'] = process.pid
        (dest / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        code = await process.wait()
    raw = (dest / 'tlc.out').read_text(errors='replace') if (dest / 'tlc.out').exists() else ''
    wrapper = (dest / 'wrapper.log').read_text(errors='replace')
    errors = [s for s in raw.splitlines() if s.startswith('Error:')]
    progress = re.findall(r'Progress\((\d+)\).*?: ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue', raw)
    receipt.update(end=now(), exit_code=code, errors=errors,
                   initialized='Finished computing initial states' in raw or 'Starting...' in raw,
                   completed='Model checking completed. No error has been found.' in raw,
                   progress=progress[-1] if progress else None,
                   diameter=max([int(x) for x in re.findall(r'Progress\((\d+)\)', raw)] +
                                [int(x) for x in re.findall(r'depth of the complete state graph search is (\d+)', raw)] + [0]))
    if errors:
        receipt['status'] = 'violation' if 'violated' in '\n'.join(errors) else 'error'
    elif receipt['completed']:
        receipt['status'] = 'complete-clean'
    elif code == 124 and receipt['initialized'] and 'OutOfMemoryError' not in raw:
        receipt['status'] = 'budget-clean-incomplete'
    elif code == 0 and simulate and 'states checked' in raw:
        receipt['status'] = 'simulation-clean'
    else:
        receipt['status'] = 'error'
    receipt['log_sha256'] = digest(dest / 'tlc.out') if (dest / 'tlc.out').exists() else None
    (dest / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k:receipt[k] for k in ['config','mode','status','exit_code','diameter','progress','errors']}), flush=True)
    return receipt

async def main():
    label = sys.argv[1]
    simulate = '--simulate' in sys.argv[2:]
    names = [x for x in sys.argv[2:] if x != '--simulate']
    cfgs = [SPEC / name for name in names] if names else sorted(SPEC.glob('MC_hunt_*.cfg'))
    if len(cfgs) > 11:
        raise ValueError('Aggregate budget supports at most 11 concurrent runs')
    os.environ.update(SPECULA_ROOT=str(ROOT),
                      TMPDIR='/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/validation-tmp',
                      TLC_STATE_DIR='/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/tlc',
                      SPECULA_TLC_MEMORY_LIMIT='128G', SPECULA_TLC_WORKER_LIMIT='40')
    results = await asyncio.gather(*(one(cfg,label,simulate) for cfg in cfgs))
    (SPEC / 'output' / label / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')

if __name__ == '__main__':
    asyncio.run(main())
