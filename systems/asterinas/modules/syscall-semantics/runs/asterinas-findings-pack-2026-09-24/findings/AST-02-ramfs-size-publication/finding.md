# AST-02: ramfs size publication before an empty or zero-progress write

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-4 (former catalog alias RF-02), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | GLM `asterinas-glm53-eval-20260826T035049Z` MC-3, REPRODUCED. 01b `20260908-150910-0a8c` MC-6 ("Ramfs zero-count positional writes can enlarge the file"), REPRODUCED, and MC-8 ("Ramfs zero-progress failed writes can publish the full requested extent"), REPRODUCED. 2026-09-16 backend source audit: tmpfs and devtmpfs ordinary files share the same `RamInode` code (static reachability only). |
| Syscalls | `write`, `pwrite64`, `writev`, `pwritev` |
| Upstream | `matches.json` (2026-09-14): no direct match. PR [#3481](https://github.com/asterinas/asterinas/pull/3481) was reviewed and still publishes the requested size before the copy. Since then PR [#3875](https://github.com/asterinas/asterinas/pull/3875) (opened 2026-09-20, open on 2026-09-24) covers the empty-write subcase. |
| Fix | Empty-write subcase: PR #3875, head `37b18435c` (`6fca818f4` ramfs guard plus regression, `37b18435c` exFAT guards) on `bc12195df`. Register state: FIX_PENDING_VALIDATION, final runtime deferred by the user. Nonempty zero-progress fault subcases: unfixed, repair pending. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

On ramfs, `write()` and `pwrite64()` publish the requested end
(`offset + len`) as the file size, together with block count and timestamps,
before the fallible user copy, and never roll back. A write whose source buffer
faults at byte zero therefore enlarges the file permanently with zero-filled
bytes, and a zero-length `pwrite64()` past EOF also enlarges it. Any
unprivileged process can do this to a file it can write, and every reader sees
the phantom size.

## Linux contract

write(2): "If count is zero and fd refers to a regular file, then write() may
return a failure status if one of the errors below is detected. If no errors
are detected, or error detection is not performed, 0 is returned without
causing any other effect." A transfer that fails before any byte is copied must
not extend the file beyond what was committed. Linux tmpfs (`shmem_write_end`
with `copied == 0`) grows the size at most to the write start (`pos + copied`),
never to the requested end. The Linux 7.1.9 tmpfs control (2026-09-02) printed
`deviations=0`, including CASE D at 16384 (the write start).

## Asterinas behavior

At pin `604948581`,
`kernel/core/src/fs/fs_impls/ramfs/fs.rs::RamInode::write_at` (the `FileOps`
impl, lines 721-752) publishes size, blocks, mtime, and ctime and resizes the
page cache to the requested end, then calls `page_cache.write(offset, reader)?`.
A copy error propagates with no rollback, and there is no early return for a
zero-length write.

Observed on 2026-09-02 at the pin (SMP=2): CASE A (`pwrite64` past EOF from a
faulting buffer), CASE B (zero-length `pwrite64` past EOF), and CASE C
(`O_APPEND` write from a faulting buffer) grew the size from 8192 to 16384. CASE
E (a write overlapping EOF) grew it to 12288. CASE D (a write at a seeked
offset) grew it to 24576, where Linux reaches 16384. CASE A's size survives
close and reopen, and `pread` past the old EOF returns 4096 zero bytes where
Linux returns 0.

## Reproduction

- `repro/repro.c`: the 01a confirmation program (MC-4). It runs CASE A to E on
  a directory argument (default `/`) and prints `MC4_SUMMARY ...
  deviations=<n>`. The unfixed kernel prints `deviations=5`. Linux and a fixed
  kernel print `deviations=0`.
- `repro/min_ast02.c`: a 43-line version from the 2026-09-02 validation. It
  prints `MIN_AST02 BUG` on the unfixed kernel and `MIN_AST02 OK` on Linux.
- `repro/empty_write-regression-pr3875.patch`: the in-tree regression test from
  PR #3875 (`fs/empty_write`). It covers only the empty-write subcase, on ramfs
  and on exFAT and ext2 in buffered and direct modes.
- `repro/variants/GLM-MC-3/`: the GLM run's variant, which also covers a memfd
  file and a fault after a positive prefix.

`repro/README.md` has the commands and output tables.

## Fix and upstream status

- Register repair column: empty-write guard in the 2026-09-16 batch
  (`/home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/README.md`),
  FIX_PENDING_VALIDATION, final runtime deferred by the user. The historical v5
  A/B is retained. The nonempty fault repair is pending.
- PR #3875, "Preserve ramfs and exFAT metadata on empty writes", was opened on
  2026-09-20 by the workspace owner from branch `fix/empty-write-metadata-review`.
  Its ramfs commit `6fca818f4` returns early for zero-length writes to regular
  files. Its body reports that the base kernel failed the new assertions and
  that the fixed kernel and Linux 7.2.6 passed all five modes. The register
  (last updated 2026-09-16) does not mention #3875.
- Historical local fix: the 01a v5 `fixes.patch` resized the cache before the
  copy, published size and timestamps only after it (to `offset + committed`),
  rolled a zero-progress fault back to `max(old_size, offset)`, and returned
  early for zero-length writes. A/B at the pin: 5 deviations before, 0 after,
  with CASE D at the tmpfs value 16384. It was never rebased or submitted.
- On 2026-09-02, ramfs `write_at` on main `29b0f4bcf` had moved to lines
  984-1045 but its logic was unchanged (static check only).

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-02-ramfs-size-publication/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-4/`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-4_ramfs_size_publication.c`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-02-tmpfs.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/minimal/` (`min_ast02.c`, `asterinas-604948581-output.txt`, `linux-7.1.9-output.txt`, `regression/fs/ramfs/write_size.c`)
- `/home/chin39/Documents/play/specula-profile/reports/empty-write-batch-2026-09-16/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-02-empty-write-2026-09-14/README.md` and `related-filesystems-2026-09-16.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-3/`
- `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md` (entries MC-6 and MC-8)
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-02`)

## Caveats

- PR #3875 and the 2026-09-16 batch fix only the count-zero case. The
  zero-progress copy-fault cases (CASE A, C, D, E and 01b MC-8) remain unfixed.
- Sources disagree on validation. The register and the 2026-09-16 batch record
  the empty-write fix as FIX_PENDING_VALIDATION with runtime deferred. The PR
  #3875 body, written four days later, reports base, fixed, and Linux runs. No
  log of those runs is linked from the workspace records.
- The exFAT empty-write analogue is AST-14, and the virtiofs direct-write lead
  is AST-72. GLM MC-3 also saw the zero-progress fault case on a memfd file.
  The 2026-09-16 audit found that memfd already guards empty writes.
- An earlier v1 local patch rolled CASE D back to the old size, which Linux
  tmpfs does not do. The final v5 kept the `pos + copied` result.
- `repro/run.sh` compiles inside the guest with `cc`. The stock initramfs has no
  compiler. See `docs/running-reproducers.md`.
