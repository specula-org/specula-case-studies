# Asterinas findings package (AST-01..AST-72)

This package holds every entry of the Asterinas findings register as of
2026-09-24. The entries come from four Specula runs, one Specula
analysis-only run, two external reproduction packages, a TLPI-based interface
audit, and a backend source audit. Use it to check whether a new finding is
already known, or to pick up a finding and reproduce, fix, or report it
upstream.

## Rules before you use it

- **Keep it out of blind runs.** Do not put this package, or any finding
  text from it, into the context of a Specula analysis, spec-generation or
  hunting phase. Doing so seeds the model with the answers and makes the run
  useless as a measurement. Read it only during bug confirmation,
  deduplication, repair, or upstream work.
- **Check `status` before calling something a bug.** Only `REPRODUCED` and
  `MASKED` entries have runtime evidence of a defect. `SOURCE LEAD` and
  `UNSUPPORTED` entries are unverified questions. `FALSE POSITIVE`,
  `DROPPED` and `MODEL ERROR` entries record candidates that were rejected,
  so that nobody reports them again.
- **Evidence is tied to a pin.** Each entry records the Asterinas commit it
  was observed on (`origin.pin`). Upstream may have changed since. Re-run the
  reproducer on your target commit before claiming the bug still exists.
- **Upstream status is a snapshot.** Issue and PR matches come from a search
  on 2026-09-14, plus later checks noted in each entry. Check GitHub before
  filing anything.

## Layout

| Path | Contents |
|---|---|
| `findings.json` | All 72 entries in one file, one object per entry (schema below) |
| `specula-known-findings/asterinas.json` | Only the confirmed defects (`REPRODUCED` and `MASKED`), in the format of Specula's known-findings dataset |
| `findings/AST-xx-<slug>/finding.md` | The readable record: contract, mechanism, reproduction, fix status, evidence, caveats |
| `findings/AST-xx-<slug>/meta.json` | The same entry as structured data |
| `findings/AST-xx-<slug>/repro/` | Reproducer sources and a `README.md` on how to run them. `repro/variants/` holds reproductions of the same bug from other runs. |
| `docs/running-reproducers.md` | How to build and run a userspace reproducer on Asterinas in QEMU and compare it with Linux |
| `docs/confirmation-provenance.md` | Which findings Specula's confirmation phase verified, what human intervention it needed, and which were checked again outside Specula |
| `reference/id-map.md` | Maps the original run finding IDs (for example `01b:MC-3`) to AST IDs |
| `reference/upstream-matches.json` | The raw upstream issue and PR search results behind each entry's `upstream` field |

## Common tasks

**Deduplicate a new finding.** Compare the new finding's source files and
functions with each entry's `sites` (`path::symbol`), then compare its
mechanism with `keywords` and `syscalls`. A shared site plus a matching
mechanism is a likely duplicate. Read that entry's `finding.md` before
deciding, because two entries can share a site and still describe different
mechanisms (AST-05 and AST-10 are one example). Specula's matcher on the
`known-findings-dataset` branch reads `specula-known-findings/asterinas.json`
directly.

**Reproduce a bug.** Open the entry's `repro/README.md`, then follow
`docs/running-reproducers.md`. Use SMP=2 or more for any concurrency claim,
and run the same program on Linux as the oracle.

**Fix or upstream a bug.** Start from `finding.md`, which gives the source
sites and any local fix branch. Check `upstream.refs` for an existing issue
or PR first.

## Entry schema

`meta.json` and the objects in `findings.json` share one schema. The fields
`id`, `title`, `sites`, `syscalls`, `keywords`, `fix_status` and `report`
match Specula's known-findings dataset. The other fields add status, origin,
upstream, reproduction and evidence details.

| Field | Meaning |
|---|---|
| `status` | Evidence status from the register (see the rules above) |
| `origin` | Where the entry came from: kind, run alias and ID, original finding IDs, Asterinas pin |
| `also_seen_in` | Other runs that found the same mechanism, with their verdicts |
| `mechanism`, `sites` | The code path, with sites written as `path::symbol` |
| `contract`, `observed` | Linux-visible expectation and what Asterinas did |
| `upstream` | Match kind (`direct`, `open-pr`, `partial`, `related`, `merged-fix`, `none`, `not-checked`) and links |
| `fix_status`, `fix_refs` | Local and upstream fix state |
| `repro` | Whether a reproducer exists, its files, how to run it, SMP, and its runtime status |
| `evidence` | Absolute paths to the original artifacts on the machine that produced them |
| `related`, `caveats` | Related AST IDs and recorded limits |

The `evidence` paths point into the original workspace and Specula run
directories. They are not included in this package, so treat them as
provenance rather than as files you can open.

## Index

<!-- INDEX:START -->
72 entries: 41 SOURCE LEAD, 23 REPRODUCED, 3 FALSE POSITIVE, 2 UNSUPPORTED, 1 MASKED, 1 DROPPED, 1 MODEL ERROR.

| ID | Title | Status | Origin | Reproducer |
|---|---|---|---|---|
| [AST-01](findings/AST-01-ext2-buffered-write-prefix/finding.md) | ext2 durable write prefix returned as EFAULT | REPRODUCED | 01a MC-2 | yes |
| [AST-02](findings/AST-02-ramfs-size-publication/finding.md) | ramfs size publication before an empty or zero-progress write | REPRODUCED | 01a MC-4 | yes |
| [AST-03](findings/AST-03-vector-atomicity/finding.md) | Vectored I/O releases the offset lock between iovecs | REPRODUCED | 01a MC-5 | yes |
| [AST-04](findings/AST-04-read-prefix-efault/finding.md) | A copied read prefix is erased by EFAULT reporting | REPRODUCED | 01a MC-1 | yes |
| [AST-05](findings/AST-05-ramfs-read-past-eof/finding.md) | ramfs/exFAT reads copy beyond the reported EOF prefix | REPRODUCED | 01a MC-3 | yes |
| [AST-06](findings/AST-06-append-offset-on-fault/finding.md) | Failed append advances the shared file offset | REPRODUCED | 01a MC-7 | yes |
| [AST-07](findings/AST-07-segment-empty-slice/finding.md) | Empty Segment conversion dereferences an unowned first frame | REPRODUCED | External CR-11 | yes |
| [AST-08](findings/AST-08-iommu-stale-iotlb/finding.md) | IOMMU teardown frees frames before IOTLB invalidation | REPRODUCED | External CR-20 | yes |
| [AST-09](findings/AST-09-pipe-readv-eintr-restart/finding.md) | Pipe readv/writev return EINTR despite SA_RESTART | REPRODUCED | GLM CR-2 | yes |
| [AST-10](findings/AST-10-ramfs-read-length-snapshot-resize/finding.md) | ramfs snapshots read length before serializing with resize | REPRODUCED | 01b MC-1 | yes |
| [AST-11](findings/AST-11-exfat-stale-write-preparation/finding.md) | exFAT write preparation becomes stale before copy/publication | REPRODUCED | 01b MC-3 | yes |
| [AST-12](findings/AST-12-exfat-ftruncate-retains-old-size/finding.md) | Successful exFAT ftruncate retains the old logical size | REPRODUCED | 01b MC-4 | yes |
| [AST-13](findings/AST-13-exfat-regrown-hole-stale-bytes/finding.md) | exFAT regrown holes expose the file's old backing bytes | REPRODUCED | 01b MC-5 | yes |
| [AST-14](findings/AST-14-exfat-empty-write-enlarges-eof/finding.md) | Empty exFAT writes enlarge EOF and may allocate clusters | REPRODUCED | 01b MC-7 | yes |
| [AST-15](findings/AST-15-exfat-cold-tail-guard-reentry/finding.md) | exFAT cold-tail extension re-enters an inode write guard | REPRODUCED | 01b CR-2 | yes |
| [AST-16](findings/AST-16-epoll-copyout-efault-loses-edge-readiness/finding.md) | epoll copy-out EFAULT loses edge-triggered readiness | REPRODUCED | FD MC-1 | yes |
| [AST-17](findings/AST-17-epoll-oneshot-disabled-before-delivery/finding.md) | epoll disables one-shot interest before successful delivery | REPRODUCED | FD MC-2 | yes |
| [AST-18](findings/AST-18-final-close-dead-epoll-interest/finding.md) | Final close retains dead epoll interest metadata | REPRODUCED | FD MC-3 | yes |
| [AST-19](findings/AST-19-consumed-timerfd-stale-poll-cache/finding.md) | Consumed timerfd remains ready through the poll cache | REPRODUCED | FD MC-4 | yes |
| [AST-20](findings/AST-20-signalfd-mask-change-omits-readiness/finding.md) | signalfd mask change omits newly eligible readiness | REPRODUCED | FD MC-5 | yes |
| [AST-21](findings/AST-21-poll-timeout-after-timerfd-readable/finding.md) | poll times out after timerfd becomes readable | REPRODUCED | FD MC-6 | yes |
| [AST-22](findings/AST-22-signalfd-epoll-binds-registering-thread/finding.md) | signalfd epoll readiness binds to the registering thread | REPRODUCED | FD CR-4 | yes |
| [AST-23](findings/AST-23-epoll-pwait-pselect6-timeout-skips-readiness/finding.md) | epoll_pwait/pselect6 timeout skips deferred pipe readiness | REPRODUCED | FD CR-5 | yes |
| [AST-24](findings/AST-24-ext2-direct-write-live-bio/finding.md) | ext2 direct-write fault/rollback can leave an earlier BIO live | MASKED | 01a MC-6 | yes |
| [AST-25](findings/AST-25-pagecache-vmio-short-read-contract/finding.md) | PageCache/VmIo no-short-read contract versus capacity clamp | SOURCE LEAD | 01b CR-1 | none |
| [AST-26](findings/AST-26-regular-file-eintr-restart/finding.md) | Regular-file partial-progress EINTR restart candidate | FALSE POSITIVE | 01a CR-1 | yes |
| [AST-27](findings/AST-27-positional-io-shared-offset/finding.md) | Scalar positional I/O allegedly changes shared offset | FALSE POSITIVE | GLM CR-1 | yes |
| [AST-28](findings/AST-28-ofd-identity-lost-across-dup2-exec/finding.md) | OFD identity allegedly lost across dup2/exec | FALSE POSITIVE | FD CR-1 | yes |
| [AST-29](findings/AST-29-cyclic-epoll-self-back-edge/finding.md) | Cyclic epoll self/back-edge candidate | DROPPED | FD CR-6 | NOT_RUN |
| [AST-30](findings/AST-30-udp-copy-fault-malformed-datagram/finding.md) | IP UDP source-copy fault may publish a malformed datagram | SOURCE LEAD | Recon T-2 | none |
| [AST-31](findings/AST-31-socket-whole-header-writeback/finding.md) | Socket effects precede whole-header writeback to user memory | SOURCE LEAD | Recon MC-3/T-5/CR-3 | none |
| [AST-32](findings/AST-32-scm-rights-install-before-publish/finding.md) | SCM_RIGHTS installs an FD before publishing its number | SOURCE LEAD | Recon MC-4/T-4/CR-5 | none |
| [AST-33](findings/AST-33-empty-unix-records-accounting/finding.md) | Empty Unix records evade capacity accounting or readiness | SOURCE LEAD | Recon T-8/CR-6 | none |
| [AST-34](findings/AST-34-unix-datagram-scm-cycles/finding.md) | Unix datagram SCM_RIGHTS references can form ownership cycles | SOURCE LEAD | Recon T-9/CR-7 | none |
| [AST-35](findings/AST-35-ip-socket-copy-atomic-locks/finding.md) | IP socket user copy may fault while holding atomic-mode locks | SOURCE LEAD | Recon T-10 | none |
| [AST-36](findings/AST-36-unix-datagram-retain-after-fault/finding.md) | Unix datagram receive may retain a record after copy fault | SOURCE LEAD | Recon MC-2/T-3 | none |
| [AST-37](findings/AST-37-iovec-aggregate-limits-edge-cases/finding.md) | Iovec aggregate limits and edge cases need contract checks | SOURCE LEAD | Recon T-6/CR-4 | none |
| [AST-38](findings/AST-38-sendmmsg-uio-maxiov-clamp/finding.md) | sendmmsg batch length lacks the Linux UIO_MAXIOV clamp | SOURCE LEAD | Recon T-6/CR-3 | none |
| [AST-39](findings/AST-39-socket-timeout-restart-progress/finding.md) | Socket timeout/restart may repeat committed progress | SOURCE LEAD | Recon MC-5/T-7 | none |
| [AST-40](findings/AST-40-ext2-invalidation-bypasses-rollback/finding.md) | ext2 invalidation error may bypass write rollback | SOURCE LEAD | Recon CR-2 | none |
| [AST-41](findings/AST-41-signalfd-model-registration-later-waiter/finding.md) | signalfd model attributes registration to a later waiter | MODEL ERROR | FD s4_binding (historical MC_hunt_s4_binding counterexample, no native finding ID) | none |
| [AST-42](findings/AST-42-lossy-utf8-filename-aliasing/finding.md) | Lossy UTF-8 conversion aliases distinct filename byte strings | SOURCE LEAD | TLPI-v2 F01 | NOT_RUN |
| [AST-43](findings/AST-43-vectored-datagram-record-boundaries/finding.md) | Scalar decomposition of vectored datagram I/O breaks record boundaries | SOURCE LEAD | TLPI-v2 F02 | NOT_RUN |
| [AST-44](findings/AST-44-pipe-readv-blocks-after-prefix/finding.md) | Pipe readv continues blocking after a completed positive prefix | SOURCE LEAD | TLPI-v2 F02 | NOT_RUN |
| [AST-45](findings/AST-45-rwf-semantic-flags-discarded/finding.md) | Accepted RWF semantic flags are discarded before I/O | SOURCE LEAD | TLPI-v2 F03 | none |
| [AST-46](findings/AST-46-rwf-append-unsupported/finding.md) | RWF_APPEND is not supported by the reviewed vectored-I/O flags | UNSUPPORTED | TLPI-v2 F03 | NOT_RUN |
| [AST-47](findings/AST-47-openat-ignores-rlimit-nofile/finding.md) | openat FD insertion omits the stored RLIMIT_NOFILE limit | SOURCE LEAD | TLPI-v2 F04 | NOT_RUN |
| [AST-48](findings/AST-48-set-tid-address-wrong-field/finding.md) | set_tid_address ignores its pointer and updates the wrong TID field | SOURCE LEAD | TLPI-v2 F05 | none |
| [AST-49](findings/AST-49-kernelsignal-erases-signal-payload/finding.md) | Generic KernelSignal construction erases source-specific signal payload | SOURCE LEAD | TLPI-v2 F06/F18 | NOT_RUN |
| [AST-50](findings/AST-50-pdeathsig-process-not-thread-lifetime/finding.md) | PDEATHSIG tracks parent-process rather than creating-thread lifetime | SOURCE LEAD | TLPI-v2 F07 | none |
| [AST-51](findings/AST-51-msync-sync-discards-errors/finding.md) | msync MS_SYNC discards inode synchronization errors | SOURCE LEAD | TLPI-v2 F08 | none |
| [AST-52](findings/AST-52-madv-dontfork-unimplemented/finding.md) | MADV_DONTFORK is not implemented in the reviewed advice handler | UNSUPPORTED | TLPI-v2 F09 | NOT_RUN |
| [AST-53](findings/AST-53-madv-free-mapping-validation/finding.md) | MADV_FREE no-op handling omits mapping-kind validation | SOURCE LEAD | TLPI-v2 F09 | NOT_RUN |
| [AST-54](findings/AST-54-select-fixed-fdset-bitmap/finding.md) | Raw select uses a fixed libc-sized bitmap instead of nfds-sized input | SOURCE LEAD | TLPI-v2 F10 | NOT_RUN |
| [AST-55](findings/AST-55-select-ppoll-timeout-writeback/finding.md) | Raw select/ppoll omit remaining-timeout writeback | SOURCE LEAD | TLPI-v2 F11 | NOT_RUN |
| [AST-56](findings/AST-56-tty-vtime-timeout-ignored/finding.md) | TTY noncanonical reads omit VTIME timeout behavior | SOURCE LEAD | TLPI-v2 F12 | NOT_RUN |
| [AST-57](findings/AST-57-tty-canonical-read-vmin/finding.md) | TTY canonical reads apply the noncanonical VMIN threshold | SOURCE LEAD | TLPI-v2 F12 | NOT_RUN |
| [AST-58](findings/AST-58-tty-canonical-drops-nonprintable-bytes/finding.md) | TTY canonical input drops bytes outside its printable-ASCII filter | SOURCE LEAD | TLPI-v2 F13 | NOT_RUN |
| [AST-59](findings/AST-59-tiocswinsz-no-sigwinch/finding.md) | TIOCSWINSZ changes size without generating SIGWINCH | SOURCE LEAD | TLPI-v2 F14 | NOT_RUN |
| [AST-60](findings/AST-60-getrusage-accounting-fields-zero/finding.md) | getrusage leaves maintained resource-accounting fields zero | SOURCE LEAD | TLPI-v2 F15 | NOT_RUN |
| [AST-61](findings/AST-61-getrusage-null-pointer-accepted/finding.md) | getrusage accepts a NULL output pointer without copyout error | SOURCE LEAD | TLPI-v2 F15 | NOT_RUN |
| [AST-62](findings/AST-62-timerfd-create-accepts-cpu-clocks/finding.md) | timerfd_create accepts generic CPU clocks outside its Linux domain | SOURCE LEAD | TLPI-v2 F16 | NOT_RUN |
| [AST-63](findings/AST-63-signal-number-u8-narrowing/finding.md) | Signal number is narrowed to u8 before validation | SOURCE LEAD | TLPI-v2 F19 | NOT_RUN |
| [AST-64](findings/AST-64-pre-epoch-timestamps-rejected/finding.md) | Nonnegative Duration conversion rejects pre-Epoch file timestamps | SOURCE LEAD | TLPI-v2 F20 | NOT_RUN |
| [AST-65](findings/AST-65-tcp-accept-keepidle-not-inherited/finding.md) | Accepted TCP socket does not inherit listener TCP_KEEPIDLE | SOURCE LEAD | TLPI-v2 F21 | NOT_RUN |
| [AST-66](findings/AST-66-pidfd-send-signal-procdir-fd/finding.md) | pidfd_send_signal rejects the /proc/PID directory-FD form | SOURCE LEAD | TLPI-v2 F22 | NOT_RUN |
| [AST-67](findings/AST-67-clock-nanosleep-expired-fast-path/finding.md) | Expired clock_nanosleep fast path bypasses clock validation | SOURCE LEAD | TLPI-v2 F23 | NOT_RUN |
| [AST-68](findings/AST-68-inotify-rename-events-missing/finding.md) | inotify accepts move subscriptions without matching rename notifications | SOURCE LEAD | TLPI-v2 F24 | NOT_RUN |
| [AST-69](findings/AST-69-tcp-recv-ignores-msg-dontwait/finding.md) | TCP receive blocking decision ignores MSG_DONTWAIT | SOURCE LEAD | TLPI-v2 F25 | NOT_RUN |
| [AST-70](findings/AST-70-tcp-send-epipe-no-sigpipe/finding.md) | TCP send propagates EPIPE without generating SIGPIPE | SOURCE LEAD | TLPI-v2 F26 | NOT_RUN |
| [AST-71](findings/AST-71-personality-addr-no-randomize/finding.md) | personality ADDR_NO_RANDOMIZE setter may not change address layout | SOURCE LEAD | TLPI-v2 C01 | none |
| [AST-72](findings/AST-72-virtiofs-direct-empty-write/finding.md) | virtiofs direct empty write may publish a larger local size without a server write | SOURCE LEAD | Backend audit | none |
<!-- INDEX:END -->
