# Validation changelog

## Phase 0
- Opened the supplied specification and Phase 2.5 harness at NVFlare pin `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Preserved the initial model, generators, configurations, mapping and receipts under `validation/initial/`. Category A; ListResourceManager, ProcessJobLauncher, mandatory site-1, min_sites as recorded per workload, default non-strict startup.
- TraceMatched is active; ValidatePostState checks exact action-specific field sets and complete normalized snapshots. Existing harness failures require classification and repair before model checking.

## Round 1 - Trace Validation
- [fix-spec] Stop calls: split actual client stop send from blocking return in admin and startup-failure paths (source job_runner.py:374-413,719-720,798-800). Debugger confirms the old network lacked both observed stop commands.
- [fix-spec] JobRunnerEvaluateStartReplies: preserve initialized deployed-site active list when explicit errors or strict-policy checks raise before filtering (job_runner.py:313-358; admin.py:101-142). Debugger observed model active={site-1}, source active={site-1,site-2}.
- [fix] Abort capture: move executor ownership capture under its existing lock before blocking teardown, capture no-op early returns, and split STARTING termination. Old traces omit effects before parent shutdown; preserve them and regenerate from production hooks.
- [fix] MC configuration wiring: include MCTypeOK in every hunt as well as the standard configuration; no safety property or fault bound was removed.
- [diagnostic] The 120-second DAP budget expired near event 570 in the long admission trace; zero-hit/partial-hit results are incomplete debugger coverage, not false conditions. Raise the diagnostic timeout to 600 seconds; ordinary TLC replay already completed and located the mismatch.
- [fix-spec] Receiver outcomes: guard accepted state changes with the actual pending site, and add an ignored-report action/receiver probe (fed_server.py:938-956). Add heartbeat-origin missing-outcome resolution without inventing a message (fed_server.py:1045-1094).
- [fix-spec] Preserve ABORTED return-code classification separately from generic failure and retain existing stronger-code precedence (job_runner.py:548-572,813-843); this added outcome branch still requires dedicated trace coverage.
- [fix-spec] Heartbeat cleanup is normal reactive behavior with normal fairness, not an exhaustible injected fault. Server cleanup pop permits the real no-op after exit-waiter removal (server_engine.py:408-409).
- [fix-spec] Server abort cleanup: split full ten-second grace, early registry removal, and zero-grace command-exception continuations. Capture the worker independently of caller return; preserve idempotent pop and do not infer process exit from terminate (server_engine.py:354-409).
- [regression] Repeated server cleanup: the newly captured second abort worker repeats terminate after the first worker; remove the invented once-only guard, retaining occurrence history and source branches (server_engine.py:373-409). The isolated diagnostic checkpoint is copied verbatim from the final matched state; full regression retains original Init.
- [fix] Update the old synthetic generation smoke fixture to the Phase 2.5 config/trace tags; it had zero initial states because its tags predated the real trace contract. This fixture is not implementation evidence.
- [pass] Final Phase 1 regression: all 4 real traces pass (1,353 semantic events), with zero observer projection errors; `output/traces-r5/`. SANY plus all cfg initialization/first-successor checks and action/coverage audits pass; `output/check-generated-validation-r5.log`.

## Round 1 - Model Checking
- Starting MC.cfg only, 30-minute BFS budget, explicit 32 GiB heap + 128 GiB direct memory and 40 workers. Host available memory approximately 265 GiB and no active Java process at launch; limits retain the required host reserve.
- [pass] MC.cfg reached its normal 30-minute budget (task 7718fb73c3ef4aa6ac0366f4e4a1f48d, exit 124), without invariant errors. Last reported: depth 28, 85,219,049 generated, 16,008,119 distinct, 6,158,119 queued. This is bounded coverage, not exhaustive completion. No Phase 2 spec/invariant changes.

## Convergence
- Bounded convergence in round 1: all four traces pass and the standard 30-minute invariant check has no violation on the same model. Begin scenario hunting; preserve all remaining coverage boundaries in validation/priority-coverage.md.

## Bug Hunting
- [bug] MC-2 / NoFreeWhileInUse (Case C): 36-state BFS counterexample frees unit 0 after successful spawn/attachment and failed waiter installation while the child is live. Source: client_executor.py:299-334; scheduler_cmds.py:129-133. No waiter executed, so this is not evidence of double free.
- [bug] MC-3 / AcceptedPreRunAbortPersists (Case C): 22-state BFS counterexample acknowledges a pre-run abort after a stale DISPATCHED write. Source: job_runner.py:661-670; job_cmds.py:1059-1066; job_def_manager.py:459-481. Trace ends before spawn; actual API reproduction is downstream.
- [bug] MC-4 / NoTerminalResurrection (Case C): 61-state BFS counterexample writes RUNNING after COMPLETED publication. Source: job_runner.py:709-711 versus 524-538; job_def_manager.py:459-481. Counterexample ends before completion-map deletion; later orphaned status is a source-permitted continuation, not a reproduced deployment outcome.
- [run] All eight original hunt configs launched. Added the final exit-cleanup BFS after fresh measurement (91.47 GiB available) at aggregate declared 224 GiB / 80 workers; per-run bounds and 30-minute budgets retained.
- [coverage] S1 two-site/three-site and S2 strict BFS reached their 30-minute budgets without violations (depths 57/53/47); launch optional depth-100 simulations on unchanged bounds. S5 progress BFS ended at depth 20, 10,193 distinct states; its depth-100 simulation is required by the workflow.
- [tool-error] S5 simulation: all 16 workers crashed in FcnLambdaValue.toFcnRcd while comparing lazy EXCEPT values during liveness trace construction. Stopped only that JVM; exit 143 is failed execution, not clean budget coverage. Preserve full log and stop reason.
- [tool-fix] Use isolated execution copies with TLCEval around explicit function constructors. Bundled TLC.tla defines TLCEval(v)==v; canonical base/MC, every guard/property/fairness clause and all cfg bounds remain unchanged. All four real traces pass on the eager copy (`output/traces-eager-control/`). Retry S5 simulation and use the same execution-only workaround for S4 simulation.
- [coverage] S4 exit-cleanup BFS reached its normal 30-minute budget with no violation: depth 28, 4,428,812 distinct states. Run an optional depth-100 simulation to exercise deeper overlaps.

## Result
Bounded convergence in 1 alternating round after 5 full replay passes. All 4 implementation traces pass (1,353 events, 94/125 action types). Standard MC.cfg completed its 30-minute budget without invariant errors. All 8 original hunt configs ran BFS; 5 depth-100 follow-up simulations completed their budgets. Bug hunting found 3 source-supported Case C findings (MC-2, MC-3, MC-4); the shared-environment hypothesis was not reproduced in these model searches. One failed TLC simulation was preserved and successfully retried using identity eager evaluation. No exhaustive correctness or end-to-end reproduction of the violating interleavings is claimed.
