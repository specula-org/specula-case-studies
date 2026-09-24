# AST-19: Consumed timerfd remains ready through the poll cache

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-4, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | TLPI-v2 attachment F17 (source pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`): three probes `timerfd_poll_drain`, `timerfd_poll_disarm`, `timerfd_epoll_drain`, all NOT_RUN on Asterinas |
| Syscalls | `read` on a timerfd, then `poll` (reproduced). `timerfd_settime` disarm, `epoll_wait`, `select`, and `ppoll` read the same cache (source and TLPI prediction only). |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Reviewed: merged PR [#2037](https://github.com/asterinas/asterinas/pull/2037) (timerfd introduction), issue [#3823](https://github.com/asterinas/asterinas/issues/3823) and merged PR [#3824](https://github.com/asterinas/asterinas/pull/3824), which fix accepted clock IDs (that is AST-62, not this entry). Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Earlier FD guest evidence retained; imported drain/disarm/epoll probes remain NOT_RUN". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

After a successful `read` consumes a timerfd's expiration count, Asterinas
keeps returning `POLLIN` for that timerfd from `poll`, while the next
nonblocking `read` fails with `EAGAIN`. The stale readiness comes from the
`Pollee` cache, which `read` never invalidates, and it persists for a one-shot
timer because no later expiry arrives to clear it. Any unprivileged process
that polls a timerfd can observe it, and an event loop can spin on false
readiness. The run classified it as High.

## Linux contract

`timerfd_create(2)` says a timerfd is readable when one or more expirations
have occurred, and that a `read` returns the number of expirations since the
last successful read. After the count is consumed a nonblocking `read` fails
with `EAGAIN`, so `poll(2)` must not report `POLLIN`. The Linux control times
out on the post-read poll.

- https://man7.org/linux/man-pages/man2/timerfd_create.2.html
- https://man7.org/linux/man-pages/man2/poll.2.html

## Asterinas behavior

- `kernel/core/src/time/timerfd.rs::TimerfdFile::new` installs an expiry
  callback that increments `ticks` and calls `Pollee::notify(IN)`, which
  invalidates the cache and wakes pollers.
- `kernel/core/src/process/signal/poll.rs::Pollee::poll_with` returns the
  cached events whenever the cached state is nonnegative, without calling the
  `check` closure. The `Pollee` documentation requires `Pollee::invalidate`
  "whenever an old event disappears and no new event arrives".
- `kernel/core/src/time/timerfd.rs::TimerfdFile::try_read` clears `ticks` with
  `fetch_and(0)` and does not call `invalidate`.
  `kernel/core/src/time/timerfd.rs::TimerfdFile::poll` goes back through
  `poll_with`, so the cached `IN` is returned.
- `kernel/core/src/syscall/poll.rs::PollFiles::register_poller` copies that
  result into `pollfd.revents` without a recheck.
- Static observation at the pin, not runtime tested:
  `kernel/core/src/time/timerfd.rs::TimerfdFile::set_time` also clears `ticks`
  with `store(0)` and does not invalidate. This is the disarm path that TLPI F17
  predicts.

## Reproduction

Level 0, single-threaded, public API only: create a `TFD_NONBLOCK` timerfd, arm
a one-shot timer (1 ms or 100 ms), wait for `POLLIN`, optionally poll once more
to prime the cache, `read` the 8-byte count, then `poll` again with timeout 0
(or 75 ms). Asterinas returns `POLLIN` and the following `read` returns
`EAGAIN`. See `repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- Round-6 standalone test: `SPECULA_REGRESSION_FAIL timerfd_cache: consumed timerfd remained readable`.
- Confirmation turn A: `MC4_POST_CONSUME_POLL index=0..2 ret=1 revents=0x1`, `MC4_POST_CONSUME_READ bytes=-1 errno=11`, `MC4_BUG_TRIGGERED stale_polls=3 while_read_is_EAGAIN`.
- Challenger, fresh boot, repeated: `MC4B_POST_READ_TIMED_POLL poll=1 revents=0x1`, `MC4B_POST_READ bytes=-1 errno=11`, `MC4B_BUG_TRIGGERED timed_poll_reported_readiness_then_read_eagain`.
- Linux controls: `MC4_EXPECTED_NO_STALE_READINESS stale_polls=0` and `MC4B_NO_STALE_READINESS timed_poll=0 zero_poll=0`.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends
calling `Pollee::invalidate` on the successful tick-consumption path in
`TimerfdFile::try_read`, keeping the read and copy-out semantics, and keeping
the Level-0 regression that requires `poll(0) == 0` and a later `EAGAIN` after
the read. The TLPI F17 repair direction adds invalidation on the
`timerfd_settime` disarm path and a test for poll/epoll racing a new expiry.
During packaging on 2026-09-24 a static read of upstream main `bc12195df`
showed `try_read` still clearing `ticks` with `fetch_and(0)` and no
`invalidate`. No runtime retest was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 4)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/challenge_B.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/qemu.log (turn A guest output)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/host-control.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug3_timerfd_cache_smp2_round6_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_timerfd_cache_smp2_round5_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s3_cache_round2_bfs_cex.json (invariant `MCCachedReadinessSound`, 9 states)
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section `timerfd_cache`)
- /home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md (row F17)
- /home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json (entry F17)
- /home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json (cases `timerfd_poll_drain`, `timerfd_poll_disarm`, `timerfd_epoll_drain`)

## Caveats

- The runtime evidence covers the `read` (drain) path through `poll` only. The
  disarm path and the epoll path are source predictions from TLPI F17, whose
  three imported probes are NOT_RUN on Asterinas. The register keeps AST-19's
  REPRODUCED status from the FD run, not from the TLPI attachment.
- TLPI F17 notes that `Pollee::poll_with` installs the cache with
  `compare_exchange_weak`, so a single poll does not always cache. The turn-A
  test primes the cache with a second poll before the read. A test that skips
  priming may not fail on every run.
- Historical evidence at pin `4ba4abbe8cb3` only. The tested kernels were built
  from the run's instrumented source copy. The Terra review found `timerfd.rs`
  and `poll.rs` identical to the clean pin.
- Some confirmation test programs return exit status 0 when the bug triggers
  (see `repro/README.md`).
