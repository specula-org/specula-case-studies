# Modeling Brief: RedisLabs/redisraft

## 1. System Overview

- **System**: RedisRaft — Redis module implementing distributed consensus via Raft, with clustering/sharding
- **Language**: C, ~15K LOC total; ~2400 LOC core protocol (deps/raft/src/raft_server.c), ~6200 LOC integration (raft.c + redisraft.c + snapshot.c)
- **Protocol**: Raft (Ongaro 2014) with PreVote extension, leader transfer, single-server membership changes
- **Key architectural choices**:
  - Core Raft logic in a **bundled C library** (deps/raft/), separate from RedisRaft integration layer
  - Metadata (term + votedFor) persisted **atomically** via write-fsync-rename (metadata.c:65-107)
  - Log persistence with **async fsync** via dedicated thread; entries acknowledged before durable
  - Snapshots created via **fork()** (COW); sent as chunked mmap; loaded via `RdbLoad`
  - Single-threaded event loop (Redis main thread); background threads only for fsync and DNS resolution
  - Single-server membership changes (not joint consensus); non-voting node catch-up before promotion
  - **Quorum reads** optional — without it, any leader (including stale) serves reads immediately
- **Extensively Jepsen-tested** (2020): 10+ critical bugs found and fixed. 9 fuzzing bugs remain unfixed (2024).

## 2. Bug Families

### Family 1: Snapshot Loading / State Transition Safety (HIGH)

**Mechanism**: Snapshot loading involves a multi-step sequence (file rename → raft state reset → RDB load → log truncation → node reconfiguration) with crash windows between steps that leave the node in inconsistent state. Also, event loop re-entrancy during blocking RDB loads causes use-after-free and assertion failures.

**Evidence**:
- Historical: `1c421cd` — log not updated on snapshot load, corrupting persistence (critical)
- Historical: `d052699` — wrong API used for startup snapshot load, wrong indices/term
- Historical: `ea178c4` [RR-116] — rdbLoad inside command callback causes use-after-free on disconnect
- Historical: `8aa2af5` — assertion failure from re-entrant message during snapshot load
- Historical: `91a5cd1` [RR-177] — memory/connection leak: Node objects not freed after snapshot load
- Historical: Issue #449 — crash when leader sends message during follower's rdbLoad
- Historical: Issue #654 (unfixed) — truncated RDB from crash during snapshot write → permanent node failure
- Code analysis: snapshot.c:495-540 — window between snapshot rename and log reset; crash leaves new snapshot + old log
- Code analysis: snapshot.c:401-410 — child process does not fsync RDB temp file before reporting success
- Raft library: `ffb58d2` — load_snapshot() argument swap (term/index transposed)
- Raft library: `fd76599` — snapshot recv_offset updated before load completion; stale snapshot response corrupts offsets
- Raft library: `280ae54` — follower accepted snapshot it already had via log entries

**Affected code paths**:
- `raftLoadSnapshot()` (snapshot.c:473-548)
- `raftStoreSnapshotChunk()` (snapshot.c:90-139)
- `initiateSnapshot()` / `finalizeSnapshot()` (snapshot.c:238-424)
- `raft_begin_load_snapshot()` / `raft_end_load_snapshot()` (raft_server.c:1904-1978)

**Suggested modeling approach**:
- Variables: `snapshotLastIdx[Server]`, `snapshotInProgress[Server]`, `incomingSnapshotIdx[Server]`
- Actions: `BeginSnapshot`, `EndSnapshot`, `SendSnapshotChunk`, `ReceiveSnapshotChunk`, `LoadSnapshot` (multi-step), `Crash` between steps
- Key: model the ordering of snapshot rename vs. log reset vs. node reconfiguration

**Priority**: High
**Rationale**: 12+ historical bugs, most bug-dense area by far. 7 bugs in snapshot.c alone (3 critical). Multiple crash windows identified. Snapshot + log consistency is a classic TLA+ modeling target.

---

### Family 2: Stale Read / Linearizability After Leader Election (HIGH)

**Mechanism**: After leader election, the new leader can serve reads before applying all committed entries from previous terms, violating linearizability. The Raft paper requires a no-op entry after election to determine the true commit index. Without quorum reads, a stale leader (partitioned but not yet timed out) serves stale data.

**Evidence**:
- Historical: Issue #19 — stale reads in normal operation, seconds after confirmed writes
- Historical: `1149155` — missing no-op entry after election (critical linearizability violation)
- Historical: `2984ef9` / Issue #316 — new leader serves reads before applying any current-term entry
- Raft library: `af0a6b7` — no-op not appended at term 1 (leader couldn't serve reads at all)
- Code analysis: redisraft.c:750-753 — non-quorum reads execute immediately on local state machine

**Affected code paths**:
- `raft_become_leader()` (raft_server.c:443-496) — no-op append + commit
- `handleRedisCommand()` (redisraft.c:746-789) — quorum vs non-quorum read dispatch
- `raft_recv_read_request()` — quorum read confirmation via heartbeat responses
- `checkRaftNotLoading()` (common.c:118-140) — pre-apply state check

**Suggested modeling approach**:
- Variables: `lastAppliedTerm[Server]` (to track if current-term entry has been applied), `readQueue[Server]`
- Actions: `ClientRead` (quorum vs non-quorum variants), `ReadConfirmed` (quorum heartbeat ACK)
- Invariant: `NoStaleRead` — if a read returns value V, then V was the last committed write
- Key: model the window between leader election and first current-term entry commit

**Priority**: High
**Rationale**: 4 historical bugs, 2 critical linearizability violations. The no-op mechanism is critical for Raft read safety. Quorum reads vs. non-quorum reads are a key design choice to model.

---

### Family 3: Membership Change Safety / Split Brain (HIGH)

**Mechanism**: Membership changes (node add/remove) interact dangerously with leader election and log replication. Historical bugs allowed isolated leaders to unilaterally complete membership changes, creating split-brain. Single-server change constraint had off-by-one bugs. Config changes during snapshot are partially blocked (voting changes blocked, non-voting additions allowed).

**Evidence**:
- Historical: Issue #17 — isolated leader removes all other nodes, creates split-brain (critical)
- Historical: Issue #28 — split brain + lost updates with membership changes + crashes
- Historical: Issue #44 — split brain with partitions only
- Historical: Issue #52 — dueling leaders violating log agreement
- Historical: `d3a7f75` — raft library bug in concurrent voting changes
- Historical: `eeffbf0` — unsafe direct node removal; removed nodes rejoin as zombies
- Historical: `abdc7c7` — assertion crash on NULL raft_node in AE response during removal
- Raft library: `b446c58` — bulk log pop didn't properly revert config changes during conflict resolution
- Raft library: `4052f32` — re-adding node incorrectly promoted non-voting to voting
- Raft library: `27e9595` — voting_cfg_change_log_idx off-by-one allowing concurrent changes
- Code analysis: raft_server.c:1159-1177 — single-change-at-a-time enforced, but non-voting adds bypass the check
- Code analysis: redisraft.c:182-184 — self-removal of sole node triggers immediate shutdown

**Affected code paths**:
- `raft_recv_entry()` (raft_server.c:1151-1199) — config change admission
- `raft_handle_append_cfg_change()` / `raft_handle_remove_cfg_change()` (raft_server.c:1223-1303)
- `raftApplyLog()` (raft.c:1022-1094) — membership change application
- `raftNotifyMembershipEvent()` (raft.c:1167-1219) — node add/remove lifecycle

**Suggested modeling approach**:
- Variables: `clusterConfig[Server -> SUBSET Server]` (each node's view of the cluster), `votingCfgChangeInProgress[Server -> BOOLEAN]`
- Actions: `AddNonVotingNode`, `PromoteToVoting`, `RemoveNode`, `ConfigChangeApplied`
- Invariant: `NoSplitBrain` — at most one leader per term; `ConfigChangeSafety` — at most one voting change at a time
- Key: model the interaction between membership changes and leader election/log replication

**Priority**: High
**Rationale**: 7+ historical bugs (4 critical split-brain), Jepsen-discovered. The membership change mechanism is the most complex interaction in Raft and the primary source of safety violations in this system.

---

### Family 4: Log Persistence / Crash Recovery (MEDIUM)

**Mechanism**: Log operations (truncation + append in AppendEntries, compaction across two log pages) are non-atomic multi-step sequences. Async fsync means entries can be acknowledged before durable. CRC chain provides corruption detection but all-or-nothing recovery.

**Evidence**:
- Historical: `c41d4c5` — multiple persistence fixes (backoff inversion, term/vote ordering, AE during loading)
- Historical: `da13b80` — partial readv() advanced pointer by wrong amount (data corruption)
- Historical: `226891c` — integer overflow in serialization for entries >2GB
- Historical: Issue #127 — extensive discussion of crash safety concerns (half-written entries, missing fsync, header corruption)
- Code analysis: raft_server.c:893-955 — log truncation + append is NOT atomic; crash between leaves truncated log
- Code analysis: log.c:880 — idx file rename during compaction is NOT fsynced (safe because idx rebuilt on startup)
- Code analysis: raft.c:2041-2043 — `log_fsync=false` provides zero durability

**Affected code paths**:
- `raft_recv_appendentries()` (raft_server.c:823-988) — truncation + append
- `LogCompactionBegin/End()` (log.c:840-895) — two-page compaction
- `pageWriteEntry()` / `pageLoadEntries()` (log.c:147-451) — entry persistence + recovery
- `handleBeforeSleep()` (raft.c:2026-2059) — async fsync and flush

**Suggested modeling approach**:
- Variables: `persistedLog[Server -> Seq(Entry)]`, `volatileLog[Server -> Seq(Entry)]`
- Actions: `Crash` that resets volatile state to persisted state; `Fsync` that makes volatile entries durable
- Key: model the gap between entry acceptance and fsync completion

**Priority**: Medium
**Rationale**: Multiple historical bugs. Log truncation non-atomicity is safe in practice (truncated entries are uncommitted) but worth modeling for completeness. The fsync gap is the more interesting target.

---

### Family 5: Response Handler / RPC Inconsistency (LOW)

**Mechanism**: Inconsistent null-checking and validation across different RPC response handlers. Some handlers check for null/stale nodes, others don't. RPC command handlers pass potentially null node pointers to the raft library.

**Evidence**:
- Code analysis: raft.c:888-890 — handleAppendEntriesResponse does NOT null-check raft_node (unlike handleRequestVoteResponse at line 809 and handleSnapshotResponse at snapshot.c:815)
- Code analysis: redisraft.c:969-971 — cmdRaftAppendEntries passes potentially NULL node to raft_recv_appendentries
- Code analysis: redisraft.c:316-318 — same issue in cmdRaftRequestVote
- Raft library: raft_server.c:1091-1108 — raft_recv_requestvote_response lacks early null-node check

**Priority**: Low
**Rationale**: Crash bugs rather than protocol safety violations. Better addressed by code review + defensive checks than TLA+ modeling.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Snapshot install + log reset ordering | Family 1: root cause of 12+ bugs, crash windows identified | Multi-step LoadSnapshot action with Crash between steps |
| Leader no-op after election | Family 2: linearizability violation without it | NoOp append in BecomeLeader; read blocked until applied |
| Quorum reads vs. non-quorum reads | Family 2: stale leader serving stale data | ReadQuorum (waits for heartbeat ACK) vs ReadLocal (immediate) |
| Single-server membership changes | Family 3: split-brain root cause, off-by-one bugs | AddNonVoting → PromoteToVoting → RemoveNode pipeline |
| Membership change + election interaction | Family 3: 4 critical split-brain bugs | ConfigChange interleaved with election transitions |
| Log truncation + append sequence | Family 4: non-atomic, crash between is possible | Split into TruncateConflicting + AppendNew, with Crash between |
| Crash and recovery from persisted state | Families 1, 4: crash windows in multiple paths | Crash action resets volatile state; recover from persisted |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Sharding / slot management | Not related to Raft consensus safety. Cluster.c is a separate layer on top. |
| Follower proxy | Implementation-level concern (use-after-free, response routing). Not protocol logic. |
| Async fsync thread | The fsync timing is a performance concern. Model durability as: persisted or not. |
| CRC integrity chain | Data integrity, not protocol safety. Better tested with fault injection. |
| Entry cache | Pure performance optimization. Single-threaded, no consistency risk. |
| Connection management / DNS | Networking layer, not protocol logic. |
| PreVote mechanism | Not related to any high-priority bug family in this system. Can be added later. |
| Client sessions / MULTI-EXEC | Application-level concern, not Raft protocol safety. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Snapshot state machine | `snapshotLastIdx`, `snapshotInProgress`, `loadingSnapshot` | Model multi-step snapshot install with crash windows | Family 1 |
| Leader no-op + read safety | `lastAppliedTerm`, `noopCommitted` | Model read linearizability after election | Family 2 |
| Quorum read tracking | `readQueue`, `heartbeatAcked` | Model quorum vs non-quorum read paths | Family 2 |
| Cluster config tracking | `clusterConfig`, `votingCfgChangeInProgress` | Model single-server membership changes | Family 3 |
| Non-voting node catch-up | `isVoting`, `isCaughtUp` | Model two-phase node addition | Family 3 |
| Persisted vs. volatile log | `persistedLog`, `volatileLog` | Model crash between truncate and append | Family 4 |
| Crash/recovery action | `crashed` flag, recovery from persisted state | Model crash at any point | Families 1, 3, 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 3 |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard, Family 3 |
| StateMachineSafety | Safety | All servers apply same entry at same index | Standard |
| NoStaleRead | Safety | A read returns only values from committed writes at or before the read's linearization point | Family 2 |
| NoReadBeforeNoOp | Safety | Leader does not serve reads until a current-term entry is committed | Family 2 |
| ConfigChangeSafety | Safety | At most one uncommitted voting config change at a time | Family 3 |
| NoSplitBrain | Safety | No two disjoint groups both have a leader in the same term | Family 3 |
| SnapshotLogConsistency | Safety | After snapshot install, first log index == snapshot last index + 1 | Family 1 |
| CrashRecovery | Safety | After crash + recovery, persisted state satisfies all safety invariants | Families 1, 4 |
| ReadLiveness | Liveness | Every quorum read request eventually gets a response | Family 2 |
| MembershipLiveness | Liveness | Non-voting node eventually promoted if majority is healthy | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Crash during snapshot load (between rename and log reset) → inconsistent recovery state | SnapshotLogConsistency | 1 |
| MC-2 | Non-quorum read on stale leader after partition → returns outdated value | NoStaleRead | 2 |
| MC-3 | Leader serves read before current-term no-op is committed | NoReadBeforeNoOp | 2 |
| MC-4 | Membership change + partition → isolated leader completes removal unilaterally | NoSplitBrain | 3 |
| MC-5 | Non-voting node add during snapshot bypasses voting-change guard; interaction with election | ConfigChangeSafety | 3 |
| MC-6 | Crash between log truncation and new entry append → shorter log on recovery | LeaderCompleteness (should still hold) | 4 |
| MC-7 | Two concurrent membership changes via off-by-one in votingCfgChangeLogIdx | ConfigChangeSafety | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | handleAppendEntriesResponse null-node crash (raft.c:888) | Kill a node during replication, check no crash in leader |
| TV-2 | Buffer overflow in archiveSnapshot (snapshot.c:884) | Call with long rdb_filename, check for corruption |
| TV-3 | Snapshot temp file not fsynced before rename (snapshot.c:401-410) | Power-cycle test after snapshot creation |
| TV-4 | `log_fsync=false` loses acknowledged entries on crash | Write entries, kill -9, check log on restart |
| TV-5 | Proxy response use-after-free when leader removed mid-request | Remove leader during proxy operation |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | qsort comparators never return 0 (raft_server.c:582, 2212) | Fix to comply with C standard |
| CR-2 | cmdRaftDebug nodecfg missing checkRaftState (redisraft.c:1362) | Add state guard |
| CR-3 | PANIC on snapshot index mismatch in raftStoreSnapshotChunk (snapshot.c:102) | Return error instead |
| CR-4 | applyShardGroupChange silently skips failed deserialization (raft.c:1905-1909) | Add error propagation |
| CR-5 | 9 unfixed fuzzing crash bugs (issues #643-#651, #654) | Triage and fix |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/redisraft/analysis-report.md`
- **Key source files**:
  - `deps/raft/src/raft_server.c` (core Raft protocol, 2394 lines)
  - `src/raft.c` (integration layer + callbacks, 2059 lines)
  - `src/redisraft.c` (Redis module + command handlers, 2188 lines)
  - `src/snapshot.c` (snapshot management, 908 lines)
  - `src/log.c` (persistent log, 1057 lines)
  - `src/cluster.c` (sharding, 1918 lines)
- **GitHub issues**: #17, #19, #28, #44, #52 (Jepsen split-brain/stale reads); #127 (crash safety discussion); #316 (read safety); #449 (snapshot crash); #643-#654 (unfixed fuzzing bugs)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), esp. Figure 2, Section 5.4.2 (commit rule), Section 4.1 (single-server changes)
- **Jepsen test suite**: `jepsen/` directory in repo
