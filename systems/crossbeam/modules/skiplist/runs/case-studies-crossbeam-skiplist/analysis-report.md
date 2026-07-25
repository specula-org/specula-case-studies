# Analysis Report: crossbeam-skiplist

## 1. Codebase Reconnaissance

### 1.1 File Structure

| File | LOC | Purpose |
|------|-----|---------|
| `base.rs` | 2367 | Core lock-free skip list: Node, Tower, SkipList, insert, remove, search, iterators, ref counting |
| `map.rs` | 819 | `SkipMap<K,V>` safe wrapper: auto-pins epoch, `Entry` with `Drop` |
| `set.rs` | 661 | `SkipSet<T>` wrapper: delegates to `SkipMap<T, ()>` |
| `lib.rs` | 269 | Crate root, documentation, feature gating |
| `comparator.rs` | 96 | `Equivalator`/`Comparator` traits for custom key ordering |
| `equivalent.rs` | 54 | `Equivalent`/`Comparable` traits (blanket impls via `Borrow`) |
| `alloc_helper.rs` | 85 | Custom allocator wrapper (replaces unstable `Global`) |

### 1.2 Concurrency Model

**Fully lock-free**. All operations take `&self` (shared reference). Synchronization is via atomic CAS operations on `Atomic<Node<K,V>>` pointers (from `crossbeam-epoch`).

Key atomic operations:
- **Insert**: CAS on predecessor's level-0 pointer to install new node (linearization point)
- **Remove**: `fetch_or(1)` on each level pointer (top-down marking); CAS to unlink (physical removal)
- **Search**: `load_consume` on next pointers; restart on encountering marked nodes
- **Reference counting**: CAS on `refs_and_height` field (combined refcount + height in one `AtomicUsize`)

### 1.3 Data Structure Layout

```
SkipList {
    head: Head<K,V>          // [Atomic<Node>; 32] — full-height tower
    collector: Collector      // epoch GC
    hot_data: CachePadded<HotData> {
        seed: AtomicUsize     // xorshift RNG for random heights
        len: AtomicUsize      // approximate entry count
        max_height: AtomicUsize // highest tower currently in use
    }
    comparator: C
}

Node<K,V> {
    value: V
    key: K
    refs_and_height: AtomicUsize  // [refcount << 5 | (height-1)]
    tower: Tower<K,V>             // [Atomic<Node>; 0] — dynamically sized
}
```

### 1.4 Key Abstractions

- **`NodeRef<'a, K, V>`**: Raw-pointer wrapper preserving provenance for Tower access (introduced in `b8c88aa` to fix Stacked Borrows UB)
- **`TowerRef<'a, K, V>`**: Same pattern for Tower access
- **`Entry<'a, 'g, K, V>`**: Guard-lifetime-bound entry (short-lived, no ref count)
- **`RefEntry<'a, K, V>`**: Reference-counted entry (long-lived, must be explicitly released)
- **`Position<'a, K, V>`**: Search result with left/right arrays for each level

---

## 2. Bug Archaeology

### 2.1 Coverage Statistics

- **Git commits analyzed**: 14 bug-fix commits + 6 safety-improvement commits
- **GitHub issues deeply read**: 35+ (including all comments)
- **Issues confirmed as bugs**: 12
- **Issues classified as design defects**: 4
- **Issues classified as false positive/user error**: 2
- **Open PRs reviewed**: PR #1238 (draft: remove 'static bounds), PR #1162 (next release bundle)

### 2.2 Bug-Fix Commit Inventory

| # | Hash | Summary | Root Cause | Component | Severity |
|---|------|---------|------------|-----------|----------|
| 1 | `e7b5922` | Insert+get returns None (#1023) | mark_tower before CAS install | insert (replace) | Critical |
| 2 | `7121fbd` | Multiple removes return Some | Wrong scope for return | remove | Critical |
| 3 | `b8c88aa` | Stacked Borrows UB in Tower ZST | ZST &Tower has no provenance | Tower/Node | Critical |
| 4 | `c591923` | get_unchecked UB on zero-length slice | ZST slice indexing | Tower | High |
| 5 | `bbe386e` | remove() returns entry from wrong scope | Missing return in else branch | remove | High |
| 6 | `4b0c5c5` | pop_front/pop_back leak ref counts | Missing release on remove failure | pop | High |
| 7 | `a7caaf1` | RefRange leaks ref counts | Missing decrement in next/next_back | RefRange | High |
| 8 | `4e0c17c` | RefRange leaks during iteration | Missing decrement when advancing | RefRange | High |
| 9 | `e7ccb30` | RefRange leaks on drop (#1217) | clone_from without decrement | RefRange | High |
| 10 | `3406d84` | next_back uses wrong bound directions | start_bound/end_bound swapped | Range | High |
| 11 | `e6d70ca` | RefIter out-of-order + leak | Missing decrement, wrong ordering | RefIter | High |
| 12 | `46c8b53` | decrement_with_pin missing guard check | No check_guard call | memory recl. | Medium |
| 13 | `8dd9e9b` | Entry has no Drop impl | Missing Drop entirely | Entry lifecycle | High |
| 14 | `b6868f7` | Alloc error not handled | Missing null check | Node alloc | Medium |

### 2.3 Bug Hotspot Analysis

| Component | Bug Count | Commit Hashes |
|-----------|-----------|---------------|
| Ref counting / memory reclamation | 7 | 4b0c5c5, a7caaf1, 4e0c17c, e7ccb30, e6d70ca, 8dd9e9b, 46c8b53 |
| Iterator (Range/Iter) | 5 | a7caaf1, 4e0c17c, 3406d84, e6d70ca, e7ccb30 |
| Remove | 2 | 7121fbd, bbe386e |
| Insert | 1 | e7b5922 |
| Core data structure (Tower/Node) | 2 | b8c88aa, c591923 |
| Allocation | 1 | b6868f7 |
| Pop operations | 1 | 4b0c5c5 |

### 2.4 GitHub Issue Summary

**Skiplist-direct confirmed bugs (12)**:
- #1023 — insert/get race (FIXED in PR #1101)
- #671, #672 — range/remove memory leaks (FIXED in PR #673)
- #614 — test memory leaks (FIXED in PR #1022)
- #737 — iterator restarts from beginning (FIXED in PR #738)
- #1142 — Range rewinds after exhaustion (**OPEN**, unfixed)
- #878 — Miri Stacked Borrows violation (FIXED in PR #871)
- PR #1143 — remove race: multiple threads get Some (FIXED)
- PR #940 — get_unchecked panic (FIXED)
- PR #1217 — RefRange drop leak (FIXED)
- PR #337 — Entry drop leak (FIXED)
- PR #735 — pop_front/pop_back leak (FIXED)

**Design defects (4)**:
- #540 — epoch delays memory release (inherent to EBR design)
- #205 — `K: 'static` / `V: 'static` bounds required (WIP PR #1238)
- #1130 — `Send` bound asymmetry between `insert` and `get_or_insert`
- #1167 — `compare_insert` not a true CAS for missing keys

**Epoch-related bugs affecting skiplist (6)**:
- #545 — Stacked Borrows in epoch (FIXED in PR #871)
- #238 — UAF in MSQueue (theoretical, proven safe for MSQ but reasoning is subtle)
- #105 — epoch advance while pin held (FIXED)
- #395 — offsetof unsoundness (FIXED)
- #693 — buffer overflow in array init (FIXED)
- #689 — alloc null not handled (FIXED)

---

## 3. Deep Analysis Findings

### 3.1 Insert Path Analysis

**Insert-Replace Window (base.rs:1072-1092)**: After the level-0 CAS succeeds, there is a window where both old and new nodes are in the level-0 chain (pred → new → old → succ). A concurrent iterator positioned at `new` would follow `next` to `old` and see the stale value. This is transient (mark_tower on the old node closes the window) but observable.

**Tower Building Race (base.rs:1136-1218)**: After level-0 install, the node is visible but only at level 0. Higher levels are linked one-by-one via CAS. Each level CAS validates its predecessor/successor. If concurrent marking occurs during tower building:
- Line 1148-1151: checks if own tower pointer is marked; stops building
- Line 1183-1184: CAS validates predecessor still points to expected successor
- Lines 1220-1229: final cleanup if top-level pointer was marked during build

**Duplicate Key Successor Loop (base.rs:1171-1177)**: During tower building, if the successor at a level has the same key, search_position is repeated to unlink the stale node. This loop terminates because: (a) the stale node gets unlinked, (b) our own node gets marked and we break, or (c) the successor changes after search_position.

**Len Counter (base.rs:1068)**: Incremented optimistically before CAS. Over-counted by at most 1 per in-flight insert. Documented as approximate (line 519-521).

### 3.2 Remove Path Analysis

**mark_tower Top-Down (base.rs:327-348)**: Marks from highest level down to level 0. Only level-0 mark is authoritative for logical removal. Transient window: node visible at level 0 but invisible at higher levels. Safe because correctness depends only on level-0 chain.

**help_unlink Safety (base.rs:759-781)**: If the predecessor is concurrently being removed (its pointer gets marked), the CAS fails because the expected value (untagged pointer to curr) won't match the now-tagged pointer. If help_unlink CAS succeeds and then the predecessor gets marked, the predecessor's marked pointer now points to `succ` — this is correct and will be cleaned up by a subsequent help_unlink on the predecessor.

**Reference Count in remove() (base.rs:1269-1337)**: All paths are balanced:
- Path A (mark succeeds): +1 from try_acquire, returned as RefEntry
- Path B (already marked): +1 from try_acquire, immediately -1 via decrement
- Path C (try_acquire fails): no change, retry
- Path D (not found): no change, return None

**clear() Under Contention (base.rs:1369-1411)**: Not linearizable. Concurrent inserts can survive clear(). After clear(), the list may contain nodes inserted during the clear operation.

### 3.3 Iterator Analysis

**Linearizability**: Weakly consistent (snapshot-less). Elements are returned in key order. Each returned element existed in the list at some point during iteration. No element is returned twice (guaranteed by `Bound::Excluded` on the last-returned key).

**Exhaustion Bug (#1142)**: `Range::next()` (lines 2002-2008) and `Iter::next()` (lines 1813-1821) use `None` for both "not started" and "exhausted" states. After bound-checking sets `self.head = None`, the next call restarts from the beginning. `RefRange` and `RefIter` are NOT affected — they preserve `self.head` on exhaustion.

**Double-Ended Overlap**: Key comparison on head/tail cursor nodes is safe: epoch guard (for Iter/Range) or ref count (for RefIter/RefRange) prevents deallocation.

**search_bound Livelock**: Obstruction-free, not wait-free. Under continuous concurrent removals, the `continue 'search` restart can loop indefinitely. In practice, bounded by finite removal operations.

**next_node Chain Length**: O(N) per call in the worst case, where N is the number of consecutive marked-but-not-unlinked nodes. Each successful help_unlink physically removes one node from the chain.

**try_pin_loop**: Theoretically unbounded under adversarial scheduling (front entry keeps being removed between find and pin). Obstruction-free progress guarantee.

### 3.4 Memory Reclamation Analysis

**Reference Count Lifecycle**: Alloc (+2: 1 for RefEntry, 1 for level-0) → +1 per higher level linked → -1 per level unlinked → -1 per RefEntry released → 0 triggers deferred finalize.

**try_increment ABA**: Prevented by epoch protection. While caller holds a Guard, the node cannot be freed and reused at the same address. CAS with Relaxed ordering is sufficient because the atomic itself provides the synchronization.

**decrement Ordering**: Correct Arc::drop pattern (Release fetch_sub + Acquire fence at zero).

**SkipList::drop Safety**: Nodes in the level-0 chain always have refCount > 0 (the level-0 link contributes 1). So finalize is not deferred for them. Nodes already unlinked from level-0 are not in the chain and won't be visited by drop. No double-free.

**IntoIter Marked Nodes**: For marked-but-still-in-chain nodes, `IntoIter::next` takes ownership of key/value via `ptr::read` and deallocates the raw memory. The node's finalize was never deferred (refCount > 0 due to level-0 link). Safe: no double-drop.

---

## 4. Developer Signals (TODOs in base.rs)

| Line | Signal | Context |
|------|--------|---------|
| 334 | `TODO(Amanieu): can we use release ordering here?` | `mark_tower` fetch_or uses SeqCst |
| 456-463 | `TODO(stjepang): Embed a custom epoch::Collector` | Global collector requires 'static bounds |
| 1075 | `TODO(Amanieu): can we use release ordering here?` | Level-0 CAS uses SeqCst |
| 1143 | `TODO(Amanieu): can we use relaxed ordering here?` | Tower load during building uses SeqCst |
| 1182 | `TODO(Amanieu): can we use release ordering here?` | Node level-pointer CAS uses SeqCst |
| 1196 | `TODO(Amanieu): can we use release ordering here?` | Predecessor CAS during tower install uses SeqCst |
| 1226 | `TODO(Amanieu): can we use relaxed ordering here?` | Top-level mark check uses SeqCst |
| 1305 | `TODO(Amanieu): can we use relaxed ordering here?` | Successor load during unlink uses SeqCst |
| 1309 | `TODO(Amanieu): can we use release ordering here?` | Unlink CAS uses SeqCst |

**Pattern**: All 8 Amanieu TODOs concern relaxing SeqCst. The entire skiplist uses SeqCst for ALL critical CAS operations — correct but potentially over-synchronized. Analysis suggests Release/Acquire would suffice in most cases, but the SeqCst provides a total order that simplifies correctness reasoning.

---

## 5. Bug Family Grouping

### Family 1: Reference Count Lifecycle Errors
- **7 historical bugs**, all sharing the same mechanism: missing decrement/release calls
- **Root cause pattern**: code path handles the "happy path" correctly but misses ref count management in error/retry/exhaustion/drop paths
- **Highest density** in iterator code (5 of 7 bugs in RefIter/RefRange)
- **Model-checkable**: ref count invariant can be expressed as a safety property

### Family 2: Concurrent Insert/Remove Linearizability
- **3 historical bugs**: insert/get race, multi-remove race, wrong return scope
- **Root cause pattern**: non-atomic compound operations (mark_tower + CAS, find + acquire + mark)
- **Model-checkable**: linearizability can be checked against a sequential spec

### Family 3: Iterator Exhaustion and Ordering
- **3 historical bugs** + 1 open (#1142)
- **Root cause pattern**: conflation of "not started" and "exhausted" iterator states
- **Affects only guard-based iterators** (Iter, Range); ref-counted variants (RefIter, RefRange) unaffected

### Family 4: Tower Marking Protocol
- **0 known bugs** in current code, but complex interleavings are hard to reason about
- **Top-down marking + bottom-up tower building** creates non-obvious invariants
- **Model-checkable**: finite state space with 2-3 levels and 2-3 threads

### Family 5: Epoch Reclamation Design
- **Delayed deallocation** is inherent to EBR design, not a bug
- **Stacked Borrows issues** are fixed in PR #871 (pending next release)
- **NOT suitable for TLA+ modeling** (requires weak-memory model tools)

---

## 6. Cross-Cutting Observations

### 6.1 All SeqCst, No Nuance
The entire skiplist uses `Ordering::SeqCst` for every CAS and `fetch_or`. The maintainer (Amanieu) has 8 TODO comments asking about relaxation. This is a deliberate conservatism — correctness is ensured at the cost of potential performance. The SeqCst provides a total order that eliminates entire classes of subtle weak-memory bugs.

### 6.2 Epoch Protection vs. Reference Counting
The skiplist uses BOTH epoch-based reclamation (for memory safety of concurrent access) AND manual reference counting (for determining when to finalize). This dual mechanism is the source of most bugs: code must correctly manage both the epoch guard (short-lived) and the reference count (long-lived). Missing either one leads to different failure modes: missing guard = use-after-free; missing refcount decrement = memory leak.

### 6.3 Guard-Based vs. Ref-Counted API Split
The codebase has two parallel API tracks:
- **Guard-based** (`Entry`, `Iter`, `Range`): short-lived, tied to epoch guard lifetime
- **Ref-counted** (`RefEntry`, `RefIter`, `RefRange`): long-lived, must be explicitly released

The ref-counted variants are more complex but actually MORE correct in practice (e.g., not affected by #1142 exhaustion bug). This suggests the guard-based iterators receive less testing attention.

### 6.4 Insert-Replace is the Hardest Path
The `insert_internal` function (lines 1013-1234) handles 4 distinct scenarios:
1. Key not found → insert new node
2. Key found, replace=false → return existing (get_or_insert)
3. Key found, replace=true → mark old, insert new (insert with replace)
4. CAS failure → retry with fresh search

Scenario 3 has the most bug potential because it involves both a new node installation AND an old node removal in a non-atomic compound operation. Both historical critical bugs (#1023, #1143) were in this area.
