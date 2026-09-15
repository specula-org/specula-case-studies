"""Write final workflow artifacts after all started searches have been observed."""
import datetime
import json
from pathlib import Path
import re

SPEC=Path(__file__).resolve().parent.parent
OUT=SPEC.parent
runs=json.loads((SPEC/'output/run-coverage.json').read_text())
candidates=json.loads((SPEC/'validation/candidates.json').read_text())
assert not any(r['status']=='running' for r in runs), 'A started search is still running'
cfgs={p.name for p in SPEC.glob('MC_hunt_*.cfg')}
assert len(cfgs)==8
assert cfgs=={r['config'] for r in runs if r['mode']=='BFS' and r['config'].startswith('MC_hunt_')}
for r in runs:
    if r['status']=='execution_error_or_incomplete':
        assert any(q['config']==r['config'] and q['mode']==r['mode'] and q['status'] in {'budget_no_violation','completed_no_violation','violation'} for q in runs), 'Unresolved execution error'
    if r['mode']=='BFS' and r['status'] in {'budget_no_violation','completed_no_violation'} and r.get('depth',0)<=25:
        assert any(q['config']==r['config'] and q['mode']=='simulation' and q['status'] in {'budget_no_violation','completed_no_violation','violation'} for q in runs), 'Missing required simulation'
root_causes={
'MC-2':'JobExecutor attaches a spawned process handle before creating and starting the sole child-exit waiter. A waiter-installation exception propagates to StartJobProcessor, whose catch frees the retained allocation without checking whether a child already owns it. The resource manager immediately returns the unit to its free deque. This exposes available capacity while the child may still use its launch binding, without an installed waiter owning normal cleanup.',
'MC-3':'JobRunner checks SUBMITTED before deployment, then writes DISPATCHED unconditionally. The concurrent pre-run abort handler reads status once, stores ABORTED, and constructs a success response from its saved branch. Deployment can overwrite that terminal value before the response is constructed. The built-in job manager performs a plain metadata update without an expected-state condition.',
'MC-4':'JobRunner publishes running_jobs membership under its lock, then stores RUNNING after releasing that lock. The completion thread can observe the entry after server exit and outcome resolution and publish a terminal status first. The delayed startup write then restores RUNNING. Completion can subsequently delete its bookkeeping without another status publication.',
}
scenarios={'MC-1':'1 - allocation and shared launch environment','MC-2':'2 - startup cleanup ownership','MC-3':'3 - pre-run abort status','MC-4':'3 - terminal status publication'}
for c in candidates:
    assert c['classification']=='C'
    assert (OUT/c['counterexample']).is_file()
    assert c['id'] in root_causes or 'root_cause' in c
for r in runs:
    if r['status']=='violation':
        assert any(r['output']==c['counterexample'] or r['output'] in c.get('additional_counterexamples',[]) for c in candidates), 'Unclassified counterexample: '+r['output']
candidates.sort(key=lambda c:int(c['id'].split('-')[1]))
summary=f'''# Bug Report — nvflare-job-lifecycle

## Summary

- Source: NVIDIA/NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; source references below use original pinned lines, retained under `validation/source/`.
- Scenarios addressed: all 5 priority areas; all 8 original hunting configurations ran. Complete per-run evidence is in [run-coverage.json](output/run-coverage.json).
- Findings: **{len(candidates)} source-supported Case C model findings**. The violating interleavings were not reproduced end to end in the implementation during this validation phase. Passing controlled-fault harness scenarios are separate evidence.
- Trace conformance: **4/4 traces, 1,353 semantic events, 94/125 action types**; zero projection errors. See [replay receipts](output/traces-r5/summary.json) and [harness results](../harness/RESULTS.md).
- Standard convergence: one 30-minute `MC.cfg` BFS budget without invariant errors on the same model. Last report: depth 28, 85,219,049 generated, 16,008,119 distinct, 6,158,119 queued states. This was **bounded coverage, not exhaustive completion**. See [standard output](output/MC-r1.out).
- Selected production chain: DefaultJobScheduler, JobRunner, real Cell transport, ListResourceManager/ListResourceConsumer, and the default local process-launch path. Traces use one unit/site, max_jobs=2, required site-1, default non-strict startup and min_sites=1 (delayed-start: 2). Hunts also use two units, strict/min_sites=2, max_jobs=1 and a third optional site. Reservation TTL remains 30 real scan ticks; retry defaults remain 10 attempts and 10–600 seconds. The token universe is explicitly finite (11 attempts/job).

[PR #5191](https://github.com/NVIDIA/NVFlare/pull/5191) was refreshed on 2026-09-14: **open, unmerged**, head `27ecde2ab85b38734072b90128dc5dc2e8390882`; full discussion is saved in `validation/pr5191-*.json`. Its admission-exception bookkeeping/cancellation scope is known context, not a new finding here. The [expiry discussion](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101) concerns reservations: missing cancellation acknowledgement alone does not establish a permanent leak, and expiry does not reclaim an allocation transferred to a job. Proposed PR changes were not applied to the pinned implementation.

'''
entries=[]
for number,c in enumerate(candidates,1):
    cause=c.get('root_cause',root_causes.get(c['id']))
    summary+=f'''## Bug {number}: {c['title']}

- **ID / classification:** {c['id']} / Case C, pinned-source supported
- **Scenario:** {scenarios.get(c['id'],c.get('scenario',''))}
- **Severity:** {c['severity']}
- **Invariant violated:** `{c['invariant']}`
- **Config:** `{c['config']}`
- **Counterexample:** {c['states']} states; [{Path(c['counterexample']).name}]({c['counterexample'].removeprefix('spec/')})

### Trace Summary

{c['trace_summary']}

### Root Cause

{cause}

### Affected Code

'''
    summary+=''.join(f'- `{ref}`\n' for ref in c['source_references'])
    summary+=f'''\n### Evidence Boundary

{c['evidence_boundary']}

### Recommendation

{c['recommendation']}

---

'''
    entries.append(dict(id=c['id'],title=c['title'],source='model-checking',scenario=scenarios.get(c['id'],c.get('scenario','')),severity=c['severity'],invariant=c['invariant'],config=c['config'],counterexample=c['counterexample'],affected_code=c['source_references'],summary=cause))
summary+='''## Search Coverage

Every successful budget run used 30 minutes. Simulation used a depth limit of 100 and a requested trace count of 999999999, allowing the timer to terminate exploration. No configuration bound was shrunk. BFS depths are achieved search depths; simulation 100 is a configured limit, not an exhaustive diameter. Counts below are the final available TLC statistics, so budgeted counts can precede termination by a progress interval.

| Config | Mode | BFS depth / simulation limit | State coverage | Result | Output |
|---|---|---:|---|---|---|
'''
for r in runs:
    if r['config']=='MC.cfg':continue
    depth=str(r.get('depth','—')) if r['mode']=='BFS' else '100 (limit)'
    count=f"{r.get('distinct',0):,} distinct / {r.get('generated',0):,} generated" if r['mode']=='BFS' else f"{r.get('states_checked',0):,} checked / {r.get('traces_generated',0):,} traces generated"
    result={'budget_no_violation':'Budget ended; no violation reported','completed_no_violation':'Finite search completed; no violation','violation':'Violation: '+', '.join(r['violations']),'execution_error_or_incomplete':'TLC worker crash; excluded from successful coverage'}[r['status']]
    summary+=f"| `{r['config']}` | {r['mode']} | {depth} | {count} | {result} | [{r['label']}]({r['output'].removeprefix('spec/')}) |\n"
summary+='''
The first progress simulation crashed in TLC's lazy-function equality while constructing liveness traces. It was stopped, retained as failed execution, and retried with `TLCEval` around explicit function constructors in isolated execution copies. `TLCEval(v)==v`; all guards, properties, fairness and bounds retain identical mathematical meaning. Four real traces also pass on that eager copy. The canonical model is unchanged. See [execution workaround](validation/eager-execution.md), [control replay](output/traces-eager-control/summary.json), and the retry's input/hash receipt. The exit-cleanup simulation uses the same workaround. Generated-trace counts do not imply exhaustive liveness verification.

## Not Reproduced

'''
found_configs={c['config'] for c in candidates}
summary+='| Scenario / boundary | Result |\n|---|---|\n'
for cfg in sorted(cfgs-found_configs):
    related=[r for r in runs if r['config']==cfg and r['status']!='execution_error_or_incomplete']
    if not any(r['status']=='violation' for r in related):
        summary+=f'| `{cfg}` | No violation in the recorded bounded BFS/simulation coverage; this does not establish implementation correctness. |\n'
summary+='''| Two-unit process-binding implementation trace | Not executed; the four passing traces use one unit/site. Any shared-environment source hypothesis not backed by a model counterexample remains outside findings.json. |
| Post-spawn waiter-install failure in real NVFlare | Not injected in the passing implementation traces; MC-2 remains source-supported model evidence pending local functional confirmation. |
| TV-2 / TV-3 service-death paths | Not modeled/tested here; progress assumes live scheduling/completion services. |
| CR-2 surviving server process after termination request | No permanent surviving-process consequence was established; no ineffective-SIGKILL fault was invented. |
| CR-1 returned startup error, CR-3 invalid custom resource counts, CR-4 full notification retry loop, CR-5 header-only error producer, CR-6 disconnected fallback | Retained as brief/code-review boundaries, not promoted into model-checking findings. |
| Zero-grace server command exception and accepted ABORTED outcome receiver path | Source-modeled but lack dedicated passing implementation traces. |
| Delayed heartbeat snapshots | Current trace projection covers the observed missing-outcome branch; delayed snapshot interleavings remain outside that projection. |

All five priority questions, including physical ownership versus logical stop, exact reply/job identity, participant policy and conditional progress, are mapped in [priority-coverage.md](validation/priority-coverage.md). No progress guarantee is claimed under permanent site/resource/store failure. No GPU computation, HA recovery, external trainer, alternative launcher or workspace-content correctness was tested.

## Specification and Capture Repairs

The initial replay mismatches were model/capture issues: stop-send versus blocking return, pre-wait abort ownership capture, exceptional participant-list preservation, heartbeat-origin outcome resolution, ignored late reports, server cleanup grace branches, and repeated termination/pop. The pending-client acceptance guard, ABORTED classification and unbounded normal heartbeat behavior were preserved/refined from source. Every hunt now checks MCTypeOK. No safety predicate was weakened to suppress a counterexample. See [changelog.md](changelog.md) and [source-fidelity notes](validation/review-resolution.md).
'''
(SPEC/'bug-report.md').write_text(summary)
(SPEC/'findings.json').write_text(json.dumps({'schema_version':'2','system':'nvflare-job-lifecycle','generated_by':'validation-workflow','findings':entries},indent=2)+'\n')
headings=re.findall(r'^## Bug \d+: (.+)$',summary,re.M)
assert headings==[e['title'] for e in entries]
assert len({e['id'] for e in entries})==len(entries)
print('wrote bug-report.md and findings.json:',len(entries),'findings;',len(runs),'recorded executions')
