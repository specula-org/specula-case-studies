# MC-1 investigation — ramfs read returns saved count ≠ delivered bytes

Source: MC (counterexample `spec/output/MC_hunt_s1_ramfs_bfs1.out`, invariant SuccessfulTransferAccounting).
Base revision: Asterinas 604948581512d83734377974d4c34adb4530f2d7 (Specula conversion base f5e9e97).

## Step 1: Code audit

### Cited code (verified at worktree)

`kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-718` (`RamInode::read_at` for `Inner::File`):

```rust
let (offset, read_len, specula_size) = {
    let file_size = self.size();                       // metadata lock, taken + dropped here
    let start = file_size.min(offset);
    let end = file_size.min(offset + writer.avail());
    (start, end - start, file_size)
};
...
let cache = page_cache.lock();                          // cache lock taken AFTER size observation
cache.read(offset, writer)?;                            // copies however much the CACHE allows
read_len                                                // returns the SAVED count, not copied progress
```

The return value is derived only from the logical file size observed before the
cache mutex is acquired. `cache.read`'s actual copy progress is discarded
(`PageCache::read`/`Vmo::read` return `Result<()>`).

`kernel/core/src/vm/page_cache/vmo/mod.rs:539-546` (`Vmo::read`):

```rust
let read_len = writer.avail().min(self.size().saturating_sub(offset));
if read_len == 0 { return Ok(()); }
```

Delivered bytes are capped by the VMO's own page-aligned capacity at the moment
the copy runs (i.e. after the cache lock is held) — a different size source from
the one the ramfs caller used.

`kernel/core/src/vm/page_cache/mod.rs:246-294` (`PageCache::resize`): on shrink,
`vmo.size.store(new_cache_size, Release)` + page decommit under the cache lock;
ramfs publishes the metadata size only afterwards (`RamfsResizePublish`,
fs.rs:843-851). On extension, ramfs publishes metadata first, then grows the
cache (fs.rs:837-842). So logical size and cache capacity are intentionally not
updated atomically — the module doc (page_cache/mod.rs:132-138) states the
filesystem owns "the higher-level synchronization that keeps metadata, buffered
I/O, invalidation, and VM mappings coherent". Ramfs does not provide it for reads.

`kernel/core/src/fs/file/inode_handle.rs:285-294` (`InodeHandle::read`): takes
the shared-offset lock, calls `read_at`, then `*offset += len` with the RETURNED
(saved) count — the shared offset advances by bytes that may never have been
delivered. `pread64` reaches the same `read_at` via `InodeHandle::read_at`
without touching the offset.

### Call chain

`sys_read`/`sys_pread64` → `FileLike::read`/`read_at` (inode_handle.rs) →
`RamInode::read_at` (fs.rs:695) → `PageCache::read` (page_cache/mod.rs:355) →
`Vmo::read` (vmo/mod.rs:539). Fully reachable via ordinary `read(2)`/`pread64(2)`
on any ramfs regular file (the initramfs root is ramfs).

### Trigger scenario

Two cooperating unprivileged threads on one ramfs file:

- SHRINK: file = 4096 B. T0 `pread(fd, buf, 8192, 0)`; T1 `ftruncate(fd, 0)`.
  T0 observes size 4096 → read_len 4096; T1's `PageCache::resize(0, 4096)` wins
  the cache lock first and stores vmo.size = 0; T0 then copies 0 bytes and
  returns 4096. Positive return, zero delivered bytes.
- GROW: file = 4096 B. T0 `pread(fd, buf, 8192, 0)`; T1 `pwrite(fd, buf, 8192, 2048)`
  (extends to 10240 B). T0 observes size 4096 → read_len 4096; T1 holds the
  cache lock for its whole write and grows the cache; T0 copies 8192 bytes
  (including T1's fresh data) but returns 4096.
- Consequence: caller's return count ≠ bytes actually written into its buffer;
  shared-offset `read(2)` additionally advances the file position by the wrong
  count (data skip on over-report, re-read on under-report).

Caller-side safeguards: none found on this path. `Vmo::read` returns no count,
so `read_at` cannot correct itself; the syscall layer trusts the returned usize.

### Existing evidence from the prior guest run

`traces/ramfs-2-2.ndjson` (captured by the trace harness from a real QEMU guest
run of the same revision, ramfs backend, one TSC-synchronized attempt):

- T0 `pread64` O=0 N=4 cells (8192 B): `RamfsReadAtObserve` records S=2 cells
  (4096 B) as the saved EOF.
- T1 `pwrite64` O=1 N=4 (offset 2048, 8192 B) extends the file.
- T0 `BackendReturn`: **result = 2 cells (4096 B)** while **ioDone = 4 cells
  (8192 B)** and the destination inspection shows 4 delivered cells
  `["seed","t1","t1","t1", sentinel...]`.

That is the GROW direction observed on the real kernel: 8192 bytes delivered,
4096-byte return. The harness's own validation rejected this trace against the
supplied spec (`run.sh` returns 1 on ramfs-2-2 and ramfs-3-3), consistent with
the hunt counterexample.

## Step 2: Developer-knowledge search

- Issue asterinas/asterinas#2937 "Refactor the page cache system" (2026-01-29,
  closed 2026-05-13 by PR #2953): a design proposal citing "incomplete locking
  mechanism ... leading to numerous race conditions" (its examples: writeback
  races, duplicate I/O, mapped-page truncate semantics). It does NOT report the
  read return-count vs delivered-bytes defect; no mention of read_at/read_len/
  read counts. This is developer awareness of the problem AREA, not a filed
  report of THIS mechanism.
- PR #2953 (merged 2026-05-13) reworked the page cache into the current
  PageCache-around-Vmo shape that our base already has; the ramfs read pattern
  survived it unchanged.
- PR #3256 (merged 2026-05-25) "Fix a page cache bug that leaks uninitialized
  memory to userspace": write-path page-status bug (partial write marking pages
  up-to-date). Different mechanism, different site.
- No comments/TODO at the cited lines. The PageCache module doc explicitly
  assigns metadata/IO coherence to the filesystem — i.e. developers intend the
  FS layer to synchronize EOF with buffered I/O; ramfs's read path does not.
- Current upstream master (raw.githubusercontent.com/asterinas/asterinas/main,
  checked today): `RamInode::read_at` still computes `read_len` from
  `self.size()` before `page_cache.lock()` and returns the saved value — the
  defect is still unfixed upstream.

## Step 3: Known-status / precedent

Searched upstream issues AND merged/closed PRs (queries: ramfs read truncate
race; read returns more than copied; read_at saved file size). Closest reports:
#2937 (design proposal, other aspects), #2817 (ftruncate hang in decommit_pages),
#3256 (write-path uninitialized leak), #1542 (sendfile size bug). NONE reports
"read returns a saved count that differs from delivered bytes" at
ramfs/fs.rs / vmo/mod.rs. Per the Step-3 bar, developer awareness of the locking
area does not count as a report.

**Novelty: NEW** — looked, found nothing reporting THIS mechanism at THIS site;
the pattern is still present and unfixed on upstream master.

## Reachability / escalation plan

Level 1 suffices in principle: the race window is the full length of the
competing cache-lock critical section (microseconds), and the prior harness hit
the GROW case in a single TSC-synchronized attempt without any kernel delay.
Plan: reuse the proven prebuilt instrumented kernel
(`harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`; its source tree's
cited files verified byte-identical to this worktree) and boot a purpose-built
guest test that hammers SHRINK and GROW with canary-buffer delivered-byte
inspection from pure userspace syscalls (Level 1: real public API + TSC
rendezvous timing only).
