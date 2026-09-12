"""Seal an observed timed-out baseline; never substitute timeout for convergence."""
import datetime
import difflib
import hashlib
import json
import re
from pathlib import Path

spec = Path(__file__).resolve().parent.parent
out = spec / 'output'
run = out / 'round1-MC-attached'
receipt = json.loads((run / 'exit.json').read_text())
log = (run / 'MC.out').read_text()
assert receipt['exit_code'] in (124, 137, 143), receipt
assert 'No error has been found' not in log
assert not re.search(r'Error:|Invariant .*violated|OutOfMemoryError', log)
samples = re.findall(r'Progress\((\d+)\) at ([^:]+:\d+:\d+): ([\d,]+) states generated .*?, ([\d,]+) distinct states found .*?, ([\d,]+) states left on queue\.', log)
assert samples
depth, sampled_at, generated, distinct, queued = samples[-1]
generated, distinct, queued = [int(s.replace(',', '')) for s in (generated, distinct, queued)]
assert queued > 0
traces = json.loads((out / 'trace-validation-summary.json').read_text())
assert len(traces['traces']) == 32 and all(t['status'] == 'PASS' for t in traces['traces'])
assert len(traces['controls']) == 5
for name in ('base.tla', 'MC.tla', 'MC.cfg'):
    assert (run / name).read_bytes() == (spec / name).read_bytes()
manifest = json.loads((run / 'run.json').read_text())
manifest.update(status='INCOMPLETE', converged=False, exit_code=receipt['exit_code'],
                finished=receipt['finished'], last_logged_sample={'time_utc': sampled_at,
                'generated': generated, 'distinct': distinct, 'queued': queued, 'depth': int(depth)},
                counts_are_final=False, reason='1800-second outer timeout followed by 15-second kill grace, with a nonempty exploration queue; no violation observed.',
                kill_grace_seconds=15, oom_kill_observed=False)
(run / 'run.json').write_text(json.dumps(manifest, indent=2) + '\n')
status = {'schema_version': '1', 'system': 'temporal-matching', 'status': 'INCOMPLETE',
          'source_revision': '0c010ce5fe8c0180aa7573c72fe8fc87c6df7025', 'converged': False,
          'phase': 2, 'trace_validation': {'status': 'PASS', 'complete_traces': 32, 'scenarios': 16,
          'negative_controls_rejected': 5, 'action_types_observed': 78, 'action_types_total': 82},
          'baseline': manifest, 'hunting_status': 'NOT_RUN', 'liveness_status': 'NOT_RUN',
          'fairness_status': 'NOT_RUN', 'confirmed_implementation_bugs': 0}
(spec / 'validation-status.json').write_text(json.dumps(status, indent=2) + '\n')
table = ('| Configuration | Result | Generated | Distinct | Queued | Depth |\n'
         '|---|---|---:|---:|---:|---:|\n'
         f'| `MC.cfg` | INCOMPLETE, 1800-second timeout | {generated:,} | {distinct:,} | {queued:,} | {depth} |\n')
summary = f'''# temporal-matching Phase 3 validation status

**INCOMPLETE: Phase 1 passed; Phase 2 did not complete; not converged.**

Source `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Six source-backed trace/spec corrections were applied. All 16 original and 16 freshly collected complete Matching + file-backed SQLite traces passed the same canonical spec. Five corrupted implementation traces failed specifically at `TraceMatched`. There are 16 scenarios, 32 executions, 2,068 records including bootstrap/seal, and 78/82 observed action types; none of these is product or interleaving coverage.

{table}
Counters above are the last logged sample at **{sampled_at} UTC**, not final counters. No invariant violation was reported. The 1,800-second outer deadline and 15-second kill grace ended with exit {receipt['exit_code']} at {receipt['finished']}; cgroup oom/oom_kill/oom_group_kill remained zero. Resources: 32 workers, 16 GiB heap, 32 GiB off-heap; all supplied cfg files and bounds remained unchanged. A nonempty queue and timeout do not establish an exhaustive bounded pass. Generated scratch is cleaned after exit; no resumable checkpoint is claimed.

The six enabled names are `TypeOK`, `RecordIdentity`, `RangeConditionalWrite`, `MCTypeOK`, `ReaderAccounting`, and `CursorOrder`; `MCTypeOK` subsumes `TypeOK`. Scenario conservation/deletion/replacement properties belong to the hunting cfgs and were not checked by this baseline. Deadlock checking is disabled in the supplied cfg. No conditional-liveness verdict exists.

## Workflow handoff

The validation-workflow guide requires Phase 2 to complete and both phases to pass before convergence. Bug Hunting's explicit precondition is “Spec has converged (Phase 3 passed).” Therefore the four hunting configs, their simulation follow-ups, conditional liveness and fairness extension were **not run in Phase 3**. This is an incomplete validation handoff, not a zero-bug completed hunt. Historical Phase 2.5 smaller baselines and incomplete hunts retain their original scope and do not replace this run.

Resume at Phase 2 with `MC.cfg` and the archived model/config hashes. Do not shrink fault or state bounds to manufacture completion. If a counterexample appears, classify it against implementation source before changing the invariant/spec; a base change requires another complete trace round. Only after convergence run every hunt for 30 minutes BFS, followed by 30 minutes simulation when its BFS diameter is at most 25. Keep fairness and backend paging separate and retain their implementation-evidence gates.

## Evidence and limits

- [Changelog](changelog.md), [exact trace hashes/results](output/trace-validation-summary.json), [model/config/resources manifest](output/round1-MC-attached/run.json), [full TLC output](output/round1-MC-attached/MC.out), [process receipt](output/round1-MC-attached/exit.json).
- [Priority-question evidence and precise fidelity handoff](contract-evidence.md), [phase evidence inventory](output/README.md), [spec diff](output/phase3-spec.patch).
- History is a controlled interface fixture. Non-expiry root validation is parked. Physical process crash, transport teardown, actual History obsolescence, unresolved cross-process outcomes, alternative persistence backends and fairness remain unvalidated. Stable-owner/store/poller/eventual-processing assumptions are required for progress; no unconditional delivery claim follows.
- Initial background launch was interrupted without a verdict; its evidence is separately retained in `output/round1-MC/`. The attached run above consumed the full timeout. Existing source instrumentation and original traces were preserved.
'''
(spec / 'validation-status.md').write_text(summary)
hunts = sorted(spec.glob('MC_hunt_*.cfg'))
rows = '\n'.join(f'| `{p.name}` | — | Not run: baseline did not converge |' for p in hunts)
report = f'''# Bug Report — temporal-matching

## Summary

- **Validation INCOMPLETE; hunting NOT RUN.** This file records the required handoff and does not represent post-convergence bug hunting.
- Confirmed implementation bugs: 0. No MC counterexample was produced for Case A/B/C classification in this run.
- Hunting scenarios/configurations executed in Phase 3: 0.
- Complete implementation traces: 32/32 across 16 scenarios; negative controls rejected: 5/5.
- Phase 2 config run: unchanged `MC.cfg`, 30-minute cap, 32 workers, 16 GiB heap plus 32 GiB off-heap.

{table}
Last logged counts at {sampled_at} UTC, not final totals. Timeout exit {receipt['exit_code']}; no violation observed before termination. These six enabled invariant names include redundant TypeOK/MCTypeOK coverage and do not include the hunt-only work-conservation or replacement checks. Full limitations and workflow handoff: [validation-status.md](validation-status.md).

## Not Reproduced

| Configuration | States explored | Result |
|---|---|---|
{rows}
| `MC_live_S4.cfg` | — | Not run: no conditional-progress verdict |
| Fairness V2 / Cassandra paging | — | Separate unvalidated extensions; no enabled current-suite coverage |

All six fidelity corrections arose in trace validation and are recorded in [changelog.md](changelog.md). No invariant was weakened and no bounds were reduced. The initial interrupted background launch and prior Phase 2.5 searches are not completed Phase 3 evidence. No `## Bug N` finding is asserted.
'''
(spec / 'bug-report.md').write_text(report)
findings = {'schema_version': '2', 'system': 'temporal-matching', 'generated_by': 'validation-workflow',
            'validation_status': 'INCOMPLETE', 'converged': False, 'hunting_status': 'NOT_RUN', 'findings': []}
(spec / 'findings.json').write_text(json.dumps(findings, indent=2) + '\n')
with (spec / 'changelog.md').open('a') as stream:
    stream.write(f'- [result] MC.cfg reached its 1800-second cap, exit {receipt["exit_code"]}, with no observed violation and {queued:,} queued at the last sample. Last sample: {generated:,} generated / {distinct:,} distinct / depth {depth}. INCOMPLETE, not an exhaustive pass; no Case A/B/C counterexample found.\n\n## Result\nNot converged after Round 1. Trace validation: 32/32 complete traces and 5/5 negative controls. Phase 2 baseline INCOMPLETE. Bug hunting, conditional liveness and fairness NOT RUN because convergence is required. No implementation bug confirmed. See validation-status.md and output/round1-MC-attached/run.json.\n')
for name in ('brief-coverage.md', 'gated-extensions.md'):
    path = spec / name
    text = path.read_text().replace('baseline MC is running', 'baseline MC is INCOMPLETE').replace('is still running', 'ended INCOMPLETE').replace('Phase 3 baseline is still running', 'Phase 3 baseline ended INCOMPLETE')
    path.write_text(text)
patch = ''
for initial in sorted((out / 'initial-inputs').iterdir()):
    current = spec / initial.name
    if current.exists() and current.read_bytes() != initial.read_bytes():
        patch += ''.join(difflib.unified_diff(initial.read_text().splitlines(True), current.read_text().splitlines(True), fromfile='initial/' + initial.name, tofile='spec/' + initial.name))
(out / 'phase3-spec.patch').write_text(patch)
print(json.dumps({'status': 'INCOMPLETE', 'last_sample': manifest['last_logged_sample'], 'report': str(spec / 'validation-status.md')}, indent=2))
