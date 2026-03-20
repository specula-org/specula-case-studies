# Confirmed Bug Report — Hazelcast CP Subsystem (Raft)

## Summary

- Total findings reviewed: 13
  - MC-checkable (MC-1 through MC-7): 7
  - Test-verifiable (TV-1 through TV-3): 3
  - Code-review-only (CR-1 through CR-3): 3
- Confirmed: 2 (0 reproduced, 2 code-audit only)
- False positives: 4
- Not applicable: 7 (MC-verified safe: 7, defensive/cleanup: 0)

## Confirmed Bugs

### Bug 1: Leadership Transfer Election Retry Loses Disruptive Flag (TV-1)

- **Source**: Code Review (modeling-brief.md §Family 4)
- **Status**: CONFIRMED (code audit)
- **Severity**: Medium (liveness only, not safety)
- **Location**: `impl/task/LeaderElectionTimeoutTask.java:40`

**Description**:
When a leadership transfer is initiated, the target node starts a *disruptive* election
(`TriggerLeaderElectionHandlerTask.java:81` passes `disruptive=true` to `LeaderElectionTask`).
A disruptive election bypasses leader stickiness, allowing the target to win even though
other followers still see the old leader as alive.

However, if this first election attempt times out (e.g., due to a split vote),
`LeaderElectionTimeoutTask.innerRun()` retries by creating a new `LeaderElectionTask`
with `disruptive=false` hardcoded at line 40:

```java
new LeaderElectionTask(raftNode, false).run();
```

The retry election no longer bypasses leader stickiness. Other followers that still have
an active heartbeat from the old leader will reject the vote request, causing the
leadership transfer to fail unnecessarily.

**Trigger scenario**:
1. Leader L initiates transfer to target T in a 5-node cluster
2. L sends `TriggerLeaderElection` to T; T starts disruptive election at term N+1
3. T's `VoteRequest` reaches only 1 of 3 other nodes (partial network issue) — split vote
4. Election times out → `LeaderElectionTimeoutTask` fires
5. T retries with `disruptive=false` at term N+2
6. Remaining followers still see L as alive (recent heartbeats), reject T's vote
7. Transfer fails; L eventually times out the transfer and gives up

**Why not reproduced**:
This is a deterministic code path — the `false` literal at line 40 is conclusive evidence.
Reproducing through the cluster test harness would require precise timing control over
the randomized election timeout and network partitioning, adding complexity without
resolving any uncertainty. The root cause is clear: the `disruptive` flag should be
propagated from the original `LeaderElectionTask` to the timeout retry.

**Recommendation**:
`LeaderElectionTimeoutTask` should store and propagate the `disruptive` flag from its
parent `LeaderElectionTask`, e.g.:

```java
// In LeaderElectionTask.scheduleLeaderElectionTimeout():
raftNode.schedule(new LeaderElectionTimeoutTask(raftNode, disruptive), ...);

// In LeaderElectionTimeoutTask.innerRun():
new LeaderElectionTask(raftNode, this.disruptive).run();
```

---

### Bug 2: FollowerState Backoff Power Integer Overflow (TV-2)

- **Source**: Code Review (modeling-brief.md §6.2)
- **Status**: CONFIRMED (code audit)
- **Severity**: Low (performance anomaly in edge case)
- **Location**: `impl/state/FollowerState.java:114`

**Description**:
`FollowerState.nextBackoffRound()` uses an unbounded `int` counter `nextBackoffPower`:

```java
private int nextBackoffRound() {
    return min(max((1 << (nextBackoffPower++)) * MIN_BACKOFF_ROUNDS, MIN_BACKOFF_ROUNDS), MAX_BACKOFF_ROUND);
}
```

While the result is clamped to `[MIN_BACKOFF_ROUNDS=4, MAX_BACKOFF_ROUND=20]`,
`nextBackoffPower` increments on every call without bound. When it reaches 30:

- `1 << 30` = 1,073,741,824
- `1,073,741,824 * 4` overflows Java `int` → 0
- `max(0, 4)` = 4, `min(4, 20)` = **4** (should be 20)

The backoff drops from the maximum (20 rounds ≈ 2s) to the minimum (4 rounds ≈ 400ms),
causing the leader to retry append requests to an unreachable follower ~5x more frequently.
The same overflow occurs at `nextBackoffPower=31`, and the pattern repeats cyclically
(Java `int` shift wraps modulo 32).

**Trigger scenario**:
1. 5-node cluster with 2 followers unreachable (partial partition)
2. Leader continues operating with the 3-node majority
3. For the 2 unreachable followers, `nextBackoffPower` increments on each failed
   append request cycle
4. After ~30 cycles (≈57 seconds under default config), backoff overflows
5. Leader retries to dead followers every 400ms instead of every 2000ms

Under default configuration (`maxMissedLeaderHeartbeatCount=5`,
`heartbeatPeriodInMillis=5000`), the leader would only self-demote if the *majority*
stops responding (threshold: 25s). In a partial partition where a minority is
unreachable but the majority is fine, the leader stays active indefinitely, allowing
`nextBackoffPower` to reach the overflow threshold.

**Why not reproduced**:
This is a pure arithmetic issue — the overflow behavior of `(1 << 30) * 4` in Java `int`
is deterministic. The practical impact (slightly more frequent retries to unreachable
followers) is observable but minimal. The trigger requires sustained partial partition
(~57 seconds), which is feasible but the anomalous behavior is difficult to distinguish
from normal retry patterns without instrumenting the backoff internals.

**Recommendation**:
Cap `nextBackoffPower` to prevent overflow:

```java
private int nextBackoffRound() {
    int power = Math.min(nextBackoffPower++, 30);
    return min(max((1 << power) * MIN_BACKOFF_ROUNDS, MIN_BACKOFF_ROUNDS), MAX_BACKOFF_ROUND);
}
```

Or, since the result is clamped to `MAX_BACKOFF_ROUND` after `nextBackoffPower >= 3`,
simply stop incrementing once the cap is reached.

---

## False Positives

### FP-1: commitEntries Ordering Depends on Status (CR-1)

- **Location**: `RaftNodeImpl.java:1299-1311`
- **Finding**: When `status != ACTIVE` (i.e., `UPDATING_GROUP_MEMBER_LIST`), queries run
  before `applyLogEntries()`, reversing the normal order.
- **Why false positive**: This is intentional. When a membership change entry is being committed,
  `applyLogEntries()` may call `setStatus(STEPPED_DOWN)`, which would prevent pending queries
  from completing. Running queries first ensures they execute before the node potentially steps
  down. The queries were submitted when the commit index was at or below the old value, so the
  state machine has already been applied to at least the query's `queryCommitIndex`.

### FP-2: groupDestroyed() Bypasses setStatus() Guard (CR-2)

- **Location**: `RaftNodeImpl.java:485-493`
- **Finding**: `groupDestroyed()` sets `status = TERMINATED` directly instead of using
  `setStatus()`, allowing the `STEPPED_DOWN → TERMINATED` transition that `setStatus()` would
  reject.
- **Why false positive**: This bypass is intentional. `groupDestroyed()` handles the case where
  a Raft group is destroyed (via committed `DestroyRaftGroupCmd`). A node that has already
  stepped down may still need to process this destruction. The method correctly:
  1. Guards against double-close (`if (status != TERMINATED)`)
  2. Closes the state store before setting the status
  3. Uses the appropriate `onGroupDestroyed()` callback (not `onNodeStatusChange()`)

### FP-3: replicateMembershipChange() Without CommitIndex Skips CAS (CR-3)

- **Location**: `RaftNodeImpl.java:429-431`, `MembershipChangeTask.java:150-164`
- **Finding**: The 2-arg overload `replicateMembershipChange(member, mode)` passes `null`
  for `groupMembersCommitIndex`, skipping the CAS safety check against concurrent membership
  changes.
- **Why false positive**: The 2-arg overload is **only called from test code** (verified by
  searching all callers: `MembershipChangeTest.java`, `PersistenceTest.java`,
  `SnapshotTest.java`, `LeadershipTransferTest.java`). No production code calls this overload.
  Furthermore, the single-change-at-a-time invariant is enforced at a different level:
  `canReplicateNewEntry()` (line 534) rejects `RaftGroupCmd` operations when
  `status == UPDATING_GROUP_MEMBER_LIST`, and `updateGroupMembers()` (line 497) asserts
  `committedGroupMembers == lastGroupMembers` as defense-in-depth.

### FP-4: Assert-Only Term Check in AppendSuccessResponseHandlerTask (MC-1)

- **Location**: `handler/AppendSuccessResponseHandlerTask.java:65`
- **Finding**: The term check `resp.term() <= state.term()` is an `assert` (disabled in
  production), unlike the runtime `if` check in `AppendFailureResponseHandlerTask.java:64`.
- **Why false positive**: Confirmed by both code audit and model checking (14M states,
  `AssertsDisabled=TRUE`). The condition `resp.term() > state.term()` is unreachable in
  practice: a follower with a higher term would reject the AppendEntries RPC at
  `AppendRequestHandlerTask.java:73` (`req.term() < state.term()` → failure response), so
  a success response with a higher term than the leader's cannot be generated. The
  `AppendSuccessResponse` carries `state.term()` at the time of processing (line 211), which
  equals the request's term after the follower's term update at line 88. This assert is
  defense-in-depth guarding an impossible condition.

## MC-Verified Safe Findings (No Violation)

The following 7 findings from the modeling brief were systematically tested by TLC model
checking across ~1.6 billion states. All invariants held with 0 violations.

| ID | Finding | Config | States | Result |
|----|---------|--------|--------|--------|
| MC-1 | Assert-only term check (with asserts disabled) | MC_hunt_vote_safety.cfg | 14M | ElectionSafety, LeaderCompleteness, LogMatching all hold |
| MC-2 | Pre-applied membership + leader crash | MC_hunt_membership.cfg | 297M | MembershipRevertConsistency holds |
| MC-3 | Slow follower batch membership changes | MC_hunt_membership.cfg | 297M | SingleMembershipChange holds |
| MC-4 | Linearizable read + membership change interaction | MC_hunt_linearizable_read.cfg | 609M | QuerySafety holds |
| MC-5 | Pre-vote / real election state leak | MC_hunt_prevote.cfg | 668M | PreVoteNoTermInflation holds |
| MC-6 | Leader stickiness vs PreVote interaction | MC_hunt_prevote.cfg | 668M | ElectionSafety holds |
| MC-7 | Stale leader detection window | MC_hunt_vote_safety.cfg | 14M | No violation |

## Not Reviewed

| ID | Finding | Reason |
|----|---------|--------|
| TV-3 | Flow control compatibility shim (`TODO RU_COMPAT_5_3`) | Cleanup TODO, not a bug. Backwards-compatibility code that returns `true` when `flowControlSequenceNumber == -1`. |
