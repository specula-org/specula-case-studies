# Analysis Report: etcd-io/raft

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Bug-fix commits analyzed | 45 |
| GitHub issues deeply read (etcd-io/raft) | 22 |
| GitHub issues/PRs deeply read (etcd-io/etcd) | 12 |
| Core source files fully read | 14 |
| Total core LOC analyzed | ~5,500 |
| Bug families identified | 6 |
| Findings pending verification | 18 (8 model-checkable, 4 test-verifiable, 6 code-review-only) |

---

## Phase 1: Reconnaissance

### Codebase Structure

| Component | Files | Lines | Purpose |
|-----------|-------|-------|---------|
| State Machine | raft.go | 2158 | Core Raft logic, state transitions, RPC handlers |
| Node Interface | node.go | 610 | Channel-based public API, run loop |
| Raw Interface | rawnode.go | 562 | Synchronous API, async storage protocol |
| Log Management | log.go, log_unstable.go | 819 | Replicated log, commit tracking, unstable entries |
| Storage | storage.go | 313 | Storage interface, MemoryStorage reference impl |
| Configuration | confchange/ | 574 | Joint consensus membership changes |
| Tracker | tracker/ | 780 | Per-peer replication progress state machine |
| Quorum | quorum/ | 357 | Voting, quorum checks, joint config |
| Read-Only | read_only.go | 121 | ReadIndex linearizable read tracking |

### Concurrency Model

- **Single-threaded event loop**: `node.run()` (node.go:343) drives all raft state mutations via channel select
- **No internal locks**: raft struct has no mutexes; all mutations happen on the run goroutine
- **Application-driven**: ticks, message delivery, and persistence are controlled by the application
- **Channel boundaries**: `propc` (proposals), `recvc` (RPC messages), `tickc` (timer, buffered 128), `readyc`/`advancec` (Ready protocol)
- **MemoryStorage** has its own mutex for concurrent access (storage.go:99-101)

### Key Types

- `raft` struct (raft.go:341): main state machine with `Term`, `Vote`, `state`, `raftLog`, `trk`, `msgs`, `msgsAfterAppend`, `lead`
- `StateType`: Follower(0), Candidate(1), Leader(2), PreCandidate(3) (raft.go:48-54)
- `stepFunc`: function pointer set per state — `stepFollower`, `stepCandidate`, `stepLeader` (raft.go:1265)
- `raftLog` (log.go:23): `storage` + `unstable` + `committed`/`applying`/`applied` indices
- `Progress` (tracker/progress.go:30): per-peer `Match`, `Next`, `State` (Probe/Replicate/Snapshot)
- `JointConfig` (quorum/joint.go): two `MajorityConfig` for joint consensus

---

## Phase 2: Bug Archaeology

### Bug-Fix Commit Analysis (45 commits)

#### CRITICAL Safety Violations (9)

| # | Commit | Summary | Root Cause | Component |
|---|--------|---------|------------|-----------|
| 1 | `8ecce32` | CommittedEntries pagination skipped entries | HardState.Commit truncated to match paginated delivery | node.go |
| 2 | `76f1249` | Panic on MsgApp after log truncation | `term()` returned 0 for compacted entries | raft.go, log.go |
| 3 | `6618455` | Stale-term messages processed | Missing `return` after `m.Term < r.Term` case | raft.go |
| 4 | `b2431fa` | maybeAppend overwrote committed entries | Missing `findConflict` logic | log.go |
| 5 | `e51bb3c` | pendingConf not reset on state transitions | becomeFollower/becomeLeader missed reset | raft.go |
| 6 | `846008d` | MsgProp term overwritten by send() | No special case for MsgProp in send | raft.go |
| 7 | `98379fc` | Term reset to 0 on restart | `becomeFollower(0, None)` after loading hard state | raft.go |
| 8 | `f9382a4` | Stale reads before leader commits in term | Missing current-term commit check for ReadIndex | raft.go |
| 9 | `7c8872a` | Empty-peer node self-elected as leader | No promotable check in tickElection | raft.go |

#### HIGH Severity (16)

| # | Commit | Summary | Root Cause | Component |
|---|--------|---------|------------|-----------|
| 10 | `a370b6f` | Unbounded log growth counter drift | proto.Size() before index/term assignment | raft.go |
| 11 | `bd3c759` | Repeated auto-leave joint config proposals | Missing guard on pendingConfIndex | raft.go |
| 12 | `e515a67` | Joint config lost on snapshot restore | Restore had no joint config concept | confchange/restore.go |
| 13 | `e419ba5` | Inflights byte counter leak | reset() didn't zero bytes | tracker/inflights.go |
| 14 | `0c22de0` | findConflictByTerm panic on compacted index | Assumed all indices had valid terms | log.go |
| 15 | `f8f7f47` | MemoryStorage.Compact data race | Missing lock in Compact | storage.go |
| 16 | `eed45a6` | MemoryStorage.Append didn't handle overlap | Missing truncation of old entries | storage.go |
| 17 | `255b5d1` | MemoryStorage.Append mixed old/new entries | No truncation before appending | storage.go |
| 18 | `4481b79` | sendAppend panic from concurrent compaction | term() returned 0 silently | log.go, raft.go |
| 19 | `2e0653d` | Async storage pagination broke tracking | Pagination designed for sync Ready/Advance | log.go, rawnode.go |
| 20 | `816fc51` | Removed node panicked on MsgTimeoutNow | Missing promotable() check | raft.go |
| 21 | `abb533c` | Learners blocked from voting after promotion | Overly restrictive guard | raft.go |
| 22 | `3c7359d` | PreVote migration deadlock | CheckQuorum not extended to PreVote | raft.go |
| 23 | `d4471b2` | PreVoteResp with term=0 | Local term used instead of request term | raft.go |
| 24 | `a3afec7` | New node triggers spurious leader step-down | RecentActive not set for new Progress | raft.go |
| 25 | `0675f3d` | MustSync computed from empty HardState | Used rd.HardState (empty when unchanged) | node.go |

#### MEDIUM Severity (17)

| # | Commit | Summary | Component |
|---|--------|---------|-----------|
| 26 | `f99897c` | prevHardSt initialized wrong on start | node.go |
| 27 | `38216cb` | Data race: n.propc vs local propc | node.go |
| 28 | `b470c6b` | Data race reading raft.lead from Tick | node.go |
| 29 | `6315e22` | Unbuffered tick channel causes livelock | node.go |
| 30 | `8746360` | Overflow in mustCheckOutOfBounds | log.go |
| 31 | `dd721e1` | Wrong function for unapplied entries | raft.go |
| 32 | `94e30e3` | MemoryStorage.Term panic on OOB | storage.go |
| 33 | `235a62a` | Out-of-bounds in maybeAppend | log.go |
| 34 | `656dcfa` | Panic: varint buffer too small | node.go |
| 35 | `06c21e9` | Campaign on already-leader panics | raft.go |
| 36 | `e769766` | Wrong invariant (committed < unstable) | log.go |
| 37 | `fdc052d` | promotable() called as function not field | node.go, raft.go |
| 38 | `49bac48` | Probe state recovery stalled on heartbeat | raft.go |
| 39 | `dfab82f` | Missing append retry after MsgAppResp | raft.go |
| 40 | `9392e5d` | ReadIndex response not delivered locally | raft.go |
| 41 | `8fc2d46` | Election elapsed reset in wrong states | raft.go |
| 42 | `f0ca9c6` | Messages from removed node cause panic | node.go |

#### LOW Severity (3)

| # | Commit | Summary | Component |
|---|--------|---------|-----------|
| 43 | `6439482` | Next index below Match after reordering | tracker/progress.go |
| 44 | `fdf77ae` | Panic removing all nodes | raft.go |
| 45 | `e769766` | Wrong log documentation invariant | log.go |

### Hotspot Analysis

| File | Bug-fix appearances |
|------|-------------------|
| raft.go | 66 |
| node.go | 29 |
| log.go | 26 |
| storage.go | 16 |
| rawnode.go | 10 |
| log_unstable.go | 8 |
| tracker/inflights.go | 2 |
| tracker/progress.go | 2 |
| confchange/restore.go | 2 |

### GitHub Issues (etcd-io/raft)

#### Confirmed Bugs

| Issue | Severity | Status | Summary |
|-------|----------|--------|---------|
| #392 | CRITICAL | Fixed (PR #397) | ReadIndex stale reads via duplicate RequestCtx |
| #148 | LOW | Fixed (PR #149) | Probe index regresses below Match |
| #108 | MEDIUM | Open | MemoryStorage.Snapshot panics on nil |
| #11 | MEDIUM | Open | uncommittedSize not enforced across term changes |
| #354 | MEDIUM | Open (PR #355) | ConfChange silently converted to no-op |
| #197 | MEDIUM | Open (PR #104) | Commit index regression panic on rejoin |

#### Design Defects

| Issue | Severity | Summary |
|-------|----------|---------|
| #166, #99 | HIGH | LeaseRead implementation acknowledged incorrect by maintainer |
| #80 | MEDIUM | Config change validation has false positives |
| #43 | LOW | ProposeConfChange doesn't use stepWait |
| #144 | MEDIUM | Term notion overloaded (design concern) |
| #157 | MEDIUM-HIGH | Stale snapshot commit possible via log_unstable invariant gap |
| #83 | LOW | StepDownOnRemoval not default |
| #138 | LOW | Lagging follower commit delayed by extra RTT |

#### Disputed / False Positives

| Issue | Reason for exclusion |
|-------|---------------------|
| #372 | Test bypassed joint quorum; invalid in production |
| #234 | Async storage split brain impossible due to campaign restrictions |
| #280 | Misunderstanding of Raft Figure 8; no-op already implemented |
| #349 | Node ID reuse is application responsibility |

### GitHub Issues (etcd-io/etcd, raft-related)

| Issue | Severity | Status | Summary |
|-------|----------|--------|---------|
| #20418 | CRITICAL | Fixed | Stale reads found by Antithesis (same as raft #392) |
| #14370 | HIGH | Fixed | Single-node durability violation |
| #16666 | HIGH | Fixed | wait-cluster-ready stale linearizable read |
| #11651 | CRITICAL | Fixed | Auth revision divergence causes data corruption |
| #12359 | HIGH | Open | Config change + voter removal liveness loss |
| #15247 | CRITICAL | Open | Stale leader revokes leases after disk stall |
| #18055 | MEDIUM | Open | Snapshot race panic (Antithesis) |
| #14143 | CRITICAL | Partial | Split brain after WAL repair (Jepsen) |

---

## Phase 3: Deep Analysis

### raft.go Analysis

#### Code Path Inconsistency Findings

1. **MsgTimeoutNow handling asymmetry**: stepCandidate ignores (line 1707), stepFollower acts (line 1753), stepLeader falls through silently. Leader should explicitly ignore.

2. **MsgReadIndexResp only handled by follower** (line 1766): Leader and candidate silently drop it. Benign (leaders generate, not receive) but no defensive logging.

3. **Follower sets `r.lead = m.From` unconditionally** (lines 1725-1736) for any MsgApp/MsgHeartbeat/MsgSnap in the same term. No validation that `m.From` matches known leader. Safe under correct behavior but no defensive check.

#### State Transition Findings

4. **`becomePreCandidate` does NOT call `reset()`** (line 917-931): Intentional design — preserves term and vote. But `electionElapsed` is NOT reset and `randomizedElectionTimeout` is NOT re-randomized, meaning a pre-candidate inherits the timer from its previous state.

5. **Missing `StatePreCandidate` guard in `becomeLeader`** (line 935): Only `StateFollower` is prevented. In practice, `stepCandidate` handles this correctly at line 1696-1701, but the defense-in-depth guard is incomplete.

#### Missing Guard Findings

6. **`handleHeartbeat` commits without local validation** (line 1830-1833): `commitTo(m.Commit)` panics if `tocommit > lastIndex()`. Relies entirely on leader computing correct commit value. Fragile coupling.

7. **`campaign()` proceeds despite unpromotable warning** (line 1029): Warning fires but no early return. If callers fail to check `promotable()`, an unpromotable node sends vote requests.

8. **MsgTimeoutNow sent without re-checking learner status** (line 1565): If a conf change demoted the transferee between MsgTransferLeader and MsgAppResp, MsgTimeoutNow is still sent. Benign (learner campaign fails) but guard is missing.

#### Non-Atomic Operation Findings

9. **Leader self-ack via msgsAfterAppend** (line 845): Leader's Match is stale until entries are persisted. `maybeCommit` during this window doesn't count the leader's vote. Conservative and safe.

10. **MsgCheckQuorum reset after check** (lines 1273-1284): `RecentActive` reset at line 1280 could clear a peer's activity set between check (line 1274) and reset. Benign since check already passed.

#### Reference Deviation Findings

11. **Vote granting: extra `r.lead == None` check** (line 1208): Raft paper Figure 2 says grant if "votedFor is null or candidateId". etcd-raft adds requirement that no leader is known. Prevents unnecessary elections but deviates from paper.

12. **Heartbeat carries commit index** (line 700): Not in Raft paper. Optimization that relies on leader computing `min(pr.Match, r.raftLog.committed)` correctly.

13. **MsgTimeoutNow bypasses PreVote** (line 1758): Leadership transfer goes directly to `campaignElection`, not `campaignPreElection`. Deliberate per comment at line 1755-1757.

#### Developer Signal Findings

14. **6 panic-on-error sites** (lines 444, 475, 676, 1307, 1313, 1963): All tagged with TODO(bdarnell) or TODO(tbg). Storage and config errors crash instead of being returned.

15. **`raft.go:1787-1788` TODO**: "construct logSlice up the stack... validate it before taking any action." Currently, term bump (line 1119-1122) happens BEFORE message content validation.

16. **Non-follower restore increments term** (line 1870): `becomeFollower(r.Term+1, None)` with undocumented +1.

### log.go + log_unstable.go + storage.go Analysis

17. **`acceptApplying` does not enforce `applying` monotonicity** (log.go:345-349): Only checks `committed < i`, not `applying <= i`. Direct assignment `applying = i` could regress if called with stale value.

18. **TOCTOU in `slice`** (log.go:498-516): `mustCheckOutOfBounds` reads storage state, then `Entries()` is called separately. Concurrent `Compact` between them could cause `ErrUnavailable` panic.

19. **`MemoryStorage.Append` lacks entry continuity validation** (storage.go:278-280): TODO comment acknowledges entries not checked for continuity. Gaps panic (line 308-310) but overlapping/duplicate entries silently accepted.

20. **`MemoryStorage.Compact` has no protection against compacting committed-but-unapplied entries** (storage.go:253): Application responsibility, no enforcement.

21. **`MemoryStorage.InitialState` does not take the lock** (storage.go:121-124): Safe only because called once during initialization before concurrent access.

22. **ABA defense in `stableTo`** (log_unstable.go:134-160): Term-matching guard + offset check prevents stale stability notifications from corrupting unstable log. Well-documented and correct.

### confchange/ + tracker/ + quorum/ Analysis

23. **`Config.Clone()` drops `AutoLeave`** (tracker.go:96-112): New Config constructed without `AutoLeave` field. Overwritten by callers (EnterJoint/LeaveJoint) but semantically incomplete.

24. **No guard on Progress state transitions** (progress.go:121-158): Any state can transition to any other. Safety depends entirely on correct calling code.

25. **`BecomeReplicate` does not reset `sentCommit`** (progress.go:146-149): Stale high value could suppress eager commit index sends. Performance issue, not safety.

26. **`BecomeSnapshot` does not validate `snapshoti >= Match`** (progress.go:153-158): Could silently violate `Match < Next` invariant.

27. **`TallyVotes` iterates Progress, not Voters** (tracker.go:265-278): May include outgoing-only voters in informational granted/rejected counts. Authoritative `VoteResult` uses Voters config correctly.

28. **Empty `MajorityConfig` returns `VoteWon`** (quorum/majority.go:170-175): Intentional for joint quorum semantics. Empty half does not constrain result.

### node.go + rawnode.go + read_only.go Analysis

29. **Self-acknowledged bug at node.go:409-411**: "This isn't very sound and **likely has bugs**" regarding propc re-enabling after conf changes where a removed node's proposal channel may be incorrectly re-enabled.

30. **Rejected responses deferred despite being "likely safe"** (raft.go:578-589): Developer chose conservative approach. Comment: "the safety of such behavior has not been formally verified."

31. **ReadIndex dequeue batching** (read_only.go:81-111): `advance()` dequeues ALL requests up to acknowledged context. Earlier requests satisfied transitively — correct but subtle.

32. **Pending ReadIndex leak on leader step-down**: `reset()` (raft.go:812) reconstructs `readOnly` from scratch. Pending requests silently discarded. Client must retry.

33. **`addRequest` silently drops duplicate contexts** (read_only.go:58-59): Only first request with a given context is tracked. Root of Issue #392 (stale reads).

34. **Ready re-computation discards old Ready** (node.go:354-364): If Ready channel is not consumed, old Ready is discarded and rebuilt with more accumulated state. Safe but non-obvious.

---

## Phase 4: Bug Family Synthesis

See `modeling-brief.md` for the complete synthesis of findings into 6 Bug Families, modeling recommendations, proposed extensions, proposed invariants, and findings pending verification.

### Family Summary

| Family | Priority | Historical Bugs | New Findings | TLA+ Suitability |
|--------|----------|----------------|--------------|------------------|
| 1. Linearizable Read Safety | HIGH | 3 critical | 3 | Excellent |
| 2. Persistence Ordering / Async Storage | HIGH | 4 critical | 4 | Excellent |
| 3. Configuration Change Safety | HIGH | 5+ | 5 | Excellent |
| 4. Log Consistency Under Compaction | MEDIUM | 6 | 3 | Medium |
| 5. Term/Vote Handling | MEDIUM | 6 critical | 3 | Good |
| 6. Heartbeat Commit Propagation | LOW | 3 | 2 | Low |

### Cross-Implementation Comparison

etcd-raft differs significantly from hashicorp/raft:
- **No independent heartbeat goroutine**: etcd-raft's single-threaded model eliminates the heartbeat term-check omission family found in hashicorp/raft.
- **Library vs framework**: etcd-raft delegates persistence to the application. hashicorp/raft owns its own persistence, leading to the non-atomic persistVote family.
- **Joint consensus**: etcd-raft implements full joint consensus (ConfChangeV2). hashicorp/raft uses a different config change mechanism.
- **ReadIndex**: etcd-raft has sophisticated ReadIndex batching with known bugs. hashicorp/raft uses a different linearizable read approach.
- **Async storage**: etcd-raft's optional async writes introduce a unique class of ABA and ordering bugs not present in hashicorp/raft.

---

## Appendix: Developer TODO/FIXME Signals

| File | Line | Comment | Assessment |
|------|------|---------|------------|
| raft.go:208 | TODO | "feedback to application to limit proposal rate" | Design question |
| raft.go:444 | TODO(bdarnell) | `panic(err)` on InitialState error | Known debt |
| raft.go:676 | TODO(bdarnell) | `panic(err)` on snapshot fetch error | Known debt |
| raft.go:903,918,934 | TODO(xiangli) | "remove the panic when stable" | Stability indicator |
| raft.go:1006 | TODO(pavelkalinnikov) | Budget memory for conf scan | Resource concern |
| raft.go:1787-1788 | TODO(pav-kv) | Validate before taking action | **Missing validation** |
| raft.go:1962 | TODO(tbg) | Return error from applyConfChange | **Error handling gap** |
| raft.go:1995 | TODO(tbg) | Transfer to largest Match follower | Missing optimization |
| log.go:76,80,304,315,410 | TODO(bdarnell) | `panic(err)` on storage errors | Known debt (5 sites) |
| log.go:429 | TODO(xiangli) | "handle error?" in allEntries | Potential issue |
| log.go:518 | TODO(pavelkalinnikov) | `panic(err)` in slice | Known debt |
| storage.go:47 | TODO(tbg) | Split Storage interface | Architecture debt |
| storage.go:278 | TODO(xiangli) | No continuity check in Append | **Missing validation** |
| node.go:383 | TODO | Buffer config proposals | Design suggestion |
| node.go:409-411 | NB | "**likely has bugs**" in propc handling | **Self-acknowledged bug** |
| rawnode.go:587-588 | NB | "not formally verified" (rejected responses) | **Formal verification needed** |
| bootstrap.go:48 | TODO(tbg) | Remove StartNode | API cleanup |
