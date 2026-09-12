# Phase 3 evidence

`initial-inputs/` and `initial-provenance.json` preserve the supplied specification and original trace hashes. `initial-source.diff` preserves the pre-existing instrumentation; Phase 3 did not modify Temporal source behavior.

`skill_tools.py` invokes the installed Specula tool handlers directly because this session does not expose the trace/debug MCP methods as callable tools. The handlers implement `run_trace_validation_parallel`, `run_trace_validation`, `run_trace_debugging`, `validate_spec_syntax`, and `clean_traces`. A local output-parser adapter recognizes this TLC build's singular `Temporal property TraceMatched was violated` diagnostic; it does not alter TLC execution or the validation predicate. Every invocation saves arguments, spec/config snapshots, full logs, and structured results. Debugging uses `TLCGet("level")` conditions.

Trace evidence:

- `trace-original/`: all supplied traces fail initialization under the original transport decoder.
- `trace-envelope/` through `trace-ignore-final-error/`: full-suite regression checks after each source-backed correction.
- `debug-*/`: layered localization and actual variable inspection for each failure family.
- `trace-final-original/`: all 16 original complete traces pass the corrected canonical spec.
- `fresh-build.log`, `fresh-scenarios.log`, `fresh-traces/`: fresh build and 16 real Matching/file-backed SQLite executions, with independent store and owner readbacks.
- `trace-final-fresh/`: all 16 fresh complete traces pass the same spec.
- `trace-controls/`: all five corrupted implementation traces fail specifically at `TraceMatched`.
- `trace-validation-summary.json`: exact trace/model hashes, record counts, action-type coverage, controls and scope.
- `trace-cleanup/`: generated root `Trace_TTrace_*` cleanup receipt; original implementation traces and evidence are retained.

Model checking evidence:

- `round1-MC/`: interrupted initial background launch; no completion or verification verdict.
- `round1-MC-attached/`: attached Phase 2 run of the unchanged supplied `MC.cfg`, with 16 GiB heap, 32 GiB off-heap, 32 workers and a 1,800-second outer timeout. `MC.out` is the TLC-only log; `driver.log` includes resource admission and wrapper diagnostics; `exit.json` is the process receipt after termination. A process exit or timeout is not a completed state-space search.

Only the baseline configuration belongs to Phase 2. The pre-existing Phase 2.5 searches in `../../harness/model-checks/` are historical evidence with their own snapshots and limits, and do not substitute for this run or authorize post-convergence hunting.

The model runtime uses the installed Specula `lib/tla2tools.jar` build 2026.09.04.170753. Trace replay uses the harness-pinned `tools/tla2tools.jar` build 2026.08.11.125311. Both run hashes are recorded with the final status; no result from another base/config hash is promoted.

Final outcome: **INCOMPLETE**, baseline deadline plus kill grace exit 137. See `../validation-status.md`, `final-artifact-audit.json` and `scratch-cleanup-result.json`. All required report/index files explicitly retain non-convergence.
