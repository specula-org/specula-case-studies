# Receiving-controller decision for Phase 2 model checking

This note was written by the receiving controller of run
`asterinas-unix-dgram-scm-rights-20261004T064345Z`, not by a phase agent. It
answers the Phase 2 blocker in `validation-report.md` (attempt
`validation-20261005T220019Z`): the unchanged `MC.cfg` reached its 30-minute
budget with a nonempty queue, so the workflow could not establish convergence
or start hunting. It changes no model, invariant, configuration, trace or
acceptance rule.

## Facts already established

`MC.cfg` at the brief's starting bounds has now stopped on a time limit three
times with no reported violation:

- 5,400 s, 25,166,056 distinct states, depth 35, 5,270,015 queued
  (`generation-checks/MC.log`, revision 1);
- the 30-minute Phase 2 run in this validation attempt, 12,442,357 distinct
  states, depth 33, 3,385,376 queued.

The reviewed suite (spec review PASS, 40/40) already contains companion
configurations that differ from their originals only in `AllowedLayouts`,
operation budgets or `RightsCount = 3`. They keep two receivers, the same
invariants and at least 16 free receiver slots. Twenty-five of them completed
exhaustively with no violation. `generation-checks/README.md`, section
"Revision 2: completing companion configurations", lists each one with its
exact constants, what it covers and what it gives up.

## Decision

1. For Phase 2 in this run, exhaustive model checking is established by the
   completing companion set, not by `MC.cfg` at its original bounds. Rerun
   every revision-2 companion that completed, under the lane's 4 GiB / two-
   worker limit, and require each to complete again. Any violation is handled
   by the normal Case A/B/C procedure.
2. `MC.cfg` at its original bounds stays in the record as time-limited, not
   passed. Do not report it as complete, and do not shrink its bounds.
3. Convergence may be declared over the completing companion set together
   with the 23 accepted traces. Every statement of convergence or of a
   negative result must name that bounded scope: which layouts, operation
   budgets and rights counts completed, and which original-bound searches
   (including original-bound cleanup liveness) remain time-limited.
4. Then run hunting as the workflow specifies. A hunting configuration that
   reaches its time budget is recorded as time-limited, not as a pass. The
   three compatibility configurations are expected to violate
   (`NoFailedNumberInstalled` and `ReportedPrefixMatchesLinux` for existing
   AST-32, `PayloadFaultConsumptionMatchesLinux` for existing AST-36). Report
   them as findings with that attribution, not as new defects.
5. Produce `bug-report.md` and `findings.json` as the workflow specifies once
   hunting has run. An empty finding list is not allowed if the compatibility
   counterexamples appear; a list containing only those known leads is
   allowed.

The resource policy is unchanged:
`/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json`.
