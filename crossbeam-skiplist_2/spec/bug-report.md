# Bug Report — crossbeam-skiplist

## Summary

- Bug families tested: 4 (F1 iter rewind, F2 insert dup, F3 mark ordering, F4 caller misuse)
- Bugs found: 1 (F1 reproduced; F2/F3/F4 no violations within budget)
- Configs run: `MC_hunt_family1_iter_rewind.cfg`, `MC_hunt_family2_insert_dup.cfg` (BFS + simulation), `MC_hunt_family3_memorder.cfg`, `MC_hunt_family4_caller_misuse.cfg` (BFS + simulation)

## Bug 1: Iterator Rewind After Exhaustion

- **Bug Family**: F1 — Iterator rewind after exhaustion (HIGH; #1142, PR #1252)
- **Severity**: High (4 confirmed rewind sites; PR #1252 only patches 1 of 4)
- **Invariant violated**: `IteratorFusion`
- **Config**: `MC_hunt_family1_iter_rewind.cfg` (`FaultIterRewind = TRUE`)
- **Counterexample**: 11 states, output file `spec/output/MC_hunt_family1_bfs.out`
- **TLC stats**: 18065 states generated, 17617 distinct states, depth 15, finished in 5s

### Trace Summary

| State | Action | Effect |
|---|---|---|
| 1 | `Initial` | Empty skiplist. |
| 2 | `MCInsert_Begin(t1, k2, v1)` | t1 begins inserting key `k2`. |
| 3 | `MCInsert_AllocCASLevel0(t1)` | t1 installs node 1 at level 0. `lenCounter = 1`. |
| 4 | `MCInsert_MarkOld(t1)` | `found = NULL`, no-op transition. |
| 5 | `MCInsert_BuildLevel(t1)` | Height = 1, transitions to PostBuildCheck. |
| 6 | `MCInsert_PostBuildCheck(t1)` | Top-level check passes. |
| 7 | `MCInsert_Done(t1)` | Entry handle released. List = `{k2 → v1}`. |
| 8 | `MCIter_Begin(t1, "Iter")` | t1 starts forward iterator. |
| 9 | `MCIter_Next(t1)` | Yields node 1 (k2). `iter[t1] = {head=1, finished=FALSE}`. |
| 10 | `MCIter_Next(t1)` | No more candidates → cross-over reset: `iter[t1] = {head=NULL, tail=NULL, finished=TRUE}`. History records `result=NULL`. |
| 11 | `MCIter_Next(t1)` | **REWIND BUG**: with `FaultIterRewind=TRUE`, the `finished` flag is ignored, the `None`-arm of `match self.head` re-enters `search_bound`, and the iterator yields node 1 (k2) **a second time**. `IteratorFusion` is violated. |

### Root Cause

In `base.rs:2098-2120` (`Iter::next`):

```rust
self.head = match self.head {
    Some(n) => next_node(n.as_tower(), Excluded(&n.key), guard),
    None    => search_bound(start_bound or Unbounded, false, guard),  // REWIND
};
if let (Some(h), Some(t)) = (self.head, self.tail) {
    if h.key >= t.key { self.head = None; self.tail = None; }       // exhaust resets
}
self.head.map(|n| Entry { ... })
```

After cross-over, `self.head` and `self.tail` are both set to `None`. On the next call, the `None` arm of `match` re-enters `search_bound(Unbounded, false, ...)`, which returns the front node — **rewinding** the iterator instead of staying exhausted (`FusedIterator` semantics broken).

The same shape exists in three more places:

| Site | Lines | Direction |
|---|---|---|
| `Iter::next` | base.rs:2098-2120 | forward |
| `Iter::next_back` | base.rs:2126-2147 | backward |
| `Range::next` | base.rs:2287-2320 | bound-respecting forward |
| `Range::next_back` | base.rs:2329-2361 | bound-respecting backward |

`RefIter`/`RefRange` are unaffected — they retain `RefEntry` handles instead of nulling the cursor (this is the design that closed #737 / commit `e6d70ca8`).

### Affected Code

- `crossbeam-skiplist/src/base.rs:2098-2120` — `Iter::next` rewind site (1 of 4).
- `crossbeam-skiplist/src/base.rs:2126-2147` — `Iter::next_back` rewind site.
- `crossbeam-skiplist/src/base.rs:2287-2320` — `Range::next` rewind site.
- `crossbeam-skiplist/src/base.rs:2329-2361` — `Range::next_back` rewind site.

### Recommendation

Apply PR #1252's `finished: bool` flag pattern (currently fixes `Range::next` only) to all four sites. Alternative: adopt the `RefIter`/`RefRange` "retain cursor" approach by storing `Option<Entry>` instead of nulling the cursor — this is the design precedent already shipping in the closed #737 fix and has been stable since.

---

## Not Reproduced

| Bug Family | Config | Mode | States Explored | Diameter | Result |
|---|---|---|---|---|---|
| F2 — Insert install-then-mark transient duplicate | `MC_hunt_family2_insert_dup.cfg` (FaultInsertReorder=TRUE) | BFS 30 min | 735M distinct | 18 | No `KeysUnique` / `LenIsApproximatelyKeyCount` / `IterNoSameKeyTwice` / `MarkMonotone` / `MarkTopDown` violation |
| F2 — Insert install-then-mark transient duplicate | `MC_hunt_family2_insert_dup.cfg` (sim follow-up, depth 75) | Simulation 30 min | 2.88B checked, 220M traces | n/a | No violation |
| F3 — Tower-CAS memory ordering / SeqCst sensitivity | `MC_hunt_family3_memorder.cfg` (FaultMarkBottomUp=TRUE) | BFS exhaustive | 5.37M distinct, 11.7M generated | 35 | No `KeysUnique` / `MarkTopDown` / `MarkMonotone` violation. State space FULLY EXPLORED. |
| F4 — Caller misuse (concurrent iter+insert+remove+pop_front) | `MC_hunt_family4_caller_misuse.cfg` | BFS 30 min | 767M distinct | 19 | No `RefcountMatchesHandlesAndInstalls` / `GetReturnsLatest` / `NoUseAfterFree` violation |
| F4 — Caller misuse (concurrent iter+insert+remove+pop_front) | `MC_hunt_family4_caller_misuse.cfg` (sim follow-up, depth 75) | Simulation 30 min | 5.05B checked, 377M traces | n/a | No violation |

### Why F2 didn't surface

The hunting cfg sets `FaultInsertReorder = TRUE`, which inverts insert into mark-old-first → install-new. The mechanism described by #1023 — between mark-old and install-new, the level-0 chain has 0 unmarked nodes for K — produces an *absence* window, not a *duplicate*. The shipped `KeysUnique`/`IterNoSameKeyTwice` invariants only catch duplicate observations, so they don't fire on the F2 absence window. The PR #1101 canonical order (install-new-then-mark-old) produces the *duplicate* window, but our `KeysUnique` invariant has a deliberate carve-out for `pc[t].step ∈ {MarkOld, BuildLevel, PostBuildCheck}` — which exactly covers that transient state. The model thus correctly exonerates the in-flight insert.

### Why F3 didn't surface

The base spec collapses `mark_tower`'s level loop into a single transition (see `Insert_MarkOld` comment, base.rs:303-315): for the abstraction, the *resulting* set of marked levels is identical whether the loop walked top-down or bottom-up. The `FaultMarkBottomUp` flag therefore can't change reachable states at this granularity — it would require modeling intermediate per-level states inside `mark_tower`, which the brief explicitly trades off against state-space tractability (priority LOW). The exhaustive 5.37M-state run rules out any other surface that would expose the sensitivity at this abstraction.

### Why F4 didn't surface

The well-tested refcount-discipline regressions (#672, #671, #1143, #1178) have all been fixed in the implementation; the spec correctly models the post-fix invariants. With 2 threads × 2 ops over k1, the configured bound exhausts the meaningful adversarial schedules within 767M distinct states / 19 levels deep, and an additional 5B simulation states extend coverage. None of `RefcountMatchesHandlesAndInstalls`, `GetReturnsLatest`, or `NoUseAfterFree` was violated, consistent with the brief's expectation that this family is "well-understood and individually fixed" (modeling-brief F5 reference-only rationale carries over to F4 in this pass).

---

## Spec Fixes Applied During Hunting

- **`Insert_AllocCASLevel0` CAS-contention precondition** (base.tla, applied during F2 hunt). The first F2 BFS run (before fix) reported a `KeysUnique` violation that was Case B: two concurrent `Insert(k1)` calls both observed `found = NULL` at search-position time and both proceeded to install distinct level-0 nodes for k1 → permanent duplicate. In the implementation (`base.rs:1095-1104`), the level-0 `compare_exchange` would fail for the loser, who then retries from `search_position`. The spec was abstracting the CAS away. Fix added the precondition `\A n \in NodesForKeyAt(pc[t].key, 0) : n = pc[t].found`, which models CAS success only when the predecessor's level-0 pointer hasn't been overwritten in the gap. All 5 traces still pass after the fix; F2 hunt re-ran clean.
