# MC-2 Investigation (Phase 1 — evidence only)

Finding: **MC-2 "Seal-rejected fixed replacement removes the existing mapping"**
Source: model checking (actual 31-state counterexample), invariant `SealRejectedReplacement`,
cfg `MC_hunt_TV2.cfg`, CE output `spec/output/validation/MC_hunt_TV2.out`.
Source commit: `0c60537098f4c2949ad2d382aaf499de72263d76` (2026-09-21).

## Step 1 — Code audit

### Cited sites (pristine line numbers at the pinned commit)

- `kernel/core/src/vm/vmar/vmar_impls/map.rs:289-297` — in `VmarMapOptions::build()`, the
  `VmarMapOffset::FixedReplace(map_to_addr)` arm calls
  `inner.alloc_free_region_exact_truncate(parent, map_to_addr, map_size, &mut rss_delta)`
  (call at map.rs:291). This happens **before** any per-file admission check.
- `kernel/core/src/vm/vmar/vmar_impls/mod.rs:377` — `fn alloc_free_region_exact_truncate`:
  for every existing `VmMapping` intersecting the target range it calls `self.remove()`,
  splits the mapping (`split_range`), reinserts the non-intersecting left/right survivors,
  and then `taken.unmap(&vmar.vm_space)` — a **completed** unmap of the intersected part.
- `kernel/core/src/vm/vmar/vm_mapping.rs:830` — `VmMapping::unmap`: `cursor.unmap()` +
  `cursor.flusher().dispatch_tlb_flush()` + `sync_tlb_flush()`, then the taken mapping
  (and its `MappedVmo`, i.e. the memfd writable-mapping owner registration) is dropped.
- `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:80` — `MemfdInode::check_writable` (the
  reject site): if `seals.intersects(F_SEAL_WRITE | F_SEAL_FUTURE_WRITE)` and
  `perms.contains(VmPerms::WRITE)` → `EPERM` ("the file is sealed against writing").
  The seal publication site is `add_seals` (`*seals |= new_seals`, memfd.rs:68); adding
  `F_SEAL_FUTURE_WRITE` has **no** writable-mapping precondition (only `F_SEAL_WRITE`
  calls `page_cache.writable_mapping_status().deny()?`).

### Call chain (public API → bug)

`mmap(2)` (`kernel/core/src/syscall/mmap.rs`) with `MAP_SHARED|MAP_FIXED`, `PROT_READ|PROT_WRITE`,
writable memfd fd → `may_perms` retains `MAY_WRITE` (fd writable) → `VmarMapOffset::FixedReplace`
(mmap.rs:83-87) → `VmarMapOptions::build()`:
1. rlimit re-check that explicitly accounts for the upcoming removal
   ("Overlapping mappings will be removed. Check again after considering this fact.");
2. **`alloc_free_region_exact_truncate`** — old intersecting mappings removed, unmapped,
   TLB flushed, `MappedVmo` owners dropped (map.rs:291 → mod.rs:377 → vm_mapping.rs:830);
3. only then the memfd admission check `memfd_inode.check_writable(perms, &mut may_perms)?`
   (map.rs:353 area) → with `F_SEAL_FUTURE_WRITE` active and `PROT_WRITE` requested →
   **EPERM** (memfd.rs:84). The `?` propagates the error out of `build()`; there is **no
   rollback** of the removal performed in step 2.

`F_ADD_SEALS`/`F_GET_SEALS` reach `MemfdInode::add_seals`/`get_seals` via
`kernel/core/src/syscall/fcntl.rs`; `memfd_create` via `kernel/core/src/syscall/memfd_create.rs`.
All entry points are ordinary unprivileged syscalls — reachable in normal usage.

### Counterexample correspondence (MC_hunt_TV2.out, 31 states)

t1: map(fd=rw, RW, shared, **non-fixed**) → `vmar_lock → check_writable → mapped_new →
insert → return` (states 2-11, succeeds; seals = {}). t2: `add` seal → `seal_lock →
seal_check → publish (seals = {FUTURE}) → seal_unlock → return` (states 12-17). t1: map
(fd=rw, RW, shared, **fixed=TRUE**) → `vmar_lock → remove_next → split_left →
split_right → put_rest → unmap_pt → dispatch → sync → unmap_drop → remove_next →
check_writable → vmar_unlock → return` (states 18-31): the removal loop completes and
drops the old owner **before** `check_writable`, which then rejects with EPERM.
Invariant `SealRejectedReplacement` (a seal-rejected fixed replacement must leave the
pre-existing mappings intact, mirroring Linux) is violated at state 31.

### Trigger scenario (concrete, public API only)

1. `fd = memfd_create("x", MFD_ALLOW_SEALING)`; `ftruncate(fd, N*4096)`.
2. `base = mmap(NULL, N*4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)` → succeeds,
   write test pattern.
3. `fcntl(fd, F_ADD_SEALS, F_SEAL_FUTURE_WRITE)` → succeeds (no writable-mapping
   precondition for FUTURE_WRITE).
4. `mmap(base, N*4096, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_FIXED, fd, 0)` → returns
   `MAP_FAILED` with `errno == EPERM` on both Linux and Asterinas (admission correctly
   rejected).
5. **Divergence**: Linux v6.18+ leaves the pre-existing mapping intact (failed mmap
   must not modify the address space — POSIX mmap(2) error contract); Asterinas has
   already removed and unmapped the range in step 4's kernel path, so the range is a
   hole: `mprotect(base, len, PROT_READ)` → `ENOMEM`, reads/writes to `base` fault
   (SIGSEGV), and the memfd's writable-mapping owner count drops to zero so
   `F_ADD_SEALS(F_SEAL_WRITE)` now *succeeds* on Asterinas while Linux rejects it.

Caller-side safeguards: none found. The rlimit check in `build()` explicitly models the
removal, i.e. the removal itself is intended; what is missing is performing/committing
it before a check that can still fail. No code path re-inserts or restores the removed
mapping after the EPERM return.

### Prior live observation inside this dataset (shared harness infra)

The Category-B harness (`harness/INSTRUMENTATION.md`, `harness/src/scenarios.c`
`rejected_replacement_and_prefix`) already ran the same public-API scenario on the real
pinned kernel and on Linux 7.2.8; `harness/logs/guest.log` records for `tv2-full`:
`map(..., fixed=1)` → "Operation not permitted", then `protect(...)` → "Cannot allocate
memory" (range gone) and `fcntl(fd, 1033, 0x8)` (F_SEAL_WRITE) → Success. The Linux
reference branch asserts `protect` succeeds. These are the "existing full/partial
differential traces" (tv2-full/tv2-partial) the finding cites as TV-2.

## Step 2 — Developer-knowledge search

- **Commits / blame**: removal-before-check ordering originates in the VMAR refactor
  (`4ea3e4978`, `3f1bf99b2` "Make `mremap` behavior consistent with Linux") — long before
  memfd sealing. The memfd admission check was wired into `build()` after the region
  allocation by `64569ef8f` "Update mappable interface for shared mappings" (2026-08-17)
  and adjusted by `ac9ce5f01` "Allow special files to reject invalid mappings"
  (2026-09-23). No commit message or comment acknowledges the ordering vs. replacement.
- **Comments**: the only comment about removal effects is the rlimit re-check comment
  in `build()` ("Overlapping mappings will be removed. Check again after considering
  this fact.") — evidence the removal is deliberate, but nothing about failure
  atomicity or seal checks. `check_writable` carries a Linux v6.16.5 reference for the
  MAY_WRITE-clearing behavior only. No TODO/FIXME/known-issue at any cited site.
- **Tests**: `test/initramfs/src/regression/fs/pseudofs/memfd_access_err.c` covers
  F_SEAL_SEAL add/get errors only; the mmap regression suite
  (`test/initramfs/src/regression/memory/mmap/*`) contains no seal tests and no
  seal-rejected MAP_FIXED case. No test asserts the current destructive behavior.
- **Issue tracker (upstream)**: searched via GitHub API + web: memfd-seal related
  upstream work is PR #2408 (feature "Support sealing memfd files", required by issue
  #2214), PR #3372 (memfd_create name errno), PR #3481 "Fix inode append and memfd seal
  races" (**open, unmerged**; TOCTOU around append writes/resize/fallocate in ramfs — a
  *different* mechanism at different sites), PR #2521 (exec from memfd). No issue or PR
  reports the seal-rejected MAP_FIXED replacement destroying the existing mapping.
- Upstream `map.rs`/`memfd.rs` commit history after the pinned commit: latest is
  ac9ce5f01 (merged 2026-09-26) — already contained in the pinned tree. **No fix landed
  upstream** as of the search date.

## Step 3 — Known-status / precedent

- No public issue/PR/CVE/advisory reports this exact mechanism at this site. The
  nearest prior art (PR #3481) is a write-path TOCTOU fix, not the mmap-replacement
  ordering — not a match (different mechanism, different site).
- No prior Specula dataset entry exists (`persistent-findings-context.json`: previous =
  null, inherited_records = {}).
- Within *this* dataset the same mechanism was already observed by the trace-validation
  phase as **TV-2** (harness differential traces `tv2-full`/`tv2-partial`, cited in the
  finding itself as "known TV-2 / AST-75", i.e. the dataset's internal analysis-tracking
  label). The MC counterexample independently re-derived it.
- Pre-filter: N/A — the finding is **MC-sourced with an actual counterexample** (the
  code-review × known drop does not apply). Proceed to Phase 2.

## Reachability conclusion (recorded, not a verdict)

The bug path is reachable through ordinary unprivileged syscalls in a single process
(no concurrency required — the CE's two-thread interleaving is not essential; the
removal and the check are ordered inside one `build()` call under the VMAR write lock).
The consequence is observable to the caller itself (mapping hole after a syscall that
returned an error), is permanent for the life of the address space, and matches the
differential already recorded by the harness.
