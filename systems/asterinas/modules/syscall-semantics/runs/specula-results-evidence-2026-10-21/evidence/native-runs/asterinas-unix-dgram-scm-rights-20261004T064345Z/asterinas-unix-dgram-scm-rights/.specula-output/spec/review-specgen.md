# Spec Generation Review: asterinas-unix-dgram-scm-rights

Reviewed the eight requested files on 2026-10-09 against Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`.
The source working tree contains existing instrumentation changes, so source annotations and control flow were checked against the committed files.
The review also inspected the scenario, compatibility, cleanup and witness-search configurations.
[Input hashes](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/output/specgen-review-20261009T154332Z/input-hashes.json) identify the reviewed bytes.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All four scenarios have corresponding ownership state, actions and hunt configurations. Linux behavior is explicitly represented by compatibility predicates and external controls. |
| Action Design | 5/5 | Implementation-based names and separate queue selection, clone/move, unlock, header, insertion, integer-copy and destructor boundaries preserve the relevant interleavings. |
| Source Annotations | 5/5 | All 84 distinct cited source ranges in the model, MC wrapper and instrumentation document resolve. Inspected branches match the pinned source, and fixture restrictions are distinguished from implementation behavior. |
| Invariant Coverage | 5/5 | All ten brief safety properties are defined and enabled in hunt configurations. Cleanup liveness has weak fairness and a configuration without symmetry. The repaired PEEK oracle rejects a consuming mutant. |
| MC Spec Structure | 3/5 | Reactive steps have no counter limits. Fixture admission and fault counters, receiver symmetry and a full-state view are present. However, the default configuration excludes every PEEK execution, including the central mixed-publication scenario. See issue 1. |
| Trace Spec Design | 5/5 | There are no silent actions. All 34 wrappers call full base actions and validate mandatory post-state fields. Timebox ordering, terminal cleanup and the documented completion-witness fallback are implemented. |
| Instrumentation Mapping | 5/5 | The 34 base actions, dispatch cases, required-field definitions and mapping rows agree. Capture rules distinguish actual reference release, copy coverage, cursor rewind and observations protected by existing locks. |
| Logical Correctness | 5/5 | All three modules pass fresh SANY parsing and semantic checks. Inspected ownership, fault and reporting transitions match the implementation. Positive, negative and mutation probes behave as specified. |

## Overall: 38/40

## Issues Found

- **1. [P2] The default MC configuration removes the PEEK mechanism from convergence checking.**
  [MC.cfg:19](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/MC.cfg:19) sets `PeekLimit = 0`, while [MC.tla:29](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/MC.tla:29) requires `budget.peek < PeekLimit` before admitting a PEEK.
  Since the counter starts at zero, no PEEK can begin.
  Consequently, the default run cannot check clone ownership, repeated PEEK, PEEK output faults, or the earlier-PEEK/later-ordinary publication interleavings required by [Scenario 2](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/../modeling-brief.md:36).
  A successful ordinary-only run would remain successful even if the PEEK clone transition were incorrect.

  The base model and hunt configurations retain these paths, so this is a configuration coverage defect, not a missing base action.
  The [coverage audit](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/brief-coverage.md:243) accurately records the restriction and the incomplete mixed-call alternatives.
  Its narrower completed companions do not establish the four-right Full mixed PEEK/ordinary state space.
  Restore at least one PEEK and one ordinary receive in the default convergence scope, retaining the four-right identity/multiplicity case, and address search cost without removing that interaction.
  Keep repeated-PEEK coverage explicit in the scenario configurations.
  Until then, describe the default result as ordinary-receive coverage, not convergence of all four scenarios.
  The two-slot bound also excludes the recorded three-attempt single-thread history, as documented at [brief-coverage.md:285](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/brief-coverage.md:285).

The previous review's two findings are resolved in the current bytes.
[base.tla:264](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/base.tla:264) records PEEK's after-snapshots from the primed queue.
A fresh isolated mutation check that replaces cloning with consumption now violates `PeekPreservesQueueRights` at state 17, while the unchanged control completes.
[Trace.tla:194](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/Trace.tla:194), `TraceSearch.cfg` and [the acceptance procedure](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/instrumentation-spec.md:233) provide the required complete matching witness when universal `TraceMatched` fails.
The overlap fixture still fails that universal property, then produces the expected complete witness with all safety and terminal checks retained.
These resolved findings are not counted again.

Fresh bounded checks produced the following results.
Every TLC run initialized with one state.

| Check | Observed result |
|-------|-----------------|
| SANY: base, MC, Trace | Parsing and semantic checks passed. |
| Valid synthetic trace | Completed with 56 distinct states and no violation. |
| Overlapping synthetic trace | `TraceMatched` failed, then the witness search violated exactly `TraceNoCompleteMatch` on a complete 56-state path. |
| Corrupted post-state | Witness search exhausted one state without a witness. The documented rule correctly rejects this input despite TLC exit code zero. |
| Truncated trace | `TraceEndComplete` failed. |
| PEEK control and consuming mutant | Control completed with 37 distinct states. Mutant violated `PeekPreservesQueueRights` at state 17. |

[Commands, results and logs](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/output/specgen-review-20261009T154332Z/review-checks.json) preserve these checks.
The isolated probes use copies of the reviewed modules and change only the selected fixture or the explicitly identified mutant.
Two initial MCP launches were rejected before TLC initialization because the launcher omitted the run's fixed resource policy.
The successful wrapper runs explicitly retained the existing 4 GiB aggregate budget, with a 3 GiB heap, 512 MiB off-heap allocation, one worker and a one-minute limit.

This review did not rerun exhaustive scenario searches, cleanup liveness, production traces, kernel tests or Linux controls.
The single-message buffer constraint is deliberately redundant, and `MCView = mcVars` performs no state reduction. Neither silently discards behavior.
AST-32 and AST-36 remain the separately checked, previously identified compatibility leads.
No reviewed specification, configuration, instrumentation document, modeling brief or source file was changed.

## Verdict: NEEDS_IMPROVEMENT
