# Specification validation status

> Receiving-controller note (2026-10-06, not written by a phase agent): read [CONTROLLER-DECISION-2026-10-06-phase2.md](CONTROLLER-DECISION-2026-10-06-phase2.md) before continuing Phase 2. It answers the `MC.cfg` time-limit blocker recorded below.

Phase 0 and Round 1 trace validation passed. The unchanged `MC.cfg` reached its
30-minute budget with no reported violation and a nonempty state queue.
Validation remains incomplete at Phase 2. Convergence is not established and
all 27 hunting configurations remain unexecuted. This is a bounded negative
result, not a kernel defect or an exhaustive pass. The earlier Phase 0 blocker
is resolved, and its evidence remains in `output/validation-20261005T220019Z/`.

## Accepted production traces

Attempt `20261005T220019Z` rebuilt and booted the existing corrected HPET
instrumentation on Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`.
The source, harness implementation, model, invariants and configurations were
unchanged. The build started only after the required 10 GiB memory reserve
cleared, at 17,620,212 kB MemAvailable. The two-CPU, 2 GiB guest reported
`SCM_DONE 0` after all 23 fixtures. Build exit was 0 and QEMU exit was 33.

All 23 fixtures passed 128 cross-CPU clock exchanges. The accepted batch has
1,117 production events covering all 34 event types. Both competition fixtures
have strict overlapping receiver events: case 17 has two pairs and case 18 has
14 pairs. Case 18 includes a successful PEEK and ordinary receive of the same
message. Whole-trace fractions, receive-window fractions and structural bounds
are reported in [the harness results](../harness/RESULTS.md). They meet the
[controller's recorded criterion](../harness/CONTROLLER-DECISION-2026-10-06.md),
which replaced the 20% whole-trace target for this scope. No timestamps were
adjusted and no failed fixtures were omitted from the attempt history.

The [compiled audit](output/validation-20261005T220019Z/compiled-hook-audit.md)
checks the final clock, destructor and installation/publication boundaries
against the booted ELF. Its SHA-256 is
`ef6d75a71f066985b9d668e6831d9bd4f95a406a57dfc1b2add4381e0ed0b32a`.
HPET MMIO measurement overhead can affect scheduling. The clock exchanges and
observed overlaps qualify this guest batch, not every possible execution.

## Round 1 trace validation

All 23 traces passed `Trace.cfg`, including `TraceMatched`, all enabled safety
invariants and `TraceEndComplete`. Every replay had a nonzero initial-state
count. The harness's resource-wrapped replay logs are retained under
[`validation/`](../harness/evidence/20261005T220019Z/validation/).
The Phase 1 MCP replay independently passed all 23 traces, using singleton
batches of `run_trace_validation_parallel` to preserve the 4 GiB lane limit.
Its [results](output/validation-20261005T220019Z/round1-trace-mcp.json) record the
pre-run memory checks. No `TraceSearch.cfg` fallback, spec change or invariant
revision was needed. Generated trace-debugger files were checked for cleanup.

The [Phase 0 evidence record](output/validation-20261005T220019Z/phase0-result.json)
and [static field audit](output/validation-20261005T220019Z/phase0-static-audit.json)
retain the checks and identities. The static audit describes the provisional
batch at attempt start. The Phase 0 result records its subsequent replacement
by the accepted HPET batch. The initial hashes retain both provenance states.

## Model checking

Task `08c1da773e9f4d058fa57a5722f6a8ee` ran the unchanged `MC.tla` and `MC.cfg`
with two workers, a 3 GiB heap, 512 MiB off-heap memory and a 30-minute budget.
TLC initialized with one state and exited 124 when the wrapper's budget ended.
There was no reported invariant violation, evaluation error or out-of-memory
error. A normal budget ending is not itself a CI or implementation failure.
It also does not establish an exhaustive model-checking pass.

The last progress record, at 2026-10-06 06:56:38 Asia/Shanghai, reported:

| Measurement | Last reported value |
| --- | ---: |
| Search depth | 33 |
| States generated | 32,560,435 |
| Distinct states found | 12,442,357 |
| States left on the queue | 3,385,376 |

These are the last reported counters, not final totals. The process ended at
06:57:34 without an exhaustive-completion marker. `MC.cfg` enabled
`MCTypeOK`, `OwnershipConserved`, `QueueStructure` and `PublicationStructure`.
The separate scenario/compatibility invariants and cleanup-liveness property
were not model-checked in this phase. No Case A, B or C classification was
made because TLC produced no counterexample. No invariant, bound or source
transition was altered to change this outcome.

The [TLC log](output/validation-20261005T220019Z/MC-round1.log),
[launcher log](output/validation-20261005T220019Z/MC-round1-launcher.log),
[task result](output/validation-20261005T220019Z/MC-round1-result.json) and
[final evidence record](output/validation-20261005T220019Z/final-result.json)
preserve the command, resource admission, process outcome and coverage limits.
The wrapper removed its temporary checkpoint directory at exit. There is no
retained checkpoint from which to resume this search.

The validation workflow requires completion of Phase 2 before its convergence
check and permits hunting only after convergence. The completed trace round
therefore does not authorize a hunting result here. The
[27-config inventory](output/validation-20261005T220019Z/hunting-plan.json)
records every hunting configuration as unexecuted. Completing the original
`MC.cfg` remains the next verification prerequisite. Repeating the same
bounded search from its initial state would not establish missing coverage,
and shrinking the supplied bounds would violate the workflow.

## Linux controls and known leads

The same userspace source completed 23 fresh controls on Linux 7.2.8. The booted
kernel and scoped source hashes match the existing reconciliation with the
supplied Linux 6.16.5 reference. The [comparison record](../harness/evidence/20261005T220019Z/reference-comparison.json)
keeps return values, errno, control length, flags and FD/object scans separate.
Raw bytes and production copy events remain in the attempt's evidence.

The first-number fault left one Asterinas FD and no Linux FD. Later/partial
third-number faults left three Asterinas FDs versus two Linux FDs, with reported
lengths zero versus 24. The earlier two delivered entries survived in both.
A header fault left no Asterinas FD but retained four Linux FDs despite zero
reported length. Normal payload-fault retry succeeded on Asterinas and returned
EAGAIN on Linux. PEEK retry succeeded on both. These observations retain the
existing AST-32 and AST-36 attribution. They are not new candidates, a change
to the shared catalog, or execution of the separate confirmation phase.

## Phase boundary

The [validation-workflow skill](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/SKILL.md)
delegates to its [guide](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/guide.md),
which requires: "Complete each phase fully before switching." Its Phase 2 also
requires model checking to complete without violations before Phase 3.
No bug-hunting report or findings index was emitted because convergence and
hunting did not complete. An empty findings index would imply a completed
zero-finding run. Zero new candidates here means none were produced, not that
all hunting configurations found no bugs.
The previous failed clock and MMIO attempts remain in the
[attempt history](../harness/evidence/20261005T220019Z/attempt-history.json).
The corrected kernel/harness result does not by itself establish model-checking,
cleanup-liveness or hunting coverage. Confirmation, severity classification,
repair and shared-catalog updates remain outside this phase.

The harness launcher, its waiter and TLC task have all exited. The owned guest
container was removed. The final audit confirms that the accepted traces
still match the replayed bytes and the source, harness implementation, TLA+
modules and configurations still match their initial hashes. The receiver
owns the next phase decision. No confirmation, classification, repair or
shared-catalog action was started.
