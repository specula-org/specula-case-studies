# Validation Review: slatedb-dist-compaction

## Status
- Syntax: PASS
- MC: FAIL
- Ready for trace validation: YES

## Next Steps
- Fix the real MC finding: conflicting externally submitted compactions can both be promoted from `Submitted` to `Scheduled` because the promotion path does not re-run the overlap checks enforced by `add_compaction()`.
- Re-run `MC_hunt_family1.cfg` and `MC_hunt_family5.cfg` after that fix. `MC.cfg` itself only hit its 30-minute budget with no convergence-phase violation.
- Treat the early `trace.trace.out` failure as setup noise, not a spec failure: it was caused by a `../traces/trace.ndjson` symlink loop, while the real per-trace reruns all parsed, semantically checked, and passed.
- The only unexpected post-fix violation was the family 1/5 admission bug. Family 2 was resolved as a model-fidelity issue, family 3's original liveness check was invalid without fairness, and the corrected family 3 safety run plus family 4 both ran clean.
- No new core instrumentation is required for the current trace suite. For broader trace coverage, add a scenario for conflicting external submits and, if needed, close the remaining gaps around `MaybeValidateSubmittedDrain`, `ReleaseClaimPostClaimInvalid`, and `CommitCompactedEntriesFail`.

## Verdict: NEEDS_IMPROVEMENT
