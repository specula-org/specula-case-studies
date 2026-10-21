# Modeling Brief: Asterinas Syscall User-Memory Semantics

## 1. System Overview

- Target: Asterinas, Rust, exact non-Git export of `604948581512d83734377974d4c34adb4530f2d7`; all 53 repository files cited here/report were blob-verified with no mismatch.
- Analysis slice: 40 files, 7,514 Rust code lines (11,356 physical lines), spanning syscall dispatch, VFS, sockets, page cache, signals, and OSTD user-copy primitives.
- Category: **B (Concurrent / Shared-State)**. Cooperating threads can mutate mappings and nested metadata while a syscall changes file offsets, queues, and the file table.
- Reference behavior: Linux syscall-specific partial-progress, message-commit, copy-out, ownership, and restart contracts; there is no universal rollback rule.
- Asterinas uses delayed pointer validation and fallible `VmReader`/`VmWriter` views (`kernel/core/src/context.rs:88-117`, `ostd/src/mm/vm_space.rs:153-195`).
- The coherent model is one syscall transaction automaton: `Idle -> Snapshot -> Validate -> Transfer -> EffectCommitted -> Copyout -> Return/Error/Restart`.

## 2. Scenarios

### Scenario 1: Partial Progress Crosses a Count-Erasing or Split Layer

**Mechanism**: A lower copy reports `(fault, copied)` but an adapter drops `copied`, or one logical vector call is split into independently committed file operations.

**Evidence**:
- Historical: [issue #711](https://github.com/asterinas/asterinas/issues/711) documents the mechanism but is reference evidence only; fixed short-progress bugs [#3181](https://github.com/asterinas/asterinas/issues/3181) and [#1554](https://github.com/asterinas/asterinas/issues/1554) show adjacent commit-accounting failures.
- Code analysis: tuple progress is produced at `ostd/src/mm/io/mod.rs:271-292,332-362`, discarded by `kernel/core/src/error.rs:209-219`, and crossed with page-cache state at `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566,702-759`.
- Code analysis: scalar regular I/O holds one offset lock (`kernel/core/src/fs/file/inode_handle.rs:272-320`), but vector handlers call the file separately per iovec and acknowledge missing atomicity (`kernel/core/src/syscall/preadv.rs:101-125,134-180`, `kernel/core/src/syscall/pwritev.rs:102-131,134-175`).

**Affected code paths**: `read`, `write`, `pread64`, `pwrite64`, `readv`, `writev`, `preadv`, `pwritev`, page cache, pipes, regular files, and shared open-file descriptions.

**Suggested modeling approach**:
- Variables: `copyProgress`, `committedProgress`, `reportedProgress`, `iovIndex`, `filePos`, `appendRange`, `vectorOwner`.
- Actions: split `CopyChunk`, `CommitBytes`, `AdvanceOffset`, `ReturnShort`, and competing scalar/vector file actions.
- Granularity: use `Zero/Positive/Complete`, not byte- or page-exact counts; keep vector serialization as a transaction-level choice.

**Priority**: High
**Rationale**: The mechanism spans several helpers and can couple a visible short result to the wrong shared offset or interleave one vector call with another operation.

### Scenario 2: Socket Backends Choose Different Copy and Queue Commit Points

**Mechanism**: Stream and datagram implementations disagree on whether user copy precedes, accompanies, or follows queue publication/consumption.

**Evidence**:
- Code analysis: TCP converts a positive partial-copy error to short success (`kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs:373-443,446-535`), while ring-buffer helpers commit only after a plain success (`kernel/core/src/util/ring_buffer.rs:31-67,82-145`).
- Code analysis: IP UDP reserves a send buffer before user copy and warns that a fault still sends a packet (`kernel/core/src/net/socket/ip/datagram/bound.rs:86-116`, `kernel/libs/aster-bigtcp/src/socket/bound/udp.rs:140-191`).
- Code analysis: Unix datagram receive pops only after successful copy (`kernel/core/src/net/socket/unix/datagram/message.rs:174-218`), whereas Linux v6.16 frees a non-peek datagram even after copy error (`net/unix/af_unix.c:2493-2602`).
- Code analysis: vsock stages packets because `MultiWrite` hides the faulting packet's partial count (`kernel/core/src/net/socket/vsock/transport/connection/recv.rs:20-70`); Unix datagram/seqpacket queue only payload bytes, so zero-length records/SCM data do not consume capacity, and seqpacket readiness ignores such records (`kernel/core/src/net/socket/unix/datagram/message.rs:34-100`, `kernel/core/src/net/socket/unix/stream/connected.rs:284-359,391-403`).

**Affected code paths**: IP TCP/UDP, Unix stream/datagram/seqpacket, vsock, `sendmsg`, `recvmsg`, `sendmmsg`, and `recvfrom`.

**Suggested modeling approach**:
- Variables: `socketKind`, `queue`, `queuedRecords`, `accountedOccupancy`, `readable`, `messageToken`, `copyProgress`, `messagePublished`, `messageConsumed`, `peek`.
- Actions: separate `ReserveMessage`, `CopyPayload`, `PublishMessage`, `SelectMessage`, and `ConsumeMessage`.
- Granularity: tokens represent bytes/messages; datagram publication is one atomic effect, while streams allow positive partial effects.

**Priority**: High
**Rationale**: Backend divergence is concentrated at fault boundaries and directly affects replay, duplication, and malformed message visibility.

### Scenario 3: A Side Effect Precedes Contractual Metadata or Ownership Publication

**Mechanism**: Data, a message, a connection, or an FD changes ownership before a later user-memory output can fault.

**Evidence**:
- Code analysis: `recvmsg` receives, writes address/control data, then rewrites the full saved `CUserMsgHdr` (`kernel/core/src/syscall/recvmsg.rs:32-58`); `sendmmsg` sends before rewriting the full `CMmsgHdr` (`kernel/core/src/syscall/sendmmsg.rs:67-76`). Linux writes only output fields (`net/socket.c:2664-2720,2760-2813`).
- Code analysis: SCM_RIGHTS inserts each file before writing its descriptor number and converts copy error to `MSG_CTRUNC` (`kernel/core/src/net/socket/unix/ctrl_msg.rs:116-152`, `kernel/core/src/net/socket/util/message_header.rs:104-129`); its cycle guard checks `UnixStreamSocket` but not `UnixDatagramSocket` (`kernel/core/src/net/socket/unix/ctrl_msg.rs:256-274`). Linux publishes the number before `fd_install` and garbage-collects Unix-socket cycles (`fs/file.c:1325-1364`, `net/unix/garbage.c:560-621`).
- Code analysis: `recvfrom` receives before address copy-out (`kernel/core/src/syscall/recvfrom.rs:29-48`); `accept` accepts before address copy-out but installs the FD only afterward (`kernel/core/src/syscall/accept.rs:55-80`). Those orderings require syscall-specific outcomes, not blanket rollback.

**Affected code paths**: `recvmsg`, `sendmmsg`, `recvfrom`, `accept`, socket-address helpers, control-message helpers, and `FileTable::insert`.

**Suggested modeling approach**:
- Variables: `effectToken`, `copyoutMask`, `copyoutFaultField`, `objectOwner`, `fdNumberPublished`, `batchCompleted`.
- Actions: split irreversible `CommitEffect` from per-field `Copyout`; represent ownership as `Queued/InMessage/Reserved/Installed/Dropped`.
- Granularity: preserve the allowed Linux commit point for each syscall and track only contract output fields.

**Priority**: High
**Rationale**: The model must distinguish permitted post-effect errors from stale-field overwrite, hidden effects at non-contractual fault sites, and stranded ownership.

### Scenario 4: Nested Metadata and Mappings Change Between Snapshot Steps

**Mechanism**: A top-level header is captured once, nested iovec/control/address entries are copied later, and another thread can mutate or remap either range between those steps.

**Evidence**:
- Code analysis: `sendmsg`/`recvmsg` first read one `CUserMsgHdr`, then copy nested fields (`kernel/core/src/syscall/sendmsg.rs:22-59`, `kernel/core/src/syscall/recvmsg.rs:19-56`, `kernel/core/src/util/net/socket.rs:100-179`).
- Code analysis: iovecs are read one entry at a time into persistent readers/writers (`kernel/core/src/util/iovec.rs:78-117`); Linux also copies metadata and does not promise a same-generation snapshot (`lib/iov_iter.c:1355-1494`).
- Code analysis: constructing a view checks the address bound, not present mappings (`ostd/src/mm/vm_space.rs:153-195`); page-fault handling and remap/protection use current VMAR state (`kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:8-24`, `kernel/core/src/vm/vmar/vmar_impls/unmap.rs:44-52`, `kernel/core/src/vm/vmar/vmar_impls/protect.rs:17-80`).
- Current review context: [PR #3720](https://github.com/asterinas/asterinas/pull/3720) identifies null-base/nonzero-length iovec validation absent from this baseline (`kernel/core/src/util/iovec.rs:44-56`).

**Affected code paths**: syscall dispatch, `CurrentUserSpace`, typed header copy, iovec import, address/control helpers, page faults, `munmap`, and `mprotect`.

**Suggested modeling approach**:
- Variables: `liveMeta`, `snapMeta`, `mappingState`, `validatedRanges`, `accessedRanges`, `copyoutMask`.
- Actions: allow `MutateMeta` and `RemapRange` between explicit snapshot, validation, transfer, and copy-out steps.
- Granularity: require each captured typed value to be internally complete, but do not require all nested values to share one generation.

**Priority**: Medium
**Rationale**: The important property is range safety and contractual output behavior under re-reading, not an unrealistically atomic userspace snapshot.

### Scenario 5: Signal, Timeout, or Restart Crosses the Commit Boundary

**Mechanism**: an `EINTR` is translated into restart state without a uniform proof that no progress was already committed.

**Evidence**:
- Historical: [issue #1578](https://github.com/asterinas/asterinas/issues/1578) and [PR #1598](https://github.com/asterinas/asterinas/pull/1598) introduced restart infrastructure; they are mechanism history, not targets.
- Code analysis: individual syscall handlers translate `EINTR` to `ERESTARTSYS` (`kernel/core/src/syscall/read.rs:27-44`, `kernel/core/src/syscall/write.rs:27-44`, `kernel/core/src/syscall/sendmsg.rs:58-64`, `kernel/core/src/syscall/recvmsg.rs:32-40`, `kernel/core/src/syscall/accept.rs:55-62`).
- Code analysis: signal handling restores the original return register and rewinds the syscall instruction under `SA_RESTART` (`kernel/core/src/thread/task.rs:71-105`, `kernel/core/src/process/signal/mod.rs:48-62,145-158`). Timeout FIXMEs remain in socket handlers; [PR #3576](https://github.com/asterinas/asterinas/pull/3576) proposes moving restart decisions into wait primitives and is absent from the baseline.

**Affected code paths**: blocking file/socket operations, poll/wait helpers, syscall return handling, signal delivery, and timeout options.

**Suggested modeling approach**:
- Variables: `interrupt`, `timeout`, `restartable`, `restartToken`, `committedProgress`, `attempt`.
- Actions: inject `Interrupt` before/after transfer and effect commit; permit `Restart` only from a zero-commit attempt.
- Granularity: one restart creates a fresh attempt with original arguments but shared effects retained.

**Priority**: Medium
**Rationale**: No concrete duplicate was established manually, but the cross-layer decision is well suited to bounded interleaving exploration.

## 3. Modeling Recommendations

### 3.1 Model

- **One transaction automaton**: all scenarios share `phase`, progress, effect, copy-out, and restart state; specialize behavior with an immutable `opProfile`.
- **Per-syscall contracts**: encode effect granularity, offset policy, partial policy, contractual output fields, post-effect fault policy, and restart eligibility.
- **Faultable copies**: a copy nondeterministically completes zero, some positive amount, or all; preserve whether that progress reaches the caller.
- **Concurrent user actions**: allow metadata mutation and range remap only at implementation preemption boundaries exposed by Scenarios 3-5.
- **Shared kernel effects**: model file position/append ranges, stream or datagram tokens, accepted connections, and received-FD ownership.

### 3.2 Do Not Model

- Do not recreate [issue #711](https://github.com/asterinas/asterinas/issues/711) or any other closed historical bug; use them only to justify mechanisms.
- Do not require bit-for-bit/page-exact counts, universal `Error => no effect`, or one generation for mutable metadata; check captured-value/range safety instead.
- Do not model TLB/RCU/page-table internals, parser-only errno differences, unsupported operations/flags, protocol contents, scheduler fairness, or performance.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| `SyscallProfile` | `opKind`, `effectKind`, `offsetPolicy`, `partialPolicy`, `postFaultPolicy` | Select the Linux contract without separate state machines | 1-5 |
| `FaultableCopy` | `requested`, `copyProgress`, `copyFault` | Abstract split-range faults without exact byte counts | 1, 2, 4 |
| `VectorTransaction` | `iovIndex`, `vectorOwner`, `vectorDone` | Test ordered, single-operation vectored I/O | 1 |
| `FileCommit` | `committedProgress`, `filePos`, `appendRange` | Relate visible progress to shared and positional offsets | 1 |
| `SocketCommit` | `queue`, `queuedRecords`, `queueCost`, `readable`, `messageToken`, `published`, `consumed`, `peek` | Distinguish stream progress, record bounds, and datagram atomicity | 2 |
| `ContractCopyout` | `copyoutMask`, `copyoutFaultField`, `batchCompleted` | Represent only Linux-contractual outputs after effects | 3, 4 |
| `ObjectOwnership` | `objectOwner`, `fdNumberPublished` | Track connections and SCM_RIGHTS through fault paths | 3 |
| `RestartAttempt` | `attempt`, `interrupt`, `timeout`, `restartToken` | Detect replay of an already committed effect | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `TypeOK` | Safety | Every phase, profile, progress class, range, queue token, and owner has a legal value | All |
| `OneCommitPerAttempt` | Safety | An attempt commits each byte/message/object token at most once | 1, 2, 3, 5 |
| `ProgressIsVisible` | Safety | Positive byte-granular commit produces a positive short/success result unless that profile permits a later contractual output error | 1, 2 |
| `OffsetFollowsCommit` | Safety | Shared file position follows this operation's committed short result; positional I/O never changes it | 1 |
| `VectorLinearizable` | Safety | A regular-file vector call is one ordered transfer relative to competing file operations | 1 |
| `AppendRangesDisjoint` | Safety | Successful concurrent append operations reserve non-overlapping ranges and each description records its own end | 1 |
| `DatagramPublicationAtomic` | Safety | A send-side copy fault cannot publish a partial or zero-filled datagram | 2 |
| `DatagramConsumedOnce` | Safety | A non-peek receive cannot replay one selected datagram; a peek never consumes it | 2 |
| `QueuedRecordAccounted` | Safety | Every queued datagram/seqpacket record consumes bounded capacity and is reflected in level-triggered readability, even with zero payload | 2 |
| `CopyoutIsContractual` | Safety | Kernel copy-out touches only output fields defined by the selected syscall profile | 3, 4 |
| `BatchHiddenEffectBound` | Safety | `sendmmsg` has at most one uncounted current send, and only a contractual `msg_len` fault permits it | 3 |
| `FdInstallRequiresNumberPublication` | Safety | A received FD is not installed until its complete descriptor number is published | 3 |
| `OwnershipConserved` | Safety | Every received FD/accepted connection is queued, reserved, installed, or deliberately dropped, never duplicated or stranded | 3 |
| `RestartBeforeCommit` | Safety | A restarted attempt has zero committed progress and no published object/message | 5 |
| `AccessWithinCapturedRange` | Safety | Transfer/copy-out uses bounded captured ranges; iovec/batch counts and address arithmetic cannot overflow or wrap | 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can a faulting vector call interleaved with scalar I/O or another appender produce a result/file-position history that has no single vector linearization point? | `OffsetFollowsCommit`, `VectorLinearizable`, `AppendRangesDisjoint` | 1 |
| MC-2 | Can record selection, payload fault, concurrent peek/receive, and retry select or consume one datagram more than once under a non-peek profile? | `OneCommitPerAttempt`, `DatagramConsumedOnce`, `ProgressIsVisible` | 2 |
| MC-3 | Can concurrent header mutation/remap between effect commit and Asterinas's full-structure writeback create a stale input-field overwrite or a hidden effect at a non-contractual fault field? | `CopyoutIsContractual`, `BatchHiddenEffectBound` | 3, 4 |
| MC-4 | Across multi-FD control delivery and later top-level copy-out, can an object become installed without publication, duplicated, or ownerless? | `FdInstallRequiresNumberPublication`, `OwnershipConserved` | 3 |
| MC-5 | Can an interrupt or timeout after positive progress reach `Restart` and repeat the committed transfer/effect? | `RestartBeforeCommit`, `OneCommitPerAttempt` | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T-1 | Split-mapped buffers preserve a Linux-valid short result and matching shared offset | Run scalar and vectored regular-file/pipe cases with a mapped page followed by `PROT_NONE`; inspect result, data, and `lseek` |
| T-2 | IP UDP copy fault does not deliver a malformed datagram | Fault a source iovec after a readable prefix and assert the peer receives no packet |
| T-3 | Unix datagram non-peek receive is not replayed after copy fault | Compare Asterinas and Linux with a faulting destination, then retry receive |
| T-4 | SCM_RIGHTS never leaves an installed but unpublished FD | Place the descriptor slot across a protection boundary and inspect `/proc/self/fd` after `recvmsg` |
| T-5 | `recvmsg`/`sendmmsg` touch only contractual output fields | Race input-only header fields and protect those bytes after snapshot; check for stale overwrite and extra `EFAULT` |
| T-6 | Iovec and batch bounds match the intended contract | Cover null base with nonzero length, overlapping/aliased vectors, aggregate `MAX_RW_COUNT`, and `sendmmsg` `vlen > 1024` |
| T-7 | Socket timeout plus `SA_RESTART` does not restart a timed operation or duplicate progress | Interrupt blocking send/receive before and after a peer creates progress |
| T-8 | Zero-length Unix datagram/seqpacket records and self-referential SCM remain bounded, readable, and collectible | Fill queues with empty records/SCM_RIGHTS, poll after enqueue, close all external FDs, and observe resource release |
| T-9 | IP socket user copy does not fault while an atomic-mode lock can sleep | Use a valid not-present file-backed page and assert contained `EFAULT`/retry without lock-context failure |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Tuple-error conversions may erase progress outside the audited adapters | Audit every `From<(Error, usize)>`, `?`, and `map_err` call site and document the owning layer |
| CR-2 | Zero-length Unix records are uncharged and the SCM socket-cycle guard omits datagram sockets | Review record overhead/readiness and either implement Unix-socket GC or reject all cycle-forming socket types |
| CR-3 | `sendmmsg` lacks Linux's `UIO_MAXIOV` clamp and rewrites the entire entry | Replace with bounded iteration and field-specific `msg_len` output after contract review (`kernel/core/src/syscall/sendmmsg.rs:57-79`) |
| CR-4 | Iovec total length is capped at `isize::MAX`, not Linux `MAX_RW_COUNT` | Decide and document the compatibility bound (`kernel/core/src/util/iovec.rs:59-76`) |

## 7. Reference Pointers

- Detailed evidence: `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md`.
- Core source: `kernel/core/src/{context.rs,util/iovec.rs,util/ring_buffer.rs}`, `ostd/src/mm/io/mod.rs`, `kernel/core/src/fs/file/inode_handle.rs`, syscall message handlers, and `kernel/core/src/net/socket/{ip,unix,vsock}/`.
- History/review context: [#711](https://github.com/asterinas/asterinas/issues/711), [#1136](https://github.com/asterinas/asterinas/issues/1136), [#1245](https://github.com/asterinas/asterinas/issues/1245), [#1554](https://github.com/asterinas/asterinas/issues/1554), [#1578](https://github.com/asterinas/asterinas/issues/1578), [#3181](https://github.com/asterinas/asterinas/issues/3181), and baseline-absent PRs [#3481](https://github.com/asterinas/asterinas/pull/3481), [#3576](https://github.com/asterinas/asterinas/pull/3576), [#3582](https://github.com/asterinas/asterinas/pull/3582), [#3720](https://github.com/asterinas/asterinas/pull/3720), [#3297](https://github.com/asterinas/asterinas/pull/3297).
- Linux contract sources: [read(2)](https://man7.org/linux/man-pages/man2/read.2.html), [write(2)](https://man7.org/linux/man-pages/man2/write.2.html), [readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html), [sendmmsg(2)](https://man7.org/linux/man-pages/man2/sendmmsg.2.html), [Linux v6.16 `net/socket.c`](https://github.com/torvalds/linux/blob/v6.16/net/socket.c), [`lib/iov_iter.c`](https://github.com/torvalds/linux/blob/v6.16/lib/iov_iter.c), and [`fs/file.c`](https://github.com/torvalds/linux/blob/v6.16/fs/file.c).
