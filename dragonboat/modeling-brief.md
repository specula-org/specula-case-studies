# Modeling Brief: lni/dragonboat

## 1. System Overview

- **System**: lni/dragonboat — Go multi-group Raft consensus library
- **Language**: Go, ~2,500 LOC core Raft logic (`internal/raft/raft.go`), ~19,000 LOC total
- **Protocol**: Raft (with PreVote, CheckQuorum, Leadership Transfer, NonVoting/Witness roles)
- **Key architectural choices**:
  - 2D handler dispatch table: `handlers[state][messageType]` (raft.go:2332)
  - Heartbeat is a separate message type from Replicate (not embedded)
  - Replicate messages sent BEFORE persistence per thesis 10.2.1 (engine.go:1332-1336)
  - All other messages (votes, etc.) sent AFTER persistence (engine.go:1354)
  - {Term, Vote, Commit} persisted as **single atomic protobuf blob** in one Pebble batch (db.go:307-320)
  - Six node states: follower, candidate, preVoteCandidate, leader, nonVoting, witness
  - Single-change-at-a-time config change enforcement via `pendingConfigChange` flag
- **Concurrency model**: Worker pool architecture — step/commit/apply/snapshot workers drive the Raft state machine; `raftMu` ensures single-threaded access to the Peer object

## 2. Bug Families

### Family 1: CheckQuorum Quorum Miscalculation (HIGH)

**Mechanism**: The leader's quorum check can produce incorrect results due to (a) missing activity tracking during snapshot transfers and (b) a side-effecting boolean function that destroys state on read.

**Evidence**:
- Code analysis: raft.go:1976 — `handleLeaderSnapshotStatus` does NOT call `rp.setActive()`, unlike `handleLeaderReplicateResp` (line 1880) and `handleLeaderHeartbeatResp` (line 1912). During long snapshot transfers, the only leader-follower communication is snapshot status messages. The follower is never marked active, so `leaderHasQuorum()` at raft.go:395 does not count it.
- Code analysis: raft.go:395-405 — `leaderHasQuorum()` clears all `active` flags as a side effect of the boolean check. If called twice in the same cycle, the second call always returns false.
- Code analysis: raft.go:1977 — early return when `rp.state != remoteSnapshot` silently drops snapshot status messages that arrive after the remote transitions out of snapshot state (race between status delivery and state transition).

**Affected code paths**:
- `handleLeaderSnapshotStatus()` (raft.go:1976-1995)
- `handleLeaderReplicateResp()` (raft.go:1878-1908)
- `handleLeaderHeartbeatResp()` (raft.go:1910-1923)
- `leaderHasQuorum()` (raft.go:395-405)
- `handleLeaderCheckQuorum()` (raft.go:1785-1791)

**Suggested modeling approach**:
- Variables: `active [Server -> BOOLEAN]`, `remoteState [Leader -> Server -> RemoteStateType]`
- Actions: Split response handling into `HandleReplicateResponse` (sets active, tries commit), `HandleHeartbeatResponse` (sets active, no commit), `HandleSnapshotStatus` (does NOT set active). Add `CheckQuorum` action that clears all active flags after checking.
- Key property: model a scenario where a node is in snapshot state and is the quorum-deciding vote.

**Priority**: High
**Rationale**: The `setActive()` omission is a concrete code path inconsistency. Combined with the side-effecting `leaderHasQuorum()`, this creates a realistic scenario where a leader with a quorum of responsive nodes steps down during a snapshot transfer.

---

### Family 2: Configuration Change + Election Interaction (MEDIUM)

**Mechanism**: Config change enforcement is both too broad (blocks elections unnecessarily) and too silent (drops second config changes without error), with historical bugs showing the config change subsystem is error-prone.

**Evidence**:
- Code analysis: raft.go:1617-1621 — `hasConfigChangeToApply()` blocks elections whenever ANY committed-but-not-applied entries exist, not just config change entries. The TODO at line 1617 acknowledges this is a known simplification.
- Code analysis: raft.go:1806 — when a second config change is proposed while one is pending, it is silently converted to an empty `ApplicationEntry`. No error is returned to the caller.
- Historical: #75 — invalid membership change (deleting the only node) was accepted and caused unrecoverable panics on restart. Fixed in v3.0.2 with validation.
- Historical: commit `ac6a472` (#94) — `restoreRemotes` incorrectly promoted any observer to follower when it saw a snapshot with that observer's ID in the Addresses map. Fixed to only self-promote.
- Code analysis: raft.go:1075-1083 — `preLeaderPromotionHandleConfigChange` panics if more than one uncommitted config change exists, which is the safety assertion for the single-change-at-a-time invariant.

**Affected code paths**:
- `handleNodeElection()` (raft.go:1632-1666)
- `hasConfigChangeToApply()` (raft.go:1611-1622)
- `handleLeaderPropose()` (raft.go:1794-1815)
- `handleNodeConfigChange()` (raft.go:1724-1745)
- `addNode()` / `removeNode()` (raft.go:1236-1299)
- `restoreRemotes()` (raft.go:493-537)

**Suggested modeling approach**:
- Variables: `pendingConfigChange [Server -> BOOLEAN]`, `membership [Server -> SUBSET Server]`
- Actions: `ProposeConfigChange` (appends config entry, sets pending flag), `ApplyConfigChange` (modifies membership, clears flag), `ProposeConfigChangeDuplicate` (silently dropped). Election action checks `hasConfigChangeToApply` — model both the conservative version (any unapplied entry blocks) and the correct version (only config entries block).
- Key: verify that the one-at-a-time invariant holds and that elections are not unnecessarily blocked.

**Priority**: Medium
**Rationale**: 3+ historical bugs in this area, acknowledged TODO for the overly conservative guard. TLA+ is well-suited for exploring config change + election interleaving. However, dragonboat's single-change-at-a-time enforcement is simpler than hashicorp/raft's dual committed/latest config model.

---

### Family 3: Persistence Error Silent Drop (HIGH)

**Mechanism**: Errors during persistence operations are silently swallowed, causing the caller to believe writes succeeded when they did not.

**Evidence**:
- PR #409 (open, unmerged): In `internal/logdb/db.go`, `saveRaftState` and `saveSnapshots` contain `return nil` where `return err` should be used after `saveSnapshot` failure. When `saveSnapshot` fails, the function exits early without calling `saveEntries` or `CommitWriteBatch`, silently dropping the entire batch of raft log entries. The caller receives nil and assumes the write succeeded.
- Historical: #156/#369 — `IOnDiskStateMachine` returns a stale index during `Open()`, and dragonboat silently ignores the inconsistency, applying a dummy snapshot without verifying the state machine's actual state. Fixed on master via PR #161, but was present for years.
- Historical: #374 (PR, closed unmerged) — `NewNodeHost` panic recovery type-asserts recovered value as `error`, but `panic()` can be called with a string. On string panics, the recovery silently returns nil with no error.

**Affected code paths**:
- `db.saveRaftState()` (internal/logdb/db.go:179-204)
- `db.saveSnapshots()` (internal/logdb/db.go:346-363)
- `statemachine.Recover()` (internal/rsm/statemachine.go)
- `NewNodeHost()` (nodehost.go:339)

**Suggested modeling approach**:
- Variables: `diskError [Server -> BOOLEAN]`
- Actions: `SaveRaftState` with a failure branch that silently succeeds (models the PR #409 bug). `Crash` action that recovers from persisted state — but if the persist was silently dropped, the recovered state is stale.
- Key: model the scenario where a leader persists entries, gets a success return (due to silent error), sends commit confirmation to clients, then crashes. On recovery, those entries are gone.

**Priority**: High
**Rationale**: PR #409 is unfixed and critical — it can cause silent data loss. #156/#369 was a years-long bug affecting production. The pattern of "silent error = data loss" is the most dangerous category because it violates assumptions that the upper layers depend on.

---

### Family 4: Leadership Transfer Edge Cases (LOW)

**Mechanism**: Leadership transfer has path-specific bugs when interacting with PreVote and response handlers.

**Evidence**:
- Historical: commit `1c7ebd3` (#223) — LeaderTransfer didn't work when PreVote was enabled because the transfer target entered preVote campaign instead of full campaign. The fix skips preVote when `isLeaderTransferTarget` is true.
- Historical: commit `175f332` — LeaderTransfer message was not classified as a request message, causing it to carry an incorrect term value when redirected from follower to leader.
- Historical: commit `9772554` — data race when requesting leadership transfer: `RequestLeaderTransfer` directly called `p.raft.Handle()` from the NodeHost goroutine while the step worker accessed the raft state. Fixed by using a channel.
- Code analysis: raft.go:1910-1923 — `handleLeaderHeartbeatResp` does not check leadership transfer completion (unlike `handleLeaderReplicateResp` at line 1892).

**Priority**: Low
**Rationale**: All three historical bugs are fixed. The HeartbeatResp path inconsistency is minor because the replicate response path is the primary trigger for transfer completion, and the heartbeat handler at line 1914-1915 sends a replicate message when the target is behind, which will eventually produce a ReplicateResp.

---

### Family 5: Observer/Witness Role Transitions (LOW)

**Mechanism**: The six-state node model (follower, candidate, preVoteCandidate, leader, nonVoting, witness) has edge cases in state transitions and handler coverage.

**Evidence**:
- Historical: commit `ac6a472` (#94) — `restoreRemotes` incorrectly promoted any observer to follower. Fixed to only self-promote.
- Code analysis: raft.go:2396-2417 — NonVoting and Witness handler maps have intentional gaps (no Election, no RequestVoteResp for nonVoting; no Propose, ReadIndex, LogQuery for witness). These are asserted in `checkHandlerMap()` at raft.go:2419-2465.
- Code analysis: raft.go:963 — `toFollowerState` panics if transitioning from witness to follower. This is a hard boundary.
- Code analysis: peer.go:184-195 — messages from unknown nodes are silently dropped (no remote found in any of the three maps).

**Priority**: Low
**Rationale**: The role transition logic is well-guarded with explicit panics and handler map assertions. The one historical bug (ac6a472) is fixed. Not suitable for high-priority TLA+ modeling — the role system adds state space without targeting a dense bug area.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Separate Heartbeat and Replicate paths | Family 1: different response handlers with different `setActive` behavior | Split AppendEntries into Replicate (with entries, checks commit) and Heartbeat (lightweight, no commit) actions |
| CheckQuorum with `active` tracking | Family 1: `setActive` omission + side-effecting `leaderHasQuorum` | `active` variable, `CheckQuorum` action that clears flags. Snapshot status does NOT set active |
| Remote state machine (Retry/Wait/Replicate/Snapshot) | Family 1: snapshot state is the trigger for the quorum bug | `remoteState` variable with transitions matching remote.go |
| Config change single-at-a-time | Family 2: multiple historical bugs, acknowledged TODO | `pendingConfigChange` flag, election blocked when pending |
| Persistence error injection | Family 3: PR #409 silently drops writes | `diskError` variable, non-deterministic persistence failure that returns success |
| Crash and recovery | Family 3: validates persistence correctness | `Crash` action recovers from persisted state only |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| PreVote protocol | No high-priority bug family. Leadership transfer PreVote interaction (Family 4) is already fixed. Adds state space without targeting known issues. |
| NonVoting/Witness roles | Family 5: well-guarded with explicit panics. Adds 4 extra states without targeting dense bug areas. |
| FastApply optimization | Implementation-level optimization in engine.go, not protocol logic. Safety already validated by code analysis. |
| Network transport / chunking | Infrastructure-level, not consensus protocol logic. |
| ReadIndex protocol | Separate from core consensus safety. The "we don't know" comment (readindex.go:101) suggests defensiveness but no confirmed bug. |
| Replicate-before-persist optimization | Already proven safe per Raft thesis 10.2.1. Not model-checkable without modeling message ordering at the transport level. |
| Term/Vote atomicity | Dragonboat persists {term, vote, commit} as a single atomic protobuf blob in one Pebble batch (db.go:307-320). No hashicorp/raft-style split vulnerability exists. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Heartbeat/Replicate split | (split in actions, no new vars) | Distinguish response handlers and their setActive behavior | Family 1 |
| Active tracking | `active [Server -> Server -> BOOLEAN]` | Track follower activity for CheckQuorum | Family 1 |
| Remote state | `remoteState [Server -> Server -> RemoteStateType]` | Model snapshot state where setActive is missing | Family 1 |
| Config change flag | `pendingConfigChange [Server -> BOOLEAN]` | Single-at-a-time enforcement | Family 2 |
| Disk error injection | `diskError [Server -> BOOLEAN]` | Model silent persistence failure (PR #409) | Family 3 |
| Crash recovery | (action, no new vars beyond persistent state) | Recover from persisted-only state | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard |
| QuorumActivityImpliesLeader | Safety | If CheckQuorum passes, a real quorum of nodes has communicated with the leader within the election timeout | Family 1 |
| SnapshotActiveTracking | Safety | A node actively sending snapshot status to the leader is counted in the leader's quorum check | Family 1 |
| ConfigChangeSingleAtATime | Safety | At most one uncommitted config change entry exists at any time | Family 2 |
| PersistBeforeAck | Safety | If a client receives acknowledgment of a committed entry, that entry is durably persisted on a quorum of nodes | Family 3 |
| CrashRecoveryConsistency | Safety | After crash+recovery, persisted state is consistent (term >= vote's term, log prefix is valid) | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | SnapshotStatus does not set active → leader steps down with active quorum | QuorumActivityImpliesLeader | 1 |
| MC-2 | `leaderHasQuorum()` side effect → double-check always fails | QuorumActivityImpliesLeader | 1 |
| MC-3 | Overly conservative `hasConfigChangeToApply` blocks elections when only regular entries are unapplied | Liveness (election delay) | 2 |
| MC-4 | Silent persistence failure (PR #409) → committed entry lost on crash | PersistBeforeAck, LeaderCompleteness | 3 |
| MC-5 | Config change silently dropped → client believes config changed when it didn't | ConfigChangeSingleAtATime | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | PR #409: `return nil` instead of `return err` in saveRaftState/saveSnapshots | Unit test: mock saveSnapshot to fail, verify error propagates |
| TV-2 | `remoteState` guard in SnapshotStatus handler drops late-arriving messages | Integration test: send SnapshotStatus after remote transitions out of snapshot state |
| TV-3 | ReadIndex duplicate context suppression (readindex.go:44) | Unit test: submit two read requests with same SystemCtx |
| TV-4 | `FastApply` overlap detection incomplete (peer.go:220) — only checks last committed entry | Unit test: construct Update where first (not last) committed entry overlaps with save range |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `commitTo` dead code at logentry.go:344 (`index < l.committed` unreachable) | Remove dead check |
| CR-2 | `leaderHasQuorum()` side-effecting boolean (raft.go:395-405) | Refactor: separate check from clear |
| CR-3 | `canGrantVote` redundant condition (raft.go:1625): `m.Term > r.term` always implies `r.vote == NoNode` | Simplify or document |
| CR-4 | Missing `mustBeLeader()` in `handleLeaderSnapshotStatus` and `handleLeaderUnreachable` | Add assertions for consistency |
| CR-5 | #374: `NewNodeHost` panic recovery misses string panics | Add default case to type switch |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/dragonboat/analysis-report.md`
- **Key source files**:
  - `artifact/dragonboat/internal/raft/raft.go` (2,465 lines — core state machine)
  - `artifact/dragonboat/internal/raft/logentry.go` (420 lines — log management)
  - `artifact/dragonboat/internal/raft/remote.go` (225 lines — follower tracking)
  - `artifact/dragonboat/internal/raft/peer.go` (449 lines — public Raft interface)
  - `artifact/dragonboat/internal/logdb/db.go` (514 lines — persistence)
  - `artifact/dragonboat/engine.go` (1,474 lines — worker pipeline)
  - `artifact/dragonboat/node.go` (1,708 lines — single group replica)
- **GitHub issues**: #94 (Family 2), #75 (Family 2), #156/#369 (Family 3), #409 (Family 3), #223 (Family 4)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014)
