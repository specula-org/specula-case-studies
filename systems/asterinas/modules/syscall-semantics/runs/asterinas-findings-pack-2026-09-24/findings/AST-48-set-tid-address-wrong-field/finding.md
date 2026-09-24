# AST-48: set_tid_address ignores its pointer and updates the wrong TID field

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F05, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `set_tid_address`, `clone`, `exit` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | none (no runtime case was supplied, imported runtime status NOT_RUN) |

## Summary

`set_tid_address` ignores its argument. It never registers `tidptr` as the clear-child-TID address, so a thread exit will not clear and wake the address the caller registered. A thread created with `CLONE_CHILD_CLEARTID` that later calls `set_tid_address` reaches a `todo!()` branch, which panics in the kernel.

## Linux contract

[set_tid_address(2)](https://man7.org/linux/man-pages/man2/set_tid_address.2.html) sets the calling thread's `clear_child_tid` to `tidptr` and returns the caller's TID. When a thread whose `clear_child_tid` is not NULL terminates, the kernel writes 0 at that address and performs a `FUTEX_WAKE`. [clone(2)](https://man7.org/linux/man-pages/man2/clone.2.html) sets the same field for `CLONE_CHILD_CLEARTID`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/set_tid_address.rs::sys_set_tid_address` uses `tidptr` only in `debug!`. It reads `ctx.thread_local.clear_child_tid()`, executes `todo!()` if that is nonzero, and otherwise calls `set_child_tid().set(clear_child_tid)`. `kernel/core/src/process/clone.rs::clone_child_cleartid` sets `clear_child_tid` for `CLONE_CHILD_CLEARTID`, which makes the `todo!()` branch reachable. `kernel/core/src/process/posix_thread/exit.rs::wake_clear_ctid` is the exit-time clear and wake.

## Reproduction

There is no runtime reproducer. `case-plan.json` lists AST-48 under `no_complete_attached_probe`. The attachment's `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md` requires a disposable VM with an external watchdog. Test first registration, overriding registration and clearing separately, and observe clearing and waking through a shared mapping and an explicit exit handshake. Reaching the `todo!()` branch needs a thread created with `CLONE_CHILD_CLEARTID` that then calls `set_tid_address`.

## Fix and upstream status

No fix is recorded. The register notes: "Includes a todo branch; no complete runtime case and no observed panic impact". The attachment's repair direction is to store `tidptr` in `clear_child_tid`, return the TID, and leave clearing and waking to the exit path, which `wake_clear_ctid` already implements.

No direct match in the searched scope. Reviewed and not matching: [#1761](https://github.com/asterinas/asterinas/pull/1761) (MERGED, ThreadLocal), [#2214](https://github.com/asterinas/asterinas/issues/2214) (CLOSED, Podman tracking), [#1433](https://github.com/asterinas/asterinas/pull/1433) (MERGED, exit munmap panic), and [#3053](https://github.com/asterinas/asterinas/pull/3053) (MERGED, futex wake matching).

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/docs/UNTESTED.md`

## Caveats

No runtime case was supplied and none ran. The default attachment suite deliberately avoids the `todo!()` branch. The attachment says the panic's whole-machine effect was not measured. A reproducer should not use libc's own thread-management memory as its test object.
