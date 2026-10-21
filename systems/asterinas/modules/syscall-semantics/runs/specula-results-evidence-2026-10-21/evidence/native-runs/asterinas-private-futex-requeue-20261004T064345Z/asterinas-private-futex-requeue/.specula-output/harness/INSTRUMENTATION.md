# Private futex trace harness

This harness applies observation points to Asterinas at
`0c60537098f4c2949ad2d382aaf499de72263d76` and runs its real private
WAIT, WAKE, and REQUEUE paths in an SMP=2 KVM guest. It is intended for
the Phase 3 agent who needs to adjust captures and replay real attempts.
The validation worker collected all 18 finite attempts using the compiled
kernel and verified complete replay witnesses for all 18. The concurrency
quality requirement remains `NOT_ESTABLISHED`: the maximum raw cross-thread
pair overlap is 0.382 percent and cross-CPU TSC comparability is unproved.
Read `coverage.json` and `spec/output/trace-results.json` before interpreting
these results as evidence of concurrency coverage.

The receiving controller must hold the preparation policy's `heavy.lock`.
A fresh build uses `bash harness/run.sh` from `.specula-output` and waits for
10 GiB host-visible MemAvailable. To reuse the already-built kernel, run
`bash harness/run.sh --reuse-kernel`. This checks the source diff, generated
modules, instrumentation inputs and image hashes before using them. It does
not invoke a compiler. Both modes repackage the per-case boot arguments and
boot each attempt in a fresh SMP=2 KVM guest with 2 GiB RAM, OVMF and earlycon.
The image contains a UEFI boot entry. Earlycon enables the serial sink used by
the probes. The container has 2 CPUs, 8 GiB memory and 512 PIDs, and exposes
only `/dev/kvm`. Cargo uses 2 jobs when a build is needed.

`SPECULA_CASES="1 2" bash harness/run.sh --reuse-kernel` selects a short
collection. The default covers all 18 attempts. The driver uses normal private
futex dispatch. The reserved instrumentation-only opcode `0x5350` registers
streams, queries actual identity/enrollment and flushes buffers. It does not
enqueue, wake, move or complete a waiter. A reserve failure, build failure,
watchdog, missing return or trace loss leaves an attempt uncovered.


## Capture and decoding

`src/trace.rs` is copied to `ostd/src/specula_trace.rs`. It records fenced
x86-64 TSC intervals in preallocated stream buffers. User tasks keep a stream
through all their calls. Interrupt contexts use CPU streams. Each stream has
its own reservation counter. There is no global event counter or writer lock.
No event allocates memory, copies user memory, or writes to the console while
a bucket or timer lock is held. The console dump happens after user calls have
returned. A final reservation count detects writes racing the freeze.

`src/probes.rs` supplies the campaign's bounded identity/enrollment registry.
The generation ID combines a registered stream with its per-stream invocation
counter. The Waker carries that generation through movement and closure.
`identity.py` embeds a build identifier derived from the patch, trace module,
probe module and scenario driver. The guest reports that identifier, actual
CPU/bucket counts, VMAR identity, aligned addresses and initial word values.
The container records image hashes and Docker image identity separately.

`normalize.py` saves the numeric observations as per-stream NDJSON under
`harness/raw/case-NN`, then writes `traces/case-NN.ndjson`. It decodes recorded
branches and locals. It does not execute the model or predict syscall results.
The retain/extract observation arrays represent logical survivors, including
unvisited entries. They never read moved or uninitialized vector storage.
Callback pending vectors are decoded from each invocation's recorded vector
and callback completion, preserving the stream and batch association.

Bucket acquisition epochs are incremented under the production bucket lock.
Timer guard and heap epochs are recorded under their existing locks. These
supply release-to-acquisition dependencies without an added synchronization
lock. Explicit join and enrollment observations supply harness synchronization
edges. They are omitted as semantic actions, while their proved predecessors
constrain the next event on the observing stream. TSC comparability across virtual CPUs is not established by this harness.
Normalized timeboxes therefore conservatively overlap across the attempt.
Raw intervals and real `ts` values remain available. That conservative overlap
is not proof of genuine concurrency. `coverage.json` reports measured raw and
same-CPU overlap separately, including the skill's 20 percent quality check.
A `NOT_ESTABLISHED` quality result must not be reported as a completed
Category B quality gate.

Protocol clock values use exact nanoseconds after subtracting one shared
origin. Duration and deadline arithmetic is not rounded. The decoder rejects
values outside TLC's signed integer range. Each clock read retains its own
sample independently of another CPU's later observation.

Every captured `state` field is checked by `Trace.tla`'s equality with
`WaitPost`, `CallPost`, or `PostState`. `ValidatePostState` is not `TRUE`.
The two unpark actions retain the supplied model's documented weaker target-PC
projection. The capture keeps the actual swap acceptance and written value.
A scheduler return with no observed unpark becomes `WaiterSpuriousReturn`.
The raw `ParkReturn` observation remains available to audit that decoding.

## Finite attempts

| Attempts | Contract cases and purpose |
|---|---|
| 1, 2, 15, 18 | F01/F02, zero-duration timeout, and user-store/registration overlap. |
| 3, 4 | F03 with equal and different bucket indices. |
| 5, 6, 7 | F04 with equal/different buckets and an unrelated first entry. |
| 8, 16 | F05 with zero wake quota and with both quotas zero. |
| 9 | F06 with identical source and destination addresses. |
| 10, 11 | F07 with same-bucket and cross-bucket movement before timeout. |
| 12, 17 | F08 expiry/wake overlap and a positive-timeout cancellation control. |
| 13 | F09 with a closed retained entry followed by fresh live waiters. |
| 14 | F10 with opposite-direction operations released concurrently. |

Enrollment comes from the actual bucket append. Bucket selection uses the real
`FutexKey` constructor and bucket lookup. A polling deadline only rejects an
attempt. It does not establish deadlock. Source-predicted quota/count behavior
is recorded without repairing the implementation or treating a return count
as a successful Linux comparison. Linux runtime calibration belongs to the
receiver's later verification work and is not supplied by this harness.

The driver prefaults stable atomic words, so the recoverable-fault events may
remain uncovered. Their original retry path is instrumented and preserved.
Spurious scheduler returns and callback cancellation/weak-upgrade races are
not guaranteed by a finite run. Read the actual event coverage after collection.
Do not add silent actions to make an incomplete capture pass.

## Adjusting an observation

Edit `src/trace.rs` or `src/probes.rs` for the reusable modules. Edit the applied
production site listed below when moving a probe. Take the start stamp before
the semantic operation and preserve its actual result before another thread
can change shared state. A queue snapshot must remain inside its existing lock.
Extend the numeric data array and its matching branch in `normalize.py` when
adding a field. Arrays are limited to ten scalar fields and sixteen entries.
The emitter records overflow and the decoder rejects it.

For a new event, add its wire name to `events.json` and `event_code`, insert an
observation at the actual implementation step, and add a decoder branch with
the exact `Trace.tla` argument and post-state domains. Do not populate missing
state by running the TLA model. Regenerate `patches/instrumentation.patch` from
the intended tracked source files after changing a production site, then rerun
`apply.sh`. `identity.py` refreshes the embedded build identity. `clean.sh`
reverses only the instrumentation patch and checks generated files before
removing them. It preserves unrelated workspace files.

After collection, run the skill's quick trace validation on a complete attempt.
Use no more than 4 GiB TLC memory and two workers, with one TLC process at a
time and at least 6 GiB host MemAvailable. Keep `Trace.cfg` unchanged.
Its expected positive witness violates only `TraceIncomplete` after consuming
all events. Inspect the final cursors and other invariants. A generic nonzero
exit or a universal temporal failure is not an existential replay verdict.
The receiver owns any subsequent phase transition.

## Applied locations

The paths below are relative to `source`. `instrumentation-points.json` gives
the same mapping in machine-readable form.

| Event | Applied source location |
|---|---|
| `SysFutexWait` | `kernel/core/src/process/posix_thread/futex.rs:91` |
| `FutexWaitLock` | `kernel/core/src/process/posix_thread/futex.rs:103` |
| `FutexWaitLoad` | `kernel/core/src/process/posix_thread/futex.rs:115` |
| `FutexWaitFault` | `kernel/core/src/process/posix_thread/futex.rs:119` |
| `FutexWaitFaultUnlock` | `kernel/core/src/process/posix_thread/futex.rs:123` |
| `HandlePageFault` | `kernel/core/src/process/posix_thread/futex.rs:140` |
| `FutexWaitCompare` | `kernel/core/src/process/posix_thread/futex.rs:146` |
| `FutexWaitMismatchUnlock` | `kernel/core/src/process/posix_thread/futex.rs:156` |
| `FutexBucketAddItem` | `kernel/core/src/process/posix_thread/futex.rs:170` |
| `FutexWaitUnlock` | `kernel/core/src/process/posix_thread/futex.rs:181` |
| `PauseTimeoutCheck` | `kernel/core/src/process/signal/pause.rs:179` |
| `TimerSetTimeout` | `kernel/core/src/time/core/timer.rs:225` |
| `WakerDoWait` | `ostd/src/sync/wait.rs:312` |
| `WaiterPark` | `ostd/src/sync/wait.rs:322` |
| `PauseTimeoutTimerLock` | `kernel/core/src/process/signal/pause.rs:221` |
| `PauseTimeoutNoTimer` | `kernel/core/src/process/signal/pause.rs:245` |
| `PauseTimeoutRemain` | `kernel/core/src/process/signal/pause.rs:229` |
| `TimerCancel` | `kernel/core/src/process/signal/pause.rs:233` |
| `PauseTimeoutTimerUnlock` | `kernel/core/src/process/signal/pause.rs:237` |
| `PauseTimeoutTimerDrop` | `kernel/core/src/process/signal/pause.rs:240` |
| `TimerCollect` | `kernel/core/src/time/core/timer.rs:262`, `kernel/core/src/time/core/timer.rs:278` |
| `TimerCallbackUpgrade` | `kernel/core/src/time/core/timer.rs:360` |
| `TimerCallbackLock` | `kernel/core/src/time/core/timer.rs:373` |
| `TimerCallbackCheck` | `kernel/core/src/time/core/timer.rs:383` |
| `TimerCallbackWake` | `ostd/src/sync/wait.rs:274` |
| `TimerCallbackUnpark` | `ostd/src/sync/wait.rs:292` |
| `TimerCallbackFinish` | `kernel/core/src/time/core/timer.rs:394`, `kernel/core/src/time/core/timer.rs:410` |
| `FutexCleanupLock` | `kernel/core/src/process/posix_thread/futex.rs:192` |
| `FutexRemoveByWaker` | `kernel/core/src/process/posix_thread/futex.rs:200` |
| `FutexCleanupUnlock` | `kernel/core/src/process/posix_thread/futex.rs:208` |
| `FutexWaitDecide` | `kernel/core/src/process/posix_thread/futex.rs:227` |
| `WaiterDrop` | `ostd/src/sync/wait.rs:344` |
| `SysFutexWaitReturn` | `kernel/core/src/syscall/futex.rs:275` |
| `SysFutexControl` | `kernel/core/src/syscall/futex.rs:188` |
| `LockBucketPairsFirst` | `kernel/core/src/process/posix_thread/futex.rs:260`, `kernel/core/src/process/posix_thread/futex.rs:561`, `kernel/core/src/process/posix_thread/futex.rs:573`, `kernel/core/src/process/posix_thread/futex.rs:594` |
| `LockBucketPairsSecond` | `kernel/core/src/process/posix_thread/futex.rs:582`, `kernel/core/src/process/posix_thread/futex.rs:603` |
| `FutexWakeStart` | `kernel/core/src/process/posix_thread/futex.rs:686` |
| `FutexItemWake` | `kernel/core/src/process/posix_thread/futex.rs:693`, `ostd/src/sync/wait.rs:276` |
| `FutexWakeUnpark` | `ostd/src/sync/wait.rs:294` |
| `FutexWakeRetain` | `kernel/core/src/process/posix_thread/futex.rs:710` |
| `FutexWakeEnd` | `kernel/core/src/process/posix_thread/futex.rs:270`, `kernel/core/src/process/posix_thread/futex.rs:482` |
| `FutexUpdateItemKey` | `kernel/core/src/process/posix_thread/futex.rs:733` |
| `FutexExtractItem` | `kernel/core/src/process/posix_thread/futex.rs:780` |
| `FutexExtractedKey` | `kernel/core/src/process/posix_thread/futex.rs:792` |
| `FutexAppendExtracted` | `kernel/core/src/process/posix_thread/futex.rs:799` |
| `FutexMoveEnd` | `kernel/core/src/process/posix_thread/futex.rs:750`, `kernel/core/src/process/posix_thread/futex.rs:801` |
| `FutexRequeueFinish` | `kernel/core/src/process/posix_thread/futex.rs:272`, `kernel/core/src/process/posix_thread/futex.rs:496`, `kernel/core/src/process/posix_thread/futex.rs:513` |
| `FutexReleaseDest` | `kernel/core/src/process/posix_thread/futex.rs:509` |
| `FutexReleaseSource` | `kernel/core/src/process/posix_thread/futex.rs:279`, `kernel/core/src/process/posix_thread/futex.rs:521` |
| `SysFutexControlReturn` | `kernel/core/src/syscall/futex.rs:277` |
| `UserStore` | `kernel/core/src/syscall/futex.rs:82` |
| `TimerSetClock` | `kernel/core/src/time/core/timer.rs:80` |
| `PauseTimeoutClock` | `kernel/core/src/time/core/timer.rs:128` |
| `WaiterSpuriousReturn` | `ostd/src/sync/wait.rs:328 (ParkReturn observation, decoded only without an observed unpark)` |
| `TimerCollectClock` | `kernel/core/src/time/core/timer.rs:253` |
| `TimerCollectEnd` | `kernel/core/src/time/core/timer.rs:295` |
| `ClockAdvance` | `kernel/core/src/syscall/futex.rs:93` |
