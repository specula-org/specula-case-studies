# Modeling Brief: asterinas-unix-dgram-scm-rights

## 1. System Overview

- Asterinas implements this Rust protocol in seven requested core files totaling 1,555 lines, plus socket, user-copy, and close helpers.
- The selected source is `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. It is a local pin, not a claim about current remote main.
- **Category B (Concurrent / Lock-Free / Runtime)** applies because the problem is shared-kernel ownership transfer and publication across lock boundaries. These paths use locks, not a lock-free algorithm.
- Model one nonempty AF_UNIX SOCK_DGRAM message carrying ordinary file or pipe references from sender capture through queue, receive/PEEK, receiver FD installation, number output, and release.
- Asterinas holds the queue mutex through payload copying and selection, then releases it before ancillary output. Each receiver FD insertion has its own file-table write lock (`net/socket/unix/datagram/message.rs:174-217`; `net/socket/unix/ctrl_msg.rs:135-148`).
- Linux `4645fefac0b24d509b962c096b0327e87f34b1d2` reserves a number, copies it, then installs the file. Its receive `iolock` spans ancillary delivery (`fs/file.c:1355-1379`; `net/unix/af_unix.c:2511-2600`). Preserve both implementations' actual ordering.
- Paths below are relative to Asterinas `kernel/core/src/` unless marked Linux or OSTD. All proposed model checks, traces, and runtime controls are **NOT_RUN**. Analysis is not confirmation.

## 2. Scenarios

### Scenario 1: Captured object ownership survives descriptor reuse and release

**Mechanism**: Descriptor numbers name table slots, while independent owned references keep the captured file object alive through transfers and cleanup.
An object denotes the captured `FileLike`/open file description, not merely an inode; separate opens or pipe ends can share an inode.

**Evidence**:
- Historical: SCM_RIGHTS introduction `4d8078166eaf` / [PR #2176](https://github.com/asterinas/asterinas/pull/2176) established auxiliary file ownership. [PR #2412](https://github.com/asterinas/asterinas/pull/2412) explicitly retained `MessageReceiver` for its lifetime and destructor responsibilities.
- Code analysis: `net/socket/unix/ctrl_msg.rs:103-113,222-240,304-310` captures owned references, moves normal-receive rights, and clones PEEK rights. `net/socket/unix/datagram/message.rs:79-96,262-270` publishes only after send copying and clears queued ownership on receiver destruction.
- Code analysis: insertion clones each temporary reference, so the entire temporary list remains an owner until dropped (`net/socket/unix/ctrl_msg.rs:139-148`; `fs/file/file_table.rs:190-205`). Removing an FD leaves a temporary `ClosedFile` until its later drop (`syscall/close.rs:22-35`).

**Affected code paths**: `FileMessage::read_from`, `AuxiliaryData::from_control`, `MessageQueue::try_send`, `generate_control`, `FileTable::insert`, `sys_close`, `MessageReceiver::drop`.

**Suggested modeling approach**:
- Variables: immutable `capturedObjects`, sender FD mapping, queue rights, send/receive temporary lists, receiver FD mapping, pending close references, and per-object ownership multiplicities.
- Represent an FD slot as `(tableId, integer)` in one `fdTable`. Sender/receiver mappings are role views; when they share a table, count each occupied slot once and allow numbers to be reused.
- Actions: capture, enqueue move, PEEK clone, normal receive move, installation clone, temporary release, FD removal/drop, and final queue disposal. Permit sender close/reuse only after successful send.
- Granularity: preserve every reference-producing or releasing boundary. Count repeated references to the same object separately. A move changes the owner; a clone adds ownership.

**Priority**: High
**Rationale**: SCM-01/02/12/14 exercise the full lifetime contract without needing a new defect. Ownership accounting also explains partial-delivery outcomes in Scenario 3.

### Scenario 2: Queue selection and ancillary completion have different orders

**Mechanism**: Queue selection serializes message identity and consumption, while later FD publication from multiple receive attempts can interleave.

**Evidence**:
- Historical: `485f2189c36a` and `7e14d8d3955f` / [PR #3347](https://github.com/asterinas/asterinas/pull/3347) introduced datagram PEEK and clone-versus-move ancillary generation. The history is reference context, not a target for reverting PEEK support.
- Code analysis: `net/socket/unix/datagram/message.rs:179-217` selects, copies, and either removes or retains the message under one mutex. `net/socket/unix/ctrl_msg.rs:304-310` gives PEEK a distinct temporary rights list.
- Code analysis: `syscall/recvmsg.rs:32-52` finishes protocol receive and releases the table borrow before publishing controls. The file-table lock ends before each number copy (`net/socket/unix/ctrl_msg.rs:141-148`).

**Affected code paths**: `MessageReceiver::try_recv`, `AuxiliaryData::generate_control`, `UnixDatagramSocket::recvmsg`, `sys_recvmsg`, `FileMessage::write_to`.

**Suggested modeling approach**:
- Variables: per-receiver program counter, selected message ID, receive mode, local rights, queue-lock owner, and installation/output history.
- Actions: lock/select/copy/consume-or-clone/unlock, followed by separate publication steps. Model the critical section either explicitly or as a proven equivalent locked transition, never allowing another queue selector inside it.
- Granularity: allow one earlier PEEK and one normal receive to publish in either order after selection. Repeated PEEK creates permitted copies; at most one ordinary receive consumes the original message.

**Priority**: High
**Rationale**: SCM-08/09/10/11 need interleaving exploration and message/object identity, not an assumption that syscall completion order equals dequeue order.

### Scenario 3: Per-FD publication, capacity, and control reporting diverge

**Mechanism**: Installing a file, copying one complete integer, writing the control header, and reporting ancillary length are distinct effects with different fault boundaries.

**Evidence**:
- Prior lead: **AST-32**, still `SOURCE LEAD`, covers insertion before that FD's number-copy failure. This run does not discover or reproduce it anew.
- Historical: `e0b702663563` / [PR #3600](https://github.com/asterinas/asterinas/pull/3600) added `MSG_CTRUNC` reporting but retained the insertion-before-copy sequence. The closed fix remains reference context.
- Code analysis: `net/socket/unix/ctrl_msg.rs:116-151` computes capacity, writes the header, then installs each FD before copying its integer, with no compensating removal on failure.
- Code analysis: `net/socket/util/message_header.rs:104-129` suppresses that error, sets `MSG_CTRUNC`, and counts no bytes for the failed cmsg. `util/net/socket.rs:138-156` separately handles NULL control.
- Reference: Linux `fs/file.c:1364-1376` releases the failing reservation without installation. Linux `net/core/scm.c:348-378` preserves earlier deliveries, writes a prefix header afterward, and drops the temporary list.

**Affected code paths**: `FileMessage::write_to`, `ControlMessage::write_all_to`, `CUserMsgHdr::write_control_messages_to_user`, `sys_recvmsg`, OSTD `VmWriter::write_val`.

**Suggested modeling approach**:
- Variables: advertised capacity, selected count, per-entry allocated FD, installation status, complete-integer result, possible dirty bytes, header result/contents, reported length, `MSG_CTRUNC`, and return result.
- Actions: Asterinas header → install → number copy; Linux reserve → number copy → install, then header. Keep buffer permissions fixed per attempt and output buffers disjoint.
- Granularity: split installation from copying. Complete integer writes are independent of control length and writer cursor; OSTD resets the cursor after a failed copy without undoing bytes (`ostd/src/mm/io/mod.rs:795-808`).
- Reported length can also include alignment padding that was skipped without writing it (`net/socket/util/message_header.rs:124-126`). Do not equate it with dirtied bytes.
- Check failed-entry ownership at operation completion. Do not reject Asterinas's legitimate intermediate installed-before-copy state or Linux's intermediate copied-before-install state as a completed-call violation.
- `Completed` includes implicit local drops, not just deciding the return value. A delivered entry has completed both its number copy and installation.

**Priority**: High
**Rationale**: SCM-02 through SCM-07 and SCM-09 distinguish a stranded failed entry from a valid delivered prefix. Keep expected compatibility failures visible while checking all other ownership properties.

### Scenario 4: Payload faults occur on different sides of consumption

**Mechanism**: Asterinas copies before ordinary dequeue, while Linux unlinks before copying. Error return alone does not specify whether the message remains queued.

**Evidence**:
- Prior lead: **AST-36**, still `SOURCE LEAD`, is retained only as the bounded normal-receive/PEEK payload-fault control.
- Code analysis: `net/socket/unix/datagram/message.rs:194-213` returns on copy failure before dequeue or ancillary generation. `util/iovec.rs:304-320` can report a fault after copying a payload prefix.
- Reference: Linux `net/core/datagram.c:183-202` unlinks ordinary receives and acquires a PEEK reference. `net/unix/af_unix.c:2558-2600` frees the selected receive reference on payload failure before ancillary delivery.

**Affected code paths**: `MessageReceiver::try_recv`, `MultiWrite::write`, Linux `__skb_try_recv_from_queue`, `__unix_dgram_recvmsg`.

**Suggested modeling approach**:
- Variables: payload-copy outcome, queue membership, selected receive reference, consumption count, and retry identity.
- Actions: fixed payload fault before ancillary output, cleanup, and a later valid retry. Use the actual order for each implementation; PEEK retains the queue in both.
- Granularity: one bounded fault/retry pair, with no VM mutation, shutdown race, generic payload campaign, or assumption of whole-receive rollback.

**Priority**: Medium
**Rationale**: SCM-13 calibrates the receive boundary so Scenario 3 cannot mistake permitted consumption for a leak or unintended retry.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
| --- | --- | --- |
| Complete bounded ownership protocol | Scenarios 1–4 remain useful with zero new defect candidates. | Use one source-faithful model with per-operation local state, actual locks, and separate Linux compatibility predicates. |
| Identity and multiplicity | Scenarios 1–2 distinguish slot reuse, duplicate rights, PEEK copies, and ordinary consumption. | Start with one message, two object identities, four rights (including duplicates), two receiver threads sharing a table, up to two PEEK attempts and two ordinary attempts; only one ordinary attempt can consume. |
| Sufficient FD supply | Allocation/resource-limit stress is excluded. | Give the bounded table at least 16 free slots in addition to setup descriptors; do not let the bound introduce synthetic allocation failure. |
| Every output/fault case | Scenario 3 needs zero capacity, prefix truncation, first/later integer faults, and header faults. | Select static per-call layouts and record raw bytes, complete writes, header result, reported length, flags, FD/object maps, and cleanup separately. |
| Send failure and final release | Scenario 1 requires owners on both sides of enqueue and destruction. | Include failing send-copy cleanup, sender close/reuse, closing returned FDs, and quiescent final receiver destruction. |
| Bounded payload control | Scenario 4 distinguishes retry behavior. | One normal and one PEEK fault/retry case, attributed to AST-36. |

Use `socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, ...)`, nonempty single-iovec payloads, send flags 0, receive flags 0 or `MSG_PEEK`, `msg_name = NULL`, writable outer metadata, and no credentials. `MSG_DONTWAIT` and `MSG_CMSG_CLOEXEC` are outside the supported receive mask (`net/socket/util/message_flags.rs:40-59`).

Run protocol properties independently of the known compatibility checks, over the same reachable failure paths. A known failure must neither stop exploration of the remaining properties nor be removed by a guard. Preserve normal model/spec, harness, validation, and findings reviews. The receiving controller owns phase transitions and the shared heavy-stage lock; this brief does not start any later phase.

### 3.2 Do Not Model (with rationale)

| What | Why |
| --- | --- |
| AST-31 whole-msghdr faults, input-field rewrites, general VM changes, overlapping buffers | Outer metadata is valid and stable. These would obscure per-FD publication and require a different contract. |
| STREAM/SEQPACKET/IP sockets, accept, credentials, Unix-socket rights/cycles, empty records | Explicit exclusions. They require different queue, lifetime, or capability semantics. |
| Resource-limit stress, allocator failure, signal/restart, timeouts, shutdown races | Excluded environmental failure modes, not needed for the bounded ownership questions. |
| Unrelated FD close/dup/exec/exit races and CLOEXEC semantics | Only post-send sender reuse and deliberate cleanup belong to this protocol. Competing receivers contribute insertions only. |
| Generic weak-memory/CAS adversaries or reverting historical fixes | The relevant state is lock protected. No evidence supports weakening a lock or resurrecting a fixed historical bug. |
| ABI layout, page-copy instructions, real allocation and pipe implementation | Measure layouts and copy outcomes in later tests; abstract their events in TLA+. Pipe EOF is an external release observation, not a modeled pipe subsystem. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
| --- | --- | --- | --- |
| Explicit owners | `fdTable`, `queueRights`, `sendTemp`, `recvTemp`, `closing`, `refBalance` | Compare an independent clone/drop balance with all actual owners; sender/receiver roles do not duplicate a table slot. | 1 |
| Selected-message local state | `pc`, `selected`, `mode`, `queueLock`, `consumed` | Preserve selection identity through later concurrent publication. | 2 |
| Staged ancillary output | `capacity`, `fdForEntry`, `installed`, `numberComplete`, `dirtyBytes`, `headerResult` | Retain the implementation's installation/copy order and fixed faults. | 3 |
| Independent result reporting | `reportedLen`, `headerLen`, `ctrunc`, `returnValue` | Prevent cmsg/msghdr reporting from defining whether a number was copied. | 3 |
| Payload selection boundary | `payloadResult`, `selectedRef`, `retry` | Separate queued ownership from an unlinked Linux receive reference. | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
| --- | --- | --- | --- |
| `TypeOK` | Safety | FD slots, objects, rights entries, and message identities stay in distinct domains. | All |
| `OwnershipConserved` | Safety | Independent initial/clone/drop accounting equals queue, operation, FD, and pending-close owners for every object. No reference vanishes or acquires an unexplained owner. | 1–4 |
| `CapturedObjectIdentity` | Safety | Every delivered entry names its captured object, even after sender FD reuse; duplicate entries may name the same object. | 1, 3 |
| `OrdinaryConsumeAtMostOnce` | Safety | One message is removed by at most one ordinary receive; queue disposal is a distinct terminal event. | 2, 4 |
| `PeekPreservesQueueRights` | Safety | A PEEK transition retains message identity and queue rights and creates only its own temporary copies. A later normal receive may consume them. | 2 |
| `DeliveredPrefixSurvives` | Safety | Later number/header faults do not revoke already completed deliveries, absent explicit cleanup. | 3 |
| `OperationOwnersDrained` | Safety | A completed operation has no remaining temporary rights; installed entries and still-queued PEEK rights remain explicit owners. | 1, 3, 4 |
| `NoFailedNumberInstalled` | Safety, Linux compatibility | At completed-call boundaries, no newly installed entry has failed its own complete integer copy. Expected AST-32 mismatch, not a new finding. | 3 |
| `ReportedPrefixMatchesLinux` | Safety, Linux compatibility | With a writable header, partial number failure reports the delivered prefix and truncation. Header failure is a separate allowed outcome. | 3, AST-32 |
| `PayloadFaultConsumptionMatchesLinux` | Safety, Linux compatibility | Ordinary payload fault consumes the selected message; PEEK fault retains it. Expected AST-36 mismatch. | 4 |
| `BoundedCleanupProgress` | Liveness | With weak fairness for started operations and requested cleanup, their temporary owners eventually drain. Final object release additionally requires closing every actual FD owner. | 1–4 |

Do not assert that `MSG_CTRUNC`, zero reported length, or any receive error implies zero installed FDs. Do not assert global exactly-once delivery across PEEK. The implementation model must expose violations rather than enforce these compatibility predicates as preconditions.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

No new model-checkable defect candidate is established. Scenarios 1–4 and the protocol properties above define the required bounded verification work. Do not invent hunt findings or decline spec generation because this table is empty.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
| --- | --- | --- |
| AST-32 (existing `SOURCE LEAD`) | Asterinas installs the failing entry before number publication; partial-prefix output also reports zero cmsg length. | SCM-05/06/09 with production installation/copy events, raw bytes, bounded FD/object scans, cleanup, and the same program on identified Linux. Runtime NOT_RUN. |
| AST-36 (existing `SOURCE LEAD`) | Ordinary datagram payload fault retains the record at this pin. | SCM-13 normal/PEEK fault followed by valid retry, with queue identity and cleanup events. Runtime NOT_RUN. |

### 6.3 Code-Review-Only

No additional in-scope code-review-only defect candidate survived the compensating-path checks. Exclusions and rejected hypotheses are recorded in the analysis report; historical and out-of-scope leads are not new findings.

## 7. Reference Pointers

- [Detailed analysis and trace plan](analysis-report.md), including SCM-01–14 outcomes, history coverage, source reads, exclusions, and evidence limits.
- [Prepared contracts](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/contracts.md) and [resource policy](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json). Later heavy work requires the controller's lock and resource checks.
- Core: `syscall/sendmsg.rs:16-65`, `syscall/recvmsg.rs:13-59`, `net/socket/unix/ctrl_msg.rs:69-151,215-313`, `net/socket/unix/datagram/message.rs:26-100,174-217,262-270`, `net/socket/util/message_header.rs:104-129`, `util/net/socket.rs:80-178`, `fs/file/file_table.rs:190-205,274-297,341-362`.
- Reference: pinned Linux [receive_fd](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/fs/file.c#L1355), [SCM detach](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/net/core/scm.c#L330), and [datagram receive](https://github.com/gregkh/linux/blob/4645fefac0b24d509b962c096b0327e87f34b1d2/net/unix/af_unix.c#L2493). Six local reference files matched these remote pinned bytes.
