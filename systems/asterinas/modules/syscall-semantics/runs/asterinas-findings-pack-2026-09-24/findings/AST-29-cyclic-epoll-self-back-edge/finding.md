# AST-29: Cyclic epoll self/back-edge candidate

| Field | Value |
|---|---|
| Evidence status | DROPPED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding CR-6 (code review), Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none in this catalog. Upstream PR [#3395](https://github.com/asterinas/asterinas/pull/3395) proposed the same missing checks. |
| Syscalls | `epoll_ctl` (`EPOLL_CTL_ADD` of an epoll descriptor to itself or to a descendant), `epoll_wait`, `eventfd2`, `write` |
| Upstream | Non-actionable record (`NON_ACTIONABLE_RECORD` against upstream main `bc12195df`). PR [#3395](https://github.com/asterinas/asterinas/pull/3395) "Fix EpollTest.CycleOfOneDisallowed" adds self-edge rejection and graph-cycle detection in `EpollFile::control` and was closed without merge on 2026-06-24. The FD run's confirmation recorded novelty as KNOWN with this citation, fix status unfixed. Upstream fix status: not applicable. |
| Fix | Not applicable to this disposition. #3395 is the upstream reference if the cycle check is wanted. |
| Reproducer | repro/ (Linux control only. Asterinas NOT_RUN: the SMP=2 guest never reached QEMU.) |

## Summary

The code-review candidate said that `epoll_ctl` accepts an epoll descriptor
being added to itself, or a second epoll that closes a two-node cycle, and that
synchronous readiness callbacks could then re-enter a ready set while its lock
is held and deadlock. The finding was dropped: a cyclic topology is not a
supported operation (Linux rejects it), no failure on a supported acyclic path
was shown, the Asterinas guest never ran, and the mechanism was already
reported upstream as PR #3395. Do not re-report the missing cycle check as a
new finding. A demonstrated hang or deadlock on Asterinas would be new runtime
evidence that this record does not contain.

## Linux contract

`epoll_ctl(2)` returns `EINVAL` when `epfd` equals `fd` and `ELOOP` when `fd`
refers to an epoll instance and the `EPOLL_CTL_ADD` would create a circular
loop. The Linux control confirmed both, and it confirmed that the acyclic
nested case delivers the event.

- https://man7.org/linux/man-pages/man2/epoll_ctl.2.html

## Asterinas behavior

Static reading at the pin, which the Asterinas runtime never exercised:

- `kernel/core/src/syscall/epoll.rs::sys_epoll_ctl` and
  `kernel/core/src/events/epoll/file.rs::EpollFile::control` perform no
  self-edge or cycle check. `EpollFile::add_interest` rejects only a duplicate
  `(fd, file)` key.
- `kernel/core/src/events/epoll/entry.rs::ReadySet::push` holds its `entries`
  lock while it calls `Pollee::notify`, and `SyncSubject::notify_observers`
  (`kernel/core/src/events/subject.rs`) calls observers synchronously under its
  observer lock. A self-registration could route a notification back into the
  same ready set. The investigation did not establish a guest-visible deadlock
  for either topology.
- The comment in `ReadySet::push` shows intent to avoid one callback lock-order
  cycle, but nothing guards ready-set re-entry.

## Reproduction

`repro/test_bugCR-6_nested_epoll_cycle.c` first verifies an acyclic nested
chain (eventfd in epoll A, A in epoll B), then attempts either a self-edge
(`self` mode) or a two-epoll back-edge (`pair` mode). On Linux:

```text
CR6 ACYCLIC_CONTROL_OK ready=1 data=a11c events=1
CR6 SELF_EDGE_REJECTED errno=22 (Invalid argument)
CR6 ACYCLIC_CONTROL_OK ready=1 data=a11c events=1
CR6 PAIR_BACK_EDGE_REJECTED errno=40 (Too many levels of symbolic links)
```

An SMP=2 Asterinas initramfs with the static test was built, but the kernel
build failed in dependencies (`forward_overflowing is not a member of trait
Step` in `x86_64-0.15.5`, and a `catch_unwind` type mismatch) with both the
pinned July 2026 toolchain and the image's April 2026 toolchain. A fallback
with `nightly-2025-12-06` stalled and was stopped (exit 137). No Asterinas
syscall result was observed.

## Fix and upstream status

No fix is tracked for this disposition. The dedup pass notes that #3395 is
closed without merge and that the candidate remains DROPPED because its
support assumptions failed, not because a PR fixed a confirmed bug. The model
hunt for nested epoll (`MC_hunt_s6_nested`) found no violation.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 10)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/reproduction.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-6_guest-self.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-6_guest-pair.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-6_guest-run-image-nightly.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/bug-report.md ("Not Reproduced" table, nested epoll)
- /home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json (entry AST-29)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")

## Caveats

- Sources give two reasons for the drop, and the register keeps both: the
  native verdict emphasizes that the mechanism is KNOWN (#3395) and that the
  topology is unsupported, while the register and dedup pass say the
  supported-operation assumptions failed. Neither claims that Asterinas
  handles cycles correctly.
- Asterinas accepting a self-edge or cycle, if a later run shows it, is a Linux
  errno-compatibility gap already covered by #3395. It is not by itself a
  demonstrated deadlock.
- The debate did not run (0 rounds).
- The disposition is tied to pin `4ba4abbe8cb3`.
