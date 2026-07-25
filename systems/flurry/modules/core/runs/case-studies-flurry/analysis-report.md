# Analysis Report: jonhoo/flurry

## 1. Codebase Overview

- **System**: flurry — Rust port of Java's `java.util.concurrent.ConcurrentHashMap`
- **Language**: Rust, 8208 LOC total (3552 in map.rs, 1628 in node.rs)
- **Commits**: 488
- **GitHub**: jonhoo/flurry
- **Reclamation**: `seize` crate (epoch-based, formerly crossbeam-epoch)

### Core Files
| File | LOC | Purpose |
|------|-----|---------|
| `src/map.rs` | 3552 | HashMap: put, get, remove, transfer, resize, treeify |
| `src/node.rs` | 1628 | BinEntry, Node, TreeNode, TreeBin (tree R/W lock) |
| `src/raw/mod.rs` | 325 | Table: bin array, moved forwarding, find dispatch |
| `src/iter/traverser.rs` | 320 | Iterator: table traversal with stack for resize |
| `src/reclaim.rs` | 170 | Atomic/Shared wrappers over seize primitives |
| `src/map_ref.rs` | 306 | Ergonomic wrapper that pins guard internally |
| `src/set.rs` | 610 | HashSet built on HashMap |

### Concurrency Model
- **Readers**: Lock-free via atomic loads + epoch-based guard protection
- **Writers**: Per-bin locking via `parking_lot::Mutex` on first node of each bin
- **Resize**: Cooperative — any inserting thread can help transfer bins
- **Tree bins**: Custom read-write lock (lock_state bits: READER=4, WRITER=1, WAITER=2)
- **Count**: Single `AtomicIsize` (Java uses sharded CounterCells)

## 2. Bug Archaeology

### 2.1 Git History Mining

**Total bug-fix commits analyzed**: 24

| Commit | Summary | Root Cause | Component | Severity |
|--------|---------|------------|-----------|----------|
| `bfbb375` | Drop crash on null table/bins | Missing null checks in Drop impl | map/drop | High |
| `cdb8e5c` | Deadlock: lock guard held through put→transfer | Java synchronized scope mismatch | map/put,transfer | Critical |
| `e5e0a6b` | Transfer run-bit: last entry skipped | Off-by-one in run optimization | map/transfer | High |
| `a9c6890` | Use-after-free: refs not tied to &self lifetime | Loose lifetimes allowed map drop while refs live | map/drop | Critical |
| `c08e0b9` | Remove loaded value from wrong node (head vs matched) | Copy-paste error: head used where n needed | map/remove | High |
| `051ca79` | put() returns value at wrong node | Same head-vs-matched-node confusion | map/put | High |
| `2a5bd25` | Node#find always returned first entry | Pointer to self instead of matched node | node/find | Critical |
| `e54f12e` | resize_stamp wrong on 64-bit | 32-bit Java constants used for 64-bit isize | map/resize | Critical |
| `f0d7cf2` | Unsound: arbitrary user Guard accepted | No validation Guard's collector matches map | map/all | Critical |
| `3753520` | Global collector requires 'static K+V | Non-'static values freed while references exist | map | Critical |
| `44820e3` | Hide foot-gun with_collector API | Overly permissive API undermined #46 fix | map/API | Medium |
| `12bcddc` | replace_node didn't return old value | old_val only set in removal branch | map/replace_node | Medium |
| `9e31633` | Replace incorrectly decremented count (#69) | Missing check for replace vs remove | map/replace_node | High |
| `54b82cd` | Count underflow panic (#86) | Unsigned AtomicUsize for counter that can go negative | map/add_count | Medium |
| `2a904cf` | Memory leak on failed no_replacement insert | Value never freed when insert declined | map/put | Medium |
| `52ffd22` | Use-after-free in TreeBin waiter (#84) | Waker freed while another thread dereferences it | node/TreeBin | Critical |
| `f97487d` | Panic on Moved/Tree bin in treeify_bin (#83) | treeify_bin called outside lock; bin could change | map/treeify | Medium |
| `f5322c8` | Missing early return in tree put no_replacement (#90) | Missing return in tree-bin code path | map/put | Medium |
| `eb6290d` | Guard check was actually disabled | check_guard had been commented out as TODO | map/check_guard | Critical |
| `f704581` | Guard equality used == instead of ptr_eq | Wrong comparison + clone didn't preserve collector | map/check_guard | High |
| `4c0b1d7` | Stacked borrows violation in put | Miri-detected UB: deref before retire | map/put | Critical |
| `a94060a` | Unsafe cast in defer_drop_without_values | Missing safety docs on raw pointer cast | node/TreeBin | Low |
| `13e1047` | set_ref::take lifetime not tied to self | Potential dangling reference from anonymous lifetime | set_ref | Medium |
| `fcb7dcc` | ASAN crash from should_panic doctest | Test infrastructure interaction | map/tests | Low |

### 2.2 GitHub Issues (30 deeply read)

**Total issues**: ~50, **Deeply read**: 30, **Confirmed bugs**: 12, **False positives**: 2

| Issue | Title | Status | Severity | Component |
|-------|-------|--------|----------|-----------|
| #98 | Unsoundness in HashMap::clear | Fixed (#102) | Critical | map/drop |
| #90 | HashMap enters unreachable code in try_insert | Fixed (#91) | High | map/put |
| #86 | Tree bin subtract with overflow | Fixed | High | node/TreeBin, count |
| #84 | Segfault in concurrent_tree_bin | Fixed (52ffd22) | Critical | node/TreeBin |
| #83 | Treeifying a Moved entry | Fixed (f97487d) | High | map/treeify |
| #69 | Replace incorrectly decrements count | Fixed | Medium | map/replace_node |
| #46 | Unsound: arbitrary user Guards accepted | Fixed | Critical | map/reclamation |
| #29 | resize_stamp positive (should be negative) | Fixed (e54f12e) | High | map/resize |
| #115 | Memory usage grows unbounded | Open | Medium | reclamation |
| #12 | Missing reservation-based methods | Open (design) | Medium | map/put |
| #11 | Missing sharded counters | Open (perf) | Low | map/count |
| #34 | Needs loom testing | Open | N/A | testing |

### 2.3 Bug Hotspot Analysis

| File | Bug-fix commits | Key bug areas |
|------|----------------|---------------|
| `src/map.rs` | 12 | put, replace_node, transfer, treeify_bin, drop |
| `src/node.rs` | 4 | TreeBin lock, find, waiter lifecycle |
| `src/raw/mod.rs` | 2 | Table::find, drop_bins |
| `src/reclaim.rs` | 1 | Guard validation |

## 3. Deep Analysis

### 3.1 Transfer Off-By-One (NEW FINDING)

**File**: `src/map.rs:710`
**Java reference**: `ConcurrentHashMap.java:2430`

After claiming a range of bins via CAS on `transfer_index`:
- **Java**: `i = nextIndex - 1` (points to last bin in claimed range)
- **Rust**: `i = next_index` (points ONE PAST the claimed range)

**Impact**: When `next_index == n` (table length), the Rust code sets `i = n`, which immediately satisfies `i >= n` at line 716, entering the finishing check prematurely. The thread either (a) becomes the finishing thread and re-scans all bins, or (b) decrements size_ctl and returns without processing its claimed range.

**Correctness**: NOT a data loss bug. The finishing thread's sweep (lines 764-772) sets `i = n` and then decrements through all bins, re-checking each one. Bins that were already transferred (Moved) are skipped. The protocol is self-healing.

**Performance**: Helper threads that are not the finishing thread claim a range but return without doing work. The finishing thread serially re-processes all bins. This defeats the purpose of cooperative resizing.

**Classification**: Performance issue, model-checkable (can verify the finishing sweep always covers all bins).

### 3.2 TreeBin Read-Write Lock: Waiter Use-After-Free (FIXED)

**File**: `src/node.rs:352-407`
**Issue**: #84, Fix: `52ffd22`

The TreeBin uses a custom read-write lock with thread parking. The original code freed the waiter handle immediately upon lock acquisition. A reader thread that loaded the waiter handle for notification could then access freed memory.

**Fix**: Changed to `defer_destroy` (now `retire_shared`) for deferred deallocation.

**Current code (line 386)**: `unsafe { guard.retire_shared(waiter) };`

**Residual concern**: The waiter is stored as an `Atomic<Thread>` (line 232). The writing thread stores a `Shared::boxed(current(), collector)` at line 399. After acquiring the lock, it swaps the waiter to null (line 366) and retires it. Between the swap and the retire, another thread could have called `unpark()` on the handle. The current code handles this correctly because `retire_shared` defers the drop.

### 3.3 Count Can Go Negative (KNOWN)

**File**: `src/map.rs:95,1134-1141`
**Issue**: #86

The element count is a single `AtomicIsize`. Since count updates happen outside the bin lock (after the locked critical section), this sequence is possible:

1. Thread A removes key K, exits lock, paused before `add_count(-1)`
2. Thread B inserts key K, exits lock, paused before `add_count(1)`
3. Thread C removes key K, calls `add_count(-1)`: count goes from 1 to 0
4. Thread A calls `add_count(-1)`: count goes from 0 to -1
5. Thread B calls `add_count(1)`: count goes from -1 to 0

The `len()` method (line 362-368) clamps negative counts to 0. This is the same behavior as Java ConcurrentHashMap which uses `long` internally and clamps to `int` range.

**Impact**: `len()` may return slightly inaccurate values during concurrent operations. Not a correctness issue for the data structure itself, but callers relying on exact counts will see transient inaccuracies.

### 3.4 Memory Reclamation Lifecycle (CRITICAL AREA)

Multiple historical bugs relate to memory reclamation:
- **#46**: External guards bypass collector association, enabling use-after-free
- **#98**: `clear()` unsoundness when K/V are non-'static
- **a9c6890**: References could outlive the map due to loose lifetime bounds
- **3753520**: Non-'static values freed while references held via global collector
- **#115**: Memory growth under certain web server patterns (open)

**Current state**: The `check_guard` function (map.rs:342-347) validates that guards belong to the map's collector. The `Collector::ptr_eq` check prevents the #46 attack. The 'static requirement was removed with the seize migration (#102).

### 3.5 Treeify Race Window

**File**: `src/map.rs:1942-1943`

`treeify_bin` is called AFTER dropping the bin lock (line 1854 drops `head_lock`, then 1942 checks `bin_count >= TREEIFY_THRESHOLD`, then 1943 calls `treeify_bin`). This means between dropping the lock and calling `treeify_bin`, another thread could:
- Transfer the bin (making it Moved)
- Remove nodes (reducing count below threshold)
- Treeify the same bin

**Fix** (f97487d): `treeify_bin` now handles `Moved` and `Tree` entries gracefully instead of panicking. It re-acquires the bin lock and re-checks the head.

**Current correctness**: Safe but potentially wasteful. A treeify attempt on a Moved or already-Tree bin is a no-op.

### 3.6 value.store vs value.swap in replace_node

**File**: `src/map.rs:2497-2500`

When replacing a value in `replace_node`, the code uses `store` instead of `swap`:
```rust
n.value.store(Shared::boxed(nv, &self.collector), Ordering::SeqCst);
```

Compare with `put` (line 1812) which uses `swap`:
```rust
let now_garbage = n.value.swap(value, Ordering::SeqCst, guard);
```

Both are correct under the bin lock. The old value is loaded at line 2488 and retired at line 2634. Since the bin lock prevents concurrent writes, the loaded value is guaranteed to still be current at the time of the store.

**Classification**: Code-review-only. Not a bug, but a defensive programming inconsistency.

### 3.7 Missing ReservationNodes

**Files**: `src/map.rs:834,1782,2085`
**Issue**: #12 (open since Jan 2020)

Java ConcurrentHashMap uses ReservationNodes as placeholders during `computeIfAbsent` to:
1. Reserve a bin slot before computing the value
2. Prevent deadlocks when the compute function recursively accesses the map

Flurry does not implement `computeIfAbsent` or ReservationNodes. The `compute_if_present` method exists but works differently (it takes the bin lock, then calls the remapping function while holding it).

**Risk**: If a user calls `compute_if_present` with a function that accesses the same map, they will deadlock (parking_lot Mutex is not re-entrant for the same bin, or will wait indefinitely for a different bin that's being transferred).

### 3.8 Developer Signals (TODOs/FIXMEs)

| Location | Signal | Implication |
|----------|--------|-------------|
| map.rs:20 | `TODO: use ISIZE_BITS` | MAXIMUM_CAPACITY hardcoded to 1<<30 |
| map.rs:630 | `TODO: see #29` | resize_stamp concern (fixed but comment remains) |
| map.rs:1135 | `TODO: implement CounterCell` | Single atomic counter — scalability bottleneck |
| map.rs:1150 | `TODO: use the resize hint` | Resize hint ignored, may cause unnecessary resizes |
| map.rs:1205 | `TODO: figure out why rs + 2` | Incomplete understanding of Java protocol |
| map.rs:2206,2548 | `TODO: Is this reachable?` | TreeBin null root — defensive check |
| node.rs:560 | `TODO: Can root be null?` | Same defensive check in remove_tree_node |

## 4. Coverage Statistics

- **Git commits analyzed**: 24 bug-fix commits (all that touch src/)
- **GitHub issues deeply read**: 30 of ~50 total
- **Core files fully read**: map.rs (3552 lines), node.rs (1628 lines), raw/mod.rs (325 lines), reclaim.rs (170 lines), iter/ (439 lines)
- **Java reference comparison**: resize_stamp, addCount, transfer, helpTransfer, tryPresize
- **False positives excluded**: 2 (issue #115 likely external to flurry; issue #112 build-only)
