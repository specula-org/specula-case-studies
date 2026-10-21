# MC-8 investigation — ramfs zero-progress failed write publishes requested extent

Finding: `RamInode::write_at` publishes `inode_meta.size = new_size` and resizes the page
cache **before** the fallible user copy. A `pwrite64` at EOF whose source buffer is
inaccessible from the first byte returns `-EFAULT` with zero bytes accepted, yet leaves
the file extended (logical size grown, page cache zero-filled for the new range).
Counterexample: `spec/output/MC_hunt_s4_fault_ramfs_bfs1.out`, invariant `AcceptedExtent`.

## Step 1 — code audit

CE trace (ramfs, s4 fault): `MCSyscallEnter pwrite64 O=2 N=2` on a file with L=2 →
`RamWriteMetadata` → `ResizeBegin` sets L=4 (state 4) → `ResizeCapacity` C=4 (state 6) →
page collect/zero (`data` gains "zero","zero", states 10–11) → copy faults at first byte
(`BackendReturn status=EFAULT errorSite=user_source ioDone=0`, state 12) → `Return` with
`accepted={}` and final state L=4, C=4, view `<<"seed","seed","zero","zero">>`. Invariant
`AcceptedExtent` violated: zero accepted bytes but the extent grew.

Code in the worktree (`confirmation/MC-8/worktree`, revision 60494858, instrumented,
logic unchanged):

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs` — `RamInode::write_at`:
  1. lock page cache + metadata;
  2. `should_expand_size = new_size > file_size`; if so `inode_meta.size = new_size;
     inode_meta.blocks = new_size_aligned / BLOCK_SIZE;` (publish, instrumentation line ~758);
  3. `page_cache.resize(new_size_aligned, file_size)?`;
  4. `page_cache.write(offset, reader)?` — the fallible copy happens LAST;
  5. on `Err` the function just propagates it. No rollback of size or cache.
- `kernel/core/src/vm/page_cache/mod.rs:363` → `PageCache::write` → VMO
  `write` (`vmo/mod.rs:583`) → ramfs VMO is anonymous → `write_anonymous_pages`
  (allocates/commits zero pages first, then `write_fallible(reader)` faults).
- `ostd/src/mm/io/mod.rs` `read_fallible` (`impl_read_fallible!`): `memcpy` over the user
  cursor; a fault on the first byte returns `Err((Error::PageFault, 0))`.
- `ostd/src/mm/vm_space.rs:160` `VmSpace::reader(vaddr, len)`: only checks
  `vaddr + len <= MAX_USERSPACE_VADDR` — an unmapped/PROT_NONE user buffer passes and
  faults lazily in the copy loop above.
- Error mapping: `ostd::Error::PageFault` → `Errno::EFAULT` (`kernel/core/src/error.rs:203`).
- Syscall chain: `sys_pwrite64` (`kernel/core/src/syscall/pwrite64.rs`) →
  `file.write_at` → `InodeHandle::write_at` (`inode_handle.rs:343`, no rollback) →
  `RamInode::write_at`. Nothing above the FS restores the old size on error.
- Reachability: ramfs is the bootstrap root (`RamFs::new_rootfs()`,
  `mount_namespace.rs:102`); the boot initramfs is unpacked into it
  (`fs/initramfs.rs`); tmpfs is `type TmpFs = RamFs` (`tmpfs/fs.rs:20`) and `/dev/shm`
  uses `RamFs::new_tmpfs()` (`device/shm.rs:25`). A plain unprivileged
  `pwrite64` on any file in `/` (initramfs boot), a tmpfs mount, or `/dev/shm` hits this code.

Trigger scenario (Level 0, pure public API):
1. `fd = open("/f", O_RDWR|O_CREAT|O_TRUNC)`; `write(fd, "hi", 2)` → size 2.
2. `bad = mmap(NULL, 4096, PROT_NONE, MAP_ANON, ...)` (mapped but unreadable).
3. `pwrite64(fd, bad, 2, 2)` → `-1/EFAULT`, 0 bytes copied.
4. Observer: `fstat(fd)` and `pread(fd, buf, 4, 0)`.
   Linux ramfs: size stays 2, read returns "hi" + EOF.
   Asterinas (per code): size = 4, read returns "hi\0\0" — zero bytes that no
   successful syscall ever wrote.

Cross-backend comparison (same interface, divergent order):
- ext2 `Inner::write_at` (`ext2/inode/file.rs:282`): copy first; only on success
  `set_file_size(end)`; on error `rollback_write(old_size, end)` shrinks the cache and
  truncates block mappings. ext2 never publishes the new size before the copy.
- exfat `write_at` (`exfat/inode.rs:729`): allocates/resizes cache first, but
  `inner.size = new_size` is assigned only AFTER `page_cache.write` succeeds.
- MC agrees: no `.json` counterexample for `MC_hunt_s4_fault_ext2` / `_exfat`; only the
  ramfs config produced one.

## Step 2 — developer-knowledge search

- GitHub issue search (`repo:asterinas/asterinas`, open+closed, issues and PRs):
  - `#711` "Wrong behavior when `EFAULT` occurs in the middle of I/O system calls"
    (open, P4): about **partial-progress** EFAULT return-value semantics (bytes copied
    before the fault; Linux returns the partial count). Different mechanism and site
    (old syscall-buffer code), does not mention size publication on zero progress.
  - `#3778` "Limit page-cache reads to the file size in ramfs and exfat" (open PR):
    read-side clamp, different mechanism.
  - `#3297` "`InodeRollbackGuard` … for ext2" (open PR): ext2-only write rollback,
    confirms the project's accepted direction is rollback-on-error — ramfs not covered.
  - `#3142` xfstests tracking: has an "ENOSPC Rollback (Ext2)" entry; nothing on ramfs
    write-fault size publication.
  - Full `ramfs`-in-title sweep (22 items), `EFAULT write`, `write bad buffer`,
    `failed write extends`, `size before copy` sweeps: no report of THIS mechanism
    (size published before fallible copy → zero-progress EFAULT leaves grown file).
- Upstream `main` today still has the same ordering
  (`inode_meta.size = new_size` before `page_cache.write(offset, reader)?` in
  `kernel/core/src/fs/fs_impls/ramfs/fs.rs`) — unfixed as of this run's date.
- In-tree test evidence of intent: `test/initramfs/src/regression/fs/ext2/short_rw.c`
  ("short_write_should_not_leak_uninit_cache_page") asserts a failed EFAULT write leaves
  no trace — the ext2-side precedent for the same contract.

Novelty: **NEW** for this mechanism at this site (searched issues and merged/closed PRs).

## Step 3 — pre-filter

MC-sourced finding with a real counterexample → pre-filter drop not applicable.
Proceed to Phase 2.
