# Bug report: buffered file size and read consistency

## Summary

- Revision: [`604948581512d83734377974d4c34adb4530f2d7`](https://github.com/asterinas/asterinas/tree/604948581512d83734377974d4c34adb4530f2d7); source locations below refer to the uninstrumented revision.
- Converged in one round after correcting VMO collection capacity: 111/111 guest traces match; `MC.cfg` completed with 8,131 distinct states, depth 32, and no violations.
- Four scenario families, three separate backends, 40 unchanged hunting configurations: 18 BFS counterexamples and 22 complete BFS searches without violations.
- Eight findings group counterexamples by backend and cause. These are Case C model findings cross-checked against source. The brief already identifies the underlying concerns; this report makes no novelty claim.
- Guest evidence supports the ramfs growth under-reporting and exFAT resize findings. Other triggering schedules still need guest confirmation; the stale-hole finding requires physical cluster reuse.
- All nine required simulation follow-ups reached their 30-minute budgets without violations. Last progress samples total 748,375,097 checked states and 66,384,292 traces; these are lower bounds, not unique-state counts.

`P` denotes one page. S1/S2/S4 use `P=2` model cells; the existing guest traces map each cell to 2,048 bytes. S3 uses `P=2`, cluster size `G=4`. Requested length, actual cursor advance, accepted bytes, reported result, logical size `L`, cache capacity `C`, and allocation `A` remain distinct.

Counterexample states and original TLC output are retained in [output/](output/). [counterexample-steps.json](output/counterexample-steps.json) records every state transition for all 18 counterexamples. A trace matching the implementation does not mean its syscall result satisfies the checked contract.

## Bug 1: Ramfs reads report a saved count that differs from delivered bytes

- **Scenario**: S1, saved EOF versus copy progress; brief MC1.
- **Severity**: High. A successful count can describe untouched user bytes, and shared-offset reads advance incorrectly relative to delivery.
- **Invariant violated**: `SuccessfulTransferAccounting`; companion configurations violate `ControlledOffsetAccounting` and `UnreportedReadSuffixUnchanged`.
- **Config**: `MC_hunt_s1_ramfs.cfg`.
- **Counterexample**: 14 states, [MC_hunt_s1_ramfs_bfs1.out](output/MC_hunt_s1_ramfs_bfs1.out).

### Trace Summary

1. States 1–3: `L=C=P`; a `read(P)` saves `S=K=P` before taking the cache mutex.
2. States 4–10: a competing `ftruncate(0)` publishes `C=L=0` and releases the cache mutex.
3. States 11–12: the reader acquires the cache mutex; VMO returns success with `D=0`.
4. States 13–14: the backend returns saved `K=P`; the shared position advances from zero to `P` while the destination remains unchanged.
5. Growth witnesses reverse the discrepancy: saved `K=P`, delivered `D=2P`, returned `P`. Both buffered `pwrite64` and `ftruncate` extension configurations reproduce it. Separate suffix and offset configurations expose the associated observables.

### Root Cause

The metadata lock used by `size()` ends before cache acquisition. Size-changing operations can run between that observation and the copy, which receives the original unlimited writer. The result is still the previously computed length. Successful short reads remain permitted; a successful result must account for actual bytes read and the shared offset follows that count. [read(2)](https://man7.org/linux/man-pages/man2/read.2.html)

Existing guest trace `traces/ramfs-2-2.ndjson`, thread `t0`, events 1–13, records `pread64(O=0,N=4)`, `D=4`, result `2`: 8,192 bytes delivered, 4,096 reported. Positional I/O leaves the shared offset unchanged. `ramfs-0-0.ndjson` additionally records the known sequential EOF-padding case; it is not counted as another finding.

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:704`: samples size before taking the cache mutex.
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:709`: copies with the original writer and retains the saved count.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:535`: clamps copying to the current VMO capacity.
- `kernel/core/src/fs/file/inode_handle.rs:287`: advances the shared offset by the returned count.

### Recommendation

Acquire the cache mutex before observing EOF, following the existing cache-to-metadata lock order. Bound copying to the selected read range and keep the returned count consistent with actual cursor progress.

## Bug 2: ExFAT reads copy beyond their reported prefix during write preparation

- **Scenario**: S1, extension overlapping read.
- **Severity**: Medium. The destination changes beyond the returned prefix, including zero stores, and `read` advances by fewer bytes than it delivered.
- **Invariant violated**: `SuccessfulTransferAccounting`.
- **Config**: `MC_hunt_s1_growth_exfat.cfg`.
- **Counterexample**: 20 states, [MC_hunt_s1_growth_exfat_bfs1.out](output/MC_hunt_s1_growth_exfat_bfs1.out).

### Trace Summary

1. States 1–8: from `L=C=A=P`, an extender prepares `(O=P,N=P)`, grows `A=C=2P`, then releases its write guard without publishing `L`.
2. State 9: `read(2P)` acquires the upgradeable guard and saves `K=P`.
3. States 10–18: VMO copies two pages. The second page loads zeros because its start is at the current logical EOF. `D=2P` while `L=P`.
4. States 19–20: the reader returns `P` and advances the shared offset by `P`. The writer has not yet copied its payload.

### Root Cause

The read guard protects the size observation and copy together, but allocation and cache capacity can already exceed logical EOF after a writer releases its preparation guard. `read_at` passes the full writer to the page cache, then returns the smaller logical-EOF count. This is a concurrent manifestation of the existing missing read-limit concern, not a claim that exFAT shares ramfs's locking. [pread(2)](https://man7.org/linux/man-pages/man2/pread.2.html)

### Affected Code

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:648`: computes the logical-EOF count.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:654`: copies without limiting the writer to that count.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:729`: grows cache capacity before the preparation guard is released.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:154`: supplies zeros for a backend page beyond current logical EOF.

### Recommendation

Limit the read copy to the logical range selected under the upgradeable guard and return the measured delivered count. Cache capacity alone must not determine the user-visible transfer.

## Bug 3: ExFAT stale write preparation permits false success and inconsistent extents

- **Scenario**: S2, two extenders or a prepared extender versus shrink; brief MC2.
- **Severity**: High. Writes can report undelivered bytes, leave logical size beyond readable capacity, or regress the reported extent of a completed write.
- **Invariant violated**: `SettledReadableExtent`; companion configurations violate `SuccessfulTransferAccounting` and `ExtendersPreserveExtent`.
- **Config**: `MC_hunt_s2_exfat_extent.cfg`.
- **Counterexample**: 28 states, [MC_hunt_s2_exfat_extent_bfs1.out](output/MC_hunt_s2_exfat_extent_bfs1.out).

### Trace Summary

1. States 1–8: from `L=C=A=P`, far writer `t1` prepares `(O=2P,N=P)`, raises `A=C=3P`, and saves candidate `3P` before releasing its write guard.
2. States 9–12: near writer `t0` still observes `L=P`; its preparation sets `C=2P` while `A` remains `3P`.
3. States 13–21: the near writer copies `P`, publishes `L=2P`, and selects a successful result.
4. States 22–28: the far writer resumes at `O=2P`, copies zero because `C=2P`, publishes saved `L=3P`, and returns `P`. Both writes finish with `L=3P>C=2P`.
5. `MC_hunt_s2_exfat_preserve.cfg` reverses publication order: far writer publishes `3P`, then the near writer publishes its saved `2P`. Final size fails to cover the far writer's reported range. Its shortest witness also has zero delivery by the far writer; it does not independently prove loss of a fully copied far write.
6. The shrink configuration produces `L=3P,C=A=0` after a prepared far write resumes. The fault configuration can return success without touching a deliberately inaccessible source because the capacity clamp selects a zero copy.

### Root Cause

Preparation and copying use separate critical sections. A competing operation can change the state that the saved candidate assumes, and acquiring the copy guard performs no revalidation. The VMO accepts a capacity-clamped zero copy, while exFAT returns the original requested count and assigns its saved size. Upgradeable guards exclude competing copies; they do not close the earlier release/reacquire interval. A successful write's returned count describes bytes written, and a later read must expose the supported written contents. [write(2)](https://man7.org/linux/man-pages/man2/write.2.html)

The settled witness stops before its enabled follow-up reader. From its final state, the source's VMO clamp gives a later buffered read of the far page zero delivery despite the advertised logical extent. This continuation is source-derived, not a completed guest read in this counterexample.

### Affected Code

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:715`: prepares from a saved logical size under a write guard.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:734`: releases preparation and reacquires a separate upgradeable guard.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:743`: unconditionally publishes the saved candidate size.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:755`: returns the original requested count.
- `kernel/core/src/vm/page_cache/mod.rs:271`: stores the requested rounded capacity even when a logical extension reduces the current capacity.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:571`: accepts a zero-length capacity-clamped write.

### Recommendation

Close the preparation gap or revalidate allocation, cache capacity, and the current inode after acquiring the copy guard. Publish size from current state and accepted progress. Preserve the ability of page-cache backend callbacks to acquire their read guards when revising the lock protocol.

## Bug 4: ExFAT successful ftruncate can retain the old logical size

- **Scenario**: S3, public resize; brief TV2.
- **Severity**: Medium. A successful size-changing call can leave metadata and the readable extent inconsistent with its requested length.
- **Invariant violated**: `SuccessfulResizeContract`.
- **Config**: `MC_hunt_s3_extend_zero_exfat.cfg`.
- **Counterexample**: 7 states, [MC_hunt_s3_extend_zero_exfat_bfs1.out](output/MC_hunt_s3_extend_zero_exfat_bfs1.out).

### Trace Summary

1. State 1: the file is empty, `L=C=A=0`.
2. States 2–5: `ftruncate(1)` obtains the inode guards and updates allocation to `A=1`, but leaves `L=C=0`.
3. States 6–7: the call returns zero with logical size still zero.
4. `MC_hunt_s3_regrow_exfat.cfg` first shrinks six cells to one, then successfully requests three cells while leaving `L=1`.

### Root Cause

Public resize grows neither cache capacity nor logical size. Its allocation helper changes logical size only when the number of clusters decreases, so same-cluster shrink also retains the old size. Successful `ftruncate` must establish its requested length; a backend that cannot extend may return an error. [truncate(2)](https://man7.org/linux/man-pages/man2/truncate.2.html)

Existing guest trace `traces/exfat-0-10.ndjson`, thread `t0`, events 1–14, requests one cell and returns success with observed `L=2,A=1`; events 24–29 request four cells and return success with `L=2,A=4`. At 2,048 bytes per cell, both shrink to 2,048 and extension to 8,192 retain size 4,096. These are native observations revalidated in this phase.

### Affected Code

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:286`: allocation helper separates allocation from logical size.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:307`: logical size changes only in the cluster-removal branch.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:1452`: public resize updates cache capacity only for shrink.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:1455`: returns through allocation adjustment without final logical-size publication.

### Recommendation

Make successful public resize establish the requested logical length and the necessary readable bound in both directions, including changes within one cluster. Preserve zero-fill behavior and handle cold-tail callback locking explicitly.

## Bug 5: ExFAT regrown holes can read the subject's old backing bytes

- **Scenario**: S3, truncate, cluster reuse, and extending write; brief TV3.
- **Severity**: High. A region required to read as zeros can expose stale contents of the same file.
- **Invariant violated**: `HoleZeros`.
- **Config**: `MC_hunt_s3_holes_exfat.cfg`.
- **Counterexample**: 35 states, [MC_hunt_s3_holes_exfat_bfs1.out](output/MC_hunt_s3_holes_exfat_bfs1.out).

### Trace Summary

1. State 1: the existing three-page subject has nonzero seeded backing data.
2. States 2–9: `ftruncate(0)` removes cache pages and frees its clusters; backing bytes remain.
3. States 10–25: `pwrite64(O=2P,N=P)` reuses those clusters, overwrites only the last page, and publishes `L=3P`.
4. States 26–35: a settled `pread64(O=0,N=P)` loads the absent first page from backing storage. It returns the old `seed` bytes where the isolated history requires zeros.

### Root Cause

Allocation marks clusters used without clearing their data. Untouched pages are absent when the extending writer publishes logical EOF. The later page-load decision then treats the hole as in-EOF data and reads backing storage. Truncation decommits pages; it does not erase their disk contents. Unwritten gaps exposed by a later write must read as zeros. [lseek(2)](https://man7.org/linux/man-pages/man2/lseek.2.html)

The modeled reuse is source-reachable: allocation from an empty chain searches from the first cluster, so a subject occupying the first suitable free run can reclaim that run after truncation. No allocation failure or unrelated-file data is required. The existing guest fixture does not record physical cluster identity; this remains a source-backed model finding pending that fixture and guest confirmation.

### Affected Code

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:154`: chooses backing data once the page start falls below published logical EOF.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:743`: publishes logical EOF after copying only the requested write range.
- `kernel/core/src/fs/fs_impls/exfat/fat.rs:208`: chooses and marks an available cluster run without clearing data.
- `kernel/core/src/fs/fs_impls/exfat/fat.rs:364`: releases clusters without overwriting backing contents.

### Recommendation

Establish zeros for newly exposed unwritten regions before publishing the logical extent, either through initialized cache contents or cleared backing storage. Verify with nonzero backing data and receipts proving the subject's cluster reuse.

## Bug 6: Ramfs zero-count positional writes can enlarge the file

- **Scenario**: S4, empty positional write; brief TV5.
- **Severity**: Medium. An operation returning zero can change logical size and cache capacity.
- **Invariant violated**: `EmptyWriteNoEffect`.
- **Config**: `MC_hunt_s4_empty_ramfs.cfg`.
- **Counterexample**: 10 states, [MC_hunt_s4_empty_ramfs_bfs1.out](output/MC_hunt_s4_empty_ramfs_bfs1.out).

### Trace Summary

1. State 1: `L=C=P`.
2. States 2–6: `pwrite64(O=2P,N=0)` publishes `L=2P` and grows `C=2P`.
3. States 7–10: the zero-length copy succeeds; the call returns zero without moving the shared offset.

### Root Cause

Ramfs computes the candidate as offset plus request length and publishes it before discovering that there is nothing to copy. It has no empty-write return before the size-changing path. Successful zero-count regular-file writes must have no other effect. [write(2)](https://man7.org/linux/man-pages/man2/write.2.html)

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:736`: computes the requested end even when length is zero.
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:742`: publishes that end as logical size.

### Recommendation

Return zero before size publication, allocation, or copying when the input reader is empty.

## Bug 7: ExFAT zero-count positional writes can enlarge the file

- **Scenario**: S4, empty positional write; brief TV5.
- **Severity**: Medium. A zero-count success can allocate storage and change logical size.
- **Invariant violated**: `EmptyWriteNoEffect`.
- **Config**: `MC_hunt_s4_empty_exfat.cfg`.
- **Counterexample**: 13 states, [MC_hunt_s4_empty_exfat_bfs1.out](output/MC_hunt_s4_empty_exfat_bfs1.out).

### Trace Summary

1. State 1: `L=C=A=P`.
2. States 2–7: `pwrite64(O=2P,N=0)` prepares `A=C=2P` and retains candidate `2P`.
3. States 8–13: the zero copy succeeds; the writer publishes `L=2P` and returns zero. The shared offset remains unchanged.

### Root Cause

ExFAT enters extension preparation for an empty reader whenever its offset is beyond EOF, then publishes the saved candidate after the successful empty copy. Its lock protocol differs from ramfs, so the backend correction and validation are separate. The positional contract preserves the shared offset; this finding concerns file effects. [pread(2)](https://man7.org/linux/man-pages/man2/pread.2.html)

### Affected Code

- `kernel/core/src/fs/fs_impls/exfat/inode.rs:712`: retains zero requested length without an early return.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:725`: prepares extension from offset plus zero.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs:743`: publishes the candidate despite no delivered bytes.

### Recommendation

Return zero for an empty reader before extension preparation or logical-size publication.

## Bug 8: Ramfs zero-progress failed writes can publish the full requested extent

- **Scenario**: S4, fixed inaccessible source at EOF; brief TV4.
- **Severity**: Medium. A rejected write can leave a larger logical file with no accepted user data.
- **Invariant violated**: `AcceptedExtent`.
- **Config**: `MC_hunt_s4_fault_ramfs.cfg`.
- **Counterexample**: 14 states, [MC_hunt_s4_fault_ramfs_bfs1.out](output/MC_hunt_s4_fault_ramfs_bfs1.out).

### Trace Summary

1. States 1–2: `L=C=P`; `pwrite64(O=P,N=P)` has a pre-established inaccessible source from its first byte.
2. States 3–11: ramfs publishes `L=2P`, grows `C=2P`, and prepares the anonymous page.
3. States 12–14: the copy faults with `D=0` and no accepted bytes. The call returns `EFAULT`, while `L=C=2P` persists.

### Root Cause

Ramfs publishes the requested end before the fallible copy and does not undo that publication when copying fails. User-range construction checks address bounds, so a stable inaccessible mapping can reach this copy. The oracle is deliberately narrow: a zero-progress write starting exactly at old EOF, compared with Linux ramfs. Linux v6.12 rejects an entirely inaccessible source before `write_begin`; its size publication otherwise uses the accepted copy end. [generic_perform_write](https://github.com/torvalds/linux/blob/v6.12/mm/filemap.c#L4044), [simple_write_end](https://github.com/torvalds/linux/blob/v6.12/fs/libfs.c#L960)

This finding does not impose rollback on every failed partial write. The existing guest fault trace copies a prefix and therefore does not confirm this zero-progress witness. Raw Linux reference sources and hashes are retained under [output/contracts/](output/contracts/).

### Affected Code

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:742`: publishes requested logical size before copy acceptance.
- `kernel/core/src/fs/fs_impls/ramfs/fs.rs:750`: propagates the copy error without restoring the zero-progress extent.
- `ostd/src/mm/vm_space.rs:160`: constructs the reader without prevalidating all user mappings.
- `ostd/src/mm/io/mod.rs:354`: advances copy cursors by actual progress and reports the copy fault.

### Recommendation

Base logical-size publication on the established write-acceptance contract. In the zero-progress case, preserve the old logical extent; retain separately the semantics of accepted prefixes and initialized pages.

## Not Reproduced

All 22 configurations without a BFS violation are listed in the full coverage table below. A finite BFS without violations covers only its enabled invariants and configured inputs. A simulation timeout is a bounded search result, not an exhaustive proof.

### Hunting configuration coverage

| Config | BFS distinct states | Depth | Result |
|---|---:|---:|---|
| `MC_hunt_s1_exfat.cfg` | 519 | 18 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s1_ext2.cfg` | 710 | 19 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s1_growth_exfat.cfg` | 359 | 21 | MC-2; SuccessfulTransferAccounting |
| `MC_hunt_s1_growth_ext2.cfg` | 627 | 29 | Complete BFS; no violation |
| `MC_hunt_s1_growth_ramfs.cfg` | 885 | 26 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_growth_resize_exfat.cfg` | 231 | 16 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s1_growth_resize_ext2.cfg` | 468 | 23 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s1_growth_resize_ramfs.cfg` | 550 | 21 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_ramfs.cfg` | 562 | 15 | MC-1; SuccessfulTransferAccounting |
| `MC_hunt_s1_ramfs_offset.cfg` | 872 | 27 | MC-1; ControlledOffsetAccounting |
| `MC_hunt_s1_ramfs_suffix.cfg` | 869 | 26 | MC-1; UnreportedReadSuffixUnchanged |
| `MC_hunt_s2_exfat_accounting.cfg` | 296 | 20 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_exfat_extent.cfg` | 848 | 29 | MC-3; SettledReadableExtent |
| `MC_hunt_s2_exfat_fault.cfg` | 564 | 19 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_exfat_preserve.cfg` | 823 | 29 | MC-3; ExtendersPreserveExtent |
| `MC_hunt_s2_ext2.cfg` | 1228 | 41 | Complete BFS; no violation |
| `MC_hunt_s2_ramfs.cfg` | 1955 | 37 | Complete BFS; no violation |
| `MC_hunt_s2_shrink_exfat.cfg` | 252 | 21 | MC-3; SuccessfulTransferAccounting |
| `MC_hunt_s2_shrink_ext2.cfg` | 721 | 34 | Complete BFS; no violation |
| `MC_hunt_s2_shrink_ramfs.cfg` | 981 | 32 | Complete BFS; no violation |
| `MC_hunt_s3_cold_tail_exfat.cfg` | 105 | 17 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s3_exfat.cfg` | 735 | 35 | MC-5; HoleZeros |
| `MC_hunt_s3_ext2.cfg` | 976 | 47 | Complete BFS; no violation |
| `MC_hunt_s3_extend_zero_exfat.cfg` | 66 | 8 | MC-4; SuccessfulResizeContract |
| `MC_hunt_s3_holes_exfat.cfg` | 512 | 35 | MC-5; HoleZeros |
| `MC_hunt_s3_holes_ext2.cfg` | 1003 | 48 | Complete BFS; no violation |
| `MC_hunt_s3_holes_ramfs.cfg` | 1051 | 44 | Complete BFS; no violation |
| `MC_hunt_s3_ramfs.cfg` | 1051 | 44 | Complete BFS; no violation |
| `MC_hunt_s3_regrow_exfat.cfg` | 131 | 21 | MC-4; SuccessfulResizeContract |
| `MC_hunt_s3_regrow_ext2.cfg` | 956 | 40 | Complete BFS; no violation |
| `MC_hunt_s3_regrow_ramfs.cfg` | 1266 | 39 | Complete BFS; no violation |
| `MC_hunt_s4_empty_exfat.cfg` | 13 | 13 | MC-7; EmptyWriteNoEffect |
| `MC_hunt_s4_empty_ext2.cfg` | 5 | 5 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s4_empty_ramfs.cfg` | 10 | 10 | MC-6; EmptyWriteNoEffect |
| `MC_hunt_s4_fault_exfat.cfg` | 107 | 28 | Complete BFS; no violation |
| `MC_hunt_s4_fault_ext2.cfg` | 85 | 27 | Complete BFS; no violation |
| `MC_hunt_s4_fault_ramfs.cfg` | 83 | 27 | MC-8; AcceptedExtent |
| `MC_hunt_s4_read_fault_exfat.cfg` | 37 | 10 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s4_read_fault_ext2.cfg` | 37 | 10 | Complete BFS; 30-minute simulation found no violation |
| `MC_hunt_s4_read_fault_ramfs.cfg` | 41 | 11 | Complete BFS; 30-minute simulation found no violation |

### Simulation follow-ups

Each run used the unchanged cfg, two workers, 1 GiB heap, 1 GiB off-heap, depth 100, and 999999999 requested traces. Exit 124 is the installed wrapper's observed 30-minute watchdog expiry. Counts below are the last emitted progress samples.

| Config | Seconds | States checked | Traces generated | Result |
|---|---:|---:|---:|---|
| `MC_hunt_s1_exfat.cfg` | 1802.6 | 82,857,902 | 4,717,564 | No violation within budget |
| `MC_hunt_s1_ext2.cfg` | 1800.6 | 81,675,465 | 4,313,216 | No violation within budget |
| `MC_hunt_s1_growth_resize_exfat.cfg` | 1801.7 | 88,444,356 | 5,110,608 | No violation within budget |
| `MC_hunt_s1_growth_resize_ext2.cfg` | 1800.9 | 84,008,972 | 3,793,851 | No violation within budget |
| `MC_hunt_s3_cold_tail_exfat.cfg` | 1801.4 | 69,347,670 | 5,969,949 | No violation within budget |
| `MC_hunt_s4_empty_ext2.cfg` | 1801.9 | 90,792,977 | 18,158,597 | No violation within budget |
| `MC_hunt_s4_read_fault_exfat.cfg` | 1801.1 | 81,856,438 | 8,185,644 | No violation within budget |
| `MC_hunt_s4_read_fault_ext2.cfg` | 1802.2 | 80,921,623 | 8,092,163 | No violation within budget |
| `MC_hunt_s4_read_fault_ramfs.cfg` | 1802.4 | 88,469,694 | 8,042,700 | No violation within budget |

## Limits and classification

- The sole spec correction is an Inconsistency Error in `VmoCollectBegin`: native write vectors can collect fewer pages than the unaligned range spans. No outcome invariant, trace comparison, operation bound, or backend lock rule was weakened.
- No Case A invariant changes or further Case B transition changes were needed during model checking or hunting.
- `MC.cfg` checks core/structural safety; it deliberately excludes the outcome predicates used to discover these implementation defects. Convergence does not assert that the implementation satisfies those predicates.
- The cold-tail exFAT configuration allows a blocked backend-read state. Deadlock checking is disabled for these finite workloads; no liveness property is checked. Its no-violation result cannot certify completion of cold partial-tail resize.
- Failed-read configurations exercise fixed copy faults. Their successful-transfer and successful-shared-offset clauses have no successful read completions in these inputs. Positional offset preservation remains checked; no rollback or failed-read shared-offset guarantee is inferred.
- The exFAT resize-growth S1 configuration checks read accounting, not successful resize length. Its no-violation result does not contradict Bug 4.
- Guest action coverage is 40/42: `VmoRangeError` and `ExfatBackendReadBlocked` are unobserved. Cold-tail stack evidence, physical cluster reuse, and an Uninit page reused after an in-EOF partial fault remain guest gaps.
- No vectored I/O, whole-call read snapshot, EOF-at-return, mmap, direct I/O, durability, device failure, or resource-exhaustion claim is made.
