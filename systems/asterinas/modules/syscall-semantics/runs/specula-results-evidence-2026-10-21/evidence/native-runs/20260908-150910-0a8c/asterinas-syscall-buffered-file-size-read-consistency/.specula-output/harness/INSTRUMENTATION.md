# Buffered-file trace harness

Source revision: `604948581512d83734377974d4c34adb4530f2d7`.
The exported source baseline is `d0809945830273c4a7be6c93fc6d862e5b798e29` in `../../baseline.git` (relative to this guide).

## Run and current result

From `.specula-output/`:

```sh
bash harness/run.sh
```

- 111 guest traces, 1227 events, 40/42 event types exercised.
- 94 cross-thread interval overlaps; the best short trace has 25% overlapping pairs.
- Supplied spec: 109/111 traces match, including complete witnesses where universal temporal checking encounters a dead-end ordering.
- Separate proposed spec: 111/111 traces match.
- Sidecar: 159 generated cases, 477 executions across three backends, zero truncated, unexecuted, unsupported, or harness-error cases. All executions pass the stated count/offset oracle. This does not certify the filesystem contract or its error rollback behavior.
- `run.sh` returns 1 because the supplied spec rejects `ramfs-2-2` and `ramfs-3-3`. It preserves those traces. See [validation.json](validation.json), [validation-proposed.json](validation-proposed.json), and [run-status.json](run-status.json).

The runner uses rootful Docker, `asterinas/dev:0.18.1-20260901`, and only `/dev/kvm` from the host. It builds the real kernel with OSDK, then boots its direct ELF image with two CPUs and `earlycon`. Root mounts the two disposable filesystem images; the regression program runs as UID/GID 1000. Both workers request separate CPU affinities. A user-space TSC rendezvous starts contenders; no kernel delay or extra trace lock is inserted. Builds and guest runs have outer timeouts. A guest timeout stops the run and requires diagnosis; it is not retried.

`SPECULA_IMAGE`, `SPECULA_DOCKER_SOCKET`, `SPECULA_ROOT`, and `SPECULA_JAVA` override local dependencies. `SPECULA_CONTAINER` reuses an explicitly named development container. The ordinary runner removes its own container on exit. The MCP validation tool could not locate `java`; the CLI validator uses the discovered JRE directly and the same Specula TLC jars.

## Native receipts and trace fields

[tla_trace.rs](src/tla_trace.rs) adds a preallocated 2048-record buffer to each POSIX thread's local data. `prctl(0x53504543, tid, 2048, accessible_prefix, 0)` arms it; `0x53504544` drains it after both workers leave their attempts. Overflow returns EOVERFLOW. The hot path uses no global ID registry, sequence counter, file writer, or shared tracing mutex. No unsafe Rust was added.

- `stamp()` uses safe OSTD `read_tsc()` with fences. Each semantic hook brackets the real operation; serialization follows the interval. Guard-release intervals start at the preceding receipt's end and include the lexical guard drop.
- The subject VMO address is retained per thread. `Scope` suppresses unrelated exFAT metadata-cache I/O and restores the enclosing capture state.
- `copied()` samples exported VmReader/VmWriter cursor addresses before and after the real fallible copy. It never measures progress from `avail()`, which ext2 limits independently of copying.
- Read receipts independently inspect the successfully copied destination prefix. Write/zero receipts inspect initialized frame bytes or only the just-written fragment of an Uninit frame. Raw uninitialized frame bytes are not dumped.
- Cache resize records the selected native zero interval. Ext2 allocation records the native block mask under its existing tree guard and a zero-copy cursor receipt after the corresponding disk write completes.
- [collect.py](src/collect.py) converts exact byte units and byte tags, retains native scalar/cursor/return receipts, and derives control markers and held-guard flags from executed hooks. It implements no file contents or filesystem transition simulator. Nonrepresentable counts and nonuniform tags fail conversion.
- All eight state projections and every LocalObserved field are emitted and checked by the supplied `ValidatePostState`; no weak validator or silent repair is used. Ghost reference histories remain spec observers.

Each scenario has raw native receipts and per-thread, schema-complete NDJSON under `traces/raw/<scenario>/`. The supplied preprocessor compresses timestamps without sorting threads into a total order. The top-level scenario `.ndjson` is its one-record input to Trace.tla. Earlier batches remain under `harness/history/`; the latest `coverage.json` names its source log. Validation records bind each exact trace SHA256. Serial logs also retain syscall-side observations.

## Scenarios and generated cases

[scenarios.c](src/scenarios.c) uses Asterinas's `test/initramfs/src/regression/common/test.h`. The five data scenarios run separately on ramfs, ext2, and exFAT:

1. Shrink, shared-offset read, extension, hole/EOF positional read, and empty I/O.
2. Read versus shrink to zero.
3. Read versus an extending buffered write.
4. A partial source-copy fault during extension.
5. Two extending writers with different payloads and disjoint ranges.

Another 96 short ext2 same-size resize trials exercise lock contention and timebox ordering. Each trace starts from one fsynced 4096-byte seeded file with page 0 warm. Physical pages and exFAT clusters are 4096 bytes; one model cell is 2048 bytes. See [fixtures.json](fixtures.json).

The fault trace consumes generated case `uc-8995c3f50ef7ec12` and its `buffer` object. The complete byte-granular adapter consumes all 159 immutable cases, retaining their object IDs and empty alias-edge sets. It implements valid, null, unmapped, PROT_NONE, read-only, and guard-page mappings. Permissions remain fixed during each syscall; inaccessible mappings are restored only afterward for safe sentinel inspection.

The installed CLI lacked `syscall-inputs`. [tools/generator-identity.json](tools/generator-identity.json) pins the unmodified upstream utility recovered from local Git history. The harness-local `specula syscall-inputs` wrapper invokes that utility. Contract, cases, evidence, and referenced raw observations validate against that exact generator.

Sidecar `attempted` is the syscall request length; `copied` comes from destination sentinel inspection; `committed` comes from file readback; `reported` and offset changes come from the actual return and lseek. Unobservable progress is null. Delivered-prefix and outside-request sentinel observations are retained. Error cases do not assume all-or-nothing rollback. These results stay separate from `spec/findings.json`.

## Model mismatch and remaining coverage

The ramfs unaligned writes start at byte 2048 with length 8192. The real write path allocates a vector with capacity `ceil(8192 / 4096) = 2`, then collects pages 0 and 1 before copying. Three page indices span that unaligned range. The supplied `VmoCollectBegin` instead requires all three pages before any copy. A fault in the second copied page makes this ordering difference observable.

[proposed-base-batch-capacity.patch](patches/proposed-base-batch-capacity.patch) bounds each collection by the vector capacity actually selected by the source. It changes no post-state checks or outcome invariants. The supplied spec files remain byte-for-byte unchanged, verified by [spec-input-hashes.json](spec-input-hashes.json). To review the correction independently:

```sh
SPECULA_TRACE_SPEC="$PWD/harness/proposed-spec" python3 harness/src/validate_traces.py
```

`Trace_witness.cfg` is used only after a temporal replay failure. A witness counts as a match only when TLC reports TraceNotComplete violated and every final cursor equals that thread's event count plus one. Parse errors, structural-invariant failures, timeouts, and partial prefixes never count as matching witnesses.

Two instrumented event types remain unexercised:

- `VmoRangeError`: no inconsistent cache/backend bound occurred in the selected schedules. The harness observes real failing checks; it does not inject EINVAL. Another reachable publication history is needed to cover this path.
- `ExfatBackendReadBlocked`: the warm initial tail avoids the recursive R-under-W wait. Its hook records a failed native try_read before the original blocking read. A cold-tail fixture needs an external watchdog and ring/stack extraction because the blocked thread cannot drain its own buffer. No completion claim is made for this path.

Physical cluster-reuse identity (TV3), an Uninit page reused after an in-EOF partial fault, and cold-tail blocked-stack evidence are not covered. Their follow-ups need fixture receipts and, for reused Uninit cells, cross-attempt validity tracking before inspection. These limits are not passes or confirmed findings.

## Adjusting instrumentation

- Edit the native module in `src/tla_trace.rs` and hooks in `src/patch_source.py`, `src/patch_vmo.py`, or `src/patch_backends.py`. `apply.sh` rebuilds edits from exact baseline bytes and refuses unowned source changes.
- Add a native receipt field to `Receipt` or an unused documented value slot; decode it in `collect.py`. A new trace state field also needs its corresponding Trace.tla/base validation. Never replace a saved backend count with copied progress.
- Add an event at its real source transition, using an existing `event`, `page`, or `copied` hook as the pattern. Add its serializer branch and verify its coverage. Event names must match Trace.tla.
- To move a capture point, move the start stamp and native observation together. Keep the observation under its existing protecting guard and keep the actual drop inside release intervals. Do not reread shared state after releasing that guard.
- Re-run `bash harness/run.sh`. `clean.sh` restores only owned patched files after verifying their hashes. [instrumentation.patch](patches/instrumentation.patch) and [manifest.json](patches/manifest.json) make the applied result reviewable.

## Instrumentation points after apply

Paths below are relative to `source/`. The unchanged cursor advancement is at `ostd/src/mm/io/mod.rs:354-355`; its exported cursor values are sampled in the listed VMO copy hooks.

| Event | Native hook locations |
|---|---|
| `BackendReturn` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:729`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:780`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:858`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:674`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:787`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:1505`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:30`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:39`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:70`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:160` |
| `ExfatBackendReadBlocked` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:154` |
| `ExfatReadAt` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:666` |
| `ExfatResize` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:1483` |
| `ExfatResizeAllocation` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:321` |
| `ExfatResizeUpgrade` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:1489` |
| `ExfatWriteAtAcquireCopy` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:760` |
| `ExfatWriteAtPrepare` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:744` |
| `ExfatWriteAtPublish` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:771` |
| `ExfatWriteAtReleasePreparation` | `kernel/core/src/fs/fs_impls/exfat/inode.rs:756` |
| `Ext2AllocateRangeBlocks` | `kernel/core/src/fs/fs_impls/ext2/inode/block_manager/mod.rs:137` |
| `Ext2ReadAt` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:269`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:276` |
| `Ext2ReadAtEmpty` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:28` |
| `Ext2ReadAtUpdateAtime` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:44` |
| `Ext2Resize` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:144` |
| `Ext2ResizePageCacheBound` | `kernel/core/src/fs/fs_impls/ext2/inode/mod.rs:482` |
| `Ext2ResizePublish` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:154` |
| `Ext2RollbackBlocks` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:249` |
| `Ext2RollbackWrite` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:236` |
| `Ext2WriteAtEmpty` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:58` |
| `Ext2WriteAtPrepare` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:293` |
| `Ext2WriteAtPublish` | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:311` |
| `InodeHandleReturn` | `kernel/core/src/fs/file/inode_handle.rs:293`; `kernel/core/src/fs/file/inode_handle.rs:339`; `kernel/core/src/fs/file/inode_handle.rs:366`; `kernel/core/src/syscall/truncate.rs:30` |
| `PageCacheFillZeros` | `kernel/core/src/vm/page_cache/vmo/mod.rs:670` |
| `PageCacheResizeBegin` | `kernel/core/src/vm/page_cache/mod.rs:254`; `kernel/core/src/vm/page_cache/mod.rs:258`; `kernel/core/src/vm/page_cache/mod.rs:262` |
| `PageCacheResizeCapacity` | `kernel/core/src/vm/page_cache/mod.rs:277`; `kernel/core/src/vm/page_cache/mod.rs:291` |
| `RamfsReadAtAcquireCache` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:715` |
| `RamfsReadAtObserve` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:711` |
| `RamfsResize` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:830`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:841`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:846` |
| `RamfsResizeAcquireCache` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:825` |
| `RamfsResizePublish` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:851` |
| `RamfsWriteAtAcquireCache` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:747` |
| `RamfsWriteAtPublish` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:763` |
| `SyscallEnter` | `kernel/core/src/fs/file/inode_handle.rs:287`; `kernel/core/src/fs/file/inode_handle.rs:336`; `kernel/core/src/fs/file/inode_handle.rs:363`; `kernel/core/src/syscall/truncate.rs:27` |
| `VmoBackendRead` | `kernel/core/src/vm/page_cache/vmo/mod.rs:866`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1077`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1097` |
| `VmoCollectBegin` | `kernel/core/src/vm/page_cache/vmo/mod.rs:813` |
| `VmoCollectedPage` | `kernel/core/src/vm/page_cache/vmo/mod.rs:824`; `kernel/core/src/vm/page_cache/vmo/mod.rs:833` |
| `VmoCommitPage` | `kernel/core/src/vm/page_cache/vmo/mod.rs:318`; `kernel/core/src/vm/page_cache/vmo/mod.rs:324`; `kernel/core/src/vm/page_cache/vmo/mod.rs:382`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1070`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1087`; `kernel/core/src/vm/page_cache/vmo/mod.rs:1115` |
| `VmoCopyPage` | `kernel/core/src/vm/page_cache/vmo/mod.rs:568`; `kernel/core/src/vm/page_cache/vmo/mod.rs:713`; `kernel/core/src/vm/page_cache/vmo/mod.rs:772`; `kernel/core/src/vm/page_cache/vmo/mod.rs:781` |
| `VmoIoBegin` | `kernel/core/src/vm/page_cache/vmo/mod.rs:543`; `kernel/core/src/vm/page_cache/vmo/mod.rs:587` |
| `VmoRangeError` | `kernel/core/src/vm/page_cache/vmo/mod.rs:667`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:159`; `kernel/core/src/fs/fs_impls/ext2/inode/block_manager/mod.rs:158` |
| `WriteAtCopyStart` | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:769`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:761`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:300` |
