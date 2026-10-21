# Validation changelog

## Phase 0 - Initialization

- The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`. The receiving controller holds the run and shared heavy-stage locks. TLC is limited to 4 GiB and two workers.
- All specification, configuration and instrumentation files exist. `Trace.cfg` enables `TraceMatched`, and `ValidatePostState` compares captured fields after full base actions.
- The inherited harness status is incomplete: the final ordered-clock patch was not built, the earlier 23 traces have provisional clock ordering, and the 20% cross-thread overlap criterion was unmet. Regeneration is required before convergence can be claimed. Original input hashes and harness status are preserved in `output/validation-20261005T200356Z/`.

- The fresh attempt `20261005T200356Z` built the final instrumentation successfully but failed clock qualification in cases 00, 07, 10 and 21. The guest reported `SCM_DONE 1`, and the harness exited 1 before normalization or replay. Compiled evidence confirms the final fence sequence.
- The new competition cases 17 and 18 each have 0 overlapping pairs out of 936. The 20% timebox criterion remains unmet. No specification, invariant, bound or canonical trace was modified.

## Phase 0 - Regeneration on 2026-10-06

- The controller's recorded clock and overlap decision is in `harness/CONTROLLER-DECISION-2026-10-06.md`. The existing corrected HPET instrumentation was rebuilt without edits in attempt `20261005T220019Z` after the memory reserve cleared. Build exit was 0, guest exit was 33, and the fixture reported `SCM_DONE 0`.
- All 23 fixtures passed their 128 clock exchanges. The 1,117 production events cover all 34 action names. Competition cases 17 and 18 have 2 and 14 strict overlapping pairs, and case 18 includes successful PEEK and ordinary receipt of the same message. The compiled clock, destruction and publication boundaries were audited against the booted ELF.
- The accepted HPET batch replaced the provisional canonical traces only after all harness checks passed. Previous attempts and their failed calibrations remain in the evidence history. No source, model, invariant or configuration was changed.

## Round 1 - Trace Validation

- All 23 accepted traces passed `Trace.cfg`, including `TraceMatched` and every enabled safety and terminal check. The required parallel-validation tool was called in singleton batches to stay within the lane's 4 GiB memory limit. No witness fallback or fix was needed. Results are in `output/validation-20261005T220019Z/round1-trace-mcp.json`.

## Round 1 - Model Checking

- The unchanged `MC.cfg` ran for its full 30-minute budget with two workers, a 3 GiB heap and 512 MiB off-heap memory. Task `08c1da773e9f4d058fa57a5722f6a8ee` exited 124 at the configured limit without a reported violation. The last progress record showed depth 33, 32,560,435 generated states, 12,442,357 distinct states and 3,385,376 queued states. These are last reported counters, not final totals.
- The state space was not exhausted. No counterexample, Case A/B/C decision or spec/invariant fix was produced. Full logs and the process result are preserved in `output/validation-20261005T220019Z/MC-round1*`. The temporary checkpoint directory was removed by the wrapper.

## Prior result - attempt 20261005T220019Z

Phase 0 and all 23 traces in Round 1 passed. Validation remains incomplete at Phase 2 because the prescribed model-checking run ended before exhaustive completion. Convergence is unestablished, and all 27 hunting configurations are `NOT_RUN`. No new defect candidate was produced. No bug report or empty findings index was emitted before the required hunting stage. The source, harness implementation, model and configurations remain unchanged, and no owned job remains active.

## Attempt 20261006T023358Z - Initialization

- The required files and 27 hunting configurations are present at the same source pin. The receiver still holds the shared heavy-stage and run locks. Input hashes and the previous reports are preserved in `output/validation-20261006T023358Z/`.
- The canonical traces still match accepted attempt `20261005T220019Z`. The fresh harness attempt `20261006T022240Z` remains `INCOMPLETE_OVERLAP_REQUIREMENT`. Both batches have 1,117 events, all 34 action names, and every required receiver field. Prior replay logs and their input hashes were independently checked. No batch was promoted or regenerated during this invocation.
- The current request requires the unmodified validation workflow. The recorded controller exception allowing companion configurations is therefore not used to replace the Phase 2 `MC.cfg` check. The harness overlap limitation remains separately visible.

## Attempt 20261006T023358Z - Round 1 Trace Validation

- All 23 supplied traces passed the unchanged `Trace.cfg`, including `TraceMatched`. The first direct replay generated 54 states. The required batch tool ran in singleton batches because its fixed heap is 4 GiB. Resource checks passed before each invocation. No spec fix, invariant revision, witness fallback or trace regression occurred.
- The trace cleanup tool found no generated files to remove. The MCP outcomes are retained in `output/validation-20261006T023358Z/round1-trace-mcp.json`.

## Attempt 20261006T023358Z - Round 1 Model Checking

- Task `4fead067c67b4df8b4f627a482eaddc3` ran the unchanged `MC.cfg` for 30 minutes with two workers, a 3 GiB heap and 512 MiB off-heap memory. The initial memory reserve was 8,849,816 kB. It exited 124 at the configured budget without a reported invariant violation, evaluation error or memory error. The last counters were depth 32, 28,939,128 generated states, 12,670,700 distinct states and 3,248,457 queued states. These are last reported counters, not final totals.
- The state space was not exhausted. No counterexample was available for Case A/B/C classification, and no spec or invariant fix was made. Full logs and the task outcome are saved in `output/validation-20261006T023358Z/MC-round1*`. The wrapper removed the temporary checkpoint directory.

## Result - attempt 20261006T023358Z

All 23 supplied traces passed. The original-bound `MC.cfg` search remains incomplete, so convergence is unestablished and all 27 hunting configurations are `NOT_RUN` in this invocation. Bug-hunting artifacts are not emitted before their convergence prerequisite. The independent harness overlap limitation remains unresolved. No new defect candidate was established, and existing AST-32/AST-36 attribution is unchanged. All 109 hashed source, harness, model, configuration and canonical-trace inputs remain unchanged. The TLC task has exited and no job launched by this invocation remains active.
