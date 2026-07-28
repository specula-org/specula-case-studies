# Bug Report — SlateDB Distributed Compaction

## Summary

- Bug families tested: 5
- Bugs found: 1
- Configs run: `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family3_safety.cfg`, `MC_hunt_family4.cfg`, `MC_hunt_family5.cfg`

## Bug 1: Submitted backlog can exceed the configured running-compaction bound

- **Bug Family**: 5
- **Severity**: High
- **Invariant violated**: `BoundedRunningClaims`
- **Config**: `MC_hunt_family5.cfg`
- **Counterexample**: 8 states, `spec/output/MC_hunt_family5_bfs_repair.out`

### Trace Summary

The RR-001 repair removes the earlier family-1 overlap artifact: the repaired family-1 rerun no longer violates `NoConflictingActiveCompactions` when the hunt models the confirmed duplicate-L0 scenario. The next reachable failure in both affected hunts is instead capacity-based. In the family-5 rerun, the coordinator locally submits `j1` and `j2`, promotes both `Submitted` jobs to `Scheduled`, and the worker then claims both of them while `MaxConcurrent = 1`. The family-1 rerun reaches the same `BoundedRunningClaims` violation in 9 states after a local `j1` submission and a refreshed remote `j3` submission (`spec/output/MC_hunt_family1_bfs_repair.out`).

### Root Cause

The post-repair counterexamples now line up with the modeling brief's family-5 concern rather than the consumed family-1 artifact. `maybe_schedule_compactions()` admits new local work while counting only `Running` jobs, `maybe_validate_submitted_compactions()` promotes valid `Submitted` entries to `Scheduled` without a global capacity gate, and worker claiming is a separate loop driven by local progress bookkeeping. That leaves a path where more work becomes claimable than the configured running bound intends, so the fresh output now surfaces a `BoundedRunningClaims` candidate for the confirmation phase.

### Affected Code

- `slatedb/src/compactor.rs:1235`: local scheduling budgets against `Running` jobs, not all claimable backlog.
- `slatedb/src/compactor.rs:1308`: `maybe_validate_submitted_compactions()` promotes valid `Submitted` entries to `Scheduled` without a global capacity guard.
- `slatedb/src/compaction_worker.rs:304`: worker capacity is derived from local `job_progress`.
- `slatedb/src/compaction_worker.rs:314`: `poll_and_claim()` separately claims `Scheduled` backlog based on that local capacity calculation.

### Recommendation

This is fresh post-repair output and should go through the normal confirmation pass. If it reproduces, the likely fix direction is to unify capacity enforcement across `Submitted -> Scheduled` promotion and worker claim loops so backlog promotion cannot create more claimable work than the configured bound permits.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 2 | `MC_hunt_family2.cfg` | 206,922,576 generated / 44,319,466 distinct / depth 25 | No violation after fixing the GC output-timestamp fidelity gap in the model |
| 3 | `MC_hunt_family3.cfg` | 52,254 generated / 15,364 distinct / depth 13 | Not testable: fairness-free liveness property produced a stuttering counterexample |
| 3 (safety follow-up) | `MC_hunt_family3_safety.cfg` | 256,063,957 generated / 40,754,087 distinct / depth 62 | No safety violation after narrowing `OnlyCurrentOwnerPublishes` to the publishing worker |
| 4 | `MC_hunt_family4.cfg` | 179,421,854 generated / 35,816,002 distinct / depth 29 | No violation found in the 30-minute BFS window |

## Hunting Adjustments

- Excluded `Submitted` from `NoConflictingActiveCompactions` because the implementation can transiently hold conflicting backlog entries before the coordinator validation chokepoint.
- Required `WriteOutputSst` timestamps to be at least the durable submission time so the model matches the implementation's ULID-based GC watermark behavior and the existing GC regression test.
- Narrowed `OnlyCurrentOwnerPublishes` so it only requires the publishing worker to have cleared its own local execution; another worker may still be asynchronously stopping after reclaim.
- RR-001 repair: `MC_hunt_family1.cfg` now uses the confirmed duplicate-L0 small-world shape, and `MC_hunt_family5.cfg` now uses distinct non-conflicting jobs so it hunts capacity rather than the consumed overlap artifact.
