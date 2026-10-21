# MC-1 Investigation record (Phase 1 — evidence only)

Finding: **Post-seal read-only mappings retain writable accounting** (MC-1)
Source: model checking, counterexample `spec/output/validation/MC_hunt_scenario1.out`,
invariant `ReadOnlyAdmissionCompatibility`, config `MC_hunt_scenario1.cfg`.
Source commit: 0c60537098f4c2949ad2d382aaf499de72263d76 (worktree = same commit + trace-only
instrumentation whose semantics are unchanged; verified by diffing every cited file).

## Step 1: Code audit

### Counterexample trace (recorded facts)

The TLC trace (14 states, plan `t1: F_ADD_SEALS{F_SEAL_WRITE}`, `t2: map perms={R} fd=rw
shared=true`) walks: t1 seal_lock → seal_check → deny → publish (seals = {WRITE}, result
OK) → return; t2 fd → vmar_lock → check_writable → mapped_new → vmar_unlock with
**result = EPERM** → return. The violation: after F_SEAL_WRITE, a new shared READ mapping
through the O_RDWR handle is rejected, while the invariant (per the brief, §5 row:
"Post-seal shared READ remains admissible without new write eligibility. At a quiescent
seal attempt, such ineligible maps alone do not cause EBUSY. TV-1 is the known expected
deviation.") requires it to remain admissible.

### Call chain (all verified by reading the code)

1. `sys_mmap` (`kernel/core/src/syscall/mmap.rs:50`, `do_sys_mmap` at :60): computes
   `vm_may_perms = VmPerms::ALL_MAY_PERMS` (:96). For a file-backed MAP_SHARED mapping it
   drops MAY_WRITE **only** if the fd is not opened writable (:130-135). An O_RDWR memfd
   fd keeps `may_perms = {MAY_READ, MAY_WRITE, MAY_EXEC}`; requested `perms = {READ}`.
2. `VmarMapOptions::build` (`kernel/core/src/vm/vmar/vmar_impls/map.rs:246`, tracking
   block at :336-346): the writable-tracking decision is
   `is_writable_tracked = path.inode() is MemfdInode && map_mode.is_shared() &&
   may_perms.contains(MAY_WRITE)` — evaluated **before** the seal check — then calls
   `memfd_inode.check_writable(perms, &mut may_perms)?` and, when the condition held,
   unconditionally keeps `is_writable_tracked = true`.
3. `MemfdInode::check_writable` (`kernel/core/src/fs/fs_impls/ramfs/memfd.rs:77-84`):
   if seals ∩ {F_SEAL_WRITE, F_SEAL_FUTURE_WRITE}: EPERM only when the *requested*
   `perms` contain WRITE; otherwise strips MAY_WRITE from `may_perms` (comment cites
   Linux v6.16.5 mm/memfd.c#L356) and returns Ok.
4. `MappedVmo::new` (`kernel/core/src/vm/vmar/vm_mapping.rs:941-950`): if
   `is_writable_tracked`, calls `vmo.writable_mapping_status().map()?`.
5. `WritableMappingStatus` (`kernel/core/src/vm/page_cache/vmo/mod.rs:1195-1240`):
   AtomicIsize counter; positive = active writable mappings, 0 = none, negative = denied.
   `map()` increments unless negative, else **EPERM**; `deny()` (called by
   `MemfdInode::add_seals` for F_SEAL_WRITE, `memfd.rs:68-70`) sets −1 unless positive,
   else **EBUSY**.
6. `MemfdInode::add_seals` calls `deny()` only for F_SEAL_WRITE, not F_SEAL_FUTURE_WRITE
   (matches Linux `memfd_add_seals`: only F_SEAL_WRITE calls `mapping_deny_writable`).

### Linux v6.16.5 reference contract (fetched from kernel.org)

- `do_mmap` (`mm/mmap.c:492`) calls `memfd_check_seals_mmap` → `check_write_seal`
  (`mm/memfd.c:344-365`): shared + VM_WRITE → EPERM; shared + read-only → clears
  **VM_MAYWRITE** and succeeds. This runs *before* any writable accounting.
- `mmap_region` (`mm/vma.c:2684`) takes the writable count *afterwards*, gated on
  `is_shared_maywrite(vm_flags)` = `VM_SHARED && VM_MAYWRITE`
  (`include/linux/mm.h:841`) → `mapping_map_writable()` EPERM if `i_mmap_writable < 0`
  (`include/linux/fs.h:607`).
- `memfd_add_seals` F_SEAL_WRITE → `mapping_deny_writable()` EBUSY if
  `i_mmap_writable > 0` (`fs.h:618`). The comment at `fs.h:595` states the counting rule:
  "i_mmap_writable counts all VM_SHARED, VM_MAYWRITE vmas".

So Linux decides the accounting from the **post-seal-check** flags; Asterinas decides it
from the **fd-derived pre-check** may_perms and never reconsiders after
`check_writable` strips MAY_WRITE.

### Consequences (deterministic, single-threaded — not a race)

- **Manifestation A** (the MC-1 trace): after F_SEAL_WRITE (counter = −1),
  `mmap(PROT_READ, MAP_SHARED, O_RDWR fd)`: `check_writable` returns Ok and strips
  MAY_WRITE, but `is_writable_tracked = true` → `map()` on a negative counter → **EPERM**.
  Linux: the mmap succeeds (VM_MAYWRITE cleared, no count taken).
- **Manifestation B**: after F_SEAL_FUTURE_WRITE (no `deny()` call, counter = 0), the
  same mmap succeeds but `map()` increments the counter → a semantically read-only
  mapping (MAY_WRITE stripped: `mprotect(PROT_WRITE)` later fails EACCES) is accounted
  as a writable mapping. A subsequent `F_ADD_SEALS(F_SEAL_WRITE)` → `deny()` sees a
  positive counter → **EBUSY** although no mapping holds write eligibility. Linux: no
  count is taken, so the seal succeeds.

### Reachability

Both manifestations are reachable through public syscalls with a fresh memfd and the
original O_RDWR handle — no fork, no threads, no special state. The O_RDONLY-handle
control path never sets `is_writable_tracked` (the syscall layer already removed
MAY_WRITE at `mmap.rs:135`), so the bug is specific to the writable-handle admission
decision.

### Safeguards encountered (recorded, then proven not to mask)

- `check_writable` stripping MAY_WRITE preserves the *mprotect* part of the Linux
  contract (the split/merge lifecycle stays consistent), but nothing reconsiders the
  already-decided `is_writable_tracked`.
- Unmapping the read-only mapping decrements the counter (a user action, not a system
  safeguard), which only restores sealing after the mapping is destroyed; while it
  lives, the false EBUSY persists. No kernel mechanism corrects either wrong errno.

## Step 2: Developer-knowledge search

- Introducing history: `d1506171d` "Count writable mappings of each MemfdInode's VMO"
  (2025-11-01) defined "writable mappings" as "shared mappings that **may include** the
  `PROT_WRITE` permission"; at that time no seal check existed, so fd-derived
  `may_perms` never changed afterward. `6ba1a84ae` "Support sealing memfd files"
  (PR asterinas/asterinas#2408) inserted `check_writable(perms, &mut may_perms)` into the
  same condition but kept `is_writable_tracked = true` from the pre-check value — the
  moment the accounting decision diverged from the post-check semantics.
- PR #2408 description cites the man page: "trying to create new shared, **writable**
  memory-mappings via mmap(2) will also fail with EPERM" and "Using F_ADD_SEALS ...
  fails with EBUSY if any **writable**, shared mapping exists", and says the counting
  follows Linux's fs.h approach. A reviewer sketched `is_writable_tracked =
  "may_write && writable_status exists"` and the final review states the field exists
  "to ensure that only shared may_write mappings are counted". The implemented
  post-seal-read-only accounting contradicts the PR's own written semantics: after
  `check_writable` strips MAY_WRITE the mapping can no longer include PROT_WRITE, yet it
  is still counted (manifestation B) or even rejected outright (manifestation A).
- PR #2444 (merged 2025-09-24, fixing issue #2407) is what introduced the VM_MAYWRITE
  analog (`may_perms`) in the first place: "Shared mappings from read-only file
  descriptors should not be mprotected to read-write".
- No TODO/FIXME/comment near the code acknowledges the divergence. No test in the repo
  covers post-seal read-only shared mmap through a writable handle
  (`test/initramfs/src/regression` only covers F_SEAL_SEAL access-mode errors; the
  gVisor memfd suite enabled by `291c42c9f` does not cover this ordering; LTP memfd
  cases are blocklisted).
- Corroborating upstream-history context: Linux itself once had the same wrong outcome
  (kernel.org bugzilla 217238, 2023, "Creating shared read-only map is denied after add
  write seal to a memfd"; reinstated for good by the 2024
  "mm: reinstate ability to map write-sealed memfd mappings read-only" series). The
  Asterinas code comments cite Linux v6.16.5, where read-only shared mapping of a
  write-sealed memfd succeeds — so the current Linux behavior is the intended contract,
  not a gray area.

## Step 3: Known-status / precedent

- **Upstream tracker search (asterinas/asterinas, issues + PRs, open and closed)**:
  searches for "memfd", "seal", "F_SEAL", "read-only mmap EPERM", "mmap EBUSY" find no
  report of this mechanism. PR #3481 (open, updated 2026-08-28, "Fix inode append and
  memfd seal races") fixes TOCTOU around append writes/resize/fallocate and moves seal
  *write-path* checks under inode locks — a different mechanism at different sites; it
  does not touch the mmap admission accounting. PR #3767/#3372/etc. are unrelated. No
  issue or PR reports post-seal read-only mmap EPERM or the false EBUSY.
- **Upstream fix status**: unfixed — fetched
  `kernel/core/src/vm/vmar/vmar_impls/map.rs` from asterinas/asterinas `main` today:
  the `is_writable_tracked` block (lines 337-349 of the file at main) is byte-for-byte
  the same decision shape as the audited commit.
- **Prior Specula dataset entry**: the run's modeling brief records TV-1 as
  "Post-seal READ shared admission retains writable tracking: WRITE causes EPERM;
  FUTURE_WRITE can cause false EBUSY. Both manifestations share one cause, already
  tracked as **AST-73**" (cross-run catalog; TV-2 is tracked as AST-75). This is the
  same mechanism at the same site, previously recorded — hence the finding is KNOWN.
- Linux bugzilla 217238 is about Linux's own implementation, a different site;
  recorded as intent evidence only, not as the required citation.

**Pre-filter**: not applicable (MC-sourced with an actual counterexample → proceeds to
Phase 2 regardless of known status).

## Verdict inputs carried into Phase 2

- Trigger: two deterministic public-syscall sequences (Case A = the CE steps; Case B =
  the second manifestation), single-threaded.
- Expected (Linux 7.2.8 reference, run in Phase 2): both succeed; fcountries returned.
- Suspected (Asterinas at 0c6053709): Case A mmap → EPERM; Case B F_ADD_SEALS → EBUSY.
- The run's own harness (scenarios.c `tv1a-write-read`/`tv1b-future-read`, guest log of
  2026-10-04) already recorded both deviations on the instrumented guest and Linux
  reference; Phase 2 executes an independent test binary rather than trusting that log.
