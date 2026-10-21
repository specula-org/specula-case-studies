# MC-5 — Investigation (Phase 1, evidence only)

Finding: "Vectored I/O is not atomic on a shared open-file description".
Source: model checking, invariant `MCLaterIovecFaultLinearizable`,
cfg `MC_hunt_finding_mc1_later_iovec_fault.cfg`,
CE `spec/output/MC_hunt_finding_mc1_later_iovec_fault_bfs.out`.

Baseline: worktree commit `2cd6429` = "Asterinas 604948581 pristine baseline".
Line numbers below are from the PRISTINE tree (`git show HEAD:<path>`), because
the working tree carries Specula trace instrumentation that shifts lines.

## Step 1 — Code audit (facts)

### Cited sites

`kernel/core/src/syscall/preadv.rs` — `do_sys_readv` (pristine lines 133-181):

```rust
let mut writer_array = VmWriterArray::from_user_io_vecs(&user_space, io_vec_ptr, io_vec_count)?;
for writer in writer_array.writers_mut() {
    debug_assert!(writer.has_avail());
    // TODO: According to the man page ... readv must be atomic,
    // but the current implementation does not ensure atomicity.
    // A suitable fix would be to add a `readv` method for the `FileLike` trait,
    // allowing each subsystem to implement atomicity.
    match file.read(writer) {
        Ok(read_len) => total_len += read_len,
        Err(_) if total_len > 0 => break,
        Err(err) => return Err(err),
    }
    if writer.has_avail() { break; }
}
```

`kernel/core/src/syscall/pwritev.rs` — `do_sys_writev` has the identical shape
with `file.write(reader)`.

`kernel/core/src/fs/file/inode_handle.rs` — `impl FileLike for InodeHandle`:

- `read` (pristine 271-291): `let mut offset = self.offset.lock();` (285)
  `let len = file_ops.read_at(*offset, writer, status_flags)?;` (287)
  `*offset += len;` (288) — guard dropped on return.
- `write` (pristine 293-321): `let mut offset = self.offset.lock();` (308)
  `let len = file_ops.write_at(*offset, reader, status_flags)?;` (317)
  `*offset += len;` (318) — guard dropped on return.
- The shared offset is `offset: Mutex<usize>` (line 34).

So the shared-offset critical section spans **exactly one scalar backend call**.
A vectored call is N independent critical sections with the lock released
between them.

`ostd/src/sync/mutex.rs` — `unlock()` does `release_lock(); queue.wake_one();`.
The lock is dropped *before* the wake work runs, so the inter-entry window in
which the offset lock is free is not a few instructions; it spans the wake path
of the previous unlock plus the dyn-dispatch return and loop bookkeeping.

### Call chain (all reachable from unprivileged user space)

`sys_readv` / `sys_writev` (syscall table)
  → `do_sys_readv` / `do_sys_writev` (preadv.rs / pwritev.rs)
  → `FileLike::read` / `FileLike::write` on `InodeHandle`
  → `self.offset.lock()` → `file_ops.read_at/write_at` → `*offset += len` → unlock.

A second thread/process holding a dup()ed descriptor for the same open file
description reaches the same `Mutex<usize>` through the ordinary
`read`/`write`/`readv`/`writev` paths. No privilege, no failpoint, no special
mount is required.

### Linux contract being compared against

Linux takes `f_pos_lock` for the whole vectored call: `fdget_pos()` locks
`file->f_pos_lock` when `FMODE_ATOMIC_POS` is set (set for regular files in
`do_dentry_open`) and `file_count(file) > 1` (true after a `dup`). Therefore on
Linux one `readv` returns exactly one contiguous file range, and one `writev`
deposits exactly one contiguous file range, relative to any other f_pos user of
the same description. `man 2 readv`: "the data transfers performed by readv()
and writev() are atomic".

### Trigger scenario (concrete, natural)

1. `fd = open("/f", O_RDWR)`; `fd2 = dup(fd)` — one open file description, two
   descriptors, `file_count > 1` on Linux.
2. Thread A: `readv(fd, iov, 64)` with 64 x 4 KiB buffers.
3. Thread B (other CPU): ordinary `read(fd2, buf, 64)` (or `write(fd2, ...)`)
   in a loop.
4. B's call is granted the offset mutex in one of the 63 inter-entry windows of
   A's `readv`, advances the shared offset, and A's remaining entries then read
   from the advanced offset.
5. A's `readv` returns a buffer whose bytes are **not one contiguous file
   range** — there is a hole exactly the size of B's transfer.

The same shape with `writev` sandwiches B's bytes between two of A's iovec
entries, so the bytes A wrote are not one contiguous file range either.

### Safeguards found (recorded, not dismissed)

- None on this path. `do_sys_readv`/`do_sys_writev` take no cross-entry lock,
  and `InodeHandle` exposes no vectored entry point that could hold one.
- `get_file_fast!` only pins the `Arc<dyn FileLike>`; it does not serialize.
- `FileLike` has no `readv`/`writev` method at all (the TODO says adding one is
  the fix), so no subsystem can currently opt into atomicity.

## Step 2 — Developer-knowledge search (evidence, not classification)

- **Source comments.** `preadv.rs` and `pwritev.rs` both carry the verbatim
  TODO quoted above: "readv must be atomic, but the current implementation does
  not ensure atomicity." `inode_handle.rs` carries a separate FIXME about
  `O_APPEND` concurrency (different aspect: append-range atomicity).
- **Upstream HEAD.** `gh api repos/asterinas/asterinas/contents/kernel/core/src/syscall/preadv.rs`
  (fetched 2026-08-24) still contains the same per-entry loop and the same TODO
  — unchanged, unfixed.
- **Commits.** The confirmation worktree is a squashed pristine baseline, so
  local blame is unavailable. Upstream commit listing for
  `kernel/core/src/syscall/preadv.rs` (`gh api .../commits?path=...`) shows only
  `819e7a82` (2026-07-19, assembler refactor) and `b9cfb5cc` (2026-08-12,
  visibility) — no atomicity work.
- **PRs.** `#2230` "Fix partial writes and reads in writev and readv" (merged
  2025-07-02) only changed short-count reporting (`Err(_) if total_len > 0 =>
  break`), not serialization. `#3720` "Fix user buffer validation for iovec
  entries" (open) only touches `util/iovec.rs` bounds checking.
- **Tests.** No regression test under `test/initramfs/src/regression/` asserts
  vectored atomicity or exercises two threads on one shared open file
  description.

## Step 3 — Known-status / precedent

Issue-tracker search (`gh search issues/prs --repo asterinas/asterinas`) for
`readv`, `writev`, `iovec`, `readv atomic`, `writev atomicity`, `atomicity`,
`f_pos`, `file offset lock`, `shared file description`, `concurrent read
offset`, covering open AND closed/merged items:

- `#711` (OPEN) "Wrong behavior when `EFAULT` occurs in the middle of I/O
  system calls" — scalar `read`/`write` partial-copy fault semantics. Different
  mechanism; says nothing about shared-offset serialization across iovec
  entries.
- `#1554` (CLOSED) "PIPE implementation does not guarantee atomic writes for up
  to PIPE_BUF bytes" — pipes, different site and different guarantee.
- `#1245`, `#3720` — iovec parsing/bounds. Excluded by the campaign scope and a
  different mechanism.
- `#1938` "SMP system call test aborts" — unrelated failure mode.

**No issue, PR, CVE or advisory reports the shared-open-file-description
non-atomicity of regular-file `readv`/`writev`.** The only prior art is the
in-source TODO, which per the skill is developer *suspicion*, not a filed
report, and therefore does not make this KNOWN.

Novelty: **NEW**.
Pre-filter: not applicable — the finding is MC-sourced with a real
counterexample, so it proceeds to Phase 2 regardless.

## Counterexample mapping (what Phase 2 must match)

`MC_hunt_finding_mc1_later_iovec_fault_bfs.out`, 23 states:

| CE step | meaning |
|---|---|
| S2 `MCSysWriteStart(t1,...)` | t1 begins a shared-offset `write` |
| S3 `MCDoSysReadvStart(t2,...)` | t2 begins `readv` (VectorLength=2) |
| S7-S9 | t2 entry 1 copies, `reported[t2]="Complete"` |
| S10 | t2 releases the offset lock; `ofdOffset` 0 -> 2 |
| S11-S12 | **t1 acquires the offset lock mid-vector**; `ofdOffset` 2 -> 4; `vectorIntervened[t2] = TRUE` |
| S15 | t2 advances to `vectorIndex = 2` and re-acquires at the *moved* offset |
| S19 `MCFileOpsReadAtCopyFaultPositive(t2)` | t2's later entry faults after positive copy |
| S23 | t2 returns `ShortSuccess` with `reportedTotal = 2` while `copiedTotal = 3` |

The invariant `MCLaterIovecFaultLinearizable` fires on the conjunction:
`vectorIntervened` (S12) plus a later-entry positive-progress fault whose bytes
are not reported (S23). The **intervention** (S10-S15) is the part that is a
pure shared-offset serialization fact and needs no fault injection; it is what
Phase 2 targets at Level 0.

## Phase 2 result (recorded here for the evidence trail)

Test: `repro/test_bugMC-5_vector_atomicity.c` + `.sh`. Escalation **Level 0**
only — public syscalls, pristine kernel (`git checkout -- kernel/`; `git status
--short -- kernel/` printed nothing but the two unreferenced untracked
`tla_trace.rs` leftovers), SMP=2, ramfs root.

| CASE | what it does | Linux | Asterinas |
|---|---|---|---|
| A | `readv(64x4K)` vs competing `read` on the dup'ed fd | ATOMIC 0/100 | VECTOR_TORN 71/100, 191 gaps |
| B | `readv(64x4K)` vs competing `write` (the CE shape) | ATOMIC 0/100 | VECTOR_TORN 89/100, 153 gaps |
| C | `writev(64x4K)` vs competing `write` | ATOMIC 0/100 | VECTOR_TORN 100/100, 338048 foreign bytes inside the vector range |
| D | positive control: `readv` replaced by the per-entry `read` loop `do_sys_readv` performs | VECTOR_TORN 100/100 | VECTOR_TORN 95/100 |
| E | later iovec entry faults after positive copy (CE S19/S23) | ret=8192 = deposited = offset | ret=4096, deposited=8192, offset=+4096 |

CASE D is the detector's positive control: decomposing `readv` into per-entry
scalar reads tears on Linux too, which is exactly the shape of `do_sys_readv`
and proves the CASE A/B detector is not blind.

Pristine line numbers of the defect: `preadv.rs:156` (loop) / `165` (per-entry
`file.read`), `pwritev.rs:152` / `161`, and the per-call offset critical
section at `inode_handle.rs:285-288` (read) and `308-318` (write).
