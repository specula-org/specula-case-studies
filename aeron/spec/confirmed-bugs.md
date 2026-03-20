# Confirmed Bug Report — Aeron Cluster

## Summary

- Total findings reviewed: 5
- Confirmed: 1 (0 independently reproduced, 1 code-audit confirmed with existing developer reproduction)
- False positives: 4
- Inconclusive: 0

### Findings overview

| # | Finding | Source | Verdict |
|---|---------|--------|---------|
| 1 | Stale canvass message causes quorum position regression | MC (CommitBoundedByQuorum violated, 15-state counterexample) | **CONFIRMED** (code audit + existing developer test) |
| 2 | `onTerminationPosition` missing leader sender verification | Code review (CR-1) | FALSE POSITIVE |
| 3 | `timeOfLastLeaderUpdateNs` premature reset for future terms | Code review (CR-2) | FALSE POSITIVE |
| 4 | `Election.onCommitPosition` skips `leadershipTermId` check | Code review (modeling-brief 6.1 MC-5) | FALSE POSITIVE |
| 5 | Silent message drops in ConsensusPublisher/LogPublisher | Code review (TV-1, TV-2) | Not a logic bug (robustness concern) |

---

## Bug 1: Quorum Position Regression via Missing Monotonicity Guard

- **Source**: MC (CommitBoundedByQuorum invariant, 15-state counterexample) + code review (Family 1)
- **Status**: CONFIRMED (code audit) — root cause verified; specific MC trigger not independently reproduced due to transport-layer FIFO guarantee; developer test reproduces the same symptom via a different trigger
- **Severity**: Medium (liveness impact; safety properly mitigated)
- **Location**: `ConsensusModuleAgent.java:1054-1060` (`updateMemberLogPosition`)

### Description

`ConsensusModuleAgent.updateMemberLogPosition()` performs an unconditional assignment of a member's tracked log position:

```java
void updateMemberLogPosition(final ClusterMember member, final long leadershipTermId, final long logPosition)
{
    member
        .leadershipTermId(leadershipTermId)
        .logPosition(logPosition)
        .timeOfLastAppendPositionNs(clusterClock.timeNanos());
}
```

There is no `Math.max()` guard to prevent position regression. This method is called from **5 sites**, all unconditional:

1. `Election.onCanvassPosition()` — line 310
2. `Election.onVote()` — line 412
3. `Election.onAppendPosition()` — line 557
4. `ConsensusModuleAgent.onCanvassPosition()` — line 877
5. `ConsensusModuleAgent.onAppendPosition()` — line 1048

When a member's tracked position regresses, `quorumPosition()` (`ClusterMember.java:867-895`) computes a value lower than the already-committed `commitPosition`, violating the invariant that `commitPosition <= quorumPosition`.

### MC Counterexample (15 states)

The model checker found this violation via stale canvass message delivery:
1. s2 enters canvass, sends canvass position (logPosition=0) to s1
2. s1 becomes leader, replicates entry to s2
3. s2 sends AppendPosition (logPosition=1); s1 updates tracking and commits at position 1
4. Stale canvass message arrives; s1 overwrites s2's tracked position from 1 back to 0
5. Quorum position = 0, but commitPosition = 1 — **CommitBoundedByQuorum violated**

### FIFO Analysis: MC Trigger vs Real System

The specific MC counterexample requires out-of-order message delivery from the same peer (canvass arriving after AppendPosition). In real Aeron:

- Each peer maintains a **single ExclusivePublication** to each other peer on the consensus channel
- Aeron guarantees **FIFO ordering within a publication/subscription pair**
- Canvass and AppendPosition messages from the same peer travel through the same publication
- Publications are persistent (not recreated during election transitions; only closed on module shutdown)

**Therefore, the MC counterexample's specific message ordering is NOT achievable in the real Aeron transport.** Messages from peer A to peer B are always delivered in send order.

### Existing Developer Reproduction

The developers are aware of quorum position regression and have an explicit test:

**`ClusterTest.shouldHandleQuorumPositionGoingBackwards`** (commit `ef0a5a7cf3`, Jan 2026):
- Creates a 3-node cluster with message loss injection
- Sends 100 messages (all replicated), then blocks the slow follower's log stream
- Sends 200 more messages (replicated only to fast follower)
- **Stops the fast follower** — quorum falls to slow follower's old position
- Verifies: "quorum position went backwards" error is logged
- Verifies: `commitPosition` does NOT regress (proposeMaxRelease guard)
- Verifies: followers' `notifiedCommitPosition` does NOT regress (max() guard)

This test confirms the symptom through a **different trigger** (member inactivity changing the active set) rather than stale messages. The root cause is the same: `quorumPosition()` can compute a value below `commitPosition`.

### Safety Mitigations

The system has three layers of defense that prevent safety violations:

1. **Leader side** (`ConsensusModuleAgent.java:2839`): `commitPosition.proposeMaxRelease(quorumPosition)` — MAX-CAS operation, commitPosition counter never decreases
2. **Follower side** (`ConsensusModuleAgent.java:1080`): `notifiedCommitPosition = max(notifiedCommitPosition, logPosition)` — followers ignore regressed commit positions
3. **Error detection** (`ConsensusModuleAgent.java:2830-2835`): explicit error logging when `quorumPosition < leaderCommitPosition`

### Impact

- **Safety**: None. Committed entries remain durable on a quorum. Leader and follower commit positions are monotonic.
- **Liveness**: Temporary stall in commit advancement. The leader won't advance `commitPosition` until fresh AppendPosition updates restore `quorumPosition` above the current `commitPosition`. Duration depends on heartbeat interval.
- **Operational**: The leader logs an error ("quorum position went backwards"), which may trigger alerts. The `publishCommitPosition` call at line 2837 sends the regressed value to followers, but followers ignore it via `max()`.

### Recommendation

Add a monotonicity guard to `updateMemberLogPosition`:

```java
void updateMemberLogPosition(final ClusterMember member, final long leadershipTermId, final long logPosition)
{
    if (leadershipTermId > member.leadershipTermId() ||
        (leadershipTermId == member.leadershipTermId() && logPosition > member.logPosition()))
    {
        member
            .leadershipTermId(leadershipTermId)
            .logPosition(logPosition)
            .timeOfLastAppendPositionNs(clusterClock.timeNanos());
    }
}
```

This eliminates the root cause, removes the need for the downstream error detection at line 2830, and prevents the transient liveness stall.

---

## False Positives

### Finding 2: `onTerminationPosition` Missing Leader Sender Verification

- **Source**: Code review (CR-1)
- **Status**: FALSE POSITIVE
- **Location**: `ConsensusModuleAgent.java:1137-1147`

**Analysis**: The `TerminationPosition` message format does not include a sender ID field (`ConsensusPublisher.java:383-409`). The handler checks `leadershipTermId == this.leadershipTermId && Cluster.Role.FOLLOWER == role`, which provides sufficient protection:
- Only the leader calls `ClusterTermination.terminationPosition()` (invoked from SHUTDOWN/ABORT handlers)
- The term check ensures the message is from the current term
- Non-leaders do not send TerminationPosition messages in non-Byzantine scenarios
- All cluster members communicate over dedicated consensus channels; external actors cannot inject messages

**Safeguard**: `leadershipTermId == this.leadershipTermId` check combined with the fact that only the leader code path sends this message type.

### Finding 3: `timeOfLastLeaderUpdateNs` Premature Reset

- **Source**: Code review (CR-2)
- **Status**: FALSE POSITIVE
- **Location**: `ConsensusModuleAgent.java:1067-1070`

**Analysis**: The `onCommitPosition` handler resets `timeOfLastLeaderUpdateNs` for any commit position with `leadershipTermId >= this.leadershipTermId`. The concern is that a non-leader's message could delay failure detection. However:
- Only the leader sends CommitPosition messages (via `publishCommitPosition` at line 2837)
- Followers never send CommitPosition
- For `leadershipTermId > this.leadershipTermId`, the code immediately enters a new election at lines 1084-1098, making the timer reset irrelevant
- For `leadershipTermId == this.leadershipTermId`, the actual commit logic at line 1078 additionally checks `leaderMember.id() == leaderMemberId`

**Safeguard**: Only the leader sends CommitPosition; the timer reset is always followed by appropriate election or commit handling.

### Finding 4: `Election.onCommitPosition` Skips `leadershipTermId` Check

- **Source**: Code review / modeling-brief MC-5
- **Status**: FALSE POSITIVE (intentional backward-compatibility)
- **Location**: `Election.java:571-593`

**Analysis**: The comment at lines 571-573 explicitly explains this is a backward-compatibility workaround: "prior to fixes the leader was sending wrong `leadershipTermId` value in the `CommitPosition` message." The handler checks `leaderMember.id() == leaderMemberId` (line 574) to ensure only the known leader's messages are accepted, and uses `max(notifiedCommitPosition, logPosition)` (line 576) to prevent regression.

**Safeguard**: Leader ID check + monotonicity guard on `notifiedCommitPosition`.

### Finding 5: Silent Message Drops

- **Source**: Code review (TV-1, TV-2)
- **Status**: Not a logic bug
- **Location**: `LogPublisher.java:47` (3 SEND_ATTEMPTS), `ConsensusPublisher.java:60-63` (null publication check)

**Analysis**: These are intentional back-pressure handling mechanisms in Aeron's non-blocking architecture. Silent drops are expected under back-pressure and the system recovers through heartbeat-driven retransmission. This is a robustness/observability concern, not a safety or correctness bug.

---

## Methodology Notes

### Code Audit Approach
- Read all 5 call sites of `updateMemberLogPosition` and traced the call chains
- Verified the absence of any monotonicity guard at any level (caller or callee)
- Confirmed the `quorumPosition()` calculation uses the tracked positions directly
- Traced the downstream safety mitigations (proposeMaxRelease, follower max())

### FIFO Analysis
- Investigated Aeron's consensus publication architecture (ExclusivePublication per peer)
- Confirmed FIFO ordering within a single publication/subscription pair
- Verified publications are persistent across election transitions (not recreated)
- Concluded: the MC counterexample's specific message ordering is not achievable in real Aeron

### Reproduction Assessment
- The developer's own test `shouldHandleQuorumPositionGoingBackwards` (commit `ef0a5a7cf3`) reproduces quorum position regression via member inactivity (different trigger, same root cause)
- Independent reproduction of the MC-specific trigger (stale canvass message) was not attempted because FIFO analysis shows it is not achievable in the real transport
- The root cause (no monotonicity guard) is indisputably confirmed by code inspection
