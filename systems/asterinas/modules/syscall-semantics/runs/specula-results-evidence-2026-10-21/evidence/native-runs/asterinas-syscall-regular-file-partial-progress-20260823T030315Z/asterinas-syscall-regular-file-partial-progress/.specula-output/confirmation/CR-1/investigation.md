# CR-1 — Investigation record (Phase 1, evidence only)

**Finding**: "Restart consumes an errno without progress provenance."
**Source label**: code-review / Scenario 6 (model checking produced **no** pinned-backend
counterexample, so this is `Code Review`-sourced per guide.md).

All line numbers below are from the **pristine baseline** (`git show HEAD:<file>`,
commit `2cd6429`, Asterinas 604948581). The worktree carries untracked
`tla_trace.rs` harness instrumentation; `kernel/` is reverted to pristine before
every reproduction build.

---

## Step 1 — Code audit

### 1.1 The cited sites, verbatim

`kernel/core/src/syscall/read.rs:27-39` (identical shape in `write.rs:27-39`):

```rust
let read_len = {
    if buf_len != 0 {
        let user_space = ctx.user_space();
        let mut writer = user_space.writer(user_buf_addr, buf_len)?;
        file.read(&mut writer)
    } else {
        file.read_bytes(&mut [])
    }
}
.map_err(|err| match err.error() {
    Errno::EINTR => Error::new(Errno::ERESTARTSYS),
    _ => err,
})?;
```

`kernel/core/src/process/signal/mod.rs:54-62` — classification:

```rust
let syscall_restart = if let Some(orig_syscall_ret) = ctx.thread_local.orig_syscall_ret()
    && user_ctx.syscall_ret() == -(Errno::ERESTARTSYS as i32) as usize
{
    user_ctx.set_syscall_ret(-(Errno::EINTR as i32) as usize);
    Some(orig_syscall_ret)
} else { None };
```

`kernel/core/src/process/signal/mod.rs:145-158` — SA_RESTART rewind:

```rust
if let Some(orig_syscall_ret) = syscall_restart
    && flags.contains(SigActionFlags::SA_RESTART)
{
    const SYSCALL_INSTR_LEN: usize = 2; // x86_64 `syscall`
    user_ctx.set_syscall_ret(orig_syscall_ret);
    user_ctx.set_instruction_pointer(user_ctx.instruction_pointer() - SYSCALL_INSTR_LEN);
}
```

`kernel/core/src/thread/task.rs:83-85` — `orig_syscall_ret` (the original `rax`,
i.e. the syscall number) is stashed on every `UserSyscall` return reason.

The argument registers (`rdi`/`rsi`/`rdx`) are never touched by the kernel, so a
restarted `read`/`write` re-executes with the **identical buffer address and
length**. The finding's structural description is accurate: restartability is
carried by a bare errno; nothing in the channel can say "N bytes are already
done, resume at N".

### 1.2 Where progress would be lost

`kernel/core/src/fs/file/inode_handle.rs:285-290` (read) and `:308-320` (write):

```rust
let mut offset = self.offset.lock();
let len = file_ops.read_at(*offset, writer, status_flags)?;   // <- `?`
*offset += len;
```

On **any** `Err`, `*offset += len` is skipped. So if a backend committed bytes
and then returned `Err(EINTR)`:

* the shared open-file-description offset does **not** move;
* `sys_read`/`sys_write` returns `ERESTARTSYS`;
* SA_RESTART replays the call with the original `(buf, len)`.

Consequence classes, worked through:

* **plain write** — replay writes the same bytes to the same offset. Content is
  idempotent; the offset advances once. No user-visible divergence.
* **`O_APPEND` write** — `inode_handle.rs:311-315` recomputes
  `*offset = self.path().size()` on every attempt. The first attempt already grew
  the file by N, so the replay appends the same payload **again**: the file ends
  up 2N longer for one `write()`. This is the sharp form of "repeats an already
  committed effect".
* **read** — replay re-reads from the unmoved offset; the user buffer is
  overwritten with the same bytes. Benign for a regular file.

So the consequence is real *provided* a regular-file backend can return `EINTR`
after committing bytes.

### 1.3 Reachability: can a regular-file backend return `EINTR` at all?

Exhaustive grep of the pristine tree:

* `grep -rn EINTR kernel/core/src/fs/` → **0 hits**.
* `grep -rn EINTR kernel/core/src/vm/` → **0 hits**.
* `grep -rn EINTR ostd/src/` → **0 hits**.

The only `EINTR` producers in the kernel are the interruptible wait primitives
(`process/signal/pause.rs:157,190,216`, reached via `Poller::wait` →
`poll.rs:313`), plus `futex.rs`, `clone.rs`, `sem.rs`, `nanosleep.rs`.

Which read/write paths reach an interruptible wait?

| caller | primitive | file type |
|---|---|---|
| `fs/pipe/common.rs:115,134` | `wait_events` | pipe/FIFO |
| `net/socket/mod.rs:61` (`block_on`) | `wait_events` | socket |
| `device/tty/mod.rs:194,217`, `device/pty/master.rs:107,133`, `device/evdev/file.rs:391` | `wait_events` | char device |
| `fs/vfs/notify/inotify.rs:336` | `wait_events` | anon inode |
| — none — | — | **regular file** |

The regular-file backends wait **uninterruptibly**:

* page-cache write-back: `vm/page_cache/cache_page.rs:319-321` →
  `wait_queue.wait_until(...)` (no signal check);
* block I/O completion: `comps/block/src/bio.rs:355` → `wait_queue.wait_until(...)`;
* ramfs: pure in-memory, no wait at all;
* virtiofs: `comps/virtio/.../session.rs` → `waiter.wait()`, uninterruptible.

So on the campaign's scope (`read`/`write`/`pread64`/`pwrite64`/`readv`/`writev`
on regular files, ext2 + ramfs) the `EINTR` arm at `read.rs:37` / `write.rs:37`
**has no producer**.

### 1.4 Reachability: can *any* backend return `EINTR` after committed progress?

The kernel-wide convention in every `wait_events`/`block_on` caller is
"short count on progress, `EAGAIN` only on zero progress", and `wait_events`
(`poll.rs:365-390`) returns immediately on any non-`EAGAIN` result — so the
`poller.wait()?` that yields `EINTR` is only ever reached with **zero** bytes
committed:

* `pipe/common.rs:406-418` `try_read` → `Ok(read_len)` even when partial;
* `pipe/common.rs:464-490` `try_write` → `Ok(n)`/`Ok(0)`, never EAGAIN-after-copy;
* `inotify.rs:304-308` → `EAGAIN` only when `consumed_events == 0`;
* `tty/mod.rs:204-223` copies into a kernel bounce buffer first, then blocks on
  `push_output`; the blocking attempt has committed nothing.

That is the invariant that keeps the wrapper's missing provenance harmless
today. It is **implicit** — no comment, no doc, no type states it.

### 1.5 The scalar/vectored asymmetry

`syscall/preadv.rs:113-120` and `:165-169` (which host `readv`) — and the
`pwritev.rs` mirror — already do exactly the discrimination CR-1 says is missing:

```rust
match file.read_at(cur_offset, writer) {
    Ok(read_len) => { total_len += read_len; cur_offset += read_len; }
    Err(_) if total_len > 0 => break,      // report progress, swallow the error
    Err(err) => return Err(err),
}
```

The vectored path needs it because it *loops* and can accumulate progress across
entries. The scalar path makes exactly one `read_at`/`write_at` call, so it has
nothing to accumulate: whatever that single call returns is the whole answer.
The scalar wrapper is therefore correct **given** the §1.4 backend contract.

Also recorded: `readv`/`writev`/`pread64`/`pwrite64`/`preadv`/`pwritev` do **not**
perform the `EINTR → ERESTARTSYS` mapping at all — only `read.rs` and `write.rs`
do. That is a separate inconsistency (see Step 2, PR #3576), not CR-1's claim.

### 1.6 Trigger scenario (constructed)

1. Thread T opens a regular file on `/ext2` or `/tmp` with `O_APPEND`, `dup`s the
   fd so two descriptors share one open-file description.
2. T installs a `SIGUSR1` handler with `SA_RESTART`.
3. A sibling thread floods T with `SIGUSR1` while T issues large `write()`s.
4. **Required step that has no producer**: the ext2/ramfs backend commits a
   positive prefix and returns `Err(EINTR)`.
5. `write.rs:37` → `ERESTARTSYS`; `signal/mod.rs:145` rewinds; the append is
   replayed; the file grows by 2N for one `write()`.

Step 4 is the gap. Step 1-3 and 5 are ordinary public-API operations.

### 1.7 Safeguards recorded (Phase 2 must prove they fire)

* ext2/ramfs page-cache and bio waits are `wait_until`, not `pause_until`.
* User-buffer faults surface as `EFAULT`, never `EINTR`
  (`ostd/src/mm/io/mod.rs` fallible readers/writers).
* Every `wait_events` caller returns a short count rather than blocking after a
  partial copy (§1.4).

---

## Step 2 — Developer-knowledge search

**Issue tracker.** `gh` search over `asterinas/asterinas`:

* **PR #3576, "Refactor the syscall restart machnism"** (open, created
  2026-07-10, last updated 2026-07-23) —
  <https://github.com/asterinas/asterinas/pull/3576>. Touches the exact cited
  lines: `kernel/src/syscall/read.rs` (+1/-5) and `write.rs` (+1/-5) delete the
  `map_err(EINTR => ERESTARTSYS)` block; `signal/pause.rs` makes the `pause`
  family return `ERESTARTSYS` directly. Stated defect, verbatim:

  > Our current syscall restart mechanism is implemented in a rather unusual
  > way. We map `EINTR` to `ERESTARTSTS` at the syscall level. However, this
  > approach both misses some cases where a restart should occur, and causes
  > some cases where a restart should not occur to be restarted incorrectly.

  The concrete "restarted incorrectly" case the PR names and fixes is
  **socket timeouts** (`sock_intr_errno`: with `SO_RCVTIMEO` set the call must
  fail `EINTR`, not restart). Its new regression test
  `test/initramfs/src/regression/process/signal/syscall_restart.c` only does
  1-byte reads/writes — no partial-transfer case. Its review comments
  (`gh api .../pulls/3576/comments`) discuss epoll message wording, socket-mapping
  duplication, and a **futex relative-timeout** replay ("restart ... will re-read
  the same relative timeout and effectively extend the total wait"). **None
  mentions byte progress on `read`/`write`.**

  Crucially, the PR's own fix keeps restartability encoded as a bare errno
  (`ERESTARTSYS` now flows up from `pause_*`), so it neither reports nor repairs
  CR-1's progress-provenance concern.

* **Issue #1578, "Restart signal-interrupted system calls"** (closed 2024-12-16)
  — the feature request that introduced the mechanism. Quotes `signal(7)`'s
  SA_RESTART list but not its "if a partial transfer was performed, the call
  returns the partial count" clause. No partial-progress discussion.

* Searched additionally: `partial write signal restart`, `EINTR partial`,
  `SA_RESTART`, `short read write signal`, `restart syscall bytes transferred`.
  Hits are #3494 (socket timeouts), #3146 (short TCP reads), #3191 (sendfile
  short writes), #1542 (sendfile truncation), #1831/#1577/#2461/#1598 (restart
  plumbing). **None reports restart replaying committed read/write bytes.**

**Commits / blame.** Not available: the run's checkout is a single squashed
baseline commit (`git rev-list --count HEAD` = 1, no remotes).

**Comments / docs.** `error.rs:155`: `ERESTARTSYS = 512, /* Restart of an
interrupted system call. For kernel internal use only. */`. `signal/mod.rs:57`:
"We should never return `ERESTARTSYS` to the userspace." No comment anywhere
states the "EINTR implies zero progress" contract that §1.4 shows the code
relies on. `signal/mod.rs:50-53` carries an unrelated FIXME about one-signal-per-trap.

**Tests.** No existing test exercises a signal against a regular-file
`read`/`write`. The upstream regression test that does exist for this mechanism
(#3576's `syscall_restart.c`) uses pipes and sockets with 1-byte transfers.

**Upstream state.** `asterinas/asterinas@main` as of 2026-08-24
(`2bcd1ae127794d2d5c49019cd8ace1ff4dbf8e98`) still carries the identical
`map_err(EINTR => ERESTARTSYS)` at `kernel/core/src/syscall/read.rs:36-39`.
PR #3576 is still open/unmerged. The baseline under test is current.

---

## Step 3 — Known-status / precedent

The closest prior report is **PR #3576**. Same site (`syscall/read.rs`,
`write.rs`), same code line. But the *defect it reports* is which calls get
restarted (missed restarts; wrongly-restarted socket-with-timeout calls) — not
what state a restart resumes from. Applying the Step-3 bar ("the SAME mechanism
at the SAME site"; a same-shape precedent must have each of its prerequisites
re-verified): #3576 does not report, test, or fix CR-1's mechanism, and after
#3576 lands the errno would still carry no byte count. Recorded as **NEW for
this mechanism**, citing #3576 as related-but-different.

No Specula dataset entry matches (`specula-org/specula-case-studies` code search
for `ERESTARTSYS` / `asterinas restart` → 0 hits; the local submodule is
unchecked-out).

Pre-filter verdict: **not dropped.** Code-review-sourced, but no existing
issue/PR/CVE reports this exact defect. Proceed to Phase 2.

---

## Carry-forward for Phase 2

The claim decomposes into:

* **H1 (precondition)** — can a regular-file `read`/`write` be interrupted, i.e.
  can the backend hand `EINTR` to `read.rs:37` / `write.rs:37`? §1.3 says no.
  Must be tested empirically under signal pressure, on ext2 buffered, ext2
  `O_DIRECT`, and ramfs.
* **H2 (consequence)** — if a restart did occur after committed progress, is the
  commit replayed? §1.2 says yes, sharply for `O_APPEND`. Must be measured as
  `file size == sum of returned counts` and `shared offset == sum of returned
  counts`.
* **Positive control** — the same `read.rs` arm must be shown live on a backend
  that really blocks (pipe), otherwise a clean regular-file result is vacuous.

---

## Phase 2 result (recorded here for the evidence trail)

Test: `.specula-output/repro/test_bugCR-1_restart_progress_provenance.{c,sh}`
Command: `./test_bugCR-1_restart_progress_provenance.sh`
Kernel: pristine baseline (`git checkout -- kernel/` before every build; the
driver prints the resulting empty `git status -- kernel/`).
Levels reached: 0 and 1. Level 2 inadmissible, Level 3 not applicable — the
reasons are printed by the script itself under "== Escalation ladder ==".

Guest (Asterinas, SMP=2, ext2 on virtio-blk + ramfs), three independent runs,
all identical:

```
CR1_CTRL_PIPE restart=1 ret=1  errno=0 handler_hits=130 verdict=RESTARTED
CR1_CTRL_PIPE restart=0 ret=-1 errno=4 handler_hits=2   verdict=EINTR
CR1_PROBE  ramfs      mode=0 wr_eintr=0 rd_eintr=0 sigs_sent=32342 handler_hits=326 verdict=UNINTERRUPTIBLE
CR1_PROBE  ext2       mode=0 wr_eintr=0 rd_eintr=0 sigs_sent=44585 handler_hits=315 verdict=UNINTERRUPTIBLE
CR1_PROBE  ext2direct mode=1 wr_eintr=0 rd_eintr=0 sigs_sent=20823 handler_hits=344 verdict=UNINTERRUPTIBLE
CR1_PROBE  ext2sync   mode=2 wr_eintr=0 rd_eintr=0 sigs_sent=38554 handler_hits=340 verdict=UNINTERRUPTIBLE
CR1_APPEND ramfs/ext2/ext2direct/ext2sync  returned=8388608 size=8388608  verdict=NO_REPLAY
CR1_OFFSET ramfs/ext2/ext2direct/ext2sync  returned=8388608 offset=8388608 size=8388608 verdict=NO_DOUBLE_ADVANCE
```

Reading:

* `CR1_CTRL_PIPE` is the positive control. `restart=1 => RESTARTED` proves the
  `read.rs:37` `EINTR => ERESTARTSYS` arm and the `signal/mod.rs:145` SA_RESTART
  rewind are both live on this kernel, with 130 signals landing inside one
  blocked `read`. `restart=0 => errno 4` proves the non-restart half.
  Without this control the regular-file result would be vacuous.
* **H1 is false on regular files.** 384 large `read`/`write` calls per backend
  under 20k-52k `pthread_kill`s and 315-344 confirmed handler entries produced
  `wr_eintr=0 rd_eintr=0` on every backend and every mode (buffered, `O_DIRECT`
  bio wait, `O_SYNC` write-back wait). The regular-file path never hands `EINTR`
  to the wrapper, matching §1.3.
* **H2 could not be exercised**, precisely because H1 never fires. `NO_REPLAY`
  (`size == sum of returned counts` for 128 `O_APPEND` writes on a shared
  open-file description) and `NO_DOUBLE_ADVANCE` (`offset == size == sum`) hold
  on every backend. Asterinas matches the Linux reference line for line.

The finding's structural reading of the code (§1.1, §1.2) is accurate; its
trigger has no producer in the kernel it describes.
