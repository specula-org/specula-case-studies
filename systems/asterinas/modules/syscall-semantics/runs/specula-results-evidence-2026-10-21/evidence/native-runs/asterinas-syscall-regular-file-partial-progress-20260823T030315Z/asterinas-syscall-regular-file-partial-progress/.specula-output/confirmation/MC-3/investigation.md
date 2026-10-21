# MC-3 — Investigation (Phase 1, evidence only)

Finding: "Ramfs can copy beyond logical EOF and report only the EOF snapshot".
Source: model checking, `MC_hunt_scenario_4_positional_offset.cfg`,
invariant `MCReportedCoversVisibleCopy`.
Counterexample: `spec/output/MC_hunt_scenario_4_positional_offset_bfs.out`.

## Step 0: the counterexample

10-state trace, single thread `t1`, no fault injection, no concurrency:

| State | Action | Change |
|---|---|---|
| 1 | init | `fileSize = 2`, `ofdOffset = 0`, all counters 0 |
| 2 | `MCSysPread64Start(t1,"Ramfs",1)` | `opKind = PositionalRead`, `explicitOffset = 1`, `requested = Complete`, `backendMode = Ramfs` |
| 3 | | `ioOffset = 1`, `pc = SnapshotSize` |
| 4 | | `pc = AcquireData` (the size snapshot is taken before the data lock) |
| 5 | | `dataOwner = t1`, `pc = CopyRead` |
| 6 | | `copied = Complete` — the copy engine moved the **full requested** length |
| 7 | | `reported = Positive`, `entryResult = EntryOk` — the return value is the EOF-clamped length |
| 8-9 | | release, `pc = InodeReturn` → `SyscallDispatch` |
| 10 | | `copiedTotal = 2`, `visibleTotal = 2`, `reportedTotal = 1`, `result = Success` |

`MCReportedCoversVisibleCopy` is violated because `reportedTotal (1) <
visibleTotal (2)`: the syscall made 2 bytes of the user buffer visibly change
but told the caller only 1 byte was written. `MCPositionalOffsetStable` did
**not** fail — the shared OFD offset is untouched, as expected for `pread64`.

No fault, no interrupt, no second thread: the trace is a plain single-threaded
`pread64` that starts inside the file and requests past EOF.

## Step 1: Code audit

### The cited site

`kernel/core/src/fs/fs_impls/ramfs/fs.rs:695-719` (pristine baseline
`2cd6429`, byte-identical to upstream `main` today):

```rust
fn read_at(&self, offset: usize, writer: &mut VmWriter, _status_flags: StatusFlags)
    -> Result<usize>
{
    let read_len = match &self.inner {
        Inner::File(page_cache) => {
            let (offset, read_len) = {
                let file_size = self.size();
                let start = file_size.min(offset);
                let end = file_size.min(offset + writer.avail());
                (start, end - start)              // EOF-clamped -> the RETURN value
            };
            page_cache.lock().read(offset, writer)?;   // line 709: the FULL writer
            read_len
        }
        _ => return_errno_with_message!(Errno::EISDIR, "read is not supported"),
    };
    ...
    Ok(read_len)
}
```

`read_len` is clamped to EOF, but the `writer` handed to the page cache still
carries the caller's full `avail()`. Nothing between the syscall and this line
narrows it.

### How far the copy actually goes

`PageCache::read` (`kernel/core/src/vm/page_cache/mod.rs:344`) forwards
verbatim to `Vmo::read`
(`kernel/core/src/vm/page_cache/vmo/mod.rs:534-537`):

```rust
pub(crate) fn read(&self, offset: usize, writer: &mut VmWriter) -> Result<()> {
    let read_len = writer.avail().min(self.size().saturating_sub(offset));
```

The bound is `Vmo::size()` — the **page-aligned cache capacity**, not the file
size. The page-cache module documents that explicitly
(`page_cache/mod.rs:181-186`):

> Returns the current page-cache capacity in bytes.
> This size is page-aligned and may exceed the file size. **The filesystem
> remains responsible for tracking EOF separately.**

Ramfs sets that capacity in `write_at`
(`ramfs/fs.rs:738-748`): `page_cache.resize(new_size.align_up(BLOCK_SIZE), ...)`
with `BLOCK_SIZE = 4096` (`ramfs/mod.rs:13`) `== PAGE_SIZE`. So a 2-byte ramfs
file has a 4096-byte cache, and a `pread` at offset 1 for 64 bytes copies
`min(64, 4096-1) = 64` bytes while returning 1.

The extra bytes are zeros, not uninitialised memory: anonymous cache pages are
allocated through `CachePage::alloc_zero()`
(`page_cache/vmo/mod.rs:320`, `cache_page.rs:163-170`), truncation zero-fills
the partial tail page (`page_cache/mod.rs:246-255`), and growing over a partial
page zero-fills the gap. So this is a buffer-integrity / API-contract defect,
not an information leak of kernel memory.

### Call chain (all reachable from unprivileged userspace)

```
sys_pread64        kernel/core/src/syscall/pread64.rs:33-36
  user_space.writer(user_buf_ptr, user_buf_len)   <- writer.avail() == requested len
  -> InodeHandle::read_at                fs/file/inode_handle.rs:323-332   (no clamp)
     -> RamInode::read_at                fs/fs_impls/ramfs/fs.rs:695
        -> PageCache::read               vm/page_cache/mod.rs:344
           -> Vmo::read                  vm/page_cache/vmo/mod.rs:534
sys_read           syscall/read.rs:28-31 -> InodeHandle::read (inode_handle.rs:273-291) -> same
sys_readv/preadv   syscall/preadv.rs:101-115 -> file.read_at per iovec -> same
```

`RamFs` backs the boot rootfs (`fs/vfs/path/mount_namespace.rs:102`
`RamFs::new_rootfs()`), `tmpfs` (`ramfs/fs.rs:84`), `/dev/shm`
(`device/shm.rs:25`) and `devtmpfs` (`device/mod.rs:181`), so every ordinary
file on those filesystems is affected.

### Trigger scenario (natural, no faults, no concurrency)

1. `fd = open("/tmp/f", O_CREAT|O_RDWR)` on ramfs/tmpfs; `write(fd, "AB", 2)`.
   File size 2, page-cache capacity 4096.
2. `memset(buf, 0x5a, 64); pread(fd, buf, 64, 1);`
3. Linux/POSIX: returns 1, `buf[1..64)` still `0x5a`.
   Asterinas: returns 1, `buf[1..64)` overwritten with zeros.

Variants that widen the consequence: reading exactly at EOF returns 0 while
still overwriting the buffer; `readv`'s later entries start at EOF and get
clobbered although the return value excludes them; a 4100-byte file lets a
single `pread` scribble ~4 KiB the caller was told was untouched.

### Safeguards looked for, and not found

- No clamp at the syscall layer (`read.rs`, `pread64.rs`, `preadv.rs` pass the
  raw user buffer length).
- No clamp at the VFS layer (`InodeHandle::read`/`read_at`).
- No clamp inside `PageCache`/`Vmo` — by design; the doc comment above puts the
  responsibility on the filesystem.
- The `writer` is bounded by the user's requested length, so the over-copy
  never leaves the caller's buffer: no memory-safety issue, but the
  `[return_value, requested_len)` window that POSIX declares untouched is
  written.

## Step 2: Developer-knowledge search

- **Same-tree counter-example — ext2 does clamp.**
  `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:239-242`:
  ```rust
  let read_len = writer.avail().min(file_size - offset);
  writer.limit(read_len);
  self.page_cache().read(offset, writer)?;
  Ok(read_len)
  ```
  Same page-cache API, same EOF problem, explicit `writer.limit(read_len)`.
  virtiofs does the same (`virtiofs/inode/ops.rs:75`
  `limited_writer.limit(read_len)`). Ramfs is the outlier.
- **Sibling ramfs code clamps on the write side.** `ramfs/memfd.rs:139`
  `reader.limit(eof_page - offset)` for `F_SEAL_GROW`, citing Linux's
  `mm/shmem.c` — the developers do reach for `limit()` when the copy must stop
  at a boundary.
- **Page-cache contract states the requirement.** `page_cache/mod.rs:181-186`
  ("may exceed the file size ... The filesystem remains responsible for
  tracking EOF separately").
- **No comment, TODO or FIXME at the ramfs site** acknowledging the
  unclamped writer. Grepping `ramfs/fs.rs` for TODO/FIXME/EOF returns only an
  unrelated tmpfs-constructor TODO (line 68) and a rename TODO (line 1322).
- **No test asserts the current behavior.** There is no ramfs/tmpfs test in the
  tree that reads past EOF and checks buffer contents.
- **`git log`/`blame`**: the worktree is a single squashed baseline commit, so
  local history is unavailable; upstream history for the file was queried
  through the GitHub API (see Step 3) and shows no commit touching this logic.

Nothing found that says the behavior is intended.

## Step 3: Known-status / precedent

Searched the upstream tracker (issues **and** merged/closed PRs) via the GitHub
API and `gh`:

- `repo:asterinas/asterinas ramfs read EOF` → 5 hits, all unrelated refactors
  (#3421, #3084, #2953, #2555, #60).
- `repo:asterinas/asterinas "beyond EOF"` → #3229, #2953, #3171, #2555 — all
  page-cache/ext2 refactors, none reporting this.
- `repo:asterinas/asterinas "writer.limit"` → #2953, #3122, #1294 — none about
  ramfs.
- `repo:asterinas/asterinas ramfs read_at` / `RamInode` / `tmpfs short read` /
  `page cache EOF` → nothing reporting a read that writes past the returned
  length.
- Recent commits touching `kernel/core/src/fs/fs_impls/ramfs/fs.rs`
  (`1d5dad707`, `d921f38dd`, `0064c4f41`, `b9cfb5ccf`, `819e7a826`, newest
  2026-08-20) are rename/visibility/xattr changes; none touch `read_at`.
- Fetched `main`'s current `ramfs/fs.rs`: lines 695-719 are byte-identical to
  the baseline — **unfixed upstream today**.

The target guidance lists #711, #1554 and #3181 as mechanism context only; none
of them describes an unclamped ramfs read writer.

**Known-status: NEW.** No issue/PR/CVE reports this mechanism at this site.
The finding is MC-sourced with a real counterexample, so the code-review × known
pre-filter does not apply either way.

→ Proceed to Phase 2.
