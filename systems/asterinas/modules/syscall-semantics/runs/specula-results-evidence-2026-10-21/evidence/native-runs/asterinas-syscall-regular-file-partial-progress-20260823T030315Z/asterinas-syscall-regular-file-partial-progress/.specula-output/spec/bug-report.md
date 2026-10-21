# Bug Report — Asterinas regular-file partial progress

## Summary

- Scenarios tested: 12 focused BFS configurations covering all six modeling-brief scenarios and the MC1/MC2/delayed-BIO specializations
- Bugs found: 7
- Configs run: `MC_hunt_finding_delayed_bio_vector.cfg`, `MC_hunt_finding_mc1_later_iovec_fault.cfg`, `MC_hunt_finding_mc2_direct_completion.cfg`, `MC_hunt_scenario_1_mixed_page_prefix.cfg`, `MC_hunt_scenario_1_positive_copy_progress.cfg`, `MC_hunt_scenario_2_backend_publication.cfg`, `MC_hunt_scenario_3_append_gap.cfg`, `MC_hunt_scenario_3_vector_atomicity.cfg`, `MC_hunt_scenario_4_positional_offset.cfg`, `MC_hunt_scenario_5_append_failure.cfg`, `MC_hunt_scenario_6_effect_replay.cfg`, `MC_hunt_scenario_6_restart.cfg`
- Convergence: all six pinned traces and the reference-capability trace passed complete post-state replay; the final no-symmetry `MC.cfg` run found no standard, structural, BIO-lifecycle, or lock-liveness violation in 30 minutes, reaching depth 19 with 54,252,624 generated and 13,188,151 distinct states
- Simulations: none required; every hunting BFS found a violation before its 30-minute budget

## Bug 1: A positive read prefix is exposed but returned as EFAULT

- **Scenario**: 1 — positive copy progress
- **Severity**: High
- **Invariant violated**: `MCReportedCoversVisibleCopy`
- **Config**: `MC_hunt_scenario_1_positive_copy_progress.cfg`
- **Counterexample**: 10 states, `spec/output/MC_hunt_scenario_1_positive_copy_progress_bfs.out`

### Trace Summary

1. A shared ext2 buffered read starts with a nonempty request.
2. The fallible copy advances the user `VmWriter` by a positive prefix and then faults.
3. The backend converts the tuple error to scalar `EFAULT`, reports zero, and releases the data and OFD locks without advancing the shared offset.
4. The syscall returns `Fault` with `visibleTotal = 1` and `reportedTotal = 0`.

### Root Cause

`read_fallible` advances both cursors before returning `(PageFault, copied_len)`. The page-cache and direct-read loops use `?`, and `From<(ostd::Error, usize)> for Error` discards the count. `InodeHandle::read` therefore sees only an error, leaves the shared offset unchanged, and the syscall returns `EFAULT` even though the caller's buffer changed.

### Affected Code

- `ostd/src/mm/io/mod.rs:354`: advances both cursors before returning the partial count with the fault
- `kernel/core/src/vm/page_cache/vmo/mod.rs:557`: propagates the tuple error after a fallible page copy
- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:304`: returns a scalar error after positive buffered-read copy progress
- `kernel/core/src/error.rs:209`: drops the tuple's byte count
- `kernel/core/src/fs/file/inode_handle.rs:297`: advances the shared offset only for `Ok(len)`

### Recommendation

Carry a progress-bearing result through VMO, filesystem, `FileLike`, and syscall layers. Return a short success and advance the shared offset by the same count whenever a read fault follows positive copied progress.

---

## Bug 2: A retained write prefix is returned as EFAULT with no offset progress

- **Scenario**: 1/2 — positive write progress and backend disposition
- **Severity**: High
- **Invariant violated**: `MCMixedPageRetainedPrefixReported`
- **Config**: `MC_hunt_scenario_1_mixed_page_prefix.cfg`
- **Counterexample**: 10 states, `spec/output/MC_hunt_scenario_1_mixed_page_prefix_bfs.out`

### Trace Summary

1. An in-place ext2 buffered write begins on an up-to-date page.
2. An earlier page is copied and dirtied; a later `Uninit` page faults after positive cumulative progress.
3. Rollback preserves the earlier in-place dirty prefix, but tuple conversion erases its count.
4. The syscall returns `Fault` with `committedTotal = 1`, `reportedTotal = 0`, and an unchanged shared offset.

### Root Cause

The backed-page loop dirties each successfully copied page before moving to the next page. A later fault can therefore leave an earlier page visible even when the faulting `Uninit` page itself is not retained. Ext2 rollback removes prepared extension state but does not undo an in-place dirty prefix, while the error conversion discards the cumulative copy count.

### Affected Code

- `ostd/src/mm/io/mod.rs:354`: advances the source and destination cursors before returning the fault
- `kernel/core/src/vm/page_cache/vmo/mod.rs:734`: dirties successful earlier pages and may later return an error
- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:353`: rolls back metadata but returns a scalar error
- `kernel/core/src/error.rs:209`: drops the partial count
- `kernel/core/src/fs/file/inode_handle.rs:367`: skips shared-offset publication on error

### Recommendation

Preserve cumulative committed progress across page iterations and return it as short success. Make the syscall result, retained data, and shared-offset movement use the same count.

---

## Bug 3: Ramfs can copy beyond logical EOF and report only the EOF snapshot

- **Scenario**: 4 — positional I/O with split EOF/copy state
- **Severity**: Medium
- **Invariant violated**: `MCReportedCoversVisibleCopy`
- **Config**: `MC_hunt_scenario_4_positional_offset.cfg`
- **Counterexample**: 10 states, `spec/output/MC_hunt_scenario_4_positional_offset_bfs.out`

### Trace Summary

1. `pread64` starts at abstract offset 1 with logical file size 2.
2. Ramfs snapshots one unit of logical data remaining.
3. The page-cache VMO, whose capacity may exceed EOF, copies the complete two-unit request.
4. The syscall succeeds and reports one unit while two units of the user buffer were modified; the shared OFD offset correctly remains zero.

### Root Cause

Ramfs computes `read_len` from inode size but passes the original, unbounded `VmWriter` to `PageCache::read`. The VMO limits the copy by page-cache capacity, which is page-aligned and may exceed logical file size. Ramfs then returns the earlier `read_len`, not the actual cursor delta.

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:701`: snapshots logical EOF but does not limit the writer before page-cache read
- `kernel/core/src/vm/page_cache/mod.rs:181`: documents that capacity is page-aligned and may exceed file size
- `kernel/core/src/vm/page_cache/vmo/mod.rs:535`: limits reads by VMO capacity rather than filesystem EOF
- `kernel/core/src/fs/file/inode_handle.rs:400`: returns the ramfs length without touching the shared positional offset

### Recommendation

Limit the writer to `read_len` before calling the page cache, and return the actual copied count. Keep the current positional-offset neutrality.

---

## Bug 4: Ramfs publishes file size before a write that copies no bytes

- **Scenario**: 2 — backend publication escapes the syscall outcome
- **Severity**: Medium
- **Invariant violated**: `MCFileSizeMatchesProgress`
- **Config**: `MC_hunt_scenario_2_backend_publication.cfg`
- **Counterexample**: 9 states, `spec/output/MC_hunt_scenario_2_backend_publication_bfs.out`

### Trace Summary

1. A positional ramfs write starts at abstract offset 1 with file size 2 and a two-unit request.
2. Ramfs publishes the planned end, expanding file size to 3, before copying user memory.
3. The first user copy faults with zero progress.
4. The data lock is released with `fileSize = 3`, `expectedFileSize = 2`, and an error result pending; there is no rollback.

### Root Cause

Ramfs updates size, block count, and timestamps from `offset + reader.remain()` before calling the fallible page-cache write. Both zero-length writes beyond EOF and zero-prefix faults can therefore expand metadata without committed or reported data, and the error path returns without restoring the old size.

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:795`: publishes metadata before the fallible copy and has no rollback on error
- `kernel/core/src/vm/page_cache/vmo/mod.rs:569`: performs the later fallible write

### Recommendation

Publish size and timestamps only after successful positive copy progress, or restore the old metadata on error. A zero-length write must not expand the file.

---

## Bug 5: Vectored I/O is not atomic on a shared open-file description

- **Scenario**: 3 — vector atomicity and later-iovec fault
- **Severity**: High
- **Invariant violated**: `MCLaterIovecFaultLinearizable`
- **Config**: `MC_hunt_finding_mc1_later_iovec_fault.cfg`
- **Counterexample**: 23 states, `spec/output/MC_hunt_finding_mc1_later_iovec_fault_bfs.out`

### Trace Summary

1. The first `readv` entry completes and advances the shared offset by two units.
2. The vector loop releases the OFD lock before its second entry.
3. A competing shared operation changes the OFD position in that gap.
4. The second entry begins at the changed position, copies a positive prefix, and faults.
5. `readv` returns only the first entry's two units while three units are visible and the two entries cannot be placed at one linearization point.

### Root Cause

`readv` and `writev` are loops of independent `file.read`/`file.write` calls. Each scalar call acquires and releases `InodeHandle::offset`, so no lock spans the vector operation. Competing shared-offset operations and delayed direct-I/O effects can occur between entries.

### Affected Code

- `kernel/core/src/syscall/preadv.rs:169`: loops above `FileLike::read`
- `kernel/core/src/syscall/pwritev.rs:165`: loops above `FileLike::write`
- `kernel/core/src/fs/file/inode_handle.rs:288`: serializes only one scalar read
- `kernel/core/src/fs/file/inode_handle.rs:348`: serializes only one scalar write

### Recommendation

Move vector dispatch below one OFD serialization boundary, for example by adding deep `FileLike` vector operations that hold the shared offset and backend ordering for the whole call.

---

## Bug 6: Ext2 direct write returns while an earlier submitted BIO remains live

- **Scenario**: 2 / MC2 — delayed direct-I/O completion
- **Severity**: High
- **Invariant violated**: `MCNoUnaccountedPendingEffect`
- **Config**: `MC_hunt_finding_mc2_direct_completion.cfg`
- **Counterexample**: 13 states, `spec/output/MC_hunt_finding_mc2_direct_completion_bfs.out`

### Trace Summary

1. A direct positional write copies and submits its first mapped range.
2. Copying the second range faults with zero progress for that range.
3. Ext2 rolls back prepared metadata, releases its locks, and returns `Fault`.
4. The first BIO remains pending after the attempt is idle and can complete later, including during a later vector operation.

### Root Cause

`write_direct_blocks` calls `wait_all` only after the entire range loop. A later range's `write_fallible` error returns immediately, skipping that wait. `IoBatch` merely owns completion handles and has no `Drop` wait or cancellation, so dropping the local batch does not stop the submitted device request.

### Affected Code

- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:516`: returns from direct-write rollback after the range-loop error
- `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:590`: submits each completed range before copying the next and waits only after the loop
- `kernel/libs/io-util/src/batch.rs:107`: has no drop-time wait or cancel behavior
- `kernel/core/comps/block/src/bio.rs:278`: completion publishes independently after submission

### Recommendation

On every error exit, await or cancel all BIOs already submitted by the attempt before releasing inode/OFD serialization. Define and return a partial-success count consistent with effects that cannot be canceled.

---

## Bug 7: An O_APPEND fault leaves the shared offset at EOF

- **Scenario**: 5 — append positioning before success
- **Severity**: Medium
- **Invariant violated**: `MCSharedOffsetMatchesReported`
- **Config**: `MC_hunt_scenario_5_append_failure.cfg`
- **Counterexample**: 10 states, `spec/output/MC_hunt_scenario_5_append_failure_bfs.out`

### Trace Summary

1. A shared `O_APPEND` write begins with OFD offset 0 and file size 2.
2. `InodeHandle::write` assigns EOF to the shared offset before calling the backend.
3. The backend copy faults with zero progress and reports no bytes.
4. Error unwinding releases the OFD lock with `ofdOffset = 2` and `expectedOffset = 0`.

### Root Cause

The append branch writes `path.size()` directly into the shared offset before the fallible backend call. The error arm skips only the later `+= len`; it does not restore the pre-call offset. A following operation on a duplicated descriptor observes the unexplained jump.

### Affected Code

- `kernel/core/src/fs/file/inode_handle.rs:361`: assigns EOF to the shared offset before the backend call and does not restore it on error

### Recommendation

Keep the append start local until the backend returns a nonnegative result, or restore the previous shared offset on failure. Publish one offset transition that matches the returned byte count.

---

## BFS Coverage

| Config | Violated invariant | States generated | Distinct states | Diameter | Disposition |
|---|---:|---:|---:|---:|---|
| `MC_hunt_finding_delayed_bio_vector.cfg` | `MCVectorCallLinearizable` | 6,248 | 4,581 | 33 | Bugs 5 and 6 composition |
| `MC_hunt_finding_mc1_later_iovec_fault.cfg` | `MCLaterIovecFaultLinearizable` | 242,936 | 153,420 | 24 | Bug 5 |
| `MC_hunt_finding_mc2_direct_completion.cfg` | `MCNoUnaccountedPendingEffect` | 294,482 | 159,571 | 13 | Bug 6 |
| `MC_hunt_scenario_1_mixed_page_prefix.cfg` | `MCMixedPageRetainedPrefixReported` | 507 | 469 | 14 | Bug 2 |
| `MC_hunt_scenario_1_positive_copy_progress.cfg` | `MCReportedCoversVisibleCopy` | 6,526 | 3,663 | 10 | Bug 1 |
| `MC_hunt_scenario_2_backend_publication.cfg` | `MCFileSizeMatchesProgress` | 101,981 | 53,819 | 11 | Bug 4 |
| `MC_hunt_scenario_3_append_gap.cfg` | `MCAppendFailureVectorLinearizable` | 32,488 | 20,460 | 27 | Bugs 5 and 7 composition |
| `MC_hunt_scenario_3_vector_atomicity.cfg` | `MCVectorCallLinearizable` | 207,024 | 130,914 | 24 | Bug 5 |
| `MC_hunt_scenario_4_positional_offset.cfg` | `MCReportedCoversVisibleCopy` | 96,237 | 52,284 | 13 | Bug 3; no OFD-offset violation |
| `MC_hunt_scenario_5_append_failure.cfg` | `MCSharedOffsetMatchesReported` | 513 | 437 | 12 | Bug 7 |
| `MC_hunt_scenario_6_effect_replay.cfg` | `MCNoEffectReplay` | 795 | 700 | 21 | Reference capability only |
| `MC_hunt_scenario_6_restart.cfg` | `MCRestartRequiresZeroProgress` | 93 | 87 | 12 | Reference capability only |

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| Positional I/O changes the shared OFD offset | `MC_hunt_scenario_4_positional_offset.cfg` | 52,284 distinct | `MCPositionalOffsetStable` did not fail; the run stopped on Bug 3, and the implementation uses only a local positional offset |
| Positive-progress restart on pinned ext2/ramfs | `MC_hunt_scenario_6_restart.cfg` | 87 distinct | Not testable: current ext2/ramfs waits do not return `EINTR`; the counterexample requires `EnableReferenceInterruptible = TRUE` |
| Effect replay on pinned ext2/ramfs | `MC_hunt_scenario_6_effect_replay.cfg` | 700 distinct | Not testable: the replay counterexample requires the same reference-only capability |

## Reference-Capability Result

The two Scenario 6 configurations confirm a conditional design risk: if a regular-file backend returns `EINTR` after positive progress, the generic syscall layer maps it to `ERESTARTSYS`, and `SA_RESTART` rewinds without progress provenance. The effect-replay trace commits the same effect token twice. This is not a pinned ext2/ramfs finding because their inspected waits are uninterruptible.
