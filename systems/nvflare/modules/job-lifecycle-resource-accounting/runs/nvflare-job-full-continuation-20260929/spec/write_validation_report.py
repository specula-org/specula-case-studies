#!/usr/bin/env python3
"""Render Phase 3 reports from inspected evidence, refusing an incomplete matrix.

This is a reporting aid, not a verifier or automated Case A/B/C classifier.
Human/source dispositions live in hunt-ledger.json and finding-drafts.json.
"""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_summary(run):
    data = json.loads((ROOT / 'output' / run / 'summary.json').read_text())
    return json.loads(data['content'][0]['text'])


def stats(row):
    s = row.get('stats', {})
    keys = (['states_checked', 'traces', 'depth_limit'] if row['mode'] == 'simulation'
            else ['depth', 'generated', 'distinct', 'queue'])
    return ', '.join(f'{k}={s[k]:,}' for k in keys if k in s)


def outcome(row, ledger):
    decision = ledger.get(row['run'], {})
    assert not row.get('resource_errors'), f'Unresolved resource failure: {row["run"]}'
    if row['violations'] or row['temporal_violation']:
        assert decision.get('case') in ('A', 'B', 'C'), f'Unclassified: {row["run"]}'
        names = ', '.join(row['violations']) or 'temporal violation (see trace)'
        return f'Case {decision["case"]}: {names}; {decision.get("mechanism", "")}'
    assert not row['errors'], f'Unresolved TLC errors: {row["run"]}: {row["errors"]}'
    if row['complete_no_error_message'] and row['exit_code'] == 0:
        return 'Completed finite model with no violation; assumptions still apply'
    if row['exit_code'] == 124:
        return '30-minute budget; no violation reported; incomplete search'
    raise ValueError(f'Unresolved process outcome: {row["run"]}, {row["exit_code"]}')


def main():
    runs = json.loads((ROOT/'output/continuation-run-index.json').read_text())
    ledger = json.loads((ROOT/'hunt-ledger.json').read_text())['runs']
    draft = json.loads((ROOT/'finding-drafts.json').read_text())
    assert draft['status'] == 'final-model evidence reviewed', 'Draft findings are not ready'
    base_hash = sha(ROOT/'base.tla')
    mc_hash = sha(ROOT/'MC.tla')
    convergence = [r for r in runs if r['config'] == 'MC.cfg'
                   and r['frozen_sha256'].get('base.tla') == base_hash
                   and r['frozen_sha256'].get('MC.tla') == mc_hash
                   and r['frozen_sha256'].get('MC.cfg') == sha(ROOT/'MC.cfg')
                   and r['process_status'] != 'uncollected']
    assert convergence, 'No collected convergence run for the final model'
    convergence = convergence[-1]
    assert not convergence['violations'] and not convergence['temporal_violation']
    convergence_result = outcome(convergence, ledger)
    matrix = []
    for cfg in sorted(ROOT.glob('MC_hunt_*.cfg')):
        current = [r for r in runs if r['config'] == cfg.name
                   and r['frozen_sha256'].get('base.tla') == base_hash
                   and r['frozen_sha256'].get('MC.tla') == mc_hash
                   and r['frozen_sha256'].get(cfg.name) == sha(cfg)
                   and r['frozen_sha256'].get(r.get('spec_file', 'MC.tla')) == sha(ROOT/r.get('spec_file', 'MC.tla'))
                   and r['process_status'] != 'uncollected']
        bfs = [r for r in current if r['mode'] == 'BFS']
        assert bfs, f'No current BFS for {cfg.name}'
        latest = bfs[-1]
        verdict = outcome(latest, ledger)
        matrix.append((latest, verdict))
        sims = [r for r in current if r['mode'] == 'simulation']
        if not latest['violations'] and not latest['temporal_violation'] and latest['stats'].get('depth', 0) <= 25:
            assert sims, f'Required shallow-search simulation missing: {cfg.name}'
        if sims:
            # Preserve interrupted attempts in the index; use the latest attempt
            # for the completed matrix, just as for BFS and convergence.
            matrix.append((sims[-1], outcome(sims[-1], ledger)))

    seeds = []
    for cfg in sorted(ROOT.glob('MC_seed_*.cfg')):
        current = [r for r in runs if r['config'] == cfg.name
                   and r['frozen_sha256'].get('base.tla') == base_hash
                   and r['frozen_sha256'].get('MC.tla') == mc_hash
                   and r['frozen_sha256'].get(cfg.name) == sha(cfg)
                   and r['process_status'] != 'uncollected']
        assert current, f'No current seed check for {cfg.name}'
        seeds.append((current[-1], outcome(current[-1], ledger)))

    findings = []
    lines = ['# Bug Report — nvflare-job', '', '## Summary', '',
             '- Scenario families tested: 5 (S1–S5).',
             f'- Source-classified model candidates: {len(draft["findings"])} distinct report entries.',
             f'- Hunting configurations: {len(list(ROOT.glob("MC_hunt_*.cfg")))}; seed configurations: {len(seeds)}.',
             '- All entries await the configured separate confirmation/reproduction phase. Severity is provisional.', '',
             'Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The original Claude run was interrupted during hunting by credit exhaustion, before independent confirmation. This is an authorized mixed-model continuation: GPT-6 Astra/max verification and repair, with GPT-5.5/xhigh confirmation owned by the launcher. Historical/source-derived seeds and variants are identified below; they are not presented as new independent discoveries.', '',
             'The continuation independently audited the supplied conversations and pinned source, repaired model atomicity/prerequisites, adapted and reran the harness, replayed all 32 fresh traces, and checked the final model/configuration matrix below. Replay establishes compatibility of the observed projection; bounded TLC success is not unbounded correctness. Known failing contracts remain in strict probes while explicitly documented residuals allow other searches to continue. See [brief-coverage.md](brief-coverage.md), [continuation-audit.md](continuation-audit.md), and [changelog.md](changelog.md).', '',
             'Phase 4 must consolidate these MC findings with all source-review Scenarios in `../modeling-brief.md` and the mandatory [findings reconciliation](../adoption/findings-reconciliation.md). Source-only, policy, unsupported and environment-limited leads must retain distinct dispositions. No product logic has been fixed.', '']
    for number, f in enumerate(draft['findings'], 1):
        path = OUT/f['counterexample']
        assert path.is_file(), path
        run = path.parent.name
        row = next(r for r in runs if r['run'] == run)
        assert row['frozen_sha256'].get('base.tla') == base_hash, f'Old model finding: {run}'
        assert row['frozen_sha256'].get('MC.tla') == mc_hash, f'Old MC wrapper finding: {run}'
        entry = row.get('spec_file', 'MC.tla')
        assert row['frozen_sha256'].get(entry) == sha(ROOT/entry), f'Old entry-module finding: {run}'
        assert row['config'] == f['config'], f'Wrong config for finding: {run}'
        assert row['frozen_sha256'].get(f['config']) == sha(ROOT/f['config']), f'Old cfg finding: {run}'
        assert ledger[run]['case'] == 'C', f'Not a Case C candidate: {run}'
        assert f['invariant'] in row['violations'], f'Wrong violated property for finding: {run}'
        summary = read_summary(run)
        fields = {k: f[k] for k in ['title', 'scenario', 'severity', 'invariant', 'config', 'counterexample', 'affected_code', 'summary']}
        findings.append({'id':f'MC-{number}', 'source':'model-checking', **fields})
        lines += [f'## Bug {number}: {f["title"]}', '',
                  f'- **Scenario / provenance**: {f["scenario"]}',
                  f'- **Severity (provisional)**: {f["severity"]}',
                  f'- **Invariant violated**: {f["invariant"]}',
                  f'- **Config**: `{f["config"]}`',
                  f'- **Counterexample**: {summary["trace_length"]} states; [{path.name}]({path.relative_to(ROOT)})', '',
                  '### Trace Summary', '']
        lines += [f'{i}. {step}' for i, step in enumerate(f['trace'], 1)]
        lines += ['', '### Root Cause', '', f['summary'], '', '### Affected Code', '']
        lines += [f'- `{anchor}`' for anchor in f['affected_code']]
        if f.get('related_evidence'):
            lines += ['', '### Related evidence and limits', '']
            for related in f['related_evidence']:
                related_run = related['run']
                assert (ROOT/'output'/related_run/'tlc.out').is_file()
                lines += [f'- [{related_run}](output/{related_run}/tlc.out): {related["description"]}']
        lines += ['', '### Recommendation', '', f['recommendation'], '', '---', '']

    lines += ['## Convergence evidence', '',
              f'Final MC.cfg run: [{convergence["run"]}](output/{convergence["run"]}/tlc.out). {stats(convergence)}. {convergence_result}.', '',
              'This uses the explicit known-writer residual after the retained strict TerminalStable failure. It does not certify TerminalStable or excluded bug families. Fresh replay and negative-control records are linked in the coverage audit.', '',
              '## Complete hunting matrix', '',
              'Each frozen run directory contains its model, configuration, task manifest, TLC log and process outcome. Statistics are the last values TLC reported; simulation checked-state counts include repetitions and are not distinct-state coverage. A time budget is not exhaustive completion; a violation is classified independently of process exit. No bounds were reduced to obtain depth.', '',
              '| Config / mode | Search statistics | Result | Evidence |', '|---|---|---|---|']
    for row, verdict in matrix:
        lines.append(f'| `{row["config"]}` / {row["mode"]} | {stats(row)} | {verdict} | [{row["run"]}](output/{row["run"]}/tlc.out) |')
    lines += ['', '## Seed fidelity', '', '| Seed config | Evidence / classification | Statistics |', '|---|---|---|']
    for row, verdict in seeds:
        note = ledger[row['run']].get('note', '')
        lines.append(f'| `{row["config"]}` | [{row["run"]}](output/{row["run"]}/tlc.out): {verdict}. {note} | {stats(row)} |')

    lines += ['', '## Not Reproduced', '', '| Scenario / check | Config | States explored | Result / limit |', '|---|---|---|---|']
    for row, verdict in matrix + seeds:
        decision = ledger.get(row['run'], {})
        if not (row['violations'] or row['temporal_violation']) or decision.get('case') != 'C':
            lines.append(f'| {decision.get("mechanism", "Remaining enabled checks")} | `{row["config"]}` ({row["mode"]}) | {stats(row)} | {verdict} |')
    lines += [
        '| F6 immediate cancellation | Historical s3_promptcancel | 8-state counterexample retained | Case A: expiry-backed retention is allowed; revised ReservationDrain is a finite-batch fair-tick property, not a time bound. |',
        '| F15 cross-phase START tolerance | Historical s5_policy | 25-state counterexample retained | Case A: missing targets/explicit errors are fatal by policy. Removed as N/A; current cfg covers structural lifecycle checks only. |',
        '| F17/F20 unconditional ground-truth error delivery | Historical s4_groundtruth | 31-state diagnostic retained | Case A for the reliable-signal oracle; revised check covers recorded errors. End-to-end status loss remains in the source-only confirmation queue. |',
        '| Source-only GPU arithmetic/binding, parent-death retry, re-registration, late heartbeat, typed return codes, restart, cleanup exceptions and other retained leads | No complete reference-model mechanism | Not a TLC result | See all 33 source-review Scenarios and the reconciliation table. No omission constitutes a refutation. |', '',
        '## Repairs and evidence limits', '',
        'The changelog records Case A oracle changes and Case B model repairs. Key repairs separate SJ launch/registration/bootstrap, START request construction from delivery, actual waiter read/pop, CP reap/report/free, report acceptance from active fail_run, independent admin contexts, and completion outcome reads/latch. Clean CJ exit requires a possible runner sync; a failed sync can return an ordinary process error. CP death does not automatically kill the child, and retained remote handler state cannot disable the server START-reply deadline. Strict probes audit the families hidden by residuals. All fresh trace projections replay after repairs, with corruption/input/truncation controls recorded separately.', '',
        'The harness uses real pinned handlers, store, scheduler and resource code with controlled process/transport/authentication edges and a stronger tracing lock. Hidden sync witnesses are inferred prerequisites, not observed handshakes. Real OS descendants, typed rc-file paths, default GPU arithmetic, actual authentication and end-to-end deployment belong to the separate confirmation phase. Timing controls and faults must be labeled there, with passing controls and source provenance.', '',
        'Original Claude spend: **$180.5573146**, including preflight. New Codex subscription usage is accounted separately in the launcher usage artifacts. API-equivalent Codex estimates are not new Claude-account charges.', '']
    report = '\n'.join(lines)
    result = {'schema_version':'2', 'system':'nvflare-job', 'generated_by':'validation-workflow', 'findings':findings}
    assert len(re.findall(r'^## Bug \d+: ', report, re.M)) == len(findings)
    final_matrix = {
        'source_pin': '53ba7ee567468ea7971dad4faccef13c6cb35dc2',
        'model_sha256': {'base.tla': base_hash, 'MC.tla': mc_hash},
        'convergence': {'run': convergence, 'verdict': convergence_result},
        'hunts': [{'run': row, 'verdict': verdict} for row, verdict in matrix],
        'seeds': [{'run': row, 'verdict': verdict} for row, verdict in seeds],
        'finding_ids': [f['id'] for f in findings],
        'limits': 'Source-classified model evidence; separate implementation confirmation remains required.',
    }
    (ROOT/'output/continuation-final-matrix.json').write_text(json.dumps(final_matrix, indent=2)+'\n')
    (ROOT/'bug-report.md').write_text(report)
    (ROOT/'findings.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'findings':len(findings), 'hunt_rows':len(matrix), 'seed_rows':len(seeds)}))


if __name__ == '__main__':
    main()
