# Modeling-brief coverage audit

This audit was filled from the final `MC_hunt_*.cfg` files. It maps only Modeling Brief §2, §5, and §6.1, as required by the spec-generation workflow.

## §2 scenarios

| Brief scenario | Base-spec extension and reachable mechanism | Targeting hunt config | Actual nonzero bounds | Enabled target checks |
|---|---|---|---|---|
| 1. Path snapshot versus stable namespace identity | `ResolverParentDirAndName` caches a parent object; `InMemRmdirAt` can unlink it before `InMemCreateFileAt`. `TaskSysChdirValidate`/`Publish` stores path identity, then `InMemRmdirAt` + `InMemRecreateAt` precede `TaskResolvePathRelative`. | `MC_hunt_scenario_1_namespace.cfg`; non-masking checks in `MC_hunt_scenario_1_reachable_create.cfg` and `MC_hunt_scenario_1_cwd_identity.cfg` | Merged/CWD configs: `FSRequestLimit=2`, `FSMutationLimit=2`; create-only config: `1`/`1`; every unrelated initiator is `0` | `NamespaceIsATree`, `ReachableCreate`, `CwdIdentityStable` |
| 2. Raw FD slots versus OFD identity | A chunked operation captures an entry OFD but each `TaskChunkedReadChunk` uses the current slot. Close/reuse, fd-local directory offsets, and weak epoll interest identity share one extension but use separate configs to prevent invariant masking. | `MC_hunt_scenario_2_fd_identity.cfg`, `MC_hunt_scenario_2_alias_offsets.cfg`, `MC_hunt_scenario_2_epoll_interest.cfg` | Primary: `FDOperationLimit=3`, `FDReuseLimit=2`; alias: `2`/`0`; epoll: `1`/`1`; every unrelated initiator is `0` | `SingleBindingPerFdSlot`, `OperationBindsOneOFD`, `AliasOffsetsShared`, `NoStaleEpollInterests` (plus structural `OFDRefCountsCorrect`) |
| 3. Mapping generation versus stale auxiliary state | `TaskMaybePatchOnMprotectExecCollect` snapshots a generation; `TaskSysMunmap` and a second host/register pair can replace it before `TaskMaybePatchExecSegmentApply`. | `MC_hunt_scenario_3_mapping_generation.cfg`; non-masking stale-plan check in `MC_hunt_scenario_3_stale_patch_plan.cfg` | Both configs: `VMOperationLimit=2`, `VMMutationLimit=1`; every unrelated initiator is `0` | Merged: `MappingRangesDisjoint`, `HostVmemAgreement`, `NoStalePatchPlan`; focused: `MappingRangesDisjoint`, `NoStalePatchPlan` |
| 4. Clone publication and ownership transfer before commit | Prepare, parent-TID publication, successful stack validation, attachment, ownership transfer, and platform success/failure are separate actions. The MC-CLONE-1 spec excludes the independent early stack-error edge so it cannot mask platform-failure checking; `MC_hunt_scenario_4_parent_tid.cfg` isolates that early edge. | `MC_hunt_scenario_4_clone_transaction.cfg`, `MC_hunt_scenario_4_clone_failure_atomic.cfg`, `MC_hunt_scenario_4_parent_tid.cfg` | Platform failure: `CloneStartLimit=1`, `SpawnFailureLimit=1`; parent-TID: `CloneStartLimit=1`, `SpawnFailureLimit=0`; every unrelated initiator is `0` | `ThreadCountMatchesAttachments`, `CloneFailureAtomic` |
| 5. Futex wake quota includes an unvalidated waiter | Two insertions, one guest-word change, and one wake allow the queue head to be selected before its comparison while a later waiter is validated. | `MC_hunt_scenario_5_futex_quota.cfg` | `FutexWaitLimit=2`, `FutexWakeLimit=1`, `FutexChangeLimit=1`; every unrelated initiator is `0` | `WakeCountsValidatedWaiters`; `ValidWaiterEventuallyReturns` is also enabled as a temporal property |

There is at least one hunt config per brief scenario. Scenario 1's main config explicitly merges its two §6.1 filesystem findings and adds one non-masking create-only config. Scenario 2 separates the three live OFD consumers so an easy epoll or alias counterexample cannot stop TLC before `MC-FD-1`.

## §5 proposed invariants

| Brief invariant | Type | Defined in | Wired through MC | Enabled in actual hunt config(s) |
|---|---|---|---|---|
| `NamespaceIsATree` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_1_namespace.cfg` |
| `ReachableCreate` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_1_namespace.cfg`, `MC_hunt_scenario_1_reachable_create.cfg` |
| `CwdIdentityStable` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_1_namespace.cfg`, `MC_hunt_scenario_1_cwd_identity.cfg` |
| `SingleBindingPerFdSlot` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_fd_identity.cfg` |
| `OperationBindsOneOFD` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_fd_identity.cfg` |
| `AliasOffsetsShared` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_alias_offsets.cfg` |
| `NoStaleEpollInterests` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_2_epoll_interest.cfg` |
| `MappingRangesDisjoint` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_3_mapping_generation.cfg` |
| `HostVmemAgreement` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_3_mapping_generation.cfg` |
| `NoStalePatchPlan` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_3_mapping_generation.cfg`, `MC_hunt_scenario_3_stale_patch_plan.cfg` |
| `ThreadCountMatchesAttachments` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_4_clone_transaction.cfg` |
| `CloneFailureAtomic` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_4_clone_transaction.cfg`, `MC_hunt_scenario_4_clone_failure_atomic.cfg`, `MC_hunt_scenario_4_parent_tid.cfg` |
| `WakeCountsValidatedWaiters` | Safety | `base.tla` | inherited by `MC.tla` | `MC_hunt_scenario_5_futex_quota.cfg` |
| `ValidWaiterEventuallyReturns` | Liveness | `base.tla` | `MCSpec` adds weak fairness for wake completion | `MC_hunt_scenario_5_futex_quota.cfg` under `PROPERTIES` |

All thirteen §5 Safety invariants are defined and enabled in at least one hunt config. `MC.cfg` keeps scenario-specific invariants/properties commented out and checks only convergence/structural properties. The sole §5 liveness property is outside the mandatory Safety audit but is nevertheless wired and enabled in its focused hunt.

## §6.1 model-checkable findings

| Finding | Trigger represented in the hunt | Expected violated invariant(s) | Targeting config |
|---|---|---|---|
| `MC-FS-1` | Walk `ParentPath`; unlink the cached empty parent; complete `InMemCreateFileAt` on the retained Arc. Reactive create completion is unbounded. | `ReachableCreate` (and the standard tree check exposes the detached child) | `MC_hunt_scenario_1_reachable_create.cfg` (also enabled in the merged namespace config) |
| `MC-FS-2` | Validate/publish CWD, unlink/recreate `CwdPath`, then perform relative lookup. Two request and two mutation slots are available. | `CwdIdentityStable` | `MC_hunt_scenario_1_namespace.cfg` |
| `MC-FD-1` | Begin one logical chunked operation, run a chunk, close/reuse the same raw slot with another OFD, then run the next unbounded reactive chunk. | `OperationBindsOneOFD` | `MC_hunt_scenario_2_fd_identity.cfg` |
| `MC-VM-1` | Collect the current patch interval, unmap it, remap/register a newer generation on another idle thread, then apply the old unbounded plan. | `NoStalePatchPlan`; the merged config also checks split-publication consistency | `MC_hunt_scenario_3_stale_patch_plan.cfg` (also enabled in `MC_hunt_scenario_3_mapping_generation.cfg`) |
| `MC-CLONE-1` | Run one clone through parent publication, successful stack validation, attachment, and transfer; inject one SNP host-spawn failure. The dedicated MC spec omits the separate pre-attachment stack-error branch. | `ThreadCountMatchesAttachments`, `CloneFailureAtomic` | `MC_hunt_scenario_4_clone_transaction.cfg`, with a non-masking `CloneFailureAtomic` check in `MC_hunt_scenario_4_clone_failure_atomic.cfg` |
| `MC-FUTEX-1` | Insert the future mismatching waiter first, change the word, insert/validate a second waiter, then run `wake(1)` so queue-order selection spends quota on the unvalidated head. | `WakeCountsValidatedWaiters` | `MC_hunt_scenario_5_futex_quota.cfg` |

Every §6.1 finding has a nonzero fault/request setup that can reach its trigger. Reactive steps needed after the setup are intentionally not counter-bounded.

## Intentional exclusions

The exact `do_dup_inner` rollback/recycled-fd issue (#1170), LinuxKernel cross-core TLB shootdown (#671), source-documented overlay/resolver coarse locks, the exact PR #669 two-CoW race, PR #1155, and PR #1228 are not separate actions or hunt configurations. This follows brief §3.2 and the rerun guidance: those sites are filed or maintainer-aware and this brief did not identify a new consequence worth rehunting. Scenario 3 instead targets the current unfiled stale patch-plan/generation consumer.
