# Harness execution record

Phase 2.5 is incomplete. The final revision uses an `IoMem` mapping for the
shared HPET clock, but its build never started. Attempt
`20261005T212603Z` waited 1,800 seconds below the required 10 GiB
`MemAvailable` reserve and exited 124. At closeout, the host reported
10,162,412 kB, below the 10,485,760 kB threshold. No owned job or container
remains. This is a resource-gate timeout, not evidence of a protocol deadlock.

The final kernel build, guest run, clock qualification, overlap measurement,
compiled hook audit and trace replay are all `NOT_RUN`. The 23 canonical
traces remain byte-for-byte identical to the earlier provisional TSC batch.
There is no new accepted Asterinas trace batch.

## Changes prepared

The clock reader now obtains an uncached HPET mapping through `IoMem`,
checks the device capabilities during fixture setup and reads the common
64-bit counter without a software sequence counter. Each fixture retains
all 128 cross-CPU clock exchanges. This replaces the unqualified TSC source
without assigning a cause to its earlier failures or adjusting timestamps.
The reader's MMIO overhead can affect scheduling and is documented as a
measurement limitation.

The decoder enforces the receiver-overlap requirements in the
[controller decision](CONTROLLER-DECISION-2026-10-06.md), including a successful
PEEK and ordinary receive of the same message. It reports strict overlap,
whole-trace and receive-window fractions, and the structural upper bound.
These checks have not yet been exercised on a final-revision guest trace.

`run.sh` stages traces inside each attempt's evidence directory and promotes
only a batch whose normalization and replays succeed. Its input snapshots
preserve failed revisions. The TLA+ model, configurations and acceptance rule
are unchanged. The L2 source audit confirms that all 34 wrappers invoke
mandatory post-state comparisons and that the decoder supplies all 34 receiver
fields. Shell/Python syntax checks, patch application/reversal checks and
`git diff --check` pass. These are static checks, not execution of the final
kernel.

## Executed attempts

| Attempt | Result |
| --- | --- |
| `20261005T212304Z` | The first HPET prototype failed compilation because the volatile configuration-register write used the read-only accessor. |
| `20261005T212346Z` | After fixing that accessor, the kernel built. Fixture 00 then faulted during clock setup because HPET MMIO is outside the RAM direct map. This was an instrumentation fault before the SCM_RIGHTS protocol. |
| `20261005T212603Z` | The corrected `IoMem` revision exhausted its 30-minute resource wait before compilation. No guest fixture started. |

The failed prototype's disassembly is retained under its own attempt and
explicitly labeled. It is not a compiled audit of the final correction.
Earlier attempts, including the four TSC qualification failures, remain in
`evidence/`. The latest attempt's `prior-attempts.json` lists their observed
fixture attempts and completion markers. No failed attempt was turned into
an accepted trace or silently retried after a test hang.

## Linux controls

The already-built userspace fixture completed all 23 cases on Linux 7.2.8
while the Asterinas build was queued. Its source and binary hashes, raw
output and observations are retained separately. The booted kernel and the
scoped Linux source hashes still match the existing 7.2.8 reconciliation
against the supplied 6.16.5 reference.

In these fresh Linux controls, a first-number fault installed no FD. A later
or partial third-number fault retained the first two FDs and reported 24
control bytes with `MSG_CTRUNC`. A header fault retained four FDs despite
reporting zero control length. A normal payload-fault retry returned EAGAIN,
while the PEEK payload-fault retry succeeded. These Linux observations do not
establish the behavior of the final Asterinas revision and are not inputs to
its transition relation.

## Evidence and resumption

The latest evidence directory is
[`evidence/20261005T212603Z`](evidence/20261005T212603Z/). It includes
`completion.json`, `resources.txt`, `final-inputs.json`,
`canonical-traces-unchanged.json`, `l2-source-audit.json`,
`linux-preflight.log`, `linux-preflight.json` and `linux-source-recheck.json`.
`cache-release.json` records the advisory eviction of clean pages from this
checkout's build artifacts. It did not remove files or change host memory
settings, and did not clear the reserve gate.

Once the host has at least 10 GiB `MemAvailable`, the receiving controller
must hold the shared heavy-stage lock and run, from `.specula-output`:

```sh
timeout --kill-after=20s 1800 bash harness/run.sh
```

The worker must not reacquire that lock. The next attempt must build and boot
the corrected revision, qualify every fixture's clock, satisfy both competition
checks, retain a compiled hook audit and replay the resulting traces with the
unchanged configurations. Acceptance cannot be inferred from the old 23
provisional replays or from the successful Linux controls.

Zero new defect candidates were produced. Model checking, convergence,
hunting, confirmation, classification, repair and shared-catalog updates were
not performed during this harness attempt. The receiver owns subsequent
phase transitions.
