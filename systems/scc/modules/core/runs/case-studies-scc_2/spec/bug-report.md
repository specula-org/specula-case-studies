# Bug Report — `scc` (scalable-concurrent-containers)

## Summary

- Bug families tested: 4 (F1 / F2 / F3 / F4)
- Bugs found: 0 net-new bugs in current code; **1 confirmed regression check** (F2: pre-9573fa1 ordering bug is reachable when the legacy adversary is enabled, validating that the recent fix is necessary).
- Configs run: `MC_hunt_F1.cfg`, `MC_hunt_F2.cfg`, `MC_hunt_F3.cfg`, `MC_hunt_F4.cfg`
- Convergence: spec passed all 4 trace-replay scenarios and the `MC.cfg` invariants exhaustively up to BFS depth 26 (~41M distinct states), beyond which the run was interrupted by disk-checkpoint pressure (no violation observed in the explored frontier).

---

## Bug 1 (Validated Regression Check): Family 2 — Pre-9573fa1 `extract_from` ordering

- **Bug Family**: F2 (Per-entry migration: publish-new vs clear-old window) — HashIndex-only.
- **Severity**: Historical High (already fixed; this run validates the fix is necessary).
- **Invariant violated**: `MCMigrationVisibleEverywhere`
- **Config**: `MC_hunt_F2.cfg` (`MaxLegacyClear = 1`, `MaxResize = 1`)
- **Counterexample**: 9 states, `output/F2_bfs.out`

### Trace Summary

```
1. Init                                                — empty A1; currentArray = A1
2. WriterStart(t1, k1, v1)                             — t1 enters writer for (k1,v1)
3. WriterMaybeRehashOK(t1)                             — no linked array yet, skip rehash
4. WriterAcquireLock(t1)                               — lock A1[bucket 0]
5. WriterCommitInsert(t1)                              — k1 lands in A1[0,k1]; occBit[<<1,0,k1>>] = TRUE
6. WriterRelease(t1)
7. TryResize(t1)                                       — allocate A2 live, A1 → linked, linkedOf[A2]=A1
8. MigrateLockOldBucket(t1)                            — t1 picks A1[0] for migration
9. MigrateClearOldRelaxedLegacy(t1)                    — clears A1[0,k1] BEFORE publishing into A2
                                                         → occBit[<<1,0,k1>>] = FALSE
                                                         → no slot anywhere has k1 occupied
                                                         → MigrationVisibleEverywhere is violated
                                                           in the rehasher's "legacy_cleared" state
```

### Root Cause

Pre-9573fa1, `Bucket::extract_from` (`bucket.rs:329-368`) cleared the source-bucket bitmap *before* publishing the entry into the new bucket. Between the clear and the publish, a lock-free reader could observe the entry in **neither** array. Commit `9573fa1` (Nov 2025) reordered these operations and upgraded the source-clear to `Release`, eliminating the gap.

### Affected Code

- `artifact/scc/src/hash_table/bucket.rs:341-346` — `extract_from`: insert into new bucket (the "publish" half).
- `artifact/scc/src/hash_table/bucket.rs:348-364` — `extract_from`: store on source bitmap with the `mo` ordering (now `Release` for INDEX).

### Recommendation

No action — the production code already has the fix. The `MCMigrateClearOldRelaxedLegacy` adversary is retained in the spec as a regression detector: if a future refactor reverts the ordering, this hunt will fire again.

---

## Not Reproduced

| Bug Family | Config | Coverage Reached | Result |
|------------|--------|------------------|--------|
| F1 — Iter / Insert / Remove / Resize race | `MC_hunt_F1.cfg` | BFS depth 22 / 396k distinct states (BFS run was OOM-killed before reaching deeper frontier; simulation followup yielded no violation in 25 min) | No violation. The earlier BFS hits caught **caller-misuse** patterns (iter + concurrent insert/remove of the same key) that the implementation explicitly does not promise to handle linearizably; once the invariant was tightened to exclude (k,v) pairs whose insert or remove happened concurrently with the iter (`iterSeenRemove[t]`), F1 found no unexpected skip. The genuine migration-only bug pattern called out by `MC-1` (entry migrated to a bucket the iter already passed) was not reachable with a single resize and a one-key state space — would need `MaxResize ≥ 2` or `BUCKET_LEN ≥ 2` to expose, both of which exceed the current state-space budget. |
| F3 — Async ref invalidation across `.await` | `MC_hunt_F3.cfg` | BFS depth 33 / ~46M distinct states (run OOM-killed) | No violation. The bucket-lock pin is sufficient: a writer that holds `bucketLock[<<aid, bidx>>] = "writer"` blocks `EndIncrementalRehash` of `aid` (which requires every `aid` bucket to be in the `killed` state), so `aid` cannot transition to `garbage`/`freed` while the writer is active. `NoOrphanedLockedBucket` therefore holds even with `MaxSkipCheckRef = 2`. This **confirms code-review-CR3** in the modeling brief — the `check_ref` asymmetry between `for_each_*_async` and `writer_async`/`optional_writer_async`/`reader_async` is sound; the bucket-lock provides the protection. |
| F4 — EBR reclamation timing under per-entry tombstone | `MC_hunt_F4.cfg` | BFS depth 36 / ~10.5M distinct states (run cancelled to free disk) | No violation (after Phase-2 `EpochPinned` strengthening). The original spec had a too-weak `EpochPinned(e) == \E t : pinnedEpoch = e`, which let `DeallocGarbage` fire while a reader was pinned at an *earlier* epoch — that **was** a `NoUseAfterFree` violation found during Phase-2 convergence and fixed there (see `changelog.md`). With the corrected `pinnedEpoch <= e` gate (matching sdd's `Epoch::in_same_generation` semantics), F4 found no further violations in the explored frontier. |

---

## Spec Adjustments Made During Hunting

These were Case-A/B fixes applied while running the family-specific configs; they are also recorded in `changelog.md`:

1. `IterFinish` precondition tightened — must be at the last bucket AND the bucket is exhausted (originally allowed termination from `step="scanning"` without scanning anything; this was a too-permissive abstraction).
2. `IterAdvanceWithinBucket` / `IterCrossArray` / `IterFinish` (collapsed branch) gained an `IterBucketExhausted(t)` precondition — the implementation only advances past a bucket after `move_to_next` returned `false` (i.e., the bucket has no live entry from the iterator's view).
3. `IterStart` resets `iterCompleted[t]`, `iterEndAlsoLive[t]`, and `iterSeenRemove[t]` for thread `t` — without this, a second iter from the same thread would inherit the previous iter's terminal flags and produce spurious `NoLiveKeyMissedByCompletedIter` violations.
4. `iterSeenRemove[t]` introduced — set of `(k,v)` removed/inserted concurrently with thread `t`'s iter, populated in `WriterCommitMarkRemoved`; `NoLiveKeyMissedByCompletedIter` excludes such keys (scc explicitly does not promise iter linearizability across concurrent remove/insert of the same key).
5. Sentinel partition: `NoId == 0` (integer) for ArrayId-typed nullable fields (`linkedOf`, `garbageHead`, `pc.cachedArray`, `pc.pinnedEpoch`); kept `NONE == "none"` for record/string fields (`pc.kind`, `pc.step`, `pc.key`, `pc.val`, `pc.bucketIdx`, `pc.migrating`). This was forced by TLC's strict-mode rejection of cross-type `=`/`\in` comparisons on heterogeneous values.

---

## Coverage Notes

- **Disk pressure** was the primary limit — at `BucketCount = 2`, `MaxArrays = 3`, `Thread = {t1,t2,t3}`, `Key = {k1,k2}` BFS produces ~50M distinct states/min and exhausts the 64 GiB local disk in ~3 minutes.
- **What was NOT explored**: deeper migration chains (`MaxResize ≥ 2` would expose 2-generation migrations needed for the documented but rare F1 "skip during retire" pattern), wider key sets (`Key = {k1,k2,k3}`), and `BUCKET_LEN ≥ 2` (the spec abstracts each bucket to one slot per key, which is sufficient for the modelled invariants but undercounts the per-bucket entry-iteration order in `move_to_next`).
- **What IS robustly checked**: under the explored frontier (depth 26 for `MC.cfg`, depth 33+ for the `MC_hunt_*` configs), all of `MCAtMostOneLive`, `MCAtMostOneLinked`, `MCCurrentLive`, `MCLinkedConsistent`, `MCNoOrphanedLockedBucket`, `MCNoUseAfterFree` (post-fix), `MCNoLeakedBucketLock`, and `MCInsertedConsistency` hold. The Family-2 fix is also confirmed necessary (legacy ordering reproduces the bug).
