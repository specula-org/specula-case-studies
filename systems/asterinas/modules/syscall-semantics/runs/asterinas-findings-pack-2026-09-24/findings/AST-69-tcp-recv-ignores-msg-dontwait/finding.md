# AST-69: TCP receive blocking decision ignores MSG_DONTWAIT

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F25, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `recvfrom` (and `recv`), `recvmsg` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#1851](https://github.com/asterinas/asterinas/issues/1851) (closed Docker tracking issue), [#3494](https://github.com/asterinas/asterinas/pull/3494) (socket timeouts) and [#3600](https://github.com/asterinas/asterinas/pull/3600) (MSG_TRUNC), both merged. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tcp_dontwait`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

On a blocking TCP socket, `recv(..., MSG_DONTWAIT)` with no data waits for
data instead of failing with EAGAIN. The blocking decision looks only at the
socket's O_NONBLOCK flag, not at the per-call flag. Event loops that rely on
MSG_DONTWAIT to poll a blocking socket can hang.

## Linux contract

[recv(2)](https://man7.org/linux/man-pages/man2/recv.2.html): MSG_DONTWAIT
enables nonblocking operation for that call, and if the operation would
block it fails with EAGAIN or EWOULDBLOCK. It differs from O_NONBLOCK in
being a per-call option. The saved Linux 6.18 run returned `-1` with errno 11
after about 4 microseconds.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/recvfrom.rs::sys_recvfrom` forwards the
flags to `kernel/core/src/net/socket/ip/stream/mod.rs::StreamSocket::recvmsg`.
That function warns about unsupported flags
(`kernel/core/src/net/socket/util/message_flags.rs::RecvFlags::SUPPORTED`
contains only MSG_PEEK and MSG_TRUNC) and then always calls
`kernel/core/src/net/socket/mod.rs::SocketPrivate::block_on`. `block_on`
tries once only when `self.is_nonblocking()` is true, and otherwise waits in
`wait_events`. MSG_DONTWAIT does not enter the decision.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `tcp_dontwait` builds
a loopback TCP pair, leaves it idle, arms a 1-second SIGALRM as an escape
hatch, and calls `recv(accepted, &b, 1, MSG_DONTWAIT)`. The saved Linux
output is `DETAIL elapsed=0.000004` and
`OBS {"ret":-1,"errno":11,"alarm_seen":0}` (PASS). By source reading,
Asterinas at the pin would block until the alarm, report `alarm_seen` 1 and
FAIL. The case has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to combine the
per-call MSG_DONTWAIT with the open file's O_NONBLOCK in the blocking
decision, without changing the shared file flag for a single call. The cited
files are byte-identical at upstream `bc12195df` (the pin's direct child),
checked on 2026-09-24 with a read-only `git diff`. Later upstream commits
were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-69)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F25)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `messages_tcp`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F25)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F25)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tcp_dontwait.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-69)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Only the TCP receive path was reviewed. Make no claim for UNIX or UDP
  sockets. `StreamSocket::sendmsg` also goes through `block_on`, but no
  probe or register entry covers MSG_DONTWAIT on send.
- AST-65 and AST-70 are different defects in the same `StreamSocket`.
