#!/usr/bin/env python3
"""Retain terminal native receipts and parse them with the pinned trace handler.

Invoke only after wait_tlc has returned terminal status for every listed job.
"""
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
receipts = Path(sys.argv[1]).resolve()
campaign = receipts.parent
pinned = Path('/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/Specula')
sys.path.insert(0, str(pinned / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation import TraceValidationHandler

jobs = json.loads(receipts.read_text())
for job in jobs:
    native = Path(job['result_path']).parent
    result = json.loads((native / 'result.json').read_text())
    dest = campaign / 'tasks' / job['task_id']
    dest.mkdir(parents=True, exist_ok=True)
    for name in ['request.json', 'result.json', 'worker.json', 'worker.log', 'launcher.log', 'tlc.log']:
        if (native / name).exists():
            shutil.copy2(native / name, dest / name)
    raw = (dest / 'tlc.log').read_text()
    parsed = TraceValidationHandler()._parse_output(raw)
    parsed.pop('raw_output', None)
    job.update(result)
    job['validation'] = parsed
    job['log_sha256'] = hashlib.sha256(raw.encode()).hexdigest()
    job['retained_evidence'] = str(dest.relative_to(campaign))
    job['base_sha256'] = hashlib.sha256((Path(job['work_dir']) / 'base.tla').read_bytes()).hexdigest()
    totals = re.findall(r'^([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.', raw, re.M)
    if totals:
        job['totals'] = dict(zip(['generated', 'distinct', 'queued'], [int(x.replace(',', '')) for x in totals[-1]]))
    if job['mode'] == 'positive':
        job['expected_result_observed'] = job['exit_code'] == 0 and parsed['status'] == 'success' and job.get('totals', {}).get('distinct') == job['events'] and job.get('totals', {}).get('queued') == 0
    else:
        job['expected_result_observed'] = job['exit_code'] == 13 and parsed['status'] == 'trace_mismatch' and parsed.get('failed_trace_line') == job['events']
    print(json.dumps({k: job[k] for k in ['label', 'exit_code', 'events', 'validation', 'expected_result_observed']}))
receipts.with_name(receipts.stem.replace('-receipts', '-results') + '.json').write_text(json.dumps(jobs, indent=2) + '\n')
sys.exit(0 if all(j['expected_result_observed'] for j in jobs) else 1)
