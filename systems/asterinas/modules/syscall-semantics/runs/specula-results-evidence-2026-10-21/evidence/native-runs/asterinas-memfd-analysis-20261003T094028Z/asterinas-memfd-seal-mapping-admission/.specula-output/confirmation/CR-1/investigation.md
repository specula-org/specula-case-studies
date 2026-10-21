# CR-1 Investigation (Phase 1 — evidence only)

Finding: **CR-1 "Overlapping FUTURE_WRITE publication may misclassify mapping write eligibility"**
Source: **Code Review** (scenario 2). MC hunt configs `MC_hunt_scenario2.cfg` (6,466 states, depth 88) and
`MC_hunt_scenario2_default_seal.cfg` (1,984 states, depth 84) both returned **no violation** — this finding has
**no counterexample**; per the skill it is code-review-sourced.

Hypothesis under test: a `F_ADD_SEALS(F_SEAL_FUTURE_WRITE)` publication overlapping (i) mmap admission or
(ii) an old mapping's mprotect can (a) let a NEW mapping acquire forbidden write access, or (b) wrongly strip a
PRE-EXISTING mapping's retained eligibility.

## Step 1: Code audit (facts, base commit 0c60537098f4c2949ad2d382aaf499de72263d76)

### Eligibility-check side (mmap admission)

`sys_mmap` (kernel/core/src/syscall/mmap.rs:95-148): builds `vm_may_perms = ALL_MAY_PERMS`; for `MAP_SHARED`
on a non-writable fd: requests `PROT_WRITE` → EACCES, else `MAY_WRITE` removed. A writable fd keeps
`MAY_WRITE`. Then `VmarMapOptions::build` (kernel/core/src/vm/vmar/vmar_impls/map.rs:264-455) runs the whole
admission under the **VMAR write lock**; for a memfd (downcast at map.rs:341-345) it calls
`MemfdInode::check_writable(perms, &mut may_perms)` (map.rs:346), then constructs
`MappedVmo::new(vmo, off, is_writable_tracked)` (map.rs:355) where `is_writable_tracked` was decided by the
**pre-check** `may_perms.contains(MAY_WRITE)` (map.rs:341-352). `MappedVmo::new` performs the
`WritableMappingStatus::map()` RMW only when `is_writable_tracked`
(kernel/core/src/vm/vmar/vm_mapping.rs:1125-1128).

`MemfdInode::check_writable` (kernel/core/src/fs/fs_impls/ramfs/memfd.rs:149-180) locks the **same seals
`Mutex<FileSeals>`** used by `add_seals`: if `seals & (F_SEAL_WRITE|F_SEAL_FUTURE_WRITE)` and the request has
`WRITE` → EPERM; else `MAY_WRITE` is stripped from `may_perms`. Comment cites Linux v6.16.5 mm/memfd.c#L356
(`check_write_seal` / `memfd_check_seals_mmap`).

### Publication side (fcntl F_ADD_SEALS)

`handle_addseal` (kernel/core/src/syscall/fcntl.rs:208-218) → `MemfdInode::add_seals`
(memfd.rs:46-89): holds the seals mutex for the entire operation: F_SEAL_SEAL check → (new seals contain
`F_SEAL_WRITE` only) `page_cache.writable_mapping_status().deny()` (memfd.rs:95) — an atomic RMW
`v<=0 ? -1 : EBUSY` (kernel/core/src/vm/page_cache/vmo/mod.rs:1222-1251) → then publishes
`*seals |= new_seals` (memfd.rs:99-102). **`F_SEAL_FUTURE_WRITE` publication touches no counter and no
existing mapping record.**

### Arbitration surface (WritableMappingStatus, vmo/mod.rs:1187-1267)

`AtomicIsize`: >0 = active tracked mappings; 0 = none, allowed; -1 = denied. Methods: `map()` (+1, EPERM if
v<0), `deny()` (v<=0 → -1 else EBUSY), `increment()`/`decrement()` (split/fork/drop+merge,
vm_mapping.rs:1209-1211, 1225-1227). Exactly one caller each: `map()` ← MappedVmo::new; `deny()` ←
add_seals(F_SEAL_WRITE); increment/decrement ← MappedVmo dup/drop.

### Upgrade side (mprotect)

`sys_mprotect` (kernel/core/src/syscall/mprotect.rs:16-58) → `Vmar::protect`
(kernel/core/src/vm/vmar/vmar_impls/protect.rs:26-136): under the **VMAR write lock**, per mapping:
`new_perms = perms | (vm_mapping_perms & ALL_MAY_PERMS)` (protect.rs:56) then `VmPerms::check()`
(kernel/core/src/vm/perms.rs:35-44) requires `WRITE ⊆ MAY_WRITE`. **mprotect never consults the seals or the
counter** — eligibility is frozen per-mapping at admission (stored may-bits). Write page faults gate only on
stored mapping perms (`check_perms_for_page_fault`, vm_mapping.rs), also never re-checking seals — mirroring
Linux.

### Lock protocol / serialization argument (recorded, not judged)

1. Eligibility check (`check_writable`) and publication (`*seals |= new_seals`, deny()) execute under the
   same `seals` mutex → totally ordered per admission. Whichever order materializes yields one of the two
   doctrine-legal outcomes: check-before-publish → eligibility retained for that mapping (the finding itself
   concedes "a mapping returning after the seal may legally have checked eligibility before it"); publish-
   before-check → PROT_WRITE rejected / MAY_WRITE stripped.
2. `VmMapping.perms` (including MAY bits) is set once at `VmMapping::new` (map.rs:395,
   `perms | may_perms`) and never modified by the seal side. `protect()` preserves the may-bits
   (protect.rs:56); `MappedVmo` dup copies `is_writable_tracked` (vm_mapping.rs:1213-1218); merges
   (`insert_try_merge`, vmar_impls/mod.rs:288-340) only combine compatible mappings.
3. Within one address space, mmap admission and mprotect serialize on the VMAR write lock; cross-process
   effects go only through the per-inode seals mutex and the per-VMO counter, neither of which stores any
   per-mapping capability state.
4. Counter RMWs are `Ordering::Relaxed` but all on a single location (atomically serializing
   map()/deny()/increment()/decrement() pairs); cross-variable publication coherence is supplied by the
   seals mutex (check_writable reads `seals` inside the critical section; deny() runs inside the same
   critical section of add_seals).
5. Post-publication `PROT_WRITE mmap` → `check_writable` EPERM (seals contain FUTURE_WRITE per
   memfd.rs:159-162). Post-publication `PROT_READ mmap` + later upgrade → `MAY_WRITE` stripped at admission
   (memfd.rs:163-165) → mprotect fails `VmPerms::check` EACCES. Under-blocking (harm a) would require the
   admission check to miss already-published seals (excluded by (1)) or mprotect to grant WRITE without
   MAY_WRITE (excluded by VmPerms::check). Stripping (harm b) would require the seal path to modify an
   existing mapping's stored perms (nothing does: (2)).
6. In-flight overlap with `F_SEAL_WRITE` deny (admission passed check_writable pre-publication but
   `MappedVmo::new`'s `map()` RMW observes -1 → mmap EPERM) is over-rejection, not harm (a)/(b); the finding
   assigns that surface (retained/over-counted tracking) to MC-1 (TV-1b), which is out of scope here.

### Reference contract (Linux)

Linux v6.16.5 `memfd_check_seals_mmap` (mm/memfd.c:336-370, cached in evidence/linux-v6.16.5) reads
`*seals_ptr` **locklessly** while publication happens under `inode_lock` — the same overlap exists in the
reference kernel and is accepted: F_SEAL_FUTURE_WRITE affects *future admissions only* and pre-existing
mappings keep `VM_MAYWRITE`; mprotect gates purely on `VM_MAYWRITE`. Asterinas mirrors this doctrine
(check_writable ↔ check_write_seal; MAY_WRITE ↔ VM_MAYWRITE), with a strictly *stronger* check side (its
check is under the publication mutex, Linux's is not).

### Trigger scenario (constructed for Phase 2)

Threads A (mmap/mprotect) and B (fcntl F_ADD_SEALS F_SEAL_FUTURE_WRITE) on one memfd, plus barriers that
pin mappings provably before/after publication. Violation would manifest as: (a) a mapping provably admitted
after publication nonetheless becoming PROT_WRITE-upgradable; (b) a mapping provably admitted before
publication losing upgradability (mprotect EACCES or failing writes), including while mprotect churns
concurrently with the publication. MC bounds excluded: >2 syscall threads (two sealers vs mapper),
counter churn through map/unmap, and interleavings beyond 2 threads/3 page slots/6 owner IDs.

### Call chain (entry points → cited code, all reachable from public syscalls)

- `sys_fcntl(F_ADD_SEALS)` → `handle_addseal` → `InodeHandle::add_seals` → `MemfdInode::add_seals` [memfd.rs:46]
- `sys_mmap(MAP_SHARED)` → `VmarMapOptions::mappable/build` [map.rs:237,264] → `check_writable` [map.rs:346],
  `MappedVmo::new` [map.rs:355] → `WritableMappingStatus::map` [vmo/mod.rs:1207]
- `sys_mprotect` → `Vmar::protect` [protect.rs:26] → `VmMapping::protect` [vm_mapping.rs:966] +
  `VmPerms::check` [perms.rs:35]

## Step 2: Developer knowledge (evidence, not classification)

- Seal feature landed via **PR #2408 "Support sealing memfd files"** (5 commits incl. `Add MemfdInode`,
  `Count writable mappings of each MemfdInode's VMO`, `Support sealing memfd files`), merged 2025-11-04,
  base of worktree HEAD lineage; issue #2214 and #2407 (writable-mapping MAYWRITE tracking).
- PR-#2408 author (vvvsv) on design: *"Since the 'shared maywrite' property of a mapping does not change
  during its lifetime, it is sufficient to check it only once at the time of mmap. There is no need to
  recheck it during unmap, split, merge or other operations."* — eligibility-at-admission is a stated,
  deliberate design decision.
- Reviewer lrh2000 forced the mmap check to match Linux F_SEAL_FUTURE_WRITE semantics: *"This
  implementation is incorrect. Please search 'mm: Add an F_SEAL_FUTURE_WRITE seal to memfd' and understand
  the Linux's behavior first."* — conformance with the upstream contract is a design requirement.
- Reviewer lrh2000 question on the counter's memory ordering (*"Since you're using Acquire/Release/AcqRel,
  please tell me which other variables do you want to synchronize..."*) and cchanging: *"Could we just fix
  the deny value to -1?"* (implemented: deny → -1) — the merged RMW uses Relaxed on a single location.
- cchanging review thread on dropping counts in `VmarInner::drop` and merge efficiency — unbalanced
  increment/decrement pairs are deliberate (mirroring Linux include/linux/fs.h i_mmap_writable counting).
- **No discussion anywhere anticipates, acknowledges, or fixes a FUTURE_WRITE-publication/mmap-admission
  overlap defect.** Copilot review comments only suggest generic increment/decrement self-checks (not merged
  as hard checks).
- Tests enabled by the feature: gvisor `memfd_test` subset (test/src/syscall/gvisor/blocklists/memfd_test
  in PR; worktree has test tree with initramfs-based tests). Existing gvisor memfd tests assert basic seal
  EPERM/EBUSY behavior, not the overlap ordering hypothesized here.

## Step 3: Known-status / precedent — prior-report search (2026-10-03, upstream + tracker)

Searches performed:
1. GitHub API `repo:asterinas/asterinas FUTURE_WRITE in:title,body` → 0 results.
2. GitHub API `repo:asterinas/asterinas memfd seal race` → #2798, #2555 (pseudo-Path / FileLike-inode PRs;
   unrelated mechanism).
3. GitHub API `repo:asterinas/asterinas memfd in:title` → PRs #3481 (open: "Fix inode append and memfd seal
   races" — O_APPEND/size()/fallocate TOCTOU in **write/resize paths**, different mechanism & site),
   #3372 (errno for long name), #2634, #2408 (the feature), #2521, #2149.
4. GitHub API `repo:asterinas/asterinas seal|sealing in:title` → #3481, #2408 only.
5. Web search (asterinas memfd F_SEAL_FUTURE_WRITE race / seal mmap admission eligibility) → no
   tracker report of an admission-overlap misclassification; the adjacent items are: LWN "permit
   write-sealed memfd read-only shared mappings" (Linux F_SEAL_WRITE RO-admission semantics, the MC-1
   surface), Linux stable patch "mm: memfd: deny writeable mappings when implying SEAL_EXEC" (intra-syscall
   ordering inside memfd_add_seals, different mechanism), Asterinas issue #2937 (page-cache refactor TODO
   mentioning the WritableMappingStatus field), #2917 (protect merge unwrap panic, fixed elsewhere), #3257
   (Vmo::write lock ordering, write-syscall path).
6. Analysis-run prior artifacts (evidence/issues-a.md, issues-b.md, open-pr-audit.md — issue audits covering
   105 open PRs and historical issues) list no report matching this mechanism; #3481 is dispositioned
   there as "other operation or excluded mechanism".

**Result: no existing issue/PR/CVE/advisory reports OR fixes the FUTURE_WRITE-publication ×
mmap-admission/mprotect overlap mechanism.** Nothing in the merged-per-PR git history since the feature
landed (0c605370 lineage) modifies the admission/eligibility protocol. → Novelty: **NEW** (if a defect is
real). The code-review × known-drop pre-filter does not apply → proceed to Phase 2.

## Reproduction plan (ladder)

Level 0 (black-box, public syscalls, pthreads, deterministic + racy variants):
- I-A no-forbidden-new-access: mappings provably post-publication (`F_SEAL_FUTURE_WRITE` observed by the
  same thread ordering) must reject PROT_WRITE mmap (EPERM) and refuse upgrades (EACCES); write(2) EPERM.
- I-B retained eligibility: mapping provably pre-publication keeps mprotect(PROT_WRITE) success and
  working writes, across publication and with concurrent mprotect churn (harm b direct probe).
- I-C overlap window: racing mmap/fcntl rounds + two-sealer (3-thread) extension beyond MC bounds; assert
  invariants + absence of panics; classify each admitted mapping provably pre/post.
Level 1: add timing assists (affinity pinning, spin delays around the admission window, repeated rounds).
Level 2/3: only if needed, with reachability-cited injections (not anticipated for this protocol).
Run the same binary on the Asterinas guest (osdk-built initramfs, KVM) and natively on Linux as contract
baseline; divergences from the Linux baseline on protected invariants = evidence for the finding.

---

# Phase 2: Reproduction record (verdict decided from this + Phase 1)

Test: `repro/test_bugCR-1_future_write_overlap.c` (self-contained C, public syscalls only:
memfd_create/ftruncate/fcntl(F_ADD_SEALS,F_GET_SEALS)/mmap/mprotect/munmap/write, pthreads).
Arms: S1 deterministic core; S2 2-thread racing window (100 rounds); S3 4-thread extension
(2 mappers + 2 sealers, 60 rounds — beyond the MC two-syscall-thread bound); S4 combined
WRITE+FUTURE_WRITE publication; S5 mprotect churn on pre-seal mappings during publication;
S6a Level-1 burst admissions + continuous re-publication (200 rounds); S6b split/merge churn
via partial mprotect during publication. Bucket classification via F_GET_SEALS observed in
the same thread immediately before each mmap (authoritative: both syscalls take the
MemfdInode seals mutex).

Environment: Asterinas guest built from this worktree (base 0c605370, Specula
instrumentation, `cargo osdk build/run --scheme specula_memfd`, KVM, initramfs init) in
docker image asterinas/dev:0.18.1-20260926; same binary run natively on Linux (host
7.2.8 + container) as the reference-contract baseline. Logs preserved in
`repro-build/guest-l0l1-final.log`, `guest-l3-patched.log`, `linux-final.log`,
`linux-l1.log`.

## Escalation ladder

- **Level 0 (black-box)**: guest run 1 — S1: pre-seal mapping keeps eligibility (200
  upgrade/store/downgrade cycles post-publication); post-seal PROT_READ admission refuses
  upgrade (EACCES=13); PROT_WRITE mmap EPERM; write(2) EPERM; seals=0x10. S2/S3 racing
  arms crossed the publication window naturally (both legal outcome buckets populated:
  mid-window upgraded_ok + upgraded_fail). No harm (a), no harm (b), no torn state.
- **Level 1 (timing assistance)**: best-effort CPU pinning, swept spin delays,
  burst-admission rounds with continuous idempotent re-publication (keeps the publication
  critical section hot), split/merge churn. Guest run 2 (stop-flag fix, full volume):
  14,816 post-publication read-only admissions — all refused upgrade; 14,880 PROT_WRITE
  mmaps — all EPERM; 52 genuine window crossings (upgraded_fail) — all correctly
  classified; 16,000 churn iterations + 4,000 split/merge cycles — eligibility never lost.
  Linux baselines identical (no divergence on any protected invariant; no false triggers
  on the reference kernel).
- **Level 2 (state injection)**: not performed — no meaningful injection exists. Every
  eligibility state the hypothesis concerns (mapping with/without retained MAY_WRITE vs
  published/unpublished seal) is produced by real-API sequences that the arms already
  exercise; there is no reachable-but-untriggered pre-condition to inject, and injecting
  an unreachable one (e.g., MAY_WRITE granted post-publication) would be unsound.
- **Level 3 (kernel timing patch)**: minimal timing-only patch in
  `kernel/core/src/fs/fs_impls/ramfs/memfd.rs` — 30,000-iteration spin inside
  `add_seals`' critical section immediately before `*seals |= new_seals`, and a
  10,000-iteration spin inside `check_writable` after the seals read (no logic change;
  documented precisely; reverted after the run — worktree diff restored to the
  instrumentation baseline, verified `grep -c CR1-L3 == 0` and diff-stat match). Guest
  run 3 with the widened windows: 14,855 post-publication admissions all stripped;
  14,937 PROT_WRITE mmaps all EPERM; 52 window crossings all correct; eligibility never
  lost. Log: `repro-build/guest-l3-patched.log`.

## Observed divergences (recorded, not CR-1's mechanism)

- S4 `ro-admit-EPERM=4800`: after a combined WRITE|FUTURE_WRITE publication, read-only
  shared mmap through the O_RDWR fd fails EPERM on Asterinas where Linux admits it. This
  is the MC-1 tracking-retention surface (is_writable_tracked decided from pre-check
  may_perms at map.rs:341-352 → MappedVmo::new counter map() at -1 → EPERM). It is
  over-rejection of an admission, not a capability misclassification, and the finding
  itself assigns it to MC-1.
- S4 control: F_ADD_SEALS(WRITE|FUTURE_WRITE) with a live upgradable mapping returns
  EBUSY on both kernels (correct exclusion).

## Ladder conclusion

All levels exhausted with genuine window crossings (hundreds across runs, forced wide at
Level 3) and tens of thousands of classified admissions. No harm (a), no harm (b), no
torn state, no panic, no control mismatch — on the Asterinas guest and on the Linux
reference. Combined with the Phase-1 structural analysis (single-mutex serialization of
check-vs-publish; per-mapping capability bits frozen at admission and never touched by
the seal side; mprotect gating only on those bits; counter untouched by FUTURE_WRITE
publication), the hypothesized misclassification cannot occur.
