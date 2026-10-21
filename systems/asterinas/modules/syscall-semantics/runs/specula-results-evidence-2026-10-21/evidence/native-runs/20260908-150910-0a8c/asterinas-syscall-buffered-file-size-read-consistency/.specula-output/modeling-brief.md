# Modeling Brief: asterinas-syscall-buffered-file-size-read-consistency

## 1. System Overview

- **System:** Asterinas, Rust; seven requested anchor files total 7,299 lines.
- **Revision:** `604948581512d83734377974d4c34adb4530f2d7`; all 2,645 exported source blobs match. See [identity receipt](evidence/source-identity.json).
- **Category B (Concurrent / Lock-Free / Runtime):** threads coordinate one inode through locks, local size snapshots, copy progress, and capacity publication; no distributed protocol is involved.
- **Reference:** the selected implementation plus Linux buffered-I/O contracts; no separate reference TLA+ algorithm was supplied.
- **Subject:** `read`/`pread64` versus `ftruncate` and extending buffered `pwrite64`; ramfs, ext2, and exFAT are separate configurations.
- **Architecture:** logical EOF `L`, rounded page-cache bound `C`, initialized contents, and exFAT allocation `A` are distinct (`kernel/core/src/vm/page_cache/mod.rs:132-138,181-186`; `kernel/core/src/fs/fs_impls/exfat/inode.rs:104-110`).
- **Concurrency:** ramfs has separate metadata/cache locks; ext2 holds one inode guard through size/copy; exFAT releases preparation's write guard before reacquiring an upgradeable guard for copy (`ramfs/fs.rs:703-750`; `ext2/inode/file.rs:31,49-50`; `exfat/inode.rs:711-744`).
- **Status:** source analysis and discussion verification only. All proposed executions still need model/guest confirmation; no runtime result is claimed.

## 2. Scenarios

### Scenario 1: saved EOF and actual read progress describe different operations

**Mechanism:** a reader computes its result before acquiring the lock that stabilizes the cache used for copying.
**Evidence:**
- Code: ramfs snapshots size and computes `read_len`, then locks the cache and returns the saved count (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-718`). `Vmo::read` can return success without copying when its capacity is zero (`kernel/core/src/vm/page_cache/vmo/mod.rs:533-538`).
- History: commit `dad56e166` separated ramfs metadata/cache locking; current open [PR #3778](https://github.com/asterinas/asterinas/pull/3778) documents missing EOF copy limits, and [its review](https://github.com/asterinas/asterinas/pull/3778#discussion_r3920838790) also identifies the resize race. This is an unresolved known concern, not a claim of previously unknown history.
- Witness to check: initial `L=C=P`, read `(O=0,N=P)` samples `L`; `ftruncate(0)` completes; read copies `D=0` but returns `P`. Page alignment separates this schedule from the known sequential padding case.
**Affected code paths:** ramfs `read_at`/`resize`/extending `write_at`, VMO read, InodeHandle read and positional-read dispatch (`inode_handle.rs:273-290,323-331`).
**Suggested modeling approach:**
- Variables: original offset `O`, request `N`, sampled `S`, clamped copy offset, computed count `K`, actual delivered prefix `D`, destination bytes, cache owner, reader program counter, controlled shared position.
- Actions: `ObserveEOF`, `AcquireCache`, `CopyRead`, `ReturnRead`; allow shrink or extension before acquisition. Preserve ramfs's original offset clamping and unlimited writer.
- Granularity: keep actual cache copy protected by ramfs's mutex. Ext2 read guard and exFAT upreader block this same interleaving during their copies; do not transplant ramfs locking into those configurations.
**Priority:** High.
**Rationale:** directly observable count/position discrepancy with valid buffers; ordinary interleaving suffices. Also cover growth and under-reporting, while keeping the already documented sequential EOF case test-verifiable.

### Scenario 2: a prepared extension outlives the state it prepared

**Mechanism:** cache/allocation preparation and final logical-size publication occur in separate critical sections, with a saved candidate length used after intervening mutations.
**Evidence:**
- Code: exFAT prepares under `inner.write`, drops it, reacquires `upread`, copies, and unconditionally assigns saved `new_size` (`kernel/core/src/fs/fs_impls/exfat/inode.rs:711-755`).
- History: [issue #3295](https://github.com/asterinas/asterinas/issues/3295) and [PR #3421](https://github.com/asterinas/asterinas/pull/3421) explain page-cache ownership and the exFAT exception. Current `upread` is exclusive against other upreaders/writers (`ostd/src/sync/rwmutex.rs:148-203`); the unlocked interval, not overlapping protected copies, is the question.
- Witness to check: from `L=A=C=P`, writer B prepares `(O=2P,N=P)`, yielding `C=A=3P`; writer A prepares `(O=P,N=P)` while `L=P`, reducing `C` to `2P`, then copies/publishes `L=2P`; B resumes, copies zero, returns `P`, publishes `L=3P`. Settled `L>C` follows (`page_cache/mod.rs:250-278`; `vmo/mod.rs:569-574`).
**Affected code paths:** exFAT `write_at`, public/internal `resize`, PageCache resize, VMO write, later buffered reads.
**Suggested modeling approach:**
- Variables: `L,C,A`, per-writer observed length/candidate end, inode lock mode/owner, program counters, accepted contents and returned/copy counts.
- Actions: `PrepareWrite`, `ReleasePreparation`, `AcquireCopyGuard`, `CopyWrite`, `PublishSavedSize`; competing actions are another extender or `ftruncate`.
- Granularity: preserve the release/reacquire interval. Atomic upgrade from the copy upreader is genuine; replacing the earlier release/reacquire with downgrade would change the implementation.
- Cover both writer completion orders and prepare-then-shrink as well as shrink-before-prepare. Read settled regions after both calls return; retain allowed overlap histories.
**Priority:** High.
**Rationale:** the same protocol can misreport a write and leave later metadata/read disagreement. Two disjoint extending ranges avoid importing append or overlapping-write atomicity.

### Scenario 3: logical length, allocation, and zero-filled contents are not published together

**Mechanism:** a public size operation updates allocation or capacity without establishing the requested logical extent and contents.
**Evidence:**
- Code: exFAT public resize grows neither `C` nor `L`; its helper changes `L` only when cluster count decreases (`kernel/core/src/fs/fs_impls/exfat/inode.rs:286-312,1436-1462`). Same-cluster shrink and extension therefore need separate checks.
- Code: exFAT page loading uses zeros only while page start is beyond current `L`; otherwise it reads backing contents (`:143-167`). Cluster extension updates allocation metadata without clearing data (`exfat/fat.rs:200-248,292-342`). Publishing `L` can change how untouched, absent pages are populated.
- Reference context: historical tail clearing/initialization fixes in `b1cec501d`, `621bda8dd`, and [PR #3256](https://github.com/asterinas/asterinas/pull/3256) already exist. Preserve them; do not create their old behavior as model adversaries.
**Affected code paths:** exFAT resize/allocation/page population, ramfs anonymous zero pages, ext2 sparse block lookup and resize (`ext2/inode/mod.rs:470-481`; `ext2/inode/block_manager/mod.rs:132-156`).
**Suggested modeling approach:**
- Variables: logical bytes versus cache/backing bytes, absent/initialized page state, page size `P`, cluster size `G`, allocation bound `A`.
- Actions: faithfully model public resize's actual branches and backend zero/population decisions. Check same-page, cross-page/same-cluster, and cross-cluster shrink; extension from zero; reads of unwritten gaps and regrown tails.
- Granularity: direct sequential omissions are test-verifiable. Include their real transitions in the shared model without spending an independent hunt on an obvious assignment omission.
**Priority:** High for concrete tests; Medium for additional modeling.
**Rationale:** settled data can disagree with metadata even without a race. A zeroed test disk is insufficient evidence about the content-initialization rule.

### Scenario 4: requested extent is published before copy acceptance is known

**Mechanism:** size preparation, actual copying, accepted page contents, and error/result reporting have different commit points.
**Evidence:**
- Code: ramfs publishes requested `new_size` before cache growth and fallible copy (`kernel/core/src/fs/fs_impls/ramfs/fs.rs:733-750`). ExFAT prepares then skips saved-size publication on copy failure; ext2 attempts rollback before returning (`exfat/inode.rs:715-744`; `ext2/inode/file.rs:193-215,246-271`).
- Code: OSTD advances copy cursors and returns a partial count; kernel error conversion drops that count (`ostd/src/mm/io/mod.rs:332-370`; `kernel/core/src/error.rs:209-219`).
- History: [issue #711](https://github.com/asterinas/asterinas/issues/711) already acknowledges broad partial-copy limitations. `test/initramfs/src/regression/fs/ext2/short_rw.c:16-53` intentionally expects rejection of an uncommitted partial page; it does not establish universal rollback semantics.
**Affected code paths:** user-buffer construction, backend extending writes, initialized versus uninitialized page copy, syscall return and shared-offset update.
**Suggested modeling approach:**
- Variables: requested end, copied count, accepted prefix/page state, error site, published `L/C`, return status. Keep a fault boundary fixed during each attempt.
- Actions: allow only pre-established user-buffer copy failures, not arbitrary errors at every step. Preserve actual backend cleanup and publication; do not equate a copied but rejected uninitialized fragment with committed file data.
- Primary tests: ramfs zero-progress failed extender `(L=P,O=P,N=P)` can leave `L=C=2P`; zero-count `pwrite64(O>L,N=0)` can also extend ramfs/exFAT. Compare accepted extent to a backend-specific reference, not an all-or-nothing assumption.
**Priority:** Medium.
**Rationale:** direct size effects add information beyond the known partial-count limitation. These deterministic cases belong in tests; compose a failure with Scenario 2 only to answer a distinct publication question.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Three separate backend configurations | S1/S2 lock behavior differs | Explicit lock modes and backend-specific operation PCs; one inode per run |
| Local EOF view versus current capacity/progress | S1 | Separate `S,K,O,N,D,L,C`; preserve original/clamped offsets |
| Prepare/copy/publish interval | S2 | Split exFAT actions at real guard release/acquisition |
| Logical bytes and zero-filled holes | S3 | Small tagged byte/page domain; keep allocation separate from contents |
| Reachable copy failure and accepted state | S4 | Fixed source/destination fault boundary; backend-specific page acceptance |
| Controlled offset history | S1/S4 | One known reader position; positional competitors do not change it |

Start with at most three actors and three logical/cache pages; `G=2P` can require four pages of rounded backing capacity. Use aligned mutation endpoints for the initial MC1/MC2 searches. Additional partial-endpoint models must represent the cold-tail backend lock acquisition, including its blocked state (TV7); tests cover partial lengths, warm/cold tails, and zero count. Locks can be abstracted without a weak-memory adversary. Track actual cursor advance: `writer.limit` changes available capacity, so `initial_avail-final_avail` is not delivery (`ext2/inode/file.rs:239-241`; `ostd/src/mm/io/mod.rs:902-924`). Expected results belong in properties, never action guards.

### 3.2 Do Not Model

| What | Why |
|---|---|
| Whole-call snapshots, EOF-at-return, mandatory full reads during overlap | Unsupported oracle; Linux permits shorter/progress-dependent histories |
| Equality of `C` and `L`, or all allocated bytes being initialized | Rounded capacity, allocation, and file contents are different states |
| Closed initialization/tail/decommit defects with reverted guards | Already fixed reference context; no new information |
| Universal error rollback or universal acceptance of copied fragments | S4 has backend-specific acceptance and error paths |
| Vectored I/O, signals/restart, append atomicity, O_DIRECT, mmap/file faults | Explicit scope exclusions; they change the applicable contract |
| Crash durability, pipes, FD publication, SCM_RIGHTS, arithmetic-only or exhaustion campaigns | Explicit scope exclusions, separate subjects |
| Arbitrary device failures or timestamp errors in the initial model | No such adversary is needed for the concrete schedules; ext2 storage-error cleanup remains a qualified separate caveat |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Per-thread local observations | `pc,S,K,O,N,D,outcome` | Retain stale calculated count separately from delivered bytes | 1 |
| Backend lock/publication protocol | `cacheOwner,inodeMode,owner,candidateEnd,L,C,A` | Preserve actual serialization and unlocked preparation interval | 1,2 |
| Abstract logical/cache contents | `logicalBytes,cacheBytes,pageState,G` | Distinguish holes, initialized data, and capacity | 2,3 |
| Copy acceptance/result state | `faultBoundary,copied,accepted,errorSite` | Express operation-specific partial/error behavior | 4 |
| Controlled open-description position | `position,startPosition,operationKind` | Connect results to read versus pread64 offset rules | 1,4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK / LockExclusion | Safety | Bounded domains; preserve each backend's actual mutex/upreader rules | All; model fidelity |
| SuccessfulTransferAccounting | Safety | Successful read has `result=D<=N`; successful write has `0<=result<=D<=N`, with D measured independently of result or final size | 1,2 |
| UnreportedReadSuffixUnchanged | Safety | Successful read does not modify destination beyond its returned prefix, including zero stores | 1 |
| ControlledOffsetAccounting | Safety | Successful read position advances by returned and delivered count; pread64/pwrite64 leave shared position unchanged | 1,4 |
| SettledReadableExtent | Safety | Once mutations settle, every logical region has a valid buffered-read path; do not require `C=L` | 2,3 |
| ExtendersPreserveExtent | Safety | Record each completed positive write's original O and returned k; without truncation, final L covers every historical O+k. Never derive this history from final L | 2 |
| SuccessfulResizeContract / HoleZeros | Safety | Isolated successful resize sets requested `L`; unwritten extension/regrown bytes read zero under settled history | 3 |
| EmptyWriteNoEffect / AcceptedExtent | Safety | Successful zero-count writes do not change size/data; a failed write's extent follows its established acceptance contract | 4 |

No global liveness claim is needed. Test-only blocking concerns are recorded in the audit; do not add fairness assumptions to hide a lock dependency.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | Which current ramfs shrink/growth schedules separate saved read count from delivery, including controlled read offset effects? | SuccessfulTransferAccounting; UnreportedReadSuffixUnchanged; ControlledOffsetAccounting | 1 |
| MC2 | Can exFAT's prepared extension followed by shrink or another extender return more than it copies, regress accepted extent, or leave `L>C` for subsequent reads? | SuccessfulTransferAccounting; ExtendersPreserveExtent; SettledReadableExtent | 2 |

Output-value litmus: MC1 would establish an observable count/position discrepancy for the unresolved lock gap; MC2 would establish an observable returned-count or settled-content discrepancy in the current publication protocol. Neither requires reverting a fix. Known sequential EOF padding and known generic partial-copy behavior are not separate MC hunts.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | Known ramfs/exFAT EOF delivery exceeds reported prefix | Small file, sentinel buffer, pread/read across and at EOF; compare count, actual prefix, and untouched suffix; PR3778 is reference |
| TV2 | exFAT public resize omits logical-size/capacity updates | Valid backend fixture; grow from zero, shrink within cluster and across clusters; fstat plus settled buffered reads |
| TV3 | exFAT untouched extension/hole pages may populate from backing contents after `L` publication | Valid pre-populated subject with nonzero backing bytes; truncate to zero, verify reallocation of its old clusters, pwrite at 2P, read gap; fixture execution remains pending |
| TV4 | Failed ramfs extending pwrite publishes requested extent despite zero accepted bytes | Pre-established inaccessible source, small aligned request; record EFAULT, size, and later valid read; compare Linux ramfs |
| TV5 | Zero-count positional write can enlarge ramfs/exFAT | `pwrite64` with `N=0,O>L`; verify result zero, unchanged shared position, size/content unchanged contract |
| TV6 | Copy-failure outcomes depend on page initialization and prior accepted pages | Stable fault boundary, cold/warm pages, zero-progress and complete-page-prefix cases; distinguish copied/accepted/result/position, no universal rollback oracle |
| TV7 | exFAT cold partial-tail clearing can call its backend while holding the inode write guard (`exfat/inode.rs:1450-1453,151`; `page_cache/mod.rs:250-255`) | Valid pre-existing file with absent tail cache page; bounded completion check for ordinary resize; trace backend read-lock acquisition; no file mapping needed |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | PageCache's VmIo no-short-transfer contract and VMO's capacity-clamped success differ (`ostd/src/mm/io/mod.rs:75-84`; `vmo/mod.rs:533-574`) | Audit caller obligations and result interface; do not assume the trait comment enforces transfer progress |
| CR2 | Resize docs say extension cannot fail although partial-tail clearing is fallible (`page_cache/mod.rs:202-204,250-255`); exFAT ordering comment differs from actual branches (`exfat/inode.rs:138-140`) | Clarify lock/error obligations against actual backend paths; do not inject unreachable failures to prove a prose mismatch |

## 7. Reference Pointers

- Detailed evidence, coverage, exclusions, and source schedules: [analysis-report.md](analysis-report.md); raw commit/issue/PR receipts in `evidence/`.
- All code references are relative to [the pinned source tree](https://github.com/asterinas/asterinas/tree/604948581512d83734377974d4c34adb4530f2d7). Short FS names resolve under `kernel/core/src/fs/fs_impls/`; PageCache/VMO under `kernel/core/src/vm/page_cache/`; InodeHandle under `kernel/core/src/fs/file/`.
- Ramfs: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:695-817`.
- Ext2: `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:22-51,193-272,409-429`.
- ExFAT: `kernel/core/src/fs/fs_impls/exfat/inode.rs:143-167,286-312,643-755,1436-1462`.
- PageCache: `kernel/core/src/vm/page_cache/mod.rs:246-282`.
- VMO: `kernel/core/src/vm/page_cache/vmo/mod.rs:533-755`.
- InodeHandle: `kernel/core/src/fs/file/inode_handle.rs:273-354`.
- Copy progress: `ostd/src/mm/io/mod.rs:332-370`.
- Fully reviewed issue context: [#711](https://github.com/asterinas/asterinas/issues/711), [#2937](https://github.com/asterinas/asterinas/issues/2937), [#3295](https://github.com/asterinas/asterinas/issues/3295). Fixed-only context: [#958](https://github.com/asterinas/asterinas/pull/958), [#3256](https://github.com/asterinas/asterinas/pull/3256), [#3421](https://github.com/asterinas/asterinas/pull/3421). Pending EOF fix: [#3778](https://github.com/asterinas/asterinas/pull/3778).
- Interface references: [read](https://man7.org/linux/man-pages/man2/read.2.html), [pread/pwrite](https://man7.org/linux/man-pages/man2/pread.2.html), [truncate](https://man7.org/linux/man-pages/man2/truncate.2.html), [write](https://man7.org/linux/man-pages/man2/write.2.html). Linux comparison: [v6.12 filemap](https://github.com/torvalds/linux/blob/v6.12/mm/filemap.c), [ramfs file operations](https://github.com/torvalds/linux/blob/v6.12/fs/ramfs/file-mmu.c), [simple write completion](https://github.com/torvalds/linux/blob/v6.12/fs/libfs.c).
