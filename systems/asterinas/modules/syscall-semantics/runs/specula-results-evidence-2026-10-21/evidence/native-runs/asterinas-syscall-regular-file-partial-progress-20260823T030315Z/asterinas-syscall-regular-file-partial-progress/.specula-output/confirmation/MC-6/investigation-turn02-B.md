# MC-6 — Challenger investigation (turn 2, Agent B)

Extends `investigation.md`; does not replace it. Everything below was run or
read this turn. Pristine kernel throughout (`git status --short -- kernel/`
empty apart from the two untracked `tla_trace.rs` files).

New reproduction artifacts:
- `repro/test_bugMC-6_extend_rollback_free.c`
- `repro/test_bugMC-6_extend_rollback_free.sh`
- outputs in `repro/out_bugMC-6_extend/`

## 1. Turn 1's Linux plank — independently re-verified

Rebuilt and re-ran turn 1's binary on the host (kernel 7.1.9, ext4):

```
CASE A frag_boundary   ret=-1 errno=14 requested=8192 committed=4096 VERDICT=COMMIT_WITHOUT_REPORT
CASE B frag_midrun     ret=-1 errno=14 requested=8192 committed=6144 VERDICT=COMMIT_WITHOUT_REPORT
CASE C contig_control  ret=-1 errno=14 requested=8192 committed=4096 VERDICT=COMMIT_WITHOUT_REPORT
```

So "EFAULT with a committed prefix" is Linux's own O_DIRECT behaviour, and
Asterinas commits *less* than Linux in every case. That consequence class is
also already owned by MC-2, which is `REPRODUCED` on the divergent (buffered)
path: `MC2_VERDICT ... RETAINED_PREFIX_UNREPORTED reported=0 committed=N`,
`MC2_RESULT DIVERGES_FROM_LINUX`. MC-6's *distinct* claim is only the
pending-BIO one.

## 2. The gap in turn 1's reproduction: the cleanup path was never run

The counterexample is `rangeClass="InPlace"`, where `rollback_write`
(`file.rs:205-208`) returns immediately because `end <= old_size`. Turn 1's
A–G all use that shape. Turn 1's own recommendation names the untested one —
"the extending-write path additionally frees blocks in `rollback_write` while a
write to a sibling block is still in flight" — and case G is not it: G frees via
a *user* `ftruncate` after the syscall returned, and hands the block back to the
same file. `phases/02-reproduction.md` requires the delete/cleanup path to be
exercised before settling.

New cases J/J2 run it end to end, entirely through syscalls:

1. fill the volume to ENOSPC with one-block files + a filler, then unlink
   alternate one-block files, so the only free blocks are isolated singletons;
2. **phase 1 (positive control)** extend the victim to 8192 with a good buffer,
   then repeat turn 1's in-place faulting pwrite. Reading back `CTRL,BASE`
   proves the layout produced two mapped runs *and* that run 1 was submitted
   before run 2 faulted. `ftruncate(victim, 0)` then returns those two blocks;
3. **phase 2 (subject)** the same faulting pwrite, now extending from size 0:
   run 1 (pattern `V`) is submitted, run 2 faults, `write_direct_at` calls
   `rollback_write(0, 8192)` → `truncate_to_byte_len(0)`, freeing both blocks
   while run 1's BIO is live. `statvfs` before/after confirms the free count
   came back;
4. a different file immediately claims the lowest free block and writes `T`.
   Reading back `V` would mean an EFAULT-reporting syscall corrupted an
   unrelated file.

Result (`repro/out_bugMC-6_extend/asterinas.log`):

```
/nvme  CASE J  full_extend_xfile     rounds=32 control_ok=32 control_bad=0 freed_ok=32 clobbered=0 intact=32 filled_blocks=61143
/nvme  CASE J2 full_extend_pressure  rounds=32 control_ok=32 control_bad=0 freed_ok=26 clobbered=0 intact=32 background_ops=255
/ext2  CASE J  full_extend_xfile     rounds=32 control_ok=32 control_bad=0 freed_ok=32 clobbered=0 intact=32 filled_blocks=514587
/ext2  CASE J2 full_extend_pressure  rounds=32 control_ok=32 control_bad=0 freed_ok=25 clobbered=0 intact=32 background_ops=219
```

`control_ok=32/32` everywhere: the shape really was exercised. `clobbered=0`.
(`freed_leak` under pressure is sampling noise — the background writer allocates
between the two `statvfs` calls; the quiet runs are 32/32 `freed_ok`.)

## 3. The mask is broader than turn 1 stated, and holds on a second driver

Turn 1 named the mask "the single in-order virtio-blk virtqueue". Two corrections:

**It is not virtio-specific.** The default QEMU configuration already attaches a
second block device: `-device nvme,drive=nvme0n1` (`tools/qemu_args.sh:231-232`)
backed by the 256 MiB ext2 image `test/initramfs/Makefile:$(SSD_IMAGE)`, driven
by the in-tree `aster-nvme`, whose worker thread is spawned alongside the virtio
one (`kernel/core/src/device/registry/block.rs:44-55`). NVMe permits
out-of-order execution and completion within a submission queue, so if in-order
virtio were the whole mask, this is where it would let go. It does not:

```
/nvme  CASE A frag_boundary  ret=-1 errno=14 committed=4096  VERDICT=COMMIT_WITHOUT_REPORT
/nvme  CASE C contig_control ret=-1 errno=14 committed=0     VERDICT=NO_PUBLICATION
/nvme  CASE D pending_visible rounds=64 already_published=64 VERDICT=NOT_OBSERVED
/nvme  CASE E stale_clobber   rounds=64 clobbered=0 intact=64 VERDICT=NOT_OBSERVED
/nvme  CASE F queue_pressure  rounds=64 clobbered=0 intact=64 VERDICT=NOT_OBSERVED
/nvme  CASE G free_realloc    rounds=64 clobbered=0 intact=64 VERDICT=NOT_OBSERVED
```

The mechanism reproduces identically on NVMe (A/B publish, C does not); the harm
does not.

**What actually masks it** is a total submission order plus a synchronous
barrier at every reallocation:

- one FIFO software staging queue per device — `enqueue` `push_front`
  (`request_queue.rs:74`), `dequeue` `pop_back` (`request_queue.rs:91`), merging
  only strictly adjacent sector ranges (`can_merge`, `request_queue.rs:191-200`,
  so no overlapping merge);
- exactly one dedicated worker thread drains it per device
  (`device/registry/block.rs:32-42` virtio, `:44-55` NVMe), so the orphan is
  handed to the controller strictly before anything issued later;
- every newly allocated data block is zeroed with a *blocking* `wait_all()`
  before it is linked into the tree (`block_ptr_tree.rs:673-694`
  `zero_new_blocks`), so a reallocated block's zeroing write is submitted after
  the orphan and the reallocation cannot complete until its own write has.

The residual window is device-side completion reordering only. Across the two
turns it lost 0 times in 64×(D,E,F,G) on virtio, 64×(D,E,F,G) on NVMe, and
32×(J,J2) on each device.

## 4. A further reachability constraint neither the finding nor turn 1 states

`BlockGroup::alloc_blocks` (`block_group.rs:275-296`) calls
`alloc_consecutive(requested_count)` and only halves `requested_count` when that
fails. So while *any* two adjacent free blocks exist in the goal group, a fresh
2-block allocation comes back contiguous — one mapped run — and the user-copy
fault then happens before anything is submitted, so there is no orphan at all.

Cases H/H2 measure this: on a merely fragmented (not full) volume the positive
control fails every single round, on both devices:

```
/ext2  CASE H  sparse_extend_xfile    rounds=64 control_ok=0 control_bad=64 VERDICT=SETUP_FAILED
/nvme  CASE H  sparse_extend_xfile    rounds=64 control_ok=0 control_bad=64 VERDICT=SETUP_FAILED
```

Forcing two runs in a *newly allocated* range required filling the volume to
ENOSPC first. So the write-after-free variant of MC-6 needs a block group with
no two adjacent free blocks — an aged, near-full filesystem. Reachable, but a
precondition the finding's severity narrative does not mention. The in-place
shape (the counterexample's own) has no such constraint but also nothing to
corrupt.

## 5. Why not PENDING REPAIR (INVARIANT)

The invariant is code-anchored and matches a contract the implementation itself
states.

- `base.tla:647-652`: `NoUnaccountedPendingEffect == \A bio \in pendingBios :
  BioAttempt(bio) \in ActiveAttempts`, cited to `ext2/inode/file.rs:383-405` and
  `io-util/src/batch.rs:147-164`.
- `io-util/src/batch.rs:12-16` (verbatim): "The submission path pushes a
  completion record only when the operation will complete asynchronously. **The
  caller then waits for all records that were added to the batch.**"
- J/J2 measured the concrete defect the invariant is guarding against: a device
  block returned to the free bitmap while the kernel's own unwaited write into
  it is outstanding.

That is a real defect against the module's own documented contract, so the
counterexample is not flagging a benign state. `INVARIANT` is unsupportable, and
`FALSE POSITIVE` / `DROPPED` are not available to an MC finding.

## Conclusion

Reachability of the mechanism: proven at Level 0 on two independent block
drivers. Consequence: not demonstrated, and the mask now proven across both
drivers, quiet and under queue pressure, and — new this turn — on the cleanup
path that turn 1 never ran. Verdict unchanged from turn 1, with a corrected
statement of the mask: **MASKED**.
