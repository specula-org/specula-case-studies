#!/usr/bin/env python3
"""Render terminal, classified Scenario results without changing CI state.

This report path is deliberately separate from pipeline verdict/current logic.
It refuses unfinished jobs and unexplained failures. Native receipts and earlier
reports remain in the campaign archive.
"""
import datetime
import hashlib
import json
from pathlib import Path

SPEC = Path(__file__).resolve().parent
CAMPAIGN = SPEC / 'output/scenario-campaign-20260913-043418'
REL = str(CAMPAIGN.relative_to(SPEC))
manifest = json.loads((CAMPAIGN / 'campaign.json').read_text())
jobs = manifest['jobs']
assert all(j['status'] in ('exited', 'interrupted') for j in jobs), 'Observe all jobs before reporting'
configs = sorted(k for k in manifest['inputs'] if k.startswith('MC_hunt_'))
latest = lambda cfg, mode: max((j for j in jobs if j['config'] == cfg and j['mode'] == mode), key=lambda j: j['attempt'])
scenarios = []
for cfg in configs:
    bfs, sim = latest(cfg, 'bfs'), latest(cfg, 'simulation')
    assert bfs['budget_end_reported'] and not bfs['errors'] and not bfs['runtime_errors']
    assert sim['budget_end_reported'] and not sim['errors'] and not sim['runtime_errors']
    scenarios.append({'config': cfg, 'bfs': bfs, 'simulation': sim})
regression = latest('MC.cfg', 'bfs')
assert regression['budget_end_reported'] and not regression['errors'] and not regression['runtime_errors']
traces = json.loads((CAMPAIGN / manifest['trace_regression']).read_text())
assert all(j['expected_result_observed'] for j in traces)
base_hash = hashlib.sha256((SPEC / 'base.tla').read_bytes()).hexdigest()
assert all(j['base_sha256'] == base_hash for j in traces)
assert all(s['simulation']['base_sha256'] == base_hash for s in scenarios)
assert regression['base_sha256'] == base_hash
classified = {r['task_id'] for r in manifest.get('repairs', [])}
assert all(not j.get('errors') or j['task_id'] in classified for j in jobs), 'Classify every counterexample'

rows = []
for s in scenarios:
    b, q = s['bfs']['coverage'], s['simulation']['coverage']
    rows.append(f"| {s['config']} | {b['depth']} | {b['distinct']:,} | {q['states_checked']:,} | {q['traces_generated']:,} |")
table = '\n'.join(['| Configuration | BFS depth | BFS distinct | Simulation states checked | Simulation traces generated |', '|---|---:|---:|---:|---:|', *rows])
repair = manifest['repairs'][0]
summary = ('All ten Scenario configurations completed their prescribed BFS and simulation checks. '
           'One simulation counterexample was classified as a model caller-precondition error (Case B), repaired, and trace-regressed. '
           'The ten subsequent simulations reported no invariant violations before their planned deadlines. '
           'No implementation bug was established; exploration remains incomplete.')

report = f'''# Validation — etcd-raft V00

{summary}

This is the completed budgeted validation campaign requested on 2026-09-13, not a CI verdict, publication, initialization acceptance, or safety proof. Source HEAD remains `98047a97b87252c328c9c6eee3fe72671d23a785` (build-only additions above V00). Current base SHA-256: `{base_hash}`.

## Trace regression and reused evidence

All five canonical real traces passed after the new repair: **3,543 events**, full reference actions, complete post-state equality, all 24 Trace.cfg invariants and TraceMatched. Six controlled invalid prefixes were rejected at their exact edited events (14, 240, 6, 1076, 69 and 136). Current receipts and pinned-parser results: [{manifest['trace_regression']}]({REL}/{manifest['trace_regression']}). No trace or harness generation was repeated.

Input checks established that the prior uncached ordinary tests, harness race tests, canonical traces, instrumentation and harness assets still match. Prior independent predicate-sensitivity evidence remains recorded separately in `output/validation-round-2/trace-results.json`: AckPreservation, AppliedAgreement, ReadBasis, ReadCorrelation and ReplicationEvidence. The new guard changes no predicate or observation-only replay operator. Missing durable-entry sensitivity remains correspondence-only, and ReadApplication has no dedicated mutant. Branch visitation and finite trace acceptance do not establish exhaustive or temporal coverage.

## Source-backed repair

Simulation `8a783a3912fd433cb1c3be7f18b862fe` reached NoUnexpectedFatal in 30 states: CreateSnapshot(1) followed durable completion and first entry application while MemoryStorage lastIndex remained zero. `storage.go:198–200` explicitly panics on that out-of-bound caller argument. The model's legal-caller environment lacked this local bound. Added `k <= Len(raft[n].store.hist)` to CreateSnapshot while preserving independent persistence, storage visibility, application and Advance schedules. No invariant or configuration bound was removed or weakened. The original panic branch remains modeled.

This is **Case B**, not an implementation finding. The counterexample, source rationale and exact before/after inputs are in [{REL}/case-b-create-snapshot.json]({REL}/case-b-create-snapshot.json). The two earlier MaybeSendAppend correspondence repairs remain documented in changelog.md.

## Scenario results

{table}

Every tabled BFS and simulation ended with exit 124 at its ordinary 30-minute budget. BFS counters are last periodic samples with nonempty queues, not completed reachable diameters. Simulation counts are sampled work, not distinct states or exhaustive coverage; depth was capped at 100. The pinned runtime's displayed mean/variance is unreliable, as previously documented in `output/validation-round-2/tlc-simulation-metrics.md`; no measured maximum or average is claimed.

The table's BFS jobs used pre-repair base `{manifest['inputs']['base.tla']}`; simulations used the current repaired base. Both exact input versions are retained. The pre-repair durability simulation stopped on the classified Case B counterexample and is separate from the replacement simulation above. The initial ten BFS launches were interrupted solely to correct Java temporary-directory placement and are retained as partial attempts, not full budgeted checks.

## Repair-driven MC.cfg regression

A new MC.cfg BFS check followed the reference repair and completed trace regression, with unchanged original bounds and seven standard/structural invariants. It ended at its 30-minute budget with no reported violation: depth **{regression['coverage']['depth']}**, **{regression['coverage']['distinct']:,} distinct** states, **{regression['coverage']['queued']:,} queued**, last periodic sample. Receipt: [{regression['task_id']}]({REL}/{regression['retained_evidence']}/result.json).

The earlier broad convergence attempts were not restarted merely to exhaust their state space. Their incomplete exploration, missing BFS exit status and sampled simulation coverage remain in [{REL}/prior-validation-report.md]({REL}/prior-validation-report.md). The current round has no unexplained counterexample, but no exhaustive protocol safety result or liveness result is asserted.

## Resource and execution records

All resumed TLC jobs used registered start_tlc/wait_tlc. Scenario jobs declared 12 GiB heap + 8 GiB direct and six workers each; ten concurrent jobs fit exactly within 200 GiB / 60 workers. Native requests, process outcomes, logs, seeds, hashes and counterexamples are retained in [{REL}/campaign.json]({REL}/campaign.json) and its tasks directory. Registered-worker temporary-directory repair evidence is archived there; temporary files and states use run-local locations. The native wrapper cleans its state caches; receipts and counterexamples survive.

## Remaining coverage

`remaining-validation-work.md`, `brief-coverage.md`, `model-notes.md` and `../harness/CORRESPONDENCE.md` retain the uncovered caller orders, commit-only asynchronous durability, in-core Storage/compaction interleavings, complete Node cancellation/stop schedules, broader public proposal batching, unresolved caller/property interpretations and temporal-progress driver. Parallel persistence remains an unresolved interpretation. These gaps still require initialization refinement.

No confirmation/reproduction was run. No production protocol, property wiring, CI verdict, published baseline or current pointer was changed. The user will integrate these artifacts into CI separately.
'''
(SPEC / 'validation-report.md').write_text(report)

bug_report = f'''# Bug report — etcd-raft V00

## Summary

{summary}

Six Scenario groups and all ten supplied configurations were exercised. The run retained every invariant and bound. The single new counterexample was Case B, not a confirmed implementation defect; `findings.json` therefore contains an empty findings array. No confirmation or operational reproduction was run.

## Not reproduced within the explored work

{table}

All tabled checks ended at their ordinary 30-minute budgets with no unclassified violation. BFS used the pre-repair reference and reached only depths 3–4; simulations used the repaired reference with depth cap 100. Counters are last reported samples. Neither deadlines nor unvisited behavior are counted as exhaustive passing results. Parallel persistence interpretation remains unresolved.

## Model repair and evidence

CreateSnapshot's legal-caller precondition omitted the MemoryStorage lastIndex bound (`storage.go:198–200`). The retained 30-state durability counterexample attempts index 1 against lastIndex 0. The model now requires the local storage argument to be in bounds while retaining independent application/visibility schedules. Five real traces and six invalid prefixes were regressed successfully. Every invariant remains enabled in its original configuration.

See `validation-report.md`, `{REL}/case-b-create-snapshot.json`, and `{REL}/campaign.json` for source evidence, per-job receipts and exact input versions. The repair-driven MC.cfg check also reached its ordinary deadline without a reported violation. No exhaustive safety or progress proof is established. Remaining substantive initialization gaps are recorded in `remaining-validation-work.md`.
'''
(SPEC / 'bug-report.md').write_text(bug_report)

findings = json.loads((CAMPAIGN / 'prior-findings.json').read_text())
assert not findings['findings']
findings['verification_status'] = {
    'trace_validation': 'passed after repair',
    'scenario_campaign': 'all ten budgeted BFS/simulation checks completed; Case B repaired and regressed',
    'hunting_configurations_executed': 10,
    'hunting_configurations_total': 10,
    'exhaustive_safety_established': False,
    'temporal_progress_checked': False,
    'empty_findings_meaning': 'No implementation bug established in the explored work; model repairs and remaining coverage gaps are recorded separately.',
    'evidence': f'{REL}/campaign.json'}
(SPEC / 'findings.json').write_text(json.dumps(findings, indent=2) + '\n')

results = json.loads((CAMPAIGN / 'prior-verification-results.json').read_text())
results.update(generated_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), task_status='budgeted-campaign-completed-with-coverage-gaps', model_sha256=base_hash)
results['phases'] = {'trace_validation': 'passed after repair', 'repair_model_checking': 'budget completed; no reported violation; nonempty frontier', 'scenario_checks': '10 of 10 BFS and simulation checks completed', 'exhaustive_safety': 'not-established', 'temporal_progress': 'not-checked'}
results['trace_validation']['evidence'] = f'{REL}/{manifest["trace_regression"]}'
results['trace_validation']['independent_predicate_evidence'] = 'output/validation-round-2/trace-results.json; unchanged predicate and observation-only semantics'
results['previous_model_checking'] = results.pop('model_checking')
results['model_checking'] = {'campaign': f'{REL}/campaign.json', 'repair_regression': regression, 'exhaustive_safety_established': False, 'bounds_and_properties_unchanged': True}
results['hunting_configurations'] = scenarios
results['source_correspondence_repairs'].append(repair)
results['artifact_limitations'].append('Scenario BFS and simulations span the documented caller-bound repair; exact versions and raw native receipts are retained.')
(SPEC / 'verification-results.json').write_text(json.dumps(results, indent=2) + '\n')

remaining = (CAMPAIGN / 'prior-remaining-validation-work.md').read_text()
lines = remaining.splitlines()
for i, line in enumerate(lines):
    if line.startswith('| Complete convergence exploration |'):
        lines[i] = '| Exhaustive safety coverage | The budgeted repair-driven MC.cfg check and ten Scenario BFS/simulation pairs are now executed; BFS frontiers remain nonempty and random exploration is sampled. | Preserve these limits. Further safety evidence should target uncovered core interactions; no exhaustion-only repeat is required to finish this campaign. |'
    elif line.startswith('| Run scenario configurations |'):
        lines[i] = '| Scenario depth and reachability | All ten original configurations received ordinary BFS and simulation checks; one caller-precondition Case B was repaired and trace-regressed. Exact coverage and model versions are in validation-report.md. | Assess whether deeper executions exercise each priority interaction; nonzero input budgets and absence of violations do not establish that each required trigger was visited. |'
remaining = '\n'.join(lines) + '\n'
remaining += '\nThe resumed budgeted Scenario campaign is complete. The remaining rows are substantive initialization/coverage work, not checks skipped because a prior planned deadline expired. No confirmation, baseline publication or CI pointer/verdict update is authorized by this task.\n'
(SPEC / 'remaining-validation-work.md').write_text(remaining)

coverage = (SPEC / 'brief-coverage.md').read_text()
coverage = coverage.replace('The scenario hunts have **not been executed** in this phase.', 'The generation phase did not execute the hunts; the resumed validation campaign now executed all ten (see the final section below).')
coverage = coverage.replace('## Validation-phase evidence (final)', '## Initial validation-phase evidence')
coverage = coverage.replace('Post-convergence hunt pending', 'Budgeted Scenario BFS/simulation now executed; see final section')
coverage = coverage.replace('Convergence remains unmet, and all ten hunts remain not run under the workflow\'s precondition.', 'This was the prior recorded status; the user then explicitly authorized continuation of all ten Scenario checks with ordinary per-run budgets.')
coverage += f'''\n## Resumed Scenario campaign — completed budgeted checks\n\nAll ten original configurations received BFS and simulation checks with unchanged bounds and invariant wiring. BFS reached depths 3–4 with nonempty queues. One durability simulation found a missing MemoryStorage.CreateSnapshot caller bound (Case B); source-backed repair and full five-trace/six-invalid-prefix regression followed. The ten simulations on the repaired model reported no further violation before their 30-minute limits. A repair-driven MC.cfg regression also completed its ordinary budget without a reported violation.\n\nThe Scenario checks are no longer pending. Exact counts, model versions and native receipts are in `validation-report.md` and `{REL}/campaign.json`. Non-error random trajectories were not retained individually, so the counts alone do not establish visitation of every interaction named in the earlier hypothesis table. All substantive abstraction, caller-contract, property-sensitivity and temporal-progress gaps above remain visible in `remaining-validation-work.md`.\n'''
(SPEC / 'brief-coverage.md').write_text(coverage)

correspondence = SPEC.parent / 'harness/CORRESPONDENCE.md'
with correspondence.open('a') as stream:
    stream.write(f'\n## Resumed validation evidence\n\nThe source, harness and trace assets were reused after hash checks. The new source-backed snapshot caller-bound repair required a reference regression: all five real traces again passed complete action/post-state matching and all 24 invariants, consuming 3,543 events on base `{base_hash}`. Six controlled invalid prefixes still failed at their edited events. Native results are in `../spec/{REL}/{manifest["trace_regression"]}`. Existing harness coverage limits remain unchanged; no scenario generation or confirmation/reproduction was performed.\n')

with (SPEC / 'changelog.md').open('a') as stream:
    stream.write(f'\n## Resumed campaign result\n\nAll ten original Scenario configurations completed ordinary BFS and simulation checks. The single new Case B caller-bound counterexample was repaired and all real/invalid traces regressed; no additional violation was reported by the ten repaired-model simulations or the repair-driven MC.cfg check. Native receipts, exact versions and last-reported coverage are retained under `{REL}`. The earlier “hunts not run” result is superseded. This completes the requested budgeted checks; exhaustive safety, liveness, and the documented initialization coverage gaps remain unresolved. No CI state, production protocol, invariant wiring, or current pointer was changed.\n')
manifest['status'] = 'completed-budgeted-checks-with-coverage-gaps'
manifest['finished_at_utc'] = results['generated_at_utc']
(CAMPAIGN / 'campaign.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'status': manifest['status'], 'scenarios': len(scenarios), 'findings': 0, 'model_sha256': base_hash}))
