#!/usr/bin/env python3
"""Schema/L2, action coverage and reproducibility receipts (no model execution)."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

H=Path(__file__).resolve().parent.parent
S=H.parent/'spec'
schema=json.loads((H/'src/event-schema.json').read_text())
trace_spec=(S/'Trace.tla').read_text()
assert 'ValidatePostState(e) ==\n /\\ DOMAIN e.post' in trace_spec
assert 'PROPERTIES TraceMatched' in (S/'Trace.cfg').read_text()
assert 'THEN e.tag="trace"' in trace_spec
assert 'OTHER -> FALSE' in trace_spec
all_counts=Counter()
raw_counts=Counter()
results={}
ok=True
for receipt in sorted((H/'logs').glob('*.receipt.json')):
    r=json.loads(receipt.read_text());name=r['scenario']
    rows=[json.loads(x) for x in (H.parent/'traces'/f'{name}.ndjson').read_text().splitlines()]
    assert rows[0]['tag']=='config'
    raw=[json.loads(x) for x in Path(r['raw']).read_text().splitlines()]
    raw_counts.update(x['event'] for x in raw)
    counts=Counter()
    for event in rows[1:]:
        assert event['tag']=='trace'
        assert isinstance(event['ts'],int) and event['ts']>1_000_000_000
        name_schema=schema[event['event']]
        assert set(event['post'])==set(name_schema['fields'])
        assert set(event['args'])==set(name_schema['args'])
        counts[event['event']]+=1
    all_counts.update(counts)
    p=json.loads((H.parent/'traces'/f'{name}.provenance.json').read_text())
    assert p['receipt']['raw']==r['raw'], 'stale normalized trace selected'
    validation=json.loads((H/'logs'/f'{name}.validation.json').read_text())
    testlog=(H/'logs'/f'{name}.pytest.log').read_text()
    probe_errors=Path(r['raw']+'.errors').exists()
    item=dict(semantic_events=sum(counts.values()),raw_hooks=len(raw),event_types=len(counts),
              validation=validation['status'],first_unmatched_event=validation.get('failed_trace_line'),
              projection_errors=p['projection_errors'],probe_errors=probe_errors,
              pytest_passed='1 passed' in testlog, job_status={j:m['status'] for j,m in r['status'].items()},
              events=dict(counts))
    index=validation.get('failed_trace_line')
    if index:
        item['first_unmatched_event_name']=rows[index]['event']
        original=p['hooks'][index-1]['raw_line']
        item['first_unmatched_source']=raw[original-1]['source'][0]
    results[name]=item
    ok &= item['pytest_passed'] and not probe_errors and not item['projection_errors'] and validation['status']=='success'

coverage=[]
normalizer=(H/'src/normalize.py').read_text()
patcher=(H/'src/apply_instrumentation.py').read_text()
for name in schema:
    if all_counts[name]:
        boundary='Observed in production POC execution; see per-scenario count and replay verdict.'
    elif name in ('DefaultJobSchedulerExhausted','DefaultJobSchedulerPersistBlocked'):
        boundary='Not exercised: ten default retries require exponential backoff beyond the per-test budget; no clock acceleration.'
    elif name in ('JobRunnerOutcomeGraceExpired','JobRunnerArchiveGraceExpired','JobRunnerRetryArchive','JobRunnerArchiveException','JobRunnerTerminalStoreException'):
        boundary='Not exercised: no archival/store outage or 900-second unresolved-outcome wait in the selected four workloads.'
    elif name in ('ClientEngineStartAppReturnedError','JobRunnerMissingPendingOutcomes'):
        boundary='Deferred by input contract: supported fresh-allocation trigger / competing-deletion extension must be established in Phase 3.'
    elif 'Heartbeat' in name:
        boundary='Not exercised: connected cooperative parents retained the ordinary job/outcome protection; no orphan-heartbeat workload.'
    elif name.startswith('Admin'):
        boundary='Not exercised: selected faults delay START and cancellation replies; other deadline paths need separate transport tests.'
    else:
        boundary='Not exercised in these four workloads; needs a dedicated source-path/fault scenario. This is a coverage gap, not evidence of correctness.'
    coverage.append(dict(event=name,count=all_counts[name],referenced_in_harness=name in normalizer or name in patcher,
                         boundary=boundary))
report=dict(source_revision=subprocess.check_output(['git','-C','/home/ubuntu/nvflare-job-lifecycle-20260914/source','rev-parse','HEAD'],text=True).strip(),
            scenarios=results,covered_event_types=len(all_counts),spec_event_types=len(schema),coverage=coverage,
            raw_hook_counts=dict(raw_counts),handoff='Phase 3: replay/refinement required; not ready for correctness claims',
            all_traces_conform=ok)
(H/'coverage.json').write_text(json.dumps(report,indent=2)+'\n')
summary=['# Harness result', '', f'Source: `{report["source_revision"]}`.', '',
         '| Scenario | Pytest | Events | Trace replay | First unmatched event |',
         '|---|---|---:|---|---|']
for name,r in results.items():
    summary.append(f'| {name} | {"PASS" if r["pytest_passed"] else "FAIL"} | {r["semantic_events"]} | {r["validation"]} | {r.get("first_unmatched_event_name", "—")} |')
summary += ['',f'Observed {len(all_counts)}/{len(schema)} spec event types. See [coverage.json](coverage.json) for every untested action.',
            '', 'Pytest checks actual saved statuses, returned capacity, empty executor maps and one free per allocation. '
            'Historical replay failures are preserved with their model/capture repairs in spec/changelog.md; current replay status is shown above. Passing replay is finite conformance, not exhaustive correctness. '
            'See [INSTRUMENTATION.md](INSTRUMENTATION.md) for the precise source/model boundaries and rerun instructions.',
            '', 'Run: `cd .specula-output && bash harness/run.sh`. A nonzero result preserves unresolved replay failures.']
(H/'RESULTS.md').write_text('\n'.join(summary)+'\n')
files=list((H/'src').glob('*'))+[H/'apply.sh',H/'run.sh',H/'patches/instrumentation.patch',S/'Trace.tla',S/'Trace.cfg',S/'base.tla']
files+=list((H.parent/'traces').glob('*'))
hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
(H/'artifact-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
print(f'{len(all_counts)}/{len(schema)} event types covered; all traces conform: {ok}')
for name,r in results.items():
    print(f'{name}: pytest={r["pytest_passed"]}, events={r["semantic_events"]}, replay={r["validation"]}, projection_errors={len(r["projection_errors"])}')
sys.exit(0 if ok else 1)
