# AST-15: exFAT cold-tail extension re-enters an inode write guard

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding CR-2, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | `pwrite64` (extending buffered write) and `write`, which reaches the same `write_at` |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3603 (closed unmerged exFAT refactor), #762 and #767 (old ramfs page-cache resize deadlock, fixed), #2269 (open, exFAT eviction duplicate DMA map) |
| Fix | unfixed. Deadlock repair pending. Keep AST-11 serialization while fixing the backend I/O. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581, SMP=2) |

## Summary

An extending buffered write to an exFAT file whose old size is not
page-aligned, and whose tail page is not in the page cache, never returns. The
writer zero-fills the old tail page through the backend while holding the
inode's write guard, and the exFAT backend is the inode itself, so the backend
read waits on the guard its own task holds. The hung task also holds the exFAT
fs lock, which blocks later exFAT operations.

## Linux contract

write(2) and pwrite(2) on a regular file return the number of bytes written or
an error. They do not block forever on a lock held by the calling task. In the
same guest, the cached-tail exFAT case and the remounted ext2 case returned 16.
No Linux run was recorded for this finding.

## Asterinas behavior

At the pin, `kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::write_at`
takes `self.inner.write()` and the fs lock, and on extension calls
`inner.page_cache.resize(new_size, file_size)`.
`kernel/core/src/vm/page_cache/mod.rs::PageCache::resize` runs
`self.fill_zeros(old_file_size..fill_zero_end)?` when `old_file_size` is not a
multiple of `PAGE_SIZE`. `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::fill_zeros`
commits the tail page with `CommitMode::Read`. If the page is not cached, that
reads it from the backend, which for exFAT is
`kernel/core/src/fs/fs_impls/exfat/inode.rs::<ExfatInode as BlockAsPageCacheBackend>::submit_read_bio`.
Its first statement is `self.inner.read()` on the same non-reentrant sleeping
`RwMutex`, so the task waits for itself.

Two documentation claims are also wrong at the pin:

- The `PageCache::resize` doc says "Extending the page cache does not eagerly
  allocate pages and therefore cannot return an error." The extension branch
  calls the fallible `fill_zeros`, which can reach the backend.
- The comment on `ExfatInodeInner::page_cache` says a shrink updates the page
  cache "after we update the size of inode". `ExfatInode::resize` shrinks the
  page cache before `inner.resize`. The 01b trace confirmed that order
  (`PageCacheResizeBegin` before `ExfatResizeAllocation`).

The `write_direct_at` FIXME at the pin already names the hazard class ("the page
cache flush operation needs to acquire the backend lock, and the backend here is
the inode itself") and works around it for flush only.

Observed at the pin (01b CR-2): a 100-byte file on exFAT, `fsync`, `umount`,
`mount` (empty page cache), then `pwrite64(fd, buf, 16, 100)`:

```
T0 exfat cached-tail extend: ret=16 errno=0 (expect ret=16 errno=0)
T1b ext2 remounted uncached-tail extend: ret=16 errno=0 (expect ret=16 errno=0)
T1 exfat after remount: size=100 (expect 100)
T1 exfat uncached-tail extend: pwrite64 DID NOT RETURN within 10s -> kernel thread stuck
CR2-CLAIM-A: REPRODUCED -- extending pwrite64 on exfat self-deadlocks ...
```

The outer QEMU timeout ended the run with exit code 124.

## Reproduction

`repro/test_bugCR-2_exfat_resize_tailclear.c` is a static guest `/init` that
performs the remount sequence and detects the hang with a watchdog thread
(Level 0, no fault injection). See `repro/README.md`.

## Fix and upstream status

Register: "Deadlock repair pending; retain AST-11 serialization while fixing
backend I/O." The 01b handoff states the acceptance case: a cold-tail exFAT
`pwrite` returns, cached-tail and ext2 controls stay valid, and both AST-11
(01b MC-3) orders preserve data. The confirmation suggested performing the
extension resize, or at least the tail `fill_zeros`, before taking the write
guard or with an upread-then-upgrade pattern, and correcting both comments. The
AST-11 fix branch (`864356cec`) deliberately leaves this deadlock in place: the
extension `page_cache.resize` still runs under the upgraded write guard.
matches.json: NO_DIRECT_MATCH, upstream fix status NOT_ESTABLISHED.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 10)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/repro-guest.log
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/exfat-write-race/README.md (section "Series on `upstream/main`")

## Caveats

- The raw finding title was a documentation contradiction ("Resize
  documentation contradicts fallible tail clearing and exFAT branch order").
  Its confirmation turned it into a runtime deadlock, which is what the register
  tracks.
- The guest ran as root (uid 0) because the cold-cache precondition was created
  with `umount` and `mount`. The handoff notes that unprivileged cold-cache
  setup was not independently established. A pre-existing file on a freshly
  mounted image, or O_DIRECT `invalidate_range`, is argued to reach the same
  state but was not run.
- The watchdog detects the hang but cannot recover the guest.
- Only the buffered path was run. `ExfatInode::write_direct_at` also calls
  `page_cache.resize` under an upgraded write guard. Whether it deadlocks was
  not tested.
- The confirmation's line numbers (`inode.rs:751`, `:149`, `:1491-1494`) belong
  to the instrumented tree.
