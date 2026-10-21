# MC-4 — Challenger (Agent B, turn 2) record

Goal: remove MC-4 unless it clears reachability AND consequence. It cleared both.
Every attack below was run independently; none landed.

## Attack 1 — "the reproduction is not on a pristine kernel" (FAILED)

A's driver filters two untracked files out of its `git status -- kernel/` printout,
so I re-checked from scratch in the worktree:

- `git diff --stat HEAD -- kernel/ ostd/` → **empty** (no tracked kernel source modified).
- The two untracked files (`kernel/core/src/tla_trace.rs`,
  `kernel/core/comps/block/src/tla_trace.rs`) are **not declared as modules**:
  `tla_trace` appears in neither `HEAD:kernel/core/src/lib.rs` nor the worktree copy
  → not compiled. `grep -c tla_trace repro/out_bugMC-4/build.log` → **0**.
- The only tracked modifications are `Makefile` + `test/initramfs/*`, and their diff adds
  exactly one knob (`ENABLE_SPECULA_TRACE`, `SPECULA_INIT` init-args passthrough) to build
  a *userspace* test binary into the initramfs. Kernel logic untouched.
- The guest source is byte-identical to the repro source
  (`diff -q repro/test_bugMC-4_ramfs_size_publication.c
  worktree/test/initramfs/src/regression/io/specula/mc4_size_publication.c` → identical).
- `guest.log` is a real QEMU boot (Asterinas logo, `[kernel] running /init as the init process`)
  followed by the MC4 lines. Not a hand-written log.

## Attack 2 — "the Linux control is cherry-picked / tmpfs-specific" (FAILED)

Recompiled A's C file myself and ran it on two host filesystems:

```
== /dev/shm (tmpfs) ==   MC4_SUMMARY os=linux deviations=0 failures=0
== /tmp (ext4)     ==   MC4_SUMMARY os=linux deviations=0 failures=0
```

Both agree with A's control on every case, including the case-D quirk
(`i_size` moves to the write START offset, 16384, never to `pos + len`). So the
reference is the generic `write_end(copied=0)` rule, not a tmpfs artifact.

## Attack 3 — "a downstream mechanism masks it" (FAILED — no mask exists)

- `InodeHandle::write` / `write_at` (`inode_handle.rs:293-321,334-355`) call
  `file_ops.write_at(...)?` and propagate — no rollback, no size re-derivation.
- Nothing in `ramfs/fs.rs` shrinks the size on a write error; `resize` is only reached
  from `ftruncate`/`fallocate`.
- ramfs has no writeback / sync / fsck path that could correct the metadata later.
- Permanence is measured, not argued: `CASE A size_after_close_reopen=16384`.

## Attack 4 — "the MC invariant over-flags a benign state" (FAILED)

`FileSizeMatchesProgress == dataOwner # NoThread \/ fileSize = AllowedFileSize`
(`spec/base.tla:580`), `AllowedFileSize = Max({expectedFileSize} \cup {plannedEnd[t] :
t \in sizePublicationOwners})` (`base.tla:241-246`). In the CE's final state
`sizePublicationOwners = {}` and `dataOwner = "NoThread"`, so the invariant only fires on
a size that is STILL over-published after the write has finished — exactly the code's
behavior. Not an `INVARIANT` artifact; no `PENDING REPAIR` route.

## Attack 5 — "it is #711 / already reported / already being fixed" (FAILED — and backfired)

- Read #711 in full. Its PoC and its whole discussion are about **short counts vs EFAULT**
  (`read_bytes_from_user` returning `Result<()>` instead of `Result<usize>`); the word
  "size"/`i_size` never appears. Different mechanism.
- Independent tracker search with my own terms (`ramfs inode size`, `tmpfs size write fail`,
  `st_size wrong`, `size grow EFAULT`, `write zero length file size`, `size not rolled back`)
  → nothing reporting this ordering.
- **PR #3481** ("Fix inode append and memfd seal races", OPEN) *rewrites*
  `RamInode::write_at`. Its new body still reads:
  `inode_meta.size = new_size; ... drop(inode_meta); ... page_cache.resize(...)?;
  page_cache.write(offset, reader)?;` — the **same publication-before-copy ordering, still
  no rollback**. The most recent upstream work on this exact function does not fix it.
- **PR #3297** (`InodeRollbackGuard`, OPEN draft) touches only
  `ext2/inode/{file,dir/mod,symlink}.rs` — ramfs out of scope; it is the maintainers'
  own statement that restore-on-error is the intended semantics.
- Upstream `main` today (`contents/kernel/core/src/fs/fs_impls/ramfs/fs.rs?ref=main`) is
  byte-identical at lines 721-756. Unfixed.

⇒ `Novelty: NEW` stands.

## Correction to A's turn (widens the finding, does not weaken it)

A wrote that the timestamp half of the finding's summary "is not a Linux deviation"
because Linux stamps mtime/ctime before the copy. That is right for the **fault** cases
and wrong as a blanket claim. Measured on Linux (`/tmp/mc4_mtime.c`, tmpfs and ext4 agree):

```
A faulting_extending_pwrite     ret=-1 errno=14 mtime_changed=1 ctime_changed=1
B zero_length_pwrite_past_eof   ret=0  errno=0  mtime_changed=0 ctime_changed=0
```

Linux skips `__generic_file_write_iter` entirely when `count == 0`, so a zero-length write
stamps nothing. Asterinas' `inode_meta.set_mtime(now)` / `set_ctime(now)`
(`ramfs/fs.rs:739-740`) sit **outside** the `should_expand_size` guard and run
unconditionally, including for `write_len == 0` — and case B proves that path executes on
the guest (the size moved). So there is an extra timestamp deviation in the zero-length
case. **Not measured on the guest** — code-level only; report it as such or leave it out.

## Bars

- **Reachability**: Level 0. `open/pwrite/write/lseek/fstat/pread/mmap/mprotect` only, no
  failpoints, no state injection, pristine kernel. The fault source is a `PROT_NONE` first
  page — an ordinary guard page / partially-unmapped buffer / bad pointer. Case B needs no
  fault at all: `pwrite(fd, buf, 0, 16384)` grows the file and returns success. CLEARED.
- **Consequence**: `st_size` (`syscall/stat.rs:200`), `lseek(SEEK_END)` and `read`
  (`ramfs/fs.rs:695-718` clamps to the inflated size) all report bytes the file never
  received — `pread` past the old EOF returns 4096 zero bytes where Linux returns 0 —
  and it survives close/reopen. CLEARED.

Optional strengthening (not required for the verdict): read the *whole* phantom range in
cases A/E instead of a 4096-byte sink, and exercise the same function through
`memfd_create` (PR #3481 routes memfd writes into this identical path).

VERDICT: REPRODUCED
