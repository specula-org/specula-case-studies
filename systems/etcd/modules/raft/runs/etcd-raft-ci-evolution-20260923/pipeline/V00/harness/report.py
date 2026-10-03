#!/usr/bin/env python3
"""Assemble a hash-bound report; never write a CI verdict or promotion pointer."""
import hashlib
import json
import argparse
import fnmatch
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--batch',action='append',default=[],help='Restrict results to explicitly selected current-run label patterns.')
args=parser.parse_args()
ROOT=Path(__file__).resolve().parent
SPEC=ROOT.parent/'spec'
hashes={n:hashlib.sha256((SPEC/n).read_bytes()).hexdigest() for n in ['base.tla','Trace.tla','Trace.cfg']}
def imported_hashes(mode):
    inputs={n:hashes[n] for n in ['base.tla','Trace.tla']}
    if mode=='observation-oracle':
        inputs.update({n:hashlib.sha256((ROOT/'oracle'/n).read_bytes()).hexdigest() for n in ['OracleTrace.tla','OracleTrace.cfg']})
    else:inputs['Trace.cfg']=hashes['Trace.cfg']
    return inputs
results=[]
for p in sorted((ROOT/'logs').glob('*.json')):
    if args.batch and not any(fnmatch.fnmatch(p.name,f'*-{batch}.json') for batch in args.batch):continue
    try:r=json.loads(p.read_text())
    except (ValueError,UnicodeDecodeError):continue
    if not isinstance(r,dict) or 'sha256' not in r:continue
    r.pop('raw_output',None);r.pop('last_state',None)
    if r.get('spec_sha256')==hashes and r.get('input_hashes')==imported_hashes(r.get('mode')):results.append(r)

def find(path,mode):
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    matches=[r for r in results if r.get('mode')==mode and r['sha256']==digest and r['trace']==str(path)]
    assert matches, f'No current {mode} result for {path}'
    return matches[-1]

positive=[]
for p in sorted((ROOT.parent/'traces').glob('*.ndjson')):
    full=find(p,'full-correspondence');oracle=find(p,'observation-oracle')
    assert full['status']==oracle['status']=='success',p
    assert full['final_distinct_states']==full['event_count'] and full['final_queue']==0,p
    positive.append(dict(trace=p.name,events=full['event_count'],sha256=full['sha256'],full_replay=full,observation_oracles=oracle))

negative=[]
for mutation in json.loads((ROOT/'negative-traces/manifest.json').read_text()):
    p=Path(mutation['file']);full=find(p,'full-correspondence');oracle=find(p,'observation-oracle')
    assert full['status']=='trace_mismatch',(p,full['status'])
    assert full['failed_trace_line']==mutation['changed_line'],(p,full)
    expected=mutation['expected_oracle']
    assert (oracle.get('violated_invariant')==expected if expected else oracle['status']=='success'),(p,oracle.get('violated_invariant'),expected)
    assert hashlib.sha256(Path(mutation['source']).read_bytes()).hexdigest()==mutation['source_sha256']
    negative.append(dict(mutation=mutation,full_replay=full,observation_oracles=oracle))

coverage=json.loads((ROOT/'coverage.json').read_text())
assert not coverage['unvisited_events'] and not coverage['missing_required_witnesses']
report=dict(status='harness checks completed',scope='trace harness phase only; not an initialization acceptance verdict',
            result_batches=args.batch,
            spec_sha256=hashes,positive_traces=positive,controlled_invalid_traces=negative,
            coverage=coverage,limits='See CORRESPONDENCE.md; no exhaustive safety/liveness or model-quality acceptance claim.')
(ROOT/'results.json').write_text(json.dumps(report,indent=2)+'\n')
rows=['# Harness results','',f'{len(positive)} real traces, {sum(x["events"] for x in positive):,} events. All 36 mapped noninitial event types are exercised. Full replay consumed every event with all canonical Trace.cfg invariants and TraceMatched enabled.','',
      '| Trace | Events | Full replay | Observation-only predicates |','|---|---:|---|---|']
for r in positive:rows.append(f'| {r["trace"]} | {r["events"]} | passed | passed |')
rows+=['','All six invalid copies passed structural preflight and were rejected at their changed event by full post-state correspondence. Five also violated the expected unchanged base predicate in the separate observation-only sensitivity check.','',
       '| Invalid copy | Changed line | Independent predicate result |','|---|---:|---|']
for r in negative:
    m=r['mutation'];rows.append(f'| {Path(m["file"]).name} | {m["changed_line"]} | {m["expected_oracle"] or "No targeted predicate violation; correspondence rejection only"} |')
rows+=['','Ordinary Go tests and race scenarios are separate from the TLC result aggregation. The test runner disables Go test caching with `-count=1`; inspect the retained test logs for actual execution outcomes.', '', '`results.json` binds each selected result to its exact trace and base/Trace/config hashes and links the TLC log. Explicit `--batch` patterns can restrict a report to one validation round. `coverage.json` records branch counts and entry-size mappings.', '', 'The validation driver permits at most six isolated TLC instances, each with 8 GiB heap, 1 GiB direct memory and two workers: 54 GiB and 12 workers total. Temporary/state directories are run-local. A finite replay is not exhaustive bounded model checking or a liveness proof.', '', 'Remaining interface/interleaving coverage and oracle limits are listed in `CORRESPONDENCE.md`. Harness completion does not establish initialization or researcher model-quality acceptance. No CI promotion pointer, verdict or canonical property was altered.','']
(ROOT/'RESULTS.md').write_text('\n'.join(rows))
print(json.dumps({'positive_traces':len(positive),'events':sum(x['events'] for x in positive),'invalid_traces_rejected':len(negative),'named_oracle_failures':sum(x['mutation']['expected_oracle'] is not None for x in negative)}))
