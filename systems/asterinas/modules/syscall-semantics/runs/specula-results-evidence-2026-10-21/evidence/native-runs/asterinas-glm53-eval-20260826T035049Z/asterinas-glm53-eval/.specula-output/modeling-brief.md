# Modeling Brief: Asterinas Regular-File Partial Progress

## 1. System Overview

- **System**: Asterinas regular-file `read`, `write`, `pread64`, `pwrite64`, `readv`, and `writev` at `604948581512d83734377974d4c34adb4530f2d7`.
- **Language and scale**: Rust; 5,619 lines in the primary file, syscall, VM-copy, page-cache, signal, and restart paths, plus filesystem adapters.
- **Category**: **Category B (Concurrent / Lock-Free)**. Operations on one shared open-file description combine a mutex-protected offset, per-thread attempt state, fallible user copies, and whole-syscall restart.
- **Reference contract**: Linux short-I/O behavior, one linearization point for a vectored regular-file transfer, unchanged shared offset for positional I/O, and no restart after visible progress.
- **Concurrency model**: duplicated descriptors clone the same `Arc<dyn FileLike>` and therefore share one `InodeHandle::offset`; cooperating threads can interleave between any unlocked actions.
- **Key deviations**: page-cache adapters can erase positive copy counts; RamFS/exFAT do not bound cached reads to logical EOF; RamFS publishes requested EOF before user copy; `readv`/`writev` reacquire the offset lock per iovec.
- **Restart result**: scalar `read`/`write` translate `EINTR` to `ERESTARTSYS`, but no current local regular-file path was found that returns `EINTR` after progress.

## 2. Scenarios

### Scenario 1: Positive Progress Is Collapsed Before Result and Offset Commit

**Mechanism**: A fallible copy advances temporary cursors and may change user memory or file data, but an outer `Result` retains only the error; result aggregation, offset accounting, and restart logic then observe zero progress.

**Evidence**:
- Historical: [#711](https://github.com/asterinas/asterinas/issues/711) remains open and is positive-control history only; [PR #1156](https://github.com/asterinas/asterinas/pull/1156) explicitly did not fix it.
- Ongoing work: [PR #3576](https://github.com/asterinas/asterinas/pull/3576) moves restart ownership below syscall wrappers, but has no regular-file post-progress regression and is absent from the target.
- Code analysis: `read_fallible` returns `(error, copied)` after advancing both cursors (`ostd/src/mm/io/mod.rs:332-361`), while tuple conversions discard `copied` (`kernel/core/src/error.rs:209-219`).
- Code analysis: VMO reads and anonymous writes propagate the tuple with `?`; backed writes can dirty a positive prefix before returning only `EFAULT` (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566,667-699,734-746`).
- Code analysis: `InodeHandle` advances the shared offset only after `Ok(len)` (`kernel/core/src/fs/file/inode_handle.rs:285-320`). A later faulting iovec is omitted when the vector loop returns prior progress (`kernel/core/src/syscall/preadv.rs:165-169`; `pwritev.rs:161-165`).
- Restart bookkeeping saves the original syscall return before dispatch and handles pending signals after dispatch (`kernel/core/src/thread/task.rs:83-105`).
- Restart boundary: `ERESTARTSYS` can rewind the whole syscall (`kernel/core/src/process/signal/mod.rs:54-60,145-158`), so restart is safe only when committed progress is zero.

**Affected code paths**: scalar and vector page-cache reads/writes, all four shared/positional wrappers, and signal restart.

**Suggested modeling approach**:
- Variables: `requested`, `copied`, `committed`, `reported`, `result`, `attemptId`, `restartPending`.
- Actions: split copy, page publication, error conversion, syscall finish, signal delivery, and restart.
- Granularity: use `Zero`, `Prefix`, and `Complete`; do not encode byte/page counts.
- Keep scalar #711 as a positive-control profile, not a hunt target. Guard the new vector hunt on one completed iovec followed by a positive-prefix fault.

**Priority**: High
**Rationale**: The mechanism is live, crosses every requested result/offset property, and composes with vector aggregation. A restart replay is not yet confirmed because no in-scope post-progress `EINTR` producer was found.

### Scenario 2: Filesystem Adapters Publish or Copy Outside Logical Progress

**Mechanism**: Filesystem adapters disagree on whether logical EOF and file-size effects are enforced before or after the fallible page-cache copy.

**Evidence**:
- RamFS and exFAT compute an EOF-limited result but pass the unrestricted writer to a page-aligned cache (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-710`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:648-657`).
- `PageCache` capacity is page-aligned and may exceed logical EOF (`kernel/core/src/vm/page_cache/mod.rs:181-184,264-271`); `Vmo::read` clips against that capacity, not filesystem EOF (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-557`).
- Ext2 returns at EOF and limits the writer; VirtioFS uses a limited clone and advances the original only after success (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-242`; `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:65-80`).
- RamFS publishes `offset + requested`, timestamps, and cache capacity before the user copy and has no rollback (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750`). Ext2 and VirtioFS roll extension state back; exFAT defers visible size (`ext2/inode/file.rs:193-218,246-271`; `virtiofs/inode/ops.rs:148-178`; `exfat/inode.rs:720-743`).

**Affected code paths**: RamFS/tmpfs/memfd and exFAT cached reads; RamFS cached writes; overlay files backed by those inodes.

**Suggested modeling approach**:
- Variables: `logicalAvail`, `cacheCapacity`, `fileSize`, `adapterProfile`.
- Actions: `ComputeLogicalLimit`, optional `PublishRequestedEnd`, `Copy`, `PublishResult`, and `RollbackExtent`.
- Granularity: distinguish old EOF, committed-prefix EOF, and full-request EOF.

**Priority**: High
**Rationale**: Two new deterministic Linux-visible defects are source-confirmed: a zero-byte read may alter/fault the buffer, and a zero-progress RamFS write may extend the file to the full requested end.

### Scenario 3: Vectored I/O Releases Serialization Between Entries

**Mechanism**: One API-level vector operation is implemented as independently serialized scalar operations, exposing a split-operation window.

**Evidence**:
- Historical: [#1223](https://github.com/asterinas/asterinas/issues/1223) left correct `readv`/`writev` behavior unfinished; [PR #3086 review](https://github.com/asterinas/asterinas/pull/3086#discussion_r3031308667) agreed that aggregate methods are needed.
- Code analysis: `readv` and `writev` call `file.read`/`file.write` once per iovec (`kernel/core/src/syscall/preadv.rs:152-174`; `kernel/core/src/syscall/pwritev.rs:148-170`).
- Code analysis: each scalar call separately locks and unlocks the shared offset (`kernel/core/src/fs/file/inode_handle.rs:285-320`).

**Affected code paths**: non-positional `readv` and `writev` on duplicated descriptors.

**Suggested modeling approach**:
- Variables: `iovIndex`, `offsetOwner`, `commitLog`, per-operation observed segments.
- Actions: acquire, transfer one iovec, update offset, and release; permit a competing scalar/vector operation between entries.
- Granularity: two iovecs and two threads suffice. Tag symbolic chunks by operation and iovec.

**Priority**: High
**Rationale**: `readv([1,1])` interleaved with `read(1)` can return `A,C` while the competitor returns `B`; neither serial order explains it.

### Scenario 4: Positional Offset Isolation

**Mechanism**: Shared-offset and positional operations intentionally use different offset ownership paths and must remain consistent under concurrency and faults.

**Evidence**:
- Duplicated/forked entries retain the same file-object `Arc` (`kernel/core/src/fs/file/file_table.rs:117-121,181-188,393-398`).
- Shared scalar operations hold `InodeHandle::offset`; positional `read_at`/`write_at` do not access it (`kernel/core/src/fs/file/inode_handle.rs:285-354`).
- `pread64`/`pwrite64` pass only their explicit offset (`kernel/core/src/syscall/pread64.rs:33-37`; `kernel/core/src/syscall/pwrite64.rs:33-35`).

**Affected code paths**: all six requested syscalls on one open-file description.

**Suggested modeling approach**:
- Variables: `sharedOffset`, `explicitOffset[op]`, `usesSharedOffset[op]`.
- Actions: select the start offset at operation begin; only shared operations may write `sharedOffset`.
- Granularity: positional data effects may interleave, but they never own the offset mutex.

**Priority**: Medium
**Rationale**: The target code appears correct. Modeling this required interaction prevents vector/fault extensions from accidentally attributing positional progress to the shared offset.

## 3. Modeling Recommendations

Use one state machine for all four scenarios. Select operation and adapter
profiles rather than creating independent specs.

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Progress classes and separate copy/commit/report state | Scenarios 1-2 | `Zero/Prefix/Complete` variables and split actions |
| User-buffer remap/fault environment | Scenarios 1-2 | Choose a fresh copy outcome at each kernel copy step; do not assume a stable buffer generation |
| Adapter profiles | Scenario 2 | Correct, unbounded-read, and prepublished-write profiles |
| One shared open description | Scenarios 1, 3-4 | Shared `fileData`, `fileSize`, and `sharedOffset` |
| Per-iovec program counters | Scenarios 1 and 3 | Two-entry vectors with an unlocked boundary |
| Positional operations | Scenario 4 | Explicit local offset; no shared-offset write |
| Signal/restart gate | Scenario 1 | Deliver after syscall result; restart only from `ERESTARTSYS` with zero commit |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Sockets, pipes, PTYs, `sendfile`, control messages, SCM_RIGHTS, accept | Explicitly separate campaigns |
| `preadv`/`pwritev`, `*v2`, and RWF flags | Explicitly excluded offset-flag variants |
| Exact byte, page, batch, or chunk counts | Only zero/prefix/complete classes are contractual |
| Same-generation userspace buffer snapshot | The caller may mutate or remap between kernel steps; only each copy outcome is observed |
| Iovec parser bounds/arithmetic, including open PR #3720 | Separate parser/ABI tests; no additional state machine |
| O_APPEND range atomicity and memfd seals | Explicitly excluded; PR #3481 is reference only |
| Page-lock/page-fault deadlock #3257, TLB, eviction, and broad OOM | Separate VM/liveness protocols |
| An adversarial `EINTR` after commit without a concrete regular-file producer | It would manufacture the restart counterexample rather than model target behavior |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Progress lattice | `requested`, `copied`, `committed`, `reported` | Preserve distinct attempt stages | 1-2 |
| Adapter ordering | `adapterProfile`, `logicalAvail`, `cacheCapacity`, `fileSize` | Capture missing EOF limit and early EOF publication | 2 |
| Shared-offset ownership | `sharedOffset`, `offsetOwner` | Represent the `InodeHandle` mutex | 1, 3-4 |
| Vector execution | `iovIndex`, `commitLog` | Expose the per-entry unlock window | 1, 3 |
| Positional execution | `explicitOffset`, `usesSharedOffset` | Keep positional effects offset-neutral | 4 |
| Restart attempts | `attemptId`, `restartPending`, `signalPending` | Detect replay across whole-syscall rewind | 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `ReadReturnCoversCopies` | Safety | A finished read reports every logically transferred byte; zero/error does not alter the logical destination range | 1-2 |
| `WriteReturnCoversCommit` | Safety | Visible file-data progress is a reported positive prefix | 1-2 |
| `NoReadPastEOF` | Safety | User memory beyond logical available data is unchanged | 2 |
| `NoNominalEOFOnFault` | Safety | Zero-copy fault leaves EOF unchanged; prefix completion cannot publish full requested EOF | 2 |
| `SharedOffsetTracksReport` | Safety | A shared operation's offset delta equals its reported transfer | 1, 3 |
| `VectorSingleLinearization` | Safety | One vector operation's tagged effects are contiguous relative to competing shared-offset I/O | 3 |
| `PositionalOffsetIsolation` | Safety | Positional actions never change `sharedOffset` | 4 |
| `RestartNoReplay` | Safety | Restart is enabled only with zero committed progress, and no effect is committed twice across attempts | 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | After one iovec completes, can a later positive-prefix fault be omitted from both the vector result and shared-offset delta? | `ReadReturnCoversCopies` or `WriteReturnCoversCommit`; `SharedOffsetTracksReport` | 1 |
| MC-2 | Can a competing shared-offset operation commit between two iovecs so no serial order explains the observed buffers/data? | `VectorSingleLinearization` | 3 |

Direct scalar reproduction of #711 is intentionally not an MC finding.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | RamFS/exFAT read at non-page-aligned EOF can alter the buffer or return `EFAULT` instead of zero | Create a short file; use sentinel and `PROT_NONE` destinations at EOF with `read` and `pread64` |
| TV-2 | A zero/positive-prefix faulting RamFS write can leave full requested EOF while result is `EFAULT` and shared offset is unchanged | Cross into an unmapped source page; compare return, `fstat`, `lseek`, and file contents |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `PageCache`/filesystem APIs have no owner for an error plus partial count | Define one progress-preserving file-I/O contract before repairing adapters |
| CR-2 | Scalar and vector/positional EINTR translation differs, but no local regular-file EINTR source exists | Audit future/remote regular-file implementations before enabling restart fault injection |

## 7. Reference Pointers

- **Full analysis report**: `.specula-output/analysis-report.md`
- **Key target files**: `inode_handle.rs:272-354`; `preadv.rs:134-180`; `pwritev.rs:134-175`; `vmo/mod.rs:528-760`; `error.rs:195-220`; `signal/mod.rs:48-62,145-158`
- **New adapter evidence**: `ramfs/fs.rs:694-757`; `exfat/inode.rs:642-657`; comparator paths in `ext2/inode/file.rs:228-271` and `virtiofs/inode/ops.rs:65-80,148-178`
- **Historical issues**: [#711](https://github.com/asterinas/asterinas/issues/711), [#1136](https://github.com/asterinas/asterinas/issues/1136), [#1223](https://github.com/asterinas/asterinas/issues/1223), [#1578](https://github.com/asterinas/asterinas/issues/1578)
- **Reference-only history**: [#1554](https://github.com/asterinas/asterinas/issues/1554), [#3181](https://github.com/asterinas/asterinas/issues/3181)
- **Linux contract**: [read(2)](https://man7.org/linux/man-pages/man2/read.2.html), [write(2)](https://man7.org/linux/man-pages/man2/write.2.html), [readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html), [pread(2)](https://man7.org/linux/man-pages/man2/pread.2.html), [signal(7)](https://man7.org/linux/man-pages/man7/signal.7.html), and [Linux v6.16 `fs/read_write.c`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c)
