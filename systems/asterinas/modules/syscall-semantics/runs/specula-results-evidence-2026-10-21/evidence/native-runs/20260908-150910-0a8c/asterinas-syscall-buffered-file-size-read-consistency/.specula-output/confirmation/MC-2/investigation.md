# MC-2 Investigation — ExFAT reads copy beyond their reported prefix during write preparation

Finding: `kernel/core/src/fs/fs_impls/exfat/inode.rs:648` (read_at), `:654`, `:729` (write_at), `:154` (submit_read_bio).
Counterexample: `spec/output/MC_hunt_s1_growth_exfat_bfs1.out` (invariant `SuccessfulTransferAccounting`).
Source revision: 604948581512d83734377974d4c34adb4530f2d7 (worktree = pristine export + passive tla_trace hooks).

## Step 1: Code audit

### Cited code (all verified at the selected revision)

`ExfatInode::read_at` (exfat/inode.rs:652-674):
```rust
let inner = self.inner.upread();
...
let (read_off, read_len) = {
    let file_size = inner.size;
    let start = file_size.min(offset);
    let end = file_size.min(offset + writer.avail());
    (start, end - start)
};
inner.page_cache.read(read_off, writer)?;   // writer NOT limited to read_len
inner.upgrade().update_atime()?;
Ok(read_len)
```
The returned `read_len` is clamped to the logical size observed at upread time, but the
`VmWriter` passed to `page_cache.read` is NOT limited (contrast ext2 below).

`Vmo::read` (vm/page_cache/vmo/mod.rs:539-545):
```rust
let read_len = writer.avail().min(self.size().saturating_sub(offset));
```
The copy bound is the VMO's own capacity (`vmo.size`), not the inode logical size.

`ExfatInode::write_at` (exfat/inode.rs:729-...):
1. `inner.write()` guard: `resize(new_size, fs_guard)` → `size_allocated = new_size`, clusters extended;
   `inner.size` NOT updated (resize doc: "The `size_allocated` field in inode can be enlarged, while the `size` field will not").
2. `inner.page_cache.resize(new_size, file_size)` → VMO capacity grows to align_up(new_size, PAGE_SIZE)
   (vmo.size.store at page_cache/mod.rs:281).
3. write guard dropped ("Locks released here, so that file write can be parallelized"), `inner.upread()`,
   `page_cache.write(offset, reader)` — the copy phase.
4. `upgrade()` → `inner.size = new_size` — logical EOF published only here (exfat/inode.rs ~770).
So for the whole copy phase: `size` = old EOF < `size_allocated` = new size <= VMO capacity.

`ExfatInode::submit_read_bio` (exfat/inode.rs:157-162):
```rust
if inner.size_allocated <= idx * PAGE_SIZE { EINVAL }
else if inner.size <= idx * PAGE_SIZE { complete_fn(BioStatus::Zeros); return Ok(()); }
```
A page beyond logical size but within size_allocated is zero-filled by the backend.

ext2 contrast (ext2/inode/file.rs:273-276):
```rust
let read_len = writer.avail().min(file_size - offset);
writer.limit(read_len);
self.page_cache().read(offset, writer)?;
```
ext2 limits the writer, so stores == reported. exFAT (and ramfs) do not. ext2 also holds
`inner.write()` for the whole write (no parallel-copy window) and rolls back on error;
exFAT does not roll back size_allocated/VMO on copy error.

### Call chain (reachability)

`sys_read`/`sys_pread64` → `InodeHandle::read`/`read_at` (fs/file/inode_handle.rs:273,327)
→ `FileOps::read_at` → `ExfatInode::read_at` (buffered; O_DIRECT excluded, in scope).
The `VmWriter` writes directly into the user buffer — stores beyond the returned count
are user-visible.

### Trigger scenario (from CE trace)

- t0: `pread(fd, buf, 8192, 0)`; t1: `pwrite(fd, buf, 8192, 2048)`; file initially 4096 bytes.
- t1 grows size_allocated 4096→10240 and VMO capacity 4096→12288, releases the write guard,
  begins copying. Logical size still 4096.
- t0 upreads, computes read_len=4096, but VMO read_len = min(8192, 12288) = 8192:
  copies page 0 (seed) + page 1 (backend zero-fill, size=4096 <= 4096 < size_allocated=10240).
- t0 returns 4096, but stored 8192 bytes into the user buffer (buf[4096..8192] clobbered with zeros).
CE final: `result=2, D=4, out=<<seed,seed,zero,zero,...>>` (model units of 2048B).

Safeguards encountered: none that limit the copy to read_len on the exFAT path. The window is
[PageCacheResizeCapacity store, ExfatWriteAtPublish store) — the writer's whole copy phase,
which scales with write length and includes a synchronous backend read for the first
extension page (observed ~63µs in native receipts).

### Existing harness evidence

`harness/src/scenarios.c` scenario 2 = exactly this (read vs extending buffered write);
existing native trace `traces/raw/exfat-2-12` ran it but the reader's `VmoIoBegin`
(58819119701) landed BEFORE the writer's `PageCacheResizeCapacity` (58819414377),
so the read copied 4096 and returned 4096 — window missed, not disproven.
The writer's in-window span in that trace is ~100K TSC ticks (~36µs) even for an 8192B write.

## Step 2: Developer-knowledge search

- **Upstream PR asterinas/asterinas#3778** (OPEN, created 2026-09-02, author chinrw,
  branch `fix/ramfs-read-past-eof`): "Limit page-cache reads to the file size in ramfs
  and exfat". Body (verbatim): "`RamInode::read_at` and `ExfatInode::read_at` compute how
  many bytes are readable ... but then hand the caller's *unlimited* writer to
  `PageCache::read`. The page cache's size is block-aligned, so it can hold bytes beyond
  the file size, and `Vmo::read` copies up to that size. A read that reaches EOF therefore
  writes past the byte count it returns". Includes a Linux-vs-Asterinas table
  (`pread(off=1,len=64)` -> ret=1 with buf[1..64) zeroed on ramfs/exfat, intact on Linux)
  and a `read_eof.c` regression. Credits Specula for the find. Reviewer cchanging:
  "Maybe we need lock the `page_cache` first to avoid a race with `resize`" — i.e. the
  concurrent resize window (this finding's schedule) is explicitly remarked in review.
- Upstream `main` fetched 2026-09-08: `ExfatInode::read_at` is still the unfixed shape
  (no `writer.limit`, returns `read_len` clamped to `inner.size`). Fix-status: unfixed.
- In-code evidence: exfat/inode.rs:138-140 comment "To enlarge the page_cache, we need to
  update the page_cache size before we update the size of inode" — the ordering that opens
  the window; `resize` doc (exfat/inode.rs:291-292): "The `size_allocated` field in inode
  can be enlarged, while the `size` field will not."
- ext2 does limit (`writer.limit(read_len)`, ext2/inode/file.rs:274-275) and holds the
  write lock across the copy — the intended shape.

## Step 3: Known-status / precedent

**KNOWN** (cite: https://github.com/asterinas/asterinas/pull/3778; fix-status: unfixed).
Same mechanism at the same site: missing read limit in `ExfatInode::read_at` lets
`Vmo::read` copy up to block-aligned capacity and store past the returned count. The PR
reports the sequential manifestation (non-page-aligned EOF); MC-2 is the concurrent
manifestation (capacity grown past logical EOF during write preparation) — same defect,
same fix, and the PR review itself flags the resize race. MC-sourced with a real
counterexample, so the code-review x known drop does NOT apply; proceeded to Phase 2.
Tracker search covered open issues and recently merged/closed PRs (GitHub search API +
web search); no other report of this mechanism found.

## Phase 2: reproduction record

Test: `repro/test_bugMC-2_exfat_read_past_prefix.c` + `repro/test_bugMC-2_run.sh`
(driver reuses the known-good harness recipe: same dev-image lineage
`asterinas/dev:0.18.1-20260805` (20260901 tag not present locally), the prebuilt
instrumented kernel ELF `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`,
fresh 128M ext2/exfat images, same QEMU flags; guest log:
`confirmation/MC-2/build/guest.log`).

Artifact provenance: kernel built by `harness/run.sh` from this worktree (revision
6049485..., manifest `harness/patches/manifest.json`). The instrumentation is passive:
`tla_trace::push` early-returns unless armed via prctl, and this repro never arms it;
`git diff` on vmo/mod.rs + exfat/inode.rs confirms the `read_len` computation and copy
loop are byte-identical to pristine. Compatible with Level 0/1.

Escalation ladder:
- **Level 0 (black-box)** — Part B: sequential pread/read across and at a non-page-aligned
  EOF (2-byte file, block-aligned capacity 4096). Same missing limit, deterministic.
  Result: exFAT VULNERABLE on all 3 checks (ret=1 with 4094 bytes clobbered past it;
  ret=0 at EOF with 4094 clobbered), ramfs VULNERABLE, ext2 clean — matches PR #3778's
  table exactly, validating the oracle on known-positive and known-negative backends.
- **Level 1 (timing)** — Part A: the CE schedule. t1 `pwrite64(fd, buf, 2MiB, 4096)`
  (extends 4096 -> 2101248); t0 loops `pread64(fd, buf, 8192, 0)`; TSC rendezvous, CPU
  pinning, 2 vCPUs, 40 trials. No state injection, no source patch.
  Result: **26 hits on exFAT (19900 reads), 0 on ext2 control (17202 reads)**.
  Hit shape: `ret=4096 clobbered=4096 first=4096 bytes=00...` — the read returned the old
  EOF (4096) but stored two pages, the second zero-filled by the backend
  (`submit_read_bio` -> `BioStatus::Zeros` for 4096 <= idx*4096 < size_allocated).
  Matches CE state 19/20: `result=2, D=4, out=<<seed,seed,zero,zero>>` (2048B cells).
- Levels 2/3: not needed.

Right-bug check: same actions (read vs buffered extending pwrite), same order (writer
grows allocation+capacity, releases preparation guard, reader enters before size
publish), same violated invariant (`SuccessfulTransferAccounting`: reported count
under-accounts delivered stores), same root-cause site (exfat/inode.rs read_at /
submit_read_bio). CE write is 2 cells at cell 2; Part A uses a 2MiB extension at byte
4096 to widen the same window — an admissible instantiation of the same step.
