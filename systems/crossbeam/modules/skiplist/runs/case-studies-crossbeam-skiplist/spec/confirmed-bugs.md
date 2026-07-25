# Confirmed Bug Report — crossbeam-skiplist

## Summary
- Total findings reviewed: 18 (5 bug families, 7 MC-verifiable, 5 test-verifiable, 4 code-review-only, F3 iterator bug)
- Reproduced: 1 (bug #1142 — iterator exhaustion restart, 4 affected code paths)
- False positives: 4 (TV-2 compare_insert on removed node, TV-3 clear() non-linearizable, TV-4 O(N) help-unlink, TV-5 IntoIter with marked nodes)
- Model checking clean: 3 families (F1 ref count 750M states, F2 linearizability 742M states, F4 tower marking 691M states)
- Historical/fixed: 13+ bugs across families F1, F2, F3 (all prior to current code)
- Inconclusive: 0

## Bug 1: Iterator Exhaustion Restart (Issue #1142)

- **Source**: Code Review (modeling brief Family 3) + Spec (ExhaustedStaysExhausted invariant)
- **Status**: REPRODUCED
- **Severity**: Medium (logic error, no memory safety impact)
- **Location**: `crossbeam-skiplist/src/base.rs` — 4 affected methods:
  - `Iter::next()` lines 1994-2015 (resets `self.head = None` on exhaustion)
  - `Iter::next_back()` lines 2022-2042 (resets `self.tail = None` on exhaustion)
  - `Range::next()` lines 2183-2215 (same pattern)
  - `Range::next_back()` lines 2224-2254 (same pattern)
- **Description**: Guard-based iterators (`Iter`, `Range`) use `Option::None` for both the "not yet started" and "exhausted" states. When the iterator is fully consumed (all elements yielded, `next()` returns `None`), both `self.head` and `self.tail` are set to `None`. On the subsequent call to `next()`, the `None` state is interpreted as "not started", causing the iterator to restart from the beginning of the list/range.
- **Root cause**: In `Iter::next()` (line 1995-2003):
  ```rust
  self.head = match self.head {
      Some(n) => self.parent.next_node(...),
      None => self.parent.next_node(self.parent.head.as_tower(), Bound::Unbounded, ...),
  };
  ```
  When `self.head` is `None` (either because iteration hasn't started OR because the iterator was exhausted), the code unconditionally re-initializes from the list head. The same pattern exists in `next_back()` (re-initializes from list tail) and in `Range::next()`/`next_back()` (re-initializes from range bounds).
- **NOT affected**: `RefIter` and `RefRange` (ref-counted variants). These types preserve `self.head` when returning `None` from beyond-range elements, so they never reset to the "not started" state. The public `SkipMap::iter()` and `SkipMap::range()` wrap `RefIter`/`RefRange` respectively, so the high-level API is safe.
- **Affected API path**: `SkipList::iter(&guard)` and `SkipList::range(bounds, &guard)` — the lower-level public API exposed via `pub mod base`.
- **Trigger scenario**: Create a `SkipList`, insert elements, obtain an `Iter` via `list.iter(&guard)`, consume all elements, then call `next()` again. The iterator returns the first element again instead of `None`.
- **Reproduction test**: `repro/test_bug1_iter_exhaustion.rs`
  - Test 1: `Iter::next()` restarts after full forward consumption
  - Test 2: `Range::next()` restarts after full forward consumption
  - Test 3: `Iter::next_back()` restarts after full backward consumption
  - Test 4: Mixed `next()`/`next_back()` meeting in middle causes restart
  - Test 5: Confirms `RefIter` (SkipMap) is NOT affected
- **Reproduction result**: PASS — all 4 buggy paths triggered, RefIter confirmed safe
- **Reproduction output**:
  ```
  Test 1: Iter restarts after exhaustion ... BUG CONFIRMED
    iter.next() returned Some(1) after exhaustion (should be None)
  Test 2: Range restarts after exhaustion ... BUG CONFIRMED
    range.next() returned Some(2) after exhaustion (should be None)
  Test 3: Iter::next_back restarts after exhaustion ... BUG CONFIRMED
    iter.next_back() returned Some(3) after exhaustion
  Test 4: Mixed next/next_back causes premature exhaustion then restart ... BUG CONFIRMED
    iter.next() returned Some(1) after forward/backward exhaustion
  Test 5: RefIter (SkipMap::iter) does NOT restart ... OK (RefIter stays exhausted, as expected)
  ```
- **Developer intent**: Issue #1142 is OPEN and unfixed in the crossbeam repository. Historical issue #737 (commit `e6d70ca`) fixed the same class of bug in `RefIter` but the guard-based `Iter`/`Range` were not addressed. The `FusedIterator` trait is not implemented for any iterator type in this crate.
- **Recommendation**: Add a boolean `exhausted` field (or use an enum `{NotStarted, Active(NodeRef), Exhausted}`) to `Iter` and `Range` to distinguish "not started" from "exhausted". Alternatively, implement `FusedIterator` after fixing the behavior.

## False Positives

### TV-2: compare_insert closure on removed node
- **Source**: Code Review (modeling brief section 6.2)
- **Finding**: The `compare_fn` closure in `compare_insert` may be called with a value from a node that is concurrently being removed.
- **Why false positive**: This is normal lock-free behavior. The epoch guard ensures memory safety (no use-after-free). If the node is removed during the compare, the subsequent `RefEntry::try_acquire` call fails (ref count is 0), and the loop retries with a fresh search. The compare_fn result on a removed node is harmless — it merely determines whether to allocate a new node before the retry.

### TV-3: clear() non-linearizable under contention
- **Source**: Code Review (CR-3)
- **Why false positive**: This is a documented design choice. `clear()` removes entries one at a time, so concurrent insertions can interleave. The crate documentation does not claim `clear()` is atomic. Not a bug.

### TV-4: next_node O(N) help-unlink chain
- **Source**: Code Review
- **Why false positive**: Performance concern, not a correctness bug. The `next_node` function may traverse a chain of logically-removed nodes during help-unlink. This is O(N) in the worst case but does not violate any safety or consistency invariant.

### TV-5: IntoIter with marked nodes
- **Source**: Code Review
- **Why false positive**: `IntoIter::next()` correctly handles marked nodes. The `Shared::as_raw()` method in crossbeam-epoch calls `decompose_tag()` which strips tag bits before returning the raw pointer (see `crossbeam-epoch/src/atomic.rs:1244-1246`). The tagged pointer stored in a marked node's level-0 link is properly cleaned before being used as `self.node`. Additionally, `IntoIter` has exclusive ownership (via `into_iter(self)`) so no concurrent access is possible.

## Model Checking Results (No New Bugs Found)

| Bug Family | Config | BFS States | Sim States | Invariants Checked | Result |
|-----------|--------|-----------|-----------|-------------------|--------|
| F1 — Ref Count | MC_hunt_family1.cfg | 750M (depth 22) | 1.39B (13.5M traces) | RefCountCorrect, NoUseAfterFinalize | PASS |
| F2 — Linearizability | MC_hunt_family2.cfg | 742M (depth 21) | 2.84B (26.8M traces) | InsertGetConsistency, RemoveLinearizability | PASS |
| F4 — Tower Marking | MC_hunt_family4.cfg | 691M (depth 20) | 2.16B (20.4M traces) | MarkingOrderTopDown, Level0Authoritative | PASS |

**Convergence**: 1.5B states, 360M distinct, depth 21, 30 min BFS — all 8 structural invariants pass.

**Note on F2**: The MarkBeforeCASFlag=TRUE injection models the #1023 pattern but the InsertGetConsistency invariant is satisfied trivially because `listMap` is updated atomically with the mark. A stronger invariant modeling "key accessible to concurrent readers during replace" would be needed to detect this bug class in future variants.

## Historical Bugs (All Fixed, No Reproduction Needed)

| Bug | Family | Commit/Issue | Description |
|-----|--------|-------------|-------------|
| Entry leak | F1 | `8dd9e9b` | Entry had no Drop impl — every Entry drop leaked memory |
| pop_front/pop_back leak | F1 | `4b0c5c5` | Leaked ref counts when entry already removed |
| RefRange leaks (×3) | F1 | `a7caaf1`, `4e0c17c`, `e7ccb30` | Three fixes for RefRange ref count leaks |
| RefIter leak | F1 | `e6d70ca` | RefIter leaked ref counts while iterating |
| decrement guard check | F1 | `46c8b53` | decrement_with_pin didn't check guard collector |
| insert/get race | F2 | `e7b5922` / #1023 | insert then get returns None (mark before CAS) |
| remove linearizability | F2 | `7121fbd` / #1143 | Multiple removes return Some for same key |
| remove wrong scope | F2 | `bbe386e` | remove() returned entry from wrong scope |
| RefIter exhaustion | F3 | `e6d70ca` / #737 | RefIter resumed from beginning (fixed; guard-based Iter not fixed → #1142) |
| RefRange bounds | F3 | `3406d84` | RefRange::next_back() used wrong bound directions |
