# Asterinas regular-file I/O trace harness

The patch instruments commit `604948581512d83734377974d4c34adb4530f2d7`.
`apply.sh` accepts only that baseline or the already-instrumented tree.
Tracing is enabled only for open descriptions whose basename starts with
`.specula_correct_`, `.specula_ramfs_`, or `.specula_exfat_`.

## Capture design

- Category B timeboxes use fenced x86-64 TSC reads at
  `kernel/core/src/tla_trace.rs:494`.
- Each POSIX thread owns a preallocated 128-event buffer at
  `kernel/core/src/tla_trace.rs:323-369`. The hot path has no global sequence,
  mutex, file write, or console write.
- Every event captures the full 33-field state at
  `kernel/core/src/tla_trace.rs:301-320,344-369`.
- Offset-acquire timeboxes start after the mutex call returns, so lock wait
  cannot overlap operations that completed before ownership changed.
- Offset-release events clear the trace owner while the real guard is still
  held, then drop the guard; a successor acquire cannot overtake the event.
- The `.specula_ramfs_fault_vector` trace gate holds its scalar before acquire.
  After iovec 1 dispatch, the vector opens the gate and waits for the scalar to
  own the offset, deterministically exercising the real unlocked boundary.
- A symbolic unit is half a page. Zero, positive-prefix, and complete copies
  map to 0, 1, and 2 units at `kernel/core/src/tla_trace.rs:26-98`.
- Buffers are printed as `SPECULA_CONFIG` and `SPECULA_TRACE` records at
  `kernel/core/src/tla_trace.rs:378-395`. The POSIX exit hook flushes before
  `clear_child_tid` can wake `pthread_join` at
  `kernel/core/src/process/posix_thread/exit.rs:65`.
- `preprocess_trace.py:59-227` validates raw records, remaps kernel TIDs to
  `t1`/`t2`, rank-compresses real timestamps, and extracts a global-time
  offset-contention prefix. It never creates or edits an event.

## Event locations after apply

| Trace event | Real-code capture point |
|---|---|
| `SysReadBegin`, `SysReadFinish` | `kernel/core/src/syscall/read.rs:23,41` |
| `SysWriteBegin`, `SysWriteFinish` | `kernel/core/src/syscall/write.rs:23,41` |
| `SysPread64Begin`, `SysPread64Finish` | `kernel/core/src/syscall/pread64.rs:33,39` |
| `SysPwrite64Begin`, `SysPwrite64Finish` | `kernel/core/src/syscall/pwrite64.rs:33,39` |
| `DoSysReadvBegin`, `DoSysReadvHandleEntry`, `SysReadvFinish` | `kernel/core/src/syscall/preadv.rs:156,179-180,191` |
| `DoSysWritevBegin`, `DoSysWritevHandleEntry`, `SysWritevFinish` | `kernel/core/src/syscall/pwritev.rs:152,175-176,187` |
| `InodeHandleReadAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:292-296` |
| `InodeHandleWriteAcquireOffset` | `kernel/core/src/fs/file/inode_handle.rs:343-347` |
| `InodeHandleReadAtStart`, `InodeHandlePositionalReturn` | `kernel/core/src/fs/file/inode_handle.rs:401,404-406` |
| `InodeHandleWriteAtStart`, `InodeHandlePositionalReturn` | `kernel/core/src/fs/file/inode_handle.rs:435,438-440` |
| `InodeHandleCommitOffset` | `kernel/core/src/fs/file/inode_handle.rs:304-307,365-368` |
| `InodeHandlePropagateError` | `kernel/core/src/fs/file/inode_handle.rs:317-319,378-380` |
| `InodeHandleReleaseOffset` | `kernel/core/src/fs/file/inode_handle.rs:309-312,321-324,370-373,382-385` |
| `Ext2VirtioFsReadComputeLimit` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-238`; `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:65-74` |
| `RamFsExfatReadComputeLimit` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-711`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:648-655` |
| `RamFsWritePublishRequestedEnd` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:764-765` |
| `DeferredWritePrepare` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:271-272`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:750-751` |
| `VmoRead` | `kernel/core/src/vm/page_cache/vmo/mod.rs:535-574` |
| `VmoWrite` | `kernel/core/src/vm/page_cache/vmo/mod.rs:580-664,702-718,745-778` |
| `ErrorFromTuple` | `kernel/core/src/vm/page_cache/vmo/mod.rs:561-563,718-720,779-781` |
| `FileOpsReadReturn` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:717-718`; `exfat/inode.rs:662-663`; `ext2/inode/file.rs:244-245`; `virtiofs/inode/ops.rs:78-79` under `kernel/core/src/fs/fs_impls/` |
| `FileOpsWriteReturn` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:777-778`; `exfat/inode.rs:771-772`; `ext2/inode/file.rs:282-283` under `kernel/core/src/fs/fs_impls/` |
| `HandlePendingSignal` | `kernel/core/src/process/signal/mod.rs:54` |
| `RestartSyscall` | `kernel/core/src/syscall/mod.rs:382-390`; state transition helper at `kernel/core/src/tla_trace.rs:572-615` |

The adapter helpers and all event-name selections are in
`kernel/core/src/tla_trace.rs:548-1079`.

## Scenario locations

- Atomic two-thread rendezvous: `harness/src/specula_trace.c:58`.
- RamFS vector fault plus scalar competitor: `harness/src/specula_trace.c:168`.
- RamFS EOF shared/positional reads: `harness/src/specula_trace.c:218`.
- ext2 correct vector/positional pair: `harness/src/specula_trace.c:265`.
- exFAT EOF vector read plus positional prefix-fault write:
  `harness/src/specula_trace.c:319`.

## Small adjustments

To add a state field:

1. Add it to `OpState` or `TraceFileState`, then to `StateSnapshot` and
   `ThreadTrace::append` in `kernel/core/src/tla_trace.rs`.
2. Add its JSON rendering in `EventDisplay` at
   `kernel/core/src/tla_trace.rs:400-478`.
3. Add the exact key to `REQUIRED_STATE_FIELDS` in
   `harness/src/preprocess_trace.py:14-49`.
4. Add the corresponding `ValidatePostState` check in `spec/Trace.tla`.

To add an event, copy an existing helper in
`kernel/core/src/tla_trace.rs:548-1079`. Take `start` immediately before the
real transition, take `end` immediately after it, mutate the shadow before
`end`, and append only after `end`. Add the event to `MatchEvent` and to
`EXPECTED_EVENTS` in `harness/src/check_traces.py:14-46`.

To move a capture point, move the source hook around the real operation. Do
not move state formatting or output inside `[start,end]`; those remain after
`end`. Preserve the one-to-one action sequence. In particular, do not merge
offset acquire/commit/release, VMO copy/tuple conversion, or vector-entry
dispatch events.

## Rebuild and validate

From `.specula-output`:

```sh
bash harness/apply.sh
bash harness/run.sh
```

`run.sh` has 20-minute per-boot and 30-minute outer timeouts. It uses only
`/dev/kvm`, disables host forwarding, runs all four scenarios, writes raw
per-thread records under `traces/raw/`, writes TLC inputs under `traces/`, and
runs schema, coverage, L2, drop, ordering, overlap-metric, and exact
vector/scalar interleaving checks.

Current coverage is 32 of 33 event types with 8.3% best cross-thread overlap.
Both the full RamFS fault trace and its contention prefix contain the exact
vector-iovec-1, scalar-commit, vector-iovec-2 order. `RestartSyscall` is the
only uncovered event: this target has no confirmed regular-file post-progress
`EINTR` producer, and the harness does not inject one.

Final quick TLC results:

- `specula-correct_vector_positional.ndjson`: passed, 29 states generated.
- `specula-ramfs_fault_vector.ndjson`: passed, 30 states generated.
- `specula-ramfs_fault_vector-contention-prefix.ndjson`: passed, 22 states
  generated.
- `specula-ramfs_eof_positional.ndjson`: passed, 25 states generated.
- `specula-exfat_fault_vector.ndjson`: passed, 29 states generated.

Trace validation checks structure, action matching, and all 33 post-state
fields. Linux-contract bug oracles run only in `MC_hunt_*.cfg`, where observed
implementation behavior can be reported as a Case C counterexample instead of
making a faithful trace fail replay.
