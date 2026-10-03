# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Strict sequential trace replay using the pinned Specula durable TLC task API."""

import argparse
import asyncio
import hashlib
import json
import os
import re
import shutil
import sys
import uuid
from pathlib import Path

from trace_contract import validate_trace


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('traces', nargs='+')
    ap.add_argument('--no-report', action='store_true', help='Only for explicitly labeled negative controls')
    ap.add_argument('--results', default=None)
    ap.add_argument('--report-dir', default=None)
    a = ap.parse_args()
    out = Path(__file__).resolve().parents[2]
    framework = Path(os.environ['SPECULA_ROOT'])
    sys.path.insert(0, str(framework / 'src'))
    from specula.tlc_tasks import start_tlc, wait_tlc

    spec = out / 'spec'
    os.environ['SPECULA_WORK_DIR'] = str(out)
    os.environ.setdefault('SPECULA_TLC_RESOURCE_DIR', str(out / '.tlc-tasks/resources'))
    scratch = out / 'harness/build/replay' / uuid.uuid4().hex
    scratch.mkdir(parents=True)
    os.environ['TLC_STATE_DIR'] = str(scratch)
    rows = []
    results = Path(a.results) if a.results else scratch / 'results.json'
    results.parent.mkdir(parents=True, exist_ok=True)
    for trace in a.traces:
        trace = Path(trace).resolve()
        row = {'trace': str(trace), 'result': 'FAIL'}
        try:
            report_dir = Path(a.report_dir) if a.report_dir else out / 'harness/build/reports'
            report = None if a.no_report else report_dir / (trace.stem + '.json')
            row['integrity'] = validate_trace(trace, spec, report)
            work = scratch / trace.stem
            work.mkdir()
            for filename in ('base.tla', 'Trace.tla', 'Trace.cfg'):
                shutil.copy2(spec / filename, work / filename)
            row['spec_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in work.iterdir()}
            config = (work / 'Trace.cfg').read_text()
            if not re.search(r'^\s+TraceMatched\s*$', config, re.M):
                raise ValueError('TraceMatched is not configured')
            os.environ['JSON'] = str(trace)
            options = ['-m', '2G', '-M', '1G', '-w', '1', '-t', '5']
            task = await start_tlc(str(work), 'Trace.tla', 'Trace.cfg', options)
            row['task'] = task
            rows.append(row)
            results.write_text(json.dumps(rows, indent=2) + '\n')
            while True:
                outcome = await wait_tlc([task['task_id']], timeout_seconds=30, mode='all')
                if outcome['outcome'] == 'finished':
                    break
                print(f"WAIT  {trace.stem} task={task['task_id']}", flush=True)
            final = outcome['tasks'][0]
            row['outcome'] = final
            log = Path(final['log_path']).read_text()
            row['result'] = 'PASS' if (final.get('exit_code') == 0 and
                                      'Model checking completed. No error has been found' in log) else 'FAIL'
            row['statistics'] = re.findall(r'^.*(?:states generated|distinct states found|depth of the complete|Finished in).*$', log, re.M)[-4:]
            if row['result'] == 'FAIL':
                row['errors'] = re.findall(r'^Error:.*$', log, re.M)[:5]
            print(f"{row['result']}  {trace.stem} rc={final.get('exit_code')} log={final['log_path']}", flush=True)
        except (ValueError, KeyError, OSError, TypeError) as exc:
            row['error'] = str(exc)
            if row not in rows:
                rows.append(row)
            print(f'FAIL  {trace.stem}: {exc}', flush=True)
        results.write_text(json.dumps(rows, indent=2) + '\n')
    print(f"{sum(r['result'] == 'PASS' for r in rows)}/{len(rows)} traces passed; results={results}", flush=True)
    return int(any(r['result'] != 'PASS' for r in rows))


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
