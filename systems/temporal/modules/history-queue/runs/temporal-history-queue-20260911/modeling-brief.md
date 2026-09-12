# Modeling Brief: temporal-history-queue

## 1. System Overview

- **System/category**: Temporal History immediate Transfer queue; Go 1.27; **Category A (Distributed / Message-Passing)** because SQL commit, RPC acceptance, crash recovery and shard ownership cross independent execution domains. No Byzantine model.
- **Revision**: `temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; 41 explicitly audited current core files, 16,720 LOC; inventory in `evidence/core-file-inventory.json`.
- **Boundary**: one cluster, one History shard, ordinary Workflow/Activity Transfer tasks, two namespace groups and two readers; Matching is an acceptance/start/discard interface.
- **Backend**: Temporal SQL with real file-backed SQLite/WAL; focused store probes use synchronous FULL. Backend guarantees are from SQL/plugin source and independent readback, not an assumed memory store.
- **Algorithm**: transactional outbox with exclusive read watermark, predicate-bearing slices, volatile executable ACK, separate prefix deletion and batched shard checkpoint (`queue_base.go:262-411`; `sql/execution.go:334-443`).
- **Concurrency**: workflow/shard locks and SQL transactions; one queue event loop; independent reader and executor goroutines. Store snapshots may finish out of order within one RangeID (`shard/context_impl.go:1228-1304`).
- **Current result**: CR-1 is a source-discovered, native SQLite-reproduced live-reader stall; work remains durable and reconstruction recovers it. No model checking or trace validation has run; discovery/reconfirmation counts are both **0**.
- Source paths below are relative to the repository; unqualified queue files mean `service/history/queues/`, `shard/` means `service/history/shard/`, `sql/` means `common/persistence/sql/`, and `api/` means `service/history/api/`.

## 2. Scenarios

### Scenario 1: Uncertain publication versus read eligibility

**Mechanism**: allocation, backend commit and observed completion advance different frontiers; a delayed writer must not insert required work below an already retired read boundary.
**Evidence**:
- Historical: publication commit and predecessor ledgers document task-key/range-error repairs; retain fixed behavior as context, never revert it as an adversary.
- Code analysis: `shard/task_key_manager.go:45-53,88-118`, `shard/task_request_tracker.go:36-89`, `shard/context_impl.go:1501-1548,2030-2149` retain uncertain pending keys and reacquire ownership; workflow task+state mutation is atomic (`sql/execution.go:360-443`).
- Native evidence: actual `ExecuteAndTimeout` committed task9 while watermark stayed9; range renewal to2 exposed16 and rejected delayed old task10 (`evidence/publication-real-store-final.log`).
**Affected code paths**: workflow transaction create/update, key allocation/tracking, SQL commit, notification, read watermark, range renewal, full shard reconstruction.
**Suggested modeling approach**: variables `rows`, `workflowState`, `allocated`, `pendingWrites`, `rpcInflight`, `durableRange`, `ownerRange`, `notify`; distinguish unknown result from definitely failed write.
**Actions/granularity**: allocate/register under shard lock; one atomic logical SQL mutation; split commit from reply; notification is a hint; range renewal fences delayed writers before pending reset. Keep earlier history-node append separate from logical commit.
**Priority**: High. **Rationale**: required Q1 and prerequisite for every checkpoint safety claim; isolated protections passed, coupled failure schedules remain unverified.

### Scenario 2: Logical scope survives but the live reader cursor disappears

**Mechanism**: scope ownership and executable completion are updated while the reader retains a pointer to a removable list element.
**Evidence**:
- Historical: [#11353](https://github.com/temporalio/temporal/pull/11353) fixes a distinct list-tail race; [#11253](https://github.com/temporalio/temporal/pull/11253) fixes escaped pending-stat maps. Both are already fixed at the pin.
- Code analysis: `reader.go:350-369` removes empty slices without resetting `nextReadSlice`; `:454-480` later follows the removed element. Full-batch exit leaves an exhausted iterator present (`slice.go:366-418`); ACK permits empty-range shrink (`:307-332`).
- CR-1: real move-group preparation and SQLite checkpointing reproduce the stall at batch100. Later Activity row and durable reader scope survive; repeated poll/checkpoint/Notify do not repair reader1; reconstruction does (`evidence/reader-slice-audit.md`, checkpoint evidence).
**Affected code paths**: SelectTasks, Ack, ShrinkScope/ShrinkSlices, next-reader traversal, move-group, Clear, predicate split/merge/compaction, checkpoint and reload.
**Suggested modeling approach**: variables `readerLists`, `sliceIdentity`, `cursor`, `iteratorRanges`, `trackedExecutables`, `execState`, `scopePredicates`; retain structural cursor membership alongside logical obligation coverage.
**Actions/granularity**: a reader batch is atomic under its mutex; ACKs interleave between batches; checkpoint shrinking is separate. Queue event-loop moves cannot interleave with another checkpoint, while reader/executor turns can run between reader locks.
**Priority**: High. **Rationale**: Q2/Q5 include a confirmed live-progress defect that a scope-set-only model would assume away; explore whether additional split/clear/reload interactions have distinct consequences.

### Scenario 3: Deletion receipt, volatile checkpoint and durable checkpoint diverge

**Mechanism**: prefix deletion and shard metadata are separate writes, and successful SetQueueState can update only memory.
**Evidence**:
- Historical/design: [#5399](https://github.com/temporalio/temporal/pull/5399) deliberately batches shard updates; queue comment explicitly requires delete-before-state (`queue_base.go:340-342`).
- Code analysis: `queue_base.go:295-361,373-411` computes minimum retained scope, deletes first, then updates state; `shard/context_impl.go:1228-1304` snapshots outside-store-I/O and may throttle persistence.
- Native evidence: healthy, delete-then-lost-reply, and batched-state-lag schedules preserve unfinished SQLite row2 and recover from durable minima1 or2; deleting the old prefix again is safe.
**Affected code paths**: checkpoint, rangeCompleteTasks, SetQueueState/updateShardInfo, unrelated shard snapshot writers, newQueueBase reconstruction.
**Suggested modeling approach**: variables `deleteRequest`, `deleteReceipt`, `memoryDeleteMin`, `memoryQueueState`, `durableQueueState`, `pendingShardSnapshots`; do not require durable checkpoint monotonicity within an epoch.
**Actions/granularity**: split DELETE commit/reply, queue memory update, actual fenced shard write/reply, and reconstruction. Preserve actual SQL immediate prefix predicate; never persist a future checkpoint before the implementation permits it.
**Priority**: High. **Rationale**: Q3 asks both retained-obligation safety and cleanup progress; neither API nil nor a lagging checkpoint alone decides either property.

### Scenario 4: An old owner can finish effects after durable ownership changes

**Mechanism**: SQL ownership fencing does not cancel already-started readers, Matching calls, or DLQ enqueue operations.
**Evidence**:
- Code analysis: `executable.go:273-298,402,724-772` separates execution from state lock; old ACK affects only its wrapper. SQL task writes and UpdateShard check RangeID; immediate DELETE and Matching/DLQ RPCs do not (`sql/execution_tasks.go:17-31,361-372`; `sql/shard.go:82-174`).
- Adjacent open [#12016](https://github.com/temporalio/temporal/pull/12016) characterizes **scheduled** cleanup erasing successor timers; it is excluded here because successor immediate task IDs occupy a higher allocation range.
- Native immediate control: stale writer/checkpoint rejected; late predecessor DELETE removes old rows8,9 but preserves successor16, independently read after the Go process exits.
**Affected code paths**: range acquisition, late read/execute, Cancel/Ack, Matching Add and Record*Started, late checkpoint, immediate prefix deletion.
**Suggested modeling approach**: two owner instances with separate volatile readers/executables and a durable RangeID; allow old RPC results after handoff.
**Actions/granularity**: ownership is not a global cancellation action. Fence only actual SQL writes; callbacks validate workflow identity/stamp/state. An old comparable vector clock is not automatically rejected (`api/consistency_checker.go:177-238`).
**Priority**: High. **Rationale**: Q4 must compose fencing with idempotency, publication and retained scopes, rather than assume all old-owner effects stop.

### Scenario 5: ACK discharges a transport obligation under a specific downstream contract

**Mechanism**: successful dispatch, obsolete work, terminal discard and durable DLQ transfer share local ACK but differ in business progress.
**Evidence**:
- Code analysis: ordinary eligibility in `service/history/transfer_queue_active_task_executor.go:250-396`; complete disposition in `executable.go:451-688`; DLQ acceptance in `dlq_writer.go:63-103` and `sql/queue_v2.go:45-113`.
- Matching normal spool waits for durable CreateTasks; sync match waits for History start result, but terminal Internal/DataLoss/stale drops can also return nil (`service/matching/matching_engine.go:810-864,1037-1108`; `task.go:373-403`).
- Known reports [#11402](https://github.com/temporalio/temporal/issues/11402)/open [#11403](https://github.com/temporalio/temporal/pull/11403) already discuss business stalls after DLQ transfer; do not hunt the documented operator-replay limitation as a new defect.
**Affected code paths**: executor eligibility, downstream commit/reply, retry/rescheduler, terminal error classification, DLQ commit/reply, ACK and later checkpoint.
**Suggested modeling approach**: separate `workflowNeedsTask`, `matchingDurable`, `started`, `obsolete`, `terminalDiscard`, `dlqRows`, `acked`, and worker completion; duplicate delivery is allowed.
**Actions/granularity**: downstream effect and reply are separate; DLQ commit and observed success separate; ACK only after actual classification. Do not hide terminal-discard outcomes under an unconditional acceptance contract.
**Priority**: High. **Rationale**: Q5 cannot be answered by task ACK counts; native DLQ lost replies preserve Pending and can create durable duplicate entries, while a separate real Workflow/Activity healthy execution completes.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Durable workflow state plus Transfer row publication | S1; required work must originate in a real atomic mutation | One SQL commit action, independent unknown reply |
| Pending allocation minimum and RangeID renewal | S1/S4; late writers determine safe read frontier | Two epochs, per-request keys, delayed admission/commit outcomes |
| Reader cursor plus scope/predicate bookkeeping | S2; otherwise CR-1 is unrepresentable | Ordered slice identities, batch-end cursor and ACK state |
| Retry, cancellation, clear and movement | S2/S4; old execution may finish after ownership/movement | Per-wrapper status and retained row/scope obligation |
| Separate deletion and memory/durable queue snapshots | S3; nil SetQueueState is not durable confirmation | Explicit snapshot requests, store outcomes and reload |
| Matching and DLQ responsibility endpoints | S4/S5; transport ACK differs from completed workflow | Explicit durable acceptance, start, justified stale/terminal drop |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Matching backlog algorithms, replication, timer scheduling, visibility, archival, CHASM migration | Explicit primary boundary; retain only proven interface contracts |
| Reverting historical fixes or replaying known DLQ/operator limitations | No new system information; historical evidence stays in Scenarios/References |
| Whole workflow language, payload serialization bytes, metrics implementation and SQL driver internals | Preserve outcome contracts; use native tests/audit for lower-level details |
| Automatic healthy-shard reload as a fairness shortcut | It would mask CR-1 and add a recovery mechanism that does not run unconditionally |
| Exact-once task delivery, completed-workflow-on-Add-success, globally disjoint reader predicates | These are not implementation guarantees; duplicates, widening and terminal outcomes exist |
| Dynamic queue-category removal or multiple persistence backends in one baseline | Changes proof contract; keep SQLite assumptions explicit and extend separately |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Transactional publication and unknown reply | `rows, workflowState, pendingWrites, rpcInflight` | Prevent invented split commits or definite-timeout assumptions | 1 |
| Owner epochs and late calls | `durableRange, ownerRange, outstandingCalls` | Fence only implementation-fenced operations | 1,4 |
| Structural reader progress | `readerLists, cursor, iteratorRanges, trackedExecutables` | Separate live cursor accessibility from durable scope coverage | 2 |
| Predicate-bearing scope transformations | `scopePredicates, sliceIdentity, execState` | Follow unfinished work through split/merge/clear/widen | 2,3 |
| Independent checkpoint persistence | `memoryQueueState, durableQueueState, pendingShardSnapshots, memoryDeleteMin` | Capture lag, reorder, loss of reply and reconstruction | 3,4 |
| Responsibility endpoints | `matchingDurable, started, obsolete, terminalDiscard, dlqRows, acked` | Preserve actual delivery/drop/replay contract | 4,5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| AtomicPublication | Safety | Accepted workflow mutation includes every generated Transfer row; no task-only half-commit | 1 |
| SafeReadFrontier | Safety | No still-admissible unresolved publication can commit below a retired read boundary | 1,4 |
| UnfinishedObligationCovered | Safety | Required work remains recoverable via durable row+queue coverage or actual durable downstream/DLQ responsibility | 1–5 |
| SafeImmediateDeletion | Safety | Deleted original rows have no unsatisfied responsibility unless an independently durable replacement exists | 3–5 |
| CurrentEpochWrites | Safety | Successful protected mutation/update has the required durable RangeID at its atomic store point | 1,4 |
| LiveCursorSoundness | Safety/progress diagnostic | Cursor is attached to the current list; nil cannot abandon unread scopes without a real pending reset path | 2; CR-1 already demonstrates a violation |
| RecoverableScopeCoverage | Safety | Durable checkpoint reconstruction covers each unresolved row it has read past | 2,3 |
| EligibleDispatchProgress | Liveness | Under stated stable ownership/fairness/finite failures, eligible work reaches accepted start/spool or explicit durable DLQ; terminal drops are separate assumptions | 2,4,5 |
| EventualCleanup | Liveness | With stable ownership and finite store failures, permanently completed prefix rows are eventually physically deleted | 3,4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if adverse | Scenario |
|---|---|---|---|
| MC-1 | Can unknown publication, an already-running checkpoint and range reacquisition compose to retire a key before its admissible write is resolved? | SafeReadFrontier / UnfinishedObligationCovered | 1,3,4 |
| MC-2 | Can overlap/widening, partial batch completion, Clear/cancel and reader movement lose durable coverage or strand a different obligation beyond the already-reproduced cursor schedule? | RecoverableScopeCoverage / EligibleDispatchProgress | 2,3 |
| MC-3 | Can reordered same-epoch snapshots, lost DELETE/update replies and one ownership replacement create an unfinished-row skip or a permanently uncleanable completed prefix? | SafeImmediateDeletion / EventualCleanup | 3,4 |
| MC-4 | Can accepted-but-unacknowledged Matching/DLQ effects plus late cancellation/owner reload and scope transforms lose every valid responsibility representation? | UnfinishedObligationCovered | 2,4,5 |

These are current-code composition questions, not recreated closed bugs. CR-1 is source/native evidence and a model-fidelity negative control; reconfirming it adds no MC-first discovery. Report distinct new schedules/consequences separately from reconfirmation.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 / CR-1 | Native cursor stall confirmed; full-engine eligible Workflow/Activity impact remains unproved | Run real dispatch with a hook between full batch ACK and next read; establish reader1 movement, row/scope readback, absent submission, healthy schedule and actual reload recovery |
| TV-2 / CR-2 | Duplicate-key tracker merge increments group statistics despite map overwrite | Generate widened overlapping reload scopes, load duplicate keys, merge and ACK; inspect actual counts and mitigation consequences (`tracker.go:58-107`) |
| TV-3 | Actual workflow transaction uncertain reply and full History Context reacquisition | Reuse testcore/store fault injection; observe atomic state+task readback, blocked watermark, new RangeID and dispatch after lost notification |
| TV-4 | Checkpoint write definite failure versus committed-but-timeout | Inject at real UpdateShard while deletion is separately observed; independently read durable snapshots and reconstruct both outcomes |

### 6.3 Code-Review-Only

| ID | Observation | Suggested action |
|---|---|---|
| CR-2 | Group counts may exceed retained executable keys after duplicate overlap merge; no user-visible defect established | Audit whether mitigation assumes exact counts; preserve duplicates and empty-range compensation |
| CR-3 | updateShardInfo resets batching bookkeeping before semaphore acquisition; acquisition failure bypasses store-error restoration (`shard/context_impl.go:1252-1295`) | Check delayed retry impact under finite contention; retain as low-impact observation, not a dedicated MC hunt |

## 7. Reference Pointers

- Primary audit: `analysis-report.md`; complete source, per-commit/per-thread classifications, test commands, raw outputs and corrected observation provenance under `evidence/`.
- Reader lead: `evidence/reader-slice-audit.md`; `reader.go:350-369,438-505`; `slice.go:307-418`; `queue_base.go:295-411`; native diagnostic test sources retained beside reports.
- Publication: `evidence/publication-persistence.md`; shard task manager/tracker; `sql/execution.go:334-443`, `sql/common.go:52-80`, `sql/shard.go:82-174`.
- Executor/interface: `evidence/executor-contract.md`; ordinary Transfer executor `:250-396`; `executable.go:451-802`; Matching Add/start/terminal-discard paths and SQL QueueV2.
- Reference algorithm comparison: pinned `docs/architecture/history-service.md:260-322` describes the transactional outbox; no canonical external TLA+ spec was supplied. [#11570](https://github.com/temporalio/temporal/pull/11570) reports prior internal TLA+ use for a different Matching reader, so a generic queue model is not itself novel.
- Progress assumptions: eventually stable shard ownership; finite eligible task population or fair service under load; positive reader/scheduler capacity; eventual store/RPC responses; finite transient failures; live worker for execution. DLQ business progress additionally needs operator replay; terminal start errors need justified terminality or an explicit recovery action.
- Defaults to preserve: Transfer batch100/readers2; move-group base500/multiplier3; predicate limit10KiB/shrink keys10; poll1min/checkpoint30s with0.15 jitter; shard persistence5min/1000 completed tasks; DLQ enabled/unexpected budget70 (`common/dynamicconfig/constants.go:2054-2114,2263-2326,2674-2690,2949-2971`). Test overrides are listed in the audit.
- Bounded exploration proposal: begin with2 epochs,2 readers,2 namespace groups and3–4 task identities; represent full-batch exhaustion explicitly. Run isolated contract checks, then publication+checkpoint, cursor+movement+reload, and late-effect+DLQ compositions. Preserve incomplete searches as INCOMPLETE; smaller runs do not prove the uncompleted cross-product.
- Trace handoff: instrument actual allocation/pending minima, SQL commit/readback, reader list/cursor/iterator+tracker, executor result/classification, durable QueueState and post-reconstruction endpoints. Keep observations independent of model-predicted values. Negative controls must reject false ACK, omitted pending row, wrong predicate/cursor and false durable checkpoint. No complete model-state traces or negative-control validation exist yet.
