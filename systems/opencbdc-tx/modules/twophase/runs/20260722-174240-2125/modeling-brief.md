# Modeling Brief: mit-dci/opencbdc-tx (2PC Architecture)

## 1. System Overview

- **System**: OpenCBDC Transaction Processor — 2PC (Two-Phase Commit) Architecture
- **Language**: C++20, ~4500 LOC core 2PC logic (coordinator + locking shard + sentinel)
- **Protocol**: Two-phase commit with conservative two-phase locking (C2PL), using Raft (via NuRaft) for coordinator and locking shard fault tolerance
- **Category**: **Category A (Distributed / Message-Passing)** — network RPC between sentinel, coordinator, and locking shards; Raft consensus for replication; protocol state machines for 2PC phases
- **Key architectural choices**:
  - Coordinator batches transactions before executing 2PC; each batch is a single distributed transaction (dtx)
  - Coordinator RSM tracks dtx phase transitions (prepare → commit → discard → done) through Raft replication
  - Locking shard is in-memory only (`/warning Not thread safe`); no persistence
  - Snapshots disabled in both coordinator and locking shard Raft instances (`snapshot_distance_ = 0`)
  - Coordinator uses a custom thread pool with yield-based scheduling, not a condition variable
- **Concurrency model**: Multiple threads: Raft ASIO threads, batch executor thread, dtx executor thread pool, sentinel handler thread, shard RPC handler threads. Shared-memory concurrency with mutexes and shared_mutexes.

## 2. Bug Families

### Family 1: Leader/Follower Asymmetry in Message Handler Lifecycle (HIGH)

**Mechanism**: Coordinator and locking shard use different patterns for managing message handlers during Raft leadership changes, creating windows where messages are accepted by a non-leader or missed during transitions.

**Evidence**:
- Historical: `86b4118` — Retry sentinel startup on failure (acknowledges startup race)
- Historical: `c0b65a8` — Check preconditions for coordinator controller init
- Code analysis: `coordinator/controller.cpp:112-144` — raft_callback sets flags, start/stop deferred to separate thread
- Code analysis: `locking_shard/controller.cpp:114-132` — raft_callback starts/stops RPC server directly (different pattern)
- Code analysis: `coordinator/controller.cpp:688` — `execute_transaction()` checks `is_leader()` but not synchronized with `start_stop_func()`

**Affected code paths**:
- `coordinator::controller::raft_callback()` (controller.cpp:112-144)
- `coordinator::controller::start_stop_func()` (controller.cpp:536-583)
- `coordinator::controller::execute_transaction()` (controller.cpp:684-731)
- `locking_shard::controller::raft_callback()` (controller.cpp:114-132)

**Suggested modeling approach**:
- Variables: `isLeader [Node -> BOOLEAN]`, `serverRunning [Node -> BOOLEAN]`
- Actions: Split `BecomeLeader`/`BecomeFollower` into notification and actual start/stop
- Model the gap between Raft leader state and message handler being active
- Add `ClientRequest` action that checks handler status, not just leader status

**Priority**: High
**Rationale**: Directly affects correctness of the 2PC protocol when leadership changes; inconsistent coordinator/locking-shard patterns create race windows.

---

### Family 2: Non-Atomic Coordinator State Machine Transitions (HIGH)

**Mechanism**: The coordinator's RSM state transitions (prepare/commit/discard/done) are not atomic with the actual locking shard operations. Between RSM replication and shard operation completion, state divergence can occur. If the leader crashes mid-phase, the new leader recovers from RSM state but may re-issue operations to shards that partially completed.

**Evidence**:
- Code analysis: `distributed_tx.cpp:109-145` — execute() transitions through prepare→commit→discard sequentially
- Code analysis: `distributed_tx.cpp:24-30` — prepare_cb called *before* shard lock operations
- Code analysis: `coordinator/controller.cpp:219-329` — recovery_func() reconstructs dtxs from RSM state and re-executes
- Code analysis: `locking_shard.cpp:142-147` — apply_outputs calls `fatal` if dtx_id not found (non-idempotent)
- Code analysis: `locking_shard.cpp:15-22` — discard_dtx removes from m_applied_dtxs

**Affected code paths**:
- `distributed_tx::execute()` (distributed_tx.cpp:109-145)
- `distributed_tx::prepare()` (distributed_tx.cpp:23-70)
- `distributed_tx::commit()` (distributed_tx.cpp:72-107)
- `distributed_tx::discard()` (distributed_tx.cpp:180-216)
- `coordinator::controller::recovery_func()` (controller.cpp:219-329)

**Suggested modeling approach**:
- Variables: `rsmState [DtxId -> {prepare,commit,discard,done}]`, `shardState [DtxId -> {none,locked,applied,discarded}]`
- Actions: Split each 2PC phase into RSM replication action + shard operation action
- Add `Crash` and `Recover` actions: crash resets volatile state, recover re-reads from rsmState and re-issues operations
- Model the locking shard's in-memory nature (crash = all shard state lost)

**Priority**: High
**Rationale**: Crash between RSM commit and shard operation is the classic 2PC failure scenario. The RSM-based recovery must handle partially-executed shard operations. Current code has fatal errors for unexpected states, not graceful recovery.

---

### Family 3: Sentinel-to-Coordinator Communication Gaps (MEDIUM)

**Mechanism**: Sentinels have no Raft leader discovery mechanism. They connect via static modulo-based endpoint selection and retry infinitely on failure, creating potential for message loss and unbounded retry loops.

**Evidence**:
- Historical: #167 — Sentinels fail to start coordinator client
- Historical: `86b4118` — Retry sentinel startup on failure
- Historical: `11f34eb` — Fix non-existent element access in sentinel distribution
- Code analysis: `sentinel_2pc/controller.cpp:21-25` — coordinator endpoint selected by `sentinel_id % coordinators.size()`
- Code analysis: `sentinel_2pc/controller.cpp:219-226` — infinite retry with `while(!m_coordinator_client.execute_transaction(...))`
- Code analysis: `sentinel_2pc/controller.cpp:217-218` — TODO: add retry error response

**Affected code paths**:
- `sentinel_2pc::controller::execute_transaction()` (controller.cpp:98-125)
- `sentinel_2pc::controller::send_compact_tx()` (controller.cpp:210-227)
- `coordinator::rpc::client::execute_transaction()` (client.cpp:19-22)

**Suggested modeling approach**:
- Variables: `coordinatorLeader [CoordinatorId -> BOOLEAN]`, `sentinelRequestQueue`, `pendingTxs`
- Actions: Model sentinel sending to non-leader (request dropped), retry with backoff
- Abstract infinite retry as bounded retry with potential message loss

**Priority**: Medium
**Rationale**: No known production incidents, but the infinite retry pattern and lack of leader discovery are acknowledged gaps. Suitable for liveness analysis.

---

### Family 4: No Snapshots / Unbounded Raft Log Growth (MEDIUM)

**Mechanism**: Both coordinator and locking shard disable Raft snapshots. Raft logs grow unbounded, and recovery from a long-running system requires replaying the entire log. Combined with the in-memory locking shard, crash recovery becomes increasingly expensive over time.

**Evidence**:
- Code analysis: `coordinator/controller.cpp:37` — `snapshot_distance_ = 0; // TODO: implement snapshots`
- Code analysis: `locking_shard/controller.cpp:46` — `snapshot_distance_ = 0; // TODO: implement snapshots`
- Code analysis: `coordinator/state_machine.cpp:102` — `// TODO: implement snapshots (cf. #768)`
- Code analysis: `locking_shard/state_machine.cpp:57` — `apply_snapshot` returns false
- Git: `bb46346` — "fix: don't track raft logs"

**Affected code paths**:
- `coordinator::controller` constructor (controller.cpp:37)
- `coordinator::state_machine::apply_snapshot()` (state_machine.cpp:101-104)
- `locking_shard::controller::init()` (controller.cpp:46)
- `locking_shard::state_machine::apply_snapshot()` (state_machine.cpp:56-58)
- `raft::log_store::compact()` (log_store.cpp:290-312)

**Suggested modeling approach**:
- Variables: `logSize [Server -> Nat]`, `snapshotExists [Server -> BOOLEAN]`
- Actions: Model log growth on each command, snapshot as optional compaction
- Constrain: recovery from log replay vs. snapshot restore takes different time

**Priority**: Medium
**Rationale**: Known acknowledged TODO, not a safety issue but a practical deployment concern. TLA+ can model the recovery cost.

---

### Family 5: Race Conditions in Coordinator Batch Processing (MEDIUM)

**Mechanism**: The coordinator's batch processing uses multiple threads with complex synchronization. Several race windows exist between batch swap, callback registration, and transaction addition.

**Evidence**:
- Code analysis: `controller.cpp:398-406` — `batch_set_cbs` called on `m_current_batch` after `m_batch_mut` is released, but `execute_transaction()` accesses `m_current_batch` under `m_batch_mut`
- Code analysis: `controller.cpp:491-525` — `schedule_exec()` uses yield-based spin loop, no condition variable
- Code analysis: `controller.cpp:527-534` — `join_execs()` uses `shared_lock` but `m_exec_mut` is `shared_mutex` — read-only is correct
- Code analysis: `controller.cpp:688-731` — `execute_transaction()` locks `m_batch_mut`, checks size, adds TX, then notifies — but `m_running` is checked before `m_batch_cv.wait()` and then re-checked inside

**Affected code paths**:
- `controller::batch_executor_func()` (controller.cpp:364-458)
- `controller::schedule_exec()` (controller.cpp:491-525)
- `controller::execute_transaction()` (controller.cpp:684-731)
- `controller::batch_set_cbs()` (controller.cpp:331-362)

**Suggested modeling approach**:
- Variables: `currentBatch`, `pendingTxs`, `execThreads [ThreadId -> {idle,busy}]`
- Actions: `AddTx`, `SwapBatch`, `StartBatchExec`, `CompleteBatchExec`
- Model yield-based scheduling as non-deterministic thread scheduling

**Priority**: Medium
**Rationale**: The yield-based thread pool is a known anti-pattern. No confirmed bugs but the complexity of the synchronization suggests future bugs are likely.

---

### Family 6: Locking Shard In-Memory State Loss on Crash (HIGH)

**Mechanism**: The locking shard is purely in-memory with no persistence. On crash, all locked outputs, applied transactions, and prepared dtx state are lost. The locking shard Raft cluster can recover the log, but the state machine itself (`locking_shard`) starts empty. This means locked UTXOs may become unlocked on recovery, and committed transactions may be lost.

**Evidence**:
- Code analysis: `locking_shard.hpp:32` — `\warning Not thread safe.` (documented)
- Code analysis: `locking_shard.hpp:139-144` — all state is `unordered_set` / `unordered_map` in memory
- Code analysis: `locking_shard.cpp:78-102` — `lock_outputs` only operates on in-memory sets
- Code analysis: `locking_shard.cpp:135-182` — `apply_outputs` only operates on in-memory sets
- Code analysis: `locking_shard/state_machine.cpp:56-58` — snapshot restore returns false
- Code analysis: `coordinator/controller.cpp:219-329` — recovery assumes shard state is recoverable

**Affected code paths**:
- All `locking_shard` methods (locking_shard.cpp:15-199)
- `locking_shard::state_machine::commit()` (state_machine.cpp:33-47)
- `coordinator::controller::recovery_func()` (controller.cpp:219-329)

**Suggested modeling approach**:
- Variables: `uhsSet [UhsId -> BOOLEAN]`, `lockedSet [UhsId -> BOOLEAN]`, `preparedDtxs`, `appliedDtxs`
- Actions: All locking shard operations are in-memory only
- Add `ShardCrash`: all volatile state is lost, shard restarts empty
- Add `ShardRecover`: shard replays Raft log from start (since no snapshots)
- Verify: does coordinator recovery correctly handle shard that lost all in-memory state?

**Priority**: High
**Rationale**: The locking shard's in-memory-only design is the fundamental fault-tolerance boundary. If a locking shard crashes and recovers, it has no locking/commit state. The coordinator's recovery assumes shard state is correct — this assumption is violated by shard crash.

---

### Family 7: Error Handling Gaps (LOW)

**Mechanism**: Multiple error paths log errors but continue execution with partial or inconsistent state.

**Evidence**:
- Code analysis: `locking_shard/state_machine.cpp:40-44` — deserialization error returns nullptr without signaling failure
- Code analysis: `coordinator/state_machine.cpp:34-36` — duplicate prepare triggers `fatal()` (program termination)
- Code analysis: `coordinator/controller.cpp:236` — empty response object logged as error but recovery continues
- Code analysis: `sentinel_2pc/controller.cpp:72` — sentinel client init failure logged as warning only

**Priority**: Low
**Rationale**: Better suited to code review than TLA+. The `fatal()` calls are intentional crash-early design. Sentinel warning is known and has a TODO.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Coordinator 2PC phase transitions | Family 2: RSM state vs shard state can diverge on crash | Split prepare/commit/discard into RSM action + shard action |
| Locking shard in-memory state loss | Family 6: shard crash loses all state | `ShardCrash` resets all shard state variables |
| Raft leadership handler delay | Family 1: gap between leader election and handler activation | Separate `isLeader` boolean from `handlerActive` boolean |
| Batch processing lifecycle | Family 5: batch swap, callback registration, thread pool | `currentBatch`, `pendingTxs` as variables with swap action |
| Sentinel to coordinator messaging | Family 3: no leader discovery, infinite retry | Abstract to request-with-retry and request-dropped |
| Continuous Raft log growth | Family 4: no snapshots, log grows unbounded | `logEntries` counter, compaction action optional |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Sentinel attestation gathering | Client-side concern, not protocol safety |
| Transaction validation logic | Pure computation, not protocol state |
| Locking shard C2PL per-tx locking | Implementation detail, 2PC protocol level is sufficient |
| Network backoff/retry delay | Performance concern, not correctness |
| NuRaft internals | Abstract as reliable/unreliable replicated log |
| `std::async` / thread pool implementation | Model as non-deterministic action scheduling |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Dual coordinator state | `rsmState`, `shardState`, `pendingShardOps` | Track RSM vs actual shard state divergence | Family 2 |
| In-memory shard crash | `uhsSet`, `lockedSet`, `preparedDtxs`, `appliedDtxs` | Model shard state loss | Family 6 |
| Leadership handler gap | `isLeader`, `handlerActive` | Model message handler delay after leader election | Family 1 |
| Batch lifecycle | `currentBatch`, `pendingTxs`, `threadStates` | Model batch swap and thread pool scheduling | Family 5 |
| Raft log growth | `logEntries` | Model unbounded log growth | Family 4 |
| Sentinel messaging | `sentinelRequests`, `coordinatorLeader` | Model request routing and retries | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoOutputsCreatedWithoutInputsLocked | Safety | Any UHS output in the system must have a corresponding locked input | Family 2, 6 |
| AtMostOnePreparePerDtx | Safety | A given dtx_id appears at most once in prepare state | Family 2 |
| ShardStateMatchesCoordinator | Safety | If coordinator believes dtx is committed, all shards must have applied it | Family 2, 6 |
| LeaderHasHandler | Safety | If leader=true then handlerActive=true (no period where leader but can't process) | Family 1 |
| HandlerOnlyWhenLeader | Safety | If handlerActive=true then leader=true (no stale handler running) | Family 1 |
| BatchConsistency | Safety | Every transaction in a batch appears exactly once in the result | Family 5 |
| NonLeaderRejectsRequest | Safety | Non-leader coordinators reject transaction requests | Family 1, 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|----------------------------|--------|
| MC1 | If locking shard crashes and recovers (in-memory state lost), can coordinator complete a dtx that the shard partially applied, leading to output commitment without input deletion or vice versa? | ShardStateMatchesCoordinator, NoOutputsCreatedWithoutInputsLocked | 2, 6 |
| MC2 | Can a coordinator RSM transition from prepare to commit before all shards complete lock_outputs, creating a window where crash recovery re-issues prepare on an already-locked shard? | AtMostOnePreparePerDtx | 2 |
| MC3 | If the coordinator start_stop_func delays activating the message handler after becoming leader, can a previous leader's stale response reach a sentinel? | LeaderHasHandler | 1 |
| MC4 | Can the locking shard RPC server be active while it's a Raft follower (not leader), causing stale/inconsistent state from direct writes? | HandlerOnlyWhenLeader | 1 |
| MC5 | If a sentinel sends a request to a coordinator that was leader but just lost leadership (handler still active), does the 2PC abort correctly or can it partially execute? | NonLeaderRejectsRequest | 1, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | yield-based thread pool can livelock under high contention | Stress test with concurrent batch submissions |
| TV2 | Locking shard `m_logger->fatal` in `apply_outputs` for non-existent dtx_id crashes the process after coordinator failover | Integration test: crash coordinator during 2PC, verify recovery |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Coordinator `schedule_exec()` yield loop should use condition variable | Convert to condition variable for efficiency |
| CR2 | Locking shard state_machine commit returns nullptr on deserialization error instead of error response | Return error response instead of nullptr |
| CR3 | Sentinel infinite retry in send_compact_tx could loop forever if coordinator is permanently down | Add retry limit and error propagation |
| CR4 | Snapshots disabled in both Raft instances — production concern | Tracked as TODO referencing #768 |

## 7. Reference Pointers

- **Full analysis report**: `analysis-report.md` (co-located)
- **Key source files**:
  - `src/uhs/twophase/coordinator/controller.cpp` (732 lines — core coordinator logic)
  - `src/uhs/twophase/coordinator/distributed_tx.cpp` (265 lines — 2PC phase orchestration)
  - `src/uhs/twophase/coordinator/state_machine.cpp` (124 lines — coordinator RSM)
  - `src/uhs/twophase/locking_shard/locking_shard.cpp` (199 lines — in-memory shard)
  - `src/uhs/twophase/locking_shard/controller.cpp` (133 lines — shard raft wrapper)
  - `src/uhs/twophase/locking_shard/state_machine.cpp` (119 lines — shard RSM)
  - `src/uhs/twophase/sentinel_2pc/controller.cpp` (228 lines — sentinel)
  - `src/util/raft/node.cpp` (142 lines — Raft wrapper)
  - `src/util/raft/log_store.cpp` (338 lines — LevelDB log)
- **Git commits**: `86b4118` (sentinel retry), `05e7732` (precondition fix), `11f34eb` (bounds fix), `c0b65a8` (coordinator init checks), `bb46346` (no raft log tracking)
- **Reference spec**: 2PC literature, C2PL literature (system uses both)
- **TODOs in code**: 8 TODOs in twophase/ code, 20+ in uhs/ code
