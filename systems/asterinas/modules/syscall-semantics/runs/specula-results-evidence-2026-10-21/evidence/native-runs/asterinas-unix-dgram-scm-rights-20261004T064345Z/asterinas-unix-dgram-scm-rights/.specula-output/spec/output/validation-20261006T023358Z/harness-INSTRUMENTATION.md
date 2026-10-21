# SCM_RIGHTS trace harness

This harness is for the Phase 3 agent validating the supplied Asterinas model.
Run `bash harness/run.sh` from `.specula-output`. The controller must hold the
shared heavy-stage lock. The worker does not acquire it again. The script
checks host memory, applies the patch, builds the real kernel, boots a two-CPU
guest, runs the same userspace scenarios on Linux, collects traces and performs
quick replays. It stops on build, guest, observation or validation failure.
Before publishing a batch, it also requires at least one trace to meet the
harness-generation skill's 20% cross-thread event-pair overlap requirement.
If that check fails, replayed traces remain under the attempt's `normalized/`
directory and the previously accepted batch is preserved.

The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`. This is temporary
instrumentation, not a kernel fix. `apply.sh` accepts only the original patch
sites or the already applied patch. `clean.sh` reverses only this patch and
removes the two copied files after checking their contents. Neither script
resets unrelated changes.

## Capture and evidence

`src/scm_trace.rs` uses a preallocated buffer of 1,024 scalar records in each
POSIX thread's `ThreadLocal`. It contains no shared tracing lock, allocation
in `emit`, global counter or owned file reference. The private `prctl` range
`0x53504300` through `0x53504305` configures the fixture, selects the next
operation's metadata, requests cleanup, drains the calling thread's buffer
and reads the shared clock.
Overflow invalidates the run. JSON formatting and console output happen only
after both receive threads have finished.
The userspace control helper calls `syscall(SYS_prctl, ...)` because the
private clock result is 64 bits. libc's `prctl()` returns an `int` and truncated
the counter once it crossed `INT_MAX`, aborting attempt `20261006T021953Z`.
The corrected attempt recorded timestamps above that limit and completed.

Each operation is measured with the shared, 64-bit HPET counter through
OSTD's `read_trace_clock`. The previous per-CPU TSC failed qualification in
four fixtures. This revision avoids that unqualified source. It does not
assign a cause to those failures or adjust any recorded timestamp. HPET is
initialized during fixture setup from the ACPI table with an owned `IoMem`
mapping. Setup verifies 64-bit counter support and disabled timer interrupts.
The read path uses one uncached 64-bit MMIO read and memory fences, with no
software sequence counter, allocation or shared tracing lock. The period
comes from the capability register and is retained in femtoseconds. QEMU derives
this counter from one virtual clock and permits 64-bit register reads, as
shown in its [HPET implementation](https://raw.githubusercontent.com/qemu/qemu/v9.2.0/hw/timer/hpet.c).

Queue acquisitions
are point markers after acquisition. Unlock snapshots are copied while the
original guard is held, with the interval ending after the actual guard drop.
The insertion guard ends before the FD integer copy. Userspace keeps the first
child runnable while the scheduler places the second, verifies distinct CPUs,
and checks 128 cross-CPU timestamp exchanges before every fixture. Every raw
kernel event also records its executing CPU. The decoder rejects unexpected
placement changes, missing calibration samples and any failed comparison.
HPET reads incur MMIO emulation overhead on this KVM guest. Intervals remain
bounded by actual clock samples around the original operations. The extra
measurement cost changes scheduling and is a limitation of these traces.

The raw clock record retains all 128 local-before, remote and local-after
samples and the smallest round-trip interval. Calibration calls the same
kernel reader through the private control syscall. Linux controls use
`CLOCK_MONOTONIC` and are separately attributed. Timestamp ranks retain
equality and order. No total order is imposed
on overlapping events. `sched_setaffinity` is not used to claim placement:
the selected kernel does not migrate an already placed thread on that call.

`src/normalize.py` is an observation decoder. It never emits an event without
a corresponding raw production record. Program counters identify hook
locations. Historical lists and counters come from recorded captures,
insertions, copy results and individual drops. Current queue lists are read
under the existing queue guard. Received-slot provenance is stored in the
table entry while its existing write guard is held. Each close record carries
that provenance. The decoder checks raw syscall results, complete output
integers, control-header fields and the final FD-to-object scan independently.

File IDs are the addresses of the captured `Arc<dyn FileLike>` data objects,
registered without cloning. A and B are different open files containing
different markers. The fixture verifies occupied FDs 0 through 6 and free FDs
7 through 63 before tracing, then sends A, B, A, B. The message identity is its
queue address and observed enqueue generation. All three thread identity maps
must agree. The decoder rejects unexpected queues, generations, objects and
non-monotonic thread clocks.

OSTD's `write_val_observed` is the original `write_val` implementation with the
copied length retained in its error. Ordinary `write_val` delegates to it and
discards that extra field. The control hooks record that length and the
restored writer cursor separately. They do not infer covered bytes from a
sentinel comparison. File-vector destructors drain and drop the original Arcs
in element order. `ClosedFileDrop` is recorded after `drop(closed_file)` returns,
so its Arc field has already been destroyed. Observer records contain IDs only.

Every run has a unique `evidence/<UTC timestamp>/` directory. It retains the
build and guest logs, container/image identity, input hashes, Linux output,
raw per-thread files, object maps, raw user bytes, clock calibration, timestamp
rank maps, event counts and replay logs. `evidence/latest` names the latest
attempt, including failed attempts. Normalized files are staged in the
attempt's `normalized/` directory. Only
a complete accepted batch is copied to `../traces/case-*.ndjson`.
`evidence/accepted` records that batch, while `evidence/latest` may name a
later failed attempt. Linux observations remain separately attributed.

## Scenario mapping

The regression program reuses `test/initramfs/src/regression/common/test.h`.
Four test groups run 23 independent, bounded child-process fixtures. Every
fixture sends one nonempty datagram on nonblocking AF_UNIX SOCK_DGRAM sockets.
Outer metadata is writable. Control faults use fixed, readable but unwritable
pages, allowing the observer to retain raw bytes without changing permissions
during the call. Each receive has its own payload and control mappings.

| Trace cases | Contract cases and exercised behavior |
| --- | --- |
| 00–01 | SCM-01/02 capture identity, sender close, controlled reuse and full delivery. |
| 02–06 | SCM-03 NULL, zero, short header, header-only and incomplete integer capacity. |
| 07–09 | SCM-04 exact one-integer capacity, partial padding and space for two integers. |
| 10–12 | SCM-05/06 first-number, later-number and partial-number faults. |
| 13–14 | SCM-07 complete and partial header faults. Case 13 keeps FD integer storage writable. |
| 15–16 | SCM-08/09 repeated PEEK then receive, and failed PEEK publication then receive. |
| 17–18 | SCM-10/11 two normal receivers, and PEEK competing with normal receive. |
| 19 | SCM-12 final socket disposal with a queued message. |
| 20–21 | SCM-13 normal and PEEK payload faults followed by a valid receive. |
| 22 | SCM-14 send payload fault, temporary release and empty receive. |

Partial layouts must produce the measured prefix prescribed by `Layout`.
The decoder rejects a mismatch and retains the raw evidence. It never changes
the recorded copy result to make a layout fit. The coverage report lists actual
cross-thread overlap counts and fractions separately from sequential controls.
Start barriers alone do not establish concurrency coverage.
The previous batch was accepted under the
[controller decision](CONTROLLER-DECISION-2026-10-06.md), which replaced the
20% target with positive receive-window overlap. The current harness-generation
request explicitly requires the skill without relaxation. `run.sh` therefore
checks the original threshold after replay and records `overlap-quality.json`.
`normalize.py` still checks positive overlap in both competition fixtures,
including a successful PEEK and ordinary receive of the same message. The
report retains the whole-trace fraction, structural upper bound and
receive-window fraction. No interval is widened and no event is omitted.
The two competition fixtures place the third FD integer in an initially
untouched, writable anonymous page. Its ordinary demand fault provides a real
publication interval while permissions and mappings remain fixed. No kernel
delay, tracing lock or synthetic interval is introduced.

## Adjusting hooks

`patches/instrumentation.patch` contains the production edits.
`src/make_patch.py` records the construction substitutions against the pinned
Git objects. The formatted patch is the applied artifact. For a small change,
edit the applied production file, format it, export `git diff --binary` from
`source/` to the patch, then run `run.sh`. Check that the diff contains only
instrumentation before exporting. To change only the trace module or C fixture,
edit its file in `src/` and run `run.sh`.

Raw records have 16 scalar slots. Add a field at the production trigger,
preserve its meaning in the decoder and require it in the associated
post-state comparison. Capture after the end timestamp while an existing lock
still protects the value. Do not extend that lock through another base action.
To add an event, allocate a distinct production boundary, emit its exact
`Trace.tla` action name, add a decoder branch and exercise it in a fixture.
Never create a missing event in preprocessing.

The normalized `post` object has exactly the fields required by
`RequiredFields`. Every receive event supplies all `EmptyReceiver` fields.
`ValidatePostState` invokes the full base action and compares these fields,
the touched table slot, explicit reference deltas and cleanup observations.
It is not a stub. No state check or invariant is disabled by this harness.

`src/validate.py` uses the resource-budgeted TLC wrapper with a 3 GiB heap,
512 MiB direct-memory bound and two workers. It first runs the unchanged
`Trace.cfg`, including `TypeOK`, `TraceMatched` and `TraceEndComplete`. Only a
temporal matching failure may enter the unchanged `TraceSearch.cfg` witness
search. Acceptance requires nonzero initial states and either an error-free
first run or exactly the inverse invariant's complete witness. A safety error,
timeout, zero initial states or missing witness rejects the trace. This is the
Phase 2.5 format/replay check. The controller owns later phase transitions.

## Applied hook locations

Paths below are relative to `source/` and refer to the formatted applied patch.
The close and syscall-completion hooks deliberately follow actual destruction.

| Event | Capture site |
| --- | --- |
| `SendBegin` | `kernel/core/src/scm_trace.rs:108` |
| `FileMessageReadFrom` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:115` |
| `AuxiliaryDataFromControl` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:343` |
| `MessageQueueTrySendLock` | `kernel/core/src/net/socket/unix/datagram/message.rs:89` |
| `MessageQueueTrySendCopy` | `kernel/core/src/net/socket/unix/datagram/message.rs:112` |
| `MessageQueueTrySendEnqueue` | `kernel/core/src/net/socket/unix/datagram/message.rs:152` |
| `MessageQueueTrySendUnlock` | `kernel/core/src/net/socket/unix/datagram/message.rs:125`, `kernel/core/src/net/socket/unix/datagram/message.rs:163` |
| `SendTemporaryDrop` | `kernel/core/src/scm_trace.rs:142` |
| `SysSendmsgComplete` | `kernel/core/src/scm_trace.rs:120` |
| `RecvBegin` | `kernel/core/src/scm_trace.rs:108` |
| `MessageReceiverTryRecvLock` | `kernel/core/src/net/socket/unix/datagram/message.rs:252` |
| `MessageReceiverTryRecvSelect` | `kernel/core/src/net/socket/unix/datagram/message.rs:261` |
| `MessageReceiverTryRecvCopy` | `kernel/core/src/net/socket/unix/datagram/message.rs:290` |
| `MessageReceiverTryRecvDequeue` | `kernel/core/src/net/socket/unix/datagram/message.rs:316` |
| `AuxiliaryDataGenerateControlRecv` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:423` |
| `AuxiliaryDataGenerateControlPeek` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:424` |
| `MessageReceiverTryRecvUnlock` | `kernel/core/src/net/socket/unix/datagram/message.rs:272`, `kernel/core/src/net/socket/unix/datagram/message.rs:298`, `kernel/core/src/net/socket/unix/datagram/message.rs:334` |
| `SysRecvmsgReleaseBorrow` | `kernel/core/src/syscall/recvmsg.rs:50` |
| `CUserMsgHdrWriteControl` | `kernel/core/src/util/net/socket.rs:153`, `kernel/core/src/util/net/socket.rs:165` |
| `FileMessageWriteCapacity` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:130`, `kernel/core/src/net/socket/unix/ctrl_msg.rs:139` |
| `FileMessageWriteHeader` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:162` |
| `FileTableInsert` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:188` |
| `VmWriterWriteFd` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:206` |
| `ControlMessageWriteAllTo` | `kernel/core/src/net/socket/util/message_header.rs:131` |
| `SysRecvmsgWriteback` | `kernel/core/src/syscall/recvmsg.rs:65` |
| `RecvTemporaryDrop` | `kernel/core/src/scm_trace.rs:144` |
| `SysRecvmsgComplete` | `kernel/core/src/scm_trace.rs:118` |
| `RequestCleanup` | `kernel/core/src/scm_trace.rs:177` |
| `FileTableCloseFile` | `kernel/core/src/syscall/close.rs:37` |
| `ClosedFileDrop` | `kernel/core/src/syscall/close.rs:62` |
| `SenderReuse` | `kernel/core/src/syscall/dup.rs:86` |
| `MessageReceiverDropBegin` | `kernel/core/src/net/socket/unix/datagram/message.rs:393` |
| `MessageReceiverDropReference` | `kernel/core/src/scm_trace.rs:140` |
| `MessageReceiverDropComplete` | `kernel/core/src/net/socket/unix/datagram/message.rs:398` |

The byte-count observation is in `ostd/src/mm/io/mod.rs:803`.

The shared clock reader is at `ostd/src/arch/x86/timer/hpet.rs:65`.

`SendBegin` and `SysSendmsgComplete` are wired into
`kernel/core/src/syscall/sendmsg.rs:23`. `RecvBegin` and
`SysRecvmsgComplete` are wired into `kernel/core/src/syscall/recvmsg.rs:20`.
The completion observer is declared before syscall locals and therefore drops
last. Receiver-vector drops originate from `FileMessage::drop`, and sender or
queue drops originate from `AuxiliaryData::drop`, in
`kernel/core/src/net/socket/unix/ctrl_msg.rs`.

An error-free replay and a satisfied overlap requirement are separate results.
`RESULTS.md` records both. A batch that misses the threshold is incomplete
under the current request, even if every production event matches the model.
