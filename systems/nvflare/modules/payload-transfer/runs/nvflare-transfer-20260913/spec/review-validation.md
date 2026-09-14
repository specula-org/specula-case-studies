# Validation Review: nvflare-transfer

## Status

- Syntax: PASS
- MC: FAIL
- Ready for trace validation: NO

Reviewed existing artifacts for source `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The recorded trace corpus passes, but unresolved source/model timing and control-flow differences prevent unconditional readiness approval. This review inspected logs, receipts, hashes, specifications, instrumentation and pinned source; it did not rerun SANY, TLC or runtime tests.

**Syntax.** All three modules (`base.tla`, `MC.tla`, `Trace.tla`) passed SANY, supported by [artifact-checks.json](checks/artifact-checks.json) and the three `checks/*-sany.log` files. Current module/configuration hashes still match those generation checks. All 42 entries in [initial-manifest.json](output/initial-manifest.json) and all 14 artifact hashes in [final-audit.json](output/final-audit.json) also match current files.

**MC results.** `quick-mc.log` is absent; the completed validation phase provides substantive MC logs and task receipts instead. Overall MC is FAIL because three hunts found invariant violations:

| Check | Result | Interpretation |
|---|---|---|
| [Main MC](output/MC_round1_summary.json) | TIMEOUT, exit 124 | Normal 30-minute budget termination without a violation: 188,559,267 distinct states, depth 21, 103,310,511 queued. Search remains incomplete. |
| [S1 progress](output/MC_hunt_s1_progress_bfs_summary.json) | FAIL, exit 12 | `CompletedProgressHasReceiverSuccess`; 35-state counterexample, classified MC-2 / Case C. |
| [S3 settlement](output/MC_hunt_s3_settlement_bfs_summary.json) | FAIL, exit 12 | `SingleSettlementEffects`; 77-state counterexample, classified MC-1 / Case C. |
| [S3 after receipt](output/MC_hunt_s3_after_receipt_bfs_summary.json) | FAIL, exit 12 | `NoSettlementEffectsAfterReceipt`; 94-state counterexample supporting the same MC-1 finding. |
| [S4 BFS](output/MC_hunt_s4_budgets_bfs_summary.json) and [simulation](output/MC_hunt_s4_budgets_sim_summary.json) | TIMEOUT, exit 124 each | Both completed their 30-minute budgets without a violation. BFS reached 163,706,943 distinct states at depth 21; depth-100 simulation reported 4,664,773 model traces. Neither establishes exhaustive correctness or liveness. |

The violations match the intended hunting hypotheses; they are classified findings, rather than unexpected parser/startup failures. The [findings](findings.json) retain important limits: MC-1 has controlled-injection trace support but no established natural production trigger; MC-2's exact contradictory-progress schedule remains unconfirmed at runtime. Neither establishes false successful strict receipts. Those findings alone do not require weakening the spec or blocking conformance work.

**Trace evidence and readiness blockers.** [Round 1 results](output/round1-traces/results.json) record 16/16 passing implementation traces, 3,029 events and complete cursors; all 16 corresponding TLC logs report success. The audit reports 94/94 action-name coverage. `Trace.cfg` enables `TraceMatched`, and `Trace.tla:169-174` checks exact required field domains and every captured post-state value. Basic instrumentation is already installed.

However, the substantive issues in [review-specgen.md](review-specgen.md) remain in the unchanged modules. Static comparison with `output/pinned-source/download_service.py` confirms:

- **Budget traversal:** `base.tla:568-603` selects using current final status and immediately rechecks/finalizes each candidate. Source lines 475-514 first capture final receivers and build a complete failure list, then enforce it. The model lacks that saved selection state and ordering.
- **Time sampling:** `RefMarkReceiverActive` (`base.tla:195-213`) samples time together with publication; source lines 441-450 sample before acquiring the ref lock. `TransactionDoneDrainBegin` (`base.tla:801-809`) likewise combines sampling and gate closure, while source lines 841-849 compute the deadline before acquiring the condition lock. Elapsed lock-wait time cannot be represented faithfully.
- **Monitor decisions:** `MonitorRetireTimeout` (`base.tla:664-677`) retests current completion at retirement. Source lines 1875-1901 retain an earlier classification before deletion; an already admitted finalizer can update status between those boundaries.

Passing the existing schedules does not resolve these differences. The report's budgeted convergence and absence of Case A/B repairs describe the executed corpus; they do not close these outstanding model-fidelity issues.

## Next Steps

- Repair budget selection to retain the per-ref final snapshot and complete failure list. Update instrumentation to capture actual list construction and subsequent enforcement separately, including candidates finalized after the snapshot.
- Split request/drain time sampling from lock-protected publication/closure, retaining the actual sampled locals. Capture monitor completion and timeout decisions separately from retirement, preserving the relevant lock exclusion.
- Regenerate the model, wrappers and action mapping; retain strict post-state equality and `TraceMatched`. Add local conformance traces covering those repaired boundaries, then replay the existing corpus and rerun affected bounded checks. Existing passing traces remain valid evidence for the unchanged suite.
- Correct the `DownloadObjectStart` example in `instrumentation-spec.md:21-25`: its mandatory `futureStarted` post-state field is missing. This documentation issue is separate from the already populated runtime corpus.
- Preserve the three counterexamples and their confirmation limits. Keep unconfigured temporal properties and incomplete search coverage explicit; neither exhaustive BFS nor a liveness proof is a prerequisite for this trace-readiness review.

## Verdict: NEEDS_IMPROVEMENT

SANY and existing trace replay pass. Readiness approval is blocked by the remaining source/model observation-boundary defects, not by normal budget termination or the mere presence of intended hunting findings.
