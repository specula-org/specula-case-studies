# Analysis Report: MongoDB RaftMongoReplTimestamp

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git history keywords searched | 27 |
| Bug-fix commits analyzed (repl + storage) | 2,500+ |
| GitHub/Jira issues deeply read | 65+ |
| Issues confirmed as bugs | 50+ |
| Issues excluded as false positive / user error | 5 |
| Core source files deeply read | 9 |
| TODO/FIXME comments cataloged | 15 |
| Bug families identified | 6 |
| Existing TLA+ specs reviewed | 8 (3 replication, 4 sharding, 1 exploratory) |

---

## Phase 1: Reconnaissance

### 1.1 Core Modules

| Component | Key Files | LOC (approx) |
|-----------|-----------|-------|
| Replication Coordinator | replication_coordinator_impl.cpp/.h | 8000 |
| Heartbeat handling | replication_coordinator_impl_heartbeat.cpp | 800 |
| Stepdown/step-up | replication_coordinator_impl_step_up_step_down.cpp | 400 |
| Catchup + lastApplied | replication_coordinator_impl_catchup.cpp | 450 |
| Election | replication_coordinator_impl_elect_v1.cpp | 500 |
| Topology coordination | topology_coordinator.cpp | 4000 |
| Oplog operations | oplog.cpp | 3000 |
| Oplog applier | oplog_applier_impl.cpp | 1200 |
| Recovery | replication_recovery.cpp | 1100 |
| Rollback | rollback_impl.cpp | 1400 |

### 1.2 Concurrency Model

**Primary locks:**
- `_mutex` (ObservableMutex): Protects most replication coordinator state. Held during timestamp calculations, commit point advancement, snapshot updates.
- RSTL (Replication State Transition Lock): Serializes role transitions (stepdown, step-up). Exclusive mode required for state changes.
- `_rsConfig` (WriteRarelyRWMutex): Separate lock for config reads. Can be read without `_mutex` via `unsafePeek()`.

**Independent threads:**
- Journal flusher: Periodically sets `lastDurable` based on `lastApplied`. Runs asynchronously — creates TOCTOU race window.
- Oplog visibility thread: Tracks `oplogReadTimestamp` for readers. Can be accidentally killed (SERVER-119964).
- Heartbeat threads: Per-member, periodic. Carry metadata including commit point.
- Oplog applier pool: Parallel worker threads for secondary batch application.

**Atomicity boundaries:**
- Single operation: `WriteUnitOfWork` wraps oplog insert + onCommit callback → atomic
- Batch application: Multiple operations across parallel workers → NOT atomic (only sequentially consistent per collection)
- Commit point update + stable timestamp + snapshot update → all under `_mutex` → atomic within a node
- Stepdown: Multi-step with RSTL release window → NOT atomic (reads can sneak in)
- Crash recovery: Multi-phase with crash windows → NOT atomic

### 1.3 Existing TLA+ Spec Coverage

The existing RaftMongoReplTimestamp spec (445 lines) covers:

| Feature | Covered? | Notes |
|---------|----------|-------|
| Elections | Yes | Simplified as `BecomePrimaryByMagic` (no actual vote protocol) |
| Log replication | Yes | `AppendOplog` from sync source |
| Rollback | Yes | One-entry rollback based on term comparison |
| Commit point propagation | Yes | Two paths: heartbeat with term check, sync source clamped to top of oplog |
| lastDurable / lastApplied / committedSnapshot | Yes | Basic timestamp tracking |
| PersistOplog (journal flush) | Yes | But modeled as **synchronous** — misses TOCTOU race |
| ApplyOplog | Yes | But only on followers, no parallel batch semantics |
| Restart (crash recovery) | Yes | But modeled as **single atomic action** |
| Stepdown | Yes | But modeled as **single atomic action** |
| **Read concerns** | **No** | Not modeled at all |
| **Write concerns** | **No** | Not modeled at all |
| **Oplog holes / allDurable** | **No** | Oplog writes are atomic in the spec |
| **Prepared transactions** | **No** | Not modeled |
| **Asynchronous journal flusher** | **No** | PersistOplog is synchronous |
| **Multiple timestamps (stable, oldest)** | **Partial** | Only committedSnapshot, not stableTimestamp or oldest |
| **writeConcernMajorityShouldJournal config** | **No** | Not modeled |
| **Multi-step crash recovery** | **No** | Single Restart action |
| **State transition windows** | **No** | Stepdown is atomic |

---

## Phase 2: Bug Archaeology

### 2.1 Bug-Fix Commit Counts by Area

| Area | Commit Count |
|------|-------------|
| Fix (general) | 417 |
| Rollback | 323 |
| Timestamp | 271 |
| Initial sync | 259 |
| Stepdown/step-up | 184 |
| Race | 163 |
| Recovery | 138 |
| Bug | 115 |
| Snapshot | 108 |
| Committed | 87 |
| Prepared transaction | 80 |
| Truncation | 76 |
| Write concern | 57 |
| Durable | 53 |
| Deadlock | 41 |
| Crash | 37 |
| Stable timestamp | 34 |
| Read concern | 29 |
| Commit point | 26 |
| Oplog visibility | 25 |

### 2.2 Historical Bug Catalog

#### Stable Timestamp / Oplog Hole Bugs

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-43978 | Stable timestamp not recalculated after aborting oplog holes | High | v4.2.3 |
| SERVER-39199 | Prepared txn commit/abort may not un-pin stable timestamp due to oplog hole | High | v4.1.8 |
| SERVER-38302 | Prepared txn commit/abort fails to advance stable timestamp (metrics race) | High | v4.1.8 |
| SERVER-35113 | Stable timestamp stalls on single-node RS | High | v3.6.7 |
| SERVER-45906 | Initial stable checkpoint not triggered (EMRC=false) | High | v4.2.4 |
| SERVER-35811 | Pin stable timestamp behind oldest uncommitted timestamp | High | v4.0.0-rc0 |
| SERVER-51387 | Assert stable timestamp never set higher than all_durable | Medium | v5.0 |
| SERVER-42366 | Stable timestamp updated during ROLLBACK state when EMRC=false | High | v4.2.2 |
| SERVER-45147 | Ghost timestamped transactions must trigger stable timestamp advance | High | v4.3.0 |
| SERVER-33806 | Only update stable/oldest when replication accepts new commit point | High | v3.6.5 |
| SERVER-57476 | Prepare conflict holds oplog slot, stalling replication indefinitely | CRITICAL | v4.2.15 |

#### Asynchronous lastDurable Race Conditions

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-50949 | lastDurable set to stale value after rollback resets optimes | High | v4.9.0 |
| SERVER-47898 | lastDurable advances irrespective of lastApplied | High | v7.3.0-rc0 |
| SERVER-52661 | lastDurable set after being cleared during initial sync | Medium | dup of 47898 |
| SERVER-85488 | setMyLastDurable not noop when lastWritten is null | Medium | v7.3.0-rc0 |
| SERVER-85703 | j:true write concern uses lastDurable alone after decoupling | Medium | v8.0.0-rc0 |

#### Commit Point Propagation Bugs

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-54374 | Commit point advanced via heartbeat during rollback state | High | v5.0.7 |
| SERVER-39831 | Commit point beyond lastApplied if learned from sync source | High | v3.6.13 |
| SERVER-39367 | Commit point advancement with term check (reverted spanning tree) | High | v3.6.12 |
| SERVER-27123 | Commit point updated outside spanning tree — majority reads can return rollbackable data | CRITICAL | v3.2.12 |
| SERVER-39626 | Majority committed entries rolled back on minority nodes | High | Won't Fix |
| SERVER-55376 | Reconfig can roll back committed writes in PSA sets | High | v5.0 |
| SERVER-78813 | Commit point propagation fails with exhaust cursors | High | v7.0.1 |
| SERVER-42305 | Commit point advanced before replication initialized | High | v4.2.0 |

#### Read Concern Violations

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-35038 | Linearizable read returns stale data after partition heals | CRITICAL | v3.6.6 |
| SERVER-27028 | Linearizable read noop without primary re-check | High | v3.4.0-rc4 |
| SERVER-37948 | Linearizable read not enforced on getMore | High | v4.1.9 |
| SERVER-67402 | Linearizable read during primary catchup | High | v5.0.14 |
| SERVER-53813 | Stale majority reads on new primary after election | High | v5.0.4 |
| SERVER-67538 | Multi-doc txn stale snapshot after index build | CRITICAL | v5.0.14 |
| SERVER-41769 | committedSnapshot exceeds allCommitted when EMRC=false | Medium | v4.2.0-rc3 |
| SERVER-46721 | Secondary readers read at lastApplied, not no-overlap point | High | v4.4.0-rc3 |
| SERVER-37514 | Snapshot readConcern infinite loop when EMRC=false | High | v4.0.0-rc0 |

#### Write Concern Loss During Stepdown

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-113256 | Write concern errors silently suppressed across all command types | CRITICAL | v7.0.26 |
| SERVER-27534 | 500 writes with w:majority acknowledged but lost | CRITICAL | v3.6.5 |
| SERVER-27053 | w:majority write confirmed after rollback | CRITICAL | v3.2.12 |
| SERVER-102765 | Collection creation rolled back without retry or error | High | v8.0.13 |

#### Crash Recovery Timestamp Ordering

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-58721 | replSetInitiate doesn't set stableTimestamp | High | v5.0.4 |
| SERVER-38555 | cappedTruncateAfter sets oldest timestamp wrong during recovery | High | v4.0.7 |
| SERVER-91841 | Repaired nodes hit oldest > stable invariant | Medium | v8.0.0-rc11 |
| SERVER-85688 | Stable timestamp not set correctly during startup recovery for restore | Medium | v8.0.0-rc0 |
| SERVER-109609 | allDurableTimestamp stuck at 1 after initial sync | High | v8.3.0-rc0 |
| SERVER-34279 | Post-upgrade crash skips oplog entries during recovery | CRITICAL | v3.7.4 |
| SERVER-48934 | Jepsen: oplog truncation skipped due to stale oplogTruncateAfterPoint read | CRITICAL | v4.4.0 |
| SERVER-58409 | RecordId reuse during prepared txn reconstruction after restart | High | v5.0.6 |

#### Prepared Transaction Interactions

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-60682 | TransactionCoordinator blocked on write tickets — system-wide deadlock | CRITICAL | v4.2.19 |
| SERVER-106075 | Prepared txns with apiVersion fail to resume after failover — partial commit | CRITICAL | v7.0.26 |
| SERVER-105751 | Session reaping kills prepared txn participant — silent inconsistency | CRITICAL | v8.0.13 |
| SERVER-58184 | Checkpoint thread races with recovering prepared txns | High | v4.4.9 |
| SERVER-38499 | Prepare fails: timestamp not > read timestamp | High | v4.1.8 |
| SERVER-89618 | Validation not disabled when reconstructing prepared txns | High | v5.0.27 |
| SERVER-40482 | Incorrect fastcount for prepared txn after rollback | Medium | v4.1.11 |

#### Oplog Visibility Bugs

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-119964 | Aggregation kills oplog visibility thread after rollback | CRITICAL | v8.2.7 |
| SERVER-120205 | Chained secondary reads beyond oplog visibility during step-up | High | OPEN |
| SERVER-122142 | Oplog visibility thread susceptible to concurrent start/stop | Medium | OPEN |
| SERVER-33859 | Oplog visibility timestamp initialized to 1 on startup | High | v3.7.4 |
| SERVER-66529 | OplogManager mutex release corrupts oplogReadTimestamp | High | v5.1.0 |

#### Deadlock Bugs (Replication)

| Ticket | Summary | Severity | Fixed |
|--------|---------|----------|-------|
| SERVER-62379 | Deadlock between ReplicationCoordinator and BackgroundSync on stepUp | High | v5.0.9 |
| SERVER-62951 | Deadlock restarting node with prepared txn (global lock) | High | v8.3.0-rc0 |
| SERVER-103744 | 3-way deadlock: renameCollection, dbHash, prepared txn | High | v8.2.0-rc0 |
| SERVER-78662 | Deadlock: index build, step down, prepared txn | High | v7.0.6 |
| SERVER-71191 | Deadlock: index build setup, prepared txn, stepdown | High | v4.4.19 |

#### Jepsen-Found Protocol Bugs

| Finding | Version | Summary |
|---------|---------|---------|
| v1 commit point bug | 3.4.0-rc3 | Heartbeats from stale primary advance commit points — majority reads return rollbackable data |
| v1 term checking bug | 3.4.0-rc3 | Primary acknowledges writes from prior terms without term check — 45% write loss |
| Transaction retry bug | 4.2.6 | Duplicate writes, retrocausal reads during partitions |
| Read concern downgrade | 4.2.6 | Transactions ignore database-level read concern settings, defaulting to `local` |
| Write concern default | 4.2.6 | Transactions default to w:1 regardless of client settings |

### 2.3 TLA+ History in MongoDB

MongoDB has used TLA+ for replication protocol verification since 2019:
- **2016 Safety Bug**: found via TLA+, initial fix worked for 3-node but not 5-node RS
- **2018 Liveness Bug**: fix for 2016 bug caused commit point stalls
- **2019 Sync Source Cycle Bug**: found via TLA+ (SERVER-39367, SERVER-39831)
- **SERVER-44851**: constrained commit points for model checking
- **SERVER-81460** (Nov 2023): added RaftMongoReplTimestamp.tla to the codebase
- **VLDB 2025**: Schultz & Demirbas published formal model of multi-shard transactions

---

## Phase 3: Deep Analysis

### 3.1 Stable Timestamp Calculation

**Code path**: `_recalculateStableOpTime` (replication_coordinator_impl.cpp:5043-5113)

The stable timestamp is computed as:
```
stableOpTime = min(noOverlap, maximumStableOpTime)
where:
  noOverlap = min(lastApplied, allDurableOpTime)  [primary]
  noOverlap = lastApplied                          [secondary, allDurable=MAX]
  maximumStableOpTime = commitPoint
```

**Key findings:**
1. `getAllDurableTimestamp()` is called while holding `_mutex` but queries the storage engine, which changes concurrently. The value is always safe (conservative) but may be stale.
2. On secondaries, `allDurable` is set to `OpTime::max()`, removing it from the min calculation. This means secondary stable timestamp = `min(lastApplied, commitPoint)`.
3. The `_updateCommittedSnapshot` function (line 5647) does NOT explicitly check `newCommittedSnapshot <= lastApplied` — it relies on the caller guarantee from `_recalculateStableOpTime`.
4. During ROLLBACK state, `_updateCommittedSnapshot` silently returns false (line 5655), freezing the committed snapshot.

### 3.2 Commit Point Advancement

**Code path**: `TopologyCoordinator::updateLastCommittedOpTimeAndWallTime` (topology_coordinator.cpp:3131-3172)

Key design decisions:
1. The config flag `writeConcernMajorityShouldJournal` determines whether durable or written optimes are used for the majority calculation (line 3141).
2. The commit point requires entries to be written by the current term's leader (`_firstOpTimeOfMyTerm` guard at line 3193).
3. From sync source: commit point is clamped to `min(committedOpTime, myLastWritten)` (line 3206).
4. From heartbeat: rejected entirely if term mismatch (line 3215).

### 3.3 Write Concern Satisfaction

**Code path**: `_doneWaitingForReplication` (replication_coordinator_impl.cpp:2222-2292)

For `w: "majority"` with snapshots:
1. Requires `_currentCommittedSnapshot >= opTime` (line 2248)
2. If `writeConcernMajorityShouldJournal` is true OR write concern doesn't require journaling, snapshot check alone suffices (lines 2271-2273)
3. Otherwise falls through to tagged-node check using topology coordinator

**During stepdown**: All waiters errored with `PrimarySteppedDown` in `_updateMemberStateFromTopologyCoordinator` (catchup.cpp:253-255).

### 3.4 Linearizable Read Implementation

**Code path**: `waitForLinearizableReadConcernImpl` (read_concern_mongod.cpp:545-599)

Two-phase protocol:
1. Check primary status (line 345)
2. Execute read command
3. Re-check primary + write noop to oplog (lines 564-587)
4. Wait for noop to be majority-committed (lines 589-592)

The window between step 1 and step 3 allows stepdown. The noop write + majority wait in step 3-4 ensures that if the read returned data, the node was the legitimate primary at the time of the noop write.

### 3.5 Stepdown Phases

**Code path**: `stepDown` (step_up_step_down.cpp:91-356)

Multi-step process:
1. Acquire RSTL exclusive lock
2. Disable writes (`_canAcceptNonLocalWrites = false`)
3. **Release RSTL** to let secondaries read oplog (line 240)
4. Wait for majority replication of lastApplied
5. Reacquire RSTL (kill any sneaked-in reads)
6. Yield prepared transaction locks
7. Finalize stepdown

The RSTL release at step 3 creates a window where reads can be served (documented at lines 285-291, references SERVER-27534).

### 3.6 Asynchronous Journal Flusher

The journal flusher thread:
1. Reads `lastApplied` (captures current value)
2. Performs journal flush
3. Calls `setMyLastDurableOpTimeAndWallTimeForward` with captured value

If rollback occurs between steps 1 and 3, the captured value may refer to entries no longer in the oplog. This is the root cause of SERVER-50949.

The `Forward` suffix on the setter method ensures monotonic-only advancement, preventing ABA issues. But it doesn't prevent the stale-value problem (a stale value that is monotonically forward relative to the reset state).

### 3.7 Crash Recovery

**Code path**: `recoverFromOplog` (replication_recovery.cpp:472-548)

Multi-phase:
1. Truncate oplog after `oplogTruncateAfterPoint` (line 495)
2. Apply oplog from stable timestamp to top (lines 522-525)
3. Reconstruct prepared transactions (line 574)
4. Mark data consistent (line 530)

Crash windows exist between each phase. The `appliedThrough` consistency marker and `oplogTruncateAfterPoint` provide crash-safe recovery bookmarks.

### 3.8 Open/Unfixed Issues

| Ticket | Status | Description |
|--------|--------|-------------|
| SERVER-120205 | OPEN | Chained secondary reads beyond oplog visibility during step-up |
| SERVER-122142 | Needs Scheduling | Oplog visibility thread concurrent start/stop |
| SERVER-101626 | OPEN | Prepared transactions bottlenecked on secondaries |

---

## Phase 4: Synthesis (Bug Family Mapping)

### Bug Family → Historical Bug Mapping

| Family | Historical Bugs | Code Analysis Findings | Total |
|--------|----------------|----------------------|-------|
| Family 1: Oplog Holes + Stable Timestamp | SERVER-43978, 39199, 38302, 35113, 45906, 57476, 35811, 45147 | allDurable query under _mutex, staleRead risk | 9 |
| Family 2: Async lastDurable TOCTOU | SERVER-50949, 47898, 52661, 85488, 85703 | Monotonic-forward doesn't prevent stale-value problem | 6 |
| Family 3: Write Concern Loss | SERVER-113256, 27534, 27053, 102765 | _doneWaitingForReplication + stepdown error race | 5 |
| Family 4: Read Concern Violations | SERVER-35038, 27028, 37948, 67402, 53813, 67538 | Linearizable two-phase window, catchup majority | 7 |
| Family 5: Crash Recovery Ordering | SERVER-58721, 38555, 91841, 85688, 109609, 34279, 48934, 58409 | Multi-phase recovery crash windows | 8 |
| Family 6: Prepared Txn Deadlocks | 15+ deadlock bugs | Lock ordering, not protocol-level | 15+ |

### Priority Ranking

| Priority | Family | Rationale |
|----------|--------|-----------|
| 1 (HIGH) | Family 1: Oplog Holes | 9 bugs, CRITICAL deadlock, completely absent from existing spec, ideal for TLA+ |
| 2 (HIGH) | Family 2: Async lastDurable | 6 bugs across v4.2-v8.0, existing spec's biggest gap (synchronous persist) |
| 3 (HIGH) | Family 3: Write Concern Loss | CRITICAL SERVER-113256 affects all versions, not modeled at all |
| 4 (MED) | Family 4: Read Concern | 7 bugs, mostly fixed, but interaction with state transitions worth exploring |
| 5 (MED) | Family 5: Crash Recovery | 8 bugs, extends existing Restart action, good TLA+ fit |
| 6 (LOW) | Family 6: Prepared Txn Deadlocks | 15+ bugs, but lock-ordering issues not suited for protocol-level TLA+ |

---

## Appendix: Source File Index

| File | Path | Key Functions |
|------|------|---------------|
| Coordinator impl | src/mongo/db/repl/replication_coordinator_impl.cpp | _recalculateStableOpTime, _setStableTimestampForStorage, _updateCommittedSnapshot, _advanceCommitPoint, _doneWaitingForReplication, awaitReplication |
| Coordinator header | src/mongo/db/repl/replication_coordinator_impl.h | State variable declarations, lock hierarchy |
| Heartbeat | src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp | _handleHeartbeatResponse, commit point from metadata |
| Step up/down | src/mongo/db/repl/replication_coordinator_impl_step_up_step_down.cpp | stepDown (RSTL release window) |
| Catchup | src/mongo/db/repl/replication_coordinator_impl_catchup.cpp | _setMyLastAppliedOpTimeAndWallTime, CatchupState |
| Election | src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp | _startRealElection, _onVoteRequestComplete |
| Topology | src/mongo/db/repl/topology_coordinator.cpp | updateLastCommittedOpTimeAndWallTime, advanceLastCommittedOpTimeAndWallTime |
| Oplog | src/mongo/db/repl/oplog.cpp | logOp (slot reservation), insertDocumentsForOplog |
| Applier | src/mongo/db/repl/oplog_applier_impl.cpp | _applyOplogBatch (parallel workers) |
| Recovery | src/mongo/db/repl/replication_recovery.cpp | recoverFromOplog, _applyOplogOperations |
| Rollback | src/mongo/db/repl/rollback_impl.cpp | _runPhaseFromAbortToReconstructPreparedTxns |
| Read concern | src/mongo/db/read_concern_mongod.cpp | waitForLinearizableReadConcernImpl |
| Existing TLA+ spec | src/mongo/tla_plus/Replication/RaftMongoReplTimestamp/RaftMongoReplTimestamp.tla | 445 lines, 9 vars, 12 actions |
