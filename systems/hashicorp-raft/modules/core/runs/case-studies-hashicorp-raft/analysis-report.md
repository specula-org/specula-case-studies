# Analysis Report: hashicorp/raft

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits found | 54 |
| Git commits analyzed in detail | 25 |
| GitHub issues searched (unique) | ~160 |
| GitHub issues deeply read (full comments) | 45+ |
| GitHub issues confirmed bugs | 13 |
| GitHub issues debunked/false positive | 4 |
| Core source files read in full | 7 (raft.go, replication.go, configuration.go, commitment.go, snapshot.go, state.go, commands.go) |

---

## 1. Codebase Reconnaissance

### 1.1 Core Module Map

| File | Lines | Purpose |
|------|-------|---------|
| `raft.go` | 2286 | Main state machine, all RPC handlers, election, leader loop |
| `replication.go` | 749 | Per-peer replication + independent heartbeat, pipeline mode |
| `api.go` | 1289 | Public API, NewRaft (recovery), BootstrapCluster |
| `configuration.go` | 368 | Config changes, committed/latest tracking, nextConfiguration |
| `commitment.go` | 104 | Commit index tracking, quorum calculation |
| `snapshot.go` | 278 | Snapshot creation, compaction |
| `state.go` | 174 | State variables (term, commitIndex, lastLog) with atomic/lock access |
| `commands.go` | 223 | RPC request/response structs |
| `transport.go` | 142 | Transport interface (includes SetHeartbeatHandler fast-path) |
| `fsm.go` | 285 | FSM runner goroutine |

### 1.2 Concurrency Model

| Component | Thread/Goroutine | Communication |
|-----------|-----------------|---------------|
| Main state machine | Single goroutine (run → runFollower/runCandidate/runLeader) | Channels: rpcCh, applyCh, configurationChangeCh, etc. |
| Per-peer replication | One goroutine per follower (`replicate()`) | `followerReplication` struct: triggerCh, stopCh |
| Per-peer heartbeat | One goroutine per follower (`heartbeat()`) | Shares `followerReplication` with replication goroutine |
| Pipeline decoder | One goroutine per pipeline session (`pipelineDecode()`) | finishCh/stopCh bilateral coordination |
| Snapshot | Single goroutine (`runSnapshots()`) | fsmSnapshotCh, configurationsCh |
| FSM | Single goroutine (`runFSM()`) | fsmMutateCh |

### 1.3 Shared State and Synchronization

| State | Protected by | Accessed from |
|-------|-------------|---------------|
| `currentTerm` | `atomic.LoadUint64/StoreUint64` | Main thread, replication goroutines (read only) |
| `state` (Follower/Candidate/Leader) | `atomic.LoadUint32/StoreUint32` | Main thread (write), any goroutine (read) |
| `lastLogIndex/lastLogTerm` | `lastLock` (Mutex) | Main thread, replication goroutines |
| `lastSnapshotIndex/lastSnapshotTerm` | `lastLock` (Mutex) | Main thread, snapshot goroutine |
| `commitIndex` | `atomic.LoadUint64/StoreUint64` | Main thread (write), any goroutine (read) |
| `lastApplied` | `atomic.LoadUint64/StoreUint64` | Main thread, FSM goroutine |
| `leader` | `leaderLock` (RWMutex) | Main thread (write), any goroutine (read) |
| `lastContact` (per follower) | `lastContactLock` (RWMutex) | Heartbeat goroutine (write), main thread (read) |
| `peer` (per follower) | `peerLock` (RWMutex) | Main thread (write), heartbeat/replication (read) |
| `followerReplication.nextIndex` | `atomic.LoadUint64/StoreUint64` | Replication goroutine (write), pipeline decoder (write) |
| `followerReplication.notify` | `notifyLock` (Mutex) | Main thread (write), heartbeat/replication (read+write) |
| `configurations` | Main thread only (no lock) | Main thread exclusively |
| `commitment.matchIndexes` | `commitment.Mutex` | Main thread, replication goroutines |

### 1.4 Key Architectural Decisions

1. **Heartbeat independence** (replication.go:138-141): The `replicate()` function spawns a separate `heartbeat()` goroutine. This is explicitly to "avoid head-of-line blocking from disk IO" (transport.go:62-63). The heartbeat goroutine shares the `followerReplication` struct but operates independently of the replication loop.

2. **Two configurations** (configuration.go:146-157): `committed` is the last configuration that has been committed to the cluster. `latest` is the most recent configuration (may be uncommitted). At most one uncommitted configuration exists at any time (enforced by `configurationChangeChIfStable()` at raft.go:663-673).

3. **Non-transactional persistence**: The `StableStore` interface (stable.go) provides `Set` and `SetUint64` but no batch/transaction API. This means multi-field persistence (term + votedFor) requires multiple calls with crash windows between them.

4. **Leader lease via lastContact**: The leader checks `time.Since(f.LastContact())` against `LeaderLeaseTimeout` for each voter (raft.go:1068-1069). If fewer than a quorum have been contacted within the timeout, the leader steps down (raft.go:1088-1092).

---

## 2. Bug Archaeology

### 2.1 Bug Hotspot Analysis

| File | Bug-fix commits | Key bug types |
|------|----------------|---------------|
| `raft.go` | 43 | Log truncation, term handling, races, deadlocks, config changes |
| `replication.go` | 14 | Term checking, peer races, pipeline issues |
| `api.go` | 12 | Shutdown, notify channels, recovery |
| `configuration.go` | 6 | NonVoter/Voter transitions, removed nodes |
| `commands.go` | 5 | Missing fields for backward compat |
| `state.go` | 3 | Atomic access, lastLock introduction |
| `snapshot.go` | 3 | Compaction range, stream consumption |

### 2.2 Critical Historical Bug Fixes

| Commit | Summary | Root cause | Severity |
|--------|---------|------------|----------|
| `0f31a01` | Stop truncating non-conflicting entries in AppendEntries | Truncated ALL overlapping entries before rewriting; crash during window = permanent data loss. Fix by Diego Ongaro. | Critical |
| `670fc01` | compactLogs removes all logs in snapshot | Kept snapshot entry in log for replication; that entry could conflict with leader's | Critical |
| `538e56c` | Index/Term in raft state should be locked atomically | lastLogIndex and lastLogTerm read with separate atomics; reader sees torn state | Critical |
| `f887341` | Race on current term update to replicators | Replicators read term directly from r.currentTerm, racing with main thread | High |
| `2489ac1` | Race condition with noop application | No-op dispatched via goroutine through applyCh, racing with client requests | High |
| `5800ad5` | Deadlock: committed logs over channel | Blocking channel send inside lock; leader loop slow to drain = deadlock | High |
| `49bd61b` | candidateFromLeadershipTransfer not atomic | Plain bool accessed from multiple goroutines | High |
| `1a62103` | Peer access race with heartbeat | peer field read by heartbeat without lock | High |
| `d68b78b` | Leadership transfer race and transition bug | Flag set inside goroutine (too late); AppendEntries during transfer caused step-down | High |
| `42d3446` | PreVote incorrectly updates lastContact | Prevents followers from ever timing out during pre-vote spam | High |
| `656e6c0` | NonVoter can transition to Candidate | Used `inConfig()` instead of `hasVote()` for election eligibility | Medium |
| `6b4e320` | Non-voter with higher term gets elected | No voter-check after term update in requestVote | Medium |

### 2.3 Open GitHub Issues (Confirmed Bugs)

| Issue | Summary | Component | Severity | Status |
|-------|---------|-----------|----------|--------|
| #503 | Leader LogStore hang = cluster stuck indefinitely | Heartbeat/leader loop | HIGH | OPEN since 2022, confirmed by @banks |
| #522 | Leader can't load snapshot, doesn't step down | Replication/snapshot | MEDIUM | OPEN |
| #612 | Replication stopped but heartbeat kept working | Heartbeat/replication | HIGH | OPEN |
| #614 | Corrupted storage node wins elections repeatedly | Election/persistence | HIGH | Closed (user's log store issue) |
| #666 | Missing resp.Term check in heartbeat() — confirmed as liveness issue (not safety); phantom contact precondition unreachable | Heartbeat | MEDIUM (liveness) | OPEN, maintainers working on fix |
| #498 | Apply future deadlocks on quorum loss | Apply/future | MEDIUM | OPEN since 2022, confirmed |
| #85 | Panic after restoring from old snapshot | Snapshot/log | MEDIUM | OPEN since 2016 |
| #86 | TrailingLogs=0 crashes after snapshot | Snapshot/compaction | MEDIUM | OPEN since 2016 |

### 2.4 Debunked Issues

| Issue | Claim | Why debunked |
|-------|-------|-------------|
| #661 | Non-atomic vote persistence enables split-brain | Maintainer @tgross showed: (1) RPC response is deferred, crash before persistVote means response never sent; (2) the test scenario used impossible state (isolated node using victim's lastLogTerm); (3) after recovery, next election uses term+1. Reporter acknowledged error. |
| #568 | Panic split-brain in appendEntries | Temporary dual-leadership during term transitions is expected Raft behavior. Safety maintained by term mechanism. |
| #586 | Election fails with max current term | uint64 term overflow requires ~6 billion years of 10ms elections. Outside design envelope. |
| #482 | OverrideNotifyBool race condition | Go's select locks all channels atomically before evaluating. Race detector confirms no race. |

---

## 3. Deep Analysis Findings

### 3.1 Path Inconsistency: AppendEntries Response Term Check

The most significant finding is the systematic path inconsistency in how AppendEntries responses are handled across 4 code paths.

| Path | File:Line | Checks resp.Term? | setLastContact guarded? | notifyAll on reject? |
|------|-----------|-------------------|------------------------|---------------------|
| `replicateTo()` | replication.go:250 | YES | YES (only after term check) | NO |
| `heartbeat()` | replication.go:462 | **NO** | **NO** (unconditional) | YES (resp.Success) |
| `pipelineDecode()` | replication.go:607 | YES | YES (only after term check) | NO |
| `sendLatestSnapshot()` | replication.go:387 | YES | YES (only after term check) | NO |

The `heartbeat()` function at replication.go:416-483 is the ONLY path that does not check `resp.Term > req.Term` before calling `s.setLastContact()`. This is a real code inconsistency; however, its practical impact differs from what we initially reported.

**Compensating mechanism we missed (2026-03-18 update)**: Maintainer @tgross identified that the phantom contact scenario (follower at higher term responds to heartbeat) is **unreachable** in the real system because heartbeats themselves suppress follower election timeouts. When a follower receives a heartbeat, `appendEntries()` calls `setLastContact()` at raft.go:1580, resetting the election timer. Additionally, followers with recent leader contact reject vote requests from other candidates (raft.go:1650-1656). This means followers cannot reach a higher term while heartbeats are flowing, so the `resp.Term > req.Term` case that would trigger phantom contacts never occurs.

**What IS real**: The path inconsistency contributes to a **liveness** issue: when a leader's disk stalls, heartbeats continue (by design), preventing followers from starting elections. The cluster gets stuck — no commits, no new leader. See https://github.com/hashicorp/raft/issues/666#issuecomment-4077990688.

### 3.2 Configuration committed vs latest Usage Audit

| Function | File:Line | Uses | Assessment |
|----------|-----------|------|------------|
| `setupLeaderState()` | raft.go:467 | latest | Correct |
| `startStopReplication()` | raft.go:593,597 | latest | Correct |
| `quorumSize()` | raft.go:1101 | latest | Conservative (not unsafe) |
| `checkLeaderLease()` | raft.go:1061 | latest | Conservative (not unsafe) |
| `verifyLeader()` | raft.go:983 | latest (via quorumSize) | Consistent |
| `electSelf()` | raft.go:2058 | latest | Correct |
| `preElectSelf()` | raft.go:2150 | latest | Correct |
| `appendConfigurationEntry()` | raft.go:1217 | latest | Correct |
| Leader step-down | raft.go:810 | committed | Different (by design) |
| `configurationChangeChIfStable()` | raft.go:668 | Both | Correct |
| `appendEntries()` config rollback | raft.go:1559-1560 | Both | Correct |
| `processConfigurationLogEntry()` | raft.go:1618-1619 | Both | Correct |
| `commitment.setConfiguration()` | commitment.go:53 | latest (passed in) | Correct |

The configuration usage is more consistent than initially suspected. The codebase systematically uses `latest` for operational decisions and `committed` for safety decisions. Two separate quorum calculations exist (`quorumSize()` in raft.go:1101 and `recalculate()` in commitment.go:98) but they stay in sync because `appendConfigurationEntry()` updates both atomically on the main thread.

### 3.3 Non-Atomic Persistence Analysis

#### requestVote() persistence gap (raft.go:1709 → 1768)

When `req.Term > currentTerm`:
1. **Line 1709**: `r.setCurrentTerm(req.Term)` — persists CurrentTerm = T
2. (59 lines of checks)
3. **Line 1768**: `r.persistVote(req.Term, candidateBytes)` — persists vote

Crash between step 1 and 3: Term T on disk, vote not persisted. On recovery and receiving RequestVote from a different candidate for term T, the node can grant a second vote because `lastVoteTerm` from stable store is stale (≠ T), so the duplicate check at line 1740 fails to fire.

**Safety assessment**: NOT a practical safety violation because:
1. The RPC response is deferred (line 1655) and only sent when the function returns normally
2. A crash before `persistVote` means the response was never sent — the first candidate never counted this vote
3. After recovery, the node starts as Follower; any new self-election uses term+1
4. The only actual vote is the one granted after recovery

#### persistVote() internal (raft.go:2175-2183)

Two writes: `SetUint64(keyLastVoteTerm, term)` then `Set(keyLastVoteCand, candidate)`. Crash between: `LastVoteTerm = T`, `LastVoteCand = <stale>`. On next RequestVote for term T: duplicate check fires (`lastVoteTerm == T`) but candidate mismatch → rejects all votes for that term. This is safe.

#### appendEntries() truncation (raft.go:1555-1573)

`DeleteRange` then `StoreLogs` with crash window. Safe on crash (leader re-sends). But if `StoreLogs` FAILS (error, no crash), the in-memory `lastLog` cache retains pre-truncation values (acknowledged by TODO at line 1571).

### 3.4 Cross-Handler Comparison

| Behavior | appendEntries | requestVote | requestPreVote | installSnapshot | timeoutNow |
|----------|---------------|-------------|----------------|----------------|------------|
| Term check (reject older) | raft.go:1485 | raft.go:1700 | raft.go:1815 | raft.go:1878 | **NONE** |
| Term upgrade (higher term) | raft.go:1491-1497 | raft.go:1705-1713 | **NO** (correct) | raft.go:1886-1891 | **NONE** |
| State → Follower | Yes | Yes | No (correct) | Yes | → **Candidate** |
| Records leader | Yes (1500-1504) | No (correct) | No (correct) | Yes (1894-1898) | Clears leader |
| Config membership check | No | Yes (1681) | Yes (1800) | No | **No** |
| Sets lastContact | Yes (1609) | Yes (1775) | No (correct) | Yes (1995) | No |
| Persists state | Term, logs | Term, vote | **None** (correct) | Term, snapshot | **None** |

**Notable**: `timeoutNow()` at raft.go:2254-2259 performs NO checks — no term, no state, no config. Any node can be forced to become a candidate by a `TimeoutNow` message.

### 3.5 handleStaleTerm() Analysis

`handleStaleTerm()` at replication.go:730-734 signals leader step-down via `asyncNotifyCh(s.stepDown)`. This is asynchronous — unbounded delay between signal and actual state transition in `leaderLoop()` at raft.go:697-699. During this window, the leader continues processing and other replication/heartbeat goroutines continue running.

Also: `handleStaleTerm()` does NOT update the leader's term to the follower's higher term. The term update only happens via `processRPC` on the main thread.

### 3.6 Recovery Analysis (NewRaft, api.go:502-633)

| State recovered from disk | Source |
|--------------------------|--------|
| `currentTerm` | `stable.GetUint64(keyCurrentTerm)` (api.go:516) |
| `lastLogIndex/Term` | `logs.LastIndex()` then `logs.GetLog()` (api.go:522-533) |
| Snapshot state | `r.restoreSnapshot()` (api.go:600) |
| Configuration | Scanned from log entries post-snapshot (api.go:605-615) |

**NOT recovered**: `LastVoteTerm`/`LastVoteCand` (only read lazily on next requestVote). `commitIndex` (set to 0, rebuilt via AppendEntries). RaftState (always starts as Follower).

---

## 4. Bug Family Summary

### Family 1: Leader Cannot Self-Detect Failure (HIGH → MEDIUM, reclassified as liveness)
- **Bug count**: 5 open issues, 1 code path inconsistency
- **Production impact**: Yes (#503 confirmed by maintainer, Azure disk hangs) — but as a **liveness** issue, not safety
- **TLA+ suitability**: Medium — the safety violation (phantom lease) was a spec fidelity false positive; the real liveness issue requires modeling heartbeat-election timeout coupling
- **2026-03-18 update**: MC-found NoPhantomContact and LeaseImpliesLoyalty violations retracted. The phantom contact precondition (follower at higher term) is unreachable because heartbeats suppress election timeouts. The real bug is liveness: disk-stalled leader holds lease via heartbeats while preventing follower elections.

### Family 2: Configuration Change Safety (HIGH)
- **Bug count**: 5+ historical fixes, 2 confirmed issues
- **Production impact**: Yes (#472 multiple independent reports, #524 affected Consul/Nomad/Vault)
- **TLA+ suitability**: Excellent — config interaction with election is classic model checking target

### Family 3: Non-Atomic Persistence (MEDIUM)
- **Bug count**: 3 code patterns, 2 open issues
- **Production impact**: Low (double-vote debunked, snapshot issues are edge cases)
- **TLA+ suitability**: Good — crash recovery modeling is a TLA+ strength

### Family 4: PreVote Copy-Paste (LOW)
- **Bug count**: 2 historical fixes, 1 remaining
- **Production impact**: Low (fixed, remaining is metrics label)
- **TLA+ suitability**: Poor — code-level issues

### Family 5: Error Handling / Edge Cases (LOW)
- **Bug count**: 1 open issue, 3 code findings
- **Production impact**: Medium (#498 is real)
- **TLA+ suitability**: Poor — most are implementation-level

---

## 5. False Positive Exclusions

| Finding | Why excluded |
|---------|-------------|
| #661: Non-atomic vote persistence split-brain | Debunked by maintainers. RPC response is deferred; crash before persistVote = response never sent. After recovery, next election uses term+1. |
| Double-vote in electSelf() after crash | Same mechanism: crash before persistVote means the candidate never collects the vote. After recovery, node starts as Follower and new elections use higher terms. |
| quorumSize() using latest is unsafe | It's conservative, not unsafe. Higher quorum during config addition makes it harder to maintain lease but never violates safety. |
| checkLeaderLease() nil dereference | Impossible under normal operation because `setLatestConfiguration()` and `startStopReplication()` are always called atomically on the main thread. |
| s.peer.ID unprotected in updateLastAppended | replication.go:744 reads `s.peer.ID` without peerLock. On 64-bit Go, string header assignment is word-sized and practically atomic. Only a concern on 32-bit platforms. |
