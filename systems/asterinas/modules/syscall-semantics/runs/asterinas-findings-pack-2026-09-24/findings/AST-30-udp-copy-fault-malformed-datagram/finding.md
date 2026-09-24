# AST-30: IP UDP source-copy fault may publish a malformed datagram

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-2 (same ID in the modeling brief), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendto, sendmsg, sendmmsg, write |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#1294](https://github.com/asterinas/asterinas/pull/1294), [#2032](https://github.com/asterinas/asterinas/pull/2032) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

An IP UDP send reserves a datagram of the full requested size in the smoltcp
send buffer and only then copies the payload from user memory into it. If the
copy faults, the syscall fails, but the reserved datagram stays queued and
leaves on a later interface poll. A peer can then receive a datagram whose
bytes after the fault point were never written by the sender.

## Linux contract

A datagram send is all-or-none. On Linux, `udp_sendmsg()` copies the payload
while it builds the skb (`ip_make_skb()`/`ip_append_data()` in `net/ipv4/`).
A copy fault fails the call with EFAULT and the partly built skb is
discarded, so nothing reaches the peer. The Recon report states the contract
as "a source-copy fault must not publish a partial datagram" and cites
sendmsg(2) and the Linux v6.16 datagram paths.

## Asterinas behavior

- `kernel/core/src/net/socket/ip/datagram/bound.rs::BoundDatagram::try_send`
  calls `UdpSocket::send(reader.sum_lens(), remote, closure)`. The closure
  copies the user payload into the reserved slot. A FIXME there reads "If copy
  failed, we should not send any packet. But current smoltcp API seems not to
  support this behavior", and the error arm logs
  `unexpected UDP packet {e:#?} will be sent`.
- `kernel/libs/aster-bigtcp/src/socket/bound/udp.rs::UdpSocket::send` takes
  the raw-socket spin lock, calls smoltcp `socket.send(size, meta)` to enqueue
  a `size`-byte slot, runs the closure on it, and sets `need_dispatch` from the
  send-queue length whatever the closure returned.
- `kernel/core/src/net/socket/ip/datagram/mod.rs::DatagramSocket::try_send`
  returns the copy error through `?` before `iface_to_poll.poll()`. The queued
  slot therefore leaves on a later poll, not during the failing call. This
  point is a package-builder reading of the pin, not a Recon statement.

The recorded evidence does not establish what the peer receives in the
unwritten tail of the slot.

## Reproduction

No runtime reproducer exists. Recon was analysis and review only. The check
it proposes (T-2) is that no peer-visible datagram appears after a
source-copy fault. A concrete form:

1. Bind a receiver UDP socket on 127.0.0.1 and make it nonblocking with
   `fcntl(O_NONBLOCK)`. Create a sender UDP socket.
2. Map two adjacent pages and make the second `PROT_NONE`. Send 128 bytes
   starting 64 bytes before the boundary with `sendto`. A `sendmsg` variant
   can put its second iovec on the `PROT_NONE` page. Do not use a NULL iovec
   base, because the pin filters NULL-base iovecs as empty (see AST-37).
3. Both kernels should return -1 with EFAULT.
4. Send one valid marker datagram so the interface is polled, then drain the
   receiver until EAGAIN.

On Linux the receiver gets only the marker. The defect is shown if the
receiver also gets a 128-byte datagram before the marker. Record its
contents. SMP=1 is enough because no concurrency is involved. The existing
`test/initramfs/src/regression/network/udp_err.c` (lines 342-403 at the pin)
checks the EFAULT result but not the peer, so it is a natural home for the
assertion.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #1294 discusses UDP receive consuming a packet on copy
error, which is Linux-compatible and a different path. The Unix datagram
send path copies the whole payload into a kernel `Vec` before it queues
anything (`MessageQueue::try_send`), which shows one way to stage the copy.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 6.3, 7, 9.2 T-2)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 2, section 6.2 T-2)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- Source-only lead. The register records "Peer-visible outcome not
  reproduced".
- A read-only `git show` of upstream main `bc12195` on 2026-09-24 found the
  same FIXME and send closure. This is a package-builder check, not recorded
  evidence.
- IP UDP receive consuming a datagram on a copy fault matches Linux and is not
  part of this lead.
