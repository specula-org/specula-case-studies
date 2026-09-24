# AST-38: sendmmsg batch length lacks the Linux UIO_MAXIOV clamp

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-6/CR-3 (same IDs in the modeling brief, T-6 shared with AST-37 and CR-3 shared with AST-31), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendmmsg |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-match: [#2676](https://github.com/asterinas/asterinas/pull/2676) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

`sendmmsg` iterates over the raw user-supplied `vlen` without Linux's clamp
to `UIO_MAXIOV` (1024) and without a scheduling point. One call can therefore
send more than 1024 messages, and a very large valid batch keeps the thread
in the kernel for its whole length.

## Linux contract

sendmmsg(2) notes that `vlen` is capped to `UIO_MAXIOV` (1024).
`__sys_sendmmsg` applies the clamp and calls `cond_resched()` between entries
(Recon cites Linux v6.16 `net/socket.c:2664-2730` and `2678-2723`). The
return value counts the messages whose `msg_len` was written.

## Asterinas behavior

- `kernel/core/src/syscall/sendmmsg.rs::send_mmsg_hdrs` runs
  `for i in 0..count` with `count: usize` taken directly from the syscall
  argument. It computes each entry address as
  `mmsghdrs_addr + size_of::<CMmsgHdr>() * i` without checked arithmetic.
  There is no clamp and no yield.
- `kernel/core/src/syscall/sendmmsg.rs::sys_sendmmsg` returns the number of
  counted messages, or the error when none was counted.

## Reproduction

No runtime reproducer exists. Recon T-6 includes `sendmmsg` with
`vlen > 1024`.

1. Bind a UDP receiver on 127.0.0.1 and connect a UDP sender to it. UDP on
   loopback avoids blocking on receiver space on either kernel.
2. Build 1025 valid entries, each carrying a 1-byte message, and call
   `sendmmsg(fd, vec, 1025, 0)`.

Linux returns 1024. A return of 1025 shows the missing clamp. An optional
availability check times a very large valid batch on SMP=1 against a
CPU-bound thread. Recon did not analyze Asterinas kernel preemption, so
treat that result as exploratory. SMP=1 is enough for the count check.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #2676 introduced `sendmmsg`. The Recon code-review item CR-3
recommends bounded iteration together with field-specific `msg_len` output.
The output part is AST-31.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 4, 6.4, 6.7, 7, 9.2 T-6, 9.3 CR-3)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register says to keep this batch-bound question separate from AST-31
  header publication.
- Recon flags the unchecked address multiplication but did not establish a
  reachable wrap. The loop faults on the first unmapped entry long before
  `i * 64` could overflow.
- `sendmmsg.rs` is unchanged between the pin and upstream main `bc12195`
  (package-builder `git diff`, 2026-09-24).
