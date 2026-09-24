# AST-16: epoll copy-out EFAULT loses edge-triggered readiness

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-1, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `epoll_wait` (reproduced). `epoll_pwait` and `epoll_pwait2` share the same `do_epoll_pwait2` copy-out loop (static reachability only). |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Nearest reviewed records: merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277) (epoll identity and observer ownership) and closed issue [#868](https://github.com/asterinas/asterinas/issues/868) (epoll test crash, VMAR page fault). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Historical SMP=2 guest evidence; current repair status not revalidated". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

When `epoll_wait` is given an unwritable event buffer, Asterinas removes a
ready `EPOLLET` entry from the epoll ready list before it copies the event to
user memory, and then returns `EFAULT` without putting the entry back. A later
`epoll_wait` with a valid buffer returns 0 even though the watched eventfd is
still unread, so an edge-triggered event loop can stall until an unrelated new
edge arrives. Any unprivileged process that uses `EPOLLET` can observe this.
The run classified it as Critical in `bug-severity.md`.

## Linux contract

`epoll_wait(2)` lists `EFAULT` for an event buffer that is not writable, and
`epoll(7)` describes edge-triggered delivery as consumed by an
`epoll_wait` call that returns the event. A call that failed with `EFAULT`
returned no event, so the edge must still be reported by the next call.
Linux `fs/eventpoll.c` puts the selected item back on the ready list when the
copy to user space faults, before it applies the ET/LT completion step (as read
by the confirmation challenger). The same test passes on host Linux.

- https://man7.org/linux/man-pages/man2/epoll_wait.2.html
- https://man7.org/linux/man-pages/man7/epoll.7.html

## Asterinas behavior

- `kernel/core/src/syscall/epoll.rs::do_epoll_pwait2` calls
  `EpollFile::wait`, which returns a `Vec<EpollEvent>` that is already
  committed, and only then copies each event with `user_space.write_val(..)?`.
  The `?` returns `EFAULT` with no rollback path.
- `kernel/core/src/events/epoll/file.rs::EpollFile::pop_multi_ready` pops the
  entry through `kernel/core/src/events/epoll/entry.rs::ReadySetPopIter::next`
  (which clears the observer's ready bit) and requeues it only when
  `Entry::poll` reports `is_still_ready`.
- `kernel/core/src/events/epoll/entry.rs::Entry::poll` returns
  `is_still_ready = false` for an entry with `EPOLLET` (or `EPOLLONESHOT`).
- The entry can re-enter the ready list only through a new observer
  notification (`Observer::on_events` to `ReadySet::push`). An unread eventfd
  produces no new notification, so the lost edge is never redelivered.

## Reproduction

Level 0, public API only, no kernel change. Create a nonblocking eventfd,
register it with `EPOLLIN | EPOLLET`, write 1, call `epoll_wait` with the
invalid buffer address `1` (expect `-1/EFAULT`), then call `epoll_wait` again
with a valid buffer and timeout 0. Asterinas returns 0 on the second call and
Linux returns the event. See `repro/README.md` for the build and run commands.

Recorded Asterinas SMP=2 results at the pin:

- Round-6 standalone test: `SPECULA_REGRESSION_FAIL copyout_et: ready event was not retained after EFAULT`.
- Confirmation challenger, twice: `MC1_CASE name=edge_after_efault first=-1 first_errno=14 second=0 ... unread=1`, while the level-triggered control redelivered (`second=1`).

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The dedup pass on
2026-09-14 found no direct upstream report. The run's recommendation is to
commit the ready-list removal only after all selected events copy out, or to
restore every selected entry before returning a copy-out error, and to define
the result for a partially copied multi-event wait. During packaging on
2026-09-24 a static read of upstream main `bc12195df` showed the same shape
(copy-out after `EpollFile::wait`, `?` on `write_val`). No runtime retest was
done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 1)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/challenger-reproduction.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/repro_smp2_rebuilt_artifact.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug1_epoll_efault_et_smp2_round6_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_repro_smp2_round6_manifest.txt
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_copyout_et_smp2_round5_attempt2.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s2_copyout_round2_bfs_cex.json (invariant `MCDeliveryCommitOnCopyout`, 9 states)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/bug-severity.md
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section `copyout_et`)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")
- /home/chin39/Documents/play/specula-profile/reports/workflow-validation.md (Stage 2 and Stage 3 sections)

## Caveats

- Historical evidence at pin `4ba4abbe8cb3` only. The register says the current
  repair status was not revalidated, and no runtime test ran on a newer tree.
- The tested kernel was built from the run's private source copy, which carried
  Specula TLA+ trace instrumentation. The independent Terra review found that
  the instrumentation added no readiness, rollback, or cleanup branch on this
  path.
- Line numbers in the run artifacts (for example `file.rs:244`) refer to that
  instrumented copy. In the clean pin, `pop_multi_ready` starts at
  `file.rs:210`. Use the symbol names above.
- Only `maxevents = 1` was tested. The correct result for a partially copied
  multi-event wait was not tested.
- The Terra review counted this entry and AST-17 as one commit-before-copy-out
  mechanism with two observable modes. A fix for one should be checked against
  the other.
