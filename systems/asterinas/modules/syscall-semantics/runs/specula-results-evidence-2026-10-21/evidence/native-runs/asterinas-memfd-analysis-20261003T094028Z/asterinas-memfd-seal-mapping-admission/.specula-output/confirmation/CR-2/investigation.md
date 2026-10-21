# CR-2 Investigation (Phase 1 — evidence only)

Finding: "Mapping ownership may not survive split, merge, protection and unmap
transitions" (code-review source; Scenario 3 "Ownership survives representation
changes and revocation"; severity High). BMC (MC_hunt_scenario3.cfg) exhausted
32,382 states to depth 157 with no violation, so this is a code-review-sourced
finding and confirmation must look for lifetime defects outside the modeled
bounds or abstraction.

## Step 1: Code audit

### The write-eligibility counter protocol

`WritableMappingStatus` (kernel/core/src/vm/page_cache/vmo/mod.rs:1193-1273) is
an `AtomicIsize` on the memfd's page-cache VMO: positive = number of active
writable(-eligible) mappings, 0 = none and allowed, -1 = denied.

- `map()` (mod.rs:1202) — called from `MappedVmo::new` (vm_mapping.rs:1125) —
  increments, fails EPERM if negative. Reached from mmap admission
  (vmar_impls/map.rs:341-363) only when `is_writable_tracked` is true.
- `deny()` (mod.rs:1233) — called from `MemfdInode::add_seals`
  (fs/fs_impls/ramfs/memfd.rs:88-91) when F_SEAL_WRITE is being added — sets -1,
  fails EBUSY if positive. Atomic RMW, so it serializes against map/increment/
  decrement without any lock coupling with the VMAR lock.
- `increment()` / `decrement()` (mod.rs:1255-1272) — called from
  `MappedVmo::dup_at_offset` (vm_mapping.rs:1209) and `MappedVmo::drop`
  (vm_mapping.rs:1222) respectively, gated by `is_writable_tracked`.

`is_writable_tracked` is decided once at mmap time (vmar_impls/map.rs:341-355):
memfd inode && MAP_SHARED && `may_perms` contains MAY_WRITE (i.e. a writable
FD). `MemfdInode::check_writable` (memfd.rs:151-190) may then strip MAY_WRITE
(when F_SEAL_WRITE|F_SEAL_FUTURE_WRITE is set) or reject PROT_WRITE with EPERM,
but tracked-ness stays. After admission, the flag is only ever copied
(`dup_at_offset`, `..self` moves); no transition adds or removes it.

### Transition-by-transition accounting (all audited in the worktree)

- `VmMapping::split(self, at)` (vm_mapping.rs:742-805): the right piece gets
  `mapped_mem.dup_at_offset(left_size)` (+1 when tracked); the left piece MOVES
  the original `MappedVmo` (no +1, no drop). One owner before, two owners after.
  Balanced.
- `VmMapping::split_range` (vm_mapping.rs:808-875): composes `split`; each
  split point adds exactly one dup. Balanced.
- `try_merge` (vm_mapping.rs:1250-1345): the merged mapping gets
  `l_vmo_obj.dup()` (+1); both inputs are then dropped by the caller
  (`try_merge_with` drops `self`, vm_mapping.rs:905-921;
  `insert_try_merge` removes and drops the tree neighbor,
  vmar_impls/mod.rs:292-324). Two owners before, one after. Balanced.
- `VmMapping::protect` (vm_mapping.rs:966-1050): `Self { perms, ..self }` — the
  owner MOVES, `is_writable_tracked` unchanged, may-bits preserved by
  `new_perms = perms | (mapping & ALL_MAY_PERMS)` (protect.rs:75). No counting
  change. Hardware: for non-device mappings PTEs are set to
  `PageFlags::from(perms) - PageFlags::W`, so W is revoked in hardware while
  the count is retained — matches Linux, where VM_MAYWRITE (and thus
  i_mmap_writable) survives mprotect.
- `VmMapping::unmap(self, vm_space)` (vm_mapping.rs:931-964): PTE unmap ->
  `dispatch_tlb_flush()` -> `sync_tlb_flush()` -> return -> `self` (and its
  MappedVmo) dropped at scope exit -> decrement. The final eligible owner is
  released strictly AFTER ordinary PTE/TLB revocation completes, so a
  concurrent F_SEAL_WRITE that observes count==0 cannot race stale write PTEs
  from munmap. Correct ordering.
- `Vmar::remove_mapping`/`alloc_free_region_exact_truncate`
  (vmar_impls/mod.rs:391-461, unmap.rs:47-57): remove -> split_range ->
  re-insert survivors (`insert_without_try_merge`) -> `taken.unmap()` (drop
  after TLB sync). Survivors keep their owners; the taken piece's drop is
  ordered after TLB sync. Balanced.
- `Vmar::protect` loop (protect.rs:17-160): snapshot (range, perms) first;
  per mapping: remove -> split_range -> re-insert left/right -> protect taken ->
  `insert_try_merge` (may merge with neighbors whose perms now match). The
  let-else at protect.rs:96-108 skips snapshot entries already merged into a
  protected neighbor (upstream issue #2917's panic is fixed here). Merge
  accounting balanced as above.
- `fork` (fork.rs:41 `new_fork` -> `MappedMemory::dup` +1; parent keeps
  original) and `remap` (remap.rs: `clone_for_remap_at` dup +1, old owner
  dropped after `move_pt` TLB sync) are balanced too, but fork/exec/exit and
  mremap are excluded from this target's scope.
- `Vmar::clear` (unmap.rs:16-33) drops all mappings BEFORE unmapping page
  tables and syncing the TLB — the one place where the counter can reach 0
  before hardware revocation. It is reachable only from `dec_num_handles`
  (vmar_impls/mod.rs:113-121) when the last VMAR handle is dropped, i.e.
  process exit/exec — excluded from scope per the target brief
  ("fork/exec/exit" excluded). Recorded as an out-of-scope observation.

### Why eligible and non-eligible mappings cannot merge

`try_merge` requires `left.perms == right.perms` where the stored perms include
the MAY bits (VmMapping::new is called with `perms | may_perms`,
vmar_impls/map.rs:371-379), plus same VMO (`Arc::ptr_eq`), same map_mode, and
contiguous offsets. For memfd shared mappings, MAY_WRITE presence in perms
coincides exactly with `is_writable_tracked` (MAY bits are never added or
removed after admission; mprotect only ORs). So a tracked mapping can never
merge with an untracked one; the dup-then-drop-both merge accounting can never
lose or double the count across an eligibility boundary.

### Entry/exit protocol soundness under concurrency

mmap admission: `check_writable` (seals mutex) then `MappedVmo::new` ->
`map()` (atomic). F_ADD_SEALS: `deny()` (atomic) under the seals mutex. The
RMWs serialize: either map-then-deny (deny sees >0 -> EBUSY, seal fails) or
deny-then-map (map sees -1 -> EPERM, mmap fails). munmap: decrement strictly
after TLB sync, so deny observing 0 implies revocation completed. No lock
coupling is needed and none exists.

### Reachability and trigger scenario

All in-scope transitions are reachable from plain user-space syscalls on one
memfd: mmap (MAP_SHARED, writable FD) creates a tracked mapping; mprotect on a
 subrange splits it; mprotect back can merge pieces; munmap on a subrange
 splits and drops pieces; fcntl(F_ADD_SEALS, F_SEAL_WRITE) observes the
 counter (EBUSY vs success). The observable oracle for a counting defect is:
 F_SEAL_WRITE must return EBUSY iff at least one live write-eligible mapping
 exists (eligibility fixed at mmap time), and a successful seal must leave no
 writable path into the file. A counter leak shows as a false EBUSY after all
 mappings are gone; an undercount shows as a successful seal while an eligible
 mapping remains, after which writes through that mapping would modify a
 WRITE-sealed file (the NO-STALE-ACCESS harm).

### Adjacent divergences found during the audit (NOT this finding's mechanism)

Recorded because they are the known Asterinas-vs-Linux differences in this
area, established by the prior harness corpus (harness/INSTRUMENTATION.md,
harness/src/scenarios.c, completed run: Asterinas 426 assertions, Linux 427):

- TV-1a: after F_SEAL_WRITE, mmap(PROT_READ, MAP_SHARED) through the still
  writable FD fails EPERM on Asterinas; Linux v6.16 allows it
  (`memfd_check_seals_mmap`/`check_write_seal` strips VM_MAYWRITE instead of
  rejecting, mm/memfd.c). Admission-time behavior.
- TV-1b: after F_SEAL_FUTURE_WRITE, a new PROT_READ shared mapping is still
  counted by Asterinas (`is_writable_tracked` is computed from MAY_WRITE
  BEFORE `check_writable` strips it, vmar_impls/map.rs:341-355), so a later
  F_SEAL_WRITE fails EBUSY; Linux strips VM_MAYWRITE at mmap
  (mm/memfd.c check_write_seal) so i_mmap_writable never increments and the
  seal succeeds. Admission-time classification, no transition involved.
- TV-2: a rejected MAP_FIXED replacement truncates the old mappings on
  Asterinas before the seal check fails (alloc_free_region_exact_truncate runs
  before check_writable); Linux leaves them. Failure-atomicity of rejected
  admission.

These belong to admission/failure-atomicity scenarios, not to CR-2's
split/merge/protect/unmap ownership mechanism. CR-2's verdict below is about
the transitions only.

### Linux reference semantics (v6.16.5, verified from source)

- mm/vma.c `__vma_link_file`: `if (vma_is_shared_maywrite(vma))
  mapping_allow_writable(mapping)` — increment iff VM_SHARED && VM_MAYWRITE at
  link time; `__remove_shared_vm_struct` decrements under the same condition.
- include/linux/mm.h: `is_shared_maywrite(vm_flags)` = both VM_SHARED and
  VM_MAYWRITE set. include/linux/fs.h: i_mmap_writable = "Number of
  VM_SHARED, VM_MAYWRITE mappings"; comment: "the file was opened for writing
  i.e. vma may be mprotected writable even if now readonly";
  `mapping_writably_mapped` > 0 blocks F_SEAL_WRITE (EBUSY);
  `mapping_deny_writable` = atomic_dec_unless_positive.
- mm/mmap.c do_mmap: VM_MAYWRITE granted from the writable FD, then
  `memfd_check_seals_mmap` strips it for new read-only shared mappings of
  write-sealed memfds; PROT_WRITE shared of a sealed memfd -> EPERM.
- So Linux's counting rule equals Asterinas's, modulo the TV-1b admission
  classification difference above. VMA split/merge in Linux preserves the
  count exactly as Asterinas's VmMapping split/merge does.

## Step 2: Developer knowledge

- Commit d1506171d (2025-11-01) "Count writable mappings of each
  MemfdInode's VMO" introduced the counter; commit 6ba1a84ae (2025-10-30,
  PR #2408) "Support sealing memfd files" introduced F_ADD_SEALS/F_GET_SEALS.
  No commit message states an accepted trade-off about transition lifetimes.
- Upstream tracker (searched issues AND merged/closed PRs, Jan 2026 - now):
  - #2917 "Reachable unwrap panic in vmar protect when merging mappings"
    (closed) — fixed in this tree by the let-else at protect.rs:96-108.
  - #2209 "Integer Underflow in vm_mapping::try_merge on mmap with inverted
    file offsets" (closed) — fixed; current `try_merge` checks offset
    contiguity without underflow.
  - #682 "Vmar::get_vm_mapping may return a dead Arc<VmMapping>" (closed) —
    old architecture; mappings are now owned by the interval tree.
  - PR #2926 "Fix permission validation in mprotect and mmap" (merged
    2026-01-28) — added the `new_perms.check()` MAY-bit validation present in
    this tree.
  - No issue or PR reports the writable-mapping counter misbehaving across
    split/merge/protect/unmap, and none reports a false EBUSY or a seal with
    stale write access from these transitions.
- The prior harness corpus (harness/src/scenarios.c, completed run) already
  exercised a split-merge-flush transition sequence with COMMON (identical)
  Linux/Asterinas expectations and Asterinas passed it; the divergences it
  preserved (TV-1a/TV-1b/TV-2) are all admission/atomicity behaviors, not
  transition counting.

## Step 3: Known-status / precedent

No existing issue/PR/CVE/advisory or prior dataset entry reports THIS
mechanism (writable-eligibility ownership across split/merge/protect/unmap
transitions of the memfd seal protocol) at these sites. The three saved issues
in the finding (#2917/#2209/#682) are different defects at nearby code and are
fixed in this tree. Novelty: NEW (tracker search covered open and recently
merged/closed items). Not dropped — proceeds to Phase 2.

## Phase 2: Reproduction (per phases/02-reproduction.md)

Test: `repro/test_bugCR-2_seal_ownership_lifecycle.c` (self-contained C,
gcc -O2 -static -pthread).  The same binary runs as the host Linux reference
(7.2.8) and as `/scenarios` in the Asterinas guest (uname "5.13.0") booted
from the known-good harness recipe (Docker image asterinas/dev:0.18.1-20260926,
/dev/kvm, osdk scheme specula_memfd, incremental kernel build reusing the
harness cache; script: confirmation/CR-2/guest-run.sh).

Coverage (identical op streams on both systems; the known admission-side
divergences TV-1a/TV-1b/TV-2 are excluded by construction):

- SEQ1 partial munmap split; SEQ2 protect-split / re-split / merge-back with
  per-page unmap zero-crossing; SEQ3 two separately-mmap'd pieces merged by
  protect; SEQ4 mixed eligibility (O_RDWR vs O_RDONLY fds, adjacent) incl.
  seal-must-SUCCEED while an ineligible mapping lives; SEQ5 downgrade retains
  blocking + upgrade; SEQ6 MAP_FIXED interior replacement (truncate +
  re-admission); SEQ7 protect across a hole.
- STRESS: 24 rounds of deterministic LCG-driven op mixes (munmap / mprotect
  R<->RW / MAP_FIXED re-admission) over the 4-page window with the seal oracle
  probed after EVERY operation: EBUSY iff >=1 eligible page live, success
  exactly at the zero crossing.
- L1 (timing): 48 rounds, 3 threads — racing writer (SIGSEGV-recovered store
  loop), sealer (F_ADD_SEALS retry), main (final munmap); asserts legal
  outcomes, post-join sealability, final WRITE-sealed state.

Escalation ladder:

- Level 0 (black-box syscalls): PASS on Linux 7.2.8 (627/627 checks) and on
  Asterinas (627/627, two full guest runs).  The normalized serial outputs of
  the guest runs are line-for-line identical to the Linux reference (the only
  diff is the guest init marker SPECULA_TEST_EXIT).  No false EBUSY (no
  counter leak), no premature seal success (no undercount; the harm probe
  never fired), no observable divergence of the F_SEAL_WRITE contract through
  any transition.
- Level 1 (timing assistance): PASS — 48+48 race rounds on Asterinas and
  Linux; every round ended in a legal outcome (seal succeeded after the
  unmap; every memfd ended WRITE-sealed; 46/48 rounds carried >1000
  concurrent writes through the mapping while the seal raced the unmap).
  Limitation recorded: without kernel-side timestamps the race cannot
  precisely order the writer's last store against deny(); that ordering claim
  is instead proven structurally by the code-order audit (decrement strictly
  after sync_tlb_flush in VmMapping::unmap) and was replayed by the prior
  harness trace corpus.
- Levels 2/3 (state injection / source patch): not escalated to — nothing
  failed at Levels 0/1, the mechanism is deterministic (a fixed code order,
  not a race), and no reachable pre-condition exists that the Level-0 stress
  battery (which enumerates the syscall-reachable transition space with a
  probe after every step) does not already cover.  Injecting an unreachable
  counter state would fabricate, not reproduce, a violation.

Evidence files:

- confirmation/CR-2/logs/guest_run1.log, guest.log (run 2), guest-exit.txt,
  kernel-build.log, osdk-build.log
- repro/linux_ref_run.log, repro/test_bugCR-2_linux_ref (binary)

Verdict (from the decision table, investigation + reproduction together):
FALSE POSITIVE — the hypothesized defect does not exist.  MappedVmo ownership
is conserved exactly across split / try_merge / protect / unmap
(insert_try_merge, alloc_free_region_exact_truncate), the final eligible
owner is released strictly after ordinary PTE/TLB revocation completes, the
deny/map atomic protocol admits no undercount window, and the Linux-visible
F_SEAL_WRITE EBUSY-vs-success contract holds through every exercised
transition interleaving on the real kernel.  The adjacent admission-side
divergences (TV-1a/TV-1b/TV-2) are different mechanisms at different sites
and are out of this finding's scope (handled elsewhere).
