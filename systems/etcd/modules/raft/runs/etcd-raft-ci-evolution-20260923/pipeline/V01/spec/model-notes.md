# Reference model and caller contracts

The specification was generated from this run's modeling brief and current source at upstream V00 `d58d5d159ae1a1f644a10003f2d8b3b807cd0b3a`. The supplied checkout's `go.mod`/`go.sum` adaptation does not change production Raft. No previous experiment, later revision, target history page, external model or operational reproducer was used. The target guidance supplied in the task is the scope basis. Pinned methodology: `Specula/skills/spec_generation/SKILL.md`, full guide and all five referenced methodology files; the directory uses an underscore.

## Architecture and semantic boundaries

`base.tla` is one Category A reference. Pure record transformations implement the source's serialized core call. The outer actions invoke complete transformations and independently update observation histories. `MC.tla` uses exactly those actions with counters on injected inputs and faults. `Trace.tla` invokes exactly those actions with mandatory post-state equality; it cannot skip an implementation transition or manufacture intermediate state to make a trace pass.

| State | Why separate | Source / scenarios |
|---|---|---|
| `raft` | role/term/vote, effective stable+unstable log, local membership, progress, queues and wrapper state | raft.go, log.go, tracker; S1–S6 |
| `disk` | completed durable logical images, independent from Storage visibility and volatile commit | README:116-124, storage.go:40-69; S1/S4 |
| `ready` | captured immutable endpoints/content plus caller stages, independent of live core state | node.go:386-419,573-604 / rawnode.go:44-69; S1/S3/S6 |
| `application` | actual histories, queued jobs and delivered read witnesses survive early Advance within the incarnation | node.go:145-157, README:120; S1/S3/S5 |
| `requests` | invocation/handoff/API result/cancel/client completion and retry lineage | node.go:473-509, README:170; S5/S6 |
| `wire` | published message multiplicity with drop/duplicate/reorder and old-incarnation traffic | README:118,126; all scenarios |
| `history` | independently checked elections, obligations, promises, application, read results and decision observations | brief §5/analysis-report §6; no history predicate guards a core decision |

One outer core call includes term dispatch, the role handler, all internal sends and progress changes, leader no-op and refill loop. The source cannot observe a network event inside that serialized call. All independently completed caller operations are separate transitions: logical write start/completion, Storage visibility, **each individual message publication**, queued work, actual snapshot/entry application, Advance, client results and recovery. Full core snapshot restore is atomic and leaves the previous Raft applied cursor in place, as in `log.go:299-303`.

Node's proposal-channel enable state is retained as `nodeLead`/`propcEnabled`: removal can disable it, and a later leader change can enable it again (`node.go:339-351,373-378`). RawNode ignores that channel state. Wrapper-loop housekeeping is included at the end of the corresponding core event, equivalent to its next select-loop entry; no extra protocol interleaving is introduced.

## Caller assumptions and named alternatives

These assumptions apply to the environment, not to protocol correctness. Invariants remain verification targets. Every later result must identify its cfg and caller variant.

| Choice | Meaning and basis | Limit |
|---|---|---|
| `SendPolicy="Strict"` | publish after the current batch's Entries, HardState and Snapshot completion; follows Ready field ordering (`node.go:58-85`) | conservative documented order, not the only caller possibility |
| `SendPolicy="SameBatch"` | require captured HardState completion; allow current Entries/Snapshot work to lag; previous batch is complete before its Advance | README:118 permission evaluated separately from field text; corresponding snapshot/follower interpretation needs review |
| `PersistPolicy="Atomic"` | one logical atomic disk completion contains Entries/HS/Snapshot | README:116 expressly permits atomic writes; Storage visibility is still separate |
| `PersistPolicy="EntriesHSnap"` | start/complete Entries, then HS, then Snapshot; crashes between completions retained | literal README:116 order; snapshot may provide required recovered boundary only after its own completion |
| `PersistPolicy="Parallel"` | independently start and complete the three logical records | alternative reading of README parallelism versus Ready field constraints, explicitly **unresolved**, not the canonical legal caller model |
| `EarlyAdvance=TRUE` | persist/install and queue work, then Advance may precede its actual application; queued batches apply in order | node.go:145-157 and README:122. Advance currently waits for outgoing publication/queueing; additional legal orders are an open extension |
| `RecoveryMode="Replay"` | recover snapshot configuration; replay committed entries above the snapshot through normal Ready/application | RestartNode, newRaft and MemoryStorage.InitialState; the model does not automatically replay skipped configs |
| `RecoveryMode="AppliedAdapter"` | caller checkpoint supplies saved application prefix, Config.Applied and coherent InitialState configuration | a custom caller adapter responsibility; **not** behavior provided automatically by MemoryStorage |
| `ReadFence="Inclusive"` | caller has applied through index i (`app index >= i`), so it contains prefix 1..i | mathematical prefix convention. Source text says “greater/further”; set Strict for the literal `>` variant and expect idle-read progress to require another applied entry |
| `CancelChanges` | fixed request IDs canceled deterministically at callback; target zero is also a callback no-op | README:120; cancellation does not depend on health or timing |
| `CancelUnknownRemovals=TRUE` | deterministic caller cancels a removal when absent in its applied configuration | satisfies tracked-peer helper precondition. FALSE retains the explicit helper fatal path; legal-use status must be resolved before attributing a violation |

IDs are immutable and nonzero. Re-adding an identity after an effective removal is not injected. Duplicate additions to a still-present identity and learner promotion are retained. Read contexts are unique among invocations; one empty context is expressible in S6. A retry uses a fresh attempt ID and records `parent`; exactly-once application/deduplication is not assumed. RawNode calls are serialized; Node core work runs through its event loop. Only previously published messages can be delivered, duplicated or used as transport-report provenance.

Compaction is permitted only through the Raft released cursor and a caller-created snapshot witness (`storage.go:213-215`, Storage contract older data in Snapshot). Snapshot application is ordered with entries. Storage visibility does not automatically mean durable persistence. The disk model stores entries by index, keeping interrupted-write holes visible rather than filling them from the live log. Successfully completed logical writes survive crash; HardState is never torn into independent term and vote writes.

## Abstraction and retained mechanisms

| Mechanism | Retained | Omitted / impact |
|---|---|---|
| Elections/options | exact higher/lower/zero term dispatcher; PreVote future-term exceptions; local learner grant block; Hup's unapplied-conf scan; unguarded campaign warning; phase-specific response tally; CheckQuorum activity grace and windows | finite logical timeout choices; no clock precision, Byzantine messages or lease reads |
| Membership | one local voter set plus learners; committed application effects; per-node lag; promotion retaining Progress; unsupported demotion no-op; removal leaving leader role; duplicate/no-op/canceled callbacks | unreachable joint protocol and future ConfChangeV2 excluded; unknown-removal API legality labeled |
| Log | effective stable/unstable overlay, exact indexed term/command identities, current-term majority commit, conflict/fatal branches, snapshot dummy boundary | bytes/allocations/physical storage layout excluded; retained compacted prefix is ghost evidence only |
| Progress | Match/Next separately; Probe/Replicate/Snapshot; state-specific rejection; optimistic endpoints; ordered capacity; nonempty versus empty sends; all allowed refill sends per core response | ring storage layout excluded; no universal Next>Match or inflight==wire assertion |
| Batching | maximal nonempty fitting prefix, oversized first entry, separate payload and encoded weights; bounded Ready pages | public injection currently submits one entry per proposal; internal rewrite accepts sequences but arbitrary externally supplied batched proposals are not yet generated |
| ReadIndex | initiation/captured index/config; self-ack; current voter set on confirmation; queue-prefix release; singleton branch by count only; forwarding, delivery and actual app/return | unique context domain; no KV service; ReadBasis needs validation as a sufficient evidence oracle rather than a complete linearizability procedure |
| Persistence/application | captured endpoints, independent disk/Storage/app, MustSync observation, delayed app after Advance, old-batch stability guard, durable-only recovery | chosen disk adapter currently requires explicit completion even for commit-only MustSync=false; async durability lag is not modeled |
| Errors | Hup/snapshot slice error, commit/applied bounds, committed overwrite, missing self-progress, snapshot absence and unknown-removal fatal outcomes | uncommon arbitrary fatal Storage errors excluded by specified nonfatal environment; full Storage-call race/error matrix remains open |
| Outcomes | actual source acceptance/drop/forward/rewrite, handoff versus core result, uncertain effects after cancel, actual completion and retry parent | Stop shares crash cleanup; full stopped-method return behavior and every Node channel race not yet represented |

Protocol branches use source-relevant state. They do not consult durable backing, global history agreement, correct quorum overlap or read-safety predicates to decide whether to run. For example, `Restore` does not fix Hup's scan, `StepLeaderReadIndex` does not replace singleton cardinality with identity membership, and configuration admission uses the released `applied` cursor exactly as the source does.

## Property meaning and limits

`history.liveOK` retains whether any live-incarnation transition overwrote the old logical commit prefix. Separate `obligations` include independently observed durable-quorum current-term commitment and every published commit assertion/client write completion even if invalid. Crashes never clear those histories. An unexposed unpersisted volatile singleton commit is not automatically made a durable global obligation. This avoids the invalid universal assertion `volatile commit <= local durable index`.

LogMatching, election history, LeaderCompleteness, obligation agreement and actual application agreement use retained full prefixes across compaction. ConfigurationTransitionSafety independently folds prior entries and checks predecessor voters used when a configuration entry commits; it does not merely recheck pendingConfIndex. LearnerEligibility observes actual decision-time learner status. Remote Match evidence is checked independently of optimistic Next and self's volatile Match. AckPreservation observes old and new effective logs and the captured snapshot endpoint.

QuotaIntegrity checks nonnegative quota, its upper bound by the payload of unreleased log entries while leader, ordered inflight endpoints and capacity. It intentionally does not assert exact equality with uncommitted bytes or outstanding messages. OutcomeSoundness independently specifies both justified rejection and justified admission; a source-consistent return is still not a successful client write.

ReadBasis applies only to actual completed reads. It requires identity-valid voter confirmation, quorum evidence, term/commit support and coverage of writes completed before invocation. ReadApplication checks actual prefix coverage; ReadCorrelation checks original invocation and context. This is a candidate sufficient-evidence characterization: valid but differently justified read executions may expose invariant mismatches. In particular the configuration-witness relation and the chosen application fence need positive traces and independent source/protocol review. They must not be assumed true to register/return reads.

ReadyAccounting includes possible loss of an already produced ReadState during RawNode's whole-buffer Advance clear. The source behavior is preserved; whether every such ReadState has an unconditional delivery contract remains TV-1 review. No failed invariant is automatically a source bug.

## Model checking, symmetry and progress

The MC layer counters bound injected ticks/campaigns/requests/crashes/loss/duplication/management/snapshot/compaction/availability/cancel/report/quiesce actions. Responses, internal commit/refill, persistence completion, Storage installation, application, Advance and restart are unbounded reactive actions. Finite request identities bound workload, not the number of allowed reactive steps.

`StateConstraint` explicitly prunes maximum term, effective log length, and wire/outgoing buffer size. Such bounds do not prove larger domains. Fingerprints retain fault counters: excluding them could merge states with different remaining fault budgets. `MCView` is an unused diagnostic projection. Symmetry fixes the ordered bootstrap identities and respects options, allowing only interchangeable joining identities. Current small cfgs often have only the identity permutation; this is reported by TLC and is not an error or evidence of reduction.

Safety hunts retain core safety and enable their actual scenario targets. The default MC cfg's commented extension properties all have enabled hunt counterparts. `brief-coverage.md` documents the actual wiring and trigger budgets. Hunting is a later post-convergence step, not a passing result obtained from this generation task.

Progress is deliberately separate. MC.tla declares the five brief progress targets and explicit availability/service/timing premises, but does not claim them checked by a state-pruned, fault-exhausted safety run. Current FairNetwork is peer-pair fairness rather than per-message-instance fairness; delayed individual messages and needed transport reports require a stronger service driver. CatchupProgress needs fair retry/status processing and a stable catch-up target. ElectionProgress's quiet-campaign premise needs a validated timing driver. ManagementProgress currently covers committed config entries through application, and ReadProgress covers enabled caller completions; full admission/retry-to-completion progress remains unfinished. Quantification over unbounded indices must be instantiated appropriately for finite TLC liveness checking.

## Remaining initialization work

1. Generate a real public-interface harness and positive traces for all H1–H10 families; check every observed post-state and fix correspondence mismatches against V00 source. No implementation trace was generated in this phase.
2. Add the independent core-Storage read/compaction interleavings, asynchronous commit-only MustSync=false completion, and the additional permitted Advance/publication orders. These omissions affect S1/S4, so initialization is not yet an accepted broadly covering baseline.
3. Extend batched public proposal injection, stopped-method outcomes and precise Node wrapper concurrency as needed by traces. Review unknown-removal, snapshot-status and caller-contract ambiguities without classifying out-of-contract inputs as implementation bugs.
4. Review the candidate read/configuration/ReadState-ownership oracles, strengthen quorum/evidence observations where necessary, and run controlled invalid trace artifacts. Do not delete a property or captured field to force acceptance.
5. Run the scenario hunts with nonvacuity/witness records and larger/composed bounds, retaining incomplete exploration as incomplete. Build the liveness service driver and check explicit progress premises.

These are substantive coverage gaps. The generated suite is a reusable starting reference with a passing small developer check, not a proof of safety, completed trace convergence, finished initialization, or researcher model-quality acceptance. No `current`, CI verdict, publication or production source repair was performed.

## Harness-phase handoff

The subsequent harness phase has now supplied the public-interface harness in `../harness/` and real implementation traces in `../traces/`. Its `CORRESPONDENCE.md` documents the envelope, exact-size and initial-timeout adapter changes; core protocol transformations and canonical safety predicates are unchanged. Consult `../harness/RESULTS.md`, `results.json` and `coverage.json` for this phase's independently executed results and remaining gaps. The earlier generation-phase result descriptions above remain historical claims of that phase, not substitutes for the new validation. Overall initialization acceptance and the later verification hunts remain separate.

## Validation-phase source alignment

The validation review corrected `MaybeSendAppend` to treat compacted entry reads as empty results before the source's `sendIfEmpty=false` early return (`raft.go:454–457`, `log.go:306–310,347–356`). Retained ghost prefixes remain oracle evidence and are no longer used as available refill entries below First. Snapshot retrieval now also preserves the preference for an existing unstable snapshot over temporary Storage snapshot unavailability (`log.go:170–174`). These are reference correspondence repairs, not implementation findings. All safety properties, trace observations and MC bounds remain enabled/unchanged. See `changelog.md` and the final validation report for fresh checks against the revised hash.

### Scenario validation: snapshot caller bound

`CreateSnapshot` requires its requested index to be visible in the receiving MemoryStorage (`storage.go:198–200`), as well as backed by the caller application prefix. Successfully persisting and applying an entry does not itself install it into MemoryStorage. Application remains independent of StorageAppend; the local snapshot call waits for its own storage argument to be valid. The implementation fatal branch and NoUnexpectedFatal remain intact.

## Small observational quality extension

`Quality.tla` is an optional extension used by `QualityTrace`, `QualityDecisions` and `QualityManagement`; original base/MC/Trace configurations remain unchanged. It adds transition observations without action guards, observes actual output differences, and checks independently expressed eligibility/content relations. It shares record/log access and weight summation with the model but no decision helper. The five original real traces are replayed with every original invariant and full post-state matching.

Decision-context fixtures call the actual base core functions over explicit small input sets; they are source-alignment and property-sensitivity evidence, not protocol-reachable executions. The management driver starts at five exact validated post-states, resets pre-window ghost histories, and permits original ApplyEntry, FinishApplication and legal Advance actions only. Fairness applies to callback/job service, not to the desired result. No new work or failures occur in this driver. This finite conditional result is separate from the general progress definitions in MC.tla. Contract/source mapping and limits: `quality-improvement.md`.

## Quality integration and finite progress window

The five decision/effect contracts now execute in the public base actions and are inherited by ordinary MC and Trace. The quality ghost is in fingerprints but outside captured production/caller post-state equality; all old protocol relations and guards remain unchanged. Source contracts, output multiplicity, cancellation/no-op handling and limitations are recorded in quality-integration.md.

ConfigurationProgress uses four operational states from accepted real Propose prefixes with the tracked entry still uncommitted. A fair cyclic service driver invokes original reference actions, permitting cancellation and a separately checked optional transfer; it does not assume success. Only the fixed-publication/fixed-delivery policy completed temporal checking (2,920 states). Other policies/transfer remain incomplete. Prior accumulated ghosts reset at the window boundary, boot-cluster application is the endpoint, and this conditional quiet-window result does not discharge general recovery, retries, arbitrary failures or future joint membership.

## Incremental joint-consensus semantics

The local configuration is the five-field tracker projection: incoming voters, outgoing voters, learners, learners-next, and auto-leave. Election results, commit indices, CheckQuorum and read confirmation use a quorum in each nonempty voter half. ConfChangeV2 applies an ordered batch either simply, by entering joint state, or by leaving it; legal-shape checks follow Changer preconditions and preserve delayed demotions through `learnersNext`.

Ready is observation-only for RawNode and accepts Node message/read buffers at delivery. Advance releases quota and captured stability endpoints for both, advances previous HardState for both, advances RawNode previous SoftState, and conditionally appends the exact empty V2 leave entry. Compact MC domains map its concrete 2-byte payload/10-byte Entry size to their largest configured representatives; full traces retain 2/10 exactly.

`RestoreProjection` deliberately matches current `newRaft`/`restore`: only incoming voters and learners are installed from persisted ConfState. It does not “fix” the implementation by replaying outgoing voters, learners-next, or auto-leave. `JointSnapshotRecovery` and the older `ConfigurationOrigin` independently require the persisted/applied configuration to survive; the source-backed restart trace violates them. This is a candidate implementation finding pending the required model campaign and fresh source confirmation.
