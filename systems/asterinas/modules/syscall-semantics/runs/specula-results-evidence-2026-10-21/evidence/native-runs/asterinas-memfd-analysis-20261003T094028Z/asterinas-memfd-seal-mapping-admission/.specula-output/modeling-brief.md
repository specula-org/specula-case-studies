# Modeling Brief: asterinas-memfd-seal-mapping-admission

## 1. System Overview

- **System:** Asterinas, Rust, source pin `0c60537098f4c2949ad2d382aaf499de72263d76`. The saved audit covers 22 core files and 7,031 lines.
- **Category:** **B (Concurrent / Lock-Free / Runtime)**. One memfd eligibility protocol coordinates inode seals, VMAR mutations, atomic accounting, owned mapping objects, and ordinary translation revocation.
- **Scope:** One fixed-size ordinary-page memfd and one shared address space. Include add/get seals, ordinary MAP_SHARED admission, mprotect, split/merge and munmap. O_RDONLY and private mappings are admission controls.
- **Reference:** The source contracts and pinned Linux snapshots in [analysis-report §4](analysis-report.md#4-linux-reference-and-contract-boundaries). Keep reference versions explicit when interpreting an outcome.
- **Identity:** Source, target, config, guidance and run ID are unchanged. This revision changes the derived modeling decision at the user's request to prepare the complete pipeline.
- **Evidence:** TV-1 and TV-2 remain source leads with runtime **NOT_RUN**. The completed source review has not established an additional concurrent defect. This revision performs no TLC, trace collection or kernel execution.

**Disposition:** Proceed to spec generation for bounded verification of the whole eligibility protocol. Produce a source-faithful model, check its observable contracts, and plan implementation trace validation. An empty list of newly suspected MC bugs does not remove these verification obligations. The former test-only recommendation and its review are preserved in the [revision record](/home/chin39/Documents/play/specula-profile/reports/memfd-brief-revision-2026-10-03/README.md).

## 2. Scenarios

### Scenario 1: Admission determines eligibility and accounting

**Mechanism:** FD mode, requested permissions and the observed seals determine future write eligibility. The implementation separately decides whether to acquire a counted owner.

**Evidence:** `kernel/core/src/syscall/mmap.rs:124-145`, `kernel/core/src/vm/vmar/vmar_impls/map.rs:337-349`, `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80-89`, and `kernel/core/src/vm/vmar/vm_mapping.rs:933-953`. Saved #2407/#2408 archaeology supplies the MAY_WRITE background. TV-1 retains tracking after the seal check strips MAY_WRITE.

**Affected paths:** `sys_mmap` → `VmarMapOptions::build` → `check_writable` → `MappedVmo::new`, followed by mprotect, seal addition and unmap.

**Suggested modeling approach:**
- Variables: requested/current permissions, checked MAY_WRITE, observed seals, FD-description identity, actual tracking decision and a pending ownership reservation.
- Actions: apply FD admission, check seals, conditionally acquire a token, publish a mapping and return. Record the implementation's tracking decision independently of semantic eligibility.
- Granularity: keep seal observation separate from the counter RMW. Preserve the VMAR lock over both steps and publication. Successful RO controls and rejected WRITE controls exercise the same state machine.

**Priority:** High. This establishes the initial capability used by every later operation. TV-1's two manifestations are known source controls and one tracking item, not two novel MC findings.

### Scenario 2: Seal publication overlaps admission and retained eligibility

**Mechanism:** Sealing serializes on the inode mutex, while admission holds the VMAR lock and briefly takes that mutex. WRITE exclusion is arbitrated by the counter RMW.

**Evidence:** `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:46-89`, `kernel/core/src/vm/page_cache/vmo/mod.rs:1199-1235`, `kernel/core/src/vm/vmar/vmar_impls/map.rs:269,337-349,402`, and `kernel/core/src/vm/vmar/vmar_impls/protect.rs:39-43`.

**Affected paths:** shared mmap, `F_ADD_SEALS(WRITE/FUTURE_WRITE/SEAL)`, `F_GET_SEALS` and protection changes of existing mappings.

**Suggested modeling approach:**
- Variables: seals, counter/denied state, both lock owners, per-thread operation stage, seal-check history and pending seal publication.
- Actions: check SEAL, attempt WRITE denial, publish requested bits, acquire mapping ownership, and change access within retained MAY permissions.
- Granularity: each counter RMW is atomic. Denial precedes publishing WRITE, so `WRITE ⇒ denied` is meaningful while the reverse implication is false during a pending successful seal operation.

**Priority:** High. Enumerate legal overlaps and preserve old eligibility across FUTURE_WRITE. A mapping returning after that seal may have checked eligibility before it. Return order alone is not a violation.

### Scenario 3: Ownership survives representation changes and revocation

**Mechanism:** Split, merge, protect and unmap change VMAR representation while ownership and possible hardware access have different lifetimes.

**Evidence:** `kernel/core/src/vm/vmar/vm_mapping.rs:725-788,808-875,1026-1102`, `kernel/core/src/vm/vmar/vmar_impls/mod.rs:292-324,391-411`, and `kernel/core/src/vm/vmar/vmar_impls/page_fault.rs:9-17`. Saved #2917/#2209/#682 findings are fixed historical context, not injected failure modes.

**Affected paths:** `split_range`, `try_merge`, `MappedVmo::dup_at_offset/Drop`, protect, ordinary range removal, page-fault exclusion and TLB completion.

**Suggested modeling approach:**
- Variables: mapping generation/range/backing offset, full permissions and file identity, installed and temporary owned objects, abstract PTE access and pending revocations.
- Actions: duplicate before transferring ownership, split or merge compatible pieces, detach a removed piece, revoke its PTEs, dispatch/synchronize invalidation, then drop its owner.
- Granularity: preserve increment-before-drop and completion-before-drop. Count reserved, detached and merge-temporary owners as well as installed mappings. Counter equality with tree entries or page count would be incorrect.

**Priority:** High. Check composition across these transitions without claiming the audit found a new lifetime defect. Track generations so a valid remap of an address does not look like stale access from its old mapping.

### Scenario 4: Rejected operations have operation-specific effects

**Mechanism:** A busy seal addition, a partly completed protection change and a rejected fixed replacement have different observable failure boundaries.

**Evidence:** `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:49-68`, `kernel/core/src/vm/vmar/vmar_impls/protect.rs:21-77`, and `kernel/core/src/vm/vmar/vmar_impls/map.rs:289-298,337-349`. The saved Linux admission sources reject the selected seal conflict before fixed replacement. TV-2 describes the current Asterinas order.

**Affected paths:** combined seal addition, multi-piece mprotect, and same-memfd MAP_SHARED | MAP_FIXED replacement under an already active FUTURE_WRITE seal.

**Suggested modeling approach:**
- Variables: request identity, visited range prefix, pre-operation seals/ranges, per-segment effects and the raw result category.
- Actions: process protection segments in source order, attempt seal denial before publication, and preserve Asterinas's fixed removal before its later seal rejection.
- Granularity: allow a successfully protected prefix to persist after a later EACCES/ENOMEM. Check the Linux early-rejection oracle only for the specified seal-conflict case, not every failed mmap.

**Priority:** High. TV-2 is independent of TV-1 and remains a known sequential source lead. Its source-faithful modeled outcome may violate the compatibility oracle without invalidating model fidelity.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

Select one **seal–eligibility–owned-mapping–revocation protocol** covering Scenarios 1–4. The useful result is bounded contract coverage and implementation correspondence, including successful behaviors and possible counterexamples. Generation does not require inventing a new §6.1 finding.

Keep current WRITE permission, retained MAY_WRITE, the actual tracked-owner flag, and denial state distinct. TV-1 makes those distinctions observable. Preserve the current implementation in the transition relation. Express Linux expectations as properties checked against it, never as guards that silently repair its behavior.

Preserve both locks, conditional RMWs, stable identity, and ordinary TLB synchronization. Model scheduling only at source-supported boundaries. Normal TLB completion is a substrate assumption, not a proof of hardware correctness. Current source compensation is part of the model rather than an obstacle to producing one.

Start exploration with two syscall threads and three page-sized address slots, which admit middle splits, partial unmap, remerge and prefix failures. Include enough owner identities for acquisition reservations and merge temporaries beyond installed pieces. Spec generation must justify its exact finite limits, show each scenario is reachable, and report bound-induced exclusions. A bound is not an implementation guard.

Generate `base.tla/.cfg`, `MC.tla/.cfg`, `Trace.tla/.cfg`, `instrumentation-spec.md`, `MC_hunt_*.cfg` and `brief-coverage.md`. The coverage audit must map every scenario/property to an existing configuration and verify that its predicate is actually enabled. Separate structural/protocol checks and individual TV-1a, TV-1b and TV-2 compatibility configurations so the first expected counterexample cannot mask another obligation. Use the same source transition semantics in every configuration. Account for every failed property without filtering its states or changing expected outcomes to obtain PASS.

### 3.2 Do Not Model (with rationale)

| Exclusion | Reason |
|---|---|
| MAP_SHARED_VALIDATE's FD-mode branch | It is a separate contract and the guidance excludes it. |
| Exec sealing, hugetlb, GUP/DMA, concurrent resize, mremap, fork/exec/exit, general COW, other filesystems | Preserve the approved single-protocol boundary. ftruncate is setup only. |
| Reverted historical fixes or weakened locks/RMW/TLB guarantees | They do not describe the pinned implementation. Historical fixes remain evidence pointers. |
| Byte-level storage, arbitrary memory corruption, counter overflow or injected allocation failures | No selected scenario needs these mechanisms or has a justified failure premise. |
| Syscall-wide rollback or return-order-only admission rules | They would prohibit Linux-permitted prefix effects or overlapping admissions. |

## 4. Proposed Extensions

These state components refine the public contract into the source implementation. Names are illustrative and may be refined by spec generation.

| Component | Suggested state | Purpose | Scenarios |
|---|---|---|---|
| Seal protocol | seal bits, denied/count, pending seal request, mutex owner | Separate successful denial from later bit publication and failed combined requests. | 1, 2, 4 |
| Admission history | thread stage, requested permissions, observed seals, MAY_WRITE, tracked flag | Preserve checked eligibility, actual accounting and legal overlap histories. | 1, 2 |
| Mapping ownership | generation, range/offset, file-description identity, installed/reserved/detached/temporary owners | Check accounting and identity through splitting, merging and retirement. | 1, 3, 4 |
| Access and completion | current permissions, abstract PTE access, outstanding generation-specific invalidations | Connect ordinary revocation completion to release of the final owner. | 2, 3 |
| Observable effects | operation ID, result, visited prefix, old range/seal snapshot | Check admission and operation-specific failure contracts at defined observation points. | 1, 2, 4 |

## 5. Proposed Invariants and Observable Contracts

Properties constrain observations of the implementation, not its enabled actions. Define intermediate-state predicates using operation stages and pending owners. Expected outcomes below are source-analysis expectations, not completed model-checking results.

| Property | Type and observation boundary | Contract and qualification | Scenarios |
|---|---|---|---|
| TypeAndIdentity | Structural safety throughout | Mapping ranges and owner identities are well formed. Split/merge preserve inode/VMO, backing offset, compatible full permissions and file-description identity. | 1, 3 |
| TrackedOwnershipConservation | Structural safety throughout | A nonnegative counter equals all actual live tracked owners, including reservations and temporaries. Denied state has no tracked owners. Do not count MAY_WRITE pages instead. | 1–3 |
| SealPublicationAndFreeze | Safety with operation history | Seals only accumulate, an existing SEAL blocks additions, busy WRITE addition publishes no requested bits, and published WRITE implies denied state. Do not require the converse between denial and publication. | 2, 4 |
| RetainedWriteEligibility | Safety at admitted/protected segments | Shared WRITE access requires the segment's retained MAY_WRITE. FUTURE_WRITE preserves eligibility obtained before its publication, including legal overlapping admission. | 1–3 |
| RevocationBeforeOwnerRelease | Safety by mapping generation | Ordinary removed tracked owners remain counted until required PTE/TLB revocation completes. Untracked O_RDONLY/private controls do not acquire a shared-eligibility counter obligation. Published WRITE cannot coexist with writable access still protected by such an owner. | 2, 3 |
| ReadOnlyAdmissionCompatibility | Outcome contract for valid resource-sufficient cases | Post-seal shared READ remains admissible without new write eligibility. At a quiescent seal attempt, such ineligible maps alone do not cause EBUSY. TV-1 is the known expected deviation. | 1 |
| SealRejectedReplacement | Outcome contract for the selected fixed replacement | An already active seal rejects the incoming shared WRITE before consuming the old range in the pinned Linux reference. Preserve Asterinas's order and report TV-2 if this property fails. | 4 |
| ProtectionPrefixEffects | Outcome contract at each segment and syscall return | A failed later protection segment permits prior successful changes while never granting permissions beyond each segment's MAY bits. No blanket rollback requirement. | 3, 4 |

Safety is the initial verification target. Add progress claims only with explicit scheduler/IPI fairness premises and evidence that the harness observes completion. A bounded run with no counterexample establishes only its recorded model, assumptions and coverage.

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

**No additional implementation defect is established by this revision.** The obligations in §5 are selected protocol-verification targets, not invented findings. Counterexamples must first be checked for abstraction, trace/oracle and supported-operation errors. A novel finding requires a source-reachable consequence beyond the known TV-1/TV-2 mechanisms.

### 6.2 Test-Verifiable Findings and Known Semantic Controls

| ID | Existing source lead | Role in the complete pipeline |
|---|---|---|
| TV-1 | Post-seal READ shared admission retains writable tracking: WRITE causes EPERM; FUTURE_WRITE can cause false EBUSY. Both manifestations share one cause, already tracked as AST-73. | Retain deterministic differential cases and source-faithful compatibility checks. Lifecycle consequences remain this same lead. Runtime is NOT_RUN. |
| TV-2 | Seal-rejected shared MAP_FIXED has already consumed the old range, independently of TV-1. | Retain the exact early-rejection oracle and full/partial replacement cases. Track as AST-75 in the cross-run catalog. Runtime is NOT_RUN. |

### 6.3 Code-Review-Only

No additional defect candidate is introduced. Keep the saved exclusions for legal overlap, old eligibility, counter ordering, merge compatibility and ordinary TLB completion. Contract verification does not relabel them as newly discovered bugs.

## 7. Handoff and Stage Decisions

1. **After analysis:** Review whether one coherent protocol, source-supported transitions and Linux-visible properties are selected. This revised brief selects them. Lack of a new MC candidate is not a stop condition. Stop for contradictory scope, unsupported contract, or a material missing premise.
2. **After spec generation:** Review every scenario/property against the generated model, assumptions, exclusions and finite bounds. Verify that known failures remain observable and that all property groups have reachable coverage before harness work.
3. **Harness and validation:** Map events to the same source transitions, then assess trace correspondence and bounded model results. Record object/generation/operation/thread identities, seal observations/publication, ownership changes, mapping changes, revocation completion and raw results. Syscall-return logs alone cannot establish internal ordering.
4. **Finding disposition and completion:** Preserve known-versus-new attribution and every counterexample, validate any implementation claim with the required source/runtime evidence, and report exact coverage and unresolved limits. Zero new bugs is a valid result. Missing artifacts, unrun obligations or unresolved mismatches are not a completed pipeline.

Keep source instrumentation from serializing away an original overlap. A Relaxed counter log is not a cross-thread ordering proof. Concurrency claims require attributable SMP≥2 runtime evidence when that work is executed.

This revision prepares continuation only. The next command runs spec generation and its review under the unchanged execution identity, with later stages deferred until that review. The user has not requested a phase launch in this revision task.

## 8. Reference Pointers

- [Analysis report](analysis-report.md), especially §§4–7, preserves source evidence, qualified Linux oracles and proposed tests. Its §8 records the revised modeling decision.
- [History audit](evidence/history-audit.md), [issue batch A](evidence/issues-a.md), [issue batch B](evidence/issues-b.md), and [open-PR screen](evidence/open-pr-audit.md) preserve prior archaeology. It is reused, not rerun by this revision.
- [VMO audit](evidence/deep-vmo.md), [mapping lifetime audit](evidence/deep-mapping-lifecycle.md), and [ordinary TLB audit](evidence/deep-tlb.md) supply detailed source reasoning.
- The saved Linux snapshots are under `evidence/linux-v6.18/`. Earlier v6.16/v6.16.5 comparisons retain their separate source identities. No claim about uninspected newer upstream code follows.
- [Revision record and continuation commands](/home/chin39/Documents/play/specula-profile/reports/memfd-brief-revision-2026-10-03/README.md) identify the preserved originals, fresh review and exact input hashes.
