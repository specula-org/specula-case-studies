# Modeling Brief: crossbeam-skiplist

## 1. System Overview

- **System**: `crossbeam-skiplist` — Pugh-style lock-free skip list with epoch-based reclamation, used as the foundation for many higher-level Rust concurrent crates.
- **Language**: Rust (no_std + alloc), 2653 LOC core (`base.rs`); 819 + 661 LOC for `map.rs` / `set.rs` wrappers; 518 LOC for `tla_trace.rs` instrumentation.
- **Category**: **Category B (Concurrent / Lock-Free)** — lock-free CAS chains, epoch-deferred reclamation, top-down tower marking, combined-atomic refcount+height. Sub-category: **lock-free data structures** (per `concurrent-analysis.md` § 5 prioritization table).
- **Algorithm**: Skip list with random tower heights (1..32) installed bottom-up; remove marks tower top-down via `fetch_or(1)`; level-0 mark is the linearization point.
- **Key architectural choices**:
  - Single `AtomicUsize` (`refs_and_height`) packs height (low 5 bits) + refcount (upper bits). Refcount = (Entry/RefEntry handles) + (tower-level installations).
  - Combined node + tower allocation (`#[repr(C)]` Node followed by variable-size `Atomic<Node>` tail). Provenance preserved via `NodeRef`/`TowerRef` zero-sized wrappers (b8c88aa5 stacked-borrows fix).
  - Tower mark-tower goes **top-down**; PostBuildCheck (insert) only inspects top level, relying on this invariant.
  - Level-0 install CAS uses `Ordering::SeqCst`; 5 sites flagged with `TODO: can we use release ordering here?` (Amanieu).
  - `compare_insert` skips predicate when key absent (documented, design defect #1167).
- **Concurrency model**: Many threads may concurrently call `insert`/`remove`/`get`/`iter`/`range` with `&self`. Each thread holds an epoch `Guard`; reclamation deferred until quiescent epoch.

## 2. Bug Families

### Family 1: Iterator rewind after exhaustion (HIGH)

**Mechanism**: Iterators that null-clear their cursor state on exhaustion treat the next call as a fresh iteration — re-traversing from the front/back of the list.

**Evidence**:
- Historical: #737 / commit `e6d70ca8` — `RefIter` rewind fixed by retaining cursor `RefEntry` handles. Fix did NOT cover `Iter` (non-Ref).
- Historical: #1142 (open) — `Range::next` rewinds; PR #1252 (open) adds a `finished` flag.
- Code analysis: `base.rs:2098-2120` — `Iter::next` sets `head=None; tail=None` on cross-over; subsequent call's None-arm calls `next_node(self.parent.head.as_tower(), Bound::Unbounded, ...)` → returns front. **Novel**.
- Code analysis: `base.rs:2126-2147` — `Iter::next_back` sets both to None; subsequent call rewinds to back via `search_bound(Unbounded, true)`. **Novel**.
- Code analysis: `base.rs:2329-2361` — `Range::next_back` rewinds to range's end_bound. **Novel** (PR #1252 only fixes `Range::next`).

**Affected code paths**: `Iter::next`, `Iter::next_back`, `Range::next`, `Range::next_back`. (`RefIter`/`RefRange` keep `RefEntry` handles → unaffected.)

**Suggested modeling approach**:
- Variables: per-iterator `head`, `tail`, `finished: BOOLEAN`. Spec models the `head=None, tail=None` reset and the matched-arm logic that re-searches.
- Actions: `IterNext`, `IterNextBack`, `IterCrossover` (sets head/tail to none and `finished=False`), `IterRewind` (the buggy transition where `finished=False` and head=None re-enters search).
- Granularity: keep iter step as one action; but split `Crossover → SubsequentCall` to expose the rewind window.
- Invariant: `IterFusedAfterExhaust` — once an iterator has yielded `None`, all subsequent calls yield `None` (or only yield keys strictly larger than the largest already-yielded key).

**Priority**: High
**Rationale**: 4 confirmed rewind sites with the same shape. Already-fixed precedent for `RefIter`. Open issue (#1142) and open PR (#1252) only cover 1 of 4 sites — the brief expansion to all 4 is a real, model-checkable property.

---

### Family 2: Insert install-then-mark transient duplicate (MEDIUM)

**Mechanism**: PR #1101 fixed issue #1023 by reordering insert: install new at level 0 first, THEN mark the old node's tower. The fix narrows but does not eliminate a window where an iterator can observe two nodes with the same key.

**Evidence**:
- Historical: #1023 / PR #1101 / commit `e7b5922e` — pre-fix, mark-old preceded install-new → reader could find old marked, new not yet installed → `get` returns None despite `len==1`.
- Code analysis: `base.rs:1095-1129` — between level-0 CAS success (line 1104) and `r.mark_tower()` (line 1126), the level-0 chain is `pred → n_new → r → ...` with `r` unmarked. Iterators observe both. `len.fetch_add(1)` happened at line 1085; `len.fetch_sub(1)` (the compensating decrement) only happens at line 1128 inside the `mark_won` branch.
- Code analysis: `base.rs:1273-1288` — at higher levels, between `n.tower[level] = succ` (CAS at 1273) and `pred.tower[level] = node` (CAS at 1288), `n.tower[level]` may be marked by a remover; subsequent traversers help-unlink, but the link persists briefly.

**Affected code paths**:
- `insert_internal` (base.rs:1018-1370)
- `Iter::next` / `Range::next` traversing during the window
- `len()` reading the over-counted value

**Suggested modeling approach**:
- Variables: per-thread `insertState ∈ {Searching, InstalledLevel0, MarkedOld, BuiltLevel(k), Done}`; shared `tower[node][level]` with marker bit.
- Actions: `InsertCASLevel0`, `MarkOld`, `BuildLevel(k)`, `BuildLevelCASFailed(k)`, `PostBuildCheck`.
- Granularity: split InstallNew and MarkOld into separate transitions to expose the duplicate window; `InsertCASLevel0` increments `len`, `MarkOld` decrements it (matching the implementation).
- Invariants: 
  - `IterNoSameKeyTwice` — a single iter traversal yields each key at most once.
  - `LenMatchesUnmarkedLevel0Count` — len equals the count of unmarked nodes reachable at level 0.

**Priority**: Medium
**Rationale**: PR #1101 narrowed but did not close the window. The duplicate is observable to iter / `len()` / `range().count()`. TLA+ is uniquely good at exposing this — exhaustive interleaving exploration will find the iter-during-gap trace easily, and the spec choice of linearization point will determine whether this is reported as a bug or accepted as the design.

---

### Family 3: Tower-CAS memory ordering / SeqCst justification (LOW)

**Mechanism**: Five `TODO(Amanieu): can we use release ordering here?` comments mark sites where SeqCst is used without analysis. Top-down `mark_tower` is implicitly required for PostBuildCheck soundness; a refactor that changes mark order would silently break the invariant.

**Evidence**:
- Code analysis: `base.rs:339, 1100, 1217, 1273, 1288, 1356` — TODO comments and SeqCst orderings.
- Code analysis: `base.rs:1356-1359` — PostBuildCheck only inspects `n.tower[height-1]`; relies on `mark_tower`'s `(0..height).rev()` invariant at line 333.
- Code analysis: `base.rs:297-307` — refcount drop uses Release fetch_sub + Acquire fence on zero (canonical Boost shared_ptr pattern).
- Issue #204 (closed, no fix) — atomicity claim discussion; maintainers note Java's ConcurrentSkipListMap uses Acquire/Release ordering, not full SeqCst.

**Affected code paths**: All tower CAS sites (insert / mark_tower / unlink / search) and the help_unlink path.

**Suggested modeling approach**:
- Label each modeled atomic with its implementation ordering (SeqCst, Release, Relaxed, etc.).
- Hypothetical-weakening run: deliberately downgrade one SeqCst at a time to Release/Acquire/Relaxed, check whether invariants still hold. Report counterexamples as **robustness/sensitivity** results, not implementation bugs (the implementation uses SeqCst).
- Specifically test: would weakening `mark_tower`'s `fetch_or(1, SeqCst)` to `fetch_or(1, Release)` break PostBuildCheck?

**Priority**: Low (research / robustness, not active bug)
**Rationale**: Per `concurrent-analysis.md` § 5.5, memory-ordering modeling for lock-free is a sensitivity check — useful but secondary to interleaving. The main payoff is identifying which TODOs are safe to relax (perf gain) vs which are load-bearing.

---

### Family 4: Caller misuse — concurrent iter + insert + remove (MEDIUM)

**Mechanism**: The library documents lock-free semantics. Per `concurrent-analysis.md` § 5.7, the primary fault family for concurrent collections is adversarial caller patterns: concurrent iter + modify, multi-threaded insert/remove, and pin/unpin against in-flight iterators.

**Evidence**:
- Historical: #672, #671, #1178 — refcount leaks under concurrent iter + insert + remove. All fixed but the bug class persisted across multiple regressions (#1178 was a regression of #671's #673 fix).
- Code analysis: `base.rs:1640-1680` — `clear()` doesn't physically unlink; relies on next iteration's `lower_bound` for cleanup. Concurrent insert during `clear()` may observe a half-cleared list.
- Code analysis: `base.rs:1610-1622` — `pop_front` loops `front → pin → remove`. Concurrent removes can cause unbounded retries (livelock under fairness).

**Affected code paths**: `pop_front`, `pop_back`, `clear`, all iterators, `compare_insert`, `get_or_insert`.

**Suggested modeling approach**:
- ClientHarness adversary that non-deterministically issues insert/remove/iter/range/get in any interleaving with bounded concurrency (2-3 threads, 3-4 keys).
- Track refcount per node as state; invariant: `RefcountNonNegative`, `RefcountMatchesHandlesAndInstalls`.
- Liveness: if a thread keeps trying `pop_front` and the list is non-empty after some bound, it eventually returns Some.
- Safety: `get(K)` after `insert(K, V)` (no concurrent remove) returns Some(V).

**Priority**: Medium
**Rationale**: This is the headline modeling target for any concurrent collection per § 5.1 + § 5.7. The bug class has been live (4 regressions in 4 years) and refactor work continues.

---

### Family 5: Reference-count discipline (HIGH historically, mostly fixed) — REFERENCE-ONLY

**Mechanism**: refcount must equal (Entry handles) + (tower-level installations). Off-by-one bugs leak nodes (epoch-deferred finalize never fires) or cause use-after-free (refcount drops to 0 prematurely).

**Evidence**:
- Historical: #672 / PR #673 — mark-loser path leaked refcount.
- Historical: #671 / PR #673 — RefRange missing Drop.
- Historical: #1178 / PR #1217 — `clone_from` overwrote internal RefEntry without decrement (regression of #673).
- Historical: #1143 / PR #1143 (commit `7121fbd4`) — `remove()` returned Some when mark_tower lost.
- Historical: #1131 / closed as dup of #540 — epoch GC backlog (by design).

**Affected code paths**: All operations that increment/decrement refcount (try_acquire, decrement, mark_tower-loser path, all iterator Drops, clone, release, release_with_pin).

**Suggested modeling approach**: **None** — these are well-understood, individually fixed, and the bug class is well-tested. Per `bug-archaeology.md` § 1.4, reproducing closed bugs adds no value. Use as evidence for Family 4 (caller misuse) only.

**Priority**: Reference-only (do not model)

---

### Family 6: API contract / `compare_insert` predicate gap (LOW) — REFERENCE-ONLY

**Mechanism**: `compare_insert` skips predicate when key absent (`base.rs:1018-1196`). Documented behavior; design defect per #1167 (open since 2024). Maintainer suggested changing predicate to `Option<&V>`.

**Evidence**: #1167 (open), #1122 (open).

**Modeling fit**: None — design issue, not a protocol bug.

**Priority**: Reference-only

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Per-thread iter state with explicit cursor null/non-null | Family 1: rewind bug | `iter[t] = [head ↦ Pos, tail ↦ Pos, finished ↦ BOOL]`; transitions explicitly null `head`/`tail` on cross-over and check `finished` on subsequent calls |
| Insert level-0 install vs MarkOld split | Family 2: transient duplicate | Two actions `InsertCASLevel0` and `MarkOld`; thread state machine `Searching → InstalledLevel0 → MarkedOld → BuildLevel(k) → Done` |
| Tower with mark bit per level | Family 2, 3 | `tower[node][level] ∈ Pointer × {marked, unmarked}`; mark_tower transitions top-down |
| Refcount as state variable | Family 4 | `refs[node] ∈ Nat`; transitions track increment/decrement balance |
| `len` as relaxed counter | Family 2, contract | `len ∈ Int` (allow underflow); `Len()` operator clamps `< 0` to 0 |
| Adversarial ClientHarness | Family 4 | Non-deterministic action picker (insert/remove/iter/range/get) under bounded thread/key counts |
| PostBuildCheck top-only inspection | Family 3 | Single-level read at top, with sensitivity check that mark_tower top-down ordering is required |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Random height generation (`random_height`) | Modeling-irrelevant; treat height as non-deterministic input from {1, 2, 3} |
| `crossbeam-epoch` internals | Treat as oracle; abstract `Guard` and `defer_unchecked` as "node retire" + "reclaim after all guards drop" |
| Stacked-borrows / Miri / UB at language level | Already fixed (b8c88aa5); not protocol-level |
| Allocation failure | OOM is documented as `handle_alloc_error` (panic); skip per § 5.3 |
| `compare_insert` predicate semantics | Family 6: design issue, not protocol |
| Memory leak from epoch GC backlog | Family 5: by-design, not a bug |
| Variant memory orderings for sites NOT flagged TODO | Author has analyzed those; flagging them adds noise |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Iterator state machine | `iter[t]: [head, tail, finished]` | Distinguish "unstarted" from "exhausted" — required for FusedIterator semantics | 1 |
| Two-phase insert | `insertState[t]: enum`, `installedAt[t][level]: BOOL` | Split level-0 CAS from MarkOld; expose duplicate window | 2 |
| Top-down mark with marker bit | `tower[n][lvl]: ⟨ptr, mark⟩`, `markPhase[t]: level being marked` | Capture top-down invariant; PostBuildCheck dependency | 2, 3 |
| Refcount accounting | `refs[n]: Nat`, `entries[n]: Set` | Verify balance under all paths | 4 |
| Adversarial harness | `pendingOps: Seq[Op]` | Drive interleaving exploration | 4 |
| Memory-ordering labels | per-action `ordering: enum` | Sensitivity / robustness check | 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `KeysUnique` | Safety | At any state, level-0 chain has at most one unmarked node per key | Family 2 |
| `IterNoSameKeyTwice` | Safety | An iter traversal yields each key at most once | Family 1, 2 |
| `IterFusedAfterExhaust` | Safety | After an iter returns None, subsequent calls return None | Family 1 |
| `RefcountNonNegative` | Safety | `refs[n] ≥ 0` for all nodes | Family 4, 5 |
| `RefcountMatchesHandlesAndInstalls` | Safety | `refs[n] = |entries[n]| + |{lvl : tower-installed[n][lvl]}|` | Family 4 |
| `MarkMonotone` | Safety | Once `marked[n][lvl] = true`, never returns to false | Family 2 |
| `MarkTopDown` | Safety | If `marked[n][lvl] = true`, then `marked[n][lvl'] = true` for all lvl' > lvl | Family 2, 3 |
| `LenIsApproximatelyKeyCount` | Safety | `Len() = |{k: k ∈ unmarked level-0 chain}| ± inflightInserts` | Family 2 |
| `GetReturnsLatest` | Safety | `get(K)` after a completed `insert(K,V)` (no concurrent remove of K, no concurrent insert of K) returns V | Family 4 |
| `NoUseAfterFree` | Safety | Refcount → 0 only after node is unlinked at level 0 | Family 5 (already proven by epoch GC; included for completeness) |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC1 | `Iter::next` after exhaustion returns front again — does any iter cross-over → next sequence yield the same key twice? | `IterFusedAfterExhaust`, `IterNoSameKeyTwice` | 1 |
| MC2 | `Iter::next_back` after exhaustion returns back again | `IterFusedAfterExhaust` | 1 |
| MC3 | `Range::next_back` after exhaustion rewinds to `end_bound()` | `IterFusedAfterExhaust` | 1 |
| MC4 | During the window between InsertCASLevel0 and MarkOld, can Iter observe two unmarked nodes with the same key? | `IterNoSameKeyTwice`, `KeysUnique` | 2 |
| MC5 | During the window between InsertCASLevel0 and MarkOld, can `len()` over-count by more than `inflightInserts`? | `LenIsApproximatelyKeyCount` | 2 |
| MC6 | If insert breaks early at level k (build CAS failed), does the partially-built node's higher-level installs get cleaned up by help_unlink? | `RefcountMatchesHandlesAndInstalls` after grace period | 2 |
| MC7 | If `mark_tower` is bottom-up instead of top-down, does PostBuildCheck miss a marked tower? | `KeysUnique`, novel partial-install reachability | 3 (sensitivity) |
| MC8 | Concurrent `pop_front` from N threads on a list of size 1 — is exactly one returned Some, others None? | `RefcountMatchesHandlesAndInstalls` (no leak), liveness (eventually Some or list empty) | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-----------------------|
| T1 | Iter / Range / next_back rewind reproduction | Add deterministic single-threaded test: build small list, iterate to exhaustion, call next/next_back again, assert None |
| T2 | compare_insert predicate not invoked on absent key | Single-thread test with side-effect predicate (e.g., closure mutates a counter); insert absent key; verify counter unchanged |
| T3 | Stacked-borrows regressions | Already in CI via `cargo +nightly miri test`; no action |
| T4 | `len()` over/under-count under heavy contention | Stress test: N threads doing insert/remove on overlapping keys, periodically verify `len()` is bounded by `[0, max_observed_size]` |
| T5 | Refcount leak regression for clear/iter/range Drop | Run existing tests under ASan; add `LoudDrop`-style accounting tests for new code paths |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| R1 | 5 `TODO(Amanieu): can we use release ordering here?` sites | Memory-ordering audit; confirm safe weakening; document load-bearing top-down `mark_tower` |
| R2 | `compare_insert` doc inconsistency (#1167, #1122) | Update doc to clarify "predicate not invoked when key absent"; consider API change to `Option<&V>` predicate (per maintainer suggestion) |
| R3 | `lib.rs:70-73` atomicity claim overstates (per #204) | Replace "race conditions are impossible" with "point operations are linearizable; len/iter are eventually-consistent approximations" |
| R4 | `Iter` and `Range` rewind (forward + backward) — extend PR #1252 fix | Apply the `finished` flag pattern from PR #1252 to `Range::next_back`, `Iter::next`, and `Iter::next_back`. Adopt the `RefIter`/`RefRange` "retain cursor" approach as alternative. |
| R5 | `clear()` couples mark with next-batch unlink | Document that `clear` does not physically unlink; consider explicit cleanup pass |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/crossbeam-skiplist_2/.specula-output/analysis-report.md`
- **Source code**:
  - `artifact/crossbeam/crossbeam-skiplist/src/base.rs` (2653 LOC) — entire skiplist implementation
  - `artifact/crossbeam/crossbeam-skiplist/src/map.rs` / `set.rs` — type-safe wrappers
  - `artifact/crossbeam/crossbeam-skiplist/src/tla_trace.rs` (518 LOC) — `tla-trace` cargo feature; emits per-thread NDJSON traces with rdtsc intervals
- **Tests**: `artifact/crossbeam/crossbeam-skiplist/tests/{base,map,set}.rs`
- **GitHub issues** (key references):
  - Family 1: #737 (RefIter, fixed), #1142 (open), PR #1252 (open)
  - Family 2: #1023 (closed by PR #1101)
  - Family 3: #204 (closed, design discussion); 5 TODO sites in source
  - Family 4: #672, #671, #1143, #1178 (all closed)
  - Family 5: #1131 (dup of #540); design notes in lib.rs
- **Reference algorithm**: William Pugh, "Skip Lists: A Probabilistic Alternative to Balanced Trees" (CACM 1990); concurrent variant follows Fraser & Harris (2007).
- **Trace validation hints** (from tla_trace.rs): emits `Insert{Begin, AllocCASLevel0, MarkOld, BuildLevel, PostBuildCheck}`, `Remove{Begin, Acquire, MarkTower, UnlinkLevel}` with rdtsc intervals — spec author should mirror these as TLA+ actions for OmniLink-style trace validation.
