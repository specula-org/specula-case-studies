# AST-40: ext2 invalidation error may bypass write rollback

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report CR-2 (not brief CR-2, which is AST-33/34), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | write, pwrite64, writev, pwritev (with `O_DIRECT`) |
| Upstream | open-pr: draft [#3297](https://github.com/asterinas/asterinas/pull/3297) (open, head `97ae1dfadc84`) arms a rollback guard before the invalidation |
| Fix | pr-open: #3297, static coverage only |
| Reproducer | NOT_RUN |

## Summary

In the ext2 direct-write path, `prepare_write` may grow the page cache and
allocate blocks, and `rollback_write` undoes that on failure. The next step,
`invalidate_range(...)?`, returns directly on error and skips the rollback.
A writeback failure during invalidation can therefore leave page-cache
capacity and allocated blocks past an unchanged file size.

## Linux contract

Recon recorded this as a code-review item and stated no user-visible Linux
contract. The governing rule is Asterinas's own doc comment on
`InodeInner::prepare_write`: on failure the caller must call `rollback_write`
with the original size. Linux ext2 performs the equivalent cleanup in
`ext2_write_failed()` (`fs/ext2/inode.c`), which truncates the page cache and
blocks past `i_size` after a failed write. That Linux pointer is a
package-builder reference, not part of the recorded evidence.

## Asterinas behavior

`kernel/core/src/fs/fs_impls/ext2/inode/file.rs::InodeInner::write_direct_at`
runs three steps:

1. `prepare_write(fs, offset, end)`, followed by `rollback_write` on error.
2. When the write overlaps existing data, `self.page_cache()
   .invalidate_range(discard_start_bytes..discard_end_bytes)?` with no
   rollback.
3. `write_direct_blocks`, followed by `rollback_write` on error.

`InodeInner::rollback_write` returns early when `end <= old_size`. The
skipped rollback therefore matters only when the write both overlaps old
data and extends past EOF (`offset < old_size < end`).
`kernel/core/src/vm/page_cache/mod.rs::PageCache::invalidate_range` flushes
dirty pages and then evicts clean ones, so it fails only when writeback
fails.

## Reproduction

No runtime reproducer exists. Recon CR-2 asks only for review of rollback
coverage. A runtime check needs a device write error or a test hook.

1. Create an ext2 file of 8192 bytes and dirty the cached page covering bytes
   4096 to 8191 with a buffered write.
2. Make the next writeback of that page fail. Options are a QEMU `blkdebug`
   drive that injects EIO on writes, or a test-only kernel patch that makes
   `PageCache::invalidate_range` return EIO.
3. Issue an `O_DIRECT` `pwrite` of 8192 bytes at offset 4096, which spans the
   old EOF.

The expected result, under both the Asterinas rollback rule and Linux ext2,
is that the call fails, `st_size` stays 8192, `st_blocks` returns to its
value before the call, and an offline `e2fsck -fn` of the image reports no
inconsistency. A larger `st_blocks`, or an fsck complaint about blocks past
`i_size`, shows the skipped rollback. SMP=1 is enough.

## Fix and upstream status

The 2026-09-14 dedup recorded OPEN_PR_COVERS with upstream fix status
OPEN_PR_STATIC_COVERAGE. Draft #3297, "Introduce `InodeRollbackGuard` to
handle write errors more elegantly for ext2", arms the guard before the
direct-write `invalidate_range` call, so an error there reaches rollback by
inspection. It is unmerged, and rebase and runtime validation are pending.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 5.5 #3297, 6.2, 9.3 CR-2)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (reference pointers only)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md` (notes the brief/report CR-2 mismatch)
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/raw/final-check/pr-3297.json`

## Caveats

- The register records "Open draft #3297 places invalidation under a
  rollback guard; static coverage only."
- Triggering requires a writeback failure, so plain syscalls cannot reach it.
  No user-visible harm beyond leaked allocation and cache capacity is
  claimed.
- AST-24 (MASKED) is a different fault in the same function: an earlier BIO
  can stay live after a direct-write fault and rollback.
- `ext2/inode/file.rs` is unchanged between the pin and upstream main
  `bc12195` (package-builder `git diff`, 2026-09-24).
