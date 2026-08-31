# Validation changelog

## Round 1 - Trace Validation

- [fix] TraceStructuralSafety: aligned trace convergence with `MC.cfg`'s structural oracle set; the full scenario-specific `TraceSafety` remains defined and each target invariant remains enabled in its dedicated hunt config. This separates event/post-state matching from three implementation traces that deliberately exercise target safety violations (Traces: `clone_stack_failure.ndjson`, `clone_spawn_failure.ndjson`, `futex_validation_quota.ndjson`).
- [fix] ViablePIDs: added the concrete future wake-transition dependency for an overlapping futex mismatch interval, pruning branches that consume the mismatch before the trace's earlier-completing select/complete transitions for that waiter. The mismatch and wake actions remain unchanged (Trace: `futex_validation_quota.ndjson`).

## Round 1 - Model Checking

- [fix-inv] NamespaceIsATree: scoped the structural tree oracle to nodes currently linked by `namespace`, while still requiring every linked non-root node's parent to be linked. The old invariant incorrectly treated an object retained by an `Arc` after `rmdir` as a live namespace member; InMem traversal clones the `Arc` and later mutation legitimately operates on that detached object (`litebox/src/fs/in_mem.rs:249-302,488-525,585-610`). This is Case A; `ReachableCreate` remains the falsifiable hunt oracle for the resulting successful-but-unreachable create.

## Round 2 - Trace Validation

- All 9 preprocessed traces passed with no further changes.

## Round 2 - Model Checking

- No standard or structural invariant violations in the 30-minute BFS run (`1,096,135,926` states generated, `247,268,480` distinct states, diameter 16).

## Bug Hunting Adjustments

- [fix-inv] WakeCountsValidatedWaiters: delayed the oracle until a wake-counted unvalidated waiter actually takes the mismatch path while another validated waiter remains blocked. Selecting before validation is harmless when the later comparison succeeds, and a lone mismatching entry does not establish the target's lost-quota consequence; both earlier predicates were Case A invariant mismatches. The revised predicate remains falsifiable in `MC_hunt_scenario_5_futex_quota.cfg`.
- [fix] Scenario 3 hunt wiring: added `MC_hunt_scenario_3_stale_patch_plan.cfg` so the maintainer-aware host/register publication race cannot mask the unaudited `NoStalePatchPlan` target.
- [fix] Scenario 1/4 hunt wiring: added focused CWD-identity and failed-clone `PARENT_SETTID` configs so earlier ReachableCreate and platform-spawn counterexamples cannot mask those independent behaviors.

## Bug Hunting Findings

- [bug] ReachableCreate: a retained InMem parent handle can create successfully after the parent is unlinked, returning an unreachable file (Case C; `MC_hunt_scenario_1_reachable_create.cfg`).
- [bug] CwdIdentityStable: unlink/recreate of the stored CWD pathname redirects later relative operations to a new directory object (Case C; `MC_hunt_scenario_1_cwd_identity.cfg`).
- [bug] OperationBindsOneOFD: repeated raw-fd lookup lets one chunked syscall cross from `ofd0` to a reused `ofd1` (Case C; `MC_hunt_scenario_2_fd_identity.cfg`).
- [bug] AliasOffsetsShared: `Diroff` is fd-local, so dup aliases of one OFD expose different directory positions (Case C; `MC_hunt_scenario_2_alias_offsets.cfg`).
- [bug] NoStaleEpollInterests: last close leaves a dead interest whose pointer-qualified key is not replaced after raw-fd reuse (Case C, maintainer-aware mechanism with a new retention consequence; `MC_hunt_scenario_2_epoll_interest.cfg`).
- [bug] NoStalePatchPlan: a generation-1 runtime patch plan applies to a generation-2 fixed-address mapping (Case C, PR #669 mechanism with a new live consumer; `MC_hunt_scenario_3_stale_patch_plan.cfg`).
- [bug] CloneFailureAtomic/ThreadCountMatchesAttachments: SNP spawn failure leaks the raw init box and its already attached phantom thread, blocking process quiescence (Case C; Scenario 4 clone configs).
- [bug] CloneFailureAtomic: clone3 stack validation fails after `PARENT_SETTID` has already published a non-existent child ID (Case C; `MC_hunt_scenario_4_parent_tid.cfg`).
- [bug] WakeCountsValidatedWaiters: an unvalidated mismatch consumes `wake(1)` while a validated waiter remains blocked (Case C after two Case A oracle refinements; `MC_hunt_scenario_5_futex_quota.cfg`).
- [known] HostVmemAgreement: the merged Scenario 3 config rediscovered the source-documented/PR #669 host-register publication race without an additional consequence beyond prior evidence; retained as maintainer-aware technical debt, not a new finding.

## Result

Converged in 2 rounds. Bug hunting: 9 actionable findings, plus 1 known/maintainer-aware duplicate observation.
