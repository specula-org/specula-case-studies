# Validation changelog — vsr-rs

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`.

## Phase 0 — Initialization
- Read the installed validation, trace, and model-checking workflow guides and required mapping/harness documentation. All inputs and seven hunting configs exist. TraceMatched and full per-event post-state comparison are active. Preserved the existing instrumented source and snapshotted spec/config hashes in `output/initial-manifest.json`.
- TLC MCP tools are not exposed in this session; use their installed Python handlers directly and the standard managed model-checking wrapper. This preserves the same engine/methodology.

## Round 1 - Trace Validation
- [pass] Installed `run_trace_validation_parallel` handler: 7/7 original implementation traces passed with active TraceMatched/full post-state checks; no spec or instrumentation fix. Per-trace commands, hashes, and raw outputs: `output/trace-round1.json`. `clean_traces` removed 0 generated files.

## Round 1 - Model Checking
- Started unchanged MC.cfg with a 30-minute deadline; 64 workers, 48 GiB heap + 96 GiB off-heap within the run resource budget.
- [infra] First background launch exited before TLC initialization (cause not established); it is not counted as a model-checking result. Restarted unchanged inputs with the launcher and mandatory PID waiter held in the same bounded foreground command (`output/MC_round1b.out`, `output/MC_round1b.driver.log`).
- [audit] Independent source and evidence audits found no Case A/B repair; all 53 input integrity checks passed. Retained integration experiments are documented separately in `output/integration-evidence.md`; they are not relabeled as MC findings.
- [resume] A provider interruption left the existing MC process running. Reattached the mandatory PID waiter to the same wrapper PID 1103522 at 10:26 UTC; no phase or MC run was restarted. Resumed observation: `output/MC_round1b.resumed-wait.log`.
- [incomplete] MC.cfg reached its managed 30-minute timeout with no observed violation; last periodic counts: 1,260,140,453 generated, 216,199,137 distinct, depth 22, 96,919,949 queued. No Case A/B fix or Case C finding.

## Result
**Not converged.** Trace validation passed 7/7; Phase 2 timed out with unexplored states. All seven hunting configs remain unrun because the convergence precondition was not met. `bug-report.md`, `findings.json`, and `validation-status.json` explicitly record the incomplete status. No spec/source changes or relaxed bounds.
