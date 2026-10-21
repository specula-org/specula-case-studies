# Specification validation result

Attempt `validation-20261010T015405Z` is finished with acceptance limitations.
The unchanged default model-checking configuration completed after all 46 trace
replays passed. This is convergence at its supplied ordinary-receive bounds,
not acceptance of the complete target protocol. The inherited PEEK coverage
review finding and harness overlap requirement remain unresolved.

## Completed trace and default checks

All 23 canonical traces and all 23 traces from harness attempt
`20261010T014248Z` passed the unchanged `Trace.cfg`, including `TraceMatched`,
mandatory post-state comparisons, safety invariants and terminal cleanup.
The initial direct replay generated 54 states. The required batch tool ran in
singleton batches to respect its fixed 4 GiB heap. No witness fallback, trace
fix, invariant revision or model change was needed.

The [trace results](output/validation-20261010T015405Z/round1-trace-mcp.json) retain every outcome.
The [harness replay audit](output/validation-20261010T015405Z/attributed-harness-replay-audit.json) confirms
that the latest batch's saved full logs have nonzero initial states and match
the current input hashes. Replay does not satisfy the separate overlap gate.

`MC.cfg` completed with 13,359,928 generated states, 3,596,537 distinct states,
depth 62 and an empty queue in 10 minutes 48 seconds. It enabled `MCTypeOK`,
`OwnershipConserved`, `QueueStructure` and `PublicationStructure`.
It used a 3 GiB heap, 512 MiB off-heap memory, two workers and a 30-minute
maximum. The [full log](output/validation-20261010T015405Z/MC-round1.log) and
[convergence record](output/validation-20261010T015405Z/convergence-result.json) preserve its result.

## Hunting results and classification

20 of 20 supplied hunting configurations have finished.
12 completed exhaustively, 5 ended incomplete, and 3
reported the expected compatibility violations. All completed no-violation
runs retain their actual depth and completion status in the
[ledger](output/validation-20261010T015405Z/hunting-results.json). The [bug report](bug-report.md) lists
every configuration with its bounds and coverage limits.

All owned TLC tasks have exited. [The findings index](findings.json) mirrors the two known identities in the bug report.

Every no-violation BFS reached at least depth 51, above the workflow's depth-25 threshold. No simulation follow-up was required or run. The execution ledger records each decision.

The 31-state `NoFailedNumberInstalled` counterexample and 36-state
`ReportedPrefixMatchesLinux` counterexample are both attributed to existing
AST-32. The 18-state `PayloadFaultConsumptionMatchesLinux` counterexample is
the existing AST-36 boundary control. Source and Linux-reference comparisons
support Case C for these known behaviors. No new defect candidate, Case A/B
repair, source change or catalog promotion was established.

## Resources and preserved work

The receiving controller holds the shared heavy-stage and run locks. This
worker does not reacquire them. Each model-checking run retains a 30-minute
maximum. Paired hunts use a 1,536 MiB heap, 256 MiB off-heap memory and one
worker each, totaling 3.5 GiB and two workers across the lane.
Every launch follows a current `MemFree + Inactive(file)` reserve check.

The [input manifest](output/validation-20261010T015405Z/input-hashes.json) records 135 source, harness,
model, configuration and trace inputs. All matched when the same session
resumed. The [final input check](output/validation-20261010T015405Z/final-input-check.json) confirms their
unchanged bytes after hunting. No completed replay, search or counterexample analysis was restarted.
Previous reports remain in this attempt's `before/` directory.
TLC's logs, process results, JSON counterexamples and generated trace files
are retained under the attempt directory. The trace-cleanup tool found no
generated trace-validation files to remove.

## Acceptance limits

The current [spec-generation review](review-specgen.md) remains
NEEDS_IMPROVEMENT. `MC.cfg` sets `PeekLimit = 0`; four replayed trace classes
use PEEK. Case 15 also contains three successive calls on one receiver
thread, exceeding the default two attempt slots. The
[trace-to-MC audit](output/validation-20261010T015405Z/trace-mc-scope-audit.json) identifies these classes.
Hunting results cannot silently replace the prescribed default convergence scope.

The latest harness remains incomplete under its unmodified 20% whole-trace
overlap requirement. Cases 17 and 18 contain 3/936 and 7/899 strict overlaps.
Their structural upper bounds are 30/936 and 32/899, so scheduling alone cannot
satisfy that requirement with these complete event inventories. The
[independent audit](output/validation-20261010T015405Z/overlap-bound-audit.json) verifies that sender events
are serialized outside the receiver window. No event, timestamp, threshold or
canonical trace was changed. Rebuilding those unchanged fixtures would not
resolve this demonstrated conflict.

Cleanup liveness was not rerun. Terminal trace checks and
`OperationOwnersDrained` safety do not prove `BoundedCleanupProgress`.
The supplied source exclusions remain in force. Later staged reviews,
confirmation and any repair or shared-catalog changes remain with the
receiving controller.
