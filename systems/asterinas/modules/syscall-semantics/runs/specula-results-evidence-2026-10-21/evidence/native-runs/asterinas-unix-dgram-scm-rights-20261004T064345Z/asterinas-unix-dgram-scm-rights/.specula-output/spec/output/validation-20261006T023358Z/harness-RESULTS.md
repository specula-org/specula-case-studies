# Harness execution record

The fresh attempt `20261006T022240Z` built and ran successfully, and all 23
production traces passed the unchanged `Trace.cfg`, including `TraceMatched`
and the terminal cleanup check. Harness generation remains incomplete under
the current request: neither competition trace meets the skill's 20%
cross-thread event-pair overlap requirement. `run.sh` exits 1 after preserving
the successful replays and measured coverage. No failed observation was removed.

The requested source module, scenarios, apply script, run script and
[instrumentation guide](INSTRUMENTATION.md) are present. The fresh traces and
replay logs are in [the attempt directory](evidence/20261006T022240Z/).
The canonical `../traces/case-*.ndjson` files and `evidence/accepted` still refer
to the earlier batch `20261005T220019Z`, accepted under the recorded controller
exception. Their bytes were preserved. `evidence/latest` identifies the fresh,
incomplete attempt. The old results and status are retained in
[the audit directory](evidence/harness-audit-20261006T021936Z/).

## Changes and execution

The first fresh attempt, `20261006T021953Z`, built successfully but aborted
fixture 22. The private clock syscall returns a 64-bit counter, while libc's
`prctl()` returns an `int`. The old binary tested `eax` and rejected a valid
counter value after it crossed `INT_MAX`, approximately 21.47 seconds into the
10 ns-period HPET clock. That attempt reported `SCM_DONE 1` and remains intact.
This was a harness ABI error, not a kernel defect candidate.

The fixture now uses `syscall(SYS_prctl, ...)`, whose return type is `long`.
The rebuilt helper tests `rax`. The corrected guest completed all 23 fixtures
and recorded seven production events above the old limit, reaching timestamp
2,147,826,079. The [regression evidence](evidence/harness-audit-20261006T021936Z/clock-return-regression.json)
retains those raw records and the two attempt identities.

The only other implementation change is a final overlap check in `run.sh`.
It runs after replay, writes `overlap-quality.json`, and prevents an incomplete
batch from replacing the canonical traces. The production kernel patch,
trace decoder, model and configurations were unchanged. No syscall behavior
was repaired and no invariant was weakened.

The corrected build began with 11,282,524 kB MemAvailable, above the 10 GiB
reserve. The controller held the shared heavy-stage lock throughout. Containers
used two CPUs, 8 GiB memory and 512 PIDs. Cargo used two jobs, and the guest used
two CPUs and 2 GiB with only the individual KVM device exposed. The build exited
0, QEMU exited 33, and the fixture reported `SCM_DONE 0`. All 23 Linux 7.2.8
controls also completed. Both launchers and PID waiters exited, and both
attempts' containers were removed.

## Trace checks and remaining requirement

The corrected batch contains 1,117 production events covering all 34 action
names. Every fixture passed 128 cross-CPU clock exchanges, for 2,944 samples.
All 23 replays had nonzero initial states and passed `Trace.cfg` without using
`TraceSearch.cfg`. All 34 receiver fields have mandatory post-state checks.
Raw thread records, user bytes, FD-to-object scans and timestamp rank maps
remain beside the normalized traces.

| Competition fixture | Strict overlapping pairs | Whole-trace fraction | Receive-window fraction | Structural upper bound |
| --- | ---: | ---: | ---: | ---: |
| 17, two ordinary receivers | 2 | 2/936 = 0.214% | 2/130 = 1.538% | 30/936 = 3.205% |
| 18, PEEK and ordinary receive | 15 | 15/2384 = 0.629% | 15/650 = 2.308% | 50/2384 = 2.097% |

Fixture 18 selected the same message in both successful operations. Both
competition fixtures exercise real overlapping production intervals. The
whole-trace denominator also contains serialized setup and cleanup events.
For these fixtures, only the receiver streams can overlap. Two internally
nonoverlapping streams of n and m events have at most n + m - 1 strict
intersections. Thus the recorded event counts cannot reach 20% by scheduling
changes alone. Intervals were not widened and events were not omitted.

The [timebox guide](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/references/concurrent-timebox-guide.md)
says, "At least 20% of event pairs across different threads should have
overlapping `[start, end]` intervals." The current request explicitly forbids
relaxing the skill. This invocation therefore does not use the historical
[controller exception](CONTROLLER-DECISION-2026-10-06.md) to declare completion.
The receiver must resolve this requirement before claiming a complete harness
phase. The traces' successful model replay remains valid as a separate result.

## Attribution and phase boundary

The booted kernel ELF is
`fe645eb4347b532eb5bc32640123ddd22690ef7f78955ab1e6857bcabb2428ee`.
Its whole-file hash differs from the prior build. The fresh disassembly
matches all 2,486 retained instruction records for the audited clock, Arc and
ClosedFile release, syscall completion, and installation/publication hooks.
The current [compiled evidence](evidence/harness-audit-20261006T021936Z/compiled-identity.json)
records this distinction. HPET MMIO overhead can affect scheduling.

The running Linux kernel and scoped source hashes still match the existing
[reference reconciliation](evidence/20261005T194207Z/linux-source/RECONCILIATION.md).
Fresh [external observations](evidence/20261006T022240Z/reference-comparison.json)
retain the first-number, later-number, header and payload-fault controls.
They remain separately attributed to Linux and Asterinas. Existing AST-32 and
AST-36 behavior is preserved, and no new candidate or shared catalog change
was produced.

This invocation performed Phase 2.5 harness work and quick trace replays only.
It did not start Phase 3 model checking, hunting, confirmation, classification
or repair. Earlier phase results retain their own attempt identities. The
receiver owns subsequent phase transitions.
