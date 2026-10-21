# MC-1 Investigation (Phase 1 — evidence only)

Finding: **MC-1 / AST-32** — "Failed SCM_RIGHTS number publication retains an installed FD".
Invariant: `NoFailedNumberInstalled` (install CE) + `ReportedPrefixMatchesLinux` (report CE).
Config: `MC_hunt_AST32_install.cfg`; CEs: `spec/output/validation-20261010T015405Z/MC_hunt_AST32_install.log`
and `MC_hunt_AST32_report.log` (31-state and shorter traces, exit code 12, real TLC violations).

## Step 1: Code audit

### Cited sites (worktree = pin 0c6053709 + harness instrumentation; underlying logic from upstream 4d8078166e)

1. `kernel/core/src/net/socket/unix/ctrl_msg.rs:179-203` — `FileMessage::write_to`, per-FD loop:

   ```rust
   for (index, file) in self.files[..nfiles].iter().enumerate() {
       let fd = {
           let mut table = file_table.unwrap().write();
           let fd = table.insert(file.clone(), FdFlags::empty());   // L184: INSTALL FIRST
           ...
       };
       // L199-201: "Perhaps we should remove the inserted files from the file table if we cannot write
       // the file descriptor back to user space? However, even Linux cannot handle every
       // corner case (https://elixir.bootlin.com/linux/v6.15.2/source/net/core/scm.c#L357)."
       let result = writer.write_val_observed::<i32>(&(fd.into())); // L203: PUBLISH NUMBER SECOND
       ...
       result.map_err(|(err, _)| err)?;                              // failure: Err returned, FD kept
   }
   ```

   The receiver's file table gains an entry at L184 *before* the FD integer is copied to
   the user control buffer at L203. On a copy failure (page fault on the control buffer)
   the `?` returns `Err` and nothing removes the just-inserted entry. Earlier iterations'
   FDs are likewise kept (they were published, which is defensible); the *failed* entry's
   FD is installed but its number never reached user space.

2. `kernel/core/src/net/socket/util/message_header.rs:113-126` — `ControlMessage::write_all_to`:

   ```rust
   Err(_) => {
       // ... "According to the Linux implementation, it seems okay to silently ignore errors here."
       output_flags |= RecvFlags::MSG_CTRUNC;
       break;
   }
   ```

   The error is swallowed; `len` is NOT incremented for the partially-written message, so
   the reported `msg_controllen` is 0 even when a prefix of FD integers was already copied
   into the user's buffer (report CE: installed=[1,2,3], numberComplete=[1,2],
   numberFailed=[3], reportedLen=0, CTRUNC, retval=1).

### Call chain (all reachable from the public syscall)

`recvmsg(2)` (`kernel/core/src/syscall/recvmsg.rs:33-76`) →
`socket.recvmsg(...)` returns the dequeued/peeked datagram with its `ControlMessage`s →
`c_user_msghdr.write_control_messages_to_user(...)` (`kernel/core/src/util/net/socket.rs:143-176`)
→ `ControlMessage::write_all_to` (`message_header.rs:100`) → `FileMessage::write_to`
(`ctrl_msg.rs:139`). The syscall then writes `msg_controllen = control_len`,
`msg_flags |= MSG_CTRUNC`, and returns the payload length (CE `returnValue = 1`).
Datagram recv path (selection/dequeue) is `kernel/core/src/net/socket/unix/datagram/message.rs`
(try_recv; PEEK retains the message, matching the CE which ends with `queue.msg = message1`).

### Linux reference behavior (fetched, v6.15)

- `fs/file.c` `receive_fd()`: `get_unused_fd_flags()` (reserve number) →
  `put_user(new_fd, ufd)` (publish number) → on failure `put_unused_fd(new_fd)` and return
  error (**nothing installed**) → `fd_install(new_fd, get_file(file))` (install LAST).
- `net/core/scm.c` `scm_detach_fds()` (v6.15.2): per-FD `scm_recv_one_fd` → on break at i,
  if `i > 0` the kernel writes the cmsghdr with `cmlen = CMSG_LEN(i * sizeof(int))` and
  advances/decrements `msg_control_user`/`msg_controllen` by `CMSG_SPACE(i * sizeof(int))`
  (capped) — the delivered prefix IS reported; `MSG_CTRUNC` if `i < count`. Line L357 (the
  line the Asterinas comment cites) is the *final header* `put_user(SOL_SOCKET, &cm->cmsg_level)`
  whose error is indeed ignored — a DIFFERENT corner case (delivered FDs with a failed header
  write). It does not cover the per-FD install-before-publish case, which Linux orders
  reserve→copy→install precisely to avoid.

So: on Linux the failed entry's file is never installed and the successful prefix is
reported; on Asterinas the failed entry stays installed (FD leak) and the prefix is
reported as length 0.

### Counterexample mapping (install CE, 31 states)

- s1-s9: sender sends datagram `message1` with rights `[fileA, fileB, fileA, fileB]` (4 FDs).
- s12: receiver r1/1 starts `recvmsg` with MSG_PEEK, layout `FirstFault`
  (header 16 bytes writable, capacity 32, `failEntry=1`).
- pc: Lock→Select→Copy(payload OK)→GeneratePeek(clone rights)→Unlock→ReleaseBorrow→
  Control→Capacity→Header (cmsg header written OK)→
  **Install (s21→s22: entry 1 installed, fd 7 = fileA)** →
  **Number (s22→s23: FD-integer copy FAILS, numberFailed=[1])** →
  Report (reportedLen=0, CTRUNC) → Writeback → Drop (temporaries dropped) → Done.
- Final state: `fdTable[<<shared,7>>] = fileA`, `fdOrigin[<<shared,7>>] = [kind |-> "Received",
  entry |-> <<r1,1>, 1>]`, message still queued (`queue.msg = message1`, PEEK),
  `returnValue = 1`, `reportedCtrunc = TRUE`.

The FD at slot 7 exists in the receiver's file table but was never published — exactly
`NoFailedNumberInstalled`.

### Reachability / safeguards

- Trigger is a normal user fault: a control buffer whose cmsghdr bytes are writable but
  whose FD-integer region hits a PROT_NONE page. No failpoints, no source patch. The
  model's fault layouts were validated against the instrumented guest (harness Phase 2.5,
  `VmWriterWriteFd ok=0` events observed in production traces).
- No caller-side guard removes the entry afterwards: the error is swallowed at
  `message_header.rs:115`, the syscall succeeds (payload returned), and the temporary
  references are dropped while the installed entry persists. The only "remedies" are
  process exit or the user happening to guess/close the fd number (it is never reported).
- `SlotVec::put` (`kernel/libs/aster-util/src/slot_vec.rs:66`) allocates the LOWEST free
  slot, so the leaked fd number is predictable (`probe open → close → faulting recvmsg`).

### Trigger scenario (concrete, real-API)

`socketpair(AF_UNIX, SOCK_DGRAM|SOCK_NONBLOCK)`; sender `sendmsg` with one SCM_RIGHTS
cmsg of N fds + 1-byte payload; receiver maps a 2-page region with page 2 PROT_NONE and
places the 32-byte control buffer so the cmsghdr (16 B) fits in page 1 and an FD integer
lands in page 2; `recvmsg` (flags 0 or MSG_PEEK) returns the payload length with
`msg_controllen=0`, `MSG_CTRUNC` set, and — the bug — the lowest-free fd in the process
table is now open, aliasing the message's first file object, with no number ever published.

## Step 2: Developer knowledge

- `git log -L 184,190` and `git blame`: install-then-copy order and the comment at
  ctrl_msg.rs:199-201 originate in upstream commit **4d8078166e** "Send and receive UNIX
  control messages" (Ruihan Li, 2025-06-13), merged via PR asterinas/asterinas#2176
  ("Enable UNIX sockets to send and receive file descriptors (SCM_RIGHTS)", merged
  2025-07-21/Aug-2025).
- PR #2176 review discussion (16 threads, fetched): NO reviewer mentions the
  install-before-copy-failure leak. The only "leak" discussed is circular references from
  passing UNIX sockets over UNIX sockets (a different mechanism; AST-34, out of scope).
  No linked issue; "Linked references: none".
- In-code comment (verbatim, ctrl_msg.rs:199-201): "Perhaps we should remove the inserted
  files from the file table if we cannot write the file descriptor back to user space?
  However, even Linux cannot handle every corner case (scm.c#L357)." — developer
  *awareness/suspicion* with a justification that (per the fetched Linux source) covers a
  different corner case (final-header put_user) than the per-FD ordering this finding flags.
- `kernel/core/src/net/socket/util/message_header.rs:115` swallow branch comment:
  "at this point, there is no good way to report the errors to user space. According to
  the Linux implementation, it seems okay to silently ignore errors here."
- Tests: no test in the tree exercises a faulting control buffer during SCM_RIGHTS
  receive (harness fixture scm_rights_trace.c cases are the Specula instrumentation, not
  upstream assertions). Upstream `test/` tree: nothing about recvmsg control faults.

## Step 3: Known status / precedent

- Upstream git history at this pin and later (log --all over ctrl_msg.rs): no commit
  changes the install/copy order or adds removal-on-failure (later commits are refactors,
  SCM_CREDENTIALS, MSG_CTRUNC reporting).
- GitHub tracker searches (issues + PRs, open and closed; queries "SCM_RIGHTS",
  "recvmsg fd", "file descriptor leak"; plus review of PR #2176 discussion): NO filed
  issue/PR/CVE reports this exact mechanism at this site. Upstream main (nightly source
  docs) still shows insert-then-write with the same TODO — unfixed upstream.
- Prior Specula dataset: **AST-32 is a retained SOURCE LEAD** from the earlier
  asterinas-bug-findings-2026-08 Recon analysis (MC-4/T-4/CR-5) per
  specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/contracts.md ("existing
  AST-32 ... prior leads, not new discoveries. Upstream status was not refreshed.").
  It was an unconfirmed code-level prediction, never a confirmed/reproduced bug.

Novelty determination: KNOWN as a prior Specula dataset lead (AST-32 /
asterinas-bug-findings-2026-08; fix-status: unfixed — no upstream report or fix), NEW as
a *confirmed* defect (no public tracker report exists; this is the first reproduction).

Pre-filter: source is MC **with an actual counterexample** → NOT dropped; proceed to Phase 2.

## Phase 2 addendum (turn re-run): fresh reproduction execution

The original turn's compiled test binary survived (`build/root/init`) but its
source (`repro/test_bugMC-1_failed_number_install.c`) was lost when the adapter
crashed during final artifact validation, breaking the evidence chain. This
turn reconstructed the source faithfully (semantics recovered from the binary's
disassembly: fault-layout math `page1_end-16` / `page1_end-24`, 0xCC sentinel
stamping, fcntl(F_GETFD) leak detection over `[pred, pred+8)`, pread-based
leak-content read, per-case fd cleanup) and re-executed BOTH runs from scratch:

1. **Linux control** (host, Linux 7.2.8): `gcc -O2 -g -Wall -Wextra` → run.
   Output byte-identical to the prior control: no leak in either fault case,
   prefix reported as 24 (`CMSG_SPACE(2*4)`), `invariant_matches_linux:1`.
   Saved to `confirmation/MC-1/linux-control.log`.

2. **Asterinas guest** (pin 0c6053709 + harness instrumentation, ISO rebuilt
   via `osdk build --scheme scm-trace --release` with the test as static init,
   QEMU/KVM 2 vCPU 2G): output byte-identical to the prior guest run —
   `MC1_PEEK_FIRST_FAULT ... "leaked":1 ... "leak_content":"AAAA"`,
   `MC1_ORD_FIRST_FAULT ... "leaked":1`, `MC1_ORD_PREFIX_FAULT ...
   "new_fds":3,"wrote_fd0":7,"wrote_fd1":8` with `reported_len:0`, and
   `MC1_RESULT {... "invariant_matches_linux":0}`. Saved to
   `confirmation/MC-1/guest.log`.

Escalation level reached: **Level 0** (pure black-box; public syscalls only:
socketpair/sendmsg/mmap/mprotect/recvmsg/fcntl/pread; the fault is a
deterministic page-granular user-address-space layout, set up before the call
— no failpoints, no source patch, no timing assistance).

issue.json dependency boundaries were fixed to unique literal lines
(`impl FileMessage {` … `            result.map_err(|(err, _)| err)?;` for
ctrl_msg.rs; the old `fn write_to…` start line is ambiguous — it appears twice
as a whole line) and `specula findings validate` now passes:
`{"id": "MC-1", "status": "REPRODUCED", "valid": true}`.
