# Modeling Brief: goraft/raft

## 1. System Overview

- **System**: goraft/raft — Go Raft consensus library (used by early etcd, InfluxDB)
- **Language**: Go, ~2425 LOC core logic (server.go:1473, log.go:632, peer.go:320)
- **Protocol**: Raft (Ongaro & Ousterhout, 2014), no PreVote, no pipeline, no leader lease
- **Status**: Unmaintained since 2014; maintainers moved to etcd/raft
- **Key architectural deviations**:
  - `currentTerm` and `votedFor` are **memory-only** — never written to stable storage (server.go:118,120)
  - Heartbeat runs in **independent per-peer goroutines** that read server state without locks (peer.go:170-182)
  - Membership changes via **log commands** (JoinCommand/LeaveCommand), not joint consensus
  - Snapshot uses **custom 2-phase protocol** (SnapshotRequest + SnapshotRecoveryRequest) with no term validation
- **Concurrency model**: Single-goroutine event loop for state machine; per-peer heartbeat goroutines; `sync.RWMutex` on server and log

## 2. Bug Families

### Family 1: Non-Persistent Safety State (CRITICAL)

**Mechanism**: Raft requires `currentTerm` and `votedFor` on stable storage before responding to RPCs. goraft stores these only in memory. A crash-restart allows a server to vote twice in the same term, violating election safety.

**Evidence**:
- Historical: Issue #8 (Diego Ongaro confirmed), Issue #12 (entries not written to disk), Issue #69 (restart applies uncommitted)
- Code: server.go:118,120 — `currentTerm` and `votedFor` are plain struct fields
- Code: server.go:1407-1434 — `writeConf()` only persists `CommitIndex` and `Peers`, not term/vote
- Code: server.go:1096 — `s.votedFor = req.CandidateName` with no disk write
- Code: server.go:747-748 — `s.currentTerm++; s.votedFor = s.name` with no disk write
- Code: server.go:1302 — `processSnapshotRecoveryRequest` overwrites `currentTerm` without clearing `votedFor`

**Affected code paths**: `updateCurrentTerm()`, `processRequestVoteRequest()`, `candidateLoop()`, `processSnapshotRecoveryRequest()`

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor` (separate from volatile `currentTerm`, `votedFor`)
- Actions: `PersistVote` (writes term+vote to disk), `Crash` (recovers from persisted state)
- Model the gap: after crash, server recovers with stale term and no votedFor, can vote again
- Also model `commitIndex` non-persistence (log.go:397-401 `flushCommitIndex` never called internally)

**Priority**: High
**Rationale**: Fundamental safety violation confirmed by Raft co-author. Directly violates Figure 2 of the paper. This is the most impactful finding — model checking should demonstrate the election safety violation.

---

### Family 2: Incorrect Election Safety Checks (HIGH)

**Mechanism**: The RequestVote log up-to-date check uses `||` (OR) instead of the correct lexicographic comparison (compare terms first, then indices if equal). This can reject candidates with higher-term but shorter logs, preventing valid elections or electing a less up-to-date leader.

**Evidence**:
- Code: server.go:1087 — `if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm`
- Raft paper Section 5.4.1: "If the logs have last entries with different terms, then the log with the later term is more up-to-date"
- Historical: Issue #5 (log comparison bug), Issue #53 (candidate doesn't step down on same-term AE)

**Affected code paths**: `processRequestVoteRequest()` (server.go:1066-1099)

**Suggested modeling approach**:
- Actions: Implement the WRONG comparison as `GoRaftRequestVote` and the CORRECT one as `RaftRequestVote`
- Invariants: Check if `GoRaftRequestVote` allows election of a leader whose log is missing committed entries (LeaderCompleteness violation)
- The `||` comparison is strictly MORE restrictive than the correct one — it rejects valid candidates. This primarily causes liveness issues (valid elections blocked), but may also cause safety issues in scenarios where the wrong candidate wins because the right one was rejected

**Priority**: High
**Rationale**: Direct deviation from Raft paper. Simple to model — just change the comparison operator. Could violate LeaderCompleteness under specific log state configurations.

---

### Family 3: Commit Safety Violations (HIGH)

**Mechanism**: The leader commits entries by computing the median of all peers' `prevLogIndex` values without verifying that the entry at the median index is from the current term. Raft Section 5.4.2 requires leaders to only commit current-term entries (which implicitly commits earlier ones). A NOP is sent asynchronously but there's a window before it arrives.

**Evidence**:
- Code: server.go:1022 — `commitIndex := indices[s.QuorumSize()-1]` (no term check on entry)
- Code: server.go:826-829 — NOP sent via `go func() { s.Do(NOPCommand{}) }()` (asynchronous, not blocking)
- Code: server.go:1004 — `syncedPeer` partially mitigates (gates on current-term append) but doesn't ensure commitIndex points to current-term entry
- Historical: Issue #118 (commit sort order bug), commit `d2d1e26` (commit past JoinCommand), commit `3f98381` (fsync-before-commit)

**Affected code paths**: `processAppendEntriesResponse()` (server.go:990-1031), `leaderLoop()` (server.go:811-862)

**Suggested modeling approach**:
- Variables: Track entry terms in log (already standard)
- Actions: `AdvanceCommitIndex` should compute median without checking entry term (matching goraft behavior)
- Invariants: `CommitSafety` — a committed entry must appear in all future leaders' logs (LeaderCompleteness)
- Variant: `AdvanceCommitIndexFixed` that checks entry term, to verify fix eliminates violation

**Priority**: High
**Rationale**: Classic Raft bug (Section 5.4.2, Figure 8). The `syncedPeer` mechanism is a partial mitigation but doesn't prevent committing a previous-term entry at the median index. Model checking can demonstrate whether a counterexample exists.

---

### Family 4: Snapshot Safety Gaps (HIGH)

**Mechanism**: Snapshot RPCs lack term validation — the `SnapshotRequest` struct doesn't even have a `Term` field. A stale leader can force a server into Snapshotting state and then overwrite its term without clearing `votedFor`. The Snapshotting state has no guaranteed exit path.

**Evidence**:
- Code: server.go:1267-1281 — `processSnapshotRequest` has zero term validation
- Code: snapshot.go:43-47 — `SnapshotRequest` struct lacks `Term` field
- Code: server.go:1289-1313 — `processSnapshotRecoveryRequest` overwrites `currentTerm` (L1302), doesn't clear `votedFor`
- Code: server.go:1278 — unconditional `setState(Snapshotting)`
- Historical: Issue #235 (wrong snapshot loaded, unfixed), Issue #238 (no snapshot locking, unfixed), Issue #207 (broken init after snapshot)
- Historical: 7 snapshot bug-fix commits, 3 critical

**Affected code paths**: `processSnapshotRequest()`, `processSnapshotRecoveryRequest()`, `snapshotLoop()`, `Peer.sendSnapshotRequest()`

**Suggested modeling approach**:
- Variables: `snapshotting` flag, `snapshotLastIndex`, `snapshotLastTerm`
- Actions: `SendSnapshot` (no term check), `RecoverSnapshot` (overwrites term, doesn't clear votedFor), `ExitSnapshotting` (via subsequent AE)
- Key: model the scenario where a stale leader triggers snapshot recovery, setting the term backward, leaving votedFor inconsistent
- Invariant: `VoteSafety` — after snapshot recovery, votedFor must be consistent with currentTerm

**Priority**: High
**Rationale**: 7 historical bugs (3 critical), 3 unfixed issues. The missing term check + votedFor inconsistency is a novel finding not present in the git history. Model checking can explore stale-leader snapshot interactions.

---

### Family 5: Heartbeat Goroutine Concurrency (MEDIUM for TLA+)

**Mechanism**: Per-peer heartbeat goroutines read `currentTerm` and `snapshot` without synchronization. A heartbeat can send an AppendEntries with a stale term after the leader has stepped down, or read a partially-constructed snapshot.

**Evidence**:
- Code: peer.go:173 — reads `p.server.currentTerm` without lock
- Code: peer.go:180 — reads `p.server.snapshot` without lock
- Code: peer.go:210 — reads `currentTerm` for `syncedPeer` tracking without lock
- Historical: 12 race bug-fix commits, 5 deadlock bug-fix commits, Issues #168/#161/#100 (unfixed)

**Affected code paths**: `Peer.flush()`, `Peer.sendAppendEntriesRequest()`, `updateCurrentTerm()`

**Suggested modeling approach**:
- This is primarily a Go concurrency issue (memory model, data races), not protocol logic
- For TLA+: model the heartbeat as a separate action that reads a potentially stale term
- Variables: `heartbeatTerm` (can be stale copy of `currentTerm`)
- Action: `SendHeartbeat` uses `heartbeatTerm` instead of `currentTerm`
- The stale-term heartbeat is mostly benign (followers reject stale-term AEs), but model checking can verify this

**Priority**: Medium (for TLA+ modeling — the concurrency bugs are real but better caught by Go race detector)
**Rationale**: While 17 historical bugs confirm this is a major issue area, most are Go-specific (lock ordering, channel semantics, goroutine lifecycle) that don't map well to TLA+. The stale-term heartbeat scenario is the main protocol-level aspect worth modeling.

---

### Family 6: Log Compaction Corruption (LOW for TLA+)

**Mechanism**: `compact()` writes wrong file Position values by seeking on the old file handle instead of the new one. Post-compaction truncation corrupts the log.

**Evidence**:
- Code: log.go:601-603 — `l.file.Seek(0, os.SEEK_CUR)` uses old file, entries written to new `file`
- Historical: 6 log persistence bug-fix commits (4 critical), Issue #191 (data corruption)

**Priority**: Low (for TLA+ modeling — this is an implementation bug in file I/O, not protocol logic)

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Non-persistent term/votedFor | Family 1: fundamental safety violation, confirmed by Raft author | Separate `persisted*` variables + `Crash` action recovering from persisted state |
| Incorrect log comparison | Family 2: direct Raft paper deviation | Implement goraft's `\|\|` comparison in `RequestVote` action |
| Commit without term check | Family 3: violates Section 5.4.2 | `AdvanceCommitIndex` computes median without checking entry term |
| Snapshot without term validation | Family 4: 7 historical bugs, stale leader can regress term | `SendSnapshot`/`RecoverSnapshot` actions with no term guard, no votedFor reset |
| Stale-term heartbeat | Family 5: heartbeat reads stale currentTerm | Split AE into `Replicate` (correct term) and `Heartbeat` (possibly stale term) |
| Crash and recovery | Families 1,3: persistence correctness | `Crash` action resets volatile state, recovers from log + config only |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Go concurrency primitives | Lock ordering, channel semantics, goroutine lifecycle — Go-specific, not protocol logic |
| Log file I/O (Family 6) | File position tracking, fsync ordering — implementation detail, not protocol |
| HTTP transport | Network-level concerns (timeouts, keep-alive) — abstracted by message passing |
| Event dispatch system | Monitoring/callback mechanism, not protocol logic |
| Heartbeat flooding (#206) | Performance/liveness issue, not safety |
| Panic assertions (#133) | Error handling policy, not protocol logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-persistent state | `persistedTerm`, `persistedVotedFor` | Model crash window where volatile state is lost | Family 1 |
| Crash/Recovery | (action only) | Reset volatile state, recover from persisted | Family 1, 3 |
| Wrong log comparison | (action logic change) | Implement `\|\|` instead of lexicographic in RequestVote | Family 2 |
| No-term-check commit | (action logic change) | Leader commits median index without verifying current term | Family 3 |
| Snapshot term gap | `snapshotting` | Model snapshot without term check, votedFor leak | Family 4 |
| Stale heartbeat | `heartbeatTerm` | Heartbeat goroutine sends AE with stale term | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Family 1, 2 |
| LogMatching | Safety | Same index+term implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Family 2, 3 |
| VoteSafety | Safety | No server votes twice in the same term (after crash) | Family 1 |
| CommitTermSafety | Safety | Committed entry's term ≤ committing leader's term at commit time | Family 3 |
| SnapshotTermConsistency | Safety | After snapshot recovery, votedFor is consistent with currentTerm | Family 4 |
| NoStaleLeaderSnapshot | Safety | Snapshot recovery only from leader with term ≥ server's currentTerm | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Non-persistent votedFor allows double-voting after crash | ElectionSafety, VoteSafety | 1 |
| MC-2 | Wrong log comparison (`\|\|`) blocks valid elections or elects wrong leader | LeaderCompleteness | 2 |
| MC-3 | Leader commits previous-term entry without current-term NOP committed | CommitTermSafety, LeaderCompleteness | 3 |
| MC-4 | Stale leader triggers snapshot, regresses term, leaves votedFor inconsistent | SnapshotTermConsistency, VoteSafety | 4 |
| MC-5 | Snapshot recovery without votedFor reset allows vote in wrong term | ElectionSafety | 1, 4 |
| MC-6 | Stale-term heartbeat from stepped-down leader causes phantom contact | Standard (benign — followers reject) | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | compact() writes wrong Position values (log.go:601-603) | Unit test: compact log, then truncate, verify file content |
| TV-2 | Heartbeat reads currentTerm without lock (peer.go:173) | Go race detector test with concurrent term changes |
| TV-3 | candidateLoop increments term without lock (server.go:747-748) | Go race detector test during election |
| TV-4 | Partial batch write on error in appendEntries (log.go:486-498) | Unit test: inject write error mid-batch, verify recovery |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | processSnapshotRecoveryRequest panics on recovery error (server.go:1291-1293) | Return error response instead of panic |
| CR-2 | writeConf ignores os.Rename error (server.go:1433) | Add error handling |
| CR-3 | readConf silently accepts missing file (server.go:1444-1446) | Document that this is intentional for first boot |
| CR-4 | Snapshot filenames sort alphabetically not numerically (Issue #235) | Zero-pad filenames (PR #237 proposed but never merged) |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/goraft/analysis-report.md`
- **Key source files**:
  - `artifact/raft/server.go` — core state machine, RPC handlers (1473 lines)
  - `artifact/raft/log.go` — log persistence, truncation, compaction (632 lines)
  - `artifact/raft/peer.go` — heartbeat goroutines, replication (320 lines)
  - `artifact/raft/snapshot.go` — snapshot structures (304 lines)
- **GitHub issues**: #8 (persistent state), #118 (commit calc), #235 (snapshot sort), #168 (stepdown race), #161 (deadlock), #191 (data corruption)
- **Reference**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
- **Historical context**: goraft was the first Go Raft implementation, used by early etcd and InfluxDB. Its maintainers (xiang90, philips, benbjohnson) moved to etcd/raft, a complete rewrite addressing many of these architectural issues (single-threaded event loop, proper stable storage, no panics).
