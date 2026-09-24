# AST-44: Pipe readv continues blocking after a completed positive prefix

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F02, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `readv`, `preadv2` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `pipe_readv_progress`, Linux evidence only) |

## Summary

A blocking `readv` on a pipe that holds 4 bytes, with two 4-byte iovecs and the write end still open, is predicted to fill the first iovec and then block in a second pipe read. Linux returns 4 at once. Programs that use `readv` on pipes can stall until the writer sends more data or a signal arrives.

## Linux contract

[pipe(7)](https://man7.org/linux/man-pages/man7/pipe.7.html) and [read(2)](https://man7.org/linux/man-pages/man2/read.2.html) let a read on a pipe return fewer bytes than requested when that is all the data available. [readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html) is one read into several buffers, so the iovec boundary does not create a second wait. The saved Linux runs show `readv=4 elapsed=0.000003 alarm_seen=0`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/preadv.rs::do_sys_readv` calls `file.read(writer)` for each iovec and stops only when the current writer still has space (`writer.has_avail()`) or when a read fails after progress (`Err(_) if total_len > 0 => break`). When the first iovec is filled exactly, the loop continues and the second `file.read` blocks on the empty pipe. `sys_readv` and `sys_preadv2` with `offset == -1` reach this loop.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `pipe_readv_progress` writes `ABCD` into a pipe, keeps the write end open, arms `alarm(1)`, and calls `readv` into two 4-byte iovecs. It passes when `readv` returns 4 with `ABCD` and the alarm has not fired. All five saved Linux executions report PASS, for example `readv=4 elapsed=0.000003 alarm_seen=0 (write end remained open)`. Source prediction for Asterinas at `a5449e62b`, not observed: `readv` blocks until the alarm fires, then returns 4 with `alarm_seen=1`, so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "Related vector-loop family; separate pipe progress/return contract". A repair would stop the loop once a pipe read has made progress and no more data is immediately available, or pass the whole vector to the pipe in one call as the attachment suggests.

No direct match in the searched scope. [#2230](https://github.com/asterinas/asterinas/pull/2230) (MERGED) handles later errors, [#1554](https://github.com/asterinas/asterinas/issues/1554) (CLOSED) is scalar PIPE_BUF atomicity, and [#3053](https://github.com/asterinas/asterinas/pull/3053) (MERGED) is FIONREAD and futex behavior. None covers a blocking pipe readv that keeps waiting after the first iovec returned data.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-pipe_readv_progress.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. The prediction that the blocked read ends with an error after the 1 s `SIGALRM`, and that the loop then returns 4, follows from the `Err(_) if total_len > 0` arm. If the signal does not interrupt the read, the harness's 5 s watchdog reports TIMEOUT instead. It is related to AST-03 and AST-43 through the same per-iovec loop, but the contract differs.
