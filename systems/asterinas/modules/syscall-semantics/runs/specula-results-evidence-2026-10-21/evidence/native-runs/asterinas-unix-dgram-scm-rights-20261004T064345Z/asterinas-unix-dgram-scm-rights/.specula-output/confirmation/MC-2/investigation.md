# MC-2 Investigation (Phase 1 — evidence only)

Finding: AST-36 — ordinary payload faults retain the datagram
(`MessageReceiver::try_recv` returns from a failed payload copy before the
ordinary dequeue; Linux unlinks the ordinary receive before copying and frees
it on fault). Invariant: `PayloadFaultConsumptionMatchesLinux`. Source: MC with
counterexample (`spec/output/validation-20261010T015405Z/MC_hunt_AST36.log`).

## Step 1: Code audit

### Counterexample (what MC found)

Trace: `MCSendBegin` sends `message1` carrying SCM_RIGHTS refs
`<<fileA, fileB, fileA, fileB>>` → `MCRecvBegin(r1, "Recv", "Full", FALSE)`
starts an ordinary (non-PEEK) receive with a faulting payload buffer
(`payloadGood = FALSE`) → payload copy faults (`payloadResult = "Fault"`,
`returnValue = "EFAULT"`, `faultRetained = TRUE`) → final state still has
`queue.msg = "message1"`, `queue.rights = <<fileA, fileB, fileA, fileB>>`,
`consumed = 0`. Invariant `PayloadFaultConsumptionMatchesLinux` violated: the
Asterinas model retains the datagram after an ordinary receive whose payload
copy faulted; Linux consumes it.

### Cited site (worktree, instrumentation applied on top of pin 0c6053709)

- Worktree `kernel/core/src/net/socket/unix/datagram/message.rs:291-299` —
  `try_recv`: `let len = match result { Ok(len) => len, Err(err) => { ...
  return Err(err.into()); } }`. The early return happens while the message is
  still the queue front; `pop_front()` (dequeue) only runs later at line 309
  inside `if behavior.will_consume_data()`, i.e. only after a successful
  payload copy.
- Upstream (uninstrumented pin): `message.rs:195`
  `let len = writer.write(&mut VmReader::from(msg.bytes.as_slice))?;` — the
  `?` propagates the fault before the dequeue at line 202. The worktree
  instrumentation is trace-only (`tr::emit` calls); the control flow is
  semantically identical (verified via `git diff` of the file: only stamping,
  snapshots, and lock-drop emission were added; the error branch and the
  dequeue ordering are unchanged).
- Worktree diff vs upstream HEAD: `git diff` shows only `scm_trace` import,
  counters, `tr::emit(...)` instrumentation; confirmed no logic change at the
  fault/dequeue boundary.

### Call chain from the public API (all reachable in normal usage)

1. `recvmsg(2)` → `sys_recvmsg` (`kernel/core/src/syscall/recvmsg.rs:15`).
   Reads the user msghdr (`read_val`) — msghdr must be readable.
2. `CUserMsgHdr::copy_writer_array_from_user` (`util/net/socket.rs:189`) →
   `VmWriterArray::from_user_io_vecs` (`util/iovec.rs:171`) →
   `copy_iovs_and_convert` (`util/iovec.rs:79`): reads the iovec array
   (metadata must be readable) and creates one `VmWriter` per iovec.
   `IoVec::writer` → `vm_space.writer(base, len)`
   (`ostd/src/mm/vm_space.rs:171-190`): validates only that the range is user
   space in the current page table — NOT per-page writability. So a payload
   page mapped `PROT_READ` passes writer construction.
3. `UnixDatagramSocket::recvmsg` (`net/socket/unix/datagram/socket.rs:299`)
   → `block_on(IN, ...)` → `MessageReceiver::try_recv`
   (`net/socket/unix/datagram/message.rs:240`).
4. `try_recv`: locks queue, selects front message, copies payload with
   `writer.write(...)`. `MultiWrite::write` is documented to return
   `OstdError::PageFault` with a partial byte count when a page fault occurs
   (`util/iovec.rs:222-232`, `read_fallible`/`write_fallible` in ostd). The
   error maps to `Errno::EFAULT` (`kernel/core/src/error.rs:202`
   `ostd::Error::PageFault => Error::new(Errno::EFAULT)`). On error the
   function unlocks and returns before dequeue → the datagram and its
   `AuxiliaryData` (SCM_RIGHTS `Vec<Arc<dyn FileLike>>`) stay queued.

### Linux oracle (pinned v6.16.5 export)

`__unix_dgram_recvmsg` (`net/unix/af_unix.c:2493-2602` in the pinned copy):
- `skb = __skb_try_recv_datagram(...)`. In
  `__skb_try_recv_from_queue` (`net/core/datagram.c:168-203`): non-PEEK →
  `__skb_unlink(skb, queue)` (unlinks BEFORE the payload copy); PEEK →
  `refcount_inc(&skb->users)` (reference only, message stays queued).
- `err = skb_copy_datagram_msg(...); if (err) goto out_free;` →
  `out_free: skb_free_datagram(sk, skb);` — on an ordinary receive whose
  payload copy faults, the already-unlinked skb is freed, dropping the
  SCM_RIGHTS file references without delivering them. On PEEK fault, only the
  peek reference is dropped; the message remains queued.

So: Linux = ordinary-fault consumes the datagram; Asterinas = retains it.
PEEK retains in both. This is exactly the invariant divergence.

### Reachability / trigger scenario (real API, Level 0)

1. `socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK)`.
2. Open two ordinary files (marker objects A and B); sendmsg one nonempty
   datagram with `SCM_RIGHTS {A, B, A, B}` (4 entries, 2 objects).
3. `recvmsg` attempt 1: `iov` points at a page mapped `PROT_READ` (write
   faults), control buffer valid and writable, flags 0 (ordinary receive) →
   the payload copy inside `try_recv` faults → `EFAULT` is returned and the
   datagram is retained in Asterinas (consumed in Linux).
4. `recvmsg` attempt 2 with a valid payload buffer: Asterinas returns the
   same datagram and delivers the 4 FDs; Linux returns `EAGAIN`.
5. PEEK control: faulting `MSG_PEEK` attempt then ordinary retry — both
   implementations retain, then deliver.

Safeguards encountered: none on this path — no caller-side guard removes or
consumes the message after the fault; the queue mutex is simply dropped. The
only "safeguards" are that the queue still owns the rights (no leak; refs are
released on later successful receive or socket close) and that `block_on`
retries `try_recv` (a fault is a terminal `Err`, not a retry).

### Prior harness observation (same worktree source, Oct 10 guest run)

The pipeline's harness-validation run (`.specula-output/harness/evidence/
20261010T014248Z`, guest build_exit=0, `SCM_DONE 0`) already exercised this
exact scenario (test case 20 = faulting ordinary receive + retry; case 21 =
faulting PEEK + retry) on the real Asterinas kernel:

- Guest (Asterinas) case 20: attempt 1 → return -1 errno 14 (EFAULT);
  attempt 2 (good buffer) → return 1 with SCM_RIGHTS fds [5,6,7,8] delivered
  — datagram RETAINED.
- Host Linux control case 20: attempt 1 → EFAULT; attempt 2 → return -1
  errno 11 (EAGAIN) — datagram CONSUMED.
- Case 21 (PEEK fault then ordinary retry): both Asterinas and Linux deliver
  the fds on attempt 2 — PEEK retains in both.

This is supporting evidence only; my own reproduction (Phase 2) still runs and
executes a self-contained test.

## Step 2: Developer knowledge

- `git log --follow` on the file: the copy-before-dequeue ordering dates to
  the original `fe1d4fe15 "Support UNIX datagram sockets"` (copy then
  unconditional `pop_front`). `485f2189c "Implement MSG_PEEK for UNIX
  datagram sockets"` introduced `will_consume_data()` but kept the copy first.
  `e645c038d "Support MSG_TRUNC..."` removed a warn only. No commit message
  states any intent about fault-consumption semantics.
- No comment near the site mentions EFAULT/fault behavior or Linux
  compatibility of the fault path.
- Upstream tests: `udp_err.c:390` tests `recvmsg` EFAULT with a partially bad
  buffer on UDP but does not assert queue state afterwards (4 datagrams sent;
  the following receives succeed under both consume-on-fault and
  retain-on-fault hypotheses — the test cannot distinguish). No unix-dgram
  EFAULT-retry test exists. `tcp_err.c:509` carries a FIXME about Linux TCP
  EFAULT reporting, unrelated to unix datagram consumption.
- `test/initramfs/src/regression/network/scm_rights_trace.c` (untracked,
  pipeline-added) covers this scenario but asserts only that the case runs
  (`_ret == 0`); it prints observations rather than asserting consumption
  parity.

## Step 3: Known status / novelty

- The run's contracts file records: "Recon analysis MC-2/T-3 is AST-36"
  (catalog `asterinas-bug-findings-2026-08`), i.e. a prior Specula dataset
  entry reported this same mechanism at this same site — the finding JSON
  itself states "the existing AST-36 boundary control, not a new defect
  identity". → Novelty: KNOWN (dataset entry; fix-status: unfixed at pin
  0c6053709 — the early-return-before-dequeue is still present, and the Oct 10
  guest run shows the retained behavior).
- Upstream tracker search (GitHub issues+PRs, several query shapes: recvmsg
  EFAULT, datagram EFAULT, SCM_RIGHTS fault, try_recv, "not consumed", unix
  datagram receive in title): no issue or PR reports this mechanism. The
  nearest results (702, 1294, 3146, 3920) are unrelated. So no upstream
  report; KNOWN rests on the prior Specula dataset entry alone.

This is an MC-sourced finding with an actual counterexample → proceeds to
Phase 2 (no pre-filter drop possible for MC source).

## Phase 2 addendum: reproduction (decides the verdict)

Test: `repro/test_bugMC-2_payload_fault_retain.c` (self-contained C; runs as
the guest init on Asterinas and as an ordinary host process for the
same-program Linux control). Runner: `confirmation/MC-2/run-repro.sh`, which
reuses the proven harness recipe (warm cargo target copied from the
byte-identical harness tree, Docker `asterinas/kernel-dev:0.18.1-20260926`
container, `osdk build --scheme scm-trace`, QEMU/KVM boot, isa-debug-exit).

Escalation level reached: **Level 0** (pure black-box: socketpair, open,
write, sendmsg with SCM_RIGHTS, mprotect, recvmsg — public syscalls only; no
failpoints, no state injection, no source modification, no timing
assistance). Levels 1–3 were never needed.

Result (2026-10-10, worktree pin 0c6053709 + trace-only instrumentation,
ISO sha256 1d6cbe47..., build_status=0, guest_status=33, linux_control=0):

- Asterinas guest: ordinary recvmsg payload fault → -1/EFAULT, control buffer
  untouched, 0 FDs installed; retry → ret 1 with the SAME datagram, 4
  SCM_RIGHTS FDs delivered, markers A,B,A,B verified, queue empty afterwards
  (`ordinary_fault_retained=1`, `invariant_matches_linux=0`).
- Host Linux control: same fault → EFAULT; retry → -1/EAGAIN (datagram
  consumed); PEEK fault → retry delivers (retained, correct)
  (`invariant_matches_linux=1`).
- PEEK control on Asterinas: retained (correct in both).
- No FD leaks on the guest (final FD scan clean).

The MC counterexample maps 1:1: send message1 with rights <<fileA,fileB,
fileA,fileB>> → ordinary recv with payloadGood=FALSE → EFAULT with
faultRetained=TRUE → retry delivers the same message and rights. Same
invariant, same code path (payload-copy error return before dequeue in
try_recv). Right bug triggered.

Verdict: REPRODUCED (Level 0). The `specula findings` CLI is not on PATH in
this environment, so the issue.json proposal written to
`confirmation/MC-2/issue.json` could not be validated with the tool; the
dispatcher/pipeline registers it.

## Resume addendum (2026-10-10, second incarnation of turn 1)

The first incarnation completed Phases 1-2 and emitted REPRODUCED, but the
pipeline's artifact validation rejected the issue.json proposal
("issues linked to model actions/invariants require model dependencies"),
and the repro test source was no longer present in repro/ when the turn
resumed. This incarnation verified and repaired the evidence chain:

1. Test source recovery: recovered the exact original
   `repro/test_bugMC-2_payload_fault_retain.c` (11409 bytes) from the first
   incarnation's session transcript (its `write` tool call) and restored it.
   Provenance proof: recompiling the restored source in the same container
   image with the same flags produced a binary byte-identical to the one the
   first incarnation had compiled (sha256
   `02ae18247dbbe294c9aec111c0b1e7fd4a1fee1c3ad8c533e7994d6bc288fd1b` for
   both `build/linux-control` and the preserved `build/linux-control.prev`).
2. Fresh execution (this session): `run-repro.sh` re-pointed at this turn's
   `worktree-1` (git worktree, pin 0c6053709 + the same scm-trace
   instrumentation; verified content-identical to $T/source with `diff -rq`;
   warm cargo cache synced by mtime). Results: build_status=0,
   guest_status=33, linux_control_status=0, run exit 0; kernel release
   build 36.74s. ISO sha256
   `1616c4ae1f5091f0bd05a44022cb50619ce46cf6d4592ee0155e2cf2dbfc97a5`.
   The fresh guest and host MC2_* outputs are line-identical to the first
   incarnation's captured runs (guest: `ordinary_fault_retained=1
   peek_fault_retained=1 invariant_matches_linux=0 consistent=1`; Linux
   control: `ordinary_fault_retained=0 peek_fault_retained=1
   invariant_matches_linux=1 consistent=1`).
3. issue.json fixed: added the model dependencies the validator requires
   (root "work" whole-file selectors: `spec/MC.tla` defines
   MCSendBegin/MCRecvBegin, `spec/base.tla` defines
   PayloadFaultConsumptionMatchesLinux, `spec/MC_hunt_AST36.cfg` is the hunt
   config that produced the cited counterexample) and fixed an ambiguous
   iovec.rs dependency boundary (`fn skip_some` appears in both MultiRead
   and MultiWrite; the end boundary is now the unique MultiWrite doc line).
   Read-only validation via
   `specula.persistent_findings.validate_issue_proposal` passes (title 153
   chars; 4 source + 3 model dependencies; 6 evidence files).
4. Counterexample re-verified directly from the log (not via the first
   incarnation's notes): the MC_hunt_AST36.log trace shows
   MCSendBegin(message1, rights <<fileA, fileB, fileA, fileB>>) ->
   MCRecvBegin(<<r1,1>>, "Recv", "Full", FALSE) -> Lock -> Select -> Copy ->
   payloadResult="Fault", returnValue="EFAULT", faultRetained=TRUE ->
   Unlock -> Drop -> Done, with final queue.msg="message1",
   queue.rights=<<fileA,fileB,fileA,fileB>>, consumed=0, budget
   payloadFault=1/recv=1 — the retention divergence the invariant flags.
5. Novelty re-verified independently: dataset `asterinas-bug-findings-2026-08`
   id-map.md maps MC-2/T-3 -> AST-36 ("Analysis-only candidate"); a fresh
   upstream search (github.com/asterinas/asterinas, issues + PRs, three
   query shapes: recvmsg EFAULT / unix datagram recvmsg fault / SCM_RIGHTS)
   found no report of this mechanism at this site (nearest: vsock PR #3122
   discusses EFAULT queue-retention for vsock, a different socket family;
   tracking issues #2112/#1851 are feature-gap lists; PR #2155 is netlink
   truncation). KNOWN therefore rests on the prior Specula dataset entry;
   fix-status unfixed at pin 0c6053709 (the early return before dequeue is
   still present and the fresh guest run shows retention).

Verdict (unchanged, now with a complete artifact chain): REPRODUCED
(Level 0).
