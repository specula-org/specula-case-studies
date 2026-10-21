# CR-2 Investigation — Resize documentation contradicts fallible tail clearing and exFAT branch order

Source: Code Review (code-review-only, brief §6.3). No MC counterexample (MC hunts returned no violation for this mechanism).
Worktree: pristine Asterinas export @ 604948581512d83734377974d4c34adb4530f2d7 + Specula trace instrumentation only (verified: `git diff` of both cited files adds only `tla_trace` calls; docs, comments, and logic are upstream-verbatim).

## Step 1 — Code audit

### Claim A: `PageCache::resize` doc vs fallible extension tail-clearing

Cited: `kernel/core/src/vm/page_cache/mod.rs:202,250,255` (worktree lines: doc 201-202, extension branch 253-256).

Doc comment (verbatim, upstream and worktree):
> "Extending the page cache does not eagerly allocate pages and therefore cannot return an error. Shrinking may fail because it can zero-fill or decommit existing pages."

Code (`pub(crate) fn resize(&mut self, new_file_size, old_file_size) -> Result<()>`, mod.rs:247):
```rust
if new_file_size < old_file_size && !new_file_size.is_multiple_of(PAGE_SIZE) {
    let fill_zero_end = old_file_size.min(new_file_size.align_up(PAGE_SIZE));
    self.fill_zeros(new_file_size..fill_zero_end)?;            // shrink tail clear (fallible)
} else if new_file_size > old_file_size && !old_file_size.is_multiple_of(PAGE_SIZE) {
    let fill_zero_end = new_file_size.min(old_file_size.align_up(PAGE_SIZE));
    self.fill_zeros(old_file_size..fill_zero_end)?;            // EXTENSION tail clear (fallible)
}
```
So on **extension** with a non-page-aligned old size, `resize` runs `fill_zeros(...)?` — fallible, contradicting "cannot return an error".

`fill_zeros` (vmo/mod.rs:660) → `Vmo::write` (vmo/mod.rs:584) → range < PAGE_SIZE → `write_pages_with_backend(.., CommitMode::Read, ..)` (vmo/mod.rs:616) → `collect_pages` → on cache miss `handle_commit_error` → `commit_on_internal` → `backend.read_page(idx, locked_page)` (vmo/mod.rs:1076/1096) → `PageCacheBackend::read_page` → `read_page_async` → backend.

Callers holding the inode write guard across `page_cache.resize`:
- **exFAT** `ExfatInode::write_at` (exfat/inode.rs:729-753): `let mut inner = self.inner.write();` … `inner.page_cache.resize(new_size, file_size)?;` — write guard held. exFAT's backend **is the inode itself** (`PageCache::new_with_backend(size, weak_self.clone())`, inode.rs:933/1044); `submit_read_bio` starts with `let inner = self.inner.read();` (inode.rs:149). ostd `RwLock::read()` spin-waits "until there are no writers" (ostd/src/sync/rwlock.rs:143-157) → same-task read-while-write = self-deadlock. The Specula instrumentation even adds an `ExfatBackendReadBlocked` detector for exactly this (inode.rs:147-152).
- **ext2** `prepare_write` (ext2/inode/file.rs:219-228): caller holds `self.inner.write()`; `resize_page_cache(end, old_size)?`. ext2's backend is `InodeBlockManager` (ext2/inode/mod.rs:625), a separate object — no self-deadlock on the inode lock.
- **ramfs**: `PageCache::new_anon` (ramfs/fs.rs:197/221) — no backend; `fill_zeros` only allocates frames.

Reachability of the backend-read-on-extension (exFAT): need old size non-page-aligned AND the old tail page absent from the page cache while `write_at` extends. exFAT keeps opened inodes in `fs.inodes` (fs.rs:132-157; removed only on unlink, inode.rs:1339), so a same-mount reopen reuses the cached tail page. A **remount** (fresh `ExfatFs`, empty inode map, fresh `PageCache` per inode) or memory-pressure eviction makes the tail page absent. Trigger: `pwrite64(fd, buf, n, off)` with `off == size`, `size % 4096 != 0`, after remount — plain public syscalls, no fault injection.

### Claim B: exFAT resize-ordering comment vs actual branch order

Cited: exfat/inode.rs:138-140 (comment) vs 1436-1462 (pristine `Inode::resize`; worktree 1467-1494).

Comment (verbatim, upstream and worktree, inode.rs:138-139):
> "Important: To enlarge the page_cache, we need to update the page_cache size before we update the size of inode, to avoid extra data read.
> To shrink the page_cache, we need to update the page_cache size after we update the size of inode, to avoid extra data write."

Actual code:
- `write_at` enlarge (inode.rs:748-752): `inner.resize(new_size, &fs_guard)?` (allocates clusters; `ExfatInodeInner::resize` doc: "The `size_allocated` field in inode can be enlarged, while the `size` field will not", inode.rs:292-294) then `inner.page_cache.resize(new_size, file_size)?`; logical size published last (`inner.size = new_size`, inode.rs:770). → enlarge = page_cache before inode size: **matches the comment** (but **contradicts** the `PageCache::resize` doc's Size-Synchronization rule "When extending a file, update the file size before increasing `Vmo::size`", mod.rs:210-213).
- `Inode::resize` shrink (ftruncate, inode.rs:1491-1494):
  ```rust
  if new_size < file_size {
      inner.page_cache.resize(new_size, file_size)?;   // page cache FIRST
  }
  inner.resize(new_size, &fs_guard)?;                  // sets self.size = new_size on shrink
  ```
  → shrink = page_cache **before** inode size: **contradicts the comment** ("after we update the size of inode"), matches the `PageCache::resize` doc's truncate rule.

Summary of the three orderings: the `PageCache::resize` doc (extend=size-first, truncate=vmo-first) and the exFAT comment (enlarge=vmo-first, shrink=size-first) are exact opposites on both axes; the exFAT code matches the comment for enlarge (write_at) and contradicts it for shrink (Inode::resize).

## Step 2 — Developer knowledge

- exFAT comment dates to the original exFAT PR asterinas/asterinas#639 (2024).
- Page-cache rework: asterinas/asterinas#2953 (refactor) and #3256 (merged 2026-05-25, "Fix a page cache bug that leaks uninitialized memory to userspace") — different mechanisms (partial-write up-to-date state), not this doc/contract mismatch.
- Direct evidence developers know the backend-under-write-guard hazard in exFAT — FIXME in `write_direct_at` (inode.rs:817-821, verbatim): "due to the current design limitations of exfat, it is not possible to acquire the inner write lock in advance, because the page cache flush operation needs to acquire the backend lock, and the backend here is the inode itself." They worked around it for flush in `write_direct_at` (upread), but the same hazard via `page_cache.resize`→`fill_zeros`→backend read in `write_at`'s extension path is not mitigated.
- Existing ktest `page_cache/tests/mod.rs:286` exercises shrink-concurrency of `resize(PAGE_SIZE, 2*PAGE_SIZE)`; no test asserts extension infallibility.
- No caller relies on extension-infallibility: all `page_cache.resize(...)` call sites propagate with `?` (grep: exfat 751/827/880/1163/1332/1492, ramfs 766/842/847, ext2 mod.rs:478, virtiofs 161/174, metadata.rs:73).

## Step 3 — Known-status / precedent

Tracker searches (asterinas/asterinas issues + PRs, incl. recently merged/closed):
- "PageCache resize cannot return an error fill_zeros extension" → no matching report.
- "exfat page cache resize ordering comment" → no matching report; #2953/#3256/#2937 are different mechanisms.
- "exfat write deadlock page cache resize inode lock" → nearest is #2817 (ftruncate shrink hang in VMO decommit loop — different mechanism/site) and #1602 (TLB FLUSH_OPS deadlock — unrelated).
- Exact-phrase searches `"does not eagerly allocate pages"` and `"To enlarge the page_cache"` → only the source files themselves, no issue/PR.
- Current upstream `main` (fetched 2026-09-08): both the doc sentence and the exFAT comment + branch order are **unchanged** — no fix has landed.

**Novelty: NEW** — no issue/PR/CVE/advisory reports this exact defect at these sites; not fixed upstream.

Trigger scenario for Phase 2 (constructed):
- T0 (control, exFAT cached tail): write 100 B, extending pwrite @100 in same session → succeeds, no backend read.
- T1 (exFAT, claim A live): write 100 B, fsync, close, umount, remount, open, extending pwrite @100 from a worker thread → extension resize → fill_zeros → tail page uncached → backend read → `self.inner.read()` while write guard held → expect worker hang (self-deadlock) or, failing that, an error return contradicting "cannot return an error".
- T1b (ext2 control): same remount sequence on ext2 → backend read goes through `InodeBlockManager` (no inode self-lock) → expect success, isolating the exFAT-specific "backend is the inode itself" hazard.
- T2 (exFAT, claim B): arm Specula trace, ftruncate shrink 100→50 with cached page, drain → `PageCacheResizeBegin` timestamp < `ExfatResizeAllocation` timestamp proves page-cache-before-inode order, contradicting the comment.

## Phase 2 addendum (reproduction, executed 2026-09-09)

Repro: `.specula-output/repro/test_bugCR-2_exfat_resize_tailclear.c` (guest init, Level 0 — public syscalls only) + `.specula-output/repro/test_bugCR-2_run.sh` (host driver; docker dev container, prebuilt instrumented kernel `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`, QEMU/KVM). Log: `confirmation/CR-2/repro-guest.log`.

Results (verbatim verdict lines):
- `T0 exfat cached-tail extend: ret=16 errno=0` — control passes.
- `T1b ext2 remounted uncached-tail extend: ret=16 errno=0` — ext2 control passes (backend is not the inode lock).
- `T1 exfat uncached-tail extend: pwrite64 DID NOT RETURN within 10s -> kernel thread stuck` — deadlock on exFAT after remount; QEMU had to be killed by the outer timeout (exit 124).
- T2 trace: `PageCacheResizeBegin @ 6286345009` precedes `ExfatResizeAllocation @ 6286360317` — shrink resizes the page cache BEFORE the inode, contradicting the exFAT comment (inode.rs:138-139).

Mechanism attribution: the only variable differing between T1 (hang) and the two controls is the exFAT backend read on the inode's own non-reentrant RwMutex while `write_at` holds the write guard (cached tail => no backend read; ext2 => backend takes no inode lock). Code audit: `ostd/src/sync/rwmutex.rs` `try_read` fails when the WRITER bit is set, `read()` sleeps on the wait queue — same-task read-while-write can never be satisfied.

Novelty re-check (this turn, GitHub API, issues+PRs incl. closed/merged): queries "exfat page_cache resize deadlock", "exfat write deadlock inode lock", "page cache resize fill_zeros" → only #3421/#2937/#2953/#958/#3505/#3084/#3048, all different mechanisms. NEW.
