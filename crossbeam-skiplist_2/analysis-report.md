# Analysis Report: crossbeam-skiplist

## Coverage statistics

- **Source code analyzed**: `crossbeam-skiplist/src/` — 8 files, 5158 LOC total. Core file `base.rs` is 2653 LOC; `map.rs` 819 LOC; `set.rs` 661 LOC; `tla_trace.rs` 518 LOC (instrumentation only).
- **Git commits reviewed**: 83 commits touching `crossbeam-skiplist/src/base.rs`. All bug-fix and merge commits inspected; ~15 are substantive correctness fixes (the rest are formatting, lints, doc, MSRV bumps).
- **GitHub issues read**: 16 deeply read with full discussion threads (issues #109, #204, #270, #426, #540, #571, #614, #671, #672, #737, #878, #1023, #1122, #1131, #1142, #1167, #1178). 6 confirmed bugs, 4 design defects, 4 user-error or duplicate, 2 questions. Plus 4 open PRs reviewed (#889, #1124, #1238, #1252).
- **Parallel-subagent depth audits**: 4 (insert path, remove path & reclamation, iterator paths, linearizability/API contract).

## System overview

- **Name**: `crossbeam-skiplist` (part of `crossbeam-rs/crossbeam`)
- **Language**: Rust (no_std, alloc), 2 atomic backends (`Atomic<T>`, `AtomicUsize`)
- **Algorithm**: Pugh's lock-free skip list adapted for Rust + epoch-based reclamation via `crossbeam-epoch`
- **Concurrency model**: Lock-free; arbitrary number of concurrent reader/writer threads with `&self` mutators (interior mutability)
- **Reclamation**: Epoch GC — node retired via `guard.defer_unchecked` once refcount hits 0; physical free deferred until quiescent epoch
- **Tower**: variable-height (1..32), allocated as a single allocation with header + dynamically-sized `[Atomic<Node>; height]` tail. `Tower<K,V>` is a ZST trick (`[Atomic<Node>; 0]`) with provenance carefully preserved via `NodeRef`/`TowerRef` (b8c88aa5 stacked-borrows fix).
- **Marking**: `mark_tower` walks levels top-down via `fetch_or(1, SeqCst)`; level 0's tag-0→1 transition is the linearization point of removal. Returns `true` only to the thread that flipped level 0.
- **Reference counting**: A combined 32-bit `refs_and_height: AtomicUsize` (lower 5 bits = height-1, upper bits = refcount). Ref count = number of `Entry` handles + number of tower-level installations.

## Category classification

**Category B (Concurrent / Lock-Free)** — Lock-free data structure with CAS chains, epoch-based reclamation, top-down tower marking, and explicit reference counting. Falls into the **lock-free data structures** sub-category per `concurrent-analysis.md` § 5 prioritization table.

Per the prioritization table, primary fault families to focus on (after 5.1 Thread Interleaving): **5.7 Caller (iter+modify), 5.6 ABA, 5.5 MemOrder, 5.3 OOM (allocate)**.

## Bug archaeology — confirmed bugs

| # | Issue / PR | Mechanism | Severity | Status |
|---|------------|-----------|----------|--------|
| 1 | #1023 / PR #1101 (e7b5922e) | Insert reordering: pre-fix marked old before installing new → reader could find old node marked, new not yet installed → `get` returned None despite `len==1` | HIGH | Fixed |
| 2 | #1143 / PR #1143 (7121fbd4) | `remove()` returned `Some(entry)` from multiple threads racing on the same key (mark_tower lost path didn't return None) | HIGH | Fixed |
| 3 | #672 / PR #673 | Concurrent remove/replace memory leak: refcount-leak on the mark_tower-loser path — incremented refcount via try_acquire but did not decrement when losing | HIGH | Fixed |
| 4 | #671 / PR #673 | `RefRange` missing `Drop` releasing held `RefEntry` | MEDIUM | Fixed |
| 5 | #737 / PR #738 (e6d70ca8) | Iterator resumed from beginning after exhaustion; same fix also fixed missing `Drop` for `Iter` | HIGH | Fixed (for RefIter only) |
| 6 | #878 / PR #871 (b8c88aa5) | Stacked Borrows violation: `Tower<K,V>` ZST `[Atomic<Node>; 0]` reborrow only granted 0-byte permission while code accessed the over-allocated tail. Fix replaced ZST-tail trick with explicit `NodeRef`/`TowerRef` raw-pointer access (445-line refactor) | HIGH (UB under SB model) | Fixed |
| 7 | #1178 / PR #1217 (e7ccb30d) | `RefRange` `clone_from` overwrote internal `head`/`tail` `RefEntry` without calling `decrement` → leaked refcount → epoch-deferred finalize never fired. Regression of #673, introduced by #741. | HIGH | Fixed |
| 8 | #1131 / closed as dup of #540 | Values dropped late or never at exit due to epoch GC backlog | LOW (by design) | Won't fix |
| 9 | PR #1252 (open) | `Range::next` rewinds to head after exhaustion (issue #1142) | MEDIUM | Open PR |

## Bug archaeology — historical bug-fix commits (mainline)

| Commit | Date | Fix |
|--------|------|-----|
| `7121fbd4` | 2024-12-20 | `remove()` returning Some only for one thread (PR #1143) |
| `e7ccb30d` | 2026-02-14 | RefRange release of internal RefEntry on clone_from (#1217) |
| `b8c88aa5` | 2026-02-14 | Stacked Borrows violations fix (NodeRef/TowerRef refactor) |
| `e7b5922e` | 2024-04-19 | #1023 fix: install new before marking old |
| `bbe386e0` | 2021-03-04 | (pre-#1143) make remove always return entry — later refined by #1143 |
| `4b0c5c54` | 2021-08-21 | pop_front/pop_back leak: missing release on remove==false |
| `a7caaf14` | 2021-08-29 | RefRange leak (precursor to #1217 regression cycle) |
| `e6d70ca8` | 2021-08-21 | Keep skiplist iterator ordered (#737) |
| `3406d849` | 2021-08-29 | Range::next_back used wrong bound |
| `4e0c17cb` | 2018-… | RefRange decrement during iteration |
| `46c8b530` | … | Call check_guard in decrement_with_pin |
| `b6868f7f` | … | Properly handle alloc error |
| `f7b4e308` | … | Switch to alloc API (resolved #270) |
| `0240f82d` | 2025-… | Helper for safer allocation |

## Deep analysis — novel findings

### Finding A1: Iter::next rewinds after exhaustion (HIGH, novel)

**File:line**: `base.rs:2098-2120` (Iter::next), `base.rs:2126-2147` (Iter::next_back)

**Mechanism**: After forward (or backward) iteration meets the opposing cursor (`h.key >= t.key`), both `self.head` and `self.tail` are reset to `None`. On the **next** call, the `None` arm of the match calls `next_node(self.parent.head.as_tower(), Bound::Unbounded, ...)` — which yields the **front** of the skip list again. The iterator silently rewinds.

**Interleaving**:
```
let mut iter = m.iter(&guard);
iter.next();  // -> Some(k1)
iter.next();  // -> Some(k2) ... etc
iter.next();  // -> None (head=tail crossover, both set to None)
iter.next();  // -> Some(k1) AGAIN  -- rewind bug
```

**Severity**: HIGH. Same shape as #1142 (Range), which is being fixed in PR #1252. `Iter` was reportedly fixed by #738 (e6d70ca8) — but only for `RefIter`. The non-Ref `Iter` retains the rewind shape because it null-clears its cursors on cross-over while `RefIter`/`RefRange` retain RefEntry handles.

**Verification**: Confirmed by re-reading `base.rs:2099-2106` and `base.rs:2126-2134`. Code path is unambiguous.

### Finding A2: Range::next_back rewinds after exhaustion (HIGH, novel mirror of #1142)

**File:line**: `base.rs:2329-2361`

**Mechanism**: When `Range::next_back` exhausts (tail crosses head), `self.head = None; self.tail = None`. Subsequent call: `tail` is None → `search_bound(self.range.end_bound(), true, ...)` returns the last node in range. Rewind.

**Severity**: HIGH. Same logic as #1142 but for the backward direction. PR #1252 fixes `Range::next` but does NOT (per the PR description) touch `next_back`.

### Finding B1: Insert transient duplicate window (MEDIUM, partially known via #1023 / PR #1101)

**File:line**: `base.rs:1095-1129`

**Mechanism**: After PR #1101's fix, the order is:
1. Allocate new node `n`, write key/value (pre-publish).
2. Optimistic `len.fetch_add(1, Relaxed)` (line 1085).
3. `n.tower[0].store(search.right[0], Relaxed)` (line 1089).
4. **Level-0 CAS**: `pred.tower[0].compare_exchange(search.right[0], n, SeqCst, SeqCst)` (lines 1095-1104).
5. If success and `search.found = Some(r)`: call `r.mark_tower()` (line 1126). If `mark_won`, decrement `len` (line 1128).

Between step 4 (success) and step 5 (`mark_tower(r)` runs), the level-0 chain is `pred → n → r → ...`, with `r` *not yet marked*. A reader iterating level 0 traverses both `n` (key K) and `r` (key K). An iterator yields **two entries with key K** transiently.

PR #1101 narrowed the window (previously `r` was marked first, then `n` installed; the reverse window let `get` return None). The current code has reversed the visibility but not eliminated the duplicate-on-iter window.

**Verification**: Confirmed by re-reading lines 1095-1162. The CAS at line 1104 is SeqCst, but `r.mark_tower()` is a separate operation; thread can be preempted in between. `n.tower[0]` was set to `search.right[0]` (= `r`), so a reader past `pred` lands on `n`, then `r`.

**Linearizability impact**: For point queries (`get`, `contains_key`), the spec is correct (returns `n`'s value, the latest). For iteration / `len()`, the spec is violated — iter sees duplicate keys, len reports n+1 instead of n.

### Finding B2: compare_insert atomicity gap with absent key (MEDIUM, known #1167/#1122)

**File:line**: `base.rs:1018-1196`, `base.rs:1392-1403`

**Mechanism**: `compare_insert(key, value, predicate)` documented as CAS-style. But predicate is only invoked inside `if let Some(r) = search.found {…}` (lines 1053-1062 and 1179-1195). On the **not-found** path, after the level-0 CAS installs the new node (lines 1095-1104), control falls through with predicate uncalled.

**API contract violation**: User expects "insert iff existing value matches predicate". Implementation: "insert always when key absent; insert iff existing value matches predicate when key present".

**Severity**: MEDIUM. Documented by maintainer (Issue #1167 open since 2024). Workaround: user must check existence separately.

### Finding C1: Memory ordering — SeqCst on tower CAS chain may be over-strong (LOW)

**File:line**: `base.rs:339, 1100, 1217, 1273, 1288, 1356, 1505, 1516`

**Observation**: The code uses `Ordering::SeqCst` for level-0 install CAS, every higher-level tower CAS during build, and `mark_tower`'s `fetch_or`. There are 5 `TODO(Amanieu): can we use release/relaxed ordering here?` comments in the file. The author has flagged these as not analyzed.

**Analysis** (from concurrent-analysis subagent): Most of the SeqCst can be replaced by `Release/Acquire` (or `Acquire` on failure) without changing correctness. However, the `mark_tower` top-down ordering is **load-bearing**: PostBuildCheck at line 1356 only inspects `n.tower[height-1]`; the validity of "if top is marked, all levels are marked" relies on `mark_tower`'s top-down sequence (line 333: `(0..height).rev()`). A future refactor changing the mark order would invalidate PostBuildCheck.

**Suggested action**: Document the top-down dependency in code comments. Verify orderings via TLA+ memory-ordering relaxation under bounded fault injection.

### Finding C2: search_position can record `left[level]` that becomes marked (LOW, defended)

**File:line**: `base.rs:928-1013`

**Mechanism**: `search_position` advances `pred = c.as_tower()` when `c.key < key`. After advancing, no re-check of `c`'s mark. A concurrent remover can mark `c` at `level` after we passed it. We then store `result.left[level] = c.as_tower()`. Insert later does `pred.compare_exchange(succ, n, ...)`; the CAS catches the staleness (the marker bit + concurrent unlink → expected != actual → CAS fails → retry).

**Severity**: LOW (CAS naturally catches the staleness). No bug, but worth modeling to demonstrate the spec's interleaving robustness.

### Finding C3: PostBuildCheck only inspects top level — fragile but sound (LOW)

**File:line**: `base.rs:1356-1359`

**Mechanism**: After 'build loop completes (or aborts early), the code reads `n.tower[height-1]` and only triggers a search-restart if the top is marked. This is sound *provided* `mark_tower` always marks top-down. A bottom-up mark order would silently break PostBuildCheck.

**Severity**: LOW (correctness depends on mark_tower's top-down invariant, which is enforced).

### Finding C4: clear() relies on next iteration's lower_bound to physically unlink (LOW)

**File:line**: `base.rs:1640-1680`

**Mechanism**: `clear` does `e.node.mark_tower()` for each node in batches but does not directly call unlink. The next batch's `lower_bound::<K>(Bound::Unbounded, guard)` triggers `search_bound` → `help_unlink` for each marked node. Sound, but couples the two actions.

**Severity**: LOW.

### Finding C5: try_pin_loop liveness (LOW)

**File:line**: `base.rs:2618-2627`

**Mechanism**: Loops calling `f()` and `try_acquire` until pin succeeds or None. Theoretical livelock if a stream of nodes each become refcount==0 immediately; in practice `f()` skips marked nodes and progresses. **No bug.**

### Finding C6: refcount underflow under Relaxed but masked by `len > isize::MAX` clamp (LOW)

**File:line**: `base.rs:519-525, 1085, 1128, 1187, 1477, 1669, 1811, 1986`

**Mechanism**: All `len.fetch_add` and `len.fetch_sub` use `Ordering::Relaxed`. Under heavy concurrent insert/remove, a `fetch_sub` may be reordered before a corresponding `fetch_add`, yielding usize underflow. The `len()` getter clamps `> isize::MAX` to 0.

**Severity**: LOW. By design — `len()` is documented as approximate.

### Finding C7: lib.rs atomicity claim is overstated (LOW, known via #204)

**File:line**: `lib.rs:70-73`

**Mechanism**: Doc claims "a _single_ operation operates atomically: race conditions are impossible." This is true for point ops (get, insert, remove, compare_insert) at their level-0 CAS linearization point. But:
- `len()` is not linearizable (Relaxed counter).
- `iter()` does NOT provide a snapshot (per-step traversal observes concurrent inserts/removes).
- Issue #204 asks about full sequential consistency vs Java's `ConcurrentSkipListMap`.

**Severity**: LOW (documentation gap).

## Bug Families (synthesis)

### Family I: Iterator rewind after exhaustion (HIGH)

**Mechanism**: Iterators that null-clear their cursor state on exhaustion subsequently treat the next `next()`/`next_back()` call as a fresh start — re-traversing from the front/back of the list. Affects:

- `Iter::next` / `Iter::next_back` (lines 2098-2147) — **novel**
- `Range::next` / `Range::next_back` (lines 2287-2361) — `next` reported in #1142, fix in PR #1252; `next_back` **novel**

`RefIter`/`RefRange` are NOT affected because they retain `RefEntry` handles (which stay alive) and never null-clear their cursors on exhaustion.

**Modeling fit**: Caller-misuse harness (5.7) plus iterator-internal-state tracking. The bug is a fused-iterator violation that's exposed when a client polls the iterator after `None` (e.g., `.peekable()`, `.by_ref().take(N)`, manual polling).

### Family II: Insert install-then-mark window — transient duplicate observable (MEDIUM)

**Mechanism**: After PR #1101 fix, level-0 CAS install precedes `mark_tower` of old node. Reader iteration in the gap observes two nodes with the same key, and `len()` over-counts. Linearizability is violated for non-point operations even though point queries are correct.

**Modeling fit**: Split actions at the boundary — `InstallNew` (level-0 CAS) and `MarkOld` (mark_tower of replaced node) as separate transitions. Invariant: "between InstallNew and MarkOld, list contains two nodes with the inserter's key". Iter snapshot invariant: "iter does not yield two entries with the same key in a single traversal" — should fail.

### Family III: Reference-count discipline (HIGH historically, mostly fixed)

**Mechanism**: refcount = (Entry count) + (tower-level installations). Bugs occur when a code path increments without a matching decrement, or vice versa. Historical instances: #672 (mark-loser leaked refcount), #671 (RefRange Drop missing), #1178 (RefRange clone_from missing decrement), #1143 (remove returned Some without consuming a refcount in mark-loser path).

**Modeling fit**: Track refcount as a state variable. Invariant: "refcount never reaches 0 while a thread holds a NodeRef-backed Entry or RefEntry from this node." The pattern is well-understood and historically heavily fixed — limited TLA+ value beyond reproducing what tests already catch.

### Family IV: Tower-CAS memory ordering (LOW, design discipline)

**Mechanism**: Multiple atomic accesses with mixed `Ordering::*`. The author flagged 5 sites with `TODO: can we use release ordering here?`. Top-down `mark_tower` is implicitly required for PostBuildCheck soundness.

**Modeling fit**: Memory-ordering relaxation (5.5) — model each atomic with its actual ordering, then probe whether weakening (e.g., `Release` → `Relaxed`) breaks PostBuildCheck or insert/remove balance. This is hypothetical-weakening analysis (label as robustness).

### Family V: API contract / linearizability documentation (LOW-MEDIUM, known)

**Mechanism**: Documentation overstates atomicity guarantees. Implementation is linearizable for point ops keyed by level-0 CAS, but not for aggregate ops (`len`, iter, range count, etc.). `compare_insert` is documented as CAS but skips predicate when key absent.

**Modeling fit**: Minimal — these are documentation/design issues, not protocol bugs. Mention in spec pre/postconditions.

### Family VI: Caller misuse — concurrent iter + insert + remove (MEDIUM)

**Mechanism**: Iteration that observes intermediate skip-list states (mid-mark, mid-build, mid-unlink). Per `concurrent-analysis.md` § 5.7, this is the primary fault model for concurrent collections. The library's documented contract makes this "normal usage", not misuse — but it's where bugs live.

**Modeling fit**: ClientHarness-style adversarial driver — non-deterministically interleave insert/remove/iter/get. Check that iter never yields a removed node twice, never skips a node that was always present, and that `get(K)` returns the latest insertion's value if no concurrent remove of K. Strong TLA+ fit per § 5.1 (Thread Interleaving) and § 5.7 (Caller).

## Excluded findings (not pursued)

- **back() linearizability** — earlier subagent flagged a concern; on re-verification, `search_bound(Unbounded, true)` does walk to the end at level 0 (pred carries from level to level, level 0 is canonical) and is linearizable. False alarm.
- **Memory leak from epoch GC backlog** (#540, #1131) — by-design, not a bug.
- **`get_mut` / mutable access** (#318) — feature request.
- **Tower<K,V> ZST stacked-borrows** — already fixed in b8c88aa5.

## Reference pointers

- **Source**: `artifact/crossbeam/crossbeam-skiplist/src/base.rs` (2653 LOC; the entire skip-list implementation)
- **TLA+ trace instrumentation**: `artifact/crossbeam/crossbeam-skiplist/src/tla_trace.rs` (518 LOC; cargo feature `tla-trace` emits per-thread NDJSON traces with rdtsc intervals)
- **Tests**: `artifact/crossbeam/crossbeam-skiplist/tests/{base,map,set}.rs`
- **GitHub issues** (key references): #1023, #1101, #1142, #1143, #1167, #1178, #204, #672, #671, #737, #738, #878, #1217, #1252
- **Reference algorithm**: William Pugh, "Skip Lists: A Probabilistic Alternative to Balanced Trees", CACM 1990. Concurrent variant follows Fraser & Harris (2007) for level-0-first install + top-down mark.
