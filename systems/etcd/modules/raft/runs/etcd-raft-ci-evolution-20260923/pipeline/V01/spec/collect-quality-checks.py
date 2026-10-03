#!/usr/bin/env python3
"""Collect completed registered checks; never polls or starts TLC."""
import json,re,shutil,sys,hashlib
from pathlib import Path
p=Path(sys.argv[1]).resolve(); root=p.parent;jobs=json.loads(p.read_text())
for j in jobs:
    native=Path(j['result_path']).parent; result=json.loads((native/'result.json').read_text())
    assert result['exit_code'] is not None,j['task_id']
    dest=root/'tasks'/j['task_id'];dest.mkdir(parents=True,exist_ok=True)
    for name in ['request.json','result.json','worker.json','worker.log','launcher.log','tlc.log']:
        if (native/name).exists():shutil.copy2(native/name,dest/name)
    j.update(result);raw=(dest/'tlc.log').read_text();j['retained_evidence']=str(dest.relative_to(root));j['log_sha256']=hashlib.sha256(raw.encode()).hexdigest()
    j['input_hashes']={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in Path(j['work_dir']).iterdir() if x.suffix=='.tla' or x.name==j['config_file']}
    totals=re.findall(r'^([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.',raw,re.M)
    if totals:j['totals']=dict(zip(['generated','distinct','queued'],[int(x.replace(',','')) for x in totals[-1]]))
    init=re.findall(r'Finished computing initial states: ([\d,]+) distinct state',raw)
    if init:j['initial_states']=int(init[-1].replace(',',''))
    samples=re.findall(r"Progress\((\d+)\) at ([^:]+:\d+:\d+): ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue\.",raw)
    if samples:
        depth,at,generated,distinct,queued=samples[-1]
        j['last_periodic_sample']=dict(depth=int(depth),reported_at=at,generated=int(generated.replace(',','')),distinct=int(distinct.replace(',','')),queued=int(queued.replace(',','')))
    simulations=re.findall(r"Progress: (\d+) states checked, (\d+) traces generated ([^\n]+)",raw)
    if simulations:
        checked,traces,lengths=simulations[-1];j['last_periodic_sample']=dict(states_checked=int(checked),traces_generated=int(traces),length_statistics=lengths)
    j['exhaustive_completion_reported']='Model checking completed. No error has been found.' in raw
    j['budget_end_reported']=j['exit_code']==124 and 'Timed out' in (dest/'launcher.log').read_text()
    j['interpretation']='incomplete_exploration' if j['budget_end_reported'] else 'terminal_result'
    violations=re.findall(r'Invariant (\w+) is violated',raw)
    j['violated_invariants']=violations
    j['syntax_valid']='Semantic processing of module '+Path(j['spec_file']).stem in raw and 'Parsing or semantic analysis failed' not in raw
    if j['expected']=='pass':j['expected_result_observed']=j['exit_code']==0 and 'Model checking completed. No error has been found.' in raw and j.get('totals',{}).get('queued')==0
    elif j['expected']=='invariant_violation':j['expected_result_observed']=j['exit_code']==12 and len(violations)>0 and (not j.get('expected_invariant') or j['expected_invariant'] in violations)
    elif j['expected']=='bounded_exploration':j['expected_result_observed']=None if j['budget_end_reported'] and not violations else False
    else:j['expected_result_observed']=j['exit_code']==13 and 'Temporal properties were violated' in raw
    print(json.dumps({k:j[k] for k in ['label','exit_code','expected_result_observed','violated_invariants','totals','syntax_valid'] if k in j}))
p.with_name(p.stem.replace('-receipts','-results')+'.json').write_text(json.dumps(jobs,indent=2)+'\n')
sys.exit(0 if all(j['expected_result_observed'] for j in jobs) else 1)
