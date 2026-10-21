# MC-7 investigation — ExFAT zero-count positional writes can enlarge the file

Finding: `pwrite64(fd, buf, 0, off)` with `off > size` on exFAT enlarges the file
(size := off, clusters allocated), returns 0. Invariant: EmptyWriteNoEffect.
Source: MC (real counterexample `spec/output/MC_hunt_s4_empty_exfat_bfs1.out`).

## Step 1 — code audit

### Counterexample (MC_hunt_s4_empty_exfat_bfs1.out)
13 states, one action: `MCSyscallEnter(t0,<<"pwrite64", 4, 0, 0, 0>>)` (O=4, N=0)
on a file of size L=2:
- ExfatAllocate: A 2→4, clusters 1→2 (cluster allocation on a 0-byte write)
- ResizeCapacity: C 2→4 (page-cache bound enlarged)
- VmoBegin: `ioKind="Write", ioOff=4, ioLen=0` — zero-byte copy
- ExfatWritePublish: **L 2→4** — logical size published as `ioEnd=4`
- Return: `status="Ok", result=0`, `positionBefore=positionAfter=0`
→ invariant `EmptyWriteNoEffect` violated.

### Cited code (pristine line numbers, `git show HEAD:...`; identical to current upstream `main`)
`kernel/core/src/fs/fs_impls/exfat/inode.rs`, `ExfatInode::write_at` (buffered path,
selected whenever O_DIRECT is not set — `FileOps::write_at` dispatches to it):
- L711 `fn write_at(&self, offset, reader)`
- L712 `let write_len = reader.remain();` — no `write_len == 0` early return anywhere
- L722 `let new_size = offset + write_len;` — for a zero write, `new_size == offset`
- L725 `if new_size > file_size {` — extension preparation runs even when write_len==0
  - L727 `inner.resize(new_size, &fs_guard)?` → `ExfatInodeInner::resize` →
    `start_chain.extend_clusters(...)` (real cluster allocation) + `size_allocated = new_size`
  - L729 `inner.page_cache.resize(new_size, file_size)?` — VMO size bound enlarged
- L736 `inner.page_cache.write(offset, reader)?` — zero-byte copy, no-op
- L743 `inner.size = new_size;` — publishes `offset` as logical size
- L755 `Ok(write_len)` — returns 0

### Call chain (all normal entry points, no guard on any of them)
1. `sys_pwrite64` (kernel/core/src/syscall/pwrite64.rs:10): checks `offset >= 0` and
   `offset+len` overflow only; passes len=0 through.
2. `FileLike::write_at` → `InodeHandle::write_at` (kernel/core/src/fs/file/inode_handle.rs:343):
   no zero-count check; only `clear_file_priv` is conditioned on `reader.remain() > 0`.
3. `FileOps for ExfatInode::write_at` → `ExfatInode::write_at` (above).

Reachable via three public syscalls:
- `pwrite64(fd, buf, 0, off)` — the CE scenario.
- `pwritev/pwritev2(fd, iov, cnt, off)` with all-empty iovs: `do_sys_pwritev`
  (kernel/core/src/syscall/pwritev.rs:86-92) — `VmReaderArray::from_user_io_vecs`
  filters empty buffers (kernel/core/src/util/iovec.rs:128-141); when the array is
  empty it deliberately **probes with a zero-length `write_at(offset)`** ("Probe with
  a zero-length write so that unsupported files (e.g., pipes) still return the
  correct errno"). On exFAT this probe extends the file to `offset`.
- `write(fd, buf, 0)` after `lseek(fd, off, SEEK_SET)` — shared-offset path also
  reaches `ExfatInode::write_at` via `InodeHandle::write`.

### Comparison with sibling backends (developer-intent baseline)
- ext2, pristine `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:45-47`:
  `let write_len = reader.remain(); if write_len == 0 { return Ok(0); }` — explicit
  guard at the head of `write_at` (and again in the inner `write_at` and
  `write_direct_at`). Zero-count writes are deliberately no-ops on ext2.
- exFAT has no such guard.

### Linux reference contract (host check, ext4 + tmpfs)
`pwrite(fd, buf, 0, 4096)` on a 2-byte file → ret 0, size stays 2
("LINUX: no effect (size unchanged)" on both ext4 and tmpfs). Linux man write(2):
"If count is zero ... 0 is returned without causing any other effects."

### Safeguards encountered
None on the exFAT path. ext2's guard shows the intended semantics.

### Trigger scenario
`fd = open("/exfat/f", O_RDWR|O_CREAT); write(fd, "AB", 2); pwrite64(fd, buf, 0, 4096);`
→ returns 0; `fstat` shows size 4096 and `st_blocks` grown; `pread` over [2,4096)
returns zero-filled hole. Also via `pwritev(fd, iov, 0, 8192)` (empty-iov probe).

## Step 2 — developer knowledge
- No comment/TODO/FIXME near exFAT `write_at` about zero-length writes; the only
  nearby comment is the page_cache resize-ordering note and "Locks released here,
  so that file write can be parallelized."
- ext2's `if write_len == 0 { return Ok(0); }` is upstream Asterinas code (pristine
  export), evidence the project intends zero-count writes to be no-ops.
- Upstream tracker search (asterinas/asterinas, issues + merged/closed PRs):
  - PR #639 "Add exFAT file system" — initial implementation only.
  - PR #3086 / commit de52fd1 "Fix `preadv`/`pwritev` errno for empty buffer lists" —
    added the zero-length `write_at` **probe** in `do_sys_pwritev` (an amplifier of
    this bug, not a report of it).
  - Mainline-Linux commit 6110151/fda94a9 "exfat: short-circuit zero-byte writes in
    exfat_file_write_iter" — Linux's own exfat driver returning -EFAULT on 0-byte
    writes; different defect (errno), different codebase.
  - Nothing reports "exFAT zero-count positional write enlarges file size" in Asterinas.
- Current upstream `main` `kernel/core/src/fs/fs_impls/exfat/inode.rs` (fetched raw)
  still has the identical unguarded `write_at` — **unfixed today**.

## Step 3 — known-status / precedent
MC-sourced with a real counterexample → the code-review × known pre-filter cannot
apply. No existing issue/PR/CVE/dataset entry reports this exact mechanism at this
site → Novelty: **NEW**.

## Environment / reuse notes
- My worktree is byte-identical to the run-root `source/` (diff -rq, rc=0).
- Harness known-good build: `.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`
  (built 2026-09-08 18:19 from that same source; kernel-latest.log "Finished release").
- Known-good guest boot: harness/logs/guest-20260908T101858Z.log contains `SPECULA_EXIT 0`.
- Recipe: container `asterinas/dev:0.18.1-20260901` on `--network=host --device=/dev/kvm`,
  QEMU `qemu-system-x86_64 -enable-kvm ... -initrd initramfs.cpio -drive ... ext2/exfat images`.
