# MC-6 Investigation — Ramfs zero-count positional writes can enlarge the file

Source: MC (real counterexample `spec/output/MC_hunt_s4_empty_ramfs_bfs1.out`, invariant `EmptyWriteNoEffect`)
Site: `kernel/core/src/fs/fs_impls/ramfs/fs.rs` `RamInode::write_at` (fn starts :733; cited :736/:742; mechanism lines :751-758, :765-766)

## Step 1 — Code audit

### What the code does (worktree == harness-applied source, verified `diff` IDENTICAL)

`RamInode::write_at(offset, reader)` (ramfs/fs.rs:733-779):

```
let write_len = reader.remain();              // :751  -> 0 for an empty reader
let new_size = offset + write_len;            // :752  -> == offset
let should_expand_size = new_size > file_size;// :753  -> true iff offset > EOF
...
if should_expand_size {
    inode_meta.size = new_size;               // :758  publishes offset as the new size
    inode_meta.blocks = new_size_aligned / BLOCK_SIZE;
}
drop(inode_meta);
if should_expand_size {
    page_cache.resize(new_size_aligned, file_size)?;  // :766 grows the cache
}
page_cache.write(offset, reader)?;            // :770 copies 0 bytes, Ok
Ok(write_len)                                 // :772 returns Ok(0)
```

With `write_len == 0` and `offset > file_size`, the call returns `Ok(0)` **but**
`inode_meta.size` becomes `offset` and the page cache is grown/zero-filled.
`RamfsWriteAtPublish` in the CE trace confirms: size 2 → 4, then `Return` with
`result = 0`, `status = Ok` (states 3→9 of the CE).

### Call chain / reachability (all through public syscall interface)

1. `sys_pwrite64` — `kernel/core/src/syscall/pwrite64.rs:10-42`. Only checks
   `offset >= 0` and `offset + len` overflow. **No `len == 0` guard.** Builds
   `user_space.reader(user_buf_ptr, user_buf_len)` and calls
   `file.write_at(offset, &mut reader)` unconditionally.
2. `InodeHandle::write_at` — `kernel/core/src/fs/file/inode_handle.rs:343-372`.
   Guards: `file_ops_for_positional_io()` (ESPIPE for non-seekable), EBADF for
   O_PATH / non-writable, `clear_file_priv` only when `reader.remain() > 0`
   (:348). **No `len == 0` guard** — an empty reader reaches the backend.
3. `RamInode::write_at` — ramfs, no zero-length guard (see above).

`CurrentUserSpace::reader(vaddr, 0)` (`kernel/core/src/context.rs:91-110`)
deliberately does not validate the pointer (Linux delayed buffer validation);
`VmReader` with `remain() == 0` is constructed fine. So `pwrite64(fd, buf, 0, 4)`
on a 2-byte ramfs file reaches the buggy lines through normal usage — a plain,
legal POSIX syscall. Reachability: direct, no race, no fault injection.

`page_cache.resize(new_size_aligned=4096, old=2)` (`vm/page_cache/mod.rs:246`)
zero-fills the tail of the partial old page and grows `vmo.size` 0→4096 — the
region [2,4) becomes readable zeros. `page_cache.write(4, empty)` is a no-op Ok.

### Trigger scenario (natural, single-threaded)

```
fd = open("/ramfs/x", O_CREAT|O_RDWR, 0644);
pwrite(fd, "hi", 2, 0);            // size = 2
pwrite64(fd, buf, 0, 4);           // zero-count positional write beyond EOF
fstat(fd) -> st_size               // expected (Linux/POSIX): 2; actual (ramfs): 4
pread(fd, b, 2, 2)                 // expected: 0 (EOF); actual: 2 zero bytes
```

POSIX write(2): "if nbyte is zero and the file is a regular file ... the write()
function shall return zero and have no other results." Linux (tmpfs/ext4)
returns 0 and leaves the size unchanged. The shared file offset is untouched
(`*offset += len` with len 0) — matches the finding ("shared offset preserved").

### Safeguards encountered

None on this path. `sys_pwrite64` only calls `notify::on_modify` when
`write_len > 0` (:36), so no fsnotify mask. Nothing downstream reverts the size
(no sync/truncate hook). The bad state is permanent until an explicit
`ftruncate`.

### Backend comparison

- **ext2**: `Ext2Inode::write_at` has an explicit guard —
  `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:56-59`:
  `let write_len = reader.remain(); if write_len == 0 { return Ok(0); }`
  (same guard in `write_direct_at` :104). So ext2 honors empty-write-no-effect.
- **exfat**: same unguarded pattern as ramfs (`exfat/inode.rs:740-772`,
  `new_size = offset + write_len`, resizes when `new_size > file_size`).
  MC-6 is scoped to ramfs only; exfat is a separate configuration/finding.
- **ramfs**: unguarded → this finding.

The ext2 guard is in-repo evidence that the developers consider
"zero-length write must not change size" the intended contract, and that ramfs
lacking it is an inconsistency, not a design choice for ramfs.

## Step 2 — Developer knowledge

- **ext2 guard** (above) — strongest intent signal: the codebase itself
  special-cases `write_len == 0` to no-op for ext2 buffered and direct writes.
- **PR asterinas/asterinas#3086 (merged)** "Fix positional I/O error handling
  for pread/pwrite" — touches zero-length preadv/pwritev, but only for the
  *error-validation* side (O_PATH/pipes must return EBADF/ESPIPE instead of
  early Ok(0)). Does not address size changes on regular files. Different
  mechanism.
- **PR asterinas/asterinas#3778 (open)** "Limit page-cache reads to the file
  size in ramfs and exfat" — read-side buffer-overrun fix on the same files;
  cites Linux 7.1.9 tmpfs as the reference. Not the write-size mechanism.
- **Upstream `main` (checked via GitHub blob, same day)**: `RamInode::write_at`
  still has no zero-length guard — defect still present upstream (unfixed).
- No TODO/FIXME near ramfs `write_at`; no test in-tree asserts the ramfs
  zero-write behavior either way (xfstests tracking issue #3142 does not list it).

## Step 3 — Known-status / precedent

Tracker search (GitHub API, asterinas/asterinas, issues+PRs any state):
`zero-length write`, `ramfs write size`, `empty write file size`,
`pwrite size`, `zero byte write`, `pwrite64 zero`, `should_expand_size`,
`zero-count write`, `empty positional write`, `write beyond EOF size`,
`zero length pwrite`. Closest hits reviewed individually: #3086 (errno
validation on unsupported files — different), #3778 (read-side overrun —
different), #3142 (xfstests gap tracker — no zero-write-size entry).
**No existing issue/PR reports THIS mechanism (zero-count positional write
enlarging a ramfs regular file) at THIS site.**

Novelty: **NEW** (searched; nothing found for this mechanism at this site).
Pre-filter: MC-sourced with a real counterexample → proceed to Phase 2
regardless; and it is not already-reported anyway.

## Provenance / environment

- Worktree commit `f5e9e97` = pristine Asterinas export @ 604948581512d8 +
  tla_trace instrumentation; `diff` of
  `harness/applied/kernel/.../ramfs/fs.rs` vs worktree = IDENTICAL.
- Prebuilt instrumented kernel: `.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`,
  sha256 `e446b1de…` matches `harness/identity.json` artifacts entry.
- Runtime: docker `asterinas/dev:0.18.1-20260805`, QEMU/KVM (`/dev/kvm` present).
  Same recipe as the already-executed `repro/test_bugMC-1_run.sh`.
- Guest rootfs: initramfs is unpacked into the bootstrap root, which is
  `RamFs::new_rootfs()` (`kernel/core/src/fs/vfs/path/mount_namespace.rs:102`),
  so files created under `/ramfs/` in the guest are served by `RamInode`.
