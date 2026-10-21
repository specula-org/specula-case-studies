# Validation Review: asterinas-syscall-buffered-file-size-read-consistency

## Status

- Syntax: PASS
- MC: PASS
- Ready for trace validation: YES

`MC: PASS` refers to the structural convergence check in `MC.cfg`. Targeted hunting violations and simulation timeouts are separate results below.

The requested `validation-report.md` and optional `quick-mc.log` are absent. This review uses the available [generation checks](validation/README.md), [final verification summary](output/verification-summary.json), and raw validation logs. Earlier generation and harness reports describe superseded stages.

- **Syntax:** Re-ran SANY on the current `base.tla`, `MC.tla`, and `Trace.tla` with the installed OpenJDK and Specula jars. All three exited 0 without diagnostics. The current base hash matches the final verification summary: `7a0dcf4fc69a69c0e86a726bd89c482517ae94f02c81df6361f99b92a03d4f2f`.
- **Convergence MC:** [MC_round1_foreground.out](output/MC_round1_foreground.out) records completion without errors: 11,270 generated states, 8,131 distinct states, depth 32, empty queue, exit 0. This configuration checks structural invariants; it excludes the outcome predicates used for hunting.
- **Hunting:** [BFS receipts](output/matrix-bfs1.json) record 18 invariant violations, exit 12, and 22 completed searches without violations across 40 configurations. The [bug report](bug-report.md) groups the violations into eight source-backed findings involving ramfs and exFAT accounting, extents, resize, hole contents, and empty/faulting writes. These are substantive candidate implementation defects, not negative-control passes or unresolved syntax errors. Most triggering schedules still need guest confirmation. All 11 ext2 hunting configurations passed within their bounds.
- **Simulation:** All nine follow-ups ended at their 30-minute watchdog budgets with exit 124 and no observed violations. These are bounded searches, not exhaustive passes; see [simulation receipts](output/simulation-final-summary.json). Reviewed MC input hashes and logged outcomes agree with the current files.
- **Expected failures:** The five synthetic mutations to count, progress, output, capacity, and lock observations each produced the intended `TraceMatched` rejection, exit 13. A `TraceNotComplete` violation in witness mode is expected evidence of complete consumption; see [generation results](validation/results.json).
- **Trace readiness:** [Round-one receipts](output/trace-round1-results.json) record matching executions for all 111 immutable guest traces: 108 universal temporal passes and three complete existential witnesses with final cursors equal to event counts plus one. `Trace.cfg` enables `TraceMatched` and structural checks. The earlier two ramfs mismatches were resolved by correcting native VMO batch capacity, without weakening post-state checks. Current trace hashes match the recorded inputs. This review re-ran syntax only; MC and guest results come from the saved runs.

## Next Steps

- Supply `validation-report.md` with links to the final receipts and identify the older 109/111 harness result as superseded. The missing optional quick log does not invalidate the completed MC evidence.
- No additional instrumentation is required to replay the existing 111 traces. Preserve per-thread timeboxes, guard-protected observations, independent copy-cursor progress, and mandatory post-state checks described in [instrumentation-spec.md](instrumentation-spec.md).
- Extend coverage beyond the observed 40/42 actions. Both missing hooks already exist: exercise `VmoRangeError` through a reachable inconsistent-bound schedule, and exercise `ExfatBackendReadBlocked` with a cold-tail fixture plus an external watchdog and ring/stack extraction. A blocked prefix cannot establish syscall completion; current MC checks no kernel liveness property. See [harness coverage limits](../harness/INSTRUMENTATION.md#model-mismatch-and-remaining-coverage).
- Capture physical cluster-reuse receipts and cross-attempt validity before inspecting reused Uninit fragments. Add the initialized-page partial-write case and source-specific failed-read offset assertion identified in [review-specgen.md](review-specgen.md) before claiming full S4 coverage.

## Verdict: NEEDS_IMPROVEMENT

The current spec is ready for trace validation and already matches the recorded guest executions. The required validation report is missing, and the listed coverage gaps limit broader confirmation. Neither gap negates the verified syntax or structural MC pass.
