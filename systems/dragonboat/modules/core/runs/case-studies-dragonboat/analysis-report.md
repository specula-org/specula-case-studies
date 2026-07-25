# Analysis Report: lni/dragonboat

## Table of Contents

1. [Codebase Structure](#1-codebase-structure)
2. [Concurrency Model](#2-concurrency-model)
3. [Persistence Architecture](#3-persistence-architecture)
4. [Bug Archaeology Results](#4-bug-archaeology-results)
5. [Deep Analysis Findings](#5-deep-analysis-findings)
6. [Excluded Findings](#6-excluded-findings)

---

## 1. Codebase Structure

### 1.1 Core Raft Logic

| File | LOC | Purpose |
|------|-----|---------|
| `internal/raft/raft.go` | 2,465 | Core state machine, handlers, state transitions |
| `internal/raft/logentry.go` | 420 | Two-layer log (inmem + logdb) |
| `internal/raft/inmemory.go` | 247 | In-memory log entries |
| `internal/raft/remote.go` | 225 | Follower replication state machine (Retry/Wait/Replicate/Snapshot) |
| `internal/raft/peer.go` | 449 | Public interface, Update construction, FastApply |
| `internal/raft/readindex.go` | 116 | ReadIndex linearizable reads |

### 1.2 Coordination Layer

| File | LOC | Purpose |
|------|-----|---------|
| `nodehost.go` | 2,196 | Multi-group orchestrator, client API |
| `node.go` | 1,708 | Single Raft group replica, message routing |
| `engine.go` | 1,474 | Worker pool, step/commit/apply pipeline |

### 1.3 Persistence Layer

| File | LOC | Purpose |
|------|-----|---------|
| `internal/logdb/db.go` | 514 | Core LogDB implementation |
| `internal/logdb/batch.go` | 397 | Batch entry operations |
| `internal/logdb/sharded.go` | 372 | Sharded DB for concurrent workers |
| `internal/logdb/logreader.go` | 335 | In-memory read cache |

### 1.4 Handler Map (raft.go:2332-2417)

Six states x 29 message types. Key handler registrations:

**Leader-only handlers** (wrapped by `lw()` for remote lookup):
- `pb.ReplicateResp` -> `handleLeaderReplicateResp`
- `pb.HeartbeatResp` -> `handleLeaderHeartbeatResp`
- `pb.SnapshotStatus` -> `handleLeaderSnapshotStatus`
- `pb.Unreachable` -> `handleLeaderUnreachable`

**Shared across all states**:
- `pb.RequestVote` -> `handleNodeRequestVote` (same function for all 6 states)
- `pb.RequestPreVote` -> `handleNodeRequestPreVote` (same function for all 6 states)
- `pb.ConfigChangeEvent` -> `handleNodeConfigChange` (all states except witness)
- `pb.LocalTick` -> `handleLocalTick` (all states)

**State-specific entry point asymmetries**:
- NonVoting: delegates Replicate/Heartbeat/InstallSnapshot to follower handlers
- Witness: has its own Replicate/Heartbeat/InstallSnapshot handlers (different from follower)
- Candidate: calls `becomeFollower` before processing Replicate/Heartbeat/InstallSnapshot (steps down)
- PreVoteCandidate: shares most candidate handlers, except uses `RequestPreVoteResp` instead of `RequestVoteResp`

---

## 2. Concurrency Model

### 2.1 Worker Architecture (engine.go)

```
Engine
├── Step Workers [N]     -- advance Raft state machines, persist, send messages
├── Commit Workers [N]   -- notify committed entries (if notifyCommit enabled)
├── Apply Workers [N]    -- apply entries to RSM, handle snapshots
├── Snapshot WorkerPool  -- save/recover/stream snapshots
└── Close WorkerPool     -- graceful node shutdown
```

Each shard is assigned to exactly one worker of each type via `FixedPartitioner`.

### 2.2 Serialization Guarantees

- **raftMu**: Protects the Raft Peer object. Acquired by `stepNode()` (node.go:1140) and `commitRaftUpdate()` (node.go:1120). Ensures no concurrent access to the core state machine.
- **WorkReady channels**: Buffered(1) channels act as coalescing dirty flags. Multiple notifications collapse into one wakeup.
- **Message queue**: Per-node `server.MessageQueue` with FIFO ordering within a shard.

### 2.3 Processing Pipeline (engine.go:1304-1364)

```
1. stepNode()                    -- advance Raft (under raftMu)
2. applySnapshotAndUpdate(fast)  -- apply already-persisted committed entries
3. sendReplicateMessages()       -- send Replicate/Ping BEFORE persistence
4. SaveRaftState()               -- ATOMIC PERSISTENCE (Pebble batch + fsync)
5. applySnapshotAndUpdate(slow)  -- apply entries that needed persistence first
6. processRaftUpdate()           -- send non-Replicate messages, update LogReader
7. commitRaftUpdate()            -- advance Raft internal state (under raftMu)
```

**Critical ordering**: Steps 3 (send Replicates before persist) and 6 (send votes after persist) are deliberate. Replicate-before-persist is safe per Raft thesis 10.2.1. Vote-after-persist ensures a node never sends a vote grant for a term it hasn't durably recorded.

---

## 3. Persistence Architecture

### 3.1 Atomic State Persistence

**{Term, Vote, Commit} are persisted as a single protobuf blob** in one key-value pair:

```go
// raftpb/state.go:11-15
type State struct {
    Term   uint64
    Vote   uint64
    Commit uint64
}

// internal/logdb/db.go:307-320 — single key, single value
func (r *db) saveState(shardID, replicaID uint64, st pb.State, wb kv.IWriteBatch, ctx IContext) {
    data := ctx.GetValueBuffer(uint64(st.Size()))
    result := pb.MustMarshalTo(&st, data)
    k.SetStateKey(shardID, replicaID)
    wb.Put(k.Key(), result)
}
```

No hashicorp/raft-style term/vote split vulnerability exists.

### 3.2 Write Batch Atomicity

All persistence for a step cycle goes into one Pebble write batch (db.go:179-204):

```
saveRaftState():
  1. saveState()    -> wb.Put(stateKey, {term,vote,commit})
  2. saveSnapshot() -> wb.Put(snapshotKey, metadata)   [if snapshot]
  3. saveEntries()  -> wb.Put(entryKeys, entries)
  4. CommitWriteBatch(wb)  -- single atomic Pebble Apply with Sync:true
```

Cross-node batching: all nodes assigned to the same step worker share one write batch.

### 3.3 Recovery Path

On restart, `ReadRaftState()` (logdb/db.go:243-282) reads the State key and reconstructs the full raft state. Since term+vote+commit are a single key, recovery always sees a consistent triplet.

---

## 4. Bug Archaeology Results

### 4.1 Git History Summary

**20 bug-fix commits analyzed in detail** across `internal/raft/`, `internal/logdb/`, `engine.go`, `node.go`, and `nodehost.go`.

**Bug hotspots by file**:
- `internal/logdb/` — 12+ fix commits (data races, batch management, pebble issues)
- `engine.go` — 5 fix commits (data races, wrong map keys, worker partition bugs)
- `internal/raft/raft.go` — 8 fix commits (election, observer promotion, leadership transfer, log queries)
- `node.go` / `nodehost.go` — 8+ fix commits (data races, snapshot handling, message routing)

### 4.2 GitHub Issues Summary

**186 unique issues/PRs examined** (136 issues + 50 PRs). **20 issues verified by reading full discussions**.

**Confirmed bugs**:

| # | Title | Severity | Fixed? |
|---|-------|----------|--------|
| #94 | `restoreRemotes` incorrectly promotes observer | High | Yes (ac6a472) |
| #75 | Invalid membership change accepted (delete only node) | Medium | Yes (v3.0.2) |
| #156 | OnDiskSM inconsistent index silently ignored | Critical | Yes (PR #161) |
| #369 | Silently ignores SMs with missed data (dup of #156) | High | Yes on master |
| #260 | SyncRequestSnapshot panic on ErrSnapshotAborted | Medium | Yes (v3.3.6) |
| #194 | Nodes loaded from two incarnations | Medium | Yes |
| #229 | RSM close called twice | Medium | Partially (master) |
| #409 | `return nil` instead of `return err` on saveSnapshot failure | Critical | **No (PR open)** |
| #374 | NewNodeHost panic recovery misses string panics | High | **No (PR closed)** |

**False positives / user error**:

| # | Title | Classification |
|---|-------|---------------|
| #224 | Leader vote before persist | False positive (FastApply logic is correct) |
| #195 | Cluster stuck in voting loop | Expected behavior (zombie node after removal) |
| #315 | DisableAutoCompaction bug | User misunderstanding of semantics |
| #317 | Membership change concurrent risk | False positive (apply worker paused during snapshot) |
| #330 | PreVoteCampaign term+1 | False positive (standard PreVote protocol) |
| #256 | Dead node with no raft logs | User error (deleted raft data) |
| #259 | Randomly panic | User error (ImportSnapshot misuse) |

### 4.3 Key Commits

| Commit | Summary | Component | Severity |
|--------|---------|-----------|----------|
| `0045aa2` | Don't reset electionTick on RequestVote (becomeFollowerKE) | Election | Medium |
| `1c7ebd3` | Skip PreVote for leadership transfer target | LeaderTransfer | High |
| `175f332` | Fix term value of redirected LeaderTransfer message | LeaderTransfer | Medium |
| `ac6a472` | Fix incorrect observer promotion in restoreRemotes | Membership | High |
| `9772554` | Fix data race in leadership transfer request | Concurrency | Medium |
| `73092ad` | RestoreRemotes before updating lastApplied (ordering fix) | Snapshot | Medium |
| `7d5dc73` | Snapshot index consistent with SM state (atomic applied tracking) | Snapshot | High |
| `c07a3c5` | Fix nodes partition issue (copy-paste: wrong load function) | Engine | High |
| `08ff2aa` | Fix data race in engine loadedNodes | Concurrency | Medium |
| `df77126` | Fix multiple log query bugs (bounds, nil check, lifecycle) | LogQuery | Medium |

---

## 5. Deep Analysis Findings

### 5.1 Code Path Inconsistency: Leader Response Handlers

| Behavior | ReplicateResp (1878) | HeartbeatResp (1910) | SnapshotStatus (1976) | Unreachable (1997) |
|----------|:---:|:---:|:---:|:---:|
| `mustBeLeader()` | YES | YES | **NO** | **NO** |
| `rp.setActive()` | YES | YES | **NO** | **NO** |
| `tryCommit()` | YES | NO | NO | NO |
| `rp.respondedTo()` | YES | NO | NO | NO |
| `rp.waitToRetry()` | NO | YES | NO | NO |
| Leader transfer check | YES | **NO** | NO | NO |

**Finding F1: Missing `setActive()` in SnapshotStatus** (raft.go:1976)

Both `handleLeaderReplicateResp` (line 1880) and `handleLeaderHeartbeatResp` (line 1912) call `rp.setActive()`. `handleLeaderSnapshotStatus` does NOT. During a long snapshot transfer, the only communication between leader and follower may be snapshot status messages. The follower will never be marked active, causing `leaderHasQuorum()` to miss it. In a cluster with exactly a quorum of nodes where one is receiving a snapshot, the leader could step down unnecessarily.

**Impact**: Leader availability loss during snapshot transfers.
**Classification**: Model-checkable.

**Finding F2: `leaderHasQuorum()` is a side-effecting boolean** (raft.go:395-405)

```go
func (r *raft) leaderHasQuorum() bool {
    c := 0
    for nid, member := range r.votingMembers() {
        if nid == r.replicaID || member.isActive() {
            c++
            member.setNotActive()  // SIDE EFFECT
        }
    }
    return c >= r.quorum()
}
```

The function clears all active flags while checking quorum. If called twice, the second call always returns false. While only called once per CheckQuorum cycle currently, this is fragile.

**Impact**: Defensive, but any code change that adds a second call would break quorum checking.
**Classification**: Code-review-only.

### 5.2 Term Validation Architecture

**Finding F3: Term validation happens at dispatch, not in handlers** (raft.go:1540-1590)

`onMessageTermNotMatched()` at raft.go:1540 acts as a global term firewall:
- `m.Term > r.term`: node steps down, then handler runs (now as follower)
- `m.Term < r.term`: message dropped entirely
- `m.Term == r.term` or `m.Term == 0`: handler runs normally

This means individual handlers do NOT need term checks — they are guaranteed `m.Term == r.term` (or the node has already stepped down). This is a clean architectural decision. `doubleCheckTermMatched` at raft.go:2191 provides a paranoid assertion.

**Impact**: Positive — eliminates an entire class of "missing term check" bugs.
**Classification**: Not a finding — this is a strength.

### 5.3 Vote Safety

**Finding F4: No double-vote risk** (raft.go:1624-1627)

```go
func (r *raft) canGrantVote(m pb.Message) bool {
    return r.vote == NoNode || r.vote == m.From || m.Term > r.term
}
```

Condition 3 (`m.Term > r.term`) is **redundant** by the time `canGrantVote` runs. `onMessageTermNotMatched` at line 1549 calls `becomeFollowerKE(m.Term, ...)` which calls `reset()` which sets `r.vote = NoLeader` when `r.term != term`. So `r.vote` is already `NoNode` and condition 1 is true. Within a term, once `r.vote` is set, only the same candidate can get a grant (condition 2).

**Impact**: None — vote safety is maintained. The redundant condition is harmless.
**Classification**: Code-review-only.

### 5.4 Configuration Changes

**Finding F5: `hasConfigChangeToApply` is overly conservative** (raft.go:1611-1622)

```go
func (r *raft) hasConfigChangeToApply() bool {
    if r.hasNotAppliedConfigChange != nil {
        return r.hasNotAppliedConfigChange()  // test hook
    }
    return r.log.committed > r.getApplied()  // ANY unapplied entry blocks
}
```

The fallback (line 1621) returns `true` if there are ANY committed-but-not-applied entries, not just config change entries. This blocks elections whenever the apply pipeline is behind. The TODO at line 1617 acknowledges this can be fixed by scanning the in-memory log for config change entries.

**Impact**: Elections can be unnecessarily delayed when there is a backlog of regular entries being applied.
**Classification**: Model-checkable (liveness property).

**Finding F6: Config change silently dropped** (raft.go:1805-1808)

```go
if e.Type == pb.ConfigChangeEntry {
    if r.hasPendingConfigChange() {
        r.reportDroppedConfigChange(m.Entries[i])
        m.Entries[i] = pb.Entry{Type: pb.ApplicationEntry}  // silently replaced
    }
    r.setPendingConfigChange()
}
```

When a second config change is proposed while one is pending, it is silently converted to an empty ApplicationEntry. The caller's proposal succeeds (the entry is committed) but it's a no-op. The caller is not explicitly notified that their config change was dropped.

**Impact**: Client confusion — config change appears to succeed but has no effect.
**Classification**: Model-checkable (can verify the invariant that at most one config change is active).

### 5.5 Snapshot Interactions

**Finding F7: Early return in SnapshotStatus handler** (raft.go:1977)

```go
func (r *raft) handleLeaderSnapshotStatus(m pb.Message, rp *remote) error {
    if rp.state != remoteSnapshot {
        return nil  // silently drops
    }
    ...
}
```

If a snapshot status message arrives after the remote has already transitioned out of `remoteSnapshot` state (e.g., due to a heartbeat response or timeout), the message is silently dropped. Combined with Finding F1 (no `setActive` call), this means the activity signal from the snapshot transfer is completely lost.

**Impact**: Compounds with F1 — the only code path that could have set the active flag for a snapshot-receiving node silently discards the message.
**Classification**: Model-checkable (part of Family 1).

### 5.6 Persistence Layer

**Finding F8: PR #409 — silent persistence error** (internal/logdb/db.go)

In `saveRaftState` and `saveSnapshots`, when `saveSnapshot` fails, the function returns early with `return nil` (should be `return err`). The caller receives nil error and assumes the entire batch (including log entries) was successfully persisted. On crash, the unpersisted entries are lost, potentially violating LeaderCompleteness.

**Impact**: Silent data loss on snapshot save failure. Critical safety violation.
**Classification**: Model-checkable (persistence failure + crash = lost committed entries).
**Status**: Open PR #409, unfixed as of analysis date.

### 5.7 Log Entry Management

**Finding F9: Dead code in commitTo** (logentry.go:344)

```go
func (l *entryLog) commitTo(index uint64) {
    if index <= l.committed { return }     // line 337-339
    if index > l.lastIndex() { panic() }   // line 340-342
    if index < l.committed { panic() }     // line 344: UNREACHABLE
    l.committed = index
}
```

Line 344 is unreachable: after line 337-339 returns for `index <= l.committed`, we know `index > l.committed`, making the check at line 344 always false.

**Impact**: None (dead code).
**Classification**: Code-review-only.

**Finding F10: `savedLogTo` silently drops stale notifications** (inmemory.go:124-136)

Four conditions can cause a "saved to disk" notification to be silently dropped:
1. Index below marker (log was truncated)
2. Empty entries
3. Index beyond last entry
4. Term mismatch (entry was overwritten)

When dropped, `savedTo` is never advanced, causing the same entries to be re-reported by `entriesToSave()`. This is safe (idempotent writes) but wasteful.

**Impact**: Performance only — no correctness issue.
**Classification**: Code-review-only.

### 5.8 ReadIndex Protocol

**Finding F11: Defensive index rewrite** (readindex.go:101-103)

```go
// re-write the index for extra safety.
// we don't know what we don't know.
for _, v := range cs {
    v.index = s.index
}
```

When a ReadIndex request is confirmed by a quorum, all earlier pending read requests are upgraded to use the confirmed request's commit index. The comment "we don't know what we don't know" signals developer uncertainty about corner cases. The rewrite is conservative and correct — since the confirmed read proves the leader was valid at `s.index`, all earlier reads can safely use that index.

**Impact**: None — the conservative rewrite is safe.
**Classification**: Code-review-only.

### 5.9 Remote State Machine

**Finding F12: `decreaseTo` in replicate mode doesn't change state** (remote.go:186-188)

```go
if r.state == remoteReplicate {
    if rejected <= r.match { return false }
    r.next = r.match + 1   // regress next, stay in replicate mode
    return true
}
```

When a rejection is received while in replicate (pipeline) mode, `next` is regressed to `match + 1` but the remote stays in replicate mode. This means the leader immediately pipelines entries from the regression point, potentially sending a burst of previously-sent entries.

**Impact**: Performance — burst re-sends after rejection in pipeline mode. Not a safety issue.
**Classification**: Code-review-only.

---

## 6. Excluded Findings

### 6.1 False Positive: PR #224 (vote before persist)

**Claim**: Leader counts its own vote before entries are persisted.
**Refutation**: The FastApply logic (peer.go:210-226) disables concurrent apply when committed entries overlap with unsaved entries. The engine pipeline (engine.go:1343) persists before sending non-Replicate messages. The reporter examined the code and confirmed the safeguards are correct (PR closed by reporter).

### 6.2 False Positive: Issue #317 (membership change concurrent risk)

**Claim**: `StateMachine.apply()` and `GetMembership()` use different mutexes, allowing concurrent access to `s.members`.
**Refutation**: The apply worker is STOPPED while the snapshot worker is running. `configChange` and `installSnapshot` cannot execute concurrently for the same shard. The sequential execution guarantee eliminates the race.

### 6.3 False Positive: Issue #330 (preVoteCampaign term+1)

**Claim**: `preVoteCampaign` incorrectly increments term by 1.
**Refutation**: Standard PreVote protocol per Raft thesis Section 9.6. The candidate sends a hypothetical `term + 1` without actually incrementing its real term.

### 6.4 Not a bug: Heartbeat does not try commit

`handleLeaderHeartbeatResp` (raft.go:1910) does not call `tryCommit()`. This is correct because heartbeat responses do not report any new `match` index — they only confirm liveness. Only `ReplicateResp` (which carries the follower's updated match index) can advance the commit.

### 6.5 Not a bug: `becomeFollowerKE` preserves election tick

Commit `0045aa2` introduced `becomeFollowerKE` which preserves the election tick when stepping down due to a RequestVote with a higher term. This is a deliberate timing defense for slow nodes — if a node's tick rate is lower than peers, resetting the election tick would prevent it from ever campaigning.
