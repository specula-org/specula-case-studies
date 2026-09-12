# Bug Report — temporal-nexus

## Summary

**INCOMPLETE: trace validation has not converged; bug hunting has not started.**

- Hunting scenarios/configs executed in this validation phase: 0.
- New model-checking findings established in this phase: 0; this is **not** a completed no-bugs result.
- Strict implementation replay: 0/21 original and 0/11 fresh recordings accepted.
- Eleven fresh real SQLite schedules and nine observer negative controls passed; five source-backed spec corrections passed partial-state boundary diagnostics. These results do not substitute for full replay or model checking.
- See [validation-report.md](validation-report.md), [changelog.md](changelog.md) and the [machine-readable validation status](output/validation-20260911/validation-summary.json).

The source-discovered B1 missing STC timer and B2 retained timeout-node capacity behavior were independently reproduced with healthy controls and post-shard-reacquisition database readback. They remain source/runtime observations in the modeling-brief handoff; they are not invented model-checking entries in findings.json. Formal reconfirmation and composition exploration remain incomplete.

## Not Reproduced

| Scenario | Config | States explored in this phase | Result |
|---|---|---:|---|
| Convergence safety/structure | MC.cfg | 0 | NOT RUN: implementation traces have not passed. |
| Remote knowledge | MC_hunt_s1_remote_knowledge.cfg | 0 | NOT RUN: convergence precondition unmet. |
| Deferred cancellation/timer | MC_hunt_s2_deferred_cancel_timer.cfg | 0 | NOT RUN: convergence precondition unmet; B1 runtime evidence retained separately. |
| Terminal capacity | MC_hunt_s3_terminal_capacity.cfg | 0 | NOT RUN: convergence precondition unmet; B2 runtime evidence retained separately. |
| Deadlines/stale tasks | MC_hunt_s4_deadlines_stale_tasks.cfg | 0 | NOT RUN: convergence precondition unmet. |
| Uncertain/buffered commit | MC_hunt_s5_uncertain_buffered_commit.cfg | 0 | NOT RUN: convergence precondition unmet. |

Earlier generation/review TLC outputs were produced against the original spec hashes. They do not establish convergence of the revised model. No MC Case A/B/C finding was classified in this validation phase.

