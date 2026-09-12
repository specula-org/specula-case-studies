# Validation Review: temporal-matching

## Status

- Syntax: PASS
- MC: TIMEOUT
- Ready for trace validation: YES

Readiness applies to the documented Matching / SQLite V1 scope and the separate root-validator trace extension. Full-model convergence remains **INCOMPLETE**.

Reviewed on 2026-09-11 for source `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, using the current [validation report](validation-report.md), retained run receipts and raw logs. `quick-mc.log` is absent. This review supersedes the earlier review of the pre-continuation artifacts; its previous contents are preserved with the [review evidence](output/review-validation-20260911-current-hg665q6v/results.json).

**Syntax:** Fresh SANY checks passed for all **16 current top-level TLA+ modules**, including `base`, `MC`, `Trace`, the contract/scenario modules and validator extensions. Each check used a byte-identical isolated copy, exited 0 and completed semantic processing without errors. Current model/config hashes match the retained active trace results and all dependencies of the ten completed MC scopes. This review reran SANY and audited retained evidence; it did not rerun TLC exploration or recollect implementation traces.

**MC:** Nine detailed bounded checks completed with no errors and empty exploration queues: core, ownership, read/backoff, submitted-write uncertainty, replacement, GC, two conditional recovery checks and root validation. The separate conditional composition check also completed. Recovery depends on the stated processing/stability assumptions; composition assumes sound ack prefixes and a closed write boundary. These checks establish their individual bounded results, without establishing exhaustive coverage of their combined behaviors. See the [run index](output/continuation-20260911/verification-results.json).

The original `MC.cfg` run, on its archived earlier model snapshot, timed out after 1,800 seconds plus kill grace (exit 137): its last sample was **307,620,915 distinct states, depth 16, 196,911,151 queued**. The current-model original-bounds projection and wider acceptance/read/replacement searches also remain incomplete. Four depth-100, 120-second simulations observed no priority invariant violation; they are exploratory results. Consequently, the overall MC status remains **TIMEOUT**, with no global convergence claim.

**Violations and errors:** The final deliberate over-deletion control violates `WorkCovered`; disabling write fencing violates `FencedWrites`. Both are expected mutation-control counterexamples, not Temporal findings. Earlier temporal-DNF expansion errors and the control model's unassigned `badFence` variable were addressed before the completed replacement runs, as recorded in [changelog.md](changelog.md). No unexpected priority-model invariant violation is reported. The separate SQLite V2 fairness diagnostic remains one existing code-origin candidate, **CR-4 / S5-MC-5**, with controlled reproduction and independent confirmation pending; it is outside the priority trace verdict and is not an MC discovery. See [fairness-diagnostic.md](fairness-diagnostic.md).

**Trace readiness:** All **24/24 active complete traces** have matching hashes, nonzero completed replay graphs, zero queued states, complete bootstrap-to-`TraceEnd` consumption and retained readback/evidence sidecars. All **8/8 main controls** reject, including the three bootstrap state/provenance controls that previously returned zero-state success. Two additional validator controls reject at their changed events. `TraceInit` now asserts bootstrap validity, the runner rejects zero-state success, both trace configs enable `TraceMatched`, and post-state comparison checks actual fields. The previous readiness blocker is resolved. Observed **84/88 action types** describe action coverage, not product or interleaving coverage. The historical 32 traces belong to their archived models. See the [active replay results](output/continuation-20260911/final-replay/validation-results.json).

## Next Steps

- Continue trace validation using the existing [harness](../harness/INSTRUMENTATION.md): one unversioned root Workflow queue, priority 3, new matcher enabled, fairness disabled, singleton writes and real file-backed SQLite V1. Existing instrumentation already supports this scope. Use `TraceValidator` for valid/obsolete/canceled root-validation outcomes and retain the actual age guard and recorded idle timeout.
- Preserve separate observations of store commit versus return, sync publication versus Add receipt, History result versus Worker receipt, allocation/replacement retries, independent backoff, read/bypass, owner lifetimes, ack/metadata and GC. Require actual SQL identities/request bounds, mandatory post-state groups and independent final readback through `TraceEnd`.
- Before adding `Crash`, `DiscardCrashedWriter` or `PollerDisconnect` traces, implement external process/transport observation that independently resolves outstanding store and History effects. A terminated process cannot supply post-crash callbacks; unknown effects must remain unresolved.
- Before claiming `ObsoleteTask` coverage or real History durability, add actual History lifecycle/stamp and acceptance/recovery observations. Root-validator interface outcomes do not establish the full History lifecycle. Alternative backends and full fairness validation need their own model and instrumentation evidence.
- Preserve the original timeout and wider incomplete frontiers. Any broader convergence claim requires further completed verification with explicit bounds and assumptions. Revalidate traces after model changes; route CR-4 separately to confirmation/classification and count its existing mechanism once.

## Verdict: PASS

PASS for proceeding with trace validation within the documented scope. Overall MC verification remains **INCOMPLETE**.
