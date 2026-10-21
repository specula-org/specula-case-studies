# Asterinas FD/epoll trace harness

This harness instruments Asterinas commit
`4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`. It emits Category B timebox
events from the production syscall and epoll paths. The test binary only
selects real syscall interleavings; it does not simulate kernel state or write
trace records.

## Run

From the source checkout or any directory:

```sh
/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/run.sh
```

`run.sh` performs these bounded steps:

1. Applies the instrumentation idempotently with `apply.sh`.
2. Ensures the pinned Rust toolchain exists in
   `${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-/tmp}/specula-asterinas-fd-epoll}`.
3. Builds the regression binary, initramfs, and kernel in the required
   `asterinas/asterinas:0.18.0-20260702` container.
4. Boots four x86_64 VMs with `SMP=2` and KVM.
5. Extracts console records, writes one merged trace per scenario, compresses
   timestamps without changing interval overlap, and checks coverage and
   concurrency.

The generated files are `../traces/*.ndjson`. Uncompressed per-actor events
are retained under `../traces/raw/`, and build/VM logs are under `logs/`.

To apply or remove only the source instrumentation:

```sh
./apply.sh
./clean.sh
```

Both scripts refuse an unexpected source revision or a modified harness-owned
file. `clean.sh` removes only files and patch hunks owned by this harness.

## Trace protocol

Each production event is buffered as:

```json
{"tag":"trace","event":"ActionName","tid":"t1","start":1,"end":2,"args":{},"state":{}}
```

The VM emits records between `SPECULA_TRACE_BEGIN` and
`SPECULA_TRACE_END`. `collect_trace.py` parses those records and writes the
single JSON object expected by `Trace.tla`:

```json
{"traces":{"t1":[...],"t2":[...]}}
```

The producer uses two preallocated 64-entry actor-local buffers. A hot-path
event performs only TSC reads and atomic stores. It does not allocate, format
JSON, print, or take a shared trace lock. JSON serialization happens after the
worker has joined and tracing is disabled.

Timestamps are fenced x86_64 `RDTSC` values. The collector maps the sorted set
of observed start/end boundaries to dense integers. This preserves ordering
and the truth of every cross-thread interval-overlap test.

The main and worker threads register as `t1` and `t2` through test-only
`PR_SET_NAME` control names. `specula-t1` resets state and snapshots the real
file-object addresses for fds 0 through 4. `specula-t2` registers the second
actor and enables capture. `specula-flush` disables capture and serializes the
buffers. Other process names retain normal `prctl` behavior.

Buffer overflow, incomplete initialization, or a callback state outside the
first-batch model emits `SPECULA_TRACE_ERROR`; the collector rejects the run.

## Scenarios

| Scenario | Real operations | Modeled purpose |
|---|---|---|
| `concurrent_fcntl` | Two CPU-pinned pthreads cross a barrier and call `F_SETFL` on the same timerfd | Captured file identity, shared OFD status, and genuine cross-thread timebox overlap |
| `dup_replace_flags` | `dup2(fd0,fd0)`, `dup3(fd0,fd2,O_CLOEXEC)`, `F_SETFD(fd0,0)` | Equal-fd behavior, exact replacement and cleanup, and per-slot flags across aliased descriptors |
| `close_reuse` | `close(fd2)`, `dup(fd0)`, `close_range(0,2,CLOEXEC)` | Final release, lowest-slot reuse, generation change, and atomic range flag update |
| `readiness_epoll` | signalfd mask update, eventfd write/read, epoll ADD, bounded nested epoll ADD | Eventfd mutex/notification phases, register-before-check, identity publication, and a two-node acyclic graph |

Every scenario first creates timerfd, signalfd, and eventfd objects in numeric
slots 0, 1, and 2, followed by epoll instances in slots 3 and 4. This matches
`base.tla` `Init`; setup occurs before tracing is enabled.

The eventfd write/read completes before epoll registration. This is
intentional: the first batch models the synchronous empty-callback path. Once
the eventfd key is registered, an eventfd notification would require the
ReadySet callback actions too, and the producer rejects that unsupported
combination instead of emitting an incomplete trace.

## Instrumented production boundaries

`instrumented-events.txt` is the coverage contract. `check_traces.py` fails if
any listed type is absent or any unlisted type appears.

| Production path after apply | Hook lines | Events |
|---|---:|---|
| `kernel/core/src/syscall/fcntl.rs` | 71-73, 92-103 | `FcntlSetFlCapture`, `FcntlSetFlUse`, `FcntlSetFd` |
| `kernel/core/src/syscall/close.rs` | 29-47, 97-114 | `SysCloseRemove`, `ClosedFileDrop`, `SysCloseRangeCloexec` |
| `kernel/core/src/syscall/dup.rs` | 16-19, 30-32, 62-99 | `SysDup2Equal`, `SysDup3Validate`, `FileTableDupExact`, `DupReplacementCleanup`, `FileTableDupCeil` |
| `kernel/core/src/syscall/eventfd.rs` | 133-145, 165-174 | `EventfdAddCounter`, `EventfdTryRead`, `EventfdNotify`, `EventfdNotifyReturn` |
| `kernel/core/src/syscall/signalfd.rs` | 115-117 | `SignalfdUpdateMask` |
| `kernel/core/src/events/epoll/file.rs` | 66-154 | `EpollControlCaptureTarget`, `EntryUpdatePoll`, `EpollAddInterest`, `EpollControlPushReady`, `EpollAddNestedInterest` |

Harness control is wired at `kernel/core/src/syscall/prctl.rs:69`; the trace
module declaration is `kernel/core/src/lib.rs:59`.

The hooks capture fd-slot generation and flags in a separate bounded shadow.
File identity comes from the actual captured `Arc<dyn FileLike>` data pointer,
not from a later numeric-fd lookup. Close and replacement liveness is sampled
at the final `ClosedFile` release boundary. Epoll target identity is captured
after the file-table borrow is released and retained through the real control
operation.

The remaining actions in `instrumentation-spec.md` are not first-batch
instrumented. In particular, this harness does not emit exec cutover, epoll
MOD/DEL/error, callback lock stages, epoll delivery/copyout, poll/select wait,
timer expiration, signal enqueue/notify, or temporary signal-mask restoration
events. Do not add a syscall that crosses one of those transitions to an
enabled scenario without adding its complete production hooks and post-state
schema. `Trace.tla` has no silent transition that can hide an omitted action.

## Adjusting the harness

1. Edit canonical files under `harness/src/`.
2. Add the matching minimal production hook to `patches/source-hooks.patch`.
3. Add the event name to `instrumented-events.txt` and an exercising real
   syscall scenario to `specula_fd_trace.c`.
4. Extend `tla_trace.rs::print_event` with every `args` and `state` field read
   by the corresponding `Trace.ValidatePostState` branch. Missing fields are
   not wildcards.
5. Keep the interval limited to the cited production mutation. Read and
   format auxiliary state after the end timestamp where possible.
6. Run `clean.sh`, `apply.sh`, then `run.sh`. Confirm the exact event coverage,
   at least 20% cross-thread overlap in one trace, and TLC validation of every
   merged trace.

Never add a shared sequence counter, trace mutex, hot-path allocator, or
cross-actor synchronization to the producer. If a state field cannot be read
without changing the production synchronization contract, mark that event
unsupported and fail the run until the instrumentation spec is revised.
