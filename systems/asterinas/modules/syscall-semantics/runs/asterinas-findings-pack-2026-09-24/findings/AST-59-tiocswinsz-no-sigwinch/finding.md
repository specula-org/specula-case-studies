# AST-59: TIOCSWINSZ changes size without generating SIGWINCH

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F14, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `ioctl(TIOCSWINSZ)` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#1459](https://github.com/asterinas/asterinas/issues/1459) (closed shell hang) and [#3521](https://github.com/asterinas/asterinas/pull/3521) (merged termios2 support). |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tty_winsize_signal`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

Setting a new window size with TIOCSWINSZ stores the size but sends no
SIGWINCH to the terminal's foreground process group. Shells, editors and
terminal multiplexers that redraw on SIGWINCH would not react when a
terminal emulator or `stty` resizes a PTY. The getter reports the new size,
so a test that only reads it back passes.

## Linux contract

[TIOCSWINSZ(2const)](https://man7.org/linux/man-pages/man2/TIOCSWINSZ.2const.html):
when the window size changes, SIGWINCH is sent to the foreground process
group. The saved Linux 6.18 run received signal 28 (SIGWINCH) within 200 ms
after changing `ws_row`.

## Asterinas behavior

At the pin, the `SetWinSize` arm of
`kernel/core/src/device/tty/mod.rs::Tty::ioctl` reads the new size and calls
`kernel/core/src/device/tty/line_discipline.rs::LineDiscipline::set_window_size`,
which only assigns `self.winsize`.
`kernel/core/src/device/pty/master.rs::PtyMaster::ioctl` forwards
`SetWinSize` to the slave's `Tty::ioctl`, so both ends take this path.
Nothing in `kernel/core/src/device/` refers to SIGWINCH at the pin.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `tty_winsize_signal`
calls `setsid`, opens a PTY, makes the slave the controlling terminal with
TIOCSCTTY and `tcsetpgrp`, blocks SIGWINCH, changes `ws_row` with TIOCSWINSZ
and waits 200 ms in `sigtimedwait`. The saved Linux output is
`resize controlling PTY: received=28 expected=28 errno=0` (PASS). By source
reading, Asterinas at the pin would time out with `received=-1` and
`errno=11` and FAIL. The case has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to send SIGWINCH
to the foreground process group only when the size actually changes. The
cited files are byte-identical at upstream `bc12195df` (the pin's direct
child), checked on 2026-09-24 with a read-only `git diff`. Later upstream
commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-59)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F14)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `tty`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F14)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F14)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tty_winsize_signal.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-59)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Observe the signal, not only the getter state.
- Whether setting the same size again sends SIGWINCH is a separate question
  that this probe does not test.
- The probe needs working `setsid`, TIOCSCTTY and `tcsetpgrp` in the guest. A
  SETUP_ERROR there is not evidence either way.
- `tty_winsize_signal` is a legacy text-only case, so read the text line and
  the RESULT line.
