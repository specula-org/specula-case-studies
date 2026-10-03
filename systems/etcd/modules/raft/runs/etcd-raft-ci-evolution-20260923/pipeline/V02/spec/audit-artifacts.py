"""Mandatory brief/config wiring audit; this does not establish reachability."""
from pathlib import Path
import json
import re
p=Path(__file__).resolve().parent
expected=['base.tla','base.cfg','MC.tla','MC.cfg','Trace.tla','Trace.cfg','brief-coverage.md','instrumentation-spec.md']
for name in expected:
    assert (p/name).is_file() and (p/name).stat().st_size, name
brief=(p.parent/'modeling-brief.md').read_text()
safety=[]
for line in brief.splitlines():
    if '| Safety |' in line:
        safety.extend(x.strip() for x in line.split('|')[1].strip().split('/'))
def enabled(f):
    result=[];mode=False
    for line in f.read_text().splitlines():
        s=line.strip()
        if not s or s.startswith('\\*'):continue
        if s in {'INVARIANT','INVARIANTS'}:mode=True;continue
        if re.match(r'^(CONSTRAINT|SYMMETRY|CHECK_DEADLOCK|CONSTANTS|SPECIFICATION|PROPERT)',s):mode=False
        if mode:result.append(s)
    return result
hunts={f.name:enabled(f) for f in sorted(p.glob('MC_hunt_*.cfg'))}
defs=set(re.findall(r'^(\w+)\s*==',(p/'base.tla').read_text(),re.M))
mapping={name:[cfg for cfg,props in hunts.items() if name in props] for name in safety}
assert all(name in defs for name in safety),'Missing safety definition'
assert all(mapping.values()),'Safety property not enabled in a hunt cfg'
assert all(any(f.startswith(f'MC_hunt_{i}_') for f in hunts) for i in range(1,7)), 'Missing scenario hunt'
assert all(not {'MCTypeOK','TypeOK','LogStructure'} & set(props) for props in hunts.values()),'Structural checks leaked into targeted hunts'
trace=(p/'Trace.tla').read_text();cfg=(p/'Trace.cfg').read_text()
assert re.search(r'^PROPERTIES TraceMatched$',cfg,re.M)
assert 'ValidatePostState(e) == Observed\'=Decode(e.post)' in trace
assert 'ValidatePostState(logline)' in trace
assert 'ELSE "../traces/trace.ndjson"' in trace
wrappers=set(re.findall(r'^Trace(\w+)\(p\) ==',trace,re.M))
events=set(re.findall(r'e\.event="(\w+)" -> Trace',trace))
assert wrappers==events,('wrapper/dispatch mismatch',wrappers^events)
doc=(p/'instrumentation-spec.md').read_text()
missing=[x for x in wrappers if f'| {x} |' not in doc]
assert not missing,('missing action mapping',missing)
report={'status':'definition-and-wiring checks passed','expected_artifacts':expected,
        'scenario_hunts':hunts,'brief_safety_properties':mapping,
        'trace_action_count':len(wrappers),'reachability':'not established by this static audit'}
(p/'output/artifact-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(f'{len(expected)} required artifacts; {len(hunts)} hunt cfgs; {len(safety)} brief safety properties enabled; {len(wrappers)} trace actions mapped.')
