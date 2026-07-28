# Modeling Brief: slatedb-dist-compaction

## 1. System Overview

- **System**: SlateDB distributed compaction coordination in `slatedb/slatedb`
- **Language / scale**: Rust, about 14.7k LOC across the audited core files plus RFC-0025
- **Category**: **Category A (Distributed / Message-Passing)** because correctness depends on coordination between a coordinator, multiple workers, shared durable metadata, and crash/recovery windows across separate persistent objects
- **Protocol**: SlateDB's distributed compaction coordination protocol
- **Key architectural choices**:
  - Shared state is split across two durable objects: `.manifest` and `.compactions`
  - Workers only claim, heartbeat, and publish `Compacted`; the coordinator alone publishes manifest-visible results
  - There is no cross-object transaction; durability is ordered as checkpoint -> manifest -> `.compactions`
  - Recovery intentionally allows `.compactions = Failed` even when the manifest already contains the compaction result
- **Concurrency model**: async Rust message loops with periodic tickers for the coordinator and workers, plus background compaction executor tasks

## 2. Bug Families

### Family 1: Split Admission Control for `Submitted` Compactions

**Mechanism**: The coordinator applies different admission checks depending on how a compaction becomes `Submitted`; externally inserted jobs bypass the in-memory conflict checks and promotion-time capacity checks used elsewhere.

**Evidence**:
- Historical: `#1838` (open as of July 21, 2026) - maintainer-confirmed bug: the coordinator should reject source/destination conflicts when moving `Submitted -> Scheduled`
- Historical: `PR #1926` - one accounting path already needed a fix because status handling was inconsistent across schedulers
- Code analysis: `slatedb/src/admin.rs:192`, `slatedb/src/compactor.rs:478` - admin/CLI submission writes directly to `.compactions`
- Code analysis: `slatedb/src/compactor_state.rs:988` - `add_compaction()` enforces destination collision checks and an explicit active-drain guard only for locally added compactions
- Code analysis: `slatedb/src/compactor.rs:1022`, `slatedb/src/compactor.rs:1130` - `validate_compaction()` explicitly does not re-run `add_compaction()` conflict checks except for same-segment L0 parallelism
- Code analysis: `slatedb/src/compactor.rs:1308` - `maybe_validate_submitted_compactions()` promotes every valid `Submitted` entry to `Scheduled` without applying a global capacity bound on that path
- Code analysis: `slatedb/src/compaction_worker.rs:304`, `slatedb/src/compaction_worker.rs:327` - each worker enforces capacity only locally, so multiple workers can claim multiple globally scheduled jobs

**Affected code paths**:
- `Admin::submit_compaction`
- `Compactor::submit`
- `CompactorState::add_compaction`
- `CompactorEventHandler::maybe_validate_submitted_compactions`
- `CompactorEventHandler::validate_compaction`
- `CompactionWorkerHandler::poll_and_claim`

**Suggested modeling approach**:
- **Variables**: `compactions`, `status`, `segment`, `sources`, `destination`, `submittedOrigin`, `maxConcurrent`, `workerLocalJobs`
- **Actions**: separate `SubmitExternal`, `ScheduleInternal`, and `ValidateSubmitted` actions; do not assume they share the same guards
- **Granularity**: split into at least three steps: durable submission, coordinator validation/promotion, worker claim

**Priority**: High
**Rationale**: This is a current maintainer-acknowledged bug family, directly safety-relevant, and small enough to model precisely.

### Family 2: Non-Atomic Shared-State Publication and Recovery-Safe Terminal Semantics

**Mechanism**: One logical compaction result becomes durable through multiple ordered writes to different objects, with crash possible between each write.

**Evidence**:
- Historical: `#604`, `#1044`, `PR #487` - GC could delete files before shared state durably protected them
- Historical: `#1192`, `PR #1194`, `PR #1212` - restart ordering around persisted compaction state repeatedly broke recovery
- Historical: `#1095`, `PR #1152` - manifest and `.compactions` epochs can diverge unless fencing explicitly couples them
- Code analysis: `slatedb/src/compactor_state_protocols.rs:93` - readers fetch `.compactions` before manifest
- Code analysis: `slatedb/src/compactor_state_protocols.rs:247`, `slatedb/src/compactor_state_protocols.rs:326` - writers persist checkpoint, then manifest, then `.compactions`
- Code analysis: `slatedb/src/compactor.rs:907`, `slatedb/src/compactor.rs:930` - `Compacted -> Completed/Failed` is coordinator-only and intentionally allows `Failed` after a manifest commit crash
- Code analysis: `slatedb/src/garbage_collector/compacted_gc.rs:200` - GC relies on compaction state being read before manifest to avoid deleting unpublished outputs

**Affected code paths**:
- `CompactorStateReader::read_view`
- `CompactorStateWriter::new`
- `CompactorStateWriter::write_manifest`
- `CompactorStateWriter::write_state_safely`
- `CompactorEventHandler::commit_compacted_entries`
- `CompactedGcTask::collect`

**Suggested modeling approach**:
- **Variables**: persistent `manifest`, persistent `compactions`, `checkpoints`, `sstFiles`, `gcVisible`
- **Actions**: split one logical commit into `WriteCheckpoint`, `WriteManifest`, `WriteCompactions`, plus `Crash` and `Recover`
- **Granularity**: crash should be possible between every durable write; recovery must allow `manifest` to reflect a compaction whose `.compactions` state later becomes `Failed`

**Priority**: High
**Rationale**: This is the densest historical bug family in the subsystem and the main correctness boundary for GC and crash recovery.

### Family 3: Independent Heartbeat / Reclaim / Ownership Control Loops

**Mechanism**: Worker execution, worker heartbeat publication, coordinator timeout-based reclaim, and executor shutdown all run on separate schedules and can observe different ownership states.

**Evidence**:
- Historical: `PR #1730`, `PR #1753`, `PR #1786` - the distributed worker/heartbeat/reclaim protocol required multiple follow-up fixes
- Historical: `#1850`, `PR #1856`, `#1862` - reclaiming timed-out work could panic or loop while the original execution was still active
- Code analysis: `slatedb/src/compactor.rs:790` - reclaim is driven by coordinator-local timeout checks
- Code analysis: `slatedb/src/compaction_worker.rs:377`, `slatedb/src/compaction_worker.rs:581`, `slatedb/src/compaction_worker.rs:742` - heartbeats and completion timestamps come from worker-local clocks
- Code analysis: `slatedb/src/compaction_worker.rs:610`, `slatedb/src/compaction_worker.rs:719`, `slatedb/src/compaction_worker.rs:805` - ownership checks use `worker_id`, not a per-claim nonce
- Code analysis: `slatedb/src/compaction_worker.rs:780`, `slatedb/src/compaction_worker.rs:827` - executor stop is asynchronous, and `handle_finished()` drops local bookkeeping before durable claim release/write

**Affected code paths**:
- `CompactorEventHandler::reclaim_stale_workers`
- `CompactionWorkerHandler::poll_and_claim`
- `CompactionWorkerHandler::heartbeat_owned_jobs`
- `CompactionWorkerHandler::write_compacted`
- `CompactionWorkerHandler::release_claim`
- `CompactionWorkerHandler::handle_finished`

**Suggested modeling approach**:
- **Variables**: `owner`, `lastHeartbeat`, `workerLocalJobs`, `timedOut`, optional `claimGeneration`
- **Actions**: `Claim`, `Heartbeat`, `Reclaim`, `StopLocalJob`, `FinishOldExecution`, `ReleaseClaim`
- **Granularity**: separate durable ownership from local executor state; use one coordinator and two workers

**Priority**: High
**Rationale**: This is the other major current bug family, with recent production-facing reports and clear state-machine interleavings.

### Family 4: Stale-State Merge, Fencing, and Post-Merge Invariant Repair

**Mechanism**: Writers and readers refresh `.manifest` and `.compactions` independently, then merge remote state into local state; stale remote views must be accepted in some cases and rejected in others.

**Evidence**:
- Historical: `#352` - stale updater can write behind a GC tail after missing intermediate versions
- Historical: `#877`, `#1095`, `PR #1152` - explicit epoch coupling between `.manifest` and `.compactions` was needed
- Historical: `PR #1840` - merge logic had to accept stale `Compacted`/terminal entries after CAS conflicts
- Historical: `PR #1836`, `#1935`, `#779` - post-merge state needed additional invariant repair or version-skew handling
- Code analysis: `slatedb/src/compactor_state_protocols.rs:177` - fencing initializes `.compactions` from the manifest epoch
- Code analysis: `slatedb/src/manifest/store.rs:52` - manifest fencing and compactor fencing are separate entry points
- Code analysis: `slatedb/src/compactor_state.rs:882`, `slatedb/src/compactor_state.rs:951` - coordinator merges remote compactions and remote manifest independently

**Affected code paths**:
- `CompactorStateWriter::fence`
- `FenceableManifest::init_compactor`
- `CompactorStateWriter::load_compactions`
- `CompactorStateWriter::load_manifest`
- `CompactorState::merge_remote_compactions`
- `CompactorState::merge_remote_manifest`

**Suggested modeling approach**:
- **Variables**: `manifestEpoch`, `compactionsEpoch`, per-object `version`, `localView`, `durableView`
- **Actions**: `RefreshCompactions`, `RefreshManifest`, `MergeRemoteCompactions`, `MergeRemoteManifest`, `FencedWrite`
- **Granularity**: abstract manifest contents to just the fields needed for reachability and conflict reasoning

**Priority**: Medium
**Rationale**: This family is bug-dense, but modeling it usefully requires careful abstraction to avoid state explosion.

### Family 5: Fragmented Concurrent-Compaction Accounting

**Mechanism**: Capacity is enforced by several partially independent mechanisms: size-tiered proposal budgeting, coordinator-side `Running` counts, `Submitted -> Scheduled` promotion, and worker-local claim limits.

**Evidence**:
- Historical: `PR #1926` - `Compacted` incorrectly consumed scheduler slots until July 14, 2026
- Code analysis: `slatedb/src/compactor.rs:1239`, `slatedb/src/compactor.rs:1428` - coordinator scheduling only counts `Running`
- Code analysis: `slatedb/src/compactor.rs:1308` - externally submitted compactions are promoted to `Scheduled` with no capacity gate
- Code analysis: `slatedb/src/compaction_worker.rs:304` - workers enforce capacity only per worker process
- Code analysis: `slatedb/src/size_tiered_compaction.rs:188`, `slatedb/src/size_tiered_compaction.rs:246` - the default scheduler self-budgets differently from the coordinator event loop

**Affected code paths**:
- `CompactorEventHandler::maybe_schedule_compactions`
- `CompactorEventHandler::maybe_validate_submitted_compactions`
- `CompactorEventHandler::running_compaction_count`
- `CompactionWorkerHandler::capacity`
- `SizeTieredCompactionScheduler::propose`

**Suggested modeling approach**:
- **Variables**: `maxConcurrent`, `scheduled`, `running`, `workerLocalJobs`
- **Actions**: allow manual `Submitted` backlog plus multiple workers claiming from the same globally scheduled set
- **Granularity**: model capacity as a protocol property, not only a scheduler heuristic

**Priority**: Medium
**Rationale**: The family is narrower than the publication/reclaim families, but the user explicitly wants concurrency-bound invariants and the current enforcement is visibly fragmented.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Separate durable `.manifest` and `.compactions` | Family 2 is defined by split persistence and recovery gaps | Two persistent objects with separate versions and epochs |
| External/manual `Submitted` path | Family 1 is current and maintainer-acknowledged | Separate `SubmitExternal` and `ValidateSubmitted` actions |
| Worker ownership, heartbeat, and reclaim | Family 3 repeatedly broke in production | Distinguish durable owner state from worker-local executor state |
| Crash/recovery between checkpoint, manifest, and `.compactions` writes | Family 2 depends on those windows | Split logical commit into multiple durable-write actions plus `Crash` |
| Fence/refresh/merge ordering | Family 4 depends on stale/local-vs-remote divergence | Add per-object versions, epochs, and refresh/merge actions |
| Global compaction-capacity bound | Family 5 is a target invariant in this case | Track global max separately from per-worker local capacity |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| SST merge internals, compression, iterators, bloom filters | Out of scope for this case and not part of the coordination bug families |
| `.compactions` file GC housekeeping (`#1127`, `PR #1129`) | Operational cleanup only; not a coordination-safety mechanism |
| Perf-only heartbeat write-rate tuning (`#879`) | Performance concern, not protocol safety |
| Assert-style helper defects by themselves | Better handled by tests/code review than TLA+ |
| General manifest format/version-skew details beyond fields used by compaction coordination | Too broad unless needed for the specific stale-merge invariant being checked |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Split persistent state | `manifest`, `compactions`, `manifestVer`, `compactionsVer` | Represent non-atomic cross-object publication | 2 |
| Crash/recovery windows | `checkpoints`, `sstFiles` | Allow crash between checkpoint, manifest, and `.compactions` writes | 2 |
| External submission path | `submittedOrigin`, `status`, `destination`, `segment` | Model the admission path that bypasses local conflict checks | 1 |
| Ownership lease / reclaim | `owner`, `lastHeartbeat`, `workerLocalJobs`, `timedOut` | Model stale reclaim and duplicate execution risk | 3 |
| Epoch / merge state | `manifestEpoch`, `compactionsEpoch`, `localView` | Model stale refresh and fenced writes | 4 |
| Capacity accounting | `maxConcurrent` | Check global bound under manual backlog and multiple workers | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SinglePublishPerCompaction | Safety | One logical compaction cannot durably change the live manifest twice | 1, 2 |
| NoConflictingActiveCompactions | Safety | No two active compactions reserve the same destination or otherwise violate coordinator conflict rules | 1 |
| BoundedRunningClaims | Safety | Total worker-owned running jobs never exceeds the configured bound | 1, 3, 5 |
| OnlyCurrentOwnerPublishes | Safety | A stale worker execution cannot publish after ownership has moved | 3 |
| ManifestReferencesExistingFiles | Safety | Every SST reachable from the live manifest or checkpoints still exists | 2, 4 |
| NoPrematureReclaim | Safety | Source or output SSTs are not deleted while still needed by live state or in-flight publication | 2, 4 |
| RecoverySafeTerminalRelation | Safety | If the manifest already reflects a compaction, later `.compactions = Failed` does not make it reschedulable or GC-unsafe | 2 |
| FencedWriterCannotOverwriteFreshState | Safety | A stale epoch/version holder cannot successfully overwrite the current durable state | 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Can externally submitted compactions that bypass `add_compaction()` both reach `Scheduled` even when they conflict on destination or active-drain rules? | `NoConflictingActiveCompactions`, `SinglePublishPerCompaction` | 1 |
| MC2 | Can multiple externally submitted valid compactions exceed the configured global bound because `Submitted -> Scheduled` has no capacity gate and workers budget locally? | `BoundedRunningClaims` | 1, 5 |
| MC3 | After reclaim of a still-running job, can an old execution from the same worker still publish because ownership is keyed only by `worker_id` and not by claim generation? | `OnlyCurrentOwnerPublishes`, `BoundedRunningClaims` | 3 |
| MC4 | Can crash after manifest publication but before `.compactions` terminal update lead to a later reschedule, duplicate publish, or unsafe reclaim? | `SinglePublishPerCompaction`, `NoPrematureReclaim`, `RecoverySafeTerminalRelation` | 2 |
| MC5 | Can split refresh/merge of stale manifest and stale `.compactions` views still reintroduce metadata that should have been pruned or fenced away? | `FencedWriterCannotOverwriteFreshState`, `ManifestReferencesExistingFiles` | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| TV1 | `maybe_schedule_compactions()` uses `.count()` over a `Result`-producing iterator, so failed `add_compaction()` attempts are silently dropped | Unit test with a scheduler that proposes conflicting specs |
| TV2 | `handle_finished()` removes `job_progress` before `write_compacted()` or `release_claim()` succeeds | Inject non-conflict store failures after local completion bookkeeping |
| TV3 | Post-claim invalid specs are released back to `Scheduled`, not `Submitted`, which can create claim/release thrash | Integration test with stale manifest + repeated worker polls |
| TV4 | `available_capacity = max - running` can underflow if `Running` already exceeds the configured bound | Unit test with handcrafted `Running > max` coordinator state |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `CompactorState::add_compaction()` overwrites duplicate compaction ids instead of rejecting them | Add explicit duplicate-id guard |
| CR2 | `retain_active_and_last_finished()` keeps the max ULID, not the most recently completed job by finish time | Clarify intent or store completion recency explicitly |
| CR3 | `CompactionContext` update validation uses `assert!` / `assert_eq!` on persisted state transitions | Convert to recoverable protocol errors if malformed state should be tolerated |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/analysis-report.md`
- **Key source files**:
  - `slatedb/src/compactor.rs`
  - `slatedb/src/compactor_state.rs`
  - `slatedb/src/compactor_state_protocols.rs`
  - `slatedb/src/compaction_worker.rs`
  - `slatedb/src/manifest/store.rs`
  - `slatedb/src/garbage_collector/compacted_gc.rs`
- **Key history**:
  - Publication / GC / recovery: `#604`, `#1044`, `PR #487`, `#1192`, `PR #1194`, `PR #1212`
  - Reclaim / duplicate execution / capacity: `#1838`, `#1850`, `PR #1856`, `#1862`, `PR #1926`
  - Fencing / stale merge / invariant repair: `#352`, `#877`, `PR #1152`, `PR #1840`, `PR #1836`, `#1935`
- **Reference intent**: `rfcs/0025-distributed-compaction.md`
