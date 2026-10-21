# Validation changelog

## Phase 0 - Initialization

- The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`. The receiving controller holds the run and shared heavy-stage locks. TLC is limited to 4 GiB and two workers.
- All specification, configuration and instrumentation files exist. `Trace.cfg` enables `TraceMatched`, and `ValidatePostState` compares captured fields after full base actions.
- The inherited harness status is incomplete: the final ordered-clock patch was not built, the earlier 23 traces have provisional clock ordering, and the 20% cross-thread overlap criterion was unmet. Regeneration is required before convergence can be claimed. Original input hashes and harness status are preserved in `output/validation-20261005T200356Z/`.

- The fresh attempt `20261005T200356Z` built the final instrumentation successfully but failed clock qualification in cases 00, 07, 10 and 21. The guest reported `SCM_DONE 1`, and the harness exited 1 before normalization or replay. Compiled evidence confirms the final fence sequence.
- The new competition cases 17 and 18 each have 0 overlapping pairs out of 936. The 20% timebox criterion remains unmet. No specification, invariant, bound or canonical trace was modified.

## Result

Validation is incomplete at Phase 0. No convergence round or bug hunting was run. No new defect candidate was produced. See [the validation report](validation-report.md) and [status](validation-status.json) for exact evidence and the remaining prerequisites.
