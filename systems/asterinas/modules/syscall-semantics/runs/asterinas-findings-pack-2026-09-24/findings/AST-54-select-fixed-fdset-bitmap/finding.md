# AST-54: Raw select uses a fixed libc-sized bitmap instead of nfds-sized input

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F10, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `select`, `pselect6` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `select_large_nfds`, `select_short_bitmap`, Linux evidence only) |

## Summary

Raw `select` treats every `fd_set` as the 1024-bit glibc type. It rejects `nfds > 1024` with `EINVAL` and always reads 128 bytes per set, so a caller that passes a bitmap sized for a small `nfds` at the end of a mapping gets `EFAULT`. Programs that call the syscall with dynamically sized bitmaps, or with more than 1024 descriptors, are affected.

## Linux contract

[select(2)](https://man7.org/linux/man-pages/man2/select.2.html) describes `FD_SETSIZE` as a limit of the glibc `fd_set` type and its macros. The attachment states that the kernel sizes the bitmaps from `nfds`. The saved Linux runs show `raw select(nfds=1025, empty sets)=0 errno=0` and `raw select(nfds=1, one-word bitmap at page end)=0 errno=0`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/select.rs::do_sys_select` returns `EINVAL` when `nfds as usize > FD_SETSIZE` (1024) and reads each non-NULL set with `user_space.read_val::<FdSet>(addr)`. `FdSet` is `[usize; FD_SETSIZE / USIZE_BITS]`, 128 bytes on x86-64. `kernel/core/src/syscall/pselect6.rs::sys_pselect6` calls the same `do_sys_select`.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `select_large_nfds` raises the soft `RLIMIT_NOFILE` to 2048 when the hard limit allows (SKIP otherwise) and calls raw `select(1025, NULL, NULL, NULL, {0,0})`. It passes when `select` returns 0. All five saved Linux executions report PASS, for example `raw select(nfds=1025, empty sets)=0 errno=0`. Source prediction for Asterinas at `a5449e62b`, not observed: `select` returns -1 with errno 22 (`EINVAL`), so the case reports FAIL.

Case `select_short_bitmap` places one zeroed `unsigned long` at the end of a readable page whose next page is `PROT_NONE`, and calls raw `select(1, bits, NULL, NULL, {0,0})`. It passes when `select` returns 0. All five saved Linux executions report PASS, for example `raw select(nfds=1, one-word bitmap at page end)=0 errno=0`. Source prediction for Asterinas at `a5449e62b`, not observed: the 128-byte read crosses into the `PROT_NONE` page, so `select` returns -1 with errno 14 (`EFAULT`) and the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The attachment's repair direction is to decode the bitmaps by the syscall's nfds-derived length and to keep the libc `FD_*` macro range separate from the kernel ABI.

No direct match in the searched scope. [#2782](https://github.com/asterinas/asterinas/issues/2782) (CLOSED) is a poll allocation failure with large nfds, and [#2734](https://github.com/asterinas/asterinas/pull/2734) (MERGED) adds SCML coverage for select. Neither addresses the fixed libc-sized fd_set.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/source-check.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/inputs/asterinas_tlpi_audit_v2.zip`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/metadata.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-select_large_nfds.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-select_short_bitmap.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. It must be tested through raw `syscall(SYS_select, ...)`. An ordinary `fd_set` with an out-of-range `FD_SET` is undefined in libc and is not a valid test. Not recorded by the attachment, but visible at the pin: `do_select` clears each whole `FdSet` and `do_sys_select` writes all 128 bytes back with `write_val`, so a readable and writable bitmap shorter than 128 bytes would have the bytes after it zeroed. That consequence was not tested.
