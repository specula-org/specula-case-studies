"""Collect execution receipts; classification remains a separate source review."""
import json
from pathlib import Path
import re
import shutil

SPEC = Path(__file__).resolve().parent.parent
rows = []
for request_file in sorted((SPEC.parent / '.tlc-tasks/jobs').glob('*/request.json')):
    task = request_file.parent
    request = json.loads(request_file.read_text())
    cfg = request['config_file']
    if cfg != 'MC.cfg' and not cfg.startswith('MC_hunt_'):
        continue
    options = request['options']
    label = Path(options[options.index('-j')+1]).stem if '-j' in options else task.name
    if cfg == 'MC.cfg':
        label = 'MC-r1'
    result_file = task / 'result.json'
    result = json.loads(result_file.read_text()) if result_file.exists() else None
    log = (task / 'tlc.log').read_text() if (task / 'tlc.log').exists() else ''
    row = dict(task_id=task.name, label=label, config=cfg,
               mode='simulation' if '-S' in options else 'BFS', created_at=request['created_at'],
               status='running' if result is None else 'unclassified',
               exit_code=result.get('exit_code') if result else None,
               elapsed_seconds=(result['finished_at']-request['created_at']) if result else None,
               output='spec/output/'+label+'.out', input_dir=request['work_dir'])
    violations = re.findall(r'Error: Invariant (\w+) is violated', log)
    row['violations'] = sorted(set(violations))
    row['temporal_violation'] = 'Temporal properties were violated' in log
    stats = re.findall(r'([\d,]+) states generated[^\n]*?([\d,]+) distinct states found[^\n]*?([\d,]+) states left on queue', log)
    if stats:
        row.update(zip(('generated','distinct','queued'), (int(v.replace(',','')) for v in stats[-1])))
    depths = re.findall(r'Progress\((\d+)\)', log) + re.findall(r'The depth of the complete state graph search is (\d+)', log)
    if depths:
        row['depth'] = max(map(int, depths))
    row['last_progress'] = next((line for line in reversed(log.splitlines()) if line.startswith('Progress')), None)
    samples = re.findall(r'Progress: ([\d,]+) states checked, ([\d,]+) traces generated \(trace length: mean=(\d+), var\(x\)=(\d+), sd=(\d+)\)', log)
    if samples:
        row.update(zip(('states_checked','traces_generated','trace_length_mean','trace_length_variance','trace_length_sd'), (int(v.replace(',','')) for v in samples[-1])))
    row['worker_exceptions'] = bool(re.search(r'Exception in thread|OutOfMemoryError', log))
    if result:
        if violations or row['temporal_violation']:
            row['status'] = 'violation'
        elif 'Model checking completed. No error has been found.' in log:
            row['status'] = 'completed_no_violation'
        elif (result['exit_code']==124 and row['elapsed_seconds']>=1790
              and row['last_progress'] and 'Error:' not in log
              and 'OutOfMemoryError' not in log and 'Exception in thread' not in log):
            row['status'] = 'budget_no_violation'
        else:
            row['status'] = 'execution_error_or_incomplete'
        for source_name, suffix in [('tlc.log','.out'),('launcher.log','.launcher.log'),('request.json','.request.json'),('result.json','.result.json')]:
            if (task/source_name).exists():
                shutil.copy2(task/source_name, SPEC/'output'/(label+suffix))
    rows.append(row)
rows.sort(key=lambda r:(r['config'],r['mode'],r['created_at']))
(SPEC/'output/run-coverage.json').write_text(json.dumps(rows,indent=2))
for r in rows:
    print(r['label'],r['status'],'depth='+str(r.get('depth')),'distinct='+str(r.get('distinct')),r['violations'])
