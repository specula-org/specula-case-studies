# Confirmed Bug Report — crossbeam-skiplist_2

## Summary

- Total findings reviewed: 7 (1 MC-confirmed bug; 4 modeling-brief families F2–F5 not surfaced by MC; 2 reference-only families F5/F6)
- Reproduced: **1** (all four affected sites in Bug 1, six sub-tests, all FAIL → bug present)
- Confirmed (code audit, reproduction failed): 0
- False positives / not-bugs: 0
- Inconclusive (MC ran clean within budget): 3 (F2 install-then-mark, F3 memorder, F4 caller misuse)
- Reference-only / out-of-scope: 2 (F5 refcount discipline — already fixed; F6 `compare_insert` predicate — design issue)

The principal new finding is **Bug 1: Iterator Rewind After Exhaustion** at four sites in `base.rs`. The MC counterexample (11 states, 5 s wall-clock) flagged `Iter::next`; code audit showed the same shape at three more sites (`Iter::next_back`, `Range::next`, `Range::next_back`). All four sites are reached by direct, single-threaded use of the public `SkipList` API, and a single test file with six sub-tests reproduces them all (`repro/test_bug1_iter_rewind.rs` + `run_bug1.sh`).

The other modeling-brief findings either (a) had no MC violation within budget, (b) are reference-only families already fixed in the implementation (F5), or (c) are documented design choices (F6). They are recorded below for traceability with appropriate tier downgrades.

---

## Bug 1: Iterator Rewind After Exhaustion (FusedIterator semantics broken)

- **Source**: MC (counterexample at `MC_hunt_family1_iter_rewind.cfg`, 11 states; bug-report.md §"Bug 1") + code review (modeling-brief Family 1)
- **Status**: **REPRODUCED** (6/6 sub-tests fail — bug triggered at all four affected sites)
- **Severity**: High
- **Location**:
  - `crossbeam-skiplist/src/base.rs:2098-2120` — `Iter::next`
  - `crossbeam-skiplist/src/base.rs:2126-2147` — `Iter::next_back`
  - `crossbeam-skiplist/src/base.rs:2287-2320` — `Range::next`
  - `crossbeam-skiplist/src/base.rs:2329-2361` — `Range::next_back`

### Description

After `Iter::next` (and `Iter::next_back`, `Range::next`, `Range::next_back`) reaches exhaustion — either by walking past the last/first node, or by head-tail crossover from `DoubleEndedIterator` interleaving — the iterator's internal `head`/`tail` cursor is reset to `None`. The next invocation distinguishes only two cases via a `match self.head { Some(n) => …, None => … }`. The `None` arm is the same arm taken on a fresh iterator and re-enters `next_node(self.parent.head.as_tower(), Bound::Unbounded, …)` (or `search_bound` for `Range`/`next_back`), which **rewinds** the iterator to the front (resp. back, or `start_bound`/`end_bound`) of the structure.

This breaks Rust's `FusedIterator` contract ("once an iterator returns `None`, all subsequent calls return `None`"). Concrete observations:

```rust
// base.rs:2098-2120, Iter::next (forward)
self.head = match self.head {
    Some(n) => self.parent.next_node(n.as_tower(), Bound::Excluded(&n.key), self.guard),
    None    => self.parent.next_node(self.parent.head.as_tower(),    // ← REWIND
                                     Bound::Unbounded, self.guard),
};
if let (Some(h), Some(t)) = (self.head, self.tail) {
    if self.parent.comparator.compare(&h.key, &t.key).is_ge() {
        self.head = None; self.tail = None;                          // ← exhaust resets
    }
}
```

The `RefIter`/`RefRange` siblings (`base.rs:2188-2261`, `base.rs:2410-...`) avoid this by **retaining** the `RefEntry` cursor on the exhaust path — they return `None` without nulling `head`/`tail`, so subsequent invocations re-evaluate the crossover predicate against the same retained boundary and consistently return `None`. That fix shipped as part of issue #737 / commit `e6d70ca8` ("Keep skiplist iterator ordered", 2021), confirmed by `git show e6d70ca8`.

### Trigger scenarios

Each scenario uses only the public `SkipList` API. Six are demonstrated in `repro/test_bug1_iter_rewind.rs`; in every case the assertion `iter.next().is_none()` after exhaustion fails because the iterator returns `Some(...)` again.

| # | Sub-bug | Setup | Sequence | Observed |
|---|---|---|---|---|
| 1a | `Iter::next` exhaustion | `{42}` | `next()` → 42; `next()` → None; `next()` | 42 (REWIND) |
| 1b | `Iter::next` crossover | `{1,2,3,4,5}` | alternate next/next_back until crossover; `next()` → None; `next()` | 1 (REWIND) |
| 1c | `Iter::next_back` exhaustion | `{42}` | `next_back()` → 42; `next_back()` → None; `next_back()` | 42 (REWIND) |
| 1d | `Range::next` exhaustion | `{5,10,15}`, range `..` | exhaust forward; `next()` → None; `next()` | 5 (REWIND) |
| 1e | `Range::next_back` exhaustion | `{5,10,15}`, range `..` | exhaust backward; `next_back()` → None; `next_back()` | 15 (REWIND) |
| 1f | `Range::next` bounded crossover | `{1..7}`, range `[3,6)` | alternate; crossover; `next()` → None; `next()` | 3 (REWIND to `start_bound`) |

### Developer intent investigation

- **Issue #737 ("Iter rewinds to front after returning None") + commit e6d70ca8** — this exact bug shape is already on record for `RefIter`/`RefRange`, where it was fixed by retaining the `RefEntry` cursor on the exhausted path. The fix did **not** propagate to `Iter`/`Range`. *git history confirms*.
- **Open issue #1142 + open PR #1252 ("Range::next rewinds")** — the modeling brief cites these. The maintainers know `Range::next` rewinds, and the proposed fix is a `finished: bool` flag. PR #1252 currently only patches `Range::next`; the other three sites (`Iter::next`, `Iter::next_back`, `Range::next_back`) are NOT in that PR. The brief identifies this as "1 of 4 sites covered."
- **Existing tests** — `tests/map.rs::ordered_iter` and `ordered_range` (lines 251-302) explicitly assert FusedIterator-like semantics on `SkipMap`'s iterator. But `SkipMap::iter()` wraps `base::RefIter`, not `base::Iter` (`map.rs:224-228, 717-718`), so the existing tests pass. The buggy `Iter`/`Range` are reachable via the publicly re-exported `crossbeam_skiplist::SkipList` (`lib.rs:260`), but no test in `tests/base.rs` exercises the exhaust-then-call-again pattern (`tests/base.rs:587-596` calls `it.next()` exactly once after exhaustion).
- **Conclusion**: Maintainers have identified this exact behavior as a bug (PR #1252) and a fix exists for the sibling type (RefIter/RefRange). The four affected sites here are an incomplete fix, not a deliberate trade-off. By the developers' own stated intent (PR #1252), the rewind is bug behavior.

### Prerequisites

```
Prerequisites:
- [code] `Iter` and `Range` are publicly reachable from user code: VERIFIED
    `lib.rs:253,260` — re-exports `base` module and `base::SkipList`; SkipList::iter (base.rs:654)
    and SkipList::range (base.rs:674) return `base::Iter` and `base::Range` directly.
- [code] The `match self.head { Some(_) => …, None => REWIND }` pattern is reachable: VERIFIED
    base.rs:2099-2107 (Iter::next), 2127-2134 (Iter::next_back),
    2288-2295 (Range::next), 2329-2336 (Range::next_back).
- [code] `head`/`tail` are reset to None on exhaust/crossover: VERIFIED
    base.rs:2110-2112, 2137-2139, 2300-2310, 2342-2353.
- [spec] FusedIterator contract is the developer's intended semantics: VERIFIED
    Open PR #1252 + closed #737 + commit e6d70ca8 = "iterator must not rewind after None."
    The maintainers' own fix on the sibling type (RefIter/RefRange) is the canonical evidence.
- [code] The bug is reachable WITHOUT concurrency, WITHOUT the `tla-trace` feature,
   in single-threaded code on the default cargo build: VERIFIED — see repro test output.
```

### Counterfactual fix check

Not applicable. The violated invariant (`IteratorFusion`) is a per-instance, per-call property of the iterator state machine, not a system-wide property like "some session can never close" or "two replicas can disagree." The bug *is* the missing `finished` check (or "retain cursor" pattern) on these specific code paths; there is no broader bad-outcome class to search for alternative paths to.

### Report Tier: **A**

Externally observable, hard-to-recover correctness bug. A user iterating to exhaustion and then continuing to call `.next()` (e.g., behind a `while let Some(x) = iter.next()` that the user hand-codes — or any consumer that doesn't internally rely on the iterator being terminated) will silently see the iterator restart and yield duplicates indefinitely. This can corrupt accumulators, hashmaps, set differences, etc. that consume `Iter`/`Range`. No panic; no memory unsafety. But "the iterator never terminates and re-emits old data" is a Tier A correctness violation.

### Reproduction test

- File: `.specula-output/repro/test_bug1_iter_rewind.rs` (Rust integration test)
- Runner: `.specula-output/repro/run_bug1.sh` (copies the test into `tests/`, runs `cargo test`, removes the test, prints the output)
- Coverage: 6 sub-tests, one per affected site × triggering condition (exhaustion vs crossover vs bounded range).

### Reproduction result

**REPRODUCED — 6/6 sub-tests trigger the bug.**

Exact command (from runner script): `timeout 120s cargo test --test test_bug1_iter_rewind`. Full output is saved to `repro/test_bug1_iter_rewind.out`. Key excerpts:

```
running 6 tests
test iter_next_rewinds_after_crossover ... FAILED
test iter_next_back_rewinds_after_exhaustion ... FAILED
test iter_next_rewinds_after_single_element_exhaustion ... FAILED
test range_next_back_rewinds_after_exhaustion ... FAILED
test range_next_rewinds_to_start_bound_after_crossover ... FAILED
test range_next_rewinds_after_exhaustion ... FAILED

---- iter_next_rewinds_after_crossover stdout ----
panicked at ...:88:5:
after crossover, Iter::next should keep yielding None,
but got Some(k=Some(1)) — REWIND BUG triggered

---- iter_next_back_rewinds_after_exhaustion stdout ----
panicked at ...:112:5:
after exhaustion, Iter::next_back should keep yielding None,
but got Some(k=Some(42)) — REWIND BUG triggered

---- iter_next_rewinds_after_single_element_exhaustion stdout ----
panicked at ...:55:5:
after exhaustion, Iter::next should keep yielding None,
but got Some(k=Some(42)) — REWIND BUG triggered

---- range_next_back_rewinds_after_exhaustion stdout ----
panicked at ...:163:5:
after exhaustion, Range::next_back should keep yielding None,
but got Some(k=Some(15)) — REWIND BUG triggered

---- range_next_rewinds_to_start_bound_after_crossover stdout ----
panicked at ...:190:5:
after crossover, Range::next should keep yielding None,
but got Some(k=Some(3)) — REWIND BUG triggered (rewinds to start_bound=3)

---- range_next_rewinds_after_exhaustion stdout ----
panicked at ...:138:5:
after exhaustion, Range::next should keep yielding None,
but got Some(k=Some(5)) — REWIND BUG triggered

test result: FAILED. 0 passed; 6 failed; 0 ignored; 0 measured;
            0 filtered out; finished in 0.00s
```

Each `panicked at ...REWIND BUG triggered` line is direct evidence: the iterator returned `Some(...)` after a previous `next()` had already returned `None`. The keys returned (`42`, `1`, `5`, `15`, `3`) match the expected rewind targets (front of list, front of list, front of range, back of range, `start_bound` of bounded range), confirming the root cause is the `next_node`/`search_bound` re-entry on the `None` arm of the match.

The MC trace's specific shape (insert k2, iterate, exhaust, see k2 again) is captured by sub-test 1a (`iter_next_rewinds_after_single_element_exhaustion`) and is the closest-by-construction reproduction.

### Recommendation

Apply the `finished` flag pattern from PR #1252 to all four sites. Concretely, add `finished: bool` to `Iter` and `Range` and:
1. Initialize `finished = false`.
2. Set `finished = true` whenever the iterator transitions to "no more results" (both the natural-exhaustion path returning `None` and the head-tail crossover path).
3. Short-circuit at the top of `next`/`next_back` to return `None` immediately when `finished` is set, before the `match self.head` re-entry.

Alternative (already proven in the sibling code): adopt the `RefIter`/`RefRange` "retain cursor" approach — return `None` from the crossover branch *without* clearing `head`/`tail`. This requires no new field; the crossover predicate continues to evaluate against the retained values on every subsequent call.

PR #1252 should be expanded from `Range::next` only to all four affected sites before merging.

---

## Findings 2-7: Not Reproduced / Reference-Only / Inconclusive

These findings come from the modeling brief but did not produce confirmed counterexamples. Each is recorded for traceability; tier follows the bug-confirmation guide's per-finding rules.

### Finding 2: F2 — Insert install-then-mark transient duplicate

- **Source**: Code review (modeling-brief Family 2; bug-report.md "Why F2 didn't surface")
- **Status**: INCONCLUSIVE (MC ran clean within 30 min BFS / 30 min simulation budgets)
- **Location**: `base.rs:1095-1129` (level-0 install vs `mark_tower`); `base.rs:1273-1288` (higher-level link vs mark)
- **Evidence**: Historical issue #1023 / PR #1101 / commit `e7b5922e` resolved one direction (mark-old-then-install-new). The current shipping order is install-new-then-mark-old; the brief asked whether the *transient duplicate* between InstallNew and MarkOld is observable to a concurrent iterator.
- **Why no MC violation**: The shipped `KeysUnique`/`IterNoSameKeyTwice` invariants carve out `pc[t].step ∈ {MarkOld, BuildLevel, PostBuildCheck}` precisely to permit the in-flight transient (bug-report §"Why F2 didn't surface"). Adversarial schedules at 2 threads × 4 keys with 735M distinct states (BFS) and 2.88B simulation states found no violation outside the carve-out.
- **Counterfactual fix check**: Not applicable — there is no candidate fix to apply because there is no current violation. The carve-out is by design (matches the actual implementation: `len.fetch_add(1)` at line 1085, `len.fetch_sub(1)` at line 1128 inside `mark_won`).
- **Report Tier**: C (inconclusive within explored space; no observable harm demonstrated).
- **Recommendation**: Keep the invariant carve-outs as-is; document `len()` as eventually-consistent (per modeling-brief R3). Ship the linearization-point spec note in `lib.rs:70-73` so callers don't expect strict equality.
- **Reproduction**: Not attempted — no counterexample to reproduce.

### Finding 3: F3 — Tower-CAS memory ordering / SeqCst sensitivity

- **Source**: Code review (modeling-brief Family 3; bug-report.md "Why F3 didn't surface")
- **Status**: INCONCLUSIVE (MC ran exhaustively at the spec's chosen abstraction; no violation)
- **Location**: 5 `TODO(Amanieu): can we use release ordering here?` sites in `base.rs:339, 1100, 1217, 1273, 1288, 1356`
- **Evidence**: SeqCst is used at every CAS without analysis; the brief flagged this as a robustness/sensitivity question, not a known bug.
- **Why no MC violation**: The base spec collapses `mark_tower`'s level loop into a single transition (base.rs:303-315 comment). Per the brief's explicit modeling trade-off, intermediate per-level states inside `mark_tower` are not modeled. The `FaultMarkBottomUp` flag therefore can't change reachable states at this granularity. 5.37M distinct states explored exhaustively.
- **Report Tier**: C (no observable harm; per `concurrent-analysis.md` § 5.5 this is robustness research, not an active bug).
- **Recommendation**: Keep the TODOs as-is until a finer-grained spec or hardware-level test (e.g., `loom`) provides evidence one way. The PostBuildCheck top-only invariant (`base.rs:1356-1359`) is load-bearing — whoever weakens `mark_tower` ordering must verify PostBuildCheck still holds.
- **Reproduction**: Not attempted — no counterexample.

### Finding 4: F4 — Caller misuse (concurrent iter+insert+remove+pop_front)

- **Source**: Code review (modeling-brief Family 4; bug-report.md "Why F4 didn't surface")
- **Status**: INCONCLUSIVE (MC ran clean: 767M BFS states + 5.05B simulation states)
- **Location**: `base.rs:1610-1622` (`pop_front`/`pop_back` retry loops); `base.rs:1640-1680` (`clear`).
- **Evidence**: Refcount discipline regressions (#672, #671, #1143, #1178) — all closed and fixed in the implementation; the spec models the post-fix invariants.
- **Why no MC violation**: The post-fix invariants hold under 2-thread × 2-op × 1-key adversarial schedules at the configured bound. Per modeling-brief Family 5 carry-over, this family is "well-understood and individually fixed."
- **Report Tier**: C (no new finding; existing fixes are validated).
- **Reproduction**: Not attempted — no counterexample.

### Finding 5: F5 — Reference-count discipline (REFERENCE-ONLY)

- **Source**: Code review (modeling-brief Family 5)
- **Status**: KNOWN-HISTORICAL (all four cited issues #672, #671, #1143, #1178 are closed and fixed)
- **Location**: All refcount-touching paths (`try_acquire`, `decrement`, `mark_tower`-loser, all iterator `Drop`s, `clone`, `release`, `release_with_pin`).
- **Evidence**: Modeling brief explicitly excluded this family from active modeling per `bug-archaeology.md` § 1.4 ("reproducing closed bugs adds no value").
- **Report Tier**: C (reference-only).
- **Recommendation**: None. Existing CI (`cargo test`, ASan, Miri) catches future regressions.

### Finding 6: F6 — `compare_insert` predicate gap (REFERENCE-ONLY)

- **Source**: Code review (modeling-brief Family 6)
- **Status**: KNOWN-DESIGN-ISSUE (open issues #1167, #1122)
- **Location**: `base.rs:1018-1196` — `compare_insert` skips predicate when key absent.
- **Evidence**: Documented design defect; maintainer suggested API change to `Option<&V>` predicate.
- **Report Tier**: C (design issue, not a protocol bug).
- **Recommendation**: Pursue the maintainer's `Option<&V>` API change (out of scope for this case study).

### Finding 7: lib.rs atomicity claim overstates (R3 in modeling brief)

- **Source**: Code review (modeling-brief Family 3 reference R3)
- **Status**: NOT-A-BUG (documentation hygiene)
- **Location**: `lib.rs:70-73` — "race conditions are impossible" overstates what is actually guaranteed.
- **Evidence**: Issue #204 (closed, design discussion). Per modeling-brief, point operations are linearizable; `len`/`iter` are eventually-consistent approximations.
- **Report Tier**: C (documentation accuracy, not a behavior bug).
- **Recommendation**: Update `lib.rs:70-73` to: "Point operations (`get`, `insert`, `remove`, `contains`) are linearizable. `len()` and iterators provide an eventually-consistent view: a concurrent insert/remove may or may not be reflected, and `len()` may transiently disagree with the count of keys observed by an iterator."
- **Reproduction**: Not applicable — documentation issue.

---

## Notes on the bug-report's "Spec Fixes Applied During Hunting"

The bug report records that during F2 hunting the spec was strengthened to model the level-0 CAS contention precondition (`Insert_AllocCASLevel0`). A pre-fix spec run had reported a `KeysUnique` violation that turned out to be a spec-abstraction error, not a real implementation bug — the implementation's `compare_exchange` at `base.rs:1095-1104` already prevents two concurrent inserts of the same key from both succeeding at level 0. After the spec fix, all 5 baseline traces still pass. This is a *spec correction*, not a bug in the implementation; recorded here for completeness, not as a separate finding.
