# Bug Report — Asterinas Regular-File I/O

## Summary

- Scenarios tested: 4, with the signal/restart gate included in the Scenario 1 hunt
- Bugs found: 4
- Configs run: `MC.cfg` and all six supplied `MC_hunt_*.cfg` files
- Trace validation: 5 of 5 traces passed with nonzero replay states and all 33 post-state fields checked
- Harness coverage: 32 of 33 event types; `RestartSyscall` is uncovered because the target has no confirmed in-scope regular-file post-progress `EINTR` producer

### Model-Checking Coverage

| Config | Mode | Coverage | Result |
|---|---:|---:|---|
| `MC.cfg` | BFS | 511,868 distinct states | Exhausted; convergence invariants hold, with the last periodic progress line at depth 12 |
| `MC_hunt_s1_partial_progress.cfg` | BFS | 141 | `MCReadReturnCoversCopies` violated; 18-state trace |
| `MC_hunt_s2_adapter_ordering.cfg` | BFS | 56 | `MCNoReadPastEOF` violated; duplicate mechanism isolated below |
| `MC_hunt_s2_unbounded_read.cfg` | BFS | 20 | `MCNoReadPastEOF` violated; 5-state trace |
| `MC_hunt_s2_prepublished_write.cfg` | BFS | 19 | `MCNoNominalEOFOnFault` violated; 9-state trace |
| `MC_hunt_s3_vector_linearization.cfg` | BFS | 1,021 | `MCVectorSingleLinearization` violated; 21-state trace |
| `MC_hunt_s4_positional_isolation.cfg` | BFS | 2,016 distinct states | Exhausted at diameter 18; no violation |
| `MC_hunt_s4_positional_isolation.cfg` | Simulation | 464,812,379 states checked; 27,870,352 traces | No violation in the required 30-minute depth-100 run |

## Bug 1: A Later readv Fault Can Hide a Positive Copy Prefix

- **Scenario**: 1 — positive progress is collapsed before result and offset commit
- **Severity**: High
- **Invariant violated**: `MCReadReturnCoversCopies`
- **Config**: `MC_hunt_s1_partial_progress.cfg`
- **Counterexample**: 18 states, `spec/output/MC_hunt_s1_partial_progress_bfs.out`

### Trace Summary

1. The first `readv` iovec copies and reports one complete symbolic chunk, advancing the shared offset from 0 to 2.
2. The second iovec copies a positive prefix at offset 2 before the user copy faults.
3. Tuple conversion retains `EFAULT` but drops the copied count. `InodeHandle::read` therefore leaves the shared offset at 2.
4. Because an earlier iovec succeeded, `do_sys_readv` suppresses the error and returns 2. User memory contains 3 units of newly copied data, but both the result and shared-offset delta are 2.

The trace-valid RamFS `writev` capture shows the write-side form of the same count loss: its second iovec commits a positive prefix, receives `EFAULT`, and returns only the earlier iovec's count. This report consolidates both directions under the shared progress-erasure root cause.

### Root Cause

`VmReader::read_fallible` advances both cursors before returning `(Error::PageFault, copied_len)`. The kernel error conversions discard that count. Page-cache read and write paths then return only `Error`, and `InodeHandle` advances the shared offset only for `Ok(len)`. The vector loops suppress a later error after prior progress, so neither the later prefix nor its offset effect reaches the syscall result.

### Affected Code

- `ostd/src/mm/io/mod.rs:347`: advances cursors before returning an error plus copied count
- `kernel/core/src/error.rs:209`: converts `(error, count)` to a count-less `Error`
- `kernel/core/src/vm/page_cache/vmo/mod.rs:558`: propagates a partial read as only `Error`
- `kernel/core/src/vm/page_cache/vmo/mod.rs:716`: propagates a partial anonymous write as only `Error`
- `kernel/core/src/fs/file/inode_handle.rs:298`: changes the shared offset only on `Ok(len)`
- `kernel/core/src/syscall/preadv.rs:168`: returns prior aggregate progress after a later iovec error
- `kernel/core/src/syscall/pwritev.rs:164`: has the corresponding write-side aggregation path

### Recommendation

Carry error-plus-progress through the page-cache and file-I/O interfaces. A positive prefix must become a short successful result, update the shared offset by that prefix, and participate in vector aggregation. Add later-iovec fault regressions for both `readv` and `writev`.

---

## Bug 2: RamFS and exFAT Cached Reads Copy Beyond Logical EOF

- **Scenario**: 2 — filesystem adapters copy outside logical progress
- **Severity**: High
- **Invariant violated**: `MCNoReadPastEOF`
- **Config**: `MC_hunt_s2_unbounded_read.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_s2_unbounded_read_bfs.out`

### Trace Summary

1. A `pread64` starts exactly at logical EOF 6 with a two-unit destination. The page cache has aligned capacity 8.
2. RamFS computes zero logical availability but passes the original writer to the VMO.
3. The VMO clips against capacity 8 rather than logical EOF 6 and copies a positive prefix into user memory. `readPastEOF` becomes true immediately.
4. The same implementation path can therefore return zero after altering the destination or return `EFAULT` after touching an address that a zero-length EOF read must not access. The combined adapter config reaches the same violation, and the trace-valid RamFS/exFAT captures exercise the over-copy.

### Root Cause

RamFS and exFAT calculate a logical `read_len`, but neither limits the `VmWriter` passed to `PageCache::read`. Page-cache capacity is page-aligned and explicitly may exceed filesystem EOF; `Vmo::read` treats that capacity as its only bound. Its cursor movement can therefore exceed the length later reported by the filesystem adapter.

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:704`: computes a logical bound but calls `page_cache.read` with the unrestricted writer
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:649`: has the same unrestricted cached-read path
- `kernel/core/src/vm/page_cache/mod.rs:181`: defines cache capacity as page-aligned and potentially larger than file size
- `kernel/core/src/vm/page_cache/vmo/mod.rs:534`: limits reads against VMO capacity, not filesystem EOF

### Recommendation

Return immediately when the logical length is zero. Otherwise pass a writer limited to the logical length and advance the original writer only by the bytes the adapter reports. Add sentinel and inaccessible-tail tests for `read`, `pread64`, and `readv` on short RamFS and exFAT files.

---

## Bug 3: A Zero-Progress RamFS Write Can Publish the Full Requested EOF

- **Scenario**: 2 — filesystem adapters publish outside logical progress
- **Severity**: High
- **Invariant violated**: `MCNoNominalEOFOnFault`
- **Config**: `MC_hunt_s2_prepublished_write.cfg`
- **Counterexample**: 9 states, `spec/output/MC_hunt_s2_prepublished_write_bfs.out`

### Trace Summary

1. A two-unit `pwrite64` starts at EOF 6.
2. RamFS sets the inode size and cache capacity to the requested end 8 before reading user memory.
3. The VMO copy faults before copying any byte. The syscall returns `EFAULT`, with no data effect and no reported progress.
4. No error path restores the metadata, so the file remains length 8 despite zero committed bytes.

### Root Cause

`RamInode::write_at` computes `new_size` from the full remaining request and publishes inode size, block count, timestamps, and cache growth before invoking the fallible page-cache write. The `?` error path exits without rollback. A zero-copy fault leaves the full nominal extent visible; a prefix fault can likewise publish beyond committed progress.

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:747`: locks and mutates inode metadata before user copy
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:755`: publishes the requested end as inode size
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:761`: grows page-cache capacity before copying
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:775`: propagates a copy fault without rolling metadata back

### Recommendation

Publish file size from committed progress after copying, or roll size and allocation metadata back on error. On a positive-prefix fault, the visible end may advance only to `offset + copied`; on zero progress it must remain unchanged. Add `fstat`, content, and return-value regressions using a source buffer that crosses into an inaccessible page.

---

## Bug 4: Vectored I/O Is Not Atomic Against a Shared-Offset Competitor

- **Scenario**: 3 — vectored I/O releases serialization between entries
- **Severity**: High
- **Invariant violated**: `MCVectorSingleLinearization`
- **Config**: `MC_hunt_s3_vector_linearization.cfg`
- **Counterexample**: 21 states, `spec/output/MC_hunt_s3_vector_linearization_bfs.out`

### Trace Summary

1. `readv` commits iovec 1 over shared-offset range `[0,2)` and releases the offset lock.
2. A competing scalar `write` acquires the same open-description offset and commits `[2,4)`.
3. `readv` reacquires the lock and commits iovec 2 over `[4,6)`.
4. The commit log is therefore `readv[1], write, readv[2]`. No single ordering of the two API-level operations explains the observed data and offset history. The deterministic trace-valid RamFS harness captures the write-side order `writev[1], write, writev[2]` on the actual kernel path.

### Root Cause

`do_sys_readv` and `do_sys_writev` dispatch each iovec through a separate scalar `file.read` or `file.write` call. Each `InodeHandle` scalar call independently locks, advances, and unlocks the shared offset. There is no API-level serialization spanning the whole vector operation, so a duplicated descriptor can enter between entries.

### Affected Code

- `kernel/core/src/syscall/preadv.rs:159`: loops over iovecs and calls `file.read` per entry
- `kernel/core/src/syscall/pwritev.rs:155`: loops over iovecs and calls `file.write` per entry
- `kernel/core/src/fs/file/inode_handle.rs:292`: acquires and releases the read offset lock for one scalar entry
- `kernel/core/src/fs/file/inode_handle.rs:346`: acquires and releases the write offset lock for one scalar entry

### Recommendation

Add vectored file operations that hold the open-description serialization and shared-offset update across the full iovec list. Filesystem implementations may still process entries internally, but competing I/O on the same description must observe one API-level linearization point. Retain the deterministic vector/scalar gate as a regression.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| Positional offset isolation | `MC_hunt_s4_positional_isolation.cfg` | 2,016 BFS states at diameter 18; 464,812,379 simulation checks across 27,870,352 traces | No violation; BFS exhausted and the required 30-minute depth-100 simulation completed |
| Signal restart replay | `MC_hunt_s1_partial_progress.cfg` | 141 distinct states before the primary partial-progress violation | Not testable to completion: the hunt stopped on `MCReadReturnCoversCopies`, and no in-scope regular-file post-progress `EINTR` producer exists for a concrete restart trace |

Scalar `read` and `write` translate `EINTR` to `ERESTARTSYS` at
`kernel/core/src/syscall/read.rs:37` and
`kernel/core/src/syscall/write.rs:37`. A pending `SA_RESTART` signal can then
rewind the syscall instruction at `kernel/core/src/process/signal/mod.rs:156`.
The surveyed regular-file implementations do not supply the post-progress
`EINTR` precondition, so injecting it would test an invented implementation
behavior rather than this target.
