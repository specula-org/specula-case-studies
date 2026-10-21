# MC-5 investigation — ExFAT regrown holes can read the subject's old backing bytes

Source: MC (real counterexample: `spec/output/MC_hunt_s3_holes_exfat_bfs1.out`, invariant `HoleZeros`, cfg `MC_hunt_s3_holes_exfat.cfg`). No verdict here; evidence only.

## Counterexample summary (from the .out file)

Sequential single-thread trace (`solo = TRUE` everywhere, depth 35):

1. Initial: file of 6 model cells ("seed" data on disk), 2 clusters.
2. `ftruncate(fd, 0)` — completes `Ok`, `L: 6 -> 0`, clusters freed (`C -> 0`), model disk bytes remain "seed".
3. `pwrite64(fd, 2 cells @ off 4)` — completes `Ok`; extends to `L = 6`; only the tail page is overwritten (model `data` becomes `<<seed, seed, uninit, uninit, t0, t0, ...>>`); reference says file must be `<<zero x4, t0, t0>>`.
4. `pread64(fd, 2 @ off 0)` — returns `2` with `out = <<seed, seed>>`, `zerosOK = FALSE` → `HoleZeros` violated.

Control runs: `MC_hunt_s3_holes_ext2_bfs1.out` and `..._ramfs_bfs1.out` explored the FULL state space (0 left on queue) with NO violation. exFAT-only.

## Step 1: code audit

Revision: worktree = pristine Asterinas `604948581512d83734377974d4c34adb4530f2d7` + Specula trace-only instrumentation (diff adds `tla_trace::event` calls, no logic change; `fat.rs` untouched). All cited sites byte-identical to current upstream master (verified via raw.githubusercontent diff of `exfat/inode.rs` `write_at`/`submit_read_bio`, `vm/page_cache/mod.rs` `PageCache::resize`).

Cited sites (pinned-revision lines, verified against upstream file at the pinned SHA):

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:154` — `submit_read_bio`: a page read returns `BioStatus::Zeros` ONLY when `inner.size <= idx * PAGE_SIZE` (page fully beyond logical EOF). A hole page below logical size falls through to a real disk read of the mapped cluster.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:743` — `write_at` publishes `inner.size = new_size` after copy. The extension branch (`write_at`, worktree lines 745-749): `if new_size > file_size { if new_size > file_allocated_size { inner.resize(...) } inner.page_cache.resize(new_size, file_size)?; }`.
- `kernel/core/src/vm/page_cache/mod.rs:246` — `PageCache::resize`: on extension it zero-fills only `old_file_size..min(new_size, align_up(old_file_size))` (tail of the old partial page), and only when `!old_file_size.is_multiple_of(PAGE_SIZE)`. With old size 0 (or any page-aligned old EOF), NO bytes are zero-filled; full-page gaps stay `Uninit`.
- `kernel/core/src/fs/fs_impls/exfat/fat.rs:208` — `alloc_cluster_from_empty` → `bitmap.find_next_unused_cluster_range(EXFAT_FIRST_CLUSTER, n)`: first-fit from the very first data cluster.
- `kernel/core/src/fs/fs_impls/exfat/fat.rs:364` — `remove_clusters_from_tail` → `bitmap.set_range_unused(...)`: frees clusters in the allocation bitmap ONLY; backing bytes on disk are never erased.
- `kernel/core/src/fs/fs_impls/exfat/bitmap.rs:119-157` — `find_next_unused_cluster_range_by_bits` is first-fit ascending: after truncate-to-zero frees the file's clusters, they are the lowest free range and are reclaimed by the next from-empty allocation.

Mechanism chain (all code-verified):
1. `ftruncate(fd, 0)` → `Inode::resize(0)` (worktree inode.rs:1469): `page_cache.resize(0, old)` decommits ALL cache pages (VMO size 0); `inner.resize(0)` → `remove_clusters_from_tail` frees the clusters in the bitmap; disk bytes stay.
2. `pwrite64(fd, n @ off)` with `off+n > 0` → `ExfatInode::write_at`: `inner.resize(new_size)` → `extend_clusters` → `alloc_cluster_from_empty` → first-fit from `EXFAT_FIRST_CLUSTER` reclaims the same (stale-byte) clusters; `page_cache.resize(new_size, 0)` grows the VMO with NO zero-fill of full-page gaps; `page_cache.write(off, reader)` commits only the pages covering `[off, off+n)`; `inner.size = new_size` publishes logical EOF across the untouched hole.
3. `pread64(fd, off', n')` into the hole → `read_at` computes `read_len` from `inner.size` → `page_cache.read` → hole page `Uninit` → `handle_commit_error(WaitUntilInit)` → `backend.read_page` → `submit_read_bio`: `size_allocated > off'` and `size > off'` → disk read → stale pre-truncation bytes returned as file contents.

Why exFAT only: ext2 leaves gap blocks unmapped (block 0 = hole → `Zeros`); ramfs has no backend (anonymous zero-fill). exFAT has no hole representation — the cluster chain is contiguous from cluster 0 — so an extending write must allocate the gap, and nothing zero-fills it.

Reachability: pure public syscalls, sequential, single thread, unprivileged. No race, no fault, no injection. Deterministic modulo physical cluster reuse, which is deterministic on a fresh image with the first-created file (first-fit from `EXFAT_FIRST_CLUSTER`).

Caller-side safeguards that could mask: none found on the read path. `submit_read_bio`'s only zero path is `inner.size <= idx*PAGE_SIZE`, which is false for an in-EOF hole. The struct comment (worktree inode.rs:137-139) documents the page_cache-vs-inode size ordering but does not zero extension gaps.

## Step 2: developer-knowledge search

- Upstream issue tracker (api.github.com/search, 2026-09-08):
  - `exfat truncate` → 14 hits; none this mechanism. (#3413 O_TRUNC permission check; #3435 cluster reclaim on unlink — unlink, not truncate-extend.)
  - `exfat stale/hole/zero` → 129 hits; reviewed: #3604 (xfstests gap tracker — entries are mmap-rmap, sync semantics, small clusters; nothing on truncate→extend stale reads), #3778 (open PR "Limit page-cache reads to the file size in ramfs and exfat" — read-past-EOF buffer overwrite, DIFFERENT mechanism at the same file, found by Specula), #3424 (deleted file space not reclaimed — space leak, different), #2269 (eviction DMA map — different).
  - `exfat extend/extending/append zero` → 38 hits; nothing on zero-filling extension gaps.
  - `specula` across repo → only #3778.
  - #3142 (xfstests tracker): ext2 "Sparse File Support" entry records that ext2 got "hole-based storage ... and zero-fill logic in the page cache" — explains why ext2 is clean; it is about ext2, not exFAT.
- Recent commits touching `kernel/core/src/fs/fs_impls/exfat/inode.rs` (GitHub commits API): latest 2026-09-02 (symlink impl), 2026-08-27 (SyncMode), 2026-08-21 — none touch `write_at`/`submit_read_bio`/resize zero-fill. Current master's `write_at`, `submit_read_bio`, and `PageCache::resize` are byte-identical to the pinned revision (downloaded and diffed) → mechanism unfixed upstream as of 2026-09-08.
- Comments near code: no TODO/FIXME about zero-filling extension gaps. `PageCache::write` has a TODO about the write lock ("we need to fix the exfat code first, since it does not hold the write lock when handling write()") — unrelated to holes.
- Tests: harness `INSTRUMENTATION.md` explicitly notes "Physical cluster-reuse identity (TV3) ... not covered" by its scenarios — this finding exercises exactly that uncovered interaction.

Known-status: no existing issue/PR/CVE/advisory reports THIS mechanism (regrown exFAT holes reading stale backing bytes after truncate-to-zero + extending write) at THIS site. Novelty: NEW.

## Step 3: pre-filter

MC-sourced with an actual counterexample → cannot drop regardless of novelty. Proceed to Phase 2.

## Trigger scenario (for Phase 2, Level 0)

On a fresh exFAT image (cluster = page = 4096), as unprivileged uid:

```c
fd = open("/exfat/mc5.bin", O_RDWR|O_CREAT|O_TRUNC, 0644);
pwrite(fd, pageA, 4096, 0);      // 'A'
pwrite(fd, pageB, 4096, 4096);   // 'B'
pwrite(fd, pageC, 4096, 8192);   // 'C'
fsync(fd);                        // seed bytes durable on disk
ftruncate(fd, 0);                 // decommit pages, free clusters, disk bytes stay
pwrite(fd, pageZ, 4096, 8192);   // extends to 12288; reclaims same clusters; hole [0,8192)
pread(fd, buf, 4096, 0);          // expect zeros; bug: 'A' bytes from reused cluster
```

Expected (Linux contract, `HoleZeros`): hole reads as zeros. Bug: reads pre-truncation 'A'/'B' bytes. Control: same sequence on ext2 (and ramfs) must yield zeros.
