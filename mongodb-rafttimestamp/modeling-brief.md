# Modeling Brief: MongoDB RaftMongoReplTimestamp

## 1. System Overview

- **System**: MongoDB Replica Set Replication (mongodb/mongo), C++, ~10K LOC core replication logic
- **Protocol**: Raft-derived consensus with MongoDB-specific extensions: timestamp-based oplog, MVCC via WiredTiger, multi-level read/write concerns, prepared transactions
- **Key architectural choices**:
  - Oplog writes reserve slots atomically but commit out-of-order, creating "holes" tracked by `allDurable` timestamp
  - Journal flusher is an **asynchronous thread** that periodically sets `lastDurable` based on `lastApplied` — creates TOCTOU races with rollback/initial sync
  - Stable timestamp = `min(lastApplied, allDurable, commitPoint)` — three independent inputs, any can stall
  - Config flag `writeConcernMajorityShouldJournal` switches commit calculation between `lastDurable` and `lastWritten` — a runtime toggle
  - Prepared transactions pin oldest timestamp and hold oplog holes open indefinitely
- **Concurrency model**: Single `_mutex` protects most state; RSTL (Replication State Transition Lock) serializes role transitions; journal flusher and oplog visibility thread run independently
- **Existing TLA+ spec**: 445 lines, 9 variables, 12 actions — covers basic Raft replication, commit point propagation, durability (lastDurable/lastApplied/committedSnapshot), restart/crash recovery, rollback

## 2. Bug Families

### Family 1: Oplog Holes Stall Stable Timestamp (HIGH)

**Mechanism**: Oplog slot reservation creates "holes" that pin the `allDurable` timestamp. Since `stableTimestamp = min(lastApplied, allDurable, commitPoint)`, a stuck hole stalls the stable timestamp, blocking checkpointing, snapshot reads, and write concern satisfaction.

**Evidence**:
- Historical: SERVER-43978 — aborted operation closes hole but nobody recalculates stable timestamp
- Historical: SERVER-39199 — prepared transaction commit writes entry but `OplogSlotReserver` hole still open; threads hang waiting for committed snapshot
- Historical: SERVER-38302 — race between prepare/commit oplog entries and oldest-prepared-timestamp metric update
- Historical: SERVER-35113 — single-node RS: out-of-order commits advance `allCommitted` without advancing `lastApplied`, stable timestamp stuck
- Historical: SERVER-57476 (CRITICAL) — prepare conflict holds oplog slot, creating circular deadlock: hole blocks replication → replication blocks majority commit → majority commit blocks prepare resolution → prepare holds hole
- Code analysis: `_recalculateStableOpTime` (replication_coordinator_impl.cpp:5077) queries `getAllDurableTimestamp()` from storage engine; prepared transactions block this indefinitely

**Affected code paths**:
- `_recalculateStableOpTime` (replication_coordinator_impl.cpp:5043-5113)
- `_setStableTimestampForStorage` (replication_coordinator_impl.cpp:5117-5178)
- `logOp` slot reservation (oplog.cpp:588)
- Prepared transaction prepare/commit paths

**Suggested modeling approach**:
- Variables: `oplogHoles [Server -> SUBSET OplogSlot]`, `allDurable [Server -> Timestamp]`
- Actions: `ReserveOplogSlot` (creates hole), `CloseOplogHole` (removes slot from set), `PrepareTransaction` (creates persistent hole), `CommitPreparedTxn` (closes hole after commit entry)
- Granularity: Split `ClientWrite` into `ReserveSlot` + `CommitWrite` (two steps with crash window)
- `allDurable = IF oplogHoles[s] = {} THEN lastWritten[s] ELSE Min(oplogHoles[s]) - 1`
- `stableTimestamp = Min({lastApplied[s], allDurable[s], commitPoint[s]})`

**Priority**: High
**Rationale**: 6+ historical bugs including one CRITICAL circular deadlock. The existing spec treats oplog writes as atomic (no holes), missing this entire class of bugs. TLA+ is ideal for exploring the interleaving space between slot reservation, commit, and stable timestamp calculation.

---

### Family 2: Asynchronous lastDurable TOCTOU Races (HIGH)

**Mechanism**: The journal flusher thread reads `lastApplied` at time T1, then later sets `lastDurable` at time T2. If rollback, initial sync, or stepdown resets optimes between T1 and T2, `lastDurable` is set to a stale value — pointing to oplog entries that no longer exist.

**Evidence**:
- Historical: SERVER-50949 — journal flusher reads `lastApplied = OpTime(2,2)`, rollback resets to `OpTime(1,1)`, new entries bring `lastApplied` to `OpTime(3,3)`, flusher sets `lastDurable = OpTime(2,2)` — entries not in oplog
- Historical: SERVER-47898 — `lastDurable` advances independently of `lastApplied`, causing latency for `w:majority` and incorrect `replSetGetStatus`
- Historical: SERVER-52661 — race between journal flusher and initial sync reset; flusher writes stale value after optimes cleared
- Historical: SERVER-85488 — journal flusher acquires token before initial sync resets optimes, then advances `lastDurable` past `lastWritten` (which is now null)
- Historical: SERVER-85703 — after decoupling `lastDurable` from `lastApplied`, `j:true` write concern sees entries as durable that aren't yet applied
- Code analysis: `_setMyLastDurableOpTimeAndWallTime` (replication_coordinator_impl.cpp:1693-1708) accepts any optime and updates commit level — no guard against the optime referring to rolled-back entries

**Affected code paths**:
- Journal flusher thread → `setMyLastDurableOpTimeAndWallTimeForward`
- `_setMyLastDurableOpTimeAndWallTime` (replication_coordinator_impl.cpp:1693-1708)
- Rollback reset in `_runPhaseFromAbortToReconstructPreparedTxns` (rollback_impl.cpp:700-769)
- Initial sync optime reset

**Suggested modeling approach**:
- Variables: `journalFlusherSnapshot [Server -> OpTime]` (the value the flusher will use), `lastWritten [Server -> OpTime]` (new variable, distinct from lastDurable)
- Actions: `JournalFlusherCapture(s)` (reads lastApplied into snapshot), `JournalFlusherFlush(s)` (sets lastDurable from snapshot, advances commit if configured). Split into two steps to expose the TOCTOU window.
- Add guard in `JournalFlusherFlush`: skip if `lastWritten[s]` is null (the SERVER-85488 fix)

**Priority**: High
**Rationale**: 5+ historical bugs spanning v4.2 through v8.0, repeatedly rediscovered. The existing spec models `PersistOplog` as synchronous and instantaneous — completely misses this asynchronous race pattern. The two-step journal flusher is a classic TLA+ target.

---

### Family 3: Write Concern Loss During Stepdown (HIGH)

**Mechanism**: Writes acknowledged with `w:majority` can be silently rolled back if the primary steps down at the wrong moment. The client receives success but the write is lost.

**Evidence**:
- Historical: SERVER-113256 (CRITICAL, affects ALL versions 4.4-8.0) — write concern errors suppressed across insert, update, findAndModify, batch writes, bulkWrite, abortTransaction, createIndexes, createCollection; clients believe writes succeeded despite rollback
- Historical: SERVER-27534 — batch insert with `w:majority` acknowledged, primary steps down, writes rolled back, original primary steps back up and completes remaining inserts; 500 writes lost
- Historical: SERVER-27053 — race: primary acks `w:majority`, steps down, write rolls back, re-wins election, `awaitReplication()` sees write as already satisfied on majority — returns success despite rollback
- Historical: SERVER-102765 — collection creation rolled back without retry, no error to client
- Code analysis: `_doneWaitingForReplication` (replication_coordinator_impl.cpp:2222-2292) checks `_currentCommittedSnapshot >= opTime`; during stepdown, `_replicationWaiterList.setErrorAll()` is called (catchup.cpp:253-255) but there's a window between snapshot check satisfaction and error signaling

**Affected code paths**:
- `awaitReplication` → `_doneWaitingForReplication` (replication_coordinator_impl.cpp:2222-2292)
- `_updateMemberStateFromTopologyCoordinator` (catchup.cpp:251-268) — error-signals all waiters
- Stepdown RSTL release window (step_up_step_down.cpp:240-241, 285-291)

**Suggested modeling approach**:
- Variables: `writeConcernWaiters [Server -> SUBSET WriteOp]`, `acknowledged [WriteOp -> BOOLEAN]`, `rolledBack [WriteOp -> BOOLEAN]`
- Actions: `ClientWriteWithWC(s, op)` (creates write + waiter), `WriteConcernSatisfied(s, op)` (sets acknowledged), `StepdownCancelWaiters(s)` (errors all waiters)
- Key invariant: `\A op \in WriteOp : acknowledged[op] => ~rolledBack[op]`

**Priority**: High
**Rationale**: SERVER-113256 is the most severe MongoDB replication bug in recent years — silently losing acknowledged writes across all versions. TLA+ can model the race between write concern satisfaction, stepdown, and rollback to find remaining gaps.

---

### Family 4: Read Concern Violations During State Transitions (MEDIUM)

**Mechanism**: Read concern implementations (majority, linearizable, snapshot) can return stale or inconsistent data during elections, stepdowns, or catchup periods.

**Evidence**:
- Historical: SERVER-35038 (CRITICAL) — linearizable read returns stale data after network partition heals; stale primary serves reads without confirming quorum
- Historical: SERVER-27028 — linearizable read noop written without re-checking primary status
- Historical: SERVER-37948 — linearizable guarantee not enforced on getMore operations
- Historical: SERVER-67402 — linearizable read served during primary catchup
- Historical: SERVER-53813 — stale majority reads on new primary after election (before first write majority-committed)
- Historical: SERVER-67538 — multi-doc transaction silently proceeds with stale snapshot after index build
- Code analysis: `waitForLinearizableReadConcernImpl` (read_concern_mongod.cpp:545-599) has a two-phase check (isPrimary → write noop → await majority), but the window between Phase 1 check and Phase 2 noop write allows stepdown to interleave

**Affected code paths**:
- `waitForLinearizableReadConcernImpl` (read_concern_mongod.cpp:545-599)
- `_waitUntilClusterTimeForRead` (replication_coordinator_impl.cpp:2029-2038)
- `_primaryMajorityReadsAvailability` (replication_coordinator_impl.cpp:5607-5644)
- `_updateCommittedSnapshot` (replication_coordinator_impl.cpp:5647-5690)

**Suggested modeling approach**:
- Variables: `readOps [ReadOp -> {readConcern, snapshot, result}]`, `readConcernLevel [ReadOp -> {"local", "majority", "linearizable"}]`
- Actions: `StartLinearizableRead(s, op)` (check primary + capture data), `WriteNoopForLinearizable(s, op)` (write noop to oplog), `AwaitLinearizableMajority(s, op)` (wait for majority commit of noop)
- Key: stepdown can interleave between each of these three steps
- Invariant: `LinearizableReadsAreLinearizable` — if a linearizable read returns value V, V was the latest committed value at some point during the read

**Priority**: Medium
**Rationale**: Historical linearizable read bugs are severe but mostly fixed. The remaining value is in modeling the interaction between read concern and state transitions (election, stepdown, catchup) — a complex interleaving space.

---

### Family 5: Crash Recovery Timestamp Ordering (MEDIUM)

**Mechanism**: Startup recovery involves multiple timestamps (stable, oldest, allDurable, appliedThrough, oplogTruncateAfterPoint) that can get out of order, especially during initial sync completion, post-repair rejoining, or post-upgrade crashes.

**Evidence**:
- Historical: SERVER-58721 — `replSetInitiate` activates checkpointer without stable timestamp; rollback attempt crashes
- Historical: SERVER-38555 — `cappedTruncateAfter` sets oldest timestamp incorrectly during startup recovery with `EMRC=false`
- Historical: SERVER-91841 — repaired node rejoining RS hits `oldest > stable` invariant during initial sync
- Historical: SERVER-85688 — stable timestamp not set correctly during startup recovery for restore
- Historical: SERVER-109609 — `allDurableTimestamp` stuck at 1 after initial sync; primary transition invariant fails
- Historical: SERVER-34279 — crash after upgrade skips oplog entries during recovery
- Historical: SERVER-48934 (CRITICAL, Jepsen) — oplog truncation skipped due to stale read of `oplogTruncateAfterPoint`
- Code analysis: `recoverFromOplog` (replication_recovery.cpp:472-548) is multi-phase with crash windows between: oplog truncation → oplog replay → appliedThrough update → prepared transaction reconstruction

**Affected code paths**:
- `recoverFromOplog` (replication_recovery.cpp:472-548)
- `_truncateOplogTo` (replication_recovery.cpp:864-951)
- `_applyOplogOperations` (replication_recovery.cpp:730-849)
- Rollback `recoverToStableTimestamp` (rollback_impl.cpp:700)

**Suggested modeling approach**:
- Extend the existing `Restart` action to be multi-step:
  1. `RecoverTruncateOplog(s)` — truncate entries after oplogTruncateAfterPoint
  2. `RecoverReplayOplog(s)` — replay entries from stable timestamp to top of oplog
  3. `RecoverSetTimestamps(s)` — set lastApplied, lastDurable, stable, oldest
- Variables: `oplogTruncateAfterPoint [Server -> Timestamp]`, `appliedThrough [Server -> OpTime]`
- Crash can occur between any recovery step

**Priority**: Medium
**Rationale**: 7+ historical bugs, including a Jepsen-found data inconsistency. The existing spec models restart as a single atomic action — extending it to multi-step recovery would catch ordering bugs. However, many of these bugs involve storage-engine-specific details that may be too low-level for protocol-level TLA+.

---

### Family 6: Prepared Transaction Deadlocks (LOW for TLA+)

**Mechanism**: Prepared transactions hold locks for extended periods, creating circular wait deadlocks with step-up, step-down, index builds, migrations, and other subsystems.

**Evidence**:
- Historical: 15+ deadlock bugs including SERVER-60682, SERVER-62951, SERVER-103744, SERVER-78662, SERVER-71191, SERVER-73218, SERVER-80978, SERVER-50381, SERVER-49508
- The fundamental pattern: prepared txn holds IX lock → other operation needs X lock → blocks → first operation needs prepared txn to complete → blocks = deadlock

**Priority**: Low (for TLA+)
**Rationale**: These are lock-ordering bugs, better verified by lock-ordering analysis tools or stress testing. TLA+ at the protocol level cannot model the full MongoDB lock hierarchy. However, the **timestamp pinning** aspect of prepared transactions (Family 1) IS model-checkable.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Oplog holes + allDurable | Family 1: 6+ bugs, CRITICAL deadlock. Existing spec has no holes. | `oplogHoles` set variable, `allDurable` computed from holes |
| Stable timestamp calculation | Family 1: `min(lastApplied, allDurable, commitPoint)` — three-way interaction | New `stableTimestamp` variable, computed each time any input changes |
| Asynchronous journal flusher | Family 2: 5+ TOCTOU bugs across v4.2-v8.0. Existing spec has synchronous persist. | Split `PersistOplog` into `JournalFlusherCapture` + `JournalFlusherFlush` |
| Write concern tracking | Family 3: CRITICAL write loss (SERVER-113256). Not modeled at all. | `writeConcernWaiters` + `acknowledged` tracking per write op |
| Stepdown interleaving with writes | Family 3: window between RSTL release and reacquisition | Split `Stepdown` into multi-step with waiter cancellation |
| Prepared transaction timestamp pinning | Family 1 interaction: prepared txns hold holes indefinitely | `preparedTxns` set that creates persistent oplog holes |
| `writeConcernMajorityShouldJournal` toggle | Family 2: switches commit calculation between durable and written | Boolean config variable that determines which optime feeds commit point |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Linearizable read concern | Family 4: interesting but secondary priority; the noop-write-then-await-majority protocol is well-understood |
| Prepared transaction lock deadlocks | Family 6: lock-ordering bugs, not protocol logic. Better for lock-order analysis tools. |
| Initial sync protocol | Large separate protocol with its own state machine; would triple spec size |
| Snapshot read concern with atClusterTime | Lower bug density; the mechanism is a simple timestamp comparison |
| Oplog applier parallel batching | Secondary-specific optimization; the batching details are implementation, not protocol |
| Replication configuration changes | Separate spec (MongoReplReconfig) already exists in the MongoDB TLA+ suite |
| Network/transport layer | Too low-level; the existing spec's "magic" message delivery is appropriate |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Oplog holes | `oplogHoles`, `allDurable` | Model out-of-order oplog commits and their impact on stable timestamp | Family 1 |
| Stable timestamp | `stableTimestamp` (computed) | Explicit three-way min calculation | Family 1 |
| Async journal flusher | `journalFlusherSnapshot`, `lastWritten` | Model TOCTOU between capture and flush | Family 2 |
| Write concern | `writeConcernWaiters`, `acknowledged` | Track client write acknowledgments | Family 3 |
| Stepdown phases | (split existing Stepdown action) | Multi-step stepdown with RSTL release window | Family 3 |
| Prepared transactions | `preparedTxns`, `prepareTimestamp` | Persistent oplog holes from prepared transactions | Family 1 |
| Commit source toggle | `useDurableForCommit` | `writeConcernMajorityShouldJournal` setting | Family 2 |
| Recovery steps | `recoveryPhase`, `oplogTruncateAfterPoint` | Multi-step crash recovery | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoTwoPrimariesInSameTerm | Safety | At most one leader per term | Standard (existing) |
| NeverRollbackCommitted | Safety | Committed entries never rolled back | Standard (existing) |
| CommittedSnapshotNeverRollback | Safety | Committed snapshot monotonically increases | Standard (existing) |
| StableNeverExceedsAllDurable | Safety | `stableTimestamp[s] <= allDurable[s]` for all primaries | Family 1 |
| StableNeverExceedsCommitPoint | Safety | `stableTimestamp[s] <= commitPoint[s]` | Family 1 |
| StableNeverExceedsLastApplied | Safety | `stableTimestamp[s] <= lastApplied[s]` | Family 1 |
| AcknowledgedWriteNeverRolledBack | Safety | If `acknowledged[op]`, then `op` is in every future leader's log | Family 3 |
| LastDurableImpliesInOplog | Safety | If `lastDurable[s] = OpTime(t,i)`, then `log[s][i].term = t` | Family 2 |
| HolesBlockAllDurable | Safety | If `oplogHoles[s] /= {}`, then `allDurable[s] < Min(oplogHoles[s])` | Family 1 |
| PreparedTxnPinsStable | Safety | If a prepared txn exists with timestamp T, then `stableTimestamp[s] <= T` | Family 1 |
| StableTimestampEventuallyAdvances | Liveness | If all holes close and commit point advances, stable timestamp eventually advances | Family 1 |
| WriteConcernEventuallyResolves | Liveness | Every write concern waiter is eventually satisfied or errored | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Prepared txn holds oplog hole while commit point advances via other writes — does stable timestamp stall prevent checkpointing? | StableTimestampEventuallyAdvances (liveness) | Family 1 |
| MC-2 | Journal flusher captures lastApplied, rollback resets optimes, flusher sets lastDurable to stale value — does lastDurable point to non-existent entry? | LastDurableImpliesInOplog | Family 2 |
| MC-3 | Write acknowledged with w:majority, stepdown occurs, write rolled back — does client see success for rolled-back write? | AcknowledgedWriteNeverRolledBack | Family 3 |
| MC-4 | Commit source toggles from written to durable during reconfig — can committed snapshot regress? | CommittedSnapshotNeverRollback | Family 2 |
| MC-5 | Oplog hole closed by abort but no recalculation trigger — does stable timestamp stall? | StableTimestampEventuallyAdvances (liveness) | Family 1 |
| MC-6 | Primary steps down during catchup before first write majority-committed — can stale reads be served? | (new: NoStaleMajorityReads) | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Oplog visibility thread can be killed by long-running aggregation across rollback (SERVER-119964) | Integration test: start aggregation, trigger rollback, check visibility thread still running |
| TV-2 | Write concern error suppression across command types (SERVER-113256) | Systematic test: each command type + stepdown + check error propagation |
| TV-3 | Race between journal flusher and initial sync optime reset (SERVER-85488) | Inject delay in journal flusher, trigger initial sync reset, check lastDurable invariant |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `_updateCommittedSnapshot` does not explicitly check `newCommittedSnapshot <= lastApplied` — relies on caller guarantee | Add defensive invariant at replication_coordinator_impl.cpp:5669 |
| CR-2 | Oplog visibility thread susceptible to concurrent start/stop (SERVER-122142, OPEN) | Architectural review of visibility thread lifecycle management |
| CR-3 | Chained secondary reads beyond oplog visibility timestamp during step-up (SERVER-120205, OPEN) | Review concurrency control between step-up noop and oplog cursor yield/restore |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-rafttimestamp/analysis-report.md`
- **Existing TLA+ spec**: `artifact/mongo-src/src/mongo/tla_plus/Replication/RaftMongoReplTimestamp/RaftMongoReplTimestamp.tla` (445 lines)
- **Key source files**:
  - `src/mongo/db/repl/replication_coordinator_impl.cpp` (core coordinator, ~6000 lines)
  - `src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp` (heartbeat + commit point propagation)
  - `src/mongo/db/repl/replication_coordinator_impl_step_up_step_down.cpp` (stepdown phases)
  - `src/mongo/db/repl/replication_coordinator_impl_catchup.cpp` (catchup + lastApplied management)
  - `src/mongo/db/repl/topology_coordinator.cpp` (commit point calculation, member optime tracking)
  - `src/mongo/db/repl/oplog.cpp` (oplog slot reservation, visibility)
  - `src/mongo/db/repl/oplog_applier_impl.cpp` (parallel batch application)
  - `src/mongo/db/repl/replication_recovery.cpp` (crash recovery)
  - `src/mongo/db/repl/rollback_impl.cpp` (rollback to stable timestamp)
- **Critical SERVER tickets**: SERVER-113256, SERVER-57476, SERVER-50949, SERVER-48934, SERVER-35038, SERVER-27534, SERVER-39199, SERVER-43978
- **Jepsen reports**: MongoDB 3.4.0-rc3 (2017), MongoDB 4.2.6 (2020)
- **TLA+ Conference 2019**: William Schultz — "Fixing a MongoDB Replication Protocol Bug with TLA+"
- **Shared harness**: `case-studies/mongodb-shared-harness.md` (log-parsing approach, Docker compose templates)
