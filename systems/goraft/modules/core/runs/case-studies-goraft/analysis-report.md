# Analysis Report: goraft/raft

**System**: goraft/raft — Go Raft consensus library
**GitHub**: https://github.com/goraft/raft
**Language**: Go
**Reference**: Raft (Ongaro & Ousterhout, 2014)
**Status**: Unmaintained since ~2014 (maintainers moved to etcd/raft)
**Analysis date**: 2026-03-19

---

## 1. Codebase Structure

### 1.1 Scale

| Category | Files | LOC |
|----------|-------|-----|
| Core logic | 3 | ~2425 |
| RPC messages | 2 | ~268 |
| Snapshot | 1 | ~304 |
| Transport | 2 | ~341 |
| Commands/SM | 4 | ~193 |
| Support | 4 | ~245 |
| Tests | 8 | ~1377 |

**Core files**:
- `server.go` (1473 lines) — state machine, event loops, RPC handlers
- `log.go` (632 lines) — log persistence, truncation, compaction
- `peer.go` (320 lines) — heartbeat goroutines, replication

### 1.2 Architecture

- **Event loop**: Single main goroutine dispatches to state-specific loops (`followerLoop`, `candidateLoop`, `leaderLoop`, `snapshotLoop`)
- **Heartbeat**: Per-peer goroutines (`Peer.heartbeat()`) run independently of main loop
- **Synchronization**: `server.mutex` (RWMutex), `log.mutex` (RWMutex), per-peer `sync.RWMutex`
- **Communication**: Buffered channel (`c chan *ev`, 256) for internal events; synchronous `send()` and asynchronous `sendAsync()`
- **Persistence**: File-based log (protobuf-encoded entries), JSON config file, snapshot files
- **No stable storage interface**: Unlike hashicorp/raft's `StableStore`, goraft has no abstraction for persisting term/votedFor

### 1.3 Key Architectural Deviations from Raft Paper

1. **currentTerm and votedFor are NOT persisted** — memory-only variables
2. **Heartbeat runs in independent goroutines** — reads server state without locks
3. **Membership changes via log commands** (JoinCommand/LeaveCommand) — quorum recalculated when JoinCommand committed
4. **No PreVote, no pipeline replication, no leader lease**
5. **Snapshot via custom 2-phase protocol** — SnapshotRequest then SnapshotRecoveryRequest, no InstallSnapshot RPC

---

## 2. Coverage Statistics

### 2.1 Git History Mining

| Metric | Count |
|--------|-------|
| Total commits in repo | 552 |
| Bug-fix commits analyzed | 46 |
| Critical severity | 20 |
| High severity | 18 |
| Medium severity | 7 |
| Low severity | 1 |

**By component**:

| Component | Bugs | Critical | High |
|-----------|------|----------|------|
| Election | 8 | 4 | 3 |
| Replication | 6 | 3 | 2 |
| Concurrency/Race | 12 | 2 | 6 |
| Deadlock | 5 | 4 | 1 |
| Snapshot | 7 | 3 | 3 |
| Persistence/Log | 6 | 4 | 2 |
| Infrastructure | 2 | 0 | 1 |

### 2.2 GitHub Issues/PRs

| Metric | Count |
|--------|-------|
| Total issues | 70 |
| Total PRs | 180 |
| Issues deeply read | 45+ |
| PRs deeply read | 35+ |
| Confirmed bugs | 30 |
| Design defects | 6 |
| User error / misconfiguration | 3 |
| Unfixed bugs (library unmaintained) | 9 |

---

## 3. Bug-Fix Commit Details

### 3.1 Election Bugs (8)

| Commit | Summary | Severity |
|--------|---------|----------|
| `53d43de` | Election timeout reset on every loop iteration, followers never time out | Critical |
| `fa3ec69` | `break` in `select` only breaks select, not outer loop; candidate never exits | Critical |
| `605f671` | Leader's term in AE request read after step-down, sends wrong term | Critical |
| `cbceb05` | State race: Do() appends entries as follower with leader's term | Critical |
| `b6e9a8c` | Timer goroutine races on internalTimer access | High |
| `c544519` | Timer initialized before goroutine ready to receive | High |
| `0d2cb8a` | Election timer channel nil race, votedFor accessed without lock | High |
| `8efbb15` | Peer heartbeat timer starts before goroutine ready | Medium |

### 3.2 Replication Bugs (6)

| Commit | Summary | Severity |
|--------|---------|----------|
| `0916bba` | Leader updates prevLogIndex from stale-term response | Critical |
| `3f98381` | Leader skips fsync before committing log entries | Critical |
| `d2d1e26` | Commit advances past JoinCommand without quorum recalculation | Critical |
| `2987111` | Missing step-down check when peer reports higher commitIndex | High |
| `5f64d15` | Off-by-one: `>` should be `>=` for prevLogIndex update | High |
| `007b8de` | Commit channel cleaned by sender, receiver blocks on nil channel | High |

### 3.3 Concurrency/Race Bugs (12)

| Commit | Summary | Severity |
|--------|---------|----------|
| `e63296e` | Stop() closes log before goroutines finish; use-after-close panics | Critical |
| `9e88344` | JoinCommand.Apply modifies peers inside log apply, races with server | High |
| `b6b4e57` | send() on uninitialized stopped channel | High |
| `f762c2f` | Stop() sets state directly, races with State() reads | High |
| `1c4fa98` | processAE sets s.state directly without lock | High |
| `d474840` | Term/CommitIndex accessors read without locks | High |
| `107888a` | Peer heartbeat grabs server state without lock | High |
| `bf84fb1` | LogEntries() returns internal slice without lock during append | Medium |
| `0ccec83` | Extra setState(Follower) on every AE causes spurious events | Medium |
| `7b3522c` | lastActivity read/written without lock from heartbeat goroutines | Medium |
| `cbc15dc` | ResponseHeaderTimeout set per-request, races with concurrent HTTP | Medium |
| `776a2cc` | Server map access in tests, peer.internalFlush without lock | Medium |

### 3.4 Deadlock Bugs (5)

| Commit | Summary | Severity |
|--------|---------|----------|
| `12e7a19` | removePeer holds log lock, peer.stopHeartbeat needs log lock | Critical |
| `78ce625` | setCurrentTerm holds server mutex, peer flush needs server mutex | Critical |
| `7defa72` | log.currentIndex takes RLock, ApplyFunc calls currentIndex again (non-reentrant) | Critical |
| `3392f81` | Initialize() holds mutex, log replay applies JoinCommand calling AddPeer needing mutex | Critical |
| `75c9644` | processCommand blocks on sendAsync to full channel while holding event loop | High |

### 3.5 Snapshot Bugs (7)

| Commit | Summary | Severity |
|--------|---------|----------|
| `8f47758` | `req.State = req.State` self-assignment instead of `req.State = pb.GetState()` | Critical |
| `c159d91` | Missing `i++` in peer iteration loop; only first peer written | Critical |
| `dbedc98` | Multiple: entries appended below startIndex, commitIndex decreases, recovery issues | High |
| `2802722` | Server cannot be inited after loading snapshot (isEmpty check wrong) | High |
| `67329dc` | JSON struct tags have spaces, reflect ignores them silently | High |
| `30ecfdb` | Snapshot mkdir error check inverted | Medium |
| `7a2b6e1` | Init reports error on existing snapshot directory | Medium |

### 3.6 Persistence/Log Bugs (6)

| Commit | Summary | Severity |
|--------|---------|----------|
| `c79ddde` | `io.Read` instead of `io.ReadFull` — partial reads corrupt log entries | Critical |
| `b66cb1a` | Log file replacement: old removed before new synced/renamed | Critical |
| `8c7779d` | appendEntry has no lock, appendEntries has no fsync | Critical |
| `b01e3e7` | Log recovery: missing break after truncation, corrupt entry appended | Critical |
| `083797f` | Log decode returns wrong read size (missing header length) | High |
| `8ca39ae` | writeFileSynced swallows write errors | High |

---

## 4. GitHub Issue Details

### 4.1 Protocol Safety Bugs (Confirmed)

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #8 | currentTerm and votedFor not persisted to disk (Diego Ongaro confirmed) | Fixed | Critical |
| #12 | Uncommitted entries not written to disk; no NOP on leader election | Fixed | High |
| #118 | Commit index calculation uses ascending sort instead of descending | Fixed (PR #119) | Critical |
| #53 | Candidate doesn't step down on AE from same-term leader | Fixed | High |
| #69 | Restart node applies all log entries including uncommitted | Fixed | High |
| #13 | No randomized timeout after split vote (Diego Ongaro confirmed) | Fixed | Medium |
| #162 | Leader updates peer prevLogIndex from higher-term response | Fixed | High |

### 4.2 Concurrency/Deadlock Bugs (Confirmed)

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #168 | Race condition during leader stepdown; heartbeat uses stale prevLogIndex | **OPEN** | High |
| #161 | Deadlock: setState holds mutex, event handler calls State() | **OPEN** | High |
| #100 | go test -race fails (pervasive races) | Partially fixed | Medium |
| #212 | server.Start/Stop/Init cannot be called simultaneously | **OPEN** | Medium |
| #187 | Deadlock when removing nodes (log lock ordering) | Fixed (PR #195) | High |

### 4.3 Snapshot Bugs (Confirmed)

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #235 | Wrong snapshot loaded: filenames sorted alphabetically not numerically | **OPEN** | High |
| #207 | Broken initialization after loading from snapshot (InfluxDB affected) | Fixed (PR #208) | High |
| #238 | No locking during snapshot creation | **OPEN** | High |

### 4.4 Data Integrity Bugs (Confirmed)

| Issue | Summary | Status | Severity |
|-------|---------|--------|----------|
| #191 | Partial log data read via io.Read causes corruption (RavenDB CEO reported) | Fixed (PR #192) | Critical |
| #158 | readBytes calculation wrong in log recovery | Fixed (PR #159) | Medium |

### 4.5 Design Defects

| Issue | Summary |
|-------|---------|
| #249 | No read consistency mechanism (no linearizable reads) |
| #239 | Command.Apply receives inconsistent CurrentIndex/CommitIndex during recovery |
| #116 | Hardcoded 1-second commit timeout causes false failures |
| #44 | Poor randomness in election timeout (simultaneous seeds) |
| #133 | Panics as assertions crash production systems |
| #206 | Heartbeat flooding blocks join requests |

---

## 5. Deep Analysis Findings

### 5.1 CRITICAL: currentTerm and votedFor Never Persisted (server.go:118,120)

`currentTerm` and `votedFor` are plain struct fields (server.go:118,120). The `writeConf()` function (server.go:1407-1434) only writes `CommitIndex` and `Peers` to a JSON config file. There is no `StableStore` interface. On restart, `currentTerm` is recovered from the last log entry's term (server.go:511), and `votedFor` resets to `""` (zero value).

**Consequences**:
- A server that voted in term T, then crashed before appending entries for term T, restarts with an earlier term. It can vote AGAIN in term T, violating election safety.
- A leader at term T that crashes after incrementing term but before appending entries restarts at an older term and may vote for a different candidate.

This was reported as Issue #8 and confirmed by Diego Ongaro (Raft co-author). While a fix was reportedly applied (persisting via config), the current codebase still does not persist term/votedFor through the config file.

### 5.2 CRITICAL: RequestVote Log Up-to-Date Check is Wrong (server.go:1087)

```go
if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm {
```

The Raft paper (Section 5.4.1) specifies: compare last log terms first; if equal, compare indices. The `||` formulation rejects candidates with higher terms but shorter logs. Example: server has `(term=2, index=5)`, candidate has `(term=3, index=3)`. Candidate's log is more up-to-date (higher term), but server rejects because `5 > 3`. This can prevent valid leader election.

### 5.3 HIGH: processSnapshotRequest Has No Term Check (server.go:1267-1281)

`processSnapshotRequest` performs zero term validation. The `SnapshotRequest` struct (snapshot.go:43-47) doesn't even include a `Term` field — it only has `LeaderName`, `LastIndex`, `LastTerm`. A stale leader from an old term can trigger a snapshot transition on a server that has already moved to a newer term. The handler unconditionally transitions to `Snapshotting` state (server.go:1278) if the entry doesn't match.

### 5.4 HIGH: processSnapshotRecoveryRequest Has No Term Check (server.go:1289-1313)

Accepts any snapshot recovery without verifying sender's term. Directly overwrites `s.currentTerm` (server.go:1302) without clearing `votedFor`. If the recovery sets term to a value where the server already voted, the vote is now orphaned (wrong term). If another RequestVote arrives for the same term, the server may grant it (because `votedFor != ""` is checked against `CandidateName`, not term validity).

### 5.5 HIGH: Leader May Commit Entries from Previous Terms (server.go:1022)

```go
commitIndex := indices[s.QuorumSize()-1]
```

Raft paper Section 5.4.2: "Raft never commits log entries from previous terms by counting replicas." The leader should only commit entries from its current term. The `syncedPeer` mechanism (server.go:1004) gates on whether enough peers have appended an entry from the current term, but the actual `commitIndex` is the median of ALL peers' `prevLogIndex` values, which might point to entries from old terms. A NOP is sent asynchronously (server.go:826-829) but there's a window where heartbeat responses can advance the commit index before the NOP is committed.

### 5.6 HIGH: Heartbeat Goroutines Read Server State Without Locks (peer.go:170-182)

`Peer.flush()` reads `p.server.currentTerm` (peer.go:173) and `p.server.snapshot` (peer.go:180) without holding the server mutex. The main event loop modifies `currentTerm` under the mutex (server.go:565-566), so this is a data race. The heartbeat could send an AppendEntries with a stale or torn term value. Additionally, `sendAppendEntriesRequest` reads `p.server.currentTerm` (peer.go:210) for `syncedPeer` tracking without synchronization.

### 5.7 HIGH: candidateLoop Increments Term Without Lock (server.go:747-748)

```go
s.currentTerm++
s.votedFor = s.name
```

Two separate assignments with no atomicity guarantee. Heartbeat goroutines from a previous leader tenure may still be running and can observe the incremented term with stale `votedFor`, or send AE with the candidate's new term (the server is a candidate, not a leader).

### 5.8 HIGH: compact() Writes Wrong Position Values (log.go:601-603)

```go
position, _ := l.file.Seek(0, os.SEEK_CUR)
entry.Position = position
```

`l.file` is the OLD log file, but entries are being written to `file` (the new file). After compaction, all `entry.Position` values refer to positions in the old (now deleted) file. If `truncate()` runs after compaction (log.go:451: `position := l.entries[index-l.startIndex].Position`), it truncates the new file at wrong offsets, corrupting the log.

### 5.9 HIGH: Snapshotting State Has No Direct Exit (server.go:1289-1313)

After `processSnapshotRecoveryRequest` completes, it does NOT change state back from Snapshotting. The server must wait for a subsequent `AppendEntriesRequest` or `RequestVoteRequest` with appropriate term to transition back to Follower. If the snapshot recovery changed `s.currentTerm` (server.go:1302) to the leader's last term, and the leader's current term is higher, the next AE from the leader will trigger `updateCurrentTerm` → `setState(Follower)`. But if the recovery set the same term as the leader, the AE handler works correctly. If no more AEs arrive, the server is stuck.

### 5.10 MEDIUM: commitIndex Not Automatically Persisted (log.go:397-401)

`flushCommitIndex()` exists but is never called internally. It's only exposed via `server.FlushCommitIndex()` (server.go:1401-1404) for external callers. On restart, `commitIndex` starts at 0 (or from the config file if manually flushed). Without persistence, a restarting node won't re-apply committed entries until the leader re-sends its commit index.

### 5.11 MEDIUM: Snapshot Request/Recovery Only Handled in Specific Loops

| RPC | followerLoop | candidateLoop | leaderLoop | snapshotLoop |
|-----|-------------|---------------|------------|-------------|
| AppendEntriesRequest | Yes (L695) | Yes (L793) | Yes (L849) | Yes (L876) |
| RequestVoteRequest | Yes (L702) | Yes (L796) | Yes (L853) | Yes (L879) |
| SnapshotRequest | Yes (L706) | **NO** | **NO** | **NO** |
| SnapshotRecoveryRequest | **NO** | **NO** | **NO** | Yes (L882) |
| Command | **NO** (except self-join) | **NO** | Yes (L846) | **NO** |

Snapshot-related requests arriving in wrong states are silently dropped.

---

## 6. Bug Families

### Family 1: Non-Persistent Safety State (CRITICAL)

**Mechanism**: The Raft protocol requires `currentTerm` and `votedFor` to be on stable storage before responding to RPCs. goraft stores these only in memory, allowing crash-restart to violate vote safety.

**Evidence**:
- Historical: Issue #8 (Diego Ongaro confirmed), Issue #12, Issue #69
- Code: server.go:118,120 (memory-only fields), server.go:1407-1434 (writeConf only saves CommitIndex+Peers)
- Code: log.go:397-401 (flushCommitIndex exists but never called internally)

**Affected code paths**:
- `updateCurrentTerm()` (server.go:545) — writes currentTerm+votedFor to memory only
- `processRequestVoteRequest()` (server.go:1096) — sets votedFor to memory only
- `candidateLoop()` (server.go:747-748) — increments currentTerm, sets votedFor to memory only
- `processSnapshotRecoveryRequest()` (server.go:1302) — overwrites currentTerm without clearing votedFor

**Priority**: HIGH — fundamental safety violation, confirmed by Raft author

### Family 2: Incorrect Election Safety Checks (HIGH)

**Mechanism**: The RequestVote handler uses an incorrect log comparison (`||` instead of lexicographic), and the candidate loop modifies term/vote state without synchronization, allowing incorrect election outcomes.

**Evidence**:
- Code: server.go:1087 (`lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm`)
- Historical: Issue #5 (log comparison bug), Issue #53 (candidate doesn't step down), Issue #13 (no randomized timeout)
- Code: server.go:747-748 (term increment without lock)

**Affected code paths**:
- `processRequestVoteRequest()` (server.go:1066-1099) — wrong up-to-date check
- `candidateLoop()` (server.go:730-808) — non-atomic term/vote update

**Priority**: HIGH — can prevent valid elections, potentially elect less-up-to-date leader

### Family 3: Commit Safety Violations (HIGH)

**Mechanism**: The leader's commit index advancement doesn't verify that the entry being committed is from the current term, potentially committing old-term entries by counting replicas (violating Raft Section 5.4.2). Additionally, the NOP entry for committing old entries is sent asynchronously.

**Evidence**:
- Code: server.go:1022 (`commitIndex := indices[s.QuorumSize()-1]` — no term check on entry)
- Historical: Issue #118 (commit index sort order bug), commit `d2d1e26` (commit past JoinCommand)
- Historical: commit `3f98381` (leader fsync-before-commit bug)
- Code: server.go:826-829 (NOP sent in goroutine, not synchronously)

**Affected code paths**:
- `processAppendEntriesResponse()` (server.go:990-1031)
- `leaderLoop()` (server.go:811-862)
- `setCommitIndex()` (log.go:330-393)

**Priority**: HIGH — can violate leader completeness and state machine safety

### Family 4: Snapshot Safety Gaps (HIGH)

**Mechanism**: Snapshot RPCs lack term validation, can be triggered by stale leaders, and the Snapshotting state has no guaranteed exit path. Snapshot loading uses alphabetic filename sort instead of numeric.

**Evidence**:
- Code: server.go:1267-1281 (no term check in processSnapshotRequest)
- Code: server.go:1289-1313 (no term check, no votedFor reset in processSnapshotRecoveryRequest)
- Code: server.go:1278 (unconditional Snapshotting state transition)
- Historical: Issue #235 (wrong snapshot loaded, confirmed by CoreOS maintainer)
- Historical: Issue #238 (no locking during snapshot creation)
- Historical: Issue #207 (broken init after snapshot, affected InfluxDB)
- Historical: commit `8f47758` (snapshot state self-assignment copy-paste error)

**Affected code paths**:
- `processSnapshotRequest()` (server.go:1267-1281)
- `processSnapshotRecoveryRequest()` (server.go:1289-1313)
- `LoadSnapshot()` (server.go:1316-1393)
- `snapshotLoop()` (server.go:864-887)
- `Peer.sendSnapshotRequest()` (peer.go:258-301)

**Priority**: HIGH — 7 historical bugs, multiple unfixed issues, stale leader can force state regression

### Family 5: Heartbeat Goroutine Concurrency (HIGH)

**Mechanism**: Per-peer heartbeat goroutines run independently and access server state (currentTerm, snapshot, peers) without proper synchronization, causing data races and state inconsistencies.

**Evidence**:
- Code: peer.go:173 (reads currentTerm without lock)
- Code: peer.go:180 (reads snapshot without lock)
- Code: peer.go:210 (reads currentTerm for syncedPeer tracking without lock)
- Historical: 12 race condition bug-fix commits, 5 deadlock bug-fix commits
- Historical: Issues #168 (open, leader stepdown race), #161 (open, deadlock in event handlers), #100 (race detector failures)

**Affected code paths**:
- `Peer.flush()` (peer.go:170-182)
- `Peer.sendAppendEntriesRequest()` (peer.go:189-254)
- `updateCurrentTerm()` (server.go:545-577, stops heartbeats)
- `candidateLoop()` (server.go:747-748, increments term)

**Priority**: HIGH — 17 historical bugs, 3 unfixed issues, pervasive pattern

### Family 6: Log Persistence Corruption (MEDIUM)

**Mechanism**: Log compaction writes wrong file positions, truncation doesn't fsync, and partial writes leave inconsistent state. Recovery code compensates for some issues but not all.

**Evidence**:
- Code: log.go:601-603 (compact uses wrong file handle for Seek)
- Code: log.go:429-430, 452-453 (truncation doesn't fsync)
- Code: log.go:486-498 (partial batch write on error)
- Historical: commit `c79ddde` (io.Read instead of io.ReadFull — critical)
- Historical: commit `b66cb1a` (unsafe log file replacement — critical)
- Historical: commit `b01e3e7` (missing break after truncation — critical)
- Historical: Issue #191 (data loss from partial reads, reported by RavenDB CEO)

**Affected code paths**:
- `compact()` (log.go:576-632)
- `truncate()` (log.go:409-468)
- `appendEntries()` (log.go:475-507)
- `open()` (log.go:88-208, recovery)

**Priority**: MEDIUM — compensated by recovery code in most cases, but compact() Position bug (log.go:601-603) has no compensation

---

## 7. False Positives / Exclusions

| Finding | Reason for Exclusion |
|---------|---------------------|
| Issue #240 (panic on restart) | User error: omitted `-join` flag, shared data directory |
| Issue #250 (package error) | Build/import path issue, not a correctness bug |
| Leader() accessor race (server.go:236-238) | Low-severity read race on informational field, no safety impact |
| writeConf rename error (server.go:1433) | Low-severity: config is best-effort, reconstructed from log |
| json.Marshal error in writeConf (server.go:1422) | Low-severity: only fails on unserializable types, not in practice |
| NOP sent asynchronously (server.go:826-829) | Partial mitigation: syncedPeer gate prevents commit without current-term entry, but window exists |
