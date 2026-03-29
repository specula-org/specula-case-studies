# Analysis Report: jonhoo/left-right

## 1. Codebase Overview

- **System**: left-right — Read-write separation concurrency primitive
- **Language**: Rust, ~2170 LOC total, ~1780 LOC core (`src/`)
- **Repository**: https://github.com/jonhoo/left-right (449 commits)
- **Version analyzed**: 0.11.7
- **Dependencies**: `slab`, `crossbeam-utils`, `loom` (test)

### Core Files

| File | Lines | Role |
|------|-------|------|
| `src/write.rs` | 793 | WriteHandle: oplog, publish, wait, swap, try_publish, take |
| `src/aliasing.rs` | 430 | Aliased<T,D>: memory de-duplication across two copies |
| `src/lib.rs` | 301 | Absorb trait, constructors (new, new_from_empty) |
| `src/read.rs` | 249 | ReadHandle: enter protocol, epoch management, clone |
| `src/read/guard.rs` | 126 | ReadGuard: RAII guard, epoch restore on drop, map/try_map |
| `src/read/factory.rs` | 39 | ReadHandleFactory: Send+Sync handle distributor |
| `src/sync.rs` | 22 | Loom compatibility layer for atomics |
| `src/utilities.rs` | 20 | Test-only CounterAddOp |

### Architecture

Two copies of data `T`: `r_handle` (readers access via `AtomicPtr`) and `w_handle` (writer mutates directly). The writer maintains an operational log (oplog) of mutations. On `publish()`:

1. Writer waits for all readers to leave old `w_handle` (epoch tracking)
2. Writer applies oplog to stale `w_handle` (`absorb_second` for old ops, `absorb_first` for new ops)
3. Writer atomically swaps `r_handle`↔`w_handle` via `AtomicPtr::swap(Release)`
4. Writer snapshots all reader epochs (for next wait)

Readers: per-reader epoch counter (AtomicUsize). Odd = reading, even = idle. Reader protocol: bump epoch (AcqRel) → fence(SeqCst) → load pointer (Acquire). Guard drop: bump epoch back (AcqRel, only on last guard).

### Concurrency Model

- **Single writer**: `WriteHandle` is `!Sync`, enforced at type level
- **Multiple readers**: Each `ReadHandle` is `!Sync` (per-thread), has its own epoch counter
- **Shared state**: `AtomicPtr<T>` (pointer to read copy), `Epochs` slab (Mutex-protected)
- **Synchronization**: Epoch-based quiescence detection, SeqCst fences for cross-variable ordering

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits analyzed | 449 |
| Bug-fix commits deeply read | 21 |
| GitHub issues deeply read (left-right) | 51 |
| GitHub issues deeply read (evmap) | 12 |
| PRs deeply read | ~15 |
| Confirmed bugs | 14 |
| False positives excluded | 7 (user error, feature requests) |

### 2.2 Historical Bug List

#### Critical Severity

| # | Ref | Summary | Root Cause |
|---|-----|---------|------------|
| 1 | `ce1082d` | Use-after-free from temporary Box::from_raw | Temporary Box ownership allowed panic to trigger double-free |
| 2 | `1066dc9` | Memory ordering violation: Release insufficient for cross-variable ordering | Epoch store and pointer swap needed SeqCst, not Release |
| 3 | `6529287` | Compiler reordering: pointer load before epoch update | Missing compiler barrier between epoch update and pointer read |
| 4 | `d8a6729` | ReadHandle incorrectly marked Sync | Data race from concurrent epoch mutations |
| 5 | Issue #75 | Missing Send/Sync bounds allow Rc<Cell> across threads | AtomicPtr doesn't propagate T's thread safety bounds |
| 6 | Issue #74 | Box<T> aliasing is UB under Stacked Borrows | ShallowCopy for Box created aliased exclusive pointers |
| 7 | `6a678e7` + `338ef95` | Use-after-free from non-deterministic HashBag drain order | Duplicate values + non-deterministic iteration → mismatched drops |

#### High Severity

| # | Ref | Summary | Root Cause |
|---|-----|---------|------------|
| 8 | `02eb63b` | Deadlock: reader clone + writer refresh | Lock ordering: clone holds epoch, needs mutex; writer holds mutex, needs epoch |
| 9 | `73a6729` | Writer permanently blocked by panicking reader | Panic skipped epoch parity restore |
| 10 | `110632c` | Resource leak from Clone types with destructors | ShallowCopy + Clone + mem::forget leaked Drop resources |
| 11 | `ec87c59` (Issue #24) | Memory leak when WriteHandle dropped | AtomicPtr doesn't drop its pointee |
| 12 | `c57756c` | Use-after-free from non-deterministic retain predicate | Predicate returns different results for same element across copies |

#### Medium Severity

| # | Ref | Summary | Root Cause |
|---|-----|---------|------------|
| 13 | `78cf502` (Issue #53) | Unbounded epoch slot growth | Epoch slots never reclaimed on ReadHandle drop |
| 14 | `de8664a` | Complex reader protocol hard to verify | Double-pointer-read protocol simplified to single read |
| 15 | `50d931b` | SeqCst atomics split into Release + SeqCst fence | Correctness-neutral but fence placement critical |
| 16 | `6e935f2` | Fat pointer comparison in Predicate PartialEq | vtable pointer differs across compilation units |
| 17 | `a05f8b0` | Double eviction from stale w_handle read | Reading from w_handle after swap returned stale data |

### 2.3 Bug Hotspot Analysis

| File/Module | Bug Count | Types |
|-------------|-----------|-------|
| Epoch/ordering logic (read.rs + write.rs) | 7 | Ordering, deadlock, panic safety |
| Aliasing/ShallowCopy (aliasing.rs) | 5 | UB, drop correctness, non-determinism |
| Handle lifecycle (read.rs drop, write.rs drop) | 3 | Leak, deadlock |
| Send/Sync bounds | 2 | Data race |

---

## 3. Deep Analysis Findings

### 3.1 write.rs Analysis

**Memory ordering**: All atomic operations verified correct. Key properties:
- `update_and_swap()`: Release swap at line 421, SeqCst fence at line 428, Acquire epoch reads at 430-432. **Correct.**
- `wait()`: Acquire epoch loads at line 265. Even-epoch skip (line 261) correct including wraparound. Slab reuse handled by mutex exclusion during wait. `starti` restart optimization verified safe. **Correct.**
- `try_publish()`: Inline epoch check equivalent to single-pass wait. Mutex held across check and swap. **Correct.**

**take_inner() fence placement**: The SeqCst fence at write.rs:178 is after `wait()`, but its comment says "ensure epoch reads aren't reordered before swap." The epoch reads happen inside `wait()`, before the fence. The fence is **redundant but harmless** — its stated purpose doesn't match its position.

**First-publish optimization**: Verified correct. When `first=true`, ops go directly to w_handle via `absorb_second` (write.rs:519-528). First publish just swaps pointers. Second publish calls `sync_with` to synchronize stale copy. No ops lost or double-applied.

**Developer signals**: TODO at write.rs:475 acknowledges `raw_write_handle()` should return `Option<&mut T>`. FIXME at sync.rs:9 about loom fence limitation.

### 3.2 read.rs + guard.rs Analysis

**Enter protocol**: Verified correct. AcqRel epoch bump (line 169) → SeqCst fence (line 172) → Acquire pointer load (line 175). The three-case safety argument in the comments (lines 140-166) is sound.

**Nested enter**: When `enters != 0`, pointer load reuses existing epoch. Safe because writer cannot swap while this reader's epoch is odd. Verified.

**ReadGuard::map/try_map**: `mem::forget(orig)` after copying handle state is correct — prevents double epoch decrement. `try_map` failure path correctly drops the original guard.

**Potential deadlock in clone**: ReadHandle::clone (line 74-78) locks the epochs mutex. If a reader holds a ReadGuard (epoch is odd) and calls `handle.clone()` while the writer is in `publish()` (holding the mutex, waiting for this reader's epoch):
- Writer holds mutex, waits for reader's epoch
- Reader holds epoch, waits for mutex
- **Deadlock** (same-thread scenario, since ReadHandle is !Sync)

This is a **real potential deadlock** under contention. Mitigated by the fact that it requires the clone and publish to overlap in time, but it's not prevented at the type level.

### 3.3 aliasing.rs Analysis

**`alias()` (line 180-189)**: `ptr::read` on `MaybeUninit<T>` is well-defined. No Stacked Borrows violation since only `&T` is exposed while aliases exist. **Sound** given the safety contract.

**`change_drop()` (line 211-218)**: Takes `self` by value, does `ptr::read` to create new `Aliased<T, D2>`, but does NOT call `mem::forget(self)`. When `D::DO_DROP == true`, self's Drop runs `drop_in_place`, destroying T. The returned value then holds a dangling T. **Latent unsoundness** in the DoDrop→anything direction. The safety doc at line 209 ("always safe to change from dropping to non-dropping") is **misleading**. In practice, only NoDrop→DoDrop is used (confirmed in tests/deque.rs:91), so this is not currently exploitable.

**Send/Sync bounds**: `Send` requires `T: Send + Sync` (correct — aliased T is read from multiple threads). `Sync` requires `T: Sync` (correct — `&Aliased` gives `&T`). Verified.

### 3.4 Cross-File Interaction Analysis

**Publish protocol end-to-end**: The two SeqCst fences (writer write.rs:428, reader read.rs:172) participate in a single total order. Either (a) writer sees reader's epoch bump, or (b) reader sees writer's pointer swap. Both cases are safe. **Verified correct.**

**take_inner() safety**: After the NULL swap (write.rs:170) and wait (write.rs:175), a reader that entered between the last publish's epoch snapshot and the NULL swap is correctly handled: the SeqCst fence from the last publish's `update_and_swap` synchronizes with the reader's SeqCst fence in `enter()`, ensuring the writer's epoch snapshot captured the reader's odd epoch. **Verified correct (subtle but sound).**

**Loom testing gap** (sync.rs:6-17): All `fence(SeqCst)` calls are downgraded to `fence(Acquire)` under loom. This means loom **cannot verify** the SeqCst ordering that the correctness argument depends on. This is the most significant testing gap. Referenced as FIXME with loom issue tokio-rs/loom#117.

### 3.5 Epoch Wraparound

The even/odd invariant is preserved across `usize` wraparound (`MAX` is odd, `MAX+1 = 0` is even). The equality check in `wait()` could theoretically false-match after 2^64 increments (liveness issue, not safety), which is physically impossible. **Not a real concern.**

---

## 4. Bug Families

### Family 1: Memory Ordering Protocol (HIGH)

**Mechanism**: The epoch-based reader/writer synchronization requires SeqCst fences on both sides to establish a total order between operations on different atomic variables (epoch counter vs pointer). Weaker orderings allow reorderings that break the protocol.

**Evidence**:
- Historical: 4 rounds of ordering fixes (`6529287` asm barrier → `1066dc9` SeqCst atomics → `de8664a` simplified protocol → `50d931b` SeqCst fences)
- Code: SeqCst fences at write.rs:428 and read.rs:172 are **the** correctness linchpin
- Gap: sync.rs:9 FIXME — loom downgrades SeqCst to Acquire, making the core ordering property untestable
- Issue #17: comprehensive loom testing remains incomplete

**Affected code paths**: `ReadHandle::enter()`, `WriteHandle::publish()`, `WriteHandle::try_publish()`, `WriteHandle::take_inner()`

**Assessment**: The current ordering appears correct (verified by manual reasoning), but has never been machine-verified. 4 historical ordering bugs demonstrate this is the highest-risk area. TLA+ model checking with an explicit memory ordering model could provide the first machine verification.

**Priority**: HIGH

### Family 2: Aliased Value Drop Correctness (HIGH)

**Mechanism**: The two-copy architecture requires that `absorb_first` and `absorb_second` produce identical mutations. Non-deterministic trait implementations (Hash, Eq, Ord) or incorrect drop behavior cause the copies to diverge, leading to use-after-free or double-free of aliased values.

**Evidence**:
- Historical: `6a678e7` + `338ef95` (HashBag drain order mismatch with duplicates)
- Historical: `c57756c` (retain made unsafe due to non-deterministic predicates)
- Historical: Issue #74 (Box aliasing UB), PR #83 (Aliased redesign)
- Historical: evmap #1 (non-deterministic PartialEq → segfault)
- Code: aliasing.rs:211-218 — `change_drop()` missing `mem::forget(self)`, DoDrop→anything unsound
- Design: `Absorb` trait safety contract is unenforceable at the type level

**Affected code paths**: `Absorb::absorb_first`, `Absorb::absorb_second`, `Aliased::alias`, `Aliased::change_drop`, `Aliased::drop`

**Assessment**: 5+ historical bugs in this family. The `Aliased<T,D>` redesign (PR #83) addressed Box UB but the fundamental challenge — ensuring deterministic `absorb_*` — remains. Model checking can verify that the protocol correctly propagates identical operations to both copies, but the non-determinism risk is in user-provided trait impls, not the protocol itself. The `change_drop()` missing `mem::forget` is a latent code bug.

**Priority**: HIGH (for the determinism protocol), LOW (for Aliased implementation bugs — code-review-only)

### Family 3: Reader Lifecycle and Liveness (MEDIUM)

**Mechanism**: Reader creation (clone), destruction (drop), and epoch registration interact with the writer's epoch-checking through a shared Mutex. Incorrect interaction causes deadlock or resource leaks.

**Evidence**:
- Historical: `02eb63b` (clone deadlock), `73a6729` (panic blocks writer), `78cf502` (epoch slot leak)
- Code: ReadHandle::clone while holding ReadGuard + concurrent publish → potential deadlock
- Code: ReadHandle::drop assertion enters==0 (defense-in-depth)

**Affected code paths**: `ReadHandle::clone`, `ReadHandle::drop`, `ReadHandleFactory::handle`, `WriteHandle::wait`

**Assessment**: All historical bugs are fixed. The remaining clone+guard deadlock requires specific timing but is not prevented at the type level. Model checking can explore the reader creation/destruction lifecycle interleaved with writer operations.

**Priority**: MEDIUM

### Family 4: Pointer Swap / Publish Protocol (MEDIUM)

**Mechanism**: The publish protocol (wait → apply oplog → swap → snapshot epochs) must maintain the invariant that the writer never modifies data being read. The `try_publish` and `take_inner` paths are variants that must provide identical guarantees.

**Evidence**:
- Historical: `d21b680` (wait before swap, not after)
- Code: `try_publish` (write.rs:309-335) — novel non-blocking path, verified correct
- Code: `take_inner` (write.rs:149-199) — NULL swap, verified correct but subtle
- Code: write.rs:178 — misplaced fence comment (redundant, harmless)

**Affected code paths**: `WriteHandle::publish`, `WriteHandle::try_publish`, `WriteHandle::take_inner`, `WriteHandle::drop`

**Assessment**: Current code verified correct by manual reasoning. The `try_publish` path is the newest addition (PR #120, released v0.11.6) and has the least testing history. Model checking can verify all three publish variants provide identical safety guarantees.

**Priority**: MEDIUM

### Family 5: Send/Sync Trait Bounds (LOW — fixed)

**Mechanism**: AtomicPtr doesn't propagate Send/Sync bounds from T, allowing types like Rc<Cell<i32>> to be shared across threads if handle types don't add manual bounds.

**Evidence**:
- Historical: Issue #75 (fixed in v11 rewrite), `d8a6729` (ReadHandle !Sync)
- Historical: evmap #12 (ReadHandleFactory bounds, still open in evmap)
- Code: Current bounds verified correct (read.rs:53, aliasing.rs:226-237)

**Assessment**: Fixed in current left-right. Not suitable for TLA+ modeling (type system concern, not protocol logic).

**Priority**: LOW (already fixed)

---

## 5. Open Issues and Unresolved Concerns

1. **Loom testing gap** (Issue #17, sync.rs:9): SeqCst fences untestable under loom. The core correctness property has never been machine-verified.

2. **ReadHandle::clone deadlock**: Clone while holding ReadGuard + concurrent publish creates a deadlock cycle. Not prevented at the type level. Requires specific timing but is theoretically possible.

3. **Aliased::change_drop() missing mem::forget**: DoDrop→anything direction is unsound. Only NoDrop→DoDrop is used in practice, so currently unexploitable.

4. **No rollback** (Issue #77): Cannot discard uncommitted operations. Design discussion ongoing.

5. **evmap ReadHandleFactory bounds** (evmap #12): Still open in evmap, though fixed in left-right itself.
