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

## Attempt validation-20261010T015405Z - Initialization

- The required files, 23 canonical traces and 20 hunting configurations are present. The latest harness batch contains another 23 traces and 1,084 production events across all 34 actions. Both batches pass the static schema and per-thread ordering audit. `TraceMatched` and mandatory post-state comparisons remain enabled. Input hashes and prior reports are retained in `output/validation-20261010T015405Z/`.
- The receiver holds the shared heavy-stage lock. The latest harness remains incomplete under the unchanged 20% overlap gate, and the canonical batch was accepted under a superseded exception. Neither batch is promoted by this invocation. The current spec review also flags the default `PeekLimit = 0`; any completed default search establishes ordinary-receive coverage only.

## Attempt validation-20261010T015405Z - Round 1 Trace Validation

- All 23 canonical traces and all 23 latest-batch traces passed the unchanged `Trace.cfg` through the required batch tool, called in singleton batches to respect its fixed 4 GiB heap. The initial direct replay generated 54 states. No mismatch, witness fallback or spec/invariant change occurred. The smallest pre-launch effective memory reserve was 43.33 GiB. Results are in `output/validation-20261010T015405Z/round1-trace-mcp.json`. Successful replay does not resolve the harness overlap gate.

## Attempt validation-20261010T015405Z - Round 1 Model Checking

- `MC.cfg` completed without errors at its supplied ordinary-receive bounds: 13359928 generated states, 3596537 distinct states, depth 62, and an empty queue. Task `f885fa1f983f4ef0a0708df99f556187` used two workers, a 3 GiB heap, 512 MiB off-heap memory and a 30-minute maximum. No Case A/B/C counterexample or spec/invariant fix occurred. Logs and result are under this attempt directory.
- The trace/MC loop converged in one round at those supplied bounds. This is not full-protocol convergence: the default excludes PEEK and three-attempt single-thread histories, and the harness overlap gate remains unmet. The workflow now proceeds to the existing hunting configurations without changing their bounds.

## Attempt validation-20261010T015405Z - Bug Hunting

- [bug] `NoFailedNumberInstalled` fails in 31 states during a first-number-fault PEEK. The completed operation retains FD 7 after its number-copy failure while temporary references drain and queue ownership remains. Source readback and the Linux reserve/copy/install order establish Case C, attributed to existing AST-32.
- [bug] `ReportedPrefixMatchesLinux` fails in 36 states after a normal receive delivers two numbers and faults on the third. The first two FDs remain valid, the third remains installed, and reported control length is zero with a 32-byte header instead of the Linux 24-byte prefix. This is Case C and another check of existing AST-32.
- [bug] `PayloadFaultConsumptionMatchesLinux` fails in 18 states when ordinary payload copying returns EFAULT before Asterinas dequeues the message. Linux unlinks before copying and releases its receive reference on error. This is Case C, attributed only to the existing AST-36 boundary control.
- Persistent-finding lookups returned no registered matches. Attribution to the known leads comes from the supplied contracts and current source comparison. No invariant or action was changed, no new AST ID was assigned, and no confirmation or shared-catalog update was performed. Counterexamples and structured analysis are retained under this attempt directory.

## Same-session continuation

- Revalidated all 135 saved input hashes after resuming. None changed. Preserved the 46 passing replays, completed default search and three analyzed compatibility counterexamples. The two outstanding TLC tasks both finished at their 30-minute budgets without a reported violation. Their saved results are now in the ledger. No completed analysis or search was restarted.

## Result - attempt validation-20261010T015405Z

The trace/MC loop converged in one round at the supplied ordinary-receive `MC.cfg` bounds. All 46 trace replays passed, and the default check exhausted 3,596,537 distinct states at depth 62. No action, invariant, configuration bound, source file or harness implementation changed.

All 20 hunting configurations ran with their prescribed 30-minute maxima. Twelve completed exhaustively without violations. Five four-right searches reached their budgets without a reported violation: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario1_separate_tables.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg` and `MC_hunt_scenario4.cfg`. Their remaining queues stay visible in the execution ledger. The three Case C counterexamples describe existing AST-32 and AST-36, yielding two known finding identities and zero new defect candidates. `bug-report.md` and `findings.json` preserve both identities and the AST-32 reporting refinement.

Every no-violation BFS reached at least depth 51. No simulation follow-up was required. All TLC tasks have exited. The final audit confirms all 135 hashed inputs and the complete source diff are unchanged. Trace cleanup found no generated trace-validation files to remove.

Full-protocol acceptance remains incomplete: the default excludes PEEK and three-call single-thread histories, and the latest harness does not meet the unchanged 20% overlap gate. Cleanup liveness was not rerun. These results do not waive the outstanding spec review, change the harness criterion, promote shared findings, or launch later pipeline phases. The receiving controller retains those decisions.
