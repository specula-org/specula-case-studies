# Asterinas

## Scope

Early experiments analyzed mutexes, reader-writer mutexes, spinlocks, and an
SPSC ring buffer, including lock acquisition, upgrade/downgrade, FIFO wakeups,
and empty/full/wraparound behavior. They recorded no bugs in that scope.

The later [findings collection](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/README.md)
covers Linux file I/O, partial progress, shared offsets, ramfs/ext2/exFAT size
consistency, and epoll/poll/timerfd/signalfd readiness. It was supplied as
reports and reproduction material from several runs; complete original run
outputs were not included.

## Findings

The collection contributes **22 Specula tracking entries: 21 reported as
REPRODUCED and one MASKED**. These are source dispositions at their recorded
commits. They do not imply current-version reproduction, novelty, or blanket
maintainer confirmation. The tracking classification is **17 New and five
Known**, based on earlier upstream issue, review, or fix coverage. Original
AST IDs are retained separately, including entries that share a mechanism.

| ID | Finding | Source disposition | Source run |
|---|---|---|---|
| [AST-01](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-01-ext2-buffered-write-prefix/finding.md) | ext2 write faults leave a committed prefix unreported | REPRODUCED | 01a MC-2 |
| [AST-02](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-02-ramfs-size-publication/finding.md) | ramfs size publication before an empty or zero-progress write | REPRODUCED | 01a MC-4 |
| [AST-03](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-03-vector-atomicity/finding.md) | Vectored I/O releases the offset lock between iovecs | REPRODUCED | 01a MC-5 |
| [AST-04](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-04-read-prefix-efault/finding.md) | Read faults hide copied progress and leave the shared offset unchanged | REPRODUCED | 01a MC-1 |
| [AST-05](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-05-ramfs-read-past-eof/finding.md) | ramfs/exFAT reads copy beyond the reported EOF prefix | REPRODUCED | 01a MC-3 |
| [AST-06](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-06-append-offset-on-fault/finding.md) | Failed append advances the shared file offset | REPRODUCED | 01a MC-7 |
| [AST-09](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-09-pipe-readv-eintr-restart/finding.md) | Pipe readv/writev return EINTR despite SA_RESTART | REPRODUCED | GLM CR-2 |
| [AST-10](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-10-ramfs-read-length-snapshot-resize/finding.md) | ramfs snapshots read length before serializing with resize | REPRODUCED | 01b MC-1 |
| [AST-11](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-11-exfat-stale-write-preparation/finding.md) | exFAT write preparation becomes stale before copy/publication | REPRODUCED | 01b MC-3 |
| [AST-12](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-12-exfat-ftruncate-retains-old-size/finding.md) | Successful exFAT ftruncate retains the old logical size | REPRODUCED | 01b MC-4 |
| [AST-13](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-13-exfat-regrown-hole-stale-bytes/finding.md) | exFAT regrown holes expose the file's old backing bytes | REPRODUCED | 01b MC-5 |
| [AST-14](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-14-exfat-empty-write-enlarges-eof/finding.md) | Empty exFAT writes enlarge EOF and may allocate clusters | REPRODUCED | 01b MC-7 |
| [AST-15](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-15-exfat-cold-tail-guard-reentry/finding.md) | exFAT cold-tail extension re-enters an inode write guard and deadlocks | REPRODUCED | 01b CR-2 |
| [AST-16](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-16-epoll-copyout-efault-loses-edge-readiness/finding.md) | epoll copy-out EFAULT loses edge-triggered readiness | REPRODUCED | FD MC-1 |
| [AST-17](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-17-epoll-oneshot-disabled-before-delivery/finding.md) | epoll disables one-shot interest before successful delivery | REPRODUCED | FD MC-2 |
| [AST-18](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-18-final-close-dead-epoll-interest/finding.md) | Final close retains dead epoll interest metadata | REPRODUCED | FD MC-3 |
| [AST-19](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-19-consumed-timerfd-stale-poll-cache/finding.md) | Consumed timerfd remains ready through the poll cache | REPRODUCED | FD MC-4 |
| [AST-20](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-20-signalfd-mask-change-omits-readiness/finding.md) | signalfd mask change omits newly eligible readiness | REPRODUCED | FD MC-5 |
| [AST-21](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-21-poll-timeout-after-timerfd-readable/finding.md) | poll times out after timerfd becomes readable | REPRODUCED | FD MC-6 |
| [AST-22](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-22-signalfd-epoll-binds-registering-thread/finding.md) | signalfd epoll readiness binds to the registering thread | REPRODUCED | FD CR-4 |
| [AST-23](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-23-epoll-pwait-pselect6-timeout-skips-readiness/finding.md) | epoll_pwait/pselect6 timeout skips deferred pipe readiness | REPRODUCED | FD CR-5 |
| [AST-24](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/findings/AST-24-ext2-direct-write-live-bio/finding.md) | ext2 direct-write fault paths can bypass waiting for earlier BIOs | MASKED | 01a MC-6 |

The 01a, GLM, and 01b findings use Asterinas
`604948581512d83734377974d4c34adb4530f2d7`; the FD findings use
`4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`. Later checks on other commits are
identified in the individual reports.

AST-01/04 share the partial-progress family tracked by
[issue #711](https://github.com/asterinas/asterinas/issues/711); AST-16/17
cover edge-triggered and one-shot effects of committing before event copyout.
AST-11 required a kernel timing hook in the original run and has separate
later hook-free evidence. AST-21 retains uncertainty about the preserved
ordering evidence. AST-24 retains the MASKED label because subsequent I/O
corruption was not observed.

## Additional records

The [complete 72-entry index](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/source-README.md#index)
also retains two externally sourced reproduced findings (AST-07/08), 41 source
leads, two unsupported-feature entries, three false positives, one dropped
candidate, and one model error. These 50 entries are outside the 22-entry
Specula tracking set. Cross-run rediscoveries are recorded as aliases.

See the [import notes](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/review/import-notes.md)
for the checked upstream links and historical-metadata qualifications, and the
[reproduction guide](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/docs/running-reproducers.md)
for environment and result-marker requirements.

## Upstream updates

As of 2026-10-03, [PR #3875](https://github.com/asterinas/asterinas/pull/3875) has merged (2026-09-29). It fixes AST-14 and the empty-write subcase of AST-02. AST-02 also covers zero-progress copy faults, so the entire entry is not marked fixed. [PR #3778](https://github.com/asterinas/asterinas/pull/3778), associated with AST-05/AST-10, remains open. Original reports and their historical source dispositions are unchanged.
