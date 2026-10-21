# MC-3 Investigation — A Zero-Progress RamFS Write Can Publish the Full Requested EOF

Re-executed in full this turn (the finding was re-leased after a pipeline crash;
the prior round's artifacts under `repro/` were wiped, the worktree was reset —
this turn rewrote the test and re-ran both the Linux control and the guest).

## Phase 1, Step 1 — Code audit

### Cited code (worktree)

`kernel/core/src/fs/fs_impls/ramfs/fs.rs`, `RamInode::write_at` (FileOps impl):

- fs.rs:747 — `let mut inode_meta = self.metadata.lock();`
- fs.rs:749-752 — `write_len = reader.remain()` (full request), `new_size = offset + write_len`
- fs.rs:755-758 — **publishes the full requested EOF before any copy**:
  `inode_meta.size = new_size; inode_meta.blocks = new_size_aligned / BLOCK_SIZE;`
- fs.rs:761-762 — fallible `page_cache.resize(new_size_aligned, file_size)?`
- fs.rs:775 — fallible user copy `page_cache.write(offset, reader)?`
- Neither `?` error path restores `inode_meta.size`/`blocks` or shrinks the
  page cache back to `file_size`.

### Baseline-vs-instrumentation check

`git show HEAD:kernel/core/src/fs/fs_impls/ramfs/fs.rs` (pristine baseline
d0139a1, `write_at` at baseline lines 721-755) contains the identical
publish-before-copy order (`inode_meta.size = new_size` at :742, fallible
`page_cache.write(offset, reader)?` at :750). The worktree diff on this file is
`tla_trace::*` call-plumbing only (checked by filtering non-trace diff lines:
only tuple captures for tracing remain). The defect is baseline code, not
campaign instrumentation. Same check on `inode_handle.rs`, `vmo/mod.rs`,
`syscall/write.rs`, `syscall/pwrite64.rs` diffs (prior round, re-confirmed by
artifact hashes): trace-only; `*offset += len` still happens only on `Ok`.

### Fault semantics (why the copy can fault)

- `sys_pwrite64`/`sys_write` create the user reader via
  `CurrentUserSpace::reader` → `VmSpace::reader` (`ostd/src/mm/vm_space.rs:160`,
  `kernel/core/src/context.rs:91`): **bounds check only** — deliberately no
  page validation (Linux delayed buffer validation; comment in context.rs).
- The copy runs in `Vmo::write` → `write_anonymous_pages`
  (`kernel/core/src/vm/page_cache/vmo/mod.rs:579,696`): per-page
  `page.writer().skip(..).write_fallible(reader)`; on fault returns
  `Err(EFAULT)` — for RamFS (no backend) the partial `written_size` is dropped.
- Callers do not roll back: `InodeHandle::write`/`write_at`
  (`kernel/core/src/fs/file/inode_handle.rs:328,412`) propagate the error
  unchanged (shared offset correctly not advanced on Err — the corruption is
  the inode size, not the fd offset); `sys_pwrite64`/`sys_write` return the
  error to userspace.

### Affected surfaces

`pub(crate) type TmpFs = RamFs;` (`kernel/core/src/fs/fs_impls/tmpfs/fs.rs:20`);
`memfd_create` uses `ramfs::memfd` (`kernel/core/src/syscall/memfd_create.rs`).
So /tmp (guest initramfs root is ramfs), tmpfs mounts, /dev/shm, and memfds all
route through this `write_at`.

### In-tree contrast (intended design)

ext2 `Ext2Inode::write_at` (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs`,
~255-285): copies first via `page_cache().write(offset, reader)`; on error
`rollback_write(old_size, end)`; only on success `set_file_size(end)`. RamFS
deviates from the tree's own standard for the identical fault case.

### Trigger scenario (constructs from public API)

Exactly the MC CE (`MCSysPwrite64Begin(t1,6,...)` requested=2 → size publish →
`MCVmoWrite(t1,"Zero")` → EFAULT, fileSize 6→8):

1. `open("/tmp/f", O_CREAT|O_RDWR, 0644)`; write 6 bytes (size 6).
2. `buf = mmap(...PROT_READ|PROT_WRITE, ANON)`; `mprotect(buf, page, PROT_NONE)`
   (equivalent production shape: freed/unmapped buffer).
3. `pwrite(fd, buf, 2, 6)` → delayed validation passes; `write_at` sets
   size=8; copy faults at byte 0 → EFAULT propagates; size stays 8.

Caller-side safeguards encountered: none on this path (no caller rollback; no
revalidation of the buffer; the anonymous VMO has no backend/sync to reconcile
the size). Record only — Phase 2 proves what fires.

## Phase 1, Step 2 — Developer knowledge

- Local git history is a single squashed baseline commit (`d0139a1`), so no
  local commit intent is recoverable.
- No TODO/FIXME/known-issue comment near `RamInode::write_at`; the nearby
  FIXMEs in `inode_handle.rs` concern O_APPEND, not this.
- `context.rs:91-107` comment documents deliberate Linux delayed-validation
  fault semantics at the syscall edge — the tree intends EFAULT-after-entry,
  which is what makes the pre-published size observable.
- No existing test asserts size-after-EFAULT for ramfs/tmpfs/memfd.

## Phase 1, Step 3 — Known-status / novelty

Tracker searches (GitHub asterinas/asterinas, issues + recently merged/closed
PRs; multiple query angles, this turn re-run):

- #3142 — xfstests gap tracker for **ext2** (timestamps, O_DIRECT alignment,
  page-cache locking). Fetched and read: no tmpfs/ramfs, no EFAULT-size
  rollback mechanism. Not a match.
- #2937 / PR #2953 — page-cache redesign (size consistency races), different
  mechanism. #2817 — ftruncate shrink hang. PR #3086 — pread/pwrite errno
  selection. Commit 513532f — writev partial-count aggregation. #1554 — pipe
  write atomicity (named in the brief as context only). #711 — not this
  mechanism. None report publish-before-copy with missing rollback at
  RamFS `write_at`.
- Conclusion: **Novelty: NEW** — no existing report of this mechanism at this
  site. (MC-sourced with a real counterexample proceeds to Phase 2 regardless.)

## Phase 2 — Reproduction (Level 0, executed this turn)

Test: `repro/test_bugMC-3_prepublished_write_eof.c`
(sha256 42fc8f659b7ce6043fbe953eb12a351c29a95a44a3b5d562bd0b921ab2a377aa),
guest copy byte-identical at
`worktree/test/initramfs/src/regression/io/file_io/specula_repro_mc3.c`.

- **Level 0** — public syscalls only (open/write/pwrite/pread/lseek/fstat/
  mmap/mprotect/memfd_create), single thread, deterministic, no failpoints,
  no state injection, no source modification. Triggered on the first run.
- Linux control (host tmpfs, same binary): all phases CLEAN — zero-progress
  EFAULT leaves `st_size=6`; prefix fault returns short 4096, `st_size=4096`.
  Saved: `repro/test_bugMC-3_prepublished_write_eof.linux_control.txt`.
- Guest run: `run_mc3_repro.sh` → docker `asterinas/dev:0.18.1-20260805`,
  KVM, `make run_kernel AUTO_TEST=mc3repro TARGET_ARCH=x86_64 SMP=2 MEM=2G
  LOG_LEVEL=error`, `MC3_REPRO_DONE` gate passed. Output saved:
  `repro/test_bugMC-3_prepublished_write_eof.guest_output.log` and
  `.guest_qemu_full.log` (genuine boot console: `[kernel] running /init` …).

Results: 4 BUG / 0 skip —

1. ramfs_zero_pwrite (exact CE): ret=-1 EFAULT, st_size=8, seek_end=8,
   read_at_write_pos=2 (phantom bytes readable past committed EOF).
2. ramfs_zero_write: ret=-1 EFAULT, st_size=8, fd_offset=6 (offset unmoved;
   size corrupted), seek_end=8.
3. ramfs_prefix_pwrite: ret=-1 EFAULT (Linux: short 4096), requested=8192,
   st_size=8192, committed_prefix=4096 — EOF 4096 bytes beyond committed data.
4. memfd_zero_pwrite: ret=-1 EFAULT, st_size=8.
5. ext2 control, same guest: CLEAN (st_size=6) — divergence is the ramfs
   adapter, not the harness or the syscall layer.

### Verify-right-bug check

Matches the MC trace exactly: Pwrite64, entryStart=6, requested=2, Zero fault
progress (`MCVmoWrite(t1,"Zero")`), publishedEOF=Complete committed=0,
result=EFAULT, fileSize 6→8; same invariant class (`MCNoNominalEOFOnFault`:
no nominal EOF beyond committed bytes on fault); same root cause site
(ramfs/fs.rs:755-775 pre-publish without rollback). Prefix variant confirms
the second half of the finding's summary.

### Pre-REPRODUCED checklist

1. **Level 0 alone — yes.** Real public API, normal ops, single thread,
   deterministic; timing help not needed.
2. N/A (no Level 2/3 used). The trigger state (unreadable user buffer page)
   is produced by real-API calls (`mmap` + `mprotect`) and instantiates the
   admissible CE step `MCVmoWrite(t1,"Zero")`.
3. **Real consumer:** the calling process itself via subsequent syscalls —
   `fstat` (`kernel/core/src/syscall/fstat.rs`) reports st_size=8/8192 after
   EFAULT; `lseek(SEEK_END)` returns 8 (a resume-at-EOF writer silently skips
   never-written bytes); `pread64` serves phantom zero bytes past the
   committed prefix. Observed in captured output, not argued-only.
4. **Permanent, not masked.** The wrong size is durable inode metadata: no
   caller rolls back (verified error paths in inode_handle.rs and
   syscall/write.rs / pwrite64.rs); the anonymous VMO has no backend/sync to
   reconcile; the guest run shows the state persisting across subsequent
   syscalls. No safeguard fires (ext2's rollback exists but only in ext2's
   own adapter).
