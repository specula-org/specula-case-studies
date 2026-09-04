# CR-10 Investigation

Finding: `mmio_alloc` lacks two-pass rollback and `mmio_free` drops ownership without
revoking PTEs. Source: code-review (brief §6.3). Severity: Medium.
Cited sites: `src/kernel/src/pm/process/manager/mod.rs:3632` (mmio_alloc), `:3689` (mmio_free).

## Step 1 — Code audit (facts)

### Two mechanisms in the finding
- (A) mmio_alloc "release-only path that skips the two-pass dry-run/rollback".
- (B) mmio_free "drops ownership without revoking PTEs".

### (A) mmio_alloc — `manager/mod.rs:3632`
Current code (default build) ALREADY implements a two-pass validate-then-apply:
```
if cfg!(feature = "nightly-performance-optimizations") {
    // single pass apply
} else {
    // pass 1: kctrl(vaddr, perm, /*dry_run=*/true) for every page  -> validate only
    // pass 2: kctrl(vaddr, perm, /*dry_run=*/false) for every page  -> apply
}
state.add_mmio(region);
```
So the finding's claim that mmio_alloc "skips the two-pass" is FALSE for the current worktree.
The two-pass dry-run was added by PR #1510 (closes issue #1481). `add_mmio` is committed only
after both passes succeed. => Part (A) is not reproducible in the default config; it is a
FALSE POSITIVE against current code. (The opt-in `nightly-performance-optimizations` single-pass
is tracked separately by issue #1894.)

### (B) mmio_free — `manager/mod.rs:3689`
```
pub fn mmio_free(&mut self, pid, tag) -> Result<(),Error> {
    let mut process = self.find_process_mut(pid)?;
    let state = process.state_mut();
    state.remove_mmio(tag);   // <-- only bookkeeping
    Ok(())
}
```
`ProcessState::remove_mmio` (state/mod.rs:529) only removes the `IoMemoryRegion` from the
process's `mmio: VecDeque`. It calls NO page-table function. Compare `munmap`
(manager/mod.rs:3603) which calls `mm.try_unmap_upage(vmem, vaddr)` to actually revoke the PTE.
`mmio_alloc` installed the mapping via `Vmem::kctrl(vaddr, perm, false)` (vmem.rs:1801), which for
an absent PTE creates an identity-mapped, USER-ACCESSIBLE, cache-disabled entry
(vmem.rs:1859-1866). `mmio_free` never undoes that. => the PTEs installed by mmio_alloc survive
mmio_free. This is a real omission present in current code.

### Ownership / allocator interaction (strengthens consequence)
`remove_mmio` drops the `IoMemoryRegion`, and `IoMemoryRegion::Drop` (hal/io/mmio/region.rs:138)
returns the (tag, region) to the allocator via a `return_channel`. So after `mmio_free`:
  - the tag/region is RETURNED to `IoMemoryAllocator` and becomes reallocatable to ANY process,
  - but the freeing process still holds a live user-accessible mapping of that device memory.
=> Cross-process isolation hazard: process A frees region R; process B allocates the same tag R;
   process A can still read/write R's device memory through the stale mapping.

### Reachability / call chain (real public API)
kcall `AllocMmio`/`FreeMmio` -> `io::mmio_alloc`/`io::mmio_free` (io/kcall/mmio_alloc.rs,
mmio_free.rs) -> capability check (`Capability::IoManagement`) -> `pm.mmio_alloc`/`pm.mmio_free`.
Reachable by any process holding `IoManagement` (acquired via `capctl`). Existing guest tests
`test-rust-mmio-fault` and `test-rust-kernel/mmio_ramfs.rs` already drive exactly this API against
the MicroVM RAMFS MMIO region (tag "RAMFS   "), confirming the path is a normal, exercised flow.

### Safeguards observed
- fork(duplicate)/exec reject a process that owns mmio/pmio/events/mailbox
  (manager/mod.rs:1524, 2015) — a guard for a DIFFERENT path (image replacement), not for free.
- No caller-side guard re-maps or blocks access to a freed region.

## Step 2 — Developer-knowledge search
- git log/blame: `mmio_free` never revoked PTEs. The prior signature took an `addr` but the old
  `remove_mmio(tag, addr)` also only did `self.mmio.retain(...)` (commit 46efaa43b refactor). So
  the PTE-revocation gap predates the refactor; the refactor did not introduce it.
- No TODO/FIXME/"revoke"/"unmap" comment near mmio_free or remove_mmio.
- The FIXME "if we fail, we need to revert operation" existed only in mmio_alloc (part A), now
  resolved by PR #1510.

## Step 3 — Known-status / precedent
Issue-tracker search (github.com/nanvix/nanvix):
- Part (A) mmio_alloc rollback: KNOWN and FIXED — issue #1481 (closed 2026-06-28), PR #1510
  (merged 2026-03-06, "follows the dry-run pattern"), also #1563. Matches current two-pass code.
- Part (B) mmio_free not revoking PTEs: searched `mmio_free`, `mmio unmap/revoke`, `MMIO` in
  title/body (issues #1295,#1340,#1482,#1894,#2010,#2066,#2239,#2261,#2421, PRs #1510/#1563 …).
  NONE report mmio_free / detach failing to revoke page-table entries. => mechanism (B) is NOT
  already reported.

Pre-filter (code-review × known): does NOT apply to mechanism (B) — it is unreported. Proceed to
Phase 2 to reproduce (B). (Part (A) is known+fixed and moot for current code.)

Novelty for the confirmed mechanism (B): NEW.

## Phase 2 — Reproduction result (Level 0, black-box) — EXECUTED

Repro added as guest test `test-rust-mmio-uaf` (public kcalls only; kernel MMIO path UNMODIFIED —
verified `git diff` touches no mmio/kctrl/unmap code). Sequence:
capctl(IoManagement) -> mmio_alloc(RAMFS) -> mmio_info -> read base (ok)
-> mmio_free(RAMFS) -> read base AGAIN.

Harness config sets `expected_exit_code = 4` (the CORRECT outcome: a revoked mapping makes the
post-free read fault -> SIGSEGV default action -> exit 4).

Executed via `repro/test_bugCR-10_mmio_free_uaf.sh` (nanvix-test http executor, MicroVM/KVM):
- CONTROL `test-rust-mmio-fault` (write PAST region, never mapped): runner exit 0 == exit code 4
  (fault). Proves the environment DOES fault on genuinely-unmapped access.
- REPRO `test-rust-mmio-uaf` (read WITHIN region AFTER free): harness reports
  `exit code mismatch (expected=4, actual=0)`. Guest console:
    [INFO] test-mmio-uaf: allocated ramfs base=0x0ff00000, size=1048576, first_byte=0xeb
    [INFO] test-mmio-uaf: freed ramfs region; re-reading base to test for a stale mapping
    [INFO] test-mmio-uaf: BUG: post-free read of freed MMIO region succeeded
           (base=0x0ff00000, byte=0xeb) -- mmio_free did NOT revoke the page-table entries
  The post-free read returned the same byte (0xeb, the FAT boot signature) — the mapping survived.

Built with DEFAULT features (microvm; NOT nightly-performance-optimizations), so mmio_alloc used the
(fixed) two-pass dry-run path; the surviving mapping is purely from mmio_free's missing revocation.

Checklist:
1. Level 0 alone triggered it (real public kcalls, normal memory read; no failpoint/injection/patch): YES.
2. N/A (Level 0).
3. Real consumer: user process using the public MMIO kcall API (same API vfsd/init.rs and the RAMFS
   tests use). Wrong outcome: after mmio_free the region is still mapped + user-accessible.
4. Permanent: the mapping lives in the SHARED kernel page tables (vmem.rs clone shares the Rc across
   all address spaces) — process teardown frees per-process user tables, not these; nothing re-revokes
   it. Not masked. (Allocator side IS reclaimed via return_channel, so the tag can be re-allocated to
   another process while the stale global mapping persists.)

VERDICT: REPRODUCED (Level 0). Source: Code Review. Novelty: NEW (mechanism B unreported; Part A —
mmio_alloc rollback — is a false premise for the default build and is KNOWN+FIXED via issue #1510).
Artifacts: repro/test_bugCR-10_mmio_free_uaf.sh, .rs, .run.log.
