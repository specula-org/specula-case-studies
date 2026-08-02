# Specification Validation Changelog

## Round 1 - Trace Validation
- All 4 implementation traces passed strong post-state validation; no spec or harness changes were required.

## Round 1 - Model Checking
- Standard `MC.cfg` checks found no violations in the 30-minute BFS run (67,319,566 generated / 19,811,800 distinct states; diameter 7); no spec or invariant changes were required.

## Bug Hunting - Invariant Refinement
- [fix-inv] LegalRolePair: classified the immediate `Standby -> Destroying` / ASIC-Standby counterexample as Case A. The implementation installs the phase before asynchronously queuing the Dead-role write (`crates/hamgrd/src/actors/ha_scope/npu.rs:1562-1564,1724-1748`), so the invariant now accepts a mismatch only while the matching role transition is queued, in flight, or durably awaiting rehydration. All 4 traces still pass.

## Bug Hunting - Specification Fidelity
- [fix-spec] RoleForState / RequiredActions: classified the follow-on `LegalRolePair` counterexample as Case B. The model incorrectly converted `SwitchingToStandby` into ASIC role `None`, while the implementation programs `Standby`; it also omitted the directly adjacent `InitializingToStandby` role write (`crates/hamgrd/src/actors/ha_scope/npu.rs:1526-1528,1557-1560`). Both state-to-role effects now match the implementation. Per the validation workflow, convergence restarts after this action-level change.

## Round 2 - Trace Validation
- All 4 implementation traces passed after the state-to-role fidelity correction.

## Round 2 - Model Checking
- Standard `MC.cfg` checks found no violations in the 30-minute BFS run (65,317,357 generated / 19,390,616 distinct states; diameter 7). The action-level model correction therefore converged.

## Bug Hunting - Pipeline Invariant Refinement
- [fix-inv] ParentBeforeScope: classified the first pipeline counterexample as Case A. The original equality rejected the safe intermediate state where parent epoch 2 was applied while scope epoch 1 remained applied. The invariant now enforces the brief's actual implication with `haSetApplied >= scopeApplied`, which still fails when a child epoch applies before its same parent epoch or survives parent deletion.

## Bug Hunting - Pending-Edge Specification Fidelity
- [fix-spec] DpuHandlePendingOperation: classified the first recovery counterexample as Case B. The model allowed a second pending-flag epoch while the first flag was still live, but `dpu.rs:158-173` creates an operation only on a false-to-true edge. A second operation is now enabled only when no flag is live, or after a crash clears the volatile cached edge while the same durable flag epoch remains live. Per the validation workflow, convergence restarts after this action-level change.

## Round 3 - Trace Validation
- All 4 implementation traces passed after the pending-edge fidelity correction.

## Round 3 - Model Checking
- Standard `MC.cfg` checks found no violations in the 30-minute BFS run (65,923,597 generated / 19,407,952 distinct states; diameter 7). The final action-level model converged.

## Result
Converged in 3 rounds. Bug hunting found 7 distinct Case C implementation bugs across all 8 supplied focused configurations after deduplicating the pipeline and route reproductions. Every focused BFS produced a source-confirmed counterexample, so no simulation follow-up was required. See `bug-report.md` and `findings.json`.
