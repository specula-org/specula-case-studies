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
"""Corrupt copies of a fresh implementation trace to test the input and replay checks.

These are explicitly synthetic negative controls, never implementation evidence.
"""
import copy
import json
import os
import subprocess
from pathlib import Path

from trace_contract import TraceInputError, validate_trace

out = Path(__file__).resolve().parents[2]
evidence = out / 'harness/evidence/continuation/phase3-C6-negative-controls'
evidence.mkdir(parents=True, exist_ok=True)
source = out / 'traces/normal_two_jobs.ndjson'
report = out / 'harness/build/reports/normal_two_jobs.json'
original = [json.loads(x) for x in source.read_text().splitlines()]
results = []


def save(name, records):
    path = evidence / f'{name}.ndjson'
    path.write_text(''.join(json.dumps(r) + '\n' for r in records))
    return path


def change(name, mutation):
    records = copy.deepcopy(original)
    mutation(records)
    return save(name, records)


def event(records, name):
    return next(r['event'] for r in records[1:] if r['event']['name'] == name)


def swapped(records):
    i = next(i for i,r in enumerate(records) if r.get('event',{}).get('name') == 'CmpFinalizeBegin')
    j = next(i for i,r in enumerate(records) if r.get('event',{}).get('name') == 'CmpPublish')
    # Swap semantic events only; keep valid timestamps and sequence envelopes.
    records[i]['event'], records[j]['event'] = records[j]['event'], records[i]['event']


semantic = [
    change('wrong_waiter_read', lambda rs: event(rs,'SpWaitRead')['arg'].update(record_present=False)),
    change('wrong_status', lambda rs: event(rs,'RunnerSetDispatched')['state']['jobs']['j1'].update(status='RUNNING')),
    change('wrong_free', lambda rs: event(rs,'CpCheckResource')['state']['clients']['c1']['free'].append('u0')),
    change('wrong_pending', lambda rs: event(rs,'RunnerStartCollect')['state']['jobs']['j1']['pending'].update(present=False,set=[])),
    change('publish_before_latch', swapped),
]
malformed = [
    change('filtered_record', lambda rs: rs[-1].update(tag='ignored')),
    change('unknown_action', lambda rs: rs[1]['event'].update(name='NotAnAction')),
    change('duplicate_config', lambda rs: rs.append(copy.deepcopy(rs[0]))),
    change('sequence_gap', lambda rs: rs[-1].update(seq=rs[-1]['seq']+1)),
    change('missing_state', lambda rs: rs[1]['event'].pop('state')),
]
for p in malformed:
    try:
        validate_trace(p, out/'spec')
    except (TraceInputError, KeyError, TypeError, ValueError) as exc:
        results.append({'control': p.stem, 'input_rejected': True, 'reason': str(exc)})
    else:
        results.append({'control': p.stem, 'input_rejected': False})
truncated = save('truncated_valid_prefix', original[:-2])
try:
    validate_trace(truncated, out/'spec', report)
except TraceInputError as exc:
    results.append({'control': truncated.stem, 'report_integrity_rejected': True, 'reason': str(exc)})
else:
    results.append({'control': truncated.stem, 'report_integrity_rejected': False})
for p in semantic:
    validate_trace(p,out/'spec')  # corruption is semantic, not malformed JSON
command = [os.environ['NVF_PYTHON'], str(out/'harness/src/validate_traces.py'), '--no-report',
           '--results', str(evidence/'replay-results.json'), *map(str,semantic), str(truncated)]
with (evidence/'replay.log').open('w') as f:
    result = subprocess.run(['timeout','600',*command],stdout=f,stderr=subprocess.STDOUT,check=False)
replays = json.loads((evidence/'replay-results.json').read_text())
for row in replays:
    expected = 'PASS' if Path(row['trace']).stem == truncated.stem else 'FAIL'
    results.append({'control': Path(row['trace']).stem, 'expected_tlc': expected, 'actual_tlc': row['result'],
                    'exit_code': row.get('outcome',{}).get('exit_code'),
                    'errors': row.get('errors',[]), 'task_id': row.get('task',{}).get('task_id')})
ok = all(r.get('input_rejected', True) and r.get('report_integrity_rejected',True)
         and r.get('expected_tlc') == r.get('actual_tlc') for r in results)
for r in results:
    if r.get('expected_tlc') == 'FAIL':
        ok = ok and r.get('exit_code') not in (None,0) and any('TraceMatched' in e for e in r['errors'])
final = {'baseline':str(source), 'label':'synthetic corruptions of fresh implementation trace',
         'checks_passed':ok,'command':command,'validation_command_exit_code':result.returncode,'controls':results,
         'limitation':'TLC accepts a valid finite prefix. Frozen report hash/count checks detect accidental truncation; they do not prove whole-system observation completeness.'}
(evidence/'results.json').write_text(json.dumps(final,indent=2)+'\n')
print(json.dumps(final,indent=2))
raise SystemExit(0 if ok else 1)
