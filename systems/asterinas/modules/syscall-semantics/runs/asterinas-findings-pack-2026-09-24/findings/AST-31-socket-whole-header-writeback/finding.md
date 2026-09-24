# AST-31: Socket effects precede whole-header writeback to user memory

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report MC-3/T-5/CR-3 (same IDs in the modeling brief), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | recvmsg, sendmmsg |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#2676](https://github.com/asterinas/asterinas/pull/2676), [#1294](https://github.com/asterinas/asterinas/pull/1294) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

After a completed receive, `recvmsg` writes the whole saved `msghdr` back to
user memory, and `sendmmsg` writes the whole saved `mmsghdr` entry back after
each send. Linux writes only the output fields. Two consequences follow. A
stale snapshot can overwrite input-only fields that another thread changed,
and an unwritable input-only field can turn a completed receive or send into
EFAULT.

## Linux contract

`recvmsg` copies back only `msg_namelen`, `msg_controllen` and `msg_flags`,
plus the name and control buffers they describe. It never rewrites
`msg_name`, `msg_iov`, `msg_iovlen` or `msg_control` (Recon cites Linux v6.16
`net/socket.c:2760-2813`). `sendmmsg` writes only each entry's `msg_len`
(`net/socket.c:2664-2720`). Linux does allow an effect to precede a later
EFAULT, but only at those output fields. For `sendmmsg`, at most one current
message may be sent without being counted when its `msg_len` write fails.

## Asterinas behavior

- `kernel/core/src/syscall/recvmsg.rs::sys_recvmsg` reads `CUserMsgHdr` once,
  receives, stores `msg_namelen`, `msg_controllen` and `msg_flags` in the
  saved copy, and then calls `user_space.write_val(user_msghdr_ptr,
  &c_user_msghdr)`, which writes all 56 bytes.
- `kernel/core/src/syscall/sendmmsg.rs::send_mmsg_hdrs` reads each
  `CMmsgHdr` (64 bytes), calls `send_one_message`, sets `msg_len`, and writes
  the whole entry back. If that write fails, `sent_msgs` is not incremented,
  and `sys_sendmmsg` returns the error when no earlier message was counted.
- `kernel/core/src/util/net/socket.rs::CUserMsgHdr` has the x86-64
  `struct msghdr` layout: `msg_name` at 0, `msg_namelen` at 8, `msg_iov` at
  16, `msg_iovlen` at 24, `msg_control` at 32, `msg_controllen` at 40,
  `msg_flags` at 48, size 56. `msg_len` follows at offset 56 in `CMmsgHdr`.

## Reproduction

No runtime reproducer exists. Recon T-5 proposes checking that only
contractual output fields change and that an input-only field cannot add a
post-effect fault. Steps 1 to 3 are single-threaded and deterministic.

1. `recvmsg` extra fault. Place the `msghdr` so that bytes 0 to 7
   (`msg_name`) end one page and the rest starts the next page. Set
   `msg_name = NULL` and make the first page `PROT_READ`. Queue one datagram
   on an `AF_UNIX` `SOCK_DGRAM` socketpair and call `recvmsg`. Linux returns
   the payload length because it writes only offsets 40 and 48. The defect is
   -1 with EFAULT after the datagram was consumed. A following nonblocking
   receive returns EAGAIN on both kernels.
2. `sendmmsg` hidden send. Place one 64-byte entry so bytes 0 to 55 end a
   `PROT_READ` page and `msg_len` starts a writable page. Send one datagram to
   a bound UDP receiver on loopback. Linux returns 1 and sets `msg_len`. The
   defect is -1 with EFAULT while the receiver still gets the datagram.
3. Controls. Make the output field itself unwritable (`msg_flags` for
   `recvmsg`, `msg_len` for `sendmmsg`). Both kernels may then report EFAULT
   after the effect, which Linux permits.
4. Stale overwrite, two threads. Thread A blocks in `recvmsg`. Thread B then
   changes `msg_iovlen` or `msg_control` in the same `msghdr`. A peer sends.
   Linux keeps B's values. The defect is that A's snapshot values reappear.

Steps 1 to 3 need only SMP=1. Step 4 should run with SMP=2.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #2676 introduced `sendmmsg` and #1294 refactored the network
APIs. Neither reports the whole-header writeback. The Recon code-review item
CR-3 recommends field-specific output (`msg_len` only). The `UIO_MAXIOV`
clamp in the same CR-3 item is tracked as AST-38.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 4, 6.4, 9.1 MC-3, 9.2 T-5, 9.3 CR-3)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenarios 3 and 4, section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register says to check contractual output fields and to treat
  permitted post-effect faults as controls. A fault at `msg_flags`,
  `msg_controllen` or `msg_len` is Linux-permitted and is not this defect.
- MC-3 was never model-checked. The Recon run produced no TLA+ spec.
- `recvmsg.rs` and `sendmmsg.rs` are unchanged between the pin and upstream
  main `bc12195` (package-builder `git diff`, 2026-09-24).
