# AST-20: signalfd mask change omits newly eligible readiness

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-5, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `signalfd4` (update of an existing descriptor), `epoll_wait`, `epoll_ctl`, `kill`, `rt_sigprocmask` |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Reviewed: merged PR [#2245](https://github.com/asterinas/asterinas/pull/2245) (inverted mask filter in the old observer path) and merged PR [#3656](https://github.com/asterinas/asterinas/pull/3656) (signalfd signatures and comments). The confirmation also reviewed [#3655](https://github.com/asterinas/asterinas/pull/3655) and [#1837](https://github.com/asterinas/asterinas/pull/1837). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Historical guest evidence; current repair status not revalidated". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

When `signalfd4` changes the mask of an existing signalfd so that an
already-pending signal becomes readable, Asterinas stores the new mask but does
not notify pollers. An epoll instance that already watches the signalfd keeps
timing out, although a direct `poll` or `read` of the signalfd succeeds. The
missed readiness lasts until the signal is read directly or a new signal is
queued. Any unprivileged process that uses signalfd with epoll can observe it.
The run classified it as Critical.

## Linux contract

`signalfd(2)` allows `fd` to name an existing signalfd, in which case `mask`
replaces the set of signals the descriptor accepts, and the descriptor is
readable when a signal in the mask is pending. Linux `do_signalfd4`
(`fs/signalfd.c`, lines 274-279 of upstream as cited by the challenger)
updates the mask under `siglock` and wakes the signalfd wait queue, so epoll
re-polls it. The same test returns `EPOLLIN` on Linux.

- https://man7.org/linux/man-pages/man2/signalfd.2.html

## Asterinas behavior

- `kernel/core/src/syscall/signalfd.rs::update_existing_signalfd` calls only
  `SignalFile::update_signal_mask` (a relaxed atomic store) and
  `SignalFile::set_non_blocking`. It does not notify any `Pollee` or push the
  epoll entry.
- `kernel/core/src/syscall/signalfd.rs::SignalFile::poll` registers the epoll
  poller with the registering thread's queues through
  `kernel/core/src/process/posix_thread/mod.rs::PosixThread::register_signalfd_poller`
  (thread queue and process queue).
- `kernel/core/src/process/signal/sig_queues.rs::SigQueues::enqueue` is the only
  place that notifies the signalfd pollee, and it runs only when a signal is
  enqueued. The already-pending signal is not re-enqueued by a mask change.
- `kernel/core/src/events/epoll/file.rs::EpollFile::wait` waits for the ready
  set and does not rescan the whole interest set. The earlier empty-mask poll
  already removed the entry from the ready set.

## Reproduction

Level 0, single-threaded, public API only: block `SIGUSR1`, create a
nonblocking signalfd with an empty mask, add it to epoll, queue `SIGUSR1` with
`kill(getpid(), ...)`, check that `epoll_wait(.., 0)` returns 0, update the same
signalfd's mask to include `SIGUSR1`, then `epoll_wait` with a timeout. The
challenger's exact-counterexample variant queues the signal before
`EPOLL_CTL_ADD` and uses `EPOLLET`. See `repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- Round-6 standalone test: `SPECULA_REGRESSION_FAIL signalfd_mask_transition: mask update did not publish pending signal readiness`.
- Turn A (LT): `MC5_POSTUPDATE_EPOLL_WAIT=0 events=0x0`, `MC5_PENDING_SIGNAL_READ signo=10`, `MC5_CONTROL_POSTQUEUE_EPOLL_WAIT=1 events=0x1`, `MC5_REPRODUCED ...`.
- Challenger (ET, queue before add), two runs: `MC5_CE_POSTUPDATE_EPOLL_WAIT=0`, `MC5_CE_DIRECT_POLL=1 revents=0x1`, `MC5_CE_PENDING_SIGNAL_READ signo=10`, `MC5_CE_CONTROL_POSTQUEUE_EPOLL_WAIT=1`, `MC5_CE_REPRODUCED ...`.
- Linux: `MC5_POSTUPDATE_EPOLL_WAIT=1 events=0x1` and `MC5_CE_POSTUPDATE_EPOLL_WAIT=1 events=0x1`.

The fresh-signal control shows the epoll registration is still live, so the
failure is the missed mask-transition notification, not a dead registration.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends that
the mask update notify or re-evaluate the signalfd's registered signal-queue
pollers so epoll re-polls the file under the new mask, and adding the SMP=2
sequence to the signalfd/epoll regression suite. During packaging on
2026-09-24 a static read of upstream main `bc12195df` showed
`update_existing_signalfd` still only storing the mask and the nonblocking
flag. No runtime retest was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 5)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/reproduction.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/turn01_A.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/turn02_B.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug5_signalfd_mask_transition_smp2_round6_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_signalfd_mask_transition_smp2_round5_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s4_mask_transition_round2_bfs_cex.json (temporal property `MCRegisteredTransitionNotLost`, 8 states)
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section `signalfd_mask_transition`)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")

## Caveats

- The confirmed-bugs debate addendum points to a guest log at
  `confirmation/MC-5/worktree/qemu.log`, which no longer exists because the
  worktree was removed. The challenger's guest output survives in
  `reproduction.md` and the turn logs.
- The blocked self-`kill` takes the process-queue path in this implementation
  (`kernel/core/src/process/kill.rs`). Thread-directed signals and the
  registering-thread question are AST-22, a separate finding.
- This is not the historical signalfd binding model counterexample (AST-41).
  The Terra review states this explicitly.
- The turn-A program runs as guest init because the checkout's secondary
  `execve` path rejected the test ELF before user code in that environment. The
  syscall sequence under test is unchanged by that choice.
- Historical evidence at pin `4ba4abbe8cb3` only. The tested kernel carried
  Specula trace instrumentation, including a trace call in
  `update_existing_signalfd`. The Terra review found no added readiness branch.
