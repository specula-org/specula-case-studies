# AST-70: TCP send propagates EPIPE without generating SIGPIPE

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F26, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `sendto` (and `send`), `sendmsg`, `write` on a TCP socket |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#1888](https://github.com/asterinas/asterinas/issues/1888) (closed Go syscall tracking), [#1851](https://github.com/asterinas/asterinas/issues/1851) (closed Docker tracking) and [#3494](https://github.com/asterinas/asterinas/pull/3494) (merged socket timeouts). None raises SIGPIPE. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tcp_sigpipe`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

A TCP send that fails with EPIPE, for example after `shutdown(SHUT_WR)`,
returns the error but raises no SIGPIPE. A process that relies on the
default SIGPIPE action to stop when it writes to a closed connection keeps
running and sees only EPIPE. MSG_NOSIGNAL makes no difference because no
signal is ever generated.

## Linux contract

[send(2)](https://man7.org/linux/man-pages/man2/send.2.html): EPIPE means the
local end of a connection-oriented socket has been shut down, and the
process also receives SIGPIPE unless MSG_NOSIGNAL is set. The saved Linux
6.18 run saw EPIPE (32) with SIGPIPE pending after a plain `send`, and EPIPE
without a signal when MSG_NOSIGNAL was set.

## Asterinas behavior

At the pin,
`kernel/core/src/net/socket/ip/stream/connected.rs::ConnectedStream::try_send`
maps `SendError::InvalidState` to EPIPE.
`kernel/core/src/net/socket/ip/stream/mod.rs::StreamSocket::sendmsg` returns
the result of `block_on(.., try_send)` directly and ends with
`TODO: Trigger SIGPIPE if the error code is EPIPE and MSG_NOSIGNAL is not specified`.
`kernel/core/src/syscall/sendto.rs::sys_sendto` only rewrites EINTR.
`write(2)` on a socket reaches the same `sendmsg` through
`kernel/core/src/net/socket/mod.rs::FileLike::write` with empty flags.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case `tcp_sigpipe` builds
a loopback TCP pair, blocks SIGPIPE with the default disposition, calls
`shutdown(client, SHUT_WR)`, sends one byte and checks for a pending SIGPIPE
with a zero-timeout `sigtimedwait`. It then repeats the send with
MSG_NOSIGNAL and checks that no signal is pending. The saved Linux output is
`OBS {"ret":-1,"errno":32,"sigpipe":true,"nosignal_ret":-1,"nosignal_errno":32,"nosignal_suppressed":true}`
(PASS). By source reading, Asterinas at the pin would report
`"sigpipe":false` and FAIL. The case has not run on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to raise SIGPIPE
for the calling thread at the right point, keep the MSG_NOSIGNAL exception
and keep the EPIPE error. The cited files are byte-identical at upstream
`bc12195df` (the pin's direct child), checked on 2026-09-24 with a read-only
`git diff`. Later upstream commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-70)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F26)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batch `messages_tcp`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F26)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F26)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tcp_sigpipe.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-70)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- Checking errno alone misses this difference. Observe the signal and the
  MSG_NOSIGNAL control.
- Only the TCP stream path was reviewed. UNIX stream sockets and pipes were
  not.
- AST-65 and AST-69 are different defects in the same `StreamSocket`.
