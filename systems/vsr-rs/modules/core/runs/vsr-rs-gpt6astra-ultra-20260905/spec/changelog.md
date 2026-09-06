# Validation changelog — vsr-rs

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`.

## Phase 0 — Initialization
- All required specs, six hunting configs, mapping, harness documentation and four real traces exist. `TraceMatched` is enabled; every trace wrapper checks the full post-state and application observations.
- Existing Phase 2.5 instrumentation is retained. Live provenance audit matched all 46 recorded hashes and the owned source patch; no regeneration needed.
- MCP endpoints are not exposed in this session. Invoke the installed `run_trace_validation_parallel` handler directly through Python, retaining its logic and saving raw TLC output; use installed TLC launch/PID-wait scripts for model checking.

## Round 1 — Trace Validation
- [pass] Installed `run_trace_validation_parallel` handler: 4/4 implementation traces pass; 474 transitions and 50 apply calls. Strict positive/negative checks also pass (4/4 each). Evidence: `output/round1-traces/`. No spec or invariant changes.

## Round 1 — Model Checking
- Launching unchanged `MC.cfg`, 30-minute budget, 32 workers, 16 GiB heap + 64 GiB off-heap; no extra depth/state bounds.
- [infra] First background launch exited during initialization without a result. Retained `output/MC_round1_bfs.out`; restarted via foreground managed wrapper (`MC_round1_bfs_retry.*`) to retain process lifetime and separate launcher/TLC logs. This is not a model failure or a completed run.
- [infra] Relocated TLC temporary state storage from the 64 GiB container root (11 GiB free) to the workspace volume (449 GiB free). Stopped the first foreground run before disk exhaustion and restarted unchanged; retain `MC_round1_bfs_retry.*` as interrupted, not a pass.
- [bounded-pass] `MC_round1_bfs_final.out`: 30-minute watchdog exit 124, no TLC errors/invariant violations; last sample 1,299,398,606 generated / 232,574,619 distinct / 128,644,184 queued, depth 19. Counts are last-progress samples, not exhaustive completion. No semantic or invariant modifications; trace and MC checks agree within this budget.

## Convergence
- Workflow converged in Round 1 under the required 30-minute MC budget. State-space exploration remains incomplete. Proceed to all six hunting cfgs without reducing any bounds.

## Bug Hunting
- Starting six isolated 30-minute BFS runs, five workers and 4 GiB heap + 16 GiB off-heap each (aggregate 30 workers / 120 GiB).
- [bounded-pass] MC_hunt_scenario1.cfg: BFS 30 minutes, depth 16, 38,357,729 distinct at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario1_five.cfg: BFS 30 minutes, depth 14, 33,041,202 distinct at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario2.cfg: BFS 30 minutes, depth 16, 42,502,326 distinct at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_recovery.cfg: BFS 30 minutes, depth 15, 255,684 distinct at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_recovery_five.cfg: BFS 30 minutes, depth 9, 39,756 distinct at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_requests.cfg: BFS 30 minutes, depth 9, 182,469 distinct at last progress; no errors or violations.
- All six BFS depths are <=25. Starting six depth-100 simulations on the same cfgs, `-S -n 999999999 -p 100 -t 30`; five workers and 8 GiB heap + 4 GiB off-heap each (aggregate 30 workers / 72 GiB).
- [infra] Resumed after a temporary provider interruption at 15:25 UTC. All six original simulation processes were still alive with clean logs; reattached PID-based waits without rerunning completed work.
- [infra] All six simulations reached their explicit 30-minute wrapper timeout and exited. Provider interruption left driver completion fields unwritten; preserved original records as `run.launch.json` and recovered completion fields from logs, exited PIDs and filesystem timestamps. Exit 124 is inferred from the wrapper timeout branch; elapsed times are filesystem-derived. See `output/simulation-metadata-recovery.json`.
- [bounded-pass] MC_hunt_scenario1.cfg: simulation 30 minutes, configured depth 100, 1,058,385 paths / 131,614,373 states checked at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario1_five.cfg: simulation 30 minutes, configured depth 100, 1,544,266 paths / 188,856,259 states checked at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario2.cfg: simulation 30 minutes, configured depth 100, 1,590,914 paths / 196,883,558 states checked at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_recovery.cfg: simulation 30 minutes, configured depth 100, 23,499 paths / 2,369,826 states checked at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_recovery_five.cfg: simulation 30 minutes, configured depth 100, 2,532 paths / 257,917 states checked at last progress; no errors or violations.
- [bounded-pass] MC_hunt_scenario3_requests.cfg: simulation 30 minutes, configured depth 100, 3,560 paths / 438,450 states checked at last progress; no errors or violations.

## Result
Converged in 1 round within the prescribed MC budget. Bug hunting: no model-checking bugs found in all six BFS + simulation pairs. All searches remain bounded/non-exhaustive; liveness is LIMITED. No semantic spec, invariant or source changes were made by validation.
