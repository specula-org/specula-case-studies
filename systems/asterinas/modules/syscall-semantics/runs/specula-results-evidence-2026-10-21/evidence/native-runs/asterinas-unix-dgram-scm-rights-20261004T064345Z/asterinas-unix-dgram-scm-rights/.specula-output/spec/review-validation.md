# Validation Review: asterinas-unix-dgram-scm-rights

## Status

- Syntax: PASS
- MC: PASS (the supplied default `MC.cfg`; hunting outcomes are qualified below).
- Ready for trace validation: YES (replay is operational, but full-protocol acceptance remains incomplete).

Reviewed attempt `validation-20261010T015405Z` on 2026-10-10 against source
`0c60537098f4c2949ad2d382aaf499de72263d76`. `quick-mc.log` is absent, so this
review uses the recorded default and hunting logs. All 135 entries in the
[validation input manifest](output/validation-20261010T015405Z/input-hashes.json)
still match the current files. No SANY, TLC or guest runs were started during
this review.

All three specifications passed SANY parsing, semantic processing and linting
with exit code zero: [base.tla](output/specgen-review-20261009T154332Z/parse-base.log),
[MC.tla](output/specgen-review-20261009T154332Z/parse-MC.log) and
[Trace.tla](output/specgen-review-20261009T154332Z/parse-Trace.log).
The checked copies are byte-identical to the current modules.

The [default MC log](output/validation-20261010T015405Z/MC-round1.log) confirms
exhaustive completion without violations: 13,359,928 generated states,
3,596,537 distinct states, depth 62 and an empty queue after 10 minutes
48 seconds. This checks `MCTypeOK`, `OwnershipConserved`, `QueueStructure`
and `PublicationStructure` at the supplied bounds. It does not establish
all scenario properties or cleanup liveness.

The [20 hunting results](output/validation-20261010T015405Z/hunting-results.json)
agree with their logs: 12 completed without violations, five reached their
30-minute budgets with exit code 124, and three produced expected compatibility
counterexamples. The timed-out configurations are `MC_hunt_scenario1.cfg`,
`MC_hunt_scenario1_separate_tables.cfg`, `MC_hunt_scenario2.cfg`,
`MC_hunt_scenario3.cfg` and `MC_hunt_scenario4.cfg`. Their absence of a reported
violation is incomplete evidence, not a pass.

| Violated invariant | Counterexample | Interpretation |
| --- | --- | --- |
| `NoFailedNumberInstalled` | [31 states](output/validation-20261010T015405Z/MC_hunt_AST32_install.log) | Known AST-32: an FD remains installed after its number fails to copy to user space. |
| `ReportedPrefixMatchesLinux` | [36 states](output/validation-20261010T015405Z/MC_hunt_AST32_report.log) | Known AST-32: two delivered FDs survive a later copy fault, but the reported control length is zero. |
| `PayloadFaultConsumptionMatchesLinux` | [18 states](output/validation-20261010T015405Z/MC_hunt_AST36.log) | Known AST-36: an ordinary payload-copy fault leaves the datagram queued. |

The pinned implementation supports the recorded mechanisms: insertion precedes
integer copying, ancillary errors bypass the length update, and payload copying
precedes ordinary dequeue. These are the existing Case C compatibility findings
documented in [bug-report.md](bug-report.md), not unexpected model failures or
new defect identities. This review did not reproduce them in a guest.

Trace replay readiness is already demonstrated by
[46 successful replays](output/validation-20261010T015405Z/round1-trace-mcp.json):
23 canonical traces and 23 from harness attempt `20261010T014248Z`, using the
unchanged `Trace.cfg`. The latest batch's full logs each show one initial state
and successful completion. `TraceMatched`, mandatory post-state comparisons,
safety checks and terminal cleanup remained enabled. No witness fallback was
needed. The latest normalized traces contain 1,084 events covering all 34 event
types, consistent with the [harness report](../harness/RESULTS.md).

Two acceptance gaps remain. First, [MC.cfg](MC.cfg) sets `PeekLimit = 0` and
`AttemptSlots = 2`. Cases 15, 16, 18 and 21 exercise PEEK, and case 15 makes
three calls on one receiver thread. Fresh case 18 also uses one right instead
of the default four. The [scope audit](output/validation-20261010T015405Z/trace-mc-scope-audit.json)
therefore prevents treating default convergence as coverage of every replayed
class. The [spec-generation review](review-specgen.md) remains NEEDS_IMPROVEMENT.

Second, competition cases 17 and 18 have only 3/936 and 7/899 strict overlaps.
Their whole-trace structural upper bounds are 30/936 (3.205%) and 32/899
(3.560%), both below the unchanged 20% requirement. The
[overlap audit](output/validation-20261010T015405Z/overlap-bound-audit.json)
shows that scheduling alone cannot satisfy the gate with these event inventories.
Successful replay does not satisfy that separate harness requirement.

## Next Steps

- Restore mixed PEEK/ordinary convergence coverage while retaining the four-right
  A/B/A/B identity and multiplicity case. Cover repeated PEEK and the three-call
  single-thread history explicitly. Record each configuration's actual bounds
  and completion status rather than substituting narrower hunting results.
- Resolve the whole-trace overlap requirement conflict with the receiving
  controller before accepting the harness. Any fixture redesign must preserve
  complete lifecycle events and real timestamps. Rebuilding unchanged fixtures,
  removing serialized events or substituting the receive-window denominator
  cannot establish compliance with the current gate.
- No missing event type needs initial instrumentation for the existing replay
  corpus. Reuse the [34-action mapping](instrumentation-spec.md) and
  [implemented hooks](../harness/INSTRUMENTATION.md). Preserve capture, PEEK
  clone/ordinary move, queue unlock, FD insertion before integer copying,
  actual copy coverage, and actual reference-release boundaries. Retain
  per-thread buffers, comparable cross-CPU timestamps and mandatory post-state
  observations when changing fixtures or hooks.
- Address the five incomplete searches and check fairness-based
  `BoundedCleanupProgress` before claiming broader verification. Cleanup
  liveness was not run in this validation attempt. After any model or harness
  change, replay affected traces with the existing checks enabled and retain
  nonzero initialization, input hashes and complete logs as evidence.

## Verdict: NEEDS_IMPROVEMENT
