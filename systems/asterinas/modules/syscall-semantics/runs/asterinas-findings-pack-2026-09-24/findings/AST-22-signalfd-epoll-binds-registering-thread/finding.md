# AST-22: signalfd epoll readiness binds to the registering thread

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding CR-4 (code review), Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none. Not the same record as AST-41, the discarded signalfd binding model oracle from the same run. |
| Syscalls | `epoll_ctl` (registration thread), `epoll_wait` (other thread), `tgkill` via `pthread_kill`, `signalfd4`, `read` on the signalfd |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Reviewed: open issue [#200](https://github.com/asterinas/asterinas/issues/200) (epoll notification and fork), merged PR [#3656](https://github.com/asterinas/asterinas/pull/3656) (signalfd signatures and comments), merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277). The confirmation also reviewed [#1837](https://github.com/asterinas/asterinas/pull/1837) and [#2245](https://github.com/asterinas/asterinas/pull/2245). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Separate runtime finding from the discarded AST-41 model oracle". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

When thread A adds a signalfd to an epoll instance, Asterinas registers the
epoll poller only with thread A's signal queues. If a signal is then directed at
thread B (for example with `pthread_kill`) and B waits on the same epoll
instance, the signal lands in B's queue, nothing notifies the epoll entry, and
B's `epoll_wait` times out even though B's direct `read` of the signalfd
returns the signal. A multithreaded event loop that registers from one thread
and waits from another can hang. The run classified it as Critical.

## Linux contract

`signalfd(2)` says a thread reading a signalfd receives signals directed to
itself and signals directed to the process, and that the descriptor can be
monitored with `poll`, `select`, and `epoll`, being readable when a matching
signal is pending. Linux `signalfd_poll` registers on the thread group's shared
`sighand->signalfd_wqh` and checks the calling thread's private and shared
pending sets. Because the wait queue is shared by the thread group,
registration by another thread does not hide the waiter's thread-directed
signal. The identical test passes on Linux in all
eight iterations.

- https://man7.org/linux/man-pages/man2/signalfd.2.html
- https://man7.org/linux/man-pages/man7/signal.7.html

## Asterinas behavior

- `kernel/core/src/events/epoll/entry.rs::Entry::update` calls
  `file.poll(.., Some(poller))` in the context of the thread that runs
  `epoll_ctl` (`EPOLL_CTL_ADD` or `EPOLL_CTL_MOD`).
- `kernel/core/src/syscall/signalfd.rs::SignalFile::poll` takes
  `current_thread!()` and calls
  `kernel/core/src/process/posix_thread/mod.rs::PosixThread::register_signalfd_poller`,
  which registers with that thread's `SigQueues` and the process `SigQueues`.
- A thread-directed signal goes through `kernel/core/src/process/kill.rs::tgkill`
  to the target thread's `enqueue_signal`, and
  `kernel/core/src/process/signal/sig_queues.rs::SigQueues::enqueue` notifies
  only the pollee of the queue that received the signal (thread B's).
- `kernel/core/src/syscall/signalfd.rs::SignalFile::read` uses the reader's
  own pending set, so B can read the signal directly.
- `kernel/core/src/events/epoll/file.rs::EpollFile::wait` re-polls entries only
  after an observer puts them on the ready list, so re-polling from B never
  happens.

## Reproduction

Level 0, public API only, no timing aid. Thread A blocks `SIGUSR1`, creates a
nonblocking signalfd and an epoll instance, and adds the signalfd. Thread B
inherits the mask and blocks on a pipe. A sends `SIGUSR1` to B with
`pthread_kill`, then releases B. B calls `epoll_wait` twice with a bounded
timeout, then reads the signalfd directly. See `repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- `CR4 iteration=0 epoll_rc=0 ... epoll_retry_rc=0 ... read_rc=128 read_errno=0 signo=10 outcome=42` then `CR4_RESULT=PERSISTENT_MISS: two epoll_wait calls timed out while the same thread directly read its pending SIGUSR1 from signalfd` (turn A and the challenger's replay).
- Control where B registers: `CR4_CONTROL ... epoll_rc=1 ... epoll_events=0x1` and `CR4_CONTROL_RESULT=REGISTRATION_ACTOR_OK`.
- Control where B exists before A registers: `CR4_PREEXISTING_RESULT=PERSISTENT_MISS`.
- Linux: all eight iterations `epoll_rc=1 epoll_events=0x1`, then `CR4_RESULT=NO_MISS`.

The pair of controls isolates the registering thread's identity as the cause.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends
registering signalfd epoll observers against readiness state shared by every
thread that may consume the shared signalfd, or notifying the shared signalfd
observer for each thread-directed queue. It warns against relying on
re-polling inside `epoll_wait`, which happens only after an observer was
already queued. During packaging on 2026-09-24 a static read of upstream main
`bc12195df` showed `SignalFile::poll` still using `current_thread!()` for
registration. No runtime retest was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 8)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/challenge_B.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_thread_registration.asterinas.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_challenger.asterinas.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_registration_actor_control.asterinas.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_preexisting_waiter.asterinas.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/bug-severity.md
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")
- /home/chin39/Documents/play/specula-profile/reports/workflow-validation.md (Stage 3 section)

## Caveats

- This finding came from code review, not from the model. After the AST-41
  oracle correction, the model's signalfd binding hunt (`MC_hunt_s4_binding`)
  reported no violation, so the model does not cover this failure.
- The register keeps AST-22 and AST-41 separate. AST-41 is the discarded model
  oracle from the same run. Its trace has the same shape (registration by one
  thread, a thread-directed signal pending for the epoll consumer), but it ends
  at a structural oracle violation with no caller-visible result, and
  validation judged the oracle itself wrong. AST-22 is the runtime failure.
  When deduplicating a new candidate, a missed epoll wakeup for a signal
  directed at a non-registering thread belongs here.
- Process-directed signals are covered by the registering thread's process
  queue and were not shown to fail. The failure needs a thread-directed signal
  to a thread other than the one that ran `epoll_ctl`.
- The Terra review predates this finding and did not review it.
- Historical evidence at pin `4ba4abbe8cb3` only. The tested kernel carried
  Specula trace instrumentation. The challenger noted that trace collection is
  active only for threads named `specula-t1` or `specula-t2` through
  `PR_SET_NAME`, which the CR-4 tests never set, and that `SignalFile::poll`,
  `SignalFile::read`, `register_signalfd_poller`, and `SigQueues` were not
  instrumented.
