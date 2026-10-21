# Instrumentation for Unix datagram SCM_RIGHTS

Instrument Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76` to follow one
nonempty datagram from reference capture to final release. Each action below
needs a production hook. These instructions hand off instrumentation design.
No harness, kernel patch or production trace was generated in this phase.

Use nonblocking AF_UNIX SOCK_DGRAM sockets, ordinary files or pipe endpoints,
one valid SCM_RIGHTS input array, receive flags 0 or MSG_PEEK, and separate,
stable payload/control/msghdr regions. Outer metadata stays writable.
Configure faults before entry and keep permissions fixed until return.

## 1. Trace event schema

Use Category B per-thread timeboxes. Each thread records into a preallocated
private buffer. Merge buffers into NDJSON without sorting overlapping events
into an invented total order. Preserve each thread's program order and replace
timestamps with their dense ranks, preserving equality and strict ordering.
`Trace.tla` groups the merged lines by `tid` and uses `ViablePIDs` to respect
nonoverlapping intervals. There is no global sequence-number counter.

Store normalized traces under `../traces/`, relative to `spec/`.
`Trace.tla` defaults to `../traces/trace.ndjson`; `IOEnv.JSON` selects another
file. It loads NDJSON directly, so a separate per-thread JSON container is
unnecessary. Keep original per-thread logs, raw byte captures, identity maps,
source hashes, patch hashes and guest identities beside the normalized trace
as evidence. Do not feed those diagnostic sidecars to the event parser.

The first line is a fixture record, for example:

```json
{"tag":"fixture","schema":1,"source":"0c60537098f4c2949ad2d382aaf499de72263d76","implementation":"Asterinas","receivers":["r1","r2"],"tids":["s","r1","r2","c"],"attemptSlots":2,"rightsCount":4,"objectA":"fileA","objectB":"fileB","sharedTable":true,"setupFDCount":5,"maxFD":22,"payloadSize":1,"headerBytes":16,"fdBytes":4,"alignment":8}
```

The model begins before sender capture. Its initial ordinary-object owners
are exactly A at `(SenderTable, setupFDCount)` and B at the next number.
Numbers below that prefix represent other objects, socket FDs or test controls.
All remaining slots are free. Establish this layout before tracing, verify it
by an FD scan, and keep at least 16 additional receiver slots. Close inherited
A/B aliases in a separate-table receiver before initialization. Do not discard
a real initial owner merely because it does not fit the model. Adapt the
fixture or revise the initialization explicitly.

For four entries, the send array is A, B, A, B. Object identity means the
captured FileLike/open file description, not inode number or numeric FD.
Use stable trace IDs attached to the original objects and a generation-aware
message ID. Repeated entries for the same object retain their multiplicity.
Do not clone an Arc merely to keep an identity alive for logging.

Each subsequent line has this envelope:

```json
{"tag":"trace","event":"FileTableInsert","tid":"r1","op":["r1",1],"start":21,"end":22,"args":{},"post":{"rx":{},"slot":{"slot":["shared",7],"object":"fileA","origin":{"kind":"Received","entry":[["r1",1],1]}},"balance":[{"object":"fileA","delta":1},{"object":"fileB","delta":0}]}}
```

This envelope illustrates shape only. The empty `post.rx` is not a valid
snapshot: it must contain every field of `EmptyReceiver` in `base.tla`.
Required post fields are listed in the action table and enforced exactly by
`RequiredFields`. There are no optional post-state tests or silent actions.
Unknown events, missing fields, mismatched state and unfinished traces fail.
Metadata, source identity, event envelopes and per-thread time ordering are
asserted during initialization. A trace result counts only when TLC reports
a nonzero initial-state count and satisfies the acceptance rule in section 3
below. Run `Trace.cfg` first with every existing check enabled, including
`TypeOK` and `TraceMatched`. A zero-state run is invalid evidence even if TLC
prints that it found no error.

| Envelope field | Meaning |
| --- | --- |
| `tag`, `event` | Literal `trace` and the exact action name below. Every event maps to one full base action. |
| `tid` | The stable thread ID in the fixture's `tids`. Sender, receiver and cleanup actions follow their actual executing threads. |
| `op` | For receiver events, `[tid, attempt]` with attempts starting at 1. Use `[]` otherwise. A thread finishes an attempt before starting its next one. |
| `start`, `end` | Ordered timestamps immediately around the semantic step, with `start <= end`. Capture scalar post-state immediately after `end` while any already-held lock still protects it. |
| `args` | `SendBegin`: `{"good":boolean}`. `RecvBegin`: `{"mode":"Recv" or "Peek","layout":name,"good":boolean}`. Close/remove/drop: `{"slot":[table,fd]}`. Other actions: `{}`. |
| `post` | Exactly the fields required for that event in the table below. No sparse receiver records. |

The permitted layout names and byte capacities are defined by `Layout` in
`base.tla`. Full, NULL, zero, undersized header, header-only, incomplete
integer, exact one integer, partial padding and space for two integers are
distinct. `FirstFault` fails entry 1. `LaterFault` and `PartialFault` fail
entry 3 after two complete integers. The latter copies two bytes of entry 3.
`HeaderFault` and `HeaderPartial` copy zero and eight header bytes.
Measure the ABI and actual copy effects. If a layout cannot produce a planned
partial byte count, record that coverage gap. Do not rewrite observations to
the planned outcome.

### State fields and their production sources

The event record captures changed locations and the operation's own state.
It does not obtain a fabricated atomic snapshot of all kernel state.

| Post field | Required representation and capture rule |
| --- | --- |
| `send` | Full `send` record: `pc`, `temp`, `capturedObjects`, `payloadGood`, `result`. Derive PC from the hook location, capture actual object IDs from the owned vector, retain the ordered capture history, record the observed copy result. Result is `Pending`, `OK` or `EFAULT`. |
| `queue` | Full `queue` record: `msg`, `rights`, `lock`, `enqueued`, `consumed`, `disposed`, `disposeTemp`, `closed`. Read message/list IDs while the existing queue mutex is held. Counters record observed enqueue/pop/dispose events on this queue. `lock` is the current operation tuple, `["Sender",0]`, `["Disposer",0]` or `["NoOwner",0]`. The zero attempt index keeps these owner tags distinct from receiver operations. Empty message is `NoMessage`. |
| `rx` | Full local receiver record, with the field mapping below. `Trace.tla` compares it to the primed operation state after invoking the full base action. |
| `slot` | `{"slot":[table,fd],"object":id,"origin":value}` for the touched FD slot. Capture insertion/removal results under the existing table lock. Origin is `{"kind":"Sender"}`, `{"kind":"Reuse"}`, `{"kind":"Other"}`, or `{"kind":"Received","entry":[op,entry]}`. Keep observer provenance attached to the slot under that lock. |
| `pendingClose` | `{"slot":[table,fd],"object":id}` from the actual `ClosedFile`, or `NoObject` after its drop. This is separate from the removed table entry. |
| `balance` | An array containing both object IDs exactly once and their signed clone/drop deltas for this event. Build it from actual captured/cloned/released entry IDs. Duplicates count individually. The trace predicate compares it to `refBalance' - refBalance`; no global strong-count read is required. |
| `released` | An array of received `[op,entry]` identities explicitly removed by this close. It is empty for original/reused sender FDs. The trace compares it to the new entries in `releasedEntries`. |
| `cleanup`, `reuse` | Boolean completion of the fixture's cleanup request or successful controlled sender reuse. Neither is inferred from an expected invariant. |

| Receiver fields | Capture and meaning |
| --- | --- |
| `pc`, `mode`, `layout`, `payloadGood` | Map the current production hook to the PC in the base action. Mode comes from flags. Layout includes every member of `Layout(name)` and is fixed by measured setup. `payloadGood` distinguishes the prearranged valid/fault buffer. |
| `selected`, `payloadResult`, `faultRetained` | Selected message ID and actual payload copy result, `Pending`, `OK` or `Fault`. Record queue membership at a fault while still locked. A later retry must not replace this historical observation. |
| `selectedRef`, `temp` | Ordered object IDs actually owned by the popped local Message or the generated control-message vector. Record each transfer and each individual release. Borrowed selection is not an extra file owner. |
| `nfit`, `index`, `fdForEntry`, `installedObjects`, `installed` | Selected count and loop position from `FileMessage::write_to`; FD and object returned by every insertion. Arrays indexed by entry hold -1 or `NoObject` before installation. `installed` is the set of insertion events observed so far, including failed-number entries. |
| `numberComplete`, `numberFailed`, `delivered` | Accumulate actual full-value copy outcomes. Delivery requires an observed installation and a successful complete integer copy. Never derive delivery from reported length or header success. |
| `dirtyBytes`, `cursor` | `dirtyBytes` contains offsets actually covered by copying, including partial effects. It is not a byte-difference test, because a copied byte may equal its sentinel. Record `write_fallible`'s copied length before the `write_val` rewind. Capture the restored/advanced cursor separately. |
| `headerResult`, `headerLen`, `controlError` | Actual header copy result and full header length only on success. Header length is 0 if no complete header exists. Error stage is `""`, `Null`, `Capacity`, `Header` or `Number`. Keep raw partially written header bytes in the evidence sidecar. |
| `internalLen`, `ctrunc`, `reportedLen`, `reportedCtrunc`, `msghdrWritten`, `returnValue` | Capture the `write_all_to` return tuple, then separately capture msghdr writeback and final syscall result. Before writeback, `reportedLen` retains input capacity. An early EAGAIN/EFAULT does not publish flags/length. Positive result is the fixture payload size. |
| `generated`, `generatedObjects`, `peekBefore`, `peekAfter`, `peekMessageBefore`, `peekMessageAfter` | Record actual generation and list contents. For PEEK, capture the queue IDs before generation and read them again after generation while locked. The model records `queue'.rights` and `queue'.msg` in the after-snapshots. Capture the independently cloned list separately. Keep these observations after later dequeue so retention checks do not confuse a later ordinary receive with the earlier PEEK. |

Encode sequences as JSON arrays. Encode the receiver's `installed`,
`numberComplete`, `numberFailed`, `delivered` and `dirtyBytes` sets as
arrays without duplicates. `DecodeReceiver` converts exactly those five
arrays to TLA+ sets. `fdForEntry` and `installedObjects` remain arrays in
entry order. No live object ID may equal `NoObject` or `External`.

Historical fields are observer records, not additional kernel owners.
Reconstruct them from recorded concrete events, with object identities and
copy results preserved. Do not synthesize a missing production event from the
next model action. A trace adapter must retain the raw event that supports each
derived history member.

## 2. Action-to-code mapping

Paths in this table are relative to `kernel/core/src/`, except the marked
OSTD and kernel-library paths. Source line numbers refer to the pinned commit.
The event name is exactly the spec action name. The post column lists the
mandatory fields consumed by `ValidatePostState`.

| Action / event | Source and precise trigger | Required post fields |
| --- | --- | --- |
| `SendBegin` | `syscall/sendmsg.rs:23-40`. After fixture setup, before any ordinary-file capture. Record the already configured send payload layout. | `send` |
| `FileMessageReadFrom` | `net/socket/unix/ctrl_msg.rs:107-110`. One event after each successful `into_owned` and vector push, retaining the actual sender slot and object mapping in raw evidence. | `send, balance` |
| `AuxiliaryDataFromControl` | `net/socket/unix/ctrl_msg.rs:230-240`. After moving the single file-message vector into auxiliary data. | `send` |
| `MessageQueueTrySendLock` | `net/socket/unix/datagram/message.rs:60`. Immediately after acquiring the queue mutex. | `send, queue` |
| `MessageQueueTrySendCopy` | `net/socket/unix/datagram/message.rs:79-81`. Capture success/error before `?` exits. No rights transfer has occurred yet. | `send` |
| `MessageQueueTrySendEnqueue` | `net/socket/unix/datagram/message.rs:83-96`. After auxiliary transfer and queue publication, before releasing the mutex. | `send, queue` |
| `MessageQueueTrySendUnlock` | `net/socket/unix/datagram/message.rs:81,100`. At the queue-guard release on either success or error. Copy the final protected state into the thread buffer before releasing the existing guard. | `send, queue` |
| `SendTemporaryDrop` | `net/socket/unix/datagram/socket.rs:95,134-135`, `net/socket/unix/ctrl_msg.rs:215-217`. One event per actual Arc release when the failed-send auxiliary vector drops. Successful send has an empty vector. | `send, balance` |
| `SysSendmsgComplete` | `syscall/sendmsg.rs:40-42`. At completion after send-local ordinary-file references have dropped, on success and error. | `send` |
| `RecvBegin` | `syscall/recvmsg.rs:20-33`. After immutable fixture setup, before queue locking. Record call/attempt ID, flags and buffer layout. | `rx` |
| `MessageReceiverTryRecvLock` | `net/socket/unix/datagram/message.rs:179`. Immediately after acquiring the queue mutex. | `rx, queue` |
| `MessageReceiverTryRecvSelect` | `net/socket/unix/datagram/message.rs:182-194`. After front-message selection or empty-queue decision, before copy/return. | `rx, queue` |
| `MessageReceiverTryRecvCopy` | `net/socket/unix/datagram/message.rs:195`; `util/iovec.rs:304-320`. After actual payload copy result, before propagation through `?`. On failure, also snapshot fault-time queue membership. | `rx, queue` |
| `MessageReceiverTryRecvDequeue` | `net/socket/unix/datagram/message.rs:202-203`. After pop and length update, before ancillary generation. The local Message still owns its rights. | `rx, queue` |
| `AuxiliaryDataGenerateControlRecv` | `net/socket/unix/ctrl_msg.rs:304-310`. After the normal path moves rights into its control vector. | `rx` |
| `AuxiliaryDataGenerateControlPeek` | `net/socket/unix/ctrl_msg.rs:304-310`. Bracket the clone and capture both queue list and cloned vector while the caller still holds the mutex. | `rx, queue, balance` |
| `MessageReceiverTryRecvUnlock` | `net/socket/unix/datagram/message.rs:184,195,217`. Queue-guard release on every selected/empty/error exit. | `rx, queue` |
| `SysRecvmsgReleaseBorrow` | `syscall/recvmsg.rs:43-45`. Immediately after the explicit file-table borrow drop. | `rx` |
| `CUserMsgHdrWriteControl` | `util/net/socket.rs:143-156`. After NULL handling or successful writer construction. Invalid address-range metadata is excluded. | `rx` |
| `FileMessageWriteCapacity` | `net/socket/unix/ctrl_msg.rs:117-134`. After count/too-short decision, before attempting the header. Include the early payload-length error path. | `rx` |
| `FileMessageWriteHeader` | `net/socket/unix/ctrl_msg.rs:135`; OSTD `ostd/src/mm/io/mod.rs:795-808`. Record the result and actual covered bytes before error propagation. | `rx` |
| `FileTableInsert` | `net/socket/unix/ctrl_msg.rs:139-144`, `fs/file/file_table.rs:190-193`. After the actual clone/insertion while the write guard still protects the slot. Emit before the following integer copy. Lowest-free allocation is at Asterinas `kernel/libs/aster-util/src/slot_vec.rs:66-76`. | `rx, slot, balance` |
| `VmWriterWriteFd` | `net/socket/unix/ctrl_msg.rs:148`; OSTD `ostd/src/mm/io/mod.rs:795-808`. Record success or copied-prefix failure and the restored cursor. Do not close the inserted FD in an error hook. | `rx` |
| `ControlMessageWriteAllTo` | `net/socket/util/message_header.rs:109-129`. After suppressed error or successful length/padding computation. Padding advances the cursor without writing bytes. | `rx` |
| `SysRecvmsgWriteback` | `syscall/recvmsg.rs:53-58`. After successful outer msghdr copying, before the control-vector destructor. | `rx` |
| `RecvTemporaryDrop` | `syscall/recvmsg.rs:32-58`, `net/socket/unix/ctrl_msg.rs:69-71`. One event for each actual temporary-list Arc release at scope exit. | `rx, balance` |
| `SysRecvmsgComplete` | `syscall/recvmsg.rs:40,58`. After all ordinary-file locals drop, including early error exits. A return-value decision alone is too early. | `rx` |
| `RequestCleanup` | Fixture boundary after observed send/receive completion, before intentional closes. Verify all started receivers are quiescent and stop new calls. | `cleanup` |
| `FileTableCloseFile` | `syscall/close.rs:22-28`, `fs/file/file_table.rs:196-205`. After removal into `ClosedFile`, before its later destruction. | `slot, pendingClose, released` |
| `ClosedFileDrop` | `syscall/close.rs:35`, `fs/file/file_table.rs:274-297`. After the stored Arc actually drops, outside the file-table lock. Entry to `Drop::drop` precedes field destruction and is not sufficient. | `pendingClose, balance` |
| `SenderReuse` | `syscall/dup.rs:21-34,77-82`. After successful controlled dup2(B, old-A), with old-A absent and no receives started. | `slot, balance, reuse` |
| `MessageReceiverDropBegin` | `net/socket/unix/datagram/message.rs:262-268`. At the final receiver's locked destruction, retain IDs for the old queue contents as pending disposal owners. | `queue` |
| `MessageReceiverDropReference` | `net/socket/unix/datagram/message.rs:268`, `net/socket/unix/ctrl_msg.rs:215-217`. One event per queued ordinary-file Arc actually released under the existing lock. | `queue, balance` |
| `MessageReceiverDropComplete` | `net/socket/unix/datagram/message.rs:268-270`. After all queued rights have dropped and the guard is released. | `queue` |

## 3. Special considerations

Do not allocate, format JSON, block on output, acquire a shared tracing mutex
or add a global ID lookup in these critical sections. Preassign IDs and reserve
thread-local storage during fixture setup. Copy scalar IDs/results into that
storage under the existing production lock, then serialize outside it. Report
overflow as invalid evidence. Never silently drop an event.

Bracket the actual step with timestamps. For unlock events, snapshot the
protected values before releasing the guard and report the boundary after
release, without rereading potentially changed shared fields. Do not lengthen
Asterinas's queue lock through publication or its insertion lock through user
copy. The model intentionally permits another receiver to select or install
between those operations.

Refine queue-lock acquisition events to a point immediately after the existing
mutex has been acquired, using equal start/end timestamps for that marker.
Do not include time spent waiting in that acquisition event. Bracket table
insertion/removal within the already-held table lock. These observations
preserve each lock's real acquisition order without adding a global tracing
counter, while allowing publication outside the queue lock to overlap freely.
Verify that timestamps from different guest CPUs share a calibrated clock.

Destructor hooks must observe real ownership release. An entry hook in
`ClosedFile::drop` runs before its Arc field is destroyed. A hook at the
`Ok` expression in `sys_recvmsg` runs before local destruction. Use scoped
observers with verified drop order or hooks at the actual field-release sites.
Keep only IDs in observers. Source readback and compiled hook placement must
show that logging neither extends a reference lifetime nor introduces an
extra clone. If a hook cannot observe the required boundary, report the gap
instead of replacing it with a silent model step.

The model aggregates PEEK's clone while holding the queue lock. Its per-object
deltas still count every cloned entry. Individual temporary/destructor drops
remain separate events. The failed entry installed before integer failure
must remain visible in FD scans and in the table until explicit cleanup.
Observe it before removing it.

Record raw user bytes before parsing ancillary output. Keep complete integers,
partial bytes, header success, skipped padding and reported length distinct.
The normalization of `dirtyBytes` requires actual copy coverage, not comparing
bytes against a sentinel and not subtracting writer cursors after a rewind.
Decode fully copied FD integers and verify them against `fdForEntry`.
Validate the header's SOL_SOCKET/SCM_RIGHTS type and length on a complete
header. Keep payload prefix measurements in the raw sidecar; the bounded
payload model checks success/failure and consumption, not byte contents.

Every normalized trace must end with all started operations completed,
requested cleanup and final ordinary-object release. `TraceEndComplete`
rejects a trace cut off before destructor/close/disposal work. Empty or
metadata-only traces cannot validate. `Trace.cfg` enables `TraceMatched`
and core protocol/structural checks but excludes the expected AST-32/AST-36
compatibility failures, so a faithful implementation trace can replay them.
The separate hunt cfgs retain those failures.

Timebox matching explores permitted interleavings and prunes steps whose base
preconditions or captured state do not match. `TraceMatched` requires fair
progress along every remaining matching branch. An overlapping event can
disable a pending event in one ordering while another ordering consumes the
entire log. A failure of that temporal property alone therefore requires a
completion-witness search before deciding whether the trace is accepted.

Apply this acceptance rule to the same input bytes and model in both runs:

1. Accept when `Trace.cfg` completes without errors and reports a nonzero
   initial-state count. Keep every configured check, including `TraceMatched`.
2. If `Trace.cfg` fails only on `TraceMatched`, run `Trace.tla` with
   `TraceSearch.cfg`. Accept only if TLC reports a nonzero initial-state count
   and violates exactly `TraceNoCompleteMatch`. That inverse invariant is the
   negation of all events consumed and `TraceEndComplete` holding, so its
   counterexample is a complete matching witness. Save the full path and both
   run logs. This acceptance does not make the universal temporal check pass.
3. Reject any other failure, including an assertion, safety or terminal-check
   failure. Reject when the witness search finishes with no witness. A timeout,
   evaluation error or zero-state result cannot establish acceptance.

`TraceSearch.cfg` retains every safety and terminal invariant from `Trace.cfg`
and uses the same `TraceSpec`, full base actions and mandatory
`ValidatePostState` comparisons. Every event on a witness must satisfy those
post-state checks. A corrupted post-state that cannot match has no witness and
is rejected. The search adds `TraceNoCompleteMatch` instead of checking the
universal temporal property. `Trace.cfg` and `TraceMatched` remain unchanged.
An error-free witness search means that no complete path exists. Its exit
code zero is therefore a rejection, while the specific inverse-invariant
violation is evidence of a witness. A safety failure can never be overridden
by a witness found in another run.

Run both configurations with the Java, jar and resource settings in
[the revision 3 check instructions](generation-checks/README.md#revision-3-review-findings-5-and-6).
Set `JSON` to the same NDJSON path for both commands. The supplied
`run_r3_checks.py trace` executes both modes on the reviewer's valid, overlap
and four negative fixtures and records the expected outcome for each.

For concurrency coverage, use at least two guest CPUs, disjoint buffers and
actual overlapping production timeboxes. User-space start barriers do not
prove an insertion/copy window occurred. Preserve lock-event order, per-thread
order and observed interleavings through preprocessing. Run short traces for
SCM-01 through SCM-14, including empty competing receives and repeated PEEK.
Record event coverage and which traces have overlapping intervals separately
from sequential fault controls.

Linux controls use the same external layouts and account for already delivered
FDs after later faults. Identify the running Linux kernel and reconcile it
with reference `4645fefac0b24d509b962c096b0327e87f34b1d2`. Linux reserves,
copies and then installs each FD, writes a prefix header afterward, and holds
its receive iolock through ancillary output. Its payload fault can follow
ordinary unlink. Linux traces cannot be replayed as this Asterinas transition
relation. Keep them as separately attributed reference evidence.

The controller chooses when to generate the harness and run validation.
Follow the shared resource policy: one heavy lane at a time, at most two
workers, bounded memory, and the prescribed MemAvailable checks before heavy
work. Do not reacquire the controller's lock from a phase worker.

## Revision 4 correction

The controller's independent C1/C2 review is this correction's only input.
Every recorded event stays an ordinary NDJSON event line, including serialized
sender setup, send and cleanup. No event is stored in fixture metadata.
`Trace.tla` is byte-identical to `593a85c` and reads the body directly. The
old revision-4 metadata serialization fixtures remain historical evidence
only and are not inputs to the corrected replay path.

Fixture 17 retains four A,B,A,B rights and 32-byte Full capacity. Fixture 18
retains the redesign's one A right and 20-byte Full capacity. CPU pinning and
`SCM_WINDOW` markers remain. The decoder sizes arrays and capacities from
`rightsCount` and copies `attemptSlots` from fixture metadata. Kernel hooks,
their record layout and the fixture C source are unchanged by this correction.

The summary's top-level overlap fields count every unordered cross-thread
event pair over the whole trace. They retain point events in the denominator
and use strict interval intersection. The structural bound is the existing
audit's `n + m - 1` for two internally disjoint receiver streams, divided by
the whole-trace pair count. Sender setup/send/cleanup is serialized outside
the receiver window, so it adds pairs without adding possible intersections.

The separate `receive_window` summary selects events wholly inside the raw
`SCM_WINDOW` endpoints only for analysis. It includes its own fraction and
bounds and explicitly says that it is not the timebox guide's criterion.
Missing historical markers yield null. Neither marker endpoints nor
selected events enter fixture metadata. Timestamp rank maps still preserve
every event's original endpoints, equality and order.

Case 17's full inventory is 26 sender, 5 empty-receiver and 26 successful
receiver events. Its whole-trace bound is 30/936 = 3.205%, and its window bound
is 30/130 = 23.077%. Case 18's successful one-right inventory is 19 sender,
16 PEEK and 17 ordinary events. Its bounds are 32/899 = 3.560% and
32/272 = 11.765%. Both whole-trace bounds fall below 20%. Point markers tighten
them further. See [the harness guide](../harness/INSTRUMENTATION.md#revision-4-correction)
for inventories, measurements, point-aware bounds and the unrun guest work.
