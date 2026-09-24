# AST-36: Unix datagram receive may retain a record after copy fault

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report MC-2/T-3 (same IDs in the modeling brief), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | recvfrom, recvmsg, read |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#2412](https://github.com/asterinas/asterinas/pull/2412), [#3347](https://github.com/asterinas/asterinas/pull/3347), [#3600](https://github.com/asterinas/asterinas/pull/3600), [#1294](https://github.com/asterinas/asterinas/pull/1294) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

A non-peek receive on a Unix datagram socket copies the front message into
the user buffer and removes it from the queue only if the copy succeeds.
After a copy fault the syscall fails, the user buffer may already hold part
of the message, and the next receive returns the same message again. Linux
removes the selected datagram before copying and frees it even when the copy
fails.

## Linux contract

In `unix_dgram_recvmsg` a non-peek receive unlinks the skb from the queue,
and a copy error frees it (Recon cites Linux v6.16
`net/unix/af_unix.c:2493-2602`). `MSG_PEEK` never consumes. No manual page
states the fault case, so the reference is Linux source behavior. Recon also
records that Asterinas's own IP UDP receive consumes the datagram on a copy
fault, which matches Linux.

## Asterinas behavior

`kernel/core/src/net/socket/unix/datagram/message.rs::MessageReceiver::try_recv`
takes the front message and calls
`writer.write(&mut VmReader::from(msg.bytes.as_slice()))?`. The `?` returns
before `pop_front`, before the `total_length` update, and before
`generate_control`, so the message and its SCM data stay queued.

## Reproduction

No runtime reproducer exists. Recon T-3 proposes comparing Asterinas and
Linux with a faulting destination and then retrying the receive.

1. Create an `AF_UNIX` `SOCK_DGRAM` socketpair and make the receiver
   nonblocking with `fcntl(O_NONBLOCK)`. Send "AAAA", then "BBBB".
2. Receive 4 bytes into a `PROT_NONE` page. Both kernels should return -1
   with EFAULT. A variant places the second half of the buffer on the
   `PROT_NONE` page to also record the partial prefix.
3. Receive again into a valid buffer.

Linux returns "BBBB", because "AAAA" was consumed in step 2. The defect is
"AAAA" again. As a control, pass `MSG_PEEK` in step 2. Both kernels then
return "AAAA" in step 3. SMP=1 is enough for this check. The concurrent MC-2
variant, a second receiver or peeker racing the faulting receive, needs
SMP=2.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #2412 added Unix datagram sockets, #3347 and #3600 added
`MSG_PEEK` and `MSG_TRUNC`, and #1294 discusses IP UDP consume-on-fault.
None settles Unix datagram non-peek replay after a copy failure.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 6.3, 9.1 MC-2, 9.2 T-3, 10)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 2, section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register says to compare non-peek consumption and retry against
  Linux. Whether retention is a defect or a tolerable difference depends on
  that comparison. No security impact has been established.
- MC-2 was never model-checked. The Recon run produced no TLA+ spec.
- `datagram/message.rs` is unchanged between the pin and upstream main
  `bc12195` (package-builder `git diff`, 2026-09-24).
