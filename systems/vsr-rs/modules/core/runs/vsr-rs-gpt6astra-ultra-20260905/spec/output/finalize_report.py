#!/usr/bin/env python3
"""Finalize the no-counterexample report only after every scheduled run ends."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

SPEC = Path(__file__).resolve().parent.parent
OUT = SPEC / 'output'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(path):
    return json.loads(path.read_text())

scenarios = {
    'MC_hunt_scenario1.cfg': 'S1: historical preservation, N=3',
    'MC_hunt_scenario1_five.cfg': 'S1: historical preservation, N=5',
    'MC_hunt_scenario2.cfg': 'S2: logical execution and replies',
    'MC_hunt_scenario3_recovery.cfg': 'S3: quiescent recovery, N=3',
    'MC_hunt_scenario3_recovery_five.cfg': 'S3: quiescent recovery, N=5',
    'MC_hunt_scenario3_requests.cfg': 'S3: request progress, N=3',
}
convergence = read(OUT/'convergence.json')
trace = read(OUT/'round1-traces/parallel-results.json')
controls = read(OUT/'round1-traces/controls/results.json')
assert convergence['workflow_converged_within_budget'] and not convergence['spec_changed']
assert trace['status'] == 'success' and trace['passed'] == 4 and controls['all_passed']
for name, value in trace['sha256'].items():
    assert digest(Path(name)) == value, name
for name, value in read(OUT/'inputs/manifest.json')['files'].items():
    assert digest(SPEC/name) == value, name

rows = []
for config, scenario in scenarios.items():
    row = {'config': config, 'scenario': scenario}
    for mode in ['bfs', 'simulation']:
        directory = OUT/(Path(config).stem+'_'+mode)
        record = read(directory/'run.json')
        assert record.get('finished_utc'), f'{directory}: still running'
        assert record['budget_elapsed_without_error'] and record['returncode'] == 124, directory
        assert not record['errors'] and not record['violation'], directory
        log = (directory/'tlc.out').read_text()
        assert not re.search(r'^Error:|OutOfMemoryError|unexpected exception|GC overhead', log, re.M|re.I), directory
        for name, value in record['sha256'].items():
            assert digest(directory/name) == digest(SPEC/name) == value, (directory, name)
        progress = [line for line in log.splitlines() if line.startswith('Progress')][-1]
        if mode == 'bfs':
            match = re.search(r'Progress\((\d+)\).*?: ([\d,]+) states generated .*?, ([\d,]+) distinct states found .*?, ([\d,]+) states left on queue', progress)
            stats = dict(zip(['depth','generated','distinct','queue'], [int(x.replace(',','')) for x in match.groups()]))
            assert stats['depth'] <= 25
        else:
            match = re.search(r'Progress: ([\d,]+) states checked, ([\d,]+) traces generated \(trace length: mean=(\d+)', progress)
            stats = dict(zip(['states_checked','traces','mean_length'], [int(x.replace(',','')) for x in match.groups()]))
            stats['configured_max_depth'] = 100
        seed = re.search(r'(?:with seed |and seed )(-?\d+)', log)
        row[mode] = {'directory': str(directory.relative_to(SPEC)), 'returncode': 124,
                     'elapsed_seconds': record['elapsed_seconds'], 'last_progress': progress,
                     'statistics': stats, 'seed': int(seed.group(1)) if seed else None,
                     'completed_temporal_checks': log.count('Finished checking temporal properties'),
                     'completion_metadata_recovered': record.get('completion_metadata_recovered',False),
                     'returncode_source': record.get('returncode_source','Collected by the run driver'),
                     'elapsed_seconds_source': record.get('elapsed_seconds_source','Driver monotonic clock'),
                     'sha256': record['sha256']}
    rows.append(row)

summary = {'system': 'vsr-rs', 'source_revision': convergence['source_revision'],
           'generated_utc': datetime.now(timezone.utc).isoformat(),
           'workflow_status': 'CONVERGED_WITHIN_BUDGET', 'exhaustive': False,
           'semantic_spec_modified': False, 'rounds': 1, 'trace_passed': 4,
           'negative_controls_passed': 4, 'case_a': 0, 'case_b': 0, 'case_c': 0,
           'model_checking_findings': 0, 'liveness_assurance': 'LIMITED',
           'counts_are_last_progress_samples': True,
           'simulation_counts_are_not_unique_states_or_unique_paths': True,
           'convergence': convergence, 'hunting': rows}
(OUT/'run-summary.json').write_text(json.dumps(summary, indent=2)+'\n')

table = ['| Scenario / config | BFS distinct / queued | Depth | Simulation paths / states checked | Result |',
         '|---|---:|---:|---:|---|']
for row in rows:
    b, s = row['bfs']['statistics'], row['simulation']['statistics']
    table.append(f"| {row['scenario']} — [{row['config']}]({row['config']}) | {b['distinct']:,} / {b['queue']:,} | {b['depth']} | {s['traces']:,} / {s['states_checked']:,} | No violation observed; LIMITED |")
table_text = '\n'.join(table)

bug_report = f'''# Bug Report — vsr-rs

## Summary

- Source revision: `3ac0104a567092139534c9022205d02281a2da41`.
- Protocol scenarios tested: 3 (S1 preservation, S2 execution/replies, S3 progress), across all six supplied hunting configs. S4's conforming abstract publication boundary is included in S1; the shipped example's concrete integration is outside this model.
- Model-checking bugs found: **0**. No counterexamples required Case A/B/C classification, and no semantic spec or invariant changes were made.
- Convergence: four real traces passed, followed by a 30-minute `MC.cfg` run without violations. Workflow convergence is limited to the configured budget; the reachable state space was not exhausted.
- Hunting: every config received 30 minutes of BFS and, because every BFS depth was <=25, 30 minutes of simulation with `-S -n 999999999 -p 100`. No bounds were reduced.

## Not Reproduced

{table_text}

All runs ended through the configured 30-minute watchdog (exit 124), rather than exhausting their search. Counts above are the last logged samples: generated/distinct/state-check/path counts are lower bounds on work done; queue sizes are point-in-time samples. Simulation counts include repeated states and paths. The configured maximum simulation depth was 100; observed reported means were 77–78. These results establish **no violations found in the explored/sample executions**, not absence of implementation defects.

Exact commands, seeds, hashes, times, complete progress logs and runtime exits are in each `output/MC_hunt_*_{{bfs,simulation}}/` directory. [Machine-readable run summary](output/run-summary.json), [BFS audit](output/bfs-audit.md), and [simulation audit](output/simulation-audit.md) support the table.

The provider interruption prevented the simulation driver's completion fields from being saved. The original launch records are preserved as `run.launch.json`; completion fields in `run.json` were recovered from unchanged logs and observed exited PIDs. For these six runs, exit 124 is inferred from the installed wrapper's exclusive `Timed out` branch, and elapsed time is filesystem-derived (final `launch.out` modification time minus the recorded start), rather than an OS-collected return value or recovered monotonic timing. [Recovery evidence](output/simulation-metadata-recovery.json) records this distinction. No simulation was rerun.

## Assurance boundaries

- All checks are limited to the supplied finite views, logs, requests, fault budgets, network/outbox bounds, N=3/N=5 membership and deterministic Put/Get workload. The original configs and all semantic files remain unchanged; their initial identities are in [the input manifest](output/inputs/manifest.json).
- S3 checks the configured conditional formulas `<>BoundHit \\/ <service-property>`. Reaching a bound discharges the bounded question. Stabilization, continuing service clocks, owner fairness, reliable delivery relative to ticks, and failure-budget compliance are premises. Periodic temporal checks ran during BFS, but unrestricted request/recovery liveness remains **LIMITED**. All supplied configs disable deadlock checking.
- No per-scenario hit census, bound-avoidance census, or assumption-satisfying infinite service witness was recorded. In particular, the five-replica config permits two concurrent recoveries; aggregate search/path counts alone do not document a specific witness of that trigger.
- Quiescent recovery configs submit no requests. Their empty-log preservation predicates do not add independent committed-data coverage; the relevant S1/S2 hunts carry that question.
- The [fidelity audit](output/fidelity-audit.md) distinguishes substantive history checks from the redundant primary-identity conjunct and records the absence of a separate historical-view-floor oracle. It found no basis for an invariant/spec correction. Trace agreement remains evidence for the recorded schedules, not a general refinement proof.
- Singleton behavior, DST observer/workload limitations, and concrete example filesystem/startup/identity/nonce/transport obligations remain the separate test/review candidates in `../modeling-brief.md`. They are not silently promoted into this phase's model-checking findings.

## Changes during validation and hunting

No Case A or Case B fixes were required. Two preliminary MC launches were interrupted during infrastructure setup and are excluded from successful coverage; the full replacement run is retained. A later provider interruption left the simulations running, and the same processes were resumed and observed without restarting completed checks. See [changelog.md](changelog.md).
'''
(SPEC/'bug-report.md').write_text(bug_report)
(SPEC/'findings.json').write_text(json.dumps({'schema_version':'2','system':'vsr-rs',
    'generated_by':'validation-workflow','findings':[]}, indent=2)+'\n')

validation = f'''# Specification validation — vsr-rs

**Result: workflow converged in one round within the prescribed budget; no model-checking finding was produced. Exploration and liveness assurance remain LIMITED.** Source: `3ac0104a567092139534c9022205d02281a2da41`.

## Evidence

1. Phase 0 verified all required inputs, six hunt cfgs, enabled `TraceMatched`, full post-state/application comparisons, and 46/46 inherited provenance hashes. The existing harness needed no regeneration. [Audit](output/phase0-audit.md).
2. The installed `run_trace_validation_parallel` handler replayed all four implementation traces successfully: 474 transitions and 50 nested application calls. A second strict pass and four corrupted controls passed their expected acceptance/rejection checks. Every negative was rejected specifically by `TraceMatched`; no checks were relaxed. The installed `clean_traces` handler found no generated trace artifacts to remove. [Trace results](output/round1-traces/parallel-results.json), [controls](output/round1-traces/controls/results.json).
3. `MC.cfg` ran for 30 minutes with 32 workers and 16 GiB heap + 64 GiB off-heap. The last sample recorded 1,299,398,606 generated states, 232,574,619 distinct states, 128,644,184 queued states and depth 19. No violation or semantic/invariant change occurred. [Convergence record](output/convergence.json).
4. All six hunts ran for 30 minutes in BFS, then 30 minutes in depth-100 simulation. Concurrent runs used explicit worker/memory budgets and separate directories with copied, hash-checked inputs. [Bug report and per-config coverage](bug-report.md), [run summary](output/run-summary.json).

## Interpretation

Preservation, ordered application, logical-request uniqueness and reply soundness were checked where enabled by each supplied config. No counterexample was produced, so Case A/B/C counts are all zero. Source, semantic specifications and config bounds were preserved. There is no bug reproduction or new simulator regression from this phase.

The recorded traces cover all 18 event types, but not every finer dispatch branch. Aggregate search counts do not prove mechanism-specific reachability. Conditional temporal passes discharge bound-reaching behaviors and rely on the explicit timing/fairness environment; they do not establish general service liveness or the shipped example's obligations. The detailed limitations and independently reviewed oracle qualifications are in [the bug report](bug-report.md) and [fidelity audit](output/fidelity-audit.md).

Required artifacts are [changelog.md](changelog.md), [bug-report.md](bug-report.md), [findings.json](findings.json), and the preserved TLC evidence under `output/`. The findings index contains a present empty list, explicitly recording zero model-checking findings rather than a missing phase result.
'''
(SPEC/'validation-report.md').write_text(validation)

changelog = SPEC/'changelog.md'
text = changelog.read_text()
assert '\n## Result\n' not in text, 'Already finalized; inspect rather than appending twice'
for row in rows:
    stats = row['simulation']['statistics']
    text += f"- [bounded-pass] {row['config']}: simulation 30 minutes, configured depth 100, {stats['traces']:,} paths / {stats['states_checked']:,} states checked at last progress; no errors or violations.\n"
text += '\n## Result\nConverged in 1 round within the prescribed MC budget. Bug hunting: no model-checking bugs found in all six BFS + simulation pairs. All searches remain bounded/non-exhaustive; liveness is LIMITED. No semantic spec, invariant or source changes were made by validation.\n'
changelog.write_text(text)
print(json.dumps({'status':'finalized','configs':len(rows),'findings':0,'liveness':'LIMITED'}, indent=2))
