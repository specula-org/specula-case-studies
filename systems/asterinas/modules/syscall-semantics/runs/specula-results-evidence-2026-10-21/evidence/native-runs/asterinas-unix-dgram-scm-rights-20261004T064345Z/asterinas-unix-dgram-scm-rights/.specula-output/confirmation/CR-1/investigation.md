# CR-1 Investigation (Phase 1 — evidence only)

Finding: "Scenario 1: Captured object ownership survives descriptor reuse and release"
Source: code-review (MC hunt across five `MC_hunt_scenario1*` configs returned **no violation**;
counterexample: null). Severity: High.

## Step 1: Code audit

All line numbers below cite the pinned pre-instrumentation tree
(commit `0c60537098f4c2949ad2d382aaf499de72263d76`), which is what the finding's
`affected_code` ranges resolve to. The confirmation worktree additionally carries the
Category-B trace instrumentation from the harness-validation phase
(`kernel/core/src/scm_trace.rs`); a full diff review confirmed it is trace-only
(per-thread record buffer, `tr::emit` no-ops when the buffer is uninitialized) and does
not alter the ownership logic audited here. `git diff` of the worktree is byte-identical
to the pipeline's `source` checkout, whose kernel build (attempt `20261010T014248Z`)
is the reuse candidate for Phase 2.

### Call chain (public API → cited sites)

Send: `sys_sendmsg` (`syscall/sendmsg.rs`) → `read_control_messages_from_user`
(`util/net/socket.rs:125-136`) → `ControlMessage::read_all_from`
(`net/socket/util/message_header.rs`) → `UnixControlMessage::read_from` →
`FileMessage::read_from` (`ctrl_msg.rs:103-113`) → `UnixDatagramSocket::sendmsg`
(`datagram/socket.rs:288`) → `AuxiliaryData::from_control` (`ctrl_msg.rs:222-240`) →
`do_send` (`datagram/socket.rs:92-120`, aux_data **by value**) →
`MessageQueue::try_send` (`datagram/message.rs:79-96`).

Receive: `sys_recvmsg` (`syscall/recvmsg.rs`) → `UnixDatagramSocket::recvmsg`
(`datagram/socket.rs:299-317`) → `MessageReceiver::try_recv`
(`datagram/message.rs:174-218`) → `AuxiliaryData::generate_control`
(`ctrl_msg.rs:304-310`) → back in `sys_recvmsg`: `write_control_messages_to_user`
(`util/net/socket.rs:138-157`) → `ControlMessage::write_all_to` →
`FileMessage::write_to` (`ctrl_msg.rs:139-148`).

Close: `sys_close` (`syscall/close.rs:22-35`) → `FileTable::close_file`
(`fs/file/file_table.rs:196-206`).

Queue disposal: `Drop for MessageReceiver` (`datagram/message.rs:262-270`).

### Ownership ledger (what the audit found)

| Transition | Site | Effect on the file object's refcount | Owner after |
|---|---|---|---|
| Capture (per fd int) | `ctrl_msg.rs:109` `get_file_fast!(..).into_owned()` | +1 | `FileMessage.files` |
| Merge into aux | `ctrl_msg.rs:240` `files.append(&mut msg_files)` | 0 (Rust move) | `AuxiliaryData.files` |
| Send-side failure release | `datagram/socket.rs:92-120` early `?`s; `message.rs:81` payload-fault `?` (both occur **before** the take) | −1 on drop | released |
| Enqueue move | `message.rs:83` `mem::take(aux_data)` | 0 (move) | queued `Message.aux` |
| PEEK delivery | `ctrl_msg.rs:307` `files.clone()` | +1 each | delivered `FileMessage` (queue keeps originals) |
| Ordinary delivery | `ctrl_msg.rs:306` `mem::take(files)` on the popped message | 0 (move) | delivered `FileMessage` |
| Installation (per fd) | `ctrl_msg.rs:144` `table.insert(file.clone(), ..)` | +1 | receiver `FileTable` entry |
| Post-write release | `FileMessage` dropped after `write_all_to` (RAII) | −1 each not installed | released |
| Receiver close | `close.rs:22-35` + `file_table.rs:196-206` (`ClosedFile` moved out, dropped after unlock) | −1 | released |
| Queue disposal | `message.rs:268` `*inner.lock() = None` drops all queued `Message.aux` | −1 each | released |

Key audit facts:

1. `get_file_fast!` (`file_table.rs:341-363`) returns `Cow<Arc<dyn FileLike>>`:
   unshared table → `Cow::Borrowed`, and `.into_owned()` **clones the Arc**; shared
   table → `Cow::Owned(..clone())`. Capture always takes a new owned reference; the
   sender's file-table entry keeps its own. The fd **number** is never stored.
2. Every hand-off between capture and delivery is either a Rust move (`append`,
   `mem::take` ×2) or an explicit clone with a named owner (`files.clone()` for PEEK,
   `file.clone()` for installation). No site takes an Arc out of a structure without
   leaving an owner or moving it.
3. Failure paths release exactly the temporary references they captured:
   `from_control` errors drop the partially built `files` vec; `do_send` takes
   `aux_data` by value so every early error return drops it; `try_send`'s payload-fault
   `?` fires before `mem::take`, so the queue never sees a half-captured message.
4. `sys_close` removes the entry under the table write lock and drops the `Arc` after
   releasing it (`ClosedFile`), so a queued reference is untouched by sender close —
   the queued `Arc` is an independent owner.
5. Queue disposal (`Drop for MessageReceiver`) replaces the `Inner` with `None`,
   dropping every queued `Message` and its `aux` — the queued references are released
   exactly once, when the last owner (the queue) goes away.
6. The receiver-side `write_socket_addr_to_user` fault path (`syscall/recvmsg.rs`,
   between the dequeue and the control write-out) drops the already-moved references
   via RAII — released, not leaked, not double-dropped.

### Reachability / trigger scenario

All of the above is reachable through the plain public sequence: `socketpair(AF_UNIX,
SOCK_DGRAM)` → `open` a file → `sendmsg` with an SCM_RIGHTS cmsg → `close` the sender
fd (and optionally `open` another file so the number is reused) → `recvmsg` (optionally
MSG_PEEK first) → `fstat`/`read` the delivered fd → `close` it; plus the disposal
variant: send, then close the receiving socket without receiving, then observe the
object's lifecycle (pipe write-end EOF is the user-visible probe for a leaked owner).

### Safeguards / notes encountered (recorded, not dismissed)

- `ctrl_msg.rs:100-102`: TODO for the Linux ETOOMANYREFS in-flight-fd limit — a
  resource-limit gap, not an ownership-accounting defect.
- `ctrl_msg.rs:145-147`: comment that installed-but-unreportable fds are left in the
  table on integer-copy failure, citing Linux's own corner-case behavior
  (net/core/scm.c). The entry remains attributable to an open (if unreported) FD.
- `ctrl_msg.rs` FIXME (UNIX sockets over UNIX sockets → reference cycles): a known
  limitation about *socket objects in cycles*, out of this run's scope (ordinary files
  only) and a different mechanism from the one hypothesized here.

## Step 2: Developer-knowledge search

- `git log` on `ctrl_msg.rs` / `datagram/message.rs`: the SCM_RIGHTS pipeline arrived
  in `4d8078166` ("Send and receive UNIX control messages") and `c3572e954`
  ("Support SCM_CREDENTIALS"), with `e0b702663` ("Report MSG_CtrUNC for truncated
  control messages") and later refactors. **No commit message describes an
  ownership/lifetime fix** in this path.
- Upstream tracker (searched issues *and* merged/closed PRs, 2026-10-10):
  - Issue #2112 (syscall-gap tracking issue, closed by the feature work) and #1888
    (Golang tracking issue) mention SCM_RIGHTS as *missing features*, not defects.
  - PR #2176 (merged 2025-07-21) is the original SCM_RIGHTS implementation. Its review
    discussion notes the UNIX-socket cycle-leak risk (mitigated by the CAP_SYS_ADMIN
    check — visible at the audited `lsm_hooks::on_capable` call) and control-message
    accumulation limits. Neither is the ordinary-file ownership-accounting mechanism
    of this finding.
  - PR #2268 (SCM_CREDENTIALS/SOCK_SEQPACKET), #3347 (MSG_PEEK for all sockets),
    #3600 (MSG_TRUNC): feature work, no ownership fix.
  - No open or closed issue/PR reports a reference vanishing or gaining an unexplained
    owner across capture → enqueue → PEEK/recv → install → close/disposal for
    ordinary files.
- Existing tests: `test/` tree has unix-socket regression tests (e.g.
  `scm_rights_test.rs`-adjacent cases); none asserts a broken-ownership behavior.

## Step 3: Known-status / precedent

No existing issue, PR, CVE, advisory, or prior dataset entry reports THIS mechanism
(ordinary-file reference ownership conservation across the SCM_RIGHTS datagram
pipeline) at THIS site. The only adjacent public discussion (PR #2176's cycle-leak
note) is a different mechanism (socket-object cycles, no GC) and is excluded from this
run's scope. → **Novelty: NEW** (search performed over upstream issues and
merged/closed PRs on 2026-10-10).

Pre-filter: code-review × known does not apply (nothing already reported). Proceed to
Phase 2.

## Phase 2 plan (recorded for the reproduction step)

Level 0 black-box test on the real kernel, public APIs only, exercising every
transition in the ledger: sender-close survival, fd-number reuse, PEEK clone then
ordinary receive, duplicate fds in one message, pipe write-end EOF as a leak probe
through (a) queue disposal and (b) full receive cycle, EAGAIN temporary release,
cross-process capture/install with separate file tables, and post-disposal liveness.
A Linux run of the identical binary serves as the behavioral control. Expected
(correct) outcome per case is fixed by the Linux control run; any Asterinas deviation
(panic, hang, wrong inode, missing EOF, EAGAIN-instead-of-EOF) is the live harm.

## Phase 2 result (2026-10-10)

Test: `../repro/test_bugCR-1_ownership_conservation.c`, executed via
`repro-build/run-repro.sh` (builds the static binary inside the kernel-dev
container, runs the Linux control, repacks the ISO from the pinned `scm-trace`
scheme with the test as initramfs `/init`, boots QEMU/KVM with the harness's
exact guest shape, restores the harness-content ISO afterwards).

- Linux control (host kernel, same binary): 11/11 PASS, `CR1_DONE 0`.
- Asterinas guest (pinned commit `0c6053709` + trace-only instrumentation):
  11/11 PASS, `CR1_DONE 0`; guest container exit 33 (isa-debug-exit poweroff,
  same as harness runs); all evidence in `repro-build/evidence/`.
- Case 11 is the Level-1 (timing) probe: 40 rounds of a sender thread racing a
  closing thread on the same fd; 32,768 successful racing deliveries, every
  delivered fd naming the captured object, no crash (Linux control: 278
  deliveries, same result — the difference is only scheduling throughput).
- Case 9 count matches the kernel constant exactly: 65 × 1000-byte payloads
  fill the 64 KiB `UNIX_DATAGRAM_DEFAULT_BUF_SIZE`, the 66th send returns
  EAGAIN (temporary capture released), drain of 65 delivers 65 fds, final pipe
  EOF observed.

Escalation ladder outcome:
- Level 0 — exhausted: all eleven trigger sequences (covering every transition
  of the hypothesized defect class) ran through real public APIs; no wrong
  object, no dead object, no missing EOF, no panic.
- Level 1 — exercised via case 11 (real concurrency, no logic change). No
  further timing dimension exists for an ownership-accounting claim: every
  reference mutation is serialized by the queue lock, the file-table lock, or
  `Arc`'s atomic refcount; widening windows cannot flip an ownership outcome.
- Level 2 — not applicable: all hypothesized pre-conditions (queued refs at
  sender close, number reuse, EAGAIN capture, disposal with queued refs) are
  naturally reachable and were reached through real API sequences; there is no
  additional hidden state to inject, and injecting a broken refcount would
  fabricate the symptom (prohibited).
- Level 3 — not applicable: a source patch that mismanages a reference would
  create the defect rather than reveal it (prohibited); the property is not a
  delay-sensitive race.

Conclusion input to the verdict: the hypothesized ownership-accounting break has
no candidate site in the audit, no MC violation, an independent harness trace
audit confirming conservation ("Both ordinary objects finish with no modeled
owner after cleanup"), and eleven live black-box probes all passing on the real
kernel. The ownership-conservation contract holds across capture, enqueue move,
PEEK clone, ordinary-receive move, installation clone, temporary release, FD
removal/drop, and final queue disposal.
