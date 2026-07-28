---
target: SPEC_REPAIR
counterexample: spec/output/MC_hunt_family1_bfs_rerun.out
scope:
  actions: [MCMaybeValidateSubmittedSchedule]
  invariants: [NoConflictingActiveCompactions]
  hunt_cfgs: [MC_hunt_family1.cfg]
  fault_actions: []
---

## Trigger
The counterexample requires `MCMaybeValidateSubmittedSchedule` to promote a second L0-sourced compaction to `Scheduled` while another L0 compaction in the same segment is already active, but the implementation rejects that transition before scheduling.

## Evidence
- The counterexample sequence is: local scheduler submits `j1`, external submit persists `j2`, coordinator refreshes, then `MCMaybeValidateSubmittedSchedule("j1")` and `MCMaybeValidateSubmittedSchedule("j2")` both succeed (`spec/output/MC_hunt_family1_bfs_rerun.out`, states 3-7).
- The live Level 0 reproduction used the same real API sequence:
  - standalone coordinator schedules one L0 compaction,
  - `Admin::submit_compaction()` persists a duplicate `Submitted` compaction,
  - the duplicate never reaches `Scheduled`.
  - Reproduction output from `repro/test_bugMC-1_conflicting_external_submissions.sh`:
    - `first scheduled compaction: ... destination=0 status=Scheduled`
    - `manual duplicate submission: ... destination=0 status=Submitted`
    - `latest compactions at timeout:`
    - original job `status=Scheduled`
    - duplicate job `status=Failed`
- The blocking implementation guard is in `slatedb/src/compactor.rs:1136-1150`. `validate_compaction()` rejects any L0-sourced compaction if another `Scheduled` or `Running` L0 compaction already exists in the same segment.
- That guard is independently covered by `test_validate_compaction_rejects_parallel_l0()` in `slatedb/src/compactor.rs:5673-5700`.
- The guard predates this confirmation run: commit `2f9b8e23ad3310e40ca0344c75f87e252b25075e` (`Ensure l0 not compacted in parallel (#1459)`, committed March 27, 2026) added the parallel-L0 rejection.

## Proposed change
Tighten the model action that corresponds to `Submitted -> Scheduled` so an external/manual L0 compaction cannot be promoted when another L0 compaction in the same segment is already `Scheduled` or `Running`. The model should mirror the implementation guard in `validate_compaction()`.
