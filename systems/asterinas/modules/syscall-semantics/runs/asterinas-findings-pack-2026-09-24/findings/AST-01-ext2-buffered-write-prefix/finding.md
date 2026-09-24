# AST-01: ext2 durable write prefix returned as EFAULT

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-2 (former catalog alias RF-01), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | GLM `asterinas-glm53-eval-20260826T035049Z` MC-1, REPRODUCED (the readv observation maps to both AST-01 and AST-04). Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z` analysis-report T-1/CR-1 and modeling-brief T-1/CR-1, analysis-only candidates shared with AST-04. |
| Syscalls | `write`, `pwrite64`, `writev`, `pwritev` |
| Upstream | Partial match: open issue [#711](https://github.com/asterinas/asterinas/issues/711) reports the lost partial count. Open draft PR [#3297](https://github.com/asterinas/asterinas/pull/3297) is related ext2 rollback work and does not restore the count. |
| Fix | Local only: the historical 01a v5 `fixes.patch` at the pin, A/B validated on 2026-08-25. Not rebased onto current main and not submitted. No upstream fix. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

A `write()` or `pwrite64()` to an ext2 regular file whose user source buffer
faults after a positive prefix has been copied leaves that prefix in the page
cache, marked dirty, so it survives `fsync` and is visible to an `O_DIRECT`
re-read. The syscall still returns `-1`/`EFAULT` and moves neither the shared
file offset nor the file size. Any unprivileged process that writes from a
partly unmapped buffer can observe the mismatch, and any reader of the file
sees bytes the writer was told were never written.

## Linux contract

write(2): on success the call returns the number of bytes written, which may
be less than the requested count. A transfer cut short by a faulting user page
after some bytes were copied is reported as that short count, and the file
offset advances by the same amount. The Linux control run of the same source
(ext4 on Linux 7.1.9, 2026-09-02) printed `CONSISTENT_SHORT_WRITE` for all
three cases: the return value, the committed bytes, and the offset delta
agree (4096/4096/4096 and 128/128/128).

## Asterinas behavior

Line numbers are at pin `604948581`.

- `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::write_pages_with_backend`
  (called from `Vmo::write`, lines 740-745 at the pin; the catalog description
  cites 745-752): on `Err((err, written_size))` the
  fault arm marks an up-to-date page dirty when `written_size > 0`, then
  returns the error and discards `written_size`.
- `kernel/core/src/error.rs::<Error as From<(ostd::Error, usize)>>::from`
  (lines 209-219) drops the copied count carried in the tuple.
- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs::InodeInner::write_at`
  (lines 245-271) returns the full requested count only on success. Its
  rollback is a no-op for in-place ranges below the old EOF, so the dirty
  prefix stays.
- `kernel/core/src/fs/file/inode_handle.rs::<InodeHandle as FileLike>::write`
  (lines 308-320) advances the shared offset only on `Ok(len)`.

The reproducer's `O_DIRECT` case (`uninit_tail`) goes through
`kernel/core/src/fs/fs_impls/ext2/inode/file.rs::InodeInner::write_direct_at`
instead. There 128 bytes reach the disk while the call reports `EFAULT`. The v5
patch fixed it separately, by waiting for the committed segment's BIOs and
converting the fault into a short write.

## Reproduction

`repro/repro.c` is the 01a confirmation program (byte-identical to
`test_bugMC-2_retained_write_prefix_efault.c` in the 01a run). It runs three
cases on a directory argument (default `/ext2`): `mixed_page`, `partial_page`,
and the `O_DIRECT` `uninit_tail`. See `repro/README.md` for build steps and
`docs/running-reproducers.md` for the guest harness.

On the unfixed kernel every case prints `ret=-1 errno=14`, a positive
`changed_bytes`, and `MC2_VERDICT <case> RETAINED_PREFIX_UNREPORTED`, and the
run ends with `MC2_RESULT DIVERGES_FROM_LINUX`. Linux prints
`CONSISTENT_SHORT_WRITE` for each case and `MC2_RESULT MATCHES_LINUX`.

Runtime record: reproduced in the 01a confirmation (2026-08-24, SMP=2), in the
01a patch-validation A run (2026-08-25), and again in the independent
2026-09-02 validation (QEMU/KVM, SMP=2): committed 4096/128/128 bytes with
offset delta 0 in all three cases.

`repro/variants/GLM-MC-1/` holds the GLM run's readv/writev variant of the same
count-erasure mechanism.

## Fix and upstream status

- Upstream dedup (2026-09-14, `matches.json`): `PARTIAL_MATCH`. Issue #711
  reports the same lost-progress mechanism. The durable ext2 file/offset
  consequence is a narrower extension that #711's PoC never inspected. PR #3297
  changes rollback, not successful short-count reporting. Both were still open
  on 2026-09-24.
- The 2026-09-02 validation record notes "AST-01 already submitted per user"
  next to #711, without a link. No AST-01-specific issue or PR number is
  recorded anywhere.
- Local fix: `fixes.patch` v5 changes `read_fallible`/`write_fallible` fault
  handling in `vmo/mod.rs` so a positive prefix returns `Ok(())` with the
  cursor carrying progress, counts the committed prefix only for up-to-date
  pages, and derives the ext2 `O_DIRECT` return from `reader.remain()`. A/B
  result: every case changed from `RETAINED_PREFIX_UNREPORTED` to
  `CONSISTENT_SHORT_WRITE`. Patch path:
  `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.fixes.patch`.
  It covers AST-01..06 together (not AST-24) and was never rebased.
- On 2026-09-02 the decisive files (`vmo/mod.rs`, `error.rs`,
  `ext2/inode/file.rs`) were byte-identical on upstream main `29b0f4bcf`
  (static check only, no runtime run on main).

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-01-ext2-buffered-write-prefix/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-2/` (`investigation.md`, `debate.md`, `verdict.json`, `asterinas-run.log`, `linux-control.log`)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-2_retained_write_prefix_efault.c` and `.sh`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.patchval/` (`A-run.log`, `B5-run.log`, `e2e-rf01/E2E-RESULT.md`)
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-01-ext4.txt`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-1/`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-01`)

## Caveats

- The Linux control ran on ext4 and tmpfs, because the host has no ext2 mount.
  The write(2) short-count contract does not depend on the filesystem, but the
  Linux column is ext4 evidence.
- Linux and Asterinas ran separately compiled builds of the same source (host
  gcc versus the initramfs toolchain), not one pinned binary.
- The v5 A/B evidence and the "promotion complete" label belong to the
  historical 01a snapshot at `604948581`. No runtime run on current main.
- The mechanism (count erasure) is the same as AST-04 and is tracked upstream
  in #711. Do not file it as a new mechanism. The new part is the durable
  file-data and offset/size mismatch on ext2.
- `repro/run.sh` and the description say to build and run the program inside
  the guest with `cc`. The stock Asterinas initramfs has no compiler. The
  binaries must be built into the initramfs, as the patch-validation record
  notes. See `docs/running-reproducers.md`.
