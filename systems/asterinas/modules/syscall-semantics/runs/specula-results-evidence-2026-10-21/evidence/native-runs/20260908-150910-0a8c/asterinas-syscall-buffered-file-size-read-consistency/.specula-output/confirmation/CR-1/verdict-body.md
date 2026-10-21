# CR-1 verdict body

- **Source**: Code Review
- **Novelty**: NEW (searched asterinas/asterinas issues + PRs, open and closed, plus upstream `main` source on 2026-09-08; closest hits are different mechanisms: PR #3256 uninitialized-memory leak via the write path, already merged; issue #711 EFAULT mid-copy; PRs #3729/#3582 unrelated short-read features. Upstream `main` still carries the identical `read_len = writer.avail().min(self.size().saturating_sub(offset))` clamp.)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ostd/src/mm/io/mod.rs:75` (contract), `kernel/core/src/vm/page_cache/vmo/mod.rs:533` (capacity-clamped `Vmo::read`), exposed through `kernel/core/src/vm/page_cache/mod.rs:354` (`impl VmIo for PageCache`); affected callers `kernel/core/src/fs/fs_impls/ramfs/fs.rs` (`FileOps::read_at`) and `kernel/core/src/fs/fs_impls/exfat/inode.rs:667` (`ExfatInode::read_at`); unaffected control `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:275` (`writer.limit(read_len)`).

## Description

`VmIo::read` documents "No short reads": on success the writer must be filled completely, and partial availability must be an error. `Vmo::read` instead clamps the transfer to the page-aligned VMO capacity (`min(writer.avail(), size().saturating_sub(offset))`) and returns `Ok(())` — including after delivering 0 bytes. `PageCache`'s `impl VmIo` delegates verbatim, so the contract conflict the finding names is real, and the trait side is the authoritative one: the two other `VmIo` implementation families (`HasVmReaderWriter` blanket impl at `ostd/src/mm/io/util.rs:75-92`, `IoMem` at `ostd/src/io/io_mem/mod.rs:310-323`) both enforce all-or-error, and `IoMem` exposes partial progress only through a separately-named `read_fallible`.

The caller question resolves concretely: ext2 clamps the writer (`writer.limit(read_len)`) so the capacity clamp never binds; ramfs and exfat compute `read_len` from the logical file size but pass the **unclamped** user `VmWriter`, so `Vmo::read` delivers up to `align_up(file_size)` bytes into the user buffer while the syscall returns only the size-clamped count. The returned count fails to account for up to `align_up(size) - ret` observably delivered bytes — the over-delivery side of priority question 1, distinct from MC-1's race-dependent over-report (count > delivered). Fixed-size `read_bytes`/`read_val` callers (ext2 symlink/inode table, exfat dentry/meta) all stay within `[0, size) ⊆ capacity` today, so the all-or-error half of the contract is latent-only.

## Trigger scenario

No race, no fault injection, unprivileged (uid 1000), sequential:

1. `fd = open("/ramfs/cr1_small.bin", O_CREAT|O_TRUNC|O_RDWR)`; `pwrite(fd, buf, 100, 0)` → size 100, page-cache capacity 4096.
2. Fill an 8192-byte buffer with sentinel `0x5A`; `pread(fd, buf, 8192, 0)`.
3. Expected (Linux): return 100, bytes [100..8192) untouched. Observed: return 100, bytes [100..4096) overwritten (ramfs zeros, exfat zeros).
4. Variant: `pread(fd, buf, 8192, 4096)` at/past EOF returns 0 yet overwrites bytes [0..3996).
5. ext2 runs the identical operations as control: buffer untouched.

## Developer intent

The `VmIo` trait docs (unchanged since at least api-docs 0.4.2) and both other implementation families enforce no-short-read as the norm; `VmIoFill::fill_zeros` explicitly flags itself as the exception ("Unlike the methods in [`VmIo`], this method allows for short writes"). The `PageCache`/`Vmo` docs state the capacity is page-aligned, may exceed the file size, and "the filesystem remains responsible for tracking EOF separately" — the capacity clamp is deliberate layer design, but exposing it through `impl VmIo for PageCache` contradicts the trait without any callout. ext2's `writer.limit(read_len)` shows the compensating caller discipline; ramfs/exfat lack it. No issue/PR/TODO reports this mismatch.

## Reproduction result

PASS at **Level 0** (pure black-box syscalls; prebuilt harness kernel `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`, provenance-verified against `source/`, byte-identical to this worktree at all cited files; fresh guest initramfs + fresh ext2/exfat images).

- Test: `.specula-output/repro/test_bugCR-1_vmo_overdelivery.c` (guest), `.specula-output/repro/test_bugCR-1_run.sh` (driver), log `.specula-output/repro/test_bugCR-1_guest.log`.
- Command: `timeout 500 bash .specula-output/repro/test_bugCR-1_run.sh` (guest rc=33 = clean isa-debug-exit poweroff).

Output (verbatim, trimmed to the decisive lines):

```
CR1|ramfs/small/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[100..4095]
CR1|ramfs/small/pread@0|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 100
CR1|ramfs/small/pread@eof4096|ret=0 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[0..3995]
CR1|ramfs/small/pread@eof4096|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 0
CR1|ramfs/small/read@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[100..4095]
CR1|ramfs/small/read@0|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 100
CR1|ramfs/empty/pread@0|ret=0 clobbered_beyond_ret=0 ... clean: buffer beyond returned count untouched
CR1|ext2/small/pread@0|ret=100 clobbered_beyond_ret=0 ... clean: buffer beyond returned count untouched
CR1|ext2/small/pread@eof4096|ret=0 clobbered_beyond_ret=0 ... clean: buffer beyond returned count untouched
CR1|ext2/empty/pread@0|ret=0 clobbered_beyond_ret=0 ... clean: buffer beyond returned count untouched
CR1|exfat/small/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[100..4095]
CR1|exfat/small/pread@0|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 100
CR1|exfat/small/pread@eof4096|ret=0 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[0..3995]
CR1|exfat/small/pread@eof4096|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 0
CR1|exfat/empty/pread@0|ret=0 clobbered_beyond_ret=0 ... clean: buffer beyond returned count untouched
CR1|exfat/victim/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[100..4095]
CR1|end|anomalies=7
CR1_DONE child_status=10752
```

ramfs and exfat over-deliver 3996 bytes (up to capacity) on both the `pread64` and shared-offset `read` paths, including after an EOF read that returns 0; ext2 is clean in every case; the zero-capacity (empty file) branch exists but is masked by caller-side clamping to `read_len = 0`, so it is a benign sub-case today. The exfat donor/victim probe shows the over-delivered tail is zeros in this environment: a new file's first page-commit is short-circuited to `BioStatus::Zeros` while `inner.size == 0` (exfat/inode.rs:158-164) and the subsequent full-page writeback zeroes the on-disk tail, so the stale-data flavor is not reachable this way; the over-delivery defect itself is fully demonstrated.

## Recommendation

Resolve the contract conflict at the `PageCache` boundary, not per-caller: make `PageCache as VmIo` honor the no-short-read obligation — e.g., have `PageCache::read` return `EINVAL` when `offset + writer.avail()` exceeds capacity (matching the `HasVmReaderWriter` and `IoMem` impls), and give filesystems the explicit clamped interface (a `read_up_to`/return-count method, or keep the VMO method `pub(crate)`-only and have ramfs/exfat adopt ext2's `writer.limit(read_len)` discipline). At minimum, ramfs (`fs_impls/ramfs/fs.rs` `read_at`) and exfat (`fs_impls/exfat/inode.rs:667`) must limit the writer to their size-clamped `read_len` before calling `page_cache.read`, so a returned count always accounts for every byte delivered to userspace.
