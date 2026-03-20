# Confirmed Bug Report — tikv/raft-rs

## Summary

- Total findings reviewed: 10 (4 test-verifiable, 3 code-review-only, 3 code-analysis)
- Confirmed: 4 (4 reproduced)
- False positives: 3
- Inconclusive: 0
- Filtered (style/cleanup/out-of-scope): 3

Model checking explored 500M+ states across 5 configurations with 0 safety violations found.
The confirmed bugs are all liveness/availability issues, not safety violations — consistent with MC results.

## Bug 1: PreVote + Priority Panic at Term=0 (#511)

- **Source**: Code Review (TV-1), GitHub issue raft-rs #511 (OPEN)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `raft.rs:631-648` (send() term assertion), `raft.rs:1525-1534` (rejection response)

### Description

When a fresh node (term=0) with `pre_vote=true` and high priority receives a PreVote request
from a lower-priority node, it rejects the PreVote. The rejection response carries
`to_send.term = self.term = 0`. The `send()` function asserts that all vote/prevote messages
must have non-zero term (lines 631-648), causing a `fatal!` panic.

The assertion comment explains: "All {pre-,}campaign messages need to have the term set when
sending." This invariant holds after at least one election cycle (term >= 1), but fails for
freshly initialized nodes that have never participated in an election.

### Trigger Scenario

1. 3-node cluster, all fresh (term=0), `pre_vote=true`, priorities: {1, 5, 5}
2. Node 1 (priority=1) times out first, starts PreVote campaign with term=1
3. Node 2 (priority=5, term=0) receives the PreVote request
4. Vote grant check: `is_up_to_date` passes (equal empty logs), but
   `self.priority(5) <= get_priority(&m)(1)` → FALSE → vote rejected
5. Rejection: `to_send.term = self.term = 0`
6. `send()` panics: "term should be set when sending MsgRequestPreVoteResponse"

### Reproduction

Test: `harness/tests/integration_cases/test_raft.rs::test_bug_prevote_priority_panic_at_term_zero`

```
$ cargo test -p harness --test tests -- test_bug_prevote_priority_panic_at_term_zero
```

Output confirms the panic:
```
panicked at raft.rs:644:17: term should be set when sending MsgRequestPreVoteResponse, raft_id: 2
```

The test catches the panic with `catch_unwind` and verifies the panic message matches.

### Impact

Any cluster using `pre_vote=true` with heterogeneous priorities will crash nodes during the
first election if a low-priority node campaigns before higher-priority nodes have advanced
beyond term=0. This is especially likely in fresh cluster bootstrapping.

### Recommendation

Fix the rejection response to use `m.term` (the incoming PreVote request's term) instead of
`self.term` when `self.term == 0`, or ensure nodes advance to term >= 1 during initialization.
Alternatively, the `send()` assertion could be relaxed for PreVoteResponse rejections, since
the etcd/raft comment only justifies the invariant for *granted* responses.

---

## Bug 2: Priority Blocks CAMPAIGN_TRANSFER Votes (Liveness)

- **Source**: Code Review (analysis finding #1), Code Analysis (raft.rs:1499)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `raft.rs:1499` (priority check in vote grant), `raft.rs:1358` (CAMPAIGN_TRANSFER force flag)

### Description

When the leader explicitly transfers leadership to a target node via `MsgTransferLeader`, the
target campaigns with `CAMPAIGN_TRANSFER` context. The `force` flag at `raft.rs:1358` correctly
bypasses the lease/check_quorum protection, but the priority check at line 1499 is NOT bypassed.

If the transfer target has lower priority than other voters AND all logs are equal length
(which is guaranteed since the leader waits for the target to catch up before sending
`MsgTimeoutNow`), the priority check causes other voters to reject the vote:

```rust
// raft.rs:1499 — priority check applies regardless of CAMPAIGN_TRANSFER
(m.index > self.raft_log.last_index() || self.priority <= get_priority(&m))
```

When logs are equal (`m.index == last_index`), the first condition is false, and the priority
check `self.priority <= get_priority(&m)` rejects if the voter has higher priority.

### Trigger Scenario

1. 3-node cluster: Node 1 (priority=10, leader), Node 2 (priority=1, target), Node 3 (priority=10)
2. Leader (node 1) transfers to node 2 via `MsgTransferLeader`
3. Node 2's log is caught up → leader sends `MsgTimeoutNow`
4. Node 2 campaigns with `CAMPAIGN_TRANSFER` at term+1
5. Node 1 (priority=10): steps down to new term, rejects vote (`10 <= 1` → false)
6. Node 3 (priority=10): steps down to new term, rejects vote (`10 <= 1` → false)
7. Node 2 gets 1/3 votes → election fails
8. **Result**: No leader in the cluster. Old leader stepped down, transfer target couldn't win.

### Reproduction

Test: `harness/tests/integration_cases/test_raft.rs::test_bug_priority_blocks_leader_transfer`

```
$ cargo test -p harness --test tests -- test_bug_priority_blocks_leader_transfer
```

The test confirms:
- Node 2 (transfer target) does NOT become leader
- Node 1 (old leader) is no longer leader
- No node is leader — the cluster is leaderless

### Impact

Leader transfer to low-priority nodes always fails in clusters where other voters have higher
priority. This is a liveness regression: the explicitly requested transfer fails, the old
leader has already stepped down, and the cluster must wait for a new election timeout.
Worse, the new election will likely elect a high-priority node, not the desired target.

This effectively makes priority-based clusters unable to do leadership transfer to any
non-highest-priority node.

### Recommendation

Bypass the priority check for `CAMPAIGN_TRANSFER` elections, similar to how the lease check
is already bypassed. The leader has explicitly designated this target; the priority system
should not override an intentional transfer.

Suggested fix at `raft.rs:1499`:
```rust
let is_transfer = m.context == CAMPAIGN_TRANSFER;
if can_vote
    && self.raft_log.is_up_to_date(m.index, m.log_term)
    && (is_transfer || m.index > self.raft_log.last_index() || self.priority <= get_priority(&m))
```

---

## Bug 3: Leader Removed from Config Does Not Step Down

- **Source**: Code Review (analysis finding #5), Code Analysis (raft.rs:2747-2757)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `raft.rs:2747-2757` (`post_conf_change` function)

### Description

When a configuration change removes the current leader from the voter set, `post_conf_change()`
at line 2747-2757 detects `!is_voter && self.state == StateRole::Leader` but **does not step
down**. It simply returns early after setting `self.promotable = false`.

The code contains two explicit TODOs from the etcd/raft authors:
- "TODO(tbg): step down (for sanity) and ask follower with largest Match to TimeoutNow"
- "TODO(tbg): test this branch. It is untested at the time of writing."

### Trigger Scenario

1. 3-node cluster: {1, 2, 3}, node 1 is leader
2. Leader proposes config change removing itself from the voter set
3. Config change commits and is applied
4. `post_conf_change()` detects leader is no longer a voter → returns early
5. Leader continues sending heartbeats to nodes 2 and 3
6. Heartbeats reset election timers → nodes 2 and 3 cannot start elections
7. With `check_quorum` enabled, the leader eventually steps down when it fails quorum check
8. Without `check_quorum`, the cluster is blocked indefinitely — the removed leader
   continues preventing elections while unable to commit new entries

### Reproduction

Test: `harness/tests/integration_cases/test_raft.rs::test_bug_removed_leader_does_not_step_down`

```
$ cargo test -p harness --test tests -- test_bug_removed_leader_does_not_step_down
```

The test confirms:
- Node 1 is removed from the voter set via `apply_conf_change(&remove_node(1))`
- Node 1 remains `StateRole::Leader` after removal (the bug)
- Node 1 is no longer promotable (`promotable() == false`)
- Node 1 still sends `MsgHeartbeat` messages to remaining voters
- Node 2 remains a follower with `leader_id == 1` (heartbeats suppress elections)

### Impact

Liveness issue. A removed leader delays the election of a new leader by continuing to suppress
election timeouts via heartbeats. With `check_quorum` disabled, this can block indefinitely.

### Recommendation

Implement the suggested TODO: step down and send `MsgTimeoutNow` to the follower with the
highest `matched` index.

---

## Bug 4: Auto-Leave Joint Consensus Stalls on Leader Change

- **Source**: Code Review (analysis finding #10), Code Analysis (raft.rs:987)
- **Status**: REPRODUCED
- **Severity**: Low
- **Location**: `raft.rs:987-1007` (`commit_apply_internal` auto-leave logic)

### Description

The auto-leave mechanism for joint consensus (line 987-1007) only triggers when
`self.state == StateRole::Leader`. If the leader crashes after proposing the enter-joint
config change but before applying it, followers apply the entry but cannot trigger auto-leave
(the `self.state == StateRole::Leader` guard at line 991 prevents it).

If the joint config includes nodes that don't yet exist in the cluster, this becomes fatal:
no new leader can be elected because joint consensus requires quorum from both old and new
configs, and the nonexistent nodes can never vote. The cluster is permanently stuck.

The code contains an explicit TODO: "it may never auto_leave if leader steps down before
enter joint is applied."

### Trigger Scenario

1. 3-node cluster {1, 2, 3}, node 1 is leader
2. Leader proposes joint config change: add nodes 4 and 5 (auto_leave=true)
3. Entry is committed by nodes 1, 2, 3 (original quorum)
4. Leader crashes before applying the entry
5. Nodes 2, 3 apply the enter-joint config change as followers
6. `commit_apply_internal` skips auto-leave check: `self.state == StateRole::Leader` is false
7. No leave-joint entry is proposed — cluster stays in joint consensus
8. Nodes 2, 3 try to elect a new leader, but joint consensus requires quorum from
   both {1,2,3} (old) and {1,2,3,4,5} (new). With node 1 crashed and nodes 4,5
   nonexistent, the new config's quorum (3/5) is unreachable.
9. No leader can be elected. Cluster is permanently stuck.

### Reproduction

Test: `harness/tests/integration_cases/test_raft.rs::test_bug_auto_leave_joint_stalls_on_leader_crash`

```
$ cargo test -p harness --test tests -- test_bug_auto_leave_joint_stalls_on_leader_crash
```

The test confirms two things:
1. **Follower auto-leave skipped**: After node 2 (follower) applies the enter-joint entry
   and calls `commit_apply`, the log does not grow — no leave-joint entry is proposed.
   The auto-leave check at raft.rs:991 (`self.state == StateRole::Leader`) prevents it.
2. **Cluster stuck**: No live node (2 or 3) can become leader because the joint config
   {1,2,3,4,5} requires 3 votes for quorum, but only nodes 2 and 3 are available.

### Impact

The cluster gets stuck in joint consensus, requiring manual intervention to force a config
change. This is a liveness issue; safety is not affected.

Note: if the joint config only involves existing nodes, the new leader's conservative
`pending_conf_index = last_index` in `become_leader()` (raft.rs:1267) allows auto-leave
to trigger when the noop entry is applied. The bug is most severe when the joint config
includes nodes that haven't joined the cluster yet.

MC tested this scenario (MC_hunt_confchange.cfg, 126M states) and did not find a safety
violation, confirming the issue is liveness-only.

### Recommendation

A follower should also be able to trigger auto-leave when applying the enter-joint entry,
or a new leader should proactively scan committed entries to detect pending auto-leave.

---

## Findings Classified as False Positive

### FP-1: `find_conflict_by_term` Edge Case at Index 0 (TV-2)

The theoretical concern is that `find_conflict_by_term` could return `(0, None)` when
decrementing past the compaction boundary, and the caller at `raft.rs:2566-2569` would
`fatal!` on `None`. However, this requires ALL entries from `last_index` down to the
compaction boundary to have terms strictly greater than the leader's `log_term`, which
contradicts Raft's term progression guarantees: the leader's `log_term` for a specific
index is the term of the entry at that index in the leader's log, and the follower's
entries at lower indices should have terms <= the compaction snapshot's term.

Additionally, the `hint_index` is `min(m.index, self.raft_log.last_index())`, which is
bounded by the follower's log. The function would find a matching entry at or near the
snapshot boundary. **Not a practical bug.**

### FP-2: `applied_index_upper_bound` Overflow (TV-3)

The addition `self.persisted + self.max_apply_unpersisted_log_limit` at `raft_log.rs:463`
could overflow u64 in release mode. However, `max_apply_unpersisted_log_limit` defaults to
0 and is a configuration parameter that would never realistically be set to values
approaching u64::MAX. The `persisted` index is a realistic log position. This is a
defensive coding concern, not a reachable bug.

### FP-3: Code-Review-Only Findings (CR-1, CR-2, CR-3)

- CR-1: `INVALID_INDEX` vs `INVALID_ID` (both = 0) — cosmetic
- CR-2: Untested assertion in `restore()` — dead code concern
- CR-3: Debug panic code in production apply.rs — operational concern

These are style/hygiene issues with no correctness impact.

---

## Model Checking Results Summary

The TLA+ spec modeled 4 of 5 identified bug families (Leader Lease, Election Safety,
Configuration Change, Async Persistence). Model checking explored:

| Config | States | Invariants | Result |
|--------|--------|-----------|--------|
| MC.cfg (structural) | 1.04B+ | 7 invariants | PASS |
| MC_hunt_election.cfg | 140M | ElectionSafety, PreVoteSafety | PASS |
| MC_hunt_lease.cfg | 129M | LeaseLinearizability, NoStaleReadAfterTransfer | PASS |
| MC_hunt_confchange.cfg | 126M | CommitByVoteSafety, ConfChangeSafety | PASS |
| MC_hunt_persist.cfg | 136M | AsyncPersistSafety, CrashRecoverySafety | PASS |

**All safety invariants hold.** The confirmed bugs are liveness/availability issues, which
are inherently harder to catch with bounded model checking. The priority interaction bugs
(#1, #2) involve the priority extension which is non-standard Raft — the base protocol's
safety guarantees remain intact.
