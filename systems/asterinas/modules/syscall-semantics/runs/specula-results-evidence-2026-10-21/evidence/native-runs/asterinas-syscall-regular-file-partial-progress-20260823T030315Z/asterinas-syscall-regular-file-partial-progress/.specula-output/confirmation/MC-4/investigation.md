# MC-4 investigation — ramfs publishes file size before a write that copies no bytes

Baseline: `2cd64291cf4e11283eeabb4e4e953cb8be971cb9` (Asterinas upstream `604948581`).
All line numbers below are from the **pristine** tree (`git show HEAD:<path>`), not
from the Specula-instrumented worktree the finding cited.

## Step 1 — Code audit (facts)

### Cited site

`kernel/core/src/fs/fs_impls/ramfs/fs.rs:721-757`, `RamInode::write_at`:

```rust
let mut page_cache = self.inner.as_file().unwrap().lock();      // 731
let mut inode_meta = self.metadata.lock();                      // 733
let file_size = inode_meta.size;                                // 734
let write_len = reader.remain();                                // 735
let new_size = offset + write_len;                              // 736  <- requested END
let should_expand_size = new_size > file_size;                  // 737
let new_size_aligned = new_size.align_up(BLOCK_SIZE);           // 738
inode_meta.set_mtime(now);                                      // 739
inode_meta.set_ctime(now);                                      // 740
if should_expand_size {
    inode_meta.size = new_size;                                 // 742  <- PUBLISHED
    inode_meta.blocks = new_size_aligned / BLOCK_SIZE;          // 743
}
drop(inode_meta);                                               // 745
if should_expand_size {
    page_cache.resize(new_size_aligned, file_size)?;            // 748
}
page_cache.write(offset, reader)?;                              // 750  <- FALLIBLE COPY
write_len                                                       // 752  <- always the request
```

The size published at :742 is `offset + reader.remain()` — the **requested end**,
decided before a single byte is copied. The user copy happens at :750 and can
fail; the `?` propagates the error out of `write_at` with **no rollback** of
:742/:743. There is no guard, no `commit()`, no restore path in this function.

Two distinct ways to reach a size increase with zero committed bytes:

1. **Copy fault with zero bytes copied.** `page_cache.write` →
   `Vmo::write` (`kernel/core/src/vm/page_cache/vmo/mod.rs:570`) → ramfs has no
   backend, so `write_anonymous_pages` (:671) → `page.writer().skip(..).write_fallible(reader)?` (:690).
   `write_fallible` returns `Err((Error, usize))`, and the `From<(ostd::Error, usize)>`
   impl at `kernel/core/src/error.rs:209-214` drops the count, so the error surfaces
   as a plain `Err`. With a buffer whose first byte is unreadable, zero bytes are
   copied and `write_at` returns `Err(EFAULT)` — after :742 already grew the file.
2. **Zero-length write past EOF.** `write_len == 0` ⇒ `new_size == offset`. If
   `offset > file_size`, :737 is true, :742 publishes `offset`, :750 copies nothing
   and returns `Ok`, and `write_at` returns `Ok(0)`. The file grew on a syscall
   that reported success and moved no data.

### Call chain (reachable from unprivileged user space, no special setup)

- `sys_pwrite64` (`kernel/core/src/syscall/pwrite64.rs:34-35`) — builds a `VmReader`
  over the raw user range (`user_space.reader(ptr, len)`; **range check only, no
  page probing**) and calls `file.write_at(offset, &mut reader)`.
- `InodeHandle::write_at` (`kernel/core/src/fs/file/inode_handle.rs:334-355`) → `file_ops.write_at(...)`.
- `sys_write` → `InodeHandle::write` (:293-321) — same `file_ops.write_at`, offset
  taken from (and, for `O_APPEND`, set to) the shared open-description offset.
- `FileOps::write_at` for a ramfs regular file is the audited function.

So both positional (`pwrite64`) and shared-offset (`write`, `O_APPEND` write)
paths land on the same publication.

### Consumers of the published size

- `sys_fstat`/`sys_stat`/`sys_statx`: `st_size` comes straight from the inode
  metadata (`kernel/core/src/syscall/stat.rs:200`).
- `RamInode::read_at` (`fs.rs:695-718`) clamps the read to `self.size()`, so any
  size increase turns the never-written range into readable zero bytes instead of EOF.
- `lseek(SEEK_END)` resolves against the same size.

### Safeguards found

None. No rollback guard exists on the ramfs write path, nothing re-derives the
size from committed data, and ramfs has no writeback/`fsck` path that could later
correct it. `page_cache.resize` at :748 grows the VMO *before* the copy (required,
because `Vmo::write` clamps to `self.size()`), and is likewise never undone.

### Trigger scenario (constructed, natural)

An unprivileged process writes into a ramfs/tmpfs file through a buffer whose
first page is not currently readable — a `PROT_NONE`/guard page, a lazily-faulted
region another thread just `mprotect`ed or unmapped, or a bad pointer. The write
extends the file. It fails with `EFAULT`, and the file is left longer than it was.

## Step 2 — Developer-knowledge search (evidence, verbatim)

- **Local history is unusable**: the run's checkout is a single squashed baseline
  commit (`git log -- kernel/core/src/fs/fs_impls/ramfs/fs.rs` → one commit), so
  blame/messages were taken from the upstream tracker instead.
- **No comment, TODO or FIXME** anywhere in `ramfs/fs.rs` touches the ordering
  (the file's only TODOs are at :68 tmpfs constructor and :1458 dentry lookup).
- **No test** in the tree asserts the current behavior. The Specula harness
  scenario `ramfs_zero_append` performs exactly `pwrite(fd, buf, 0, 4*PAGE)` and
  asserts only the return value, never the resulting size.
- **Upstream issue #711**, "Wrong behavior when `EFAULT` occurs in the middle of
  I/O system calls" (OPEN, P4, opened 2024-03-23, last touched 2026-07-14): about
  a *different* mechanism — Asterinas returns `EFAULT` instead of the short count
  when a copy faults after a positive prefix. Maintainer `lrh2000`: *"It seems that
  we do not allow partial reads or writes in our page cache implementation."*
  Nothing in the issue mentions inode size, and its fix (propagating short counts)
  would not touch either MC-4 path: a zero-copy fault still legitimately returns
  `EFAULT`, and the zero-length case has no fault at all.
- **Upstream PR #3297**, "Introduce `InodeRollbackGuard` to handle write errors more
  elegantly for ext2" (OPEN draft, 2026-05-29): the maintainers' own statement of
  what correct looks like — a guard that *"captures the current state before
  fallible operations and restores it on error, with `commit` finalizing success"*,
  restoring *"page-cache capacity and block mappings to the captured `old_size`"*.
  Files touched: `ext2/inode/{file,dir/mod,symlink}.rs` — **ramfs is not in scope**.
  The PR reasons case-by-case about which partial effects Linux does and does not
  roll back, i.e. rollback-on-write-failure is treated as the intended semantics.
- Referenced-as-context issues **#1554** (pipe `PIPE_BUF` atomicity, CLOSED) and
  **#3181** (`sendfile` drops data after a short PTY write, CLOSED) are unrelated
  to this site.

Note on scope of the finding text: the timestamp half of the finding's summary
("timestamps published before copy") is **not** a Linux deviation — Linux also
stamps mtime/ctime before the copy (`__generic_file_write_iter` calls
`file_update_time()` ahead of `generic_perform_write`). Only the **size**
publication deviates. This was not tested or reported as part of the bug.

## Step 3 — Known status / precedent

Searched `asterinas/asterinas` issues **and** PRs (open and closed/merged) via the
GitHub API: `ramfs`, `EFAULT`, `write_at`, `partial write`, `inode size write fail`,
`file size not restored`, `size before copy`, `zero-length write`, `write extends
file`, `rollback ramfs`, `tmpfs file size`, `st_size incorrect`, `metadata rollback
write`, `inode size rollback`; plus every merged PR with `ramfs` in the title
(newest: #2385, 2025-08-29).

- Nothing reports the ramfs size-publication-before-copy defect.
- #711 is a different mechanism (discarded partial progress), #3297 is the same
  *shape* at a **different site** (ext2) and is still an unmerged draft — per the
  skill, a same-shape precedent at a different site is not the same bug.
- Upstream `main` fetched today (`/repos/asterinas/asterinas/contents/kernel/core/src/fs/fs_impls/ramfs/fs.rs?ref=main`)
  is byte-identical at lines 721-757 → **unfixed upstream**.

⇒ `Novelty: NEW`. Source is MC (a real TLC counterexample exists), so the
code-review × known pre-filter does not apply in any case; proceed to Phase 2.

## Phase 2 — Reproduction (Level 0)

Test: `.specula-output/repro/test_bugMC-4_ramfs_size_publication.{c,sh}`; raw
outputs under `repro/out_bugMC-4/`. Differential: the *same* C binary runs on
Linux tmpfs (control) and on an Asterinas guest built from the **pristine**
baseline kernel (`git checkout -- kernel/` before the build; the driver prints the
resulting empty `git status -- kernel/`, and `build.log` contains zero `tla_trace`
references). Only public syscalls are used — no failpoints, no state injection,
no kernel patch.

Result: Linux `deviations=0`, Asterinas `deviations=5`. Case E reproduces the
counterexample geometry exactly (offset inside the file, end past EOF, zero bytes
copied, `EFAULT`): size 8192 → 12288, and `pread` past the old EOF returns 4096
phantom zero bytes instead of 0. Case A additionally shows the size survives
close/reopen — permanent, not a transient snapshot.

Escalation ladder: **Level 0 succeeded**; Levels 1-3 were never needed.

Verdict: **REPRODUCED**.
