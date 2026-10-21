# Unix datagram SCM_RIGHTS source contracts

Use this preparation to run bounded verification of one Unix datagram's file
references, receiver FD installation, number publication, and cleanup. The goal
is the complete protocol pipeline, including useful bounded coverage when no
new model-checkable defect is found. Analysis must establish the model's
contract and evidence limits, rather than use novelty as its continuation gate.

This is manual source preparation, not a native analysis result or its review.
Every case below is `NOT_RUN`. The source-preparation subtask ran no phase,
model checker, test, build, guest, or provider probe. The controller records
separate readiness probes in the shared package. No finding was added or promoted.

## Inputs and prior evidence

- Asterinas was read from the clean standalone checkout
  `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source`.
  Its HEAD is `0c60537098f4c2949ad2d382aaf499de72263d76` and tree is
  `4693fdec88cd7da14bed4f1541eba593f123059c`. This preserves Git history and
  is the selected local main snapshot, not a claim about today's remote main.
- Linux was read from
  `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5`, the prepared
  selected-file copy of the source export pinned to
  `4645fefac0b24d509b962c096b0327e87f34b1d2`.
  The copy has no Git history. These source comparisons are not Linux runtime
  controls. A later control on another kernel must identify that kernel and
  reconcile any difference before changing the oracle.
- This is an informed follow-up to
  [the socket assessment](../../specula-scope-assessment-2026-10-02/socket-fd-scopes.md)
  and [the priority review](../../specula-scope-assessment-2026-10-02/ultraplan-priorities-2026-10-03.md).
  Their preliminary recommendation to decide later whether to model does not
  supersede the user's subsequent complete-protocol-verification goal.
- [The catalog](../../asterinas-bug-findings-2026-08/README.md) and
  [old-ID map](../../asterinas-bug-findings-2026-08/id-map.md) retain AST-32 as
  `SOURCE LEAD`, originating in Recon analysis MC-4/T-4/CR-5 at
  `604948581512d83734377974d4c34adb4530f2d7`. The receive installation order is
  still present at the new pin. Recon analysis MC-2/T-3 is AST-36. AST-31 is
  Recon MC-3/T-5/CR-3 and remains a separate whole-msghdr/output-field question.
  These are prior leads, not new discoveries. Upstream status was not refreshed.
- The original [Recon analysis][recon-analysis] was read for the SCM_RIGHTS
  ownership and allowed-effects discussion. Its SHA-256 is
  `f8e1fdd25f0dc12519aa206fba8e58861220d4a5321ab36910b3aa2549192243`.

## Scope and source map

The target is Category B: a kernel ownership and publication protocol with
queue and file-table locks. Use AF_UNIX `SOCK_DGRAM`, a nonempty payload, one
SCM_RIGHTS message, and ordinary files or pipe endpoints. Send-side reference
capture, PEEK, competing receivers, and final release belong only where they
explain that same message's ownership. Each claim below distinguishes a file
object from its sender FD and from every receiver FD assigned to that object.

In the table, Asterinas paths are relative to `kernel/core/src/`, except OSTD.
Linux paths are relative to the pinned Linux export. Links open the inspected
local source. Line numbers are for the pins above.

| Anchor | Source and boundary |
| --- | --- |
| A1 | [sendmsg.rs:31][a-syssend] lines 31–59 and [unix/ctrl_msg.rs:87][a-ctrl-read] lines 87–114 resolve sender numbers to owned file references before send. |
| A2 | [unix/datagram/message.rs:54][a-send] lines 54–100 lock the queue, copy payload, then move auxiliary references into the new message and enqueue it. |
| A3 | [unix/datagram/message.rs:174][a-recv] lines 174–217 keep the queue mutex across payload copy and normal dequeue or PEEK selection. |
| A4 | [unix/ctrl_msg.rs:284][a-generate] lines 284–313 move references for normal receive and clone them for PEEK. |
| A5 | [unix/ctrl_msg.rs:116][a-publish] lines 116–151 choose capacity, write the control header, then insert each file under the file-table write lock before copying its integer FD. The lock does not span that copy. |
| A6 | [util/message_header.rs:104][a-report] lines 104–129 turn a control-message write error into `MSG_CTRUNC` and stop. The failed message contributes zero to the reported length, even if bytes or FD installations already occurred. |
| A7 | [syscall/recvmsg.rs:32][a-sysrecv] lines 32–58 receive, release the file-table borrow, write the optional address and control output, and finally write the whole msghdr. [util/net/socket.rs:138][a-usermsg] lines 138–156 handle NULL control and construct the writer. |
| A8 | [fs/file/file_table.rs:190][a-table] lines 190–205 install or remove a file reference. [syscall/close.rs:19][a-close] lines 19–35 drop a removed file outside the lock. [unix/datagram/message.rs:262][a-drop] lines 262–270 drop queued messages when the receiver is destroyed. |
| A9 | [ostd/src/mm/io/mod.rs:786][a-copy] lines 786–808 report a failed complete-value copy and restore the writer cursor, but do not restore already written bytes. [ostd/src/mm/vm_space.rs:171][a-writer] lines 171–190 validate the address range, not the writability of every page at writer creation. |
| A10 | [util/message_flags.rs:37][a-flags] lines 37–69 list PEEK/TRUNC as supported receive flags. [net/socket/mod.rs:48][a-nonblock] lines 48–68 use the socket's nonblocking status for a one-shot receive attempt. |
| L1 | [fs/file.c:1355][l-install] lines 1355–1379 reserve an FD, copy its number, release the reservation on failure, and install the referenced file only after successful number copy. |
| L2 | [net/core/scm.c:323][l-detach] lines 323–379 deliver FDs one by one, write the control header afterwards, set truncation on partial delivery, and release the temporary file list. Lines 133–146 implement that release. |
| L3 | [net/unix/af_unix.c:2493][l-recv] lines 2493–2602 obtain a datagram before payload copy, detach or clone SCM references, process control output, then release the receive reference. [net/core/datagram.c:168][l-queue] lines 168–203 distinguish ordinary unlink from PEEK reference acquisition. |
| L4 | [net/unix/af_unix.c:1930][l-refs] lines 1930–1955 detach, duplicate, or destroy the message's SCM references. [net/core/scm.c:382][l-dup] lines 382–404 clone a list with file references. Lines 477–505 drop the list when no control buffer is supplied. |
| L5 | [net/socket.c:2762][l-sysrecv] lines 2762–2815 publish address, flags, and control length after protocol receive. A later output failure does not roll back earlier FD delivery. |
| L6 | [net/unix/af_unix.c:2089][l-send] lines 2089–2098 copy send payload before queue publication at 2232–2239. Error exits at 2247–2251 release the skb and remaining SCM list. [net/unix/af_unix.c:722][l-close] lines 722–730 drain and free queued messages on socket release. |

`FileMessage` and `AuxiliaryData` own `Vec<Arc<dyn FileLike>>` at
`unix/ctrl_msg.rs:69–71,215–217`. Dropping a temporary list releases its own
references. It does not remove an independently installed file-table entry.
The scope concerns stranded process ownership when a number fails to publish,
not an assertion that all discarded ancillary references leak kernel memory.

## Contract and case table

Each row is a source-supported experiment design. All Linux and Asterinas
runtime cells are `NOT_RUN`. Preserve the complete result tuple: return and
errno, payload bytes, raw control bytes, complete integer boundaries, reported
control length and flags, FD-to-object associations, queue state, and cleanup.
Do not derive one component from another.

| Case | Setup and contract to check | Asterinas source and static prediction | Linux source and allowed effects |
| --- | --- | --- | --- |
| SCM-01 | After successful send, close or reuse the sender's original FD. The received reference must still identify the captured object. | A1/A2 capture an owned reference and move it into the queue. A4/A5 never look up the sender number again. | L2/L4 operate on file references. Sender and receiver FD numbers need not match. |
| SCM-02 | Receive with sufficient writable control space, including distinct objects and repeated references to one object. Every published FD must name the intended object. | A3–A7 consume once and publish each selected entry. Distinct FD entries may legitimately share one object. | L1/L2 install one new FD per delivered array entry. Earlier entries remain valid after later entries complete. |
| SCM-03 | Supply NULL control, zero control length, or less than one full FD after the header. Payload reception may succeed with `MSG_CTRUNC` and no new FD. | A5 rejects zero capacity before insertion. A6/A7 report truncation. Normal receive drops undelivered temporary references. | L2/L4 install none and destroy undelivered SCM references. Normal receive still consumes the datagram. |
| SCM-04 | Receive only a fitting prefix of the sent rights. Preserve that prefix and release the undispatched rights. | A5 selects the fitting count and sets `MSG_CTRUNC`; A6 reports the completed header and padding. | L2 installs only the fitting count, marks truncation, and releases the temporary list. Whole-message rollback is not required. |
| SCM-05 | Make the control header writable but the first complete FD integer unwritable. The failed number must not leave a receiver FD installed under the Linux reference behavior. | A5 inserts before the failing copy and has no removal branch. A6 reports control length zero and `MSG_CTRUNC`; with other outputs valid, A7 can return the payload length. This is existing AST-32. | L1 releases the reserved slot before any install. L2 marks truncation and releases the temporary references. The datagram may already be consumed. |
| SCM-06 | Permit two FD integers, then fault the next integer, with the header and outer outputs writable. Account separately for the prefix, failed entry, and untouched suffix. | A5 retains the two published entries and the additional entry installed before the failed copy. A6 does not count the partially completed cmsg, so its reported length is zero. This refines AST-32, not a new ID. | L1/L2 keep the two published entries, release the failing slot, and report a header for the delivered prefix. The prefix is not rolled back. |
| SCM-07 | Keep integer output writable but fault the control header. This is a negative control for overly strong output-atomicity claims. | A5 writes the header first, so that failure reaches A6 before installing an FD. | L2 writes numbers and installs FDs first. A subsequent header write can fail with the delivered FDs retained and without advancing control length. Do not label those FDs invalid merely because no complete header was returned. |
| SCM-08 | PEEK repeatedly, then receive normally, closing every returned FD after observing it. Each successful PEEK may return fresh descriptors for the same object. | A3/A4 retain the queue's references and clone temporary rights on PEEK. Normal receive consumes the original message. | L3/L4 deliberately duplicate SCM references on PEEK. Multiple deliveries by PEEK are allowed. |
| SCM-09 | Fault an individual FD output during PEEK, then retry with valid output. Distinguish the still-queued reference from a transient list and any installed entries. | A4 preserves queue ownership; A5/A6 can reproduce AST-32 on the PEEK copy. | L1 rejects only the failed installation. L3/L4 leave the queued message available. Valid retry may deliver new FDs. |
| SCM-10 | Two receivers compete for one datagram using nonblocking sockets and disjoint output buffers. At most one normal receive consumes it. | A3 serializes queue selection, payload copy and dequeue. FD publication occurs later, after that mutex is released. | L3 serializes receive and unlinks once. An empty-queue attempt can return `EAGAIN`; a scheduler delay alone is not a lost message. |
| SCM-11 | PEEK competes with a normal receiver. Explain each result by the real queue order, while allowing ancillary publication to finish later. | A3/A4 permit a successful earlier PEEK plus normal consumption, or an empty PEEK after consumption. A5 publication can interleave between calls. | L3/L4 permit the same ownership outcomes. There is no requirement that syscall return order match queue-selection order. |
| SCM-12 | Close the final receiver socket while a message remains queued and no receive is active. Release that queue's ordinary file references. | A8 sets the queue contents to `None`, dropping messages and their references. Other sender/receiver FDs remain independent owners. | L6 drains queued messages and L4 supplies their SCM destructor. Observe final pipe EOF only after accounting for every remaining write endpoint. |
| SCM-13 | As a boundary control, fault payload copying before ancillary delivery, then retry with a valid buffer, comparing normal receive and PEEK. | A3 returns before normal dequeue on a payload fault. Its queue and SCM references remain. This is existing AST-36, kept distinct from AST-32. | L3 unlinks a normal receive before payload copy and releases it on fault. PEEK retains the queue reference. Do not assume that every failed receive restores the message. |
| SCM-14 | Fail send payload copying before enqueue with valid control input. The receiver must not gain a newly queued message or FD. | A1 captures rights, but A2 copies before moving them into a message. The failing send drops its temporary rights. | L6 fails before queue publication and drops the skb and remaining SCM list. L4's destructor releases references already transferred into the skb. |

The core contract is per-object, per-delivery ownership. A complete FD-number
write is separate from the cmsg header and the final msghdr. In a stable-buffer
case with no concurrent closes, an entry installed after its own number-copy
failure is different from a previously delivered FD surviving a later fault.
Retain this distinction in both the implementation model and the reference
checks. Expected Linux behavior must remain testable, rather than become a
guard that removes the Asterinas failure path.

## Input layouts and observation requirements

1. Use `socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, ...)`, receive flags
   `0` or `MSG_PEEK`, and a valid nonempty single-iovec payload by default.
   Keep socket timeouts, signals, credentials, `MSG_CMSG_CLOEXEC`, and
   per-call `MSG_DONTWAIT` outside the contract. The latter two exist as
   constants but are not in A10's supported receive mask.
2. Put msghdr, iovec metadata, payload, and ancillary storage in separate,
   stable regions. Use `msg_name = NULL` and leave the whole msghdr writable.
   Configure page permissions before the operation and keep them unchanged
   during it. This isolates FD output from AST-31 and from VM races.
3. Distinguish `CMSG_LEN` from `CMSG_SPACE`. On the native x86-64 layout,
   the header is 16 bytes, each FD is 4 bytes, and alignment is 8 bytes.
   `CMSG_SPACE(sizeof(int))` is 24 bytes and can fit two FD integers. To
   admit exactly one, advertise `CMSG_LEN(sizeof(int))`, or 20 bytes after
   verifying these sizes on the receiving ABI. Keep allocation size separate
   from the advertised length. Check send `cmsg_len` using `CMSG_LEN`.
4. For SCM-05, let a writable header end exactly at a page boundary and make
   the following integer page inaccessible. For SCM-06, an aligned header
   beginning 24 bytes before the boundary leaves two writable FD integers
   before the next page faults. Send at least three rights and advertise
   enough control capacity to reach that failing entry. A capacity truncation
   is a different case. For SCM-07, use a readable but unwritable header page
   and a writable following integer page. Record the actual offsets and
   permissions. These layouts are planned, not executed.
5. Record raw output before parsing it. A6 may report zero bytes after copying
   a prefix, and A9 restores a writer cursor without restoring user memory.
   Neither `msg_controllen` nor cursor progress proves how many integers were
   completely copied. Keep untouched sentinels distinct from complete numbers
   and partial bytes, and never use a partially copied integer as an FD.
6. Establish the receiver FD baseline without opening diagnostic files inside
   the measured interval. In a bounded isolated fixture, scan an established
   FD range with `fcntl(F_GETFD)` and match new descriptors to tagged pipe or
   ordinary-file objects. Account for sender and test-control descriptors.
   A `/proc` directory FD created by the observer is not an SCM leak.
7. For final release, transferring a pipe write endpoint permits an EOF check
   on its read endpoint once every recorded writer has closed. Observe and
   record unexpected installed FDs before cleaning them up. Hidden ownership
   is not proved by a timeout alone. Record each reference-producing setup
   operation and the close order so a remaining legitimate writer is visible.
8. Concurrent receivers use distinct user buffers. The initial scope allows
   their shared table's insertions but does not add unrelated `close/dup2`,
   exec, exit, or namespace changes. A later concurrency claim requires
   `SMP=2` or higher and attributable production events. User-space barriers
   alone cannot prove the kernel installation/publication window occurred.

Existing [stream SCM_RIGHTS tests][a-test-stream] and
[seqpacket PEEK tests][a-test-peek] are API and cleanup examples. They do not
supply this datagram scope's fault or concurrency coverage. Their exact
numeric-FD assertions and different socket kinds are not reusable oracles.

## Required production trace observations

Trace the message identity and file-object identity through successful sender
capture, queue publication, payload-copy result, normal dequeue or PEEK,
temporary reference transfer, each installed receiver FD, each complete FD
integer copy result, control-header result, and final return/length/flags.
Record cleanup of the temporary list, removed table entries, and queued rights
at receiver destruction. Distinguish multiple references to one object.

Use A2/A3's mutex boundaries and A5's per-insertion file-table lock as actual
serialization facts. Preserve A7's explicit borrow release. Instrumentation
must not add blocking work inside these critical sections or turn user-copy
failures into a different order. Source readback must verify the hook locations.
FD scans and pipe behavior provide external observations, but internal transfer
and publication events need production hooks for trace validation.

Linux L3 holds its `iolock` through ancillary output and releases it at line
2600. Asterinas releases its queue mutex before A5. Preserve each implementation's
actual serialization and compare the external contract. Importing the longer
Linux critical section as an Asterinas assumption would hide valid interleavings.

SCM-05/06 may expose an already known sequential mismatch. That does not remove
the verification value of ownership conservation, PEEK versus consumption,
competing receiver selection, and release after partial publication. Keep
compatibility checks for AST-32 and AST-36 distinct from protocol properties.
Record negative results with their bounds instead of inventing a new candidate.

## Boundaries and remaining work

The first model excludes whole-msghdr ABI/writeback analysis (AST-31), stream,
SEQPACKET, IP sockets, accept, credentials, Unix-socket rights and GC cycles
(AST-34), empty-record capacity, resource-limit stress, allocator failure,
signal/restart, socket shutdown races, general VM changes, and CLOEXEC semantics.
AST-36 is a bounded receive-boundary control, not permission to expand into a
generic payload-copy campaign. A control-header fault remains in scope only
to calibrate the per-FD ownership oracle.

Native analysis still owes reviewed scenarios, explicit supported properties,
source/history coverage, and an instrumentation plan. Before any runtime claim,
the receiver must implement the layouts, prove setup and cleanup, obtain
same-program Linux controls, and show which production branches ran. Runtime
identity, provider readiness, stage commands, resource division, and run ownership belong
to the coordinator's handoff. This document neither checks nor authorizes them.

The source-only exit criterion is met: one bounded protocol, source anchors,
operation-specific allowed effects, prior AST attribution, planned observations,
and explicit gaps are documented. Every native phase, build and runtime result
remains `NOT_RUN`; no catalog disposition changed.

[a-syssend]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/syscall/sendmsg.rs:31
[a-ctrl-read]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/ctrl_msg.rs:87
[a-send]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/datagram/message.rs:54
[a-recv]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/datagram/message.rs:174
[a-generate]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/ctrl_msg.rs:284
[a-publish]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/ctrl_msg.rs:116
[a-report]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/util/message_header.rs:104
[a-sysrecv]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/syscall/recvmsg.rs:32
[a-usermsg]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/util/net/socket.rs:138
[a-table]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/fs/file/file_table.rs:190
[a-close]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/syscall/close.rs:19
[a-drop]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/unix/datagram/message.rs:262
[a-copy]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/ostd/src/mm/io/mod.rs:786
[a-writer]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/ostd/src/mm/vm_space.rs:171
[a-flags]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/util/message_flags.rs:37
[a-nonblock]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/kernel/core/src/net/socket/mod.rs:48
[l-install]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/fs/file.c:1355
[l-detach]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/core/scm.c:323
[l-recv]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/unix/af_unix.c:2493
[l-queue]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/core/datagram.c:168
[l-refs]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/unix/af_unix.c:1930
[l-dup]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/core/scm.c:382
[l-sysrecv]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/socket.c:2762
[l-send]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/unix/af_unix.c:2089
[l-close]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/net/unix/af_unix.c:722
[a-test-stream]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/test/initramfs/src/regression/network/unix_stream_err.c:22
[a-test-peek]: /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/source/test/initramfs/src/regression/network/msg_peek.c:236
[recon-analysis]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md:273
