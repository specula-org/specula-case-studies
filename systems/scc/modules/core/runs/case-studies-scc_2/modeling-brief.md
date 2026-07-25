# Modeling Brief — `scc` (scalable-concurrent-containers)

## 1. System Overview

- **Name / language / scale**: `scc` 3.4.8, Rust, ~17k LOC of core logic across `hash_table.rs` (1.7k), `hash_table/bucket.rs` (1.6k), `hash_index.rs` (2.2k), `hash_map.rs` (2.4k), `hash_cache.rs` (1.8k), `hash_set.rs` (0.9k), and the `tree_index/*` files (~4.2k).
- **System category**: **Category B (Concurrent / Lock-Free / Runtime)**. The library is a collection of in-process concurrent containers using EBR-style reclamation (`sdd` crate) and `saa::Lock` for per-bucket exclusive/shared locking. There is no network, no persistence, no message passing.
- **Algorithm/data structure**: `HashIndex` (lock-free read, per-entry tombstone-and-EBR migration), `HashMap` (write-locked, bucket-batch migration), `HashSet` (thin wrapper on `HashMap`), `HashCache` (LRU on bucket), `TreeIndex` (B+tree-like with Acquire/Release linked leaves). All share `hash_table::HashTable` trait for resize and rehash.
- **Architectural deviations from "vanilla" concurrent maps**:
  1. `HashIndex` performs **per-entry** lock-free migration: a logically-removed entry stays in `occupied_bitmap` but gains a bit in `removed_bitmap`, and its `partial_hash` byte is repurposed as a stored-epoch tombstone. The actual `(K,V)` is dropped only when `clear_unreachable_entries` runs (next bucket-overflow insert) **or** when the `BucketArray` is finally dropped.
  2. `BucketArray.linked_array` is reused both as the live "old → new" pointer during resize and as a "next garbage" pointer once the array is on the `garbage_chain` (HashIndex only).
  3. The bucket lock state machine has a terminal **poisoned/killed** state (`saa::Lock::poison_lock`); after kill, all `lock_async`/`lock_sync`/`try_lock` return `None`. Lock-free INDEX readers continue to walk the bucket via `search_entry` and rely solely on the EBR epoch for memory safety.
- **Concurrency model**: every public op has both `*_sync` and `*_async` variants. Async paths hold an `AsyncGuard` (a wrapper around `Option<sdd::Guard>`); the guard is **reset across every await** that yields on a contended lock (`async_guard.reset()` is invoked from inside `Lock::lock_async_with(|| async_guard.reset())`). Compensating mechanisms: `AsyncGuard::check_ref` re-validates a captured array pointer, and the bucket lock pins the containing `BucketArray`.

## 2. Bug Families

### Family 1: Iterator/Scan + concurrent insert/remove/resize (caller-misuse / adversarial client)

**Mechanism**: The iterator captures a `BucketArray` pointer A. While suspended (sync iterator: between `next()` calls; async iterator: across `.await`) another writer triggers migration; A becomes garbage; the iterator's resumption logic at `hash_index.rs:2127–2162` may **(a)** advance to the new array and re-yield entries already returned (duplicates — explicitly documented), or **(b)** miss entries that migrated to a bucket index already passed by the iterator before A was garbage-collected.

**Evidence**:
- Historical: `9573fa1` (Nov 2025, "iterator reading outdated bucket state") swapped order of `insert-into-new` vs `clear-old` in `extract_from` and upgraded the clear to `Release` for INDEX. Earlier patches: `b915090` (Sep 2025, "async iteration may omit entries"), CHANGELOG 3.0.7 ("Fix a rare data race in Hash* iterator methods"), 2.0.12 (Range fails to find min during update), #16 (insert-remove-scanner inconsistent linked list).
- Doc acknowledgment: `hash_index.rs:1141-1145` admits duplicates during resize but does not mention skipping.
- Code: `hash_index.rs:2099-2164` (`Iter::next`), `hash_table.rs:512-565` (`for_each_reader_async`), `hash_table.rs:618-694` (`for_each_writer_async`).

**Affected code paths**: `HashIndex::iter`, `HashIndex::iter_async`, `HashIndex::retain`, `HashIndex::retain_async`, `HashMap::iter`, `HashMap::iter_async`, `HashMap::iter_mut_async`, `HashMap::retain_async`, `HashCache::any_async`, `OccupiedEntry::next_async`, `tree_index::Range`/`Iter`.

**Suggested modeling approach**:
- Adversarial-client harness with three concurrent processes: `Iter`, `Insert`, `Resize`. Iter has an explicit cursor `(array_id, bucket_idx, slot_idx)`. Resize swaps the array pointer, retires the old. Insert places into a bucket dictated by the new array's hash function.
- Variables: `arrays: Seq[Array]`, `linked_array: ArrayId -> ArrayId | NONE`, `garbage_chain: Seq[ArrayId]`, per-iterator `cursor`.
- Actions split: `IterStart`, `IterAdvanceWithinBucket`, `IterAdvanceToNextBucket`, `IterCrossArray`, `WriterInsert`, `WriterRemove`, `MigrateEntry(entry, oldArr, newArr)`, `SwapBucketArray(newArr)`, `RetireOldArray`.
- Granularity: `MigrateEntry` must be split into `PublishToNew` (Release on new occupied_bitmap) and `ClearOnOld` (Release on old occupied_bitmap) — the window in between is the bug surface.
- Invariants: `EachLiveKeyVisitedAtLeastOnce` (across the iter trace), `NoVisitedKeyDropped`, `NoSpuriousNotFound`.

**Priority**: **High**. This is the unmodeled adversarial pattern called out in the prompt. Two production fixes in 2025 alone touched exactly this surface; no formal verification has been attempted.

---

### Family 2: Per-entry migration & bucket-array swap window (HashIndex-specific)

**Mechanism**: `extract_from` (`bucket.rs:331-368`) for INDEX type (a) bit-copies `(K,V)` from old slot, (b) inserts into new bucket with `occupied_bitmap.store(.., Release)`, (c) clears old bucket's bit with `occupied_bitmap.store(.., Release)`. Between (b) and (c) the entry is occupied-visible in **both** arrays. A lock-free reader walking old-then-new (`hash_table.rs:222-261`) returns at most one observation, but a sequence of two consecutive reads can observe stale-then-fresh in either order, breaking *user-perceived* linearizability of `peek` against `insert`/`remove`.

The `9573fa1` fix re-ordered `insert-new` and `clear-old` (insert-new first, clear-old second) and made the clear `Release`. Before the fix, the clear-on-old was `Relaxed` and the insert-new happened later; a reader could see the entry in **neither** array briefly.

**Evidence**:
- Historical: `9573fa1` (current as of branch), CHANGELOG 3.0.5–3.0.6 ("Fix a potential duplicate key issue with Hash* containers if HashMap::insert_* fails to allocate memory"), CHANGELOG 3.0.3–3.0.4 ("Fix potential data races in asynchronous operations"), `94303a4` ("ABA in checking references in async code"), `8316957` ("rebuild HashIndex if necessary").
- Code: `bucket.rs:329-368` (extract_from), `hash_table.rs:1003-1094` (relocate_bucket), `hash_table.rs:222-261` (peek_entry).

**Affected code paths**: `HashIndex::peek`, `HashIndex::peek_with`, `HashIndex::contains`, `HashIndex::iter`, also indirectly `HashMap::read` via the same migration plumbing for non-INDEX (where readers hold a shared lock and the window is closed by lock-acquire).

**Suggested modeling approach**:
- Variable per slot: `slot[a, b, s] ∈ {Empty, Occupied(k,v), TombstonedAt(epoch)}`.
- Split `extract_from` into `PublishNewOccupiedRelease` and `ClearOldOccupiedRelease`. Add a dedicated **adversary** `MCRelaxClear` that injects the legacy (pre-fix) `Relaxed` ordering on the clear, to confirm that the reordering allowed a "neither-array" miss, validating the fix.
- Invariants: `LookupConsistency` (one peek sees the entry IFF it is occupied in some live array); `PostFixNoMissingWindow` (under `Release` clear, the lookup interval `[publish, clear]` always finds the entry in one array).

**Priority**: **High**. This is a recently-fixed bug surface; modeling can confirm the fix is sufficient and detect regressions.

---

### Family 3: Async reference invalidation across `.await`

**Mechanism**: Three sub-patterns:

1. **`AsyncWait` future-drop** (#118 historical): a `Future` that registered an `AsyncWait` waker and was dropped without being polled to completion left the wait queue with a stale waker; later signaller hit `unreachable!()`.
2. **ABA on cached entry pointer** (#190 historical): a `*_async` path stored a raw entry pointer across an `.await`; on resume, the same address held a different entry (the slot was reclaimed and reused at the same generation). Fix: pointer-plus-version (`AsyncGuard::check_ref` against the array variable).
3. **Missing `check_ref` after lock acquisition** (recently mitigated for `for_each_*_async` by `b915090`, Sep 2025): the patch added `check_ref(self.bucket_array(), current_array, Acquire)` immediately after `lock_async(...).await`. **Asymmetry**: `writer_async`, `optional_writer_async`, and `reader_async` (`hash_table.rs:335, 418, 263`) do **not** call `check_ref` after their lock acquisition — but they hold the bucket lock, which pins the containing `BucketArray`. Whether this is genuinely sufficient for all callers is the modelable question.

**Evidence**:
- Historical: #118, #190, `4939622` ("add robust reference checking across awaits"), `b915090` (Sep 2025), `bf6ebb4` ("potential data race in asynchronous code").
- Code: `async_helper.rs:33-76` (AsyncGuard), `hash_table.rs:540-549, 658-661` (check_ref sites — present), `hash_table.rs:442-449, 370-378` (sites without check_ref).

**Affected code paths**: every `*_async` method on every container.

**Suggested modeling approach**:
- Per-thread state: `local_array_ptr` (set on a load), and a non-deterministic `MCDropFuture` action that drops the future at any await-point of the spec.
- Action `LockAcquireAsync` resets the guard. Adversary `MCBucketArraySwapDuringAwait` swaps the bucket array between the load and the lock-acquire. Then `check_ref` either holds and the operation continues, or fails and the operation must restart.
- Invariant: `OperationAlwaysSeesCurrentOrLinkedArray` (any insert lands somewhere reachable from the current array's linked-chain).

**Priority**: **High**. A real bug fixed in this category as recently as Sep 2025; the asymmetry between `for_each_*_async` (now checks) and `writer_async`/`optional_writer_async`/`reader_async` (does not) is suspicious and should be confirmed sound by model-checking.

---

### Family 4: EBR reclamation timing under per-entry tombstone

**Mechanism**: `HashIndex` keeps logically-removed entries in `occupied_bitmap` and tags them via `partial_hash_array[i] = u8::from(guard.epoch())` plus `removed_bitmap |= 1<<i` (`bucket.rs:220-249`, `mark_removed`). The actual drop happens later in `drop_unreachable_entries` (`bucket.rs:498-534`), which gates each tombstoned slot by `Epoch::try_from(epoch_byte).in_same_generation(current_epoch)`. A reader that observed the slot before mark_removed has its `Guard` pinning the global epoch; soundness requires `current_epoch ≤ reader_epoch + 1`. If the global epoch were ever to advance two generations while a reader's Guard is alive, the reader's reference would point to dropped memory.

**Evidence**:
- Historical: #28 (CellLocker read-after-free), #45 (cursor outliving container), #176 (HashMap::read released bucket lock too early — yanked 2.0.0–2.3.0), #198/#200 (HashIndex peek references outliving container), `0074979` (#202).
- Code: `bucket.rs:498-540` (drop_unreachable_entries / drop_entry), `hash_index.rs:1191-1218` (dealloc_garbage), `hash_index.rs:1374-1389` (defer_reclaim).

**Affected code paths**: `HashIndex::peek*`, `HashIndex::contains`, `HashIndex::iter`, `HashIndex::clone`, `HashIndex::drop`.

**Suggested modeling approach**:
- Explicit epoch counter; per-thread guard records the epoch at acquisition; entries carry `tombstoned_at_epoch`; reclamation gate: `entry can be dropped iff no active guard pins an epoch in the same generation`.
- Adversary `MCAcceleratedEpoch` advances the epoch by two while a reader holds a guard; the spec must catch this as an invariant violation (use-after-free analog).
- Invariant: `NoUseAfterFree` (no thread reads an entry after it has been dropped).

**Priority**: **Medium**. Soundness depends on `sdd::Guard` semantics that scc does not control; a previous round explored this with `MCBuggyReclaimArray` and the four known patterns are already validated. Re-modeling has marginal value unless adding the per-entry tombstone interaction.

---

### Family 5: Bucket-lock leak in `relocate_bucket_async` (latent / unreachable but fragile)

**Mechanism**: `hash_table.rs:910-923` locks every target bucket on the new array via `Writer::lock_async(...).await; forget(writer)`, then re-checks `current_array.linked_array(...)`. If the linked array is `None` at line 921, the function returns *before* installing the `ExitGuard` at line 926, **leaking the just-acquired forgotten locks**.

**Why this is latent**: while the caller holds `old_writer` on `old_array.bucket(old_index)`, no other thread can complete `incremental_rehash_*` (it would need to lock that bucket too), so `linked_array_var` cannot be swapped to `None`. Therefore the early-return path is not reachable in current code. **But** any future refactor that allows `relocate_bucket_async` to be called without holding the old-bucket lock, or that adds a side-channel that can null `linked_array_var`, would expose the leak.

**Evidence**: code structure at `hash_table.rs:891-943`. No historical commit fixes this.

**Affected code paths**: `relocate_bucket_async` — called from `dedup_bucket_async` (`hash_table.rs:831`) and `incremental_rehash_async` (`hash_table.rs:1180`).

**Suggested modeling approach**: for completeness in a `MigrationPath` spec, set up the early-return branch as a possible action and model the leaked-lock state. A counter-example would either confirm the path is genuinely unreachable (UNSAT) or surface a missed adversarial schedule.

**Priority**: **Low**. Listed for the spec author's awareness; recommend installing `ExitGuard` *before* line 921 as a defensive fix even if currently sound.

---

### Family 6: Data race on `partial_hash_array` u8 cells (formal-UB but hardware-benign)

**Mechanism**: `Bucket::mark_removed` and `Bucket::insert_entry` write `partial_hash_array[i]` non-atomically (`bucket.rs:230, 240, 453`); `search_data_block` reads `partial_hash_array[i]` non-atomically for **all** i in `0..LEN` (`bucket.rs:703`), regardless of whether bit i is masked out by the live bitmap. For INDEX, lock-free readers race with writers. This is a formally-undefined Rust memory race; on x86_64 (and ARMv8 with single-byte access) the observed value is either the old hash byte or the new epoch byte, both safe paths in `search_data_block` (mask-out path or partial_hash mismatch).

**Evidence**: `bucket.rs:597-606` (`read_cell`/`write_cell` are non-atomic), `bucket.rs:703` (read), `bucket.rs:230/240/453` (writes).

**Affected code paths**: every lock-free read on `HashIndex`.

**Suggested modeling approach**: **do not model**. This is a hardware-specific soundness concern; TLA+ has no abstraction for tearing-vs-non-tearing byte access. Suggested action: replace `UnsafeCell<u8>` with `AtomicU8` and `load(Relaxed) / store(Relaxed)`, or run Miri.

**Priority**: **Low (code-review only)**.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why (Bug Family) | How |
|------|------|-----|
| Adversarial iterator harness over a migrating array | Family 1 (the unmodeled pattern called out in the brief) | `Iter` process with explicit cursor; non-deterministic interleaving of `Insert`, `Remove`, `Resize`, `Migrate`, `RetireOldArray`. Track per-key visit count. |
| Split `extract_from` into Publish-New and Clear-Old | Family 2 (window-of-double-visibility) | Two actions; under `Release` ordering each reader sees ≥1 occurrence; under injected `Relaxed` clear (legacy adversary), neither-occurrence becomes reachable. |
| `check_ref` semantics across `.await` | Family 3 (post-Sep-2025 invariant; remaining asymmetry in `writer_async`/`optional_writer_async`/`reader_async`) | Per-thread cached `array_ptr`; `MCBucketArraySwap` action; spec asserts that the acquired `LockedBucket`'s array is reachable from current's `linked_array*` chain. |
| Garbage-chain lifecycle for `HashIndex` | Family 4 (EBR timing bookkeeping) | Variables: `garbage_chain: Seq[ArrayId]`, `garbage_epoch: Epoch`, per-thread `guard_epoch`. Reclaim action gated by epoch generation. |
| `dedup_bucket_async` retry semantics on `check_ref` failure | Family 1 + 3 | Action returns `false`; outer caller restarts loop. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Internals of `saa::Lock` and `sdd::Guard` | External dependencies; spec should treat `Lock::poison`, `Guard::epoch` as primitive operations with their documented contracts. |
| Byte-level partial_hash race | Hardware-level, not protocol-level (Family 6). Use Miri/loom instead. |
| `HashCache` LRU bookkeeping | Bug family historically self-contained (#121, #122) and structurally orthogonal to Family 1; add only if explicitly requested. |
| `TreeIndex` structural racing (split/merge/clear) | Distinct sub-system; Family 5 of the analysis report; outside the prompt's "concurrent collection iter+modify+resize" focus. |
| Allocator failure (OOM) | Already validated by previous round (`MCBuggyReclaimArray` family). Marginal new value. |
| Memory ordering relaxation as adversary on every atomic | Out of scope for TLA+ sequential consistency. Only relax the specific ordering whose downgrade is the historical pre-fix state (Family 2). |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| `IteratorCursor` | `cursor: [Process -> {array_id, bucket_idx, slot_idx, visited_keys}]` | Track adversarial-iter state across resizes | Family 1 |
| `MigrationWindow` | `slot_state: [array_id × bucket_idx × slot_idx -> {Empty, OccupiedPending, Occupied, ClearedPending}]` | Capture publish-new vs clear-old transition | Family 2 |
| `BucketArrayChain` | `arrays: Seq[ArrayId]`, `linked_array: ArrayId -> ArrayId`, `garbage_chain: Seq[ArrayId]` | Distinguish current/linked/garbage and let resize chain to depth 2+ | Family 1, 4 |
| `EpochAndGuards` | `global_epoch`, `pinned_epoch: [Process -> Epoch]` | Gate reclamation on no-pinned-generation | Family 4 |
| `AsyncFrameValidation` | `cached_array_ptr: [Process -> ArrayId]`, `MCDropFuture(p)` | Model pre-await captured pointer + post-await `check_ref` | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `NoLiveKeyMissedByCompletedIter` | Safety | If a key is continuously present (under same generation) for the entire span of an `Iter`, the iterator yields it ≥ 1 time | Family 1 |
| `NoDuplicatePublication` | Safety | A key is occupied in at most one array (after `extract_from`'s `ClearOld`) — given the publish-then-clear ordering | Family 2 |
| `MigrationVisibleEverywhere` | Safety | Between `PublishNew` and `ClearOld`, the entry is occupied in either old or new (Family 2 fix invariant) | Family 2 |
| `NoUseAfterFree` | Safety | A reader holding a Guard pinned at epoch e never observes a slot whose `(K,V)` was dropped at epoch < e + GenerationDistance | Family 4 |
| `NoOrphanedLockedBucket` | Safety | A `LockedBucket` returned to a caller is always tied to an array currently reachable from `current_array.linked_array_var()*` chain | Family 3 |
| `NoLeakedLockOnEarlyReturn` | Safety | After `relocate_bucket_async` returns, every bucket lock it acquired has been released | Family 5 |
| `IteratorTerminates` | Liveness | Every iterator eventually terminates under fairness | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC-1 | Iterator may skip a still-live key when migration moves it to a bucket index already passed by the iterator before the old array is retired | `NoLiveKeyMissedByCompletedIter` | F1 |
| MC-2 | (Pre-9573fa1 regression) When `extract_from` clears old before publishing new, a lock-free reader sees the entry in neither array | `MigrationVisibleEverywhere` | F2 |
| MC-3 | `optional_writer_async`/`writer_async`/`reader_async` return `LockedBucket` whose array may have been swapped during the await; verify either that the bucket-lock pin is sufficient or that a check_ref is needed | `NoOrphanedLockedBucket` | F3 |
| MC-4 | `dedup_bucket_async`'s retry-on-check_ref-failure is correctly composed with `incremental_rehash_async`'s drain; specifically, the `current_array.has_linked_array() ? break` early-exit at hash_table.rs:846-849 must not leave entries unrelocated | (combined invariant: every entry placed in old before resize is reachable) | F1, F2 |
| MC-5 | Concurrent `Iter` + `clear_async` (which is `retain_async(false)`) — `retain_async` walks via `for_each_writer_async` which has `check_ref`, but the iterator does not | `NoUseAfterFree` analog at iterator level | F1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| T-1 | `partial_hash_array` u8 race (Family 6) | Run existing `extended_tests/` suite under Miri with `-Zmiri-tree-borrows -Zmiri-disable-isolation` |
| T-2 | Async iter + insert + resize stress | tokio-multi-task test: 8 inserters + 8 iterators + 1 resizer for 30s; assert no Miri error and no missed/duplicated key beyond what doc admits |
| T-3 | `retain_async(false)` linearizability vs concurrent `iter_async` | Property test with proptest: end state must be empty AND iterator must not yield any item from the post-clear window |
| T-4 | `OccupiedEntry::next_async` after self-mark-removed | proptest randomly drops the future at every await point; assert no leaked locks (probe via `try_lock`) |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | `relocate_bucket_async` early-return at line 921-923 leaks forgotten new-array locks if reachable | Move `ExitGuard` setup to immediately after the lock-acquisition loop (before line 921) |
| CR-2 | `partial_hash_array` is `[UnsafeCell<u8>; LEN]` accessed via non-atomic `read_cell`/`write_cell` (Family 6) | Replace with `[AtomicU8; LEN]` and `load(Relaxed)`/`store(Relaxed)`; impact is only in the inner search loop and is likely auto-vectorized either way |
| CR-3 | `writer_async`/`optional_writer_async`/`reader_async` lack the `check_ref` post-fix that `for_each_*_async` got in Sep 2025 | Decide explicitly: either add `check_ref` for symmetry, or add a comment explaining why the bucket-lock pinning is sufficient here |
| CR-4 | `Iter` doc comment admits duplicates during resize but not skips | Update doc to either rule out skips (preferred — fix iterator) or admit them |
| CR-5 | `BucketArray.linked_array_var` is overloaded as both "old → new" pointer and "next garbage" pointer | Add internal documentation distinguishing the two phases; consider splitting into two fields if memory allows |

## 7. Reference Pointers

- Full analysis report: `/home/ubuntu/Specula/case-studies/scc_2/.specula-output/analysis-report.md`
- Key source files:
  - `src/hash_table.rs:222-261` (peek_entry order), `:335-379` (writer_async), `:418-452` (optional_writer_async), `:512-565` (for_each_reader_async), `:618-694` (for_each_writer_async), `:801-854` (dedup_bucket_async), `:891-943` (relocate_bucket_async), `:1003-1094` (relocate_bucket), `:1098-1255` (start/end_incremental_rehash + incremental_rehash_*), `:1306-1429` (try_resize)
  - `src/hash_table/bucket.rs:144-177` (insert), `:181-218` (remove), `:220-249` (mark_removed), `:329-368` (extract_from), `:438-460` (insert_entry), `:462-495` (clear_unreachable_entries), `:498-540` (drop_unreachable_entries), `:614-720` (search_*)
  - `src/hash_index.rs:1141-1180` (iter), `:1184-1218` (reclaim_memory/dealloc_garbage), `:1319-1350` (Drop), `:1374-1389` (defer_reclaim), `:2091-2165` (Iter::next)
  - `src/async_helper.rs:33-76` (AsyncGuard)
- GitHub issues most relevant: #16, #19, #28, #45, #88, #118, #176, #190, #194, #198, #200
- Bug-fix commits most relevant: `9573fa1` (Nov 2025), `b915090` (Sep 2025), `94303a4` (#190 ABA), `4939622` ("robust reference checking across awaits")
- Reference algorithm: there is no published paper; comparable Rust crates `flurry`, `dashmap`, `papaya` (already case-studied in this corpus).
