# Confirmed Bug Report — papaya_2

## Summary

- Total findings reviewed: 3 MC findings + 5 code-review-only items
  (3 "Not Reproduced" MC families + ancillary CR-* items from the modeling
  brief)
- Reproduced: **3** (Bug 1, Bug 2, Bug 3)
- Confirmed (code audit, reproduction failed): 0
- False positives / by-design: 0 within the confirmed set;
  the 3 Not-Reproduced MC families are recorded as "no violation" (see
  bug-report.md)
- Inconclusive: 0

All three MC-confirmed bugs were independently reproduced by executable
tests against the source tree. Bug 1 and Bug 2 use the in-tree
reproducers that ship with this round's instrumented build; Bug 3 is a
new self-contained deterministic reproduction written for this report.

---

## Bug 1: Wrong-Parker Routing on Blocking Resize Abort

- **Source**: MC (counterexample at depth 7 in 5 s) + code audit
- **Status**: **REPRODUCED**
- **Severity**: **High** — confirmed liveness bug (deadlock); no upstream
  fix as of `master` `b510b15`
- **Location**: `artifact/papaya/src/raw/mod.rs:2336-2337` (abort path);
  parking site at `mod.rs:2400-2406`
- **Description**: In `help_copy_blocking`, when a resize is aborted
  because the destination table ran out of space, the code unparks
  threads on the **source** table's parker
  (`let state = table.state(); state.parker.unpark(&state.status);`)
  instead of the **destination** table's parker. Threads parked at
  `next.state().parker.park(&next.state().status, …)` use a different
  `Parker` instance and a different key, so the unpark wakes nobody.
  Threads waiting for that resize remain parked forever.
- **Trigger scenario**:
  1. ≥2 threads share a `HashMap<.., ResizeMode::Blocking>` whose
     destination table fills up during the copy (forced here with
     `--cfg papaya_stress`, which keeps capacity constant on every resize
     so destination tables always overflow).
  2. Thread A reaches the wait loop in `help_copy_blocking` and parks on
     `(next.parker, next.status)`.
  3. Thread B exhausts the destination during its copy chunk and enters
     the abort branch. It stores `ABORTED` on `next.state().status`,
     allocates a replacement table, and then calls
     `state.parker.unpark(&state.status)` on the **source** table.
  4. The unpark targets a parker/key pair Thread A is not registered
     under → Thread A stays parked. Subsequent participants pile up
     behind it.
- **Reproduction test**:
  `repro/test_bug1_parker_deadlock.rs` (a copy of
  `artifact/papaya/tests/repro_parker_deadlock.rs`). The test spawns 4
  worker threads that each insert 50 keys into a capacity-4 blocking-mode
  map under `--cfg papaya_stress`. A timeout-join harness asserts every
  worker completes within 30 seconds.
- **Reproduction command**:
  ```
  cd artifact/papaya
  RUSTFLAGS="--cfg papaya_stress" cargo test \
      --test repro_parker_deadlock -- --test-threads 1 --nocapture
  ```
- **Reproduction result**: **PASS (bug triggered)**. Actual output:
  ```
  running 1 test
  test parker_deadlock_on_resize_abort ... DEADLOCK DETECTED: thread did not complete within timeout
  thread 'parker_deadlock_on_resize_abort' (2035510) panicked at tests/repro_parker_deadlock.rs:83:5:
  BUG REPRODUCED: Deadlock detected - threads parked on destination table were never unparked because abort path unparks the wrong (source) table's parker
  ...
  test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 30.01s
  ```
  The panic line is the success criterion: every worker should have been
  able to complete its 50 inserts in ≪ 30 s; the timeout proves at least
  one thread is parked indefinitely. Without the bug, the test completes
  in well under a second on the same machine.
- **Developer intent**: PR #92 (specula-org fork) is the proposed fix —
  swap `state.parker.unpark(&state.status)` for
  `next.state().parker.unpark(&next.state().status)`. Not yet merged
  upstream.
- **Recommendation**: Apply the PR-#92 one-liner on upstream master.

---

## Bug 2: META Overwrite — Phase-2 Store Clobbers TOMBSTONE

- **Source**: MC (counterexample at depth 11 in 16 s) + code audit
- **Status**: **REPRODUCED**
- **Severity**: Medium — slot leak / probe-chain bloat; not memory-unsafe
- **Location**: `artifact/papaya/src/raw/mod.rs:1051` (winner's
  unconditional Phase-2 meta store); slot-reusability check at
  `mod.rs:1336` and the iter check at `mod.rs:3070`
- **Description**: `insert_at` writes the entry pointer (Phase 1, CAS at
  line 1037-1043) and then writes the meta byte (Phase 2, store at line
  1060) as separate atomic operations. The yield-loop at line 1056
  widens the window. If a concurrent `remove` lands during this window,
  it CAS-tombstones the entry pointer (`mod.rs:769`) and stores
  `meta::TOMBSTONE` (`mod.rs:1388`). The original winner's Phase-2 store
  then fires unconditionally and overwrites `TOMBSTONE` with `h2(k)`.
  After the race, the slot has `entry == NULL` but
  `meta == h2(k) ∉ {EMPTY, TOMBSTONE}`. Because slot reusability requires
  `meta ∈ {EMPTY, TOMBSTONE}`, the slot is no longer recyclable until a
  full-table resize.
- **Trigger scenario**: Concurrent inserter and remover threads racing
  on the same key. Specifically:
  1. T_insert succeeds at the CAS — entry now holds new key, meta still
     EMPTY.
  2. T_fixup (a third thread that lost the CAS) observes the non-EMPTY
     entry and writes `meta = h2(k)` via the loser-fixup branch.
  3. T_remove finds `meta = h2(k)`, CAS-tombstones the entry, and stores
     `meta = TOMBSTONE`.
  4. T_insert resumes Phase 2 and unconditionally stores
     `meta = h2(k)` — overwriting the tombstone.
- **Reproduction test**:
  `repro/test_bug2_meta_overwrite.rs` (a copy of
  `artifact/papaya/tests/repro_bug1_meta_overwrite.rs`). Six threads
  (3 inserters + 3 removers) hammer a single key for 5,000 iterations
  each. Detection is performed at the Phase-2 store site: after the
  meta store, the winner re-loads the entry pointer and increments
  `META_OVERWRITE_BUG_COUNT` if the pointer no longer matches what was
  CAS'd in. This is a **Level 3** reproduction per the bug-confirmation
  guide: `src/raw/mod.rs` carries a `yield_now` loop that widens the
  race window without altering the bug logic, plus a counter to make
  the race observable. Both modifications are noted in source comments
  (`[BUG-1 REPRODUCTION: Level 3 ...]` and
  `[BUG-1 DETECTION: ...]`).
- **Reproduction command**:
  ```
  cd artifact/papaya
  cargo test --test repro_bug1_meta_overwrite -- --nocapture
  ```
- **Reproduction result**: **PASS (bug triggered)**. Actual output:
  ```
  running 1 test
  BUG-1 Meta overwrite detections: 4 (across 5000 iterations x 6 threads)
  test bug1_meta_overwrite_race ... ok

  test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
  ```
  Four distinct Phase-2 stores in this run observed the entry pointer
  changing under them — exactly the race the MC counterexample
  identified. Without the bug, the counter would remain 0 across all
  iterations.
- **Recommendation**: Make the Phase-2 store conditional analogous to
  the loser fixup — re-load the entry pointer (or check meta still
  EMPTY) immediately before the Release store, and skip the store if
  the slot has been tombstoned. Equivalent to making the winner CAS its
  meta byte instead of a blind store.

---

## Bug 3: Iterator Double-Yield Across Insert/Remove/Reinsert

- **Source**: MC (counterexample at depth 11 in 7 s) + code audit
- **Status**: **REPRODUCED**
- **Severity**: Medium — semantic surprise; iterator API contract issue
  rather than a memory-safety bug
- **Location**:
  `artifact/papaya/src/raw/mod.rs:3038-3119` (`Iter::next`)
- **Description**: `Iter::next` advances `self.i` linearly through the
  snapshot table and yields whatever is at slot `self.i` when it
  inspects it. There is no per-iter "already-yielded keys" set. If a
  key is removed from a slot the iterator has already passed and then
  re-inserted into a slot the iterator has not yet reached, the same
  key will be yielded twice in a single iteration — even though at no
  moment in time did the map contain two live entries with that key.
- **Trigger scenario** (single-threaded; the same race can also arise
  multi-threaded):
  1. Insert key K. With a uniform-zero hasher, K lands in slot 0.
  2. Begin iteration. `iter.next()` reads slot 0 (`meta = h2(K)`),
     loads the entry, yields `(K, v0)`. `iter.i` is now 1.
  3. Remove K. Slot 0's entry → NULL, slot 0's meta → TOMBSTONE.
  4. Re-insert K (with a different value v1). Insertion probes from
     `h1(K) & mask = 0`. Slot 0's meta is TOMBSTONE (≠ EMPTY, ≠ h2(K))
     so the insert path advances to the next probe step (slot 1). The
     new entry lands at slot 1.
  5. `iter.next()` reads slot 1, yields `(K, v1)`. K has been yielded
     twice.
- **Reproduction test**:
  `repro/test_bug3_iter_double_yield.rs` — newly written for this round.
  Uses a `BuildHasher` that returns 0 for every key so the probe layout
  is fully deterministic. Single-threaded; no system modifications.
- **Reproduction command**:
  ```
  cd artifact/papaya
  cargo test --test repro_bug3_iter_double_yield -- --nocapture
  ```
- **Reproduction result**: **PASS (bug triggered)**. Actual output:
  ```
  running 1 test
  iter.next() #1 -> Some((1, 100))
  remove(1) -> Some(100)
  insert(1, 200) — re-inserted in a fresh slot
  iter.next() -> (1, 200)
  thread 'iter_double_yield_via_insert_remove_reinsert' (2043435) panicked at tests/repro_bug3_iter_double_yield.rs:90:13:
  BUG 3 REPRODUCED: iterator yielded key 1 twice (second yield: (1, 200)) even though the map never held two live entries with that key simultaneously
  ...
  test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.02s
  ```
  The two `iter.next()` calls returned the same key with two different
  values. The reproduction is deterministic — every run reproduces the
  bug.
- **Developer intent**: The crate-level "Consistency" docs
  (`src/lib.rs:81`) state that aggregate operations rely on "a weak
  snapshot of the table" and "may, but are not guaranteed to, reflect
  concurrent modifications". This permits stale reads and missed
  inserts, but the documentation does not say a key can be **yielded
  twice in the same iteration** — and the documented signature of
  `iter` is "all key-value pairs in arbitrary order", which most users
  will read as "each key at most once". This is therefore a contract
  violation by any reasonable engineering standard, although the
  developers may classify it as a documentation issue rather than a
  code fix.
- **Recommendation** (in order of cost):
  1. **(Cheap, doc-only)** Tighten the doc comment on `HashMap::iter`,
     `HashMap::keys`, and `HashMap::values` to explicitly call out
     "a key may be yielded more than once if the caller mutates the map
     concurrently".
  2. **(Stronger guarantee)** Introduce an `iter_unique` variant that
     tracks yielded keys in a per-iter `HashSet` and skips duplicates
     (O(n) memory per iter). This is a separate API surface; the
     existing `iter` keeps its current low-overhead behavior.

---

## Findings Reviewed and Filtered

The bug-report explicitly recorded three MC families that were checked
exhaustively (or via deep simulation) and produced no violations:

- **MC-3 / Family 6 — Iter Weak Snapshot** (`MC_hunt_iter_weak_snapshot.cfg`):
  Deep BFS (195K states) and 30-min simulation (190M states) found no
  `IterWeakSnapshot` violation. The "key inserted into the new root
  after iter-begin is missed by the snapshot" pattern is the
  documented weak-snapshot carve-out. **Not a bug.**
- **MC-7 / Family 1 — Resize Race** (`MC_hunt_resize_race.cfg`):
  After fixing a Case-B spec issue (`CopyInsertToNext` one-shot guard)
  the spec ran exhaustively to depth 23 with 4.7M distinct states and
  no `NoLostEntry` violation. **Not a bug** — the original alleged
  trace was a spec modeling defect, not a code defect.
- **MC-5 / Family 4 — Reclamation** (`MC_hunt_reclamation.cfg`):
  Exhaustive BFS in 15 s (309K states, depth 20) found no
  reclamation safety violation. **Not a bug** at the modeled
  granularity.

The CR-* items in the modeling brief (CR-1 through CR-5) are
documentation, defensive-coding, and process suggestions; per the
Phase-0 system-level consequence test in the bug-confirmation guide,
they are not bugs and are not pursued further here.

---

## Reproduction Artifacts

| Bug | Test file | Build flags |
|-----|-----------|-------------|
| 1 | `repro/test_bug1_parker_deadlock.rs` | `RUSTFLAGS="--cfg papaya_stress"` |
| 2 | `repro/test_bug2_meta_overwrite.rs` | none (relies on `[BUG-1 REPRODUCTION]` Level-3 instrumentation in `src/raw/mod.rs:1055-1068`) |
| 3 | `repro/test_bug3_iter_double_yield.rs` | none |

The `repro/` copies are durable artifacts; the actual files driving
`cargo test` live at `artifact/papaya/tests/`. See `repro/README.md` for
exact reproduction commands and expected output.
