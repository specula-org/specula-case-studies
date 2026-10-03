# Validation Changelog — openraft

Pinned source: `15f927e1358d41ffc1297516f781029dbf8ca86a`.

## Phase 0 - Initialization

- Read the requested validation, trace-validation, and model-checking workflows plus their required references, the modeling brief, `instrumentation-spec.md`, and `harness/INSTRUMENTATION.md`.
- Verified all base, trace, MC, trace-data, harness, and five hunting-config inputs. `Trace.cfg` enables `PROPERTIES TraceMatched`, and `Trace.tla::ValidatePostState` checks the complete emitted common state rather than returning `TRUE`.
- Regenerated the three focused traces through the real instrumented OpenRaft tests and reran their structural checks and TLC replay. The harness intentionally covers 3 of 47 mapped action types; the other 44 remain explicit trace-coverage gaps.

## Round 1 - Trace Validation

- [pass] The installed `run_trace_validation_parallel` handler passed all 3 generated traces (`election_remote_grants.ndjson`, `competing_candidates.ndjson`, and `snapshot_trigger.ndjson`), containing 7 total events; no specification or instrumentation fix was required. Evidence: `output/trace-round1.json` and `harness/validation/*.log`.

## Round 1 - Model Checking

- [infra] The first background-wrapper launch was admitted but exited before TLC initialization. It consumed no checking budget. The unchanged command was immediately rerun through the workflow's allowed foreground-blocking runner.
- [incomplete] Unchanged `MC.cfg` ran breadth-first for the full managed 30-minute budget with 8 workers, 8 GiB heap, and 24 GiB off-heap. No invariant violation was observed. The last periodic report recorded 82,076,855 generated states, 17,112,556 distinct states, depth 17, and 6,379,765 states still queued.
- No Case A invariant repair, Case B specification repair, or Case C implementation finding was established. The specification was not modified.

## Prior Baseline Result

**Prior run not converged.** Trace validation passed 3/3, but Phase 2 timed out with unexplored states. All five hunting configs were unrun in that baseline because the convergence precondition was not met. No bounds or properties were relaxed.

## Incremental Update - 2026-09-09

- Source delta from `0f4e195474e4a902b391b99497bdbb3535b89749` to `15f927e1358d41ffc1297516f781029dbf8ca86a` required a model change for the new watch-channel IO completion forwarder and the initialize/respond/elect order.
- Updated `base.tla`, `MC.tla`, `Trace.tla`, and new `Update.tla`/`Update_*.cfg` to split durable append completion from LocalIO delivery and to add update-focused IO bridge invariants.
- Rebased the trace harness and added `initialize_then_election`; final trace run passed 4/4 focused tests and TLC replayed all 4 traces, 8 total events.
- Model-side validation repairs: protected append-prefix comparison at index 1, parenthesized the `staleSessionEffect'` disjunction assignment, and capped `SaveCommittedAndApply` at `min(localCommitted, submittedIO.log)` to match OpenRaft's progress-driven command logic.
- Final focused checks passed: `Update_focused.cfg` exhausted 314,780 generated / 74,438 distinct states; `MC_hunt_scenario2_io.cfg` exhausted 3,322 generated / 1,081 distinct states.
- Final broad checks found no implementation counterexample: random simulation completed 160,000 traces / 14,381,960 states; full `Update_full.cfg` BFS was budget-limited at depth 17 with 84,024,319 generated / 17,476,123 distinct states and no violation reported before timeout.
