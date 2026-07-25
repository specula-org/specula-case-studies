# Modeling Brief: vesoft-inc/nebula (Raft Consensus)

## 1. System Overview

- **System**: vesoft-inc/nebula — C++ distributed graph database using Raft for storage partition consensus
- **Language**: C++, ~4,700 LOC core Raft logic (`src/kvstore/raftex/`)
- **Protocol**: Raft (Ongaro 2014) with pre-vote, learner/listener nodes, atomic operations, leader lease reads
- **Key architectural choices**:
  - **Term and votedFor are NOT persisted** — recovered from WAL's `lastLogTerm` on restart (RaftPart.cpp:412-414)
  - **Heartbeat runs on IO thread**, separate from worker-thread log replication; acquires `raftLock_` on IO thread
  - **Leader lease** for read consistency — no ReadIndex or CheckQuorum mechanism
  - **`isBlindFollower_` optimization** — freshly started node bypasses election timeout entirely
  - **Separate heartbeat RPC** — does NOT advance follower's `committedLogId_` (RaftPart.cpp:1895-1952)
  - **WAL defaults to no-fsync** (`wal_sync=false`) — data sits in kernel page cache until file rotation
- **Concurrency model**: Thrift worker threads for appendLog/vote/snapshot; IO threads for heartbeat; background timer for statusPolling; per-peer Host objects for replication; `raftLock_` (mutex) + `logsLock_` (mutex) + per-host `lock_` (mutex)

## 2. Bug Families

### Family 1: Non-Persisted Term/Vote — Vote Safety Violation (HIGH)

**Mechanism**: Raft requires `currentTerm` and `votedFor` to be persisted to stable storage and recovered on restart. Nebula initializes `term_` from `wal_->lastLogTerm()` and `votedTerm_`/`votedAddr_` from zero/"". After a crash, a node can vote again in a term where it already voted, enabling two leaders in the same term.

**Evidence**:
- Code analysis: RaftPart.cpp:412-414 — `term_ = lastLogTerm_; lastLogTerm_ = wal_->lastLogTerm()` (no persistent term store)
- Code analysis: RaftPart.h — `votedTerm_` and `votedAddr_` are volatile fields, never persisted
- Historical: #685 — term confusion causes crash and 10+ minute election deadlock
- Historical: #2405 — double voting in same term (two leaders)
- Historical: PR #3415 — missing self-vote in formal election after pre-vote
- Historical: RaftPart.cpp:1850-1858 — `verifyLeader` has explicit "split brain happens" LOG(ERROR) handler, suggesting the scenario occurs in practice

**Affected code paths**:
- `RaftPart::start()` (term recovery: RaftPart.cpp:412-414)
- `processAskForVoteRequest()` (vote grant: RaftPart.cpp:1560-1600)
- `prepareElectionRequest()` (self-vote: RaftPart.cpp:1183-1187)

**Suggested modeling approach**:
- Variables: `persistedTerm[Server]`, `persistedVotedFor[Server]` (what survives crash) vs. `term[Server]`, `votedFor[Server]` (volatile)
- Actions: `Crash` resets volatile state, recovers `term` from `lastLogTerm` (not `persistedTerm`)
- Invariant target: ElectionSafety — at most one leader per term

**Priority**: HIGH
**Rationale**: Violates a core Raft safety invariant. 3+ historical bugs. The double-voting scenario (#2405) was confirmed by developers. Model checking can definitively show whether crash+restart enables two-leader scenarios.

---

### Family 2: Leader Lease / Split Brain Without CheckQuorum (HIGH)

**Mechanism**: Nebula implements lease-based reads without CheckQuorum or ReadIndex. Combined with `isBlindFollower_` (which lets restarted nodes bypass election timeout) and missing leader-lease checks in vote handling, a new leader can be elected while the old leader's lease is still valid, breaking linearizability.

**Evidence**:
- Historical: #5352 — linearizability broken: old leader serves stale reads while new leader accepts writes
- Historical: #5379 — followers grant votes without checking if leader lease is valid
- Historical: #5265 — RocksDB write stall inflates `lastMsgAcceptedCostMs_`, causing false lease invalidation
- Historical: PR #5534 / PR #5271 — heartbeat time going backwards due to out-of-order responses
- Code analysis: RaftPart.cpp:2254-2268 — lease calculation can underflow with uint64 arithmetic when `lastMsgAcceptedCostMs_ > heartbeat_interval`
- Code analysis: RaftPart.h — `isBlindFollower_` initialized to `true`, bypasses election timeout (RaftPart.cpp:1145-1147)
- Design defect: #3111 — acknowledged lack of ReadIndex/CheckQuorum

**Affected code paths**:
- `leaseValid()` (RaftPart.cpp:2254-2268)
- `processAskForVoteRequest()` — no leader lease check before granting vote
- `needToStartElection()` — `isBlindFollower_` bypass (RaftPart.cpp:1145-1147)
- `processAppendLogResponses()` and `sendHeartbeat()` — lease timing updates (RaftPart.cpp:1084-1089, 2103-2121)

**Suggested modeling approach**:
- Variables: `leaseValid[Server]` (derived from timing), `blindFollower[Server]` (boolean)
- Actions: `BlindFollowerElection` (bypasses timeout), `GrantVoteWithoutLeaseCheck`, `CheckLeaderLease`
- Model lease as: leader's lease expires after N steps without quorum heartbeat ack
- Invariant target: `NoStaleRead` — if leader's lease is valid, no other node is leader

**Priority**: HIGH
**Rationale**: 4+ historical bugs. #5352 is a confirmed linearizability violation. The design gap (no CheckQuorum) is acknowledged by maintainers. TLA+ can explore the interleaving of lease timeout + blind follower election.

---

### Family 3: Snapshot Lifecycle Race Conditions (HIGH)

**Mechanism**: Snapshot transfers are long-running operations. Leadership can change during a transfer, but the completion callback updates Host state without re-validating the term. `Host::reset()` (called on re-election) doesn't wait for in-flight snapshots. If SnapshotManager's leadership check fails early, the promise is never fulfilled, permanently wedging the Host.

**Evidence**:
- Code analysis: Host.cpp:358-374 — snapshot callback updates `lastLogIdSent_`/`lastLogTermSent_` without term check
- Code analysis: Host.h:85-96 — `reset()` waits for `requestOnGoing_` but force-clears `sendingSnapshot_` without waiting
- Code analysis: SnapshotManager.cpp:41-46 — leadership check failure returns without fulfilling promise → Host permanently stuck
- Code analysis: SnapshotManager.cpp:82-85 — no leadership re-check at end of transfer
- Historical: #4479 — split brain from snapshot + stale leader heartbeats
- Historical: #3909 — node stuck after receiving snapshot (WAL gap loop)
- Historical: #4372 — crash after snapshot (CHECK_LE assertion on empty WAL)
- Historical: #3710 — snapshot data inconsistency (non-atomic RocksDB scan)
- Historical: #5240 — `GetSnapshot` returns nullptr when `commitInThisTerm_` is false
- Historical: PR #1769 — infinite snapshot/election loop (candidate rejects snapshot)
- Historical: PR #4019 — snapshot cleanup deletes all data; wrong-leader snapshot accepted

**Affected code paths**:
- `Host::startSendSnapshot()` / completion callback (Host.cpp:340-374)
- `Host::reset()` (Host.h:85-96)
- `SnapshotManager::sendSnapshot()` (SnapshotManager.cpp:37-109)
- `RaftPart::processSendSnapshotRequest()` (RaftPart.cpp:1960-2030)

**Suggested modeling approach**:
- Variables: `snapshotInProgress[Server -> SUBSET Server]`, `snapshotTerm[Server -> Server -> Term]`
- Actions: `StartSnapshot` (captures term), `CompleteSnapshot` (may apply to wrong term), `LeaderChangeWhileSnapshotting`
- Split Host state: separate `pre-snapshot` and `post-snapshot` state with term validation
- Invariant target: `SnapshotTermConsistency` — snapshot callback only updates Host state if term hasn't changed

**Priority**: HIGH
**Rationale**: 7+ historical bugs in snapshot interactions. The Host reset / snapshot completion race (H-5, H-6, H-11) is a new finding with no historical fix. The cluster of bugs suggests the snapshot-leader interaction is fundamentally underspecified.

---

### Family 4: Log Replication State Desynchronization (MEDIUM)

**Mechanism**: Multiple code paths update `lastLogId_`, `lastLogTerm_`, `committedLogId_` at different times and under different locks. The Host's AppendLog response handler doesn't check terms (ABA). One leader step-down path (via AppendLog responses) omits `onLostLeadership` callback and `host->pause()`. The heartbeat path doesn't advance follower commit index.

**Evidence**:
- Code analysis: RaftPart.cpp:895-906 — `lastLogId_` not updated after WAL write (only after majority ack at line 1056)
- Code analysis: Host.cpp:190-234 — no term check in AppendLog response handler (ABA if leadership cycles)
- Code analysis: RaftPart.cpp:1025-1037 — step-down via AppendLog response missing `onLostLeadership` and `host->pause()`
- Code analysis: RaftPart.cpp:1895-1952 — heartbeat handler never advances follower's `committedLogId_`
- Historical: PR #568 — no role/status checks after WAL append; ABA term detection missing
- Historical: PR #1593 — three replicas diverge into permanently inconsistent states
- Historical: PR #2483 — follower rollback past committed entries
- Historical: #5881 — massive unnecessary rollback on overlapping log retransmit (OPEN, unfixed)

**Affected code paths**:
- `appendLogsInternal()` (leader WAL write: RaftPart.cpp:874-906)
- `processAppendLogResponses()` (majority ack handling: RaftPart.cpp:1000-1135)
- `Host::appendLogsInternal()` response handler (Host.cpp:190-280)
- `processHeartbeatRequest()` (RaftPart.cpp:1895-1952)
- `processAppendLogRequest()` (follower log matching: RaftPart.cpp:1610-1830)

**Suggested modeling approach**:
- Variables: track `lastLogId` separate from WAL state; model Host's `lastLogIdSent_` per follower
- Actions: split heartbeat (no commit advance) from appendLog (with commit advance)
- Model the ABA scenario: leader loses and regains leadership, old response processed in new term
- Invariant target: `CommitIndexMonotonicity` — `committedLogId_` never decreases; `LogMatching` — matching index+term implies identical prefix

**Priority**: MEDIUM
**Rationale**: 5+ historical bugs. The heartbeat-doesn't-commit gap is a known design choice but can cause stale reads. The Host ABA is a new finding. Model checking can explore the term cycling scenario.

---

### Family 5: Pre-Vote Implementation Undermines Its Own Purpose (MEDIUM)

**Mechanism**: Nebula's pre-vote implementation causes the recipient to step down and update its term when the pre-vote sender has a higher actual term — exactly the disruption pre-vote was designed to prevent. Combined with not resetting election timeout on pre-vote receipt, this creates election storms when partitioned nodes rejoin.

**Evidence**:
- Code analysis: RaftPart.cpp:1522-1528 — pre-vote with higher term causes step-down (`role_ = FOLLOWER`, `term_ = req.get_term() - 1`)
- Code analysis: RaftPart.cpp:1572-1575 — pre-vote grant returns early without resetting `lastMsgRecvDur_`
- Code analysis: RaftPart.cpp:1247-1253 — no term staleness check for pre-vote responses
- Code analysis: RaftPart.cpp:1256 — pre-vote responses can escalate candidate's term
- Historical: PR #3415 — 7 bugs introduced by pre-vote implementation
- Historical: PR #3322 — pre-vote added to fix election disruption from stale nodes (but implementation is flawed)
- Historical: #3439 — election takes 20x expected time due to unnecessary delays

**Affected code paths**:
- `processAskForVoteRequest()` pre-vote path (RaftPart.cpp:1516-1576)
- `processElectionResponses()` (RaftPart.cpp:1247-1253, 1256, 1268-1272)
- `statusPolling()` (RaftPart.cpp:1401-1424)

**Suggested modeling approach**:
- Actions: `SendPreVote` (doesn't increment term), `ReceivePreVote` (currently: steps down; should: no state change)
- Model a partitioned node accumulating high term, then reconnecting and sending pre-votes
- Invariant target: `PreVoteNonDisruptive` — pre-vote should not cause leader step-down or term escalation

**Priority**: MEDIUM
**Rationale**: The pre-vote implementation has caused 7+ bugs (PR #3415). The step-down-on-prevote behavior is a direct deviation from Ongaro's pre-vote spec. Model checking can show whether a partitioned-then-rejoining node triggers unnecessary elections.

---

### Family 6: WAL Durability Gaps (LOW for TLA+ — HIGH for system)

**Mechanism**: Multiple durability gaps in the WAL: no fsync by default, no fsync after ftruncate in rollback, no fsync on parent directory after file creation. Acknowledged Raft commits can be silently lost on crash.

**Evidence**:
- Code analysis: FileBasedWal.cpp:18 — `DEFINE_bool(wal_sync, false, ...)` (default no-fsync)
- Code analysis: FileBasedWal.cpp:360-368 — `rollbackInFile` does not fsync after ftruncate
- Code analysis: FileBasedWal.cpp:302-303 — no fsync on parent directory after file creation
- Code analysis: FileBasedWal.cpp:480-484 — partial write → LOG(FATAL) crash
- Historical: #531 — data loss from async WAL flusher
- Historical: PR #729 — WAL changed to write() per log (from buffered)
- Historical: PR #1194 — crash recovery for partially written WAL entries
- Historical: #5884 — storaged can't start due to empty WAL file (OPEN, unfixed)

**Affected code paths**: `FileBasedWal::appendLogInternal()`, `rollbackInFile()`, `prepareNewFile()`, `scanLastWal()`

**Priority**: LOW (for TLA+ modeling)
**Rationale**: WAL durability is critical for system safety but is better verified by integration tests and crash testing than by TLA+ model checking. The fsync gap can be noted as an assumption in the spec: "WAL writes are durable" (optimistic) or modeled as "crash can lose unflushed writes" (pessimistic).

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Non-persisted term/vote + crash recovery | Family 1: violates core Raft safety (vote-once-per-term) | Separate `persistedTerm` (from WAL lastLogTerm) vs. `term` (volatile). Crash recovers from WAL only. |
| Leader lease without CheckQuorum | Family 2: confirmed linearizability violation (#5352) | `leaseValid` variable + `BlindFollowerElection` action that bypasses timeout |
| isBlindFollower bypass | Family 2: enables fast election that overlaps with valid lease | Boolean per server, cleared after first heartbeat from leader |
| Snapshot-leadership race | Family 3: 7+ bugs, new finding (H-5/H-6/H-11) | Model snapshot as multi-step action; leadership change mid-snapshot should invalidate |
| Separate heartbeat path (no commit advance) | Family 4: heartbeat doesn't advance follower commitIndex | Split into `SendHeartbeat` (no logs, no commit) and `SendAppendEntries` (with logs + commit) |
| Host response without term check (ABA) | Family 4: stale responses from old term can corrupt Host state | Model delayed RPC responses across leadership changes |
| Pre-vote with step-down | Family 5: defeats pre-vote purpose, enables election storms | Model pre-vote as state-changing (current impl) to show it causes disruption |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WAL file management details | Family 6: durability is best verified by crash tests, not model checking |
| AtomicLogBuffer concurrency | C++ memory model issue, not protocol logic |
| Thrift RPC transport | Network abstraction; model as async message delivery |
| RocksDB interactions | Storage engine details outside Raft protocol scope |
| Learner/Listener distinction | Low bug density; learner voting handled by quorum calculation |
| Log batching / AppendLogsIterator | Performance optimization, not safety-relevant |
| Thread pool starvation (#5358) | Operational concern, not protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-persisted vote | `persistedTerm`, WAL-derived recovery | Model crash recovery using WAL lastLogTerm | Family 1 |
| Leader lease | `leaseValid`, `lastHeartbeatAck` | Track lease validity window | Family 2 |
| Blind follower | `isBlindFollower` per server | Model immediate election on restart | Family 2 |
| Snapshot lifecycle | `snapshotInProgress`, `snapshotTerm` | Track multi-step snapshot + leadership interaction | Family 3 |
| Split heartbeat/append | (action split, no new vars) | Model heartbeat not advancing commit | Family 4 |
| Delayed RPC responses | `pendingResponses` with term tags | Model ABA from stale responses | Family 4 |
| Pre-vote with step-down | `isPreVote` flag on vote messages | Model pre-vote causing term escalation | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Family 1 (crash + re-vote) |
| LogMatching | Safety | Matching term at same index implies identical prefix | Family 4 (rollback correctness) |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Families 1, 4 |
| VoteOncePerTerm | Safety | Each server votes for at most one candidate per term | Family 1 (non-persisted vote) |
| NoStaleLeaseRead | Safety | If leader serves a read under lease, no other leader has committed a write | Family 2 |
| CommitIndexMonotonicity | Safety | committedLogId never decreases on any server | Family 4 |
| SnapshotTermConsistency | Safety | Snapshot completion only updates state if the initiating term is still current | Family 3 |
| PreVoteNonDisruptive | Safety | Pre-vote should not cause current leader to step down (violated in impl) | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-A | Crash + restart → node votes twice in same term | VoteOncePerTerm, ElectionSafety | 1 |
| F2-A | Blind follower starts election while old leader's lease valid | NoStaleLeaseRead | 2 |
| F2-B | Lease calculation underflow makes expired lease appear valid | NoStaleLeaseRead | 2 |
| F3-A | Leadership change during snapshot → Host state corrupted | SnapshotTermConsistency | 3 |
| F3-B | SnapshotManager leadership check fails → Host permanently wedged | Liveness (snapshot must eventually complete or fail cleanly) | 3 |
| F4-A | Leader loses/regains leadership → old Host response updates new term state | LogMatching | 4 |
| F4-B | Heartbeat-only period → follower commit lags leader indefinitely | CommitIndexMonotonicity (liveness variant) | 4 |
| F5-A | Partitioned node rejoins → pre-vote causes leader step-down | PreVoteNonDisruptive | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T-1 | Raw `this` capture in heartbeat callback (UAF on shutdown) | ASan test: destroy RaftPart with pending heartbeat futures |
| T-2 | `removeSpace` iterator invalidation when removing learner parts | Unit test with learner parts during space removal |
| T-3 | `backup()` iterates `spaces_` without lock (concurrent modification) | TSan test: concurrent addSpace + backup |
| T-4 | `batchWriteWithoutReplicator` moves batch in loop (only first engine gets data) | Unit test with multiple engines |
| T-5 | WAL fsync gaps: committed data lost on crash | Crash injection test with wal_sync=false |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C-1 | `processAppendLogResponses` step-down missing `onLostLeadership` / `host->pause()` | Add callbacks matching other step-down paths |
| C-2 | `removeListenerSpace` never erases space from map | Add `spaceListeners_.erase(spaceIt)` |
| C-3 | `lastHeartbeatTime_` not atomic (data race, benign on x86) | Change to `std::atomic<int64_t>` |
| C-4 | Infinite retry loop in processAppendLogResponses with no timeout | Add timeout or max-retry bound |
| C-5 | Massive unnecessary rollback on overlapping retransmit (#5881, OPEN) | Compare overlapping entries before rollback |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/nebula/analysis-report.md`
- **Key source files**:
  - `artifact/nebula/src/kvstore/raftex/RaftPart.cpp` (~2271 lines — state machine, election, replication, heartbeat)
  - `artifact/nebula/src/kvstore/raftex/RaftPart.h` (~891 lines — class definition, state variables)
  - `artifact/nebula/src/kvstore/raftex/Host.cpp` (~535 lines — per-peer replication, response handling)
  - `artifact/nebula/src/kvstore/raftex/SnapshotManager.cpp` (~142 lines — snapshot transfer)
  - `artifact/nebula/src/kvstore/wal/FileBasedWal.cpp` (~740 lines — WAL persistence)
- **GitHub issues**: #685, #2405 (Family 1); #5352, #5379, #5265 (Family 2); #4479, #3909, #4372, #3710, #5240 (Family 3); #3140, #5881 (Family 4); #3439 (Family 5); #531, #5884 (Family 6)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
