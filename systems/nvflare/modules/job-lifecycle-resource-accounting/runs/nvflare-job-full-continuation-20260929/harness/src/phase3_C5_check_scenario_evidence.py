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
"""Check that the adopted source-derived seed scenarios actually exercise their named mechanisms.

These are trace-harness assertions, not MC seed runs or independent product confirmation.
"""
import json
from pathlib import Path

out = Path(__file__).resolve().parents[2]
rows = []


def load(name):
    records = [json.loads(x) for x in (out / 'traces' / (name + '.ndjson')).read_text().splitlines()]
    return [r['event'] for r in records[1:]], json.loads((out/'harness/build/reports'/(name+'.json')).read_text())


def locate(events, name, after=-1, pred=lambda e: True):
    return next(i for i,e in enumerate(events) if i > after and e['name'] == name and pred(e))


def state(events, i, job='j1'):
    return events[i]['state']['jobs'][job]


def record(name, fn):
    try:
        details = fn(*load(name))
        rows.append({'scenario': name, 'passed': True, 'details': details})
    except (AssertionError, StopIteration, KeyError) as exc:
        rows.append({'scenario': name, 'passed': False, 'error': repr(exc)})


def normal(events, report):
    assert all(s == 'FINISHED:COMPLETED' for s in report['final_status'].values())
    assert not events[-1]['state']['scheduled_jobs'] and not events[-1]['state']['running_jobs']
    for c in events[-1]['state']['clients'].values():
        assert sorted(c['free']) == ['u0','u1'] and not c['reserved']
        assert all(not j['allocated'] and not j['registration']['present'] for j in c['jobs'].values())
    return 'Two completed jobs, released admission slots and original list-unit capacity.'


def f1(events, report):
    abort = locate(events,'AdminAbortWrite')
    assert state(events,abort)['status'] == 'FINISHED:ABORTED'
    launch = locate(events,'RunnerStartServerApp',abort)
    running = locate(events,'RunnerSetRunning',launch)
    assert state(events,running)['status'] == 'RUNNING'
    return {'ack_abort_event':abort+1,'later_launch_event':launch+1,'running_event':running+1}


def f16(events, report):
    read = locate(events,'RunnerRefreshRead')
    abort = locate(events,'AdminAbortWrite',read)
    write = locate(events,'RunnerRefreshWrite',abort)
    assert state(events,abort)['status'] == 'FINISHED:ABORTED'
    assert state(events,write)['status'] == 'SUBMITTED'
    launch = locate(events,'RunnerStartServerApp',write)
    return {'refresh_read':read+1,'abort':abort+1,'refresh_write':write+1,'later_launch':launch+1}


def f3(events, report):
    insert = locate(events,'RunnerInsertRunning')
    publish = locate(events,'CmpPublish',insert)
    remove = locate(events,'CmpRemove',publish)
    running = locate(events,'RunnerSetRunning',remove)
    assert state(events,publish)['status'] == 'FINISHED:EXECUTION_EXCEPTION'
    assert state(events,running)['status'] == 'RUNNING'
    assert not events[running]['state']['running_jobs'] and not events[running]['state']['scheduled_jobs']
    return {'insert':insert+1,'terminal_publish':publish+1,'remove':remove+1,'late_running':running+1}


def f5(events, report):
    failure = locate(events,'SpProcessJobFailure',pred=lambda e:e['msg']['cl']=='c1' and e['msg']['code']==104)
    collect = locate(events,'RunnerStartCollect',failure)
    failed = locate(events,'RunnerExceptSetFailed',collect)
    assert not state(events,failure)['pending']['present']
    assert state(events,failed)['status'] == 'FINISHED:FAILED_TO_RUN'
    assert sum(e['name']=='CpStartLaunch' for e in events) == 2
    assert not any(e['name']=='CpStartLaunchFail' for e in events)
    return {'failure_report':failure+1,'collect_missing_pending':collect+1,'failed_write':failed+1,
            'cause':'Both CJ launches succeeded; report removed pending entry before START collection.'}


def f2(events, report):
    assert report['runner_exception'] and report['expected_runner_exception']
    assert report['final_status'] == {'j1':'DELETED','j2':'SUBMITTED'}
    assert not any(e['name']=='RunnerStartServerApp' for e in events)
    return 'Expected runner exception; deleted j1, later j2 still SUBMITTED and never launched in this finite scenario.'


def abort_control(events, report):
    assert set(report['final_status'].values()) == {'FINISHED:ABORTED'}
    assert not any(e['name']=='RunnerStartServerApp' for e in events)
    return 'Aborts before the status checks prevent both launches.'


def deadline(events, report):
    start = report['scenario'].startswith('start_')
    cutoff = locate(events,'RunnerStartTimeout' if start else 'RunnerCheckTimeout')
    late = locate(events,'CpStartAllocate' if start else 'CpCheckResource',cutoff,
                  lambda e:e['msg']['cl']=='c2')
    timeout = 20 if start else 15
    waits = [r for r in report['network_observation'] if r['operation']=='admin_wait'
             and r['requested_timeout_seconds']==timeout and r['elapsed_seconds']>=timeout-0.1
             and False in r['replies']]
    assert waits
    assert report['final_status']=={'j1':'FINISHED:COMPLETED'}
    return {'timeout_event':cutoff+1,'late_handler_event':late+1,'waits':waits}


record('normal_two_jobs',normal)
record('abort_before_checks',abort_control)
record('abort_during_deploy',f1)
record('refresh_rmw_revert',f16)
record('running_after_terminal',f3)
record('failrun_during_start',f5)
record('failrun_during_start_dup_abort',f5)
record('delete_held_job_kills_runner',f2)
record('delete_during_scan',f2)
record('check_deadline_backoff_expiry',deadline)
record('start_deadline_late_start',deadline)
result = {'checks_passed':all(r['passed'] for r in rows),'checks':rows,
          'scope':'Trace assertions only; named MC seed fidelity remains a validation obligation.'}
(out/'harness/evidence/continuation/phase3-C5-scenario-assertions.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
raise SystemExit(0 if result['checks_passed'] else 1)
