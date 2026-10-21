# Instrumentation specification

## 1. Trace event schema

This is a Category B timebox trace. Each execution actor writes raw observed
values and a shadow delta to its own preallocated, single-writer trace buffer.
Syscall actors are the cooperating tasks. Device completions use a fixed
per-CPU completion actor instead of being appended to a submitting task's
buffer. The postprocessor reconstructs the model-only post-state, concatenates
the streams while preserving each actor's order, compresses all `start`/`end`
timestamps, and normalizes the two logical syscall owners to the strings `"0"`
and `"1"` used by `Trace.cfg`.

Every base action has exactly one event type with the same name. No base action
is silent in `Trace.tla`.

```json
{
  "tag": "trace",
  "event": "InodeHandleReadAcquireOffset",
  "tid": "0",
  "start": 101,
  "end": 104,
  "shadow_order": 17,
  "args": { "owner": "0" },
  "state": { "...": "postprocessor-reconstructed post-action snapshot" }
}
```

### Envelope

| Field | Type | Required meaning |
|---|---|---|
| `tag` | string | Always `"trace"`. |
| `event` | string | Exact base action name from the mapping below. |
| `tid` | string | Execution actor. Normal actions use logical owner `"0"`/`"1"`; BIO completion uses a stable per-CPU value such as `"bio-cpu-0"`. `Trace.tla` derives this actor domain from the file. |
| `start`, `end` | integer | Tight interval around only the mapped semantic action. The source-specific semantic-order stamp is taken inside this interval. |
| `shadow_order` | integer | Unique value from a relaxed global `fetch_add` at the ordered boundary described below. It orders offline shadow reconstruction only; `ViablePIDs` still uses the timebox. |
| `args.owner` | string | Normalized logical syscall owner. It equals `tid` except for `SubmittedBioComplete`, whose actor is the completion context and whose owner is the submitter. |
| `args.*` | action-specific | Start parameters or `SubmittedBioComplete.args.bio`; listed below. |
| `state` | object | Strong post-state snapshot produced offline from raw observations/deltas and validated by `ValidatePostState`. |

### Common post-state fields

Every final event contains every field in this table. Fields marked “observed”
come from the implementation value or branch recorded at the hook. Fields
marked “shadow” are reconstructed offline from those observations in
`shadow_order`. A shadow must never be filled from an expected TLA+ post-state.

| Trace field | TLA+ state | Capture source |
|---|---|---|
| `pc`, `op_kind`, `backend_mode` | `pc[owner]`, `opKind[owner]`, `backendMode[owner]` | Shadow `pc`; observed syscall kind, filesystem kind, and `O_DIRECT` flag select the other fields. `owner` means `args.owner`, not the execution actor. |
| `requested`, `copied`, `committed`, `reported` | progress-class ledger | Observed request/copy/return counts, the cumulative retained-prefix observation, and BIO disposition, normalized to `Zero`, `Positive`, or `Complete`. |
| `copied_total`, `committed_total`, `visible_total`, `reported_total` | aggregate abstract units | Shadow totals updated only from the observed per-entry classes; at most 4 for two entries. |
| `result`, `entry_result`, `copy_fault` | syscall/backend outcome | Observed `Result` branch and tuple fault count, normalized to the spec strings. |
| `io_offset`, `explicit_offset`, `append_mode` | current local position/arguments | Function locals and `StatusFlags::O_APPEND`. |
| `old_file_size`, `planned_end`, `page_state`, `range_class` | backend preparation/disposition | Inode/page-cache locals. For an aggregate fault, `page_state` is only the actual faulting page state (`UpToDate` or `Uninit`); cumulative earlier retention is captured separately as `args.retained_prefix`. `range_class` is `InPlace` or `Extending`. |
| `file_size_snapshot`, `entry_data_epoch`, `buffer_epochs` | ramfs/read generation diagnostics | Observed size local plus shadow epochs read from the shared effect counter at copy completion. These fields validate trace reconstruction; vector conflict classification uses range overlap because the counter is inode-wide. |
| `vector_index` | `vectorIndex[owner]` | Observed loop index, 1 or 2. |
| `vector_intervened_all` | complete `vectorIntervened` function | JSON object keyed by every logical owner. Shared OFD movement updates vectors in an offset gap. Range-overlapping writes conflict with either vector direction; range-overlapping reads conflict with a vector write because they can observe its split state. Append pre-positioning is recorded even if the backend later faults at zero. |
| `attempt_id`, `effect_token`, `direct_part` | attempt/effect identity | Per-owner shadow. Restart increments `attempt_id` but preserves `effect_token`. |
| `sa_restart`, `restart_pending`, `interruptible_backend` | signal/restart state | Signal flags plus per-owner shadow. Current ext2/ramfs traces always emit `interruptible_backend: false`. |
| `ofd_offset`, `offset_owner` | shared OFD position/owner | Observed `InodeHandle::offset` while its mutex is already held, plus shadow owner changed at acquire/release hooks. |
| `data_owner` | inode/page-cache critical-section owner | Shadow changed only at existing inode/page-cache guard acquire/release hooks; no new mutex. |
| `file_size`, `data_epoch` | visible inode size/data generation | Observed inode size plus a shared atomic shadow epoch advanced after retained/public data effects. |
| `expected_offset`, `expected_file_size` | Linux-contract shadows | Offline state updated only from observed successful return counts and size outcomes. |
| `size_publication_owners` | speculative ramfs size owners | Sorted array of normalized IDs from the trace shadow. |
| `pending_bios`, `completed_bios` | direct-I/O lifecycle sets | Sorted arrays of `[owner, attempt_id, effect_token, vector_entry, segment, range_start]`; scalar direct I/O uses vector entry 0. `range_start` is the abstract start of that segment. |
| `positional_ofd_expected_all` | complete `positionalOFDExpected` function | JSON object keyed by every logical owner. Positional entry snapshots the live OFD offset; every shared OFD publication refreshes all active positional expectations. |
| `commit_counts` | effect replay counts | Sparse sorted array of `{"key":[owner,effect_token,part],"count":n}` entries with nonzero counts. `Trace.tla` reconstructs the full function. |

The contract/identity shadows are not read from user memory and do not exist as
shared online state. At each hook, record the observed inputs and a compact
event-specific delta. Obtain `shadow_order` at a synchronization-coupled point
inside the timebox: after a protected state update but before its guard is
released; after a guard acquisition; immediately before the guard drop for
`FileOpsReleaseData`; and immediately before the release publication for BIO
completion. These placements ensure any operation that observes the transition
receives a later order while unrelated overlapping operations may take either
order. Then record `end` and append the fixed-size raw record to the execution
actor's buffer. The postprocessor
sorts copies of all raw records by `shadow_order`, applies the matrix below to a
single offline `TraceShadow`, and attaches the resulting full snapshot to each
event. It then restores per-actor buffer order for NDJSON emission. Assert that
orders are unique, monotonic within each actor, and consistent with every
nonoverlapping `[start, end]` pair. Do not append a completion to an owner's
buffer, and do not allocate, format JSON, perform registry lookup, or take a
shared output lock on the measured path.

### Offline shadow reconstruction matrix

Each row is a complete rule for the listed event group. Unlisted fields retain
their previous value. The hook records the listed observations and delta; the
postprocessor applies the rule in `shadow_order` and attaches the resulting
fixed-size snapshot. This makes the common snapshot executable without asking a
hook to infer a TLA+ state or racing an online shadow update.

| Events | Observed inputs | Shadow updates |
|---|---|---|
| Six `*Start` events | syscall kind, request length, backend/flags, explicit offset, append and restart flags, current file size/page state | Increment `attempt_id`; assign a fresh `effect_token`; reset progress, totals, results, vector fields, and direct part; set `pc` to `AcquireOffset` or `BeginPositional`. |
| `InodeHandleReadAcquireOffset`, `InodeHandleWriteAcquireOffset` | guarded `*offset` | Set `offset_owner = owner`, `io_offset = *offset`, and the next `pc`. |
| `InodeHandleReadAtBegin`, `InodeHandleWriteAtBegin` | explicit positional argument and current OFD offset | Set `io_offset = explicit_offset` and `positional_ofd_expected_all[owner] = ofd_offset`; leave the live OFD and contract offset unchanged. |
| `InodeHandleWriteChooseAppendStart` | EOF and guarded pre/post-assignment offsets | Set `ofd_offset`/`io_offset` to EOF and refresh `positional_ofd_expected_all` for every active positional owner; do not update `expected_offset` until success. If the assignment changes f_pos, mark every other vector in its OFD gap before any backend outcome. |
| `RamInodeReadAtSnapshotSize`, `FileOpsAcquireData` | snapshotted EOF; acquired backend guard | Set `file_size_snapshot`; then set `data_owner = owner` and the copy/prepare `pc`. The data-conflict witness remains open until this acquisition. |
| `Ext2InodeWriteAtZeroLengthReturn` | observed zero request before ext2 `self.inner` acquisition | Set `entry_result = EntryOk`, `reported = Zero`, and `pc = InodeReturn`; leave `data_owner`, data, size, and effect state unchanged. |
| `InodeInnerPrepareWrite`, `RamInodeWriteAtPublishMetadata` | old size, request end, zero-length branch, published ramfs size | Set `old_file_size`, `planned_end`, and `range_class`; for ramfs update `file_size` and the owner bitmap from the observed publication. An EOF extension also marks overlapping vectors immediately, before copy outcome. |
| Six aggregate `FileOps*Copy*` outcomes | request size, writer/reader cursor before and after the complete scalar backend call, final `Result`, actual faulting page state, and cumulative retained-prefix class | Emit exactly once per scalar call, regardless of zero, one, or many internal page/range copies. Normalize the cumulative cursor delta, set `copy_fault`, and advance to `BackendFinish`; read outcomes also sample `data_epoch`. For `FileOpsWriteAtCopyFaultPositive`, set `committed` from the observed `args.retained_prefix` before the later retain/rollback disposition. |
| Three `BioSegmentWriteFallible*` outcomes | current direct range, per-range tuple count, fault branch, vector/direct part | Keep one event per modeled direct range. Complete advances to submit; faults advance to rollback. |
| `InterruptibleBackendReturnEintr` | reference-only EINTR after the copy/publication seam | Preserve copied progress; for a published write set committed progress, `data_epoch`, the selected `commit_counts` slot, and affected vector witnesses. Set `entry_result = EntryEintr`, `reported = Zero`, and `pc = ReleaseData`. Pinned ext2/ramfs never emit it. |
| Seven read/backend finish events | actual return/error branch, copied prefix, page state/dirty disposition, post-call file size | `FileOpsReadAtFinish` covers buffered/ramfs reads, including ext2's pre-VMO EOF return; `InodeInnerReadDirectAtFinish` covers ext2 direct reads. Set committed/reported classes and `entry_result`; retained/public positive writes increment `data_epoch`, the selected `commit_counts` slot, and every qualified `vector_intervened_all` entry. Update expected size only for observed successful positive expansion, then set `pc = ReleaseData`. |
| `BioSubmit`, `SubmittedBioComplete` | stable BIO identity including abstract range start, submitting attempt/effect, current owner attempt, and final completion | Set/clear the fixed pending bit and set the completed bit. Completion increments `data_epoch` and the effect's commit count; when owner attempt/effect still match, derive `committed[owner]` from all completed segment bits regardless of completion order. Mark only vectors whose range overlaps the stored BIO segment, including the same owner when it has moved to a later attempt. No base field changed by completion is omitted. |
| `IoBatchWaitAll`, `InodeInnerWriteDirectAtCommit`, `InodeInnerWriteDirectAtRollback` | empty current-attempt batch, final result, post-rollback size | Advance `pc`; commit sets complete progress and expected size, rollback records `EntryFault` without clearing previously submitted BIO slots. Commit/rollback finish at `ReleaseData`. |
| `FileOpsReleaseData` | observed drop/return of the existing inode/page-cache guard | Set `data_owner = NoThread` and `pc = InodeReturn`; retain the shared OFD owner until the following `InodeHandle*Return*` event. This transition opens the positional-write window before OFD publication. |
| Four `InodeHandle*Return*` events | backend result, returned length, guarded post-call OFD offset | Release only `offset_owner`. Shared success updates `expected_offset` from the observed length and refreshes every active positional expectation to the new OFD value; positional events leave both unchanged. Error leaves them unchanged, including after append pre-position. |
| Six `DoSys*Entry*` events | loop index, scalar result, `total_len`, cursor remaining/available | Accumulate observed progress classes; append the read entry epoch; either increment `vector_index` and reset entry state or set the completed result and `pc = Idle`. |
| Four scalar syscall return events | syscall return/error and notification length | Copy per-entry progress into totals, normalize `result`, and set `pc = Idle`. |
| Six EINTR/signal/restart events | errno mapping, signal flags, saved return, rewind decision | Advance the restart PCs without consulting progress; set/clear `restart_pending`; a non-restarted EINTR publishes the observed copied/visible/committed totals; restart increments `attempt_id`, preserves `effect_token`, and resets only per-attempt progress. Re-entry has no unrelated-lock precondition. |

### Action-specific arguments

| Event | Extra `args` fields |
|---|---|
| `SysReadStart` | `backend`, `restartable` |
| `SysWriteStart` | `backend`, `requested`, `append_mode`, `restartable`, `page_state` |
| `SysPread64Start` | `backend`, `explicit_offset` |
| `SysPwrite64Start` | `backend`, `requested`, `explicit_offset`, `page_state` |
| `DoSysReadvStart` | `backend` |
| `DoSysWritevStart` | `backend`, `page_state` |
| `FileOpsWriteAtCopyFaultPositive` | `retained_prefix`: cumulative pre-rollback class, `Zero` or `Positive` |
| `SubmittedBioComplete` | `bio`: `[owner, attempt_id, effect_token, vector_entry, segment, range_start]` |

All other events carry only `args.owner`.

## 2. Action-to-code mapping

“Common” in the Fields column means the full post-state above plus
`args.owner`. Start and BIO-completion rows add the arguments listed above.

### Syscall entry and critical-section boundaries

| Spec action / event | Code location | Trigger point | Fields |
|---|---|---|---|
| `SysReadStart` | `kernel/core/src/syscall/read.rs:21-35` | After the `VmWriter`/zero buffer path is selected and immediately before `file.read`/`read_bytes`. | Common + start args |
| `SysWriteStart` | `kernel/core/src/syscall/write.rs:21-35` | After the `VmReader`/zero buffer path is selected and immediately before `file.write`/`write_bytes`. | Common + start args |
| `SysPread64Start` | `kernel/core/src/syscall/pread64.rs:22-37` | After offset/overflow checks and writer creation, immediately before `file.read_at`. | Common + start args |
| `SysPwrite64Start` | `kernel/core/src/syscall/pwrite64.rs:22-35` | After offset/overflow checks and reader creation, immediately before `file.write_at`. | Common + start args |
| `DoSysReadvStart` | `kernel/core/src/syscall/preadv.rs:145-156` | After file lookup and `VmWriterArray` construction, before the first loop iteration. | Common + start args |
| `DoSysWritevStart` | `kernel/core/src/syscall/pwritev.rs:145-152` | After file lookup and `VmReaderArray` construction, before the first loop iteration. | Common + start args |
| `InodeHandleReadAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:281-287` | Timebox `self.offset.lock()`; end immediately after the guarded offset is read for `read_at`. | Common |
| `InodeHandleWriteAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:304-309` | Timebox `self.offset.lock()`; end immediately after acquisition. | Common |
| `InodeHandleReadAtBegin` | `kernel/core/src/fs/file/inode_handle.rs:323-331` | Immediately before positional `file_ops.read_at`, after copying the explicit offset locally. | Common |
| `InodeHandleWriteAtBegin` | `kernel/core/src/fs/file/inode_handle.rs:334-353` | Immediately before positional `file_ops.write_at`, after local append/offset handling. | Common |
| `InodeHandleWriteChooseAppendStart` | `kernel/core/src/fs/file/inode_handle.rs:310-315` | Timebox the `*offset = self.path().size()` assignment; snapshot after assignment. | Common |
| `RamInodeReadAtSnapshotSize` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-708` | After computing `(start, read_len)` from `self.size()`, before `page_cache.lock()`. | Common |
| `Ext2InodeWriteAtZeroLengthReturn` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:44-46,83-85` | Immediately before the buffered/direct `Ok(0)` return, before any `self.inner` guard is acquired. | Common |
| `FileOpsAcquireData` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31,50,70,94`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:709,731` | Timebox acquisition of the existing inode/page-cache guard. Refine start/end to the lock operation. | Common |
| `InodeInnerPrepareWrite` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:193-201,245-260,297-310` | Zero-length branch: just before `Ok(0)`. Nonzero branch: immediately after successful `prepare_write`. | Common |
| `RamInodeWriteAtPublishMetadata` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:733-749` | After dropping `inode_meta`, including size/blocks publication, before resize/page-cache copy. | Common |

### Copy outcomes

| Spec action / event | Code location | Trigger point | Fields |
|---|---|---|---|
| `FileOpsReadAtCopyComplete` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242,274-287,331-362`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710`; internal loop `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566` | While the existing data guard is held, emit once after the scalar backend read succeeds. Compare the outer `VmWriter` cursor before/after the whole call. This event also covers ext2 EOF/no-copy and direct-read hole paths. Emit before the following backend-finish event. | Common |
| `FileOpsReadAtCopyFaultZero` | Same read locations; tuple conversion `kernel/core/src/error.rs:209-219` | Capture the backend `Result` instead of using `?`, compare the outer writer cursor, and emit once when the cumulative delta is zero before propagating the error. Never emit per internal page/range call. | Common |
| `FileOpsReadAtCopyFaultPositive` | Same read locations; internal fallible calls `ostd/src/mm/io/mod.rs:332-362` | Same boundary when the cumulative outer-writer delta is positive, including earlier complete pages/ranges followed by a later fault. Emit before scalar error conversion. | Common |
| `FileOpsWriteAtCopyComplete` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:727-752`; internal loops `kernel/core/src/vm/page_cache/vmo/mod.rs:667-759` | While the existing data guard is held, emit once after the buffered/anonymous page-cache call succeeds. Compare the outer `VmReader` cursor before/after the whole call; ramfs zero-length writes emit this zero-delta event. | Common |
| `FileOpsWriteAtCopyFaultZero` | Same write locations; tuple conversion `kernel/core/src/error.rs:209-219` | Capture the page-cache `Result`, compare the outer reader cursor, and emit once when the cumulative delta is zero before backend disposition/rollback. | Common |
| `FileOpsWriteAtCopyFaultPositive` | Same write locations; internal fallible calls `ostd/src/mm/io/mod.rs:332-385`; per-page disposition `kernel/core/src/vm/page_cache/vmo/mod.rs:724-750,1019-1052` | Same boundary when the cumulative delta is positive, including faults after earlier complete page copies. Record the actual faulting `page_state` and the cumulative pre-rollback `args.retained_prefix` independently. For ext2, a successful earlier page sets the local retained tracker before the loop advances; a later `Uninit` fault does not clear it. For ramfs, every positive anonymous-page prefix is retained. | Common + `args.retained_prefix` |
| `BioSegmentWriteFallibleComplete` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-390` | Immediately after `bio_segment.writer().write_fallible(reader)` succeeds, before `write_blocks_async`. | Common |
| `BioSegmentWriteFallibleFaultZero` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-390`; `ostd/src/mm/io/mod.rs:332-362` | On tuple error with zero bytes in the current range, before `?` unwinds the range loop. | Common |
| `BioSegmentWriteFallibleFaultPositive` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-390`; `ostd/src/mm/io/mod.rs:332-362` | On tuple error with a positive current-range prefix, before `?` unwinds. | Common |
| `InterruptibleBackendReturnEintr` | test-only reference `FileOps` backend at the result seam represented by `kernel/core/src/fs/file/inode_handle.rs:287,317` and mapping at `kernel/core/src/syscall/read.rs:36-39`, `write.rs:36-39`; negative pinned evidence `ostd/src/sync/wait.rs:69-85`, `kernel/libs/io-util/src/batch.rs:147-164` | A dedicated reference harness must inject EINTR after an observed copy/publication in the test-only backend and emit this event as the error crosses `FileOps`. There is no pinned ext2/ramfs producer, so their harness must never emit it. | Common |

### Backend disposition and direct-I/O lifecycle

| Spec action / event | Code location | Trigger point | Fields |
|---|---|---|---|
| `FileOpsReadAtFinish` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710`; VMO/error paths `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566`, `kernel/core/src/error.rs:195-219` | Buffered ext2/ramfs only: immediately after the aggregate copy event, record the scalar result/length while the data guard is held. Emit for ext2 EOF/no-copy as well as VMO success/error. Never emit for ext2 direct reads. | Common |
| `InodeInnerReadDirectAtFinish` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:274-287,331-362`; `kernel/core/src/error.rs:209-219` | At `read_direct_at` success after `read_direct_blocks`, or on its mapped-range fallible-copy error immediately before `?` propagates the scalar error. | Common |
| `VmoWritePagesWithBackendFinishSuccess` | `kernel/core/src/vm/page_cache/vmo/mod.rs:734-759`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-271` | After dirty marking and ext2 size/timestamp commit, before returning `Ok(write_len)`. | Common |
| `VmoWritePagesWithBackendFaultRetain` | `kernel/core/src/vm/page_cache/vmo/mod.rs:724-750`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265`; `kernel/core/src/vm/page_cache/mod.rs:246-280` | Positive cumulative retained progress intersecting old-file data: after `set_dirty` and ext2 rollback, before returning the error. The faulting page may be `UpToDate`, or it may be a later `Uninit` page reached after an earlier page was already dirtied. | Common |
| `VmoWritePagesWithBackendFaultDiscard` | `kernel/core/src/vm/page_cache/vmo/mod.rs:727-746,1019-1052`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265`; `kernel/core/src/vm/page_cache/mod.rs:246-280` | Zero retained progress, including an `Uninit` fault with no earlier dirty page, or an extending prefix wholly beyond old EOF: after disposition/rollback, before returning the error. | Common |
| `VmoWriteAnonymousPagesFinishSuccess` | `kernel/core/src/vm/page_cache/vmo/mod.rs:681-700`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:747-756` | After anonymous page copy and before ramfs returns `Ok(write_len)`. | Common |
| `VmoWriteAnonymousPagesFinishFault` | `kernel/core/src/vm/page_cache/vmo/mod.rs:689-691`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:747-750` | On page-cache write error after metadata was published, before `?` returns. | Common |
| `BioSubmit` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:388-390`; `kernel/core/comps/block/src/bio.rs:121-150` | After successful enqueue and `io_batch.push`, before the next mapped range. | Common |
| `SubmittedBioComplete` | `kernel/core/comps/block/src/bio.rs:239-270` | In the real device completion context, timebox callback/status publication through `wake_all`; snapshot immediately after status is final. Set `tid` to the per-CPU completion actor and `args.owner`/`args.bio` from submit-time identity. | Common + `args.bio` |
| `IoBatchWaitAll` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:405-406`; `kernel/libs/io-util/src/batch.rs:147-164` | After `wait_all()` succeeds and before returning from `write_direct_blocks`. | Common |
| `InodeInnerWriteDirectAtCommit` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:319-328` | After timestamp/file-size commit and immediately before `Ok(write_len)`. | Common |
| `InodeInnerWriteDirectAtRollback` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,319-321` | After `rollback_write`, before returning the direct-copy error; do not await/cancel prior BIOs. | Common |
| `FileOpsReleaseData` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31,51,70,95`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:709-710,750-756` | Immediately after the existing inode/page-cache guard drops as `read_at`/`write_at` returns, before `InodeHandle` consumes the `Result` or updates its guarded OFD offset. | Common |

### Nested return and vector dispatch

| Spec action / event | Code location | Trigger point | Fields |
|---|---|---|---|
| `InodeHandleReadReturnOk` | `kernel/core/src/fs/file/inode_handle.rs:285-290,323-332` | After successful shared offset addition (or positional no-op) and OFD guard release; the backend guard release is the preceding event. | Common |
| `InodeHandleReadReturnError` | `kernel/core/src/fs/file/inode_handle.rs:285-290,323-332` | On backend error after OFD guard release; shared offset addition is skipped and the backend guard is already gone. | Common |
| `InodeHandleWriteReturnOk` | `kernel/core/src/fs/file/inode_handle.rs:308-320,334-353` | After successful offset addition (or positional no-op) and OFD guard release; the backend guard release is the preceding event. | Common |
| `InodeHandleWriteReturnError` | `kernel/core/src/fs/file/inode_handle.rs:308-320,334-353` | On backend error after OFD guard release; post-call addition is skipped, append pre-position remains, and the backend guard is already gone. | Common |
| `DoSysReadvEntryOkContinue` | `kernel/core/src/syscall/preadv.rs:156-174` | After adding `read_len`, when the writer is exhausted and another iovec remains; before next loop call. | Common |
| `DoSysReadvEntryOkReturn` | `kernel/core/src/syscall/preadv.rs:165-180` | After EOF/partial/final-entry branch chooses to leave the loop, before return. | Common |
| `DoSysReadvEntryFaultReturn` | `kernel/core/src/syscall/preadv.rs:165-180` | In either error match arm after deciding suppress-versus-return, before function return. | Common |
| `DoSysWritevEntryOkContinue` | `kernel/core/src/syscall/pwritev.rs:152-170` | After adding `write_len`, when the reader is exhausted and another iovec remains. | Common |
| `DoSysWritevEntryOkReturn` | `kernel/core/src/syscall/pwritev.rs:161-175` | After partial/final-entry loop exit, before return. | Common |
| `DoSysWritevEntryFaultReturn` | `kernel/core/src/syscall/pwritev.rs:161-175` | In either error match arm after suppress-versus-return decision. | Common |

### Syscall result and restart

| Spec action / event | Code location | Trigger point | Fields |
|---|---|---|---|
| `SysReadReturn` | `kernel/core/src/syscall/read.rs:36-44` | After non-EINTR result mapping/notification decision, immediately before `SyscallReturn::Return` or EFAULT propagation. | Common |
| `SysWriteReturn` | `kernel/core/src/syscall/write.rs:36-44` | Same point for write. | Common |
| `SysPread64Return` | `kernel/core/src/syscall/pread64.rs:33-43` | After result/notification decision, before positional syscall return. | Common |
| `SysPwrite64Return` | `kernel/core/src/syscall/pwrite64.rs:33-41` | After result/notification decision, before positional syscall return. | Common |
| `SysReadTranslateEintr` | `kernel/core/src/syscall/read.rs:36-39` | Immediately after mapping EINTR to ERESTARTSYS. | Common |
| `SysWriteTranslateEintr` | `kernel/core/src/syscall/write.rs:36-39` | Immediately after mapping EINTR to ERESTARTSYS. | Common |
| `HandlePendingSignalClassify` | `kernel/core/src/process/signal/mod.rs:54-62` | After replacing ERESTARTSYS with userspace EINTR and retaining `orig_syscall_ret`. | Common |
| `HandlePendingSignalRestart` | `kernel/core/src/process/signal/mod.rs:145-158` | After restoring return/arguments and rewinding IP for `SA_RESTART`. | Common |
| `HandlePendingSignalNoRestart` | `kernel/core/src/process/signal/mod.rs:145-158` | After the user-signal branch decides not to rewind IP. | Common |
| `TaskRestartSyscall` | `kernel/core/src/thread/task.rs:83-105` | On the next `ReturnReason::UserSyscall`, immediately before re-entering the same read/write wrapper. | Common |

## 3. Special considerations

- Keep `[start, end]` tight around each listed semantic operation. Record the
  observed inputs/delta and obtain `shadow_order` at the synchronization-coupled
  point above, then capture `end`; write only a compact fixed-size raw record to
  the execution actor's buffer. Reconstruct common state and serialize JSON
  after the test.
- Lock-acquire events stamp after acquisition. State-update events stamp after
  the update and before unlock. `FileOpsReleaseData` stamps immediately before
  dropping the existing guard. Raw capture must not allocate or format while an
  OFD/inode/page-cache lock is held.
- Do not maintain a shared online `TraceShadow`. The relaxed `shadow_order`
  counter does not guard kernel state and is not a replay-order constraint;
  `ViablePIDs` still explores every ordering allowed by the recorded intervals.
  Post-state validation prunes orderings inconsistent with the offline snapshot.
- `SubmittedBioComplete` stays in its device completion actor's stream. Store
  normalized owner/attempt/effect/entry/segment/range-start identity in the BIO at submit
  time. The post-state update changes the submitting owner's current
  `committed` class only when attempt/effect still match, but its write-conflict
  witness compares the stored attempt and range with every currently active
  vector and therefore includes an overlapping later vector from the same owner.
- Emit each `FileOps*Copy*` event once at the scalar backend boundary. Do not
  emit it from each `read_fallible`/`write_fallible` call inside a VMO page or
  direct-read range loop. The outer cursor delta supplies cumulative progress,
  including no-copy and multi-call paths.
- For backed writes, maintain a trace-only per-call retained-prefix accumulator
  beside the existing page loop. Set it after every successful positive page
  write and after a positive fault on an `UpToDate` page; do not clear it when
  a later `Uninit` page faults. Emit its `Zero`/`Positive` class as
  `FileOpsWriteAtCopyFaultPositive.args.retained_prefix` before ext2 rollback.
  This is an observed loop outcome, not a value inferred from the TLA+ state.
- Preserve each execution actor's event order when concatenating streams. Do
  not sort events globally or move completion into an owner stream. Compress
  timestamps by rank while preserving `<` and overlap relations; `Trace.tla`
  derives `ViablePIDs` from those intervals.
- The default trace path is `../traces/trace.ndjson`; validation may select a
  different file with the `JSON` environment variable.
- A validation input must contain at least one `tag: "trace"` event for every
  logical owner listed in `Trace.cfg`. Empty, wholly untagged, and missing-owner
  inputs trigger the `TraceInit` assertion; completion actor IDs are derived
  from the trace and are not listed in `Trace.cfg`.
- `InitialFileSize`, `MaxAttempts`, and `MaxOffset` in `Trace.cfg` must match
  the focused harness scenario. Keep traces short (roughly 50–200 events).
- Current ext2/ramfs traces must contain no interruption/restart events. A
  separate reference-capability trace requires
  `EnableReferenceInterruptible = TRUE` in a dedicated config and the test-only
  interruptible `FileOps` backend described in the mapping. The seven-event
  reference path is `InterruptibleBackendReturnEintr`, the two
  `Sys*TranslateEintr` alternatives, `HandlePendingSignalClassify`, the restart
  and no-restart delivery alternatives, and `TaskRestartSyscall`.
- Before handoff, require all 52 pinned-producible event types among the 59
  mappings above in at least one ext2/ramfs trace, all seven reference-path event
  types across dedicated harness traces, and at least one trace with genuine
  cross-thread interval overlap. Historical issue IDs and source TODO/FIXME text
  are not trace events or findings.
