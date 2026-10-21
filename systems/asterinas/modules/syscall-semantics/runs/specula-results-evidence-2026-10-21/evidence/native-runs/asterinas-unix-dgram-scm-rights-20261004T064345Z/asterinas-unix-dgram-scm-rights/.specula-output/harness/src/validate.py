#!/usr/bin/env python3
"""Quick Phase 2.5 replays using the reviewed acceptance rule and resource wrapper."""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
SPEC = HARNESS.parent/'spec'
WRAPPER = Path('/home/chin39/Documents/play/Specula/scripts/tlc/run_model_check.sh')
MEMORY_MEASURE = Path('/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(trace, cfg, evidence):
    available = float(subprocess.check_output([str(MEMORY_MEASURE)], text=True))
    while available < 6:
        print(f'Waiting for 6 GiB MemFree + Inactive(file) (currently {available:.2f} GiB).', flush=True)
        time.sleep(10)
        available = float(subprocess.check_output([str(MEMORY_MEASURE)], text=True))
    log = evidence/f'{trace.stem}-{cfg.stem}.log'
    assert not log.exists(), log
    command = ['timeout', '180', 'bash', str(WRAPPER), '-s', 'Trace.tla', '-c', cfg.name,
               '-m', '3G', '-M', '512M', '-w', '2', '-t', '2', '-o', str(log)]
    env = dict(os.environ, JSON=str(trace), SPECULA_TLC_MEMORY_LIMIT='4G', SPECULA_TLC_WORKER_LIMIT='2')
    env['SPECULA_RUN_DIR'] = str(HARNESS.parents[2])
    with (evidence/f'{trace.stem}-{cfg.stem}.launcher.log').open('w') as f:
        p = subprocess.run(command, cwd=SPEC, env=env, stdout=f, stderr=subprocess.STDOUT)
    text = log.read_text() if log.exists() else ''
    initial = re.search(r'Finished computing initial states:\s*(\d+) distinct state', text)
    if not initial:
        initial = re.search(r'Finished computing initial states:\s*(\d+) state', text)
    nonzero = initial and int(initial[1]) > 0
    completed = bool(nonzero and p.returncode == 0 and 'Model checking completed. No error has been found.' in text)
    witness = bool(nonzero and 'Invariant TraceNoCompleteMatch is violated.' in text
                   and not re.search(r'Error: (?!Invariant TraceNoCompleteMatch is violated|The behavior|The following behavior)', text))
    matched_only = bool(nonzero and ('Temporal properties were violated' in text or 'Temporal property TraceMatched was violated' in text)
                        and not re.search(r'Error: (?!Temporal propert|The following behavior)', text))
    return dict(command=command, exit=p.returncode, log=str(log), effective_mem_GiB=available, nonzero_initial=bool(nonzero),
                completed=completed, witness=witness, matched_only=matched_only,
                inputs={str(x): sha(x) for x in [trace, SPEC/'base.tla', SPEC/'Trace.tla', cfg]})

def main():
    evidence = Path(sys.argv[1])
    dest = evidence/'validation'
    dest.mkdir(exist_ok=False)
    results = []
    for trace in sorted((evidence/'normalized').glob('case-*.ndjson')):
        check = run(trace, SPEC/'Trace.cfg', dest)
        result = dict(trace=trace.name, check=check, accepted=check['completed'])
        if check['matched_only'] and not check['completed']:
            search = run(trace, SPEC/'TraceSearch.cfg', dest)
            result.update(search=search, accepted=search['witness'])
        results.append(result)
        (dest/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(f"{trace.name}: {'ACCEPT' if result['accepted'] else 'REJECT'}", flush=True)
        if not result['accepted']:
            raise SystemExit(1)

if __name__ == '__main__': main()
