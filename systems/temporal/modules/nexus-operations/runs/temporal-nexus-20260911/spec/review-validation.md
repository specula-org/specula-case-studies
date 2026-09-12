# Validation Review: temporal-nexus

## Status

- Syntax: PASS
- MC: SKIPPED
- Ready for trace validation: NO

Reviewed the [validation report](validation-report.md), recorded check logs, current specification and [instrumentation handoff](instrumentation-spec.md). All 11 current module/configuration hashes match the final [validation summary](output/validation-20260911/validation-summary.json), which pins source revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. This review assesses existing evidence; it does not rerun validation.

**Syntax:** `base.tla`, `MC.tla` and `Trace.tla` all passed SANY, with exit code 0 and successful semantic processing in the final logs. The earlier missing-`IOUtils` error came from omitting `CommunityModules.jar` from the syntax handler's classpath; the recorded combined-classpath checks passed.

**MC results:** `quick-mc.log` is absent. Neither `MC.cfg` nor the five full hunting configurations ran for this revised specification because Phase 1 trace validation did not pass. Consequently, there is no current MC verdict or current MC counterexample to classify. The [earlier generation checks](checks/validation.md) recorded a completed small baseline (18,491 distinct states, empty queue) and expected B1 `RequiredTimerPublished` and B2 `TerminalCapacityReclaimed` violations. Those witnesses represented previously identified source/runtime behaviors, not new MC discoveries, and belong to the earlier specification. They cannot establish a PASS for this revision.

**Readiness:** The final gate accepted **0/21 original and 0/11 fresh recordings**. Individual [replay logs](output/validation-20260911/final-replay/) report `Cannot convert value: unsupported JSON value null` during input decoding, before state replay. The aggregate `trace_mismatch` label therefore does not demonstrate a Temporal invariant violation or a semantic counterexample. The complete observation-derived post-state stream remains unfinished. Eleven successful functional executions, nine observer negative controls and five passing partial-state boundary diagnostics provide useful evidence, but do not establish full implementation/model agreement or strict TLC negative-control coverage.

## Next Steps

- **Complete instrumentation and the semantic join.** Reuse existing raw recordings and add hooks wherever required observations are missing. Capture complete durable/workspace HSM state, history and buffers; logical timers and physical wakes; actual wire identities and endpoint outcomes; SQL/append receipts and post-reacquisition readback; and transaction-return/caller-response boundaries. Include physical task publication, local delivery and acknowledgment ownership: persisted queue rows alone do not define available tasks. Preserve immutable identity aliases, independent call/callback ordinals, causal ordering and receipt provenance. Produce the required Init header and full `post`/`evidence` records without deriving observations from model execution.
- **Resolve input encoding.** Produce a semantically justified TLC-compatible representation of optional values while retaining raw receipts. Fixing JSON null conversion alone will not complete the missing semantic join. Mark observer completeness only after all required fields and boundaries are accounted for.
- **Correct remaining transaction boundaries.** Align WFT completion, subsequent commands and close preparation within the actual transaction; model frontend-to-history callback retries through the final caller observation. Preserve the documented bootstrap, buffering, timer-batch, refresh and definite-pre-store-failure corrections.
- **Resolve time semantics.** The report's exact affine mapping exceeds TLC's int32 range in 19/32 recordings. Use a justified representation preserving deadline and minimum-budget comparisons and retry jitter. Represent logical deadlines separately from physical wake visibility. Add a stored deadline/elapsed-time guard to `RequestDeadlineExceeded` and distinguish expiry from immediate transport failure.
- **Establish strict trace acceptance.** Replay all 32 complete implementation traces with full post-state equality and `TraceMatched` enabled. Run TLC negative controls for forged identities, missing timers/events, false commit/Accepted claims, queue/DB mismatches, unmatched suffixes and empty input. Authentic B1/B2 behavior must remain replayable; observer-audit rejection alone is insufficient.
- **Resume convergence and MC afterward.** Once traces pass, run `MC.cfg` for the prescribed duration, classify counterexamples and repeat trace validation after specification changes. Complete the outstanding progress/fairness and workflow-observation obligations, then run all five hunting configurations with the required BFS/simulation strategy and unchanged fault bounds; justify any necessary time-horizon adjustment.

## Verdict: NEEDS_IMPROVEMENT

Syntax is validated, but input conversion, instrumentation/join completeness and remaining model-fidelity gaps block meaningful strict trace replay. MC remains unexecuted for the current specification.
