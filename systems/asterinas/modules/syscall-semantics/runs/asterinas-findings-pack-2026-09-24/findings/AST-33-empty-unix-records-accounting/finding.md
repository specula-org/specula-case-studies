# AST-33: Empty Unix records evade capacity accounting or readiness

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-8/CR-6 (brief T-8 and brief CR-2, both shared with AST-34), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendto, sendmsg, recvmsg, poll, epoll_wait |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#2268](https://github.com/asterinas/asterinas/pull/2268), [#3600](https://github.com/asterinas/asterinas/pull/3600), [#3712](https://github.com/asterinas/asterinas/pull/3712) (benchmark material, not a fix) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

Unix datagram queues charge only payload bytes, so a zero-length datagram
passes every capacity check and costs nothing. Repeated empty sends, each of
which may carry SCM_RIGHTS files, grow the receiver's queue without a bound.
Separately, an empty `SOCK_SEQPACKET` record does not make the socket
readable, because readiness looks only at the byte ring.

## Linux contract

Linux allocates an skb for every record, including an empty one, and charges
its truesize against the sender's `sk_sndbuf`. Its Unix queue logic also
checks record counts (Recon cites Linux `net/unix/af_unix.c:288-291,
2083-2098, 2195-2235`). Sends therefore stop with EAGAIN or block after a
bounded number of empty records. A queued seqpacket record, even an empty
one, makes the socket readable: Linux polls `SOCK_SEQPACKET` with
`unix_dgram_poll`, which reports POLLIN when the receive queue is not empty.
Recon did not model the exact Linux buffer formula.

## Asterinas behavior

- `kernel/core/src/net/socket/unix/datagram/message.rs::MessageQueue::try_send`
  rejects `len > UNIX_DATAGRAM_DEFAULT_BUF_SIZE` (65536) and
  `BUF_SIZE - total_length < len`. Both checks pass for `len == 0`. The
  message is pushed and `total_length` grows by 0. There is no per-record
  charge and no record-count bound. Each message can hold an `AuxiliaryData`
  with up to 253 files (`MAX_NR_FILES` in `ctrl_msg.rs`).
- `kernel/core/src/net/socket/unix/stream/connected.rs::Connected::try_write`
  accepts an empty seqpacket record and pushes a zero-length
  `RangedAuxiliaryData` without using ring space.
- `kernel/core/src/net/socket/unix/stream/connected.rs::Connected::check_io_events`
  sets IN only when the byte ring is not empty. It ignores `all_aux` and
  `has_aux`.

## Reproduction

No runtime reproducer exists. Recon T-8 proposes filling queues with empty
records, polling after enqueue, and checking bounds.

1. Datagram bound. Create an `AF_UNIX` `SOCK_DGRAM` socketpair and set the
   sender `O_NONBLOCK` with `fcntl`. The pin ignores `MSG_DONTWAIT` on Unix
   datagram sends (`UnixDatagramSocket::do_send` takes `_flags`), so do not
   rely on the flag. Call `send(sv[0], buf, 0, 0)` up to 1,000,000 times
   without receiving and stop at the first error. Linux stops with EAGAIN
   well before the limit. The exact count depends on `sk_sndbuf` and the
   kernel version, so assert only that it is bounded. The defect is that every
   iteration succeeds. An optional variant attaches one SCM_RIGHTS descriptor
   to each empty record and watches guest memory.
2. Seqpacket readiness. Create an `AF_UNIX` `SOCK_SEQPACKET` socketpair, call
   `send(sv[0], buf, 0, 0)`, then `poll({sv[1], POLLIN}, 1, 0)`. Linux reports
   POLLIN. The defect is zero events. A following nonblocking `recv` returns 0
   on both kernels, which shows the record exists. Repeat with a
   level-triggered epoll.

SMP=1 is enough. The existing
`test/initramfs/src/regression/network/msg_peek.c` (lines 236-298 at the pin)
already sends an empty seqpacket record with SCM_RIGHTS, so empty records are
intended input, but it checks neither bounds nor readiness.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #2268 added seqpacket support and #3600 added `MSG_TRUNC`.
The Recon code-review item CR-6 asks to charge every queued record and to
include empty seqpacket records in readiness.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 6.8, 7, 9.2 T-8, 9.3 CR-6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 2, sections 6.2 T-8 and 6.3 CR-2)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register says queue bounds and zero-length seqpacket readability are
  not tested.
- Brief CR-2 covers this entry and AST-34. Report CR-2 is AST-40. Cite the
  artifact together with the ID.
- The observation that `do_send` ignores `MSG_DONTWAIT` is a package-builder
  reading of the pin, made only to keep the test from blocking.
- `datagram/message.rs` and `stream/connected.rs` are unchanged between the
  pin and upstream main `bc12195` (package-builder `git diff`, 2026-09-24).
