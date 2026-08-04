# Brief Coverage Self-Audit

This audit maps the modeling brief's §2 scenarios, §5 safety invariants, and §6.1 model-checkable findings to the generated model-checking artifacts. It was filled by reading the generated `MC*.cfg` files.

## §2 Scenario Coverage

| Brief scenario | Mechanism covered in spec | Target hunt cfg | Enabled target invariants |
|---|---|---|---|
| Scenario 1: Durable Commit Boundary vs Async Log Flush | Cache append, write worker, flush start, async flush completion/failure, commit advancement, metadata append, crash/recovery | `MC_hunt_scenario1.cfg` | `CommittedImpliesDurableFlush`, `RecoveredCommitCovered`, plus `ElectionSafety`, `LogMatching` |
| Scenario 2: Recovered or Reformatted Voter in Election | Format empty storage, metadata recovery, vote request/response, valid/empty/missing `lastEntry` evidence, election result acceptance | `MC_hunt_scenario2.cfg` | `ElectionSafety`, `LeaderCompleteness`, `RecoveredCommitCovered` |
| Scenario 3: Snapshot Install vs AppendEntries and ReadIndex | Snapshot notification, chunk append, final publish/reload, append rejection, read rejection, optional append-during-snapshot fault | `MC_hunt_scenario3.cfg` | `SnapshotInstallExclusion`, `LogMatching`, `ReadIndexRequiresCurrentLeader` |
| Scenario 4: ReadIndex and Leader Lease Across Leadership Change | Lease enablement, reply timestamp observation before result processing, lease extension, lease fast-path read, step-down cleanup | `MC_hunt_scenario4.cfg` | `ReadIndexRequiresCurrentLeader`, `NoOldLeaderLeaseRead`, plus `ElectionSafety` |
| Scenario 5: Reconfiguration, Catch-Up, and Leader Recognition | Staging, attempted snapshot, catch-up gate, old/new conf append, follower in-memory config before durable append, joint-majority commit, optional old-majority fault | `MC_hunt_scenario5.cfg` | `JointConfigMajorityOverlap`, `DurableConfigMatchesRecoveredRole`, `LeaderCompleteness`, plus `ElectionSafety` |

## §5 Safety Invariant Wiring

| Brief invariant | Defined in | MC wrapper visibility | Enabled in hunt cfg(s) |
|---|---|---|---|
| `ElectionSafety` | `base.tla` | Inherited by `MC.tla`; enabled in default `MC.cfg` | `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario4.cfg`, `MC_hunt_scenario5.cfg` |
| `LeaderCompleteness` | `base.tla` | Inherited by `MC.tla`; enabled in default `MC.cfg` | `MC_hunt_scenario2.cfg`, `MC_hunt_scenario5.cfg` |
| `LogMatching` | `base.tla` | Inherited by `MC.tla`; enabled in default `MC.cfg` | `MC_hunt_scenario1.cfg`, `MC_hunt_scenario3.cfg` |
| `CommittedImpliesDurableFlush` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario1.cfg` |
| `RecoveredCommitCovered` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg` |
| `SnapshotInstallExclusion` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario3.cfg` |
| `ReadIndexRequiresCurrentLeader` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg` |
| `NoOldLeaderLeaseRead` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario4.cfg` |
| `JointConfigMajorityOverlap` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario5.cfg` |
| `DurableConfigMatchesRecoveredRole` | `base.tla` | Inherited by `MC.tla`; commented in default `MC.cfg` | `MC_hunt_scenario5.cfg` |

The liveness invariants `SnapshotEventuallyClearsOrFails` and `ReadIndexEventuallyCompletesOrFails` are defined in `base.tla` but are not enabled in the safety hunt cfgs. This follows the checklist scope: §5 liveness and §6.2/§6.3 items are not required for the safety coverage audit unless the brief asks otherwise.

## §6.1 Finding Coverage

| Finding | Trigger mechanism in cfg | Expected violated invariant(s) | Target hunt cfg |
|---|---|---|---|
| MC-1 | `MaxAsyncFlushBugLimit = 2`, append/write/flush/crash enabled; unrelated snapshot/read/config bounds zeroed | `CommittedImpliesDurableFlush`, `RecoveredCommitCovered` | `MC_hunt_scenario1.cfg` |
| MC-2 | Election, vote reply kind, format, crash/recovery, and message bounds enabled; snapshot/read/lease disabled | `LeaderCompleteness`, `ElectionSafety` | `MC_hunt_scenario2.cfg` |
| MC-3 | Snapshot notification/chunk/read enabled, append-during-snapshot fault enabled with `MaxSnapshotBugLimit = 1` | `SnapshotInstallExclusion`, `LogMatching`, `ReadIndexRequiresCurrentLeader` | `MC_hunt_scenario3.cfg` |
| MC-4 | Lease enablement, reply timestamp/result processing, lease read, and election bounds enabled; crash/snapshot/config disabled | `NoOldLeaderLeaseRead`, `ReadIndexRequiresCurrentLeader` | `MC_hunt_scenario4.cfg` |
| MC-5 | Staging/catch-up/config ack enabled, config old-majority fault enabled with `MaxConfigBugLimit = 1`, crash/election kept reachable | `JointConfigMajorityOverlap`, `DurableConfigMatchesRecoveredRole`, `LeaderCompleteness` | `MC_hunt_scenario5.cfg` |

## Gaps and Scope Notes

- `MC.cfg` is a convergence config: it enables core safety and structural sanity while leaving scenario-specific hunt invariants commented out, as required by the spec-generation guide.
- `MC_hunt_scenario*.cfg` files are the bug-hunting configs. Each §2 scenario has exactly one target cfg, and every §6.1 finding maps to a cfg with the relevant fault/setup bounds enabled.
- Test-verifiable §6.2 items and code-review-only §6.3 items are intentionally not mapped to hunt cfgs.
