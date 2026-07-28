# Brief Coverage Audit: SlateDB Distributed Compaction

This audit was filled by reading the generated `MC.cfg` and `MC_hunt_family*.cfg` files in this directory, not from intended coverage.

## Brief §2: Bug Families

| Brief family | Base-spec hooks | Hunt cfg covering it | Notes |
|---|---|---|---|
| Family 1: Split admission control for `Submitted` compactions | `ExternalSubmit`, `CoordinatorRefreshCompactions`, `MaybeValidateSubmittedFail`, `MaybeValidateSubmittedSchedule`, `PollAndClaim` in [base.tla](./base.tla) | [MC_hunt_family1.cfg](./MC_hunt_family1.cfg) | Models the path that bypasses `add_compaction()` and only later goes through coordinator validation. |
| Family 2: Non-atomic shared-state publication and recovery-safe terminal semantics | `CommitCompactedEntriesWriteManifest`, `CommitCompactedEntriesWriteCompactions`, `CommitCompactedEntriesFail`, `RefreshCheckpoint`, `GcSweep`, `CrashCoordinator`, `StartCoordinator` in [base.tla](./base.tla) | [MC_hunt_family2.cfg](./MC_hunt_family2.cfg) | Splits checkpoint, manifest, and `.compactions` durability into separate actions and keeps crash windows live. |
| Family 3: Independent heartbeat / reclaim / ownership control loops | `PollAndClaimStopDuplicate`, `HeartbeatOwnedJobs`, `HeartbeatLoseOwnership`, `HandleFinishedSuccess`, `HandleFinishedLostOwnership`, `HandleFinishedExecError`, `ReclaimStaleWorkers` in [base.tla](./base.tla) | [MC_hunt_family3.cfg](./MC_hunt_family3.cfg) | Distinguishes durable ownership from worker-local execution and reclaim timing. |
| Family 4: Stale-state merge, fencing, and post-merge repair | `StartCoordinator`, `CoordinatorRefreshCompactions`, `CoordinatorRefreshManifest`, `MaybeScheduleCompactions`, `MaybeValidateSubmitted*`, `CommitCompactedEntries*` in [base.tla](./base.tla) | [MC_hunt_family4.cfg](./MC_hunt_family4.cfg) | Uses per-object versions and epochs plus fresh-write preconditions to model fenced writes after refresh. |
| Family 5: Fragmented concurrent-compaction accounting | `MaybeScheduleCompactions`, `ExternalSubmit`, `MaybeValidateSubmittedSchedule`, `PollAndClaim`, `ReclaimStaleWorkers` in [base.tla](./base.tla) | [MC_hunt_family5.cfg](./MC_hunt_family5.cfg) | Hunts the gap between coordinator-side `Running` counting and per-worker claim limits. |

## Brief §5: Proposed Invariants

| Brief invariant | Defined in spec | Enabled in standard `MC.cfg`? | Enabled in hunt cfg(s) | Coverage status |
|---|---|---|---|---|
| `SinglePublishPerCompaction` | [base.tla](./base.tla) | No | [MC_hunt_family1.cfg](./MC_hunt_family1.cfg), [MC_hunt_family2.cfg](./MC_hunt_family2.cfg) | Covered |
| `NoConflictingActiveCompactions` | [base.tla](./base.tla) | No | [MC_hunt_family1.cfg](./MC_hunt_family1.cfg), [MC_hunt_family5.cfg](./MC_hunt_family5.cfg) | Covered |
| `BoundedRunningClaims` | [base.tla](./base.tla) | No | [MC_hunt_family1.cfg](./MC_hunt_family1.cfg), [MC_hunt_family3.cfg](./MC_hunt_family3.cfg), [MC_hunt_family5.cfg](./MC_hunt_family5.cfg) | Covered |
| `OnlyCurrentOwnerPublishes` | [base.tla](./base.tla) | No | [MC_hunt_family3.cfg](./MC_hunt_family3.cfg) | Covered |
| `ManifestReferencesExistingFiles` | [base.tla](./base.tla) | No | [MC_hunt_family2.cfg](./MC_hunt_family2.cfg), [MC_hunt_family4.cfg](./MC_hunt_family4.cfg) | Covered |
| `NoPrematureReclaim` | [base.tla](./base.tla) | No | [MC_hunt_family2.cfg](./MC_hunt_family2.cfg), [MC_hunt_family3.cfg](./MC_hunt_family3.cfg) | Covered |
| `RecoverySafeTerminalRelation` | [base.tla](./base.tla) | No | [MC_hunt_family2.cfg](./MC_hunt_family2.cfg), [MC_hunt_family4.cfg](./MC_hunt_family4.cfg) | Covered |
| `FencedWriterCannotOverwriteFreshState` | [base.tla](./base.tla) | Yes | [MC_hunt_family4.cfg](./MC_hunt_family4.cfg) | Covered |

Notes:

- `MC.cfg` keeps only structural / fencing invariants enabled by default and leaves bug-hunting safety checks to the targeted family configs.
- The spec also retains compatibility aliases for the older invariant names used by the prior SlateDB artifact, but the hunt coverage above is keyed to the current brief’s names.

## Brief §6.1: Model-Checkable Findings

| Finding | Trigger mechanism from brief | Expected violated invariant(s) | Targeting hunt cfg |
|---|---|---|---|
| MC1 | Externally submitted conflicting jobs bypass `add_compaction()` and both survive to `Scheduled` / `Running` | `NoConflictingActiveCompactions`, `SinglePublishPerCompaction` | [MC_hunt_family1.cfg](./MC_hunt_family1.cfg) |
| MC2 | `Submitted -> Scheduled` has no global capacity gate and workers only budget locally | `BoundedRunningClaims` | [MC_hunt_family5.cfg](./MC_hunt_family5.cfg) |
| MC3 | Reclaim races with still-running local execution and ownership is tracked only by worker id | `OnlyCurrentOwnerPublishes`, `BoundedRunningClaims` | [MC_hunt_family3.cfg](./MC_hunt_family3.cfg) |
| MC4 | Crash after manifest publication but before `.compactions` terminalization leaves recovery to classify the job later | `SinglePublishPerCompaction`, `NoPrematureReclaim`, `RecoverySafeTerminalRelation` | [MC_hunt_family2.cfg](./MC_hunt_family2.cfg) |
| MC5 | Stale refresh / merge / restart ordering attempts to write behind a fresher durable state | `FencedWriterCannotOverwriteFreshState`, `ManifestReferencesExistingFiles` | [MC_hunt_family4.cfg](./MC_hunt_family4.cfg) |

## Scope Notes

- The drain path remains modeled because it shares the same manifest-first durability machinery, but none of the current hunt configs specialize on drain-only watermark bugs.
- Family 4 fencing is modeled via `manifestVersion`, `compactionsVersion`, `manifestEpoch`, `compactionsEpoch`, refresh actions, and fresh-write preconditions on coordinator durability actions; it is intentionally abstracted away from the unmodeled manifest writer details.
