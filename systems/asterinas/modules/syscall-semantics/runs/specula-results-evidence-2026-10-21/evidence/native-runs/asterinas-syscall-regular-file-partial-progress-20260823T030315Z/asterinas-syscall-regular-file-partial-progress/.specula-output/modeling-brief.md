# Modeling Brief: Regular-file partial progress and shared offsets

Source pin: [`asterinas/asterinas@604948581512d83734377974d4c34adb4530f2d7`](https://github.com/asterinas/asterinas/commit/604948581512d83734377974d4c34adb4530f2d7)

## 1. System Overview

Asterinas is a Rust kernel; the required syscall, file, copy, page-cache, and signal slice is 6,579 lines.
This is **Category B (Concurrent / shared-state)** because cooperating threads mutate one open-file-description offset and file state through nested critical sections.
The reference state machine is Linux regular-file I/O: requested, copied, committed, and reported progress must agree with shared-offset, positional-offset, vector-atomicity, and restart rules.
Duplicated and inherited descriptors clone one `Arc<dyn FileLike>`, so they reach the same `InodeHandle::offset` mutex (`kernel/core/src/fs/file/file_table.rs:117-121,181-187,393-399`).
Scalar `read`/`write` hold that mutex across one backend call, while `pread64`/`pwrite64` bypass it (`kernel/core/src/fs/file/inode_handle.rs:273-353`).
`readv`/`writev` are loops of scalar calls, releasing serialization between iovecs (`kernel/core/src/syscall/preadv.rs:134-180`; `kernel/core/src/syscall/pwritev.rs:134-175`).
Fallible copy preserves a prefix count in OSTD, but kernel adapters erase it before the syscall result and offset decision (`ostd/src/mm/io/mod.rs:271-292,332-385`; `kernel/core/src/error.rs:209-219`).

## 2. Scenarios

### Scenario 1: Positive copy progress is erased at the VMO boundary

**Mechanism**: A fallible transfer advances its cursors and returns `(error, copied)`, but tuple conversion and `?` retain only the error.
**Evidence**:

- Historical: [#711](https://github.com/asterinas/asterinas/issues/711) is the open positive control; [PR #1156](https://github.com/asterinas/asterinas/pull/1156) explicitly preserved the unresolved short-I/O problem.
- Code analysis: `read_fallible` returns the prefix (`ostd/src/mm/io/mod.rs:332-362`); conversions drop it (`kernel/core/src/error.rs:209-219`); VMO read/write propagate a scalar error after copying (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566,667-759`).
- Code analysis: `InodeHandle` advances the shared offset only on `Ok(len)` (`kernel/core/src/fs/file/inode_handle.rs:285-290,308-320`).
**Affected code paths**: `read`, `write`, `pread64`, `pwrite64`, each `readv`/`writev` entry, ext2 buffered I/O, and ramfs I/O.
**Suggested modeling approach**:

- Variables: `requested`, `copied`, `committed`, `reported` in `{Zero, Positive, Complete}`, `result`, `ofdOffset`, `pageState`.
- Actions: split `CopyPrefix`, `CommitOrDiscardPrefix`, and `ReturnFaultOrShortSuccess`.
- Granularity: keep scalar locking intact, but do not collapse copy, backend publication, result, and offset publication into one action.
**Priority**: High. **Rationale**: The count is observably lost on current read and warm-page write paths, and it composes with every other scenario.

### Scenario 2: Backend publication escapes the syscall outcome

**Mechanism**: Backend-specific state is published before the attempt has a result, and rollback does not uniformly undo positive or even zero-copy effects.
**Evidence**:

- Historical: [PR #3256](https://github.com/asterinas/asterinas/pull/3256) fixed only the cold full-overwrite page case; [#651](https://github.com/asterinas/asterinas/issues/651) and [#2835](https://github.com/asterinas/asterinas/issues/2835) show direct-I/O ordering sensitivity.
- Code analysis: an up-to-date ext2 page becomes dirty after a positive fault, while an `Uninit` overwrite page stays unpublished (`kernel/core/src/vm/page_cache/vmo/mod.rs:724-751,1019-1052`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-218,245-271`).
- Code analysis: ramfs publishes an extending request's full end and timestamps before copy, with no rollback; in-place requests retain the old larger size (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:721-756`).
- Code analysis: fragmented ext2 `O_DIRECT` submits each completed range before copying the next; a later fault skips `wait_all` (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:365-406`; `kernel/core/comps/block/src/bio.rs:100-150`).
**Affected code paths**: ext2 buffered/direct write, ramfs write, page-cache backed/anonymous VMO writes.
**Suggested modeling approach**:

- Variables: `backendMode`, `rangeClass`, `fileSize`, `pageState`, `dirtyPrefix`, `pendingBio`, `effectEpoch`.
- Actions: choose `RetainPrefix`/`DiscardPrefix`; separate `DirectSubmit` from `DirectComplete`; publish ramfs size before `CopyPrefix` exactly as implemented.
- Granularity: abstract exact pages and blocks, but retain zero/positive/complete classes and an outstanding-effect bit.
**Priority**: High. **Rationale**: It can leave file data, size, and future completion inconsistent with `EFAULT`, reported zero, and an unchanged shared offset.

### Scenario 3: A vector call is multiple shared-offset critical sections

**Mechanism**: `readv`/`writev` loop above the only offset lock, so a competing operation may linearize between entries.
**Evidence**:

- Historical: [#1223](https://github.com/asterinas/asterinas/issues/1223) tracked the missing vector interface; [PR #2230](https://github.com/asterinas/asterinas/pull/2230) repaired prior-entry error suppression but not whole-call atomicity.
- Code analysis: each loop iteration calls `file.read` or `file.write` independently (`kernel/core/src/syscall/preadv.rs:152-174`; `kernel/core/src/syscall/pwritev.rs:148-170`).
- Code analysis: the offset lock spans only one scalar backend call (`kernel/core/src/fs/file/inode_handle.rs:273-320`); file-table lookup and backend locks do not span the vector loop (`kernel/core/src/fs/file/file_table.rs:321-361`).
**Affected code paths**: `readv`, `writev`, scalar competitors on duplicated descriptors, and positional competitors touching the same inode data.
**Suggested modeling approach**:

- Variables: `vectorIndex`, `offsetOwner`, `dataOwner`, `opStart`, `observedEpochs`, `reported`.
- Actions: `VectorEntry` acquires/releases scalar serialization; enable a competitor only between entries; permit a later entry to fault after a prefix.
- Granularity: one action per successful scalar entry, with the faulting entry split as in Scenario 1.
**Priority**: High. **Rationale**: `readv` can return `ab|ef` while a competitor reads `cd`; `writev` can produce `AA|XX|BB`. No whole-call order explains either history.

### Scenario 4: Positional offset neutrality coexists with split data snapshots

**Mechanism**: positional I/O correctly avoids the OFD offset, but its data mutation can expose vector splits and ramfs snapshots EOF outside its data lock.
**Evidence**:

- Reference: Linux positional calls use a local position, while shared scalar/vector calls hold `f_pos_lock` for the whole call ([Linux `read_write.c`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L704-L802), [vector calls](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L1068-L1106), [`fdget_pos`](https://github.com/torvalds/linux/blob/v6.16/fs/file.c#L1210-L1218)).
- Code analysis: Asterinas `read_at`/`write_at` never access `self.offset` (`kernel/core/src/fs/file/inode_handle.rs:323-353`).
- Code analysis: ramfs reads snapshot size before taking the page-cache mutex and fail to limit the writer to EOF (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710`; `kernel/core/src/vm/page_cache/mod.rs:181-186`).
**Affected code paths**: `pread64`, `pwrite64`, scalar shared-offset I/O, vector I/O, and ramfs regular files.
**Suggested modeling approach**:

- Variables: `explicitOffset`, `ofdOffset`, `fileSizeSnapshot`, `dataEpoch`, `bufferEpochs`, `copied`, `reported`, `result`.
- Actions: positional operations mutate/read data without changing `ofdOffset`; permit them between vector entries and between ramfs size snapshot and copy.
- Granularity: atomic positional scalar data action for ext2; split ramfs `SnapshotSize` from `CopyData`.
**Priority**: Medium. **Rationale**: the offset-neutrality baseline is correct, but `readv` can return mixed generations and ramfs can copy more data than it reports.

### Scenario 5: Append positioning commits before write success

**Mechanism**: scalar `O_APPEND` assigns EOF to the shared offset before invoking the fallible backend.
**Evidence**:

- Code analysis: `*offset = path.size()` precedes `file_ops.write_at(...)?`; failure skips only the subsequent `+= len` (`kernel/core/src/fs/file/inode_handle.rs:308-320`).
- Code analysis: regular ext2/ramfs opens return no per-open file object, so the guarded append branch is reachable (`kernel/core/src/fs/fs_impls/ext2/impl_for_vfs/inode.rs:140-171`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:260-286,923-929`).
- Reference: Linux publishes its local position back to `f_pos` only for a nonnegative result ([Linux `read_write.c`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L727-L744)).
**Affected code paths**: scalar `write` on a regular file opened with `O_APPEND`; positional `pwrite64` remains offset-neutral (`kernel/core/src/fs/file/inode_handle.rs:334-353`).
**Suggested modeling approach**:

- Variables: `append`, `appendStart`, `ofdOffset`, `result`, `committed`.
- Actions: model the current pre-position action separately from backend copy/failure.
- Granularity: split `ChooseAppendStart` and `WriteAttempt` so zero-progress failure can expose the offset move.
**Priority**: Medium. **Rationale**: This is failure-path offset accounting, not the excluded concurrent append-range atomicity question, and is directly testable.

### Scenario 6: Restart consumes an errno without progress provenance

**Mechanism**: scalar wrappers translate any `EINTR` to `ERESTARTSYS`, and `SA_RESTART` rewinds the syscall without consulting copied or committed progress.
**Evidence**:

- Historical: [#1578](https://github.com/asterinas/asterinas/issues/1578) and [PR #1598](https://github.com/asterinas/asterinas/pull/1598) introduced restart; open [PR #3576](https://github.com/asterinas/asterinas/pull/3576) identifies the generic syscall-layer classification problem but has no regular-file positive-progress witness.
- Code analysis: translation is in `read`/`write` (`kernel/core/src/syscall/read.rs:27-39`; `kernel/core/src/syscall/write.rs:27-39`); signal delivery restores arguments and rewinds IP (`kernel/core/src/process/signal/mod.rs:54-62,145-158`; `kernel/core/src/thread/task.rs:83-105`).
- Negative reachability: ext2/ramfs page waits are uninterruptible and user faults are `EFAULT`, so no inspected regular-file path returns `EINTR` at all (`ostd/src/sync/wait.rs:69-85`; `kernel/libs/io-util/src/batch.rs:147-164`).
**Affected code paths**: scalar `read`/`write`, signal delivery, and any future regular-file backend that can return `EINTR`.
**Suggested modeling approach**:

- Variables: `attemptId`, `saRestart`, `restartPending`, `interruptibleBackend`, `copied`, `committed`.
- Actions: `InterruptBeforeProgress` requires `interruptibleBackend`; set that capability false for pinned ext2/ramfs, and permit restart only when all progress is zero.
- Granularity: keep all interrupt transitions disabled in the pinned backend configuration.
**Priority**: Low. **Rationale**: The restart gate is structurally progress-blind, but the required positive-progress regular-file source is absent today.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Progress ledger**: keep requested, copied, committed, reported, and offset movement separate; Scenarios 1, 2, and 5 show that each can diverge.
- **One shared OFD**: two threads use duplicated descriptors that share `ofdOffset`; this is the actual ownership path in `file_table.rs:117-121,181-187`.
- **Scalar and vector lock boundaries**: scalar operations hold the offset lock through one backend call, while vector operations release it between entries; Scenario 3 depends on this exact boundary.
- **Backend disposition**: retain/discard a buffered prefix according to page state and whether it lies below old EOF, and retain a submitted direct-I/O effect; Scenario 2 requires each class.
- **Positional and capability-gated restart actions**: positional operations never mutate `ofdOffset`; the pinned ext2/ramfs configuration disables interruption, while a reference-only backend capability permits restart only at zero progress.

### 3.2 Do Not Model (with rationale)

- Sockets, pipes, `msghdr`, control messages, `SCM_RIGHTS`, and `accept`: separate protocols and explicitly out of scope.
- `preadv`/`pwritev`, RWF variants, parser-only iovec bounds/arithmetic, and broad resource exhaustion: excluded by guidance; historical [#1245](https://github.com/asterinas/asterinas/issues/1245) and [#1554](https://github.com/asterinas/asterinas/issues/1554) are reference-only.
- Exact byte, page, block, or chunk counts: retain only zero/positive/complete classes.
- Concurrent append-range placement: excluded; model only the distinct pre-success shared-offset mutation in Scenario 5.
- Signal interruption in the pinned backend configuration: current ext2/ramfs paths cannot produce `EINTR`; only a disabled reference capability may define zero-progress restart.
- User-buffer snapshot stability: cooperating userspace may remap or mutate buffers between steps; assert kernel accounting, not same-generation source data.
- Closed historical bugs as hunt targets: use them only as evidence of error-prone mechanisms.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Progress ledger | `requested`, `copied`, `committed`, `reported`, `result` | Separate physical progress from syscall accounting | 1-6 |
| OFD serialization | `ofdOffset`, `offsetOwner`, `vectorIndex` | Reproduce scalar versus per-entry vector locking | 3, 4 |
| Backend publication | `backendMode`, `rangeClass`, `pageState`, `fileSize`, `pendingBio` | Represent retained/discarded prefixes and escaped direct I/O | 2 |
| Data epochs | `dataEpoch`, `bufferEpochs`, `fileSizeSnapshot` | Detect mixed-generation and stale-size observations | 3, 4 |
| Restart attempts | `attemptId`, `restartPending`, `saRestart`, `interruptibleBackend` | Gate reference restart while disabling it for pinned backends | 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `TypeOK` | Safety | Progress classes, owners, operation kinds, and PCs remain well typed | All |
| `ReportedCoversVisibleCopy` | Safety | Visible positive copy implies a positive successful result whose report covers that progress | 1, 4 |
| `ReportedCoversCommittedWrite` | Safety | A committed positive write implies a positive successful result whose report covers that progress | 1, 2 |
| `SharedOffsetMatchesReported` | Safety | Nonpositional successful progress moves the OFD offset by reported progress; zero-progress failure does not move it | 1, 3, 5 |
| `FileSizeMatchesProgress` | Safety | Zero-copy failure and zero-length writes do not expand the file; expansion is covered by committed/reported progress | 2 |
| `VectorCallLinearizable` | Safety | One vector call observes/produces one contiguous block relative to competing I/O on the OFD | 3, 4 |
| `PositionalOffsetStable` | Safety | `pread64`/`pwrite64` never change `ofdOffset` | 4 |
| `NoUnaccountedPendingEffect` | Safety | A returned failure cannot leave a later direct completion outside the reported attempt | 2 |
| `RestartRequiresZeroProgress` | Safety | A restarted attempt has zero copied and committed progress | 6 |
| `NoEffectReplay` | Safety | No effect identity is committed by two restart attempts | 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | Can a later-iovec positive fault plus an intervening shared-offset operation produce a result/offset/data history with no whole-call order? | `VectorCallLinearizable`, `ReportedCoversVisibleCopy`, or `ReportedCoversCommittedWrite` | 1, 3 |
| MC2 | Can an ext2 direct submission survive a later user fault, release inode/OFD serialization, and complete out of order with a subsequent shared operation? | `NoUnaccountedPendingEffect` or `SharedOffsetMatchesReported` | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | Buffered partial faults across scalar/vector paths | Split-map buffers; compare result, changed buffer/file prefix, and duplicated-FD offset on warm and cold ext2 pages |
| TV2 | Ramfs faulting writes publish size before progress | Fault immediately and after a prefix; assert result, `stat` size, data, and offset |
| TV3 | Ramfs read crosses logical EOF | Seed sentinel bytes after the destination’s returned range; assert they remain unchanged and a post-EOF fault still returns the logical prefix |
| TV4 | Zero-length ramfs write beyond EOF | `lseek` or `pwrite64` beyond EOF with length zero; assert size is unchanged |
| TV5 | Append failure moves the OFD offset | Set an initial non-EOF offset, issue invalid-buffer `O_APPEND` write, then inspect offset and next shared I/O |
| TV6 | Fragmented ext2 direct write faults after one range | Force multiple mapped ranges and a later buffer fault; observe submitted data and ordering with the next operation |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | Kernel error conversion erases the fallible-copy count | Carry a progress-bearing result through VMO, filesystem, `FileLike`, and syscall layers |
| CR2 | Ramfs metadata publication and EOF limiting differ from ext2 | Limit the writer to `read_len`; commit size/timestamps only after copy or add rollback |
| CR3 | No `FileLike` vector operation can hold one OFD/backend critical section | Add a deep vector interface or move the vector loop below serialization |
| CR4 | Restartability is encoded as a bare errno | Make interruptible operations return an outcome that distinguishes zero progress from committed progress |
| CR5 | Direct-I/O error exits do not await/cancel prior submissions | Establish an await-on-error or partial-success contract before releasing the inode lock |

## 7. Reference Pointers

- Full audit: `../.specula-output/analysis-report.md`
- Shared offset: `kernel/core/src/fs/file/inode_handle.rs:273-353`
- Vector dispatch: `kernel/core/src/syscall/preadv.rs:134-180`; `kernel/core/src/syscall/pwritev.rs:134-175`
- Fallible copy and count erasure: `ostd/src/mm/io/mod.rs:271-292,332-385`; `kernel/core/src/error.rs:209-219`
- Page-cache effects: `kernel/core/src/vm/page_cache/vmo/mod.rs:533-759,1019-1052`
- Backend behavior: `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:181-406`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-756`
- Restart: `kernel/core/src/syscall/read.rs:27-39`; `kernel/core/src/syscall/write.rs:27-39`; `kernel/core/src/process/signal/mod.rs:54-62,145-158`
- Linux contracts: [`read(2)`](https://man7.org/linux/man-pages/man2/read.2.html), [`write(2)`](https://man7.org/linux/man-pages/man2/write.2.html), [`readv(2)`](https://man7.org/linux/man-pages/man2/readv.2.html), [`pread(2)`](https://man7.org/linux/man-pages/man2/pread.2.html), [`signal(7)`](https://man7.org/linux/man-pages/man7/signal.7.html)
- Archaeology anchors: [#711](https://github.com/asterinas/asterinas/issues/711), [#1223](https://github.com/asterinas/asterinas/issues/1223), [PR #2230](https://github.com/asterinas/asterinas/pull/2230), [PR #3256](https://github.com/asterinas/asterinas/pull/3256), [PR #3576](https://github.com/asterinas/asterinas/pull/3576)
