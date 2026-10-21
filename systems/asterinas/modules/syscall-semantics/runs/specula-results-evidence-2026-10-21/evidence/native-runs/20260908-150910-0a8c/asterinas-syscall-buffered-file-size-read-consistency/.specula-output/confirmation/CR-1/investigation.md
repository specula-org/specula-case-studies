# CR-1 investigation — VmIo no-short-transfer contract vs VMO capacity-clamped success

Finding source: code-review (no counterexample). Worktree: baseline `604948581512d83734377974d4c34adb4530f2d7` + Specula tla_trace instrumentation (identical in all cited files to `source/` used for the harness kernel build).

## Step 1 — code audit

### Cited contract (ostd/src/mm/io/mod.rs:68-84)

```rust
pub trait VmIo {
    /// Reads requested data at a specified offset into a given `VmWriter`.
    ///
    /// # No short reads
    ///
    /// On success, the `writer` must be written with the requested data
    /// completely. If, for any reason, the requested data is only partially
    /// available, then the method shall return an error.
    fn read(&self, offset: usize, writer: &mut VmWriter) -> Result<()>;
```

Contract: `Ok(())` ⟹ the writer received exactly `writer.avail()` bytes; partial availability must be an `Err`.

### Cited implementation (kernel/core/src/vm/page_cache/vmo/mod.rs:533-540)

```rust
pub(crate) fn read(&self, offset: usize, writer: &mut VmWriter) -> Result<()> {
    let read_len = writer.avail().min(self.size().saturating_sub(offset));
    if read_len == 0 {
        return Ok(());                       // <-- Ok with zero bytes delivered
    }
    ...
```

`Vmo::read` clamps the transfer to the page-aligned VMO **capacity** (`self.size()`), not to the
requested length, and returns `Ok(())` after delivering `min(avail, capacity - offset)` bytes —
fewer than requested whenever `avail > capacity - offset` (including 0 when `offset >= capacity`).
`PageCache` implements `VmIo` by delegating verbatim (kernel/core/src/vm/page_cache/mod.rs:354-360):

```rust
impl VmIo for PageCache {
    fn read(&self, offset: usize, writer: &mut VmWriter) -> ostd::Result<()> {
        self.0.read(offset, writer)?;
        Ok(())
    }
```

So `PageCache as VmIo` violates the documented no-short-read obligation in both directions the
finding names: it can report success after a short transfer (contract says error), and it can
*deliver* more than the caller's own clamped length when the caller passes an unclamped writer.

### Callers of `PageCache: VmIo::read` and how each copes

| Caller | Discipline | Affected by clamp? |
|---|---|---|
| ext2 `InodeInner::read_at` (fs_impls/ext2/inode/file.rs:266-279) | `writer.limit(read_len)` where `read_len = avail.min(file_size - offset)`; early `Ok(0)` at EOF | **No.** Requested range ⊆ [0, file_size) ⊆ [0, capacity) (capacity = align_up(file_size)); clamp cannot bind. |
| ramfs `FileOps::read_at` (fs_impls/ramfs/fs.rs:~700) | Computes `read_len` from metadata size, but passes the **unclamped** writer; returns precomputed `read_len` | **Yes, two ways.** (a) Over-*report* when capacity < observed size during a shrink race — that is MC-1, out of scope here. (b) Over-*deliver* whenever `avail > read_len` and capacity > read_off: `Vmo::read` copies up to `min(avail, capacity - read_off)` bytes into the user buffer while ramfs reports only `read_len`. No race needed: capacity = align_up(file_size) > file_size is the steady state for any non-page-aligned file. |
| exfat `ExfatInode::read_at` (fs_impls/exfat/inode.rs:645-668) | Same shape as ramfs: clamps `read_off`/`read_len` to `inner.size`, passes the **unclamped** writer, returns `read_len` | **Yes.** Same over-delivery; additionally the extra bytes come from the on-disk page read (exfat `submit_read_bio`, inode.rs:144-176 reads the full 4 KiB page when `idx*PAGE_SIZE < size`, with **no zeroing of the `[size..page_end)` tail**), so they can be stale cluster data. `read_off` is clamped to `file_size` for `offset >= size`, so a read at EOF delivers `[size..capacity)` and returns 0. |
| ext2 `read_bytes` symlink (ext2/inode/symlink.rs:136), `read_val` inode table (ext2/block_group.rs:447) | Fixed-size reads at offsets < size | No (range within capacity; clamp cannot bind). |
| exfat dentry iterator `read_bytes` (exfat/dentry.rs:465-490), `delete_dentry_set` (inode.rs:1242), `meta_cache.read_bytes` (exfat/fs.rs:167) | Loop guard `byte_start + len <= self.size` / offsets within dir or meta size | No today (all within [0, size) ⊆ capacity). These rely on the all-or-error contract; the latent hazard is that a capacity < size skew (resize race) silently short-reads into a parsed struct — the racy form is again MC-1's territory. |

### Delivery plumbing (why over-delivery reaches userspace)

`sys_read` (kernel/core/src/syscall/read.rs:24-32) and `sys_pread64` (pread64.rs:33-38) construct
`user_space.writer(user_buf_addr, buf_len)` — a `VmWriter` directly over the user buffer — and hand
it down unmodified: `file.read(&mut writer)` → `InodeHandle::read` → `FileOps::read_at` →
`page_cache.read` → `Vmo::read` → `page.reader().skip(...).read_fallible(writer)` copies straight
into user pages. There is no kernel bounce buffer (the 2024-era buffered-copy design of issue #711
is gone). Therefore every byte `Vmo::read` delivers is physically observable in the user buffer,
while the value returned to userspace is the fs's precomputed `read_len` (ramfs/exfat).

### Trigger scenario (no race, no fault injection)

1. Create a fresh file, `pwrite(fd, buf, 100, 0)` → file size 100, page-cache capacity 4096.
2. Fill an 8192-byte user buffer with a sentinel; `pread(fd, buf, 8192, 0)`.
3. ramfs/exfat return `100` (correct per POSIX), but `Vmo::read` delivers
   `min(8192, 4096 - 0) = 4096` bytes into the buffer: bytes `[100..4096)` are overwritten
   (zeros on ramfs; on exfat, the raw on-disk tail of the file's cluster, possibly stale data).
4. Variant: `pread` at `offset = 100` (EOF) returns `0` yet still writes up to 3996 bytes.
5. Control: ext2 performs the same operations with `writer.limit()` and leaves the tail untouched.
6. Benign sub-case: empty file (capacity 0) — `Vmo::read` returns `Ok(())` with 0 delivered, all
   three filesystems clamp to `read_len = 0` first, so the "zero bytes at zero capacity" branch is
   currently indistinguishable from a correct EOF result.

The returned count failing to account for bytes observably delivered is exactly priority question 1
of the target brief ("fail to account for bytes observably delivered under the supported contract").

## Step 2 — developer-knowledge search

- The trait docs themselves are the intent: "No short reads … the method shall return an error"
  (ostd/src/mm/io/mod.rs:72-79, present unchanged since at least api-docs 0.4.2 through
  docs.rs/ostd latest — the contract predates and survives the page-cache refactor).
- The two *other* `VmIo` implementation families enforce the contract:
  - `HasVmReaderWriter` blanket impl (ostd/src/mm/io/util.rs:75-92): `if limit > reader.remain() { return Err(Error::InvalidArgs) }`, plus `debug_assert!(!writer.has_avail())`.
  - `IoMem` (ostd/src/io/io_mem/mod.rs:310-323): `check_range(offset, len)?` before copying; the
    separate `read_fallible` method exists precisely to expose partial progress "instead of
    enforcing no-short-read semantics" (doc comment on IoMem::read_fallible).
  `PageCache` is the sole implementation that returns `Ok` for a short/out-of-range read.
- `PageCache`/`Vmo` docs (page_cache/mod.rs, vmo/mod.rs headers, `PageCache::size` docs) state the
  capacity is page-aligned, may exceed the file size, and that "the filesystem remains responsible
  for tracking EOF separately" — i.e. the capacity clamp is deliberate layer design; the *conflict*
  is that this is exposed through an `impl VmIo` whose trait forbids it.
- ext2's `writer.limit(read_len)` discipline (file.rs:275) shows at least one caller compensating
  for the implementation's behavior; ramfs/exfat do not.
- Issue/PR search (github.com/asterinas/asterinas, issues + PRs, open and closed; also checked
  upstream `main` source): nothing reports this mechanism.
  - PR #3256 (merged 2026-05-25, "Fix a page cache bug that leaks uninitialized memory to
    userspace") — different mechanism (Uninit pages marked UpToDate on partial overwrite; leak of
    uninitialized RAM), different site (write path), already merged. Not this finding.
  - Issue #711 (EFAULT mid-I/O) — error-path partial-copy semantics, not the capacity clamp.
  - PR #3729 (RWF_NOWAIT short reads), PR #3582 (virtio-fs short replies) — unrelated features.
  - Issue #2937 / PR #2953 — the page-cache refactor design discussion; describes layering, does
    not report the contract violation.
  - Upstream `main` (fetched 2026-09-08) still carries the identical
    `let read_len = writer.avail().min(self.size().saturating_sub(offset)); if read_len == 0 { return Ok(()); }`.
- No TODO/FIXME at the cited sites acknowledges the mismatch; `VmIoFill::fill_zeros` docs ("Unlike
  the methods in [`VmIo`], this method allows for short writes") confirm the authors treat the
  no-short rule as the norm that exceptions must call out — `PageCache`'s impl has no such callout.

## Step 3 — known-status / precedent

Tracker search covered open and closed issues and merged PRs for this exact mechanism
(capacity-clamped `Vmo::read` returning `Ok` on short/zero delivery; over-delivery past the
reported read count). No existing report; upstream `main` unfixed. **Novelty: NEW.**
Not dropped; proceeding to Phase 2.

## Provenance note for reproduction

Harness build `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf` (2026-09-08 18:19 +0800)
was built from `source/`; no `.rs` file in `source/` is newer than the ELF, and `source/` is
byte-identical to this CR-1 worktree in all four cited files (diff rc=0). Instrumentation is
trace-only. The prebuilt kernel is reused; the guest test is built fresh with its own initramfs
and fresh ext2/exfat images.
