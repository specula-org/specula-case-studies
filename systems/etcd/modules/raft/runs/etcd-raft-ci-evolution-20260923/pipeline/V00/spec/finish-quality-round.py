#!/usr/bin/env python3
"""Retain this small round and update human reports; never changes CI state."""
from pathlib import Path
import datetime,hashlib,json,re,shutil,subprocess
P=Path(__file__).resolve().parent
ROOT=P/'output/quality-round-20260913-0910'
prior=ROOT/'prior-reports';prior.mkdir(exist_ok=True)
reports=['validation-report.md','remaining-validation-work.md','brief-coverage.md','model-notes.md','changelog.md','bug-report.md']
for name in reports:
    if not (prior/name).exists():shutil.copy2(P/name,prior/name)
checks={k:json.loads((ROOT/(k+'-results.json')).read_text()) for k in ['replay','decision','management']}
assert all(j['expected_result_observed'] for group in checks.values() for j in group)
assert len(checks['replay'])==11 and len(checks['decision'])==16 and len(checks['management'])==2
original=json.loads((ROOT/'initial-inputs.json').read_text())
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in original.items())
for j in checks['replay']:
    assert j['input_hashes']['Quality.tla']==hashlib.sha256((P/'Quality.tla').read_bytes()).hexdigest()
    assert j['input_hashes']['base.tla']==hashlib.sha256((P/'base.tla').read_bytes()).hexdigest()
for group in ['decision','management']:
    for j in checks[group]:
        for name,h in j['input_hashes'].items():
            if (P/name).exists():assert hashlib.sha256((P/name).read_bytes()).hexdigest()==h,name
expected_props={'vote':'VoteDecisionEligibility','campaign':'CampaignDecisionEligibility','transfer':'TransferDecisionEligibility','effect':'RequestCorrelatedConfigurationEffects','proposal':'ProposalConfigurationDecisions'}
for j in checks['decision']:
    if j['expected']=='invariant_violation':assert j['violated_invariants']==[expected_props[j['label'].split('-')[0]]]
# All original trace invariants must still be wired into the additional replay.
def invs(path):
    text=Path(path).read_text();ans=set();mode=False
    for line in text.splitlines():
        line=line.split('\\*')[0].strip()
        if line in ('INVARIANT','INVARIANTS'):mode=True;continue
        if line and line.split()[0] in ['CONSTANT','CONSTANTS','PROPERTIES','PROPERTY','CHECK_DEADLOCK','SPECIFICATION','INIT','NEXT']:mode=False
        if mode and line:ans.add(line)
    return ans
assert len(invs(P/'Trace.cfg'))==24
assert invs(P/'Trace.cfg')<=invs(P/'QualityTrace.cfg')
assert len(invs(P/'QualityTrace.cfg'))==29
assert 'ValidatePostState(logline)' in (P/'Trace.tla').read_text()
assert 'Observed\'=Decode(e.post)' in (P/'Trace.tla').read_text()
assert 'PROPERTIES TraceMatched' in (P/'QualityTrace.cfg').read_text()
coverage=json.loads((ROOT/'interaction-coverage.json').read_text())
# Zeroes are explicit coverage gaps, not omitted successful targets.
required=['vote_stale_log','vote_at_learner','hup_with_unapplied_configuration','hup_nonvoter','transfer_to_unknown','transfer_same_target','transfer_self','transfer_with_configuration_disagreement','learner_demotion_noop','callback_after_API_cancellation','callback_during_transfer','callback_with_pending_read','callback_after_early_advance','read_completion_with_configuration_disagreement']
coverage['unvisited_requested_decision_or_interaction_witnesses']=[k for k in required if coverage['totals'].get(k,0)==0]
(ROOT/'interaction-coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
summary=dict(round='small V00 quality improvement',started_at='2026-09-13T09:09:50+00:00',completed_at=now,
 status='completed scoped improvement; initialization coverage gaps remain',
 source_head=json.loads((ROOT/'source-preservation.json').read_text())['head'],
 base_sha256=hashlib.sha256((P/'base.tla').read_bytes()).hexdigest(),
 new_properties=sorted(invs(P/'QualityTrace.cfg')-invs(P/'Trace.cfg')),
 syntax='SANY passed; all 29 registered jobs reached model evaluation; native logs retained',
 real_trace_count=5,real_trace_events=3543,original_invariants_retained=24,new_invariants=5,
 retained_negative_checks=6,new_invariant_sensitivity_checks=11,
 decision_context_counts={j['label']:j['totals']['distinct'] for j in checks['decision'] if j['expected']=='pass'},
 management=dict(initial_windows=5,states=35,generated=110,queued=0,depth=4,fair_result='completed without error',unfair_result='expected temporal violation; callback already settled, FinishApplication starves',
  premises='Only existing queued work; live services; fair ApplyEntry and FinishApplication; optional legal Advance; no new proposals/messages/crashes/storage actions.'),
 all_jobs_within_five_minute_planned_budget=True,registered_job_count=29,
 resources=dict(replays=dict(heap_plus_direct_gib=99,workers=22),decisions_and_management=dict(heap_plus_direct_gib=98,workers=20),shared_limits=dict(heap_plus_direct_gib=200,workers=60)),
 results={k:k+'-results.json' for k in checks},coverage='interaction-coverage.json',
 reused_evidence='Original base/configurations, source, harness, real traces and negative traces preserved; prior tests/campaign retain their original scope.',
 remaining=coverage['unvisited_requested_decision_or_interaction_witnesses'],
 safety_findings='No unexpected counterexample or new implementation finding in this round. Intentional invalid observations are diagnostic controls, not Case C findings.',
 ci='No CI verdict, confirmation verdict, current pointer, baseline publication, or production protocol change.')
(ROOT/'quality-results.json').write_text(json.dumps(summary,indent=2)+'\n')
(P/'quality-improvement.md').write_text('''# V00 small quality improvement

Completed the scoped round within the one-hour window. The original model, configurations and bounds, harness, five real traces, and six negative traces are unchanged. Results and execution receipts are in [this round's record](output/quality-round-20260913-0910/quality-results.json).

`Quality.tla` adds five observational properties. They capture inputs and outputs at decision time and do not constrain protocol actions. Their oracles do not call the modeled decision helpers (`Step*`, `Promotable`, `UpToDate`, `RewriteConf`, `ConfigAfter`, `ConfigOf`, or `ExpectedDecision`). Common record/log access and payload summation remain shared abstractions.

| Property | V00 contract and retained outcomes |
|---|---|
| VoteDecisionEligibility | `raft.go:787–928`, `log.go:279`: term/CheckQuorum suppression, learner eligibility, vote reuse and log freshness; both unjustified grants and rejections fail. Removed nonlearners and candidates outside the local voter set are permitted by V00. |
| CampaignDecisionEligibility | `raft.go:863–887`: Hup checks local voter eligibility and unapplied configuration entries; permitted ignore, PreVote, election and compacted-slice fatal outcomes stay distinct. |
| TransferDecisionEligibility | `raft.go:1038–1046,1163–1199`: distinguish unknown/learner/same-target ignore, self cancellation, lagging-target admission and immediate TimeoutNow. |
| RequestCorrelatedConfigurationEffects | `README.md:120`, `node.go:135–163`, `raft.go:1420–1514`: each callback has a committed entry and matching request kind/target; independently derive voter/learner changes, deterministic cancellation, promotion, redundant add, prohibited demotion and Update no-op. API cancellation does not undo an already handed-off entry. |
| ProposalConfigurationDecisions | `raft.go:965–1002,1247–1262`: check admission/rejection and request identity through append or pending-change rewrite to an anonymous normal entry. A returned API call is not a commitment guarantee. |

`QualityTrace` preserves complete matching of all six observed state components, every original invariant, and TraceMatched. Observers retain only the latest action's evidence; the trace interface and base transitions do not change.

| Executed check | Actual result |
|---|---|
| Syntax and five real replays | SANY valid; all **3,543 events accepted**, with all **24 original + 5 new invariants**. |
| Six existing negative checks | All rejected at their original edited events: 14, 6, 240, 69, 136 and 1076. |
| Compact decision-context checks | Complete finite sets: **3,456 vote, 36 Hup, 66 transfer, 160 callback and 1,536 proposal observations**; no violations. These test core-function decisions, not whole-protocol reachability. |
| New sensitivity checks | All **11** deliberately invalid observations rejected by the intended property: unjustified rejection/ignore, forbidden admission, wrong request target, cancellation/demotion errors, and rewritten identity. They are formal diagnostics, not implementation findings. |
| Executable management progress | Five real queued-work windows, **35 states**, depth 4, queue exhausted. Fair ApplyEntry/FinishApplication drains the queued effects and jobs; legal Advance can interleave. Without caller fairness, TLC finds an unfinished-job stuttering cycle after callback and Advance. |

The management windows come from membership-snapshots events 233, 1165, 1338, 1437 and 1536: learner addition, promotion, canceled removal, Update no-op and removal. Initial source/caller states are copied exactly from the validated trace; accumulated pre-window ghosts are reset. This establishes only conditional drainage of existing queued work, with no further failures or new work. It does not establish proposal-to-commit, retry, recovery or system-wide management progress.

[Interaction witnesses](output/quality-round-20260913-0910/interaction-coverage.json) retain exact trace lines: 20 request-correlated callbacks; 25 callbacks and 2 vote decisions amid configuration disagreement; 5 callbacks with in-flight replication; 1 transfer to a learner, 1 with replica lag; 4 promotions, 4 canceled callbacks and 4 Update no-ops. Counts are visitation evidence. Completed reads retained in an observation buffer are excluded from pending-read coverage.

Remaining work is explicit in [remaining-validation-work.md](remaining-validation-work.md). In particular, these real traces do not exercise a configuration callback during an outstanding read or transfer, stale-log vote rejection, learner demotion, or a callback after API cancellation. Decision fixtures cover some missing local branches, not their distributed interactions. Independent TimeoutNow/PreVote-continuation eligibility, broader request/result semantics, Ready/Advance ownership, Storage-call concurrency and general liveness still need refinement. The original ten-configuration campaign was not repeated.

Every new TLC job used registered start_tlc/wait_tlc and a five-minute cap. Peak declared batches were 99 GiB/22 workers and 98 GiB/20 workers, within 200 GiB/60 workers. Native receipts, exact inputs and logs survive wrapper cache cleanup. No production protocol, confirmation verdict or CI state changed; integration remains manual.
''')
addition='''## Small quality round — 2026-09-13

The subsequent limited round added observational eligibility and request-correlated configuration checks without changing base.tla, original configurations or bounds. All five real traces passed all 24 original and five additional properties with full post matching; all six existing negative checks retained their exact failure positions. Five finite decision-context sets passed, and 11 new invalid observations tripped their intended properties. A five-window post-commit management-drain check completed 35 states under caller fairness; its unfair negative control produced the expected stuttering counterexample. This limited temporal result does not establish general management or recovery progress. See [quality-improvement.md](quality-improvement.md) and its hash-bound receipts. The campaign results below retain their original input versions and exploration limits.

'''
s=(prior/'validation-report.md').read_text();s=s.replace('# Validation — etcd-raft V00\n\n','# Validation — etcd-raft V00\n\n'+addition,1)
(P/'validation-report.md').write_text(s)
s=(prior/'remaining-validation-work.md').read_text()
s=s.replace('Six edited trace prefixes fail full correspondence. Five independently trip their intended predicates; missing durable-entry completion is correspondence-only, and ReadApplication lacks a dedicated mutation.', 'Six unchanged edited trace prefixes still fail full correspondence. The small quality round adds 11 independent decision/configuration mutants, all rejected; five prior predicate controls remain reusable. Missing durable-entry completion is correspondence-only, and ReadApplication lacks a dedicated mutation.')
s=s.replace('Five progress definitions and premises exist, but no finite liveness driver or liveness run establishes them. Finite scenarios demonstrate only their explicitly serviced operations.', 'The small quality round completed a 35-state, five-window queued-management drain check with fair callbacks/job completion and optional Advance; the unfair control fails. This does not establish the existing general election, catch-up, management, transfer or read progress definitions.')
s=s.replace('| Temporal progress |', '| General temporal progress |')
s+='''
## Small-round remaining work

The scoped quality checks are complete; receipts and source/input preservation checks are in `output/quality-round-20260913-0910/`. They do not discharge the wider initialization rows above.

- Add independent observations for TimeoutNow and PreVote continuation, transfer dispatch across term/role changes, and configuration progress/transfer side effects. Current observers cover explicit Hup/triggered ticks, incoming vote requests, leader-local/equal-term transfers, proposal admission/rewrite and configuration callbacks.
- Exercise actual configuration callbacks while reads or transfers are outstanding and after API cancellation; cover stale-log votes, local learners/removed nodes, learner-demotion no-ops and same/self/unknown transfer decisions through legal public scenarios. These are absent from the five real traces. Finite decision contexts establish local oracle consistency/sensitivity only.
- Extend request correlation through retry, duplicate context, overwritten proposals, callback return/ConfState, and final client results. API handoff/return and deterministic zero-target configuration cancellation remain distinct.
- Generalize management progress beyond already-persisted queued entries to replication/commit, publication, storage completion, recovery, new work, and appropriate message-instance fairness. Preserve the legal no-op/cancel outcomes. No large interface or liveness-driver redesign was attempted in this round.

The new coverage audit records zero outstanding-read/configuration-callback witnesses after excluding already completed ReadStates retained in observation buffers; mere buffer nonemptiness is not treated as an interaction.
'''
(P/'remaining-validation-work.md').write_text(s)
s=(prior/'brief-coverage.md').read_text()+'''
## Small quality-round correspondence and execution matrix

| Mechanism | Current source | New observation/property | Existing real scenario and result | Limit |
|---|---|---|---|---|
| Votes, freshness and Hup | raft.go:787–928; log.go:279 | VoteDecisionEligibility; CampaignDecisionEligibility | 14 vote decisions, 7 Hup decisions; two votes amid configuration disagreement; all five replays pass | Local fixtures cover missing eligibility/rejection cases; TimeoutNow/PreVote continuation not independently audited here |
| Leadership transfer | raft.go:1038–1046,1163–1199 | TransferDecisionEligibility | membership-snapshots learner-target ignore and lagging-target transfer; three decisions total | Unknown/same/self targets and transfer/configuration-callback overlap lack real witnesses |
| Configuration proposal and effect | raft.go:965–1002,1420–1514; README.md:120 | ProposalConfigurationDecisions; RequestCorrelatedConfigurationEffects | 6 proposals, 1 anonymous rewrite, 20 request-correlated callbacks; 25 callbacks with differing configurations, 5 with in-flight replication | Distributed rejection/cancellation/retry outcomes remain incomplete; no outstanding-read overlap witnessed |
| Ordered callback, job completion and Advance | node.go:145–163 | QueuedManagementDrains plus original 24 safety properties | Five exact queued-work windows; 35-state fair check completes; unfair control rejects | Conditional post-commit drainage only; prior accumulated ghosts reset, no further crash/network/storage work |

See `quality-improvement.md` for finite-context counts, all 11 sensitivity controls, unchanged six negative checks, and precise remaining work. No generated fixture is counted as an implementation trace.
'''
(P/'brief-coverage.md').write_text(s)
s=(prior/'model-notes.md').read_text()+'''
## Small observational quality extension

`Quality.tla` is an optional extension used by `QualityTrace`, `QualityDecisions` and `QualityManagement`; original base/MC/Trace configurations remain unchanged. It adds transition observations without action guards, observes actual output differences, and checks independently expressed eligibility/content relations. It shares record/log access and weight summation with the model but no decision helper. The five original real traces are replayed with every original invariant and full post-state matching.

Decision-context fixtures call the actual base core functions over explicit small input sets; they are source-alignment and property-sensitivity evidence, not protocol-reachable executions. The management driver starts at five exact validated post-states, resets pre-window ghost histories, and permits original ApplyEntry, FinishApplication and legal Advance actions only. Fairness applies to callback/job service, not to the desired result. No new work or failures occur in this driver. This finite conditional result is separate from the general progress definitions in MC.tla. Contract/source mapping and limits: `quality-improvement.md`.
'''
(P/'model-notes.md').write_text(s)
s=(prior/'changelog.md').read_text()+'''
## Small quality improvement — 2026-09-13

- [observations/properties] Added Quality.tla and QualityTrace.tla/.cfg: independent decision-time vote/Hup/transfer checks, proposal admission/rewrite content, and request-correlated committed configuration effects. Retained allowed rejection, cancellation and no-op behavior using V00 source contracts. Base protocol actions, original configurations/bounds, source and trace schema unchanged.
- [trace regression] All five real traces, 3,543 events, pass full matching and 24 original + 5 new properties. Six unchanged negative traces reject at their original edited events.
- [compact checking] Complete finite context checks: votes 3,456; Hup 36; transfers 66; effects 160; proposals 1,536. All 11 deliberately bad observations violate the intended new property. These are diagnostic controls, not Case A/B/C implementation findings.
- [progress] QualityManagement checks five real queued-work windows with original ApplyEntry/FinishApplication/Advance. The fair 35-state graph completes; omission of caller fairness exposes a stuttering unfinished-job trace. General management/network/recovery progress is not claimed.
- [coverage] Added quality-coverage.py with exact decision and cross-stage witness lines. Corrected its preliminary pending-read witness heuristic to exclude completed ReadStates retained in buffers; the final audit reports no outstanding-read/configuration-callback overlap.
- [evidence] All 29 new jobs use registered start_tlc/wait_tlc with five-minute budgets, within shared 200 GiB/60-worker limits. Exact module/config/trace copies, native receipts, logs, mutation states, source hashes and results are retained under output/quality-round-20260913-0910/. No new unexpected counterexample, confirmation/reproduction, protocol edit or CI-state change.
'''
(P/'changelog.md').write_text(s)
s=(prior/'bug-report.md').read_text()+'''
## Small quality round — diagnostic results

No unexpected counterexample or implementation finding was established. Eleven deliberately invalid observational fixtures failed their intended new invariants. The management check without caller fairness exhibited an expected unfinished-job stuttering cycle; the same finite graph with fair callback/job service passed. These controls are not implementation bugs or confirmations. Prior classifications/verdicts are unchanged. Evidence and open scope: `quality-improvement.md`.
'''
(P/'bug-report.md').write_text(s)
(ROOT/'README.md').write_text('''# Small V00 quality round artifacts

`quality-results.json` is the scoped research result, not a CI verdict. `replay-results.json`, `decision-results.json` and `management-results.json` bind checks to native receipts and exact inputs. Their corresponding `*-plan.json` and `*-receipts.json` preserve registered start_tlc arguments and task IDs; wait_tlc was used for all waits. All jobs used five-minute caps.

`replays/*/spec/` contains exact modules/configurations and sibling unchanged trace files. `decisions/Quality_*.cfg` are explicitly small source-decision/sensitivity configurations. `management/spec/Quality_management_*.cfg` selects five exact queued states from the unchanged membership trace; it is not a broad liveness campaign. Modules also live at the spec root for reuse.

`tasks/*/` retains native requests/results/workers/logs. Initial-state invariant controls retain their bad observations in logs and mutation-states.json; the temporal control also retains its JSON counterexample in management/spec/. Native state caches are wrapper-managed and were cleaned on exit.

`interaction-coverage.json` contains line-addressable witnesses and explicit zero-coverage targets. `source-preservation.json`, `initial-inputs.json` and `original-inputs-preserved.json` establish reuse. `prior-reports/` preserves the reports before this round's updates; prior campaign receipts and results remain in their original directories.

Run-local scripts at the spec root: quality-coverage.py (read-only trace audit), collect-registered-traces.py (pinned trace-result parser), collect-quality-checks.py (terminal result retention), finish-quality-round.py (checks and human-report updates). No script publishes CI state or launches protocol traffic. Use registered tools with the saved plans for future checking, subject to the shared resource ceiling.
''')
print(json.dumps(dict(status=summary['status'],completed_at=now,decision_contexts=sum(summary['decision_context_counts'].values()),original_inputs_verified=len(original))))
