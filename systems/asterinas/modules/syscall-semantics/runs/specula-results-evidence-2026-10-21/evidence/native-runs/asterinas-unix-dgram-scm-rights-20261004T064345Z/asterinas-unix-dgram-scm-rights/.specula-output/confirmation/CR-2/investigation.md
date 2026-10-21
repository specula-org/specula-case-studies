# CR-2 Investigation (Phase 1 — evidence only)

Finding: "Scenario 2: Queue selection and ancillary completion have different orders"
Source: code-review (MC_hunt_scenario2* configs returned **no violation**; not MC-found).
Worktree pin: `0c6053709` + trace-only `scm_trace` instrumentation (verified: `diff -rq` between
`source/` and `confirmation/CR-2/worktree` differs only in `.git` and `target/`).

## Step 1: Code audit

### Cited code, read in full

All line numbers below are worktree lines (pin + trace-only instrumentation; the trace diff does
not move any lock boundary — verified against `git diff` of the pinned source).

1. `kernel/core/src/net/socket/unix/datagram/message.rs` — `MessageReceiver::try_recv` (243–341;
   the pinned cited range 179–217 is the same function before instrumentation):
   - acquires `self.queue.inner` mutex (247);
   - selects `inner.messages.front()` **under the lock** (253);
   - copies payload to user iovec **under the lock** (285);
   - consume branch: `pop_front` + `total_length -=` **under the lock** (311–315), then
     `message.aux.generate_control(behavior, is_pass_cred)` **under the lock** (324);
   - peek branch: `inner.messages.front_mut()` + `generate_control` **under the lock** (327–328);
   - `drop(guard)` (334) — by then the `Vec<ControlMessage>` returned to the caller already owns
     its file references outright.

2. `kernel/core/src/net/socket/unix/ctrl_msg.rs`:
   - `AuxiliaryData::generate_control` (pinned cited 304–310): `ReceiveBehavior::Recv =>
     mem::take(files)` (moves the queue's `Vec<Arc<dyn FileLike>>` out), `Peek => files.clone()`
     (clones the Arcs). This is the SCM_RIGHTS **ownership transfer** and it executes inside the
     queue mutex, jointly serialized with selection and consumption.
   - `FileMessage::write_to` (pinned cited 141–148; worktree 139–231): per file, takes
     `file_table.unwrap().write()` (the `RwArc<FileTable>` write lock), `table.insert(file.clone(),
     FdFlags::empty())`, then `writer.write_val_observed::<i32>(&fd)` into that call's own user
     control buffer. This is the **publication** (FD installation + number copy) and it runs after
     the queue mutex has been released.

3. `kernel/core/src/syscall/recvmsg.rs:32–52` — `sys_recvmsg`: reads user msghdr, borrows file
   table, `socket.recvmsg(...)` (the queue-locked phase above), **drops the file-table borrow**,
   then `c_user_msghdr.write_control_messages_to_user(...)` (the publication phase). The comment
   at 44–45 states the ordering constraint: control-message writing re-borrows the file table, so
   it must run after the first borrow is dropped.

### Call chain (public API → cited code), reachability

`recvmsg(2)` → `sys_recvmsg` (syscall/recvmsg.rs:17) → `get_file_fast` →
`UnixDatagramSocket::recvmsg` (net/socket/unix/datagram/socket.rs:299) → `block_on(IoEvents::IN,
..., || self.local_receiver.try_recv(writer, flags))` (net/socket/mod.rs:48; retries from scratch
on EAGAIN) → `MessageReceiver::try_recv` (queue mutex: select → copy → pop|front →
`generate_control`) → back in `sys_recvmsg` → `CUserMsgHdr::write_control_messages_to_user`
(util/net/socket.rs:138) → `ControlMessage::write_all_to` → `UnixControlMessage::write_to` →
`FileMessage::write_to` (file-table write lock: `insert` + fd-number copy).

Fully reachable through normal usage: any `recvmsg` on an AF_UNIX SOCK_DGRAM socket whose queue
holds a message sent with SCM_RIGHTS. `MSG_PEEK` is in `RecvFlags::SUPPORTED`
(net/socket/util/message_flags.rs:50) and maps to `ReceiveBehavior::Peek` (63–69). The sharing
needed for the hypothesized interleaving is two threads of one process using the same socket fd
(same `MessageReceiver`, same `FileTable` inside one `RwArc`).

### Lock/order analysis of the hypothesized interleaving

What the finding describes is real as a *wall-clock ordering fact*: the peek thread's
`FileTableInsert`/fd-number writes can execute after the consuming thread already dequeued the
message and published its own fds — selection order and publication order can differ. The three
hypothesized defect classes, assessed against the code:

(a) **Message consumed twice** — `pop_front` runs under the queue mutex exactly once per message;
    the peek branch never pops (`front_mut`). A second ordinary receiver re-locks and sees either
    the next message or an empty queue (EAGAIN). No path pops twice.

(b) **PEEK publication delivering moved rights** — the peek branch clones the Arcs while holding
    the queue mutex and while the message is still the front element. The moved (taken) `Vec`
    exists only as a local of the consuming thread after its own `pop_front`. No ownership state
    is shared across the lock boundary; each thread's `FileMessage` owns independent Arcs.

(c) **Stale rights published after consumption** — the peek-cloned Arcs hold references, so the
    file objects stay alive regardless of when the consuming thread's publication runs. Installing
    them after the message was consumed yields valid fds naming the captured objects — which is
    Linux's documented MSG_PEEK + SCM_RIGHTS behavior (peek duplicates the references; a later
    ordinary receive delivers them again). Not a wrong outcome.

### Safeguards encountered (recorded; Phase 2 proves whether they hold)

1. Queue mutex spans selection + payload copy + consumption + ownership transfer (message.rs).
   Introduced with MSG_PEEK support: commit `485f2189c` "Implement MSG_PEEK for UNIX datagram
   sockets" restructured `try_recv` so **both** the `pop_front` branch and the `front_mut` branch
   call `generate_control` inside the lock (the pre-peek code already generated under the lock).
2. Publication is serialized per-file by the file table's own write lock (`RwArc<FileTable>`;
   file_table.rs:105–115, ctrl_msg.rs `write_to`), so concurrent installs get distinct slots.
3. Peek leaves the message queued with its own Arcs (clone-not-take), so later receives still
   deliver rights.
4. `block_on` re-runs `try_recv` from scratch; no state survives a failed attempt.

### Trigger scenario (constructed for Phase 2)

Same process, two threads pinned to different CPUs, AF_UNIX SOCK_DGRAM socketpair; one datagram
carrying k SCM_RIGHTS references to two regular files with distinct 1-byte markers, sender then
closes its copies. Thread P calls `recvmsg(MSG_PEEK)`, thread R calls `recvmsg(0)`, released
together with swept relative delays; hundreds of rounds. Observable checks: every received fd
reads the expected marker (`pread` at offset 0), exactly one consuming receive per message (a
follow-up ordinary receive sees EAGAIN iff the racing one consumed), fd-count accounting exact,
no kernel panic/hang, no stray fds after cleanup. Variants: two competing ordinary receivers;
repeated-peek vs consume; three-message queue under a peek+recv storm. On Asterinas the
`scm_trace` instrumentation dumps per-thread event timestamps (SCM_RAW lines) used post-hoc to
prove the interleaving (peek selection before recv dequeue, peek publication after recv
completion) actually occurred while the properties held.

## Step 2: Developer knowledge

- Commit `485f2189c` (jiangjianfeng, 2026-06-09) "Implement MSG_PEEK for UNIX datagram sockets":
  no concurrency commentary; the diff itself is the evidence — both branches generate control
  messages under the queue lock.
- Comment in `FileMessage::write_to` (ctrl_msg.rs ~197): "Perhaps we should remove the inserted
  files from the file table if we cannot write the file descriptor back to user space? However,
  even Linux cannot handle every corner case" — acknowledged trade-off about
  install-before-number-copy (Scenario 3 territory), not about interleaving.
- FIXME in `from_control`: UNIX-socket-in-SCM_RIGHTS circular references may leak (no GC) —
  different aspect, out of scope.
- Tests: upstream `test/initramfs/src/regression/network/msg_peek.c` asserts single-threaded
  MSG_PEEK semantics only. The only concurrent SCM_RIGHTS test in-tree is this run's harness
  (`scm_rights_trace.c`, cases 15–18), which passed (`SCM_DONE 0`) on the pinned kernel with
  competition cases 17/18 (two receivers racing; case 18 is exactly PEEK vs ordinary receive).
- Model checking: MC_hunt_scenario2* configs (four) found no violation of at-most-once
  consumption / PEEK queue-preservation within bounds (three exhaustive, one budget-ended).

## Step 3: Known status

- Searched GitHub asterinas/asterinas issues and PRs (open and recently merged/closed) plus the
  upstream commit lists for both cited files: the latest upstream commits touching them are
  `819e7a826` (Aug 11, 2026) and `b9cfb5ccf` (Aug 13, 2026) — both refactor/visibility work, no
  fix after the pin. No issue/PR/CVE reports a queue-selection-vs-ancillary-publication ordering
  defect at these sites. Asterinas SCM-related PRs found (#2176, #2268, c3572e9, e4c5c36) are
  feature work (SCM_CREDENTIALS, SO_PASSCRED, SO_PEERCRED).
- Linux's `af_unix` "GC vs MSG_PEEK" bugs (cbcf01128d0a, e5b31d98) are a different site and
  mechanism (unix-socket garbage collector vs peek refcount bumps; Asterinas has no SCM GC).
- **Novelty: NEW.** Not a code-review × known duplicate; no Phase-1 drop. Proceed to Phase 2.

## Phase 2 addendum — reproduction record

Test: `.specula-output/repro/test_bugCR-2_peek_consume_interleave.c`
(build/run scripts + captured logs in `confirmation/CR-2/`).

Escalation ladder:

- **Level 0 (black-box, real API)**: 5 variants (V0 sequential peek→recv→peek;
  V1 racing PEEK vs ordinary recv; V2 two competing ordinary receivers; V3
  4-peek storm vs one recv; V4 3-message queue under peek+recv storm), 600
  rounds per run. Asterinas guest (pin 0c6053709 + trace-only instrumentation,
  ISO rebuilt from the provenance-verified `source` cache, QEMU/KVM, 2 CPUs,
  2G) and Linux control (host kernel 7.2.8) both: **0 failures**. Sender closes
  its file copies after sendmsg, so the queue owns the only references — a
  stale/moved reference would leave a dead object behind a delivered fd.
- **Level 1 (timing assistance)**: worker threads pinned to distinct CPUs
  (asserted via getcpu; same_cpu=0 in all instrumented runs), relative start
  offsets swept 0..2000 spin iterations alternating the lead thread, and an
  escalation build with 8 SCM_RIGHTS per message widening the post-lock
  publication window 4x. Three instrumented Asterinas runs: 74+61+38 V1
  rounds delivered BOTH the peek copy and the consumed copy (173 total).
- **Interleaving proof (trace)**: the pinned instrumentation's per-thread
  kernel event timestamps show, in 8+5+4 instrumented V1 rounds, that the peek
  thread selected the message BEFORE the recv thread dequeued it, and its
  `FileTableInsert` publication finished AFTER the dequeue — i.e. the exact
  "selection order != publication order" interleaving the finding hypothesizes
  demonstrably occurs, with the peek's publication overlapping the recv's
  publication phase. In every such round all properties held (markers correct,
  exactly-once consumption, exact fd accounting).
- **Level 2 (state injection)**: not sound here — each hypothesized defect
  class needs a pre-condition the real API cannot produce (the peek's
  FileMessage sharing the queue's moved Vec; a message popped twice). The
  ownership transfer is under the queue mutex, so no real-API call sequence
  reaches such a state; injecting it would fabricate the bug.
- **Level 3 (source patch)**: not applicable — a delay would only widen an
  interleaving already exercised; it cannot create a defect for which no
  shared mutable state exists.

Captured outputs: `guest_r2.log` (default build, CR2_DONE 0, 38 both-delivered,
4 trace-proven publication-after-consumption rounds), `guest_r8.log`
(8-rights escalation, CR2_DONE 0, 61 both-delivered, 5 trace-proven rounds),
`analyze_interleave.py` + its output, Linux control output in the transcript.
The harness ISO in `source/target/osdk/` was backed up before the rebuild and
restored afterwards.
