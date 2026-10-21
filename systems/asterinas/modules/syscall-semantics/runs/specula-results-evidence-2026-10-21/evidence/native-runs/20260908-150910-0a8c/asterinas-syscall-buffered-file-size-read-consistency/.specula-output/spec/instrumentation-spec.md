# Instrumentation mapping

Category B, revision `604948581512d83734377974d4c34adb4530f2d7`. This is a harness handoff; no kernel instrumentation or guest execution was performed during generation.

## 1. Trace event schema

### Files and bootstrap

Raw per-thread files belong in `../traces/` relative to spec/. Run [preprocess_trace.py](preprocess_trace.py) to assemble per-thread arrays and compress timestamps. Its output is one JSON object on one NDJSON line. Trace.tla defaults to `../traces/trace.ndjson`; environment variable `JSON` selects another file. File order never imposes cross-thread ordering.

Bootstrap example (all counts and offsets have already undergone the exact model-unit mapping):

```json
{"format":"asterinas-buffered-v1","revision":"604948581512d83734377974d4c34adb4530f2d7","backend":"ramfs","p":2,"g":2,"max_byte":6,"initial_size":2,"warm_pages":[0],"initial_position":0,"threads":["t0","t1"]}
```

- The preprocessor adds `traces`, an object mapping each thread string to its event array. Every thread is present, including an idle thread with an empty array. A wholly empty trace is rejected.
- Initial subject bytes below initial_size are tagged `seed`; backing bytes beyond it are `zero`. Ramfs requires every seeded page to be resident. ext2/exFAT may begin cold. No operation is already in flight at bootstrap.
- `p` is the normalized PAGE_SIZE; `g` is the normalized exFAT cluster size. Establish the physical cluster-reuse fixture separately when exercising TV3. Track only the same subject’s old clusters.
- The unit map must preserve exact offsets, transfer counts, copy fault boundaries, page/cluster boundaries and uniform byte tags. Reject nonrepresentable values. Never round a partial count to make a trace fit.

### Event envelope

```json
{"tag":"trace","event":"RamfsReadAtObserve","tid":"t0","start":17,"end":18,"args":[],"state":{"local":{},"accepted":[],"held":{},"inode":{},"pages":[],"disk":[],"blocks":[],"position":[]}}
```

The empty local/held objects above show envelope shape only; they are invalid as a trace event. All events must carry the complete mandatory projections below. `args` is `[kind, original_offset, length, resize_target, accessible_prefix]` for SyscallEnter and `[]` for every other action. Read ignores original_offset and uses the locked shared position. `accessible_prefix=length` means no copy fault; a smaller value is established before the syscall and remains fixed.

| State field | Required representation and validation |
|---|---|
| `local` | Exact `LocalObserved` record from Trace.tla, with the fields listed below. No zero-value omission. Every value is compared with q after the full base action. |
| `accepted` | Duplicate-free array of absolute byte-cell offsets accepted by user write copies so far. Compare to q.accepted; zero filling does not add entries. |
| `held` | Exact booleans `{cache, writer, up, reader, offset}` for this thread after the action. Compare against mu ownership/membership. Retain ownership in thread-local trace context; no global registry or extra shared lock. |
| `inode` | Exact map of required scalar fields from the action table below: L, C, A, clusters or npages. All emitted keys are compared with f after the action. Otherwise `{}`. |
| `pages` | Array of `{index,state,data}` for exactly the affected pages, no duplicates. States are Absent/Uninit/Clean/Dirty. data has p cell tags. Compare state and data against f after the action. Otherwise `[]`. |
| `disk` | Array of `{index,data}` for exactly the newly zeroed ext2 blocks. Compare the p tags with f.disk after allocation. Use actual completed zero-write receipts, without issuing diagnostic disk reads in the hot path. Otherwise `[]`. |
| `blocks` | A one-element array containing the allocated ext2 page-index set, for Ext2AllocateRangeBlocks, Ext2ResizePublish and Ext2RollbackBlocks. Otherwise `[]`. Distinguishes an observed empty set `[[]]` from no observation `[]`. |
| `position` | One-element array for SyscallEnter(read) and InodeHandleReturn(read), captured from the held offset guard immediately before releasing it. Otherwise `[]`. Positional calls do not acquire an extra offset lock to trace. |

The mandatory local fields are:

`pc`, `kind`, `O`, `N`, `target`, `fault`, `S`, `K`, `copyO`, `candidate`, `D`, `status`, `errorSite`, `result`, `ioKind`, `ioOff`, `ioLen`, `ioDone`, `ioEnd`, `page`, `afterIo`, `resizeOld`, `resizeNew`, `resizePurpose`, `afterResize`, `segmentEnd`, `collectNext`, `collectEnd`, `overwrite`, `out`.

| Local fields | Native source or retained observation |
|---|---|
| kind, O, N, target, fault | Validated syscall inputs and the pre-established user mapping boundary. O is never replaced by the clamped read offset. |
| S, K, copyO, candidate | Actual backend locals for file_size/read_len/read_off/new_size, retained across guard lifetimes. K is not replaced with observed D. |
| D | Sum of actual VmReader/VmWriter cursor deltas at ostd/src/mm/io/mod.rs:354-355. initial_avail-final_avail is invalid after ext2 writer.limit. |
| result, status, errorSite | Actual backend/syscall return and failing source site. result stays -1 until BackendReturn; Pending becomes Ok there. EFAULT/EINVAL remain errors. |
| ioKind, ioOff, ioLen, ioDone, ioEnd | VMO call inputs, capacity-clamped range and actual progress. Zero-copy progress is separate from D. |
| page, segmentEnd, collectNext, collectEnd, overwrite | Actual current page/index ranges and CommitMode; retain collection progress separately from copy progress. |
| resizeOld, resizeNew, resizePurpose | Actual PageCache resize arguments; purpose identifies ordinary resize, write preparation or rollback. Ramfs write preparation passes a rounded new argument. |
| out | A max_byte-cell destination receipt. Sentinel tags are initialized before the attempt; update only independently observed stores. Fault-inaccessible cells are represented from the pre-established sentinel plus store/cursor evidence, never read unsafely by the logger. |
| pc, afterIo, afterResize | Control markers derived from the actual executed branch/hook and caller context. These describe stage selection; they are not substitute observations for S/K/D/result or file bytes. |

Tags are strings: `zero`, `seed`, `sentinel`, `uninit`, or a thread ID for that thread’s stable source payload. The byte representation is an abstraction of uniform user/subject contents. Never serialize raw uninitialized kernel frames: `uninit` denotes unknown, unreadable cells. Copied prefixes in an Uninit page can have known tags while still being unaccepted; later backend initialization replaces them.

`h` and the local oldView/solo/reference/startPosition history fields are specification observers. They have no independent native mutable counterpart. They are rebuilt by the same full base actions from validated inputs, cursor/copy receipts, publication events and the read position. No action bypasses these updates. The logger must not invent a file-size observation while lacking its protecting lock.

## 2. Action-to-code mapping

Paths beginning ramfs/, ext2/ or exfat/ are under `source/kernel/core/src/fs/fs_impls/`. Paths beginning syscall/, fs/ or vm/ are under `source/kernel/core/src/`. OSTD paths begin at `source/ostd/`. Each row’s trace event name is exactly its spec action name; Trace<action> is its wrapper.

Every row carries local, accepted and held plus the complete state envelope. Extra required observations are listed below. Native field capture occurs at the specified source transition under its existing guard; format and enqueue the retained snapshot afterward.

| Spec action / event | Code location | Trigger | Extra fields / notes |
|---|---|---|---|
| `SyscallEnter` | `syscall/read.rs:27-44; pread64.rs:33-43; pwrite64.rs:33-41; truncate.rs:15-28; fs/file/inode_handle.rs:285-287` | After stable user-range setup; for read after taking the offset mutex, before backend dispatch. | Five input arguments; local/held; position for read. |
| `RamfsReadAtObserve` | `ramfs/fs.rs:703-708,784-785` | After saving file_size, clamped offset and read_len; metadata guard has ended. | S, copyO, K; local/held. |
| `RamfsReadAtAcquireCache` | `ramfs/fs.rs:709` | After acquiring cache mutex, before VMO read. | ioOff, ioLen; local/held. |
| `Ext2ReadAt` | `ext2/inode/file.rs:31,234-242` | After inner R acquisition and EOF/count selection, before VMO call. | S, K, writer limit, copyO, ioLen; local/held. |
| `ExfatReadAt` | `exfat/inode.rs:644-654` | After upread acquisition and saved count, before VMO call. | S, K, copyO, original ioLen; local/held. |
| `Ext2ReadAtEmpty` | `ext2/inode/file.rs:27-28` | Zero-count early return, before any inner guard. | local/held; no size observation. |
| `Ext2WriteAtEmpty` | `ext2/inode/file.rs:44-46` | Zero-count return, before inner W acquisition. | local/held; no candidate publication. |
| `RamfsWriteAtAcquireCache` | `ramfs/fs.rs:731` | Immediately after cache mutex acquisition, before metadata lock. | local/held. |
| `RamfsWriteAtPublish` | `ramfs/fs.rs:733-748` | After metadata size assignment and guard drop, before resize/copy. | L, S, candidate, resize arguments; local/held. |
| `Ext2WriteAtPrepare` | `ext2/inode/file.rs:50,252-257` | After W acquisition, checked end and saved old size, before prepare_write. | S, candidate, resize arguments; local/held. |
| `Ext2AllocateRangeBlocks` | `ext2/inode/file.rs:200,432-437; ext2/inode/block_manager/block_ptr_tree.rs:667-693` | After allocation and zero-write completion, while inode W remains held. | Full block index set; disk receipts for newly allocated model pages; local/held. |
| `ExfatWriteAtPrepare` | `exfat/inode.rs:715-726,731` | After W acquisition and end/size observations, before allocation/cache resize. | S, candidate=max(end,S), requested resize arguments; local/held. Candidate is a pure local calculation of the saved final value. |
| `ExfatResizeAllocation` | `exfat/inode.rs:286-314` | After cluster-count branch and size_allocated assignment, before returning helper. | L, A, clusters; local/held. No implicit zeroing. |
| `ExfatWriteAtReleasePreparation` | `exfat/inode.rs:732-735` | At preparation guard release, before attempting upread. | local/held; retain saved candidate. |
| `ExfatWriteAtAcquireCopy` | `exfat/inode.rs:735-736` | After upread acquisition, before PageCache write. | local/held; original O and N retained. |
| `RamfsResizeAcquireCache` | `ramfs/fs.rs:796` | After cache mutex acquisition, before metadata lock. | local/held. |
| `RamfsResize` | `ramfs/fs.rs:797-812` | After metadata observation and growth/no-change/shrink branch selection; before cache resize. | L, S, exact resize arguments; local/held. |
| `RamfsResizePublish` | `ramfs/fs.rs:813` | After metadata shrink publication, while cache remains held. | L; local/held. |
| `Ext2Resize` | `ext2/inode/file.rs:108-128` | After W acquisition and old size/branch selection. | S, resize arguments; local/held. |
| `Ext2ResizePublish` | `ext2/inode/file.rs:412-415,426-428` | After block truncation if shrinking and logical size assignment. | L, block set; local/held. |
| `ExfatResize` | `exfat/inode.rs:1437-1448` | After U acquisition and file_size observation, before upgrade. | S, resize arguments; local/held. |
| `ExfatResizeUpgrade` | `exfat/inode.rs:1450-1455` | After atomic U-to-W upgrade, before optional cache shrink. | local/held; extension skips cache resize. |
| `PageCacheResizeBegin` | `vm/page_cache/mod.rs:246-255` | At resize entry, after choosing the actual tail-zero interval. | resizeOld, resizeNew, ioOff, ioLen, ioKind=Zero; local/held. |
| `PageCacheFillZeros` | `vm/page_cache/vmo/mod.rs:644-660` | After the range check, before VMO write from the stable zero source. | local/held; user fault boundary is inactive for this copy. |
| `PageCacheResizeCapacity` | `vm/page_cache/mod.rs:258-282` | After capacity store and logical-shrink decommit, before returning resize. | C; page receipts for exactly the decommitted pages; local/held. No eviction on logical extension even if C decreases. |
| `Ext2ResizePageCacheBound` | `ext2/inode/mod.rs:478-481` | After block_manager.set_npages, with inode W held. | npages; local/held. |
| `WriteAtCopyStart` | `ramfs/fs.rs:750; ext2/inode/file.rs:262; exfat/inode.rs:736` | Immediately before PageCache write, after all preparation. | ioKind=Write, original ioOff/ioLen; local/held. |
| `VmoIoBegin` | `vm/page_cache/vmo/mod.rs:535-542,571-578` | After effective length and range computation, including the successful zero-length branch. | Actual effective ioEnd, ioOff/ioLen, ioDone; local/held. |
| `VmoCollectBegin` | `vm/page_cache/vmo/mod.rs:548-554,595-637,681-687,717-718` | Before collection of the next read/anonymous batch or backed head/middle/tail segment. | Actual segment end, collect index range and commit mode; local/held. |
| `VmoCommitPage` | `vm/page_cache/vmo/mod.rs:309-322,762-805,1020-1051,1056-1075` | After obtaining/inserting the page reference, before required backend initialization. Instrument both fast and fallback paths. | One page receipt, allocation state, collect index; local/held. No raw uninitialized frame bytes. |
| `VmoCollectedPage` | `vm/page_cache/vmo/mod.rs:548-557,681-690,717-724,762-805` | After a prepared page is retained in the batch; only the last page permits copying. | collectNext, collectEnd, current copy page; local/held. |
| `ExfatBackendReadBlocked` | `exfat/inode.rs:151; ostd/src/sync/rwmutex.rs:129-130,163-168` | At the failed nested read-lock attempt while the same thread retains inode W, before sleeping. | local/held; blocked PC is terminal within this subject, not a made-up EFAULT. |
| `VmoBackendRead` | `exfat/inode.rs:151-167; ext2/inode/block_manager/mod.rs:141-154; vm/page_cache/vmo/mod.rs:821-827,1032-1051; vm/page_cache/mod.rs:475-485` | After ensure_init succeeds, including an already-initialized recheck; before adding that page to the batch. | One initialized page receipt; local/held. ExFAT nested R is permitted under U. |
| `VmoRangeError` | `vm/page_cache/vmo/mod.rs:648-650; ext2/inode/block_manager/mod.rs:141-142; exfat/inode.rs:152-153` | At the real failed range/bound check, before propagating error or cleanup. | status, errorSite; local/held. Cleanup must retain the original write error. |
| `VmoCopyPage` | `ostd/src/mm/io/mod.rs:339-360; vm/page_cache/vmo/mod.rs:557,690,734-753` | After cursor advancement and page dirty-state handling for this page, before continuing or propagating the error. | Independent cursor delta, copied prefix tags, accepted offsets, status, result-independent D; page receipt for writes/zeros; local/held. |
| `Ext2WriteAtPublish` | `ext2/inode/file.rs:267-271` | After successful logical size assignment, before releasing W. | L; local/held. |
| `ExfatWriteAtPublish` | `exfat/inode.rs:740-744` | After atomic upgrade and saved new_size assignment, before dropping W. | L, saved candidate; local/held. Do not replace assignment with max(current L,candidate). |
| `Ext2RollbackWrite` | `ext2/inode/file.rs:205-214,257-264` | At rollback entry, before optional cache resize back to old size. | Original error, S, candidate, rollback resize arguments; local/held. |
| `Ext2RollbackBlocks` | `ext2/inode/file.rs:216-218` | After truncating block mappings, including after a logged resize cleanup error. | Block set; local/held. Previously accepted in-EOF bytes need not roll back. |
| `BackendReturn` | `ramfs/fs.rs:709-718,750-756,816; ext2/inode/file.rs:31-35,271; exfat/inode.rs:656-657,744-755,1462` | After the backend guard release and result selection. Ext2 positive read pauses before its separate atime W acquisition. | Actual backend result/error, local/held. Timestamp/storage errors are excluded in these fixtures. |
| `Ext2ReadAtUpdateAtime` | `ext2/inode/file.rs:32-35` | After the separate atime W acquisition/update/release, before returning the saved count. | local/held; logical size may have changed since copying. |
| `InodeHandleReturn` | `fs/file/inode_handle.rs:287-290,323-353,387-401; syscall/truncate.rs:15-28` | After result propagation and read offset update; release the offset guard at this boundary. | Actual syscall result/error, local/held; position for read. Positional operations do not sample an unlocked shared offset. |

## 3. Special considerations

### Timing and locking

- Preallocate per-thread ring buffers and IDs. Logging, formatting and ID lookup must not acquire shared locks, allocate in the critical path, or add a global sequence counter. Flush after the attempt. Use existing safe OSTD timing interfaces; do not add unsafe Rust under kernel/.
- Record start/end around each modeled semantic step, not around a whole syscall. Capture field values from the operation’s locals or while its existing protecting guard is still held, retain them locally, then serialize outside the timebox. A late unlocked reread is not a valid post-state snapshot.
- For a guard-release event, retain data while guarded; record the actual drop within the event interval, and record this thread’s resulting held flags afterward. Do not replace exFAT’s release/reacquire with downgrade, or hold a tracing lock across the gap.
- Timeboxes constrain only cross-thread order. Per-thread order is exact. The preprocessor preserves ties and overlap under dense timestamp compression. Events whose timeboxes overlap may be explored in either order, subject to the base guards and captured state.
- Page collection is observable. Instrument every page preparation and every later copy. A fault in the first copy does not erase initialization events for the rest of the already-prepared batch. Model capacity is at most 32 pages; larger batches need a specification extension.
- VmoCopyPage occurs after page-state handling. For an initialized page, a copied prefix remains accepted on EFAULT. A full-overwrite Uninit page retains Uninit on a failed partial copy; accepted does not grow for that fragment. Record D even when kernel error conversion discards the partial count.
- BackendReadBlocked is emitted before the nested lock wait. A trace ending there is a prefix, not evidence that a syscall completed. TV7’s completion timeout and blocked-stack evidence belong in the test sidecar. No silent trace action fabricates progress.

### Fixture and contract boundaries

- Run ramfs, ext2 and exFAT separately. Use valid regular files, stable mappings, distinct extending writer payloads/ranges, non-O_APPEND descriptors and non-sync fixtures. Device, metadata timestamp, allocation and resource failures are excluded unless separately established and modeled.
- Build warm/cold and cluster-reuse fixtures before bootstrap. Whole-page overwrite may skip initialization. A zeroed fresh disk cannot validate a stale backing-content hypothesis. Disk reallocation identity and side effects are external fixture evidence, not arbitrary model faults.
- Sidecars must retain requested inputs, raw returns/errno, independent delivered-prefix/suffix evidence, logical size and controlled offsets. User-level syscall logs alone cannot supply internal S/K/C/lock/acceptance events and cannot be labeled a successful Trace.tla replay.
- Short successful reads remain permitted; the [read contract](https://man7.org/linux/man-pages/man2/read.2.html) ties the reported count and shared-position advance to bytes read. [Positional I/O](https://man7.org/linux/man-pages/man2/pread.2.html) preserves the shared offset.
- The [resize contract](https://man7.org/linux/man-pages/man2/truncate.2.html) supplies isolated size and zero-extension expectations. The [write contract](https://man7.org/linux/man-pages/man2/write.2.html) supplies empty-write and successful-count expectations. General error rollback is not assumed.
- The narrow ramfs zero-progress error oracle additionally uses the pinned [Linux v6.12 generic_perform_write](https://github.com/torvalds/linux/blob/v6.12/mm/filemap.c#L4015) and [simple_write_end](https://github.com/torvalds/linux/blob/v6.12/fs/libfs.c#L960). Partial acceptance and current Asterinas cleanup remain distinct.

### Replay and interpretation

```sh
python3 preprocess_trace.py ../traces/bootstrap.json ../traces/trace.ndjson ../traces/thread-*.ndjson
JSON=../traces/trace.ndjson java -cp "$SPECULA_ROOT/lib/tla2tools.jar:$SPECULA_ROOT/lib/CommunityModules-deps.jar" tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
```

- Trace.cfg enables TraceMatched and core/structural checks. Scenario predicates remain in hunt cfgs so a real buggy execution can still validate the implementation model.
- TraceSpec has fairness only for the offline event cursor. It eliminates arbitrary replay stuttering, never enables a blocked base action and makes no kernel liveness claim.
- TLC temporal checking is universal over explored paths. If one viable ordering is a dead end, TraceMatched can fail even when another ordering consumes the whole trace. Use Trace_witness.cfg to search for an explicit TraceNotComplete invariant violation: that counterexample is a complete matching order. A partial dead end, parse error or timeout is never a match.
- Generation-time synthetic traces check parser/adapter behavior only. They cannot establish implementation fidelity or confirm any §6.1 finding. Real per-thread traces, event coverage, overlapping intervals and independent syscall evidence remain later validation gates.
