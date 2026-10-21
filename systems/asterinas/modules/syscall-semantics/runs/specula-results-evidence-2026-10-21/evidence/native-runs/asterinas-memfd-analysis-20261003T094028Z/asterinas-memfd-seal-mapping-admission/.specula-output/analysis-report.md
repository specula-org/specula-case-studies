# Analysis report: asterinas-memfd-seal-mapping-admission

This analysis identifies two deterministic admission defects in the pinned source. One retains a writable-mapping tracking flag after seal validation removes write eligibility. The other removes an existing mapping before rejecting a sealed `MAP_FIXED` replacement. Both are source-verified candidates for syscall regression tests, not fresh runtime reproductions. The investigated admission, ownership, and ordinary-unmap paths otherwise supply concrete compensating mechanisms for the proposed concurrency failures. The user has selected bounded verification of the complete eligibility protocol. The revised modeling brief therefore proceeds to spec generation while retaining these source leads and every negative source conclusion below.

## 1. Identity, methodology, and evidence limits

- Source: `asterinas/asterinas`, commit `0c60537098f4c2949ad2d382aaf499de72263d76`. [The source identity manifest](evidence/source-identity.json) records every counted core file and its SHA-256.
- Checkout: `/home/chin39/Documents/play/Specula/runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/source`.
- Output: the sibling `.specula-output` directory. GitHub evidence was collected on 2026-10-03.
- Category: **B (Concurrent / Lock-Free / Runtime)**. Threads share an inode, an atomic eligibility counter, and a VMAR. The relevant boundaries are lock acquisition, atomic counter updates, owned mapping transfer, and TLB completion. There is no distributed message or crash-recovery protocol in the selected scope.
- Methodology: the installed Specula 1.2.0 code-analysis skill, its complete guide, shared deep-analysis, Category B, archaeology, modeling-brief format, example, and persistent-findings reference were read. Three parallel workers handled commit archaeology, two issue batches, and then independent VMO, mapping-lifecycle, and TLB analysis. The parent traced syscall and admission paths and compared Linux sources.
- Evidence categories remain separate: current source deductions, historical public reports, and Linux reference source/tests. No Asterinas guest, Linux syscall reproducer, imported reproducer, TLC model, or trace harness was executed. No patch was applied to the kernel.
- Persistent history was checked before deeper candidate analysis. The provided `persistent-findings-context.json` has no previous run and no inherited records. Lookups for `check_writable`, `WritableMappingStatus`, `MappedVmo`, and the read-only admission symptom returned `[]`. A second lookup for `FixedReplace`, `alloc_free_region_exact_truncate`, and seal rejection removing an existing mapping also returned `[]`. Analysis-only candidates were not registered as completed confirmation results.

The selected environment is one ordinary-page memfd with a fixed, page-aligned EOF and stable file descriptions, operated on by threads sharing one VMAR. Setup must verify `F_GETFL & O_ACCMODE` and `F_GET_SEALS`, rather than infer them from descriptor names. With `MFD_ALLOW_SEALING` and no execution-policy complication, the created handle is `O_RDWR` and the initial seal set is empty. Without that flag, the initial set contains `F_SEAL_SEAL` (`kernel/core/src/fs/fs_impls/ramfs/memfd.rs:230-274`). On Linux, any host execution-seal policy must be detected in this setup observation, not silently ignored.

Read-only controls reopen `/proc/self/fd/N` with `O_RDONLY`. `dup` and `F_SETFL` do not create a different access mode: the mode is a separate immutable field in `kernel/core/src/fs/file/file_common.rs:22-47`. The checked repository regression already reopens memfds this way (`test/initramfs/src/regression/fs/pseudofs/memfd_access_err.c:19-25,50-65`). Private mappings are admission controls only. Resizing is setup only. `MAP_SHARED_VALIDATE`, exec sealing, hugetlb, GUP/DMA, mremap, fork/exec/exit, concurrent resizing, general COW, and other filesystems remain excluded.

## 2. Reconnaissance and atomicity map

### 2.1 Structural map

| Layer | Responsibility and checked anchors |
|---|---|
| Syscalls | `kernel/core/src/syscall/memfd_create.rs:12-57` constructs the file. `fcntl.rs:207-224` validates seal bits and dispatches add/get. `mmap.rs:124-145` derives eligibility from the actual FD mode. `mprotect.rs:11-56` and `munmap.rs:8-27` validate ranges and enter the VMAR. |
| Memfd inode | `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:39-89` owns the seal mutex, seal publication, and admission restriction. `memfd.rs:277-306` checks file-handle authority and preserves inode identity. |
| File to VMO | `kernel/core/src/fs/file/inode_handle.rs:378-396` obtains the inode's page-cache VMO. `kernel/core/src/vm/vmar/vmar_impls/map.rs:329-349` checks the same inode and constructs the tracked owner. |
| VMAR | `kernel/core/src/vm/vmar/vmar_impls/map.rs:253-404` installs mappings while holding the VMAR write lock. `protect.rs:17-80` transforms ranges under that lock. `unmap.rs:44-51` calls the ordinary removal path. |
| Mapping ownership | `kernel/core/src/vm/vmar/vm_mapping.rs:725-788` splits owned mappings. `vm_mapping.rs:933-1045` associates the tracking token with a `MappedVmo` and balances duplicates/drops. `vm_mapping.rs:1056-1102` enforces merge compatibility. |
| VMO counter | `kernel/core/src/vm/page_cache/vmo/mod.rs:1184-1237` implements admission, deny, increment, and decrement on one `AtomicIsize`. |
| PTE and TLB | `kernel/core/src/vm/vmar/vm_mapping.rs:830-840,843-875` performs ordinary unmap/protect and waits for translation completion. `ostd/src/mm/vm_space.rs:472-536` dispatches unmap flushes. `ostd/src/mm/tlb.rs:82-160` implements dispatch and completion. |

The 22 fully read current core files total **7,031 lines**. The small syscall files and the memfd/admission files were read completely. `vm_mapping.rs` was read completely by the parent and independently by a worker. Full-file coverage and adjacent reads for the VMO, interval tree, VMAR implementation, and OSTD completion paths are recorded in `evidence/deep-vmo.md`, `evidence/deep-mapping-lifecycle.md`, and `evidence/deep-tlb.md`. Excluded operations residing in these files were distinguished from the selected call chains rather than imported into the model scope.

### 2.2 Operations are not single atomic syscalls

| Operation | Atomic boundary and permitted interleaving |
|---|---|
| `F_ADD_SEALS` | The inode seal mutex spans the `F_SEAL_SEAL` check, any `deny()` RMW, and the OR into seals (`memfd.rs:46-70`). `F_GET_SEALS` takes the same mutex (`memfd.rs:73-75`). The counter operation is separately atomic relative to map/split/drop. |
| Map admission | The VMAR write lock spans region selection/replacement, seal checking, token acquisition, and tree insertion (`map.rs:269-404`). `check_writable` holds the seal mutex only for its own call (`memfd.rs:80-89`). A seal operation can run between that check and `MappedVmo::new`. |
| `mprotect` | The VMAR write lock excludes another map/protect/unmap in the same address space (`protect.rs:21`). Each mapping is checked using its retained MAY bits (`protect.rs:39-43`), split, protected, and merged. A seal operation can interleave because it does not acquire the VMAR lock. |
| Split/merge | Owned tokens exist even when their mappings are temporarily outside the tree. Splitting duplicates before releasing the original ownership. Merging constructs a replacement token before dropping inputs (`vm_mapping.rs:732-746,1026-1043,1086`; `vmar_impls/mod.rs:292-311`). Counting only installed tree nodes is therefore an invalid abstraction. |
| Ordinary removal | Removal transfers the mapping to a local owner, splits it, and consumes the removed piece in `unmap` (`vmar_impls/mod.rs:391-411`). The piece retains its token through PTE removal and `sync_tlb_flush`, then drops (`vm_mapping.rs:830-840,1039-1043`). |
| User access | A resident writable translation can be used without taking VMAR locks. Fault handling, however, holds a VMAR read guard (`vmar_impls/page_fault.rs:9-17`). Thus tree membership alone cannot stand in for completed revocation. |

The atomic counter records outstanding accounting tokens, including constructor reservations and locally held tracked `MappedVmo` owners. It does not count pages, VMAs visible in the tree, open FDs, `Arc<Vmo>` references, or currently writable PTEs. Positive values deny a WRITE seal. Zero permits `deny()` to install -1. Negative values deny tracked admission. `map()` and `deny()` are conditional atomic RMWs on that same location (`vmo/mod.rs:1199-1221`). A model must not replace them with independent load/store pairs or invent stale successful RMWs.

## 3. Bug archaeology

### 3.1 Collection and review coverage

Git history was mined across 25 current and 147 current/historical core paths, including the former `kernel/src/vm/vmo` layout. All 419 touching commit subjects and bodies were screened. All 71 keyword matches and 33 supplemental non-keyword changes had their complete core diffs inspected: **104 commits, 10,767 diff lines**. These include **60 behavior fixes**: 11 directly in scope, 19 boundary/ABI fixes, and 30 outside the selected operations. The other 44 are mechanical changes, introductions, refactors, support changes or a performance change. The 315 remaining nonkeyword commits were metadata-screened, not patch-read. The complete inventory, every candidate diff, per-commit cause/component/severity/relevance, and hotspot counts are in [the history audit](evidence/history-audit.md). No keyword candidate or identified behavior-fix candidate was sampled out.

Eleven `gh issue list` searches used `memfd`, `seal`, `mmap`, `mprotect`, `munmap`, `VMO`, `"page cache"`, `TLB`, and three `C-bug` label/keyword combinations. Their result counts were 8, 3, 81, 16, 20, 68, 55, 20, 38, 17, and 13. They yielded **190 unique issue records**. The 30 issues most relevant to the selected mechanisms and their adjacent controls were read in two parallel workers, in batches of 10 then 5. All their bodies and all **46 comments** were read. The remaining 160 are collected metadata, not deeply read or confirmed findings. Raw query results are in `evidence/github/issue-queries.json` and `issue-inventory.json`.

| Deep-read issue classification | Count | Interpretation |
|---|---:|---|
| Confirmed bugs or API defects | 23 | Includes historical and out-of-scope defects. Duplicate #1530/#1420 is not an additional mechanism. |
| Acknowledged design defect/proposal | 4 | Not four reproduced failures. |
| Unresolved design question | 2 | #466 and #648 do not establish an admission defect. |
| Disputed/false allegation | 1 | #2849's unconditional-flush/UAF allegation was not established and its proposed fix was rejected. |
| User error | 0 | No issue was assigned this category. |

Direct historical protocol evidence comprises four issues. Nine provide adjacent architectural context, and 17 require excluded operations or invalid-input premises. Scope exclusion is separate from the one false-positive exclusion. Per-issue confirmation, root cause, fix status, thread completeness, and uncertainty are retained in [batch A](evidence/issues-a.md) and [batch B](evidence/issues-b.md).

All **105 open PRs** were collected and screened for scope. A deliberately broad title/body fix expression selected 73 candidates, including feature PRs that only mention an error or regression. Returned changed-file metadata was inspected for every PR. Seven directly relevant or misleading shared-file discussions were read completely, including reviews and inline comments. This is not a claim to have deeply reviewed 105 whole patches. The full scope-screen inventory is [open-pr-audit.md](evidence/open-pr-audit.md).

| Open PR | Verified disposition |
|---|---|
| [#3481](https://github.com/asterinas/asterinas/pull/3481), head `d4d1cd3a22ac68b2e56821f42f867cd4548b6cd6` | Despite the memfd seal-race title, its full discussion and memfd diff concern append offsets, resize, and fallocate under inode locks. It does not fix `VmarMapOptions::build` or change `MappedVmo` tracking. Its size-changing competitors are excluded here. |
| [#2613](https://github.com/asterinas/asterinas/pull/2613), head `e5d6a590178d0fc9e259132f4d6fc0969630e921` | A proposed cursor API redesign. Its branch-specific comments about `clear`, COW, huge-page traversal, and dispatch do not establish the same defects in this pinned ordinary-page removal path. Full discussion assessment is in the TLB audit. |
| [#2615](https://github.com/asterinas/asterinas/pull/2615), head `8d8d0452004b96d0c14552f1e479b11abdd59ff4` | CortenMM is an unmerged replacement architecture, with its own VMAR/cursor representation. Its body and complete discussion do not establish a fix to the current memfd eligibility decision. Do not silently analyze its code as current. |
| [#3778](https://github.com/asterinas/asterinas/pull/3778) | The complete discussion concerns returned read lengths, writer buffers, EOF and concurrent resize, outside this protocol. It is not a seal-admission fix. |
| [#3346](https://github.com/asterinas/asterinas/pull/3346) | The complete discussion concerns VFS/inode validation responsibilities and resize/fallocate placement. A shared memfd filename is not evidence of a mapping-counter fix. |
| [#3841](https://github.com/asterinas/asterinas/pull/3841), [#3842](https://github.com/asterinas/asterinas/pull/3842) | Both full discussions concern fcntl ownership and SIGIO delivery, not `F_ADD_SEALS` or `F_GET_SEALS`. Their reported CI results are not validation of this target. |

Across the two workers and the parent, **29 distinct PR discussions** were read completely: 18 in the issue batches, four additional historical PRs (#2408, #2766, #2926, #3784), and these seven open PRs. Fetching another PR's metadata or patch does not increase that deep-read count.

### 3.2 Historical mechanisms that guided current inspection

| Mechanism | Historical evidence | Treatment in this analysis |
|---|---|---|
| Current permission was confused with future eligibility | [#2407](https://github.com/asterinas/asterinas/issues/2407), fixed by #2444 / `57d3d9ded1fe`. The complete discussion distinguishes O_RDONLY admission, retained MAY bits, and private COW. | Inspect the current post-validation eligibility and normal mprotect path. Do not recreate the old missing-MAY check. |
| Ownership counting was introduced across mapping transformations | [#2408](https://github.com/asterinas/asterinas/pull/2408), including `d1506171d27e` and `6ba1a84ae90d`. The full discussion moves accounting into `MappedVmo` and explains why Relaxed suffices for one counter. | The same introduction left the current `check_writable(...); true` decision. TV-1 concerns that still-present logic, not a reverted historical fix. |
| A snapshot of mapping addresses outlived merging | [#2917](https://github.com/asterinas/asterinas/issues/2917), fixed by #2919 / `c7b633e9bdf4`. | Verify the current absent-remove compensation and compatibility checks. |
| Adjacent virtual ranges need not have contiguous backing offsets | [#2209](https://github.com/asterinas/asterinas/issues/2209), fixed by #2213 / `810580bda555`. | Preserve VMO identity and offsets in reasoning. Do not inject the removed subtraction bug. |
| A mapping reference survived removal from its address space | [#682](https://github.com/asterinas/asterinas/issues/682), resolved by owned `VmMapping` in #1557. | Check the current local owners and the VMAR guard over page-fault handling. |
| Memfd can be reopened with different FD access modes | [#2555](https://github.com/asterinas/asterinas/pull/2555), `9c6dbcee79a3`, with all 7 conversation comments, 20 reviews, and 37 inline comments read. | Use actual O_RDONLY controls and the same inode/page-cache identity. |
| Error returns can retain legal partial effects | [#2766](https://github.com/asterinas/asterinas/pull/2766), including `7feb803eaba2`. | Preserve mprotect prefix updates on later failure. Check the exact seal-rejection point for fixed replacement separately. |
| Page-table changes need completed translation invalidation | [#970](https://github.com/asterinas/asterinas/issues/970), [#1602](https://github.com/asterinas/asterinas/issues/1602). | Inspect the present dispatch/sync path and IRQ-safe flush locks. Do not remove historical fixes to manufacture a trace. |

The full #2408 discussion also contains automated suggestions to make every increment/decrement fallible. These are not confirmed bugs: current increments duplicate a live token, and decrements consume one. The maintainer explicitly corrected the earlier acquire/release rationale in [discussion_r2480010887](https://github.com/asterinas/asterinas/pull/2408#discussion_r2480010887). The unguarded helper alone is insufficient evidence of a reachable negative-counter resurrection.

## 4. Linux reference and contract boundaries

The primary implementation baseline is the pinned upstream Linux **v6.18** tag, with the seal-rejection placement cross-checked against **v6.16**. Full source snapshots are saved in `evidence/linux-v6.18/` and `evidence/linux-v6.16/`. Public manual pages supply the ABI vocabulary. These are reference facts, not locally observed kernel outcomes.

| Contract | Reference and consequence for this task |
|---|---|
| Seal state belongs to the inode and is monotone | [F_ADD_SEALS manual](https://man7.org/linux/man-pages/man2/F_ADD_SEALS.2const.html). Further additions fail under SEAL, and adding seals requires a writable descriptor. |
| WRITE excludes shared mappings that retain write eligibility | [Linux v6.18 `include/linux/fs.h:594-627`](https://github.com/torvalds/linux/blob/v6.18/include/linux/fs.h#L594-L627) defines the counter in terms of shared MAYWRITE, even if currently read-only. A downgrade alone does not make WRITE sealing legal. |
| Read-only shared admission remains legal after either write seal | [Linux v6.18 `mm/memfd.c:373-407`](https://github.com/torvalds/linux/blob/v6.18/mm/memfd.c#L373-L407) rejects requested shared WRITE and otherwise clears MAYWRITE. The subsequent [counter reservation](https://github.com/torvalds/linux/blob/v6.18/mm/vma.c#L2731-L2744) uses the resulting eligibility. |
| Old FUTURE_WRITE eligibility survives protection changes | [Linux v6.18 `mm/mprotect.c:948-963`](https://github.com/torvalds/linux/blob/v6.18/mm/mprotect.c#L948-L963) retains existing MAY bits and checks the requested access against them. It does not reclassify a mapping from the current seal set. |
| Failed mprotect can retain a successfully changed prefix | [Linux v6.18 `mm/mprotect.c:931-1005`](https://github.com/torvalds/linux/blob/v6.18/mm/mprotect.c#L931-L1005) changes one VMA at a time, then can stop at a hole or an ineligible next VMA. FAILURE-ATOMICITY cannot mean syscall-wide rollback. |
| Seal denial precedes fixed replacement in the checked Linux baselines | [v6.18 `mm/mmap.c:485-491`](https://github.com/torvalds/linux/blob/v6.18/mm/mmap.c#L485-L491) and [v6.16 `mm/mmap.c:488-494`](https://github.com/torvalds/linux/blob/v6.16/mm/mmap.c#L488-L494) reject active seals before entering mapping-region replacement. This is a specific early-rejection guarantee in these sources, not a universal guarantee for every mmap failure. |
| Failed combined WRITE sealing publishes no requested bits in this scope | [Linux v6.18 `mm/memfd.c:282-305`](https://github.com/torvalds/linux/blob/v6.18/mm/memfd.c#L282-L305) returns on a busy writable counter before ORing the seals. Pin-draining behavior is excluded. |

Linux's own [ordinary memfd selftests](https://github.com/torvalds/linux/blob/v6.18/tools/testing/selftests/memfd/memfd_test.c#L965-L1022) explicitly include a read-only shared map after WRITE and read-only shared admission after FUTURE_WRITE. The helper at lines 285-300 uses the original descriptor. These tests support TV-1's admission oracle. They were read, not executed.

The requested terms are questions and test oracles, not premises imposed on the implementation: BOUNDARY-VALIDATION asks whether the admitted capability is correct, NO-STALE-ACCESS asks when revocation completes, FAILURE-ATOMICITY asks which effects each particular failure may retain, and OBJECT-IDENTITY-STABILITY asks whether file, VMO, offset and eligibility survive representation changes.

## 5. Source-verified findings requiring runtime confirmation

### TV-1: Seal validation removes MAY_WRITE but leaves writable tracking enabled

**Status:** Source-verified candidate, already tracked as AST-73, runtime unverified. **Impact:** Availability and Linux compatibility. This finding does not demonstrate a forbidden write or an immutable-file modification.

The decisive lines are `kernel/core/src/vm/vmar/vmar_impls/map.rs:337-349`. The branch tests the initial MAY_WRITE, calls `MemfdInode::check_writable`, and returns `true` unconditionally. `check_writable` clears MAY_WRITE for a read-only request when WRITE or FUTURE_WRITE is present (`memfd.rs:80-89`). The resulting mapping therefore has no upgrade eligibility but still invokes `WritableMappingStatus::map` (`vm_mapping.rs:944-953`). No later code recomputes the flag: it is retained and copied by `MappedVmo` (`vm_mapping.rs:1026-1043`).

There are two externally distinct manifestations of this one root cause:

1. Create a sealable, fixed-size memfd and verify O_RDWR plus empty seals. Add WRITE with no existing eligible maps. A new `mmap(..., PROT_READ, MAP_SHARED, fd, 0)` passes `check_writable`, which clears MAY_WRITE, but attempts tracked admission against counter -1 and returns EPERM (`vmo/mod.rs:1199-1206`). Linux allows the read-only mapping. An O_RDONLY handle and a private mapping bypass this erroneous tracking branch and serve as controls.
2. Start empty, add FUTURE_WRITE, and create an O_RDWR read-only shared mapping. It has no MAY_WRITE, so mprotect to WRITE correctly fails EACCES (`protect.rs:42-43`; `perms.rs:35-40`). Nevertheless, its tracked owner makes the counter positive. A subsequent `F_ADD_SEALS(WRITE)` incorrectly returns EBUSY although no eligible shared mapping exists (`memfd.rs:63-68`; `vmo/mod.rs:1212-1221`). Ordinary munmap releases the false blocker. Splitting can multiply it and merging can combine it, but those are consequences of the original misclassification, not independent leaks.

**Compensations checked:** The ordinary MAP_SHARED FD-mode check only removes MAY_WRITE for a genuinely nonwritable handle (`mmap.rs:128-137`), so it does not protect the original O_RDWR case. `new_perms.check()` prevents the ineligible FUTURE_WRITE mapping from gaining WRITE. The ordinary unmap path drops the token correctly. Seal publication remains behind successful `deny()`, so a rejected combined request does not partially set new seals.

**History match:** Empty persistent registry. The current decision can be traced to `6ba1a84ae90d` in the sealing introduction. The complete #2408 discussion establishes intended MAYWRITE semantics, not an acknowledged decision to count ineligible maps. The reviewed open memfd-race PR does not touch this path.

**Verification route:** A small deterministic syscall matrix is sufficient. It should assert mapping return values, mprotect errno, observed `F_GET_SEALS`, and the ability to add WRITE before and after final unmap. No interleaving search is necessary to demonstrate either manifestation.

### TV-2: Seal-rejected MAP_FIXED admission has already removed the old mapping

**Status:** Source-verified compatibility candidate against Linux v6.16 and v6.18, tracked as AST-75, runtime unverified. **Impact:** A rejected request removes an existing user mapping and its eligibility, potentially making subsequent WRITE sealing succeed. The file contents are not shown to be corrupted.

The ordinary MAP_SHARED fixed-replacement branch calls `alloc_free_region_exact_truncate` at `kernel/core/src/vm/vmar/vmar_impls/map.rs:289-298`. That routine removes mappings, splits surviving pieces, and synchronously unmaps each removed piece (`vmar_impls/mod.rs:391-411`). Only afterwards does `map.rs:337-349` validate the memfd seals. An EPERM return at `memfd.rs:83-84` cannot restore the consumed mapping.

A trigger entirely inside the selected protocol is: create a fixed-size memfd and an eligible shared mapping through its O_RDWR handle, add FUTURE_WRITE, then request `MAP_SHARED | MAP_FIXED` with WRITE over that old mapping using the same memfd and a valid in-EOF offset. The seal request succeeds because FUTURE_WRITE permits existing eligibility. The replacement request must fail EPERM. In the pinned Asterinas source it has already removed the old range. In the checked Linux sources, the seal failure occurs in `do_mmap` before `mmap_region` can remove anything (`mm/mmap.c` references above).

A particularly discriminating oracle uses the last eligible mapping: after the failed replacement, another `F_ADD_SEALS(WRITE)` is source-predicted to succeed on Asterinas, whereas Linux still has the original eligible VMA and returns EBUSY. A partial replacement should lose only the attempted subrange on Asterinas, while any surviving eligible fragment must continue to block WRITE. These checks expose the mapping effect without relying on a crash or invalid user buffer.

**Compensations checked:** FD-mode and user-range errors occur before VMAR mutation, but this valid O_RDWR seal failure does not. `FixedNoReplace` conflict checks are a different branch and are not a rollback mechanism. Holding the VMAR lock makes replacement serialized with other VMAR operations, but does not restore discarded mappings. `MappedVmo::new` is not reached for an explicitly requested WRITE under the active seal, so this trigger does not depend on TV-1.

**Contract qualification:** This is not a claim that all failed MAP_FIXED operations must roll back. The checked Linux failure happens before replacement. Other failure sites may legally retain effects and must have their own oracle. The effect is already deterministic without a competing seal thread, so it does not independently justify model checking.

## 6. Protocol hypotheses checked and excluded

| Hypothesis | Current-source resolution |
|---|---|
| A read-only shared map made before sealing must not block WRITE. | Rejected. With O_RDWR and retained MAY_WRITE it remains eligible for upgrade, so EBUSY is required. `mmap.rs:74,128-137`; `vmo/mod.rs:1184-1191`; Linux `include/linux/fs.h:594-601`. |
| An old mapping upgraded after FUTURE_WRITE is a forbidden new writer. | Rejected. `protect.rs:42-43` preserves the mapping's original MAY_WRITE. FUTURE_WRITE does not revoke it. This applies even if the old mapping had only READ when the seal was added. |
| A map that returns after FUTURE_WRITE must be treated as new. | Rejected. A successful pre-seal `check_writable` can admit eligibility before the seal operation while map publication is pending. Both syscalls overlap. Return order alone does not invalidate this linearization. `map.rs:269,337-349`; `memfd.rs:80-89`. |
| A WRITE seal can succeed between the seal snapshot and tracked admission, then admit a writer. | Rejected. If deny wins, the counter is negative and map fails. If map wins, deny sees a positive count and returns EBUSY. These are atomic RMWs on the same location (`vmo/mod.rs:1199-1221`). |
| A protection downgrade should decrement eligibility. | Rejected. MAY bits survive and the owned `MappedVmo` is moved into the protected mapping (`protect.rs:42`; `vm_mapping.rs:875`). A future upgrade remains legal. |
| Splitting or merging briefly exposes zero while eligible access remains. | No reachable witness found. Split duplicates a live token before moving ownership. Merge duplicates one compatible source before consuming either input. Full permissions, file description, VMO identity, and offset contiguity constrain merging (`vm_mapping.rs:725-749,1056-1102`). |
| A mixed eligible/ineligible merge transfers write eligibility. | Rejected for the checked syscall paths. Full `perms`, including MAY bits, must match, and different open descriptions do not merge (`vm_mapping.rs:1058-1064`). The omission of an explicit tracked-flag comparison does not establish a reachable mismatch for the same FD and equal MAY bits. |
| The final ordinary unmap releases its seal blocker before TLB completion. | Rejected for this path. A local `taken` mapping owns the token until `unmap(self)` finishes dispatch and sync (`vmar_impls/mod.rs:398-411`; `vm_mapping.rs:830-840`). This conclusion does not cover `clear()` during exit, which is excluded. |
| A detached page-fault worker can repopulate a mapping after ordinary removal. | Rejected in this scope. Fault handling holds `inner.read()` over the mapping access, while map/protect/remove require `inner.write()` (`vmar_impls/page_fault.rs:9-17`; `unmap.rs:48`; `protect.rs:21`). |
| Ineligible RO mappings remaining after eligible mappings are removed show an unmap leak. | TV-1 explains the false blocker: those mappings were misclassified at admission. With correctly classified owners, ordinary unmapping balances drops. Backing cache pages or FD references remaining alive are not eligibility tokens. |
| An EACCES or ENOMEM mprotect return requires all previous permission changes to be undone. | Rejected. The current code checks and changes mappings sequentially (`protect.rs:29-77`), matching Linux's allowed prefix effects. A useful control is an old eligible VMA followed by a post-FUTURE_WRITE ineligible VMA. The first may gain WRITE before the second causes EACCES. |
| Failed `F_ADD_SEALS(WRITE | FUTURE_WRITE | SEAL)` sets some new bits. | No witness found. Existing SEAL is checked first. Busy `deny()` returns before `*seals |= new_seals` (`memfd.rs:49-68`). Existing bits remain observable through locked `get_seals`, and no requested bit is added on this failure. |
| Sealing and mapping might use different VMOs for the same memfd. | Rejected under stable FDs and fixed inode identity. `InodeHandle::mappable` returns the inode's page cache (`inode_handle.rs:389-393`), `map.rs:331-338` checks that same path, and the mapping holds the file and `Arc<Vmo>` (`vm_mapping.rs:72-77,933-952`). Construction details are in the VMO audit. |
| Forged user MAY bits bypass checks. | Rejected. `sys_mmap` uses `from_user_bits_truncate` and `sys_mprotect` uses `from_user_bits`; only normal permission bits enter (`mmap.rs:25`; `mprotect.rs:17`; `perms.rs:46-61`). The historical validation fix is already present. |
| Relaxed accounting or unchecked increment alone establishes a race. | Rejected. The accounting decisions use one atomic modification order. Increments require an existing owned token, and denied state cannot coexist with such a correctly admitted token. No cross-variable weak-memory witness was established. Do not inject the equivalent of removing the RMW checks. |

The source-level accounting argument establishes why the listed candidates fail under the chosen premises. It is not a machine-checked proof of all kernel behavior. Actual hardware invalidation and syscall outcomes remain unverified in this analysis.

Developer signals were scanned across all selected core paths. The TODO/FIXME sites concern unsupported hugetlb (`memfd_create.rs:39`), stricter overflowing mprotect ranges (`mprotect.rs:33`), fcntl process groups (`fcntl.rs:183`), private COW reverse mappings/RSS (`vm_mapping.rs:198,521`), VMO backend/eviction generality (`vmo/mod.rs:119,136,996`), and address-allocation policy (`vmar_impls/mod.rs:426`). None is promoted into an in-scope defect by its label alone. The mremap FIXME is explicitly excluded.

## 7. Verification handoff

Each row below is a proposed test, **NOT_RUN**. Use a fresh memfd per independent case, ordinary page sizes, verified FD modes and initial seals, adequate address-space limits, stable descriptors, and offsets entirely within the fixed EOF. Thread creation, if needed for controls, precedes the operation sequence. Capture the complete syscall result, errno, F_GET_SEALS values, and range state. Do not count an unexpected setup seal or unsupported environment as a product result.

| Test family | Expected Linux oracle and Asterinas source prediction |
|---|---|
| TV-1a: add WRITE, then O_RDWR READ shared mmap | Linux succeeds and later WRITE mprotect fails EACCES. Asterinas is predicted to fail the mmap with EPERM. O_RDONLY shared and private mappings are controls. |
| TV-1b: add FUTURE_WRITE, admit O_RDWR READ shared map, add WRITE | Linux permits WRITE because the new mapping lacks MAY_WRITE. Asterinas is predicted to return EBUSY. Confirm upgrade remains EACCES and F_GET_SEALS is unchanged on failure. |
| TV-1 lifecycle consequence | Admit an old eligible multi-page map, add FUTURE_WRITE, then admit a new read-only ineligible map. Split/protect/partially unmap the old map, remove its final fragment, and try WRITE. Only TV-1's falsely tracked new map should explain any remaining EBUSY. Remove it and retry. |
| TV-2: denied fixed replacement | With the last old eligible mapping under FUTURE_WRITE, try shared WRITE MAP_FIXED replacement over it. Expect EPERM on both systems, but Linux retains the original eligibility and WRITE remains EBUSY. Asterinas is predicted to lose it and permit WRITE. Repeat on a subrange to distinguish partial loss from removal of the whole mapping. |
| Existing eligibility control | Admit READ shared via O_RDWR before FUTURE_WRITE. Upgrade to WRITE after the seal, downgrade, split, merge, and upgrade again. These are legal operations. WRITE remains EBUSY until the final eligible fragment is ordinarily unmapped. |
| New eligibility control | Admit READ shared after FUTURE_WRITE or through O_RDONLY. WRITE mprotect must fail EACCES. A new shared WRITE mmap after either write seal must fail EPERM, except that a genuinely O_RDONLY FD is rejected earlier with EACCES. |
| Failure-effects control | Protect a range containing an eligible first VMA and an ineligible next VMA. Expect an EACCES return with any successfully changed prefix retained. A range with a hole may similarly return ENOMEM after changing the prefix. |
| Seal monotonicity/control | Test default SEAL initialization, repeated permitted additions, an existing SEAL rejecting additions, O_RDONLY add rejection, and a busy combined WRITE/FUTURE_WRITE/SEAL request leaving the old bitset unchanged. |
| Scheduled overlap control | If concurrency testing follows, record the seal-check and token-acquisition boundaries. A mere mmap-return timestamp after FUTURE_WRITE is not an oracle. WRITE admission must have the two mutually exclusive RMW outcomes described above. |

The checked regression suite already covers memfd FD access modes, but its source is not proof of this matrix's execution. The Linux selftest is a useful admission reference. No new test source, kernel patch, model, or reproduction result is claimed here.

## 8. Revised modeling disposition

On 2026-10-03 the user requested a brief that supports the complete pipeline, then limited this task to revising the brief and preparing continuation commands. The previous report, brief, analysis review and failed generation audit are preserved in the [revision record](/home/chin39/Documents/play/specula-profile/reports/memfd-brief-revision-2026-10-03/README.md). No source/config/guidance/target identity changed and no phase was executed by this revision.

The selected paths form one eligibility protocol: inode seal state controls admission, mappings retain capabilities, owned tokens arbitrate WRITE exclusion, and ordinary revocation retains ownership through translation completion. Select this protocol for bounded contract verification and implementation trace correspondence. Keep locks, RMW semantics, pending owners, retained MAY permissions and operation-specific error effects faithful to the source. The revised [modeling brief](modeling-brief.md) supplies scenarios, state boundaries, properties, trace requirements and stage decisions.

The Model-Checkable Findings list remains empty because selecting a verification target is not evidence of a new defect. The former rule requiring a new contradictory witness before any modeling is superseded. TV-1/AST-73 and TV-2/AST-75 remain source leads with runtime NOT_RUN. Keep their deterministic tests and source-faithful compatibility checks separate from protocol properties whose exploration they could otherwise terminate early. Known failures must remain visible, attributable and classified. Do not repair the modeled implementation or relax an oracle merely to obtain a passing result.

Analysis review decides whether the selected protocol and contracts are coherent. Spec review decides whether abstractions, assumptions and finite bounds are justified. Trace/model validation decides whether implementation correspondence and property results are supported. Completion requires the applicable artifacts, reviews and dispositions, and can report zero new bugs. The unchanged exclusions in §1 and negative resolutions in §6 remain in effect.
