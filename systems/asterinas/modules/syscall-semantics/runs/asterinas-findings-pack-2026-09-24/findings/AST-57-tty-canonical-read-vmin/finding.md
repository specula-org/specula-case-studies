# AST-57: TTY canonical reads apply the noncanonical VMIN threshold

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F12, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `read` on a TTY or PTY slave |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#2108](https://github.com/asterinas/asterinas/pull/2108), [#3521](https://github.com/asterinas/asterinas/pull/3521), [#3695](https://github.com/asterinas/asterinas/pull/3695), all merged, none repairs this. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tty_canonical_vmin`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

In canonical (ICANON) mode, the TTY line discipline still refuses to return
data until `min(buffer length, VMIN)` bytes are buffered. A completed line
shorter than VMIN therefore yields EAGAIN on a nonblocking slave and keeps a
blocking reader waiting, where Linux returns the line. Any program that sets
VMIN above 1 and then reads a canonical terminal can observe it.

## Linux contract

[termios(3)](https://man7.org/linux/man-pages/man3/termios.3.html): in
canonical mode, input is made available line by line, and a read returns as
soon as a line delimiter arrives. VMIN and VTIME are described only under
noncanonical mode. The saved Linux 6.18 run read the 2-byte line `x\n` with
VMIN=5.

## Asterinas behavior

At the pin, `kernel/core/src/device/tty/line_discipline.rs::LineDiscipline::try_read`
reads VMIN and returns EAGAIN when `self.buffer_len() < dst.len().min(vmin)`.
The check runs before the canonical-mode handling in the same function.
`LineDiscipline::push_char` moves a canonical line into the read buffer only
when its terminator arrives, so the buffered count is the completed line.
`kernel/core/src/device/tty/mod.rs::Tty::read` calls `try_read` once for
O_NONBLOCK and otherwise loops in `wait_events(IoEvents::IN, None, ..)`, so a
blocking reader waits until VMIN bytes are buffered.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `tty_canonical_vmin`
opens a PTY pair, sets canonical mode with VMIN=5 and VTIME=0, makes the
slave nonblocking, writes `x\n` to the master and polls `read` for up to
0.2 s. The saved Linux output is
`canonical VMIN=5, complete two-byte line: read=2 errno=0` (PASS). By source
reading, Asterinas at the pin would print `read=-1 errno=11` and FAIL. The
case has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to complete
canonical reads per line and apply VMIN only in noncanonical mode. The cited
files are byte-identical at upstream `bc12195df` (the pin's direct child),
checked on 2026-09-24 with a read-only `git diff`. Later upstream commits
were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-57)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F12 split into AST-56 and AST-57)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `tty`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F12)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F12)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tty_canonical_vmin.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-57)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build, not from a run
  in this workspace.
- AST-56 covers the separate VTIME timeout gap from the same TLPI group F12.
  Keep the two apart when fixing or deduplicating.
- The effect needs VMIN greater than the completed line length. With the
  common VMIN=1 the check passes as soon as one byte is buffered.
- `tty_canonical_vmin` is a legacy text-only case. Its comparison projection
  is empty, so read the text line and the RESULT line.
