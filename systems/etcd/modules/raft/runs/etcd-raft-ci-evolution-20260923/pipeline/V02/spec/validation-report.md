# Validation — etcd-raft V00

## Quality integration round — 2026-09-13

The ordinary MC and Trace paths now update and check all five Quality contracts. Five real traces passed full post-state equality with all 29 invariants; six original invalid traces retained their exact rejection points. The ordinary MC smoke completed 1,605 states; the three full-bound MC/election/configuration checks ended at five-minute budgets without reported violations and remain partial. A four-window precommit configuration driver completed 2,920 states under an explicitly fixed communication-service policy; broader progress orderings and transfer progress remain incomplete. Expected local sensitivity and distributed coverage witnesses are distinguished from protocol findings in [quality-integration.md](quality-integration.md) and [machine results](quality-integration-results.json).

Integrated base SHA-256: `d73a782af8f3cfdb51fe77e43aae03dcdfad6e1f54c88b47d335170d9531f938`. The source and real traces are unchanged. Normal launchers now share registered TLC resource accounting and blocking waits; normal reports verify imported module/config hashes. No confirmation, production-code or CI-state change occurred.

## Prior rounds — historical input versions

## Small quality round — 2026-09-13

The subsequent limited round added observational eligibility and request-correlated configuration checks without changing base.tla, original configurations or bounds. All five real traces passed all 24 original and five additional properties with full post matching; all six existing negative checks retained their exact failure positions. Five finite decision-context sets passed, and 11 new invalid observations tripped their intended properties. A five-window post-commit management-drain check completed 35 states under caller fairness; its unfair negative control produced the expected stuttering counterexample. This limited temporal result does not establish general management or recovery progress. See [quality-improvement.md](quality-improvement.md) and its hash-bound receipts. The campaign results below retain their original input versions and exploration limits.

All ten Scenario configurations completed their prescribed BFS and simulation checks. One simulation counterexample was classified as a model caller-precondition error (Case B), repaired, and trace-regressed. The ten subsequent simulations reported no invariant violations before their planned deadlines. No implementation bug was established; exploration remains incomplete.

This is the completed budgeted validation campaign requested on 2026-09-13, not a CI verdict, publication, initialization acceptance, or safety proof. Source HEAD remains `98047a97b87252c328c9c6eee3fe72671d23a785` (build-only additions above V00). Scenario-round base SHA-256: `f0db2c17906d5fb3caffe6cb0c90283e8edbbd22440269bcff04af504f7aca2e`.

## Trace regression and reused evidence

All five canonical real traces passed after the new repair: **3,543 events**, full reference actions, complete post-state equality, all 24 Trace.cfg invariants and TraceMatched. Six controlled invalid prefixes were rejected at their exact edited events (14, 240, 6, 1076, 69 and 136). Current receipts and pinned-parser results: [trace-repair-1-results.json](output/scenario-campaign-20260913-043418/trace-repair-1-results.json). No trace or harness generation was repeated.

Input checks established that the prior uncached ordinary tests, harness race tests, canonical traces, instrumentation and harness assets still match. Prior independent predicate-sensitivity evidence remains recorded separately in `output/validation-round-2/trace-results.json`: AckPreservation, AppliedAgreement, ReadBasis, ReadCorrelation and ReplicationEvidence. The new guard changes no predicate or observation-only replay operator. Missing durable-entry sensitivity remains correspondence-only, and ReadApplication has no dedicated mutant. Branch visitation and finite trace acceptance do not establish exhaustive or temporal coverage.

## Source-backed repair

Simulation `8a783a3912fd433cb1c3be7f18b862fe` reached NoUnexpectedFatal in 30 states: CreateSnapshot(1) followed durable completion and first entry application while MemoryStorage lastIndex remained zero. `storage.go:198–200` explicitly panics on that out-of-bound caller argument. The model's legal-caller environment lacked this local bound. Added `k <= Len(raft[n].store.hist)` to CreateSnapshot while preserving independent persistence, storage visibility, application and Advance schedules. No invariant or configuration bound was removed or weakened. The original panic branch remains modeled.

This is **Case B**, not an implementation finding. The counterexample, source rationale and exact before/after inputs are in [repair evidence](output/scenario-campaign-20260913-043418/case-b-create-snapshot.json). The two earlier MaybeSendAppend correspondence repairs remain documented in changelog.md.

## Scenario results

| Configuration | BFS depth | BFS distinct | Simulation states checked | Simulation traces generated |
|---|---:|---:|---:|---:|
| MC_hunt_1_durability.cfg | 4 | 5,751,426 | 6,822,626 | 10,257 |
| MC_hunt_1_parallel.cfg | 4 | 5,503,525 | 8,892,960 | 8,176 |
| MC_hunt_1_same_batch.cfg | 4 | 5,145,688 | 7,575,325 | 9,180 |
| MC_hunt_2_election_transfer.cfg | 3 | 19,730,092 | 6,862,224 | 7,891 |
| MC_hunt_3_configuration_application.cfg | 3 | 18,276,401 | 7,066,573 | 7,658 |
| MC_hunt_3_node.cfg | 3 | 19,803,444 | 5,952,565 | 9,694 |
| MC_hunt_4_replication_snapshot.cfg | 3 | 21,208,013 | 8,385,536 | 11,019 |
| MC_hunt_5_reads.cfg | 3 | 22,538,999 | 7,286,663 | 7,889 |
| MC_hunt_5_singleton.cfg | 4 | 105,960,938 | 21,874,302 | 94,779 |
| MC_hunt_6_outcomes.cfg | 3 | 20,436,713 | 7,190,459 | 8,148 |

Every tabled BFS and simulation ended with exit 124 at its ordinary 30-minute budget. BFS counters are last periodic samples with nonempty queues, not completed reachable diameters. Simulation counts are sampled work, not distinct states or exhaustive coverage; depth was capped at 100. The pinned runtime's displayed mean/variance is unreliable, as previously documented in `output/validation-round-2/tlc-simulation-metrics.md`; no measured maximum or average is claimed.

The table's BFS jobs used pre-repair base `f906b1b70c9b70555bf2e73d8692ecc952532049ab1bb4768d151b9cee0c9e5b`; simulations used the then-current repaired base. Both exact input versions are retained. The pre-repair durability simulation stopped on the classified Case B counterexample and is separate from the replacement simulation above. The initial ten BFS launches were interrupted solely to correct Java temporary-directory placement and are retained as partial attempts, not full budgeted checks.

## Repair-driven MC.cfg regression

A new MC.cfg BFS check followed the reference repair and completed trace regression, with unchanged original bounds and seven standard/structural invariants. It ended at its 30-minute budget with no reported violation: depth **3**, **187,820,952 distinct** states, **187,774,192 queued**, last periodic sample. Receipt: [f4c74da8e7d14d9e87d0f6f66fec667f](output/scenario-campaign-20260913-043418/tasks/f4c74da8e7d14d9e87d0f6f66fec667f/result.json).

The earlier broad convergence attempts were not restarted merely to exhaust their state space. Their incomplete exploration, missing BFS exit status and sampled simulation coverage remain in [prior validation report](output/scenario-campaign-20260913-043418/prior-validation-report.md). The current round has no unexplained counterexample, but no exhaustive protocol safety result or liveness result is asserted.

## Resource and execution records

All resumed TLC jobs used registered start_tlc/wait_tlc. Scenario jobs declared 12 GiB heap + 8 GiB direct and six workers each; ten concurrent jobs fit exactly within 200 GiB / 60 workers. Native requests, process outcomes, logs, seeds, hashes and counterexamples are retained in [campaign manifest](output/scenario-campaign-20260913-043418/campaign.json) and its tasks directory. Registered-worker temporary-directory repair evidence is archived there; temporary files and states use run-local locations. The native wrapper cleans its state caches; receipts and counterexamples survive.

## Remaining coverage

`remaining-validation-work.md`, `brief-coverage.md`, `model-notes.md` and `../harness/CORRESPONDENCE.md` retain the uncovered caller orders, commit-only asynchronous durability, in-core Storage/compaction interleavings, complete Node cancellation/stop schedules, broader public proposal batching, unresolved caller/property interpretations and temporal-progress driver. Parallel persistence remains an unresolved interpretation. These gaps still require initialization refinement.

No confirmation/reproduction was run. No production protocol, property wiring, CI verdict, published baseline or current pointer was changed. The user will integrate these artifacts into CI separately.
