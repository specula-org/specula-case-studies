# AST-72: virtiofs direct empty write may publish a larger local size without a server write

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Backend audit, 2026-09-16 read-only source audit (no native run ID or finding ID), Asterinas pin `bc12195df4acfb1fc4ae968cf7acf9333ed83435` |
| Also seen in | none |
| Syscalls | pwrite64, write, pwritev, writev (zero-length) |
| Upstream | not-checked: AST-72 was added after the 2026-09-14 dedup |
| Fix | unfixed, no patch written |
| Reproducer | NOT_RUN |

## Summary

A zero-length write that takes the virtiofs direct path sends no
`FUSE_WRITE` and returns 0, but the caller still commits local metadata with
size `max(old_size, offset + 0)`. A zero-length positional write beyond EOF
therefore raises the locally cached size, sector estimate, mtime and ctime
without any server write. Whether a syscall can observe this is unconfirmed,
because an attribute refresh may replace the local values first.

## Linux contract

write(2): "If count is zero and fd refers to a regular file, then write()
may return a failure status if one of the errors below is detected. If no
errors are detected, or error detection is not performed, 0 is returned
without causing any other effect." pwrite(2) and the vectored forms follow
the same rule. AST-02 (ramfs) and AST-14 (exFAT) rest on the same contract.

## Asterinas behavior

Sites at `bc12195`:

1. `kernel/core/src/fs/fs_impls/virtiofs/file.rs::VirtioFsFile::write_at`
   sends `O_DIRECT`, `O_APPEND`, and any non-cached policy to
   `direct_write_at` with no empty-reader return. The ordinary positional
   caller has none either.
2. `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs::VirtioFsInode::do_direct_write`
   starts the count at zero and skips its `while reader.has_remain()` loop
   for an empty reader, so it sends no `FUSE_WRITE` and returns 0.
3. `VirtioFsInode::direct_write_at` computes `offset + written`, takes the
   maximum with `self.size()`, calls `commit_local_write`, and updates the
   atomic inode size. For a 2-byte file and offset 8192 the result is 8192.
   When a page cache exists it also calls `invalidate_range` on the empty
   range.
4. `kernel/core/src/fs/fs_impls/virtiofs/inode/metadata.rs::InodeInner::commit_local_write`
   sets the size, `nr_sectors_allocated`, mtime and ctime, and expires the
   attribute cache.

`VirtioFsInode::cached_write_at` returns 0 for an empty reader before
touching the size, but only after its missing-page-cache fallback to
`direct_write_at` has been checked. Without a page cache it also reaches the
direct path.

## Reproduction

No runtime reproducer exists and no executable test was written. The audit
proposes this check:

1. Mount virtiofs with a matched server. The Asterinas virtiofs test setup is
   not recorded in the source evidence.
2. Create a 2-byte file and open it with `O_DIRECT`. Confirm that the direct
   route is taken, for example with a server-side `FUSE_WRITE` count or a
   kernel log.
3. Call `pwrite(fd, buf, 0, 8192)`. Expect 0.
4. Observe `fstat` (`st_size`, `st_blocks`, `st_mtime`),
   `lseek(fd, 0, SEEK_END)`, and the size of the file on the host.
5. Repeat on the cached route (no `O_DIRECT`, cached policy) as a control, and
   on Linux virtiofs.

On Linux the size stays 2, the mtime does not change, and no `FUSE_WRITE` is
sent. Any Asterinas observer that reports 8192 or a new mtime, or a grown
host file, would support the lead. Record whether an attribute refresh
happened between the write and each observation. SMP=1 is enough.

## Fix and upstream status

No patch exists. Upstream deduplication has not been run for this entry. A
fix would mirror the ramfs and exFAT guards: return 0 for an empty reader
before any metadata commit in `direct_write_at`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md` (section "AST-72: virtiofs direct empty-write source lead")
- `/home/chin39/Documents/play/specula-profile/reports/ast-02-empty-write-2026-09-14/related-filesystems-source.json` (source hashes at the pin)
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`

## Caveats

- The register records "Local metadata mutation found statically; attribute
  refresh may mask syscall observations. Runtime NOT_RUN; upstream dedup
  NOT_CHECKED."
- Remote file growth is not established. `metadata()` and `seek_end()`
  revalidate server attributes, and a refresh may erase the local anomaly
  before `fstat` or `SEEK_END` sees it. No security impact is established.
- The audit ran on the AST-02 worktree with its ramfs guard applied. The
  virtiofs files there match base `bc12195` by SHA-256.
- Keep AST-72 separate from AST-02 and AST-14. The storage and publication
  paths differ.
- The `O_APPEND` routing and the cached-path fallback order come from a
  package-builder reading of `bc12195`, not from the audit text.
