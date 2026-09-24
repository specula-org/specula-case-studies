# AST-39: Socket timeout/restart may repeat committed progress

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report MC-5/T-7 (same IDs in the modeling brief), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendto, sendmsg, recvfrom, recvmsg, accept, accept4, connect |
| Upstream | partial: open PR [#3576](https://github.com/asterinas/asterinas/pull/3576) covers timeout-conditioned restart. Also reviewed: [#3494](https://github.com/asterinas/asterinas/pull/3494) (merged), [#3607](https://github.com/asterinas/asterinas/pull/3607) (closed unmerged) |
| Fix | pr-open, partial: #3576 (open, head `8e02d0e94230`) |
| Reproducer | NOT_RUN |

## Summary

Socket syscall handlers turn every EINTR from the socket layer into
ERESTARTSYS, so a signal handler with `SA_RESTART` restarts the call. This
ignores Linux's rule that a socket call with a timeout set is not restarted,
which the source marks with FIXMEs. The wider question is whether any path
returns EINTR after it has already committed progress. A restart would then
repeat that progress. Recon found no such path.

## Linux contract

signal(7) lists socket calls that are never restarted and always fail with
EINTR when interrupted by a handler: `accept`, `recv`, `recvfrom`, `recvmmsg`
and `recvmsg` when a receive timeout is set, and `connect`, `send`, `sendto`
and `sendmsg` when a send timeout is set with setsockopt(2). signal(7) also
says that an I/O call interrupted after it transferred some data returns
success with the partial count.

## Asterinas behavior

- `kernel/core/src/syscall/sendmsg.rs::send_one_message`,
  `sendto.rs::sys_sendto`, `recvmsg.rs::sys_recvmsg`,
  `recvfrom.rs::sys_recvfrom`, `accept.rs::do_accept` and
  `connect.rs::sys_connect` map EINTR to ERESTARTSYS. Each carries a FIXME
  that the call "should not be restarted if a timeout has been set on the
  socket using `setsockopt`".
- `kernel/core/src/process/signal/mod.rs::handle_pending_signal` turns
  ERESTARTSYS into EINTR and, when the handler has `SA_RESTART`, restores the
  original return register and rewinds the instruction pointer so the
  syscall runs again.
- `kernel/core/src/process/signal/poll.rs::Pollable::wait_events` retries
  only EAGAIN and returns other results unchanged. Recon notes this shrinks
  the replay surface and found no baseline backend that returns EINTR after a
  positive commit.

## Reproduction

No runtime reproducer exists. Recon T-7 proposes interrupting blocking send
and receive calls before and after a peer creates progress.

1. Timeout, no restart. Create an `AF_UNIX` `SOCK_STREAM` socketpair, set
   `SO_RCVTIMEO` to 2 seconds on `sv[1]`, install a `SIGALRM` handler with
   `SA_RESTART`, arm a 0.5-second timer, and call `recv(sv[1], buf, 1, 0)`
   with nothing queued. Linux returns -1 with EINTR at about 0.5 seconds. The
   FIXME predicts that Asterinas restarts the call and returns EAGAIN at
   about 2 seconds or later. Repeat with `SO_SNDTIMEO` on a full stream
   socket for `send`, and with `accept` on a listening socket.
2. Committed progress. Send a large patterned buffer (for example 8 MiB of
   32-bit counters) with one blocking `send` on a Unix stream socketpair while
   the peer reads slowly, and deliver `SA_RESTART` signals every few
   milliseconds. Linux returns short counts, and the peer's stream equals the
   pattern prefix of the summed counts. A repeated or reordered range in the
   peer's stream shows replay of committed progress.

Step 1 needs only SMP=1. Step 2 runs sender and reader concurrently and
should use SMP=2.

## Fix and upstream status

The 2026-09-14 dedup recorded PARTIAL_MATCH with upstream fix status
OPEN_PR_PARTIAL_COVERAGE. #3576, "Refactor the syscall restart mechanism",
moves restart decisions into the wait primitives and directly covers
timeout-conditioned restart after the socket timeout support of #3494. It
does not prove every positive-progress duplication hypothesis in this entry.
#3607 was a closed alternative focused on socket timeouts.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 5.2 #1578, 5.5 #3576, 6.6, 9.1 MC-5, 9.2 T-7)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 5, section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register calls this a broad restart question and notes that the AST-26
  rejection applies only to regular files. AST-09 is the reproduced pipe
  `readv`/`writev` restart case and has its own scope.
- Step 1 checks a documented Linux rule that the source already marks as
  FIXME. Step 2 is an open hypothesis with no known triggering backend.
- MC-5 was never model-checked. The Recon run produced no TLA+ spec.
- All six FIXMEs are still present at upstream main `bc12195`
  (package-builder `git grep`, 2026-09-24).
