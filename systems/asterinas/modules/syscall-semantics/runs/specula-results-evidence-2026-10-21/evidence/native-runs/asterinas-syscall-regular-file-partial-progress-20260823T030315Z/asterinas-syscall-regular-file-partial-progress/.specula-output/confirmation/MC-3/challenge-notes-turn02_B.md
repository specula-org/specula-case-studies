# MC-3 — Challenge notes (turn 2, Agent B, adversarial)

Attacked both bars. Neither broke. Concede REPRODUCED.

## Bar 1 — Reachability: nothing to attack

Level 0 in A's run and in my own independent run: unprivileged public syscalls
(open/pwrite/ftruncate/pread/read/lseek/preadv), single thread, no faults, no
failpoints, no timing help, no source patch. `git status --short -- kernel ostd`
in the tree under test is empty before *and* after my run — only initramfs
wiring is added. `/mc3` is on the RamFs rootfs
(`fs/vfs/path/mount_namespace.rs:102` -> `ramfs/fs.rs:64 new_rootfs()`).

The CE step `MCSysPread64Start(t1,"Ramfs",1)` with `fileSize = 2` is
instantiated verbatim (case1 / C5), not approximated.

## Bar 2 — Consequence: hunted for a mask, found none that covers the path

Masks checked and ruled out by reading the code, not by assumption:

- `sys_pread64` (`syscall/pread64.rs:33-37`): `user_space.writer(ptr, len)` is
  handed straight to `file.read_at` — no clamp.
- `InodeHandle::read` / `read_at` (`fs/file/inode_handle.rs:273-291`,
  `396-406`): forwards the writer unchanged — no clamp.
- `PageCache::read` -> `Vmo::read` (`vm/page_cache/vmo/mod.rs:534-535`): bound is
  `self.size()`, the page-aligned capacity, by documented design
  (`page_cache/mod.rs:181-186`: "may exceed the file size. The filesystem
  remains responsible for tracking EOF separately").
- In-kernel callers (ELF loader) slice by the returned length. That masks the
  in-kernel paths ONLY; it does not touch the reproduced syscall path.
- Permanence: every assertion is made after the syscall returns. Nothing
  repairs the buffer.

## What I added beyond A's repro

`repro/test_bugMC-3_eof_consumer_harm.{c,sh}` — one boot, both payloads.
Independent re-run reproduced A's six violations byte-for-byte, plus:

| Case | Linux | Asterinas |
|---|---|---|
| C1 short/old-format record read over caller defaults | `timeout_ms=5000 retries=3 name="default-profile"` | `timeout_ms=0 retries=0 name=""` — WRONG_OUTCOME |
| C2 `preadv` iov[1] = live unrelated object | magic/payload intact 60/60 | magic zeroed, payload 0/60 — WRONG_OUTCOME |
| C3 past-EOF window after truncate | untouched | `zeroed=4086 stale_pre_truncate=0` |
| C4 negative control: page-aligned file (cap == EOF) | no clobber | **no clobber — control HELD** |

- C1/C2 lift the harm from "sentinel bytes differ" to an application-level wrong
  result: a config record silently loses its caller-supplied defaults, and a
  short `preadv` destroys a live object the return value says was not written.
- C3 settles severity: the extra bytes are zeros, not resurrected pre-truncate
  content. Contract/integrity defect, not a disclosure of deleted data —
  A's Medium is right.
- C4 was my strongest available objection ("the test just measures Asterinas
  zeroing buffers"). It held: with a page-aligned file, capacity == EOF and
  nothing past EOF is touched. That pins the defect to the cited mechanism —
  page-aligned page-cache capacity exceeding logical EOF at `ramfs/fs.rs:709`.

## Corrections to A's recommendation (fix shape, not the verdict)

1. `VmWriter::limit(&mut self, max_avail) -> &mut Self`
   (`ostd/src/mm/io/mod.rs:919-925`) permanently shrinks the caller's writer.
   The ext2 form is safe only because each iovec entry gets a fresh writer.
   virtiofs's form is safer for a shared `&mut VmWriter`:
   `clone_exclusive()` + `limit(read_len)` + `writer.skip(read_len)`
   (`virtiofs/inode/ops.rs:74-79`).
2. The fix must cover `read_len == 0`, which is the case2/C2 shape (read at or
   past EOF returns 0 and still clobbers). ext2 early-returns
   (`ext2/inode/file.rs:233-236`); ramfs has no such guard.
3. A's secondary note is accurate: `self.size()` is read before
   `page_cache.lock()` (`ramfs/fs.rs:704-709`) — the CE's SnapshotSize-before-
   AcquireData ordering. Secondary to the headline, worth folding into the fix.

Verdict: REPRODUCED (agree with A).
