# Harness execution record

Attempt `20261010T014248Z` built the pinned kernel, completed all 23 guest and Linux
fixtures, and generated 23 traces containing 1,084 production events across
all 34 event types. Every trace passed the unchanged `Trace.cfg` with a
nonzero initial-state count, including `TraceMatched` and terminal cleanup.
No completion-witness search was needed.

Phase 2.5 remains **incomplete**. Neither competition trace meets the installed
harness-generation skill's 20% whole-trace overlap requirement. `run.sh`
therefore exited 1 after preserving the traces and successful replays. No
threshold, event, timestamp, model or configuration was changed to pass it.

The [fresh traces](evidence/20261010T014248Z/normalized/),
[replay results](evidence/20261010T014248Z/validation/results.json),
[coverage](evidence/20261010T014248Z/coverage.json) and
[quality result](evidence/20261010T014248Z/overlap-quality.json) belong to this attempt.
`evidence/latest` points here. Canonical `../traces/case-*.ndjson` and
`evidence/accepted` retain the historical batch `20261005T220019Z`. That batch
was accepted under a superseded controller exception and does not establish
completion under the current request. All its bytes were preserved.

## Changes and execution

The resource checks in `run.sh` and `src/validate.py` now call the shared
policy's `effective-mem-gib.sh`. This implements the user's 2026-10-09 choice
of `MemFree + Inactive(file)` rather than the obsolete `MemAvailable` gate.
The successful build began with 43.98 GiB. The smallest measured reserve
before a replay was 42.33 GiB. The receiving controller held `heavy.lock`.
The worker did not reacquire it.

The first attempt, `20261010T014159Z`, exited 6 during the build because the
global `cargo-osdk` embedded another checkout's
`asterinas-nix-vdso-docker/osdk/deps/frame-allocator` path. Its
[build log](evidence/20261010T014159Z/build.log) is retained.
`src/guest-build.sh` now builds OSDK from the pinned checkout with
`OSDK_LOCAL_DEV=1` and `--locked`. `run.sh` no longer mounts or invokes the
global binary and records the local binary's hash. The original
`bash harness/run.sh` entry point was then rerun without a bypass.

The successful attempt used two container CPUs, 8 GiB memory, 512 PIDs,
two Cargo jobs and a two-CPU, 2 GiB KVM guest. Only `/dev/kvm` was exposed.
The build exited 0. QEMU exited 33 with `SCM_DONE 0`, and Linux also reported
`SCM_DONE 0`. All commands finished within their timeouts. Both attempt
containers were removed. Source hooks, the trace module, fixture source,
decoder, model and configurations remained unchanged by this invocation.

## Coverage and remaining requirement

All 23 fixtures passed 128 cross-CPU HPET exchanges, totaling 2,944 samples.
The decoder verified raw event correspondence, per-thread order, timestamp
rank preservation, mandatory post fields, complete output integers, header
bytes and final FD scans. The L2 audit confirms all 34 receiver fields are
compared. Both ordinary objects finish with no modeled owner after cleanup.
The [audit](evidence/harness-attempt4-audit-20261010T014145Z/trace-audit.json) retains these checks.

| Competition case | Whole-trace events by sender/r1/r2 | Strict overlaps | Whole-trace fraction | Receive-window fraction | Whole-trace structural bound |
| --- | --- | ---: | --- | --- | --- |
| 17, four-right ordinary/ordinary | 26 / 5 / 26 | 3 | 3/936 = 0.321% | 3/130 = 2.308% | 30/936 = 3.205% |
| 18, one-right PEEK/ordinary | 19 / 16 / 17 | 7 | 7/899 = 0.779% | 7/272 = 2.574% | 32/899 = 3.560% |

Case 17 has one successful receive and one `EAGAIN`. Case 18 has a successful
PEEK and ordinary receive of the same message. Both exercise genuine
cross-thread overlap. `SCM_WINDOW` endpoints came from the guest. Window
fractions are separate analysis and are not substituted into the quality gate.
Every sender and cleanup event remains an ordinary NDJSON event line.

The installed [harness-generation skill](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/SKILL.md)
requires its [timebox methodology](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/harness-generation/references/concurrent-timebox-guide.md),
which says, "At least 20% of event pairs across different threads should have
overlapping `[start, end]` intervals." These complete lifecycle inventories
cannot attain that threshold through scheduling alone: only the two internally
disjoint receiver streams overlap, giving an upper bound of n+m-1
intersections. Point events tighten the bounds further to 23/936 and 24/899.
The receiving controller must resolve this requirement conflict before phase
completion can be claimed. This worker has not reinstated the exception.

## Attribution and retained behavior

The booted ELF SHA-256 is
`9f46dc3723075142c9157c2a618391e60c748f2642670af9776ae88f136c0751`.
The rebuilt binary differs from the preceding build, so old instruction
identity is not claimed. Fresh [compiled placement evidence](evidence/harness-attempt4-audit-20261010T014145Z/compiled-placement.md)
contains 2,645 selected instruction records. It confirms the shared clock
read, actual Arc and ClosedFile release before emission, completion after
local destruction, and table unlock before the four-byte user copy.
HPET MMIO emulation still has scheduling overhead.

The Linux control ran on 7.2.8. Its booted kernel path and all scoped source
hashes match the existing reconciliation with reference
`4645fefac0b24d509b962c096b0327e87f34b1d2`.
The [current identity check](evidence/harness-attempt4-audit-20261010T014145Z/linux-source-verification.json)
and [external comparisons](evidence/20261010T014248Z/reference-comparison.json)
retain attribution. Linux observations are not Asterinas trace replays.

The first-number fault leaves one Asterinas FD installed while Linux leaves
none. The later and partial-number faults leave Asterinas's two delivered
FDs and a third installed entry, while Linux keeps the two delivered FDs.
Asterinas reports zero control length and Linux reports 24 bytes for those
prefix cases. After a header fault, Linux can retain all four already
published FDs. Ordinary payload fault retains the Asterinas message for a
successful retry, whereas the Linux retry is empty. Both PEEK payload-fault
controls retain the message. These are the scoped AST-32 and AST-36 behaviors,
not new defect candidates or a catalog update.

This invocation performed harness work and quick trace replays only.
It did not start Phase 3 model checking, hunting, confirmation, classification
or repair. Previous reports, status and scripts are archived in
[the audit's before directory](evidence/harness-attempt4-audit-20261010T014145Z/before/).
[INSTRUMENTATION.md](INSTRUMENTATION.md) describes the current adjustment and
rebuild path, and [status.json](status.json) records the incomplete phase.
