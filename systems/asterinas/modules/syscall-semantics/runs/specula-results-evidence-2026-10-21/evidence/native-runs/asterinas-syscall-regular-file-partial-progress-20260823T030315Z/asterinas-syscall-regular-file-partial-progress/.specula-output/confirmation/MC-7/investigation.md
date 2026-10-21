# MC-7 — Investigation record (Phase 1, evidence only)

Finding: "An O_APPEND fault leaves the shared offset at EOF"
Source: model checking, invariant `MCSharedOffsetMatchesReported`,
config `MC_hunt_scenario_5_append_failure.cfg`,
counterexample `spec/output/MC_hunt_scenario_5_append_failure_bfs.out`.

Baseline: `2cd64291` = upstream Asterinas `604948581` (2026-08-08).

## Step 1 — Code audit

### Cited site

Pristine baseline `kernel/core/src/fs/file/inode_handle.rs:308-320`
(`impl FileLike for InodeHandle :: fn write`); the same lines are 347-397 in the
trace-instrumented worktree, where the assignment is line 361:

```rust
let mut offset = self.offset.lock();

// FIXME: How can we deal with the `O_APPEND` flag if `open_file` is set?
if status_flags.contains(StatusFlags::O_APPEND) && self.open_file.is_none() {
    // FIXME: `O_APPEND` should ensure that new content is appended even if another process
    // is writing to the file concurrently.
    *offset = self.path().size();          // line 314 — publishes EOF into the OFD offset
}

let len = file_ops.write_at(*offset, reader, status_flags)?;   // line 317 — `?` returns early
*offset += len;

Ok(len)
```

`self.offset: Mutex<usize>` (`inode_handle.rs:34`) is the open-file-description
offset: it is per-`InodeHandle`, so `dup`, `dup2`, `fcntl(F_DUPFD)` and `fork`
all share it. The `?` on line 317 propagates the backend error while `*offset`
already holds EOF; dropping the `MutexGuard` releases the lock but keeps the
written value. There is no restore of `old_offset` on the error arm.

### Call chain (all reachable from unprivileged userspace)

- `sys_write` (`kernel/core/src/syscall/write.rs:10-46`) → `file.write(&mut reader)`
  → `InodeHandle::write`. The error is only remapped `EINTR`→`ERESTARTSYS`
  (write.rs:35-38); nothing repairs the offset.
- `sys_writev` → `do_sys_writev` (`kernel/core/src/syscall/pwritev.rs:134-176`)
  calls `file.write(reader)` once per iovec, so each entry re-enters the same
  append repositioning.
- Observers of the same field: `InodeHandle::seek` →
  `do_seek_util(&self.offset, ...)` (pristine `inode_handle.rs:417-435`), i.e.
  `lseek(fd, 0, SEEK_CUR)`; and `InodeHandle::read` (pristine `inode_handle.rs:273-288`),
  which reads at `*offset` — an `O_RDWR|O_APPEND` description reads from the
  shared offset because `O_APPEND` only constrains writes.

### Linux contract being compared against

Linux resolves `O_APPEND` into the *local* `kiocb.ki_pos`
(`generic_write_checks`), never into `file->f_pos`. `fs/read_write.c` copies it
back only after progress: `new_sync_write` does `if (ret > 0) *ppos = kiocb.ki_pos;`
and `ksys_write` does `if (ret >= 0 && ppos) f.file->f_pos = pos;` over a local
`pos`. A failed `write()` therefore leaves `f_pos` exactly where it was.
Verified empirically — see `repro/out_bugMC-7/linux.log`.

### Trigger scenario (constructed, all public API)

1. Create a regular file with 4096 bytes.
2. `open(path, O_RDWR|O_APPEND)`; `dup(fd)` → a second descriptor onto the same
   open-file description (a `fork`ed child gets the same sharing).
3. `lseek(fd, 0, SEEK_SET)` → shared offset 0.
4. `mmap` two anonymous pages, `mprotect` the first `PROT_NONE`, and
   `write(fd, that_page, 4096)`. The copy from user faults having moved zero
   bytes; the syscall returns `-1/EFAULT`.
5. `lseek(dupfd, 0, SEEK_CUR)` and `read(dupfd, ...)` now observe the offset.

Nothing in the path is privileged, and the faulting buffer is an everyday
condition (partially unmapped user buffer).

### Safeguards / masks looked for

- `sys_write` does not restore the offset (write.rs:40-45 only fires
  `notify::on_modify` when `write_len > 0`).
- No later re-sync exists: the offset is only rewritten by the next `write` on
  the same description (append recomputes EOF, so writes stay correct), by an
  explicit `lseek`, or by a successful non-append write. Reads and
  `lseek(SEEK_CUR)` consume the corrupted value directly.
- No caller-side guard: `InodeHandle::write` is the VFS entry point for every
  `write`/`writev` on a regular file.

## Step 2 — Developer-knowledge search

- **Comments at the site.** Two `FIXME`s (inode_handle.rs:310, 312 pristine).
  They cover (a) `O_APPEND` when `open_file` is set and (b) concurrent-append
  range atomicity. Neither mentions the offset being left at EOF when the write
  fails. The campaign brief also lists append-range atomicity as out of scope
  and explicitly says these comments must not be reported as findings — this
  finding is a different mechanism (error-path state, not concurrency).
- **Git history.** The run's checkout is a single squashed baseline commit, so
  `git blame` carries no upstream authorship; upstream history was consulted
  through the GitHub tracker instead.
- **Issue tracker (`gh api search/issues`, repo `asterinas/asterinas`).**
  Queries: `O_APPEND`; `file offset EFAULT write`; `offset not restored write
  error`; `append offset error write fails`; `lseek offset after failed write`.
  Hits reviewed:
  - **PR #3481 "Fix inode append and memfd seal races"** — OPEN, created
    2026-06-29, `mergedAt: null`, still open as of 2026-08-24 and absent from
    the 2026-08-08 baseline. Its stated subject is TOCTOU races between
    `path.size()` and the filesystem write (exactly the existing `FIXME`), and
    it moves `O_APPEND` resolution into the fs layer via a new
    `WriteOffset::Append`. As a side effect its diff reorders `InodeHandle::write`
    to `let len = file_ops.write_at(...)?;` *before* `*offset = self.path().size();`,
    which would also remove the defect described here. The PR neither reports
    nor mentions the failed-write offset behaviour.
  - **PR #3086 "Fix positional I/O error handling for `pread`/`pwrite`"** —
    MERGED 2026-04-09, about `ESPIPE`/`EBADF` ordering on non-seekable files.
    Different mechanism, different site.
  - Issues #2291, #1558, #3071, #2564, #3084, #36 — unrelated to this site.
- **Tests.** `grep -rn O_APPEND test/` finds only
  `io/file_io/fcntl_status_flags.c:120` (flag round-trip through `F_SETFL`) and
  `fs/ext2/open_unlink.c:75` (append-mode open of an unlinked file). No test
  asserts what the offset does after a failed write.

## Step 3 — Known-status / precedent

No filed issue/PR/CVE/advisory reports **this** defect (the shared OFD offset
being left at EOF when the append write reports no progress). The one PR that
touches these lines, #3481, is unmerged and reports a different defect
(size TOCTOU). Per the skill, a same-site refactor that would incidentally fix
the bug, and a developer `FIXME` about a different aspect, are not "already
reported". → **Novelty: NEW.**

Pre-filter does not apply: the finding is MC-sourced with an actual
counterexample, so it proceeds to Phase 2 regardless.

## Counterexample ↔ implementation correspondence

`MC_hunt_scenario_5_append_failure_bfs.out`, invariant
`MCSharedOffsetMatchesReported`:

| CE state | action | `ofdOffset` | `reported` | maps to |
|---|---|---|---|---|
| 1 | initial | 0 | Zero | `open` + `lseek(0)`; `fileSize = 2` |
| 2 | `MCSysWriteStart(t1,"Ext2Buffered","Complete",TRUE,…)` | 0 | Zero | `sys_write` on an `O_APPEND` fd |
| 3 | → `ChooseAppendStart` | 0 | Zero | offset mutex acquired |
| 4 | append resolves | **2** | Zero | `*offset = self.path().size()` (line 314) |
| 7 | `MCFileOpsWriteAtCopyFaultZero(t1,…)` | 2 | Zero | copy from user faults at 0 bytes |
| 9-10 | `InodeReturn` → `SyscallDispatch` | **2** | **Zero** | `?` returns `Err`, offset keeps EOF |

The real kernel already produced the identical shape during harness tracing —
`.specula-output/traces/ramfs_zero_append.ndjson`:
`InodeHandleWriteChooseAppendStart` moves `ofd_offset` 0 → 4, then
`FileOpsWriteAtCopyFaultZero`, then `InodeHandleWriteReturnError` /
`SysWriteReturn` with `result: "Fault"`, `reported_total: 0`, and
`ofd_offset: 4`. The counterexample's backend is `Ext2Buffered`, the trace's is
`Ramfs`; the append repositioning sits above both, in `InodeHandle::write`.

## Open question carried into Phase 2

The trace proves the internal state; Phase 2 must show a *real consumer*
observing the wrong outcome through public syscalls, on both backends, against
the Linux control.

---

## Phase 2 outcome (recorded here for the evidence trail)

Level 0 (pure black-box) triggered it; Levels 1-3 were not needed.
Test: `repro/test_bugMC-7_append_offset_on_fault.{c,sh}`;
output: `repro/out_bugMC-7/{driver,asterinas,linux,guest,build}.log`.
Verdict: **REPRODUCED** — see the confirmation entry.

---

## Turn 2 — Challenger (Agent B) adversarial audit

Independently re-verified, not taken from A's report.

### Reachability — attacked, survived

- **Level 0 is genuine.** `driver.log:18-19` prints `baseline commit:
  2cd64291cf4e11283eeabb4e4e953cb8be971cb9` and an **empty** `git status --short --
  kernel/`. `git diff --stat -- kernel/` on the worktree is empty now too.
- **The untracked `tla_trace.rs` files are dead.** `grep -rn tla_trace --include="*.rs"
  kernel/` matches only the two files themselves — no `mod`, no `#[path]`, no `include!`.
  They are never compiled.
- **`ENABLE_SPECULA_TRACE` never reaches the kernel.** It is consumed only by
  `Makefile:66,119` (sets `--init-args`) and `test/initramfs/Makefile:10,60`
  (`--arg enableSpeculaTrace`). Initramfs-only; the kernel crate is unmodified.
- **The fault is inside the declared fault model.** `mprotect(PROT_NONE)` on the first
  page is the campaign's "any user copy may complete zero ... and then fault".
- **CE correspondence re-derived from the raw trace**
  (`MC_hunt_scenario_5_append_failure_bfs.out`): `ofdOffset` 0→2 at State 4,
  `MCFileOpsWriteAtCopyFaultZero` at State 7, and States 7/10 hold `ofdOffset = 2`,
  `reported = "Zero"`, `fileSize = 2` (unchanged). Same shape as ext2 case A
  (off 0→4096 = size, rc=-1, size unchanged).

### Consequence — masks hunted, none found

| Candidate mask | Result |
|---|---|
| Syscall-layer restore | None. `syscall/write.rs:31-43` only remaps `EINTR`→`ERESTARTSYS` and `?`-propagates; `notify::on_modify` is gated on `write_len > 0` and touches no offset. |
| "Nothing reads the value" | False. Every `self.offset` access in `inode_handle.rs`: 91-92 (`offset()`), 136 (`readdir`), 287 (`read`), 425/435 (`seek`→`lseek`). Two are the consumers the repro exercises. |
| Later re-sync | None. No path rewrites the offset except the next read/write/lseek on the same description — each *consumes* the wrong value first. |
| "O_APPEND makes the offset don't-care" | False for reads. `O_RDWR\|O_APPEND` (glibc `fopen(...,"a+")`) reads at the shared offset. ext2 case A: `read(dupfd,…,16)` → 0/EOF vs Linux 16 bytes, with `size_after == size_before == 4096` (file intact — the offset is the sole cause). |
| POSIX-literalist defence | Strongest objection available, and it fails. POSIX `write()` says the offset "shall be set to the end of the file prior to each write", which pedantically could excuse parking it at EOF. But Asterinas' contract is Linux ABI compatibility (`README.md:33,55`) and the campaign brief makes Linux the contract. Rebuilt the identical `.c` myself on Linux 7.1.9: `off_after=0`, `dupfd_read=16`. Divergence is real under the governing contract. |
| "Rarely noticed ⇒ masked" | Not a mask. In append-only workloads the offset already sits at EOF so damage is invisible; the `a+` pattern (read from 0, append at end) puts it at 0 — exactly the repro's setup. Unnoticed ≠ masked; nothing prevents the harm. |

### Independent verification runs

Rebuilt `test_bugMC-7_append_offset_on_fault.c` from source and ran it on the host
(Linux 7.1.9) — the binary is not rigged: `bugs=0` on Linux, `bugs=2` on Asterinas from
identical source.

```
MC7_CASE A_append_zero_fault ... rc=-1 errno=14 off_before=0 off_after=0 off_expected=0 dupfd_read=16 dupfd_bytes=[AAAAAAAAAAAAAAAA]
MC7_OK A_append_zero_fault
MC7_END bugs=0
```

### Novelty — re-checked with queries A did not run

`O_APPEND offset write fail`, `f_pos EFAULT`, `"file offset" append failed write`,
`inode_handle offset append`, `write error offset advanced` — nothing reports this
mechanism. PR #3481 re-checked live: `state=OPEN merged=null closed=null updated=2026-07-21`.
**Current upstream master** fetched via `gh api repos/asterinas/asterinas/contents/...`:
`inode_handle.rs:310-318` is byte-identical to the baseline — the defect is live on HEAD
today, not a stale-baseline artifact. `NEW` stands. (Moot for the verdict: the known-drop
pre-filter is code-review-only; an MC finding with a real CE proceeds regardless.)

### Repro corrections demanded (scope precision, not verdict)

1. **Do not lean on the ramfs rows.** `/tmp` case A reports `rc=-1` with
   `size_after=8192`, and case D `size_after=12288` — the file grew despite the failed
   write. That is committed-progress-without-report, a *different* mechanism, not the
   offset defect. The clean demonstrator is **ext2 case A** (size unchanged, offset
   0→4096, consumer reads EOF).
2. **ext2 case D carries a second divergence too** — Asterinas returns `-1/EFAULT` where
   Linux short-writes 4096. Fine as corroboration that the append assignment moves the
   offset, but it must not be cited as MC-7's harm.

Neither correction touches the headline claim, which stands on ext2 case A alone.

**Challenger verdict: REPRODUCED (conceded).**
