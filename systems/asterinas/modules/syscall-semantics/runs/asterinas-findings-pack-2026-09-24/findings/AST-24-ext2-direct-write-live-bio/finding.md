# AST-24: ext2 direct-write fault/rollback can leave an earlier BIO live

| Field | Value |
|---|---|
| Evidence status | MASKED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-6, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | `pwrite64`, `write` on an `O_DIRECT` ext2 file |
| Upstream | related (RELATED_ONLY): #3297 (open draft, `InodeRollbackGuard` for ext2 write errors), #3604 (open exFAT xfstests tracking issue, VMO writeback returns after partial submission) |
| Fix | unfixed. Excluded from the 01a v5 repair. |
| Reproducer | repro/ (runtime run at 604948581, SMP=2: mechanism observed, harm not observed, MASKED) |

## Summary

When an `O_DIRECT` write on ext2 spans two non-adjacent device runs and the user
buffer faults while copying the second run, the first run's BIO has already
been submitted. The error path drops the `IoBatch` without waiting, rolls back
metadata, and returns `EFAULT` while that BIO is still in flight. On the
extending path, rollback frees the blocks while the orphaned write still
targets one of them. No wrong outcome was observed, because the block layer
completed the orphaned write before any later request in every run.

## Linux contract

Linux `iomap_dio_rw` waits for every submitted BIO before returning, including
on the error path, so no I/O from a failed call outlives the call. Linux ext4
also returns `EFAULT` with a committed prefix for this shape (host kernel
7.1.9 control: 4096, 6144, and 4096 bytes committed for cases A, B, C), so
"EFAULT with committed bytes" by itself is not a Linux-contract violation. The
in-tree contract is `kernel/libs/io-util/src/batch.rs`: "The caller then waits
for all records that were added to the batch."

## Asterinas behavior

At the pin, `kernel/core/src/fs/fs_impls/ext2/inode/file.rs::InodeInner::write_direct_blocks`
walks the write one mapped device run at a time. For each run it allocates a
`BioSegment`, copies user bytes with `write_fallible(reader)?`, and submits it
asynchronously into a local `kernel/libs/io-util/src/batch.rs::IoBatch`.
`io_batch.wait_all()` runs only after the loop. A fault on a later run returns
through the `?` and drops the batch. `IoBatch` has no `Drop` impl and no cancel
API, and `Bio::submit` enqueues the request before recording the waiter, so
dropping the batch neither waits nor cancels. `InodeInner::write_direct_at`
then calls `rollback_write`. For an extending write that truncates the new
blocks back to the free bitmap while the first run's BIO is live.

Observed at the pin (01a MC-6, pristine kernel, `/ext2` on virtio-blk):

```
CASE   SHAPE            LINUX                    ASTERINAS
A      frag_boundary    COMMIT_WITHOUT_REPORT    COMMIT_WITHOUT_REPORT
B      frag_midrun      COMMIT_WITHOUT_REPORT    COMMIT_WITHOUT_REPORT
C      contig_control   COMMIT_WITHOUT_REPORT    NO_PUBLICATION
D      pending_visible  NOT_OBSERVED             NOT_OBSERVED
E      stale_clobber    NOT_OBSERVED             NOT_OBSERVED
F      queue_pressure   NOT_OBSERVED             NOT_OBSERVED
G      free_realloc     NOT_OBSERVED             NOT_OBSERVED
```

Cases A and B publish 4096 bytes after `EFAULT`, and contiguous control C
publishes nothing, which isolates the already-submitted first run. D to G (64
rounds each) never saw late publication or a clobbered later write. The
debater's extending-write cases J and J2 (32 rounds each on `/ext2` and on the
NVMe-backed `/nvme`) freed the blocks under the live BIO and still saw
`clobbered=0 intact=32`.

## Reproduction

`repro/test_bugMC-6_direct_write_pending_bio.c` (cases A to G) and
`repro/test_bugMC-6_extend_rollback_free.c` (cases H, H2, J, J2) take the target
directory as an argument and run on Linux as a control and in the Asterinas
guest. The drivers boot a pristine kernel with SMP=2. See `repro/README.md`.

## Fix and upstream status

Register: "Observed backend masks harm; excluded from 01a v5 repair."
matches.json: RELATED_ONLY, upstream fix status NOT_ESTABLISHED. #3297 adds
rollback guards without establishing outstanding-BIO completion safety. The
01a confirmation recommended giving `IoBatch` a `Drop` that calls `wait_all()`,
restructuring `write_direct_blocks` to copy every run before submitting any,
and deciding the result from committed bytes. No patch exists.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md (Entry 6)
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-6/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-6/investigation-turn02-B.md
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-6/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/out_bugMC-6/
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/out_bugMC-6_extend/
- /home/chin39/Documents/play/specula-profile/references/active-specula-run-handoff.md (01a completion record)

## Caveats

- MASKED, not REPRODUCED: the mechanism (an unwaited BIO after `EFAULT`) was
  observed, but no consumer saw a wrong outcome.
- The two confirmation turns named different masks. Turn 1 named the single
  in-order virtio-blk virtqueue. The debater corrected it: the mask is one FIFO
  staging queue drained by one worker thread per device plus the blocking
  `wait_all()` in `zero_new_blocks` on every block allocation, and it held on
  NVMe too. The 01a handoff summary still says "masked by single in-order
  virtqueue".
- The write-after-free variant needs a near-full block group: while two
  adjacent free blocks exist, a two-block allocation is contiguous and no
  orphan BIO forms (cases H and H2).
- A backend that completes requests out of order, or a different staging
  design, could remove the mask. That was argued, not demonstrated.
- The drivers expect `confirmation/MC-6/worktree`, which no longer exists in
  the run directory, and the Specula initramfs hooks (`ENABLE_SPECULA_TRACE`,
  `SPECULA_INIT`). The kernel under test was pristine.
