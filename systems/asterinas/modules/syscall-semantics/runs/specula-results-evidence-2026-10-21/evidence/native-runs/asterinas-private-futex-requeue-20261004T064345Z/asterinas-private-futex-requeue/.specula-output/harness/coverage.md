# Implementation trace coverage

The 18 finite attempts ran on the instrumented Asterinas commit
`0c60537098f4c2949ad2d382aaf499de72263d76`, with 2 guest CPUs and 512 futex
buckets. The kernel payload hash is
`39ae35494bbe282481081f5f3c0200d85cb325dfb6974e4888c6f5e115b2f3cc`.
Each attempt booted a fresh guest. All buffers reported zero loss, all declared
calls returned, and all 18 traces have complete TLC replay witnesses. The
1,341 events exercise 53 of the 57 instrumented actions.

[Attempt observations](attempt-observations.json), [event coverage](coverage.json),
and [replay results](../spec/output/trace-results.json) retain the measurements.
The raw serial logs and per-stream records remain under `logs/` and `raw/`.
Per-stream order and recorded synchronization dependencies establish ordering.
The inter-thread order of lines in an NDJSON file does not.

| Contract case | Attempt | Observed behavior and limit |
|---|---|---|
| F00 | 18 | The user store was followed by WAKE. WAIT observed the changed word and returned EAGAIN. A competing successful registration history was not captured by this attempt. |
| F01 | 1 | Mismatch returned EAGAIN, left no registration, and the subsequent WAKE returned zero. |
| F02 | 2 | Actual enqueue preceded WAKE. One accepted wake, removal and completion were recorded. |
| F03 | 3, 4 | Same-bucket and cross-bucket REQUEUE(1,1) each woke one, moved one and returned one. Destination WAKE reached the moved registration. Source WAKE returned zero. |
| F04 | 5, 6, 7 | With migration quota zero, the matching-first same-bucket path moved one remaining entry. The cross-bucket path and unrelated-first same-bucket control moved none. |
| F05 | 8, 16 | REQUEUE(0,1) accepted one wake and moved one. REQUEUE(0,0) accepted one wake and moved none. Return counts alone do not distinguish these effects. |
| F06 | 9 | The same-address shortcut woke one, moved none and returned one. The second wait remained on that address. |
| F07 | 10, 11 | Same-bucket timeout found and removed the registration, returning ETIMEDOUT. Cross-bucket timeout searched the original bucket, missed and returned success. The destination retained the closed generation and later WAKE accepted zero. Spurious success alone is not a defect oracle. |
| F08 | 12, 17 | Destination wake before expiry and timer cancellation were observed. Timer-delivered expiry appears in attempts 10, 11 and 13. A close wake/expiry race with both winners is not established by these captures. |
| F09 | 13 | After generation 3001 timed out and closed, two fresh B waiters enrolled. REQUEUE B to A woke generation 4001 but migrated old generation 3001. Generation 5001 stayed on B. Later WAKE A returned zero and WAKE B returned one. The fresh admissions follow observed joins/enrollment, not ready flags. |
| F10 | 14 | Both direction calls completed. A is bucket 6 and B is bucket 303. The captured lock acquisitions use ascending bucket order in both source/destination directions. |

Attempts 3, 5, 7 and 10 measured equal source/destination bucket indices.
The cross-bucket controls measured different indices. Attempt 9 used the same
address, separately from a bucket collision. These classifications come from
kernel lookup/enqueue observations.

## Quality and coverage gaps

The Category B concurrency quality requirement is not satisfied. The greatest
raw cross-thread event-pair overlap is 5/1,309, or 0.382 percent, in attempt 5.
The skill requires at least 20 percent. No same-CPU cross-stream overlap was
observed, and cross-CPU TSC comparability was not established. The conservative
normalized timeboxes overlap by construction. They are search bounds, not
evidence that the operations overlapped. Replay success does not close this
quality gap.

`FutexWaitFault`, `FutexWaitFaultUnlock` and `HandlePageFault` were not exercised
because the finite driver prefaults its stable words. Their source paths and
model actions remain present. `WaiterSpuriousReturn` was not observed. No
scheduler fault or synthetic spurious return was introduced to force it.
Runtime coverage of these actions remains absent.

The initial BIOS attempt timed out before any test-entry observation. Inspection
showed the image has only a UEFI boot entry. A later UEFI control shut down with
QEMU status 33, but earlycon was absent and no probe output was available. Both
attempts remain uncovered boot/capture controls. Enabling OVMF and earlycon
produced the 18 complete captures above. Neither earlier outcome is evidence of
a futex progress defect.

## Linux count calibration

The bounded control in [linux-control.c](src/linux-control.c) ran on Linux
`7.2.8`, `#1-NixOS SMP PREEMPT_DYNAMIC Tue Jan 1 00:00:00 UTC 1980`, x86-64,
with waiters pinned to CPUs 0 and 1. [Raw output](logs/linux-control.ndjson)
records each waiter in `__futex_wait` before the operation. The control uses
private raw syscalls and stable atomic words, and drains both keys before
joining the threads. It records no Linux bucket identity and emits no internal
Linux movement trace.

| Operation with two waiting threads | Return | Later destination WAKE | Later source WAKE |
|---|---:|---:|---:|
| REQUEUE(1,1), distinct addresses | 2 | 1 | 0 |
| REQUEUE(1,0), distinct addresses | 1 | 0 | 1 |
| REQUEUE(0,1), distinct addresses | 1 | 1 | 1 |
| REQUEUE(0,0), distinct addresses | 0 | 0 | 2 |
| REQUEUE(1,1), same address | 2 | 1 | 0 |
| WAKE(0), followed by both key controls | 1 | 0 | 1 |

The observed counts agree with the selected Linux v6.16.5 source reference,
where ordinary REQUEUE counts both wakes and processed requeues. The running
control kernel was 7.2.8. This is not execution evidence for the v6.16.5 binary
or proof of both Linux bucket-path variants. The WAKE(0) legacy behavior is
kept separate from REQUEUE's zero-wake semantics.
