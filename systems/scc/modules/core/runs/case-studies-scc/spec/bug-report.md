# Bug Report — scc (scalable-concurrent-containers)

## Summary

- Bug families tested: 5 (F1: Guard/Lock Lifetime, F2: Async Reference Invalidation, F3: Resize Protocol, F5: EBR Reclamation, MC-6: HashIndex Lock-Free Reads)
- New bugs found: 0
- Known patterns validated: 4 (F1, F2, F5 via fault injection; OOM via MC_hunt_hashindex_oom)
- Specs: base.tla (HashMap), MC_hunt_hashindex.tla (HashIndex lock-free reads + per-entry migration + OOM)
- Total states checked: ~850M (190M BFS + 26M BFS + 650M simulation)

## State Space Coverage

### base.tla (HashMap)

| Config | States Generated | Distinct States | Depth | Duration | Result |
|--------|-----------------|-----------------|-------|----------|--------|
| MC.cfg (convergence) | 190,687,986 | 26,774,004 | 45 | 8m 46s | All 9 invariants pass |
| MC_hunt_F1.cfg | 114 | 57 | 8 | <1s | F1_BugDetector violated (fault injection) |
| MC_hunt_F2.cfg | 3,915 | 1,592 | 10 | <1s | AsyncRefValidity violated (fault injection) |
| MC_hunt_F3.cfg | 81,467 | 9,024 | 20 | <1s | No violation |
| MC_hunt_F5.cfg | 2,814 | 1,123 | 9 | <1s | F5_BugDetector violated (fault injection) |

### MC_hunt_hashindex.tla (HashIndex lock-free reads)

| Config | States Generated | Distinct States | Depth | Duration | Result |
|--------|-----------------|-----------------|-------|----------|--------|
| MC_hunt_hashindex.cfg (3t, BFS) | 25,998,243 | 5,956,732 | 32 | 2m 10s | All 7 invariants pass |
| MC_hunt_hashindex_deep.cfg (3t, sim) | 650,158,571 | — | 50 | ~25m | All 7 invariants pass (13M traces) |
| MC_hunt_hashindex_oom.cfg (2t, OOM) | 9,816 | 4,510 | 9 | <1s | LockFreeReadCompleteness violated (known OOM pattern) |

## Fault Injection Validation

The following are **not new bugs** — they validate that the spec can detect known historical bug patterns via injected fault actions.

### F1: Guard/Lock Lifetime (MC-5) — Validates Yanked Version Pattern

- **Bug Family**: F1 — Guard/Lock Lifetime vs Data Access Window
- **Severity**: Critical (caused versions 2.0-2.3 to be yanked)
- **Invariant violated**: F1_BugDetector
- **Config**: MC_hunt_F1.cfg
- **Counterexample**: 7 states (output/MC_hunt_F1_v2.out)

#### Trace Summary

1. t1 creates guard
2. t1 begins sync read on k1, bucket 1 (acquires Reader lock, lockHeld=<<1,1>>)
3. t2 creates guard
4. t1 accesses data in callback (accessingData=TRUE)
5. t2 begins sync read on k1, bucket 1 (shared Reader lock)
6. **BuggyReleaseLockEarly(t1)**: t1's Reader lock released while callback still running
7. **Violation**: accessingData[t1]=TRUE but lockHeld[t1]=NoLock

#### Root Cause

In scc versions 2.0-2.3, `reader_sync` dropped the `Reader` lock guard before the user callback returned. The callback continued accessing data through a dangling reference.

#### Affected Code (historical, now fixed)

- `hash_table.rs:306-328` (`reader_sync`): Reader must be kept alive until callback returns
- Fix: `ad75430` — threaded Reader through return tuple to extend its lifetime

### F2: Async Reference Invalidation (MC-3) — Validates ABA Pattern

- **Bug Family**: F2 — Async Reference Invalidation / ABA
- **Severity**: High
- **Invariant violated**: AsyncRefValidity
- **Config**: MC_hunt_F2.cfg
- **Counterexample**: 9 states (output/MC_hunt_F2.out)

#### Trace Summary

1. t1 creates guard, inserts k1
2. t1 begins async read (seenArray=1, asyncStep=loaded_ref)
3. t1 awaits (guard dropped, asyncStep=awaiting)
4. t1 reacquires guard
5. t2 creates guard, triggers resize (currentArray=2, old array=1)
6. **BuggyAsyncSkipCheckRef(t1)**: skips check_ref, directly accesses data using stale seenArray=1
7. **Violation**: asyncStep=operating, seenArray=1 ≠ currentArray=2

#### Root Cause

Without `check_ref()` after await, the async operation uses a stale bucket_array reference. If a resize happened during the await, the reference points to the old (potentially reclaimed) array.

#### Affected Code (historical, now fixed)

- `async_helper.rs:72` (`check_ref`): Must validate reference after every await
- Fixes: `94303a4`, `c8bc10d`, `bf6ebb4`, `4939622`, `b915090`

### F5: EBR Premature Reclamation (MC-7) — Validates Epoch Safety

- **Bug Family**: F5 — EBR Epoch Advancement + Garbage Reclamation Timing
- **Severity**: Medium
- **Invariant violated**: F5_BugDetector
- **Config**: MC_hunt_F5.cfg
- **Counterexample**: 8 states (output/MC_hunt_F5.out)

#### Trace Summary

1. t1 creates guard (threadEpoch=0)
2. t1 triggers resize, rehashes all buckets, finalizes (retiredAt[1]=0)
3. **BuggyReclaimArray(1)**: reclaims array 1 without checking epoch generation
4. **Violation**: array 1 reclaimed while t1 holds guard with threadEpoch=0, which is in the same generation as retiredAt[1]=0

#### Root Cause

Without the `in_same_generation` check, garbage can be reclaimed while threads still hold references through their epoch-announced guards. The 3-epoch grace period exists precisely to prevent this.

#### Affected Code (would be affected if check removed)

- `collector.rs:410` (`scan`): Epoch advancement safety
- `hash_index.rs:1191-1218` (`dealloc_garbage`): Generation check before reclamation

---

## Deep Dive: HashIndex Lock-Free Reads (MC_hunt_hashindex.tla)

A focused spec was created to model the HashIndex lock-free read path (`peek_entry`), per-entry migration, OOM faults, and entry removal with epoch-based GC. This covers areas MC-6 (lock-free reads) and OOM handling that were listed as unmodeled in the original spec.

### Spec: MC_hunt_hashindex.tla

**Key differences from base.tla:**
1. `ExtractEntry` models per-entry migration (not atomic per-bucket)
2. `BeginLockFreeRead`/`SearchOldArray`/`SearchNewArray` model HashIndex `peek_entry` (no lock required)
3. `ExtractEntryOOM` injects OOM during entry migration
4. `RemoveKey`/`GarbageCollectEntry` model `mark_removed` + `clear_unreachable_entries`
5. Reader tracks search key (`rSearchKey`), current array, linked array, and retry logic

**Key invariants:**
- `EntryReachability`: Every inserted non-removed key has at least one live array
- `LockFreeReadCompleteness`: Lock-free reader cannot report "not_found" for a reachable key
- `NoEntryInReclaimed`: No non-removed entry in a reclaimed array
- `EBRSafety`: No thread is actively reading a reclaimed array
- `CurrentArrayLive`, `NoRemovedVisible`, `OOMSafety`

### State Space Coverage

| Config | States Generated | Distinct States | Depth | Duration | Result |
|--------|-----------------|-----------------|-------|----------|--------|
| MC_hunt_hashindex.cfg (2t, 1 resize) | 624,440 | 194,849 | 26 | 7s | All 7 invariants pass |
| MC_hunt_hashindex.cfg (3t, 1 resize) | 25,998,243 | 5,956,732 | 32 | 2m 10s | All 7 invariants pass |
| MC_hunt_hashindex_deep.cfg (3t, 2 resize, sim) | 650,158,571 | — | — | ~25m | All 7 invariants pass (13M traces) |
| MC_hunt_hashindex_oom.cfg (2t, OOM) | 9,816 | 4,510 | 9 | <1s | LockFreeReadCompleteness violated (expected) |

### OOM Fault Injection Result

**Config**: MC_hunt_hashindex_oom.cfg (MaxOOMFaults=1)
**Invariant violated**: LockFreeReadCompleteness
**Counterexample**: 9 states

#### Trace Summary

1. t1 creates guard, inserts k1 into array 1
2. t1 triggers resize (currentArray=2, linked[2]=1)
3. **ExtractEntryOOM(t1,k1,1)**: OOM prevents k1 from moving to array 2 — k1 stays in array 1
4. CompleteMigration(t1,1): migration "completes" with k1 still in array 1
5. FinalizeResize(t1,1): array 1 unlinked, retiredAt[1]=0
6. t1 begins lock-free read for k1: currentArray=2, no linked array
7. SearchNewArray(t1): k1 not in array 2 → **not_found**
8. **Violation**: k1 is inserted, not removed, reachable in array 1, but reader can't find it

#### Root Cause

This validates the known OOM bug pattern (scc v3.0.5-3.0.6 yanked). When OOM prevents entry migration but the migration is considered "complete," the old array is unlinked and the entry becomes invisible to lock-free readers. The spec's `CompleteMigration` is overly permissive (allows completion with unmoved entries); the real code (post-fix) returns false from `relocate_bucket` on failure.

**Not a new bug** — confirms the spec correctly detects the known OOM failure mode.

### Code Analysis: Potential Races Examined

During the deep dive, the following potential race conditions were analyzed:

1. **Reader vs migrator on same entry**: Safe. Migrator holds bucket lock; reader is lock-free. Reader's Acquire load of `occupied_bitmap` synchronizes with migrator's Release store. Reader either sees entry in old array (before migration) or in new array (after migration) — never misses it.

2. **Two-step extract_from visibility**: Safe. Step 1 (set occupied in new, Release) + Step 2 (clear occupied in old, Release). If reader sees step 2 via Acquire, Release-Acquire ordering guarantees step 1 is also visible. Entry is in at least one array at all times.

3. **Reader vs clear_unreachable_entries**: Safe. Removed entries have `removed_bitmap` bit set. Reader's `(!removed_bitmap) & occupied_bitmap` (both Acquire) skips removed entries. `clear_unreachable_entries` only drops entries already in `removed_bitmap`.

4. **partial_hash_array dual-use (hash/epoch)**: Design trade-off, not a bug. `mark_removed` overwrites partial_hash with epoch via `UnsafeCell`. Concurrent reader may see epoch instead of hash → partial hash mismatch → reader skips slot → misses entry. But entry is being removed, so linearizable (remove happens-before read). No safety violation.

5. **Garbage chain race (defer_reclaim two-swap)**: Memory leak, not safety bug. Between `garbage_chain.swap(new)` and `new.linked_array.swap(prev)`, a concurrent `dealloc_garbage` can orphan `prev_head`. Leaked array won't be freed but no data corruption.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| F3: Resize Protocol | MC_hunt_F3.cfg | 81,467 | No violation — resize protocol correct under all interleavings |
| F3 (convergence) | MC.cfg | 190,687,986 | No violation — EntryReachability, EntryUniqueness, NoLostEntryDuringResize all pass |
| MC-6: Lock-free read | MC_hunt_hashindex.cfg (BFS) | 25,998,243 | No violation — LockFreeReadCompleteness passes with 3 threads |
| MC-6: Lock-free read | MC_hunt_hashindex_deep.cfg (sim) | 650,158,571 | No violation — 13M traces, all invariants pass |

### Limitations of Current Model

The following mechanisms are **not modeled** and could harbor undiscovered bugs:

1. ~~**OOM during resize**~~: Now modeled in MC_hunt_hashindex.tla — correctly detects the known v3.0.5-3.0.6 bug pattern.
2. ~~**HashIndex optimistic reads**~~: Now modeled in MC_hunt_hashindex.tla — lock-free read protocol verified correct (26M BFS + 650M simulation).
3. **Garbage chain linkage race** (MC-8): Analyzed as memory leak only (not safety bug). Non-atomic `defer_reclaim` can orphan arrays. Not modeled.
4. **Iterator during resize**: Iterator skipping entries during concurrent resize is not modeled.
5. **TreeIndex concurrent structure modification** (Family 4): B+ tree clear+insert race is not modeled.
6. ~~**Individual entries within buckets**~~: Now modeled at per-entry granularity in MC_hunt_hashindex.tla.
7. **Chained resizes**: MC_hunt_hashindex.tla blocks second resize while first is in progress. Real code allows array chains (array3 → array2 → array1).
8. **partial_hash_array data race**: UnsafeCell access during concurrent mark_removed + search_data_block. Technically UB in Rust, but single-byte access is atomic on all target architectures. May cause linearizability anomaly (reader misses entry being removed) but no safety violation.

### Assessment

The scc HashMap and HashIndex core protocols are correct under the modeled abstraction level:

- **HashMap** (base.tla): 190M-state BFS, all 9 invariants pass. Locked reads + atomic bucket migration + EBR verified.
- **HashIndex lock-free reads** (MC_hunt_hashindex.tla): 26M-state BFS + 650M-state simulation, all 7 invariants pass. Per-entry migration + lock-free read + entry removal + EBR verified with 3 concurrent threads.

No new bugs were found. The most likely source of undiscovered bugs is in areas still outside model scope:
- **Chained resizes** (multiple in-flight resize cycles)
- **Iterator correctness during resize**
- **TreeIndex B+ tree operations**
