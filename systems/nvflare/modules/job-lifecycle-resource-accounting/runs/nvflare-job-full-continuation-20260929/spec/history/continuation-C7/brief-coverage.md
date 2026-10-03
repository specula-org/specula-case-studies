# Brief coverage audit — continuation validation

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The adoption version is preserved in `history/continuation-phase2-brief-coverage.md`; the unchanged supplied narrative is `../adoption/supplied-brief-coverage.md`. Neither old PASS records nor the interrupted original run complete the continuation.

[continuation-audit.md](continuation-audit.md), [changelog.md](changelog.md), and the adoption [model-audit.md](../adoption/model-audit.md) contain the source-backed action, atomicity, invariant and failure-assumption review. `output/continuation-config-audit.json` records actual declarations; `output/continuation-run-index.json` records frozen configurations/model hashes and process outcomes. Wiring and replay coverage are not full implementation conformance.

## Scenarios and target questions

| Scenario / target question | Configuration families | Modeled mechanisms and repairs | Remaining limits |
|---|---|---|---|
| S1 / Q3: status and abort overlap | s1_contracts, s1_status; strict writer probes; F1/F3/F16 seeds | Blind writes, metadata RMW, independent abort/delete contexts, completion reads/latch/publish/remove. | At most one admin request of each kind per job; not every store/exception-metadata operation split; residuals exclude writer families. |
| S2 / Q4: ordinary failure and later admission | s2_contracts, s2_slots, s2_slots_c2, s2_sweeper, live_admission; deleted-slot/startup-failure probes | Per-object scan, stale delete authorization, runner/completion/sweeper death, admission slots and later job, deletion publication retry. | Other filesystem failures, client-token replacement, other live-map loops, archival callbacks and post-reservation poison remain source-only. |
| S3 / Q1: ownership and resource lifetime | s3_resources, s3_groups, s3_promptcancel, live_cleanup | Discrete free/reserved/in-handler/allocated ownership, TTL, late requests, pending handle, child reap/report versus free, leader/group lifetime. | List units do not cover GPU float arithmetic or process-global CUDA binding. Notification retry and OS descendant cleanup require real-code confirmation. |
| S4 / Q2–Q3: partial start and outcome | s4_outcome, s4_unsafe, s4_groundtruth, live_finalize; stop-success and F5 probes | SJ launch/register/bootstrap, whole START-map construction before delivery, CJ sync prerequisite, generic RC remap, waiter read/pop, report acceptance versus active fail_run, stop/marker, completion outcome reads. | Flat topology only; typed rc files, retained Python dict identity, late SJ heartbeat and real durations not fully modeled. MC-U1 is rechecked on C7; real supported fast-workflow timing still needs independent confirmation. |
| S5 / Q2: partial deploy/start | s5_policy; startup_failure; shared S3/S4 checks | Deployment subsets, default non-strict START, explicit errors, disconnected clients and launch exception. | min_sites=1/no required sites; strict mode absent. Inherited START tolerance is a diagnostic policy hypothesis. |

No scenario or lower-priority source finding is removed because its mechanism is outside this finite model. The launcher must consolidate MC findings with the source-review Scenarios in the modeling brief and all rows of [findings-reconciliation.md](../adoption/findings-reconciliation.md).

## Properties and actual wiring

Configuration names below omit `MC_hunt_`. Exact enabled declarations, including additional structural checks, are in the machine-readable configuration audit.

| Property | Checked in | Contract qualification |
|---|---|---|
| TerminalStable, AbortHonored | s1_contracts; relevant seeds | Strict status/acknowledgment diagnostics; post-acknowledgment launch violates the queued-cancel promise, while terminal-to-terminal precedence requires individual assessment. |
| OneShot, RunningIsTracked | s1_contracts; OneShot also s1_status; F3 seed | Launch count and tracking with explicit runner-owned windows. |
| RunnerAliveInv, CompletionAlive, SweeperAlive | s2_contracts / s2_slots / s2_sweeper as declared | Thread-death claim requires a concrete source exception. slots_c2 deliberately omits CompletionAlive. |
| SlotBalance, NoOrphanSlot | s2_contracts and selected slot/startup cfgs | Idempotent slot effect, not exactly one terminal event. Post-publication Remove is a legitimate transient owner. |
| ResourceConservation, ExclusiveOwnership, NoFreeWhileGroupAlive | s3_resources, s3_groups | Discrete list-unit accounting. Same-group descendants enabled in groups only; not default GPU exclusivity. |
| ReservationBounded | s3_resources, revised s3_promptcancel | TTL range, not eventual/wall-clock reclamation. |
| ReservationDrain | revised s3_promptcancel | Finite-batch eventual drain under fair cleanup ticks; replaces unsupported instantaneous PromptCancel. Persistent reservations can falsify it. |
| FinalMatchesOutcome | strict F5 seed; retained first s4_unsafe run | Recorded/accepted signals versus publication; post-finality signals and genuine START errors require contract analysis. |
| AdmissionProgress | live_admission | Well-formed later job progresses despite a pre-poison first job; only numeric-string pre-reservation poison is encoded. |
| BoundedFinalization | live_finalize | Eventual removal under fair deadline/actions; inherited name does not imply numerical timing proof. |
| EventualCleanup | live_cleanup | Child/group and ownership cleanup. Dead CP no longer exempts child/group lifetime; lost in-memory accounting remains outside live-CP conservation. |
| RecordedExecutionErrorNotMasked | revised s4_groundtruth | Recorded execution errors must not be published as success. Unconditional ground-truth delivery was Case A; source-only F17/F20 remains queued. |
| StartFailureMatchesPolicy | removed from s5_policy as N/A | Case A: source policy permits fatal missing targets/explicit errors even when min_sites is met. Same cfg now checks tracking/publication/slot ownership; no min/required-site policy PASS. |
| NoAdminAbortOverwrite, NoCompletionOverwrite, NoCantSchedOverwrite, NoStartFailureOverwrite, NoDeployMetaOverwrite | respective writer probes | Expose residual-excluded writers; each witness needs source/contract classification. |
| NoDeletedTrackedSlot, NoStoppedSuccess, NoStartKeyError, NoRefreshWriteOverwrite | respective probes/seeds | Mechanism-specific oracles, not independently proven whole-system contracts. |
| NoInactiveFailureSuccess | u1_startup_gap via MC_OutcomeProbes.tla | Accepted failure ignored in the startup gap followed by success while still tracked; excludes deliberate post-finality ignoring. Oracle-only extension, no transition change. |
| TypeOK, RunningWasStarted, PublishHasLatch | MC.cfg and selected cfgs | Structural checks; TypeOK does not type every field of the 56-variable model. VAV checks assignment coverage only. |

Residuals remain explicitly conditional:

- NoNovelTerminalOverwrite accepts listed writer/from/to classes after the initial Case C result. They are narrower than inherited categories but still exclude more than one witnessed execution.
- AbortHonoredNovel can exempt a job permanently after a known window/overwrite.
- NoOrphanSlotNovel globally exempts dead lifecycle threads and tolerates deleted tracked jobs. It cannot certify later-job progress in those cases.
- FinalMatchesOutcomeNovel tolerates START failure/KeyError and the stop-marker window, including a marker written after completion reads it but before the latch. Strict outcome and stop probes are retained.

A residual success never certifies its strict counterpart. Dedicated seed/probe configurations preserve the excluded contracts and writer mechanisms.

## Bounds, fairness and atomicity

Inherited topology and fault/input limits are retained. Normal CHECK attempts, heartbeats and backoff choices are no longer artificially bounded. MaxAttempts/MaxHeartbeat/MaxBackoff constants remain for cfg compatibility, but no active AttemptBound constraint exists. The new startup_failure cfg increases only the formerly disabled SJ launch exception budget to one.

Families use one or two ordered, initially submitted jobs, one or two clients, zero to two list units and one or two admission slots. Exact fault bounds are in each cfg. All select MCDeployAll, MCMinOne and MCReqNone; unused stronger helper definitions do not imply coverage. Poison is off except live_admission. Unsupported app disappearance is off except the explicitly defensive F9 seed.

Safety views retain behavior, micro-step state, fault counters and the history read by their checks. Symmetry preserves uniform client/unit configurations and never permutes ordered jobs. Temporal cfgs have no VIEW, SYMMETRY or state constraint. Weak fairness assumes modeled reactive work runs; grouped-message fairness, normal exits, expiry ticks and outcome deadlines are assumptions, not guarantees under arbitrary scheduling, hangs or unlimited failures. Eventual claims are not time bounds.

`EventualCleanup` is a leads-to property: a currently clean state can satisfy an earlier terminal antecedent, and the property alone does not forbid a later launch or reappearance. `AbortHonored`, `OneShot` and the resource-lifetime safety probes supply separate checks. `BoundedFinalization` likewise names an eventual-removal predicate, not a numerical deadline. Two initially submitted jobs represent interference with a later eligible job; arbitrary new arrivals and indefinite service operation remain outside the finite topology. A counterexample that stops a multi-invariant run does not establish the remaining properties.

The final parameter comparison is `output/continuation-C7-bounds-audit.json`: every inherited configuration retains its original constants. New strict probes match their stated reference configurations exactly; startup_failure increases only MaxSjLaunchFail from zero to one. AttemptBound is absent from all active configurations. Header text inherited from the old model about bounded backoff is superseded by the current unbounded MC transition and this audit.

Repairs expose per-object scan reads, SJ launch/registration/bootstrap, per-site target lookup with delivery only after the complete request map, the actual waiter read, kill versus map pop, CP reap/report versus free, accepted report versus active fail_run/stop/marker, and completion server/pending/abort/outcome reads. CP death no longer automatically kills children. C5 adds the real flat-topology CJ synchronization prerequisite for clean return; C6 corrects request construction versus delivery. Coarse projections still include START reply intersection plus JOB_STARTED, selected pending-loop serialization, callbacks/workspace behavior and some object-reference lifetimes. They are coverage limits, not claims that the implementation is atomic there.

## Fresh trace evidence

The adapted harness was rerun against the pinned source/runtime/output tree. The current C5 batch has **32 scenarios, 2,286 events, 65 event types and 46 actual waiter-read hooks**. All 32 replay on C7 with active TraceMatched; 11 mechanism/control assertions pass. Frozen evidence is in `harness/evidence/continuation/phase3-C5-fresh-suite/` and `spec/output/continuation-C7-fresh-replay.json` (exact inputs/model hashes in `continuation-C7-trace-manifest.json`). Previous batches remain separate.

The harness executes implementation handlers/scheduler/store/resource code with controlled process, transport and authentication edges. The waiter-read hook exists only in the disposable instrumented copy. Relevant server-engine unit tests passed in pristine, instrumented-disabled and instrumented-no-op modes (32 each); earlier targeted suite controls passed 392 tests per mode. Product source is unchanged.

Two randomized old fake-process schedules returned cleanly despite lacking a possible CJ sync opportunity. The repaired stub logs a nonzero process-edge outcome instead. This is controlled generic failure, not execution of the real 60-second SYNC_RUNNER timeout or typed rc-file handling. Hidden sync witnesses are inferred prerequisites, not observed wire events. Wrapper lookahead constrains them before the last live SJ opportunity, never advances the event cursor and never bypasses post-state checks.

The global trace lock suppresses schedules. Token/ownership side tables and fake process state are projections. Replay establishes compatibility of those projections only. Earlier negative controls reject five semantic corruptions and five malformed inputs; a valid truncated prefix passes raw TLC but fails frozen report hash/count validation. C5 negative controls pass and are recorded in `harness/evidence/continuation/phase3-C5-negative-controls/`; C7 negative controls also pass; see phase3-C7-negative-controls/. Synthetic corruptions and old model-generated traces are not implementation evidence.

## Seeds and historical reconciliation

All eight seeds have fresh C7 evidence. F1 (12 states), F2 (5), F3 (33), F5 (33), direct F5 KeyError (32) and dedicated F16 refresh (37) reach their named mechanisms. Generic F16 instead reaches F1 (13), so the inherited refresh-fidelity claim is rejected. F9 (19) is the deliberately unsupported app-disappearance conservation control, not an eligible ordinary defect. The run index and `hunt-ledger.json` distinguish violations, exhaustive finishes, budgets, environmental failures and interruptions.

Historical MC-A, MC-B, MC-C, MC-D, MC-E and MC-U1 each now have fresh C7 counterexamples: respectively 14, 32, 27, 38, 35 and 37 listed states. These are historical/source-derived rediscoveries. MC-A and other terminal-to-terminal variants retain an overlapping-precedence confirmation question and do not independently establish F1's stronger launch impact. The C7 MC-E witness publishes success before the abort marker/acknowledgment, unlike the earlier C5 read/mark/latch witness. The first group-resource witness was Case B; current C7 reaches a valid sync-before-clean-exit group-release path in 28 states. Late-CHECK PromptCancel and the S5/ground-truth diagnostic counterexamples remain Case A; source-only concerns are preserved.

The source-only queue retains GPU arithmetic/binding, parent-death notify retry, disable grace delay, ordinary restart, typed rc files, startup thread status, re-registration, delayed heartbeat, cleanup exceptions, partial workspace retention and retained UPDATE object identity. All lower-priority leads remain in the mandatory reconciliation document. Confirmation must deduplicate roots without losing triggers/consequences.

## Search status and phase ownership

Final C7 MC.cfg completed its full 30-minute resumed budget without a reported violation: depth 40, 419,928,659 generated / 76,111,186 distinct / 33,238,676 queued. All 32 fresh traces replay on those same model hashes; VAV reports zero assignment issues. The first C7 attempt was interrupted after 46 seconds and is not a result. C4–C6 remain separate historical convergence runs in the changelog. Current C7 hunting is still in progress; no overall PASS, exhaustive graph completion or unbounded-correctness claim follows.

The original run stopped during hunting after Claude credit exhaustion. This is a mixed-model continuation: GPT-6 Astra/max verification/repair, followed through the launcher by the configured GPT-5.5/xhigh confirmation and later classification. Source-classified counterexamples are not real-deployment confirmations. Original Claude spend is $180.5573146 including preflight; new Codex subscription usage is separate. API-equivalent estimates are not new Claude-account charges.

## C7 outcome-hunting supplement (in progress)

The final-model first outcome hunt reached an accepted active failure after completion latched success (37 states), a concrete schedule for the reopened V04 boundary. The unsafe cfg first reached F5 through the ordinary sync deadline; it now uses the existing FinalMatchesOutcomeNovel residual to get beyond that duplicate, with unchanged bounds. Its continued 41-state typed-102 witness leaves Mark pending at publication, so it establishes a stop-before-marker variant, not execution of RS-5's no-op marker. The real rc-file precondition remains mandatory.

A separate `MC_OutcomeProbes.tla` extends the unchanged MC module with NoInactiveFailureSuccess. Its cfg keeps every s4_outcome parameter and targets historical MC-U1 while excluding post-finality reports by requiring current running_jobs membership. No action, input or MC.cfg contract changed, so main convergence remains applicable. Both the original and tightened-guard runs reach 37-state startup-gap witnesses; the latter is the current primary evidence. Separate real-code checks must compare delayed outcome resolution/deadline expiry with immediate resolution and include an already-active tracking control. Final report generation is gated on completion of every current-model hunt and required follow-up.
