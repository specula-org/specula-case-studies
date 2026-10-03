# Brief coverage audit — BYOM Phase 2 continuation

Source 53ba7ee567468ea7971dad4faccef13c6cb35dc2. This replaces the historical coverage narrative; its unchanged original is adoption/supplied-brief-coverage.md. Actual cfgs were parsed into [static-checks.json](../adoption/static-checks.json), rather than inferred from intended coverage. No model, wrapper or cfg semantics were edited in adoption.

The suite is reusable, syntactically usable, and incomplete as an implementation-conformance argument. [model-audit.md](../adoption/model-audit.md) audits every action family, property, atomicity choice and residual; [harness-audit.md](../adoption/harness-audit.md) identifies observed-state and timing gaps. Existing PASS claims are not current-stage acceptance.

## 1. Brief §2 Scenarios and target questions

| Scenario / user question | Actual targeting cfgs | Implemented mechanisms | Remaining gaps |
|---|---|---|---|
| S1 / Q3: status and abort overlap | MC_hunt_s1_contracts.cfg; MC_hunt_s1_status.cfg | Blind status writes, selected RMW splits, admin snapshot, stop/mark, completion latch/publish/remove. | V01 all store/scan windows; V05 multiple same-job admin requests; V04 incomplete latch boundary. Residuals suppress whole writer/job families. |
| S2 / Q4: later-job admission after failure | MC_hunt_s2_contracts.cfg; MC_hunt_s2_slots.cfg; MC_hunt_s2_slots_c2.cfg; MC_hunt_s2_sweeper.cfg; MC_hunt_live_admission.cfg | Runner death, pre/post poison abstraction, slots, completion death, deletion retry, sweeper run-map size change. | V02 transient I/O/archival; V06 client-map/stale-token sweeper cases and sessions. Only pre-poison enabled. slots_c2 drops CompletionAlive. |
| S3 / Q1: resource ownership/lifetime | MC_hunt_s3_resources.cfg; MC_hunt_s3_groups.cfg; MC_hunt_s3_promptcancel.cfg | Bag free/reserved/allocated/in-handler units, TTL, late requests, pending handle, leader/group use. | V07 report/reap/free windows; V08 configured GPU arithmetic/environment binding; V09 partial spawn failure; V10 CP-death cleanup. |
| S4 / Q2–Q3: outcome/status consistency | MC_hunt_s4_outcome.cfg; MC_hunt_s4_unsafe.cfg; MC_hunt_s4_groundtruth.cfg | Multiple outcome channels, waiter/remover, client report, abort marker, pending/deadline/latch. | V03 launch/registration; V04 real accepted-signal boundary; V07 actual normalized rc/file; V06 late SJ heartbeat. MC-U1 unclassified. |
| S5 / Q2: partial deploy/start | MC_hunt_s5_policy.cfg; shared S3 cleanup and S4 outcomes | Subset deployment result, missing/error/timeout START, default non-strict policy. | V02 concrete partial deployment/cleanup; V03 strict mode and varied required/min sites. Probe is not an established contract. |

No supplied Scenario is silently removed or merged. S5 explicitly shares S3/S4 lifecycle mechanisms and retains its own policy cfg. Focused supplement V01–V10 maps to these Scenarios; out-of-model items remain explicit rather than receiving semantic additions in BYOM adoption.

## 2. Brief §5 properties → actual enabled hunt configs

All base properties are visible through MC.tla EXTENDS base. Names below are exact operators.

| Brief property | Type | Enabled hunt cfgs (MC_hunt_ prefix omitted) | Qualification |
|---|---|---|---|
| TerminalStable | Safety | s1_contracts | Also MC.cfg, seed_F3/F16. Includes terminal-to-terminal changes; classify precedence per source. |
| AbortHonored | Safety | s1_contracts | Also seed_F1. Checks post-ack launch/terminal meaning; does not undo launches already begun. |
| OneShot | Safety | s1_contracts, s1_status | Counts SJ launches only. |
| RunningIsTracked | Safety | s1_contracts | Also seed_F3; permits runner-owned window. |
| RunnerAliveInv | Safety | s2_contracts, s2_sweeper | Also seed_F2; concrete unhandled default-path failure required. |
| CompletionAlive | Safety | s2_contracts, s2_slots | Deliberately absent from s2_slots_c2. |
| SweeperAlive | Safety | s2_sweeper | Only the modeled cardinality-change path, not SE-1 A/C. |
| SlotBalance | Safety | s2_contracts, s2_slots, s2_slots_c2 | Abstract Boolean event history/slot set; not exactly one end event. |
| NoOrphanSlot | Safety | s2_contracts | Novel residual in s2_slots/slots_c2 is broader. |
| ResourceConservation | Safety | s3_resources, s3_groups | Also MC.cfg/conv and defensive seed_F9; discrete units only. |
| ExclusiveOwnership | Safety | s3_resources, s3_groups | Job-ID holder identity and modeled using; not actual CUDA binding. |
| NoFreeWhileGroupAlive | Safety | s3_resources, s3_groups | Descendants disabled in resources cfg, enabled in groups cfg. |
| ReservationBounded | Safety | s3_resources | TTL range check, not eventual or wall-clock reclamation proof. |
| FinalMatchesOutcome | Safety | s4_unsafe | Also seed_F5. s4_outcome uses residual, not this strict property. |
| AdmissionProgress | Liveness | live_admission | PoisonFirstPre only; no constraint/view/symmetry. |
| BoundedFinalization | Liveness | live_finalize | Eventual finalization, despite name; no timed bound. |
| EventualCleanup | Liveness | live_cleanup | Dead CP exemption and exit fairness must be audited. |
| PromptCancel | Diagnostic safety | s3_promptcancel | Expected counterexamples may be expiry-backed design. |
| SjErrorNotMasked | Diagnostic safety | s4_groundtruth | Ground truth versus best-effort signal; contract not presumed. |
| StartFailureMatchesPolicy | Diagnostic temporal/action property | s5_policy | MCSpec, ViewS3, symmetry and AttemptBound; review temporal reduction. |

Thus every safety property proposed in current brief §5 is enabled in at least one hunt cfg. That is wiring coverage only; it is not a proof the property accurately expresses every source contract. TypeOK, RunningWasStarted and PublishHasLatch are additional structural checks in base.cfg, Trace.cfg, MC.cfg and MC_conv.cfg, but not currently enabled in every hunt. TypeOK does not type all 55 variables. Validate and repair these gaps under the normal workflow.

Residual operators actually enabled:

- NoNovelTerminalOverwrite: MC_conv.cfg and s1_status; KnownOverwrite tolerates broad writer/from-status families, including MC-A/B.
- AbortHonoredNovel: s1_status; any ackInWindow/KnownOverwriteOf can exempt the job thereafter.
- NoOrphanSlotNovel: s2_slots and s2_slots_c2; global exemption when runner/completion is dead, plus deleted tracked jobs.
- FinalMatchesOutcomeNovel: s4_outcome; startFailCause and latchInStopWin history exemptions are not limited to one causal trace.

The historical assertion that each residual tolerates “exactly one confirmed seed mechanism” is rejected. Strict properties remain in separate cfgs. Validation must check residual vacuity, consider unrelated later jobs and retarget individual mechanisms.

## 3. Brief §6.1 open questions → reachable fault setup

| Question | Actual setup | Coverage implication |
|---|---|---|
| MC-1 | s1 cfgs: 2 jobs, 1 client/unit, Need=1, MaxJobs=2; abort=2, delete=1, SJ error=1, CJ error=1, heartbeat=1, attempts≤3. | Resource contention permits refresh; stale abort/delete and terminal writers reachable. Only one adm operation per job can be in flight. |
| MC-2 | s2 contract/slot cfgs: 2 jobs, 1 client, no resource units, MaxJobs=1; abort/delete/SJ error/SJ crash/CJ error/heartbeat each≤1. sweeper: 2 jobs/2 clients, crash=1, MaxJobs=2. | Abstract later-job/slot effects and run-map sweeper race reachable. Resource contention and token-generation effects absent from these runs. |
| MC-3 | resources: 2 jobs, 1 client, 2 units, MaxJobs=2; loss/CHECK timeout/START timeout/CJ error/CP launch fail/abort each≤1, heartbeat≤2. groups: 1 unit, descendants≤1, abort≤1. | Allocation concurrency and selected failures reachable; no CP crash in either, no descendants in resources cfg. |
| MC-4 | outcome: 1 job/1 client, no units; loss, SJ error/crash, CJ error, abort, heartbeat each≤1. unsafe: 1 job/2 clients, unsafe≤1. groundtruth: 1 job, loss/SJ error/crash/abort≤1. | Historical MC-E/U1, unsafe and lossy status channels reachable. Real rc preservation and actual early SJ completion need evidence. |
| MC-5 | live_finalize: 1 job/2 clients, no units, disable/crash≤1. live_cleanup: 1 job/client/unit, loss/CHECK timeout/abort≤1. live_admission: 2 jobs, first pre-poison, no faults. | Only selected progress contexts. No CP crash in cleanup; EventualCleanup itself exempts dead CP. No quantitative deadline theorem. |
| S5 policy | 1 job/2 clients, no units, deploy fail/START timeout/CP launch fail/disable≤1. | min=1 and no required sites throughout; supported strict configuration absent. |

Across all supplied MC cfgs: MaxSjLaunchFail=0 and MaxBackoff=0. All select MCDeployAll, MCMinOne and MCReqNone; helper definitions for stronger site requirements do not imply tested coverage. Safety AttemptBound caps normal CHECK attempts; heartbeats are likewise bounded. Report those bounds honestly. Three MCLiveSpec cfgs omit CONSTRAINT/VIEW/SYMMETRY and permit fair unbounded heartbeat; other fairness and finite-state assumptions still require audit. Jobs are finite and pre-submitted, so this is not a proof for arbitrary later arrivals.

## 4. Seeds, historical evidence and correction

| Seed/config | Historical result / fidelity target | Current adoption status |
|---|---|---|
| MC_seed_F1.cfg | Acked abort then blind DISPATCHED/write; AbortHonored. | Source-derived seed, no fresh TLC run. |
| MC_seed_F2.cfg | Delete during scan/held read kills runner; RunnerAliveInv. | Source-derived seed, no fresh TLC run. |
| MC_seed_F3.cfg | Early SJ error, completion then RUNNING write; TerminalStable/RunningIsTracked. | Source-derived seed; use actual error exit semantics. |
| MC_seed_F5.cfg | Accepted fail_run removes pending, START collect KeyError, FAILED_TO_RUN. | Source-derived seed; recheck named mechanism versus genuine START failure. |
| MC_seed_F16.cfg | Historical first violation was F1, not refresh RMW. | **Old seed-fidelity claim corrected.** Generic TerminalStable failure is insufficient. |
| MC_seed_F16_refresh.cfg | Dedicated NoRefreshWriteOverwrite; original validation recorded 30-state refresh/abort/write trace. | Required fresh fidelity test for F16. |
| MC_seed_F9.cfg | App disappearance after allocation; ResourceConservation with EnableUnsupported=TRUE. | Defensive/unsupported, not ordinary defect evidence. |

Historical MC-A–MC-E and the final unclassified MC-U1 are fully reconciled in [findings-reconciliation.md](../adoption/findings-reconciliation.md). Original code seeds remain distinct from historical model variants and genuinely new future discoveries. All eligible source-only candidates also require later confirmation even if excluded from the reference model.

Historical MC_conv 30-minute BFS left 32,473,737 queued states; S1 status and S2 continuation likewise hit time limits with queues. Old 30/30 official replay, stress/random passes, and one-round “convergence” apply to the old model/projection/residuals only. The interrupted resource/outcome hunts do not have a completed final verdict. The continuation has no fresh runtime replay, TLC search or confirmation result yet.

## 5. Trace and instrumentation coverage

Trace.tla/Trace.cfg exist; TraceMatched requires complete consumption of nonempty filtered event input and ValidatePostState implements real checks. SANY freshly accepted base/MC/Trace. The full instrumentation patch applies to the pin and matches all 11 historical patched files; syntax checks passed. Evidence: adoption/syntax-checks.json and adoption/static-checks.json.

Usability does not imply observational completeness:

- Existing map/stubs merge report/free, launch/registration and several heartbeat steps; event side tables project ownership; fake processes omit OS lifetime and rc-file effects.
- Trace filtering/schema acceptance and cache/ghost values need independent input/projection checks.
- Global tracing lock suppresses some target races; CP crash directly kills children in the stub.
- Old negative controls were model-generated synthetic traces. Fresh implementation-trace corruption/omission tests are still required.
- All 30 ordinary scenarios must be regenerated after working-copy path/runtime adaptation. Old official traces are quarantined under adoption/supplied-traces.

## 6. Phase 2 acceptance and remaining ownership

Accepted: provenance-checked reusable artifacts, complete inventory, focused Scenario supplement, explicit action/property/harness audit, actual cfg wiring and full candidate reconciliation. Not accepted: old final bug labels, full-conformance claims, exact residual coverage, old fresh-stage PASS or unbounded correctness.

No missing base/MC/Trace wrapper or instrumentation map required regeneration. BYOM preserves supplied semantics in adoption. Required semantic repairs and new coverage configs belong to normal validation/repair; harness adaptation/rerun belongs to Phase 2.5. See takeover-review.md for the concrete next-phase checklist and mixed-model/resource constraints.
