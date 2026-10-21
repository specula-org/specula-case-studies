# MC-4 investigation — ExFAT successful ftruncate retains old logical size

## Counterexample (spec/output/MC_hunt_s3_extend_zero_exfat_bfs1.out)

TLC invariant `SuccessfulResizeContract` violated. Trace (7 states):

1. `MCSyscallEnter(t0, <<"ftruncate", 0, 0, 1, 0>>)` — `ftruncate(fd, 1)` on an empty file (L=0, A=0, clusters=0).
2. State 3: `pc = "ExfatResizeUpgrade"`.
3. State 4: `pc = "ExfatAllocate"` — allocation runs.
4. State 5: `pc = "BackendReturn"`, `A=1`, `clusters=1`, **`L=0` unchanged**.
5. State 6/7: `pc = "Return"/"Done"`, `status="Ok"`, `result=0` — success returned while logical size is still 0.

The invariant requires a successful isolated ftruncate to publish the requested
length; the model returns Ok without it.

## Code audit (worktree at Asterinas 60494858, Specula-instrumented)

Call chain: `sys_ftruncate` (kernel/core/src/syscall/truncate.rs:15 →
`file.resize(len)` :30) → `InodeHandle::resize`
(kernel/core/src/fs/file/inode_handle.rs:401) → `Path::resize_unchecked_access`
→ exfat `Inode for ExfatInode::resize` (fs_impls/exfat/inode.rs:1461 instrumented).

`Inode::resize` (instrumented lines 1461–1507):
- `if new_size < file_size { inner.page_cache.resize(new_size, file_size)?; }`
  — page-cache bound updated **only on shrink** (instrumented line ~1491).
- `inner.resize(new_size, &fs_guard)?` — inner helper.
- Returns Ok(()). Never assigns `inner.size` on the growth path.

`ExfatInodeInner::resize` (doc comment at line 289-290, body 291–323):
- Comment: "The `size_allocated` field in inode can be enlarged, while the `size` field will not."
- `Ordering::Greater`: only `extend_clusters` (line ~303).
- `Ordering::Less`: `remove_clusters_from_tail`, and `self.size = new_size`
  only when `new_size < self.size` (instrumented lines ~311-313).
- `Ordering::Equal` (same-cluster shrink): no `size` update at all.
- `self.size_allocated = new_size` (instrumented line ~319); `Ok(())`.

Consequences visible from the code:
- Extension via ftruncate (empty file → 1 byte; or cross-cluster 4096 → 8192):
  returns 0, but `inode.size` stays 0/4096. `fstat` (`metadata()`, instrumented
  line ~1509: `size: inner.size`) reports the stale size. `read_at`
  (instrumented line ~653: `file_size = inner.size`, `end = file_size.min(...)`)
  delivers fewer bytes than the truncated length. Persistent: nothing on the
  resize path ever fixes `size` (only `write_at` publishes `size` after a write).
- Same-cluster shrink (e.g. 4096 → 2048, one 4096-byte cluster): `size` stays
  4096; `read_at` happily serves up to 4096 — bytes past the truncate point
  remain readable, violating truncate semantics.
- Note the write path: `write_at` calls `inner.resize` only when
  `new_size > file_allocated_size`, then `page_cache.resize` and publishes
  `inner.size = new_size` — so writes treat logical-size publication as their
  own duty; the resize helper deliberately does not.

## Guest-receipt evidence (harness, exfat-0-10)

From `harness/logs/guest-20260908T095308Z.log` (and traces/raw/exfat-0-10/native-receipts.jsonl):

- Shrink: `SyscallEnter kind=3 len=2048` → `ExfatResize v=[4096, 2048]` →
  `ExfatResizeAllocation v=[4096, 2048, 1]` — after the allocation helper,
  **size (v[0]) is still 4096** with 1 cluster; final `SPECULA_END {"size":4096,...}`
  — ftruncate(2048) returned success, fstat reports 4096.
- Extension: `ExfatResize v=[4096, 8192]` → `ExfatResizeAllocation v=[4096, 8192, 2]`
  — size still 4096 after extend to 2 clusters; final `SPECULA_END {"size":4096,...}`
  — ftruncate(8192) returned success, fstat reports 4096.

`ExfatResizeAllocation` is emitted at instrumented inode.rs:321 after
`size_allocated` is set; v = [inner.size, inner.size_allocated, num_clusters].
This is production-behavior evidence (the hooks are passive trace stamps; they
do not alter logic), from the exact scenario-0 ftruncate sequence.

## Reachability / trigger scenario

Single-threaded, no race needed:
`open(O_CREAT|O_TRUNC|O_RDWR)` → `ftruncate(fd, N)` (N > 0 for extension;
0 < N < cluster_size for same-cluster shrink) → `fstat` / `pread`.
Reaches exfat `Inode::resize` unconditionally on any regular file. No caller
safeguard publishes size afterwards (inode_handle.rs:401-415 only checks
append-only and delegates).

## Developer knowledge (Step 2)

- The inner helper's doc comment (inode.rs:289-290) states the size non-update
  is intentional for the helper — it is designed to be called from `write_at`,
  which publishes `size` itself. The defect is that the **public** `Inode::resize`
  entry point (the ftruncate path) reuses this helper without publishing size —
  no comment or commit sanctions that path.
- No TODO/FIXME around the public resize.

## Known-status (Step 3)

- Tracker search (asterinas/asterinas issues + PRs, incl. recently merged):
  closest are #2817 (ftruncate hang in VMO decommit — different mechanism/site),
  PR #639 (original exFAT addition), PR #3413 (O_TRUNC permission), #3142
  (xfstests tracking, ext2 ENOSPC etc.). None reports exFAT ftruncate retaining
  the old logical size.
- Upstream `main` (fetched raw from GitHub): `ExfatInodeInner::resize` and
  `Inode::resize` are byte-identical to the worktree logic — **unfixed**.
- Verdict so far: NEW (searched; no report of this mechanism at this site).

## Phase 2 plan

Level 0 black-box guest run: reuse the existing instrumented kernel ELF +
exfat/ext2 fixtures; boot with a tiny initramfs whose init runs a C test:
exFAT empty-file ftruncate(1) → fstat; exFAT 4096-file ftruncate(8192) →
fstat + pread; exFAT 4096-file ftruncate(2048) → fstat + pread; ext2 controls.
Also capture SPECULA_RAW ExfatResizeAllocation receipts from the serial log.
Docker image is unavailable (registry TLS failure), so run QEMU directly from
the host (nix store qemu-system-x86_64) with the same command line as
harness/run_guest.sh, fresh fs images created with host mkfs tools.
