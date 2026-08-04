# Brief Coverage Self-Audit

Input brief: `../modeling-brief.md`

This audit maps modeling brief §2, §5, and §6.1 to the generated model-checking artifacts. It was filled after reading the actual `MC*.cfg` files in this directory.

## Scenario Coverage

| Brief §2 scenario | Primary hunt cfg | Target invariant(s) enabled | Notes |
|---|---|---|---|
| Scenario 1: In-flight append composition across leader change | `MC_hunt_scenario1.cfg` | `AppendSuccessReflectsLog`, plus `LogMatching`, `LeaderCompleteness` | Covers same-start append composition through `ServerImplUtils_NavigableIndices_append_ComposeExisting`. |
| Scenario 2: Term, role, and metadata persistence are non-atomic | `MC_hunt_scenario2.cfg` | `PersistedTermBeforeAccept`, `StepDownTermNotLost`, `ElectionSafety` | Covers one-shot persist failure and duplicate step-down event coalescing. |
| Scenario 3: Snapshot, purge, restart, and configuration frontier | `MC_hunt_scenario3.cfg` | `SnapshotLogContinuity`, plus `LogMatching`, `LeaderCompleteness`, `StateMachineSafety` | Covers snapshot notification/chunk finalization, purge, restart, and config frontier carried by snapshot. |
| Scenario 4: Joint membership, staged catch-up, and listener role transition | `MC_hunt_scenario4.cfg` | `ConfigEntryBeforeCaughtUp`, plus `ElectionSafety`, `LeaderCompleteness` | Covers staged catch-up, stale progress, old/new config application, stable new config replication, and listener promotion. |
| Scenario 5: Client-visible commit, read-index, and delayed AppendEntries replies | `MC_hunt_scenario5.cfg` | `LinearizableReadIndex`, plus `StateMachineSafety` | Scenario 5 has no §6.1 finding, but its safety invariant is still enabled in a dedicated hunt cfg. |
| Scenario 6: gRPC appender progress under reconnect, timeout, and stream reset | `MC_hunt_scenario6.cfg` | `ProgressBounds`, `AppendSuccessReflectsLog` | Covers pending timeout/reset and old-stream success replies that update leader-side follower progress. |

## Invariant Coverage

| Brief §5 invariant | Type | Defined in | Wired in `MC.tla` | Enabled in cfg |
|---|---|---|---|---|
| `ElectionSafety` | Safety | `base.tla` | inherited by `MC.tla` | `MC.cfg`, `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario4.cfg` |
| `LogMatching` | Safety | `base.tla` | inherited by `MC.tla` | `MC.cfg`, `MC_hunt_scenario1.cfg`, `MC_hunt_scenario3.cfg` |
| `LeaderCompleteness` | Safety | `base.tla` | inherited by `MC.tla` | `MC.cfg`, `MC_hunt_scenario1.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg` |
| `StateMachineSafety` | Safety | `base.tla` | inherited by `MC.tla` | `MC.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario5.cfg` |
| `AppendSuccessReflectsLog` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario1.cfg`, `MC_hunt_scenario6.cfg` |
| `PersistedTermBeforeAccept` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario2.cfg` |
| `StepDownTermNotLost` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario2.cfg` |
| `SnapshotLogContinuity` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario3.cfg` |
| `ConfigEntryBeforeCaughtUp` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario4.cfg` |
| `ListenerInitializationCompletes` | Liveness | Not encoded as a safety invariant | Not wired | Not enabled; Phase 2.5 safety audit excludes liveness, and the brief places the concrete listener issue as TV-RATIS-1. |
| `LinearizableReadIndex` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario5.cfg` |
| `ProgressBounds` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario6.cfg` |

`MC.cfg` lists all scenario invariants as commented-out convergence checks; every safety invariant from brief §5 is enabled in at least one hunt cfg.

## Finding Coverage

| Brief §6.1 finding | Trigger mechanism | Expected invariant violation | Hunt cfg |
|---|---|---|---|
| MC-RATIS-1 | Higher-term leader sends conflicting entries while an old same-start append is in flight | `AppendSuccessReflectsLog`, `LogMatching`, `LeaderCompleteness` | `MC_hunt_scenario1.cfg` |
| MC-RATIS-2 | Higher-term AppendEntries persist failure, later same-term accept, restart into older durable term | `PersistedTermBeforeAccept`, `ElectionSafety` | `MC_hunt_scenario2.cfg` |
| MC-RATIS-3 | Multiple step-down events with different terms coalesced by event type | `StepDownTermNotLost`, `ElectionSafety` | `MC_hunt_scenario2.cfg` |
| MC-RATIS-4 | Leader carries uncommitted transitional configuration into startup/config handling | `ConfigEntryBeforeCaughtUp`, `LeaderCompleteness` | `MC_hunt_scenario4.cfg` |
| MC-RATIS-5 | Snapshot notification/reload, purge, leader change, and restart interleave around config/frontier | `SnapshotLogContinuity`, `ConfigEntryBeforeCaughtUp` | `MC_hunt_scenario3.cfg` and `MC_hunt_scenario4.cfg` |
| MC-RATIS-6 | Reconnect, timeout, and delayed replies move progress beyond follower evidence | `ProgressBounds`, `AppendSuccessReflectsLog` | `MC_hunt_scenario6.cfg` |

## Gaps / Scope Notes

- `ListenerInitializationCompletes` is a liveness property and is not enabled in hunt cfgs; the brief's concrete listener concern is TV-RATIS-1 and should be validated by integration tests.
- `leaderHeartbeatCheck=false` is an unsafe configuration caveat in brief §6.3, not a default safety bug; `Trace.cfg` and MC cfgs use `InitialLeaderHeartbeatCheck = TRUE`.
- gRPC flow-control/backpressure, metrics, examples, shell, log-service, and alternate transports are intentionally absent per brief §3.2 and the target-specific out-of-scope list.
