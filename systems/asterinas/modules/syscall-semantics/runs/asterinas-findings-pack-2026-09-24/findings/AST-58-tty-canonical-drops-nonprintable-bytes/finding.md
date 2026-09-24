# AST-58: TTY canonical input drops bytes outside its printable-ASCII filter

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F13, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `write` on a PTY master, `read` on the slave |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#3695](https://github.com/asterinas/asterinas/pull/3695) (merged) and [#3687](https://github.com/asterinas/asterinas/pull/3687) (closed unmerged), which change signal-character handling only. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tty_canonical_bytes`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

In canonical mode the line discipline appends a byte to the current line
only if it is printable ASCII (0x20 to 0x7e). Other bytes that are not
special characters, such as UTF-8 lead and continuation bytes, are silently
discarded. A program typing or piping non-ASCII text into a canonical
terminal reads back only the ASCII part and the line terminator.

## Linux contract

[termios(3)](https://man7.org/linux/man-pages/man3/termios.3.html): with
ISTRIP clear, the eighth bit is kept, and canonical input stores every byte
that is not a special editing or line character. The saved Linux 6.18 run
wrote `c3 a9 0a` to the master and read the same three bytes from the slave.

## Asterinas behavior

At the pin, the canonical branch of
`kernel/core/src/device/tty/line_discipline.rs::LineDiscipline::push_char`
handles VKILL, VERASE and line terminators, then appends the byte to
`current_line` only when
`kernel/core/src/device/tty/line_discipline.rs::is_printable_char` returns
true for the range `0x20..0x7f`. There is no other branch that stores the
byte, so it is lost. The raw-mode branch pushes every byte and is not
affected.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `tty_canonical_bytes`
opens a PTY pair, sets canonical mode with VMIN=1 after `cfmakeraw` (which
clears ISTRIP), writes `c3 a9 0a` to the master and reads the slave. The
saved Linux output is `canonical UTF-8 bytes: read=3 data=c3a90a` (PASS). By
source reading, Asterinas at the pin would print `read=1 data=0a` and FAIL.
The case has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to process bytes
according to termios and stop using printable ASCII as the storage
condition. The cited file is byte-identical at upstream `bc12195df` (the
pin's direct child), checked on 2026-09-24 with a read-only `git diff`.
Later upstream commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-58)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F13)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `tty`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F13)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F13)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tty_canonical_bytes.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-58)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The probe checks byte preservation only. It does not audit canonical
  editing, erase of multibyte characters, or echo. The same
  `is_printable_char` predicate also gates echo in
  `LineDiscipline::output_char`, which no probe covers.
- AST-56 and AST-57 are separate defects in the same `LineDiscipline`.
- `tty_canonical_bytes` is a legacy text-only case, so read the text line and
  the RESULT line.
