"""Preserve completed TLC task evidence and invoke installed counterexample tools."""
import asyncio
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

OUT = Path(__file__).resolve().parents[2]
ROOT = next(p for p in OUT.parents if (p / 'src/specula/tlc_tasks.py').exists())
sys.path.insert(0, str(ROOT / 'tools/inv_checking_tool'))
from src.mcp.handlers.summary import SummaryHandler
from src.mcp.handlers.state import StateHandler
from src.mcp.handlers.compare import CompareHandler

async def main():
    task_id, label = sys.argv[1:3]
    task = OUT / '.tlc-tasks/jobs' / task_id
    result = json.loads((task / 'result.json').read_text())
    request = json.loads((task / 'request.json').read_text())
    assert result['status'] not in {'starting','running'}
    dest = OUT / 'spec/output' / (label + '.out')
    shutil.copy2(task / 'tlc.log', dest)
    for name in ['request.json','result.json','launcher.log','worker.log']:
        if (task / name).exists():
            shutil.copy2(task / name, OUT / 'spec/output' / (label + '_' + name))
    log = dest.read_text()
    violations = re.findall(r'Invariant (\w+) is violated', log)
    progress = re.findall(r'Progress\((\d+)\).*?: ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue', log)
    final_counts = re.findall(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', log)
    counts = [int(x.replace(',','')) for x in final_counts[-1]] if final_counts else ([int(x.replace(',','')) for x in progress[-1][1:]] if progress else None)
    depths = re.findall(r'The depth of the complete state graph search is (\d+)', log)
    depth = int(depths[-1]) if depths else (int(progress[-1][0]) if progress else None)
    errors = [line for line in log.splitlines() if line.startswith('Error:')]
    row = dict(task_id=task_id, label=label, request=request, result=result,
               violations=violations, errors=errors, depth=depth, counts=counts,
               exhausted='Model checking completed. No error has been found.' in log,
               timed_out=result['exit_code']==124,
               log_sha256=hashlib.sha256(dest.read_bytes()).hexdigest(),
               model_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in
                              [OUT/'spec/base.tla',OUT/'spec/MC.tla',Path(request['work_dir'])/request['config_file']]})
    row['counts_source'] = 'terminal statistics' if final_counts else 'last reported progress'
    simulation = re.findall(r'Progress: ([\d,]+) states checked, ([\d,]+) traces generated([^\n]*)', log)
    if simulation:
        checked, traces, moments = simulation[-1]
        row['simulation'] = dict(states_checked=int(checked.replace(',','')),
                                 traces_generated=int(traces.replace(',','')),
                                 reported_trace_statistics=moments.strip(),
                                 counts_source='last reported progress')
    if violations or 'Error: Temporal properties were violated.' in log:
        args = {'file_path':str(dest)}
        row['summary'] = await SummaryHandler().execute(args)
        (dest.parent / (label+'_last-state.json')).write_text(json.dumps(await StateHandler().execute(dict(args,index=-1)),indent=2,default=str)+'\n')
        (dest.parent / (label+'_last-diff.json')).write_text(json.dumps(await CompareHandler().execute(dict(args,index1=-2,index2=-1)),indent=2,default=str)+'\n')
        (dest.parent / (label+'_states.json')).write_text(json.dumps(await StateHandler().execute(dict(args,indices='1:')),indent=2,default=str)+'\n')
    (dest.parent / (label+'_summary.json')).write_text(json.dumps(row,indent=2,default=str)+'\n')
    print(json.dumps({k:v for k,v in row.items() if k not in {'request','result','model_sha256','summary'}},indent=2))
    if 'summary' in row:
        print(json.dumps(row['summary'],indent=2,default=str))

if __name__=='__main__':
    asyncio.run(main())
