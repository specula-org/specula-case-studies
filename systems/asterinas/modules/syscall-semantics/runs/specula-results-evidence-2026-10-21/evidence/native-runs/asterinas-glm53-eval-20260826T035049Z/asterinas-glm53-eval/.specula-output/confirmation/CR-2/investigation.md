# CR-2 Investigation — Vectored/Positional syscalls lack EINTR→ERESTARTSYS restart translation

Worktree: `.specula-output/confirmation/CR-2/worktree` (git baseline d0139a1
"Asterinas 604948581 pristine baseline" + Specula tla_trace instrumentation;
the instrumentation only adds trace calls — verified via `git diff HEAD` that
the EINTR translation and its absence are pristine-baseline code).

## Step 1: Code audit

### The restart machinery (how it is supposed to work)

- `kernel/core/src/syscall/mod.rs:379-411` `handle_syscall`: on syscall error
  sets `user_ctx.syscall_ret = -errno`. **No generic EINTR→ERESTARTSYS
  translation exists at dispatch level.**
- `kernel/core/src/thread/task.rs:80-83`: on `ReturnReason::UserSyscall`,
  `ctx.thread_local.set_orig_syscall_ret(Some(user_ctx.syscall_ret()))`
  saves the syscall number for a possible rewind.
- `kernel/core/src/process/signal/mod.rs:63-71`
  (`handle_pending_signal`): iff
  `user_ctx.syscall_ret() == -(Errno::ERESTARTSYS as i32)` (-512), it
  converts the return to `-EINTR`; then at mod.rs:145-157, if the dequeued
  signal has a **user handler with SA_RESTART**, it restores
  `syscall_ret = orig_syscall_ret` (the syscall number) and rewinds RIP by
  the syscall instruction length (2 bytes on x86-64) → the whole syscall is
  re-executed; userspace never sees EINTR. Without SA_RESTART (or no
  handler), the syscall returns -EINTR.

So a syscall is restartable **only if its wrapper translates the internal
EINTR (produced by interruptible waits) into ERESTARTSYS before returning**.

### Translation present (baseline)

`grep ERESTARTSYS` over syscall wrappers: read.rs:38, write.rs:38, accept.rs:60,
connect.rs:27, fcntl.rs:38, flock.rs:30, futex.rs:142, open.rs:49,
recvfrom.rs:37, recvmsg.rs:38, sendmsg.rs:62, sendto.rs:43, wait4.rs:38,
waitid.rs:45 — each does
`Errno::EINTR => Error::new(Errno::ERESTARTSYS)`.

### Translation absent (the finding's sites — verified in baseline via `git show HEAD:`)

- `kernel/core/src/syscall/preadv.rs` — `sys_readv` → `do_sys_readv` (returns
  `final_error` raw), `sys_preadv`/`sys_preadv2` → `do_sys_preadv` (returns
  `Err(err)` raw). No EINTR handling anywhere in the file.
- `kernel/core/src/syscall/pwritev.rs` — `sys_writev`/`sys_pwritev`/
  `sys_pwritev2`: same shape, no EINTR handling.
- `kernel/core/src/syscall/pread64.rs:33` / `pwrite64.rs:33` — `result`
  returned raw; no EINTR handling.

### Where EINTR actually comes from (reachability)

The producer is the POSIX-aware wait family:
`kernel/core/src/process/signal/pause.rs` — `pause_until`/`pause_timeout`
return `Err(EINTR)` when the waiting thread has a pending unmasked signal.
`kernel/core/src/process/signal/poll.rs:313-315` — `Poller::wait()` →
`pause_timeout` → EINTR. `Pollable::wait_events` (poll.rs:354+) propagates it
to any file type that waits for IO events.

Concrete chain for **readv on an empty pipe** (all public APIs):
`SYS_readv` → `do_sys_readv` (preadv.rs) → `file.read(writer)` →
`InodeHandle` per-open ops → `PipeHandle::read_at`
(fs/pipe/common.rs:100-116) → `wait_events(IoEvents::IN, None, try_read)` →
`poller.wait()` → `pause_timeout` → **Err(EINTR)** → propagates raw through
`do_sys_readv` (`final_error = Some(err)`) → `handle_syscall` sets ret = -4 →
`handle_pending_signal` sees -4 ≠ -512 → **no restart** → after the SA_RESTART
handler runs, userspace observes `readv() = -1, errno = EINTR`.

Same for **writev on a full pipe** (`PipeHandle::write_at` → wait OUT).

For scalar `read`/`write` on the same pipes, read.rs/write.rs translate to
ERESTARTSYS → `handle_pending_signal` rewinds → syscall restarts → returns
data. This asymmetry is the finding.

### Regular files (the campaign scope) — why the finding says "deliberately never model-checked"

No local regular-file I/O path can produce EINTR today: ext2/exfat/ramfs/
virtiofs file reads/writes go through the page cache and kernel-internal
block waits; greps show no `pause`-family / `wait_events` / EINTR producer in
`fs_impls/{ext2,exfat,ramfs,virtiofs}` I/O paths. `pread64`/`pwrite64`
further require a seekable file (pipes/sockets → ESPIPE at
`file_ops_for_positional_io`), so for them the missing translation is
**currently latent** (no reachable trigger). The **live** trigger through the
affected wrapper code is vectored I/O on interruptible file types (pipes,
sockets, tty) — `do_sys_readv`/`do_sys_writev` are fd-type-generic and are
exactly the functions the finding cites (preadv.rs:134 / pwritev.rs:134).

### Trigger scenario

Parent installs a SIGUSR1 handler with SA_RESTART, forks a child, and blocks
in `readv()` on an empty pipe. Child (t≈1s) sends SIGUSR1, then (t≈2s)
writes one byte. Linux contract (signal(7)/readv(2)): the interrupted readv
is **restarted** (pipe reads return -ERESTARTSYS internally; SA_RESTART
rewinds); the caller eventually gets the byte and never sees EINTR.
Asterinas prediction from the audit: `readv()` returns -1/EINTR after the
handler runs. Scalar `read()` on the same pipe restarts correctly (control),
demonstrating the divergence is specific to the un-translated wrappers.

Note on the "replay committed bytes" hazard in the finding: a whole-syscall
restart replays only when the wait was interrupted *before progress*;
`do_sys_readv` returns short counts once `total_len > 0`, so the restart
hazard requires an EINTR *after committed progress* — no such producer exists
for local regular files today (consistent with the finding's own text). The
demonstrable Linux-visible divergence is the raw-EINTR-vs-restart behavior.

## Step 2: Developer knowledge

- In-tree tests: no test anywhere in `test/` asserts EINTR behavior for
  readv/writev/preadv/pwritev (grep). No TODO/FIXME near the cited wrappers
  mentions restart.
- Issue **#1578** "Restart signal-interrupted system calls" (closed completed
  2024-12-16 by PR #1598; #2461 extended to all architectures) introduced the
  current mechanism. Its syscall list is **read, write, ioctl, open,
  wait/waitpid, fcntl locks, futex** — the vectored/positional wrappers were
  silently left out; the issue text never mentions readv/writev/preadv/
  pwritev/pread64/pwrite64.
- PR **#3576** "Refactor the syscall restart mechanism" (OPEN, unmerged,
  created 2026-07-10): states the current design "both misses some cases
  where a restart should occur, and causes some cases where a restart should
  not occur to be restarted incorrectly", and proposes moving the conversion
  into `pause` (which would implicitly fix readv/writev). **However**: its
  diff touches none of preadv.rs/pwritev.rs/pread64.rs/pwrite64.rs, and its
  new test `process/signal/syscall_restart.c` (fetched, read in full) covers
  only read-on-pipe, poll, futex, and socket reads — **no readv/writev/
  preadv/pwritev/pread64/pwrite64 test**. It is awareness of the flaw class,
  not a report of this defect at these sites.
- PR #3607 (closed, unmerged) — socket-timeout-aware EINTR mapping: different
  mechanism. #3091 — poll revents on EINTR: different mechanism. #3283 —
  flock waker growth: different mechanism.

## Step 3: Known status / precedent

Tracker search (GitHub issues+PRs, "EINTR" full list of 28 fetched and
reviewed; plus web search): no issue, PR, or CVE reports that
readv/writev/preadv/pwritev/pread64/pwrite64 surface raw EINTR despite
SA_RESTART (missing translation at preadv.rs/pwritev.rs/pread64.rs/
pwrite64.rs). Closest: #1578 (introduced mechanism, different syscall list,
closed as completed before these wrappers existed in that form), #3576 (open
refactor naming the general flaw class, not these sites, no tests for them).
→ **Novelty: NEW** (with #3576 noted as near prior art; unmerged).

Code-review source, not already-reported → **not dropped**; proceed to Phase 2.

## Phase 2 plan

Level 0 black-box: public syscalls only (pipe/fork/sigaction-SA_RESTART/
kill/read/readv/write/writev/pread64/fcntl/waitpid), child sleeps order the
events. Linux host run = contract control; Asterinas guest run via Docker
`asterinas/dev:0.18.1-20260805` + `make run_kernel AUTO_TEST=cr2repro`
(recipe reused from harness/run.sh and the CR-1 confirmation).

- Check 1 (control): read() empty pipe + signal + late data → expect n=1,
  handler ran (restart machinery works for translated syscalls).
- Check 2 (bug): readv() empty pipe, same → Linux: n=1; predicted Asterinas:
  n=-1 EINTR.
- Check 3 (control): write() full pipe + signal + late drain → expect n=1.
- Check 4 (bug): writev() full pipe, same → Linux: n=1; predicted Asterinas:
  n=-1 EINTR.
- Check 5 (info): pread64 on a regular file works; local regular files have
  no EINTR producer → the pread64/pwrite64 half of the finding is latent
  (documented, cannot be live-triggered on ramfs/ext2/exfat/virtiofs).

## Phase 2 record (added at reproduction)

Escalation ladder:

- **Level 0 (executed, bug triggered)**:
  `repro/test_bugCR-2_eintr_restart_divergence.c` — pure public-syscall test
  (pipe/fcntl/fork/kill/sigaction-SA_RESTART/waitpid; raw SYS_read/SYS_readv/
  SYS_write/SYS_writev/SYS_pread64). Child helper sleeps 1 s (parent is
  blocked in the syscall under test by then), sends SIGUSR1, sleeps 1 s,
  then supplies the byte (read side) or drains the pipe (write side).
  Five checks: scalar read/write controls (translated path), readv/writev
  probes (untranslated path), pread64 sanity + latency note.

  **Linux control (host, same binary): PASS 5/5** (run 4x, deterministic;
  saved as `.linux_control.txt`):
  ```
  CR2   1 read()  empty pipe restarted (control)              : PASS (ret=1 signals=1)
  CR2   2 readv() empty pipe must restart (SA_RESTART)        : PASS (ret=1 signals=1)
  CR2   3 write()  full pipe restarted (control)              : PASS (ret=1 signals=1)
  CR2   4 writev() full pipe must restart (SA_RESTART)        : PASS (ret=1 signals=1)
  CR2   5 pread64() works on regular file (sanity)            : PASS (ret=7)
  CR2_RESULT: PASS (5 checks, 0 failed)
  ```
  → the oracle is correctly encoded: Linux restarts readv/writev on pipes
  with SA_RESTART and never surfaces EINTR.

  **Asterinas guest (Docker asterinas/dev:0.18.1-20260805, KVM,
  `make run_kernel AUTO_TEST=cr2repro TARGET_ARCH=x86_64 SMP=2 MEM=2G
  ENABLE_KVM=1`, pristine baseline + trace instrumentation inactive for
  this test filename): BUG TRIGGERED — checks 2 and 4 FAIL** (saved as
  `.guest_output.log` / `.guest_qemu_full.log`, make_exit=0):
  ```
  CR2   1 read()  empty pipe restarted (control)              : PASS (ret=1 signals=1)
  CR2   2 readv() empty pipe must restart (SA_RESTART)        : FAIL (ret=-1 errno=4 (Interrupted system call) signals=1)
  CR2   3 write()  full pipe restarted (control)              : PASS (ret=1 signals=1)
  CR2   4 writev() full pipe must restart (SA_RESTART)        : FAIL (ret=-1 errno=4 (Interrupted system call) signals=1)
  CR2   5 pread64() works on regular file (sanity)            : PASS (ret=7)
  CR2_RESULT: FAIL (5 checks, 2 failed)
  CR2_REPRO_DONE
  ```
  Interpretation:
  - Controls 1/3 PASS on the guest → the EINTR→ERESTARTSYS translation +
    SA_RESTART rewind machinery WORKS for scalar read()/write()
    (read.rs:38 / write.rs:38), and the test sequencing is sound.
  - Checks 2/4 FAIL exactly per the finding: `readv()` on an empty pipe and
    `writev()` on a full pipe return **-1/EINTR to userspace** although the
    handler was installed with SA_RESTART (handler DID run: signals=1).
    The failing syscalls dispatch to `do_sys_readv` (preadv.rs) and
    `do_sys_writev` (pwritev.rs) — the exact cited sites. Root cause as
    audited: pipe waits produce EINTR (`pause_timeout`), which those
    wrappers return untranslated; `handle_pending_signal` only rewinds when
    syscall_ret == -ERESTARTSYS.
  - Check 5 + audit: pread64/pwrite64 half is latent — no local
    regular-file EINTR producer exists (no interruptible wait in ext2/
    exfat/ramfs/virtiofs I/O paths; seekable requirement excludes pipes/
    sockets), so their missing translation has no live trigger today.
    The "restart replays committed bytes" hazard likewise requires an
    EINTR-after-progress producer that no current path supplies.

- **Level 1**: timing assistance already built in (1 s child sleeps); no
  tighter window exists — the divergence is not a race, it is deterministic
  control flow (the guest run shows it in a single shot with both controls
  green).
- **Level 2/3**: unnecessary — Level 0 triggered the live harm.

Right-bug verification: the failing syscalls are exactly the finding's
cited wrappers (preadv.rs `do_sys_readv`, pwritev.rs `do_sys_writev`); the
observed divergence (raw EINTR despite SA_RESTART) is exactly the finding's
title mechanism; the scalar controls isolate the cause to the missing
translation, not to the signal/restart machinery.

Novelty re-check this turn: GitHub tracker full EINTR list (28 items)
reviewed + PR #3576 file list and new test fetched and read in full + PR
#3607, #3091, #1578 checked — none reports readv/writev/preadv/pwritev/
pread64/pwrite64 returning EINTR despite SA_RESTART. Novelty: NEW
(#3576 = open unmerged refactor naming the flaw class, not these sites).

Phase-2 outcome: **REPRODUCED** (Level 0, live harm via public syscalls;
real consumer = any userspace caller of readv/writev, which receives a
spurious EINTR where Linux restarts).
