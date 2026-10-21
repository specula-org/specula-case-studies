# SCM_RIGHTS trace harness

The Phase 3 agent can rebuild the instrumented Asterinas kernel, run the
23 bounded fixtures and replay their production traces with this command
from `.specula-output`:

```sh
bash harness/run.sh
```

The receiving controller must hold the shared heavy-stage lock. This worker
does not reacquire it. The host needs rootful Docker through `sudo -n`, the
local `asterinas/kernel-dev:0.18.1-20260926` image, `/dev/kvm`, Python and Java.
The resource policy's `effective-mem-gib.sh` measures `MemFree + Inactive(file)`.
The script waits for 10 GiB before building and 6 GiB before each replay.
Containers have two CPUs, 8 GiB memory and 512 PIDs. Cargo uses two jobs.
The guest has two CPUs and 2 GiB. Only `/dev/kvm` is exposed to the container.
Builds, guest execution and replays have timeouts.

The script builds OSDK from this pinned checkout with `OSDK_LOCAL_DEV=1` and
uses `source/osdk/target/debug/cargo-osdk`. That variable embeds dependency
paths at compilation time. A global OSDK built in another checkout cannot
supply reproducible paths. The complete original entry point was rerun after
removing that dependency.

The latest execution and its remaining quality failure are in
[RESULTS.md](RESULTS.md). A successful replay alone does not complete this
phase. `run.sh` keeps each attempt under `evidence/<UTC timestamp>/`, reports
line counts, replays every trace and enforces the skill's 20% overlap gate.
It copies a batch to `../traces/` only after every gate succeeds. A rejected
batch's traces remain in its `normalized/` directory. `evidence/latest` names
the latest attempt. `evidence/accepted` and the canonical traces still name
a historical batch accepted under a now-superseded controller exception.

## Capture and decoding

The source pin is `0c60537098f4c2949ad2d382aaf499de72263d76`.
`src/scm_trace.rs` records into each POSIX thread's preallocated buffer of
1,024 scalar records. It holds no ordinary-file Arc, shared tracing mutex or
global counter. Overflow rejects the fixture. The private control syscalls
initialize the buffer, select operation metadata, request cleanup, read the
clock and drain the buffer. Serialization occurs after the measured receives
finish. The userspace helper uses `syscall(SYS_prctl, ...)` to preserve the
clock's 64-bit return value.

This is Category B instrumentation. HPET supplies real timebox endpoints.
A single uncached 64-bit register read with memory fences provides a shared
clock without per-CPU TSC offsets. Each fixture verifies distinct worker CPUs
and 128 cross-CPU exchanges. Raw events record CPU identity, and the decoder
rejects placement changes or failed comparisons. HPET MMIO emulation overhead
can affect scheduling, so these runs do not establish behavior without probes.

Queue acquisitions are point markers immediately after the existing mutex
acquisition. Insertion and removal are bracketed inside the existing table
lock. Unlock snapshots are copied while protected, with the end timestamp
after the guard drops. The insertion lock ends before the user integer copy.
State capture stays outside the measured semantic interval.

`src/normalize.py` decodes one output event per raw production record. Hook
locations determine PCs. Concrete captures, inserts, copy results and drops
supply historical state. Queue snapshots come from its existing guard, and
received-slot provenance is attached under the table write lock. All required
post fields and all 34 receiver fields are compared by `ValidatePostState`.
There are no silent steps or optional state comparisons.

The raw file identity is the data address of the original `Arc<dyn FileLike>`.
The setup registers A and B without cloning and verifies all three identity
maps agree. The fixture scans FDs 0 through 63 before tracing. FDs 0–4 are
external setup owners, A and B occupy 5 and 6, and 7–63 are free. Message
identity combines queue address and enqueue generation. The decoder rejects
unexpected objects, queues or generations.

`VmWriter::write_val_observed` retains the actual copied prefix before the
original cursor rewind. Header and integer hooks record coverage and cursor
separately. The decoder verifies raw bytes for complete integers and headers,
checks the final FD-to-object scan and keeps partial bytes in the sidecar.
File-vector destructors release the original Arcs in element order.
`ClosedFileDrop` follows `drop(closed_file)`. Syscall completion observers
are declared before ordinary-file locals and run after their destruction.
The latest source and compiled placement audit is linked from `RESULTS.md`.

Normalized timeboxes are dense ranks of the raw clock samples. Equality,
strict order and per-thread program order are preserved. Overlapping events
are not sorted into an invented total order. Every event stays in the body
of the NDJSON file, including sender actions and cleanup. The first line
contains fixture metadata only.

Each attempt retains input and binary hashes, the source diff, image identity,
Cargo lockfile, build and guest logs, per-thread records, identity maps, raw
user bytes, clock samples, timestamp ranks, coverage and replay logs. Linux
runs use the same external layouts and are recorded separately. They are
not replayed through the Asterinas transition relation.

## Scenarios and quality

`src/scm_rights_trace.c` reuses the repository's regression `common/test.h`.
Four test groups cover 23 independent child-process fixtures. They use
nonblocking AF_UNIX SOCK_DGRAM, one nonempty message, ordinary files, receive
flags 0 or MSG_PEEK, valid writable outer metadata and disjoint stable buffers.
Fault permissions are configured before the call and remain fixed.

| Trace cases | Contract cases and behavior |
| --- | --- |
| 00–01 | SCM-01/02 capture identity, sender close or reuse, and full delivery. |
| 02–06 | SCM-03 NULL, zero, short, header-only and incomplete-integer capacity. |
| 07–09 | SCM-04 one integer, partial padding and space for two integers. |
| 10–12 | SCM-05/06 first, later and partially copied integer faults. |
| 13–14 | SCM-07 complete and partial control-header faults. |
| 15–16 | SCM-08/09 repeated PEEK and failed PEEK publication followed by receive. |
| 17–18 | SCM-10/11 ordinary/ordinary and PEEK/ordinary competition. |
| 19 | SCM-12 final socket disposal while rights remain queued. |
| 20–21 | SCM-13 ordinary and PEEK payload faults followed by receive. |
| 22 | SCM-14 failed send payload copy and temporary-reference cleanup. |

Case 17 sends four A,B,A,B rights with 32-byte Full capacity. Case 18 sends
one A right with 20-byte Full capacity. The other cases send four rights.
Competition places the first integer in an untouched writable anonymous page
so an ordinary demand fault can overlap real publication work. No delay is
inserted into kernel operations. The Asterinas fixture verifies actual CPU
placement. Linux competition workers use affinity to select distinct CPUs.

The 20% gate uses strict intersections over every unordered cross-thread
event pair in the complete trace, including point events in the denominator.
`SCM_WINDOW` statistics describe the receive window separately and never
replace that denominator. Barriers alone do not prove overlap.

For the current complete lifecycles, sender work is serialized outside the
two receiver streams. Internally disjoint streams with n and m events have
at most n+m-1 strict intersections. The whole-trace denominator is
s*(n+m)+n*m, where s counts sender events. Thus case 17's bound is
30/936 = 3.205%, and case 18's bound is 32/899 = 3.560%. Point events tighten
these bounds further. Scheduling alone cannot satisfy 20% with these inventories.
The original threshold remains enabled, and no event or timestamp is changed
to improve its score. Resolving this conflict belongs to the receiving controller.

## Adjusting instrumentation

`apply.sh` checks the source pin and either applies
`patches/instrumentation.patch` or verifies it is already applied, then copies
the trace module and fixture into the source tree. Conflicting edits fail.
`clean.sh` reverses only that patch and removes copied files after checking
their contents. Neither script resets unrelated changes.

For production-hook changes, edit the applied source, format it, inspect
`git diff` and export only the instrumentation diff to
`patches/instrumentation.patch`. `src/make_patch.py` retains the original
construction substitutions. For module or fixture changes, edit the copy
under `src/`; `apply.sh` refreshes its installed copy.

Raw events contain 16 scalar slots. To add a field, capture it at the existing
production hook, assign a scalar slot, decode it in the corresponding branch
of `normalize.py` and require its comparison in `Trace.tla`. Keep only IDs
in observer history. Do not reconstruct a missing production event from an
expected model transition.

To add an event, place its exact action name around a real semantic step,
add a decoder branch and run a scenario that triggers it. To move a capture
point, move both clock reads around that step and capture its post-state after
the end read while the original lock still protects it. For unlock events,
copy the protected snapshot first, release the guard, then read the end clock.
Never reread shared state after unlocking or extend a lock through user copy.

Rerun `bash harness/run.sh` after changes. `src/validate.py` uses Specula's
resource wrapper with a 3 GiB heap, 512 MiB direct memory and two workers.
It preserves every `Trace.cfg` check. A nonzero initial-state count and an
error-free run accept the replay. Only a failure solely of `TraceMatched`
permits the supplied `TraceSearch.cfg` completion-witness search. A safety
error, timeout, zero-state run or missing witness rejects the trace.
This is the Phase 2.5 quick replay. The receiver controls later phases.

## Applied hook locations

Paths are relative to `source/`. The original syscall hooks call the begin
and completion observers in `scm_trace.rs`. The byte-prefix helper is at
`ostd/src/mm/io/mod.rs:803`, and the clock reader is at
`ostd/src/arch/x86/timer/hpet.rs:65`.

| Event | Applied source location |
| --- | --- |
| `AuxiliaryDataFromControl` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:343` |
| `AuxiliaryDataGenerateControlPeek` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:424` |
| `AuxiliaryDataGenerateControlRecv` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:423` |
| `CUserMsgHdrWriteControl` | `kernel/core/src/util/net/socket.rs:153`, `kernel/core/src/util/net/socket.rs:165` |
| `ClosedFileDrop` | `kernel/core/src/syscall/close.rs:62` |
| `ControlMessageWriteAllTo` | `kernel/core/src/net/socket/util/message_header.rs:131` |
| `FileMessageReadFrom` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:115` |
| `FileMessageWriteCapacity` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:130`, `kernel/core/src/net/socket/unix/ctrl_msg.rs:139` |
| `FileMessageWriteHeader` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:162` |
| `FileTableCloseFile` | `kernel/core/src/syscall/close.rs:37` |
| `FileTableInsert` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:188` |
| `MessageQueueTrySendCopy` | `kernel/core/src/net/socket/unix/datagram/message.rs:112` |
| `MessageQueueTrySendEnqueue` | `kernel/core/src/net/socket/unix/datagram/message.rs:152` |
| `MessageQueueTrySendLock` | `kernel/core/src/net/socket/unix/datagram/message.rs:89` |
| `MessageQueueTrySendUnlock` | `kernel/core/src/net/socket/unix/datagram/message.rs:125`, `kernel/core/src/net/socket/unix/datagram/message.rs:163` |
| `MessageReceiverDropBegin` | `kernel/core/src/net/socket/unix/datagram/message.rs:393` |
| `MessageReceiverDropComplete` | `kernel/core/src/net/socket/unix/datagram/message.rs:398` |
| `MessageReceiverDropReference` | `kernel/core/src/scm_trace.rs:140` |
| `MessageReceiverTryRecvCopy` | `kernel/core/src/net/socket/unix/datagram/message.rs:290` |
| `MessageReceiverTryRecvDequeue` | `kernel/core/src/net/socket/unix/datagram/message.rs:316` |
| `MessageReceiverTryRecvLock` | `kernel/core/src/net/socket/unix/datagram/message.rs:252` |
| `MessageReceiverTryRecvSelect` | `kernel/core/src/net/socket/unix/datagram/message.rs:261` |
| `MessageReceiverTryRecvUnlock` | `kernel/core/src/net/socket/unix/datagram/message.rs:272`, `kernel/core/src/net/socket/unix/datagram/message.rs:298`, `kernel/core/src/net/socket/unix/datagram/message.rs:334` |
| `RecvBegin` | `kernel/core/src/scm_trace.rs:108` |
| `RecvTemporaryDrop` | `kernel/core/src/scm_trace.rs:144` |
| `RequestCleanup` | `kernel/core/src/scm_trace.rs:177` |
| `SendBegin` | `kernel/core/src/scm_trace.rs:108` |
| `SendTemporaryDrop` | `kernel/core/src/scm_trace.rs:142` |
| `SenderReuse` | `kernel/core/src/syscall/dup.rs:86` |
| `SysRecvmsgComplete` | `kernel/core/src/scm_trace.rs:118` |
| `SysRecvmsgReleaseBorrow` | `kernel/core/src/syscall/recvmsg.rs:50` |
| `SysRecvmsgWriteback` | `kernel/core/src/syscall/recvmsg.rs:65` |
| `SysSendmsgComplete` | `kernel/core/src/scm_trace.rs:120` |
| `VmWriterWriteFd` | `kernel/core/src/net/socket/unix/ctrl_msg.rs:206` |
