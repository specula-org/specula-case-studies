# Brief coverage audit: nvflare-transfer

Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, clean `source-transfer` checkout. Category A with explicit threaded callback/operation continuations. Methodology: installed `spec_generation/guide.md` and its five references. The guide's mandatory audit requirement takes precedence over its older checklist's optional-artifact wording.

This is **spec-generation coverage**, not a converged hunt, conforming implementation trace or confirmed runtime defect. The mappings were checked against actual generated cfg files. `action-map.json` inventories executable actions, source boundaries and required post-state fields.

## Brief §2: scenarios

| Scenario | Model representation | Target cfg or explicit merger |
|---|---|---|
| S1 receiver truth versus terminal progress | One atomic dedup/pending-pop/status/all-done-latch update; separate guarded downloaded-to-one/all callbacks, progress selection, event construction and public delivery. Pipelining precedes consume; a started pipeline future survives consume failure, including before remote admission. | `MC_hunt_s1_progress.cfg`: `CompletedProgressHasReceiverSuccess`; one receiver/ref, one DATA chunk, one consume/finalization failure, other fault limits zero. |
| S2 full-payload sets and caller declarations | `Verdict`, `CommonSuccess`, `ConfirmedSuccess`, `OutcomeAggregation`; every declared receiver and fixed registered ref participates. | **Merged into all hunts as core safety**; two-ref/two-receiver matrices in `MC_hunt_s4_budgets.cfg`. No standalone hunt of already-fixed aggregation. TV-1 and TV-3 remain caller/value-level regressions. |
| S3 enqueue/error/fallback settlement | Enqueue, submission acknowledgement, post-enqueue RuntimeError, stopped executor, fallback and worker entry are separate. Each entry runs its own drain/snapshot/callback/release/record chain. | `MC_hunt_s3_settlement.cfg`: `SingleSettlementEffects`; `MC_hunt_s3_after_receipt.cfg`: `NoSettlementEffectsAfterReceipt`. Separate cfgs prevent a shallower duplicate effect masking the later target. |
| S4 receiver budgets versus global inactivity | Separate transaction/ref/receiver request clocks, captured request timestamps, budget snapshot and monitor sampled time. Freshness recheck and final-status commit are separate. | `MC_hunt_s4_budgets.cfg`: supporting core safety; time limit 6, receiver budgets 3, sliding transaction timeout 2, two receivers/refs. Budgets are enabled even when greater than transaction inactivity timeout. |
| S5 source lifetime, receipts and waiters | Per-invocation verdict and source snapshots; callback entry/return; release attempts; owner-guarded receipt; shutdown None; receipt expiry and second waiter; minimal strict caller barrier. | **Merged into both S3 hunts** for settlement effects/order. S4 additionally enables callback/compute errors, deletion, shutdown and forced-drain scheduling. CR-1/2/4 remain review topics. |

`MC.cfg` enables core safety and structural invariants, and lists all three scenario hypotheses commented out for convergence. Hunt cfgs enable target hypotheses and core safety, without the convergence-only structural block. Reactive steps have no fault counters. Ordinary requests are finite because the payload is fixed; counters bound injected exceptions, loss, deletion, shutdown and time advancement. Receiver symmetry is enabled. The display-only view is not enabled as a TLC state projection: different fault budgets change future reachability.

## Brief §5: actual invariant wiring

| Invariant | Definition and wiring | Enabled hunt cfgs |
|---|---|---|
| `TypeOK` (Safety) | Defined in `base.tla`, inherited by MC; types every field, matrix, cached value and program counter. `MCTypeOK` additionally types counters in `MC.cfg`. | All four hunts. |
| `SingleSettlementEffects` (Safety) | Counts each object's transaction_done, transaction callback, outcome callback and source release attempt at invocation. No entry-dedup assumption. | `MC_hunt_s3_settlement.cfg`. |
| `NoSettlementEffectsAfterReceipt` (Safety) | A persistent observer flag records a settlement hook entry after either waiter received a non-None outcome. | `MC_hunt_s3_after_receipt.cfg`. |
| `CompletedProgressHasReceiverSuccess` (Safety) | Delivered public source-progress COMPLETED implies winning receiver/ref SUCCESS. Does not substitute producer EOF or strict receipt for the progress observer. | `MC_hunt_s1_progress.cfg`. |
| `EventualSettlementObservation` (Conditional liveness) | `base.tla` / `FairSpec`: fair reactive action instances, runnable worker/monitor, returning callbacks, advancing time. `MCFairSpec` exposes the wrapper version. | Not enabled in finite safety cfgs; not a verified liveness result. Clock budgets and symmetry need a separately sized liveness configuration. |

Core assertions are `SingleReceipt`, `ConfirmedSuccess`, `OutcomeAggregation`, `ReceiptFollowsOwnCleanup`, and `CallerRequiresCompleted`. They do not restrict transitions. `FinalStatusesImmutable` records the transition-level property; status dedup follows implementation. Cleanup ordering applies to the invocation that records the receipt and does not assume the absence of another invocation.

## Brief §6.1: finding reachability

| Finding | Fault setup and enabling path | Expected target |
|---|---|---|
| MC-1 | Confirmation completes the fixed payload; helper retires; enqueue publishes task; one post-enqueue RuntimeError leaves it available; fallback and worker can both execute unrestricted cleanup steps. Worker may remain unscheduled until inline receipt publication. | `SingleSettlementEffects` in S3 settlement cfg; independently `NoSettlementEffectsAfterReceipt` in S3 after-receipt cfg. `SingleReceipt` remains core safety because receipt ownership still deduplicates. |
| MC-2 | DATA reply enables pipeline; admit next pull; one consume Exception sends cancellation; cancellation commits FAILED and pauses before its progress; EOF serve returns no nonce for already-final receiver; producer selects/delivers COMPLETED first. | `CompletedProgressHasReceiverSuccess` in S1 cfg. No arbitrary terminal notification or removed confirmation guard. |

These are source-grounded enabling paths, **not recorded TLC counterexamples**. No hunt has been run during generation. Synthetic schema tests are kept under `checks/` and are not implementation traces.

## User priority questions

1. **Served versus consumed:** produce/serve/reply, Consumer completion, confirmation and winning status are separate. Confirmed EOF is provisional. `ConfirmedSuccess` and strict outcome/caller assertions express the contract. Legacy/disabled confirmation uses producer-served truth (`download_service.py:204-216,369-390,1707-1709,1739-1749`) and is documented separately, not judged by this confirmed-mode model.
2. **Full payload/quorum:** explicit identities and the full matrix are base semantics. FINISHED includes failed receivers; `quorum_met` counts common successful receivers across every ref; `completed` requires all declared receivers. Count-only/unknown-count modes remain TV-3, and caller underdeclaration remains TV-1.
3. **Overlapping termination:** table retirement has one winner; admitted operations, finalizers, bounded drain, per-ref snapshots and settlement invocations remain separate. Receipt ownership does not imply single settlement entry.
4. **Clock scope:** requests update global activity, then ref activity, then the captured timestamp under the receiver stats lock. Accepted confirmation updates only global activity after callbacks. Other receivers cannot reset a receiver's budget snapshot. A selected timeout need not be undone by a later request. No absolute transaction-age limit is imposed.
5. **Callbacks/release/waiters:** hook Exceptions are independently contained; a failed release may keep the source. Successful release drops only the infrastructure reference. Non-None waiter resolution follows the recording invocation's cleanup attempts; outcome_cb precedes release; shutdown resolves None before cleanup. Previously resolved waiter values survive receipt expiry. The inspected `CellClientAPI` has a no-op source-progress callback and requires strict waiter COMPLETED (`api.py:481-487,624-648`), so MC-2 does not establish false trainer success.

## Explicit abstractions and remaining evidence

- One fixed transaction, registration order preserved, cooperative peers, known identities, confirmation enabled and configured callbacks. No late registration, reuse, adversarial identities, byte transports, serialization, trainer process lifecycle, HA or numerical behavior. Hook mutation/reentrancy and process-level BaseException are outside this slice.
- `ChunkCount` ordinary DATA units lead to EOF or ERROR. Producer exception, consume failure, receiver finalization failure and confirmation-send loss are represented. Data/terminal reply retry, retry nonce replacement, mixed peers, cancellation loss, repeated tombstone retry sequences and service restart are not. Retired-ref lookup, including a late first acquisition and the finished-ref TTL check, is represented. A Boolean nonce denotes the one accepted terminal nonce in this no-retry attempt, not cross-attempt nonce validation.
- Ref loops follow registration order; batched source progress follows dictionary insertion order. A complete status update/event-construction critical section stays atomic; unlocked user callbacks and source snapshots remain split. `is_finished` uses the monotone final-status predicate: a successful scan can linearize at its last check and an unsuccessful overlapping scan before the missing status commits. Instruction-level scan internals are not modeled.
- Budget candidates are processed lazily using the fixed transaction snapshot and current final map; freshness recheck and final dedup remain separate. An already-final candidate has no further user effect. Python set-iteration mechanics are abstracted.
- Source progress uses configured callback, interval zero, byte units and no item counters. Progress callback return and contained Exception share one return transition because neither changes modeled functional state; invocation remains separate. `TransferProgressTracker`'s counter-advancement clock is distinct from request activity and is not another modeled receiver timeout authority.
- Time is monotone and quantized. Monitor cadence is nondeterministic; captured `monitorNow` precedes budget callbacks and is reused for transaction classification. Configured drain duration is scaled to model time units, not a claim that production uses two seconds (source policy is 60 seconds). Forced drain permits later admitted-operation effects; no unconditional quiet-source/physical-GC assertion or bounded-shutdown promise is made.
- The source profile drops its infrastructure reference on successful release and may raise before dropping it. Default no-op Downloadable.release and arbitrary subclass side effects require a separately documented profile. Local/future/application references may retain the object regardless of this model's flag.
- Receipt expiry and a late waiter are modeled. Acquired-receiver query semantics at retirement (CR-2), exact retention APIs (CR-1), warning text (CR-3), and stale cacheable comments (CR-4) remain review items.
- Next: instrument the required boundaries, collect local implementation traces, check `TraceMatched` and captured post-state, converge, then hunt. TV-1/2/3 regressions were not run. Historical fixes and existing tests are context, not execution evidence.

## Generation checks performed

See `generation-report.md` and `checks/artifact-checks.json`: SANY, cfg/one-layer initialization checks, 94-action coverage wiring, and synthetic positive/negative post-state schema checks passed. These checks do not establish trace conformance, exhaustive safety, liveness or runtime confirmation.

## Phase 3 validation execution update — 2026-09-13

The generation-phase account above is preserved as its original evidence boundary. Phase 3 subsequently replayed all 16 implementation traces (3,029 events; 94 action names), completed the prescribed 30-minute `MC.cfg` check without a violation, and executed all four unchanged hunting cfgs. One budgeted convergence round required no model/invariant repair. S1 produced MC-2 (35-state progress contradiction); the two S3 cfgs produced MC-1 (77-state duplicate-effect and 94-state after-receipt counterexamples). S4 BFS reached reported depth 21 without a violation, so the required same-cfg depth-100, 30-minute simulation was run and also found no violation. Neither wide BFS run was exhaustive.

The detailed final per-cfg statistics and source mappings are in `bug-report.md`; all five priority questions, conditional liveness limits, runtime-confirmation limits and the unverified concurrent timestamp-publication question are in `validation-report.md`. Action-name conformance is not exhaustive branch/schedule coverage. No new budget-monotonicity or eventual-termination oracle was added, and `EventualSettlementObservation` remains unverified.
