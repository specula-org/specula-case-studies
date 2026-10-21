# MC-6 — Investigation (Phase 1, evidence only)

Finding: "Ext2 direct write returns while an earlier submitted BIO remains live"
Source: model checking, counterexample
`spec/output/MC_hunt_finding_mc2_direct_completion_bfs.out`
Invariant: `MCNoUnaccountedPendingEffect`

All `file.rs` line numbers below are the worktree's instrumented copy
(`confirmation/MC-6/worktree`); the instrumentation only adds `tla_trace::*`
calls and does not alter control flow. The reproduction is built from the
pristine kernel (`git checkout -- kernel/`).

Pristine-kernel line numbers for the same sites (what a fix would touch):

| site | instrumented | pristine |
|---|---|---|
| `IoBatch::new()` in `write_direct_blocks` | file.rs:590 | file.rs:383 |
| user-copy fault abandons the batch | file.rs:620 | file.rs:389 (`write_fallible(reader)?`) |
| `io_batch.wait_all()?` | file.rs:667 | file.rs:405 |
| `rollback_write` + `return Err` | file.rs:516 | file.rs:319 |
| `IoBatch` (no `Drop`, no cancel) | batch.rs:107 | batch.rs:107 |
| `io_batch.push` after `enqueue` | bio.rs:167 | bio.rs:149 |

## Step 1 — Code audit

### The loop and its early returns

`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:568` `write_direct_blocks`:

```rust
let mut io_batch = IoBatch::new();                                  // :590
let mut logical_offset = offset;
while let Some(range) = range_iter.next()? {
    match range {
        IoRange::Mapped(device_range) => {
            let bio_segment = BioSegment::alloc(nblocks, BioDirection::ToDevice);
            let copy_result = bio_segment.writer().unwrap().write_fallible(reader);
            match copy_result {
                Ok(_)  => { /* trace */ }
                Err((err, _)) => { return Err(err.into()); }        // :620  EARLY RETURN
            }
            fs.write_blocks_async(device_range.start, bio_segment, None, &mut io_batch)?;
            logical_offset += range_bytes;
        }
        IoRange::Hole(_) => {
            return_errno_with_message!(Errno::EIO, "unexpected hole ...");  // EARLY RETURN
        }
    }
}
io_batch.wait_all()?;                                               // :667
```

`IoRangeIter::next` (`ext2/inode/io_range.rs:44`) yields one `IoRange::Mapped`
per *contiguous device-block run*, so a fragmented file produces several
submit-then-copy iterations.

### `IoBatch` has no drop-time wait and no cancel

`kernel/libs/io-util/src/batch.rs:107` defines `IoBatch` as a plain
`SmallVec<[Arc<dyn IoCompletion>; 1]>`. It is `#[must_use]`, which only warns on
an unused *value*; it has **no `Drop` impl**, no `cancel`, and no other method
besides `push` / `len` / `is_empty` / `wait_all` / `Index`. Dropping it therefore
just drops the `Arc`s.

`Bio::submit` (`kernel/core/comps/block/src/bio.rs:126`) hands the
`SubmittedBio` to `block_device.enqueue(..)` *first* and pushes the
`BioMetadata` waiter into the batch afterwards (`bio.rs:167`). Once `enqueue`
returns, the device owns the request; the batch entry is only a waiter handle.
Dropping the waiter does not stop, cancel, or account for the request — the
driver still calls `SubmittedBio::complete` (`bio.rs:278`) later.

For virtio-blk (`kernel/core/comps/virtio/src/device/block/device.rs:133`)
`enqueue` pushes onto the virtqueue and returns; completion runs from the
device's interrupt path. So the request is genuinely asynchronous.

### The error path releases everything

`InodeInner::write_direct_at` (`file.rs:480`):

```rust
if let Err(err) = self.write_direct_blocks(fs, offset, reader) {    // :516
    self.rollback_write(old_size, end);
    return Err(err);
}
```

`rollback_write` (`file.rs:241`) is a no-op when `end <= old_size` (the in-place
overwrite shape of the counterexample); when the write extended the file it
resizes the page cache back and calls `truncate_to_byte_len(old_size)`, which
frees every block allocated beyond `old_size`.

`Inode::write_direct_at` (`file.rs:102`) then drops the `self.inner.write()`
guard and returns the error; `sys_pwrite64`
(`kernel/core/src/syscall/pwrite64.rs:42`) propagates it verbatim, so user space
sees `-1 / EFAULT` with no byte count.

### Call chain from user space (reachable, no privilege needed)

`pwrite64(fd, buf, len, off)` → `sys_pwrite64` → `InodeHandle::write_at`
(`kernel/core/src/fs/file/inode_handle.rs:470`, passes `status_flags`) →
`Ext2Inode::write_at` (`ext2/impl_for_vfs/inode.rs:55`, `O_DIRECT` →
`write_direct_at`) → `InodeInner::write_direct_at` → `write_direct_blocks`.
Only requirement: block-aligned offset and length (`file.rs:117`).

### Trigger scenario

1. `/ext2` is a real ext2 volume in the standard guest
   (`test/initramfs/src/init` mounts `/dev/vda` on `/ext2`).
2. Fragment a victim file: one-block direct write to the victim, one-block
   direct write to a spacer file, then one more block to the victim. The ext2
   allocator is first-fit over the group bitmap and ignores the goal hint
   (`ext2/block_group.rs:290` `alloc_consecutive`, with the standing
   `TODO: Improve bitmap allocation to reduce fragmentation`), so the victim's
   two logical blocks land on non-adjacent device blocks → two mapped runs.
3. `mmap` three anonymous pages, `mprotect(PROT_NONE)` the last one, and
   `pwrite` 8192 bytes at offset 0 from that buffer.
4. Run 1 copies fully and is submitted; run 2's `write_fallible` faults; the
   early return at `file.rs:620` drops the batch with a live BIO in it.

Safeguards found and recorded (Phase 2 must test whether they fire):
- the inode `RwMutex` — released *before* the stale BIO is known to have landed,
  so it does not order the stale BIO against later operations;
- the single virtio-blk virtqueue — requests are enqueued in FIFO order, which
  may in practice make the stale BIO land before any later request;
- `page_cache().invalidate_range(..)` runs before the copy, so subsequent reads
  come from the device rather than from a stale cached page.

### Matching the counterexample

`MC_hunt_finding_mc2_direct_completion_bfs.out`:
- State 3 `MCSysPwrite64Start(t2,"Ext2Direct","Complete",0,"UpToDate")` — an
  `O_DIRECT` `pwrite64` at offset 0 for the whole length;
- State 9 `MCBioSegmentWriteFallibleFaultZero(t2)` — the current part's copy
  faults with zero bytes copied;
- State 13 `result[t2]="Fault"`, `pc[t2]="Idle"`,
  `pendingBios = {<<t2,1,1,0,1,0>>}` — the syscall has returned EFAULT while
  part 1's BIO is still pending. `rangeClass="InPlace"`, `oldFileSize=2`,
  `plannedEnd=2`, `fileSize=2` — an in-place two-block overwrite.

The repro's CASE A instantiates exactly this shape.

## Step 2 — Developer-knowledge search

- **Comments at the site.** `file.rs:653-661` (the `IoRange::Hole` arm) states
  the developers' ordering belief verbatim: *"Stale-read is not a concern
  because our inode-level lock serializes reads after this write."* With an
  unwaited BIO that premise does not hold for the error path — the lock is
  released while the write is still in flight. There is no comment anywhere
  about the dropped batch.
- **`IoBatch` docs.** `batch.rs:1-64` documents the intended contract: *"The
  caller then waits for all records that were added to the batch."* Nothing
  says what happens if the caller does not.
- **Other `IoBatch` callers.** `vm/page_cache/mod.rs:402-404`,
  `vm/page_cache/vmo/mod.rs:917-922`, `bio.rs:182-184`,
  `nvme/.../block_device.rs:923-943` all keep submission and `wait_all` in the
  same straight-line region with no fallible step in between. `file.rs:590-667`
  is the only site that has fallible work interleaved with submissions.
- **Commits / blame.** The run's baseline is a single squashed commit, so local
  blame is unavailable. Upstream history for the two files:
  `kernel/libs/io-util/src/batch.rs` — last touched by `c4da9d28`
  "Rename `io_util` to `io-util`" (2026-05-14), no semantic change;
  `kernel/core/comps/block/src/bio.rs` — `8acf72b4` "Fix BIO completion
  ordering" (2026-08-12) + `33acbe81` (2026-08-13), which move
  `general_complete_fn` before the status CAS and make `status()` an
  `Acquire` load. That fix is about *when a completion becomes visible*, not
  about un-waited batches, and it is already present in the baseline.
- **Tests.** `file.rs` ktest `file_write_enospc_rollback` covers the
  `prepare_write` ENOSPC rollback, i.e. a failure *before* any submission. No
  test covers a failure *after* a submission.

Nothing found asserts the current behavior is intended.

## Step 3 — Known-status / precedent

Searched `asterinas/asterinas` issues and PRs (open **and** merged/closed) for:
`IoBatch`, `wait_all`, `write_direct_blocks`, `O_DIRECT`, `direct I/O`,
`EFAULT partial`, `partial copy fault write`, `bio leak`,
`asynchronous write not waited`, `bio pending after error`,
`ext2 direct write rollback`; plus the upstream commit history of
`ext2/inode/file.rs`, `io-util/src/batch.rs` and `block/src/bio.rs`.

Nearest hits, none of which report this mechanism at this site:
- #2835 (closed) "Ext2 O_DIRECT read cannot return data from disk" — read path,
  different defect.
- #3142 "Tracking issue for gaps found by `xfstests`" — lists an O_DIRECT
  *sector-alignment* gap (`generic/091,263,418,450`), not error-path BIO
  accounting.
- #3257 "Locking same page in `Vmo::write` and page fault handler will
  deadlock" — page-cache locking, different path.
- PR #3509 "Add `O_DIRECT` support for virtiofs regular-file I/O" (merged) —
  adds a different filesystem's direct path.
- `8acf72b4` / `33acbe81` — completion-visibility ordering, as above.

The `TODO: Improve bitmap allocation to reduce fragmentation`
(`block_group.rs:286`) and the `TODO: Consider falling back to buffered write
like Linux` (`file.rs:654`) are developer suspicion about *other* aspects, which
per the skill do not make this finding known.

**Novelty: NEW.** MC-sourced with a real counterexample, so the code-review ×
known pre-filter does not apply either way. Proceed to Phase 2.
