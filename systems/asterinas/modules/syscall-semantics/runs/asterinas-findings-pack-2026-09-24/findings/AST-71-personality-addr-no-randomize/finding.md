# AST-71: personality ADDR_NO_RANDOMIZE setter may not change address layout

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), extra candidate C01, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `personality`, with the effect expected at `execve` |
| Upstream | Partial overlap. Open PR [#3560](https://github.com/asterinas/asterinas/pull/3560) "Add `/proc/sys/kernel/randomize_va_space`" acknowledges that `personality(ADDR_NO_RANDOMIZE)` does not disable randomization, but adds a read-only sysctl instead of fixing the setter. Related: open GDB tracking issue [#2323](https://github.com/asterinas/asterinas/issues/2323) and merged GDB patches PR [#3254](https://github.com/asterinas/asterinas/pull/3254). |
| Fix | Unfixed. PR #3560 does not implement the flag's effect. |
| Reproducer | none |

## Summary

`personality(ADDR_NO_RANDOMIZE)` is accepted and stored, and the getter
returns the flag, but the setter logs that ASLR is still not disabled.
Tools that turn off randomization this way before `execve`, such as
`setarch -R` and debuggers, may still get a randomized layout. No runtime
experiment exists, so the actual layout effect is unknown.

## Linux contract

[personality(2)](https://man7.org/linux/man-pages/man2/personality.2.html):
with ADDR_NO_RANDOMIZE set, address-space layout randomization is disabled.
Linux applies it to the layout of programs the process subsequently
executes.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/personality.rs::sys_personality` checks
for ADDR_NO_RANDOMIZE and emits
``warn!("`personality(ADDR_NO_RANDOMIZE)` is accepted, but still does not disable ASLR")``,
then stores the value with `set_personality` and returns the old one. A
FIXME in the same function says inheritance across `clone` and `execve` is
not yet worked out. Where and whether Asterinas randomizes the address
layout was not recorded by TLPI-v2.

## Reproduction

There is no runtime case. `case-plan.json` lists AST-71 under
`no_complete_attached_probe`. The TLPI-v2 plan (`docs/UNTESTED.md`) is to
build a fixed ELF, run it repeatedly through `execve` with fixed argv,
environment and build configuration, with and without the flag, and compare
the addresses the flag should affect. It also asks to record whether the
kernel randomizes by default. A `personality` set followed by a get proves
nothing about layout.

## Fix and upstream status

No fix exists. PR #3560 is open and scoped to exposing
`randomize_va_space`, not to making the setter take effect.
`personality.rs` is byte-identical at upstream `bc12195df` (the pin's direct
child), checked on 2026-09-24 with a read-only `git diff`. Later upstream
commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-71)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (C01)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (`no_complete_attached_probe`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md` (C01 section)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/evidence/source_index.md` (personality.rs entry)
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-71)

## Caveats

- C01 is an extra source candidate outside the F01..F26 count, and no
  executable case was supplied.
- The title says "may not". The register records only the setter's own
  warning, not a measured layout.
- Whether Asterinas randomizes layout at all in its default configuration is
  not recorded. `docs/UNTESTED.md` asks for that to be recorded,
  because the flag has a visible effect only when randomization is on.
