# Bug Report — vsr-rs

## Summary

- Source revision: `3ac0104a567092139534c9022205d02281a2da41`.
- Protocol scenarios tested: 3 (S1 preservation, S2 execution/replies, S3 progress), across all six supplied hunting configs. S4's conforming abstract publication boundary is included in S1; the shipped example's concrete integration is outside this model.
- Model-checking bugs found: **0**. No counterexamples required Case A/B/C classification, and no semantic spec or invariant changes were made.
- Convergence: four real traces passed, followed by a 30-minute `MC.cfg` run without violations. Workflow convergence is limited to the configured budget; the reachable state space was not exhausted.
- Hunting: every config received 30 minutes of BFS and, because every BFS depth was <=25, 30 minutes of simulation with `-S -n 999999999 -p 100`. No bounds were reduced.

## Not Reproduced

| Scenario / config | BFS distinct / queued | Depth | Simulation paths / states checked | Result |
|---|---:|---:|---:|---|
| S1: historical preservation, N=3 — [MC_hunt_scenario1.cfg](MC_hunt_scenario1.cfg) | 38,357,729 / 21,913,627 | 16 | 1,058,385 / 131,614,373 | No violation observed; LIMITED |
| S1: historical preservation, N=5 — [MC_hunt_scenario1_five.cfg](MC_hunt_scenario1_five.cfg) | 33,041,202 / 21,296,373 | 14 | 1,544,266 / 188,856,259 | No violation observed; LIMITED |
| S2: logical execution and replies — [MC_hunt_scenario2.cfg](MC_hunt_scenario2.cfg) | 42,502,326 / 25,730,664 | 16 | 1,590,914 / 196,883,558 | No violation observed; LIMITED |
| S3: quiescent recovery, N=3 — [MC_hunt_scenario3_recovery.cfg](MC_hunt_scenario3_recovery.cfg) | 255,684 / 115,939 | 15 | 23,499 / 2,369,826 | No violation observed; LIMITED |
| S3: quiescent recovery, N=5 — [MC_hunt_scenario3_recovery_five.cfg](MC_hunt_scenario3_recovery_five.cfg) | 39,756 / 25,771 | 9 | 2,532 / 257,917 | No violation observed; LIMITED |
| S3: request progress, N=3 — [MC_hunt_scenario3_requests.cfg](MC_hunt_scenario3_requests.cfg) | 182,469 / 130,986 | 9 | 3,560 / 438,450 | No violation observed; LIMITED |

All runs ended through the configured 30-minute watchdog (exit 124), rather than exhausting their search. Counts above are the last logged samples: generated/distinct/state-check/path counts are lower bounds on work done; queue sizes are point-in-time samples. Simulation counts include repeated states and paths. The configured maximum simulation depth was 100; observed reported means were 77–78. These results establish **no violations found in the explored/sample executions**, not absence of implementation defects.

Exact commands, seeds, hashes, times, complete progress logs and runtime exits are in each `output/MC_hunt_*_{bfs,simulation}/` directory. [Machine-readable run summary](output/run-summary.json), [BFS audit](output/bfs-audit.md), and [simulation audit](output/simulation-audit.md) support the table.

The provider interruption prevented the simulation driver's completion fields from being saved. The original launch records are preserved as `run.launch.json`; completion fields in `run.json` were recovered from unchanged logs and observed exited PIDs. For these six runs, exit 124 is inferred from the installed wrapper's exclusive `Timed out` branch, and elapsed time is filesystem-derived (final `launch.out` modification time minus the recorded start), rather than an OS-collected return value or recovered monotonic timing. [Recovery evidence](output/simulation-metadata-recovery.json) records this distinction. No simulation was rerun.

## Assurance boundaries

- All checks are limited to the supplied finite views, logs, requests, fault budgets, network/outbox bounds, N=3/N=5 membership and deterministic Put/Get workload. The original configs and all semantic files remain unchanged; their initial identities are in [the input manifest](output/inputs/manifest.json).
- S3 checks the configured conditional formulas `<>BoundHit \/ <service-property>`. Reaching a bound discharges the bounded question. Stabilization, continuing service clocks, owner fairness, reliable delivery relative to ticks, and failure-budget compliance are premises. Periodic temporal checks ran during BFS, but unrestricted request/recovery liveness remains **LIMITED**. All supplied configs disable deadlock checking.
- No per-scenario hit census, bound-avoidance census, or assumption-satisfying infinite service witness was recorded. In particular, the five-replica config permits two concurrent recoveries; aggregate search/path counts alone do not document a specific witness of that trigger.
- Quiescent recovery configs submit no requests. Their empty-log preservation predicates do not add independent committed-data coverage; the relevant S1/S2 hunts carry that question.
- The [fidelity audit](output/fidelity-audit.md) distinguishes substantive history checks from the redundant primary-identity conjunct and records the absence of a separate historical-view-floor oracle. It found no basis for an invariant/spec correction. Trace agreement remains evidence for the recorded schedules, not a general refinement proof.
- Singleton behavior, DST observer/workload limitations, and concrete example filesystem/startup/identity/nonce/transport obligations remain the separate test/review candidates in `../modeling-brief.md`. They are not silently promoted into this phase's model-checking findings.

## Changes during validation and hunting

No Case A or Case B fixes were required. Two preliminary MC launches were interrupted during infrastructure setup and are excluded from successful coverage; the full replacement run is retained. A later provider interruption left the simulations running, and the same processes were resumed and observed without restarting completed checks. See [changelog.md](changelog.md).
