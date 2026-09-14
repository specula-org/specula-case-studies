# Validation changelog — nvflare-fedavg

## Phase 0 — Initialization
- Source pinned at `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; existing Phase 2.5 instrumentation and all 24 implementation traces retained. Category A, full state equality, and `PROPERTIES TraceMatched` verified.
- Read validation, trace and checking workflows, instrumentation mapping, harness instructions and modeling brief. All base/MC/Trace inputs and eleven hunting configs present.
- Added `checks/validate_all_traces.py` to invoke the experiment-local `run_trace_validation_parallel` handler (MCP is not exposed). Only launch/resources and evidence persistence are adapted; parsing and validation semantics are unchanged. Each trace uses 1 GiB heap, 1 GiB off-heap, one worker, and an outer timeout; total remains under 128 GiB / 40 workers.

## Round 1 — Trace Validation
- All 24 traces passed the installed parallel handler; complete finite replay with full post-state equality and TraceMatched. No spec or instrumentation changes. Receipts and logs: `output/trace-round1/`.

## Round 1 — Model Checking
- Started standard `MC.cfg` BFS with 30-minute budget, 16 GiB heap, 48 GiB off-heap and 40 workers. No state/depth/config bounds changed.

- [infra] Initial background launch exited before TLC initialization; PID wait returned exit 3. Its log is preserved but gives no semantic coverage. Restarted unchanged `MC.cfg` with a foreground session and outer 31-minute timeout; TLC initialized normally at 11:34:05 UTC (`output/MC_round1_bfs_retry.*`). All seven installed source/instrumentation hashes match the Phase 2.5 ownership receipt.
- [infra] Added isolated hunt launcher and installed TLC output-reader adapter under `checks/`; each hunt keeps input hashes and an isolated copy. Trace launcher now names its wrapper log per trace under `output/`, avoiding shared timestamp-log names; original per-trace captured stdout remains complete. No TLA/config/trace changes.
- Standard MC ended on its 30-minute budget (exit 124), with no invariant violation or execution error. Last periodic progress: 1,334,981,180 generated / 292,238,651 distinct / 24,216,269 queued states, depth 86. This is bounded clean exploration, not exhaustive completion.

## Round 1 — Convergence
- 24/24 traces pass and standard MC is clean within its full budget; no TLA or cfg changes. Budgeted convergence in one round.

## Bug Hunting
- Launching all 11 original hunt cfgs as independent BFS runs, each with unchanged bounds, 30-minute budget, 4 GiB heap, 6 GiB off-heap and 3 workers (aggregate 110 GiB / 33 workers). Exact input snapshots and receipts are saved under `output/hunt-bfs/`.
- [bug] S3: ordinary parameter/metric consumer failures violate CommittedAcceptanceConsistency (Case C, one shared MC-1 mechanism). Metric CE: 81 states, rejected c1 remains in the exposed model; parameter CE: 77 states, first-key statistics change despite rejection before value update. Source and state-by-state analysis: `output/counterexample-classification.md`.
- [fix-inv] S4 direct cancel/filter failure/before-send error and S5 permitted-death: remove AbnormalTerminationVisible from four cfgs (Case A). No unified product no-save-after-task-termination guarantee or AllowPartialCompletion setting was established. Preserve all counterexamples and mark that property not applicable; enable actual receipt/contribution/round/caller-lock checks. No behavior, bound or fault budget changed.
- [hunt] Add CommittedValuesAccepted, a value-only conjunct, and a supplemental parameter cfg to expose the later value-retention window while keeping the original full-consistency hunt. MC.tla change is an invariant definition only; base/Trace and all actions are unchanged.
- [bug] Supplemental parameter value oracle found 79-state Case C for the same MC-1: second-key materialization fails after key 1 changes; rejected c2 remains in GLOBAL_MODEL key 1. This strengthens the original statistics-only counterexample without suppressing it or restricting transitions.
- [audit] Updated brief coverage and cfg audit to explicitly mark the unsupported outcome oracle not applicable and preserve all 5 scenario mappings. Original generation artifacts are archived in output/generation-audit.

## Result
Converged in 1 round within the required execution budget. Bug hunting: 1 bug found (3 Case C counterexamples of one mechanism); 4 Case A policy-oracle counterexamples retained and corrected in cfg wiring, 0 Case B behavior fixes. All 16 hunt executions (12 distinct cfgs, including one supplemental value oracle and four corrected reruns) are recorded. 7 finite hunts completed cleanly; 2 reached their full 30-minute budgets without a reported violation. All no-violation BFS depths exceed 25, so no simulation follow-up was required. Temporal coverage is stated explicitly in the report. Base/Trace/actions and production source remain unchanged. Final report, findings mirror, path/hash checks and coverage artifacts are complete.
