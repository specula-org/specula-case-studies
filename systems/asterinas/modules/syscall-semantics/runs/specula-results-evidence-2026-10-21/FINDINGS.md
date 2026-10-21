# Selected Asterinas findings

The 76 selected tracking entries exclude 13 false positives, two unsupported-operation records, one dropped candidate, and one model error from the 93-entry source catalog. Original dispositions remain in the supplied evidence. Tracker labels preserve historical higher statuses and are separate from source evidence and upstream repair coverage.

| AST | Finding | Source disposition | Tracker status | New/Known |
|---|---|---|---|---|
| [AST-01](findings/AST-01/finding.md) | ext2 durable write prefix returned as EFAULT | REPRODUCED | Confirmed | Known |
| [AST-02](findings/AST-02/finding.md) | ramfs size publication before an empty or zero-progress write | REPRODUCED | Fixed | New |
| [AST-03](findings/AST-03/finding.md) | Vectored I/O releases the offset lock between iovecs | REPRODUCED | Confirmed | New |
| [AST-04](findings/AST-04/finding.md) | A copied read prefix is erased by EFAULT reporting | REPRODUCED | Confirmed | Known |
| [AST-05](findings/AST-05/finding.md) | ramfs/exFAT reads copy beyond the reported EOF prefix | REPRODUCED | Fixed | New |
| [AST-06](findings/AST-06/finding.md) | Failed append advances the shared file offset | REPRODUCED | Confirmed | Known |
| [AST-07](findings/AST-07/finding.md) | Empty Segment conversion dereferences an unowned first frame | REPRODUCED | Fixed | New |
| [AST-08](findings/AST-08/finding.md) | IOMMU teardown frees frames before IOTLB invalidation | REPRODUCED | Confirmed | New |
| [AST-09](findings/AST-09/finding.md) | Pipe readv/writev return EINTR despite SA_RESTART | REPRODUCED | Confirmed | Known |
| [AST-10](findings/AST-10/finding.md) | ramfs snapshots read length before serializing with resize | REPRODUCED | Fixed | Known |
| [AST-11](findings/AST-11/finding.md) | exFAT write preparation becomes stale before copy/publication | REPRODUCED | Confirmed | New |
| [AST-12](findings/AST-12/finding.md) | Successful exFAT ftruncate retains the old logical size | REPRODUCED | Confirmed | New |
| [AST-13](findings/AST-13/finding.md) | exFAT regrown holes expose the file's old backing bytes | REPRODUCED | Confirmed | New |
| [AST-14](findings/AST-14/finding.md) | Empty exFAT writes enlarge EOF and may allocate clusters | REPRODUCED | Fixed | New |
| [AST-15](findings/AST-15/finding.md) | exFAT cold-tail extension re-enters an inode write guard | REPRODUCED | Confirmed | New |
| [AST-16](findings/AST-16/finding.md) | epoll copy-out EFAULT loses edge-triggered readiness | REPRODUCED | Confirmed | New |
| [AST-17](findings/AST-17/finding.md) | epoll disables one-shot interest before successful delivery | REPRODUCED | Confirmed | New |
| [AST-18](findings/AST-18/finding.md) | Final close retains dead epoll interest metadata | REPRODUCED | Confirmed | New |
| [AST-19](findings/AST-19/finding.md) | Consumed timerfd remains ready through the poll cache | REPRODUCED | Fixed | New |
| [AST-20](findings/AST-20/finding.md) | signalfd mask change omits newly eligible readiness | REPRODUCED | Confirmed | New |
| [AST-21](findings/AST-21/finding.md) | poll times out after timerfd becomes readable | REPRODUCED | Confirmed | New |
| [AST-22](findings/AST-22/finding.md) | signalfd epoll readiness binds to the registering thread | REPRODUCED | Confirmed | New |
| [AST-23](findings/AST-23/finding.md) | epoll_pwait/pselect6 timeout skips deferred pipe readiness | REPRODUCED | Confirmed | New |
| [AST-24](findings/AST-24/finding.md) | ext2 direct-write fault/rollback can leave an earlier BIO live | MASKED | Confirmed | New |
| [AST-25](findings/AST-25/finding.md) | PageCache/VmIo no-short-read contract versus capacity clamp | SOURCE LEAD | Blank | New |
| [AST-30](findings/AST-30/finding.md) | IP UDP source-copy fault may publish a malformed datagram | SOURCE LEAD | Blank | New |
| [AST-31](findings/AST-31/finding.md) | Socket effects precede whole-header writeback to user memory | SOURCE LEAD | Blank | New |
| [AST-32](findings/AST-32/finding.md) | SCM_RIGHTS installs an FD before publishing its number | REPRODUCED | Confirmed | New |
| [AST-33](findings/AST-33/finding.md) | Empty Unix records evade capacity accounting or readiness | SOURCE LEAD | Blank | New |
| [AST-34](findings/AST-34/finding.md) | Unix datagram SCM_RIGHTS references can form ownership cycles | SOURCE LEAD | Blank | New |
| [AST-35](findings/AST-35/finding.md) | IP socket user copy may fault while holding atomic-mode locks | SOURCE LEAD | Blank | New |
| [AST-36](findings/AST-36/finding.md) | Unix datagram receive may retain a record after copy fault | REPRODUCED | Confirmed | New |
| [AST-37](findings/AST-37/finding.md) | Iovec aggregate limits and edge cases need contract checks | SOURCE LEAD | Blank | New |
| [AST-38](findings/AST-38/finding.md) | sendmmsg batch length lacks the Linux UIO_MAXIOV clamp | SOURCE LEAD | Blank | New |
| [AST-39](findings/AST-39/finding.md) | Socket timeout/restart may repeat committed progress | SOURCE LEAD | Blank | New |
| [AST-40](findings/AST-40/finding.md) | ext2 invalidation error may bypass write rollback | SOURCE LEAD | Blank | Known |
| [AST-42](findings/AST-42/finding.md) | Lossy UTF-8 conversion aliases distinct filename byte strings | SOURCE LEAD | Blank | Known |
| [AST-43](findings/AST-43/finding.md) | Scalar decomposition of vectored datagram I/O breaks record boundaries | SOURCE LEAD | Blank | New |
| [AST-44](findings/AST-44/finding.md) | Pipe readv continues blocking after a completed positive prefix | SOURCE LEAD | Blank | New |
| [AST-45](findings/AST-45/finding.md) | Accepted RWF semantic flags are discarded before I/O | SOURCE LEAD | Blank | Known |
| [AST-47](findings/AST-47/finding.md) | openat FD insertion omits the stored RLIMIT_NOFILE limit | SOURCE LEAD | Blank | Known |
| [AST-48](findings/AST-48/finding.md) | set_tid_address ignores its pointer and updates the wrong TID field | SOURCE LEAD | Blank | New |
| [AST-49](findings/AST-49/finding.md) | Generic KernelSignal construction erases source-specific signal payload | SOURCE LEAD | Blank | Known |
| [AST-50](findings/AST-50/finding.md) | PDEATHSIG tracks parent-process rather than creating-thread lifetime | SOURCE LEAD | Blank | New |
| [AST-51](findings/AST-51/finding.md) | msync MS_SYNC discards inode synchronization errors | SOURCE LEAD | Blank | New |
| [AST-53](findings/AST-53/finding.md) | MADV_FREE no-op handling omits mapping-kind validation | SOURCE LEAD | Blank | New |
| [AST-54](findings/AST-54/finding.md) | Raw select uses a fixed libc-sized bitmap instead of nfds-sized input | SOURCE LEAD | Blank | New |
| [AST-55](findings/AST-55/finding.md) | Raw select/ppoll omit remaining-timeout writeback | SOURCE LEAD | Blank | Known |
| [AST-56](findings/AST-56/finding.md) | TTY noncanonical reads omit VTIME timeout behavior | SOURCE LEAD | Blank | New |
| [AST-57](findings/AST-57/finding.md) | TTY canonical reads apply the noncanonical VMIN threshold | SOURCE LEAD | Blank | New |
| [AST-58](findings/AST-58/finding.md) | TTY canonical input drops bytes outside its printable-ASCII filter | SOURCE LEAD | Blank | New |
| [AST-59](findings/AST-59/finding.md) | TIOCSWINSZ changes size without generating SIGWINCH | SOURCE LEAD | Blank | New |
| [AST-60](findings/AST-60/finding.md) | getrusage leaves maintained resource-accounting fields zero | SOURCE LEAD | Blank | New |
| [AST-61](findings/AST-61/finding.md) | getrusage accepts a NULL output pointer without copyout error | SOURCE LEAD | Blank | New |
| [AST-62](findings/AST-62/finding.md) | timerfd_create accepts generic CPU clocks outside its Linux domain | SOURCE LEAD | Fixed | Known |
| [AST-63](findings/AST-63/finding.md) | Signal number is narrowed to u8 before validation | SOURCE LEAD | Blank | New |
| [AST-64](findings/AST-64/finding.md) | Nonnegative Duration conversion rejects pre-Epoch file timestamps | SOURCE LEAD | Blank | Known |
| [AST-65](findings/AST-65/finding.md) | Accepted TCP socket does not inherit listener TCP_KEEPIDLE | SOURCE LEAD | Blank | New |
| [AST-66](findings/AST-66/finding.md) | pidfd_send_signal rejects the /proc/PID directory-FD form | SOURCE LEAD | Blank | New |
| [AST-67](findings/AST-67/finding.md) | Expired clock_nanosleep fast path bypasses clock validation | SOURCE LEAD | Blank | New |
| [AST-68](findings/AST-68/finding.md) | inotify accepts move subscriptions without matching rename notifications | SOURCE LEAD | Blank | New |
| [AST-69](findings/AST-69/finding.md) | TCP receive blocking decision ignores MSG_DONTWAIT | SOURCE LEAD | Blank | New |
| [AST-70](findings/AST-70/finding.md) | TCP send propagates EPIPE without generating SIGPIPE | SOURCE LEAD | Blank | New |
| [AST-71](findings/AST-71/finding.md) | personality ADDR_NO_RANDOMIZE setter may not change address layout | SOURCE LEAD | Blank | New |
| [AST-72](findings/AST-72/finding.md) | virtiofs direct empty write may publish a larger local size without a server write | SOURCE LEAD | Blank | New |
| [AST-73](findings/AST-73/finding.md) | Post-seal memfd read-only shared mappings retain writable tracking | REPRODUCED | Confirmed | New |
| [AST-74](findings/AST-74/finding.md) | MAP_SHARED_VALIDATE skips the ordinary shared-map FD write-access check | SOURCE LEAD | Blank | New |
| [AST-75](findings/AST-75/finding.md) | Seal-rejected shared MAP_FIXED removes the old mapping before returning EPERM | REPRODUCED | Confirmed | New |
| [AST-79](findings/AST-79/finding.md) | A cross-bucket requeued waiter's timeout cleanup misses its entry, and the stranded entry strands a live waiter | REPRODUCED | Confirmed | Known |
| [AST-80](findings/AST-80/finding.md) | FUTEX_REQUEUE converts a zero wake quota to one | REPRODUCED | Confirmed | Known |
| [AST-81](findings/AST-81/finding.md) | Same-bucket FUTEX_REQUEUE moves a waiter when the migration quota is zero | REPRODUCED | Confirmed | New |
| [AST-82](findings/AST-82/finding.md) | FUTEX_REQUEUE returns only the wake count, including on the same-address path | REPRODUCED | Confirmed | New |
| [AST-84](findings/AST-84/finding.md) | A conflicting flock SH→EX conversion keeps the caller's old SH lock | REPRODUCED | Confirmed | New |
| [AST-85](findings/AST-85/finding.md) | flock unlock drops a temporary owner reference under the list Mutex and self-deadlocks on re-entry | REPRODUCED | Confirmed | New |
| [AST-92](findings/AST-92/finding.md) | waitid without WEXITED consumes an exited child | REPRODUCED | Blank | New |
| [AST-93](findings/AST-93/finding.md) | waitid WNOHANG with no event leaves siginfo unwritten | REPRODUCED | Blank | New |

[Collection overview](README.md) · [Structured records](findings.json)
