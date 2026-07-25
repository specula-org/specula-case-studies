# Analysis Report: rabbitmq/ra

## 1. Reconnaissance Summary

### 1.1 Codebase Structure

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| Core state machine | `ra_server.erl` | 4255 | Raft protocol logic (all state handlers) |
| Process wrapper | `ra_server_proc.erl` | 2472 | gen_statem, timers, effects execution |
| Log management | `ra_log.erl` | 1743 | Log read/write, WAL coordination, snapshot install |
| Snapshot lifecycle | `ra_snapshot.erl` | 1113 | Snapshot write/accept/promote/recover |
| Write-ahead log | `ra_log_wal.erl` | 1183 | WAL batching, persistence, recovery |
| Log segments | `ra_log_segment.erl` | 1271 | On-disk segment format, read/write |
| Metadata store | `ra_log_meta.erl` | ~180 | Term/voted_for/last_applied persistence |
| Public API | `ra.erl` | 1284 | Client commands, queries, membership |
| Mem table | `ra_mt.erl` | 549 | In-memory entry staging |
| Machine interface | `ra_machine.erl` | 491 | State machine callback spec |
| **Total core** | | **~14,500** | |

### 1.2 Concurrency Model

- **Single gen_statem process per server**: All Raft message handling is sequential within a server. No independent heartbeat goroutine (unlike hashicorp/raft).
- **Effects-based architecture**: `ra_server` is a pure state machine that returns `{NextRaftState, NewState, Effects}`. `ra_server_proc` executes effects (send RPCs, spawn snapshots, etc.).
- **Spawned child processes**: Snapshot sending, vote request sending, and blocking RPC retries are spawned as child processes with monitors.
- **System-level shared processes**: WAL (`ra_log_wal`) and segment writer (`ra_log_segment_writer`) are shared across all ra servers in a system.
- **Worker process**: Per-server `ra_worker` for background I/O tasks.

### 1.3 Key Design Decisions

1. **Heartbeat is separate from AppendEntries**: `heartbeat_rpc` carries `{query_index, term, leader_id}` only. Used for consistent query quorum, not log replication.
2. **Single-server membership changes**: Gated by `cluster_change_permitted` flag. Not joint consensus.
3. **Pre-vote**: Prevents disruptive elections from partitioned nodes. Uses unique token to prevent stale pre-vote results.
4. **Follower applies before local fsync**: Intentional optimization. Follower can apply entries that haven't been locally fsynced, relying on leader's quorum durability guarantee.
5. **Term+voted_for atomic**: `ra_log_meta` uses gen_batch_server; async store(term) + sync store_sync(voted_for) in sequence guarantees both in same batch.
6. **Cluster config applied immediately on append**: Both leader and follower update in-memory cluster config when a `$ra_cluster_change` entry is first appended/received, not when committed.

### 1.4 Raft States

```
follower ─(election_timeout)─> pre_vote ─(pre_vote quorum)─> candidate ─(vote quorum)─> leader
    ^                              ^                              ^                         |
    |                              |                              |                         |
    └──────── higher term AER ─────┴──── higher term AER ─────────┴──── higher term AER ────┘

follower ─(install_snapshot_rpc)─> receive_snapshot ─(last chunk)─> follower
leader ─(transfer_leadership)─> await_condition ─(condition met)─> leader
leader ─(wal_down)─> await_condition ─(wal_up)─> leader
```

### 1.5 State Record Overview

Server state is an Erlang map with key fields:
- `current_term` -- persistent (ra_log_meta)
- `voted_for` -- persistent (ra_log_meta)
- `log` -- opaque ra_log handle
- `cluster` -- `#{ra_server_id() => ra_peer_state()}` map
- `cluster_change_permitted` -- boolean, gates membership changes
- `cluster_index_term` -- `{Index, Term}` of last cluster config entry
- `previous_cluster` -- `{PrevIdx, PrevTerm, PrevCluster}` for rollback
- `leader_id`, `commit_index`, `last_applied`, `machine_state`
- `votes` -- integer count (NOT a set of voter IDs)
- `membership` -- `voter | promotable | non_voter`
- `query_index` -- monotonic counter for consistent query protocol
- `queries_waiting_heartbeats` -- queue of pending consistent queries
- `pre_vote_token` -- unique `reference()` for pre-vote correlation
- `snapshot_phase` -- tracks multi-chunk snapshot reception

---

## 2. Bug Archaeology Results

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits in repository | 2,191 |
| Total bug-fix commits (all keywords) | ~351 |
| Bug-fix commits touching critical files | 125 |
| Commits analyzed in detail | 62 |
| GitHub issues deeply read (full comments) | 32 |
| GitHub PRs deeply read | 50+ |
| Confirmed consensus-critical bugs | 35 |
| Design defects identified | 7 |
| False positives excluded | 5 (user error: #309, #210; by design: #207; duplicate: #471; cosmetic: #310) |
| Open issues relevant to consensus | 8 (#238, #266, #387, #528, #563, #565, #585, #527) |

### 2.2 Bug Hotspot Analysis

| File | Bug-fix commits | Key bug categories |
|------|----------------|-------------------|
| `ra_server.erl` | 72 | Election, replication, cluster changes, queries |
| `ra_server_proc.erl` | 65 | Timer handling, message routing, effect execution |
| `ra_log.erl` | 57 | Log consistency, cache, snapshot interaction |
| `ra_log_wal.erl` | 33 | Recovery, written events, roll-over |
| `ra_log_segment.erl` | 18 | Format, compaction, read races |
| `ra_snapshot.erl` | 10 | Lifecycle, CRC, indexes |
| `ra_log_meta.erl` | 5 | Term/vote atomicity |
| `ra_mt.erl` | 3 | Table lifecycle |

### 2.3 Historical Bug Inventory (Consensus-Critical)

#### Log Replication / Commit Advancement

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| PR #508 (3aa50f2) | Follower applies uncommitted entries: commit_index incremented without log validation | CRITICAL |
| PR #516 (324d9bc) | 4 bugs: extra entries, incorrect resend, stale written event confirms wrong entries, liveness after removal | HIGH |
| PR #562 (ffe3016) | last_applied persisted above last_written; recovery fails | HIGH |
| 56439ce | Empty AER: follower returns higher next_index than expected, causing log inconsistency | HIGH |
| PR #509 | Off-by-one in follower assertion for log reset vs commit_index | MEDIUM |
| 11e1027 | Cache read bug causes gaps in replication messages | MEDIUM |
| d96c4b3 | WAL written event ambiguity (same index, different terms in same batch) | HIGH |

#### Election Safety

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| 306b59c / PR #111 | voted_for not cleared on new term (non-atomic persistence) | CRITICAL |
| Issue #439 / PR #442 | Candidate/pre_vote livelock: leader never elected despite majority alive | CRITICAL |
| PR #435 / PR #525 | Non-voter could become leader (via pre_vote or transfer_leadership) | HIGH |
| PR #427 | Non-voter counted in quorum calculation | HIGH |
| 8bcc62c | Pre-vote stale results counted (no token correlation) | HIGH |
| 7bf151d | Leader doesn't step down on install_snapshot_rpc with higher term | HIGH |
| ad5e674 | Leader doesn't clear voted_for on higher-term detection | HIGH |
| a643935 | Single-node cluster could not become leader | HIGH |
| PR #353 | Mixed machine version: overly strict version check blocks elections | HIGH |
| PR #588 | Missing DOWN signal handling in candidate state | MEDIUM |
| cc79766 | cluster_change_permitted not reset on becoming leader | MEDIUM |
| dbc9f0d / PR #447 | cluster_change_permitted incorrect after await_condition re-entry | MEDIUM |
| 6bc27d3 | query_index not reset on new term | MEDIUM |
| 328d00c / PR #291 | Leader_id not cleared after DOWN event; commands redirected to dead process | MEDIUM |
| 114d1d3 / PR #525 | Non-voter allowed to start election via transfer_leadership | HIGH |

#### Consistent Query

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| Issue #483 / PR #491 | Stale query_index causes minority partition leader to serve reads | HIGH |
| PR #340 | query_index not reset on term change; stale consistent read | HIGH |
| PR #342 | cluster_change_permitted not reset; reads served before noop committed | MEDIUM |
| PR #517 | Local query reply interpreted as gen_statem reply; non-leader never answers | MEDIUM |
| Issue #336 | consistent_query hangs permanently after restarts (same root cause as #483) | HIGH |

#### Snapshot

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| de94f92 | Stale snapshot_written event after remote install corrupts log | CRITICAL |
| 919a648 | Crash when follower becomes leader after snapshot install (wrong prev index) | HIGH |
| 7be9e29 | Leader snapshot + stale written event = crash in ra_log | HIGH |
| 3faf67a | Crash when resending from snapshot (fetch_term returns undefined) | HIGH |
| PR #470 | receive_snapshot stuck: AER resets timeout but is ignored | HIGH |
| PR #455 | Premature snapshot state update from writer process | HIGH |
| PR #558 | Log reset to snapshot index crashes deposed leader after partition | HIGH |
| PR #584 | Promotable members stuck after snapshot install | MEDIUM |
| PR #591 | Non-atomic snapshot state ETS read in segment writer | MEDIUM |
| adf11ab | Corrupt snapshot indexes file crashes init (not fsynced by design) | MEDIUM |
| 94add0e | Snapshot receive state doesn't handle election RPCs | MEDIUM |

#### Membership / Cluster Changes

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| 110b8d6 | Cluster config only scanned to CommitIndex; missed uncommitted changes | CRITICAL |
| 33eb036 | Cluster config not properly recovered after restart | HIGH |
| PR #447 | cluster_change_permitted incorrect after await_condition re-entry | MEDIUM |
| 4c0c57b | Wrong tuple extraction for pending cluster change From field | MEDIUM |
| Issue #387 (OPEN) | Duplicated local effects when adding new member | MEDIUM |
| Issue #528 (OPEN) | Crash on remove/re-add member (ETS table lifecycle) | HIGH |

#### WAL / Crash Recovery

| Commit/PR | Summary | Severity |
|-----------|---------|----------|
| PR #581 | WAL writers map lost after crash; gaps silently accepted | HIGH |
| PR #589 | 6 crash recovery bugs fixed in one PR | HIGH |
| 9aa04f1 | WAL recovery crash from concurrent mem table deletion | HIGH |
| fda98e3 | ra_log:commit rollback on wal_down; mem table already committed | HIGH |
| PR #428 | Multiple resend protocol bugs after WAL crash | HIGH |
| f68c255 | Writers snapshot file for persistence across crashes | HIGH |
| bbf40e0 | Segment writer deletes WAL without flushing on empty segment | CRITICAL |
| ac3d5e9 | 32-bit integer overflow in segment index (>4GB segments corrupt data) | CRITICAL |
| 2a463af | WAL: corrupt last record crashes recovery | HIGH |
| PR #456 | Pre-init recovery broken; segment writer crashes on gap detection | HIGH |

### 2.4 Issue Verification Summary

| Issue | Status | Classification | Component | Severity | Model-checkable |
|-------|--------|---------------|-----------|----------|----------------|
| #439 | Closed | Confirmed bug | Election (pre_vote) | Critical | Yes |
| #483 | Closed | Confirmed bug | Consistent queries | Critical | Yes |
| #418 | Closed | Confirmed bug | Election/leaderboard | High | Partial |
| #251 | Closed | Confirmed bug | Election/transfer | High | Yes |
| #228 | Closed | Confirmed bug (minor) | Leadership transfer | Medium | Partial |
| #336 | Closed | Confirmed bug | Consistent queries | High | Yes |
| #387 | Open | Confirmed bug | Membership/effects | Medium | Partial |
| #528 | Open | Confirmed bug | Membership/log | High | Partial |
| #238 | Open | Confirmed bug | Replication/log | High | Partial |
| #211 | Open | Design defect | Membership/API | Low | No |
| #563 | Open | Design defect | Snapshot | Medium | Yes |
| #557 | Closed | Confirmed bug | Log/snapshot | High | Yes |
| #266 | Open | Design defect | Recovery/versioning | Medium | Partial |
| #393 | Closed | Confirmed bug | Command ordering | High | Yes |
| #500 | Open | Enhancement | Quorum | Low | Yes |
| #145 | Open | Enhancement | Dedup | Medium | Yes |
| #256 | Closed | Design defect | Election/versioning | High | Yes |
| #416 | Closed | Confirmed bug | WAL resend | Medium | Partial |
| #585 | Open | Design defect | Disk exhaustion | Critical | Partial |
| #565 | Open | Confirmed bug (leak) | WAL cleanup | Medium | No |
| #527 | Open | Confirmed bug | Snapshot sending | Low | No |
| #175 | Closed | Confirmed bug | Segment overflow | Critical | No |
| #309 | Closed | User error | — | — | — |
| #310 | Closed | Design defect (minor) | API | Low | No |
| #210 | Closed | User error | — | — | — |
| #207 | Closed | By design | — | — | — |
| #471 | Closed | Disputed/False | — | — | — |
| #405 | Open | Design defect | API | Medium | No |
| #532 | Closed | Confirmed bug | Segment I/O | Medium | No |
| #167 | Closed | Design defect (feature) | Recovery | High | Partial |
| #204 | Open | Design defect | Election | Low | Yes |
| #202 | Closed | Confirmed bug (perf) | Replication | Medium | Yes |

---

## 3. Deep Analysis Results

### 3.1 Election and Vote Handling

**POTENTIAL ISSUES found:**

1. **Vote deduplication gap** (`ra_server.erl:1047`): Votes are counted as an integer (`Votes + 1`), not tracked by voter ID. No deduplication mechanism. In clusters > 3 nodes, a network-duplicated `request_vote_result` could cause premature leader election. Example: 5-node cluster, quorum=3, self-vote=1, one real remote vote=2, network duplicate=3=quorum -- but only 2 nodes actually voted. Same issue in pre-vote at line 1226. The gen_statem message processing is sequential, and Erlang distribution typically doesn't duplicate, but it's not impossible (especially with custom transport layers). **Assessment: Real gap, low probability but violates election safety if triggered.**

2. **Vote quorum exact equality** (`ra_server.erl:1050-1051`): Uses pattern match `case required_quorum(Nodes) of NewVotes ->` instead of `>=`. If cluster shrinks during election (voter removed between vote-counting events), votes can skip past quorum threshold, causing the election to time out. **Assessment: Latent liveness issue.**

3. **Missing install_snapshot_rpc handler in candidate** (`ra_server.erl:1038-1175`): Falls to catch-all. Candidate stays in candidate state despite legitimate leader sending snapshot. Compare with pre_vote which handles it (line 1212-1215). **Assessment: Liveness issue -- candidate delays recognizing new leader.**

4. **pre_vote state mishandles request_vote_rpc with Term <= CurTerm** (`ra_server.erl:1200-1269`): Falls to catch-all error handler instead of proper rejection with current term. A stale candidate doesn't learn it's stale. **Assessment: Liveness issue -- delays stale candidate step-down.**

5. **Missing membership guard in candidate/pre_vote election_timeout** (`ra_server.erl:1148,1246`): If a node's membership changes to non-voter while in candidate or pre_vote state, the next election_timeout retriggers election without checking. **Assessment: Low severity -- pre_vote quorum win requires `membership := voter` (line 1223).**

6. **Pre-vote persists voted_for** (`ra_server.erl:2920`): Raft thesis says pre-vote should not modify persistent state. Ra persists `voted_for = Id` at current term during pre-vote. Overly conservative but not unsafe because real candidates increment the term.

7. **Pre-vote in-memory voted_for blocks real votes** (`ra_server.erl:2960→1491`): When a follower grants a pre-vote, it sets `voted_for => Cand` in memory at line 2960 (not persisted). If a different candidate then sends `request_vote_rpc` at the same term, the guard at line 1491 (`VotedFor /= undefined andalso VotedFor /= Cand`) rejects the real vote. Scenario: node A sends pre_vote_rpc, node C grants (voted_for=A in memory); node B then sends real request_vote_rpc at same term, C rejects because voted_for=A. If A then fails pre-vote quorum, no candidate can win at this term. **Assessment: Liveness issue, not safety. Could delay elections by one timeout.**

8. **process_pre_vote advances receiver's term** (`ra_server.erl:2942`): `process_pre_vote` calls `update_term(Term, State0)` which, if `Term > CurTerm`, advances the receiver's term and clears voted_for. The Raft thesis (§9.6) says pre-vote should NOT update the receiver's term. This means a disconnected node that has advanced its own term (via failed elections) can still advance other nodes' terms via pre_vote_rpc. **Assessment: Non-standard deviation. Could cause unnecessary term inflation from partitioned nodes, disrupting the cluster even with pre-vote enabled.**

**CONFIRMED SAFE:**
- Election safety (single leader per term): voted_for persisted via `store_sync` before grant reply is sent as effect
- Log comparison (`is_candidate_log_up_to_date`): matches paper §5.4.1 exactly (lines 3160-3174)
- Quorum calculation: correctly excludes non-voters (lines 4008-4016)
- Pre-vote token freshness: prevents stale results from previous rounds
- Leadership transfer goes through pre-vote (not direct candidate)
- Higher-term AER in candidate correctly steps down (lines 1073-1078)
- `update_term_and_voted_for`: batch server ordering guarantees both writes in same batch; sync barrier flushes

### 3.2 Log Replication and Commit Advancement

**DEVIATIONS found:**

1. **Follower commit_index without min** (`ra_server.erl:1323,1359`): Sets `commit_index => LeaderCommit` directly. Paper says `min(LeaderCommit, lastNewEntryIndex)`. Safe because `evaluate_commit_index_follower` bounds apply at `min(lastLogIndex, commitIndex)` (line 2269).

2. **No explicit monotonicity guard on commit_index** (`ra_server.erl:3661`): `increment_commit_index` sets `commit_index => PotentialNewCommitIndex` without `max(oldCI, newCI)`. In theory, if cluster membership shrinks and remaining peers have lower match_indexes, the median could decrease. In practice, the leader's own `last_written` in the median prevents significant regression, and `last_applied` prevents re-application.

3. **match_index can go backward** (`ra_server.erl:615-626`): For non-persistent peers when `PeerLastIdx < MI`. Developer comment: "can only really happen when peers are non-persistent."

4. **Follower applies before local fsync** (`ra_server.erl:2264-2267`): Intentional optimization. Developer comment: "This may mean we apply entries that have not yet been fsynced locally."

5. **Leader replicates un-fsynced entries** (`ra_server.erl:2433`): Leader reads from mem table (not just written entries) for replication. Safe because leader's quorum contribution uses `last_written` (line 3681).

**CONFIRMED SAFE:**
- §5.4.2 safety rule (only commit current-term entries): correctly implemented at lines 3653-3664
- `agreed_commit` median calculation: correct (lines 3692-3695)
- Deduplication via `drop_existing`: correct -- checks exact `{Idx, Term}` match (lines 3707-3715)
- Term mismatch handling: follower correctly rewinds to `LastApplied`
- Pipeline flow control: `max` on match_index (line 535), assertions on next_index (line 2343)
- Written events for truncated entries: safely handled via term check and prefix removal (ra_log.erl:881-893)
- Stale-term success replies: correctly discarded (term match at line 522-525)

### 3.3 Consistent Query Protocol

**No new bugs found** in current implementation. The post-PR #491 refactor appears correct:
- Noop barrier before reads (`cluster_change_permitted` blocks queries until noop committed)
- Heartbeat quorum with term checking
- Monotonic query_index per leader term
- Redirect pending queries on leader change
- Single-node cluster: query applied immediately without heartbeats (line 3766)

**POTENTIAL CONCERN**: Queries accumulate indefinitely in `queries_waiting_heartbeats` if leader is partitioned. No per-query timeout at the server level -- relies on client-side timeout.

9. **Consistent query assertion crash risk** (`ra_server.erl:3872`): `apply_consistent_queries_effects` contains `true = LastApplied >= ReadCommitIndex` -- a hard crash assertion. If any bug in commit index advancement causes `LastApplied < ReadCommitIndex` when queries are released, the leader process crashes. This is a defensive check that is correct given protocol invariants, but any violation of the invariant chain (commit_index monotonicity, apply ordering) will crash the leader rather than serve stale data.

### 3.4 Snapshot Installation

**POTENTIAL ISSUES found:**

1. **TODO at line 1582**: "just resetting to lastapplied may not be enough if all prior entries are not fully written". If `set_last_index(LastApplied)` is called during snapshot init but WAL writes below `LastApplied` are still in flight, and the snapshot is subsequently aborted, the log may reference entries that were never durably written.

2. **Same-term AppendEntries during receive_snapshot** (`ra_server.erl:1816-1825`): Only handles `Term > CurTerm`. Same-term AERs from current leader fall to catch-all at line 1901, returning error reply instead of standard Raft rejection. This is by design but may cause unnecessary leader retries.

3. **Orphaned snapshot sender on step-down** (`ra_server.erl:2193-2202`): When leader steps down to follower, `become(follower, ...)` resets all peer statuses to `normal`. Active snapshot sender processes continue running but the eventual DOWN message is not properly handled in follower state (falls through to unexpected handler at line 2677-2680).

**CONFIRMED SAFE:**
- Stale snapshot_written events: guarded at ra_log.erl:1088 (snapshot index comparison)
- Deferred completion for pending writes: lines 1741-1751 properly defer finalization
- Chunk sequence validation: term and index checked on every chunk
- Abort handling: `abort_receive` properly cleans up (lines 1907-1925)
- Concurrent snapshot handling: `complete_accept` clears accepting state
- Snapshot + peer exclusion: leader cannot send both snapshot and AER simultaneously (peer status mechanism at line 2306-2312)
- Full log discard on snapshot install: deviation from paper §7 but safe (ra_log.erl:1159-1205)

### 3.5 Membership Changes

**POTENTIAL ISSUES found:**

1. **pre_append_log_follower crash** (`ra_server.erl:3575`): Second clause reads `maps:get(previous_cluster, State)` but `previous_cluster` may not be set if the follower received the original cluster change via the first clause (line 3562-3576 doesn't set `previous_cluster`). Requires specific interleaving: cluster change entry received, then overwritten by non-cluster-change entry at same index. **Assessment: Low severity, specific interleaving required.**

2. **Membership not updated on cluster overwrite** (`ra_server.erl:3560-3576`): First clause of `pre_append_log_follower` updates `cluster` and `cluster_index_term` but not the node's own `membership` field. Could leave stale membership after cluster change overwrite. **Assessment: Low severity, rarely triggered.**

3. **Commands silently dropped during leadership transfer** (`ra_server.erl:1959-1968`): In `await_condition` during transfer, the `transfer_leadership_condition` predicate returns `{false, State}` for client messages, causing them to be swallowed without error reply. Also noted in Issue #228. **Assessment: Medium severity -- clients need their own timeouts.**

**CONFIRMED SAFE:**
- One cluster change at a time invariant: `cluster_change_permitted` flag correctly gates at lines 3493-3498
- `cluster_change_permitted` lifecycle: reset to `false` on `become(leader, ...)` (line 2189); set to `true` when noop committed (line 3378-3383) or cluster change committed (line 3356/3362)
- Cluster recovery scans uncommitted log entries (lines 498-501)
- Follower rollback via `previous_cluster` on cluster change overwrite (line 3575-3590)
- Promotable auto-promotion via `maybe_promote_peer/3` (lines 3982-4001)

### 3.6 Persistence / WAL

**CONFIRMED SAFE:**
- Term/voted_for atomicity: gen_batch_server guarantees both in same batch; `store_sync` barrier
- `last_applied` bounded by `last_written` (PR #562 fix at line 2554-2569)
- WAL written events include term for disambiguation
- WAL roll-over correctly threads writer state via `persist_writers` (lines 688-693)
- Config file writes use atomic rename (ra_log.erl:1460-1476)
- WAL file creation uses write-to-tmp + rename (ra_log_wal.erl:716-735)

**DEVIATIONS:**
- `sync_method = none` allows silent data loss (configurable)
- Snapshot uses current cluster config, not at-snapshot-point config (developer comment: "there may well be dragons here" implied by TODO at line 3603)

### 3.7 Developer Signals

Key TODO/FIXME comments found in core files:

| File:Line | Content | Severity |
|-----------|---------|----------|
| ra_server.erl:1582 | "just resetting to lastapplied may not be enough if all prior entries are not fully written" | HIGH |
| ra_server.erl:3603 | "is it safe to do change the cluster config with an async write?" | MEDIUM |
| ra_server.erl:1904 | "work out what else to handle" (receive_snapshot catch-all) | MEDIUM |
| ra_server.erl:1023 | "find a timeout" (leadership transfer) | LOW |
| ra_server.erl:654 | leadership transfer on WAL down doesn't select best peer | LOW |
| ra_server.erl:3918 | no reply for already_member join attempts | LOW |
| ra_server.erl:46 | `make_rpcs` export should be internal | LOW |
| ra_server.erl:617 | non-persistent peer handling in match_index backtrack | LOW |

---

## 4. Cross-Reference Matrix

| Finding | Election | Replication | Queries | Snapshot | Membership | WAL |
|---------|----------|-------------|---------|----------|------------|-----|
| Non-voter quorum | X | X | | | X | |
| Vote deduplication | X | | | | | |
| cluster_change_permitted | X | | X | | X | |
| Term management | X | X | X | X | X | X |
| Pre-vote interactions | X | | | X | X | |
| Log divergence on leader change | | X | | | | |
| Stale state across term changes | X | | X | | | |
| Snapshot + election interaction | X | | | X | | |
| Commit index monotonicity | | X | | | X | |
| Crash recovery | | X | | X | X | X |

---

## 5. Comparison with hashicorp/raft

| Aspect | hashicorp/raft | rabbitmq/ra |
|--------|---------------|-------------|
| Language | Go | Erlang |
| Concurrency | Multi-goroutine (independent heartbeat) | Single gen_statem (sequential) |
| Heartbeat | Independent goroutine, no term check on response | Separate RPC type, term checked |
| Leader lease | lastContact-based lease | No lease; heartbeat quorum for reads |
| Config | Committed + latest (dual tracking) | Single config + cluster_change_permitted gate |
| Persistence | Two separate SetUint64 calls (crash window) | Batch server write (atomic via ordering + sync barrier) |
| Pre-vote | Copied from RequestVote (copy-paste bugs) | Token-correlated, purpose-built |
| Consistent reads | Not built-in (user implements) | Heartbeat-based quorum (built-in) |
| Vote tracking | Not examined | Integer counter (no dedup) |
| Key bug pattern | Independent heartbeat -> phantom contact -> stale leader | Pre-vote interactions -> livelock/non-voter election |

Ra's single-process architecture eliminates hashicorp/raft's entire Family 1 (heartbeat independence) but introduces its own Family 3 (consistent query linearizability) which hashicorp/raft doesn't have. Ra's pre-vote implementation is more robust (token-based) but has had more interaction bugs with other states.

---

## 6. Findings Summary

| Category | Count |
|----------|-------|
| Historical consensus bugs confirmed | 35 |
| New potential issues (code analysis) | 11 |
| Deviations from Raft paper | 7 |
| Model-checkable findings | 10 |
| Test-verifiable findings | 3 |
| Code-review-only findings | 3 |
| Active TODO/FIXME in core | 8 (significant) |
| Open issues relevant to consensus | 8 |

### Most Significant New Finding: Vote Deduplication Gap (MC-1)

The most impactful new finding from this analysis is the vote deduplication gap in `ra_server.erl:1047`. Votes are tracked as an integer counter (`votes => 0`, incremented by 1 per `request_vote_result{vote_granted=true}`), not as a set of voter IDs. There is no mechanism to detect or prevent double-counting of votes from the same peer.

While Erlang distribution typically provides reliable single-delivery, this is not guaranteed in all deployment scenarios (custom transports, proxied connections, or bugs in the distribution layer). In a 5-node cluster, a single duplicated vote could cause a node to believe it has won the election with support from only 2 out of 5 nodes (quorum requires 3).

The same issue applies to pre-vote counting at line 1226, though pre-vote is non-binding and a false pre-vote win only accelerates the transition to a real election (which has the same vulnerability).

**Recommendation**: Model votes as `SUBSET Server` in the TLA+ spec and check whether ElectionSafety holds when message duplication is possible. If the invariant is violated, this is a real (if low-probability) bug that should be reported.
