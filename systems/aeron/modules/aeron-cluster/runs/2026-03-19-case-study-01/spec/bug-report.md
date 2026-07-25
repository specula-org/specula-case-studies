# Bug Report — Aeron Cluster

## Summary

- Bug families tested: 6
- Bugs found: 1
- Configs run: MC_hunt_election.cfg, MC_hunt_commit.cfg, MC_hunt_truncation.cfg, MC_hunt_quorum.cfg, MC_hunt_snapshot.cfg, MC_hunt_crash.cfg

## Bug 1: Stale Canvass Message Causes Quorum Position Regression

- **Bug Family**: Family 1 — Commit Position Safety
- **Severity**: Medium
- **Invariant violated**: CommitBoundedByQuorum
- **Config**: MC_hunt_commit.cfg (also MC_hunt_quorum.cfg)
- **Counterexample**: 15 states (spec/output/MC_hunt_commit_r3.out)

### Trace Summary

1. **States 1–4**: s1 enters canvass, nominates with candidateTermId=1. s2 enters canvass.
2. **States 5–7**: s2 votes for s1 (via RequestVote). s2 also sends a canvass position message to s1 at this point (mlogPosition=0, reflecting s2's empty log). s1 becomes leader.
3. **State 8**: s1 appends a client request to its log (log length=1).
4. **States 9–10**: s2 receives NewLeadershipTerm, becomes follower. s2 replicates the entry from s1 (log length=1).
5. **States 11–12**: s2 sends AppendPositionUpdate (mlogPosition=1) to s1. s1 processes it, updating memberLogPosition[s1][s2]=1.
6. **State 13**: s1 advances commitPosition to 1 based on quorum (s1 at 1, s2 at 1 — quorum of 2 out of 3).
7. **State 14 (CRITICAL)**: s1 receives the **stale** CanvassPositionMsg from s2 (sent at step 2 with mlogPosition=0). HandleCanvassPosition calls `updateMemberLogPosition()` which **unconditionally overwrites** memberLogPosition[s1][s2] from 1 back to 0.
8. **State 15**: QuorumPosition(s1) now computes: s1=1 (own log), s2=0 (regressed), s3=0 → only 1 server at position ≥1 → quorum position = 0. But commitPosition[s1] = 1. **CommitBoundedByQuorum violated**: 1 > Min(0, 1) = 0.

### Root Cause

`ConsensusModuleAgent.updateMemberLogPosition()` (lines 1054–1060) performs an unconditional assignment:

```java
member
    .leadershipTermId(leadershipTermId)
    .logPosition(logPosition)
    .timeOfLastAppendPositionNs(clusterClock.timeNanos());
```

There is no `Math.max()` check to prevent position regression. When a stale `CanvassPositionMsg` (sent before the follower replicated entries) arrives after a more recent `AppendPositionUpdate`, the leader's tracked position for that follower regresses to the stale value.

This causes `quorumPosition()` (ClusterMember.java:867–895) to compute a value lower than the already-committed position, violating the invariant that commitPosition ≤ quorumPosition.

### Affected Code

- `ConsensusModuleAgent.java:1054-1060`: `updateMemberLogPosition()` — unconditional overwrite without max-check
- `ClusterMember.java:291-295`: `logPosition(long)` setter — simple assignment, no guard
- `Election.java:310`: `onCanvassPosition()` — calls updateMemberLogPosition with stale position
- `Election.java:412`: `onVote()` — same unconditional call (potentially affected)
- `Election.java:557`: `onAppendPosition()` — same unconditional call (potentially affected)

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

This ensures the leader's view of member positions is monotonically non-decreasing within a term, preventing stale messages from regressing quorum calculations.

### Impact Assessment

- **Safety impact**: Limited. commitPosition is monotonic (never decreases), and entries are durably replicated to a quorum before commit. Leader Completeness holds because the committed entries exist on a quorum.
- **Liveness impact**: The leader may temporarily compute a lower quorum position, delaying further commit advancement until fresh position updates arrive.
- **Operational impact**: Under normal operation, stale canvass messages are rare. The bug is most likely to manifest during election transitions when canvass and position update messages overlap.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 2: Election State Machine | MC_hunt_election.cfg | 104M | No violation (ElectionSafety, VoteUniqueness, LogMatching, CandidateTermNeverDecreases all hold) |
| Family 3: Log Truncation | MC_hunt_truncation.cfg | 115M | No violation (LeaderCompleteness, TruncationSafety, LogMatching all hold) |
| Family 5: Snapshot Divergence | MC_hunt_snapshot.cfg | 100M | No violation (SnapshotConsistency held; expected violation may require deeper state space or specific session-open sequences) |
| Family 6: Crash Recovery | MC_hunt_crash.cfg | 116M | No violation (VoteRecovery, VoteUniqueness, ElectionSafety, CandidateTermNeverDecreases all hold) |

## Spec Adjustments During Hunting

- **VoteUniqueness (Case A)**: Weakened to exclude self-votes. Two candidates CAN both self-vote at the same candidateTermId (independent term increment from same base). Fixed to check that no external voter grants "yes" to two different candidates for the same term.
- **CommitBoundedByQuorum (Case A)**: Added `memberActive[i]` guard. Leader becoming inactive after a valid commit should not retroactively invalidate the commit — past commits are durable.
