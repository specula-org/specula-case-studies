# Reproduced findings and local deduplication

Use this index to find the saved runtime evidence for an AST entry. The local
audit on 2026-10-12 checked all 93 catalog entries, their old-ID mappings and
eight distinct native final reports. It ran no phase, TLC, build, guest or
reproducer, and made no upstream query. Source revisions and upstream statuses
retain their original evidence dates. No current-HEAD validation is claimed.

The catalog has 35 REPRODUCED tracking entries: 31 with native confirmation
reports, two with kernel/device runtime evidence and two outcome-only wait/reap
observations. The eight native reports contain 54 final records. Their 38
REPRODUCED records map to 31 AST entries after repeated observations are
deduplicated. `runs/latest` is an alias and is counted once. These counts are
not a count of independent vulnerabilities or completed protocol proofs.

The [machine-readable audit](local-dedup-2026-10-12.json) records every AST
status, all 54 native record mappings, dedup decisions and source hashes.
The [catalog](README.md) remains authoritative for stable tracking IDs and
repair qualifications. The [ID map](id-map.md) preserves original run verdicts.

## Native confirmation records (31)

Each row has at least one final REPRODUCED record in the linked native report.
Read its exact source/build identity, reproduction method and controls before
reusing it. A report entry is evidence for its described behavior and does not
establish current applicability, exploitability or campaign-wide concurrency
coverage. Historical repair validation is a separate record.

| AST | Reproduced behavior | Positive native records | Qualification |
| --- | --- | --- | --- |
| AST-01 | ext2 durable write prefix returned as EFAULT | [01a:MC-2][01a] | The ext2 write witness is 01a MC-2. GLM MC-1 is a related read witness. |
| AST-02 | ramfs size publication before an empty or zero-progress write | [01a:MC-4][01a], [GLM:MC-3][glm], [01b:MC-6][01b], [01b:MC-8][01b] | Empty writes and zero-progress faults share this publication mechanism. |
| AST-03 | Vectored I/O releases the offset lock between iovecs | [01a:MC-5][01a] | GLM MC-4 stayed INCOMPLETE; it adds no positive confirmation. |
| AST-04 | A copied read prefix is erased by EFAULT reporting | [01a:MC-1][01a], [GLM:MC-1][glm] | The copied prefix is externally visible despite EFAULT and unchanged offset. |
| AST-05 | ramfs/exFAT reads copy beyond the reported EOF prefix | [01a:MC-3][01a], [GLM:MC-2][glm], [01b:MC-2][01b], [01b:CR-1][01b] | ramfs/exFAT manifestations share the missing copy bound. AST-10 is separate. |
| AST-06 | Failed append advances the shared file offset | [01a:MC-7][01a] | The observed effect is the shared offset after a failed append. |
| AST-09 | Pipe readv/writev return EINTR despite SA_RESTART | [GLM:CR-2][glm] | The recorded restart failure is on pipe readv/writev. |
| AST-10 | ramfs snapshots read length before serializing with resize | [01b:MC-1][01b] | Stale size sampling across resize is distinct from AST-05. |
| AST-11 | exFAT write preparation becomes stale before copy/publication | [01b:MC-3][01b] | The counterexample schedule used timing assistance; retain the later A/B record separately. |
| AST-12 | Successful exFAT ftruncate retains the old logical size | [01b:MC-4][01b] | Sequential ftruncate/metadata mismatch; no concurrency claim is needed. |
| AST-13 | exFAT regrown holes expose the file's old backing bytes | [01b:MC-5][01b] | Only this file's stale backing bytes were demonstrated. |
| AST-14 | Empty exFAT writes enlarge EOF and may allocate clusters | [01b:MC-7][01b] | Historical reproduction covers buffered exFAT; direct-I/O follow-up is source-only. |
| AST-15 | exFAT cold-tail extension re-enters an inode write guard | [01b:CR-2][01b] | Cold-tail clearing re-enters an inode guard. Preserve AST-11 serialization when assessing a fix. |
| AST-16 | epoll copy-out EFAULT loses edge-triggered readiness | [FD:MC-1][fd] | Archived edge-triggered delivery evidence at the FD run pin. |
| AST-17 | epoll disables one-shot interest before successful delivery | [FD:MC-2][fd] | Archived one-shot disable-before-delivery evidence at the FD run pin. |
| AST-18 | Final close retains dead epoll interest metadata | [FD:MC-3][fd] | Stale epoll interest after final close, with the original OFD assumptions. |
| AST-19 | Consumed timerfd remains ready through the poll cache | [FD:MC-4][fd] | TLPI F17 remains NOT_RUN; it is not a second runtime witness. |
| AST-20 | signalfd mask change omits newly eligible readiness | [FD:MC-5][fd] | Mask-update notification is distinct from the registration-thread binding defect. |
| AST-21 | poll times out after timerfd becomes readable | [FD:MC-6][fd] | Preserve the original timer/readiness/timeout schedule and review history. |
| AST-22 | signalfd epoll readiness binds to the registering thread | [FD:CR-4][fd] | Keep the historical model-oracle error AST-41 separate. |
| AST-23 | epoll_pwait/pselect6 timeout skips deferred pipe readiness | [FD:CR-5][fd] | The recorded terminal-arbitration effect concerns deferred pipe readiness. |
| AST-32 | SCM_RIGHTS installs an FD before publishing its number | [SCM:MC-1][scm] | Known Recon lead. A stray receiver FD is shown; no privilege escalation is established. |
| AST-36 | Unix datagram receive may retain a record after copy fault | [SCM:MC-2][scm] | Known Recon lead. Ordinary payload fault retains a message that Linux consumes. |
| AST-73 | Post-seal memfd read-only shared mappings retain writable tracking | [Memfd:MC-1][memfd] | WRITE/EPERM and FUTURE_WRITE/false-EBUSY manifestations count once. |
| AST-75 | Seal-rejected shared MAP_FIXED removes the old mapping before returning EPERM | [Memfd:MC-2][memfd] | Full and partial MAP_FIXED replacement observations share one rollback mechanism. |
| AST-79 | A cross-bucket requeued waiter's timeout cleanup misses its entry, and the stranded entry strands a live waiter | [Futex:MC-1][futex] | Timeout and later quota stranding share the missed destination-bucket cleanup. The 2026-10-19 refresh found this reported as the main body of open upstream #3964; the native NEW rating is wrong. |
| AST-80 | FUTEX_REQUEUE converts a zero wake quota to one | [Futex:MC-2][futex] | The run records a dated match to #3964, where this is the second paragraph. |
| AST-81 | Same-bucket FUTEX_REQUEUE moves a waiter when the migration quota is zero | [Futex:MC-3][futex] | Same-bucket zero-move behavior is separate from AST-80 wake normalization. |
| AST-82 | FUTEX_REQUEUE returns only the wake count, including on the same-address path | [Futex:MC-4][futex] | The runtime Linux comparison counts moved waiters as well as wakes. |
| AST-84 | A conflicting flock SH→EX conversion keeps the caller's old SH lock | [Flock:MC-1][flock] | Failed NB conversion and two blocking converters share retained old SH ownership. |
| AST-85 | flock unlock drops a temporary owner reference under the list Mutex and self-deadlocks on re-entry | [Flock:MC-2][flock] | Ungated race reproduced with observers; reviewed timing gate also reproduced it. Plain run missed it in 128 crossings. |

## Kernel and device runtime records (2)

| AST | Reproduced behavior | Evidence and limits |
| --- | --- | --- |
| AST-07 | Empty Segment conversion accesses metadata outside its owned frames. | [Original package](AST-07-segment-empty-slice/description.md) at 4c1fdd1e4 and [later ktests](../ast-validation-2026-09-02/README.md#ast-07-detail-answers-is-it-a-real-panic) at 604948581. The later run reproduced wrong answers, not kernel death. No unprivileged syscall trigger is established. |
| AST-08 | DMA teardown leaves a usable stale IOTLB translation after frame release. | [Original package](AST-08-iommu-stale-iotlb/description.md) and [later device test](../ast-validation-2026-09-02/README.md#ast-08-detail). The control preserves the witness and stale DMA overwrites it. This requires the recorded DMA-device/vIOMMU setup, not an ordinary process. |

## Outcome-only runtime observations (2)

These retain catalog status REPRODUCED because real Asterinas behavior was
recorded. Neither has a native confirmation verdict. They must not be counted
as two additional native confirmations or as concurrent protocol validation.

| AST | Observed behavior | Evidence and limits |
| --- | --- | --- |
| AST-92 | waitid without WEXITED consumes a zombie and returns its exit status. | [Wait/reap result](../flock-wait-handoff-2026-10-05/wait-reap/result.md#candidates-details-in-candidate-ledgermd): two per-call mismatches in the zombie-without-wexited case, with Linux controls. Sequential evidence. |
| AST-93 | waitid WNOHANG with no event leaves poisoned siginfo fields unchanged. | [Wait/reap result](../flock-wait-handoff-2026-10-05/wait-reap/result.md#candidates-details-in-candidate-ledgermd): one per-call mismatch, with a Linux control. Sequential evidence. |

The wait/reap collector recorded 97 calls, 94 matches and three mismatches.
All 21 Asterinas run-level verdicts remain inconclusive because the completion
marker was dropped by the collector. The user accepted the separate D9R5-S1
residual under a NOT_APPROVED harness review. There are zero implementation
traces and no credible distinct-CPU placement. Validation exited 1 at Phase 0;
findings exited 1 before an agent started. This audit neither repairs the
collector nor upgrades those observations.

## Local dedup decisions

The scan matches the contract, source mechanism and artifact identity. Similar
symptoms alone do not justify merging AST entries. No stable ID or original
native verdict was deleted, renumbered or promoted.

| Records | Treatment |
| --- | --- |
| 01a MC-4, GLM MC-3, 01b MC-6/MC-8 | Count once as AST-02. Empty and failed zero-progress writes share the same ramfs publication mechanism. |
| 01a MC-3, GLM MC-2, 01b MC-2 and CR-1's syscall effect | Count once as AST-05. Keep AST-10's stale size snapshot and AST-25's latent contract question separate. |
| GLM MC-1 and AST-01/04 | Count the actual readv witness once, under AST-04. AST-01 is the related write-side count-erasure family and has its own 01a evidence. Preserve the two contract entries without presenting this GLM record as a write reproduction. |
| GLM MC-4 and AST-03 | Preserve INCOMPLETE for that run; 01a MC-5 supplies AST-03's positive native record. |
| TLPI F17 and FD MC-4 | Both map to AST-19, but the attachment remains NOT_RUN. |
| SCM MC-1/MC-2 and Recon leads | Reproductions of AST-32/36, not new IDs. FD publication and message-consumption faults remain separate. |
| Memfd M01/M02 and TV-1/MC-1 | One AST-73 mechanism with two manifestations. AST-74's FD-access branch and AST-75's replacement rollback remain separate. |
| Futex timeout cleanup and later dead-entry quota consumption | One AST-79 mechanism. AST-80/81/82 have different quota/accounting sites and remain separate. |
| Flock FL-SQ/FL-TV/FL-MC aliases, provisional AST-NEW-FL1/2 | Resolve to AST-84/85. NB and blocking conversion manifestations count once as AST-84. |
| Flock FL-CR-1 and native CR-4 | Same request-clone Drop, re-enqueue window and scheduling-impact hypothesis. Resolve to existing AST-89 FALSE POSITIVE. The former open-question row was stale; no additional finding is counted. |
| AST-02/14/72, AST-11/15, AST-16/17, AST-22/41, AST-43/44, AST-92/93 | Preserve distinct implementation paths, contracts or evidence classes. The JSON audit records each decision. AST-72/43/44 stay source-only and AST-41 stays MODEL ERROR. |

The remaining 58 entries are outside the reproduction list: 40 SOURCE LEAD,
13 FALSE POSITIVE, two UNSUPPORTED, one MASKED, one DROPPED and one MODEL ERROR.
GLM MC-4's INCOMPLETE is an original-run status within an existing AST entry,
not a new catalog entry. Negative runtime checks and successful controls are
not reproduced bugs.

## Campaign interpretation

Futex, SCM_RIGHTS and flock reached final pipeline stages with the recorded
exceptions. Wait/reap did not complete native validation or findings. Their
critical-interleaving coverage remains incomplete. SCM_RIGHTS has actual
overlapping events, and flock AST-85 has specific observer-assisted race
evidence; neither fact establishes full protocol coverage. Keep the
[catalog's concurrency limits](README.md#concurrency-evidence-limits) attached
to any combined result or external description.

New concurrency scopes remain candidates until an authorized pilot captures
the named critical histories and validates a reviewed minimal model under
declared bounds, as required by [AGENTS.md](../../AGENTS.md#new-concurrency-scope-admission).
No new run is authorized by this documentation closeout.

## Audit boundary

Local records and mappings were checked, and document/rule corrections were
verified. Kernel and Specula code, current-HEAD behavior, upstream refresh and
publication are out of scope. Generated memory remains read-only. Existing
untracked evidence archives were preserved. Native source reports are hashed
in the JSON audit and were not edited or executed.

[fd]: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md
[01a]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md
[glm]: /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md
[01b]: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md
[memfd]: /home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md
[futex]: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md
[scm]: /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md
[flock]: /home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md
