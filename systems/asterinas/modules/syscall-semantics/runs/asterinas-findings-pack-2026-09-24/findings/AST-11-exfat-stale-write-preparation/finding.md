# AST-11: exFAT write preparation becomes stale before copy/publication

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding MC-3, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | Earlier local exFAT write-race work (2026-09-03, `upstream/main` `d76b4dcc0`): `writers` stress variant 694 and 734 of 20000 rounds anomalous, Linux tmpfs 0. That work has no Specula run ID or verdict. |
| Syscalls | `pwrite64`, `write`, `ftruncate` (competitors and triggers); `pread64`, `fstat` (observers) |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3603 (closed unmerged exFAT refactor), #3481 (open, inode append and memfd seal races) |
| Fix | fix-local: `fix/exfat-write-size-race` in `/home/chin39/Documents/asterinas-dev`, `864356cec` fix and `3ece54702` test on `upstream/main` `bc12195df`. A/B on 2026-09-14: unfixed 65 to 93 of 2000 rounds bad, fixed 0. Not pushed. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581 with a Level 3 timing hook, SMP=2. The hook-free regression fails at bc12195df, SMP=4.) |

## Summary

`ExfatInode::write_at` sizes the file and the page cache under the inode write
lock, drops the lock, copies under a new upgradeable lock, and then publishes
the size it computed before the gap. A second writer or a truncate in the gap
can shrink the page cache under the copy. The first write then returns its full
count after storing 0 bytes, or a completed extent is lost below the published
size. Any process issuing concurrent extending writes, or a write racing
`ftruncate`, on one exFAT file can observe this.

## Linux contract

write(2): on success the return value is the number of bytes written. POSIX
requires that after a successful `write` to a regular file, reads of the
modified positions return the written data until they are modified again, and
that the file size covers the written range. Linux serializes buffered writes
to one inode (the stress controls on Linux 7.1.12 tmpfs recorded 0 anomalies,
and the `fs/write_race` test recorded 0 bad rounds on the Linux host).

## Asterinas behavior

At the pin, `kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::write_at`
runs three phases:

1. Under `self.inner.write()` and the fs lock: read `file_size`, compute
   `new_size = offset + write_len`, allocate clusters with
   `ExfatInodeInner::resize` when needed, call
   `kernel/core/src/vm/page_cache/mod.rs::PageCache::resize(new_size, file_size)`,
   and keep `new_size.max(file_size)`.
2. Drop the lock ("Locks released here, so that file write can be
   parallelized."), take `self.inner.upread()`, and call `page_cache.write`.
   `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::write` clamps the copy to the
   VMO's current size and returns `Ok(())` even when it copied 0 bytes.
3. Upgrade and store `inner.size = new_size` from phase 1, then return
   `write_len`.

Nothing revalidates the phase-1 size after the gap. A lower extending writer's
phase 1 can lower the VMO capacity (`vmo.size.store(new_cache_size)` plus
decommit) under the higher writer, and `Inode::resize` from `ftruncate` can do
the same. The `PageCache` `VmIo::write` TODO at the pin says exFAT "does not
hold the write lock when handling `write()`". The `PageCache::resize` doc
requires the filesystem to keep capacity and size synchronized under one lock
that excludes buffered I/O.

01b MC-3 observed two orders with a kernel timing hook:

- CE order (`L3`): `t1 pwrite(fd,'B',4096,8192)` returned 4096 having stored 0
  bytes. The settled `st_size` was 12288 while the cache covered 8192.
  `pread64(8192, 4096)` returned 4096 with all 4096 sentinel bytes untouched. A
  third non-racing `pwrite` again returned 4096 and stored nothing.
- Regression order (`L3R`): `st_size` fell to 8192 after the write ending at
  12288 had already returned success.

## Reproduction

Two reproducers, see `repro/README.md`:

- `repro/write_race-regression.patch` adds `fs/write_race`: 2000 rounds on
  `/tmp`, `/ext2`, `/exfat`, releasing an 8 KiB and a 4 KiB writer at offset 0
  together. No kernel change is needed. It skips with one CPU. At `bc12195df`
  with SMP=4 the unfixed tree fails 65 (run V1) and 93 (run V2) of 2000 rounds on
  `/exfat`.
- `repro/guest_mc3.c` with `repro/mc3-l3-timing-hook.patch` reproduces the exact
  01b counterexample schedules. The timing-only hook busy-waits a
  `prctl(0x53504551)`-armed thread between the lock release and the
  reacquisition. Without the hook, 500 timing-assisted trials at the pin did
  not trigger (`MC3_VERDICT L1 not_triggered trials=500`).

## Fix and upstream status

Register: "Fix + `fs/write_race` on `fix/exfat-write-size-race` (`864356cec`,
`3ece54702` on `upstream/main` `bc12195df`), A/B 2026-09-14: unfixed 65 to 93 of
2000 rounds bad, fixed 0; not pushed; retest both 01b schedules with AST-15."
The fix keeps one upgradeable lock across the whole buffered write and upgrades
only to resize and to publish, as `write_direct_at` already does. The PR text is
drafted at
`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/exfat-write-race/fix/pr-draft.md`.
Nothing was filed upstream. matches.json: NO_DIRECT_MATCH, upstream fix status
NOT_ESTABLISHED.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 3)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/build/guest-L1.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/build/guest-L3.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/build/guest-L3R.log
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s2_exfat_extent_bfs1.out
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/exfat-write-race/README.md
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/exfat-write-race/fix/logs/v2/
- /home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/exfat-write-race/fix/patches/v2/
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md

## Caveats

- The 01b reproduction needed a Level 3 timing hook. The hook only dilates
  timing and changes no logic, but the pin never triggered without it in 500
  trials. The hook-free `fs/write_race` evidence is on `bc12195df`, not the pin.
- The fixed-tree A/B covers the `writers` shape. The register still requires a
  retest of both exact 01b schedules on the fixed tree.
- The fix does not cover AST-15. The extension `page_cache.resize` still runs
  under the upgraded write guard, so a cold unaligned tail can still deadlock.
  Repair AST-15 without reopening this gap.
- handoff-01b.md (2026-09-14 refresh) still describes the older series
  (`d5b645d84` + `97199dd30` on `3aa75efd3`, 79 of 2000 bad before and 0 after).
  The register and the exfat-write-race README record the later rebase to
  `864356cec`/`3ece54702` on `bc12195df` with 65 to 93 of 2000. This entry
  follows the register. The old series is kept as `scratch/exfat-v1-2026-09-04`.
- The earlier stress also saw a `truncate` variant flip between 19950 and 0 of
  20000 across passes on the same tree. That variant is scheduling-dependent.
