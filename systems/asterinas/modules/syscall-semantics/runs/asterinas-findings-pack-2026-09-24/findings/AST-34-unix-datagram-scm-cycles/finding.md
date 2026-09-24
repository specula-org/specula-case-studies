# AST-34: Unix datagram SCM_RIGHTS references can form ownership cycles

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-9/CR-7 (brief T-8 and brief CR-2, both shared with AST-33), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | sendmsg, close, bind |
| Upstream | partial: [#2176](https://github.com/asterinas/asterinas/pull/2176) review discusses UNIX-socket ownership cycles and leaks for stream sockets. Also reviewed: [#2412](https://github.com/asterinas/asterinas/pull/2412) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

A Unix datagram socket can pass its own descriptor through SCM_RIGHTS into its
own receive queue. The queued message then holds a strong reference to the
socket that owns the queue. After every user descriptor is closed, nothing
drops the socket, so its queue, the files it carries and its bound address
are never released. The existing cycle guard looks only at Unix stream
sockets.

## Linux contract

Linux counts in-flight Unix sockets and runs a garbage collector
(`net/unix/garbage.c`, Recon cites lines 560-621) that frees unreachable
cycles. After collection the socket's resources, including an abstract
address, are released.

## Asterinas behavior

- Ownership chain at the pin: `UnixDatagramSocket.local_receiver`
  (`MessageReceiver`) holds `queue: Arc<MessageQueue>`, whose
  `Inner.messages` hold `Message.aux: AuxiliaryData`, whose
  `files: Vec<Arc<dyn FileLike>>` can hold the same `UnixDatagramSocket`.
- `kernel/core/src/net/socket/unix/ctrl_msg.rs::AuxiliaryData::from_control`
  carries a FIXME about circular references and Linux's collector, but only a
  file that is a `UnixStreamSocket` triggers the check. That check is a
  `CAP_SYS_ADMIN` capability test through `lsm_hooks::on_capable`, not a
  rejection. Datagram sockets pass with no check.
- `kernel/core/src/net/socket/unix/datagram/message.rs::MessageReceiver::drop`
  is the only place that removes the bound address from `QUEUE_TABLE` and
  clears the queue. The cycle keeps it from running. Recon found no Unix-socket
  collector or other cycle breaker at the pin.

## Reproduction

No runtime reproducer exists. Recon T-9 proposes sending a socket's
descriptor into its own queue, closing every external descriptor, and
checking that the queue, socket and file references are released. A concrete
form that uses the bound address as the observer:

1. `s = socket(AF_UNIX, SOCK_DGRAM, 0)` and bind it to a unique abstract
   name (`sun_path[0] = 0`).
2. `sendmsg` one byte to that same address with SCM_RIGHTS carrying `s`.
3. `close(s)`.
4. Create a new `SOCK_DGRAM` socket and bind it to the same abstract name,
   retrying for a bounded time such as 2 seconds.

On Linux the bind succeeds once the collector frees the cycle. Collection is
asynchronous and its trigger differs between kernel versions, so calibrate
the Linux control first. Creating and closing another `AF_UNIX` socket
between retries is one way to prompt it. The defect is that the bind keeps
failing with EADDRINUSE. A resource variant repeats steps 1 to 3 many times
and watches kernel memory.

Run the test as an unprivileged user. As root the stream-socket capability
check also passes, so a root run does not show that datagram sockets skip
it. SMP=1 is enough.

## Fix and upstream status

The 2026-09-14 dedup recorded PARTIAL_MATCH with upstream fix status
PUBLIC_DISCUSSION_PARTIAL. The #2176 review explicitly discusses UNIX-socket
ownership cycles and resource leaks, but in the original stream context.
#2412 added datagram support. The datagram and self-descriptor instance is a
scope extension of that discussion. The Recon code-review item CR-7 asks to
extend the cycle policy to datagram sockets or to implement a collector.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 6.9, 7, 9.2 T-9, 9.3 CR-7)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 3, sections 6.2 T-8 and 6.3 CR-2)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/raw/details/2176-review-comments.json`

## Caveats

- The register says the UNIX ownership-cycle hazard is discussed in #2176 and
  the datagram/self-FD instance remains a scope extension.
- The ownership graph is source-confirmed. The runtime resource-release
  consequence is untested.
- Report T-9 is this entry, but brief T-9 is AST-35. Cite the artifact with
  the ID.
- The capability-check detail and the use of the abstract address as the
  observer come from a package-builder reading of the pin.
- `ctrl_msg.rs`, `datagram/message.rs` and `datagram/socket.rs` are unchanged
  between the pin and upstream main `bc12195` (package-builder `git diff`,
  2026-09-24).
