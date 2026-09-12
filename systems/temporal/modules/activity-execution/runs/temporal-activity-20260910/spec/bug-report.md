# Bug report — temporal-activity

## Summary

- Core calibration: **21/21 complete real traces**, 2,414 events, with full state comparison and complete endpoints.
- Selective real-trace controls: **84/84 rejected**. Five synthetic plumbing controls are separately labeled and excluded from real-trace counts.
- Bounded MC.cfg baseline: **PASS**, 29,188,066 distinct states, empty queue, depth 87.
- Scenario hunting: seven configurations, each with a 30-minute BFS budget and a 30-minute depth-100 simulation budget.
- Confirmed model-checking implementation bugs: **0**.

No incomplete graph is called an exhaustive pass. Simulation counts are generated walks, not unique states. The full unquotiented 1000 ms clock reference remains INCOMPLETE after 30 minutes; the completed baseline uses the documented bounded safety quotient in clock-reduction.md.

## Model/configuration corrections

The source-grounded transition fixes and independent projector are recorded in changelog.md and validation-report.md. Hunting found one oracle mismatch (Case A), in both S2 configurations: an expired Matching dispatch can disappear while a live timer still carries the Activity's termination obligation. The corrected invariant retains all deadline coverage and requires either dispatch or an expired deadline with live timer coverage. Its allowed-expiry predicate control passes; lost-timer and lost-dispatch-before-deadline controls still fail. The corrected S2 runs are reported below.

Progress counterexamples were model/configuration issues (Case B): notification fairness was omitted, and the original finite clock budget separately stopped before a pending physical cue could fire. The progress property was not weakened. The healthy event-boundary clock experiment and its explicit timing assumptions are documented in progress-assumptions.md. No Case C implementation defect was established.

## Not reproduced

The counts below are the last retained periodic reports for runs stopped by their budgets; they are lower bounds on generated/distinct counts, not claims that queued states were explored.

| Scenario/config | BFS generated | BFS distinct found | Queued at last report | Depth | Simulation walks | Result |
|---|---:|---:|---:|---:|---:|---|
| `MC_hunt_s1_attempt_identity.cfg` | 187,514,941 | 71,416,682 | 49,427,548 | 31 | 1,591,202 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s1_stamp_enabled.cfg` | 185,702,658 | 77,175,821 | 52,208,091 | 31 | 1,554,674 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s2_shared_timers.cfg` | 157,021,278 | 46,693,789 | 27,327,681 | 25 | 513,782 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s2_stamp_enabled.cfg` | 154,474,251 | 45,624,978 | 26,714,915 | 25 | 508,863 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s3_uncertain_commit.cfg` | 203,356,470 | 62,172,064 | 29,631,687 | 31 | 1,254,210 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s4_cancellation.cfg` | 172,025,290 | 60,118,809 | 35,281,296 | 32 | 1,298,061 | BFS INCOMPLETE; no simulation violation observed |
| `MC_hunt_s5_observation.cfg` | 211,428,286 | 59,146,075 | 16,603,292 | 34 | 1,280,893 | BFS INCOMPLETE; no simulation violation observed |

BFS is performed first. Both corrected S2 runs reached only depth 25, so their simulation follow-ups are mandatory under the workflow; the other five follow-ups add optional depth coverage. Every simulation uses `-n 999999999 -p 100` and stops at the 30-minute budget. Explicit no-op Next choices are removed under the unchanged stuttering envelope so simulation depth counts state changes. Original fault/request/attempt bounds remain unchanged.

## Conditional progress

| Experiment | Distinct states | Result |
|---|---:|---|
| `progress-original` | 9,122 | Case B: omitted notification fairness |
| `progress-original-fair` | 10,005 | Case B: finite clock horizon |
| `progress-healthy` | 10,485 | Case B: omitted notification fairness |
| `progress-healthy-fair` | 7,152,128 | INCOMPLETE; no completed temporal proof |
| `progress-healthy-final` | 9,451,213 | INCOMPLETE; no completed temporal proof |

The healthy progress experiment uses one Activity/two attempts, no result/heartbeat inputs or injected faults, source-scale millisecond timers, the configured 1000 ms reader shift, and fair event-boundary time/queue/persistence/WFT service. It is separate from the broader safety/hunting configurations. The additional final-only temporal run preserves model/bounds and changes only when temporal checking occurs. Unfinished temporal exploration remains INCOMPLETE.

## Evidence and scope

The authoritative complete real run is `../harness/evidence/run-20260911T031548Z-D6wqTn/`. Source revision is `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; backend is independent file-backed SQLite/WAL/synchronous=NORMAL. The fresh harness has 187 cache/SQL AI comparisons, 24 delivered-token comparisons and 205 independent task-key comparisons. Exact raw traces, versions, SQL/task readbacks, consistent backups, binary/patch hashes, tool identities and commands are retained.

Validation covers both retry-stamp settings; all four timeout types; stale completion/failure/heartbeat/cancel acknowledgement; scheduled/running/backoff cancellation; lost start reply and same-UUID retry; definitely skipped writes, committed/lost replies, internal retry after commit and delayed fenced writes; shared two-Activity scanning, heartbeat extension and duplicate timer delivery; and rejected Workflow close followed by terminal WFT consumption. All 45 top-level state fields and nested values are checked. Source/receipt duplicates and excluded interface tasks retain explicit raw evidence roles.

Recovery means cache reload and durable shard reacquisition followed by local readiness. No process/database restart, power-loss durability, administrative extension, replication, routing policy or external exactly-once effect is claimed. Unobserved model branches are listed in ../harness/COVERAGE.md. Those limits do not change the completed ordinary-core trace and bounded safety results.

The baseline snapshot predates only a later timer-oracle change inactive in MC.cfg; MC additions used solely for progress/simulation are also inactive in the baseline. The stored baseline-to-current diffs establish unchanged baseline transition and active-property semantics. Each larger run retains its own exact input snapshot and hashes.

Machine-readable results: findings.json, validation-result.json, output/continuation-20260911/checks-summary.json, artifact-manifest.json and per-run inputs/logs. There are no `Bug N` entries because no implementation defect was established by model checking.
