# Brief coverage self-audit

This is the mandatory spec-generation audit for the supplied V00 brief, Category A. Tables were populated by reading the actual generated `MC_hunt_*.cfg` files and their uncommented `INVARIANTS` blocks. Definition/enabling coverage is distinct from demonstrated reachability and implementation correspondence. The generation phase did not execute the hunts; the resumed validation campaign now executed all ten (see the final section below). The finite developer check and explicitly model-derived adapter fixtures are described in `validation-results.md`; neither establishes implementation correspondence.

The coherent reference shares elections, logs, local configurations, progress, reads, Ready batches, durable images and caller/application state. No joint transition, lease read, future implementation, historical defect model or operational reproducer was imported. Source anchors are in `base.tla`; detailed abstraction/caller limitations are in `model-notes.md`.

## Brief §2 scenarios

| Scenario | Implemented mechanisms and shared actions | Target hunt configurations | Important remaining limits |
|---|---|---|---|
| S1 promises/durability/recovery | `Ready`, `StartPersist`, `CompletePersist`, separate Storage methods, `Publish`, `QueueApplication`, `Advance`, `Crash`, `Restart`; exact endpoint/snapshot acknowledgments; whole HardState | `MC_hunt_1_durability.cfg`, `_1_same_batch.cfg`, `_1_parallel.cfg` | Parallel interpretation is explicitly unresolved. Model uses a logical durable adapter; physical WAL is excluded. Commit-only unsynced writes and in-core Storage-call races need further modeling. |
| S2 election/transfer eligibility | `Step` term dispatcher, `StepHup`, both campaigns, vote/poll, `TickCore`, `StepLeaderTransfer`, callback/config lag, wrapper response filter | `MC_hunt_2_election_transfer.cfg` | Application progress and option variations exist; source correspondence and reachable phase-crossing witnesses still need real traces and hunting. |
| S3 released work/effective membership | `RewriteConf`, proposal quota decision, independent early Advance and ordered `ApplyEntry` callback, deterministic cancellation, full snapshot config, recovery modes | `MC_hunt_3_configuration_application.cfg`, `_3_node.cfg` | `AppliedAdapter` is a named custom caller contract, not MemoryStorage automatic replay. Cancellation/unknown-removal interpretation is explicit. |
| S4 replication/snapshots | `MaybeSendAppend`, atomic refill loop, Probe/Replicate/Snapshot, state-dependent rejection, heartbeat quota release, snapshot create/persist/compact/restore/apply/report | `MC_hunt_4_replication_snapshot.cfg` | Source Storage calls inside a core Step are currently atomic with it; external call-by-call compaction races remain a coverage gap. Transport failure reports are bounded environment inputs with real publication provenance. |
| S5 ReadIndex | Invocation, forwarding, current-term gate, count-only singleton, self-ack, current-configuration queue-prefix release, Ready ownership, actual application/response | `MC_hunt_5_reads.cfg`, `_5_singleton.cfg` | ReadBasis is an explicit evidence oracle needing trace/property correspondence review; per-request progress from invocation through retry is not yet established. |
| S6 outcomes | `Invoke`, `Propose`, `ReturnAPI`, `Cancel`, forwarding/drop/rewrite decisions, quota, RawNode read-state clear, actual write/read completion, `Stop`/crash | `MC_hunt_6_outcomes.cfg` | Single-entry public proposal workload; internal multi-entry rewrite is modeled but not injected. Stop shares crash cleanup abstraction; full stopped-method return matrix needs wrapper extension. |

## Brief §5 safety properties

Every row is defined in `base.tla`, inherited by `MC.tla` (`EXTENDS base`), and enabled in at least one actual hunt cfg. Standard convergence `MC.cfg` enables the five core safety properties and structural checks; its extension-property comments are intentional and have live hunt counterparts. No property was deleted to obtain a successful developer check.

| Safety property | Observation/oracle | Enabled hunt(s), abbreviated by scenario number |
|---|---|---|
| ElectionSafety | retained successful elections, including crashed/removed leaders | All |
| LogMatching | equal indexed terms imply equal prefix witnesses | All |
| LeaderCompleteness | later-term elected log contains previously recorded obligations | All |
| CommittedHistory | live overwrite observer plus persistent/published obligation agreement | All |
| AppliedAgreement | actual application histories, including installed snapshots | All |
| VoteRecovery | saved versus reconstructed term/vote at every restart | 1, 1_same_batch, 1_parallel |
| RecoveryBacking | reconstructed commit/actual application versus durable log/snapshot, explicit holes | 1, 1_same_batch, 1_parallel |
| PromiseBacking | recorded publication/completion with independently computed backing | 1, 1_same_batch, 1_parallel, 5, 5_singleton |
| ConfigurationOrigin | effective configuration versus committed constructor/callback/snapshot prefix | 2, 3, 3_node |
| ConfigurationTransitionSafety | configuration entries committed using predecessor voters, independently folded history | 3, 3_node |
| LearnerEligibility | campaign/grant observations, local learner status at decision | 2 |
| QuorumAccounting | retained voter/yes sets and actual commit-match sets | 2, 5, 5_singleton |
| ReplicationEvidence | remote Match response witness versus leader history; self treated separately | 4 |
| SnapshotBacking | snapshot prefix, index, term and deterministically folded configuration | 4 |
| AckPreservation | pre/post effective log and exact-index snapshot acknowledgment observations | 1, 1_same_batch, 1_parallel, 4 |
| ReadyAccounting | captured page endpoints/ordering and unreported RawNode read-state losses | 3, 3_node, 6 |
| QuotaIntegrity | nonnegative payload estimate; ordered capacity-limited inflight endpoints | 4, 6 |
| OutcomeSoundness | admission/drop decision checked against a separately stated decision contract | 3, 3_node, 6 |
| ReadBasis | identity-valid voter/quorum/current-term basis plus pre-invocation completed writes | 5, 5_singleton |
| ReadApplication | actual application covers the returned prefix | 5, 5_singleton |
| ReadCorrelation | response context and invocation ID, including forwarded requests | 5, 5_singleton, 6 |
| NoUnexpectedFatal | explicit internal fatal state, including Hup/snapshot and recovery bounds | 1, 1_same_batch, 1_parallel, 2, 4, 6 |

Oracle limits are not hidden: QuotaIntegrity checks arithmetic sign, an upper bound by unreleased log payload, and flow-control structure; source quota decisions are additionally checked by OutcomeSoundness. Exact byte accounting is intentionally not asserted. ReadBasis's configuration witness is a sufficient-evidence candidate, not yet a validated complete linearizability checker. ReadyAccounting's ReadState-retention target needs TV-1 ownership-contract review. These checks must remain falsifiable during later refinement.

## Brief §6.1 model-checkable findings

These are hypotheses, not confirmed implementation bugs. Nonzero limits enable the required input classes; a completed witness showing the full trigger is still required. No finding is claimed reachable merely because its property appears in a cfg.

| Finding | Required interaction and matching setup | Target(s) | Reachability status |
|---|---|---|---|
| MC-1 | `EarlyAdvance=TRUE`, four requests, independent queued callbacks; campaigns/transfers remain possible | 3, 3_node: ConfigurationTransitionSafety and core history/elections | Encoded, not demonstrated |
| MC-2 | per-node changes/removal, retained leader role, reads and heartbeat confirmations; separate 1-voter+joiner topology | 5, 5_singleton: ReadBasis/ReadApplication | Encoded, not demonstrated |
| MC-3 | snapshot creation/compaction, valid delayed replication, full restore, pending Ready and subsequent Hup/ticks | 4: NoUnexpectedFatal; CatchupProgress is separate/pending | Encoded, not demonstrated |
| MC-4 | separate logical persistence stages/publication, outstanding Ready, crash/restart; strict, sequential same-batch, and alternative parallel interpretations | 1 and its caller variants: PromiseBacking/RecoveryBacking | Encoded; caller variant legality remains labeled |
| MC-5 | joining RawNode has empty log, may receive legitimate votes, persist HardState, crash and run empty-log constructor inference; no manufactured saved-vote state | 1: VoteRecovery/NoUnexpectedFatal | Encoded with one joining node and crash budget; legal public-interface witness pending |
| MC-6 | voter/learner additions/promotions/removal, delayed callbacks, Hup/TimeoutNow/PreVote continuation, response filtering | 2: ElectionSafety/LearnerEligibility/NoUnexpectedFatal; ManagementProgress pending | Encoded, not demonstrated |
| MC-7 | batching/inflight capacity two, actual-message loss/duplicate, snapshot status, temporary availability, compaction and heartbeat recovery | 4: ReplicationEvidence/SnapshotBacking; CatchupProgress pending | Encoded except in-core Storage-call races; not demonstrated |

## User priorities and progress obligations

Priority 1 maps to core history/election properties across S1/S2/S4. Priority 2 maps to S1's lifecycle, obligation histories and actual application. Priority 3 maps to S2/S3/S5's shared per-node configurations. Priority 4 maps to S4's progress/snapshot mechanism. Priority 5 maps to S5's actual responses and invocation-before-write observations. This retains all four must-cover interaction groups at the reference level; the open limitations above prevent a blanket coverage/acceptance claim.

`MC.tla` declares ElectionProgress, CatchupProgress, ManagementProgress, TransferSettlement and ReadProgress with explicit service/availability/timing premises. They are **not enabled as if proven by bounded fault-exhaustion runs**. A finite-state liveness service driver, stronger fair message-instance delivery, and complete retry/request progress remain required. Current ManagementProgress covers committed changes through application; current ReadProgress covers enabled caller completions. Neither substitutes for the brief's complete operation-progress questions.

TV-1/2/3 remain ordinary trace/review targets. CR-1/2/3/4 remain caller/helper-contract reviews; unknown removal can be explicitly explored by changing `CancelUnknownRemovals`, and must not be labeled a legal-use bug without resolving the contract. No exploit payload or operational reproducer is an output of this suite.

## Initial validation-phase evidence

This section updates execution status without reclassifying the generation-phase claims above. All five real traces passed again after the two MaybeSendAppend source-correspondence repairs: full base-action replay, complete post-state matching, all 24 canonical Trace.cfg invariants, and TraceMatched (3,543 events). Six controlled invalid trace copies were rejected at their edited events; five independently triggered the intended base predicates in the separately labeled observation-only checker. Uncached upstream tests and fresh harness race tests passed. Evidence: `validation-report.md`, `source-correspondence-review.md`, and `output/validation-round-2/trace-results.json`.

| Core mechanism | Current real-trace evidence | General contracts observed/checked on those traces | Bounded exhaustive / progress status |
|---|---|---|---|
| Elections and options | Eight leader transitions; PreVote continuation and CheckQuorum stepdown | ElectionSafety, LeaderCompleteness, VoteRecovery, LearnerEligibility, QuorumAccounting | MC.cfg exploration incomplete; no liveness theorem |
| Leadership transfer | Transfer events in raw, partition and membership scenarios; source-backed success/timeout and ignored-target assertions | ElectionSafety, OutcomeSoundness, full transfer/progress post-state | Budgeted Scenario BFS/simulation now executed; see final section |
| Replication and commitment | Conflicting-suffix repair, three rejected-append responses, 55 remote Match advances | LogMatching, CommittedHistory, AppliedAgreement, ReplicationEvidence | MC.cfg exploration incomplete |
| Flow control and batching | Seven inflight saturation/release pairs; oversized-first proposal and quota rejection | QuotaIntegrity, OutcomeSoundness, ReadyAccounting | Budgeted Scenario BFS/simulation now executed; see final section |
| Membership and learners | Join/learner/promotion/removal/update; one pending-change rewrite | ConfigurationOrigin, ConfigurationTransitionSafety, LearnerEligibility; invalid learner read acknowledgment detected | Broader membership interleavings and progress pending |
| Snapshots and compaction | One full restore and one fast restore; create/persist/compact/availability/status/application events | SnapshotBacking, LogStructure, AckPreservation, RecoveryBacking | In-core storage-call interleavings remain unmodeled |
| Ready and caller interfaces | Node and RawNode; eight early Advance witnesses; four same-batch pre-fsync publications | ReadyAccounting, AckPreservation, PromiseBacking; edited endpoint rejected | Additional permitted caller orders remain unmodeled |
| Crash/restart | Replay and AppliedAdapter recovery, interrupted pending durability, completed disk images | VoteRecovery, RecoveryBacking, ConfigurationOrigin | Parallel persistence interpretation unresolved |
| Quorum-based ReadIndex | Four quorum and two singleton completed reads, including forwarding and application fences | ReadBasis, ReadApplication, ReadCorrelation; context/learner mutants detected | Invocation-to-completion liveness and broader configuration interactions pending |
| API outcomes and retry/cancellation | Observed admission, forwarding, no-leader/forward-disabled/quota/transfer rejection and cancellation | OutcomeSoundness and complete request-state equality | Full stopped/canceled wrapper schedules remain gaps |

All mapped event names being visited is finite scenario coverage, not a blanket Raft coverage claim. The original safety properties and hunting configurations have not been deleted or narrowed. The model-checking result and hunting precondition must be resolved separately from these positive replay results.

Final Phase 2 evidence: repaired BFS last reported depth 3, 191,307,980 distinct states and 191,260,318 still queued; exact exit status is unavailable. Supplementary simulation ended at 30 minutes with exit 124 and a last sample of 78,182,342 checked states / 129,576 generated traces. Neither run reported a violation; neither exhausted the reachable state space. This was the prior recorded status; the user then explicitly authorized continuation of all ten Scenario checks with ordinary per-run budgets. `remaining-validation-work.md` lists the substantive refinement and progress obligations; no timeout or coverage gap is counted as passing.

## Resumed Scenario campaign — completed budgeted checks

All ten original configurations received BFS and simulation checks with unchanged bounds and invariant wiring. BFS reached depths 3–4 with nonempty queues. One durability simulation found a missing MemoryStorage.CreateSnapshot caller bound (Case B); source-backed repair and full five-trace/six-invalid-prefix regression followed. The ten simulations on the repaired model reported no further violation before their 30-minute limits. A repair-driven MC.cfg regression also completed its ordinary budget without a reported violation.

The Scenario checks are no longer pending. Exact counts, model versions and native receipts are in `validation-report.md` and `output/scenario-campaign-20260913-043418/campaign.json`. Non-error random trajectories were not retained individually, so the counts alone do not establish visitation of every interaction named in the earlier hypothesis table. All substantive abstraction, caller-contract, property-sensitivity and temporal-progress gaps above remain visible in `remaining-validation-work.md`.

## Small quality-round correspondence and execution matrix

| Mechanism | Current source | New observation/property | Existing real scenario and result | Limit |
|---|---|---|---|---|
| Votes, freshness and Hup | raft.go:787–928; log.go:279 | VoteDecisionEligibility; CampaignDecisionEligibility | 14 vote decisions, 7 Hup decisions; two votes amid configuration disagreement; all five replays pass | Local fixtures cover missing eligibility/rejection cases; TimeoutNow/PreVote continuation not independently audited here |
| Leadership transfer | raft.go:1038–1046,1163–1199 | TransferDecisionEligibility | membership-snapshots learner-target ignore and lagging-target transfer; three decisions total | Unknown/same/self targets and transfer/configuration-callback overlap lack real witnesses |
| Configuration proposal and effect | raft.go:965–1002,1420–1514; README.md:120 | ProposalConfigurationDecisions; RequestCorrelatedConfigurationEffects | 6 proposals, 1 anonymous rewrite, 20 request-correlated callbacks; 25 callbacks with differing configurations, 5 with in-flight replication | Distributed rejection/cancellation/retry outcomes remain incomplete; no outstanding-read overlap witnessed |
| Ordered callback, job completion and Advance | node.go:145–163 | QueuedManagementDrains plus original 24 safety properties | Five exact queued-work windows; 35-state fair check completes; unfair control rejects | Conditional post-commit drainage only; prior accumulated ghosts reset, no further crash/network/storage work |

See `quality-improvement.md` for finite-context counts, all 11 sensitivity controls, unchanged six negative checks, and precise remaining work. No generated fixture is counted as an implementation trace.

## Integrated default-path evidence — 2026-09-13

The five Quality contracts now live in base and are enabled in every normal MC cfg and Trace.cfg. Ordinary MC/Trace inherit the same total action observers; no independent optional path is required. Original configurations retain their bounds/actions/properties.

| Mechanism | General contract and actual evidence | Remaining coverage |
|---|---|---|
| Campaign eligibility and side effects | CampaignDecisionEligibility checks all Hups/Ticks and outgoing vote increments. Full traces: 7 explicit Hups, 21 Ticks. Six direct outgoing-bag controls plus seven additional decision mutants detect missing dimensions; a normal-MC query reaches ineligible automatic Tick. | Repeated PreCandidate Hup and successful automatic campaign are locally checked but not reached by the retained distributed queries. TimeoutNow/PreVote continuation contracts remain separate work. |
| Request-correlated configuration decisions/effects | All 29 Trace properties passed; 20 correlated callbacks, 25 callbacks amid config disagreement, 5 amid inflight replication and 3 after restart. | Read/configuration and full retry/result correspondence remain open. Local rejection/no-op fixtures are not distributed witnesses. |
| Precommit configuration progress and leadership | Four real reachable pending requests; original service transitions; completed 2,920-state fixed-communication temporal check. Distributed commitment and application-after-transfer witnesses; delivery-stalled sensitivity cycles. | Broader message orders and optional-transfer universal progress remain budget-limited. Quiet service-window/usable-quorum assumptions apply; no arbitrary failure, recovery or joint-configuration result. |
| Normal checking entrypoints | Full five-trace/six-negative regression, retained named predicate checks, source alignment and ordinary MC smoke pass. Full-bound MC/election/configuration jobs execute the new contracts. | Those three exploratory jobs remain partial at five minutes, with exact counts/inputs in quality-integration-results.json. |

The new matrix supplements the historical tables above; it does not relabel their executions. Further interface/progress refinements remain in remaining-validation-work.md.

## Incremental U1-U5 coverage

| Scenario | Changed producer/effect | High-risk consumer/fault | Fresh evidence |
|---|---|---|---|
| U1/U2 explicit joint | InvokeV2, proposal, committed V2 callback, both voter halves | ReadIndex requires incoming and outgoing quorums; explicit leave | `joint-explicit.ndjson` (447 events) |
| U2/U3 automatic leave | implicit joint transition and `AutoLeave` | Advance appends empty V2; replication/commit/application finalizes incoming voters | `joint-autoleave.ndjson` (415 events) |
| U4/U5 recovery | joint ConfState snapshot, local persistence and compaction | crash/newRaft restart consumes persisted ConfState | `joint-snapshot-recovery.ndjson` (230 events; correspondence pass and ConfigurationOrigin violation) |
| inherited interaction regression | constructor, Ready/Advance, elections, transfer, replication, membership, snapshots, reads | five compatible V00 scenario families on the new binary | remaining five traces (3,537 events) |

The update properties are wired through `Update_full.cfg` over complete `MCNext` and `Update_focused.cfg` over concrete changed/interaction Actions. Dedicated reachability-canary configs cover joint entry, Advance auto-leave, and joint restart projection. No open rely is used: the full campaign is the guard for omitted focused context.
