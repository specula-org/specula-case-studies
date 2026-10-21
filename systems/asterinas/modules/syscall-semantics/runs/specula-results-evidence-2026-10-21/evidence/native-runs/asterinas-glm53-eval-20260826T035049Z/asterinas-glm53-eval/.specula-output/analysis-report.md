# Analysis Report: Asterinas Regular-File Partial Progress

## 1. Result

This audit analyzed regular-file `read`, `write`, `pread64`, `pwrite64`,
`readv`, and `writev` at
`604948581512d83734377974d4c34adb4530f2d7`. The target is Category B
(Concurrent / Lock-Free):
correctness depends on concurrent operations sharing one open-file description,
fallible user-copy progress, filesystem publication order, and syscall restart.

The source supports four handoff scenarios:

1. A fallible user copy can make positive progress that is erased before the
   syscall result and shared-offset update. Scalar behavior is the still-open
   historical [issue #711](https://github.com/asterinas/asterinas/issues/711),
   so it is retained as a positive control rather than reported as new.
2. RamFS and exFAT cached reads are not bounded to logical EOF. A read that
   reports zero can modify user memory, and a read whose logical prefix is valid
   can fault only because the cache copy crossed EOF.
3. RamFS publishes the full requested EOF before a fallible write. A zero-copy
   fault can therefore extend the file while returning `EFAULT` and leaving the
   shared offset unchanged.
4. `readv` and `writev` release shared-offset serialization between iovecs.
   This admits both non-linearizable interleaving and a new composition in
   which a later iovec's committed prefix is omitted from the aggregate result
   and offset delta.

Positional I/O correctly bypasses the shared offset. Scalar `read` and `write`
translate `EINTR` to `ERESTARTSYS`, and signal delivery can rewind the syscall,
but no current in-scope regular-file path was found that returns `EINTR` after
committing progress. Restart replay remains a required invariant and an
interface hazard, not a confirmed current execution.

No runtime test was run. Findings are exact-target static execution-path
results; the two filesystem-adapter candidates remain test-verifiable.

## 2. Target Provenance and Scope

### 2.1 Snapshot identity

The supplied `source` directory has no Git metadata. History was inspected in
`/home/chin39/Documents/asterinas`; every analyzed target blob was then compared
against the supplied archive with Git object hashes.

| Property | Value |
|---|---|
| Commit | `604948581512d83734377974d4c34adb4530f2d7` |
| Subject | `Add aster-code-review benchmark problem:500-508` |
| Author date | 2026-08-08 01:53:59 UTC |
| Commit date | 2026-08-21 12:56:11 UTC |
| Primary-path size | 5,619 lines |
| Primary paths plus filesystem adapters | 10,124 lines |

Representative blob checks follow. Both hash columns matched for every path.

| Path | Target and archive blob |
|---|---|
| `ostd/src/mm/io/mod.rs` | `e3d485996cc19376506bd4f6f4f366b691898e71` |
| `kernel/core/src/error.rs` | `373d051f2914ebec1f6467cc9101cd265240b3f5` |
| `kernel/core/src/vm/page_cache/vmo/mod.rs` | `1380cc8f874b3a7ab79909b7b251b2e73badbd56` |
| `kernel/core/src/fs/file/inode_handle.rs` | `99e0cd93abeda0cb5804d4e9f839e4c6f4bd33c3` |
| `kernel/core/src/syscall/preadv.rs` | `d24dd138b64514a7c7360acd5c2ca947764d9da4` |
| `kernel/core/src/syscall/pwritev.rs` | `36fbc70524f6d9b129efd68c6be1f43b7e16da0d` |
| `kernel/core/src/process/signal/mod.rs` | `3ef4e7cd3e63ac42a5d4179a583d709279493417` |
| `kernel/core/src/thread/task.rs` | `8c188022a68e532bae8c2affc50d403825bec67b` |
| `kernel/core/src/fs/fs_impls/ramfs/fs.rs` | `005b0132c866de9e017d4812cf1abeee6070b975` |
| `kernel/core/src/fs/fs_impls/exfat/inode.rs` | `68be618dd300bc754e78d83c9c08d62eab5170ce` |
| `kernel/core/src/fs/fs_impls/ext2/inode/file.rs` | `8ae1f20b915b5e701cf577c8f8c24fd928b1db48` |
| `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs` | `a3031d45aaa1257d70984c5a36b4431c7f18b053` |

Source coverage was divided as follows:

| Group | Files | Lines | Mode |
|---|---|---:|---|
| Copy/error/VMO | `mm/io/mod.rs`, `error.rs`, `page_cache/vmo/mod.rs` | 2,680 | End-to-end |
| File/open-description state | `inode_handle.rs`, `file_handle.rs`, `file_table.rs` | 1,365 | End-to-end |
| Six syscall paths and iovec utility | `read.rs`, `write.rs`, `pread64.rs`, `pwrite64.rs`, `preadv.rs`, `pwritev.rs`, `util/iovec.rs` | 905 | End-to-end |
| Signal/task | `process/signal/mod.rs`, `thread/task.rs` | 669 | End-to-end |
| RamFS, exFAT, ext2, VirtioFS adapters | Four adapter files shown above | 4,505 | Relevant methods and state transitions |

The page-cache wrapper, cache-page state machine, block wait path, ext2
regression, and syscall dispatcher were traced at their relevant call sites.

### 2.2 Inclusion boundary

Included:

- scalar and vectored I/O through one shared regular-file description;
- fallible `VmReader`/`VmWriter` transfer classes: zero, positive prefix, all;
- cooperating user-buffer mutation/remap as a nondeterministic outcome at each
  kernel copy step, without a same-generation snapshot guarantee;
- copied, committed, reported, and offset progress as separate state;
- positional I/O competing with shared-offset I/O;
- signal delivery, `ERESTARTSYS`, `SA_RESTART`, and syscall rewind;
- filesystem adapters needed to determine whether a prefix is durable or
  logically visible.

Excluded:

- sockets, pipes, PTYs, `sendfile`, messages, SCM_RIGHTS, and accept;
- `preadv`/`pwritev`, `*v2`, RWF flags, and parser-only iovec validation;
- exact page, byte, batch, or chunk counts;
- O_APPEND concurrent range atomicity, seals, broad resource exhaustion, and
  the page-lock/page-fault liveness protocol;
- historical issues #711, #1554, and #3181 as novel findings.

## 3. Phase 1: Architecture and Contract

### 3.1 Call path

```text
sys_read/sys_write                 sys_pread64/sys_pwrite64
        |                                  |
        v                                  v
 FileLike::read/write               FileLike::read_at/write_at
        |                                  |
        +----------> InodeHandle <----------+
                         |
                         v
                   FileOps::{read,write}_at
                         |
                         v
              filesystem adapter / PageCache
                         |
                         v
                 Vmo / VmReader / VmWriter
```

`readv` and `writev` do not add an aggregate file operation. They loop over
iovecs and invoke `FileLike::read` or `FileLike::write` for each entry
(`kernel/core/src/syscall/preadv.rs:152-174` and
`kernel/core/src/syscall/pwritev.rs:148-170`).

### 3.2 Shared state and operation boundaries

| Operation | Offset source | Serialization | Offset publication |
|---|---|---|---|
| `read` | `InodeHandle::offset` | Mutex spans one underlying `read_at` | Add returned `len` on `Ok` |
| `write` | `InodeHandle::offset` | Mutex spans one underlying `write_at` | Add returned `len` on `Ok` |
| `readv` | Shared offset per entry | Mutex released between iovecs | Per successful entry |
| `writev` | Shared offset per entry | Mutex released between iovecs | Per successful entry |
| `pread64` | Explicit syscall offset | No shared-offset ownership | Never |
| `pwrite64` | Explicit syscall offset | No shared-offset ownership | Never |

Duplicated descriptors share the same `Arc<dyn FileLike>`
(`kernel/core/src/fs/file/file_table.rs:117-121,181-188,393-398`). The shared
offset is `InodeHandle.offset: Mutex<usize>`
(`kernel/core/src/fs/file/inode_handle.rs:28-35`). Scalar lock and publication
are at `inode_handle.rs:285-320`; positional operations bypass the field at
`:323-354`. File-table lookup clones the `Arc` and releases the table lock
before I/O (`file_table.rs:351-361`), so there is no outer serialization.

### 3.3 Linux-visible contract

The reference was checked against Linux v6.16 `fs/read_write.c` and the Linux
man pages for `read(2)`, `write(2)`, `readv(2)`, `pread(2)`, and `signal(7)`.

| Property | Required observation |
|---|---|
| Short read/write | Positive completed progress is returned instead of a later copy fault |
| Shared offset | Offset movement equals the successful result |
| Vectored I/O | One vector has the atomicity of one block transfer relative to competing I/O |
| Positional I/O | Explicit offset is used; open-description offset is unchanged |
| Interruption | `EINTR` is observable before progress; restart cannot replay a committed effect |

Linux holds `fd_pos` across the complete `vfs_readv`/`vfs_writev` call. Its
fallback may iterate iovecs internally, but the open-description position lock
remains outside that loop. Asterinas instead locks per iovec.

## 4. Phase 2: Bug Archaeology

### 4.1 Coverage

| Source | Coverage | Result |
|---|---:|---|
| Rename-aware history of target paths | 355 unique commits | All inspected by subject; 46 keyword candidates opened |
| Keyword candidates | 46 | 24 substantive, 22 excluded after diff inspection |
| GitHub issues | 30 issues, 99 comments | Every body and comment read |
| Open pull requests | 127 titles screened | 8 patches and all discussion read |
| Relevant source TODO/FIXME | 24 in core path set | 4 vector, plus offset/restart/append references |

The history search used `fix`, `bug`, `race`, `panic`, `leak`, `inconsistent`,
`wrong`, `safety`, `deadlock`, `correctness`, `crash`, and `corrupt`. Mechanism
history was also followed without relying on keywords.

### 4.2 Substantive keyword-history commits

| Commit | Sev. | Why retained |
|---|---|---|
| `00b9bf961090` | Medium | Zero-sized `VmReader` construction assertion |
| `153e530fe2ef` | High | Page-cache resize/decommit size boundary |
| `1b23182dccba` | High | Signal/thread-status ordering |
| `21365dd0bda8` | Medium | Shared-offset seek arithmetic and behavior |
| `25c4f0f2bcaa` | Medium | Incorrect signal-derived exit status |
| `39cd4420f28c` | Low | Zero-length scalar write/error ordering; pipe-specific |
| `4658b62f90ec` | High | Thread oops handling |
| `4823b82e4164` | High | User task panic/oops boundary |
| `7ade3b5dd65f` | Medium | POSIX lock ownership; outside data-progress model |
| `899db770f622` | High | `preadv`/`pwritev` split-offset ABI passing |
| `8e3212449ce3` | Critical | Typed `VmIo` slice-transmute undefined behavior |
| `8ffe1a7c4b46` | Medium | PID 1 signal defaults |
| `9e4650657524` | High | Signal-stack layout/reachable panic |
| `aa23e850c40b` | High | Range-lock ownership; outside campaign scope |
| `b606e3456c43` | Medium | Invalid `set_child_tid` panic |
| `c2b1be961b8e` | Critical | Page-cache partial write could expose uninitialized data |
| `cc779c3ead6c` | Low | Block error translation |
| `d01367944019` | Low | `preadv2` RWF errno; excluded API |
| `d7cbd0f51cd3` | Medium | Positional I/O capability and error ordering |
| `de52fd189b84` | Low | Empty positional-vector capability checks |
| `dee7734073bf` | High | Typed `VmWriter` needed volatile stores for DMA |
| `e0c6c294815d` | High | Task-reference leak |
| `e1480f94eed1` | High | Signal delivery during CPU-bound execution |
| `e6f79014779e` | Medium | Initial stack-pointer correctness |

The 22 excluded keyword hits were documentation-only changes, formatting,
refactors without semantic diffs, or paths outside the regular-file state
machine.

### 4.3 Mechanism-directed history

| Commit | Relevance |
|---|---|
| `09b6153d29ec` | Introduced fallible VM readers/writers with `(error, count)` |
| `dce796cdde87` | Routed VFS through VM cursors; PR #1156 explicitly left #711 unresolved |
| `12db7ec55d3c` | Introduced the per-iovec syscall loops and their atomicity TODOs |
| `14ada9000ac8` | Added offset-independent `read_at`/`write_at` |
| `24502ac3d4c3` | Centralized shared offset in `InodeHandle` |
| `ced0023d6b5d`, `1b56a8b600d5` | Introduced syscall restart and `SA_RESTART` rewind |
| `18e0eae33104` | Prevented `ERESTARTSYS` from escaping to userspace |
| `e928dbd7c4ca`, `04547162b406` | Moved original-result bookkeeping into thread-local state |

Commit `c2b1be961b8e` and issue #3256 fixed the uninitialized-page disclosure
case. They did not restore the positive user-copy count, so they compensate one
write state without resolving #711.

### 4.4 History hotspots

| Path | Rename-aware commits | Keyword candidates | Substantive |
|---|---:|---:|---:|
| `inode_handle.rs` | 99 | 11 | 4 |
| `thread/task.rs` | 88 | 11 | 7 |
| `process/signal/mod.rs` | 103 | 11 | 5 |
| `ostd/src/mm/io/mod.rs` | 65 | 8 | 3 |
| `vm/page_cache/vmo/mod.rs` | 18 | 4 | 2 |
| `preadv.rs` | 23 | 3 | 3 |
| `pwritev.rs` | 23 | 3 | 3 |
| `write.rs` | 50 | 3 | 1 |
| `error.rs` | 50 | 3 | 1 |
| `read.rs` | 36 | 2 | 0 |

### 4.5 Issue audit

The classification counts are 17 confirmed defects, 10 design/tracking
records, 2 false positives or user errors, and 1 unresolved report. “Retain”
means the issue informed the model or a test; it does not mean it is a new
finding.

| Issue | Classification | Disposition for this campaign |
|---|---|---|
| [#711](https://github.com/asterinas/asterinas/issues/711) | Confirmed, open | Retain as scalar partial-copy positive control only |
| [#1136](https://github.com/asterinas/asterinas/issues/1136) | Confirmed | Retain history for VM-reader VFS conversion |
| [#1223](https://github.com/asterinas/asterinas/issues/1223) | Design/tracking | Retain vector atomicity provenance |
| #1245 | Confirmed, fixed | Exclude parser/OOM mechanism |
| #1542 | Confirmed | Exclude `sendfile`/pipe path |
| #1554 | Confirmed, fixed | Reference only; pipe partial write |
| [#1578](https://github.com/asterinas/asterinas/issues/1578) | Confirmed, fixed | Retain restart provenance, not a current finding |
| #1619 | Confirmed, fixed | Exclude FPU context path |
| #3181 | Confirmed, fixed | Reference only; `sendfile`/PTY path |
| #3214 | Design/tracking | Exclude block devices |
| #419 | Design/tracking | Page-cache ownership history |
| #651 | Design/tracking | Exclude direct-I/O performance |
| #730 | False positive | Exclude |
| #791 | Design/tracking | Exclude performance-only report |
| #850 | Design/tracking | Exclude file-mode redesign |
| #1089 | Confirmed, fixed | Exclude DMA tearing |
| #1175 | Confirmed, fixed | Exclude `sigprocmask` unwrap |
| #1568 | Confirmed, fixed | Exclude signal-frame panic |
| #1587 | Confirmed, fixed | Exclude futex waiter cleanup |
| #1938 | Confirmed, open | Exclude SMP abort; no causal `writev` link |
| #2165 | Design/tracking | Exclude atomic VM-copy API design |
| #2252 | Confirmed, fixed | Exclude ignored-signal/signalfd path |
| #2256 | Design/tracking | Inode API history only |
| #2851 | Unresolved | Exclude stale `F_SETOWN` hang report |
| #2937 | Design/tracking | Page-cache refactor history only |
| #3142 | Design/tracking | Exclude broad xfstests/RWF tracking |
| #3178 | User/test error | Exclude |
| #3211 | Design/tracking | Exclude block-device gaps |
| #3257 | Confirmed, open | Exclude page-lock/page-fault deadlock state machine |
| #3283 | Confirmed, open | Exclude stale-waker/resource-exhaustion restart path |

### 4.6 Open-PR audit

All 127 current open titles were screened. The eight candidate heads are absent
from the target object graph, and their proposed semantics are absent from the
target source. All top-level comments, reviews, and inline threads were read.

| PR | Current head | Discussion read | Disposition |
|---|---|---|---|
| [#3720](https://github.com/asterinas/asterinas/pull/3720) | `7acf712904a6` | 2 comments, 2 reviews, 1 thread | Exclude parser-only iovec validation |
| [#3582](https://github.com/asterinas/asterinas/pull/3582) | `45da5c95f98a` | 5 reviews, 3 threads | Test VirtioFS/FUSE short replies; distinct from user-copy progress |
| [#3576](https://github.com/asterinas/asterinas/pull/3576) | `8e02d0e94230` | 7 reviews, 8 threads | Model restart ownership; no regular-file post-progress test |
| [#3481](https://github.com/asterinas/asterinas/pull/3481) | `d4d1cd3a22ac` | 1 comment | Exclude O_APPEND/seal races |
| [#3297](https://github.com/asterinas/asterinas/pull/3297) | `97ae1dfadc84` | 1 review, 3 threads | Model explicit ext2 rollback states |
| [#2613](https://github.com/asterinas/asterinas/pull/2613) | `4e15b0ab5960` | 15 comments, 15 reviews, 25 threads | Code review; lower page-table cursor layer |
| [#3574](https://github.com/asterinas/asterinas/pull/3574) | `39591bbf5ffc` | No discussion | Exclude socket copy-out |
| [#3643](https://github.com/asterinas/asterinas/pull/3643) | `658825b93cfc` | 6 comments | Code review; page-table marker invariant |

PR #3576 directly confirms that target restart ownership is too broad at the
syscall layer. Its tests cover pipes, poll, socket timeout, and futex timeout,
not a regular file after committed progress. PR #3297 preserves ext2's
rollback-on-error semantics; it does not reinterpret a positive copied prefix
as short success. Neither PR closes the modeled gap.

## 5. Phase 3: Deep Execution-Path Analysis

### 5.1 Progress information is lost across layers

`VmReader::read_fallible` selects a copy length, performs the copy, advances
both cursor views by the actual prefix, and returns `(PageFault, copied_len)`
when incomplete (`ostd/src/mm/io/mod.rs:332-361`). `write_fallible` delegates
to the same primitive (`:367-375`).

The count then disappears:

- tuple-to-kernel-error conversions explicitly discard it
  (`kernel/core/src/error.rs:209-219`);
- `Vmo::read` propagates the tuple through `?`
  (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566`);
- anonymous writes do the same (`vmo/mod.rs:667-699`);
- backed writes use a positive prefix to mark a page dirty, then return only
  the error (`vmo/mod.rs:734-746`);
- `InodeHandle` advances the shared offset only on `Ok(len)`
  (`kernel/core/src/fs/file/inode_handle.rs:285-320`).

| Copy class | User/file effect | Syscall-facing result | Shared offset |
|---|---|---|---|
| Zero then fault | Usually none; adapter metadata may already change | `EFAULT` | Unchanged |
| Positive prefix then fault | Read buffer changed; initialized/anonymous write prefix persists | `EFAULT`, prefix omitted | Unchanged |
| Complete | Complete copy/commit | Adapter's `Ok(len)` | Advances by `len` for shared I/O |

For backed writes, a newly allocated `Uninit` page is a compensating state: a
faulting full-overwrite does not mark it dirty, and a later read reloads it from
the backend. Already `UpToDate` or `Dirty` pages retain their prefix. Anonymous
RamFS pages retain it as well. This is why `copied` and `committed` must be
separate variables.

### 5.2 Filesystem adapter matrix

| Adapter | Read EOF boundary | Write publication/rollback | Consequence |
|---|---|---|---|
| RamFS | Computes logical count but passes unrestricted writer | Publishes requested EOF before copy; no rollback | Read-past-EOF copy; nominal EOF after fault |
| exFAT | Same missing writer limit | Defers valid size; allocation may precede copy | Read-past-EOF copy; initialized-page prefix may persist |
| ext2 | Returns at EOF and limits writer | Rolls extension back; in-place bytes not restored | Correct EOF boundary; partial in-place commit still count-collapsed |
| VirtioFS cached | Limited cloned writer, advance original on success | Rolls size/cache extension back | Compensates EOF and extension state; old-range prefix can persist |
| VirtioFS direct | Stages user data and advances source after FUSE accepts bytes | Returns prior committed progress after later failure | Strongest progress-preserving comparator |

Evidence:

- RamFS read/write: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-710,731-750`.
- exFAT read/write: `kernel/core/src/fs/fs_impls/exfat/inode.rs:648-657,720-743`.
- ext2 read/write: `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:193-218,234-271`.
- VirtioFS cached read/write:
  `kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:65-80,148-178`.
- VirtioFS direct staging: `virtiofs/inode/ops.rs:252-337`.

### 5.3 Candidate TV-1: RamFS/exFAT copy beyond logical EOF

Both adapters compute `read_len` against logical size, call `PageCache::read`
with the original unrestricted writer, and return the separately computed
count. Page-cache capacity is page-aligned
(`kernel/core/src/vm/page_cache/mod.rs:181-184,264-271`); `Vmo::read` clips
against that capacity, not filesystem EOF (`vmo/mod.rs:533-557`).

Minimal zero-return execution:

1. Create a regular file of non-page-aligned length `L`.
2. Read one byte at `L` by `pread64`, or set the shared offset to `L` and read.
3. The adapter computes `read_len = 0`.
4. The VMO copies one cache-capacity byte to the destination.
5. The adapter returns zero; shared offset remains unchanged.

The user buffer changed despite a zero result. If the destination is invalid,
the same logically empty read returns `EFAULT` instead of zero.

Fault composition: start at `L - 1`, request two bytes, and place the second
destination byte on an unmapped page. Linux-visible progress is one byte. The
unrestricted cache copy touches the second address, faults, loses the valid
prefix count, and leaves the shared offset unchanged.

Ext2's `writer.limit(read_len)` and VirtioFS's limited clone demonstrate the
missing boundary. Targeted issue and PR searches found no matching report.

### 5.4 Candidate TV-2: RamFS publishes nominal EOF before a failed write

RamFS captures the requested length, updates timestamps and logical size to
`offset + requested`, expands the cache, and only then performs the fallible
copy (`ramfs/fs.rs:731-750`). It has no error rollback.

Minimal zero-progress execution:

1. Place the shared offset at or beyond EOF.
2. Write a positive length from a source whose first byte faults.
3. RamFS publishes the full requested EOF and cache capacity.
4. The VMO copies zero and returns `EFAULT`.
5. `InodeHandle` leaves the shared offset unchanged.
6. `fstat` nevertheless observes the full nominal size.

With a positive prefix, anonymous-page bytes remain visible, the syscall still
returns `EFAULT`, the shared offset still does not advance, and EOF still shows
the complete request rather than the prefix. Ext2 and VirtioFS rollback, while
exFAT defers visible-size publication; those paths confirm this is adapter
ordering, not a page-cache requirement.

A zero-length RamFS write beyond EOF also extends the file. That deterministic
corollary is outside the requested positive-request fault model and is not a
separate handoff finding.

### 5.5 Candidate MC-1: later-iovec prefix omitted

The vector loops return `total_len` after an error if an earlier iovec
succeeded (`preadv.rs:165-169`; `pwritev.rs:161-165`). They have no channel for
the faulting iovec's positive prefix.

Read execution:

1. Iovec 0 copies `A`, returns 1, and advances the shared offset to 1.
2. Iovec 1 copies `B`, then faults.
3. Its scalar call returns `EFAULT` and does not advance the offset.
4. `readv` returns 1 because iovec 0 succeeded, although the destination has
   `A,B`.
5. The next shared read starts at offset 1 and returns `B` again.

On an anonymous or initialized file page, the write analogue commits `B`,
returns only the earlier count, and leaves the offset positioned to overwrite
`B`. This is a new composition of the known #711 mechanism and per-entry vector
dispatch; #711 itself described scalar I/O.

### 5.6 Candidate MC-2: vector operation has no single linearization point

Each iovec separately acquires and releases `InodeHandle::offset`. With file
contents `ABC` and offset zero:

1. T1 `readv([1,1])` reads `A`; offset becomes 1.
2. T2 `read(1)` reads `B`; offset becomes 2.
3. T1 reads its second entry, `C`; offset becomes 3.

T1 observes `A,C` and T2 observes `B`. If T1 linearized first it would observe
`A,B`; if T2 linearized first T1 would observe `B,C`. No serial order explains
the result. `writev([A,B])` interleaved with scalar `write(X)` similarly creates
`A,X,B` rather than a contiguous vector range.

The TODOs in `preadv.rs:159-164` and `pwritev.rs:155-160`, issue #1223, and PR
#3086 review supply provenance. The finding is the Linux-visible schedule, not
the existence of a source comment.

### 5.7 Positional offset isolation

`pread64` and `pwrite64` pass the explicit offset directly
(`kernel/core/src/syscall/pread64.rs:33-37` and `pwrite64.rs:33-35`).
`InodeHandle::read_at` and `write_at` never access the offset mutex
(`inode_handle.rs:323-354`). No syscall-layer update exists.

Data effects may race with shared-offset I/O through the filesystem, but the
positional operation cannot change the shared open-description offset. No
counterexample was found. This becomes a baseline invariant so extensions do
not accidentally conflate data-position and file-position state.

### 5.8 Signal interruption and restart

Scalar wrappers map every `EINTR` to `ERESTARTSYS`
(`kernel/core/src/syscall/read.rs:36-39`; `write.rs:36-39`). Vectored and
positional wrappers do not. Signal delivery recognizes `ERESTARTSYS` and, with
`SA_RESTART`, restores the saved syscall register and rewinds the instruction pointer
(`kernel/core/src/process/signal/mod.rs:54-60,145-158`).

The task loop stores the original syscall return-register value before
dispatch, runs the syscall, and only then handles pending signals
(`kernel/core/src/thread/task.rs:83-105`). The saved value restores the
syscall-number/return register before the instruction pointer is rewound;
restart is therefore a new invocation of the whole syscall, not a continuation
at a file-I/O substep.

Current RamFS, ext2, exFAT, VirtioFS, page-cache, and block-I/O regular-file
paths yielded no `EINTR` producer. Page-cache and block waits use
uninterruptible `WaitQueue::wait_until`, including
`kernel/core/src/vm/page_cache/cache_page.rs:316-322`,
`page_cache/mod.rs:399-405`, and
`kernel/core/comps/block/src/bio.rs:153-168,309-323`.

Therefore:

- a completed regular-file syscall updates its offset before later signal
  delivery and is not restarted;
- user-copy failures are `EFAULT`, not `EINTR`;
- no verified target execution commits regular-file progress and then produces
  `ERESTARTSYS`.

The interface remains unsafe if a future or remote filesystem returns `EINTR`
after progress: the shared offset would remain unchanged and `SA_RESTART` could
replay the attempt. The model should assert `committed = Zero` whenever restart
is enabled, but should not fabricate an interrupt transition unsupported by the
target.

## 6. Compensating Mechanisms and Rejected Candidates

- Scalar shared-offset operations do hold one mutex across their complete
  filesystem call. The atomicity gap starts only when vector code decomposes a
  syscall into multiple scalar calls.
- Positional calls correctly bypass shared-offset state.
- Ext2 limits reads to EOF and rolls back extension state; VirtioFS uses a
  limited cloned writer and explicit rollback/staging.
- Newly allocated ext2 `Uninit` pages can discard a faulting partial overwrite
  by reloading backend data. This does not compensate initialized-page writes.
- `IoVec::is_empty` treats a null nonzero entry as empty in the target
  (`kernel/core/src/util/iovec.rs:44-48`). Linux returns `EFAULT`, but open PR
  #3720 addresses it and the task explicitly excludes parser-only iovec
  validation. It is not modeled or reported as a campaign finding.
- Zero-iovec access-mode validation differs among scalar, vector, and
  positional paths. This is an access/zero-length ABI defect, not progress or
  shared-offset state.
- Issue #3257's page-lock/page-fault deadlock is real but requires a separate
  liveness and VM-lock model.
- O_APPEND range atomicity is acknowledged in source and open PR #3481, but is
  explicitly excluded.
- Issues #1554 and #3181 concern pipe/PTY/`sendfile` mechanisms and are retained
  only as historical reference.

## 7. Phase 4 Handoff

The companion `modeling-brief.md` reduces this audit to four scenarios and the
following state:

- progress classes `Zero`, `Prefix`, and `Complete` for requested, copied,
  committed, and reported work;
- shared offset and explicit positional offsets;
- adapter profile, logical EOF, cache capacity, and visible file size;
- per-vector iovec program counters and an unlocked boundary;
- signal/restart state and attempt identity.

The primary model-checkable properties are:

1. reported progress covers all copied/committed logical progress;
2. shared-offset delta equals reported progress;
3. one vector operation has one linearization point relative to competing
   shared-offset I/O;
4. positional I/O never changes the shared offset;
5. a restarted attempt has committed no prior effect.

Runtime follow-up should target TV-1 and TV-2 on RamFS and exFAT. Formal model
checking should target MC-1 and MC-2. Scalar #711 is the positive-control trace,
not a new discovery.

## 8. Primary References

- [Linux `read(2)`](https://man7.org/linux/man-pages/man2/read.2.html)
- [Linux `write(2)`](https://man7.org/linux/man-pages/man2/write.2.html)
- [Linux `readv(2)` / `writev(2)`](https://man7.org/linux/man-pages/man2/readv.2.html)
- [Linux `pread(2)` / `pwrite(2)`](https://man7.org/linux/man-pages/man2/pread.2.html)
- [Linux `signal(7)` restart rules](https://man7.org/linux/man-pages/man7/signal.7.html)
- [Linux v6.16 `fs/read_write.c`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c)
- [Asterinas issue #711](https://github.com/asterinas/asterinas/issues/711)
- [Asterinas issue #1223](https://github.com/asterinas/asterinas/issues/1223)
- [Asterinas PR #3086 vector review](https://github.com/asterinas/asterinas/pull/3086#discussion_r3031308667)
- [Asterinas PR #3576 restart refactor](https://github.com/asterinas/asterinas/pull/3576)
- [Asterinas PR #3297 ext2 rollback guard](https://github.com/asterinas/asterinas/pull/3297)
