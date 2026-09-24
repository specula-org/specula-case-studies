# AST-13: exFAT regrown holes expose the file's old backing bytes

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding MC-5, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | `ftruncate`, `pwrite64` (setup); `pread64` (observer) |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3603 (closed unmerged exFAT refactor), #3256 (merged page-cache uninitialized write-fragment fix), #3229 (merged backend zero-page change) |
| Fix | unfixed. Repair pending. Only same-file stale data was demonstrated. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581, SMP=2, single-threaded) |

## Summary

After `ftruncate(fd, 0)` on exFAT, an extending `pwrite` past offset 0 reuses the
file's freed clusters without zeroing the gap. A `pread` of the hole below the
new EOF then returns the file's own pre-truncation bytes instead of zeros. An
unprivileged process observes it with a single thread on a freshly formatted
image.

## Linux contract

lseek(2) (POSIX wording): "If data is later written at this point, subsequent
reads of data in the gap (a 'hole') return null bytes ('\0') until data is
actually written into the gap." ftruncate(2) also requires the extended part of
a file to read as null bytes. In the same guest, ext2 and ramfs returned zeros
for the identical sequence. No Linux run was recorded for this finding.

## Asterinas behavior

At the pin:

- `kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::resize` (for
  `ftruncate(fd, 0)`) calls `PageCache::resize(0, old)`, which decommits the
  cached pages, and then `ExfatInodeInner::resize`, which frees the clusters
  through `kernel/core/src/fs/fs_impls/exfat/fat.rs::<ExfatChain as ClusterAllocator>::remove_clusters_from_tail`.
  That only clears allocation-bitmap bits. The on-disk bytes stay.
- The next extending `ExfatInode::write_at` allocates clusters through
  `kernel/core/src/fs/fs_impls/exfat/fat.rs::ExfatChain::alloc_cluster_from_empty`,
  whose first-fit search starts at `EXFAT_FIRST_CLUSTER`, so on a fresh image it
  reclaims the just-freed clusters.
- `kernel/core/src/vm/page_cache/mod.rs::PageCache::resize(new, 0)` zero-fills
  only the old partial tail page. With an old size of 0 nothing is zeroed. Only
  the written tail page is committed before `inner.size` is published.
- A read of a hole page below EOF reaches
  `kernel/core/src/fs/fs_impls/exfat/inode.rs::<ExfatInode as BlockAsPageCacheBackend>::submit_read_bio`,
  which returns `BioStatus::Zeros` only when `inner.size <= idx * PAGE_SIZE`
  and otherwise reads the mapped cluster from disk.

exFAT has no sparse-file representation, so the gap must be zeroed on
extension. ext2 leaves gap blocks unmapped (holes read as zeros), and ramfs has
no backend.

Observed at the pin (01b MC-5), after seeding pages 'A', 'B', 'C', `fsync`,
`ftruncate(fd, 0)`, and `pwrite` of one 'Z' page at 8192:

```
[exfat] pread(off=0,len=2) returned bytes: 41 41 ('AA')
[exfat] hole page 0: 4096/4096 non-zero bytes, seed-'A' match: FULL
[exfat] hole page 1: 4096/4096 non-zero bytes, seed-'B' match: FULL
[exfat] MC5_RESULT BUG hole returned 8192 non-zero bytes (full seed-pattern pages: 2/2)
```

## Reproduction

`repro/test_bugMC-5_exfat_regrown_hole.c` runs the sequence on `/ramfs`,
`/ext2`, and `/exfat` as uid 1000 (Level 0, no timing help).
`repro/test_bugMC-5_init.c` mounts the fixtures and drops privileges. See
`repro/README.md`.

## Fix and upstream status

Register: "Repair pending; only same-file stale data demonstrated." The 01b
confirmation suggested zero-filling the extension gap in `ExfatInode::write_at`
and in any other extension path such as `resize` growth, dirtying the gap pages
so zeros also reach disk. The handoff asks for tests of shrink-to-zero and
regrow with cached and cold pages plus backend controls. No patch exists.
matches.json: NO_DIRECT_MATCH, upstream fix status NOT_ESTABLISHED.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 5)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc5/guest-mc5.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s3_holes_exfat_bfs1.out
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md

## Caveats

- Only the same file's pre-truncation bytes were shown. The register and the
  handoff forbid a cross-file or cross-principal disclosure claim until a
  separate donor/victim test runs.
- Deterministic cluster reuse depends on a fresh image where the subject file
  holds the lowest free clusters.
- The hole-contents check covers the cached-read path right after the write.
  The behavior after cache eviction was not tested.
