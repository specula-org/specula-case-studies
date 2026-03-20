# Modeling Brief: rabbitmq/ra

## 1. System Overview

- **System**: rabbitmq/ra -- Erlang Raft consensus library used by RabbitMQ (quorum queues, Khepri)
- **Language**: Erlang, ~4255 LOC core logic (`ra_server.erl`)
- **Protocol**: Raft (with pre-vote, heartbeat-based consistent queries, single-server membership changes)
- **Key architectural choices**:
  - **Single gen_statem process per server** -- no independent goroutines/threads; all message handling is sequential within a server
  - **Effects-based architecture** -- `ra_server` is pure state machine returning effects; `ra_server_proc` executes them
  - **Heartbeat is a separate RPC type** (`heartbeat_rpc`) carrying only `query_index` and `term`, not a lightweight AppendEntries
  - **Term+voted_for persisted atomically** via batch server (`ra_log_meta`) -- term change clears voted_for in same batch
  - **Single-server membership changes** gated by `cluster_change_permitted` flag (not joint consensus)
  - **Pre-vote** with token-based correlation to prevent stale pre-vote results counting
  - **Follower applies before local fsync** -- intentional optimization; safety relies on leader's quorum durability
- **Concurrency model**: Single gen_statem process per server; snapshot sending and vote requests are spawned as child processes; WAL and segment writer are shared system-level processes

## 2. Bug Families

### Family 1: Log Divergence and Commit Index Safety (HIGH)

**Mechanism**: Incorrect commit index advancement allows uncommitted entries to be applied, or log inconsistencies arise from term/index mismanagement during leader changes.

**Evidence**:
- Historical: PR #508 (CRITICAL) -- follower applies uncommitted entries when commit_index is incorrectly incremented on AER with unvalidated log
- Historical: PR #516 (HIGH) -- late WAL written event confirms unwritten entries in a higher term; also replication liveness bug after member removal
- Historical: PR #562 (HIGH) -- `last_applied` persisted before WAL write; recovery fails because persisted index refers to non-existent entries
- Historical: PR #509 -- off-by-one in follower assertion for log reset vs commit_index
- Code analysis: `ra_server.erl:1323,1359` -- follower sets `commit_index` directly from `LeaderCommit` without `min(LeaderCommit, lastNewEntryIndex)` (paper deviation; bounded at apply time via `evaluate_commit_index_follower`)
- Code analysis: `ra_server.erl:3661` -- no explicit `max(oldCI, newCI)` guard in `increment_commit_index`; commit_index replacement is unconditional after term check passes

**Affected code paths**:
- `handle_follower(#append_entries_rpc{})` (ra_server.erl:1274-1427)
- `evaluate_commit_index_follower/2` (ra_server.erl:2263-2291)
- `increment_commit_index/1` (ra_server.erl:3653-3664)
- `persist_last_applied/1` (ra_server.erl:2554-2569)

**Suggested modeling approach**:
- Variables: `commitIndex`, `lastApplied`, `lastWritten` per server; `log` as sequence of `{Index, Term, Value}` tuples
- Actions: `FollowerAcceptEntries` must validate prevLogIndex/prevLogTerm before advancing commit; `AdvanceCommitIndex` must enforce §5.4.2 current-term check; `PersistLastApplied` must be bounded by `lastWritten`
- Key: Model the three-way relationship `lastWritten <= lastApplied <= commitIndex` and inject faults (WAL crash, stale written events) to test whether it can be violated

**Priority**: High
**Rationale**: 4 historical bugs including one CRITICAL safety violation. Commit index is the linchpin of Raft safety. The paper deviation (no `min` on follower commit_index) is a known gap even if safe in practice.

---

### Family 2: Election / Pre-Vote Liveness and Safety (HIGH)

**Mechanism**: Missing guards in election protocol allow non-voters to become leaders, prevent valid leaders from being elected (livelock), or reduce effective quorum during leadership transfer.

**Evidence**:
- Historical: Issue #439/PR #442 (CRITICAL) -- candidate/pre_vote livelock prevents leader election despite majority alive; candidate didn't handle pre_vote_rpc from nodes with higher log
- Historical: PR #435/PR #525 (HIGH) -- non-voter could transition to pre_vote/candidate and become leader
- Historical: PR #427 (HIGH) -- `non_voter` members incorrectly counted in quorum calculation
- Historical: Issue #251 (HIGH) -- leadership transfer reduces effective quorum; await_condition state didn't handle pre_vote_rpc
- Historical: PR #353 -- mixed machine version clusters couldn't elect leaders due to overly strict version check
- Code analysis: `ra_server.erl:1047` -- **vote count is an integer, not a set of voter IDs**. No deduplication. In clusters > 3 nodes, a network-duplicated `request_vote_result` could cause premature leader election with insufficient actual quorum support (e.g., 5-node cluster: self=1, one real remote=2, duplicate=3=quorum, but only 2 nodes actually voted). Same issue applies to pre-vote counting at line 1226.
- Code analysis: `ra_server.erl:1200-1269` -- pre_vote state mishandles `request_vote_rpc` with `Term <= CurTerm` (falls to catch-all error handler instead of proper rejection with current term)
- Code analysis: `ra_server.erl:1148,1246` -- no `membership := voter` guard in candidate/pre_vote `election_timeout`; a node whose membership changes to non-voter while in these states will re-elect
- Code analysis: `ra_server.erl:2960→1491` -- **pre-vote in-memory voted_for blocks real votes**: granting a pre-vote sets `voted_for => Cand` in memory (line 2960, not persisted). If a different candidate then sends `request_vote_rpc` at the same term, the guard at line 1491 (`VotedFor /= undefined andalso VotedFor /= Cand`) rejects the real vote. This can prevent the more-qualified candidate from winning.
- Code analysis: `ra_server.erl:2942` -- `process_pre_vote` calls `update_term(Term, State0)` which advances the receiver's term on higher-term pre_vote_rpc. Non-standard: the Raft thesis says pre-vote should NOT update the receiver's term. Could cause unnecessary term inflation from disconnected nodes.

**Affected code paths**:
- `call_for_election/2` (ra_server.erl:2880-2925)
- `handle_candidate/2` (ra_server.erl:1038-1175)
- `handle_pre_vote/2` (ra_server.erl:1177-1269)
- `handle_follower(#request_vote_rpc{})` (ra_server.erl:1482-1536)
- `required_quorum/1`, `count_voters/1` (ra_server.erl:4003-4016)

**Suggested modeling approach**:
- Variables: `state` (follower/pre_vote/candidate/leader/receive_snapshot), `membership` (voter/non_voter/promotable), `preVoteToken`, `votes` as set (not integer) to detect dedup issue
- Actions: Model `CallForElection(pre_vote)` -> `WinPreVote` -> `CallForElection(candidate)` -> `WinElection` chain; inject non-voter election attempts, concurrent pre_vote/candidate states, leadership transfer, message duplication
- Key: Model non-voter exclusion from voting AND quorum; track votes as a set to detect duplicate counting; check ElectionSafety and liveness

**Priority**: High
**Rationale**: 6+ historical bugs including a CRITICAL liveness failure. The pre-vote extension adds complexity not in the original Raft paper. The vote deduplication gap is a new finding that could violate election safety in larger clusters.

---

### Family 3: Consistent Query Linearizability (HIGH)

**Mechanism**: The heartbeat-based consistent query protocol can serve stale reads when query_index state is not properly reset across term changes, or when cluster_change_permitted is incorrectly set.

**Evidence**:
- Historical: Issue #483/PR #491 (HIGH) -- follower retains stale high query_index across term changes, causing minority-partition leader to think it has quorum for consistent reads
- Historical: PR #340 (HIGH) -- query_index not reset on term change; stale read after leader change
- Historical: PR #342 (MEDIUM) -- `cluster_change_permitted` not reset to `false` when becoming leader; consistent reads served before noop committed
- Historical: Issue #336 (HIGH) -- consistent_query hangs permanently after restarts
- Historical: PR #517 (MEDIUM) -- local query reply interpreted as gen_statem reply instead of Ra effect; non-leader query caller never answered
- Code analysis: `ra_server.erl:3756-3821` -- heartbeat quorum protocol appears correct in current implementation (post-PR #491 refactor)
- Code analysis: queries may hang indefinitely if no new leader is discovered (relies on client-side timeout)

**Affected code paths**:
- `handle_leader({consistent_query, ...})` (ra_server.erl:853-877)
- `heartbeat_rpc_quorum/4` (ra_server.erl:3804-3813)
- `make_heartbeat_rpc_effects/1` (ra_server.erl:3756-3774)
- `process_new_leader_queries/1` (ra_server.erl:1970-1981 in ra_server_proc.erl)

**Suggested modeling approach**:
- Variables: `queryIndex` per server, `queriesWaiting` queue on leader, `clusterChangePermitted`
- Actions: `ConsistentQuery` (leader records read commit index, sends heartbeats), `HeartbeatReply` (follower echoes query_index), `HeartbeatQuorumCheck` (leader releases query if quorum), `LeaderChange` (resets query state)
- Key: Check linearizability -- a consistent query must reflect all writes committed before the query was issued. Test with partitions and leader changes.

**Priority**: High
**Rationale**: 4 historical bugs directly violating linearizability. The heartbeat-based protocol is Ra-specific (not standard ReadIndex). Multiple fixes were required to get the query_index lifecycle right.

---

### Family 4: Snapshot Installation / State Interaction (MEDIUM)

**Mechanism**: Snapshot lifecycle (local write, remote install, checkpoint promotion) interacts with WAL events, election, and membership in ways that cause corruption, stuck states, or lost messages.

**Evidence**:
- Historical: de94f92 (CRITICAL) -- stale `snapshot_written` event after remote snapshot install deletes the newer snapshot, corrupting the log
- Historical: PR #470 (HIGH) -- `receive_snapshot` state stuck: AERs from new leader reset timeout but are ignored, preventing timeout recovery
- Historical: PR #455 (HIGH) -- premature snapshot state update from background writer process; WAL drops entries it thinks are covered by snapshot
- Historical: PR #591 (MEDIUM) -- segment writer reads snapshot state ETS non-atomically; incorrect index sets
- Historical: PR #558 (HIGH) -- log reset to snapshot index crashes deposed leader after partition
- Historical: PR #584 (MEDIUM) -- promotable members stuck after snapshot install (not promoted until next command)
- Open: Issue #563 -- multiple edge cases in receive_snapshot state (orphaned state, missing abort callback, restarted sender ignored)
- Code analysis: `ra_server.erl:1582` -- TODO: "just resetting to lastapplied may not be enough if all prior entries are not fully written"; if snapshot receive aborts after WAL writes are in-flight, log may reference unwritten entries
- Code analysis: `ra_server.erl:1816-1825` -- same-term AppendEntries during `receive_snapshot` fall to catch-all error handler instead of being properly rejected
- Code analysis: `ra_server.erl:2193-2202` -- snapshot sender process orphaned when leader steps down (peer status reset to `normal`, DOWN message not handled in follower state)

**Affected code paths**:
- `handle_follower(#install_snapshot_rpc{})` (ra_server.erl:1545-1616)
- `handle_receive_snapshot/2` (ra_server.erl:1667-1905)
- `ra_snapshot:begin_snapshot/complete_accept` (ra_snapshot.erl)
- `ra_log:handle_event({snapshot_written, ...})` (ra_log.erl:1004-1087)
- `ra_log:install_snapshot/4` (ra_log.erl:1159-1205)

**Suggested modeling approach**:
- Variables: `snapshotPhase` (none/pending/accepting), `snapshotIndex`, `pendingSnapshotWritten` flag
- Actions: `BeginSnapshot` (background), `SnapshotWritten` (event), `InstallSnapshot` (from leader), `CompleteAccept`. Model concurrent local snapshot + remote install.
- Key: Check that stale snapshot_written events after remote install don't corrupt state; check that receive_snapshot state can always exit (no stuck)

**Priority**: Medium
**Rationale**: Rich bug history (7+ fixes) but many were implementation-level (CRC, ETS race). The core protocol interaction (local snapshot vs remote install vs WAL events) is model-checkable and has yielded a CRITICAL bug.

---

### Family 5: Membership Change / Cluster Recovery (MEDIUM)

**Mechanism**: Single-server membership changes interact with elections, snapshots, and crash recovery in ways that leave the cluster configuration incorrect or the cluster_change_permitted flag stuck.

**Evidence**:
- Historical: 110b8d6 (CRITICAL) -- cluster config only scanned to `CommitIndex` on recovery, missing uncommitted cluster changes; incorrect cluster after restart
- Historical: PR #447 (MEDIUM) -- `cluster_change_permitted` incorrect after leader re-enters from `await_condition`; pending commands lost
- Historical: 4c0c57b (MEDIUM) -- wrong tuple extraction for pending cluster change `From` field
- Open: Issue #387 -- duplicated local effects when adding new member (no pivot point for effect replay)
- Open: Issue #528 -- crash on remove/re-add member (ETS table lifecycle race in `ra_mt:commit`)
- Code analysis: `ra_server.erl:3575` -- `pre_append_log_follower` can crash with `{badkey, previous_cluster}` when follower receives conflicting non-cluster-change entry at cluster_index, if `previous_cluster` was never set
- Code analysis: `ra_server.erl:3560-3576` -- first clause of `pre_append_log_follower` doesn't update `membership` field; stale membership possible after cluster change overwrite
- Code analysis: `ra_server.erl:1959-1968` -- client requests during leadership transfer in `await_condition` are silently swallowed (no error reply)

**Affected code paths**:
- `append_cluster_change/5` (ra_server.erl:3592-3612)
- `pre_append_log_follower/2` (ra_server.erl:3560-3590)
- `apply_with($ra_cluster_change)` (ra_server.erl:3344-3363)
- `cluster_scan_fun` during recovery (ra_server.erl:3304-3314)

**Suggested modeling approach**:
- Variables: `cluster`, `previousCluster`, `clusterIndexTerm`, `clusterChangePermitted`
- Actions: `AddMember`, `RemoveMember`, `ApplyClusterChange`, `OverwriteClusterChange` (on leader change)
- Key: Check that one-at-a-time invariant holds; check recovery scans to end of log; check rollback on term change

**Priority**: Medium
**Rationale**: 1 CRITICAL recovery bug and 2 open issues. Single-server changes are simpler than joint consensus but still have subtle interactions with leader changes and recovery.

---

### Family 6: WAL Crash Recovery / Persistence Ordering (LOW for TLA+)

**Mechanism**: WAL crash windows, written event ordering, and segment writer races can leave log state inconsistent after unclean shutdown.

**Evidence**:
- Historical: PR #581 (HIGH) -- WAL writers map lost after crash; subsequent writes with gaps silently accepted
- Historical: PR #589 (HIGH) -- 6 crash recovery bugs fixed in one PR (corrupt snapshot indexes, WAL recovery race, segment deletion comparison bug, etc.)
- Historical: PR #284 (HIGH) -- corrupt last WAL record crashes recovery
- Historical: PR #456 (HIGH) -- pre-init recovery broken; segment writer crashes on gap detection
- Historical: PR #428 (HIGH) -- multiple resend protocol bugs after WAL crash
- Historical: PR #111 (CRITICAL, fixed) -- term/voted_for not updated atomically (now fixed via batch)
- Code analysis: `sync_method = none` allows silent data loss (configurable deviation from Raft paper)

**Priority**: Low (for TLA+ modeling)
**Rationale**: Most bugs are implementation-level (file format, ETS race, fsync ordering) rather than protocol-level. The term/voted_for atomicity bug is already fixed. TLA+ would need to model the WAL as a separate process with crash semantics, which adds significant complexity for limited protocol-level insight.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Separate heartbeat from AppendEntries | Family 3: Ra's heartbeat carries `query_index` not `commit_index`; consistent query bugs depend on this | Two RPC types: `AppendEntriesRPC` (entries, commit_index, prevLog) and `HeartbeatRPC` (query_index, term) |
| Consistent query protocol | Family 3: 4 historical linearizability violations | `queryIndex` per server, `queriesWaiting` queue, heartbeat quorum check |
| Non-voter membership types | Family 2: 3 bugs from non-voter participation in elections/quorum | `membership` variable with voter/non_voter/promotable states |
| Single-server membership changes | Family 5: cluster recovery bug, cluster_change_permitted lifecycle | `clusterChangePermitted` flag, `previousCluster` for rollback |
| Pre-vote protocol | Family 2: livelock bug, multiple pre-vote interaction issues | `preVoteToken`, separate pre_vote state with transitions to candidate |
| Vote tracking as set | Family 2: vote deduplication gap; integer counter can double-count | `votesGranted` as `SUBSET Server` instead of integer counter |
| Snapshot installation (simplified) | Family 4: stale snapshot_written event corruption | `snapshotPhase` tracking, model concurrent local write + remote install |
| Follower commit_index without min | Family 1: paper deviation, bounded at apply time | Set commit_index directly from leader, check at apply time |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WAL internals | Family 6: implementation-level (file format, ETS, fsync). Too low-level for protocol TLA+. |
| Segment writer / compaction | Implementation detail, not protocol logic |
| Machine version upgrades | Feature-specific, no protocol-level safety implications |
| OTP version compatibility (CRC) | Serialization format issue |
| Pipeline batching | Performance optimization, not safety-relevant |
| Background worker process | Implementation concurrency, covered by gen_statem sequential processing |
| Log cache | Performance optimization |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Heartbeat-based reads | `queryIndex`, `queriesWaiting`, `peerQueryIndex` | Model consistent query protocol | Family 3 |
| Non-voter membership | `membership` (voter/non_voter/promotable) | Prevent non-voter election/quorum bugs | Family 2 |
| Pre-vote with token | `preVoteToken`, `preVoteState` | Model pre-vote liveness issues | Family 2 |
| Vote set tracking | `votesGranted` as SUBSET Server | Detect vote deduplication gap | Family 2 |
| Snapshot lifecycle | `snapshotPhase`, `pendingSnapshotWritten` | Model concurrent snapshot operations | Family 4 |
| Cluster change gating | `clusterChangePermitted`, `previousCluster` | Model one-at-a-time constraint | Family 5 |
| Leadership transfer | `transferTarget` in await_condition state | Model quorum reduction during transfer | Family 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard, Family 2 |
| LogMatching | Safety | Same index+term implies identical prefix | Standard, Family 1 |
| LeaderCompleteness | Safety | Committed entries appear in all future leaders' logs | Standard, Family 1 |
| CommitIndexMonotonicity | Safety | commit_index never decreases | Family 1 |
| VoterOnlyElection | Safety | Only voters can win elections | Family 2 |
| VoterOnlyQuorum | Safety | Only voters counted in commit quorum | Family 2 |
| NoDuplicateVoteCounting | Safety | Each voter contributes at most one vote per election | Family 2 |
| ConsistentQueryLinearizability | Safety | Consistent query result reflects all writes committed before query was issued | Family 3 |
| NoPhantomHeartbeatQuorum | Safety | Heartbeat quorum only counts peers with matching term | Family 3 |
| OneClusterChangeAtATime | Safety | At most one uncommitted cluster change in log | Family 5 |
| SnapshotLogConsistency | Safety | No gap between snapshot index and first log entry | Family 4 |
| PreVoteLiveness | Liveness | If majority of voters alive and connected, eventually a leader is elected | Family 2 |
| ConsistentQueryLiveness | Liveness | If leader is alive with majority, consistent queries eventually complete | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Vote deduplication gap: integer counter instead of voter-ID set; network duplicate can cause premature leader election in 5+ node clusters | ElectionSafety, NoDuplicateVoteCounting | 2 |
| MC-2 | Vote quorum uses exact equality not >= (cluster shrinkage skips quorum) | PreVoteLiveness | 2 |
| MC-3 | Candidate resets voted_for on same-term AER (line 1057) | ElectionSafety (theoretical) | 2 |
| MC-4 | Missing update_term in pre_vote install_snapshot_rpc handler (line 1212-1215) | ElectionSafety (stale term) | 2 |
| MC-5 | Follower commit_index set without min(LeaderCommit, lastNewEntry) | CommitIndexMonotonicity | 1 |
| MC-6 | pre_append_log_follower membership not updated on cluster overwrite | VoterOnlyElection | 5 |
| MC-7 | Leadership transfer + non-voter interaction during election | VoterOnlyElection, PreVoteLiveness | 2, 5 |
| MC-8 | No explicit monotonicity guard on commit_index in increment_commit_index (line 3661) | CommitIndexMonotonicity | 1 |
| MC-9 | Pre-vote in-memory voted_for blocks real vote: granting pre_vote to A prevents voting for B at same term | PreVoteLiveness, ElectionSafety | 2 |
| MC-10 | process_pre_vote advances receiver's term on higher-term pre_vote_rpc (line 2942); term inflation from partitioned nodes | PreVoteLiveness | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | pre_append_log_follower crash with badkey:previous_cluster | Property-based test with leader changes during cluster changes |
| TV-2 | receive_snapshot drops commands/queries (TODO at line 1904) | Integration test with commands during snapshot reception |
| TV-3 | Client requests silently dropped during leadership transfer in await_condition | Test with pipeline_command during transfer_leadership |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | handle_pre_vote missing proper rejection for lower-term request_vote_rpc | Add explicit rejection handlers instead of catch-all |
| CR-2 | Orphaned snapshot sender when leader steps down (peer status reset, DOWN not handled) | Add snapshot sender cleanup in become(follower) |
| CR-3 | No reply for already_member join attempts (TODO at line 3918) | Add explicit reply |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/ra/analysis-report.md`
- **Key source files**:
  - `artifact/ra/src/ra_server.erl` (core state machine, 4255 lines)
  - `artifact/ra/src/ra_server_proc.erl` (gen_statem wrapper, 2472 lines)
  - `artifact/ra/src/ra_log.erl` (log management, 1743 lines)
  - `artifact/ra/src/ra_snapshot.erl` (snapshot lifecycle, 1113 lines)
  - `artifact/ra/src/ra_log_meta.erl` (metadata persistence)
- **GitHub issues**: #483 (consistent query), #439 (election livelock), #387 (duplicate effects, open), #528 (re-add crash, open), #563 (snapshot state, open), #238 (crash on index reset, open)
- **Key PRs**: #508 (log divergence), #516 (replication bugs), #491 (consistent query refactor), #442 (pre-vote fix), #581 (WAL recovery), #589 (crash recovery resilience)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation (Ongaro, 2014) section 9.6 (pre-vote)
