# Validation Review: asterinas-local-flock-ownership

## Status

- Syntax: PASS
- MC: TIMEOUT
- Ready for trace validation: YES

This review assesses trace-validation readiness for Asterinas source pin
`0c60537098f4c2949ad2d382aaf499de72263d76`. The requested
`validation-report.md` and optional `quick-mc.log` are absent. The conclusions
instead use [validation-status.json](validation-status.json), the
[bounded campaign report](bug-report.md), and the preserved parser, MC and
trace logs. No quick-MC result is inferred from the missing log.

All three modules passed SANY parsing, semantic processing and linting:
[base.tla](generation-checks/sany-base.log),
[MC.tla](generation-checks/sany-MC.log), and
[Trace.tla](generation-checks/sany-Trace.log). Their current hashes match the
inputs recorded in [the independent spec review](review-specgen.md).
The retained [configuration parser log](config-parse.log) also records
successful parsing of all 19 configurations.

The MC status above describes the general `MC.cfg` search. Its
[process outcome](output/round1-20261005T202037Z/MC-result.json) is exit 124
after the prescribed 30-minute budget. The
[raw log](output/round1-20261005T202037Z/MC-tlc.log) contains no reported
violation. Its last progress record shows 115,549,323 generated states,
20,081,186 distinct states, 10,460,133 queued states and depth 13. These are
last-reported counts, not shutdown totals. Exhaustive convergence remains
unestablished. This configuration enables only `MCTypeOK`, `CompatibleOwners`,
`UniqueOwnerItem` and `Structure`.

The [targeted run ledger](output/round1-20261005T202037Z/tlc-runs.json) and
raw logs show that 13 of 16 hunting configurations exhausted their bounded
graphs without violations. The other three reproduced previously documented
counterexamples:

| Case | Failed check and evidence | Interpretation |
|---|---|---|
| C05 | [ConversionOracle](output/round1-20261005T202037Z/MC_hunt_2_conversion_oracle-bfs.log), 80 states. | A conflicting nonblocking conversion retains the old shared lock and differs from the pinned Linux oracle. |
| C06 | [ConvertersDrain](output/round1-20261005T202037Z/MC_hunt_2_converters-bfs.log), 57 concrete states followed by stuttering. | Both blocking converters retain shared locks and cannot reach their fixture's release operations. |
| C11 | [NoRecursiveListWait](output/round1-20261005T202037Z/MC_hunt_5_temporary_last_reference-bfs.log), 34 states. | A final temporary owner reference triggers cleanup that attempts the already-held list Mutex. |

These are expected reproductions of the campaign's existing hypotheses, not
new parser or model-evaluation errors. They are failed obligations and support
two model-level candidates, with C05 and C06 sharing the conversion mechanism.
Separate bug confirmation has not run. C11 stopped on its safety violation,
so its enabled `FinalReleaseCompletes` property has no separate verdict.

Trace validation has already succeeded for the existing corpus in
[round1-20261005T202037Z](output/round1-20261005T202037Z/trace-results.json).
This review checked all 18 trace hashes, their raw witness logs and final
per-thread cursors. Every supplied event was consumed. The corpus contains
1,481 events covering all 49 action types. C00-open-overlap, C06 and C11 are
preserved prefixes, so their acceptance does not establish syscall completion
or prove a runtime deadlock.

The acceptance rule is the exact Category B adapter recorded in the
[controller decision](validation-controller-decision.md). TLC exit 12 with
only `TraceNoWitness` violated denotes a complete matching interleaving.
Exhaustive exit 0 denotes no matching witness. Timeouts and other errors
remain incomplete or erroneous. `ValidatePostState` checks exact record
equality. The absence of `PROPERTIES TraceMatched` is intentional for this
reviewed existential search. The stock raw-output parser would reverse its
acceptance meaning. The four controller-pinned hashes still match.

The existing v12 instrumentation is sufficient for this corpus. All 35
[runtime-attempt inputs](../harness/evidence/attempt-20261005T165124-821788448/inputs.json),
16 [reviewed harness inputs](../harness/evidence/runtime-reviewed.sha256), and
158 [round artifact hashes](output/round1-20261005T202037Z/artifact-sha256.json)
match their current files. This review read existing evidence and performed
hash/data checks. It launched no SANY, TLC, build or guest execution.

## Next Steps

- Restore the standard `validation-report.md` handoff using the current
  evidence above. Identify the v12 runtime attempt explicitly because the
  top-level harness status files describe an older attempt. Preserve the
  missing quick-MC log as an evidence gap rather than inventing a result.
- Reuse the reviewed v12 harness and
  [acceptance adapter](generation-checks/validate_trace.py) for further traces.
  No additional instrumentation is needed before replaying the current corpus.
  New captures must retain the [instrumentation contract](instrumentation-spec.md):
  FD/OFD identity and lifetime events, flock-list and queue transitions,
  notification/park/unpark boundaries, atomic Arc/Weak outcomes, and actual
  destructor entry and nested lock attempts. Record exact post-state fields
  in per-thread timeboxes without extra owner references or a global logger
  lock. Preserve raw streams, zero-drop evidence and observed SMP information.
- Keep the general MC outcome as TIMEOUT unless a later authorized search
  establishes completion. Preserve all three counterexamples for later
  confirmation. Matching prefixes and successful controls do not close those
  obligations. Any semantic model, oracle or harness correction requires the
  recorded independent review before dependent reruns.

## Verdict: PASS

The current suite is ready for trace validation, and the existing runtime
corpus has matching witnesses under the reviewed adapter. This verdict is
limited to that readiness. It does not establish general MC convergence or
confirm the two implementation-bug candidates.
