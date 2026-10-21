# Asterinas Findings Catalog

Unified on 2026-09-14 as **AST-01 through AST-71**. AST-01..09 retain their
existing identities. The directory keeps its original name and evidence paths.
The 2026-09-16 backend source audit adds **AST-72**, an unconfirmed virtiofs
direct empty-write lead. The [2026-10-03 memfd source analysis](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md)
adds **AST-73/74** as unconfirmed mapping-admission leads. The current register
is AST-01 through AST-93. The native memfd run maps TV-1 to existing AST-73
and adds TV-2 as AST-75. Its completed pipeline reproduced both on Asterinas
and dismissed three code-review candidates as AST-76..78. The four lane
records of 2026-10-04..10 add AST-79..93: futex AST-79..83,
flock AST-84..89, SCM_RIGHTS dismissals AST-90/91 and wait/reap AST-92/93.
The SCM_RIGHTS run also reproduced existing leads AST-32 and AST-36.
The [old-ID map](id-map.md) resolves all 34 final dispositions from FD/01a/GLM/01b,
the two external packages, reconnaissance report/brief candidate IDs, and
TLPI-v2 attachment groups. [TLPI intake](../tlpi-audit-2026-09-14/README.md)
adds source leads and unsupported-operation records only; its tests are NOT_RUN.

The 93 tracking entries contain 35 REPRODUCED records, one MASKED
record, 40 SOURCE LEAD follow-ups, two UNSUPPORTED operation records, 13
FALSE POSITIVE records, one DROPPED record, and one MODEL ERROR. These are
tracking counts, not a new count of independent vulnerabilities or unfixed
current-HEAD bugs.

The [reproduction index and local dedup audit](reproduced.md), checked on
2026-10-12, separates those 35 entries into 31 with native confirmation
reports, two with kernel/device reproduction records, and two outcome-only
wait/reap observations. Eight distinct native reports contain 54 final
finding records, including 38 REPRODUCED records that map to 31 AST entries.
Repeated runs and aliases are not additional defects. The scan did not rerun
tests or refresh upstream state. A read-only upstream refresh on 2026-10-19
is recorded under [Current upstream cross-check](#current-upstream-cross-check).

## Concurrency evidence limits

The four October lanes do not establish complete concurrency protocol
verification. Futex's key registration/wake/timeout histories and cross-CPU
clock comparability remain unvalidated. SCM_RIGHTS has real overlapping
events, but limited competition coverage and PEEK outside default MC.cfg.
Flock's general overlap criterion is met only by a four-event open trace;
AST-85 has separate observer-assisted race evidence for its specific defect.
Wait/reap has no implementation traces or credible distinct-CPU placement.
The [lane results](#campaign-register) retain individual checks, incomplete
searches, exceptions and reproduction assumptions.

Pipeline exit, trace replay, bounded model checking and defect reproduction
answer different questions. Accepting a limitation does not supply missing
interleaving evidence. Whole-trace interval overlap is not a percentage of
concurrency state-space coverage. Keep these qualifications when exporting
the catalog or describing the campaign.

## Current upstream cross-check

A read-only refresh on 2026-10-19 against upstream main `d0dc799a4c` changed
the following. These are static checks, and no local test was rerun.

- AST-02's empty-write subcase and AST-14 are fixed by the user's PR #3875,
  merged 2026-09-29. AST-02's nonempty zero-progress fault paths stay unfixed.
- AST-07 is reported by #3892 and fixed by PR #3959, merged 2026-10-11.
- AST-19 is fixed by PR #3984, merged 2026-10-13.
- AST-08's mechanism is item 11 of open omnibus issue #3920 (consolidated
  2026-09-26). It omits freed-frame reuse and has no reproduction. Main is
  still unfixed.
- AST-79 is reported by open issue #3964 (bdm-k, 2026-10-06, no linked PR).
  Its main body is the cross-bucket timeout cleanup miss, and the reporter
  added a musl reproducer on 2026-10-14. AST-80 is its second paragraph. The
  futex confirmation's NEW rating for AST-79 is wrong: its worker searched
  only with generic web search and missed the issue.
- AST-48's `todo!()` branch is reported as an unprivileged kernel panic by
  open issue #3962 (2026-10-06). Its log comes from main `73ef2b9b`, and the
  reporter says it was also observed on `0c60537098f4`. No local run exists.
- PR #3576 was force-pushed on 2026-10-09, 10-10 and 10-16 (head
  `694f86051`, the same three commits rebased). The AST-09 and AST-39
  judgments used the old head `8e02d0e94` and need review.
- AST-72..93 had a keyword pass only. AST-75, 81, 82 and 84 had no match;
  AST-72..74, 85, 92 and 93 have related items only. This is not a full
  deduplication like the September snapshot.

[Issue/PR deduplication](../upstream-dedup-2026-09-14/README.md) covers
AST-01..71 against upstream main `bc12195df4acfb1fc4ae968cf7acf9333ed83435`.
This is the 2026-09-14 snapshot. The native-agent searches mentioned below
retain their recorded October dates. None was refreshed by the local audit
on 2026-10-12.
AST-72..93 were added later and had only the 2026-10-19 keyword pass above.
Confirmation agents' own searches are recorded with their runs: the futex
agents matched AST-80 to #3964 and rated AST-79/81/82 NEW. The refresh shows
#3964 also reports AST-79.
The memfd confirmation agent's own upstream search found no report of AST-75's
mechanism. That search is recorded with the run, not as a dedup pass.
It separates direct reports, open-PR coverage, partial overlaps, related
mechanisms, and no direct match in the searched scope. Upstream state does
not rewrite the original evidence status or substitute for local test results.

That September snapshot records a merged fix for AST-62 and an open
PR #3778 matching AST-05/10. See [machine-readable decisions](../upstream-dedup-2026-09-14/matches.json)
for each entry's references, PR head, merge status, and search coverage.
All TLPI test plans remain NOT_RUN and keep their original source pin.

## Numbering and status

- Use `AST-xx` in current task lists and repair discussions. Keep original
  run IDs, finding IDs, filenames, and verdicts in evidence references.
- Append the next unused AST number for a distinct tracking item. Keep
  assigned numbers stable; use aliases for duplicates and retain merged or
  closed entries with their disposition. Numbering does not promote a finding.
- Match source mechanism and contract, not a common symptom. AST-05's
  unlimited writer and AST-10's stale read-length snapshot are distinct;
  the fixes and tests differ even though both affect buffered reads.
- One raw report may cover multiple entries. 01b:CR-1 reproduced AST-05's
  syscall effect and raised AST-25's latent contract question. AST-25's
  SOURCE LEAD status does not change the original CR-1 REPRODUCED verdict.
- A later run retains its own outcome: GLM:MC-4 is INCOMPLETE even though
  its mechanism, AST-03, was reproduced in 01a. Raw run dispositions and
  catalog evidence status are separate fields in the ID map.
- Historical reproduction, saved patch verification, current-HEAD validation,
  and upstream integration are separate states. No tests or upstream-status
  refresh ran during numbering.
- Keep finding bodies outside blind-baseline analysis/specgen/hunt contexts;
  use the catalog during confirmation/deduplication. Seeded runs remain separate.

## Unified register

REPRODUCED means a retained runtime record exists, with its original pin and
assumptions. AST-92/93 retain that catalog status for outcome-only observations;
neither has native confirmation. The reproduction index separates them from
native confirmation and kernel/device records. SOURCE LEAD includes untested
questions and contract follow-ups.
UNSUPPORTED identifies a source-documented capability gap, not a confirmed
implementation bug; imported runtime status remains separately NOT_RUN.
The evidence links and ID map retain the required limits for each entry.

| ID | Tracking item | Evidence status | Original reference | Repair / qualification |
| --- | --- | --- | --- | --- |
| [AST-01](AST-01-ext2-buffered-write-prefix/description.md) | ext2 durable write prefix returned as EFAULT | REPRODUCED | 01a:MC-2; GLM:MC-1 mechanism overlap | Upstream #711 is a partial mechanism match; #3297 is related rollback work. Historical v5 evidence remains distinct. |
| [AST-02](AST-02-ramfs-size-publication/description.md) | ramfs size publication before an empty or zero-progress write | REPRODUCED | 01a:MC-4; GLM:MC-3; 01b:MC-6/MC-8 | Empty-write subcase fixed upstream by PR #3875 (merged 2026-09-29), which carries the [local batch](../empty-write-batch-2026-09-16/README.md) with a revised ramfs guard; static check only. Nonempty zero-progress fault paths (01a CASE A/C/D/E, 01b MC-8) remain unfixed. Historical A/B retained. |
| [AST-03](AST-03-vector-atomicity/description.md) | Vectored I/O releases the offset lock between iovecs | REPRODUCED | 01a:MC-5; GLM:MC-4 | Historical v5 A/B; GLM confirmation itself stayed INCOMPLETE |
| [AST-04](AST-04-read-prefix-efault/description.md) | A copied read prefix is erased by EFAULT reporting | REPRODUCED | 01a:MC-1; GLM:MC-1 | Direct open issue #711; historical v5 A/B remains local evidence. |
| [AST-05](AST-05-ramfs-read-past-eof/description.md) | ramfs/exFAT reads copy beyond the reported EOF prefix | REPRODUCED | 01a:MC-3; GLM:MC-2; 01b:MC-2/CR-1 effect | Open PR #3778 at d007cbb62 covers EOF limiting; not merged or retested here. A 2026-09-14 maintainer review asks to move the clone-and-limit logic into a `VmIo` default method; unanswered as of 2026-10-19. The local branch was rebased to `35244712f` on 2026-10-08 and not pushed. |
| [AST-06](AST-06-append-offset-on-fault/description.md) | Failed append advances the shared file offset | REPRODUCED | 01a:MC-7 | Open PR #3481 moves offset publication after successful write; static coverage, no new runtime validation. |
| [AST-07](AST-07-segment-empty-slice/description.md) | Empty Segment conversion dereferences an unowned first frame | REPRODUCED | External CR-11 at 4c1fdd1e4 | Later ktest reproduces wrong answers; kernel death not reproduced at 604948581. Upstream: reported by #3892 and fixed by PR #3959 (merged 2026-10-11, `Segment::slice` rejects empty ranges); static check only. |
| [AST-08](AST-08-iommu-stale-iotlb/description.md) | IOMMU teardown frees frames before IOTLB invalidation | REPRODUCED | External CR-20 at 4c1fdd1e4 | Saved local fix and vIOMMU A/B verification; device-test assumptions remain. Upstream: item 11 of open omnibus issue #3920 (consolidated 2026-09-26) reports the missing IOTLB invalidation, without the freed-frame reuse or a reproduction; unfixed on main d0dc799a4c. Cite it in any AST-08 issue or PR. |
| [AST-09](AST-09-pipe-readv-eintr-restart/description.md) | Pipe readv/writev return EINTR despite SA_RESTART | REPRODUCED | GLM:CR-2 | Open PR #3576 covers wait-layer restart translation by inspection; local A/B history is separate. That inspection used head `8e02d0e94`; the PR was force-pushed on 2026-10-09, 10-10 and 10-16 (head `694f86051`, same three commits rebased), so coverage needs review. |
| AST-10 | ramfs snapshots read length before serializing with resize | REPRODUCED | 01b:MC-1; earlier read-fix review | Open PR #3778 at d007cbb62 includes lock-before-sizing; exact 01b schedule validation remains pending. |
| AST-11 | exFAT write preparation becomes stale before copy/publication | REPRODUCED | 01b:MC-3; earlier exFAT write-race work | Fix + `fs/write_race` on `fix/exfat-write-size-race` (`864356cec`, `3ece54702` on `upstream/main` `bc12195df`), A/B 2026-09-14: unfixed 65 to 93 of 2000 rounds bad, fixed 0; not pushed; retest both 01b schedules with AST-15 |
| AST-12 | Successful exFAT ftruncate retains the old logical size | REPRODUCED | 01b:MC-4 | Repair and size/EOF/remount verification pending |
| AST-13 | exFAT regrown holes expose the file's old backing bytes | REPRODUCED | 01b:MC-5 | Repair pending; only same-file stale data demonstrated |
| AST-14 | Empty exFAT writes enlarge EOF and may allocate clusters | REPRODUCED | 01b:MC-7 | Fixed upstream by PR #3875 (merged 2026-09-29), with the same buffered/direct guards as the [local batch](../empty-write-batch-2026-09-16/README.md); static check only, no local retest. Historical confirmation covers buffered I/O |
| AST-15 | exFAT cold-tail extension re-enters an inode write guard | REPRODUCED | 01b:CR-2 | Deadlock repair pending; retain AST-11 serialization while fixing backend I/O |
| AST-16 | epoll copy-out EFAULT loses edge-triggered readiness | REPRODUCED | FD:MC-1 | Historical SMP=2 guest evidence; current repair status not revalidated |
| AST-17 | epoll disables one-shot interest before successful delivery | REPRODUCED | FD:MC-2 | Historical SMP=2 guest evidence; current repair status not revalidated |
| AST-18 | Final close retains dead epoll interest metadata | REPRODUCED | FD:MC-3 | No numeric-FD retargeting or stale-event delivery demonstrated |
| AST-19 | Consumed timerfd remains ready through the poll cache | REPRODUCED | FD:MC-4; TLPI-v2:F17 source/test reference | Earlier FD guest evidence retained; imported drain/disarm/epoll probes remain NOT_RUN. Fixed upstream by PR #3984 (merged 2026-10-13: pollee invalidated in `set_time` and `try_read`, with a regression test); static check only. |
| AST-20 | signalfd mask change omits newly eligible readiness | REPRODUCED | FD:MC-5 | Historical guest evidence; current repair status not revalidated |
| AST-21 | poll times out after timerfd becomes readable | REPRODUCED | FD:MC-6 | Final ordering evidence retained with earlier independent-review uncertainty |
| AST-22 | signalfd epoll readiness binds to the registering thread | REPRODUCED | FD:CR-4 | Separate runtime finding from the discarded AST-41 model oracle |
| AST-23 | epoll_pwait/pselect6 timeout skips deferred pipe readiness | REPRODUCED | FD:CR-5 | Related timeout class to AST-21; distinct wait path and witness |
| AST-24 | ext2 direct-write fault/rollback can leave an earlier BIO live | MASKED | 01a:MC-6 | Observed backend masks harm; excluded from 01a v5 repair |
| AST-25 | PageCache/VmIo no-short-read contract versus capacity clamp | SOURCE LEAD | Contract remainder of 01b:CR-1 | Its reproduced syscall effect is AST-05; independent residual harm after caller fixes remains unverified |
| AST-26 | Regular-file partial-progress EINTR restart candidate | FALSE POSITIVE | 01a:CR-1 | Required regular-file EINTR path absent; pipe AST-09 has a different scope |
| AST-27 | Scalar positional I/O allegedly changes shared offset | FALSE POSITIVE | GLM:CR-1 | Scalar positional isolation holds; vector AST-03 is separate |
| AST-28 | OFD identity allegedly lost across dup2/exec | FALSE POSITIVE | FD:CR-1 | Source and reproduction preserve identity |
| AST-29 | Cyclic epoll self/back-edge candidate | DROPPED | FD:CR-6 | Supported-operation assumptions failed; retain the original disposition |
| AST-30 | IP UDP source-copy fault may publish a malformed datagram | SOURCE LEAD | Recon analysis:T-2 | Peer-visible outcome not reproduced |
| AST-31 | Socket effects precede whole-header writeback to user memory | SOURCE LEAD | Recon analysis:MC-3/T-5/CR-3 | Check contractual output fields; permitted post-effect faults are controls |
| [AST-32](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md) | SCM_RIGHTS installs an FD before publishing its number | REPRODUCED | Recon analysis:MC-4/T-4/CR-5; SCM_RIGHTS native run `asterinas-unix-dgram-scm-rights-20261004T064345Z`, MC-1 | Reproduced on Asterinas with a Linux 7.2.8 control: a first-integer copy-out fault (PEEK and ordinary) leaves one new FD installed with `msg_controllen` 0 and MSG_CTRUNC, where Linux installs none. Specula severity Critical; workspace assessment: compatibility bug and FD leak in the receiver's own table, which a peer cannot force. |
| AST-33 | Empty Unix records evade capacity accounting or readiness | SOURCE LEAD | Recon analysis:T-8/CR-6 | Queue bounds and zero-length seqpacket readability not tested |
| AST-34 | Unix datagram SCM_RIGHTS references can form ownership cycles | SOURCE LEAD | Recon analysis:T-9/CR-7 | UNIX ownership-cycle hazard discussed in #2176; datagram/self-FD instance remains a scope extension. |
| AST-35 | IP socket user copy may fault while holding atomic-mode locks | SOURCE LEAD | Recon analysis:T-10 | Concrete fault/lock failure not reproduced in a retained record. Local commit `4d1ed282b` on `fix/tcp-user-copy-atomic` (2026-09-27, on upstream/main 3eb661e12, unpushed) records an observed "might break atomic mode" panic on the TCP send/receive path and adds `tcp_unpopulated_buffer.c`; its run logs are not retained here, so promotion waits for archived evidence. UDP stays a lead. Upstream #2165 tracks the general hazard. |
| [AST-36](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md) | Unix datagram receive may retain a record after copy fault | REPRODUCED | Recon analysis:MC-2/T-3; SCM_RIGHTS native run `asterinas-unix-dgram-scm-rights-20261004T064345Z`, MC-2 | Reproduced on Asterinas with a Linux control: an ordinary payload fault leaves the datagram queued and a retry delivers its 4 FDs, where Linux consumes it and the retry gets EAGAIN. PEEK matches Linux. Compatibility difference, no security impact shown. |
| AST-37 | Iovec aggregate limits and edge cases need contract checks | SOURCE LEAD | Recon analysis:T-6/CR-4 | MAX_RW_COUNT versus isize::MAX and alias/overlap cases; no confirmed bug |
| AST-38 | sendmmsg batch length lacks the Linux UIO_MAXIOV clamp | SOURCE LEAD | Recon analysis:T-6/CR-3 | Separate batch-bound question from AST-31 header publication |
| AST-39 | Socket timeout/restart may repeat committed progress | SOURCE LEAD | Recon analysis:MC-5/T-7 | Broad restart question; AST-26 rejection applies only to regular files. The partial PR #3576 overlap was judged at head `8e02d0e94`; re-check against `694f86051`. |
| AST-40 | ext2 invalidation error may bypass write rollback | SOURCE LEAD | Recon analysis:CR-2 | Open draft #3297 places invalidation under a rollback guard; static coverage only. |
| AST-41 | signalfd model attributes registration to a later waiter | MODEL ERROR | FD historical s4_binding | Oracle corrected to ADD/MOD caller binding; not an implementation bug |
| AST-42 | Lossy UTF-8 conversion aliases distinct filename byte strings | SOURCE LEAD | TLPI-v2:F01 | Direct open issue #1097 already reports lossy filename aliasing; imported test remains NOT_RUN. |
| AST-43 | Scalar decomposition of vectored datagram I/O breaks record boundaries | SOURCE LEAD | TLPI-v2:F02 | Related to AST-03 splitting family; separate datagram contract, no target run |
| AST-44 | Pipe readv continues blocking after a completed positive prefix | SOURCE LEAD | TLPI-v2:F02 | Related vector-loop family; separate pipe progress/return contract |
| AST-45 | Accepted RWF semantic flags are discarded before I/O | SOURCE LEAD | TLPI-v2:F03 | #3142/#3729 track NOWAIT; SYNC/DSYNC remain explicitly deferred in #3729 discussion. |
| AST-46 | RWF_APPEND is not supported by the reviewed vectored-I/O flags | UNSUPPORTED | TLPI-v2:F03 | Static EOPNOTSUPP coverage gap; not a confirmed implementation bug |
| AST-47 | openat FD insertion omits the stored RLIMIT_NOFILE limit | SOURCE LEAD | TLPI-v2:F04 | Open tracking issue #2841 includes NOFILE; openat-specific coverage remains to verify. |
| AST-48 | set_tid_address ignores its pointer and updates the wrong TID field | SOURCE LEAD | TLPI-v2:F05 | The `todo!()` branch is reachable from a valid state (a thread created with CLONE_CHILD_CLEARTID). TLPI did not run the trigger or measure impact; no local runtime case exists. Open upstream issue #3962 (2026-10-06, no PR) reports an unprivileged whole-kernel panic there, with a log from main 73ef2b9b and a note that it was also observed on 0c60537098f4. The ignored-pointer/wrong-field part is not reported. |
| AST-49 | Generic KernelSignal construction erases source-specific signal payload | SOURCE LEAD | TLPI-v2:F06, F18 | Open #2913 overlaps the POSIX timer payload family; SIGCHLD/value deltas remain separate. |
| AST-50 | PDEATHSIG tracks parent-process rather than creating-thread lifetime | SOURCE LEAD | TLPI-v2:F07 | No complete handshake-based runtime case supplied |
| AST-51 | msync MS_SYNC discards inode synchronization errors | SOURCE LEAD | TLPI-v2:F08 | No writeback fault-injection case; no demonstrated data loss |
| AST-52 | MADV_DONTFORK is not implemented in the reviewed advice handler | UNSUPPORTED | TLPI-v2:F09 | #2766 deliberately removed the incorrect DONTFORK stub from #2692; retain unsupported status. |
| AST-53 | MADV_FREE no-op handling omits mapping-kind validation | SOURCE LEAD | TLPI-v2:F09 | A legal optimization no-op is not itself a bug; compare the shared-map validation case |
| AST-54 | Raw select uses a fixed libc-sized bitmap instead of nfds-sized input | SOURCE LEAD | TLPI-v2:F10 | Large nfds and page-end short bitmap probes; x86-64 raw syscall layer |
| AST-55 | Raw select/ppoll omit remaining-timeout writeback | SOURCE LEAD | TLPI-v2:F11 | Missing raw ppoll writeback is explicitly documented in merged PR #2025; select coverage and runtime confirmation remain separate. |
| AST-56 | TTY noncanonical reads omit VTIME timeout behavior | SOURCE LEAD | TLPI-v2:F12 | PTY setup and timing bounds need target verification |
| AST-57 | TTY canonical reads apply the noncanonical VMIN threshold | SOURCE LEAD | TLPI-v2:F12 | Separate mode/threshold defect from AST-56 timeout handling |
| AST-58 | TTY canonical input drops bytes outside its printable-ASCII filter | SOURCE LEAD | TLPI-v2:F13 | Byte-preservation probe only; not a complete terminal-editing audit |
| AST-59 | TIOCSWINSZ changes size without generating SIGWINCH | SOURCE LEAD | TLPI-v2:F14 | Observe notification in addition to getter state |
| AST-60 | getrusage leaves maintained resource-accounting fields zero | SOURCE LEAD | TLPI-v2:F15 | Compare only fields Linux actually maintains; no target measurement |
| AST-61 | getrusage accepts a NULL output pointer without copyout error | SOURCE LEAD | TLPI-v2:F15 | Separate output-pointer validation path from AST-60 accounting |
| AST-62 | timerfd_create accepts generic CPU clocks outside its Linux domain | SOURCE LEAD | TLPI-v2:F16 | #3823 closed by #3824, merged as upstream bc12195d; CPU-clock rejection statically verified. Local/TLPI pins were not changed or tested. |
| AST-63 | Signal number is narrowed to u8 before validation | SOURCE LEAD | TLPI-v2:F19 | timer_create/pidfd_send_signal share the narrowing pattern; no blanket high-register-bits rule |
| AST-64 | Nonnegative Duration conversion rejects pre-Epoch file timestamps | SOURCE LEAD | TLPI-v2:F20 | Direct open issue #3746; proposals #3826/#3827 closed without merge. No fixed main inferred. |
| AST-65 | Accepted TCP socket does not inherit listener TCP_KEEPIDLE | SOURCE LEAD | TLPI-v2:F21 | Option-state inheritance only; no keepalive packet-timing evidence |
| AST-66 | pidfd_send_signal rejects the /proc/PID directory-FD form | SOURCE LEAD | TLPI-v2:F22 | Candidate FD-kind compatibility gap; supported scope and runtime remain to check |
| AST-67 | Expired clock_nanosleep fast path bypasses clock validation | SOURCE LEAD | TLPI-v2:F23 | Raw syscall and libc error conventions must stay distinct |
| AST-68 | inotify accepts move subscriptions without matching rename notifications | SOURCE LEAD | TLPI-v2:F24 | Predicted missing events/cookie path; no measured target cookie value |
| AST-69 | TCP receive blocking decision ignores MSG_DONTWAIT | SOURCE LEAD | TLPI-v2:F25 | Reviewed TCP receive path only; no blanket claim for other socket families |
| AST-70 | TCP send propagates EPIPE without generating SIGPIPE | SOURCE LEAD | TLPI-v2:F26 | Observe signal and MSG_NOSIGNAL control, not only errno |
| AST-71 | personality ADDR_NO_RANDOMIZE setter may not change address layout | SOURCE LEAD | TLPI-v2:C01 | Open PR #3560 acknowledges ignored ADDR_NO_RANDOMIZE, but adds a sysctl instead of fixing the setter effect. |
| [AST-72](../ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md#ast-72-virtiofs-direct-empty-write-source-lead) | virtiofs direct empty write may publish a larger local size without a server write | SOURCE LEAD | 2026-09-16 backend source audit, bc12195 | Local metadata mutation found statically; attribute refresh may mask syscall observations. Runtime NOT_RUN. 2026-10-19 keyword pass: related items only (PR #3310, PR #3509, #3536). Candidate fix on fork branch `fix/virtiofs-empty-write` (`088088505`, 2026-09-18), no regression test, no PR. |
| [AST-73](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md#ast-73seal-后只读映射仍被当作可写资格计数) | Post-seal memfd read-only shared mappings retain writable tracking | REPRODUCED | Memfd source audit 2026-10-03, M01/M02; native run `asterinas-memfd-analysis-20261003T094028Z` TV-1/MC-1; 0c6053709 | [Confirmed](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md#entry-1-post-seal-read-only-mappings-retain-writable-accounting) on Asterinas with a Linux 7.2.8 control: a PROT_READ shared map through the O_RDWR fd fails with EPERM after F_SEAL_WRITE, and F_SEAL_WRITE fails with EBUSY while only a post-FUTURE_WRITE read-only mapping exists. Sequential, Level 0 public API. Compatibility/availability impact only; no write bypass or permanent leak was demonstrated. Specula severity High. 2026-10-19 keyword pass: related items only (PR #2408, PR #3481). |
| [AST-74](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md#ast-74map_shared_validate-没有经过相同的-fd-写权限检查) | MAP_SHARED_VALIDATE skips the ordinary shared-map FD write-access check | SOURCE LEAD | Memfd source audit 2026-10-03, M17/M18, 0c6053709 | [Four sequential admission cases are prepared](../memfd-sequential-cases-2026-10-03/README.md), including two ordinary Shared controls. Runtime, byte effects and security impact remain unverified. This is separate from AST-73. |
| [AST-75](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md#entry-2-seal-rejected-fixed-replacement-removes-the-existing-mapping) | Seal-rejected shared MAP_FIXED removes the old mapping before returning EPERM | REPRODUCED | Memfd native run `asterinas-memfd-analysis-20261003T094028Z`, TV-2/MC-2, 0c6053709 | Reproduced on Asterinas with a Linux 7.2.8 control, full and partial overlap: after the EPERM, mprotect returns ENOMEM, reads fault, a forked consumer dies by SIGSEGV, and F_SEAL_WRITE succeeds where Linux returns EBUSY. Sequential, Level 0 public API. Specula classified it Critical; the workspace assessment is compatibility/availability within the calling process, with no privilege boundary crossed and no security impact demonstrated. 2026-10-19 keyword pass: no upstream match. |
| AST-76 | Overlapping FUTURE_WRITE publication may misclassify mapping write eligibility | FALSE POSITIVE | Memfd native run `asterinas-memfd-analysis-20261003T094028Z`, CR-1, 0c6053709 | Seal check and publication run under the same seals mutex, so each admission lands wholly before or after publication. Mprotect gates only on the mapping's frozen MAY bits. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md). |
| AST-77 | Mapping ownership may not survive split, merge, protection and unmap transitions | FALSE POSITIVE | Memfd native run `asterinas-memfd-analysis-20261003T094028Z`, CR-2, 0c6053709 | Split, merge, protect and unmap conserve the counted owners, and removal drops the owner only after TLB synchronization. Bounded MC scenario 3 found no violation. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md). |
| AST-78 | Failed mprotect prefix and busy seal addition may leave inconsistent observable effects | FALSE POSITIVE | Memfd native run `asterinas-memfd-analysis-20261003T094028Z`, CR-3, 0c6053709 | Prefix effects match the Linux contract and a busy combined seal addition publishes no bits. The Asterinas guest run matched Linux on all 22 checks. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md). |
| [AST-79](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) | A cross-bucket requeued waiter's timeout cleanup misses its entry, and the stranded entry strands a live waiter | REPRODUCED | Futex native run `asterinas-private-futex-requeue-20261004T064345Z`, MC-1, 0c6053709 | Level 0 on an SMP=2 Asterinas guest: the moved waiter's timeout returns success instead of ETIMEDOUT, its dead entry stays in the destination bucket and consumes a later REQUEUE's migration quota, so a live waiter stays on the old futex. The same binary on Linux returns ETIMEDOUT and the live waiter is woken. The confirmation agent rated it NEW, but open upstream issue #3964 (bdm-k, 2026-10-06, no PR) reports this cleanup miss; the reporter added a musl reproducer on 2026-10-14. #3964 does not mention the stranded live waiter. The MC-1 worker searched only with generic web search; native reports stay unedited. Prior art: #1587 was closed by PR #1642, which only skipped closed wakers. Dequeue-on-timeout came from PR #2377 (`888eecb35`). Specula severity Critical; workspace assessment: compatibility and local liveness within the caller's threads, no security impact shown. Upstream: KNOWN-unfixed (#3964). |
| [AST-80](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) | FUTEX_REQUEUE converts a zero wake quota to one | REPRODUCED | Futex native run `asterinas-private-futex-requeue-20261004T064345Z`, MC-2 (validation TV-1), 0c6053709 | Level 0: REQUEUE(0,0) wakes one waiter and returns 1; the Linux 7.2.8 control returns 0 and wakes none. Reported in the second paragraph of open issue #3964, whose main body is AST-79. Linux compatibility only. |
| [AST-81](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) | Same-bucket FUTEX_REQUEUE moves a waiter when the migration quota is zero | REPRODUCED | Futex native run `asterinas-private-futex-requeue-20261004T064345Z`, MC-3 (validation TV-2), 0c6053709 | Level 0: with both futex words in one bucket, REQUEUE(1,0) still moves one entry, so later wakes on the source miss it; cross-bucket and Linux 7.2.8 controls move none. Confirmation rated it NEW. Specula severity Critical; workspace assessment: compatibility and local liveness, no security impact shown. 2026-10-19 keyword pass: no upstream match. |
| [AST-82](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md) | FUTEX_REQUEUE returns only the wake count, including on the same-address path | REPRODUCED | Futex native run `asterinas-private-futex-requeue-20261004T064345Z`, MC-4 (validation TV-3), 0c6053709 | Asterinas returns 1 where Linux 7.2.8 returns 2 for both the distinct-address and same-address cases. The man page documents only the wake count, but Linux source and runtime count requeued waiters too. Confirmation rated it NEW. Compatibility only. 2026-10-19 keyword pass: no upstream match. |
| AST-83 | A futex word update and WAKE can overlap WAIT registration, including the unlocked fault-retry window | FALSE POSITIVE | Futex native run `asterinas-private-futex-requeue-20261004T064345Z`, CR-1, 0c6053709 | No lost wake in 370,000 racing iterations at Level 0/1 on an SMP=2 guest, plus a 1,000-iteration sequential control (all EAGAIN); both outcomes and the fault-retry window were observed. Only a successful `sched_setaffinity` was checked, so distinct-CPU placement is not established. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md). |
| [AST-84](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md) | A conflicting flock SH→EX conversion keeps the caller's old SH lock | REPRODUCED | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, MC-1 (FL-SQ-1), 0c6053709 | Level 0, SMP 2: after A's EX\|NB conversion fails and B unlocks, C's EX\|NB gets EAGAIN where Linux 7.2.8 succeeds; two blocking SH→EX converters both stay parked, while on Linux one completes. `try_set_lock` checks conflicts before replacing the caller's own item. Specula severity Critical; workspace assessment: compatibility with local denial of progress, no security impact shown. 2026-10-19 keyword pass: no upstream match. |
| [AST-85](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md) | flock unlock drops a temporary owner reference under the list Mutex and self-deadlocks on re-entry | REPRODUCED | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, MC-2 (FL-SQ-2), 0c6053709 | `FlockList::unlock` upgrades a Weak owner under the non-recursive list Mutex; a concurrent `close()` can make that Arc the last reference, and its drop re-enters `unlock_flock`. A pure syscall race with trace observers deadlocked after 3 crossings on SMP 2, a gated run reproduces it deterministically, the alias control does not deadlock, and the uninstrumented run did not hit it in 128 crossings. Local denial of service on the inode's flock and close paths; cross-user impact not demonstrated. 2026-10-19 keyword pass: related items only (#3283, PR #1486, PR #1563). |
| AST-86 | flock ownership may diverge across independent opens and aliases | FALSE POSITIVE | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, CR-1, 0c6053709 | [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md). |
| AST-87 | flock waiter registration, notification and retry may miss a new blocker | FALSE POSITIVE | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, CR-2, 0c6053709 | Intermediate hangs came from the confirmation agent's own test-gate fixtures. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md). |
| AST-88 | Removing the last FD may not be the final OFD flock release | FALSE POSITIVE | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, CR-3, 0c6053709 | The behavior matches Linux OFD lifetime. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md). |
| AST-89 | flock may wake and retry waiters more than necessary | FALSE POSITIVE | Flock native run `asterinas-local-flock-ownership-20261004T160159Z`, CR-4 / analysis FL-CR-1, 0c6053709 | Intended behavior with negligible cost. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md). |
| AST-90 | SCM_RIGHTS FD ownership may diverge across descriptor reuse and release | FALSE POSITIVE | SCM_RIGHTS native run `asterinas-unix-dgram-scm-rights-20261004T064345Z`, CR-1, 0c6053709 | [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md). |
| AST-91 | Unix datagram PEEK and ordinary receive may select records against publication order | FALSE POSITIVE | SCM_RIGHTS native run `asterinas-unix-dgram-scm-rights-20261004T064345Z`, CR-2, 0c6053709 | 2-CPU guest, 173 overlapping PEEK/ordinary deliveries across three runs, 0 failures; Linux gives identical outcomes. [Disposition](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md). |
| [AST-92](../flock-wait-handoff-2026-10-05/wait-reap/result.md) | waitid without WEXITED consumes an exited child | REPRODUCED | Wait/reap native run `asterinas-child-wait-reap-20261004T160159Z`, WR-LX, 0c6053709 | Outcome-only runtime record: in the Asterinas guest `waitid(P_PID, zombie, WSTOPPED\|WNOHANG)` returns 0 with CLD_EXITED and reaps the child, so the next WEXITED wait gets ECHILD; Linux returns ECHILD and keeps the child waitable, and the Linux control matched. `process/wait.rs:310-319` never tests WEXITED. Native confirmation did not run, and the harness receipt carries a user-accepted residual (D9R5-S1). No security impact shown. 2026-10-19 keyword pass: related items only (PR #2253, PR #2511). |
| [AST-93](../flock-wait-handoff-2026-10-05/wait-reap/result.md) | waitid WNOHANG with no event leaves siginfo unwritten | REPRODUCED | Wait/reap native run `asterinas-child-wait-reap-20261004T160159Z`, WR-SQ, 0c6053709 | Outcome-only runtime record: a no-event `waitid(WEXITED\|WNOHANG)` returns 0 and leaves a poisoned siginfo unchanged; Linux zeroes the selected fields, and the Linux control matched (`syscall/waitid.rs:49-51`). Same evidence limits as AST-92. Compatibility only. 2026-10-19 keyword pass: related item only (PR #2253). |

## Current repair entry points

- **AST-15 with AST-11:** resolve cold-tail backend lock re-entry while
  preserving preparation/copy/publication serialization.
- **AST-13:** repair stale hole contents; the reproduced disclosure is the
  same file's old data, not demonstrated cross-file exposure.
- **AST-05/10:** current local read limiting and ramfs serialization exist;
  run the original 01b schedules on the selected fixed revision.
- **AST-02:** the empty-write subcase landed upstream as PR #3875
  (merged 2026-09-29) from the [local batch](../empty-write-batch-2026-09-16/README.md);
  the batch worktree no longer exists. Nonempty zero-progress fault paths
  remain separate pending repairs.
- **AST-14:** fixed upstream by the same PR #3875, with no local retest.
- **AST-08:** the local fix branch is unpushed. Upstream #3920 item 11 already
  reports the mechanism, so a PR should cite it.
- **AST-12:** fix and test ftruncate size publication across cluster boundaries.
- **AST-25 and AST-30..40:** pending source/contract questions; assign their
  own supported contract and runtime evidence before promotion. AST-32 and
  AST-36 are now reproduced by the SCM_RIGHTS native run.
- **AST-79..82, AST-84/85, AST-92/93:** reproduced by the 2026-10-04..10
  runs. AST-79..82 and AST-84/85 have native confirmation records that name
  fix sites. AST-92/93 are outcome-only observations with no native
  confirmation record. None has a local
  fix. AST-79 and AST-80 are reported by upstream #3964. The others had no
  upstream match in the 2026-10-19 keyword pass.

The [01b handoff][01b-handoff] owns exact local commits, saved A/B logs,
reproduction levels, and acceptance cases. [01a patch validation](../patch-validation-report.md)
owns v5 evidence. [Later AST validation](../ast-validation-2026-09-02/README.md)
records AST-07's wrong-answer versus hard-fault distinction and AST-08/09
local repair evidence. [FD evidence](../../references/asterinas-syscall-security-audit.md#historical-fdepoll-full-run)
retains runtime and independent-review qualifications for AST-16..23/28/29/41.

TLPI-v2 preparation is [tracked separately](../tlpi-audit-2026-09-14/test-plan.md):
AST-42..71 remain source/capability records. User requested organization only;
no imported test or new baseline ran.

## Campaign register

The aliases below are local shorthand for the exact run IDs in this table.
Counts are archived dispositions, not counts of distinct or new vulnerabilities.

| Alias / run ID | Asterinas pin | Recorded result | Detailed record |
| --- | --- | --- | --- |
| FD: `asterinas-fd-epoll-pipeline-20260811T164254Z` | `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` | Final Stage 3: 8 REPRODUCED, 1 FALSE POSITIVE, 1 DROPPED | [Final findings and evidence](../../references/asterinas-syscall-security-audit.md#historical-fdepoll-full-run), [native report][fd-report] |
| Recon: `asterinas-syscall-user-memory-baseline-20260822T172958Z` | `604948581512d83734377974d4c34adb4530f2d7` | Analysis/review only; source leads and historical issue archaeology | [Analysis scope and leads](../../references/asterinas-syscall-security-audit.md#historical-user-memory-source-analysis) |
| 01a: `asterinas-syscall-regular-file-partial-progress-20260823T030315Z` | `604948581512d83734377974d4c34adb4530f2d7` | 6 REPRODUCED, 1 MASKED, 1 FALSE POSITIVE | [Completion record](../../references/active-specula-run-handoff.md#historical-01a-regular-file-partial-progress-completed-2026-08-24), [native report][01a-report], [patch validation](../patch-validation-report.md) |
| GLM: `asterinas-glm53-eval-20260826T035049Z` | `604948581512d83734377974d4c34adb4530f2d7` | 4 REPRODUCED, 1 FALSE POSITIVE, 1 tooling-INCOMPLETE | [Final report](../glm53-eval-final-report.md), [native report][glm-report] |
| External packages (AST-07/08); original run ID not recorded in imported descriptions | `4c1fdd1e4` | Origin kernel/device reproductions; later evidence is revision-specific | [AST-07](AST-07-segment-empty-slice/description.md), [AST-08](AST-08-iommu-stale-iotlb/description.md), [later validation](../ast-validation-2026-09-02/README.md) |
| 01b: `20260908-150910-0a8c` | `604948581512d83734377974d4c34adb4530f2d7` | 10 REPRODUCED entries; classification ran; debate off | [Current handoff and repair worklist][01b-handoff], [MC-6/7 repair batch at bc12195](../empty-write-batch-2026-09-16/README.md), [native report][01b-report] |
| TLPI-v2 attachment, archive SHA-256 `0c70d01cb9b8120e...` (no native run ID) | `a5449e62b0a5a0affccb6087ea3543a2fdf66052` | 26 interface groups plus C01; saved Linux evidence only, Asterinas NOT_RUN | [Intake and mapping](../tlpi-audit-2026-09-14/README.md), [planned cases](../tlpi-audit-2026-09-14/case-plan.json) |
| Backend source audit, 2026-09-16 (no native run ID) | `bc12195df4acfb1fc4ae968cf7acf9333ed83435` with prepared ramfs guard | Static backend comparison; AST-72 SOURCE LEAD, runtime NOT_RUN | [Scope and evidence](../ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md) |
| Memfd source audit, 2026-10-03 (no native run ID) | `0c60537098f4c2949ad2d382aaf499de72263d76` | Manual bounded analysis and 18 contract cases. AST-73/74 are SOURCE LEAD. No Specula phase or runtime ran. | [Source, controls, allowed outcomes, and execution gaps](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md) |
| Memfd test preparation, 2026-10-03 (no native run ID) | `0c60537098f4c2949ad2d382aaf499de72263d76` | After ultraplan plan review, two test programs and 13 sequential cases were prepared. Host compile-only checks passed. Target userland build and all runtime cells remain unverified. | [Package and handoff](../memfd-sequential-cases-2026-10-03/README.md) |
| Memfd: `asterinas-memfd-analysis-20261003T094028Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Complete pipeline with reviews, after a user-directed brief revision and a reviewed spec fix: 90 traces matched, bounded MC found only the two known defects, and confirmation (GLM-5.3) gave 2 REPRODUCED (AST-73, AST-75; 0 new) and 3 FALSE POSITIVE (AST-76..78). Repair loop no-op. Not a blind baseline. | [Gate records](../memfd-readiness-review-2026-10-03/README.md), [native report](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md), [severity](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/bug-severity.md) |
| Private futex: `asterinas-private-futex-requeue-20261004T064345Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Final pipeline stages completed with reviews and accepted limitations. Spec PASS 38/40 after two reviewed revisions; 18 SMP=2 traces replayed. Validation was rerun on claude-code Opus 5.5 after a Codex policy block (user-authorized); its review NEEDS_IMPROVEMENT items (overlap 0.38%, clock, uncovered probes) were accepted as limitations, so no concurrency claim is made. Confirmation (GLM-5.3) gave 4 REPRODUCED (AST-79..82; the agents rated three new and matched AST-80 to upstream #3964, which the 2026-10-19 refresh shows also reports AST-79) and 1 FALSE POSITIVE (AST-83). Core MC.cfg time-limited. Not a blind baseline. | [Lane result](../parallel-scopes-2026-10-04/futex/result.md) |
| Unix DGRAM SCM_RIGHTS: `asterinas-unix-dgram-scm-rights-20261004T064345Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Final pipeline stages completed with reviews and two accepted limitations (the user accepted PEEK outside the default ordinary-receive MC.cfg; the lane controller accepted the whole-trace overlap bounds 3.2%/3.6% below 20% at gate 6, without a separate user ruling). Spec 38/40 after four revisions; 46/46 traces validated; 20 hunts (12 complete, 5 time-limited, 3 expected violations). AST-32 and AST-36 REPRODUCED (known, 0 new); CR-1/CR-2 FALSE POSITIVE (AST-90/91). Not a blind baseline. | [Lane result](../parallel-scopes-2026-10-04/scm-rights/result.md) |
| Local flock: `asterinas-local-flock-ownership-20261004T160159Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Final pipeline stages completed with reviews. Spec PASS 40/40 after one reviewed revision; 18 traces accepted under the user-ratified existential adapter; validation PASS. Only four-event C00 meets the overlap criterion; MC.cfg is time-limited. AST-85 has separate observer-assisted, ungated race evidence; campaign-wide critical-interleaving coverage remains incomplete. MC-1 and MC-2 REPRODUCED (AST-84/85); CR-1..4 FALSE POSITIVE (AST-86..89). Not a blind baseline. | [Lane result](../flock-wait-handoff-2026-10-05/flock/result.md) |
| Child wait/reap: `asterinas-child-wait-reap-20261004T160159Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Analysis PASS; spec PASS 40/40 with bounded TLC (publication and restricted wakeup liveness complete, others time-limited). Implementation-trace validation BLOCKED_ENVIRONMENT (AMD KVM, no invariant TSC). User-chosen outcome-only runtime under a user-overridden harness receipt: Linux 21/21 match, Asterinas per-call 94/97. WR-LX and WR-SQ mismatches recorded as AST-92/93. Zero implementation traces. Validation exited 1 at Phase 0; findings exited 1 before any agent started (no bug report). Native confirmation is absent. No concurrency claim. Not a blind baseline. | [Lane result](../flock-wait-handoff-2026-10-05/wait-reap/result.md) |

- FD/epoll's earlier six-item Stage-2 table is superseded by its ten-entry
  Stage-3 disposition table. The independent review's earlier uncertainty
  about the timerfd timeout race remains part of its evidence history.
- GLM's final report supersedes the intermediate dedup report: CR-2 was
  reproduced on pipes; CR-1 was FALSE POSITIVE; MC-4 remained INCOMPLETE.
- The broader user-memory run's 19 historical issue confirmations are
  archaeology, not 19 new findings from that run. Its vector/partial-count
  leads have later 01a evidence; socket/ownership leads retain their own gaps.
- Reviewed `01a-regular-file-partial-progress-v2.md` is a guidance artifact;
  01b used its separately hashed guidance. Do not attribute 01b to a v2 run.
- Dry runs and failed starts add no confirmed finding rows. Preserve
  `asterinas-fd-epoll-full-20260811T163837Z` (snapshot rejection), 01b
  `20260908-002550-834e` (wedge), and `20260908-144234-85a1` (routing-change
  interruption), with their recorded logs and inputs.

## Historical promotion audit (2026-08)

| Criterion | AST-01 | AST-02 | AST-03 | AST-04 | AST-05 | AST-06 | AST-07 | AST-08 | AST-09 |
|---|---|---|---|---|---|---|---|---|---|
| Contract | ✅ write(2) partial | ✅ tmpfs atomicity | ✅ readv(2) atomicity | ✅ read(2) partial | ✅ read(2) bound | ✅ append offset | ✅ round-trip identity | ✅ DMA revocation | ✅ signal(7) SA_RESTART |
| Source sequence | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (origin pin) | ✅ (origin pin) | ✅ |
| Userspace repro | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ kernel-internal | ❌ device-attacker | ✅ |
| Asterinas observation | ✅ SMP=2 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ `4c1fdd1e4` | ✅ `4c1fdd1e4` | ✅ SMP=2 |
| Oracle control | ✅ Linux* | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ none | ⚠️ vIOMMU trace | ✅ Linux 5/5 |
| Impact | Critical | Critical | Critical | High | High | High | kernel death | High | High |
| Known-issue status | ✅ none | ✅ | ✅ | ✅ **#711** | ✅ | ✅ (+≠PR #3481) | ✅ #3165≠ | ✅ FIXME only | ✅ none (#1578 origin) |
| SMP evidence | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | n/a | ✅ (fork+signal) |

\* Linux control ran re-compiled source (guest cc vs host gcc), not one
pinned binary — aster-syssec differential discipline is stricter.

The AST-07/08 packages use kernel/device test lanes; an unprivileged
syscall path was not demonstrated. Consult later validation records before
carrying these historical cells forward.

## Evidence and maintenance

- Current tracked items use this register's AST IDs. Historical descriptions,
  tests, logs, and patches retain their original aliases, resolved in
  [id-map.md](id-map.md). Raw verdicts were not rewritten.
- After a run, update the register, every final-disposition mapping, and the
  linked repair record. Preserve source-only and negative outcomes as well.
- AST-01..06's promotion-complete label belongs to the historical 01a/v5
  snapshot. This numbering pass neither repeats that review nor extends it
  to source-only or masked entries.
- The [current state](../../references/current-state.md) and linked handoffs
  own current checkout/repair snapshots; old PR drafts retain dated upstream
  observations. AST numbering does not mean a fix is merged or deployed.
- [Known-findings integration](../known-findings/README.md) remains separate
  Specula branch work. Specula main (`39b4a015` on 2026-10-19) lacks the dataset and
  matcher. Its old AST-01..09 dataset was not extended by this doc change.
- Authoritative checkouts, native run artifacts, prepared guidance/config,
  repro programs, patches, and generated memory were not changed.
- Unlabeled source line numbers in the futex, memfd, flock and SCM_RIGHTS
  native `confirmed-bugs.md` files refer to each run's instrumented source
  copy, not to pin `0c6053709`, and some are off by a few lines even there.
  Resolve sites by function name at the pin before citing them.

[fd-report]: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md
[01a-report]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md
[glm-report]: /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md
[01b-report]: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md
[01b-handoff]: ../runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md
[recon-report]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md
[recon-brief]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md
