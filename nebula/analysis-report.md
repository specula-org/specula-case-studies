# Analysis Report: vesoft-inc/nebula Raft Consensus

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Bug-fix commits analyzed (git history) | 40 |
| GitHub issues deeply read (full comments) | 60+ (across 3 parallel search agents) |
| Confirmed bugs from issues | 19 |
| Core source files deeply analyzed | 10 |
| Parallel analysis agents launched | 9 (4 issue/git, 5 deep code) |
| Bug Families identified | 6 |
| New findings from code analysis | 30+ |

---

## 1. Codebase Structure

### 1.1 Core Raft Implementation

| File | LOC | Responsibility |
|------|-----|---------------|
| `src/kvstore/raftex/RaftPart.cpp` | 2,271 | Core consensus: election, replication, heartbeat, commit, snapshot receive |
| `src/kvstore/raftex/RaftPart.h` | 891 | Class definition, state variables, public interfaces |
| `src/kvstore/raftex/Host.cpp` | 535 | Per-peer connection, log replication to followers, response handling |
| `src/kvstore/raftex/Host.h` | 295 | Host class definition, request batching |
| `src/kvstore/raftex/RaftexService.cpp` | 178 | Thrift RPC handler, thread dispatch |
| `src/kvstore/raftex/SnapshotManager.cpp` | 142 | Snapshot batching and sending |
| `src/kvstore/wal/FileBasedWal.cpp` | ~740 | WAL persistence, rotation, recovery |
| `src/kvstore/wal/AtomicLogBuffer.cpp` | ~215 | Lock-free in-memory WAL buffer |
| `src/kvstore/NebulaStore.cpp` | ~1,500 | Higher-level store using Raft |

**Total**: ~6,700 LOC core logic

### 1.2 Concurrency Model

```
Thrift Server
├── IO Thread Pool (folly::IOThreadPoolExecutor)
│   └── Heartbeat requests (async_eb_heartbeat) — acquires raftLock_
│
└── Worker Thread Pool (GenericThreadPool)
    ├── AskForVote requests — acquires raftLock_
    ├── AppendLog requests — acquires raftLock_
    ├── SendSnapshot requests — acquires raftLock_
    └── statusPolling() timer — acquires raftLock_ transiently

Per-Peer: Host objects with own lock_
Background: bgWorkers_ pool for delayed tasks, election callbacks
```

**Key locks**: `raftLock_` (protects role, term, leader, status, hosts), `logsLock_` (protects log cache), `Host::lock_` (per-peer state)

### 1.3 Key State Variables

| Variable | Type | Protected By | Notes |
|----------|------|-------------|-------|
| `term_` | TermID (int64_t) | raftLock_ | **NOT persisted** — recovered from WAL |
| `role_` | Role enum | raftLock_ | LEADER/FOLLOWER/CANDIDATE/LEARNER |
| `votedAddr_` / `votedTerm_` | HostAddr/TermID | raftLock_ | **NOT persisted** — reset to zero on restart |
| `lastLogId_` / `lastLogTerm_` | LogID/TermID | raftLock_ | Volatile cache of WAL state |
| `committedLogId_` / `committedLogTerm_` | LogID/TermID | raftLock_ | Last applied to state machine |
| `isBlindFollower_` | bool | raftLock_ | Bypasses election timeout on startup |
| `commitInThisTerm_` | bool | raftLock_ | Guards lease reads |
| `lastMsgAcceptedTime_` / `lastMsgAcceptedCostMs_` | uint64_t | raftLock_ | Lease timing |
| `replicatingLogs_` | atomic<bool> | — | Serializes leader's replication pipeline |
| `bufferOverFlow_` | atomic<bool> | — | Flow control flag |

---

## 2. Git History Mining

### 2.1 Bug-Fix Commit Catalog (40 commits)

**Distribution by component**:

| Component | Bug-Fix Count |
|-----------|--------------|
| Log replication | 16 |
| Election | 10 |
| Snapshot | 10 |
| Concurrency/Locking | 8 |
| WAL persistence/recovery | 7 |
| Lifecycle/shutdown | 4 |
| Leader lease | 3 |
| Membership change | 2 |

**Distribution by severity**:

| Severity | Count |
|----------|-------|
| Critical | 13 |
| High | 16 |
| Medium | 10 |
| Low | 2 |

### 2.2 Critical Bug-Fix Commits

| Commit | Summary | Root Cause | Component |
|--------|---------|-----------|-----------|
| `0441f67` | Fix raft bugs (#296) | Vote re-grant rejected; missing WAL rollback on leader step-down; missing heartbeat timer reset | Election, Replication |
| `23571a0` | Fix bugs in RAFT (#568) | No role/status checks after WAL append; ABA term problem | Replication, Election |
| `ff8daf1` | Fix split brain (#4479) | WAITING_SNAPSHOT rejects votes; snapshot continues from stale leader; non-leader sends heartbeats | Election, Snapshot |
| `9ebc49d` | [Raft] make me crazy (#3172) | 6 interrelated bugs: election blocks forever, infinite snapshot reset, deadlock in Host::reset under raftLock_ | Election, Replication, Snapshot |
| `8585de6` | Fix node can't accept logs after snapshot (#3909) | WAL `getLogTerm` returns -1 after snapshot (empty WAL), treated as mismatch | Replication, Snapshot |
| `b3a37f5` | Fix crash after snapshot (#4372) | CHECK_LE fails on empty WAL after snapshot; term corruption during snapshot | Snapshot |
| `0b88395` | Fix three copies under different states (#1593) | `lastLogIdSent_` off-by-one; E_LOG_STALE handled without resend | Replication |
| `7c4e372` | Fix problems after pre-vote (#3415) | 7 bugs: wrong lastLogTerm_ at startup, missing self-vote, WAL not rolled back, stale leader, role changed before log check | Election (pre-vote) |
| `04ec79a` | Scan last WAL for truncation (#1194) | Partial WAL entry after crash treated as valid data | WAL recovery |
| `47962e7` | WAL write() per message (#729) | In-memory WAL buffer lost on crash | WAL durability |
| `6416f59` | Fix follower commit beyond log (#681) | Follower commits up to `req.committed_log_id` without checking local log size | Replication |

### 2.3 Bug Hotspot Files

| Rank | File | Bug-Fix Commits |
|------|------|----------------|
| 1 | RaftPart.cpp | 26 |
| 2 | RaftPart.h | 11 |
| 3 | NebulaStore.cpp | 11 |
| 4 | FileBasedWal.cpp | 10 |
| 5 | SnapshotManager.cpp | 8 |
| 6 | Host.cpp | 7 |

---

## 3. GitHub Issue Analysis

### 3.1 Confirmed Bugs from Issues

| # | Issue | Title | Severity | Fixed? | Bug Family |
|---|-------|-------|----------|--------|-----------|
| 1 | #685 | Raft bugs about term | CRITICAL | Yes (PR #3435) | 1 |
| 2 | #2405 | Server sends 2 votes in one term | HIGH | Partial (PR #3435) | 1 |
| 3 | #5352 | Break linear consistency (two leaders + lease read) | HIGH | Yes (v3.5.0) | 2 |
| 4 | #5379 | Follower should check lease before granting vote | HIGH | Yes (v3.5.0) | 2 |
| 5 | #5265 | RocksDB ingest causes leader lease invalid | MEDIUM | Yes (PR #5534) | 2 |
| 6 | #3710 | Raft snapshot data inconsistency | HIGH | Yes (v3.0.0) | 3 |
| 7 | #5240 | sendSnapshot doesn't transfer real snapshot | HIGH | Yes (v3.5.0) | 3 |
| 8 | #3140 | Raft append log may block forever | HIGH | Yes (PR #3435) | 4 |
| 9 | #3147 | Raft deadlock | CRITICAL | Yes (PR #3141) | 4 |
| 10 | #5881 | Massive unnecessary rollback (spike latency) | HIGH | **NO** (PR open) | 4 |
| 11 | #3439 | Election takes very long time | MEDIUM | Yes (v3.1.0) | 5 |
| 12 | #531 | Data loss due to WAL async flusher | CRITICAL | Yes | 6 |
| 13 | #5884 | Storaged can't start (empty WAL file) | HIGH | **NO** (open) | 6 |
| 14 | #4472 | Deadlock in config change (2-node cluster) | MEDIUM | WONTFIX | Config |
| 15 | #3386 | Member change fails but returns success | HIGH | Yes (v3.1.0) | Config |
| 16 | #2893 | Edge loss during frequent leader changes | HIGH | Yes (v2.6.0) | 4 |
| 17 | #3030 | Leader change falsely reports failure | HIGH | Yes (PR #3880) | 4 |
| 18 | #2723 | Lease read clock bounce (non-x86) | MEDIUM | WONTFIX | 2 |
| 19 | #6011 | Meta snapshot copies leader commitLogId | HIGH | **NO** (open) | 3 |

### 3.2 Open / Unfixed Bugs

| Issue | Description | Impact |
|-------|-------------|--------|
| #5881 | Massive unnecessary rollback on overlapping retransmit | Multi-second latency spikes under load |
| #5884 | Empty WAL file prevents storaged startup | Node can't restart |
| #6011 | Meta snapshot sync propagates leader commitLogId to follower | Metadata loss after follower restart |
| #4472 | Config change deadlock in 2-node cluster | Permanent partition unavailability (WONTFIX) |

### 3.3 Design Defects (Acknowledged)

| Issue | Description |
|-------|-------------|
| #3111 | No ReadIndex or CheckQuorum mechanism (lease-only reads) |
| #5358 | Shared thread pool between storage queries, raft, and RocksDB |
| #5570 | Leader keeps sending appendLog to downed followers |

---

## 4. Deep Code Analysis Findings

### 4.1 Election & Vote Handling (RaftPart.cpp)

| ID | Severity | Finding | Lines | Model-Checkable |
|----|----------|---------|-------|-----------------|
| E-1 | HIGH | Pre-vote causes step-down on higher term (defeats pre-vote purpose) | 1522-1528 | Yes |
| E-2 | HIGH | Missing `onLostLeadership` + `host->pause()` on AppendLog response step-down | 1025-1037 | Yes |
| E-3 | HIGH | Raw `this` capture in heartbeat callback (potential UAF) | 2091 | No |
| E-4 | MEDIUM | Pre-vote step-down + no election timeout reset = election storm on rejoin | 1401-1424 | Yes |
| E-5 | MEDIUM | `handleElectionResponses` sets leader and resets hosts without re-checking role | 1376-1395 | Yes |
| E-6 | MEDIUM | Pre-vote responses can escalate candidate's term | 1256 | Yes |
| E-7 | LOW | `votedTerm_` check conflates pre-vote and formal vote terms | 1560-1566 | Yes |
| E-8 | LOW | No term staleness check for pre-vote responses | 1247-1253 | Yes |
| E-9 | LOW | `commitInThisTerm_` set outside status check | 1378-1389 | No |

### 4.2 Log Replication & Commit (RaftPart.cpp)

| ID | Severity | Finding | Lines | Model-Checkable |
|----|----------|---------|-------|-----------------|
| R-1 | HIGH | `term_` not persisted, initialized from WAL lastLogTerm (vote-twice-per-term) | 412-414 | Yes |
| R-2 | HIGH | Infinite retry loop on failed replication with no timeout | 1129-1135 | Yes |
| R-3 | MEDIUM | `lastLogId_` stale between WAL write and majority ack | 895-906 | Yes |
| R-4 | MEDIUM | Heartbeat does NOT advance follower commitIndex | 1895-1952 | Yes |
| R-5 | MEDIUM | `checkAppendLogResult` fails ALL buffered logs including untried ones | 2154-2176 | Yes |
| R-6 | MEDIUM | Lease calculation can underflow with uint64 arithmetic | 2254-2268 | Yes |
| R-7 | MEDIUM | Split-brain accepted with only LOG(ERROR) in verifyLeader | 1850-1858 | Yes |
| R-8 | LOW | Leader commits without raftLock — stale committedLogId briefly visible | 1068-1098 | Yes |
| R-9 | LOW | `committedLogId_` goes to 0 during snapshot reset | 2178-2184 | Yes |

### 4.3 Host / Peer Management (Host.cpp)

| ID | Severity | Finding | Lines | Model-Checkable |
|----|----------|---------|-------|-----------------|
| H-1 | HIGH | No term check in AppendLog response handler (ABA problem) | 190-234 | Yes |
| H-5 | HIGH | Snapshot callback updates state without term validation | 358-374 | Yes |
| H-6 | HIGH | `reset()` doesn't wait for in-flight snapshot | Host.h:85-96 | Yes |
| H-11 | HIGH | Unfulfilled promise permanently wedges Host in snapshot mode | SnapshotManager.cpp:41-46 | Yes |
| H-4 | MEDIUM | Snapshot failure doesn't notify follower (TODO acknowledged) | 368-373 | Yes |
| H-10 | MEDIUM | SnapshotManager doesn't re-check leadership at end of transfer | SM.cpp:82-85 | Yes |
| H-2 | LOW | `lastHeartbeatTime_` not atomic (data race on non-x86) | Host.h:227-232 | No |
| H-7 | LOW | E_RAFT_LOG_GAP/STALE treated identically to SUCCEEDED | 191-193 | Yes |

### 4.4 WAL Persistence (FileBasedWal.cpp)

| ID | Severity | Finding | Lines | Model-Checkable |
|----|----------|---------|-------|-----------------|
| W-1 | CRITICAL | Default no-fsync: committed entries lost on crash (up to 16MB) | 18, 486 | Yes |
| D-2 | HIGH | No fsync on parent directory after new WAL file creation | 302-303 | Yes |
| RB-2 | HIGH | rollbackInFile does not fsync after ftruncate — rolled-back entries reappear | 360-368 | Yes |
| W-2 | MEDIUM | Non-atomic multi-field metadata update (lastLogId_, lastLogTerm_, buffer push) | 489-497 | Yes |
| CR-1 | MEDIUM | Only last WAL file validated on recovery; non-last checked only at tail | 150-184 | No |
| CR-3 | MEDIUM | No checksums in WAL format (bit-rot undetectable) | — | No |
| C-1 | MEDIUM | AtomicLogBuffer head_/tail_ stores use memory_order_relaxed (unsafe on ARM) | ALB.cpp:88 | No |
| C-4 | MEDIUM | Known GC race in AtomicLogBuffer::releaseRef (issue #390) | ALB.cpp:167-213 | No |

### 4.5 Service Layer / NebulaStore

| ID | Severity | Finding | Lines | Model-Checkable |
|----|----------|---------|-------|-----------------|
| S-1 | HIGH | `removeSpace` iterator invalidation when removing learner parts | NS.cpp:530-536 | No (C++ bug) |
| S-2 | HIGH | `backup()` iterates `spaces_` without lock | NS.cpp:1330-1340 | No (C++ bug) |
| S-3 | MEDIUM | Data race on non-atomic `code` in `ingest()` and `compact()` | NS.cpp:988-1018 | No |
| S-4 | MEDIUM | `removeListenerSpace` never erases space from map | NS.cpp:616-624 | No |
| S-5 | MEDIUM | `batchWriteWithoutReplicator` moves batch in loop | NS.cpp:1407-1413 | No |
| S-6 | MEDIUM | IO thread raftLock_ acquisition in heartbeat handler | RP.cpp:1910 | No |

---

## 5. Bug Family Analysis

### Family 1: Non-Persisted Term/Vote

**Historical evidence**: #685, #2405, PR #3415 (7 sub-bugs), PR #568
**New findings**: R-1 (term from WAL), R-7 (split-brain LOG handler exists)
**Pattern**: The implementation fundamentally deviates from Raft's persistence requirements. The WAL's `lastLogTerm` provides a lower bound on the term but not the exact persisted term. `votedFor` is completely volatile.
**Severity ranking**: #1 — violates core Raft safety property

### Family 2: Leader Lease / Split Brain

**Historical evidence**: #5352, #5379, #5265, PR #5534, PR #5271, #2723, #3111
**New findings**: R-6 (lease underflow), E-8 (blind follower bypass)
**Pattern**: Lease-based reads without CheckQuorum, combined with mechanisms that allow fast elections (blind follower), create a window where two nodes can both serve reads — one under lease, one as new leader.
**Severity ranking**: #2 — confirmed linearizability violation

### Family 3: Snapshot Lifecycle Race Conditions

**Historical evidence**: #4479, #3909, #4372, #3710, #5240, PR #1769, PR #4019
**New findings**: H-5, H-6, H-11, H-10 (snapshot-leadership race cluster)
**Pattern**: Snapshot transfers are long-running operations that fundamentally interact with leadership changes. Multiple code paths fail to re-validate term after snapshot completes.
**Severity ranking**: #3 — high bug density, new unfixed race conditions

### Family 4: Log Replication State Desynchronization

**Historical evidence**: PR #568, PR #1593, PR #2483, #3140, #5881, #3147, #3030
**New findings**: H-1 (ABA in Host), E-2 (missing callbacks), R-3 (stale lastLogId), R-4 (heartbeat no commit)
**Pattern**: Multiple code paths update replication state variables under different locks and at different times. The separation of heartbeat (IO thread) from replication (worker thread) creates visibility gaps.
**Severity ranking**: #4 — high historical count but many already fixed

### Family 5: Pre-Vote Implementation

**Historical evidence**: PR #3322, PR #3415, #3439
**New findings**: E-1, E-4, E-6, E-7
**Pattern**: Pre-vote was added to prevent election disruption but the implementation causes state changes (step-down, term update) on the recipient, defeating its purpose.
**Severity ranking**: #5 — functional deviation from spec, moderate impact

### Family 6: WAL Durability

**Historical evidence**: #531, PR #729, PR #1194, #5884, #132, #926
**New findings**: W-1 (no-fsync default), D-2 (no dir-fsync), RB-2 (no fsync after truncate)
**Pattern**: Multiple layers of missing fsync calls mean committed Raft entries can be lost on crash.
**Severity ranking**: #6 for TLA+ modeling (better for crash testing) — but CRITICAL for system safety

---

## 6. Reference Deviations from Raft Paper (Ongaro 2014)

| Raft Rule | Implementation | Deviation | Risk |
|-----------|---------------|-----------|------|
| currentTerm persisted to stable storage | `term_` = `wal_->lastLogTerm()` on restart | MAJOR: WAL lastLogTerm is a lower bound, not exact term | Vote-twice-per-term |
| votedFor persisted to stable storage | `votedAddr_`/`votedTerm_` reset to zero on restart | MAJOR: No persistent vote record | Vote-twice-per-term |
| Pre-vote does not change state (Ongaro §9.6) | Recipient steps down and updates term on higher-term pre-vote | MODERATE: Pre-vote becomes disruptive | Election storms on rejoin |
| AppendEntries heartbeat carries leaderCommit | Separate heartbeat RPC does not advance commit | MODERATE: Followers can have stale commit | Stale follower reads |
| Leader checks response term, steps down | Host response handler doesn't check term | MODERATE: ABA if leadership cycles | State corruption |
| Election timeout randomized | `isBlindFollower_` bypasses timeout entirely on restart | MODERATE: Enables fast election | Conflicts with lease |
| At most one leader per term (Election Safety) | `verifyLeader` has explicit split-brain LOG(ERROR) handler | SYMPTOM: Implementation acknowledges this can happen | Safety violation |

---

## 7. Methodology Notes

### 7.1 Search Strategy

- Git history: 12 keyword searches across raftex/ and wal/ directories
- GitHub issues: 3 parallel search agents, 20+ keyword queries each
- Deep analysis: 5 parallel code analysis agents (election, replication, Host, WAL, service layer)

### 7.2 False Positives Excluded

| Finding | Reason for Exclusion |
|---------|---------------------|
| `termId()` lock-free read | Benign on x86 (hardware atomicity for aligned int64), not a safety issue |
| `bufferOverFlow_` TOCTOU | `std::atomic_bool` — the early check is a benign optimization |
| Pre-vote `votedTerm_` conflation | Conservative (rejects rather than accepts), no safety impact |
| `isLearner_` without lock | Single-byte bool, practically atomic on all platforms |
| Redundant `leader_ = addr_` in handleElectionResponses | Idempotent write, no correctness issue |

### 7.3 Limitations

- Analysis covers code at the current HEAD of the repository. Some bugs may have been fixed in branches not visible in the main history.
- The WAL analysis focused on `FileBasedWal.cpp` and `AtomicLogBuffer.cpp`. The `InMemoryLogBuffer` (referenced in old issues) may have been refactored away.
- Issue search was limited to English-language issues. Some issues may be in Chinese (the primary development language for this project).
- The `NebulaStore.cpp` analysis focused on Raft-related methods. The full store has many more methods not analyzed.
