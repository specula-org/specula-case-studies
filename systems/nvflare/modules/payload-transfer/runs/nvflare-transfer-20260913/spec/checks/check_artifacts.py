"""Reproducible generation-artifact checks, not model convergence or runtime evidence."""
from pathlib import Path
import copy
import hashlib
import json
import os
import re
import subprocess

P = Path(__file__).resolve().parents[1]
CP = '/home/ubuntu/nvflare-runs-20260913/specula/lib/tla2tools.jar:/home/ubuntu/nvflare-runs-20260913/specula/lib/CommunityModules-deps.jar'
results = []
def run(label, args, env=None):
    result = subprocess.run(args, cwd=P, env=env, capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    (P/'checks'/f'{label}.log').write_text(output)
    if result.returncode or any(t in output for t in ['*** Errors', 'Fatal errors', 'Semantic errors', 'Parse Error']):
        raise RuntimeError(f'{label}: inspect checks/{label}.log')
    return output

for mod in ['base', 'MC', 'Trace']:
    run(mod+'-sany', ['java','-Xmx1G','-cp',CP,'tla2sany.SANY',mod+'.tla'])
    results.append({'check':'SANY','module':mod,'result':'pass'})
    print(mod, 'SANY_OK')
for cfg in [P/'base.cfg',P/'MC.cfg',*sorted(P.glob('MC_hunt_*.cfg')),P/'Trace.cfg']:
    mod = 'Trace' if cfg.name=='Trace.cfg' else 'base' if cfg.name=='base.cfg' else 'MC'
    output=run(cfg.stem+'-init',['java','-Xmx1G','-cp',CP,'checks/ConfigInitCheck.java',mod,cfg.name])
    receipt=next(x for x in output.splitlines() if x.startswith('CONFIG_'))
    results.append({'check':'config_init','config':cfg.name,'result':receipt});print(receipt)

run('schema-encode',['java','-Xmx1G','-cp',CP,'checks/TraceSchemaCheck.java','encode-init'])
initial=json.loads((P/'checks/initial-state.json').read_text())
header=dict(tag='nvflare-transfer',event='init',schema=1,source_sha='53ba7ee567468ea7971dad4faccef13c6cb35dc2',tx='schema-only',config=dict(refs=['ref1','ref2'],receivers=['receiver1','receiver2'],chunk_count=1,acquire_timeout=3,idle_timeout=3,tx_timeout=5,drain_timeout=2,receipt_ttl=4,finished_refs_ttl=9,min_receivers=1,receiver_mode='explicit',producer_confirm=True,consumer_confirm=True,progress_interval=0,progress_enabled=True,pipeline_enabled=True,source_profile='owned_release',registration_frozen=True),post=initial)
post=copy.deepcopy({f:initial[f] for f in ['consumer','futureStarted','pullPC']})
for f,v in [('consumer','waiting'),('futureStarted',True),('pullPC','sent')]:
    next(e for e in post[f]['entries'] if e['key']==['ref1','receiver1'])['value']=v
ok=dict(tag='nvflare-transfer',tx='schema-only',n=1,event='DownloadObjectStart',args=dict(p=['ref1','receiver1']),post=post)
wrong=copy.deepcopy(ok)
next(e for e in wrong['post']['consumer']['entries'] if e['key']==['ref1','receiver1'])['value']='failed'
missing=copy.deepcopy(ok);del missing['post']['pullPC']
for label,event,expected in [('valid',ok,1),('wrong-post',wrong,0),('missing-post',missing,0)]:
    path=P/'checks'/f'schema-{label}.ndjson'
    path.write_text(json.dumps(header)+'\n'+json.dumps(event)+'\n')
    output=run('schema-'+label,['java','-Xmx1G','-cp',CP,'checks/TraceSchemaCheck.java',str(expected)],dict(os.environ,JSON=str(path)))
    receipt=next(x for x in output.splitlines() if x.startswith('SCHEMA_CHECK_OK'))
    results.append({'check':'synthetic_schema','case':label,'result':receipt});print(receipt,label)

acts=json.loads((P/'action-map.json').read_text())
trace=(P/'Trace.tla').read_text();base=(P/'base.tla').read_text();doc=(P/'instrumentation-spec.md').read_text()
assert len({a['name'] for a in acts})==len(acts)
for a in acts:
    assert a['fields']
    assert 'Trace'+a['name']+' ==' in trace
    assert '| `'+a['name']+'` |' in doc
    assert a['source'] in base
    assert re.search(r'ValidatePostState\("'+a['name']+r'"\)',trace)
assert 'ValidatePostState == TRUE' not in trace
assert re.search(r'PROPERTIES\s+TraceMatched',(P/'Trace.cfg').read_text())
requirements={'TypeOK':[],'SingleSettlementEffects':[],'NoSettlementEffectsAfterReceipt':[],'CompletedProgressHasReceiverSuccess':[]}
keywords={'SPECIFICATION','CONSTANTS','INVARIANTS','INVARIANT','PROPERTIES','PROPERTY','CHECK_DEADLOCK','SYMMETRY','CONSTRAINT','CONSTRAINTS','VIEW'}
for cfg in sorted(P.glob('MC_hunt_*.cfg')):
    mode=None
    for line in cfg.read_text().splitlines():
        line=line.split('\\*',1)[0].strip()
        if not line:continue
        words=line.split()
        if words[0] in keywords:mode=words[0];words=words[1:]
        if mode in {'INVARIANTS','INVARIANT'}:
            for word in words:
                if word in requirements:requirements[word].append(cfg.name)
assert all(requirements.values()), requirements
results.append({'check':'coverage_wiring','actions':len(acts),'wrappers':len(acts),'enabled_safety_invariants':requirements,'result':'pass'})
print('COVERAGE_WIRING_OK',len(acts),'actions/wrappers')
artifacts=[*P.glob('*.tla'),*P.glob('*.cfg'),P/'brief-coverage.md',P/'instrumentation-spec.md',P/'action-map.json',P/'generate.py']
report={'source_sha':header['source_sha'],'scope':'Generation artifact checks only. One initial layer and a synthetic single-event schema test; no exhaustive/budgeted TLC search, implementation trace conformance or runtime regression.', 'checks':results,'sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(artifacts)}}
(P/'checks/artifact-checks.json').write_text(json.dumps(report,indent=2)+'\n')
