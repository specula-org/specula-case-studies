# Confirmed Bug Report — scc_2

## Summary

- Total findings reviewed: **9**  (1 from MC bug-report.md, 6 from modeling-brief.md families, 5 code-review items overlapping with families)
- Reproduced (current production code): **0**
- Confirmed historical (already fixed in production): **1** (Family 2 / `extract_from` ordering, fix `9573fa1`)
- Reproduction failed (genuine effort, no anomaly observed): **1** (Family 1 / `MC-1` iter-skip during resize)
- False positives (code audit + MC validate as sound): **3** (Family 3 `check_ref` asymmetry, Family 5 `relocate_bucket_async` early-return leak, Family 6 `partial_hash_array` u8 race)
- Path deviations / out of scope: **2** (CR-4 doc accuracy, CR-5 doc/refactor)

The MC run (`bug-report.md`) reports zero net-new bugs in current code. After code audit, stress-test reproduction, and developer-intent investigation, this assessment is confirmed: the only "bug" with model-checker corroboration is the **historical** F2 ordering issue, which is already fixed at HEAD. No reproduction succeeds against current production code.

Two executable reproduction binaries are provided in `repro/` (one to attempt the unmodelled F1 iter-skip pattern; one to deterministically assert the F2 fix is still in place).

---

## Bug 1: Family 2 — `extract_from` clear-before-publish ordering (HISTORICAL / FIXED)

- **Source**: MC counterexample (regression-check via `MCMigrateClearOldRelaxedLegacy` adversary)
- **Status**: **REPRODUCED HISTORICALLY (pre-9573fa1) — FIX VERIFIED PRESENT IN HEAD**
- **Severity**: Historical High (already fixed; current code is correct)
- **Location**: `artifact/scc/src/hash_table/bucket.rs:329-368` (`Bucket::extract_from`)
- **Description**: Before commit `9573fa1` (Nov 2025), `extract_from` cleared the source bucket's `occupied_bitmap` *before* publishing the entry into the new bucket, with `Relaxed` ordering. A lock-free `HashIndex` reader walking old-then-new could observe the entry in **neither** array between the clear and the (later) publish, breaking lookup linearizability.
- **Trigger scenario** (pre-fix): A reader on `HashIndex::peek_with(&k, ..)` runs concurrently with a per-entry migration of `k` from `A1[bucket b]` to `A2[bucket b']`. The reader observes the source bitmap after the clear but before the destination bitmap has been published, returning `None` even though `k` was continuously live.
- **Reproduction test**: `repro/test_bug_f2_extract_from_ordering_present.rs` — static-source check that asserts (1) `self.insert(data_block, hash, entry)` (publish-new) precedes the source-bucket `occupied_bitmap.store(.., mo)` (clear-old), and (2) `mo == Release` for INDEX.
- **Reproduction result**: **PASS** — fix is in place at HEAD (`3d3d6b4`). Output:
  ```
  Locations within `extract_from`:
    publish-new offset = 619
    clear-old   offset = 992
  Family-2 (pre-9573fa1) ordering bug is FIXED in production code.
    - publish-new precedes clear-old in extract_from()
    - source occupied_bitmap clear uses `Release` for INDEX
  ```
- **Developer-intent evidence**: Commit `9573fa1bd9...` ("fix(hash_index): iterator reading outdated bucket state", 2025-11-14, author Changgyoo Park) explicitly reorders the operations and upgrades the source-clear to `Release` for INDEX. The CHANGELOG line "Fix a rare data race in `Hash*` iterator methods" (3.0.7) and the more recent fix-history (#190 ABA, `b915090` Sep 2025) show a sustained pattern of the maintainer treating these orderings as bugs and fixing them; no comment claims the legacy ordering is acceptable.
- **Recommendation**: No action — the fix is in `9573fa1` and ancestor of HEAD. The MC adversary `MCMigrateClearOldRelaxedLegacy` should be retained in the spec as a regression detector: any future refactor that reverts the ordering will trip `MigrationVisibleEverywhere` again.

---

## Bug 2 (candidate): Family 1 — `HashIndex::iter` skipping a still-live key during resize (REPRODUCTION FAILED)

- **Source**: Modeling-brief MC-1 hypothesis (no MC counterexample — state-space budget exceeded)
- **Status**: **REPRODUCTION FAILED** — no skip observed in 30M+ iter passes against an actively resizing map
- **Severity assessment**: Medium-if-real, but not corroborated by either MC or empirical reproduction
- **Location**: `artifact/scc/src/hash_index.rs:2212-2342` (`Iterator::next` for `Iter<'h, K, V, H>`)
- **Description**: The brief hypothesises that during a resize, the per-entry migration may move an entry to a bucket index the iterator has already passed, and that if the old `BucketArray` is unlinked before the iterator resumes the iterator may switch to a new array whose start position no longer covers the relocated entry. MC could not reach this state with `MaxResize <= 1` and `BUCKET_LEN = 1`; the modeling brief flagged it as the unmodelled adversarial pattern.
- **Code audit** (Phase 1):
  - `Iter::next` (hash_index.rs:2220-2342) handles the cross-array transition by reloading `current_array`, comparing the just-finished array against `current_array.linked_array(guard)`, and **chasing the chain backwards** to whichever array is the current's linked-old. A 2-generation jump (just-finished is neither current nor current's linked) falls through to "switch to current.linked_array (older)" and resumes scanning from `bucket(0)`. Because `bucket(0)` is the start of the new array and `extract_from` always publishes-new before clearing-old (post-`9573fa1`), an entry in transit is occupied in at least one array on the linked chain visible to the iterator.
  - The doc comment on `iter` (hash_index.rs:1141-1145) admits "the same key-value pair can be visited more than once if the `HashIndex` is being resized" — duplicates are possible. It does not claim no skips, but does not admit them either; combined with the BFS logic of the cross-array transition the implementation appears to maintain the "no skip" property.
- **Trigger scenario constructed**: Stable key set of 256 keys. Concurrent thread inserts and removes 4 096 disjoint *scratch* keys, repeatedly forcing growth and shrink of the underlying bucket array (multiple resizes per second). Four reader threads continuously start fresh `iter()` passes; each pass must yield every key in the stable set.
- **Reproduction test**: `repro/test_bug1_iter_skip_during_resize.rs` — multi-threaded stress, no failpoints, no source modification (Level 0 black-box).
- **Reproduction result**: **FAIL (no skip observed)**.
  - 30 s run: 6 518 698 iter passes, 0 missed-key passes.
  - 120 s run: 27 048 052 iter passes, 0 missed-key passes.
  - 15 s short run captured to `repro/test_bug1_output.txt`:
    ```
    Total iterator passes: 3222980
    Iterator passes with missing key(s): 0
    NOT REPRODUCED in this run: no iter pass missed a stable key
    ```
- **Escalation analysis**: Level 0 produced ample resize churn (the resizer thread completes thousands of insert/remove cycles per second; reader threads observe many resizes per pass). Escalating to Level 1 (timing failpoints) or Level 2 (state injection) would not change the conclusion — code-audit shows `Iter::next` re-reads `current_array` on every cross-bucket transition and chases the linked-array chain backwards from current, which structurally prevents the skip pattern the brief hypothesised. The MC convergence on `NoLiveKeyMissedByCompletedIter` (after tightening to exclude concurrently inserted/removed keys) is consistent with this.
- **Conclusion**: Hypothesis MC-1 is **not corroborated by either MC or empirical reproduction**. The brief's "Priority: High" tag was based on the assumption that the pattern is unverified; both the model and a 27M-pass stress test now provide negative evidence. Classify as **NOT A BUG** in current code.
- **Recommendation**: Update the `HashIndex::iter` doc comment to explicitly state "every key continuously present for the duration of `iter` is yielded at least once" — the implementation appears to provide this property but the docs are silent. (CR-4 in the brief is the same recommendation.)

---

## False Positives — code audit confirms safeguards prevent the bug

### FP-1: Family 3 / CR-3 — `writer_async`/`optional_writer_async`/`reader_async` lack `check_ref`

- **Source**: Code review (modeling-brief)
- **Audit**: MC `MC_hunt_F3.cfg` ran to BFS depth 33 / 46M states with `MaxSkipCheckRef = 2`. `NoOrphanedLockedBucket` held throughout. Static reasoning: `Writer::lock_async` holds the bucket lock; `EndIncrementalRehash` requires every bucket of the array to be in the `killed` state, which a held writer-lock prevents; therefore the array containing a returned `LockedBucket` cannot transition to `garbage`/`freed` while the writer is active. The `check_ref` symmetry-break with `for_each_*_async` is safe because `for_each_*` does not hold a bucket lock across the array load (it captures the array before any lock acquisition).
- **Why it's not a bug**: bucket-lock acts as the array pin. Removing it would be unsafe; adding `check_ref` is unnecessary. This was MC-validated and confirmed by the spec author (`bug-report.md` explicitly says "This **confirms code-review-CR3** in the modeling brief").
- **Status**: FALSE POSITIVE.

### FP-2: Family 5 / CR-1 — `relocate_bucket_async` early-return leak

- **Source**: Code review (modeling-brief Family 5)
- **Audit**: `hash_table.rs:891-943`. The early-return path at line 921-923 (`linked_array_var = None`) requires another thread to complete `incremental_rehash_*` while the caller holds `old_writer` on `old_array.bucket(old_index)`. `incremental_rehash_*` would itself need to lock that same bucket, which the held `old_writer` prevents. The brief itself flags this as "latent / unreachable but fragile".
- **Why it's not a bug**: the path is unreachable in the current control-flow graph. It is a defensive-programming opportunity (move `ExitGuard` setup earlier as a hardening measure), not a manifest bug.
- **Status**: FALSE POSITIVE for current code. **Optional defensive fix**: install `ExitGuard` immediately after the lock-acquisition loop (before line 921).

### FP-3: Family 6 / CR-2 — non-atomic `partial_hash_array` u8 cells

- **Source**: Code review (modeling-brief Family 6)
- **Audit**: `Bucket::mark_removed` (`bucket.rs:230, 240`) and `Bucket::insert_entry` (`bucket.rs:453`) write `partial_hash_array[i]` non-atomically via `write_cell` (`bucket.rs:603-606`); `search_data_block` reads non-atomically at `bucket.rs:703` (lock-free for INDEX). Formally a Rust data race (UB).
- **Phase 0 filter**: This finding fails the "name the observable harm" filter. On every supported target (x86-64 / ARMv8) single-byte loads/stores are atomic at the hardware level, so observable values are either the old hash byte (mismatch → mask out) or the new epoch tombstone byte (will not equal the lookup hash → mask out); both fall through the lookup loop without dereferencing freed memory or returning the wrong entry. The brief itself classifies this as "Low (code-review only)" and "do not model", and Miri runs of the multi-threaded test suite are explicitly disabled (`#[cfg_attr(miri, ignore)]` on every concurrent `HashIndex` test).
- **Status**: FALSE POSITIVE in the bug-vs-path-deviation sense. **Optional hardening**: replace `[UnsafeCell<u8>; LEN]` with `[AtomicU8; LEN]` and use `load(Relaxed) / store(Relaxed)`, eliminating the formal-UB without changing semantics.

---

## Out-of-Scope (Phase 0 rejected)

- **CR-4** (`Iter` doc admits duplicates but not skips): doc accuracy, not bug. Subsumed under Bug-2's recommendation.
- **CR-5** (`linked_array_var` overloaded as old→new pointer and "next garbage" pointer): refactor / readability, not bug.

---

## Reproduction Artifacts

```
.specula-output/repro/
├── Cargo.toml
├── test_bug1_iter_skip_during_resize.rs    # Family 1 / MC-1 — Level 0 stress test
├── test_bug1_output.txt                    # captured output of test_bug1 (15s run)
├── test_bug_f2_extract_from_ordering_present.rs  # Family 2 — fix-presence assertion
└── test_bug_f2_output.txt                  # captured output of F2 check
```

Build: `cd .specula-output/repro && cargo build --release`.

Run:
```
target/release/test_bug_f2_extract_from_ordering_present
REPRO_SECS=30 target/release/test_bug1_iter_skip_during_resize
```

Both binaries exit 0 (F2 fix verified; F1 stress yielded no skip). The F1 binary exits 1 if a skip is ever observed, making it suitable for CI as a regression detector against the iterator-skip hypothesis.
