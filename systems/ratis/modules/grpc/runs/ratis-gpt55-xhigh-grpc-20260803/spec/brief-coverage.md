# Brief Coverage Self-Audit

Source brief: `../modeling-brief.md`.

## Category

The target is Category A: distributed message passing with local leader-side concurrency.  The spec uses message/reply state plus explicit `GrpcLogAppender` and `FollowerInfoImpl` progress records rather than a Category B thread-PC model.

## Scenario Coverage

| Brief §2 scenario | Modeled mechanisms | Targeting cfg |
| --- | --- | --- |
| Scenario 1: Stream reconnect, late replies, pending reset | `streamEpoch`, `pending`, `sentRequests`, timeout removal, error/complete reset, late success/inconsistency reply handling, heartbeat/data split | `MC_hunt_rg1_stream_reset.cfg`, `MC_hunt_rg2_timeout_late_reply.cfg`, `MC_hunt_rg5_inconsistency_boundary.cfg` |
| Scenario 2: AppendEntries and snapshot transition | leader log compaction boundary, `TriggerSnapshot`, chunk send, follower snapshot-in-progress inconsistency, snapshot installed/already-installed/unavailable/expired, old append reply after snapshot | `MC_hunt_rg3_snapshot_race.cfg` |
| Scenario 3: Bootstrap, catch-up, configuration staging | staging peer creation, appender restart, successful append for staging peer, snapshot attempt, `CheckProgress`, old-new configuration apply | `MC_hunt_rg4_staging_restart.cfg` |
| Scenario 4: Cancellation, backpressure, resource boundaries | small abstraction only: stream readiness, cancellation, snapshot outstanding chunk bound, resource-exhausted terminal event | `MC_hunt_rg6_backpressure.cfg` |

## Invariant Coverage

| Brief §5 invariant/property | Defined in | Enabled in cfg |
| --- | --- | --- |
| `NextBeyondMatch` | `base.tla` | `MC_hunt_rg1_stream_reset.cfg`, `MC_hunt_rg2_timeout_late_reply.cfg`, `MC_hunt_rg5_inconsistency_boundary.cfg` |
| `MatchOnlyFromProof` | `base.tla` | `MC_hunt_rg2_timeout_late_reply.cfg`, `Trace.cfg` |
| `StaleReplyNoProgressRegression` | `base.tla` | `MC_hunt_rg1_stream_reset.cfg`, `MC_hunt_rg2_timeout_late_reply.cfg` |
| `SnapshotAppendBoundary` | `base.tla` | `MC_hunt_rg3_snapshot_race.cfg` |
| `SnapshotProgressMonotonic` | `base.tla` | `MC_hunt_rg3_snapshot_race.cfg`, `Trace.cfg` |
| `NoCommitFromHeartbeatTail` | `base.tla` | `MC_hunt_rg2_timeout_late_reply.cfg` |
| `NoPermanentStaging` | `base.tla` temporal property | `MC_hunt_rg4_staging_restart.cfg` |
| `PendingResetDoesNotLoseSafety` | `base.tla` | `MC_hunt_rg1_stream_reset.cfg` |
| `AppendDuringSnapshotDoesNotCommitUnprovenEntries` | `base.tla` | `MC_hunt_rg3_snapshot_race.cfg` |
| `SnapshotRetryPreservesCatchup` | `base.tla` | `MC_hunt_rg3_snapshot_race.cfg`, `MC_hunt_rg4_staging_restart.cfg` |
| `NoPrematureStagingCommit` | `base.tla` | `MC_hunt_rg4_staging_restart.cfg` |
| `RestartPreservesUsefulProgress` | `base.tla` | `MC_hunt_rg4_staging_restart.cfg` |
| `CancelledStreamNoCommitProof` | `base.tla` | `MC_hunt_rg6_backpressure.cfg` |

`MC.cfg` intentionally enables only convergence/structural checks: `MCTypeOK`, `MCStructuralProgressBounds`, and `CommitOnlyFromQuorumProof`.  Scenario invariants are commented out there and enabled in hunt cfgs.

## Model-Checkable Finding Coverage

| Brief §6.1 finding | Trigger mechanism in spec | Expected violated invariant/property | Hunt cfg |
| --- | --- | --- | --- |
| `MC-RG-1`: Stream reset and stale inconsistency reply | `SendAppendData` -> `StreamErrorReset` / `Reconnect` -> late `FollowerAppendInconsistency` -> `ReceiveInconsistency*` | `NextBeyondMatch`, `StaleReplyNoProgressRegression`, `PendingResetDoesNotLoseSafety` | `MC_hunt_rg1_stream_reset.cfg` |
| `MC-RG-2`: Timeout removal followed by late success or inconsistency | `TimeoutAppend` removes pending while `sentRequests` can still generate SUCCESS/INCONSISTENCY replies | `MatchOnlyFromProof`, `NextBeyondMatch`, `StaleReplyNoProgressRegression`, `NoCommitFromHeartbeatTail` | `MC_hunt_rg2_timeout_late_reply.cfg` |
| `MC-RG-3`: Snapshot completion racing with old append replies | `TriggerSnapshot` / `SnapshotInstalled` followed by `OldAppendReplyAfterSnapshot` | `SnapshotAppendBoundary`, `SnapshotProgressMonotonic`, `AppendDuringSnapshotDoesNotCommitUnprovenEntries` | `MC_hunt_rg3_snapshot_race.cfg` |
| `MC-RG-4`: Bootstrap restart and staging liveness | `AddStagingPeer`, progress proof, `RestartAppender`, `CheckProgress` under weak fairness | `NoPermanentStaging`, `NoPrematureStagingCommit`, `RestartPreservesUsefulProgress` | `MC_hunt_rg4_staging_restart.cfg` |
| `MC-RG-5`: Inconsistency helper boundary at current match frontier | request with `firstIndex = matchIndex + 1`, follower `INCONSISTENCY`, `GetNextIndexForInconsistency` helper | `NextBeyondMatch` | `MC_hunt_rg5_inconsistency_boundary.cfg` |

## Explicit Non-Coverage

- Elections, leases, read-index proof, Netty internals, byte queues, direct memory, metrics, examples, shell, and log service are out of scope per the brief.
- Scenario 4 is represented only as a compact safety abstraction because the brief classifies it as low priority for TLA+ safety modeling and recommends test/code-review handling for resource details.
