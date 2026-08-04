# Bug Report - ratis-grpc

## Summary

- Scenarios tested: 6 focused hunt configs plus main structural MC.
- Current bugs found: 1 model-checking finding.
- Repair requests consumed: RR-001 / MC-2 was repaired as a spec artifact.
- Trace validation: raw TLC passed all 3 harness traces with `Trace.tla` and `../harness/Trace.harness.cfg`.
- Syntax: `Trace.tla` and `MC.tla` passed SANY after repair; VAV reported no issues for `base.tla`.
- Main MC: `MC.cfg` reached the 30m resource timeout with no structural invariant violation reported before timeout.
- Configs run: `MC_hunt_rg1_stream_reset.cfg`, `MC_hunt_rg2_timeout_late_reply.cfg`, `MC_hunt_rg3_snapshot_race.cfg`, `MC_hunt_rg4_staging_restart.cfg`, `MC_hunt_rg5_inconsistency_boundary.cfg`, `MC_hunt_rg6_backpressure.cfg`.

## Bug 1: Snapshot progress can be overwritten by a stale INCONSISTENCY reply

- **Scenario**: RG3 snapshot race / old append reply after snapshot progress.
- **Severity**: Medium.
- **Invariant violated**: `SnapshotAppendBoundary`.
- **Config**: `MC_hunt_rg3_snapshot_race.cfg`.
- **Counterexample**: 9 states, `spec/output/repair-final-MC_hunt_rg3_snapshot_race-20260803-223000.out`.

### Trace Summary

1. The leader sends two AppendEntries requests to `F1`: one ending at index 1 and one ending at index 2.
2. Before snapshot progress is recorded, the follower generates an `INCONSISTENCY` reply for the second request with `replyNextIndex = 0`.
3. The leader compacts its log so `leaderStartIndex = 3`, then triggers and sends snapshot installation for `F1`.
4. `SnapshotInstalled(F1, 1)` records snapshot/match proof at index 1 and raises leader-side `nextIndex[F1]` to 2.
5. The old inconsistency reply is then processed by the normal INCONSISTENCY receive branch.
6. `getNextIndexForInconsistency(requestFirstIndex = 2, replyNextIndex = 0)` returns 0, and `setNextIndex(0)` overwrites the snapshot boundary.

Final state: `snapshotIndex[F1] = 1`, `matchIndex[F1] = 1`, but `nextIndex[F1] = 0`.

### Root Cause

`AppendLogResponseHandler.onNextImpl` computes whether a reply is old after snapshot, but the `INCONSISTENCY` branch still calls `updateNextIndex(getNextIndexForInconsistency(...))` before emitting the trace event.  `getNextIndexForInconsistency` intentionally may return a value below the current match/snapshot frontier when `requestFirstIndex == matchIndex + 1`.  `updateNextIndex` then clears pending requests and calls `FollowerInfoImpl.setNextIndex`, which unconditionally accepts non-negative regressions.  A reply generated before snapshot progress but received after `SnapshotInstalled` can therefore move `nextIndex` below the proven snapshot boundary.

### Affected Code

- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:561`: `onNextImpl` computes `oldAfterSnapshot`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:586`: INCONSISTENCY branch handles the reply.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:591`: derives `requestFirstIndex`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:592`: updates nextIndex from `getNextIndexForInconsistency`.
- `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:636`: clears pending and sets nextIndex.
- `ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderBase.java:177`: helper may return `requestFirstIndex - 1`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/FollowerInfoImpl.java:129`: `setNextIndex` accepts any non-negative new value.

### Recommendation

Guard the INCONSISTENCY update against known snapshot/match progress before calling `setNextIndex`, or clamp the computed next index to the current proven follower frontier when the reply predates a snapshot/match update.

## Consumed Repair Request

RR-001 / MC-2 (`RestartPreservesUsefulProgress`) was consumed as a spec artifact.  The implementation evidence shows `LeaderStateImpl.restart` re-adds a replacement sender only when `getPeer(info.getId())` finds the peer in the current configuration; staging-only peers are removed but not recreated through `addAndStartSenders`.  The model now constrains `RestartAppender` to the existing-config replacement branch and keeps the staging-only behavior out of that reset path.

Request-scoped validation for `MC_hunt_rg4_staging_restart.cfg` completed with no errors at `spec/output/repair-MC_hunt_rg4_staging_restart-20260803-220000.out` after 25,485,014 generated states and 4,169,309 distinct states.

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Main structural safety | `MC.cfg` | 904,019,369 generated; 177,227,068 distinct; 161,612,251 queued at last progress | Resource-limited timeout after 30m, no violation before timeout |
| RG1 stream reset and stale inconsistency reply | `MC_hunt_rg1_stream_reset.cfg` | 20,851 generated; 5,492 distinct | No violation |
| RG2 timeout removal followed by late reply | `MC_hunt_rg2_timeout_late_reply.cfg` | 1,680,157 generated; 372,945 distinct | No violation |
| RG4 staging restart / liveness | `MC_hunt_rg4_staging_restart.cfg` | 25,485,014 generated; 4,169,309 distinct | No violation after repair |
| RG5 inconsistency helper boundary | `MC_hunt_rg5_inconsistency_boundary.cfg` | 2,242 generated; 829 distinct | No violation |
| RG6 cancellation/backpressure proof | `MC_hunt_rg6_backpressure.cfg` | 17,064 generated; 2,456 distinct | No violation |

## Spec Adjustments During Hunting

- Case B: weakened `NextBeyondMatch`, `StaleReplyNoProgressRegression`, and `PendingResetDoesNotLoseSafety` to match Ratis' legal inconsistency backoff semantics.
- Case A: constrained newly generated follower INCONSISTENCY replies after a proven snapshot boundary to match `RaftServerImpl.checkInconsistentAppendEntries`.
- Case A: made `usefulProgressBeforeRestart` staging-lifetime-specific so ordinary existing-peer restarts do not retroactively affect staging invariants.
- Case B: narrowed snapshot retry and restart-useful-progress invariants so failed snapshot attempts are not treated as durable catch-up proof.

## Spec Adjustments During Repair

- Scoped `RestartAppender` to peers in the current configuration (`peerMode = Existing`) so staging-only restart does not model replacement/reset behavior that the implementation does not execute.
- Required snapshot terminal replies to have an active snapshot stream/request and a monotonic installed snapshot frontier.
- Added follower identity to append reply records and cleared queued replies when reusing an abstract follower slot for `AddStagingPeer`.
- Blocked data append while snapshot installation is active and required the staging snapshot-attempt path before staging data append.
- Removed `SYMMETRY` and `VIEW` from the RG4 liveness hunt config.
