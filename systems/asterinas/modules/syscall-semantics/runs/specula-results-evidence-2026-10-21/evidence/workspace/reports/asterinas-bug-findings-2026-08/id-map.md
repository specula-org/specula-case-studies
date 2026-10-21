# Original IDs to AST IDs

This is the alias map for the [unified register](README.md#unified-register).
Run aliases resolve to exact run IDs and pins in the
[campaign register](README.md#campaign-register). AST IDs name tracking items;
raw statuses below belong to the original run, not to another run's evidence.
Original native artifacts, test names and run verdicts remain unchanged.
[Dated upstream matches](../upstream-dedup-2026-09-14/matches.json) form a
separate dimension; an upstream closed/merged state does not alter these
historical run dispositions or attachment NOT_RUN records.

The [2026-10-12 local audit and reproduction index](reproduced.md) counts
repeated run findings once per AST entry and distinguishes primary runtime
witnesses from related mechanisms. A finding key includes its run and artifact
or phase: a reused `MC-1` or `CR-1` label alone is not a duplicate key.

## Source-question aliases from preparation (2026-10-05)

These names preserve source-question provenance for the handoffs. The lane
records were closed out later, and the mappings below were assigned when the
coordinator merged their results on 2026-10-11. See the run sections further
down for the evidence behind each mapping.

| Prepared run | Local question | AST mapping | Source context |
| --- | --- | --- | --- |
| `asterinas-local-flock-ownership-20261004T160159Z` | FL-SQ-1 | AST-84 (native MC-1) | Failed or blocked mode conversion and the previous SH ownership. |
| `asterinas-local-flock-ownership-20261004T160159Z` | FL-SQ-2 | AST-85 (native MC-2) | Last temporary owner reference and destructor reentry during release. |
| `asterinas-child-wait-reap-20261004T160159Z` | WR-SQ | AST-93 | waitid WNOHANG no-event output clearing. |

See the [flock contracts](../flock-wait-handoff-2026-10-05/flock/contracts.md)
and [wait/reap contracts](../flock-wait-handoff-2026-10-05/wait-reap/contracts.md)
for fixed-source evidence, compensation and outstanding checks.

## Final run dispositions

| Run | Original finding | AST ID | Original final disposition | Mapping scope |
| --- | --- | --- | --- | --- |
| 01a | MC-1 | AST-04 | REPRODUCED | Same tracked mechanism |
| 01a | MC-2 | AST-01 | REPRODUCED | Same tracked mechanism |
| 01a | MC-3 | AST-05 | REPRODUCED | Same tracked mechanism |
| 01a | MC-4 | AST-02 | REPRODUCED | Same tracked mechanism |
| 01a | MC-5 | AST-03 | REPRODUCED | Same tracked mechanism |
| 01a | MC-6 | AST-24 | MASKED | Same tracked mechanism |
| 01a | MC-7 | AST-06 | REPRODUCED | Same tracked mechanism |
| 01a | CR-1 | AST-26 | FALSE POSITIVE | Same tracked mechanism |
| GLM | MC-1 | AST-04; related AST-01 | REPRODUCED | The runtime witness is readv prefix loss (AST-04). AST-01 is the related ext2-write count-erasure mechanism, not a second write reproduction from this record. |
| GLM | MC-2 | AST-05 | REPRODUCED | Same tracked mechanism |
| GLM | MC-3 | AST-02 | REPRODUCED | Same tracked mechanism |
| GLM | MC-4 | AST-03 | INCOMPLETE | AST-03 has 01a evidence; this run remains INCOMPLETE |
| GLM | CR-1 | AST-27 | FALSE POSITIVE | Same tracked mechanism |
| GLM | CR-2 | AST-09 | REPRODUCED | Same tracked mechanism |
| 01b | MC-1 | AST-10 | REPRODUCED | Separate stale-length lock window from AST-05 unlimited-writer defect |
| 01b | MC-2 | AST-05 | REPRODUCED | Same tracked mechanism |
| 01b | MC-3 | AST-11 | REPRODUCED | Same mechanism as earlier local exFAT write-race work; exact schedules still need fix validation |
| 01b | MC-4 | AST-12 | REPRODUCED | Same tracked mechanism |
| 01b | MC-5 | AST-13 | REPRODUCED | Same tracked mechanism |
| 01b | MC-6 | AST-02 | REPRODUCED | [Local ramfs/exFAT batch](../empty-write-batch-2026-09-16/README.md) landed upstream as PR #3875 (merged 2026-09-29); static check only; original status retained |
| 01b | MC-7 | AST-14 | REPRODUCED | Buffered/direct guards fixed upstream by PR #3875 (merged 2026-09-29), from the [local batch](../empty-write-batch-2026-09-16/README.md); no local retest; historical confirmation covers buffered I/O |
| 01b | MC-8 | AST-02 | REPRODUCED | Same tracked mechanism |
| 01b | CR-1 | AST-05, AST-25 | REPRODUCED | AST-05 reproduced syscall effect; AST-25 latent contract follow-up is SOURCE LEAD |
| 01b | CR-2 | AST-15 | REPRODUCED | Same tracked mechanism |
| FD | MC-1 | AST-16 | REPRODUCED | Same tracked mechanism |
| FD | MC-2 | AST-17 | REPRODUCED | Same tracked mechanism |
| FD | MC-3 | AST-18 | REPRODUCED | Same tracked mechanism |
| FD | MC-4 | AST-19 | REPRODUCED | Same tracked mechanism |
| FD | MC-5 | AST-20 | REPRODUCED | Same tracked mechanism |
| FD | MC-6 | AST-21 | REPRODUCED | Same tracked mechanism |
| FD | CR-1 | AST-28 | FALSE POSITIVE | Same tracked mechanism |
| FD | CR-4 | AST-22 | REPRODUCED | Same tracked mechanism |
| FD | CR-5 | AST-23 | REPRODUCED | Same tracked mechanism |
| FD | CR-6 | AST-29 | DROPPED | Same tracked mechanism |

## External and former catalog aliases

| Original reference | AST ID | Qualification |
| --- | --- | --- |
| RF-01 | AST-01 | Former catalog name; original test markers preserved |
| RF-02 | AST-02 | Former catalog name; original test markers preserved |
| RF-03 | AST-03 | Former catalog name; original test markers preserved |
| RF-04 | AST-04 | Former catalog name; original test markers preserved |
| RF-05 | AST-05 | Former catalog name; original test markers preserved |
| RF-06 | AST-06 | Former catalog name; original test markers preserved |
| OS-01; external CR-11 at 4c1fdd1e4 | AST-07 | Kernel-internal evidence; later hard-fault non-reproduction retained |
| OS-02; external CR-20 at 4c1fdd1e4 | AST-08 | Device/vIOMMU reproduction assumptions retained |
| Earlier unnumbered exFAT write-race work, d5b645d84 / 97199dd30 | AST-11 | Existing local repair evidence, also observed as 01b:MC-3 |
| FD historical s4_binding model counterexample | AST-41 | MODEL ERROR, not the separately reproduced AST-22 |

## Reconnaissance analysis-report candidates

The following IDs belong to `analysis-report.md` section 9 of Recon
(`asterinas-syscall-user-memory-baseline-20260822T172958Z`). All were pending
analysis questions in that run. A mapping to an AST entry with later runtime
evidence does not make the reconnaissance itself a runtime confirmation.
T-1/CR-1 cover additional adapters beyond the later regular-file witnesses;
T-6 also includes null/alias/overlap tests, not just the two named bound checks.

| Analysis-report ID | AST ID | Original evidence level |
| --- | --- | --- |
| MC-1 | AST-03 | Analysis-only candidate |
| MC-2 | AST-36 | Analysis-only candidate |
| MC-3 | AST-31 | Analysis-only candidate |
| MC-4 | AST-32 | Analysis-only candidate |
| MC-5 | AST-39 | Analysis-only candidate |
| T-1 | AST-01, AST-04 | Analysis-only candidate |
| T-2 | AST-30 | Analysis-only candidate |
| T-3 | AST-36 | Analysis-only candidate |
| T-4 | AST-32 | Analysis-only candidate |
| T-5 | AST-31 | Analysis-only candidate |
| T-6 | AST-37, AST-38 | Analysis-only candidate |
| T-7 | AST-39 | Analysis-only candidate |
| T-8 | AST-33 | Analysis-only candidate |
| T-9 | AST-34 | Analysis-only candidate |
| T-10 | AST-35 | Analysis-only candidate |
| CR-1 | AST-01, AST-04 | Analysis-only candidate |
| CR-2 | AST-40 | Analysis-only candidate |
| CR-3 | AST-31, AST-38 | Analysis-only candidate |
| CR-4 | AST-37 | Analysis-only candidate |
| CR-5 | AST-32 | Analysis-only candidate |
| CR-6 | AST-33 | Analysis-only candidate |
| CR-7 | AST-34 | Analysis-only candidate |

## Reconnaissance modeling-brief candidates

The same run's brief groups and renumbers some candidates. In particular,
brief T-9 means the socket-lock fault question (AST-35), whereas report T-9
means the Unix datagram ownership cycle (AST-34). Cite the artifact as well
as the run and ID when using these older candidates.

| Modeling-brief ID | AST ID | Original evidence level |
| --- | --- | --- |
| MC-1 | AST-03 | Analysis-only candidate |
| MC-2 | AST-36 | Analysis-only candidate |
| MC-3 | AST-31 | Analysis-only candidate |
| MC-4 | AST-32 | Analysis-only candidate |
| MC-5 | AST-39 | Analysis-only candidate |
| T-1 | AST-01, AST-04 | Analysis-only candidate |
| T-2 | AST-30 | Analysis-only candidate |
| T-3 | AST-36 | Analysis-only candidate |
| T-4 | AST-32 | Analysis-only candidate |
| T-5 | AST-31 | Analysis-only candidate |
| T-6 | AST-37, AST-38 | Analysis-only candidate |
| T-7 | AST-39 | Analysis-only candidate |
| T-8 | AST-33, AST-34 | Analysis-only candidate |
| T-9 | AST-35 | Analysis-only candidate |
| CR-1 | AST-01, AST-04 | Analysis-only candidate |
| CR-2 | AST-33, AST-34 | Analysis-only candidate |
| CR-3 | AST-31, AST-38 | Analysis-only candidate |
| CR-4 | AST-37 | Analysis-only candidate |

## TLPI-v2 attachment aliases

Archive SHA-256 `0c70d01cb9b8120e848fe8956bf9d594a7b07dc820a5b145e9ac9f5ceec55e07`, source pin
`a5449e62b0a5a0affccb6087ea3543a2fdf66052`. Every imported Asterinas result is NOT_RUN.
The existing AST-19 status comes from the earlier FD run, not this attachment.
See the [full intake mapping](../tlpi-audit-2026-09-14/finding-map.md) for
case-level coverage and grouped-claim splits. F02 is also related to AST-03.

| Attachment ID | AST ID | Imported runtime status |
| --- | --- | --- |
| F01 | AST-42 | NOT_RUN |
| F02 | AST-43, AST-44 | NOT_RUN |
| F03 | AST-45, AST-46 | NOT_RUN |
| F04 | AST-47 | NOT_RUN |
| F05 | AST-48 | NOT_RUN |
| F06 | AST-49 | NOT_RUN |
| F07 | AST-50 | NOT_RUN |
| F08 | AST-51 | NOT_RUN |
| F09 | AST-52, AST-53 | NOT_RUN |
| F10 | AST-54 | NOT_RUN |
| F11 | AST-55 | NOT_RUN |
| F12 | AST-56, AST-57 | NOT_RUN |
| F13 | AST-58 | NOT_RUN |
| F14 | AST-59 | NOT_RUN |
| F15 | AST-60, AST-61 | NOT_RUN |
| F16 | AST-62 | NOT_RUN |
| F17 | AST-19 | NOT_RUN |
| F18 | AST-49 | NOT_RUN |
| F19 | AST-63 | NOT_RUN |
| F20 | AST-64 | NOT_RUN |
| F21 | AST-65 | NOT_RUN |
| F22 | AST-66 | NOT_RUN |
| F23 | AST-67 | NOT_RUN |
| F24 | AST-68 | NOT_RUN |
| F25 | AST-69 | NOT_RUN |
| F26 | AST-70 | NOT_RUN |
| C01 | AST-71 | NOT_RUN |

## Later source audits

| Audit reference | AST ID | Disposition / scope |
| --- | --- | --- |
| 2026-09-16 backend audit: tmpfs/devtmpfs ordinary-file dispatch | AST-02 | Same RamInode implementation; static reachability, no new mounted-filesystem run |
| 2026-09-16 backend audit: exFAT direct empty-write path | AST-14 | Source follow-up only; historical MC-7 reproduction is the buffered path |
| [2026-09-16 backend audit: virtiofs direct empty-write path](../ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md#ast-72-virtiofs-direct-empty-write-source-lead) | AST-72 | SOURCE LEAD, runtime NOT_RUN; 2026-10-19 keyword pass found related items only; no native finding ID |
| [2026-10-03 memfd analysis: M01/M02](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md#ast-73seal-后只读映射仍被当作可写资格计数) | AST-73 | Both predictions share one post-seal tracking decision. SOURCE LEAD at the time, runtime NOT_RUN; 2026-10-19 keyword pass found related items only. These are manual case IDs, not native findings. |
| [2026-10-03 memfd analysis: M17/M18](../specula-scope-assessment-2026-10-02/memfd-bounded-source-contracts-2026-10-03.md#ast-74map_shared_validate-没有经过相同的-fd-写权限检查) | AST-74 | Direct writable admission and later mprotect share the SharedValidate FD-check omission. SOURCE LEAD, runtime NOT_RUN; 2026-10-19 keyword pass found related items only. |

The memfd analysis retains M03..M16 as contract controls and bounded paths
without a new defect identified, subject to each case's stated limits. In
particular, pre-seal read-only mappings can legitimately block WRITE sealing,
and post-seal MAY checks still reject write upgrades. These static controls
are neither runtime passes nor new FALSE POSITIVE dispositions.

The [sequential test package](../memfd-sequential-cases-2026-10-03/cases.json)
maps nine AST-73 scenarios and four AST-74 scenarios to their framework
function names and exact step labels. M02 includes M07, M06 has separate W/FW
fixtures, and M09 covers only its mmap subcase. Deferred contracts remain
explicit. Preparation and host compilation do not change either SOURCE LEAD
status, and all four before/Linux program executions remain NOT_RUN.

## Native memfd protocol analysis, 2026-10-03

Run `asterinas-memfd-analysis-20261003T094028Z` uses source
`0c60537098f4c2949ad2d382aaf499de72263d76`. The [brief revision](../memfd-brief-revision-2026-10-03/README.md)
changes the modeling decision and preserves the original evidence. The run
then completed spec generation, harness, validation, confirmation (GLM-5.3),
an empty repair loop and classification. Its final report is
[confirmed-bugs.md](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md).

| Native reference | AST ID | Disposition |
| --- | --- | --- |
| TV-1 / MC-1, including WRITE/EPERM and FUTURE_WRITE/false-EBUSY manifestations | AST-73 | REPRODUCED on Asterinas with a Linux control. Recovered known mechanism, not a novel finding. |
| TV-2 / MC-2, seal-rejected shared MAP_FIXED replacement | AST-75 | REPRODUCED on Asterinas with a Linux control, full and partial overlap. 2026-10-19 keyword pass: no upstream match. |
| CR-1, overlapping FUTURE_WRITE publication | AST-76 | FALSE POSITIVE. Check and publication share the seals mutex. |
| CR-2, ownership across split/merge/protect/unmap | AST-77 | FALSE POSITIVE. Owner counting is conserved and released after TLB synchronization. |
| CR-3, mprotect prefix and busy seal addition effects | AST-78 | FALSE POSITIVE. The Asterinas guest matched Linux on all 22 checks. |
| Scenarios 2/3 and the negative hypotheses in analysis-report §6 | None added | Bounded model checking found no protocol violation for these scenarios. This is a bounded result for two threads and three pages, not formal proof. |

AST-74 remains outside this native run's ordinary MAP_SHARED scope.

## Four lane records, 2026-10-04..10

Four informed protocol runs used source `0c60537098f4c2949ad2d382aaf499de72263d76`.
None is a blind baseline. Their preparation lives in the [futex/SCM_RIGHTS
handoff](../parallel-scopes-2026-10-04/README.md) and the [flock/wait-reap
handoff](../flock-wait-handoff-2026-10-05/README.md). Each lane's `result.md`
records phase exits, review verdicts, user decisions and evidence limits.
These mappings record individual dispositions, not complete concurrency
protocol verification. Wait/reap did not complete native validation/findings.

### Private futex: `asterinas-private-futex-requeue-20261004T064345Z`

Validation was rerun on claude-code Opus 5.5 after a Codex policy block, with
the user's direct authorization. The user accepted the validation review's
open items as limitations, so no concurrency claim comes from this run.
Final report: [confirmed-bugs.md](/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmed-bugs.md).

| Native reference | AST ID | Disposition |
| --- | --- | --- |
| MC-1, cross-bucket timeout cleanup (ResourceAccountingBalance, LiveMigrationExhaustion) | AST-79 | REPRODUCED, Level 0 with a Linux control. Agent search: new; the 2026-10-19 refresh found it reported as the main body of open upstream #3964. |
| MC-2 / validation TV-1, zero wake quota (RequeueWakeQuota) | AST-80 | REPRODUCED with a Linux 7.2.8 control. Known upstream as the second paragraph of open #3964. |
| MC-3 / validation TV-2, same-bucket zero move quota (RequeueMoveQuota) | AST-81 | REPRODUCED with controls. Agent search: new. |
| MC-4 / validation TV-3, REQUEUE return count (RequeueReturnCount) | AST-82 | REPRODUCED with a Linux 7.2.8 control. Agent search: new. |
| CR-1, value update and WAKE versus WAIT registration | AST-83 | FALSE POSITIVE. |

### Unix DGRAM SCM_RIGHTS: `asterinas-unix-dgram-scm-rights-20261004T064345Z`

Two limitations were accepted. The user accepted that PEEK is outside the
default ordinary-receive `MC.cfg`. The lane controller accepted whole-trace
overlap below 20% at gate 6, without a separate user ruling. Final report:
[confirmed-bugs.md](/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md).

| Native reference | AST ID | Disposition |
| --- | --- | --- |
| MC-1, NoFailedNumberInstalled / ReportedPrefixMatchesLinux | AST-32 | REPRODUCED with a Linux 7.2.8 control. Recovered known lead, not new. |
| MC-2, PayloadFaultConsumptionMatchesLinux | AST-36 | REPRODUCED with a Linux control. Recovered known lead, not new. |
| CR-1, ownership across reuse and release | AST-90 | FALSE POSITIVE. |
| CR-2, PEEK/ordinary selection versus publication order | AST-91 | FALSE POSITIVE (2-CPU guest, 173 overlapping deliveries, 0 failures). |

### Local flock: `asterinas-local-flock-ownership-20261004T160159Z`

Trace acceptance used the existential adapter that the user ratified on
2026-10-09. Only the four-event C00 trace meets the overlap criterion, and
general MC.cfg is time-limited. AST-85's specific race evidence remains
separate from campaign-wide coverage. Final report:
[confirmed-bugs.md](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md);
lane ledger: [candidate-ledger.md](../flock-wait-handoff-2026-10-05/flock/candidate-ledger.md).

| Native reference | AST ID | Disposition |
| --- | --- | --- |
| MC-1 (FL-SQ-1, FL-TV-1, FL-MC-1, former AST-NEW-FL1; hunts C05/C06) | AST-84 | REPRODUCED, Level 0 with a Linux 7.2.8 control. The two conversion manifestations share one mechanism. |
| MC-2 (FL-SQ-2, FL-TV-2, FL-MC-2, former AST-NEW-FL2; hunt C11) | AST-85 | REPRODUCED in an ungated syscall race with trace observers and deterministically with the reviewed gate. Not hit in 128 uninstrumented crossings. |
| CR-1, CR-2, CR-3, CR-4 | AST-86..89 | FALSE POSITIVE. |
| FL-CR-1, request-clone Drop drains re-enqueued waiters outside the list Mutex | AST-89 (native CR-4) | Same site, mechanism and scheduling-impact hypothesis as CR-4. FALSE POSITIVE under that confirmation record. Earlier source-only status is historical; no additional finding is counted. |
| MC-2 plain-run freeze in unrelated waits | None added | Unverified side observation that the agent links to upstream #3283; not analyzed. |

### Child wait/reap: `asterinas-child-wait-reap-20261004T160159Z`

Implementation-trace validation is BLOCKED_ENVIRONMENT on this AMD KVM host.
The user chose an outcome-only runtime mode and accepted harness residual
D9R5-S1 over a NOT_APPROVED review. Native validation exited 1 at Phase 0
without trace/TLC verification or a review. Findings exited 1 at its missing
bug-report prerequisite before any agent started. Neither row has native
confirmation. Lane ledger:
[candidate-ledger.md](../flock-wait-handoff-2026-10-05/wait-reap/candidate-ledger.md).

| Native reference | AST ID | Disposition |
| --- | --- | --- |
| WR-LX (lane lead WR-LEAD-WEXITED) | AST-92 | Outcome-only runtime record against a matching Linux control. |
| WR-SQ | AST-93 | Outcome-only runtime record against a matching Linux control. |
| WR-CF, WR-01..WR-10 | None added | Per-call outcomes match Linux expectations; no concurrency claim because guest placement is not credible. |
| WR-OBS-AFFINITY, `sched_setaffinity` does not migrate the caller | None added | Out of scope; documented TODO. |

## Source records

- [01a final report][01a-report], [GLM final report][glm-report],
  [01b final report][01b-report], [FD final report][fd-report].
- [Recon analysis report][recon-report], [Recon modeling brief][recon-brief].
- [AST-41 model-oracle correction](../independent-review/terra-asterinas-bug-report-vm-final.md#historical-model-oracle-exclusion).
- [01b worklist][01b-handoff], [earlier exFAT write-race work](../ast-validation-2026-09-02/exfat-write-race/README.md).

[fd-report]: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md
[01a-report]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md
[glm-report]: /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md
[01b-report]: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md
[01b-handoff]: ../runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md
[recon-report]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md
[recon-brief]: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md
