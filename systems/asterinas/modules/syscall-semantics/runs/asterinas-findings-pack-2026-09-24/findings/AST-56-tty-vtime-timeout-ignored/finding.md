# AST-56: TTY noncanonical reads omit VTIME timeout behavior

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F12, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `read`, `ioctl` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `tty_vtime`, Linux evidence only) |

## Summary

Noncanonical TTY reads ignore `VTIME`. With `VMIN=0` and `VTIME=1` and no input, Asterinas is predicted to return 0 at once, while Linux waits about 0.1 s. Programs that poll a terminal or serial line with a `VTIME` timeout get an immediate 0 instead of a bounded wait. By the same code, the `VMIN>0`, `VTIME>0` inter-byte timer is also absent, but no probe covers that case.

## Linux contract

[termios(3)](https://man7.org/linux/man-pages/man3/termios.3.html) defines noncanonical `MIN == 0, TIME > 0` as a read that returns as soon as a byte is available or when `TIME` tenths of a second expire, returning 0 in the second case. VMIN and VTIME apply only to noncanonical mode. The saved Linux runs show `read=0` with elapsed times from 0.100352 to 0.103384 s.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/device/tty/line_discipline.rs::LineDiscipline::try_read` reads `VMIN` and `VTIME`, calls `warn!("non-zero VTIME is not supported")` when `VTIME != 0`, and returns `EAGAIN` only when fewer than `min(dst.len(), vmin)` bytes are buffered. With `VMIN=0` that check never fires, so it returns `Ok(0)` immediately. `kernel/core/src/device/tty/mod.rs::Tty::read` calls `wait_events(IoEvents::IN, None, ...)` under `// TODO: Add support for timeout.`

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `tty_vtime` opens a PTY pair with `posix_openpt`, sets the slave to raw noncanonical mode with `VMIN=0` and `VTIME=1`, and times one `read` of 1 byte with no input. It passes when `read` returns 0 after at least 0.05 s. All five saved Linux executions report PASS, for example `noncanonical VMIN=0 VTIME=1: read=0 elapsed=0.102904` (5 distinct lines, because PIDs or timings vary). Source prediction for Asterinas at `a5449e62b`, not observed: `read` returns 0 almost immediately (well under 0.05 s), so the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "PTY setup and timing bounds need target verification". The attachment's repair direction is to implement the four noncanonical VMIN/VTIME cases and to finish canonical reads by line without VMIN (the canonical half is AST-57).

No direct match in the searched scope. [#2108](https://github.com/asterinas/asterinas/pull/2108) (MERGED, TTY abstraction refactor) and [#3521](https://github.com/asterinas/asterinas/pull/3521) (MERGED, TCGETS2/TCSETS2) discuss VMIN=VTIME=0 and the termios2 layout and keep the nonzero-VTIME warning without implementing the timeout. [#387](https://github.com/asterinas/asterinas/issues/387) (CLOSED) tracked the gVisor pty test.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tty_vtime.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. The attachment warns that timing results are sensitive to heavy scheduling delay and that PTY setup must succeed first, otherwise the case reports SETUP_ERROR. The canonical-mode VMIN problem in the same function is the separate entry AST-57.
