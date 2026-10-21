# MC-2 Investigation — round 2 (fresh re-confirmation)

Finding: "RamFS and exFAT Cached Reads Copy Beyond Logical EOF" (MC-2,
invariant MCNoReadPastEOF, config MC_hunt_s2_unbounded_read.cfg,
counterexample spec/output/MC_hunt_s2_unbounded_read_bfs.out).

Note: a prior round (Aug 26-27) confirmed this finding REPRODUCED; the
dispatcher re-leased it with a reset worktree and cleared repro/ artifacts.
This record documents the fresh round: every load-bearing fact was
re-verified independently and the reproduction was re-executed from scratch.
The prior round's notes are retained as context only.

Worktree: confirmation/MC-2/worktree @ d0139a1 ("Asterinas 604948581
pristine baseline") + uncommitted harness instrumentation.

## Step 1: Code audit (re-verified this round)

### The bug is in the pristine baseline (instrumentation did not create it)

`git show HEAD:kernel/core/src/fs/fs_impls/ramfs/fs.rs` — pristine
`RamInode::read_at`:

```rust
let (offset, read_len) = {
    let file_size = self.size();
    let start = file_size.min(offset);
    let end = file_size.min(offset + writer.avail());
    (start, end - start)
};
page_cache.lock().read(offset, writer)?;   // writer NOT limited to read_len
```

`git show HEAD:kernel/core/src/fs/fs_impls/exfat/inode.rs` — pristine
`ExfatInode::read_at`: identical shape; `inner.page_cache.read(read_off,
writer)?` with the unrestricted writer.

The uncommitted instrumentation diff on the cited files was re-inspected:
tuple unpacking to expose `file_size`/`page_cache.size()` to trace calls and
added `crate::tla_trace::*` calls only. `page_cache.read(offset, writer)?`
itself is unchanged. The `inode_handle.rs` restructure (124 added lines)
preserves semantics verbatim: `file_ops.read_at(*offset, writer,
status_flags)` (writer passed through unchanged), `*offset += len; Ok(len)`.

### Contrast: the correct reference adapters in the same baseline

- ext2 `kernel/core/src/fs/fs_impls/ext2/inode/file.rs` (baseline HEAD):
  ```rust
  let read_len = writer.avail().min(file_size - offset);
  writer.limit(read_len);
  self.page_cache().read(offset, writer)?;
  ```
- virtiofs (baseline HEAD): `limited_writer.limit(read_len)` equivalent.

ext2/virtiofs limit the writer to the EOF-clipped length before the page
cache; ramfs/exfat alone do not. `VmWriter::limit` (ostd/src/mm/io/mod.rs:919)
is the mechanism: shrinks the writer end so `avail() <= max_avail`.

### Consequence layer

- `kernel/core/src/vm/page_cache/mod.rs:181` (`PageCache::size` doc): the
  capacity "is page-aligned and may exceed the file size. The filesystem
  remains responsible for tracking EOF separately."
- `PageCache::read` (VmIo impl, mod.rs) forwards verbatim to the VMO.
- `Vmo::read` (`kernel/core/src/vm/page_cache/vmo/mod.rs:534`):
  `let read_len = writer.avail().min(self.size().saturating_sub(offset));`
  — clipped ONLY against the page-aligned capacity, then per-page
  `read_fallible(writer)` copies into user memory. Vmo docs (vmo/mod.rs) say
  the VMO "does not define logical EOF semantics".

### Call chain (public API → cited code), re-traced this round

`sys_read` (kernel/core/src/syscall/read.rs) builds
`user_space.writer(user_buf_addr, buf_len)` — a fallible writer over EXACTLY
the user's `[buf, buf+len)` — → `InodeHandle::read` / `read_at`
(kernel/core/src/fs/file/inode_handle.rs:281/389; passes the writer through
unchanged, advances the offset and returns the FS-computed len) →
`RamInode::read_at` / `ExfatInode::read_at` (cited) → `PageCache::read` →
`Vmo::read` (cited). No caller truncates the writer before the FS adapter;
nothing sanitizes after.

### Mechanism

Whenever `offset < capacity` and `offset + writer.avail() > file_size`, the
copy length is `min(user_len, capacity - offset)` while the returned count is
`min(user_len, file_size - offset)`. Bytes of the USER's buffer past the
returned count are overwritten with page-cache content from beyond logical
EOF (zeros for ramfs anon pages; backend-dependent content for exFAT backed
pages). Extreme case = the MC counterexample: `pread64` at
`offset == file_size` returns 0 while copying up to `capacity - file_size`
bytes into `buf[0..]`.

### Reachability

RamFs is the initramfs root FS (so `/tmp` in the guest is ramfs); tmpfs
aliases RamFs (fs_impls/tmpfs). exFAT is mounted at `/exfat` and ext2 at
`/ext2` by `test/initramfs/src/init`. Trigger needs only open/write/read/
pread on regular files — public syscalls, no races, deterministic.

### MC counterexample correlation (re-read this round)

`spec/output/MC_hunt_s2_unbounded_read_bfs.out` (real TLC violation trace,
invariant `MCNoReadPastEOF`): adapterProfile="RamFs", fileSize=6,
cacheCapacity=8. `MCSysPread64Begin(t1, 6, FALSE, FALSE)` (pread64 at EOF,
requested 2) → adapter phase sets `copyLimit` from cache capacity ("Complete"
= unbounded, since the writer is unlimited) with `logicalAvail` Zero →
`MCVmoRead(t1,"Prefix")`: `entryCopied=1`, `entryReturned=0`,
`readPastEOF=TRUE` — a copy past logical EOF into the user buffer while the
logical result is 0. My `eof_pread` phase instantiates exactly this step
(scale 4096-byte pages): pread at offset=file_size=3072 returns 0 and copies
capacity−file_size = 1024 bytes into buf[0..1024).

## Step 2: Developer-knowledge search (re-run this round)

- Local git history is squashed to the single baseline commit — no blame.
- TODO/FIXME near both sites: none relates to EOF clipping of the writer
  (found comments are about tmpfs constructor, inode eviction, O_DIRECT
  fallback, pathname cosmetics).
- Vmo/PageCache doc comments explicitly assign EOF tracking to the
  filesystem layer — evidence the missing clip violates the documented
  layering, not an accepted trade-off.
- Tests: no test in test/initramfs/src/regression/io/file_io/ asserts buffer
  contents beyond the returned count (only the MC-1 harness uses sentinels,
  for a different mechanism).

## Step 3: Known-status / precedent (re-run this round, Aug 28)

Searched the upstream tracker (issues + PRs + commits, including recently
merged/closed):

- PR #3256 "Fix a page cache bug that leaks uninitialized memory to
  userspace" — WRITE path (partial write leaves uninitialized tail); different
  mechanism and site.
- #2937 / PR #2953 — page-cache refactor; no mention of the unrestricted
  reader/writer clip in ramfs/exfat read_at.
- #3086 / d7cbd0f (positional-I/O errno), 513532f (partial readv/writev
  counts), #2835 (ext2 O_DIRECT), #1554 (pipe atomicity, brief-context
  issue), #1542 (sendfile truncation) — none is this mechanism.
- Fresh fetch of upstream `main` TODAY (raw.githubusercontent):
  ramfs/fs.rs `read_at` — NO writer limit before `page_cache.read`; exfat
  inode.rs `read_at` — NO writer limit. No fix has landed.

Conclusion: no existing report of THIS mechanism at THESE sites →
Novelty: NEW. (MC-sourced with an actual counterexample → the code-review ×
known pre-filter does not apply; proceed to Phase 2.)

## Phase 2: Reproduction (this round, executed fresh)

### Escalation ladder

- **Level 0 (pure black-box, public syscalls) — TRIGGERED.** open / write /
  read / pread on regular files; single thread; deterministic; no timing
  assistance, no fault injection, no state injection, no source modification.
- Levels 1–3: not needed — the harm is demonstrated deterministically at
  Level 0.

### Test

`repro/test_bugMC-2_read_past_eof_clobber.c` (installed in the worktree as
`test/initramfs/src/regression/io/file_io/specula_repro_mc2.c` + `.sh`
wrapper + `AUTO_TEST=mc2repro` Makefile branch, mirroring the established
MC-1 harness pattern). Design: per fs ∈ {ramfs(/tmp), exfat(/exfat),
ext2(/ext2)} create a 3072-byte pattern file (page-aligned cache capacity
4096), then:

- short_read: `read(fd, buf, 4096)` from offset 0 — expect ret=3072 and
  buf[3072..4096) untouched (0xA5 sentinel).
- eof_pread (MC CE shape): `pread(fd, buf, 2048, 3072)` — expect ret=0 and
  buf untouched.

Each phase in a forked child; raw write() output; data within the returned
count verified against the pattern (data_ok=1 proves the count and returned
data are correct — only the beyond-count bytes are wrong).

Commands executed:
- Host oracle: `gcc -Wall -Werror -o mc2_check repro/test_bugMC-2_*.c &&
  ./mc2_check` → all CLEAN (Linux leaves the tail untouched).
- Guest: `bash .specula-output/confirmation/MC-2/run_mc2_repro.sh` → docker
  asterinas/dev:0.18.1-20260805, /dev/kvm, warm 10G cargo cache, `make
  run_kernel AUTO_TEST=mc2repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1
  CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1`. Real boot (qemu.log:
  UEFI → "Spawn the first kernel thread" → initramfs unpack → /init).

### Result (worktree qemu.log; extraction saved to
repro/test_bugMC-2_read_past_eof_clobber.guest_output.log)

- ramfs short_read: ret=3072 (correct), data_ok=1, buf[3072..4096)
  clobbered=1024 (zeros) → BUG
- ramfs eof_pread:  ret=0 (correct), buf[0..1024) clobbered=1024 (zeros) → BUG
- exfat short_read: ret=3072, data_ok=1, buf[3072..4096) clobbered=1024 → BUG
- exfat eof_pread:  ret=0, buf[0..1024) clobbered=1024 → BUG
- ext2 controls (same kernel/boot): both phases CLEAN
- Host Linux oracle: both phases CLEAN

The clobber length is exactly capacity − file_size = 1024 — the
page-aligned overrun the mechanism predicts. The eof_pread phase matches the
MC counterexample step-for-step (pread at EOF, logical 0, copy past EOF).

### Verify the RIGHT bug

Sequence matches the CE (pread64 at EOF → copy past EOF, reported 0);
violated property is the same one MC found (MCNoReadPastEOF); root cause is
the same code path (ramfs/exfat read_at unrestricted writer). The ext2
in-guest control isolates the missing `writer.limit` as the cause.

### Checklist (pre-REPRODUCED)

1. Level 0 alone — yes: plain read/pread on regular files, no help.
2. N/A — no Level 2/3 escalation used.
3. Real consumer: the userspace caller of read/pread64 — its buffer holds
   kernel-written bytes beyond the returned count immediately after the
   syscall (kernel/core/src/syscall/read.rs returns the correct short count;
   the sentinel bytes in the caller's own memory are gone). Demonstrated,
   not argued-only.
4. Permanent — user memory stays corrupted until the program rewrites it; no
   sync/loopback/resend/guard restores it. The correct return count also
   means nothing downstream detects it. No masking mechanism exists.

### Verdict

REPRODUCED (Level 0, deterministic, both cited filesystems, with in-guest
ext2 and host-Linux clean controls).
