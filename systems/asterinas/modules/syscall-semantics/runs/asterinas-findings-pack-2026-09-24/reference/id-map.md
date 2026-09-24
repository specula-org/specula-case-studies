# Original IDs to AST IDs

This is the alias map for the unified register (source artifact not included).
Run aliases resolve to exact run IDs and pins in the
campaign register (source artifact not included). AST IDs name tracking items;
raw statuses below belong to the original run, not to another run's evidence.
All original files, test names, and status fields remain unchanged.
Current upstream matches (source artifact not included) form a
separate dimension; an upstream closed/merged state does not alter these
historical run dispositions or attachment NOT_RUN records.

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
| GLM | MC-1 | AST-01, AST-04 | REPRODUCED | Existing shared count-erasure mapping; readv observation overlaps both historical entries |
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
| 01b | MC-6 | AST-02 | REPRODUCED | Current ramfs/exFAT batch (source artifact not included); FIX_PENDING_VALIDATION on bc12195; original status retained |
| 01b | MC-7 | AST-14 | REPRODUCED | Buffered/direct guards in current batch (source artifact not included); runtime deferred by user; historical confirmation covers buffered I/O |
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
See the full intake mapping (source artifact not included) for
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
| 2026-09-16 backend audit: virtiofs direct empty-write path (source artifact not included) | AST-72 | SOURCE LEAD, runtime NOT_RUN, upstream dedup NOT_CHECKED; no native finding ID |

## Source records

- 01a final report (source artifact not included), GLM final report (source artifact not included),
  01b final report (source artifact not included), FD final report (source artifact not included).
- Recon analysis report (source artifact not included), Recon modeling brief (source artifact not included).
- AST-41 model-oracle correction (source artifact not included).
- 01b worklist (source artifact not included), earlier exFAT write-race work (source artifact not included).
