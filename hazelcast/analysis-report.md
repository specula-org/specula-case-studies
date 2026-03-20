# Analysis Report: hazelcast/hazelcast — CP Subsystem (Raft)

## Executive Summary

Hazelcast's CP Subsystem implements the Raft consensus protocol in Java (~7800 LOC core logic). The implementation was open-source until April 2024, when it was moved to the enterprise repository (commit `f778999d3e`). This analysis covers the last open-source version (commit `f2fa6ae842`).

The analysis identified **5 bug families** from **17 git bug-fix commits**, **25+ deeply-read GitHub issues/PRs**, and systematic deep reading of all core files. The most critical findings relate to vote safety on leader demotion (Jepsen-validated) and membership change pre-application/revert logic.

---

## Phase 1: Reconnaissance — Structural Map

### Codebase Location

All core Raft code resides under:
```
hazelcast/src/main/java/com/hazelcast/cp/internal/raft/impl/
```

### Core Files (by LOC)

| File | LOC | Role |
|------|-----|------|
| `RaftNodeImpl.java` | 1498 | Central state machine, all Raft coordination |
| `state/RaftState.java` | 607 | Persistent/volatile state, role transitions |
| `log/RaftLog.java` | 388 | In-memory ringbuffer + persistence delegation |
| `handler/AppendRequestHandlerTask.java` | 268 | Follower AppendEntries handling |
| `RaftIntegration.java` | 256 | Integration interface (threading, network) |
| `RaftNode.java` | 227 | Public Raft node interface |
| `state/FollowerState.java` | 185 | Per-follower state on leader (matchIndex, nextIndex, backoff) |
| `state/QueryState.java` | 181 | Linearizable read tracking |
| `task/MembershipChangeTask.java` | 171 | Single-server membership change |
| `task/QueryTask.java` | 166 | Query execution (linearizable, leader-local, any-local) |
| Other files (50) | ~3854 | DTOs, handlers, tasks, persistence |
| **Total** | **~7800** | |

### Architecture

```
                    ┌─────────────────────────────────────┐
                    │       Single-Threaded Executor       │
                    │  (RaftIntegration.execute())         │
                    ├─────────────────────────────────────┤
                    │                                     │
  Incoming RPCs →   │  Handler Tasks                      │
                    │  ├─ AppendRequestHandlerTask         │
                    │  ├─ AppendSuccess/FailureResponseHandler │
                    │  ├─ VoteRequest/ResponseHandler      │
                    │  ├─ PreVoteRequest/ResponseHandler   │
                    │  ├─ InstallSnapshotHandler           │
                    │  └─ TriggerLeaderElectionHandler     │
                    │                                     │
  Timers →          │  Periodic Tasks                     │
                    │  ├─ HeartbeatTask (leader only)      │
                    │  ├─ LeaderFailureDetectionTask       │
                    │  └─ FlushTask (persistence)          │
                    │                                     │
  Client requests → │  Operational Tasks                  │
                    │  ├─ ReplicateTask                    │
                    │  ├─ QueryTask                        │
                    │  └─ MembershipChangeTask             │
                    │                                     │
                    │  State                               │
                    │  ├─ RaftState (term, vote, log, role)│
                    │  ├─ LeaderState (follower tracking)  │
                    │  ├─ CandidateState (vote counting)   │
                    │  └─ QueryState (read tracking)       │
                    └─────────────────────────────────────┘
```

### Concurrency Model

- **Primary mechanism**: Single-threaded executor per Raft group. All state mutations serialized.
- **Cross-thread visibility**: `status` (volatile) and `leader` (volatile) readable from other threads.
- **Persistence**: `persistTerm(term, votedFor)` is atomic (single call, durable on return). Log entries buffered until `flushLogs()`.
- **Leader flush optimization**: Leader can commit entries before flushing own disk (`flushedLogIndex` tracks durable progress).

### Key Deviations from Standard Raft

| Deviation | Description | Risk Level |
|-----------|-------------|------------|
| Heartbeat piggybacked on AppendEntries | Not a separate mechanism; same `sendAppendRequest` used | Low (simpler than hashicorp's independent heartbeat) |
| Leader commits before own disk flush | §10.2.1 optimization; uses `flushedLogIndex` in quorum calc | Low (correctly implemented) |
| Membership pre-application | New config takes effect on append, reverted on truncation | High (source of multiple bugs) |
| PreVote extension | §9.6 prevents term inflation by partitioned nodes | Medium (3 historical bugs) |
| InstallSnapshot sends full snapshot | No chunking; entire snapshot in one message | Low (simplicity) |
| Linearizable reads via heartbeat round | §6.4; query round tracks acks | Medium (complex interaction surface) |

---

## Phase 2: Bug Archaeology

### Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed | 17 |
| GitHub issues deeply read (full comments) | 25+ |
| GitHub PRs deeply read | 15 |
| Confirmed bugs | 17 |
| False positives excluded | 3 |
| Open unfixed issues found | 2 |

### Bug-Fix Commits (All Raft-core commits analyzed)

#### CRITICAL Severity

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 1 | PR #16643 / `48ffe4fb18` | Vote deleted on same-term leader demotion | `setTerm()` cleared `votedFor` even when `newTerm == term` | RaftState |
| 2 | PR #15591 | Leader doesn't self-demote (Jepsen) | No majority ack tracking; partitioned leader continues accepting writes | RaftNodeImpl, LeaderState |
| 3 | PR #14705 / `f45e41c606` | Incorrect membership revert causes node step-down | Node unilaterally decided to step down when member-add entry reverted | AppendRequestHandler |
| 4 | PR #22793 | Mutable snapshot corrupts membership | `MetadataRaftGroupSnapshot` was mutable, shared across nodes | Snapshot |

#### HIGH Severity

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 5 | `c3b558e425` | PreVote state leak blocks elections | Concurrent pre-vote + real election → leaked `preCandidateState` | RaftState, PreVoteTimeoutTask |
| 6 | `1f4bb0ed9c` | Leader stickiness uses wrong timeout | Randomized election timeout < heartbeat period → votes granted to disruptive nodes | RaftNodeImpl |
| 7 | `61c376d329` | Multiple membership changes on slow follower | Batch-applied committed membership changes violated one-at-a-time | AppendRequestHandler |
| 8 | `61c376d329` | PreVoteTask uses stale term | No term validation between scheduling and execution | PreVoteTask |
| 9 | `2f1dfe8b70` + `8e3ffce5c2` | Backoff reset by stale response | Out-of-order responses reset exponential backoff; fixed with flow control seq | FollowerState |
| 10 | PR #17632 | Stale missing members after split-brain merge | `missingMembers` map not cleared during merge | MetadataRaftGroupManager |
| 11 | PR #21665 | UUID confusion on node restart | Only IP used for identity; restarted node confused with original | Membership |

#### MEDIUM Severity

| # | Commit/PR | Summary | Root Cause | Component |
|---|-----------|---------|------------|-----------|
| 12 | `d36341c85f` | False leader failure during IP changes | Leader checked own reachability incorrectly | RaftNodeImpl |
| 13 | `9c3b0d5070` | Termination future never completed | Exception during `forceSetTerminatedStatus()` skipped future completion | RaftNodeImpl |
| 14 | `a680f71a22` | File closed after status set (Windows race) | Status set before `closeStateStore()` → concurrent file access | RaftNodeImpl |
| 15 | `532474629f` | NPE on termination before start | `forceSetTerminatedStatus()` before `start()` → null RaftState | RaftNodeImpl |
| 16 | `3a61f319d3` | Leader accepting ops after own removal | Leader didn't check if self was still in membership | RaftNodeImpl |
| 17 | `bf38a8c5e5` | Slow follower log overflow | AppendEntries batch exceeded follower log capacity | AppendRequestHandler |

### Bug Hotspot Analysis

| File | Bug Count | Severities |
|------|-----------|------------|
| `RaftNodeImpl.java` | 8 | 1 CRITICAL, 2 HIGH, 5 MEDIUM |
| `handler/AppendRequestHandlerTask.java` | 3 | 1 CRITICAL, 1 HIGH, 1 MEDIUM |
| `state/RaftState.java` | 2 | 1 CRITICAL, 1 HIGH |
| `task/PreVoteTask.java` | 2 | 2 HIGH |
| `state/FollowerState.java` | 1 | 1 HIGH |

### GitHub Issues — Key Findings

| Issue | State | Summary | Severity |
|-------|-------|---------|----------|
| #24897 | **OPEN** | CP instability on member restart; unrecoverable majority loss in K8s | CRITICAL |
| #21438 | CLOSED | Mutable snapshot corruption (3+ years of CI failures) | CRITICAL |
| #24958 | CLOSED | Exponential backoff defeated by stale responses | HIGH |
| #20917 | CLOSED | ConcurrentModificationException in RaftSessionService | HIGH |
| #25806 | CLOSED | Missing CP node replaced at same address not auto-removed | HIGH |
| #26254 | CLOSED | OOME from snapshot accumulation during rolling upgrade | HIGH |
| #22154 | CLOSED | Leader priority not respected in rebalancing | MEDIUM |
| #18372 | CLOSED | RaftEndpoint not in committed member list (query failures) | HIGH |

### False Positives Excluded

| Issue | Reason for Exclusion |
|-------|---------------------|
| #17498 | Design limitation (CP objects can't be recreated), not a bug |
| #22155 | Leader distribution skew — operational concern, not safety |
| #14478 | SessionExpiredException during split-brain — session layer, not Raft core |

---

## Phase 3: Deep Analysis

### Analysis Coverage

| Core File | Read Completely | Patterns Applied | Findings |
|-----------|----------------|-----------------|----------|
| `RaftNodeImpl.java` | Yes (1498 lines) | All 6 patterns | 10 findings |
| `handler/AppendRequestHandlerTask.java` | Yes (268 lines) | All 6 patterns | 8 findings |
| `handler/AppendSuccessResponseHandlerTask.java` | Yes (141 lines) | All 6 patterns | 3 findings |
| `handler/AppendFailureResponseHandlerTask.java` | Yes (114 lines) | All 6 patterns | 1 finding |
| `handler/VoteRequestHandlerTask.java` | Yes (123 lines) | All 6 patterns | 2 findings |
| `handler/VoteResponseHandlerTask.java` | Yes (91 lines) | All 6 patterns | 0 findings |
| `handler/PreVoteRequestHandlerTask.java` | Yes (85 lines) | All 6 patterns | 1 finding |
| `handler/PreVoteResponseHandlerTask.java` | Yes (81 lines) | All 6 patterns | 1 finding |
| `handler/InstallSnapshotHandlerTask.java` | Yes (93 lines) | All 6 patterns | 2 findings |
| `handler/TriggerLeaderElectionHandlerTask.java` | Yes (84 lines) | All 6 patterns | 0 findings |
| `state/RaftState.java` | Yes (607 lines) | All 6 patterns | 5 findings |
| `state/LeaderState.java` | Yes (123 lines) | All 6 patterns | 1 finding |
| `state/FollowerState.java` | Yes (185 lines) | All 6 patterns | 2 findings |
| `state/QueryState.java` | Yes (181 lines) | All 6 patterns | 1 finding |
| `state/CandidateState.java` | Yes | All 6 patterns | 0 findings |
| `state/RaftGroupMembers.java` | Yes (97 lines) | All 6 patterns | 0 findings |
| `task/MembershipChangeTask.java` | Yes (171 lines) | All 6 patterns | 1 finding |
| `task/QueryTask.java` | Yes (166 lines) | All 6 patterns | 3 findings |
| `task/ReplicateTask.java` | Yes (137 lines) | All 6 patterns | 1 finding |
| `task/LeaderElectionTask.java` | Yes | All 6 patterns | 0 findings |
| `task/PreVoteTask.java` | Yes | All 6 patterns | 0 findings |
| `task/PreVoteTimeoutTask.java` | Yes | All 6 patterns | 0 findings |
| `task/LeaderElectionTimeoutTask.java` | Yes | All 6 patterns | 1 finding |
| `task/LeadershipTransferTask.java` | Yes (108 lines) | All 6 patterns | 0 findings |
| `task/InitLeadershipTransferTask.java` | Yes | All 6 patterns | 0 findings |
| `log/RaftLog.java` | Yes (388 lines) | All 6 patterns | 2 findings |
| `log/LogEntry.java` | Yes | All 6 patterns | 0 findings |
| `log/SnapshotEntry.java` | Yes (102 lines) | All 6 patterns | 0 findings |
| `persistence/RaftStateStore.java` | Yes (153 lines) | All 6 patterns | 1 finding |
| `persistence/NopRaftStateStore.java` | Yes | All 6 patterns | 0 findings |
| `persistence/RaftStateLoader.java` | Yes | All 6 patterns | 0 findings |
| `persistence/RestoredRaftState.java` | Yes | All 6 patterns | 0 findings |
| **All 11 DTOs** | Yes | All 6 patterns | 1 finding |

### Code Path Inconsistency Analysis

#### Response Handler Term Check Comparison

| Handler | Term Check | Method | Demotion on Higher Term |
|---------|-----------|--------|------------------------|
| AppendSuccessResponse | `assert resp.term() <= state.term()` | **Assert only** | **NO (disabled in prod)** |
| AppendFailureResponse | `if (resp.term() > state.term())` | Runtime `if` | YES — `toFollower(resp.term())` |
| VoteResponse | `if (resp.term() > state.term())` | Runtime `if` | YES — `toFollower(resp.term())` |
| PreVoteResponse | Only checks `resp.term() < state.term()` | Runtime `if` (stale only) | NO (intentional for pre-vote) |

**Finding**: `AppendSuccessResponseHandlerTask` is the only response handler that uses `assert` instead of a runtime `if` for the term check. With assertions disabled (production default), a higher-term success response would not trigger leader demotion. While the protocol guarantees this shouldn't happen, it's a defense-in-depth gap.

#### Request Handler Membership Check

| Handler | Membership Check |
|---------|-----------------|
| AppendRequest | **NONE** |
| VoteRequest | **NONE** |
| PreVoteRequest | **NONE** |
| InstallSnapshot | **NONE** |
| TriggerLeaderElection | **NONE** |
| All Response Handlers | YES (via `AbstractResponseHandlerTask`) |

**Finding**: No request handler checks if the sender is a known member. Only response handlers do this via `AbstractResponseHandlerTask.isKnownMember()`. This asymmetry is by design (a removed node's leader must still be accepted during transitions) but could allow a removed node to disrupt the group by sending VoteRequests or InstallSnapshots.

### Developer Signals (TODO/FIXME)

| Location | Signal | Content | Severity |
|----------|--------|---------|----------|
| `QueryTask.java:96` | TODO | "We can reject the query, if leader is not able to reach majority of the followers" | Medium |
| `QueryTask.java:107` | TODO | "We can reject the query, if follower have not received any heartbeat recently" | Medium |
| `ReplicateTask.java:131-133` | TODO | Three optimization TODOs for commit advancement after group shrink | Low |
| `FollowerState.java:144` | TODO | "RU_COMPAT_5_3 ... Should be removed at Version 5.5" — backward compatibility shim | Low |
| `AppendRequest.java:150` | TODO | Same RU_COMPAT_5_3 compatibility shim | Low |
| `AppendSuccessResponse.java:105` | TODO | Same RU_COMPAT_5_3 compatibility shim | Low |
| `AppendFailureResponse.java:97` | TODO | Same RU_COMPAT_5_3 compatibility shim | Low |
| `InstallSnapshot.java:106` | TODO | Same RU_COMPAT_5_3 compatibility shim | Low |

### Message Fields vs. Raft Paper Figure 2

| RPC | Paper Fields | Hazelcast Fields | Extra Fields | Missing Fields |
|-----|-------------|-----------------|-------------|----------------|
| AppendEntries | term, leaderId, prevLogIndex, prevLogTerm, entries[], leaderCommit | All present | queryRound, flowControlSequenceNumber | None |
| AppendEntries Response | term, success | term, follower, lastLogIndex OR expectedNextIndex | queryRound, flowControlSequenceNumber | success (replaced by type split) |
| RequestVote | term, candidateId, lastLogIndex, lastLogTerm | All present | disruptive | None |
| RequestVote Response | term, voteGranted | All present | voter | None |
| InstallSnapshot | term, leaderId, lastIncludedIndex/Term, offset, data[], done | term, leader, snapshot (full) | queryRound, flowControlSequenceNumber | offset, done (no chunking) |

### Persistence Analysis

| State | Persistent | Atomic | Recovery |
|-------|-----------|--------|----------|
| `term` + `votedFor` | Yes | **Yes** (single `persistTerm(term, votedFor)` call) | Direct from store |
| Log entries | Yes (buffered until flush) | Per-entry | Replayed from store |
| Snapshot | Yes (buffered until flush) | Single entry | Loaded from store |
| `commitIndex` | **No** | N/A | Re-calculated from leader's AppendEntries |
| `lastApplied` | **No** | N/A | Re-calculated by replaying log from snapshot |
| Group members | **No** (reconstructed from log/snapshot) | N/A | Replayed from log entries containing `UpdateRaftGroupMembersCmd` |
| Leader / role | **No** | N/A | Always starts as FOLLOWER |

**Key finding**: `persistTerm(term, votedFor)` is atomic — no split-persist risk (unlike hashicorp/raft which has two separate disk writes). This eliminates an entire bug family.

### Verified Non-Issues

| Concern | Verification | Verdict |
|---------|-------------|---------|
| `commitIndex` moving backward | Assert at RaftState.java:349 prevents it | Safe |
| Quorum calculation for even group sizes | `(length-1)/2` formula verified for N=1..7 | Correct |
| Snapshot-log gap after InstallSnapshot | `setSnapshot` clears log, starts fresh from snapshot.index()+1 | Safe |
| FlushTask failure leaving stale flushedLogIndex | `flushedLogIndex` only updated after successful flush | Safe |
| Truncate-then-append crash window | Only uncommitted entries truncated; leader resends | Safe |
| Concurrent snapshot + sendAppendRequest | Single-threaded executor prevents interleaving | Safe |

---

## Phase 4: Bug Family Grouping

### Family 1: Vote Safety Violations on Leader Demotion

**Mechanism**: State transitions during leader demotion clear or corrupt vote invariants.

**Historical bugs**: 2 CRITICAL (PR #16643, PR #15591)
**New findings**: 1 (assert-only term check in AppendSuccessResponseHandlerTask)
**TLA+ suitability**: HIGH — election safety is the canonical TLA+ invariant

### Family 2: Membership Change Safety Gaps

**Mechanism**: Pre-application with rollback creates windows for inconsistent membership state.

**Historical bugs**: 3 HIGH (commits 61c376d329, 5c6d2e18bd/f45e41c606), 1 CRITICAL (PR #22793)
**New findings**: 1 (assert-based single-change guard, CAS-less API overload)
**TLA+ suitability**: HIGH — membership + election interleaving is a classic model checking target

### Family 3: Leader Self-Liveness / Stale Leader

**Mechanism**: Leader fails to detect partition, continues serving stale reads/writes.

**Historical bugs**: 1 CRITICAL (PR #15591 Jepsen), 1 HIGH (PR #16038)
**New findings**: 2 (LEADER_LOCAL TODO, ANY_LOCAL TODO)
**TLA+ suitability**: HIGH — partition + timeout modeling is TLA+ strength

### Family 4: PreVote Protocol State Management

**Mechanism**: PreVote extension adds `preCandidateState` that can leak or interact incorrectly.

**Historical bugs**: 3 HIGH (commits c3b558e425, 1f4bb0ed9c, 61c376d329)
**New findings**: 1 (disruptive flag lost on election timeout retry)
**TLA+ suitability**: MEDIUM — requires modeling pre-vote as additional phase

### Family 5: Linearizable Read Correctness

**Mechanism**: Heartbeat-round reads can interact with leader changes and membership changes.

**Historical bugs**: 0 direct (but Jepsen PR #15591 is related)
**New findings**: 3 (TODOs for LEADER_LOCAL/ANY_LOCAL, query + membership interaction)
**TLA+ suitability**: MEDIUM — requires modeling query state and round tracking

---

## Summary

The Hazelcast Raft implementation is well-structured with a clean single-threaded execution model that eliminates many concurrency bugs. The atomic `persistTerm(term, votedFor)` call eliminates the split-persist bug family found in hashicorp/raft. However, the membership change pre-application mechanism and the PreVote extension have been historically buggy. The assert-only term check in `AppendSuccessResponseHandlerTask` is a notable defense-in-depth gap. The most impactful open issue (#24897) is about operational resilience, not protocol safety.
