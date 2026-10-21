# Instrumentation Specification

This document maps every `base.tla` action to one trace event. The target is a
Category B kernel path, so tracing uses per-thread timeboxes and no global
emission lock. The harness must preserve safe Rust under `kernel/`; architecture
timestamp access belongs behind an existing safe OSTD API or a new safe OSTD
wrapper.

## 1. Trace event schema

### 1.1 Raw per-thread event

Each thread writes one NDJSON stream. Do not capture user-buffer contents,
virtual addresses, file contents, credentials, or unrelated syscall arguments.

```json
{
  "tag": "trace",
  "event": "VmoRead",
  "tid": "t1",
  "start": 101,
  "end": 108,
  "args": {"progress": "Prefix"},
  "state": {
    "shared_offset": 2,
    "offset_owner": "t1",
    "file_size": 6,
    "cache_capacity": 8,
    "adapter_profile": "Correct",
    "phase": "NeedTupleConversion",
    "kind": "Readv",
    "uses_shared_offset": true,
    "explicit_offset": 0,
    "entry_start": 2,
    "logical_avail": "Complete",
    "copy_limit": "Complete",
    "iov_index": 2,
    "requested": 4,
    "entry_copied": 1,
    "entry_returned": 0,
    "copied": 3,
    "committed": 3,
    "reported": 2,
    "offset_advanced": 2,
    "entry_status": "None",
    "result": "Pending",
    "last_fault_progress": "Prefix",
    "published_eof": "Zero",
    "read_past_eof": false,
    "size_at_entry": 6,
    "syscall_id": 1,
    "attempt_id": 1,
    "restart_pending": false,
    "signal_pending": false,
    "sa_restart": false,
    "effect_log_len": 2,
    "commit_log_len": 1
  }
}
```

`start` and `end` tightly bracket only the modeled transition. Capture the
post-state after `end`, then append to a thread-local buffer. No shared lock,
global event counter, synchronous file write, or allocation may execute on the
hot path.

### 1.2 Preprocessed trace file

The preprocessor merges per-thread NDJSON, compresses timestamps while
preserving order/overlap, and writes the object consumed by `Trace.tla`:

```json
{
  "initial_state": {
    "shared_offset": 0,
    "file_size": 6,
    "cache_capacity": 8,
    "adapter_profile": "Correct"
  },
  "traces": {
    "t1": [],
    "t2": []
  }
}
```

The default path is `../traces/trace.ndjson`. A validation run may override it
with `IOEnv.JSON`.

### 1.3 Progress encoding

Convert cursor deltas relative to the current entry's effective copy limit:

| Implementation observation | Trace value | TLA+ units |
|---|---|---|
| No cursor movement | `Zero` | 0 |
| Positive but incomplete movement | `Prefix` | 1 |
| Entire effective copy limit consumed | `Complete` | 2 |

For a two-entry vector, `requested` is 4 symbolic units. All other progress
fields are sums of these symbolic units. Do not emit exact byte/page counts.

### 1.4 Common post-state field sources

Every event carries every field below. This is what makes
`ValidatePostState` strong rather than conditional or vacuous.

| Trace field | Implementation or trace-shadow source | TLA+ field |
|---|---|---|
| `shared_offset` | Per-file trace shadow initialized with `InodeHandle::offset()` (`kernel/core/src/fs/file/inode_handle.rs:90-93`) and updated beside `*offset += len` (`:287-288`, `:317-318`). While the mutex is held, read the guard; do not recursively call `offset()`. | `sharedOffset` |
| `offset_owner` | Per-file trace-only owner set after `offset.lock()` and cleared after explicit guard drop; emit `"none"` when unlocked. | `offsetOwner` |
| `file_size` | Adapter-visible inode metadata: RamFS `metadata.size`, exFAT `inner.size`, or the corresponding correct-adapter getter. | `fileSize` |
| `cache_capacity` | `PageCache::size()` (`kernel/core/src/vm/page_cache/mod.rs:181-186`). | `cacheCapacity` |
| `adapter_profile` | Immutable harness scenario value: `Correct`, `RamFs`, or `Exfat`. One shared file must never change profile mid-trace. | `adapterProfile` |
| `phase` through `sa_restart` | Per-thread trace-only operation record. Update it at the same semantic boundary as the source transition. | `opState[tid]` fields with the same snake-to-camel mapping used in `Trace.tla` |
| `syscall_id` | Per-thread monotonic logical syscall ID. A restart reuses it. | `opState[tid].syscallId` |
| `attempt_id` | Starts at 1 and increments only when a rewound syscall re-enters. | `opState[tid].attemptId` |
| `effect_log_len` | Per-file trace-only count incremented for every positive user-memory or file-data copy event. | `Len(effectLog)` |
| `commit_log_len` | Per-file trace-only count incremented for every positive successful shared-offset entry commit. | `Len(commitLog)` |

The trace shadow is observational state only. It must not participate in
locking, error handling, scheduling, page-cache decisions, or syscall results.

### 1.5 Event-specific arguments

| Events | `args` fields |
|---|---|
| `SysReadBegin`, `SysWriteBegin`, `DoSysReadvBegin`, `DoSysWritevBegin` | `signal_pending`, `sa_restart` |
| `SysPread64Begin`, `SysPwrite64Begin` | `explicit_offset`, `signal_pending`, `sa_restart` |
| `VmoRead`, `VmoWrite` | `progress` |
| All other events | Empty object |

## 2. Action-to-code mapping

Every row is one spec action and one identically named trace event. “Common
post-state” means all fields in §1.4; event-specific fields are in §1.5.

| Spec action / event | Code location | Trigger point | Fields and notes |
|---|---|---|---|
| `SysReadBegin` | `kernel/core/src/syscall/read.rs:21-30`; `kernel/core/src/thread/task.rs:83-89` | After fd resolution and operation-ID allocation, before constructing/calling the user writer path. | Common post-state; begin args. The broad interval excludes fd lookup and buffer setup. |
| `SysWriteBegin` | `kernel/core/src/syscall/write.rs:21-30`; `kernel/core/src/thread/task.rs:83-89` | After fd resolution, before constructing/calling the user reader path. | Common post-state; begin args. |
| `SysPread64Begin` | `kernel/core/src/syscall/pread64.rs:22-36` | After negative/overflow checks and fd resolution, before `file.read_at`. Parser/arithmetic failures are out of scope and emit no event. | Common post-state; explicit-offset begin args. |
| `SysPwrite64Begin` | `kernel/core/src/syscall/pwrite64.rs:22-35` | After negative/overflow checks and fd resolution, before `file.write_at`. | Common post-state; explicit-offset begin args. |
| `DoSysReadvBegin` | `kernel/core/src/syscall/preadv.rs:134-156` | After `VmWriterArray` construction and the zero-count branch, immediately before the first vector iteration. | Common post-state; begin args. Iovec parsing emits no event. |
| `DoSysWritevBegin` | `kernel/core/src/syscall/pwritev.rs:134-152` | After `VmReaderArray` construction, immediately before the first vector iteration. | Common post-state; begin args. |
| `InodeHandleReadAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:278-287` | Start after `self.offset.lock()` returns, then bracket the owner-shadow and entry-start update. Do not include blocking lock wait in the timebox. | Common post-state. Fires once per scalar call, therefore once per `readv` iovec. |
| `InodeHandleWriteAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:301-317` | Start after `self.offset.lock()` returns, then bracket the owner/start update. Do not include blocking lock wait in the timebox. | Common post-state. O_APPEND behavior remains excluded. |
| `InodeHandleReadAtStart` | `kernel/core/src/fs/file/inode_handle.rs:323-332` | Immediately before `file_ops.read_at(offset, ...)`, after access checks. | Common post-state. Must not read or lock `InodeHandle::offset`. |
| `InodeHandleWriteAtStart` | `kernel/core/src/fs/file/inode_handle.rs:334-354` | Immediately before `file_ops.write_at(offset, ...)`, after access checks. | Common post-state. O_APPEND traces are not accepted by this campaign. |
| `Ext2VirtioFsReadComputeLimit` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242`; `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:65-80` | After logical EOF length is computed and the writer is limited, before page-cache read. | Common post-state. Select only for the `Correct` profile. |
| `RamFsExfatReadComputeLimit` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:648-657` | After logical `read_len` is computed, before the unrestricted `page_cache.read`. | Common post-state. `logical_avail` comes from EOF; `copy_limit` comes from cache capacity. |
| `RamFsWritePublishRequestedEnd` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750` | After metadata update and successful page-cache resize, immediately before `page_cache.write`. | Common post-state. Record whether the requested end expanded visible EOF. |
| `DeferredWritePrepare` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:252-262`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:720-736` | After successful capacity/allocation preparation, before the fallible page-cache copy. | Common post-state. Visible EOF remains the old size in the shadow. |
| `VmoRead` | `kernel/core/src/vm/page_cache/mod.rs:343-347`; `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566`; `ostd/src/mm/io/mod.rs:332-361` | Snapshot writer cursor at VMO entry. Emit once on function success or immediately when a fallible page copy returns error, before tuple conversion is propagated. | Common post-state; `progress`. Increment `effect_log_len` only for positive progress. Multiple internal pages still form one event. |
| `VmoWrite` | `kernel/core/src/vm/page_cache/mod.rs:349-355`; `kernel/core/src/vm/page_cache/vmo/mod.rs:569-640,667-750`; `ostd/src/mm/io/mod.rs:367-375` | Snapshot reader cursor at VMO entry. Emit once on success or at the first fallible-copy error before conversion/return. | Common post-state; `progress`. Count a dirty/copied positive prefix as committed even when the outer result will be an error. |
| `ErrorFromTuple` | `kernel/core/src/error.rs:209-219`; conversion sites `kernel/core/src/vm/page_cache/vmo/mod.rs:556-558,689-691,734-745` | Immediately after the matching `VmoRead`/`VmoWrite` error event and after converting the tuple to plain `Error`, before returning it. | Common post-state. Replacing `?` with an equivalent `match` is permitted solely to expose this boundary; preserve the returned errno and control flow. |
| `FileOpsReadReturn` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:709-718`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:654-657`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:239-242`; `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:74-80` | On successful VMO copy, after the adapter selects its returned logical length and before `Ok(read_len)`. | Common post-state. No event on the error path; `ErrorFromTuple` already moved the model to error handling. |
| `FileOpsWriteReturn` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:747-756`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:734-755`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-271`; `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:165-185` | After successful copy and visible size publication/commit, before `Ok(write_len)`. | Common post-state. Correct-adapter instrumentation must observe rollback before any error return instead. |
| `InodeHandleCommitOffset` | `kernel/core/src/fs/file/inode_handle.rs:285-290,308-320` | Tight interval around `*offset += len`, while the guard is held. | Common post-state. Increment `commit_log_len` only when `len > 0`; update `offset_advanced`. |
| `InodeHandlePropagateError` | `kernel/core/src/fs/file/inode_handle.rs:285-290,308-320` | Replace the inner `?` with an equivalent `match`; emit on `Err` before dropping the offset guard. | Common post-state. Do not advance shared offset or `commit_log_len`. |
| `InodeHandlePositionalReturn` | `kernel/core/src/fs/file/inode_handle.rs:323-354` | Wrap the tail `read_at`/`write_at` expression; emit after success/error is known and before returning it. | Common post-state. Assert the offset-owner shadow remains `none`. |
| `InodeHandleReleaseOffset` | `kernel/core/src/fs/file/inode_handle.rs:285-290,308-320` | On both success and error, clear the trace owner and emit immediately before `drop(offset)`. The held guard prevents a successor acquire from overtaking the release event. | Common post-state. The explicit drop preserves the original scope endpoint while making the per-iovec interleaving boundary observable. |
| `DoSysReadvHandleEntry` | `kernel/core/src/syscall/preadv.rs:156-174` | After the `match file.read(writer)` branch has updated/suppressed `total_len`, and after the continue/break decision, before the next entry or loop exit. | Common post-state. Increment `iov_index` only on a full successful entry. |
| `DoSysWritevHandleEntry` | `kernel/core/src/syscall/pwritev.rs:152-170` | After the corresponding write `match` and continue/break decision. | Common post-state. Preserve a later error in `entry_status` even when prior total progress will be returned. The RamFS fault-vector harness may gate scheduling after iovec 1 to expose the real unlocked boundary; the gate changes no modeled state. |
| `SysReadFinish` | `kernel/core/src/syscall/read.rs:35-44` | Wrap the mapping/return tail; emit after success length or `EINTR -> ERESTARTSYS`/other error is known, before leaving the syscall dispatcher. | Common post-state. Error paths currently hidden by `?` require an equivalent `match`. |
| `SysWriteFinish` | `kernel/core/src/syscall/write.rs:35-44` | Same boundary as scalar read, after result mapping. | Common post-state. |
| `SysPread64Finish` | `kernel/core/src/syscall/pread64.rs:33-43` | After `read_at` result is known and before returning `SyscallReturn` or the error. | Common post-state. There is no scalar EINTR-to-ERESTARTSYS mapping here. |
| `SysPwrite64Finish` | `kernel/core/src/syscall/pwrite64.rs:33-41` | After `write_at` result is known and before return. | Common post-state. |
| `SysReadvFinish` | `kernel/core/src/syscall/preadv.rs:165-180` | After loop exit and final `Ok(total_len)`/error selection, before `sys_readv` returns. | Common post-state. A later entry error with prior progress must emit `result = "Ok"`. |
| `SysWritevFinish` | `kernel/core/src/syscall/pwritev.rs:161-175` | After loop exit and final result selection. | Common post-state. |
| `HandlePendingSignal` | `kernel/core/src/process/signal/mod.rs:48-62,70-86,125-158`; call site `kernel/core/src/thread/task.rs:104-105` | Emit once after ERESTARTSYS conversion and the signal disposition/SA_RESTART decision. For a rewind, emit immediately after lines 155-157; otherwise emit before returning from this decision path. | Common post-state. The event does not claim a post-progress EINTR producer. |
| `RestartSyscall` | `kernel/core/src/process/signal/mod.rs:145-158`; re-entry `kernel/core/src/thread/task.rs:83-89` | When a TLS `restart_pending` marker observes the next re-entry of the rewound syscall, before dispatching it again. | Common post-state. Reuse `syscall_id`, increment `attempt_id`, reset entry/vector result state, and suppress a second `*Begin` event for this re-entry. |

## 3. Special considerations

### 3.1 One-to-one granularity and no silent actions

`Trace.tla` has a branch for every row above and no silent transition. Do not
merge acquire/commit/release, VMO-copy/error-conversion, vector entries, or
signal/restart into one event. Missing an intermediate event must fail trace
validation instead of being repaired with an unconstrained silent action.

### 3.2 Offset lock instrumentation

Calling `InodeHandle::offset()` while the current thread holds
`self.offset.lock()` would deadlock. Read the existing guard in held regions and
use the trace shadow after release. The shadow owner must be per open-file
description, because duplicated descriptors share the same `Arc<dyn FileLike>`
(`kernel/core/src/fs/file/file_table.rs:181-188,393-398`).

### 3.3 Buffer mutation and data privacy

Userspace may mutate/remap buffers between kernel steps. Capture only cursor
deltas and their symbolic class. Never hash or serialize bytes to approximate a
stable buffer generation; the model intentionally makes no such guarantee.

### 3.4 Adapter identity

Run separate harness scenarios for `Correct`, `RamFs`, and `Exfat`. A single
trace file contains one inode and one immutable adapter profile. RamFS covers
both unrestricted cached reads and prepublished writes; exFAT covers
unrestricted reads with deferred visible EOF.

### 3.5 Restart boundary

The target has no confirmed local regular-file source of post-progress
`EINTR`. Instrument observed `EINTR`/`ERESTARTSYS` transitions, but do not add a
test-only error return after progress. A trace with `RestartSyscall` is valid
only when the real implementation produced the rewind sequence.

### 3.6 Bootstrap and config

Start capture with both operation shadows idle and no offset owner. The
preprocessed `initial_state` must equal the constants selected in `Trace.cfg`;
per-run validation may generate a matching cfg or override only the JSON path.
`Thread` values must exactly match the string keys in `traces`.

### 3.7 Timebox quality

Use a simultaneous-start barrier in tests that share the open-file
description. Keep traces focused (roughly 50-300 events), verify cross-thread
interval overlap, and include:

- one complete-first/later-prefix-fault vector attempt;
- a vector/scalar shared-offset competitor;
- EOF reads for RamFS and exFAT;
- faulting RamFS writes at old EOF;
- positional and shared scalar operations running concurrently.

State capture and buffered emission occur after `end`; only the modeled source
transition lies inside the timebox.
