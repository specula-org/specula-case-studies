# Analysis Report: wenweihu86/raft-java

## 1. Codebase Reconnaissance

### 1.1 Core Files

| File | LOC | Role |
|------|-----|------|
| `RaftNode.java` | 1012 | Main state machine: election, heartbeat, replication, snapshot, config |
| `RaftConsensusServiceImpl.java` | 334 | RPC handlers: preVote, requestVote, appendEntries, installSnapshot |
| `RaftClientServiceImpl.java` | 217 | Client API: addPeers, removePeers, getLeader, getConfiguration |
| `SegmentedLog.java` | 362 | Segmented file-based log storage |
| `Snapshot.java` | 156 | Snapshot management and file I/O |
| `Peer.java` | 76 | Per-peer connection and replication state |
| `RaftOptions.java` | 47 | Configuration options |
| `ConfigurationUtils.java` | 49 | Configuration helper methods |
| `Segment.java` | 97 | Log segment data structure |
| `StateMachine.java` | 26 | State machine interface |
| `RaftProto.java` | 14137 | Generated protobuf (not analyzed) |
| **Total core logic** | **~2000** | |

### 1.2 Concurrency Model

- **Main lock**: Single `ReentrantLock` protects `state`, `currentTerm`, `votedFor`, `commitIndex`, `leaderId`, `configuration`, and peer state
- **Snapshot lock**: Separate `ReentrantLock` on `Snapshot` object
- **Thread pool**: `ExecutorService` (20 threads default) dispatches all RPCs
- **Scheduled pool**: 2 threads for election timer, heartbeat timer, and snapshot timer
- **Key pattern**: Lock acquired → read/modify state → lock released → RPC call → lock re-acquired → process response. This creates windows where state can change between request build and response processing.

### 1.3 State Model

```
States: FOLLOWER → PRE_CANDIDATE → CANDIDATE → LEADER → FOLLOWER
                                                         ↑
                                              (stepDown on higher term)
```

Persistent state (via `SegmentedLog.updateMetaData`):
- `currentTerm`, `votedFor`, `firstLogIndex`, `commitIndex`

Volatile state:
- `state`, `leaderId`, `lastAppliedIndex`, `peer.matchIndex`, `peer.nextIndex`, `peer.voteGranted`

### 1.4 Key Architectural Observations

1. **No separate heartbeat path**: Both heartbeats and log replication call `appendEntries(peer)`. This simplifies the code but means out-of-order heartbeat responses can affect replication state.

2. **Single configuration**: Only one `configuration` variable. No committed/latest distinction. Applied immediately when the configuration entry is committed. No joint consensus.

3. **PreVote implemented**: Two-phase election (PreVote then Vote). But PreVote sends `currentTerm` instead of `currentTerm+1`.

4. **Shared `voteGranted` field**: `Peer.voteGranted` is used for both PreVote and Vote responses, creating potential for cross-phase contamination.

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits in repo | ~95 |
| Bug-fix commits analyzed | 19 |
| Total GitHub issues | 48 |
| Issues deeply read (full discussion) | 21 |
| Confirmed bugs (from issues) | 13 |
| Fixed bugs | 5 |
| Unfixed bugs | 8 |
| Design defects | 3 |
| User error / questions | 5 |
| PRs analyzed | 12 |

### 2.2 Historical Bug-Fix Commits

#### Election Bugs
| Commit | Summary | Root Cause |
|--------|---------|------------|
| `a751dd1` | Server bootstrap: voteGranted null handling | `boolean` → `Boolean` for null distinction |
| `aff71e7` | RequestVote NPE on empty log | `getLastLogTerm()` crashes when lastLogIndex=0 |
| `144dead` | Stale vote responses not ignored | Missing term/state staleness check in callback |
| `d7e335c` | Follower didn't stepDown on AE from leader | Conditional stepDown should be unconditional for term >= currentTerm |
| `37972b8` | Configuration not built correctly; votes sent to self | Immutable protobuf list mutation; missing self-skip |
| `a1c43d4` | Vote response: `response.getTerm` vs `request.getTerm` | Dead code: `currentTerm != response.getTerm` returned before `response.getTerm > currentTerm` could trigger stepDown |

#### Replication/Commit Bugs
| Commit | Summary | Root Cause |
|--------|---------|------------|
| `6bcfe21` | Heartbeat prevLogTerm NPE | Wrong order of checks: range vs zero |
| `a430605` | matchIndexes loop off-by-one | `i < peerNum - 1` should be `i < peerNum` |
| `c92d494` | Follower commitIndex set wrong | Was `commitIndex = request.getCommitIndex()` instead of `min(leaderCommit, lastNewEntry)` |
| `e85b126` | nextIndex backtracking too slow | Decremented by 1 instead of jumping to `response.getLastLogIndex() + 1` |
| `128a159` | commitIndex not persisted (issue #19) | Data loss on restart: committed entries re-applied from snapshot |
| `b405f54` | truncateSuffix wrong key type (issue #28) | `remove(fileName)` on map keyed by `startIndex` |

#### Snapshot Bugs
| Commit | Summary | Root Cause |
|--------|---------|------------|
| `dd48b12` | Multiple snapshot bugs | Wrong directory paths, isInSnapshot never reset, wrong timer type |
| `1461a58` | Snapshot metadata write order | Wrote old metaData instead of new; corrupted in-memory state |
| `ecacf67` | Snapshot install: empty log after snapshot | `getLastLogTerm()` used raftLog (empty) instead of snapshot metadata |
| `2eada10` | Snapshot file handle leak; inverted condition | `!isTakeSnapshot` should be `isTakeSnapshot`; opened files never closed |
| `132e237` | Deadlock in appendEntries/installSnapshot | Lock released for installSnapshot but never re-acquired |

### 2.3 Open (Unfixed) Issues

| Issue | Title | Severity | Classification |
|-------|-------|----------|---------------|
| #57 | `startVote` doesn't persist currentTerm/votedFor | Critical | Raft paper violation |
| #56 | SegmentedLog crash on restart (no metadata) | High | Consequence of #57 |
| #55 | AppendEntries response carries stale term | Medium | Protocol deviation |
| #54 | Follower commitIndex can decrease | High | Raft paper violation |
| #53 | Leader matchIndex can decrease | High | Raft paper violation |
| #52 | Replicate sends appendEntries to self (NPE) | Medium | Implementation bug |
| #48 | PreVote callback pollutes real vote phase | Medium | Race condition |
| #21 | advanceCommitIndex wrong for even cluster sizes | Low (latent) | Math error |

### 2.4 Fixed Issues

| Issue | Title | Fix Commit |
|-------|-------|-----------|
| #3 | Vote response handling violates Raft rules | `a1c43d4` |
| #19 | commitIndex not persisted → data loss | `128a159` |
| #28 | truncateSuffix wrong map key | `b405f54` |

### 2.5 Design Defects

| Issue | Title | Impact |
|-------|-------|--------|
| #27 | No joint consensus for config changes | Potential for two leaders during multi-server change |
| #31 | No linearizable read mechanism | Stale reads during partitions |
| #47/#58 | asyncWrite returns success before majority commit | Data loss if leader crashes |

---

## 3. Deep Analysis Findings

### 3.1 NEW: installSnapshot Doesn't Update Node State

**Location**: `RaftConsensusServiceImpl.java:279-301`

After the final snapshot chunk is received and applied:
1. State machine is loaded from snapshot (line 283)
2. Snapshot metadata is reloaded (line 288)
3. Log is truncated (line 297)

But **NOT** updated:
- `commitIndex` — remains at old value
- `lastAppliedIndex` — remains at old value
- `configuration` — remains at old value

**Comparison with constructor** (`RaftNode.java:69-113`):
- Line 90: `commitIndex = Math.max(snapshot.lastIncludedIndex, raftLog.commitIndex)` ✓
- Line 97-100: `configuration = snapshotConfiguration` if present ✓
- Line 112: `lastAppliedIndex = commitIndex` ✓

**Impact**: After snapshot install, node operates with stale configuration. May not recognize new cluster members. If the snapshot included config changes, the node is in an inconsistent state.

**Consequence for follower advanceCommitIndex**: With `lastAppliedIndex` still at old value (say 5) and log truncated to start at `lastSnapshotIndex + 1` (say 101), the apply loop at lines 319-329 iterates from 6 to commitIndex. For indices 6-100, `getEntry()` returns null (truncated). The null check at line 322 skips them, but `setLastAppliedIndex(index)` at line 329 still advances. Configuration change entries in the gap are silently lost.

### 3.2 NEW: requestVote Missing Re-Vote for Same Candidate

**Location**: `RaftConsensusServiceImpl.java:84`

```java
if (raftNode.getVotedFor() == 0 && logIsOk) {
```

Raft paper (Figure 2): "If votedFor is null **or candidateId**, and candidate's log is at least as up-to-date..."

Missing condition: `|| raftNode.getVotedFor() == request.getServerId()`

**Impact**: If a RequestVote RPC response is lost and the candidate retries, the follower rejects the retry because `votedFor != 0` (it's already set to the candidate's ID). This causes unnecessary election timeouts under packet loss.

### 3.3 NEW: Fabricated Term on Two-Leader Detection

**Location**: `RaftConsensusServiceImpl.java:120-128`

```java
if (raftNode.getLeaderId() != request.getServerId()) {
    raftNode.stepDown(request.getTerm() + 1);
    responseBuilder.setTerm(request.getTerm() + 1);
    return responseBuilder.build();
}
```

When a follower detects two different leaders claiming the same term, it fabricates `term + 1` — a term in which no election has occurred. The response carries this fabricated term, causing the sender to also step down. This creates "phantom terms" that don't correspond to any election.

**Impact**: Term inflation. Both leaders step down. A new election starts at the fabricated term. This is a recovery mechanism for a "can't happen" situation in correct Raft, but it violates the invariant that each term has at most one election.

### 3.4 NEW: PreVote Sends Wrong Term

**Location**: `RaftNode.java:530-533`

```java
requestBuilder.setServerId(localServer.getServerId())
        .setTerm(currentTerm)     // should be currentTerm + 1
        .setLastLogIndex(raftLog.getLastLogIndex())
        .setLastLogTerm(getLastLogTerm());
```

Standard PreVote protocol (Raft thesis §9.6) sends `currentTerm + 1` to simulate what the real election term would be. This code sends `currentTerm`. The practical impact is low: for peers at the same term, the result is the same. For peers one term ahead, the pre-vote is rejected (whereas standard protocol would pass). This makes pre-vote elections slightly more conservative.

### 3.5 NEW: Concurrent appendEntries Race on matchIndex

**Location**: `RaftNode.java:161-168` and `RaftNode.java:723-731`

Both `replicate()` and `startNewHeartbeat()` submit `appendEntries(peer)` to the thread pool. Two concurrent `appendEntries` calls for the same peer can interleave:

1. Call A (heartbeat): captures `prevLogIndex=10, numEntries=0`, sends RPC
2. Call B (replication): captures `prevLogIndex=10, numEntries=5`, gets response first → `matchIndex=15`
3. Call A response arrives → `matchIndex=10` (regression from 15)

Since `peer.setMatchIndex()` (Peer.java:56) is a plain setter with no monotonicity guard, this race can regress matchIndex. Combined with the follower commitIndex monotonicity bug (#54), this can cascade to the follower.

### 3.6 Verified: Regressed commitIndex Is Persisted

**Location**: `RaftConsensusServiceImpl.java:316`

```java
raftNode.getRaftLog().updateMetaData(null, null, null, newCommitIndex);
```

The follower's `advanceCommitIndex` persists `newCommitIndex` to disk **unconditionally**, even when it's lower than the previous commitIndex. After a crash, the node restarts with the regressed commitIndex, potentially losing committed entries that were applied before the regression.

This makes issue #54 more severe than reported: not just a transient violation but a persistent one.

---

## 4. Bug Family Organization

### Family 1: Persistence Gaps
- **Members**: Issue #57, #56, #19 (fixed), startVote persistence gap
- **Mechanism**: Persistent state updated in memory but not flushed before RPCs
- **Priority**: CRITICAL

### Family 2: Monotonicity Violations
- **Members**: Issue #54, #53, concurrent race on matchIndex, persisted regression
- **Mechanism**: Missing monotonicity guards + out-of-order messages/responses
- **Priority**: HIGH

### Family 3: Snapshot-State Desync
- **Members**: installSnapshot missing config/commitIndex/lastAppliedIndex updates, 5+ historical snapshot bugs
- **Mechanism**: installSnapshot handler omits state updates that constructor performs
- **Priority**: HIGH

### Family 4: Election/Vote Protocol Deviations
- **Members**: Issue #3 (fixed), #48, missing re-vote, PreVote wrong term, fabricated term
- **Mechanism**: Multiple deviations from Raft paper Figure 2
- **Priority**: MEDIUM

### Family 5: Configuration Change Safety
- **Members**: Issue #27, arbitrary even-number constraint, no concurrent change guard
- **Mechanism**: Oversimplified membership change without joint consensus
- **Priority**: MEDIUM

---

## 5. False Positives / Excluded Findings

| Finding | Why Excluded |
|---------|-------------|
| #22 (leader rejects same-term vote) | User misunderstanding — candidates increment term before requesting votes |
| #44 (election questions) | User questions, not bugs |
| #43 (pre-vote term question) | User question, not a bug |
| #12 (advanceCommitIndex for even counts) | Duplicate of #21, dismissed by owner as "odd counts in practice" |
| Leader advanceCommitIndex has `commitIndex >= newCommitIndex` guard | Verified at RaftNode.java:758 — leader side is correct |
| appendEntries response missing state check | Compensating mechanism: `getEntryTerm(newCommitIndex) != currentTerm` at line 752 prevents stale-term commits |
