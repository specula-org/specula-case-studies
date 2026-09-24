# AST-65: Accepted TCP socket does not inherit listener TCP_KEEPIDLE

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F21, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `setsockopt`/`getsockopt(TCP_KEEPIDLE)`, `accept`, `accept4` |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#1717](https://github.com/asterinas/asterinas/pull/1717) (adds TCP_KEEPIDLE) and [#3303](https://github.com/asterinas/asterinas/pull/3303) (TCP_KEEPINTVL, TCP_KEEPCNT stub), both merged, neither handles inheritance. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `tcp_accept_keepidle`, control `tcp_accept_flags`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

A TCP_KEEPIDLE value set on a listening socket is not carried over to the
sockets it accepts. `getsockopt(TCP_KEEPIDLE)` on an accepted socket reports
the default instead of the listener's value. Servers that configure
keepalive once on the listener see a different setting on each connection.

## Linux contract

On Linux the accepted socket reports the TCP_KEEPIDLE value that was set on
the listener before the connection arrived. The saved Linux 6.18 run set 17
on the listener and read 17 on both sockets.
[tcp(7)](https://man7.org/linux/man-pages/man7/tcp.7.html) documents the
option. [accept(2)](https://man7.org/linux/man-pages/man2/accept.2.html) notes
that file status flags such as O_NONBLOCK are not inherited, which the
negative control checks so that a fix does not copy everything.

## Asterinas behavior

At the pin,
`kernel/core/src/net/socket/ip/stream/mod.rs::StreamSocket::new_accepted`
starts from `OptionSet::new()`. It copies keepalive enablement and interval
from the raw socket (or the interval from the listener) and sets TCP_NODELAY
when Nagle is off, then stops at a `TODO: Update other options for a
newly-accepted socket`. `keep_idle` in `options.tcp` stays at its default.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. `tcp_accept_keepidle`
sets TCP_KEEPIDLE=17 on a loopback listener before connecting, accepts the
connection and reads the option on both sockets. The saved Linux output is
`OBS {"listener":17,"accepted":17,"inherited":true}` (PASS). The negative
control `tcp_accept_flags` checks that O_NONBLOCK and FD_CLOEXEC are not
inherited, and Linux printed
`OBS {"listener_nonblock":true,"accepted_nonblock":false,"accepted_cloexec":false}`.
By source reading, Asterinas at the pin would report the default on the
accepted socket with `"inherited":false` and FAIL. The cases have not run on
Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to build the new
socket's options per Linux inheritance rules, not by cloning every FD or
status flag. The cited file is byte-identical at upstream `bc12195df` (the
pin's direct child), checked on 2026-09-24 with a read-only `git diff`.
Later upstream commits were not checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-65)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F21)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batches `messages_tcp` and `controls`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F21)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F21)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tcp_accept_keepidle.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-tcp_accept_flags.log`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-65)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The claim covers user-visible option state only. `do_tcp_setsockopt` at the
  pin stores `keep_idle` with a TODO to actually track idle time, so there is
  no keepalive packet-timing evidence either way.
- Other listener options may also be dropped at the same TODO, which was not
  audited.
- AST-69 and AST-70 are different defects in the same `StreamSocket`.
