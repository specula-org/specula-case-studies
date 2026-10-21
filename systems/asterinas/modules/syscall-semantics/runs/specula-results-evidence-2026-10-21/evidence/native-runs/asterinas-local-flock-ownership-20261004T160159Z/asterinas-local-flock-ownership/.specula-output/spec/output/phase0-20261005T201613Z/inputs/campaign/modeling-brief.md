# Modeling Brief: asterinas-local-flock-ownership

## 1. System Overview

- **System:** Asterinas local inode flock, Rust, 3,406 lines across the 12 core files read completely. Source is `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`.
- **Category B (Concurrent / Lock-Free / Runtime):** this is a mutex-based ownership and reference-lifetime protocol with cross-thread notification, parking, and destruction. It is not a distributed protocol or a lock-free implementation.
- **Reference:** generic local flock in Linux v6.16.5, `4645fefac0b24d509b962c096b0327e87f34b1d2`. Its ramfs/tmpfs file operations do not override flock (`fs/ramfs/file-mmu.c:41-50`, `mm/shmem.c:5229-5242`).
- **Architecture:** independent opens create different OFDs, dup aliases share one OFD, and one inode's `FsLockContext` owns a mutex-protected `FlockList` (`syscall/open.rs:102-126`, `file_table.rs:181-187`, `inode_ext.rs:10-32,73-82`).
- **Differences to preserve:** Asterinas checks conflicts before replacing an owner's old mode. Unlock temporarily upgrades Weak owners while holding the list Mutex (`flock.rs:114-131,164-181`).
- **Scope:** one established ordinary ramfs/tmpfs file, valid SH/EX/UN with optional NB, independent opens, dup, controlled conversions, close, syscall references, temporary owner references, and waiter retry. Source paths below are relative to `kernel/core/src/` unless prefixed `ostd/`; `flock.rs`, `file_table.rs`, and `inode_handle.rs` mean `fs/file/`, and `inode_ext.rs` means `fs/vfs/fs_apis/`.
- **Status:** code analysis completed for handoff to independent analysis review. Linux controls, Asterinas tests, models, instrumentation, traces, TLC, and runtime confirmation are `NOT_RUN`. This incorporates prior assessment. No new defect is required to continue after the required reviews, and no AST ID is allocated here.

## 2. Scenarios

### Scenario 1: OFD identity and compatible ownership

**Mechanism:** numeric descriptors and file objects have different lifetimes, while conflicts exclude only the same file allocation.
**Evidence:** `file_table.rs:137-205,341-361` and `flock.rs:29-59,122-127` preserve shared-Arc aliases and one lock per owner. Linux `fs/locks.c:465-474,939-948` uses the file object. Historical `ce2af1eb0570` introduced flock and `b9ce3e64ad57` introduced the borrow-or-clone lookup. The full discussion of [#3178](https://github.com/asterinas/asterinas/issues/3178) retracts a related shared-table suspicion after identifying FD reuse in the test.
**Affected code paths:** `sys_openat`, `do_open`, `Path::open`, `sys_dup`, `duplicate_entry`, `get_file_fast!`, `sys_flock`, and `FlockList::try_set_lock`.
**Suggested modeling approach:** use `fdOwner`, fresh bounded OFD IDs, `heldMode`, and request ownership captured at lookup. Model dup as an alias, not a new owner. Open creates a fresh OFD for the same inode. Retain the same-owner exclusion and grant/replacement under the list Mutex.
**Granularity:** descriptor-table mutations and shared-table capture are serialized by the table lock. Separate capture from the later flock action. A borrowed lookup is allowed only when no concurrent table mutator exists.
**Priority:** Medium. **Rationale:** these are the foundation for every other scenario; no new ownership-exclusion defect survived inspection. Cover FL-C01/C02 and FD reuse without changing an already captured request's OFD.

### Scenario 2: Conversion retention changes later conflicts

**Mechanism:** Asterinas rejects or registers a conflicting conversion before removing its own old mode, whereas fixed Linux removes a different old mode before checking other owners.
**Evidence:** `flock.rs:115-124` versus Linux `fs/locks.c:1096-1137`. The behavior exists in the flock origin `ce2af1eb0570`; it was supplied as FL-SQ-1 and independently revalidated here. No matching persistent record or reviewed pending conversion fix was found.
**Affected code paths:** `sys_flock`, `InodeHandle::set_flock`, `try_set_lock`, `set_lock`, and old-item Drop.
**Suggested modeling approach:** retain `heldMode[ofd]` separately from `requestedMode[thread]`, with NB/blocking request state and blocker queues. In the implementation, conflict leaves the old SH in place. In the Linux comparison, remove a differing old mode before conflict/EAGAIN or registration. Do not silently repair the implementation model.
**Granularity:** conflict search, registration, and successful replacement share the list Mutex. Linux's delete/check/insert shares its inode spinlock; a competing grant cannot be invented between those steps. A conflict that returns/waits opens the next interleaving window.
**Priority:** High. **Rationale:** FL-C05 has a sequential discriminator; FL-C06 can expose a conversion wait cycle. They are one mechanism, not two automatically distinct defects. Sole-owner conversions and EX-to-SH replacement notification remain required FL-C04 coverage.

### Scenario 3: Registration, notification, and retry against a new blocker

**Mechanism:** a waiter subscribes to one conflicting item, and release or replacement only makes retry possible; the next conflict may involve another owner.
**Evidence:** `flock.rs:69-82,114-157,164-181`, `ostd/src/sync/wait.rs:88-148,209-282`, and `ostd/src/task/scheduler/mod.rs:441-493`. Historical `e5fd8e747745` fixed the old infinite/stale-condition path described in [#1474](https://github.com/asterinas/asterinas/issues/1474); [#1497](https://github.com/asterinas/asterinas/issues/1497) and [#1261](https://github.com/asterinas/asterinas/issues/1261) explain compensations against false lost-wake claims. These fixed histories are context only.
**Affected code paths:** `try_set_lock`, `FlockItem::drop`, `unlock`, `Pause::pause_until`, `wait_until_or_cancelled`, `Waker::{wake_up,do_wait,close}`, and scheduler park/enqueue.
**Suggested modeling approach:** represent per-item queue identity, per-thread `pc`, registered blocker, `notified`, and closed wakers. Removal and replacement wake the old queue. Expired-owner removal also invokes item Drop. A request clone shares the installed queue, so request destruction may notify without releasing ownership. Repeated entries/notifications are not separate grants.
**Granularity:** registration cannot race a list mutation inside the same list critical section. Split list-unlock, sleep preparation, accepted wake, notification consumption, and retry. Drain releases its queue spinlock before waking. Preserve the scheduler's runqueue bridge (`sched/sched_class/mod.rs:215-242,255-258,404-414`).
**Priority:** High. **Rationale:** FL-C07/C08/C09 exercise release on either side of actual registration, migration between two SH blockers, and losing a wake race. No additional lost-wake defect is asserted. Keep these interactions even if both source leads are refuted.

### Scenario 4: Last descriptor removal is not final OFD release

**Mechanism:** a dup, in-flight syscall, or pending close object can keep the file alive after an FD is removed.
**Evidence:** `file_table.rs:196-205,274-298,341-361`, `syscall/close.rs:22-35`, and `inode_handle.rs:537-541`. Linux `fs/file.c:1153-1182`, `include/linux/file.h:60-64,83`, and `fs/file_table.c:439-457,515-542,567-570` distinguish fd removal, reference put, and final cleanup. Historical `c320552ae108`, `8600278a5f34`, and `e631da203c2c` establish the current cleanup design; [#506](https://github.com/asterinas/asterinas/issues/506) rejects premature descriptor-based cleanup.
**Affected code paths:** `get_file_fast!`, `sys_close`, `close_file`, `ClosedFile::drop`, syscall completion, and `InodeHandle::drop`.
**Suggested modeling approach:** separately count descriptor, syscall, pending-ClosedFile, and temporary references. Capture transfers/creates a syscall reference as appropriate. Close transfers the descriptor reference into ClosedFile before dropping it. The last strong drop starts final destruction; it does not instantly remove the list entry.
**Granularity:** release the FD-table lock before dropping ClosedFile. Split final-drop initiation, acquisition of the list Mutex, cleanup, and destructor completion. Permit transient expired Weak entries during pending destruction.
**Priority:** High. **Rationale:** FL-C03 and FL-C10 establish alias preservation and completion of a previously captured blocking syscall after close. No new defect is claimed for deferred final release itself. A post-close syscall need not return EBADF if lookup already succeeded.

### Scenario 5: Temporary ownership invokes cleanup while cleanup holds the Mutex

**Mechanism:** an unlock scan's temporary upgraded Arc can become the last strong reference and synchronously call back into the same nonrecursive list Mutex.
**Evidence:** `flock.rs:40-41,164-181`, `inode_handle.rs:537-541`, `ostd/src/sync/mutex.rs:30-70,113-116`, and installed Rust `alloc/src/sync.rs:2132-2143,2850-2855,2896-2898,3299-3327`. Historical post-file-table-lock cleanup fixes do not address this distinct guard. This is supplied FL-SQ-2, source-revalidated rather than runtime-reproduced.
**Affected code paths:** `unlock(A)` retaining B's item, `Weak::upgrade(B)`, concurrent `close(B)`, temporary Arc drop, `InodeHandle::drop(B)`, and nested `unlock(B)`.
**Suggested modeling approach:** add explicit `listOwner`, unlock-scan position, per-thread temporary owner, strong-reference components, and a nested destructor continuation. Allow B's last descriptor/ClosedFile reference to drain between successful upgrade and temporary drop. Derive re-entry from reaching zero; do not inject a synthetic deadlock action.
**Granularity:** retain list ownership across each scan step, while other threads may close descriptors. On last temporary drop, the same thread enters B's destructor before its outer retain closure and guard can finish. Mutex acquisition waits even when the requester owns the outer guard.
**Priority:** High. **Rationale:** the source provides a concrete in-scope path to blocked cleanup. FL-C11 must prove the reference window on SMP >= 2. FL-C12 retains an extra alias, closes before upgrade, and closes after scan completion as negative controls. A watchdog alone establishes nothing about this mechanism.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| All five scenarios as one local-inode protocol | Their ownership, conversion, queue, and lifetime states interact. | One base implementation model with scenario-specific bounded exploration, not disconnected bug demonstrations. |
| Three independent OFDs, at least one alias, and enough threads for capture/close/unlock | C01/C05/C08 need three owners; C10/C11 need concurrent reference changes. | Start with 3 OFDs and 3 threads; use a 4-thread configuration if a fixture requires a separate controller. Use finite operation budgets, not artificial queue overflow. |
| First-conflict queue selection and all Drop notifications | Scenario 3's compensation changes which histories are possible. | Preserve list order or an equivalent explicit first-blocker selection. Explain any duplicate-entry abstraction and keep accepted wakes distinct from grants. |
| Reference ownership and destructor PCs | Scenarios 4/5 are hidden by an FD-count-only model. | Track each reference source and each guard held at last drop; no model action may make an expired owner live again. |
| A fixed Linux source oracle plus later controls | Scenario 2 is a Linux-visible behavioral comparison. | Keep implementation and oracle semantics distinct. Execute C01-C05 controls before accepting their observable comparison as runtime evidence. |
| Conditional progress in a finite fixture | Scenarios 2/3/5 need more than incompatible-grant safety. | Assume issued operations receive execution opportunities and fixture owners execute their promised unlocks. Stop new competing acquisitions. Do not assume an already blocked recursive lock can become enabled. |

### 3.2 Do Not Model

| What | Why |
|---|---|
| POSIX/fcntl locks, remote/mandatory locks, special files | Different contracts. Read range-lock cleanup only to establish the ClosedFile chain and separate Mutex. |
| Unlink/rename, mounts, mmap/SCM_RIGHTS references, exec, process exit, malformed flags, OOM | Explicit campaign exclusions. Keep stable ordinary files and valid operations. |
| Arbitrary signals, restart, timeout cancellation | Excluded from the initial fixture. Retain actual waiter closure on return and the production retry loop. |
| FIFO grants, global fairness, fixed completion latency, wake-as-reservation | Neither the code nor the fixed reference promises them. Use fixture-conditional progress only. |
| Reverting old fixes, weakened memory-order adversaries, reduced-width queue wrap | Historical fixes are context, not targets. [#3283](https://github.com/asterinas/asterinas/issues/3283) acknowledges signal/restart queue growth; it does not establish a lost wake in this bounded signal-free fixture. |
| Allocator identity reuse or all of the Rust memory model | Stable bounded OFD IDs and correct Arc/Weak primitives suffice for these source-grounded lifetime questions. Do not call this a weak-memory proof. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| OFD capture and aliases | `fdOwner`, `requestOwner`, `heldMode` | Separate descriptors from incompatible ownership. | 1, 4 |
| Conversion before/after conflict policy | `requestedMode`, `requestKind`, comparison-mode state | Preserve Asterinas retention and the fixed Linux removal oracle. | 2 |
| Per-blocker retry | `itemQueue`, `registeredOn`, `notified`, `closed`, `pc` | Capture notification before sleep, blocker migration, and request/item Drop. | 3 |
| Explicit release lifetime | `fdRefs`, `callRefs`, `closedRefs`, `tempRefs`, `destroyPC` | Separate last FD, last strong reference, and completed cleanup. | 4, 5 |
| Guard ownership and callback continuation | `listOwner`, `scanIndex`, `tempOwner`, `outerPC` | Derive a recursive list wait from production destruction. | 5 |

## 5. Proposed Invariants

| Property | Type | Description | Targets |
|---|---|---|---|
| `CompatibleOwners` | Safety | Distinct granted OFDs coexist only when both modes are SH. | 1-3 |
| `UniqueOwnerItem` | Safety | At most one stored flock item belongs to an OFD; dup does not create a second owner. | 1, 2 |
| `CapturedOwnerStable` | Safety | FD removal or reuse does not change an in-flight request's captured OFD. | 1, 4 |
| `ReferenceAccounting` | Safety | All modeled strong references have owners; upgrade cannot resurrect a zero count; destruction begins only at zero. | 4, 5 |
| `WakeRequiresRetry` | Safety/action contract | A wake changes notification/runnable state; only a successful conflict check grants ownership. | 3 |
| `NoOrphanedRetry` | Safety plus conditional progress | After removal/replacement and its notifications finish, a live blocked request retains a notification or a reachable registration/retry path. Account for notifications still being drained. | 3, 4 |
| `ConversionOracle` | Sequential comparison | In C05, after A's failed EX conversion and B's unlock, C's EX probe matches the fixed Linux history. Do not require retaining A's SH. | 2, FL-TV-1 |
| `ConvertersDrain` | Fixture-conditional liveness | With only the two SH converters and release after each grant, conversion does not leave both permanently waiting. | 2, FL-MC-1 |
| `NoRecursiveListWait` | Safety diagnostic | A destructor does not wait for the same list Mutex still held by its own outer unlock continuation. | 5, FL-MC-2 |
| `FinalReleaseCompletes` | Fixture-conditional liveness | After remaining external references drain, scheduled final cleanup can finish and remove expired ownership. | 4, 5 |

These are proposed obligations, not checked properties. A zero-strong-count item is allowed while its destructor waits for the Mutex. Likewise, a closed waker may remain queued. Do not reject these intermediate states with overly strong invariants.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation if the source history is realized | Scenario |
|---|---|---|---|
| FL-MC-1 / FL-SQ-1 | Can two independently opened SH owners converting to EX retain both SH locks and form a permanent wait cycle in the finite release-on-success fixture? | `ConvertersDrain`. Linux's removal path permits one converter to proceed. | 2 |
| FL-MC-2 / FL-SQ-2 | Can a temporary upgraded owner become the last reference during unlock and block its destructor on the outer list guard? | `NoRecursiveListWait`, `FinalReleaseCompletes`. | 5 |

Both are source-supported questions still requiring model and runtime validation. Neither recreates a closed fix, and neither reserves a persistent issue ID. An empty eventual MC finding set must not suppress the protocol model or remaining case coverage.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| FL-TV-1 | Observable failed-conversion retention, the same mechanism as FL-MC-1. | C05: A/B SH, A EX\|NB -> EAGAIN, B UN, C EX\|NB. Fixed Linux predicts C success; pinned Asterinas source predicts EAGAIN. Record actual kernels/filesystems. |
| FL-TV-2 | Runtime reachability of FL-MC-2, not a separate defect. | C11/C12: capture successful Weak upgrade, the descriptor/ClosedFile drop, last temporary drop, held guard, destructor entry, and nested lock attempt. Instrumentation must not clone B for logging. |

All C01-C12 remain required protocol controls/traces, including the non-defect scenarios. Runtime concurrency claims require actual SMP >= 2 and observed registration/reference windows. Preserve partial traces. A userspace ready flag or watchdog expiry is insufficient.

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| FL-CR-1 | The local successful request's Drop drains a queue outside the list Mutex; awakened contenders may re-enqueue against the still-held item (`flock.rs:69-82,124-157`, `ostd/src/sync/wait.rs:119-131`). | Audit repeated-drain work and scheduling impact without presuming a latency violation. Preserve it as allowed behavior. No additional MC hunt or confirmed defect is justified yet. |

## 7. Reference Pointers

- [Analysis report](analysis-report.md) provides coverage counts, source histories, explicit exclusions, the C01-C12 case matrix, and evidence paths. [Root audit](analysis-evidence/root-audit.md), [ownership audit](analysis-evidence/ownership/), and [waiter audit](analysis-evidence/waiter/) retain the parallel review results.
- [Contracts](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/flock/contracts.md) fix source questions and Linux expectations. [Input hashes](analysis-evidence/input-hashes.json) verified all 30 listed files; [preparation verification](analysis-evidence/preparation-verified.json) matched both source copies, guidance, and configuration.
- Linux sources are under `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`. Installed Arc source is `/home/chin39/.rustup/toolchains/nightly-2026-07-21-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/alloc/src/sync.rs`; record the actual future build toolchain separately.
- The [resource policy](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json) requires the controller's shared heavy-stage allocation, TLC <= 4G/2 workers, and the documented memory checks before heavy work. Native workers must not recursively launch the pipeline or reacquire controller-held locks.
- Before any verification rerun after changing model/configuration, TraceSpec/interpretation, oracle assumptions, or harness/instrumentation semantics, preserve old/new bytes, hashes, diff, reason, and triggering evidence. Obtain an independent exact-version review and close material findings before rerunning. If unavailable, return preserved evidence and an incomplete status to the controller for continuation of this same campaign. This gate also applies inside Phase 3 correction loops.
