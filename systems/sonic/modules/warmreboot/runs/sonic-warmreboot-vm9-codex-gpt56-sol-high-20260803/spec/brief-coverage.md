# Modeling Brief Coverage Audit

This audit was completed against the actual final `MC_hunt_scenario*.cfg` files, not the intended design. It is brief-driven: only modeling brief §2, §5, and §6.1 are mapped.

## Brief §2 Scenarios

| Scenario | Base-spec mechanism | Target hunt configuration | Enabled target checks |
|---|---|---|---|
| 1 — Volatile Request Ownership Versus a Pending Host Reboot | Separate `backend` owner/epoch, host owner/epoch, D-Bus phase, post-return timer, crash/recover, late host completion, repeated admission | `MC_hunt_scenario1.cfg` | `SinglePendingReboot`, `OwnershipRecovery` |
| 2 — Epoch-Scoped Warm Flags and Finalization Safety | `warm.bootEpoch`, per-namespace flag/snapshot/restore/finalize epochs, dynamic required set, deadline, unconditional finalization/save, malformed readiness | `MC_hunt_scenario2.cfg` | `EpochConsistency`, `NoPrematureFinalization`, `TimeoutIsNotReadiness` |
| 3 — Causal Quiescence and Monotonic Shutdown | Per-namespace producer/channel/consumer state, freeze before visibility, irreversible commit, timer resurrection, ignored post-commit failure | `MC_hunt_scenario3.cfg` | `CausalFreeze`, `ShutdownMonotonicity`; temporal `ShutdownTermination` |
| 4 — Multi-ASIC Snapshot and Restore Coherence | Two symmetric ASICs, independent enable/failure/prune/copy/schema/restore decisions, one global reboot and completion | `MC_hunt_scenario4.cfg` | `SnapshotSafety`, `CrossNamespaceCoherence`, `EpochConsistency` |
| 5 — Backend Worker Handoff and Failure Classification | Small Scenario 1 refinement preserving set-active/thread-create/join boundaries and distinct raw D-Bus causes | `MC_hunt_scenario5.cfg` | `FailureClassification`; temporal `RetryLiveness` |

No scenario is merged or lacks a hunt configuration.

## Brief §5 Proposed Invariants

| Brief invariant | Kind | Defined / wired | Actually enabled in |
|---|---|---|---|
| `SinglePendingReboot` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario1.cfg` |
| `OwnershipRecovery` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario1.cfg` |
| `EpochConsistency` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario2.cfg`, `MC_hunt_scenario4.cfg` |
| `NoPrematureFinalization` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario2.cfg` |
| `CausalFreeze` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario3.cfg` |
| `ShutdownMonotonicity` | Safety half of mixed safety/progress statement | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario3.cfg` |
| `SnapshotSafety` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario4.cfg` |
| `CrossNamespaceCoherence` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario4.cfg` |
| `RetryLiveness` | Temporal | `base.tla`; checked under `MCFairSpec` | `MC_hunt_scenario5.cfg` via `PROPERTIES` |
| `TimeoutIsNotReadiness` | Safety | `base.tla`; inherited by `MC.tla` | `MC_hunt_scenario2.cfg` |

The progress half of the brief’s `ShutdownMonotonicity` statement is explicitly defined as `ShutdownTermination` and enabled under `MCFairSpec` in `MC_hunt_scenario3.cfg`. All safety invariants from §5 are enabled in at least one hunt config. `FailureClassification` is an additional Scenario 5 extension, enabled only in its hunt config.

`MC.cfg` intentionally enables only `CoreManagerSafety`, `MCTypeOK`, and `CounterShape`; all scenario invariants are present but commented out for convergence, as required by the MC methodology.

## Brief §6.1 Model-Checkable Findings

| Finding | Reachable trigger in the actual hunt cfg | Expected violated check | Target cfg |
|---|---|---|---|
| Backend crash after host acceptance, recovery, then second request | `AcceptLimit=2`, `BackendCrashLimit=1`; host accept and backend recovery are unbounded reactive actions | `OwnershipRecovery` immediately after recovery; `SinglePendingReboot` after second admission | `MC_hunt_scenario1.cfg` |
| Local timeout releases ownership before late host completion and admits second request | `AcceptLimit=2`, `PlatformDeadlineLimit=1`; timer start, join, and late host completion are unbounded | `SinglePendingReboot` while epoch 1 remains host-pending and epoch 2 is backend-pending | `MC_hunt_scenario1.cfg` |
| Finalizer deadline clears flags/saves DB with incomplete or late consumer | `WarmBeginLimit=1`, `FinalizerDeadlineLimit=1`, `ReadinessFaultLimit=1`; registration/finalization/save are unbounded | `NoPrematureFinalization`, `TimeoutIsNotReadiness` | `MC_hunt_scenario2.cfg` |
| Freeze sees local empty while prior config update is in transit | `ConfigUpdateLimit=1`; freeze is unbounded and deliberately does not consume the in-flight update | `CausalFreeze` | `MC_hunt_scenario3.cfg` |
| One namespace fails after prune/warm enable while global reboot proceeds mixed | `NamespaceFailureLimit=1`, `SchemaMismatchLimit=1`, `SnapshotFailureLimit=1`; both ASIC restore branches are unbounded | `SnapshotSafety`, `CrossNamespaceCoherence`, possibly `EpochConsistency` | `MC_hunt_scenario4.cfg` |
| Ignored post-no-rollback failure remains permanently degraded | `PostCommitFailureLimit=1`; commit is reactive and sets rollback false, making current-code explicit recovery unavailable | temporal `ShutdownTermination` under `MCFairSpec` | `MC_hunt_scenario3.cfg` |
| Weakest durable epoch/ownership record sufficient for safe recovery | The unsafe baseline is reachable with `AcceptLimit=2`, `BackendCrashLimit=1`; `OwnershipRecovery` states the minimum recovered-state obligation: recovered backend must not expose unowned IDLE while host is pending | `OwnershipRecovery`, `SinglePendingReboot` | `MC_hunt_scenario1.cfg` |

The last finding is only partially answerable against the current implementation: it proves that volatile backend state alone is insufficient and identifies the safety predicate a repair must establish. It does not compare concrete persistence designs because the target has no durable request record or host-query recovery branch to model (`STATE_DB` is constructed but unused). A future implementation can be checked by refining `BackendRecover` to consume its actual record/query and rerunning the same config and invariants; inventing candidate persistence protocols here would violate the code-faithfulness rule.

## Audit Result

- Five of five §2 scenarios have explicit hunt configs.
- All nine §5 safety invariants are defined, inherited by `MC.tla`, and enabled in at least one actual hunt config.
- Both §5 temporal obligations are enabled as properties under a fair targeted specification (`RetryLiveness` directly; the progress half of `ShutdownMonotonicity` as `ShutdownTermination`).
- All seven §6.1 findings have a hunt config with enabling fault bounds; the durable-record design comparison is explicitly limited to the code-supported unsafe baseline and required recovery predicate.
