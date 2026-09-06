# vsr-rs validation changelog

Pinned source: `3ac0104a567092139534c9022205d02281a2da41`.
Methodology: installed `validation-workflow`, `tla-trace-workflow`, and `tla-checking-workflow` guides.

## Phase 0 - Initialization
- All base/trace/MC files and `MC_hunt_baseline.cfg` exist. Read instrumentation mapping and harness adjustment instructions in full.
- Existing 37-entry harness manifest matches current files and all three installed source modules. Four genuine library traces contain 186 events, all 20 event names, and 163 independently counted native callbacks. No regeneration is required.
- `Trace.cfg` enables `TraceMatched`; all 19 event wrappers validate the complete post-state, network multiset, and drained outputs. Existing source instrumentation is preserved.
- The session does not expose TLA MCP endpoints. Invoke the installed local tool handlers directly, retaining their results and raw logs under `spec/output/`.
- Five independent maintainer candidates and the assurance gaps remain Phase 4 handoffs; the baseline does not model kvstore OS/clock behavior or singleton progress.

## Round 1 - Trace Validation
- Fresh `run_trace_validation_parallel` replay: 4 passed, 0 failed (`output/trace-round1/result.json`), with full `Trace.cfg` including `TraceMatched` and seven invariants. No spec, invariant, harness, or trace changes.

## Round 1 - Model Checking
- Checked unchanged `MC.cfg`, BFS, 30-minute budget; 32 explicit workers, 24 GiB heap plus 72 GiB off-heap within the run's 32-worker / 128-GiB budget. No new state-space bounds.
- Initial background-launch attempt exited before parsing/exploration and is not counted as a check (`output/MC_round1_bfs.out`; `wait_for_pid.sh` observed the PID already gone). Foreground execution with a retained process session, separate launcher log, outer timeout and the same resource guard reaches exploration (`output/MC_round1_bfs_retry.out`). State spill is placed on the workspace volume under `output/tlc-state/`.
- The 30-minute watchdog ended the valid run with exit 124 and an explicit `Timed out` launcher status. No invariant violation or other TLC error was reported. Last progress sample (2026-09-05 19:22:24 UTC): 964,252,906 generated, 219,874,256 distinct, 160,519,720 queued, BFS layer 14. These are last-reported counters, not an exact final count or an exhausted graph.
- No Case A/B/C counterexamples, invariant changes, or spec changes. Static correspondence audits of normal, view-change, recovery, and timer paths are retained in `output/fidelity-normal-audit.md` and `output/fidelity-recovery-audit.md`; they are not equivalence proofs.

## Phase 3 - Convergence Check
- All four traces passed and the prescribed 30-minute `MC.cfg` window found no violations in the same round, with no modifications. Converged in one workflow round within this budget; exhaustive MC coverage remains LIMITED. No liveness result is claimed.

## Bug Hunting
- Checked the sole supplied `MC_hunt_baseline.cfg` with unchanged bounds: BFS first, 30-minute budget, 32 workers, 12 GiB heap and 36 GiB off-heap. The brief selects zero targeted protocol scenarios; this file is explicitly baseline assurance.
- BFS completed naturally in 20 min 10 s, exit 0: 646,763,167 generated states, 74,772,829 distinct states, zero queued, complete graph depth 27; no violations (`output/MC_hunt_baseline_bfs.out`). Because 27 > 25, simulation is optional under the workflow and was not run. No config bounds were reduced.
- No Case A/B/C counterexamples or changes during hunting. `bug-report.md` records the coverage and separate Phase 4 handoffs; `findings.json` contains the required empty MC findings array.
- Called the installed `clean_traces` handler for `Trace.tla`; zero diagnostic files required removal (`output/trace-round1/cleanup.json`). Input traces and prior-phase evidence remain intact.
- Final audit: all 22 input-manifest files and 37 harness-manifest entries match, the source diff is unchanged, required report/findings wiring and links are valid, and both valid TLC processes have exited. Machine-readable statistics and artifact hashes are retained in `output/validation-results.json` and `output/validation-artifact-manifest.json`. The report preserves TLC's fingerprint-collision estimates alongside its constrained graph completion.

## Result
Converged in 1 workflow round within the prescribed budget. Bug hunting: no model-checking bugs found. The broader `MC.cfg` exploration remains LIMITED; the baseline hunting graph completed only within its existing constraints. Five priority maintainer candidates and the assurance/API/integration handoffs remain independently pending Phase 4; an empty MC findings array does not discard them.
