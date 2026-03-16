# Modeling Brief: etcd-io/raft

## 1. System Overview

- **System**: etcd-io/raft — Go Raft consensus library powering etcd, CockroachDB, TiKV
- **Language**: Go, ~5500 LOC core logic (raft.go 2158, log.go 574, node.go 610, rawnode.go 562, tracker/ 780, confchange/ 574, quorum/ 357)
- **Protocol**: Raft (Ongaro 2014), with extensions: PreVote, CheckQuorum, LeaseRead, Joint Consensus (ConfChangeV2), Async Storage Writes, Leadership Transfer
- **Key architectural choices**:
  - **Single-threaded state machine**: all raft state mutations happen in one goroutine (node.go `run()` loop). No internal concurrency — the application drives ticks and message delivery.
  - **Library model**: etcd-raft is a library, not a framework. The application is responsible for persistence, networking, and message ordering. The `Ready` struct batches outbound state.
  - **msgs vs msgsAfterAppend**: messages are split into "send immediately" (`msgs`) and "send only after persistence" (`msgsAfterAppend` — vote responses, append acks). Safety of rejected responses being deferred is explicitly noted as "not formally verified" (raft.go:587).
  - **Async storage writes**: optional mode where persistence is offloaded to a separate thread. Uses term-checking to defend against ABA in concurrent appends (rawnode.go:282-356).
  - **Joint consensus**: two-phase config changes via `EnterJoint`/`LeaveJoint` with quorum from both old and new configs.
  - **ReadIndex batching**: `readOnly` queue batches multiple ReadIndex requests; heartbeat quorum for a later request satisfies all earlier ones (`read_only.go:advance()`).
- **Concurrency model**: Application-driven single-threaded event loop. No internal goroutines (except `node.run()`). All concurrency is external.

## 2. Bug Families

### Family 1: Linearizable Read Safety (HIGH)

**Mechanism**: ReadIndex queue batching allows stale commit indices to be returned when duplicate/retried request contexts cause delayed heartbeat responses to validate requests they shouldn't.

**Evidence**:
- Historical: Issue #392 (CRITICAL) — ReadIndex stale reads via duplicate `RequestCtx`. Found by Antithesis simulation testing (etcd #20418). Fixed in PR #397 by replacing user-provided contexts with monotonic internal indices.
- Historical: Commit `f9382a4` — leader serving reads before committing entry in current term (linearizability violation).
- Historical: Issue #166, #99 — LeaseRead implementation acknowledged by maintainer @pav-kv as "did not appear correct/usable." No known production users.
- Code analysis: `read_only.go:81-111` — `advance()` dequeues ALL requests up to matched context, relying on leader validity being transitive for earlier requests.
- Code analysis: `raft.go:1357-1359` — `pendingReadIndexMessages` defers reads until leader commits in current term; correctness depends on this guard.

**Affected code paths**:
- `readOnly.addRequest()`, `readOnly.recvAck()`, `readOnly.advance()` (read_only.go)
- `stepLeader` MsgReadIndex handling (raft.go:1346-1364)
- `releasePendingReadIndexMessages()` (raft.go:2124-2141)

**Suggested modeling approach**:
- Variables: `readIndexQueue` (ordered queue of (ctx, commitIdx) pairs), `readIndexAcks` (per-request ack sets)
- Actions: `RequestReadIndex` (leader records commit idx, broadcasts heartbeat), `AckReadIndex` (follower responds), `AdvanceReadIndex` (leader dequeues when quorum reached), `RetryReadIndex` (client retries with same/new ctx)
- Model both `ReadOnlySafe` (heartbeat quorum) and `ReadOnlyLeaseBased` (immediate response)
- Key invariant: returned read index must be >= actual commit index at the time of the read

**Priority**: High
**Rationale**: CRITICAL production bug found by Antithesis. Fix is recent (March 2026). LeaseRead remains acknowledged-broken. ReadIndex is the primary linearizable read mechanism for etcd.

---

### Family 2: Persistence Ordering / Async Storage Safety (HIGH)

**Mechanism**: Multi-phase persistence creates windows where vote responses or append acks are sent before the state they reference is durable, or where concurrent appends at different terms create ABA hazards.

**Evidence**:
- Historical: Commit `8ecce32` (CRITICAL) — CommittedEntries pagination truncated HardState.Commit, permanently skipping entries.
- Historical: Commit `2e0653d` — async storage pagination broke committed entry tracking.
- Historical: Commit `0675f3d` — MustSync computed from empty HardState instead of current.
- Historical: etcd #14370 — single-node durability violation (client ack before WAL sync).
- Code analysis: `raft.go:544-590` — msgs/msgsAfterAppend split. Comment at line 587: "the safety of such behavior has not been formally verified" (regarding rejected responses).
- Code analysis: `rawnode.go:282-356` — detailed ABA problem documentation. Defense: term-checking in MsgStorageAppendResp.
- Code analysis: Issue #157 — `log_unstable.go` invariant gap where `truncateAndAppend` with `fromIndex < offset` doesn't erase snapshot, potentially allowing stale snapshot commit.

**Affected code paths**:
- `send()` classification logic (raft.go:512-598)
- `newStorageAppendMsg()` / `newStorageAppendRespMsg()` (rawnode.go:225-366)
- `MsgStorageAppendResp` handler (raft.go:1189-1195)
- `stableTo()` (log_unstable.go:134-160)

**Suggested modeling approach**:
- Variables: `persistedEntries`, `persistedHardState`, `inFlightAppends` (set of (term, lastIndex) pairs)
- Actions: Split `HandleRequestVote` response into two steps: (1) persist vote, (2) send response. Split `HandleAppendEntries` response similarly. Add `PersistComplete` action that processes MsgStorageAppendResp.
- Model `Crash` recovering from persisted state only.
- Key: model multiple in-flight appends at different terms to test ABA defense.

**Priority**: High
**Rationale**: Multiple critical bugs. The msgsAfterAppend mechanism is explicitly noted as not formally verified. The ABA defense is the most subtle correctness mechanism in the codebase.

---

### Family 3: Configuration Change Safety (HIGH)

**Mechanism**: Joint consensus interactions with elections, quorum calculations, and state transitions. Silent rejection of config changes creates API correctness gaps.

**Evidence**:
- Historical: Commit `e51bb3c` (CRITICAL) — `pendingConf` not reset on `becomeFollower`/`becomeLeader`. New leader could accept multiple concurrent config changes.
- Historical: Commit `bd3c759` — auto-leave joint config sent repeated proposals.
- Historical: Commit `e515a67` — restoring joint config dropped outgoing voter set.
- Historical: Commit `abb533c` — learners blocked from voting after promotion.
- Historical: etcd #12359 (HIGH) — removing voter + killing it causes liveness loss. Proposed fix: pass commit index in vote requests.
- Code analysis: Issue #354 — ConfChange silently converted to no-op without error.
- Code analysis: Issue #80 — config change validation has false positives.
- Code analysis: `node.go:409-411` — developer comment: "This isn't very sound and **likely has bugs**" regarding `propc` re-enabling after conf changes.
- Code analysis: `confchange.go:255-263` — `initProgress` optimistically sets `Next=LastIndex` (acknowledged TODO).
- Code analysis: `tracker.go:96-112` — `Config.Clone()` drops `AutoLeave` field.

**Affected code paths**:
- `EnterJoint()` / `LeaveJoint()` / `Simple()` (confchange/confchange.go)
- `applyConfChange()` (raft.go:1948-1978)
- `JointConfig.VoteResult()` / `JointConfig.CommittedIndex()` (quorum/joint.go)
- `stepLeader` MsgProp handler, EntryConfChange path (raft.go:1301-1340)

**Suggested modeling approach**:
- Variables: `config [Server -> Configuration]` with incoming/outgoing voter sets, `pendingConfIndex`
- Actions: `ProposeConfChange`, `ApplyConfChange` (EnterJoint), `AutoLeaveJoint`, `ApplyLeaveJoint`
- Model election during joint config: candidate must win majority in BOTH old and new voter sets
- Model config change + leader step-down interaction

**Priority**: High
**Rationale**: 5+ historical bugs, self-acknowledged likely-buggy code (node.go:409-411). Joint consensus + election interaction is a rich state space for model checking.

---

### Family 4: Log Consistency Under Compaction (MEDIUM)

**Mechanism**: Log operations (term lookup, append, truncation) interact unsafely with storage compaction. `raftLog.term()` historically returned 0 for compacted entries instead of errors, causing cascading failures.

**Evidence**:
- Historical: Commit `76f1249` (CRITICAL) — MsgApp with LogTerm=0 after compaction caused follower panic.
- Historical: Commit `4481b79` — sendAppend panic from concurrent compaction; `term()` changed to return error.
- Historical: Commit `0c22de0` — `findConflictByTerm` panic on compacted index.
- Historical: Commit `b2431fa` (CRITICAL) — missing `findConflict` in `maybeAppend`.
- Historical: Commit `94e30e3` — MemoryStorage.Term panic on out-of-bounds.
- Code analysis: `log.go:498-516` — TOCTOU between `mustCheckOutOfBounds` and `storage.Entries()`. `ErrCompacted` handled gracefully; `ErrUnavailable` panics.
- Code analysis: `storage.go:278-280` — TODO: no entry continuity validation in `MemoryStorage.Append`.

**Affected code paths**:
- `maybeSendAppend()` / `sendAppend()` (raft.go:603-691)
- `handleAppendEntries()` (raft.go:1786-1828)
- `raftLog.term()`, `raftLog.slice()` (log.go)
- `MemoryStorage.Compact()`, `MemoryStorage.Append()` (storage.go)

**Suggested modeling approach**:
- Variables: `compactedThrough` (index below which entries are unavailable)
- Actions: `CompactLog` (advance compaction point), model `sendAppend` attempting to read compacted entries
- This family is best modeled as a background fault: compaction can race with any log read
- Lower priority for TLA+ since most bugs were panics (availability) not safety violations

**Priority**: Medium
**Rationale**: High historical bug density but most were panics, not protocol safety violations. The root cause (term() returning 0) has been fixed. Remaining TOCTOU risk is mitigated by single-threaded raft goroutine.

---

### Family 5: Term/Vote Handling and Election Safety (MEDIUM)

**Mechanism**: Incorrect term comparisons, vote persistence, and election timer management create windows for double-voting, stale-term message processing, or spurious elections.

**Evidence**:
- Historical: Commit `6618455` (CRITICAL) — missing `return` after `m.Term < r.Term`, processing stale messages.
- Historical: Commit `98379fc` (CRITICAL) — `becomeFollower(0, None)` on restart reset persisted term to 0.
- Historical: Commit `846008d` (CRITICAL) — `send()` overwrote MsgProp term with current term.
- Historical: Commit `7c8872a` (CRITICAL) — empty-peer node self-elected, causing split brain.
- Historical: Commit `d4471b2` — PreVoteResp with term=0 caused election deadlock.
- Historical: Commit `3c7359d` — PreVote migration deadlock with partitioned higher-term node.
- Code analysis: Issue #144 — Term notion overloaded (design concern by maintainer).
- Code analysis: `raft.go:1208` — extra `r.lead == None` check in vote granting not in Raft paper Figure 2.
- Code analysis: Issue #11 — `uncommittedSize` reset to 0 on `becomeLeader`, losing track across term changes.

**Affected code paths**:
- `Step()` term handling (raft.go:1085-1170)
- `becomeFollower` / `becomeCandidate` / `becomeLeader` (raft.go:891-970)
- Vote granting logic (raft.go:1204-1254)
- `campaign()` (raft.go:1025-1071)

**Suggested modeling approach**:
- Standard Raft spec covers most of this. Extensions needed:
  - PreVote: pre-candidates don't increment term, don't call `reset()`
  - CheckQuorum: leader step-down on insufficient active peers
  - The `r.lead == None` guard on voting (deviation from paper)

**Priority**: Medium
**Rationale**: Most critical bugs in this family are already fixed. The remaining risks (PreVote interaction, term overloading) are important for completeness but less likely to yield new bugs than Families 1-3.

---

### Family 6: Heartbeat Commit Index Propagation (LOW)

**Mechanism**: Heartbeats carry commit index bounded by leader's knowledge of follower's Match, with no local validation at the follower that it has entries up to that index.

**Evidence**:
- Historical: Commit `31ef059` — heartbeat used wrong index calculation.
- Historical: Commit `49bac48` — probe state recovery stalled on heartbeat response.
- Code analysis: `raft.go:1830-1833` — `handleHeartbeat` calls `commitTo(m.Commit)` without validating follower has entries up to that index. Relies entirely on leader's correctness.
- Code analysis: Issue #197 — commit index regression panic when follower loses state and rejoins.
- Code analysis: Issue #138 — commit index bounded by Match delays follower commits by 1 RTT.

**Affected code paths**:
- `sendHeartbeat()` (raft.go:693-707)
- `handleHeartbeat()` (raft.go:1830-1833)
- `commitTo()` (log.go:320-328, panics if tocommit > lastIndex)

**Suggested modeling approach**:
- Model heartbeat as carrying `commit = min(pr.Match, r.raftLog.committed)`
- Follower applies `commitTo(m.Commit)` directly — test if this can ever exceed lastIndex
- Low priority: mostly liveness/performance, covered by standard Raft invariants

**Priority**: Low
**Rationale**: Most historical bugs were availability issues (panics). The safety risk (follower committing beyond its log) requires the leader to have incorrect Match tracking, which would be a separate bug.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| ReadIndex with queue batching | Family 1: CRITICAL production bug found by Antithesis, fix is recent | Model `readOnly` queue with addRequest/recvAck/advance. Add RetryReadIndex with same/different ctx |
| LeaseRead (basic) | Family 1: acknowledged broken by maintainer, no formal analysis | Model lease as local tick-based validity check without heartbeat confirmation |
| Persist-before-send constraint | Family 2: explicitly "not formally verified" per developer comment | Split message send into msgs (immediate) and msgsAfterAppend (after persist). Model crash between persist and send |
| Async storage ABA | Family 2: most subtle correctness mechanism, meticulously documented | Model concurrent in-flight appends at different terms with term-checking defense |
| Joint consensus | Family 3: 5+ historical bugs, self-acknowledged "likely has bugs" | Model EnterJoint/LeaveJoint with dual quorum. Track incoming + outgoing voter sets |
| Config change + election | Family 3: rich interaction space | Allow election during joint config, verify both quorums needed |
| PreVote | Family 5: 3 historical bugs in PreVote interaction | Model pre-election phase without term increment, separate from real election |
| CheckQuorum | Family 5: interacts with leader lease and election safety | Model leader periodic quorum check with step-down on failure |
| Crash and recovery | Family 2, 5: validates persistence correctness | Crash action resets volatile state, recovers from HardState |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Log compaction races | Family 4: mostly panic bugs (availability), not safety. Root cause (term()=0) is fixed. Single-threaded model eliminates TOCTOU. |
| Pipeline replication / Inflights | Optimization layer. Inflights tracks in-flight message count/bytes. Not protocol logic. |
| Snapshot transfer | Important but orthogonal to the top bug families. Would significantly expand spec scope. |
| Leadership Transfer (MsgTimeoutNow) | Bypasses PreVote by design. The only finding (missing learner re-check) is benign. |
| Error handling panics | Family 4: code-level issues (TODO(bdarnell) panics). Not protocol logic. |
| MemoryStorage implementation | Reference/test implementation. Real deployments use WAL-based storage. |
| Channel semantics (node.go) | Go-specific concurrency. The library model means the application drives all operations. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| ReadIndex queue | `readIndexQueue`, `readIndexAcks`, `readIndexResults` | Model batched ReadIndex with quorum confirmation | Family 1 |
| Lease-based reads | `leaseValid [Server -> BOOLEAN]` | Model local lease validity without heartbeat quorum | Family 1 |
| Persist-before-send | `persistedHardState`, `inFlightPersist` | Distinguish msgs from msgsAfterAppend; gate responses on durability | Family 2 |
| Async appends | `inFlightAppends [Server -> Seq((term, lastIdx))]` | Model concurrent appends with term-checking ABA defense | Family 2 |
| Joint consensus | `voters [Server -> <<incoming, outgoing>>]`, `jointActive` | Dual quorum during config transitions | Family 3 |
| Config change tracking | `pendingConfIndex [Server -> Nat]` | Enforce single-config-change-at-a-time | Family 3 |
| PreVote | `preVoteGranted [Server -> SUBSET Server]` | Pre-election without term increment | Family 5 |
| CheckQuorum | `recentActive [Server -> [Server -> BOOLEAN]]` | Leader quorum health check with step-down | Family 5 |
| Crash/Recovery | `persistedTerm`, `persistedVote`, `persistedCommit` | Model crash recovering from persisted-only state | Family 2, 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard + Family 5 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard + Family 4 |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard |
| VoteSafety | Safety | A server votes for at most one candidate per term | Standard + Family 2, 5 |
| ReadIndexLinearizability | Safety | ReadIndex result >= actual commit index when read was requested | Family 1, Issue #392 |
| LeaseImpliesLeadership | Safety | If lease read succeeds, no other leader has committed entries the lease holder hasn't seen | Family 1, Issue #166 |
| PersistBeforeSend | Safety | Vote response / append ack is only sent after the state it references is durable | Family 2 |
| NoABACommit | Safety | An entry committed via stale-term append ack is also committed in the current term's log | Family 2 |
| JointQuorumSafety | Safety | During joint config, commit requires majority from both incoming and outgoing | Family 3 |
| SinglePendingConfig | Safety | At most one uncommitted config change entry at any time | Family 3 |
| PreVoteNoTermBump | Safety | PreVote messages do not cause term updates on receivers | Family 5 |
| CheckQuorumLiveness | Liveness | If a majority of servers are alive and connected, eventually a leader is elected | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | ReadIndex with duplicate RequestCtx allows stale reads (pre-fix behavior) | ReadIndexLinearizability | 1 |
| MC-2 | LeaseRead serves stale data during network partition | LeaseImpliesLeadership | 1 |
| MC-3 | Rejected vote/append response sent before persistence (raft.go:578-589 "not formally verified") | PersistBeforeSend, VoteSafety | 2 |
| MC-4 | ABA in async storage: two appends at same term sandwich different-term append | NoABACommit | 2 |
| MC-5 | Config change + election during joint consensus: removed node still in outgoing can affect quorum | JointQuorumSafety, ElectionSafety | 3 |
| MC-6 | Auto-leave joint config with concurrent election | SinglePendingConfig | 3 |
| MC-7 | PreVote interaction with CheckQuorum during rolling upgrade (commit 3c7359d scenario) | CheckQuorumLiveness | 5 |
| MC-8 | Leader lease check with stale `recentActive` after network partition | LeaseImpliesLeadership | 1, 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `acceptApplying` does not enforce `applying` monotonicity (log.go:345-349) | Unit test calling acceptApplying with decreasing indices |
| TV-2 | `MemoryStorage.Append` lacks entry continuity check (storage.go:278-280) | Unit test appending entries with gaps |
| TV-3 | Inflights byte counter leak across state transitions (commit e419ba5) | State transition test checking Inflights.bytes after reset |
| TV-4 | `uncommittedSize` not enforced across term changes (Issue #11) | Integration test with ping-ponging leadership |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `node.go:409-411` — developer-acknowledged "likely has bugs" in propc re-enabling | Trace all propc nil/non-nil transitions, verify no removed node can propose |
| CR-2 | `Config.Clone()` drops `AutoLeave` (tracker.go:96-112) | Add AutoLeave to Clone; file PR |
| CR-3 | `BecomeSnapshot` does not validate `snapshoti >= Match` (progress.go:153-158) | Add assertion; file PR |
| CR-4 | `raft.go:1029` — warning message text wrong ("should have been called" vs "should NOT") | Fix log message |
| CR-5 | `raft.go:1787-1788` — TODO: validate message content before taking actions like term bump | Review if higher-term malformed MsgApp causes state corruption |
| CR-6 | `sentCommit` not reset in `BecomeReplicate` (progress.go:146-149) | May cause delayed commit index propagation; review impact |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/etcd-raft/analysis-report.md`
- **Key source files** (relative to `artifact/raft/`):
  - `raft.go` — core state machine, 2158 lines (state transitions: 891-970, step handlers: 1267-1771, vote logic: 1204-1254)
  - `log.go` — log management, 574 lines (invariants: 39-46, commit: 320-328, append: 107-140)
  - `log_unstable.go` — unstable entry tracking, 246 lines (stableTo ABA defense: 134-160)
  - `rawnode.go` — async storage protocol, 562 lines (ABA documentation: 282-356, msgs split: 225-262)
  - `read_only.go` — ReadIndex queue, 121 lines (advance batching: 81-111)
  - `confchange/confchange.go` — joint consensus, 419 lines (EnterJoint: 51-78, LeaveJoint: 94-121)
  - `tracker/progress.go` — replication state machine, 314 lines (state transitions: 121-158)
  - `quorum/joint.go` — joint quorum, 75 lines (CommittedIndex: 49-56, VoteResult: 61-75)
- **GitHub issues**: #392 (ReadIndex stale read), #166/#99 (LeaseRead), #157 (unstable snapshot gap), #354 (silent ConfChange), #80 (config validation), #11 (uncommittedSize), #144 (term overloading)
- **etcd issues**: #20418 (Antithesis stale read), #14370 (single-node durability), #12359 (config change liveness), #15247 (stale leader lease revocation)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Ongaro thesis Section 3.8 (persist-before-send), Section 4.2.3 (PreVote), Section 9.3 (joint consensus)
- **Existing TLA+ specs**: `artifact/raft/tla/` directory contains an extended spec with trace validation harness
