# Independent modeling-brief revision review

Review mode: `independent static revision review, not a native pipeline phase`.

Reviewed draft: [modeling-brief.md](modeling-brief.md).
SHA-256: `408f9dca8df0afef149a4b34c50d472817de66bd7a3d54805b3e77e93ce1a180`.

Verdict: **PASS for the revised modeling decision and handoff brief**.
Findings: `[]`.

The complete updated draft was reread. Both findings from the
[preserved first review](/home/chin39/Documents/play/specula-profile/reports/memfd-brief-revision-2026-10-03/before/review-revision-attempt1.md) are resolved:
revocation accounting now explicitly applies to tracked owners, and the
artifact requirements name `MC_hunt_*.cfg`, `brief-coverage.md`, actual
predicate enablement, and separate TV-1a/TV-1b/TV-2 checks. The analysis-report
section link is corrected. The AST-75 label attributes the existing TV-2
source lead without promoting its evidence status.

The selected model is one bounded eligibility protocol. It preserves both
locks, conditional counter RMWs, separate seal observation and publication,
retained MAY_WRITE, temporary owners, and ordinary revocation completion.
The checked source places denial before seal publication in
[memfd.rs:63](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source/kernel/core/src/fs/fs_impls/ramfs/memfd.rs:63),
conditions accounting on the tracked flag in
[vm_mapping.rs:944](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source/kernel/core/src/vm/vmar/vm_mapping.rs:944),
and completes dispatch/sync before the ordinary removed owner drops in
[vm_mapping.rs:830](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source/kernel/core/src/vm/vmar/vm_mapping.rs:830).

The draft preserves the known implementation failures rather than repairing
them in the transition relation. Saved Linux source supports the distinct
oracles: [read-only admission](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/linux-v6.18/mm__memfd.c:373)
and [seal rejection before replacement](/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/evidence/linux-v6.18/mm__mmap.c:485).
TV-1 and TV-2 remain source leads with runtime `NOT_RUN`. No new defect is
invented. Source HEAD remains `0c60537098f4c2949ad2d382aaf499de72263d76`, and
its working tree is clean.

The finite abstraction explicitly requires reachable scenarios, sufficient
temporary-owner capacity, and reported exclusions. It does not impose a
return-order admission rule, identify denial with already-published WRITE,
count only installed mappings, or require blanket failure rollback. TLB
completion remains a substrate assumption. These qualifications avoid the
identified intermediate-state false positives, subject to checking their
actual translation into the future specification.

The unchanged guidance remains compatible with the revised objective. Its
SHA-256 matches the run's saved prompt:
`1a5dee7d58a2e14710674590a28a4e9051e6ce7f973656b3da00de26d9fb1d01`.
The exclusions are retained. The required model/trace artifacts, explicit
coverage enablement and model review before harness work provide a feasible
next-stage contract. All phases remain deferred in this revision task.

This verdict covers the brief, not the continuation commands, future artifact
implementation or catalog installation. It is not a native pipeline review
result and does not authorize a phase launch. No model checker, phase, test,
guest or kernel was executed for either review pass.
