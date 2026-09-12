# Validation Review: temporal-reset

## Status

- Syntax: PASS
- MC: PASS
- Ready for trace validation: YES

These statuses cover the current `base.tla`, `MC.tla`, `Trace.tla`, the bounded standard `MC.cfg`, and the existing SQLite harness. Broader hunting has violations and incomplete searches, as detailed below. The verdict concerns the remaining handoff problems, not a failure of the completed standard MC or trace batch.

The requested `validation-report.md` and optional `quick-mc.log` are both absent. This review instead checked [validation-result.json](validation-result.json), the retained raw logs, immutable round-2 inputs, and harness evidence. Source HEAD is `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. All eight entries in [final-hashes.json](output/validation-20260909/final-hashes.json) and all 27 model/config/trace entries in the [final trace manifest](output/validation-20260909/trace-09/hashes.json) match the current files. MC and trace executions below are audited historical results; only SANY was rerun for this review.

**Syntax:** Fresh SANY parsing and semantic analysis passed for all three delivery modules (`base`, `MC`, `Trace`), each with exit 0 and no reported errors. Earlier SANY receipts also exist in [checks.json](validation/checks.json), but predate the final model refinements.

**Standard MC:** [MC-round2.out](output/validation-20260909/MC-round2.out) completes with **78,636 generated / 38,109 distinct states, zero queued, depth 54**, and no checked invariant violation. Its saved base/MC/config inputs match the current files. The one-element symmetry warning is nonblocking. This small configuration disables fault injection and Update/Signal inputs; scenario-specific contract invariants are enabled separately in hunts.

**Other violations:** The SQL and Cassandra replay simulations violate `ImmediateRetryIdentity`, reconfirming the expected prior T-1 identity defect. The short-age SQL BFS violates `AcknowledgedResetExists`: a conditional scanner/publication finding, not an expected successful check or evidence of failure at the default scanner age. Its model counterexample uses Start; separate recorded implementation probes exercise Start and Reset. These are two finding mechanisms, not three distinct bugs. The remaining 12 BFS searches and 10 non-violating simulation runs are time-limited **INCOMPLETE**, including liveness. See [bug-report.md](bug-report.md) and its linked raw logs; no unrestricted safety or liveness pass follows.

**Trace readiness:** Instrumentation already exists. The [final batch](output/validation-20260909/trace-09/result.json) passes **8/8 real traces, 619 records**, with **53/64 model action types** and **42/42 durable checkpoints** in the [harness summary](../harness/evidence/execution-summary.json). All eight TLC logs report successful completion. Full post-state equality and `TraceMatched` remain active. The [final corruption control](output/validation-20260909/negative-final-round2/result.json) fails at the deliberately changed last record, line 64, as expected. Coverage is file SQLite, one shard, I/O capacity 1; recorded shard/cache reloads do not establish OS-process restart behavior. Trace matching checks implementation/model agreement, so it can pass while a hunt contract fails.

## Next Steps

- Correct the instrumentation handoff before building another recorder: [instrumentation-spec.md](instrumentation-spec.md) still prescribes `tag: "temporal-reset"`, whereas current `Trace.tla` and accepted traces require `tag: "trace"`. Refresh the stale 57-action generation summary to the current 64-action suite, and provide the missing canonical validation report with links to the final evidence. The documented `generate_*.py` templates predate validation fixes and must be updated before regeneration.
- Continue the existing SQLite harness with `Bootstrap`, exact action arguments, complete snapshots, independent durable readback, and distinct issuance/commit/return/client-receipt observations. No additional instrumentation is required to replay the eight existing traces.
- Before expanding trace coverage, capture the 11 currently uncovered actions listed in [harness validation](../harness/evidence/validation.json): Update acceptance/completion; Cassandra current-read issuance/assertion and branch row/range deletion; request expiration; scanner age/verification; append timeout; and transient read failure. Cassandra needs actual backend observation, and scanner traces need observed age/deadline settings.
- Extend the model and recorder together before accepting multipage reapplication, buffered termination events, or admitted-then-accepted Update histories. Add actual process termination/restart and already-issued remote-write completion observations before claiming crash recovery coverage; different-base concurrent Resets and SQL I/O capacity 2 also remain outside the accepted trace suite.
- Preserve the two findings and classify unfinished hunts as `INCOMPLETE`. After any model changes, rerun SANY, affected real traces plus a corruption control, and standard MC against the same revised inputs.

## Verdict: NEEDS_IMPROVEMENT

The current suite is ready to continue trace validation within its demonstrated SQLite scope. The missing canonical report and contradictory instrumentation instructions need correction for a reliable new-harness handoff.
