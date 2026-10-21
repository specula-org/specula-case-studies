# Analysis Report: Regular-file partial progress and shared offsets

Analysis date: 2026-08-23  
Target: `asterinas/asterinas` at `604948581512d83734377974d4c34adb4530f2d7`  
Method: Specula Code Analysis, Category B

## Executive result

The pinned implementation has five statically verified Linux-visible progress/atomicity defects and one conditional direct-I/O failure window:

1. A positive user-copy prefix can be visible while the syscall returns `EFAULT` and a shared offset remains unchanged.
2. `readv`/`writev` release shared-offset and backend serialization between iovecs, so one call is not linearizable relative to competing I/O.
3. Ramfs publishes requested write size before copy, extends on zero-copy/zero-length cases, and can copy beyond logical EOF while reporting the smaller logical length.
4. A failed scalar `O_APPEND` write can move the shared open-description offset to EOF without committing a byte.
5. A ramfs size snapshot and positional data mutation can yield a scalar read whose returned length, copied bytes, and offset have no common linearization point.
6. On fragmented ext2 `O_DIRECT`, an earlier submitted range can remain live when a later user-copy fault returns `EFAULT`; this is statically supported but still needs a runtime reachability test.

Two important negative results bound the model:

- Ordinary `pread64`/`pwrite64` do not access or mutate the shared offset.
- No inspected ext2/ramfs regular-file path can return `EINTR` at all. Modeling a signal interruption at this pin would invent behavior.

The first mechanism is the current form of open issue [#711](https://github.com/asterinas/asterinas/issues/711), not a novel historical claim. The vector split is acknowledged in source. The ramfs, append-failure, combined interleaving, and direct-submission consequences were derived from the pinned code and were not found in the deeply read issue set.

## 1. Source provenance and scope

### 1.1 Pin verification

The supplied `source/` is a plain export without `.git`. Its sibling `baseline.git` has synthetic commit `3f174803dd984f381ba4845c4eb5b61f09f97dc8`, whose tree is `3893ebda0ec3c6f2ef075109c6cb620073b855ef`.

A separate read-only checkout at `/home/chin39/Documents/asterinas-dev` resolves the requested upstream commit to:

```text
commit 604948581512d83734377974d4c34adb4530f2d7
tree   3893ebda0ec3c6f2ef075109c6cb620073b855ef
title  Add aster-code-review benchmark problem:500-508
```

The matching tree IDs and a direct comparison of the target `inode_handle.rs` establish that analysis used the requested source. `git ls-remote` also resolved upstream `main` to the same commit during this run. The separate checkout had one pre-existing unrelated untracked file, `asterinas-onboarding.html`, which was not touched.

### 1.2 Category

This is **Category B (Concurrent / shared-state)**. The state machine is not the block device as a distributed participant. It is one syscall attempt’s requested, copied, committed, reported, and offset progress while two cooperating threads act on one `Arc<InodeHandle>`.

Concurrency comes from:

- duplicated or inherited descriptors sharing one open file description;
- an OFD offset mutex and filesystem/page locks with different scopes;
- vector loops above those locks;
- fallible user-memory access that can advance a prefix before error;
- asynchronous direct-I/O submission; and
- syscall restart as a second attempt over potentially shared state.

### 1.3 Included and excluded behavior

Included operations are `read`, `write`, `pread64`, `pwrite64`, `readv`, and `writev` on regular files, through one shared open file description. Ext2 buffered/direct I/O and ramfs were read because they determine whether copied progress becomes file-visible.

Excluded from the model:

- sockets, pipes, `msghdr`, control messages, `SCM_RIGHTS`, and `accept`;
- `preadv`/`pwritev`, RWF variants, and offset-flag variants;
- parser-only iovec bounds/arithmetic and broad resource exhaustion;
- exact byte/page/block/chunk counts beyond zero/positive/complete;
- concurrent `O_APPEND` range placement; and
- same-generation user-buffer snapshots.

The failed-append offset mutation remains included because it is progress accounting on one attempt, not concurrent append-range atomicity.

## 2. Method and coverage

### 2.1 Reconnaissance and full-file analysis

The 14 required files total 6,579 lines and were read completely:

| Area | Files | Lines |
|---|---|---:|
| OFD and syscall dispatch | `inode_handle.rs`, `read.rs`, `write.rs`, `pread64.rs`, `pwrite64.rs`, `preadv.rs`, `pwritev.rs` | 1,167 |
| Fallible transfer and conversion | `ostd/src/mm/io/mod.rs`, `kernel/core/src/error.rs` | 1,464 |
| Page cache | `kernel/core/src/vm/page_cache/vmo/mod.rs` | 1,216 |
| Signal/restart | `kernel/core/src/process/signal/mod.rs`, `kernel/core/src/thread/task.rs` | 669 |
| Regular-file backends | ext2 `inode/file.rs`, ramfs `fs.rs` | 2,063 |

Adjacent ownership, locking, and completion files were then traced as needed: `file_table.rs`, `file_handle.rs`, `vm_space.rs`, `iovec.rs`, page-cache `mod.rs` and `cache_page.rs`, ext2 VFS dispatch, `IoBatch`, BIO submission/completion, and `WaitQueue`.

Three parallel issue batches and three parallel full-file groups were used. Their results were cross-checked against the exact call paths in the main analysis.

### 2.2 Archaeology statistics

| Evidence source | Coverage | Result |
|---|---:|---|
| Path-following Git history | 454 unique commits across 15 core paths | All titles screened; all 87 bug-keyword candidates reviewed; 18 mechanism-relevant diffs read deeply |
| Issue searches | 40 search clauses, 189 raw hits | 106 unique candidate issues collected |
| Full issue threads | 31 unique issues | Every body and comment read, including minimized/outdated discussion where present |
| Issue dispositions | 31 | 16 confirmed current/historical mechanisms, 10 context-only, 3 false positives, 2 uncertain |
| Open PR inventory | 129 open PRs | All titles/files screened; six touched exact paths; adjacent restart/append/short-I/O PRs inspected |
| Deep PR threads | 17 unique PRs | Bodies, comments, reviews, and relevant inline discussions read |

The 31 full issue threads were:

- Confirmed current or historical mechanisms: [#651](https://github.com/asterinas/asterinas/issues/651), [#711](https://github.com/asterinas/asterinas/issues/711), [#774](https://github.com/asterinas/asterinas/issues/774), [#1223](https://github.com/asterinas/asterinas/issues/1223), [#1245](https://github.com/asterinas/asterinas/issues/1245), [#1274](https://github.com/asterinas/asterinas/issues/1274), [#1542](https://github.com/asterinas/asterinas/issues/1542), [#1554](https://github.com/asterinas/asterinas/issues/1554), [#1578](https://github.com/asterinas/asterinas/issues/1578), [#1587](https://github.com/asterinas/asterinas/issues/1587), [#2165](https://github.com/asterinas/asterinas/issues/2165), [#2252](https://github.com/asterinas/asterinas/issues/2252), [#2835](https://github.com/asterinas/asterinas/issues/2835), [#3181](https://github.com/asterinas/asterinas/issues/3181), [#3214](https://github.com/asterinas/asterinas/issues/3214), and [#3257](https://github.com/asterinas/asterinas/issues/3257).
- Context-only: [#39](https://github.com/asterinas/asterinas/issues/39), [#392](https://github.com/asterinas/asterinas/issues/392), [#419](https://github.com/asterinas/asterinas/issues/419), [#440](https://github.com/asterinas/asterinas/issues/440), [#712](https://github.com/asterinas/asterinas/issues/712), [#850](https://github.com/asterinas/asterinas/issues/850), [#1057](https://github.com/asterinas/asterinas/issues/1057), [#1136](https://github.com/asterinas/asterinas/issues/1136), [#2937](https://github.com/asterinas/asterinas/issues/2937), and [#3071](https://github.com/asterinas/asterinas/issues/3071).
- False positives: [#730](https://github.com/asterinas/asterinas/issues/730) was disproved by the reporter’s locking experiment; [#1603](https://github.com/asterinas/asterinas/issues/1603) was a BusyBox null dereference, not wrong-process delivery; [#3178](https://github.com/asterinas/asterinas/issues/3178) closed a reused descriptor and did not disprove `CLONE_FILES` sharing.
- Uncertain against the pinned rewrite: [#1938](https://github.com/asterinas/asterinas/issues/1938) and [#2269](https://github.com/asterinas/asterinas/issues/2269); neither supports an in-scope claim.

“Confirmed” in this table means the thread established its own mechanism. It does not mean the mechanism remains present, is in scope, or is a new finding.

### 2.3 Significant commit lineage

| Commit / PR | Archaeological value | Current disposition |
|---|---|---|
| [`2102107`](https://github.com/asterinas/asterinas/commit/2102107), [PR #1153](https://github.com/asterinas/asterinas/pull/1153) | Added fallible/infallible VFS transfers and the `(error, count)` contract | Count is still lost above OSTD |
| [`dce796`](https://github.com/asterinas/asterinas/commit/dce796), [PR #1156](https://github.com/asterinas/asterinas/pull/1156) | Moved VFS to direct user-memory access; discussion says it did not fix #711 | Direct positive-prefix faults remain possible |
| [`513532fe`](https://github.com/asterinas/asterinas/commit/513532fe), [PR #2230](https://github.com/asterinas/asterinas/pull/2230) | Made vector loops return prior completed entries when a later entry errors | Whole-vector atomicity and faulting-entry count remain unresolved |
| [`1b56a8b`](https://github.com/asterinas/asterinas/commit/1b56a8b), [PR #1598](https://github.com/asterinas/asterinas/pull/1598) | Introduced `ERESTARTSYS`/`SA_RESTART` rewind | Restart gate has no progress value |
| [`18e0eae`](https://github.com/asterinas/asterinas/commit/18e0eae), [PR #1831](https://github.com/asterinas/asterinas/pull/1831) | Prevented exposing internal restart errno | Does not create a regular-file interruption source |
| [`d7cbd0f`](https://github.com/asterinas/asterinas/commit/d7cbd0f), [`de52fd`](https://github.com/asterinas/asterinas/commit/de52fd), [PR #3086](https://github.com/asterinas/asterinas/pull/3086) | Repaired positional capability/error behavior | No pinned positional shared-offset mutation found |
| [`c2b1be`](https://github.com/asterinas/asterinas/commit/c2b1be), [`153e530`](https://github.com/asterinas/asterinas/commit/153e530), [PR #3256](https://github.com/asterinas/asterinas/pull/3256) | Fixed publication of a partially overwritten uninitialized cache page | Warm/dirty and earlier-page prefixes still survive faults |
| [`98e6c27`](https://github.com/asterinas/asterinas/commit/98e6c27), [PR #3310](https://github.com/asterinas/asterinas/pull/3310) | Repaired VirtioFS EOF/commit ordering | Backend-specific context; not a regular ext2/ramfs compensator |
| [`85d2c963`](https://github.com/asterinas/asterinas/commit/85d2c963), [PR #1559](https://github.com/asterinas/asterinas/pull/1559) | Fixed pipe write atomicity | Excluded file type; reference mechanism only |
| [`7f896`](https://github.com/asterinas/asterinas/commit/7f896) | Fixed TCP partial-iovec behavior | Excluded transport; analogous count-accounting evidence only |

Other inspected commits covered null user pointers, zero slices, unseekable offsets, ext2 allocation/rollback, seek behavior, page-cache rewrites, and cross-architecture restart. None compensates for the current combined state machine.

### 2.4 Open PR audit

Six open PRs touched exact target paths: [#3737](https://github.com/asterinas/asterinas/pull/3737), [#3730](https://github.com/asterinas/asterinas/pull/3730), [#3729](https://github.com/asterinas/asterinas/pull/3729), [#3717](https://github.com/asterinas/asterinas/pull/3717), [#3703](https://github.com/asterinas/asterinas/pull/3703), and [#2615](https://github.com/asterinas/asterinas/pull/2615). They address architecture support, VirtioFS mapping, excluded RWF flags, fsync, page batching, and CortenMM, not the combined progress/OFD protocol.

Adjacent open work was also checked:

- [PR #3576](https://github.com/asterinas/asterinas/pull/3576) argues that syscall-layer `EINTR -> ERESTARTSYS` both misses and misclassifies restartable waits. Its tests cover pipes, sockets, poll, and futex, not positive-progress regular-file I/O.
- [PR #3297](https://github.com/asterinas/asterinas/pull/3297) is an ext2 rollback draft but does not preserve user-copy progress or cancel submitted direct I/O.
- [PR #3582](https://github.com/asterinas/asterinas/pull/3582) concerns short FUSE results; it does not fix ext2/ramfs.
- [PR #3481](https://github.com/asterinas/asterinas/pull/3481) concerns excluded append-range atomicity.
- [PR #3720](https://github.com/asterinas/asterinas/pull/3720) concerns excluded parser behavior.

No open PR fixes the in-scope combined state machine at the pin.

## 3. Linux-visible reference contract

The contract was checked against man-pages and Linux v6.16 source, not inferred from Asterinas comments.

| Operation/condition | Linux-visible contract | Primary evidence |
|---|---|---|
| Successful/short `read` | Return bytes read; seekable offset advances by that count | [`read(2)`](https://man7.org/linux/man-pages/man2/read.2.html), [`ksys_read`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L704-L720) |
| Successful/short `write` | Return bytes written; seekable offset follows actual progress | [`write(2)`](https://man7.org/linux/man-pages/man2/write.2.html), [`ksys_write`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L727-L744) |
| User fault after progress | Report a short successful count rather than discard the visible/committed prefix | [`read(2)`](https://man7.org/linux/man-pages/man2/read.2.html), [`write(2)`](https://man7.org/linux/man-pages/man2/write.2.html) |
| Shared OFD scalar/vector I/O | Offset updates are atomic; vector data is one contiguous, non-intermingled block | [`readv(2)`](https://man7.org/linux/man-pages/man2/readv.2.html), [`do_readv`/`do_writev`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L1068-L1106), [`fdget_pos`](https://github.com/torvalds/linux/blob/v6.16/fs/file.c#L1210-L1218) |
| `pread64`/`pwrite64` | Use the supplied position and leave the file offset unchanged | [`pread(2)`](https://man7.org/linux/man-pages/man2/pread.2.html), [`ksys_pread64`/`ksys_pwrite64`](https://github.com/torvalds/linux/blob/v6.16/fs/read_write.c#L752-L802) |
| Signal after transferred data | Return successful progress; restart must not replay it | [`signal(7)`](https://man7.org/linux/man-pages/man7/signal.7.html) |
| Local disk I/O and signals | Disk I/O is not a restartable “slow device” wait in the documented signal rules | [`signal(7)`](https://man7.org/linux/man-pages/man7/signal.7.html) |

Linux implements shared-offset serialization once around the whole scalar or vector syscall. It copies `f_pos` to a local position, invokes the entire VFS operation, and publishes the local position back only on a nonnegative result (`fs/read_write.c:704-744,1068-1106`; `fs/file.c:1210-1218`). Positional calls use a local explicit offset without `fd_pos` (`fs/read_write.c:752-802`).

## 4. Current architecture and atomicity boundaries

### 4.1 Open-file-description ownership

- `InodeHandle` owns `offset: Mutex<usize>` (`kernel/core/src/fs/file/inode_handle.rs:28-35`).
- A fresh open description initializes it once (`inode_handle.rs:71-75`).
- `dup` clones the existing entry’s `Arc<dyn FileLike>` (`kernel/core/src/fs/file/file_table.rs:181-187`).
- Forked tables clone each entry, and `FileTableEntry::clone` clones that Arc (`file_table.rs:117-121,393-399`).
- Shared-table lookup clones the file and releases the table lock before any blocking I/O (`file_table.rs:321-361`).

Therefore the two cooperating threads in the guidance reach the same `InodeHandle` and offset mutex. The file-table lock is not an I/O serialization mechanism.

### 4.2 Operation matrix

| Operation | OFD offset behavior | Backend call boundary |
|---|---|---|
| `read` | Locks `offset`, calls backend, adds successful `len` | `inode_handle.rs:273-290` |
| `write` | Locks `offset`; append may preassign EOF; adds successful `len` | `inode_handle.rs:293-320` |
| `pread64` | Calls `read_at` with explicit offset; no OFD offset access | `syscall/pread64.rs:26-37`; `inode_handle.rs:323-332` |
| `pwrite64` | Calls `write_at` with explicit offset; no OFD offset access | `syscall/pwrite64.rs:26-35`; `inode_handle.rs:334-353` |
| `readv` | Calls scalar `read` once per iovec | `syscall/preadv.rs:134-180` |
| `writev` | Calls scalar `write` once per iovec | `syscall/pwritev.rs:134-175` |
| `lseek` | Uses the same OFD offset mutex | `inode_handle.rs:417-435,590-615` |

Ext2 holds an inode read/write guard through each scalar backend operation (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:20-52,77-96`). Ramfs holds its page-cache mutex through each copy (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-752`). Neither lock spans a vector syscall.

### 4.3 Fallible-copy path

`VmSpace::reader`/`writer` validates that an address range lies in userspace but does not pre-fault or validate every mapping (`ostd/src/mm/vm_space.rs:153-194`). A cooperating thread can also remap a later range after iovec parsing.

The OSTD contract explicitly returns both an error and the bytes copied so far (`ostd/src/mm/io/mod.rs:271-292`). `read_fallible` performs `memcpy`, advances both cursors by the positive prefix, and returns `(PageFault, copied_len)` if incomplete (`io/mod.rs:332-362`). `write_fallible` delegates to the same logic (`io/mod.rs:367-385`).

Kernel conversion discards the count (`kernel/core/src/error.rs:209-219`). Page-cache read and anonymous write propagate that converted error with `?` after mutation (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566,667-699`). Backed write observes the prefix only long enough to update page state, then returns the scalar error (`vmo/mod.rs:702-759`).

## 5. Verified findings

### F1. Positive copy progress can be omitted from result and shared offset

Status: **statically confirmed current behavior; open #711 mechanism**.

#### Read path

1. A regular-file backend calls page-cache `read` with the fallible user `VmWriter` (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-243`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-719`).
2. `read_fallible` copies a positive destination prefix and advances its cursor before returning `(PageFault, n)` (`ostd/src/mm/io/mod.rs:332-362`).
3. Conversion and `?` discard `n` (`kernel/core/src/error.rs:209-213`; `kernel/core/src/vm/page_cache/vmo/mod.rs:548-566`).
4. `InodeHandle::read` returns `EFAULT` before `*offset += len` (`kernel/core/src/fs/file/inode_handle.rs:285-290`).

Outcome classes:

| Copy progress | Syscall result | User buffer | Shared offset |
|---|---|---|---|
| Zero | `EFAULT` | unchanged | unchanged |
| Positive | `EFAULT` | prefix changed | unchanged |
| Complete | byte count | complete | advances by count |

The positive case violates result/copy/offset coupling. This current manifestation differs from the 2024 #711 proof of concept, whose old copied-buffer architecture could advance a backend position without exposing the destination prefix. The issue is historical positive-control evidence; its old exact output must not be projected onto this pin.

#### Buffered write path

For an existing up-to-date or dirty ext2 page, a positive source prefix mutates the cache page and the error arm marks/keeps it dirty (`kernel/core/src/vm/page_cache/vmo/mod.rs:724-751`). Ext2 rollback is a no-op for an in-place range and does not restore overwritten bytes below old EOF (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-218,245-271`). The syscall returns `EFAULT` and `InodeHandle::write` leaves the shared offset unchanged (`inode_handle.rs:308-320`).

The cold full-page overwrite case is a compensating exception. `CommitMode::Overwrite` may allocate an `Uninit` page without reading the backend (`vmo/mod.rs:593-638,1019-1052`); a faulting partial prefix leaves it `Uninit`, so a later read reloads old backend data. That is the case covered by PR #3256. Earlier completed or warm-page effects below old EOF are not restored; effects wholly in an extending range are removed when rollback shrinks the cache and block mappings to old EOF (`ext2/inode/file.rs:204-218`).

For `pread64`/`pwrite64`, the same count loss can make a buffer/file prefix visible while the syscall reports `EFAULT`; the shared OFD offset remains correctly unchanged.

### F2. `readv`/`writev` are not whole-call linearizable

Status: **statically confirmed current behavior; acknowledged interface gap**.

Each `readv` entry invokes `file.read(writer)` independently (`kernel/core/src/syscall/preadv.rs:152-174`); each `writev` entry invokes `file.write(reader)` independently (`kernel/core/src/syscall/pwritev.rs:148-170`). Each scalar call acquires and releases the OFD offset mutex (`kernel/core/src/fs/file/inode_handle.rs:273-320`).

Read witness, initial file `abcdef`, shared offset 0:

1. T1 `readv([{2},{2}])` reads `ab`, advances offset to 2, and releases the lock.
2. T2 `read(fd2, 2)` reads `cd` and advances offset to 4.
3. T1’s second entry reads `ef`, advances offset to 6, and T1 returns 4 with `ab|ef`.

If T1 linearized before T2, T1 would get `abcd`; if T2 came first, T1 would get `cdef`. Neither explains `abef` with T2=`cd`.

Write witness, initial offset 0:

1. T1 `writev(["AA","BB"])` writes `AA` at `[0,2)`.
2. T2 `write("XX")` writes at `[2,4)`.
3. T1 writes `BB` at `[4,6)`.

The file becomes `AAXXBB`; whole-call orders yield `AABBXX` or `XXAABB`.

A later-iovec fault compounds the defect. If entry 1 completes 2 bytes and entry 2 copies/commits a one-byte prefix before faulting, the outer loop suppresses the error because `total_len > 0` and returns 2 (`preadv.rs:165-168`; `pwritev.rs:161-164`). Three bytes may be visible while both the result and shared-offset advance report two.

### F3. Positional I/O exposes the vector split without moving the OFD offset

Status: **combined interleaving confirmed; scalar positional baseline correct**.

`read_at`/`write_at` do not access `self.offset` (`kernel/core/src/fs/file/inode_handle.rs:323-353`). No backend-specific path inspected mutates that field indirectly.

Initial file `abcdef`, offset 0:

1. T1 `readv([{2},{2}])` reads `ab`; shared offset becomes 2.
2. T2 `pwrite64("WXYZ", 4, 0)` replaces `[0,4)` and leaves the shared offset 2.
3. T1’s second entry reads `YZ`; shared offset becomes 4; T1 returns `abYZ`.

T1-before-T2 would return `abcd`; T2-before-T1 would return `WXYZ`. This is a data-linearizability failure caused by F2, not a positional-offset mutation.

The symmetric witness is `pread64(0,4)` between entries of `writev(["AA","BB"])`: it can observe `AAcd`, neither the pre-call nor post-call vector state.

### F4. Ramfs publishes and copies progress independently of its result

Status: **statically confirmed current behavior; runtime tests pending**.

#### Write size before copy

Ramfs locks its page cache, calculates the full requested end, publishes mtime/ctime and any size expansion, resizes the anonymous VMO when extending, and only then performs fallible copy (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:721-752`). There is no error rollback. In-place requests retain the old larger size.

| Copy progress | Result | File size | Data | Shared offset |
|---|---|---|---|---|
| Zero fault | `EFAULT` | `max(old size, requested end)` | old in-place bytes remain; newly exposed gap/tail is zero | unchanged |
| Positive fault | `EFAULT` | `max(old size, requested end)` | prefix visible; uncopied old-range bytes remain; newly exposed tail is zero | unchanged |
| Complete | count | `max(old size, requested end)` | complete requested range | advances by count |

An immediately invalid source pointer can therefore extend a ramfs file while reporting zero progress. A zero-length write has the same publication path: `new_size = offset + 0` and no early return (`ramfs/fs.rs:731-752`). Unlike ext2’s explicit zero-length exits (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:44-47,247-250`), a zero-length ramfs write beyond EOF can return 0 and extend the file.

#### Read beyond logical EOF

Ramfs computes the correct logical `read_len` from metadata but passes the unbounded writer to the page cache (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710`). Page-cache capacity is page-aligned and may exceed EOF (`kernel/core/src/vm/page_cache/mod.rs:181-186,246-282`); VMO read limits against that capacity (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-566`). Ext2 performs the missing `writer.limit(read_len)` (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-243`).

For a one-byte ramfs file backed by a page-sized cache, `read(fd, buf, 2)` can copy two bytes, return 1, and advance the shared offset by 1. It overwrites `buf[1]` outside the returned range. If `buf[1]` faults after the logical byte copied successfully, the syscall returns `EFAULT` and leaves the offset unchanged instead of returning the one-byte short read.

#### Size/data split with positional write

Ramfs read snapshots metadata size before acquiring the page-cache mutex (`ramfs/fs.rs:701-709`). Ramfs write takes the page-cache mutex and then updates metadata/data (`ramfs/fs.rs:727-750`). A positional write can therefore complete between the read’s size snapshot and data copy:

1. File is size 1 with `A`; scalar read of two bytes snapshots size 1.
2. `pwrite64("BC", 2, 0)` sets size 2 and data `BC`, without changing the OFD offset.
3. The read copies `BC` through the page cache but returns stale `read_len = 1` and advances the OFD offset by 1.

No before/after ordering explains buffer `BC`, result 1, and offset movement 1 together.

### F5. Failed `O_APPEND` can move the shared offset without progress

Status: **statically confirmed current behavior; runtime test pending**.

Scalar `write` takes the offset mutex and assigns `*offset = self.path().size()` before the backend call when `O_APPEND` applies (`kernel/core/src/fs/file/inode_handle.rs:308-315`). The backend call uses `?`; on error, the assignment remains and only success-only `*offset += len` is skipped (`inode_handle.rs:317-320`).

The branch is reachable for the in-scope backends: regular ext2 and ramfs opens return no per-open file object, while only devices and named pipes return one (`kernel/core/src/fs/fs_impls/ext2/impl_for_vfs/inode.rs:140-171`; `kernel/core/src/fs/fs_impls/ramfs/fs.rs:260-286,923-929`).

Example: shared position 0, EOF 100, invalid source. The syscall returns `EFAULT` with zero copied/committed bytes, but the shared position becomes 100. With a positive faulting prefix, the position remains at the append start rather than reflecting committed progress.

Linux’s shared write uses a local position and publishes it back to `f_pos` only for `ret >= 0` (`fs/read_write.c:727-744`). Asterinas positional `pwrite64` may choose EOF under `O_APPEND`, matching Linux’s documented positional append quirk, but it still does not mutate `self.offset` (`inode_handle.rs:334-353`).

This finding does not claim anything about concurrent append-range atomicity.

### F6. Fragmented ext2 direct write can leave a live effect after `EFAULT`

Status: **conditional static finding; model/runtime verification pending**.

Preconditions are an `O_DIRECT`, block-aligned, in-place write over at least two mapped physical `IoRange`s, with a user source that faults while copying a later range.

1. Ext2 selects direct dispatch and holds the inode write lock (`kernel/core/src/fs/fs_impls/ext2/impl_for_vfs/inode.rs:35-59`; `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:77-96`).
2. For each mapped range, it copies userspace into a BIO segment and immediately submits asynchronously (`inode/file.rs:365-391`).
3. `Bio::submit` transfers the request to the device queue and records only a completion handle in `IoBatch` (`kernel/core/comps/block/src/bio.rs:100-150`).
4. A later `write_fallible(reader)?` error returns before `io_batch.wait_all()` (`inode/file.rs:389-405`).
5. `IoBatch` has no drop-time wait or cancellation (`kernel/libs/io-util/src/batch.rs:94-165`); the already enqueued BIO remains owned by the device path.
6. Ext2 rollback cannot cancel an in-place submission, and `InodeHandle` returns `EFAULT` without advancing the OFD offset (`ext2/inode/file.rs:204-218,319-321`; `inode_handle.rs:308-320`).

The inode lock is released while an earlier write may still complete. A subsequent operation can begin with an unchanged offset and race in completion order with that unreported effect. Static control flow and ownership support the window; fragmented-layout construction and device-visible ordering were not run in QEMU.

### F7. Positive-progress regular-file restart replay is not reachable on inspected paths

Status: **verified negative at this pin**.

The scalar syscall wrappers map any backend `EINTR` to `ERESTARTSYS` (`kernel/core/src/syscall/read.rs:27-39`; `kernel/core/src/syscall/write.rs:27-39`). Signal handling converts that internal errno to `EINTR`, and with `SA_RESTART` restores the original syscall register and rewinds the instruction pointer (`kernel/core/src/process/signal/mod.rs:54-62,145-158`). The task loop captures the pre-syscall return register and handles signals after syscall dispatch (`kernel/core/src/thread/task.rs:83-105`). The gate itself has no progress value.

However, the required source is absent:

- user-copy failures are `PageFault`/`EFAULT` (`ostd/src/mm/io/mod.rs:357-360`; `kernel/core/src/error.rs:195-205`);
- page locks/writeback use `WaitQueue::wait_until`, whose cancellation closure always succeeds and cannot report interruption (`ostd/src/sync/wait.rs:69-85`; `kernel/core/src/vm/page_cache/cache_page.rs:212-239,316-322,377-385`);
- `IoBatch::wait_all` returns only its I/O error domain (`kernel/libs/io-util/src/batch.rs:147-164`); and
- BIO completion maps only completion, unsupported, no-space, or I/O failure (`kernel/core/comps/block/src/bio.rs:309-323`).

`readv`/`writev` do not perform the scalar `EINTR -> ERESTARTSYS` translation, but the same regular backends do not emit `EINTR` here. Open PR #3576 is generic evidence that restart classification is under redesign, not evidence of a current regular-file replay.

The pinned ext2/ramfs model must disable all interrupt transitions. A reference-only `interruptibleBackend` capability may define `InterruptBeforeProgress -> Restart` for future backend audits, guarded by `RestartRequiresZeroProgress`; that capability is false for the implementation configuration analyzed here.

## 6. Compensating mechanisms and explicit false positives

| Candidate claim | Evidence checked | Disposition |
|---|---|---|
| Duplicating an FD copies an offset value into an independent description | `file_table.rs:181-187,393-399` | False: it clones the same file Arc |
| The shared file-table lock serializes I/O | `file_table.rs:321-361` | False: it releases the lock before blocking file operations |
| Scalar shared-offset operations race at the offset read/update | `inode_handle.rs:273-320` | False for one scalar call: the mutex spans backend I/O and success update |
| A non-append backend error advances the OFD offset by consumed cursor bytes | `inode_handle.rs:285-290,317-320` | False: only `Ok(len)` advances; the resulting bug is unreported effects with no movement |
| `pread64`/`pwrite64` mutate `InodeHandle::offset` | `inode_handle.rs:323-353` | False for ordinary regular files |
| Ext2 rollback restores all overwritten bytes | `ext2/inode/file.rs:204-218` | False: in-place rollback is a no-op; old-range bytes are not restored |
| Every cold ext2 fault publishes its positive prefix | `vmo/mod.rs:724-751,1019-1052` | False: a faulting `Uninit` overwrite page remains unpublished |
| Ramfs’s page-cache mutex makes size+data one atomic snapshot | `ramfs/fs.rs:701-710,727-750` | False: read snapshots metadata before the data lock |
| Ext2 also copies beyond logical EOF | `ext2/inode/file.rs:228-243` | False: it limits the writer to `read_len` |
| Iovec descriptor mutation changes the active vector | `kernel/core/src/util/iovec.rs:79-116` | False: descriptors are copied first; pointed-to mappings/data remain live |
| Typed `read_val`/`write_val` cursor behavior compensates page-cache copy | `ostd/src/mm/io/mod.rs:511-549,789-812` | False path match: typed helpers restore cursors, but page-cache bulk transfer does not use them |
| A signal can currently replay a positive ext2/ramfs buffered prefix | wait/error paths in F7 | False at this pin: no positive-progress `EINTR` source was found |
| The TODO/FIXME comments themselves are findings | vector/append comments | Excluded: only verified Linux-visible consequences are reported |

Historical issues [#1542](https://github.com/asterinas/asterinas/issues/1542)/[#3181](https://github.com/asterinas/asterinas/issues/3181) (sendfile), [#1554](https://github.com/asterinas/asterinas/issues/1554) (pipes), and [#1587](https://github.com/asterinas/asterinas/issues/1587) (futex) were useful mechanism checks but are excluded targets. [#1245](https://github.com/asterinas/asterinas/issues/1245) is parser/resource behavior. [#3257](https://github.com/asterinas/asterinas/issues/3257) is a current page-lock/page-fault deadlock, but it is a separate liveness campaign rather than a result/offset safety transition.

## 7. Handoff recommendations

### 7.1 State to retain

- Per attempt: operation kind, PC, vector index, requested/copied/committed/reported classes, result, explicit offset, attempt identity.
- Shared: OFD offset, offset owner, backend/data owner, file size, symbolic data epoch, page state, pending direct effect.
- Environment: two threads sharing one description, backend mode, user fault position class, `SA_RESTART`, and permitted user-buffer mutation.

### 7.2 Atomicity to preserve or split

- Preserve scalar OFD locking across one backend call.
- Split copy from commit/discard, result publication, and offset update.
- Release OFD/backend serialization between vector entries.
- Split ramfs size snapshot from page-cache copy and size publication from write copy.
- Split direct submit from completion.
- Keep positional OFD-offset behavior atomic and neutral; permit positional data actions at the implementation’s real lock boundaries.
- Keep restart behind a reference-only interruptible-backend capability; disable that capability at this pin.

### 7.3 Verification routing

Model checking has output value for combined interleavings that manual traces do not exhaust:

- later-iovec fault plus a shared-offset competitor;
- an outstanding direct BIO plus a later shared operation.

The positional-between-vector and ramfs size-snapshot witnesses in F3/F4 are already statically answered. They belong in the base spec and regression tests, not §6.1 pending findings.

Directly visible single-path defects should go to focused tests/code review rather than expensive hunt configurations:

- ramfs invalid-source size publication and zero-length extension;
- ramfs copy beyond EOF;
- failed-append OFD offset mutation;
- warm/cold ext2 partial-fault matrix; and
- preserving the fallible-copy count across API layers.

Closed historical bugs are reference pointers, not model-checking targets. A plain recreation of #711 or PR #3256 would not produce new information; the combined open questions above satisfy the output-value litmus.

## 8. Validation status and limitations

- Source pin and tree identity: verified.
- Required files: read completely; adjacent compensating paths traced.
- Git history: 454 commits screened; 87 bug-keyword candidates analyzed; significant diffs read.
- GitHub archaeology: 106 unique issue candidates screened; 31 issue threads and 17 PR threads read deeply; all 129 open PRs inventoried.
- Static call-path claims: re-read and cross-checked at cited lines.
- Linux contract: checked against man-pages and Linux v6.16 source.
- Dynamic tests/QEMU: not run. F1-F5 are direct code-path conclusions; F6 still requires runtime layout/device confirmation.
- Repository source changes: none. Only the two requested files under `.specula-output` were created.

The next phase should consume `modeling-brief.md`; this report is the evidence ledger and should not be treated as a substitute for trace validation or runtime reproduction.
