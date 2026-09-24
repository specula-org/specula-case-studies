# AST-17: epoll disables one-shot interest before successful delivery

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-2, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `epoll_wait` (reproduced), `epoll_ctl` (`EPOLL_CTL_MOD` is the only recovery). `epoll_pwait` and `epoll_pwait2` share the same copy-out loop (static reachability only). |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Nearest reviewed records: merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277), which discusses disabled versus deleted one-shot interests but not disabling before copy-out, and closed issue [#868](https://github.com/asterinas/asterinas/issues/868). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Historical SMP=2 guest evidence; current repair status not revalidated". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

For an `EPOLLONESHOT` interest, Asterinas disables the interest while it
collects the event, before `epoll_wait` copies that event to user memory. If
the copy faults, `epoll_wait` returns `EFAULT` but the interest stays disabled,
so a retry with a valid buffer returns 0 and the still-readable descriptor is
never reported until the caller issues `EPOLL_CTL_MOD`. Any unprivileged
process that uses `EPOLLONESHOT` can observe this. The run classified it as
Critical.

## Linux contract

`epoll(7)` says that with `EPOLLONESHOT` the descriptor is disabled after an
event is pulled out with `epoll_wait(2)`, and must be rearmed with
`EPOLL_CTL_MOD`. A call that returned `EFAULT` pulled no event out. Linux's
`ep_send_events`/`ep_deliver_event` in `fs/eventpoll.c` copies the event first,
puts the item back on a copy fault, and clears the one-shot interest only after
a successful copy (lines 1976-2000 of upstream `fs/eventpoll.c` as cited by the
challenger). The Linux control redelivered the event.

- https://man7.org/linux/man-pages/man7/epoll.7.html
- https://man7.org/linux/man-pages/man2/epoll_wait.2.html

## Asterinas behavior

- `kernel/core/src/events/epoll/entry.rs::Entry::poll` builds the event and,
  for `ONE_SHOT`, calls `Observer::reset_enabled` before returning it.
- `kernel/core/src/events/epoll/file.rs::EpollFile::pop_multi_ready` has
  already removed the entry from the ready list, and
  `kernel/core/src/syscall/epoll.rs::do_epoll_pwait2` copies the collected
  vector afterwards with `user_space.write_val(..)?`. A fault returns `EFAULT`
  with no path that re-enables the entry.
- `kernel/core/src/events/epoll/entry.rs::ReadySet::push` returns immediately
  for a disabled observer, so later notifications from the eventfd are dropped.
- `kernel/core/src/events/epoll/entry.rs::Entry::update`, reached from
  `EPOLL_CTL_MOD` through `EpollFile::mod_interest`, is the only re-enable path.

## Reproduction

Level 0, public API only, no kernel change. Create a nonblocking eventfd,
register it with `EPOLLIN | EPOLLONESHOT`, write 1, call `epoll_wait` with the
invalid buffer address `1` (expect `-1/EFAULT`), then call `epoll_wait` again
with a valid buffer. Asterinas returns 0 and Linux returns the event. See
`repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- Confirmation turn A (Stage-2 driver, three logs):
  `SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT (errno=0)`.
- Round-6 standalone test: `SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT`.
- Linux control `test_bugMC-2_challenge.c`: `MC2_CONTROL_PASS first=-1/EFAULT retry=1 token=4d43325f45464155`.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends
deferring each one-shot disable until its event has been copied out, and
preserving or requeueing entries that were not copied after `EFAULT`, handled
per event rather than for the whole vector. During packaging on 2026-09-24 a
static read of upstream main `bc12195df` showed the same shape
(`reset_enabled` inside `Entry::poll`, copy-out afterwards). No runtime retest
was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 2)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.final.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.repeat2.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.run.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug2_epoll_efault_oneshot_smp2_round6_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_copyout_oneshot_smp2_round5_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s2_oneshot_round2_bfs_cex.json (invariant `MCOneShotDisabledIffDelivered`, 10 states)
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section `copyout_oneshot`)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")

## Caveats

- Historical evidence at pin `4ba4abbe8cb3` only. Current repair status was not
  revalidated.
- The challenger's fresh guest rerun did not reach QEMU because Cargo failed to
  fetch `inherit-methods-macro` over TLS. The verdict relies on the earlier
  completed SMP=2 guest runs and does not count the blocked rerun.
- The tested kernel carried Specula TLA+ trace instrumentation. The Terra
  review found no added readiness, rollback, or cleanup branch on this path.
  Run line numbers (for example `entry.rs:145`) refer to the instrumented copy.
- Only `maxevents = 1` was tested.
- The Terra review counted this entry and AST-16 as one commit-before-copy-out
  mechanism. A fix for one should be checked against the other.
