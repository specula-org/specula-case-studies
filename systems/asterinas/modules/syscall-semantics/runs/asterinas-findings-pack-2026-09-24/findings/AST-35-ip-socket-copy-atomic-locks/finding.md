# AST-35: IP socket user copy may fault while holding atomic-mode locks

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-10 (brief T-9), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendto, sendmsg, recvfrom, recvmsg |
| Upstream | partial: the same hazard class was reported for UNIX sockets in [#1304](https://github.com/asterinas/asterinas/issues/1304) and fixed by [#1365](https://github.com/asterinas/asterinas/pull/1365). Also reviewed: [#1294](https://github.com/asterinas/asterinas/pull/1294) |
| Fix | unfixed for the IP paths, no fix located |
| Reproducer | NOT_RUN |

## Summary

IP TCP and UDP send and receive copy user memory inside closures that run
while spin locks are held. The UDP raw-socket lock also disables bottom
halves. User buffers are not prefaulted, so a user page fault can occur in
that window, and serving it may need to sleep, which Asterinas forbids in
atomic mode. The possible outcomes range from an atomic-mode panic to a
spurious EFAULT. None has been observed.

## Linux contract

send(2) and recv(2) must succeed on a valid mapped buffer even when its
pages are not yet present. Linux copies socket payloads in a context that
may sleep (TCP under the `lock_sock` owner lock, UDP while building the
skb), so the fault is served and the call completes. The Recon report states
the required observation as "a valid not-present file-backed user page
faults without sleeping/panicking under the socket lock and preserves the
syscall contract".

## Asterinas behavior

- `kernel/core/src/net/socket/ip/stream/mod.rs::StreamSocket` carries a
  FIXME: "We perform userspace reads/writes when holding the spin locks
  (e.g., this state lock and other locks in `aster-bigtcp`), which will break
  the atomic mode."
- `kernel/libs/aster-bigtcp/src/socket/bound/udp.rs::UdpSocket::send` and
  `UdpSocket::recv` hold `SpinLock<Box<RawUdpSocket>, BottomHalfDisabled>`
  across the copy closure.
- `kernel/libs/aster-bigtcp/src/socket/bound/tcp_conn.rs::TcpConnection::send`
  and `TcpConnection::recv` run the copy callback under the connection lock.
  `kernel/core/src/net/socket/ip/stream/connected.rs::ConnectedStream::try_send`
  and `ConnectedStream::try_recv` call them.
- `kernel/core/src/process/posix_thread/thread_local.rs` documents
  `with_page_fault_disabled`: fault handling may load a page from disk, and
  code that must touch user memory in atomic mode has to disable the handler,
  leave atomic mode, handle the fault and retry. The IP paths do not do this.
- `kernel/core/src/context.rs::CurrentUserSpace::reader`/`writer` defer
  validation and do not prefault or pin user pages.

## Reproduction

No runtime reproducer exists. Recon T-10 proposes a test harness with a valid
not-present file-backed page and explicitly keeps the lock and preemption
internals out of the TLA+ model.

1. Use a file on ext2 whose pages are not yet mapped into the process. A file
   that already existed in the disk image before boot is most likely to also
   be absent from the page cache.
2. `mmap` it read-only without touching the mapping, then send the mapping
   over a connected UDP socket on loopback and over a TCP loopback
   connection.
3. For the receive side, receive into an untouched writable `MAP_SHARED`
   mapping of a file.

On Linux every call succeeds and the peer receives the file content. The
defect is any of a panic, a hang, or EFAULT on a valid buffer. Issue #1304
shows the signature of the UNIX-socket variant: a panic in
`ostd/src/task/atomic_mode.rs` reading "This function might break atomic mode
(preempt_count = 1, ...)". Run with SMP=1 and with SMP of 2 or more, because
#1304 was observed on SMP=4.

## Fix and upstream status

The 2026-09-14 dedup recorded PARTIAL_MATCH with upstream fix status
RELATED_BACKEND_FIX_ONLY. #1304 reported user copies sleeping under UNIX
socket locks and #1365 corrected those lock usages. The IP TCP and UDP paths
keep the FIXME. #1294 moved the network APIs to IoVec readers and writers.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 5.2 #1530, 6.10, 9.2 T-10)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (section 6.2 T-9)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/raw/details/1304-issue.json`

## Caveats

- The register records "Concrete fault/lock failure not reproduced". The
  audit reference classifies this as an availability test candidate.
- Whether a user fault in this window actually sleeps depends on the runtime
  page-fault path, which Recon did not trace.
- Report T-10 is this entry and brief T-9 is the same question. Report T-9 is
  AST-34.
- The IP stream FIXME is still present at upstream main `bc12195`
  (package-builder `git show`, 2026-09-24). `udp.rs` and `tcp_conn.rs`
  changed between the pin and `bc12195`, and those changes were not reviewed
  for this entry.
