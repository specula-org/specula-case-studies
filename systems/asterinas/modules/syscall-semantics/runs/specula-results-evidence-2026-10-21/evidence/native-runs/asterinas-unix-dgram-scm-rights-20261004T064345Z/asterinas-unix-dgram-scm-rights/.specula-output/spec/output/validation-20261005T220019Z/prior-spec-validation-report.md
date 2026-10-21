# Specification validation status

Validation is incomplete at Phase 0. The final instrumentation built and ran,
but its cross-CPU clock qualification failed in four fixtures. The new batch
also has no observed cross-thread interval overlap. No trace-validation round,
model-checking round, convergence decision or bug hunting was executed.
These are capture and coverage blockers, not SCM_RIGHTS defect findings.

## Executed attempt

The source is Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`. The
receiving controller held the shared heavy-stage and run locks. The worker
used the existing `harness/run.sh` without changing the instrumentation,
model, invariants, bounds or fixture checks.

From `.specula-output`, the command was:

```sh
timeout --kill-after=20s 1800 bash harness/run.sh
```

The build started with 11,743,496 kB MemAvailable, above the required
10 GiB. Its container used two CPUs, 8 GiB memory, 512 PIDs, two Cargo jobs
and an individual `/dev/kvm` device. The guest used two CPUs and 2 GiB.
The build exited 0. QEMU exited 33, but the test program reported
`SCM_DONE 1`, so the harness correctly exited 1. QEMU's exit alone is not
fixture acceptance. The container was removed, and the owned launcher and
waiter were reaped. No job from this attempt remains active.

[Input hashes and resource records](../harness/evidence/20261005T200356Z/inputs.sha256),
[build log](../harness/evidence/20261005T200356Z/build.log),
[guest log](../harness/evidence/20261005T200356Z/guest.log), and
[binary hashes](../harness/evidence/20261005T200356Z/binaries.sha256)
identify the executed revision. The kernel ELF SHA-256 is
`e62e70d1528c6796b1f467f5c81933c8cb20695f6bde8f9cecbc338adaa983f1`.

## Clock qualification

The fixture checks `before <= remote && remote <= after` using 128
cross-CPU exchanges before sending the test message. Four fixtures failed:

| Case | Sample | Local before | Remote | Local after | Failure |
| --- | --- | --- | --- | --- | --- |
| 00 | 4 | 20278911008 | 20278912061 | 20278911825 | Remote is 236 cycles after the enclosing interval. |
| 07 | 1 | 46210020447 | 46210020433 | 46210021135 | Remote is 14 cycles before the enclosing interval. |
| 10 | 17 | 55300894209 | 55300895091 | 55300895026 | Remote is 65 cycles after the enclosing interval. |
| 21 | 11 | 116951950688 | 116951951343 | 116951951333 | Remote is 10 cycles after the enclosing interval. |

The rebuilt kernel and user fixture contain `MFENCE`, `LFENCE`, `RDTSC`,
and the trailing `LFENCE` in order. This is established by the saved
[compiled hook disassembly](output/validation-20261005T200356Z/compiled-hooks.txt)
and [user clock disassembly](output/validation-20261005T200356Z/userspace-clock-disassembly.txt).
The current LFENCE revision was therefore exercised. The evidence does not
isolate the reason for the cross-CPU discrepancy. No host or kernel root cause
is assigned, and no offset, timestamp widening or rejected-case filtering was
applied to the traces.

The local default monotonic clock also derives from `read_tsc`
(`kernel/core/comps/time/src/tsc.rs:31`). Its clock-record read takes a shared
lock (`kernel/core/comps/time/src/clocksource.rs:97`). It is not an established
independent clock substitute for this instrumentation. The local KVM clock
helper only exposes a frequency estimate, not a validated per-CPU timestamp
conversion API.

Nineteen fixtures passed their local calibration checks and emitted 899 raw
events covering all 34 action names. This partial batch is retained only as
raw diagnostic evidence. It does not replace the missing accepted batch.
The harness stopped before Linux control execution, normalization or replay.

## Concurrency coverage

The timebox skill's minimum-quality section says, "At least 20% of event
pairs across different threads should have overlapping `[start, end]`
intervals." The new competition cases 17 and 18 each contain 936 cross-thread
pairs and zero overlapping pairs. In case 18, the ordinary receiver won queue
selection and the PEEK attempt observed an empty queue. Its raw result does
not supply overlapping PEEK/ordinary publication coverage.

This run also confirms a structural limitation of the current fixture shape.
Setup and cleanup happen outside receiver execution. In each new competition
case, the receiving threads have 26 and 5 disjoint intervals. Two strictly
ordered, internally disjoint interval lists of lengths `n` and `m` can have
at most `n + m - 1` intersections: each intersection consumes the next ending
interval in at least one list. Even their 30-pair upper bound is only
`30 / 936 = 3.205%` of all cross-thread pairs. Scheduling retries cannot meet
20% for these fixed event counts and serialized setup/cleanup. The earlier
successful-PEEK competition trace has an upper bound of `50 / 2384 = 2.097%`.
These bounds describe those fixture shapes, not all possible harness designs.
No interval was widened or event omitted to change the denominator.

## Phase gate and retained evidence

The [validation-workflow skill](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/SKILL.md)
delegates to its [guide](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/guide.md),
which requires: "Complete each phase fully before switching."
The [harness-generation skill](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/SKILL.md)
and its [timebox reference](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/references/concurrent-timebox-guide.md)
require actual overlap and the clock-based partial ordering. This attempt
cannot satisfy those prerequisites. Proceeding would relax the requested
methodology, so the phase remains incomplete.

All original TLA+ modules, configuration files and 23 canonical trace files
still match the [initial hashes](output/validation-20261005T200356Z/initial-inputs.json).
The old traces remain explicitly provisional for clock ordering. Their older
23 successful replays are not evidence that the final instrumentation passed.
The [machine-readable result](output/validation-20261005T200356Z/phase0-result.json)
records the fresh measurements and unchanged-input checks.

No Case A, B or C classification was made because there was no new TLC
counterexample. AST-32 and AST-36 remain existing leads. Zero new defect
candidates means none were produced during this blocked attempt, not that
model checking found no defects. `bug-report.md` and `findings.json` were not
created: the workflow produces them only after convergence and hunting, and
an empty findings index would incorrectly signal a completed zero-finding run.
Confirmation, severity classification, repair and shared-catalog updates were
not run.

Before this phase can continue, the receiver needs an attributable trace batch
with qualified cross-CPU timestamps and actual overlapping protocol events.
The 20% criterion also needs a compliant fixture design or an explicit
controller decision about the conflicting quality requirement. This worker
has not waived it. Existing trace validation, invariants and bounds remain
unchanged for the next attempt.
