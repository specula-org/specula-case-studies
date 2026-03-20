# Modeling Brief: wenweihu86/raft-java

## 1. System Overview

- **System**: wenweihu86/raft-java — Java Raft consensus library with PreVote extension
- **Language**: Java, ~2000 LOC core logic (excluding 14K lines generated protobuf)
- **Protocol**: Raft (Ongaro 2014) with PreVote extension
- **Key architectural choices**:
  - Single `ReentrantLock` protects most shared state; separate lock for snapshot operations
  - Heartbeats and log replication share the **same `appendEntries()` method** — no separate heartbeat path
  - `startVote()` increments `currentTerm` and sets `votedFor` **without persisting** to disk (issue #57)
  - Follower `advanceCommitIndex` has **no monotonicity guard** — commitIndex can decrease (issue #54)
  - Single `configuration` variable (no committed/latest distinction); applied immediately on commit
  - Configuration changes are single-step (no joint consensus, no single-server restriction)
  - `peer.voteGranted` field is **shared between PreVote and Vote** phases
- **Concurrency model**: Main lock serializes state access; `ExecutorService` thread pool dispatches RPCs (appendEntries, vote requests); `ScheduledExecutorService` for timers (election, heartbeat, snapshot)

## 2. Bug Families

### Family 1: Persistence Gaps (CRITICAL)

**Mechanism**: Critical Raft persistent state (currentTerm, votedFor) is updated in memory but not flushed to disk before external communication, violating Raft's persistence requirements.

**Evidence**:
- Historical: Issue #19 / commit `128a159` — commitIndex not persisted, state machine data loss on restart (FIXED)
- Historical: Issue #56 — SegmentedLog crash on restart when no metadata file exists (consequence of #57, UNFIXED)
- Code analysis: `RaftNode.java:497-501` — `startVote()` increments `currentTerm++` and sets `votedFor=localServer` but never calls `raftLog.updateMetaData()`. RPCs are sent after releasing the lock with unpersisted state.
- Code analysis: `RaftNode.java:307` — `stepDown()` correctly persists via `updateMetaData()`, proving the pattern exists but was omitted in `startVote()`.

**Affected code paths**:
- `startVote()` (RaftNode.java:490-518) — missing persistence
- `stepDown()` (RaftNode.java:298-315) — has persistence (correct)
- `requestVote` handler (RaftConsensusServiceImpl.java:85-87) — has persistence (correct)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor` (separate from volatile state)
- Actions: Split `StartVote` into two steps: (1) update volatile state + send RPCs, (2) `PersistVote` flushes to disk. Model `Crash` that recovers from persisted state only.
- Also model atomic persistence: `StartVoteAtomic` for trace validation (normal non-crash path)

**Priority**: High
**Rationale**: Issue #57 is unfixed, causes issue #56 (crash on restart), and can violate ElectionSafety (double-vote after crash-restart). Crash recovery is a classic TLA+ strength.

---

### Family 2: Commit/Match Index Monotonicity Violations (HIGH)

**Mechanism**: Out-of-order messages and concurrent RPCs cause commitIndex and matchIndex to decrease, violating Raft's monotonicity requirements.

**Evidence**:
- Issue #54 — Follower commitIndex decreases on stale AppendEntries (UNFIXED)
- Issue #53 — Leader matchIndex decreases on stale response from delayed heartbeat (UNFIXED)
- Code analysis: `RaftConsensusServiceImpl.java:315` — `raftNode.setCommitIndex(newCommitIndex)` unconditionally, no `newCommitIndex > commitIndex` guard
- Code analysis: `RaftNode.java:276` — `peer.setMatchIndex(prevLogIndex + numEntries)` unconditionally, no monotonicity check
- Code analysis: `RaftConsensusServiceImpl.java:316` — regressed commitIndex is persisted to disk, meaning crash-recovery would start with a lower commitIndex than was previously committed
- Code analysis: Concurrent thread pool calls to `appendEntries()` for the same peer (heartbeat + replication) race on matchIndex

**Affected code paths**:
- `advanceCommitIndex` (RaftConsensusServiceImpl.java:312-331) — follower, no monotonicity guard
- `appendEntries` response handling (RaftNode.java:275-277) — leader, no monotonicity guard
- `advanceCommitIndex` (RaftNode.java:737-776) — leader, has `commitIndex >= newCommitIndex` guard (correct)

**Suggested modeling approach**:
- Variables: Model message reordering (standard TLA+ message bag provides this)
- Actions: Allow out-of-order delivery of AppendEntries; check if follower commitIndex decreases
- Key: The leader-side advanceCommitIndex DOES have a guard (line 758), but the follower-side does NOT

**Priority**: High
**Rationale**: Both bugs are unfixed, affect current HEAD, and the commitIndex regression is persisted to disk — meaning committed entries can be lost on crash-recovery. Directly testable via message reordering in TLA+.

---

### Family 3: Snapshot-State Desync (HIGH)

**Mechanism**: The `installSnapshot` handler omits critical state updates that the constructor performs during startup, leaving the node with stale `configuration`, `commitIndex`, and `lastAppliedIndex` after installing a snapshot.

**Evidence**:
- Code analysis: `RaftConsensusServiceImpl.java:279-301` — after final snapshot chunk, does NOT update `configuration`, `commitIndex`, or `lastAppliedIndex`
- Code analysis: `RaftNode.java:90,97-100,112` — constructor correctly sets all three from snapshot metadata
- Historical: 5+ snapshot bug-fix commits in git history (`dd48b12`, `ecacf67`, `2eada10`, `1461a58`, `132e237`)

**Affected code paths**:
- `installSnapshot` handler (RaftConsensusServiceImpl.java:192-309) — missing state updates
- `RaftNode` constructor (RaftNode.java:69-113) — correct reference implementation

**Suggested modeling approach**:
- Variables: `snapshotIndex`, `snapshotConfig` (per server)
- Actions: `InstallSnapshot` that atomically updates state machine but does NOT update configuration/commitIndex. `ReceiveAppendEntries` that then tries to apply entries from stale lastAppliedIndex.
- Invariant: After InstallSnapshot, configuration should match snapshot's configuration

**Priority**: High
**Rationale**: After snapshot install, node operates with stale configuration — may not recognize current cluster members, fail quorum checks, or allow removed nodes to participate. The 5+ historical snapshot bugs confirm this area is error-prone.

---

### Family 4: Election/Vote Protocol Deviations (MEDIUM)

**Mechanism**: Multiple deviations from the Raft paper's election specification, including missing vote re-grant, shared pre-vote/vote state, and fabricated terms.

**Evidence**:
- Historical: Issue #3 / commit `a1c43d4` — vote response handler didn't step down on higher term (FIXED)
- Issue #48 — PreVote callback sets `peer.voteGranted` before staleness check, can pollute real vote phase (UNFIXED)
- Code analysis: `RaftConsensusServiceImpl.java:84` — requestVote checks `votedFor == 0` only, missing `|| votedFor == request.getServerId()` (Raft paper: "votedFor is null or candidateId")
- Code analysis: `RaftNode.java:531` — PreVote sends `currentTerm` instead of `currentTerm + 1` (deviates from standard PreVote protocol)
- Code analysis: `RaftConsensusServiceImpl.java:124` — two-leader detection fabricates `request.getTerm() + 1`, creating a term with no corresponding election
- Code analysis: `RaftConsensusServiceImpl.java:107-108` — AppendEntries response term is set BEFORE stepDown updates the term (issue #55)

**Affected code paths**:
- `requestVote` handler (RaftConsensusServiceImpl.java:66-99)
- `preVote` handler (RaftConsensusServiceImpl.java:34-63)
- `PreVoteResponseCallback` (RaftNode.java:566-628)
- `VoteResponseCallback` (RaftNode.java:630-694)
- `appendEntries` handler (RaftConsensusServiceImpl.java:101-190)

**Suggested modeling approach**:
- Variables: `voteGranted` as per-phase variable (not shared)
- Actions: Model PreVote and Vote as separate phases with separate vote tracking
- Key invariant: At most one leader per term (ElectionSafety)

**Priority**: Medium
**Rationale**: Issue #3 (the most severe) is fixed. Remaining issues (#48, missing re-vote, fabricated term) are edge cases. The shared voteGranted field is worth modeling as it can cause incorrect vote tallies.

---

### Family 5: Configuration Change Safety (MEDIUM)

**Mechanism**: Membership changes use a single-step approach without joint consensus or single-server restriction, with arbitrary constraints and missing protections.

**Evidence**:
- Issue #27 — no joint consensus, owner disputes but doesn't resolve
- Code analysis: `RaftClientServiceImpl.java:87` — addPeers requires even number of servers (arbitrary)
- Code analysis: `RaftClientServiceImpl.java:176` — removePeers requires even number of servers (arbitrary)
- Code analysis: No guard against concurrent configuration changes (multiple addPeers/removePeers in flight)
- Code analysis: `installSnapshot` doesn't update configuration (see Family 3)

**Affected code paths**:
- `addPeers` (RaftClientServiceImpl.java:83-169)
- `removePeers` (RaftClientServiceImpl.java:172-216)
- `applyConfiguration` (RaftNode.java:400-418)

**Suggested modeling approach**:
- Variables: `configuration` (per server), `pendingConfigChange`
- Actions: `ProposeConfigChange` that adds/removes multiple servers in one step. Check if two disjoint majorities can form during the transition.
- Key: No joint consensus means the old and new configurations can independently elect leaders

**Priority**: Medium
**Rationale**: The owner claims safety is maintained because new members don't vote until the change is committed by the old majority. Worth verifying with TLA+ — the single-step multi-server change is unusual.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Non-atomic startVote persistence | Family 1: unfixed #57, can violate ElectionSafety | Split into volatile update + persist steps; Crash recovers from persisted state |
| CommitIndex monotonicity | Family 2: unfixed #54, commitIndex regression persisted to disk | Model message reordering; check follower commitIndex never decreases |
| MatchIndex monotonicity | Family 2: unfixed #53, delayed responses reset matchIndex | Model concurrent heartbeat + replication responses |
| Snapshot state updates | Family 3: configuration not updated after installSnapshot | InstallSnapshot action that updates state machine but not configuration |
| Shared PreVote/Vote state | Family 4: unfixed #48, vote count corruption | Per-phase vote tracking variables |
| Single-step config change | Family 5: no joint consensus, multi-server changes | Model add/remove of 2+ servers simultaneously |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Replicate-to-self NPE (#52) | Implementation bug (null pointer), not protocol logic. Silently swallowed by thread pool. |
| Stale term in AE response (#55) | Minor protocol deviation — response carries old term. No safety impact (leader already handles higher-term responses). |
| Fabricated term on two-leader detection | Edge case for a situation that "shouldn't happen" in correct Raft. Defensive measure. |
| PreVote term off-by-one | Sends currentTerm instead of currentTerm+1. Functionally equivalent in most scenarios. Low impact. |
| asyncWrite mode | Design choice (leader returns before majority commit). Intentional performance tradeoff, not a bug. |
| Read consistency (#31) | Application-level concern. No linearizable read mechanism, but this is a common Raft implementation omission. |
| SegmentedLog internal bugs (#51, #56) | Storage layer bugs, not protocol logic. Better verified by unit tests. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic persistence | `persistedTerm`, `persistedVotedFor` | Model crash between volatile update and disk flush | Family 1 |
| Crash recovery | `crashed` (boolean per server) | Crash action resets volatile state; recovers from persisted | Family 1, 2 |
| Message reordering | (standard TLA+ message bag) | Out-of-order delivery triggers monotonicity violations | Family 2 |
| Snapshot install | `snapshotIndex`, `snapshotConfig` | Model partial state updates after installSnapshot | Family 3 |
| Per-phase vote tracking | `preVoteGranted`, `realVoteGranted` (separate maps) | Prevent PreVote/Vote state pollution | Family 4 |
| Multi-server config change | `pendingConfig` | Model concurrent add/remove of multiple servers | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + Family 1, 4 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard + Family 1 |
| CommitIndexMonotonicity | Safety | commitIndex never decreases on any server | Family 2 |
| MatchIndexMonotonicity | Safety | leader's matchIndex[peer] never decreases | Family 2 |
| CommitSurvivesCrash | Safety | After crash-recovery, commitIndex >= pre-crash committed value | Family 1, 2 |
| SnapshotConfigConsistency | Safety | After installSnapshot, node's configuration matches snapshot's configuration | Family 3 |
| VotePhaseSeparation | Safety | PreVote results don't affect real vote tallies | Family 4 |
| ConfigChangeSafety | Safety | At most one leader per term, even during multi-server config changes | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | startVote crash: term persisted but votedFor not (or neither persisted) | ElectionSafety (double-vote) | 1 |
| MC-2 | Stale AppendEntries causes follower commitIndex regression | CommitIndexMonotonicity | 2 |
| MC-3 | Delayed heartbeat response resets leader matchIndex | MatchIndexMonotonicity | 2 |
| MC-4 | Regressed commitIndex persisted, then crash — committed entries lost | CommitSurvivesCrash, LeaderCompleteness | 1, 2 |
| MC-5 | installSnapshot + next AppendEntries: node uses stale configuration | SnapshotConfigConsistency | 3 |
| MC-6 | Late PreVote callback corrupts real vote count → wrong leader elected | ElectionSafety, VotePhaseSeparation | 4 |
| MC-7 | Multi-server add: old and new configs form independent majorities | ConfigChangeSafety | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | replicate() passes null peer to appendEntries (#52) | Unit test: call replicate() with self in configuration, verify NPE is caught |
| TV-2 | SegmentedLog crash when metadata file missing (#56) | Integration test: write log entry, delete metadata file, restart |
| TV-3 | Segment.getEntry returns null for open segments (#51) | Unit test: create open segment, query entry within range |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | requestVote missing `votedFor == candidateId` re-vote check | Line-by-line comparison with Raft Figure 2 |
| CR-2 | PreVote sends currentTerm instead of currentTerm+1 | Design review — functionally similar but deviates from standard |
| CR-3 | Two-leader detection fabricates term+1 | Review whether this defensive measure has unintended consequences |
| CR-4 | advanceCommitIndex wrong for even peer counts (#21) | Owner dismissed; verify if even counts are truly impossible |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/raft-java/analysis-report.md`
- **Key source files**:
  - `artifact/raft-java/raft-java-core/src/main/java/com/github/wenweihu86/raft/RaftNode.java` (1012 lines — state machine, election, replication)
  - `artifact/raft-java/raft-java-core/src/main/java/com/github/wenweihu86/raft/service/impl/RaftConsensusServiceImpl.java` (334 lines — RPC handlers)
  - `artifact/raft-java/raft-java-core/src/main/java/com/github/wenweihu86/raft/service/impl/RaftClientServiceImpl.java` (217 lines — config changes)
  - `artifact/raft-java/raft-java-core/src/main/java/com/github/wenweihu86/raft/storage/SegmentedLog.java` (362 lines — log storage)
- **GitHub issues**: #57, #56, #55, #54, #53, #52, #48 (unfixed); #19, #28, #3 (fixed); #27 (design)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Figure 2
