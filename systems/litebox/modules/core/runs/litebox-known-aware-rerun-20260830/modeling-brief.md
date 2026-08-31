# Modeling Brief: microsoft/litebox

Analyzed repository head: `49f7231eef1f53836648c88bf9897d116fb73a96` (`main`, verified equal to `origin/main` on 2026-08-29).

## 1. System Overview

- **System**: LiteBox, a Rust library OS and Linux-compatible shim; about 94 KLOC Rust, with about 24 KLOC in the concurrency-heavy scope reviewed here.
- **Category**: **Category B (Concurrent / Lock-Free / Runtime)**. Guest tasks run on host threads and share descriptor, VM, filesystem, event, and process state through `Arc`, custom mutex/RwLock types, and atomics.
- **Reference semantics**: Linux fd/open-file-description lifetime, virtual-memory operations, path/CWD identity, thread creation, futex wait/wake, and layered filesystem behavior.
- **Key deviations**: a raw-fd table sits above typed shared entries; host mappings, Vmem records, and runtime-patch records are separate; file-backed mapping initialization drops the Vmem lock; CWD is stored as a normalized pathname; platform thread creation transfers an `InitThread` object through platform-specific code.
- **Concurrency boundary**: there is no single kernel-style lock covering each logical syscall. Several syscalls resolve or publish state in stages, allowing another thread to close/reuse an fd, unlink/recreate a path, replace/unmap a mapping, or fail a platform spawn between stages.

## 2. Scenarios

### Scenario 1: Path Snapshot Versus Stable Namespace Identity

**Mechanism**: A pathname walk returns an object handle or normalized path, but later mutation or relative lookup does not confirm that the namespace link or object identity is still the same.

**Evidence**:
- Historical: filesystem/path divergence is the densest history group (for example PRs #37, #51, #62, #253, #326, #887, #1107, #1113, and #1231).
- Code analysis: `Resolver::parent_dir_and_name` expects the backend to retain atomicity across walk-and-mutate (`litebox/src/fs/resolver.rs:214-232`), but InMem releases its walk locks before creation (`litebox/src/fs/in_mem.rs:249-293,478-505`) and permits concurrent parent removal (`:556-570`).
- Code analysis: `Context.cwd` stores only `Arc<ResolvedPath>` (`litebox/src/fs/resolver.rs:50-105`); relative syscalls turn it back into a path string (`litebox_shim_linux/src/syscalls/file.rs:205-228`). Deletion and recreation can therefore rebind the CWD to a different directory object.

**Affected code paths**: `Resolver::{open,mkdir,parent_dir_and_name}`, `InMem::{walk_directories,create_file_at,mkdir_at,rmdir_at}`, `Task::{sys_chdir,resolve_path}`.

**Suggested modeling approach**:
- Variables: `namespace`, `nodeAlive`, `walkedParent`, `cwdNode`, `cwdPath`, `pc`.
- Actions: split path walk, final create/mkdir, rmdir, recreate, chdir validation, CWD publication, and relative lookup.
- Granularity: preserve the lock-release boundary between walk and final backend mutation.

**Priority**: High
**Rationale**: Two unfiled current-head identity failures, strong Linux-reference semantics, repeated historical path bugs, and a small finite-state model.

### Scenario 2: Raw FD Slots Versus Open-File-Description Identity

**Mechanism**: A logical syscall or bookkeeping field repeatedly uses an integer fd or per-fd metadata where Linux semantics require one captured, shared open-file-description identity.

**Evidence**:
- Historical: fixed pipe/dup races (PRs #801 and #1182), open issues #1170/#1172, open epoll PR #1230, and raw-fd patch-state issue #821 establish recurring fd/OFD confusion.
- Code analysis: fallback file `mmap` re-resolves the numeric fd once per page (`litebox_shim_linux/src/syscalls/mm.rs:270-305`); large reads, vectored I/O, and `sendfile` similarly re-resolve fds across chunks (`litebox_shim_linux/src/lib.rs:516-541,588-628`; `litebox_shim_linux/src/syscalls/file.rs:598-681,896-956,1098-1115`). Close/reuse can bind later chunks to a different object.
- Code analysis: directory position uses fd-local `Diroff` metadata (`litebox_shim_linux/src/syscalls/file.rs:2571-2648`), although `Descriptors::duplicate` promises shared offsets and intentionally does not copy fd-local metadata (`litebox/src/fd/mod.rs:70-105`).
- Code analysis: closed epoll targets remain keyed by `(raw_fd, Weak<TypedFd> address)` and are not replaced after raw-fd reuse (`litebox_shim_linux/src/syscalls/epoll.rs:81-110,232-265,327-340`).

**Affected code paths**: chunked read/readv/preadv/writev/pwritev/sendfile/mmap, `getdents64`/directory `lseek`, epoll add/close/reuse.

**Suggested modeling approach**:
- Variables: `fdSlot`, `fdGeneration`, `ofd`, `ofdRefs`, `opOFD`, `dirOffset`, `epollInterests`, `pc`.
- Actions: capture fd, close/reuse slot, process one chunk, dup, read/store directory offset, add/close epoll interest.
- Granularity: split at every raw-fd lookup and every load/produce/store of shared bookkeeping.

**Priority**: High
**Rationale**: Multiple new live consumers plus the repository's strongest recurring concurrency mechanism.

### Scenario 3: Mapping Generation Versus Stale Auxiliary State

**Mechanism**: Host mappings, Vmem records, and runtime-patching plans are updated under different locks and can refer to different incarnations of the same address range.

**Evidence**:
- Historical: PR #488 fixed an earlier fixed-address replacement window; PR #669 explicitly acknowledges the CoW map/register split at `litebox_shim_linux/src/syscalls/mm.rs:234-266`.
- Current code: `maybe_patch_on_mprotect_exec` snapshots file mappings, releases the cache lock, then acts on the snapshot without generation revalidation (`litebox_shim_linux/src/syscalls/mm.rs:482-535,768-789`). Concurrent `sys_munmap` removes the mapping and cache interval at `:376-411`.
- Current code: partial unmap deletes an entire overlapping tracking tuple rather than retaining unaffected prefix/suffix intervals (`litebox_shim_linux/src/syscalls/mm.rs:396-410`).

**Affected code paths**: `sys_mmap`, CoW registration, `sys_mprotect`, `maybe_patch_on_mprotect_exec`, `maybe_patch_exec_segment`, `sys_munmap`, `Vmem::protect_mapping`.

**Suggested modeling approach**:
- Variables: `hostMap`, `vmemMap`, `patchIntervals`, `mapGeneration`, `patchPlan`, `pc`.
- Actions: map host pages, register Vmem, collect patch plan, unmap/replace/split, validate generation, patch, protect.
- Granularity: host operation, bookkeeping publication, plan collection, and plan application are separate actions.

**Priority**: High
**Rationale**: Address reuse plus stale local views can mutate or validate the wrong mapping; generation modeling is a direct Category B fit.

### Scenario 4: Clone Publication and Ownership Transfer Before Commit

**Mechanism**: Thread creation publishes caller-visible state or transfers ownership before all local validation and the fallible platform-spawn step have committed.

**Evidence**:
- Historical: PR #366 fixed parent/child TID ordering; open PR #1155 shows quiescence declared before final guest-memory accesses.
- Code analysis: `parent_tid` is written before clone3 stack validation (`litebox_shim_linux/src/syscalls/process.rs:685-697`).
- Code analysis: process attachment precedes `spawn_thread` (`litebox_shim_linux/src/syscalls/process.rs:700-733`); the SNP provider converts `ThreadStartArgs` to a raw pointer before a fallible host call and has no error-side reclamation (`litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:250-275`).

**Affected code paths**: `Task::do_clone`, `ThreadState::new_thread`, `Process::{attach_thread,detach_thread,kill_other_threads}`, SNP `spawn_thread`.

**Suggested modeling approach**:
- Variables: `threads`, `threadCount`, `nextTid`, `parentTid`, `initOwner`, `spawnResult`, `pc`.
- Actions: validate, publish parent TID, attach, transfer init ownership, spawn success/failure, rollback, quiesce.
- Granularity: each publication/ownership transition is separate.

**Priority**: High
**Rationale**: A failed platform operation can leave permanent non-quiescent state; rollback is finite and model-checkable.

### Scenario 5: Futex Wake Quota Includes an Unvalidated Waiter

**Mechanism**: A waiter becomes selectable before confirming that the futex word matches, so `wake(1)` can spend its quota on a thread that will return mismatch while a validated waiter remains blocked.

**Evidence**:
- Historical: repeated futex/wakeup fixes (#75, #86, #303, #335) and open PRs #820/#1228 show this state machine is error-prone.
- Code analysis: `wait` inserts before the value check (`litebox/src/sync/futex.rs:96-113`); `wake` selects only by address/bitset and stops at its quota (`:145-166`). `FutexEntry` has no validated phase (`:42-47`).

**Affected code paths**: `FutexManager::{wait,wake}`, `LoanList::{extract_if,remove_node}`.

**Suggested modeling approach**:
- Variables: `waiterPhase`, `futexValue`, `waitQueue`, `wakeBudget`, `selected`.
- Actions: insert-unvalidated, compare, validate/block, select, return-mismatch, wake.
- Granularity: insertion and comparison must remain separate.

**Priority**: Medium
**Rationale**: Strong SC-interleaving question distinct from PR #1228's already-public weak-memory mechanism; focused testing is also cheap.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Namespace node identity | Scenario 1: detached-parent creation and CWD rebinding | Path-to-node map plus stable node references and split walk/commit actions |
| FD slot and OFD identity | Scenario 2: repeated raw lookup and fd-local shared state | Per-slot generations, captured `opOFD`, aliases, shared offsets |
| Mapping generations | Scenario 3: stale patch plans and interval drift | Generation-tagged host/Vmem/patch state with split collect/apply |
| Clone transaction | Scenario 4: publication and ownership before spawn commit | Explicit prepare/publish/attach/transfer/commit/rollback PCs |
| Futex validation phase | Scenario 5: wake quota can select a non-waiter | `InsertedUnvalidated` and `ValidatedWaiting` phases |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Exact `do_dup_inner` #1170, LinuxKernel TLB #671, overlay/resolver coarse locks | Already filed or source-documented; this rerun adds no new consequence at those sites |
| Exact PR #1155 and PR #1228 counterexamples | Active public fixes/reproductions; rerunning them would add no system information |
| Exact two-CoW race from PR #669 / prior confirmation | Keep as Scenario 3 evidence; model the unaudited stale-plan/generation question instead |
| Root metadata bypass, resolver chmod/chown TOCTOU, 9P ownership limitation | Explicitly discussed in PR #1231; known technical debt |
| Rust provenance/aliasing (PR #1010), integer overflow prototype #678, allocator #1222 | Miri, static review, or focused tests are more direct |
| Pure coarse-lock performance, 9P spin transport, and unsupported features | Performance/feature scope without a new safety or liveness question |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Namespace identity | `namespace`, `nodeAlive`, `walkedParent`, `cwdNode`, `cwdPath` | Distinguish path strings from directory objects | 1 |
| Descriptor identity | `fdSlot`, `fdGeneration`, `ofd`, `opOFD`, `ofdRefs` | Bind a logical operation to one OFD across reuse | 2 |
| Shared OFD consumers | `dirOffset`, `epollInterests` | Capture alias-shared position and lifecycle cleanup | 2 |
| Mapping generation | `hostMap`, `vmemMap`, `patchIntervals`, `mapGeneration`, `patchPlan` | Reject stale auxiliary work | 3 |
| Clone transaction | `threads`, `threadCount`, `parentTid`, `initOwner`, `spawnResult` | Require failure atomicity and ownership rollback | 4 |
| Waiter lifecycle | `waiterPhase`, `waitQueue`, `wakeBudget`, `selected` | Count only validated waiters | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| NamespaceIsATree | Safety | Every linked non-root node has one live parent binding | Standard, 1 |
| ReachableCreate | Safety | A successful pathname create leaves the created node reachable from the walked parent | 1 |
| CwdIdentityStable | Safety | Deletion/recreation of a pathname does not silently change the CWD object | 1 |
| SingleBindingPerFdSlot | Safety | Each raw fd slot has at most one current generation/OFD | Standard, 2 |
| OperationBindsOneOFD | Safety | All stages of one syscall use the OFD captured at entry | 2 |
| AliasOffsetsShared | Safety | All aliases of one OFD observe one directory/file position | 2 |
| NoStaleEpollInterests | Safety | Last-reference close leaves no permanent interest for that identity | 2 |
| MappingRangesDisjoint | Safety | Current Vmem ranges do not overlap | Standard, 3 |
| HostVmemAgreement | Safety | Host and Vmem agree on generation and permissions for each live mapping | 3 |
| NoStalePatchPlan | Safety | A patch plan applies only to the mapping generation it observed | 3 |
| ThreadCountMatchesAttachments | Safety | `threadCount` equals committed attached threads | 4 |
| CloneFailureAtomic | Safety | Failed clone publishes no child and retains no transferred init ownership | 4 |
| WakeCountsValidatedWaiters | Safety | Wake return count includes only validated waiters selected for completion | 5 |
| ValidWaiterEventuallyReturns | Liveness | A selected validated waiter eventually leaves the waiting phase | 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-FS-1 | Can `rmdir(parent)` interleave between parent walk and `create_file_at` so both succeed but the new file is unreachable? | ReachableCreate | 1 |
| MC-FS-2 | Can unlink/recreate of `cwdPath` redirect relative operations to a new node? | CwdIdentityStable | 1 |
| MC-FD-1 | Can close/reuse between chunks make one read/readv/sendfile/mmap consume more than one OFD? | OperationBindsOneOFD | 2 |
| MC-VM-1 | Can a patch plan collected before unmap/replacement act on a missing or newer mapping? | NoStalePatchPlan, HostVmemAgreement | 3 |
| MC-CLONE-1 | Can platform spawn failure retain an attachment or transferred init object? | ThreadCountMatchesAttachments, CloneFailureAtomic | 4 |
| MC-FUTEX-1 | Can an unvalidated waiter consume `wake(1)` while a validated waiter remains blocked? | WakeCountsValidatedWaiters | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-FD-1 | Duplicated directory fds do not share `Diroff`; concurrent calls can duplicate batches | Dup a directory fd; consume/seek through one alias; assert the other observes the shared position; add a barrier test |
| TV-FD-2 | Closed/reused epoll targets accumulate stale `interests` entries | Repeated eventfd add/close/reuse against one epoll instance; assert stale-interest count remains bounded |
| TV-VM-1 | Partial munmap drops tracking for the unaffected suffix | Track two pages, unmap one, and assert the surviving interval remains patchable/tracked |
| TV-CLONE-1 | Invalid clone3 stack args still modify `parent_tid` | Use `PARENT_SETTID` with a deterministic post-publication validation failure and assert no caller-memory mutation |
| TV-FS-1 | `chdir` accepts a directory lacking target search permission | Create a non-searchable directory as another user and require `EACCES` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-FD-1 | Long-running syscall loops repeatedly accept raw fd integers | Audit all chunk loops and pass one captured typed/OFD handle through the operation |
| CR-VM-1 | Patch cache represents intervals as unsplittable tuples with no generation | Introduce interval split/invalidation and generation recheck contracts |
| CR-FS-1 | `WalkingDirHandle` atomicity promise is not expressed in the Backend trait | Decide whether linked-state validation or a retained mutation guard is required |
| CR-CLONE-1 | `ThreadProvider::spawn_thread` ownership-on-error is implicit | Specify and audit ownership/rollback semantics for every platform implementation |

## 7. Reference Pointers

- **Full audit trail**: `analysis-report.md` in this directory.
- **Key source files**: `litebox/src/mm/{mod.rs,linux.rs}`, `litebox/src/fd/mod.rs`, `litebox/src/fs/{resolver.rs,in_mem.rs,overlay.rs}`, `litebox/src/sync/futex.rs`, `litebox_shim_linux/src/syscalls/{mm.rs,file.rs,epoll.rs,process.rs}`.
- **Historical/public context**: issues [#1170](https://github.com/microsoft/litebox/issues/1170), [#1172](https://github.com/microsoft/litebox/issues/1172), [#671](https://github.com/microsoft/litebox/issues/671), [#821](https://github.com/microsoft/litebox/issues/821); PRs [#488](https://github.com/microsoft/litebox/pull/488), [#669](https://github.com/microsoft/litebox/pull/669), [#810](https://github.com/microsoft/litebox/pull/810), [#1155](https://github.com/microsoft/litebox/pull/1155), [#1195](https://github.com/microsoft/litebox/pull/1195), [#1228](https://github.com/microsoft/litebox/pull/1228), [#1230](https://github.com/microsoft/litebox/pull/1230), [#1231](https://github.com/microsoft/litebox/pull/1231).
- **Reference implementation semantics**: Linux `fs_struct`/CWD path identity, fd/open-file-description rules, mmap locking, `copy_process`, and futex wait/wake behavior.
