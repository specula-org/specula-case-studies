# Validation Review: asterinas-private-futex-requeue

## Status

- Syntax: PASS
- MC: FAIL
- Ready for trace validation: YES

Reviewed on 2026-10-09. The requested `validation-report.md` and optional
`quick-mc.log` are absent. This review uses the existing SANY logs,
[validation status](validation-status.json), [MC run index](output/tlc-runs-round2.json),
and trace witnesses instead. Readiness means that the specification and harness
can replay implementation traces. The concurrency quality requirement remains
unmet.

All three modules passed SANY parsing and semantic analysis:
[base.tla](generation-checks/sany-base-round2.log),
[MC.tla](generation-checks/sany-MC-round2.log), and
[Trace.tla](generation-checks/sany-Trace-round2.log).
Their current hashes and the SANY log hashes match
[generation-manifest.json](generation-manifest.json). All 71 files recorded in
[validated-inputs.json](output/validated-inputs.json) also match their saved
hashes. The source HEAD and tree match the recorded pin
`0c60537098f4c2949ad2d382aaf499de72263d76` and
`4693fdec88cd7da14bed4f1541eba593f123059c`. The worktree contains the existing
instrumentation changes. This review inspected existing evidence and ran no new
SANY, TLC, build, or guest execution.

The aggregate MC status is FAIL because seven targeted searches report invariant
violations, grouped into four known implementation defects in
[bug-report.md](bug-report.md). These are expected counterexamples for the
unchanged source model. The recorded classifications and inspected source paths
support implementation defects, with no new unclassified specification failure
found in the reviewed logs.

| Finding | Violated properties | Source behavior |
|---|---|---|
| MC-1 | `ResourceAccountingBalance`, `LiveMigrationExhaustion` | Cleanup searches the original bucket after cross-bucket migration. The stranded closed entry can consume a later migration slot. |
| MC-2 | `RequeueWakeQuota`, `RequeueQuotaAndResult` | REQUEUE converts a zero wake quota to one. |
| MC-3 | `RequeueMoveQuota` | Same-bucket migration checks its quota after rekeying an entry, so a zero quota can still move one. |
| MC-4 | `RequeueReturnCount` | REQUEUE returns only the wake count. The same-address shortcut also omits requeues from the result. |

Core `MC.cfg` checking is TIMEOUT: both
[BFS](output/MC-round2-bfs.out) and
[simulation](output/MC-round2-simulation.out) reached their 30-minute budgets
without a reported violation. BFS reached depth 6 with 32,032,634 distinct
states and 31,433,627 still queued. Simulation checked 29,203,838 states across
117,692 traces. Across the complete run index, nine searches exhausted their
configured state spaces without violation, seven found the counterexamples
above, and six BFS/simulation runs exhausted their budgets. Three of the nine
completed searches are residual checks with the already-classified oracle
removed. These results establish bounded exploration, not an exhaustive pass
for the full suite.

Trace replay prerequisites are present: [Trace.cfg](Trace.cfg) enables
`PROPERTIES TraceMatched`, and [Trace.tla](Trace.tla) checks complete,
action-specific post-state records through `ValidatePostState`. All 18 recorded
implementation traces have complete replay witnesses. Reclassification of the
raw logs confirmed that each successful witness violates only the deliberate
`TraceIncomplete` sentinel and ends with every cursor at its stream length plus
one. Cases 13 and 14 initially hit `TraceMatched` temporal failures on dead
branches. Their subsequent reachability runs with `-lncheck final` found complete
witnesses using the same configuration. Those initial failures are inconclusive
for existential replay, and the sentinel failures are expected replay success.
See [round2-trace-results.json](output/round2-trace-results.json).

Instrumentation already exists and produced 1,341 events covering 53 of 57
actions on two guest CPUs. No additional probes are required to replay these
captures. However, [coverage.md](../harness/coverage.md) records a maximum raw
cross-thread overlap of only 0.382%, below the required 20%. Cross-CPU clock
comparability is unproved, and no same-CPU cross-stream overlap was observed.
Conservatively widened replay timeboxes do not establish actual concurrency.

## Next Steps

- Supply `validation-report.md` with links to the current evidence. Distinguish
  core MC timeouts, classified hunt violations, complete replay witnesses, and
  the unmet concurrency requirement. The generation-stage statements that
  implementation traces are unexecuted predate the later captures.
- Before claiming concurrency-qualified validation, adjust workload coordination
  and timing capture to demonstrate the required real overlap. Establish clock
  comparability or suitable same-clock evidence, while preserving per-thread
  order, proven synchronization dependencies, zero-loss records, and complete
  call lifetimes as specified in [instrumentation-spec.md](instrumentation-spec.md).
- Exercise the existing `FutexWaitFault`, `FutexWaitFaultUnlock`,
  `HandlePageFault`, and `WaiterSpuriousReturn` probes, which have no runtime
  coverage. Capture the competing registration/store-WAKE history and both
  outcomes of the close wake/timeout race that the current attempts do not
  establish.
- Retain MC-1 through MC-4 for implementation follow-up and preserve their
  counterexamples. Keep the reference model faithful to the pinned source and
  continue reporting budget-limited searches separately from completed checks.

## Verdict: NEEDS_IMPROVEMENT

The specification is usable for trace validation, and the existing captures
replay successfully. Acceptance of the validation package still requires the
missing report and the unmet concurrency evidence.
