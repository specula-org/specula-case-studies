# AST-23: epoll_pwait/pselect6 timeout skips deferred pipe readiness

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding CR-5 (code review), Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `epoll_pwait` and `pselect6` (final SMP=2 trace). `epoll_wait` and `ppoll` also failed, in the first SMP=2 execution and in the one-vCPU challenger run. |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Reviewed: merged PR [#1049](https://github.com/asterinas/asterinas/pull/1049), merged PR [#1831](https://github.com/asterinas/asterinas/pull/1831), open PR [#3576](https://github.com/asterinas/asterinas/pull/3576) (syscall restart refactor). The confirmation also reviewed [#858](https://github.com/asterinas/asterinas/pull/858), [#2025](https://github.com/asterinas/asterinas/pull/2025), [#3050](https://github.com/asterinas/asterinas/pull/3050), [#3060](https://github.com/asterinas/asterinas/pull/3060), and [#3384](https://github.com/asterinas/asterinas/pull/3384). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Related timeout class to AST-21; distinct wait path and witness". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2, and at SMP=1 by the challenger) |

## Summary

A waiter that is woken by pipe readiness before its deadline, but is not
scheduled until after the deadline, gets a timeout result from Asterinas. The
wait layer decides `ETIME` purely from the expired timer, and the epoll and
poll layers turn that into a 0 return without a final readiness check. The
caller sees 0 from `epoll_pwait` or `pselect6` (and also `epoll_wait` and
`ppoll`), and an immediate zero-timeout retry finds the pipe ready. Temporary
signal masks were restored correctly. The run classified it as High.

## Linux contract

`epoll_wait(2)` returns 0 only if no file descriptor became ready during the
requested timeout, and `poll(2)`/`select(2)` define the same meaning for 0.
Readiness, signal, and timeout are the terminal outcomes, and readiness that
happened before the deadline must not be reported as a timeout. The identical
static binary booted as PID 1 on a Linux 7.1.8 one-vCPU guest returned 1 for
all four calls under the same FIFO ordering.

- https://man7.org/linux/man-pages/man2/epoll_wait.2.html
- https://man7.org/linux/man-pages/man2/poll.2.html
- https://man7.org/linux/man-pages/man2/select.2.html

## Asterinas behavior

- `kernel/core/src/process/signal/pause.rs::Waiter::pause_timeout` waits, then
  returns `ETIME` whenever the timeout timer has no remaining time, regardless
  of whether an I/O wakeup came first.
- `kernel/core/src/process/signal/poll.rs::Pollable::wait_events` propagates an
  error from `Poller::wait` directly, without rerunning its readiness closure.
  `kernel/core/src/events/epoll/file.rs::EpollFile::wait` uses this helper.
- `kernel/core/src/syscall/epoll.rs::do_epoll_pwait2` maps `ETIME` to `Ok(0)`.
  This covers `epoll_wait`, `epoll_pwait`, and `epoll_pwait2`.
- `kernel/core/src/syscall/poll.rs::do_poll` maps `ETIME` to `Ok(0)` before
  `count_events`. `ppoll` reaches it through `do_sys_poll`, and `pselect6`
  through `kernel/core/src/syscall/select.rs::do_sys_select`.
- The signal-mask sub-claim of the original code-review candidate did not
  reproduce. Mask restoration is centralized in the user-task return path, and
  every observed case reported the original mask restored.

## Reproduction

Level 1 (timing assistance through public scheduler APIs only, no kernel
change). Parent and child are pinned to CPU 0. The child waits until the
parent has entered the wait, sleeps 30 ms, switches to `SCHED_FIFO`, records a
`CLOCK_MONOTONIC` timestamp, writes one byte to a pipe well before the parent's
200 ms deadline, and then keeps the CPU for 350 ms. The parent therefore runs
again only after its deadline. A zero return with `before_deadline=1` and a
ready zero-timeout retry is the failure. See `repro/README.md`.

Recorded results at the pin:

- Asterinas SMP=2 final trace: `CR5_PRIORITY api=epoll_pwait ret=0 ... post_ret=1 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=382 mask_blocked=1` and the same for `pselect6` (381 ms), then `CR5_RESULT FAIL failures=2`. In that trace `epoll_wait` and `ppoll` returned 1 after about 30 ms.
- Asterinas one vCPU (challenger): all four APIs `ret=0 ... post_ready=1 before_deadline=1 returned_after_deadline=1`, `CR5_RESULT FAIL failures=4`.
- Linux 7.1.8 one vCPU: all four `ret=1`, `CR5_RESULT PASS failures=0`.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends
keeping the saved-mask restoration unchanged and, before mapping `ETIME` to a
user-visible 0, either preserving the wake cause or rescanning the registered
descriptors once, while keeping the existing `EINTR` precedence. It also asks
for a one-vCPU FIFO regression covering `epoll_wait`, `epoll_pwait`, `ppoll`,
and `pselect6`, with the timestamp moved to immediately after the pipe write.
AST-21 has the same shape on `poll`, so one fix in the wait layer may cover
both. During packaging on 2026-09-24 a static read of upstream main
`bc12195df` showed the same `ETIME` to `Ok(0)` arms in `do_epoll_pwait2` and
`do_poll`. No runtime retest was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 9)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/turn02_B.log (raw one-vCPU Asterinas and Linux outputs)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-5_wait_mask.smp2.log (final SMP=2 trace)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/repro-asterinas-exact-priority-smp2-final.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/repro-asterinas-exact-pressure-smp2.log (superseded preliminary run, no anomaly)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/repro-linux-final-control.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/error.txt (first-attempt adapter failure)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/bug-severity.md
- /home/chin39/Documents/play/specula-profile/reports/workflow-validation.md (Stage 3 section)

## Caveats

- The register title names `epoll_pwait/pselect6` because those two failed in
  the final SMP=2 trace. The first SMP=2 execution exposed `epoll_wait` and
  `ppoll`, and the one-vCPU run exposed all four. The mechanism is not specific
  to mask-taking waits.
- On this checkout `sched_setaffinity` only stores the requested set and does
  not migrate threads, so the SMP=2 pinning argument is weak. The challenger
  resolved this with the one-vCPU run, where the FIFO child holds the only CPU.
- The reproduction needs `SCHED_FIFO` to delay the waiter. The test treats a
  failure to enter `SCHED_FIFO` as a skip, and none of the decisive cases
  skipped.
- A preliminary pressure-based run (64 boundary and 96 pressure attempts) found
  no anomaly and was superseded. `EINTR` followed by a ready retry is expected
  and is not this bug.
- The first Stage-3 attempt for CR-5 failed after the provider's policy filter
  exhausted both retries (`error.txt`). The resumed attempt completed with the
  same model and inputs.
- Historical evidence at pin `4ba4abbe8cb3` only. The Terra review found
  `pause.rs` and `poll.rs` identical to the clean pin.
