# Analysis Report: RedisLabs/redisraft

## 1. Codebase Overview

### 1.1 Architecture

RedisRaft is a Redis module implementing distributed consensus via Raft. It consists of two layers:

1. **Raft protocol library** (`deps/raft/`): A bundled C library implementing core Raft consensus. Originally based on willemt/raft, extensively rewritten by RedisLabs.
   - `raft_server.c` (2394 lines): Election, replication, snapshotting, membership changes
   - `raft_node.c` (229 lines): Node state management
   - `raft_server_properties.c` (296 lines): State getters/setters
   - `raft_log.c` (446 lines): In-memory log implementation

2. **RedisRaft module** (`src/`): Redis module providing persistence, networking, and command handling.
   - `raft.c` (2059 lines): Raft library callbacks (send RPCs, persist, apply)
   - `redisraft.c` (2188 lines): Redis module entry, command handlers
   - `snapshot.c` (908 lines): Snapshot creation/loading via fork + RDB
   - `log.c` (1057 lines): File-based log with CRC32 integrity
   - `cluster.c` (1918 lines): Sharding/slot management
   - `connection.c` (483 lines): Async TCP connections via hiredis
   - Total: ~15,166 LOC

### 1.2 Concurrency Model

- **Single-threaded event loop**: Redis main thread handles all Raft state, commands, and callbacks
- **Background fsync thread**: Dedicated thread for log file fsync (communicates back via EventLoopAddOneShot)
- **Thread pool** (5 threads): DNS resolution only
- **Fork for snapshots**: Child process writes RDB, parent polls pipe for completion
- **No locks on Raft state**: Relies on Redis single-threaded model

### 1.3 Persistence Model

- **Metadata (term + votedFor)**: Atomic write-fsync-rename to a dedicated file
- **Log**: File-based with buffered writes, async fsync, CRC32 chain integrity
- **Snapshots**: Redis RDB files, created via fork, sent as mmap chunks
- **Two-page log**: Compaction creates a second page, then atomically renames over the first

### 1.4 Key Protocol Features

- PreVote extension (prevents disruptive elections from partitioned nodes)
- Leader transfer (explicit raft_transfer_leader API)
- Single-server membership changes (not joint consensus)
- Non-voting node catch-up before promotion to voting
- Quorum reads (optional, disabled by default)
- No-op entry after election (for commit index determination)
- Manual flush mode (batched entry persistence)

---

## 2. Bug Archaeology Results

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits analyzed | 937 |
| Bug-fix commits cataloged | 38 |
| GitHub issues deeply read | 48 |
| Issues confirmed as bugs | 35 |
| Issues classified as design defects | 5 |
| Issues classified as user error | 2 |
| Issues still open/unfixed | 9 (fuzzing crashes #643-#651, #654) |
| Raft library bug fixes found | 14 |

### 2.2 Severity Distribution

| Severity | Git Commits | GitHub Issues | Raft Library |
|----------|-------------|---------------|--------------|
| Critical | 5 | 10 | 3 |
| High | 12 | 8 | 5 |
| Medium | 16 | 5 | 4 |
| Low | 5 | 2 | 2 |

### 2.3 Bug Hotspot Analysis (by component)

| Component | Bug Count | Critical |
|-----------|-----------|----------|
| Snapshot loading/creation | 12 | 3 |
| Membership changes | 7 | 4 |
| Log persistence/recovery | 9 | 1 |
| Stale reads/linearizability | 4 | 2 |
| Connection/use-after-free | 7 | 0 |
| Serialization | 4 | 0 |
| Config/crash handling | 5 | 1 |

---

## 3. Detailed Git History Findings

### 3.1 Snapshot / Log Consistency Bugs

| Commit | Summary | Root Cause | Severity |
|--------|---------|------------|----------|
| `1c421cd` | Log not updated on snapshot load | Log file not restarted at snapshot's last index after loading | Critical |
| `d052699` | Fix snapshot loading at startup | Wrong API (follower-receive vs. startup-restore) | Critical |
| `ea178c4` | [RR-116] Don't load snapshot inside command callback | rdbLoad inside callback → use-after-free on disconnect | Critical |
| `8aa2af5` | Block leader's connection during snapshot load | Re-entrant message causes assertion failure | High |
| `91a5cd1` | [RR-177] Fix memory/connection leak on snapshot load | Node objects not freed after raft_begin_load_snapshot | High |
| `8a8ef1b` | [RR-186] Recreate locked_keys dict on snapshot load | Stale locks persist after snapshot | Medium |
| `6afb480` | Use SEEK_SET for snapshot file position | SEEK_CUR worked by accident; fragile | Low |

### 3.2 Stale Read / Linearizability Bugs

| Commit/Issue | Summary | Root Cause | Severity |
|--------------|---------|------------|----------|
| `1149155` | Fix stale read conditions | Missing no-op entry after election | Critical |
| `2984ef9` | Improve non-quorum read safety | New leader serves reads before current-term entry applied | High |
| Issue #19 | Stale reads in normal operation | Commit index not properly tracked across leader changes | Critical |
| Issue #316 | Read safety improvement | Demoted leader can serve stale data during re-election window | High |

### 3.3 Membership Change / Split Brain Bugs

| Issue/Commit | Summary | Root Cause | Severity |
|--------------|---------|------------|----------|
| Issue #17 | Lost updates with partitions + membership | Isolated leader removes all nodes → split-brain | Critical |
| Issue #28 | Split brain + lost updates with mixed faults | Same membership change mechanism | Critical |
| Issue #44 | Split brain with partitions only | Raft library joint consensus bug | Critical |
| Issue #52 | Dueling histories, duplicate elements | Two leaders violating log agreement | Critical |
| `d3a7f75` | Raft update: concurrent voting change fixes | Raft library didn't enforce single change at a time | High |
| `eeffbf0` | Fix and improve node removals | Unsafe direct removal; zombie nodes on rejoin | High |
| `abdc7c7` | Config change fuzzer fixes | Multiple: assert crash, join handling, off-by-one | Medium |

### 3.4 Log Persistence / Crash Recovery Bugs

| Commit | Summary | Root Cause | Severity |
|--------|---------|------------|----------|
| `c41d4c5` | Many persistence fixes | Inverted backoff, term/vote ordering, AE during loading | Critical |
| `da13b80` | File readv() partial read bug | Pointer advanced by requested count, not actual read count | High |
| `226891c` | [RR-262] Serialization bugs for large entries | Integer overflow: int instead of size_t/ssize_t | High |
| `aeaa561` | [RR-122] Add CRC32 to log entries | No integrity checking on log entries | Medium |
| `5136891` | RaftLogFirstIdx off-by-one | Should return snapshot_last_idx + 1, not snapshot_last_idx | Medium |
| `886fb30` | Metadata dbid null termination | Off-by-one in array index (latent, masked by zero-init) | Low |

### 3.5 Raft Library Bug Fixes

| Commit | Summary | Root Cause | Severity |
|--------|---------|------------|----------|
| `ffb58d2` | load_snapshot() argument swap | Term and index transposed in callback call | High |
| `4052f32` | recv_term() candidate step-down too aggressive | Abstraction mismatch: different RPCs need different term handling | High |
| `fd76599` | Snapshot recv_offset update before load completion | Offset advanced before success confirmed; stale snapshot response | Medium |
| `280ae54` | Follower accepted snapshot it already had | Checked against snapshot index, not current log index | Medium |
| `b446c58` | Bulk log pop didn't handle config changes properly | Individual config change reversion needed during conflict resolution | High |
| `4052f32` | Re-adding node promoted non-voting to voting | Missing explicit voting parameter in add_node_internal | Medium |
| `27e9595` | voting_cfg_change_log_idx off-by-one | current_idx already includes just-appended entry | Medium |
| `c1f2719` | Pre-vote rejection incorrectly guarded by transfer_leader | Used wrong flag for leader-known rejection check | High |
| `2986a70` | Leader heartbeat timeout_elapsed not reset | Excessive heartbeat traffic after refactoring | Medium |
| `c1f2719` | send_timeoutnow sent repeatedly | Missing sent_timeout_now guard | Low |
| `af0a6b7` | NOOP not appended for term 1 | Guard incorrectly skipped first term | High |
| `2b78f1d` | Config change on restart wrong error | voting_cfg_change_log_idx set from already-applied entry | Medium |

---

## 4. Deep Analysis Findings

### 4.1 raft_server.c Analysis

**Non-atomic log truncation + append** (lines 893-955):
In `raft_recv_appendentries`, conflicting entries are deleted first (line 939), then new entries are appended (lines 949-955), then synced (line 958). A crash between truncation and append leaves a shorter log. This is safe because truncated entries are uncommitted (assert at line 377), but creates an intermediate state.

**commitIndex guard is assert-only** (raft_server_properties.c:85):
`assert(me->commit_idx <= idx)` prevents decrement but is compiled out with NDEBUG. All callers independently guard, so this is safe in practice.

**Potential null deref in raft_update_commit_idx** (line 2233):
If `raft_get_entry_from_idx(me, commit)` returns NULL (compacted entry), `ety->term` dereferences NULL. Unlikely but possible if match_idx points to a compacted entry due to a bug elsewhere.

**Single-node auto-election skips self-vote** (lines 645-656):
Directly becomes leader without recording voted_for. Safe for single-node but deviates from the paper.

**qsort comparators violate C standard** (lines 582, 2212):
Never return 0 for equal values. Technically undefined behavior.

### 4.2 raft.c + redisraft.c Analysis

**handleAppendEntriesResponse missing null-node check** (raft.c:888):
Unlike handleRequestVoteResponse (line 809) and handleSnapshotResponse (snapshot.c:815), the AE response handler does NOT check if `raft_get_node` returns NULL. If a node is removed while a response is in flight, this passes NULL to the raft library.

**cmdRaftAppendEntries passes potentially NULL node** (redisraft.c:969):
`raft_get_node(rr->raft, src_node_id)` may return NULL if the source node ID is unknown. The result is passed directly to `raft_recv_appendentries` without a NULL check. Same issue in cmdRaftRequestVote (line 316) and cmdRaftSnapshot (line 1060).

**applyShardGroupChange silently skips failures** (raft.c:1905-1909):
On deserialization failure, returns early without error signal. The entry is still marked as applied (snapshot_info updated in caller). This can cause shard group state inconsistency.

**cmdRaftDebug nodecfg missing state check** (redisraft.c:1362-1411):
No `checkRaftState()` call. Could access `rr->raft` when raft is not initialized.

### 4.3 Snapshot Analysis

**No fsync of snapshot temp file before rename** (snapshot.c:401-410, 248):
The child process writes the RDB via `RedisModule_RdbSave` but does not explicitly fsync. The parent's `syncRename` fsyncs the directory but not the file contents. If `RedisModule_RdbSave` doesn't internally fsync, the snapshot data could be lost on power failure.

**Buffer overflow in archiveSnapshot** (snapshot.c:884-889):
`bak_rdb_filename` is allocated with `strlen(rr->config.rdb_filename)` but `snprintf` writes `"%s.bak.%d"` which is longer. The snprintf truncates, causing the backup to be renamed to a truncated path.

**Window of inconsistency during snapshot load** (snapshot.c:495-540):
Between `syncRename` (line 495) and `raft_end_load_snapshot`/`logImplReset` (line 540), the node has a new snapshot on disk but the log references old indices. A crash in this window requires re-requesting the snapshot from the leader.

**PANIC on snapshot index mismatch** (snapshot.c:102-104):
`raftStoreSnapshotChunk` PANICs if incoming snapshot index doesn't match expected. An error return would be safer.

### 4.4 Log Analysis

**Two-page compaction rename ordering** (log.c:873-895):
idx file renamed with plain `rename()` (line 880), then log file with `syncRename` (line 884). A crash between leaves inconsistent filenames. Safe because idx files are always rebuilt from log files on startup.

**No fsync after recovery truncation** (log.c:419, 435):
Corrupt entries are truncated during recovery without subsequent fsync. A crash during recovery would re-detect and re-truncate the same entries (idempotent).

**CRC chain is all-or-nothing** (log.c:377-393):
Any corruption in any entry causes truncation of all subsequent entries, even if they are individually intact. This is a design choice, not a bug.

**`log_fsync=false` provides zero durability** (raft.c:2041-2043):
With fsync disabled, acknowledged entries can be lost on any crash. This violates Raft safety if the leader considers entries replicated based on acknowledgment.

### 4.5 Cluster / Membership Analysis

**compareShardGroups only compares nodes, not slots** (cluster.c:235-237):
Acknowledged via FIXME comment. ShardingPeriodicCall might skip updates if node config matches but slot ranges differ.

**Proxy response use-after-free risk** (proxy.c:42-72):
If a leader node is removed while proxy responses are in flight, `NodeDismissPendingResponse(req->r.redis.proxy_node)` at proxy.c:48 accesses a potentially-freed Node. The mitigation relies on hiredis callback ordering.

**Connection termination flag cleared on successful resolve** (connection.c:346):
If `ConnAsyncTerminate()` is called between `ConnConnect()` and DNS resolution completing, the termination is silently reverted. This appears intentional but is surprising behavior.

---

## 5. GitHub Issues Summary

### 5.1 Jepsen-Discovered Bugs (2020, all FIXED)

| Issue | Title | Severity | Root Cause |
|-------|-------|----------|------------|
| #13 | RPUSH infinitely repeated | High | Re-entrancy: applied commands re-raftized |
| #14 | Total data loss on failover | Critical | Same re-entrancy bug |
| #17 | Lost updates with partitions + membership | Critical | Isolated leader completes membership changes |
| #18 | Transient empty values on restart | High | Reads before log replay complete |
| #19 | Stale reads in normal operation | Critical | Missing no-op after election |
| #25 | DISCARD doesn't always discard | Medium | MULTI/EXEC checks at wrong time |
| #26 | Crossed wires with follower-proxy | Critical | Proxy responses delivered to wrong client |
| #28 | Split brain + lost updates | Critical | Membership change + partition interaction |
| #30 | Empty reads with membership + crashes | High | State recovery timing |
| #44 | Split brain and lost updates | Critical | Joint consensus bug in raft library |
| #52 | Lost writes, duplicates, dueling histories | Critical | Two leaders violating log agreement |

### 5.2 Unfixed Fuzzing Bugs (2023-2024)

| Issue | Summary | Component |
|-------|---------|-----------|
| #643 | Assertion `ety != NULL` during log restore + RequestVote | Log restore + election |
| #644 | Connection crash during fuzzing | Connection management |
| #645 | Crash on adding new node | Node addition |
| #646 | Crash in callRaftPeriodic | Periodic handler |
| #647 | Crash on log update during AppendEntries | Log + replication |
| #648 | Multiple crash + assertion failures | Multiple |
| #649 | Crash polling client connections | Connection management |
| #650 | Null deref in dictFind via raft_become_follower | State transition |
| #651 | Crash in fsyncDir during MetadataWrite | Metadata persistence |
| #654 | Truncated RDB → permanent node failure | Snapshot crash safety |

### 5.3 Other Notable Issues

| Issue | Title | Classification |
|-------|-------|---------------|
| #2 | Re-adding node with same ID as removed node | Design defect (fixed) |
| #3 | Other nodes can't find leader after master removal | Bug (fixed) |
| #94 | Assert in quorum_msg_id during leader removal | Bug (fixed) |
| #102 | Dangling leader_node pointer after removal | Bug (fixed) |
| #125 | Premature node promotion affects availability | Design defect (fixed) |
| #127 | Crash safety of log file writes | Design defect (partially fixed) |
| #449 | Crash in raft.snapshot during load | Bug (fix proposed) |
| #487 | Crash on restart from RDB format change | Bug (fixed) |

---

## 6. Cross-Implementation Comparison Notes

The RedisRaft raft library (`deps/raft/`) differs from the hashicorp/raft implementation in several key ways:

1. **Metadata atomicity**: RedisRaft persists term+votedFor atomically via write-fsync-rename. hashicorp/raft uses two separate SetUint64 calls (non-atomic crash window).

2. **Heartbeat architecture**: RedisRaft's raft library sends heartbeats via the same `raft_send_appendentries` callback used for log replication (no separate goroutine). hashicorp/raft uses an independent heartbeat goroutine that can miss term updates.

3. **Membership changes**: Both use single-server changes. RedisRaft's library had critical bugs allowing concurrent changes (off-by-one in `voting_cfg_change_log_idx`). hashicorp/raft tracks committed vs. latest config with systematic inconsistency.

4. **Read safety**: RedisRaft offers optional quorum reads. hashicorp/raft uses leader lease (lastContact-based). Both had bugs related to reads after leader election.

5. **Snapshot mechanism**: RedisRaft uses fork+RDB (Redis-native). hashicorp/raft delegates to a SnapshotStore interface. Both had multiple snapshot-related bugs.

---

## 7. Findings Classification Summary

### Model-Checkable: 7 findings
- MC-1: Crash during snapshot load (between rename and log reset)
- MC-2: Non-quorum read on stale leader
- MC-3: Leader serves read before no-op committed
- MC-4: Membership change + partition → isolated leader completes removal
- MC-5: Non-voting node add during snapshot bypasses voting-change guard
- MC-6: Crash between log truncation and new entry append
- MC-7: Concurrent membership changes via off-by-one

### Test-Verifiable: 5 findings
- TV-1: handleAppendEntriesResponse null-node crash
- TV-2: Buffer overflow in archiveSnapshot
- TV-3: Snapshot temp file not fsynced
- TV-4: log_fsync=false loses acknowledged entries
- TV-5: Proxy use-after-free when leader removed

### Code-Review-Only: 5 findings
- CR-1: qsort comparators never return 0
- CR-2: cmdRaftDebug nodecfg missing state check
- CR-3: PANIC instead of error return in raftStoreSnapshotChunk
- CR-4: applyShardGroupChange silently skips failures
- CR-5: 9 unfixed fuzzing crash bugs
