# Analysis Report — `scc` (scalable-concurrent-containers)

Audit trail for the modeling brief. This document records coverage statistics, the full set of evidence reviewed, every finding (including those rejected as false positives), and the verification chain for the conclusions in `modeling-brief.md`.

---

## 0. Scope

- **Target**: `scc` v3.4.8, Rust crate `wvwwvwwv/scalable-concurrent-containers`.
- **Local checkout**: `/home/ubuntu/Specula/case-studies/scc_2/artifact/scalable-concurrent-containers`.
- **Branch**: tip = `3d3d6b4 TOMBSTONE` (Jan 2026); fetched 1151-commit history from origin via `git fetch --unshallow`.
- **System category**: Category B (Concurrent / Lock-Free / Runtime), sub-category "concurrent collections" (per `concurrent-analysis.md` § 5 prioritization table).
- **Justification**: in-process concurrent data structures, EBR reclamation (`sdd`), per-bucket `saa::Lock`, no message-passing, no persistence.

---

## 1. Phase 1: Reconnaissance

### 1.1 Module map

| Module | Lines | Role |
|---|---:|---|
| `src/lib.rs` | 35 | re-exports `sdd::*`, public modules |
| `src/async_helper.rs` | 125 | `AsyncGuard`, `AsyncWait`, `TryWait` — guard reset across `.await` |
| `src/exit_guard.rs` | 53 | scope-guard helper |
| `src/equivalent.rs` | 43 | `Equivalent`, `Comparable` traits |
| `src/hash_table.rs` | 1684 | `HashTable` trait — resize, rehash, dedup_bucket, relocate, peek, writer/reader paths shared by HashMap/Index/Set/Cache |
| `src/hash_table/bucket.rs` | 1565 | `Bucket`, `Reader`, `Writer`, `EntryPtr`, mark_removed, kill, search/insert/extract_from, drop_unreachable_entries |
| `src/hash_table/bucket_array.rs` | 251 | `BucketArray` — fixed-size array of buckets, with `linked_array` pointer |
| `src/hash_index.rs` | 2181 | `HashIndex` (lock-free read, per-entry tombstone migration) |
| `src/hash_map.rs` | 2383 | `HashMap` (write-locked, bucket-batch migration) |
| `src/hash_set.rs` | 948 | `HashSet` (thin wrapper) |
| `src/hash_cache.rs` | 1835 | `HashCache` (LRU on bucket) |
| `src/tree_index.rs` | 1113 | `TreeIndex` |
| `src/tree_index/node.rs` | 399 | `Node` enum |
| `src/tree_index/internal_node.rs` | 1365 | internal node split/merge |
| `src/tree_index/leaf_node.rs` | 1396 | leaf wrapper |
| `src/tree_index/leaf.rs` | 1345 | sorted-key leaf |
| **TOTAL CORE** | **~17,164** | |

### 1.2 Concurrency model

- Each container has both `*_sync` and `*_async` variants of every API.
- Lock primitive: `saa::Lock` with reader-shared / writer-exclusive modes plus a terminal `poison` (= "killed") state. `Reader`/`Writer` newtype wrappers hold the lock.
- EBR primitive: `sdd::Guard` pins the global epoch; `sdd::AtomicShared<T>` is a refcounted-shared atomic pointer with `Acquire`/`Release`/`AcqRel` semantics. `defer_reclaim` puts a Shared on a per-container garbage chain; `Guard::accelerate()` and `set_has_garbage()` advance the global epoch.
- HashIndex is the architectural outlier: **lock-free reads**. Readers walk `Bucket::search_entry` without taking any lock, relying on `Acquire`-ordered loads on `removed_bitmap` and `occupied_bitmap`.

### 1.3 Atomicity boundaries (for HashIndex insert path)

```
1. Load bucket_array_var (Acquire) — observable: array swap
2. Check linked_array — if present, run dedup_bucket on this bucket_index
     2a. dedup_bucket_async/sync may suspend (await) → AsyncGuard reset
3. Compute bucket_index from hash
4. Try-lock bucket via Writer::try_lock OR async Writer::lock_async (await)
5. Search bucket for existing key (read partial_hash_array, occupied_bitmap)
6. If absent → Bucket::insert
     6a. Possibly clear_unreachable_entries (drops tombstoned entries)
     6b. Write data_block[i] (non-atomic ptr::write)
     6c. Write partial_hash_array[i] (non-atomic byte write)
     6d. Store occupied_bitmap with Release (INDEX) or Relaxed (others)
7. Release Writer (drop)
8. Possibly try_shrink → may trigger try_resize
```

Observable boundaries (where another thread can interleave): 1↔2, 2↔3, 3↔4, await-points inside 4, 7↔8.

---

## 2. Phase 2: Bug Archaeology

### 2.1 Coverage statistics

- **Bug-fix commits identified**: 370 commits matching `fix|bug|race|panic|deadlock|safety|correctness|leak|use-after-free|UB|undefined`. ~150 of these touch core files (excluding chore/lint/doc).
- **GitHub issues collected**: 250 (full list, all states).
- **Issues read with full discussion**: 40+ (#16, #19, #20, #21, #22, #23, #24, #25, #28, #32, #44, #45, #57, #60, #63, #64, #65, #66, #71, #74, #77, #78, #82, #84, #86, #87, #88, #115, #116, #117, #118, #119, #120, #121, #122, #123, #129, #130, #135, #140, #150, #153, #155, #156, #157, #158, #161, #162, #165, #167, #168, #172, #173, #175, #176, #178, #186, #189, #190, #193, #194, #198, #199, #200, #202, #209, #212).
- **Confirmed bugs**: ~45 distinct (multiple commits per issue counted once).
- **False-positive issues**: #165 (semantics-by-design), #172 (irreproducible).
- **Open `bug`-labeled issues at scan time**: 0.
- **Open PRs at scan time**: 0.

### 2.2 Bug families (historical)

(Adapted from the bug-archaeology subagent's report.)

| Family | Description | Count |
|---|---|---:|
| F1 | Iterator/scan + concurrent insert/remove | 6 |
| F2 | Resize / per-entry migration race | 2 |
| F3 | Async reference invalidation (drop-without-poll, ABA, missing check_ref) | 3 |
| F4 | EBR reclamation timing | 7 |
| F5 | TreeIndex split/merge/clear/iter races | 9 |
| F6 | HashCache LRU bookkeeping | 3 |
| F7 | Memory ordering / weak-arch fences | 4 |
| F8 | UB / Miri / alignment / 32-bit | 4 |
| F9 | Compiler-version regressions | 1 |

### 2.3 Headline historical bugs

| Issue/Commit | Family | Mechanism | Severity |
|---|---|---|---|
| #28 (CellLocker read-after-free) | F4 | Bucket lock acquired without thread-pinned EBR guard | Critical |
| #84 (`remove(existing_key)` returns None) | F9 | Rust 1.65 `MaybeUninit` codegen change | Critical |
| #86 (alignment + Collector Miri) | F8 | `Layout::from_size_align_unchecked(_,1)` lied about alignment | High |
| #118 (AsyncWait drop) | F3 | Future dropped without poll → stale waker → unreachable! | High |
| #153 (TreeIndex on aarch64/ppc64le) | F7 | Relaxed dependent loads on weak archs | Critical |
| #176 (read released lock too early — yanked 2.0–2.3) | F4 | Bucket lock dropped before user closure finished | Critical |
| #190 (ABA in async ref check) | F3 | Raw entry pointer reused across await | Critical |
| #194 (stack overflow under tokio) | F8 | 2KB+ futures on 2MB stack | Med |
| #198/#200 (peek refs outliving container) | F4 | `peek` lifetime tied to Guard, not `&self` | High |
| `9573fa1` (Nov 2025) | F1+F2 | `extract_from` clear-then-publish ordering allowed neither-array window | High |
| `b915090` (Sep 2025) | F3 | `for_each_*_async` missed `check_ref` after lock acquisition | Med |

### 2.4 Recurring mechanisms

- **F1 mechanism**: scanner caches a `BucketArray` pointer; concurrent migration changes the chain; resumption logic either visits the entry twice or misses it. Doc admits duplicates, not skips.
- **F2 mechanism**: per-entry migration in HashIndex creates a window where the entry is in both arrays (or in neither, pre-`9573fa1`). Lookup order (old-then-new) determines which observation wins.
- **F3 mechanism**: `AsyncGuard` is reset on lock contention await; references captured before the await may be stale; the codebase added `check_ref` to bridge most of these but not all.
- **F4 mechanism**: lazy-drop entries via `clear_unreachable_entries` gated by epoch generation; readers' guards must pin within ≤1 generation of the drop.
- **F5 mechanism**: TreeIndex structural mutation (split/merge/root-swap/clear) replaces internal pointers while readers/inserters are mid-descent.

---

## 3. Phase 3: Deep Analysis

Analysis was distributed across four parallel subagents:

- **Subagent A**: GitHub issue mining + family grouping (consumed under § 2).
- **Subagent B**: `hash_index.rs` + `hash_map.rs` (combined ~4,500 lines).
- **Subagent C**: `hash_table.rs` + `hash_table/bucket.rs` + `bucket_array.rs` (combined ~3,500 lines).
- **Subagent D**: `tree_index/*` (combined ~4,200 lines).

Each subagent read its files in full (no skim), emitted findings with `file:line` citations, and produced suspect-interleaving narratives.

### 3.1 Findings from Subagent B (HashIndex/HashMap)

**B1** (verified). `Bucket::next_entry` for INDEX uses `(!removed_bitmap & occupied_bitmap)` with `Acquire` on both loads (`bucket.rs:1027`). Concurrent `mark_removed` correctly hides slots from iteration. *No bug.*

**B2** (verified, latent). `optional_writer_async` (`hash_table.rs:418-452`) does **not** call `check_ref(self.bucket_array_var(), current_array, Acquire)` after `Writer::lock_async(...).await`. Same for `writer_async` (line 370-378), `reader_async` (line 263-301). Compare to `for_each_writer_async` line 658 (added Sep 2025 in `b915090`) and `for_each_reader_async` line 546.

Re-verified by reading current source: `for_each_*_async` checks; `*_async` (single-bucket) do not. The asymmetry is real. Whether it is sound depends on the bucket lock's pinning-of-array invariant: `bucket.rs:748-749` "The bucket was not killed, and will not be killed until the Writer is dropped. This guarantees that the BucketArray will survive as long as the Writer is alive." — the array survives, but it may have been overtaken by a newer current.

**Disposition**: model-checkable. Report as MC-3.

**B3** (rejected). The bucket array variable used in for-each iteration once held a stale `current_array` after suspension; this was the bug fixed by `b915090`. Current code has the fix. *No new bug.*

**B4** (verified). HashIndex::Iter (`hash_index.rs:2099-2164`) holds `bucket_array: Option<&'h BucketArray>` and `guard: &'h Guard`. After visiting all buckets in the captured array, it walks lines 2127-2155 to either advance to a newer array, restart on the new current, or break. **Skip path**: if a second resize completed during iteration so that the captured array is neither current nor `current.linked_array`, the iterator falls into the `else { current_array }` branch (line 2153) and starts at index 0 of `current_array`. Entries that migrated from the captured array → intermediate array → current array, into bucket-indices below the iterator's notional position, would have been visited only if the iterator restarts from index 0 (which it does in this branch). But the iterator's `index` is reset to 0 only when entering a "newer array" (line 2129); if the iterator was *already* in the new current and still has earlier indices to visit, **no skip is possible**. The skip surface is when the iterator is in the *old* array and the resize completes during a `next()` call — at that point the iterator is in the linked branch and walks the new current from index 0.

**Disposition**: this is the F1 surface; documented behavior admits duplicates but not skips. Report as MC-1.

**B5** (verified, sound). `dealloc_garbage` (`hash_index.rs:1191-1218`) compares `self.garbage_epoch` with `guard.epoch()` via `Epoch::in_same_generation`. Race with concurrent `defer_reclaim` (which writes garbage_epoch then garbage_chain) is safe — the worst case is the reader skips reclamation and tries again later. *No bug.*

**B6** (verified, sound). `OccupiedEntry::next_async` (`hash_index.rs:1804-1819`, `hash_map.rs:2010-...`) drops the existing `LockedBucket` inside `next_async`'s call to `for_each_writer_async`, then re-locks. The handoff is clean (no reference held across the await). *No bug.*

### 3.2 Findings from Subagent C (Bucket / HashTable)

**C1** (verified, formally-UB / hardware-safe). `Bucket::search_data_block` (`bucket.rs:685-719`) reads `partial_hash_array[i]` non-atomically for **all** i in `0..LEN`, regardless of whether bit i is masked out. Writers (mark_removed, insert_entry) write the byte non-atomically. For INDEX, lock-free readers race with writers. **Formally UB in the Rust memory model**; benign on x86_64 (single-byte access is tearing-free). Miri would flag.

**Disposition**: code-review-only / test-verifiable. Report as CR-2 / T-1.

**C2** (verified, sound). `extract_from` for INDEX (`bucket.rs:329-368`) uses Release on both `insert-into-new` and `clear-on-old` (post-`9573fa1`). Lookup order (old-then-new) plus the publish-then-clear ordering means lock-free readers see the entry in exactly one place after the operation, or see it briefly in old or both during the window. The "neither-array" window that existed before `9573fa1` is closed.

**Disposition**: model-checkable to confirm `MigrationVisibleEverywhere` invariant under the post-fix ordering. Report as MC-2.

**C3** (verified, sound). `kill()` precondition for INDEX requires `removed_bitmap == occupied_bitmap` (`bucket.rs:794-797`), meaning every still-occupied slot must be tombstoned. `relocate_bucket_*` clears occupied bits via `extract_from` for migrated entries, so by the time of kill, occupied bits cover only entries that were tombstoned-but-not-yet-relocated; those have the removed bit set too. *No bug.*

**C4** (verified, latent). `relocate_bucket_async` early-return at `hash_table.rs:921-923` leaks the forgotten new-array-bucket locks acquired at lines 910-917. **Reachability analysis** (performed in this report's main flow): while the caller holds `old_writer` on `old_array.bucket(old_index)`, no `incremental_rehash_*` from another thread can complete (it would need to lock that bucket too), so `linked_array_var` cannot be swapped to `None`. The early-return path is **not reachable** in the current code. **But the code is structured as if it is reachable.**

**Disposition**: defensive code with a latent leak. Report as CR-1 / Family 5.

**C5** (verified, sound). `start_incremental_rehash` / `end_incremental_rehash` (`hash_table.rs:1098-1154`) protocol: each `start` adds `BUCKET_LEN+1` to a metadata counter; each `end-success` subtracts 1. The "all done" condition is `(metadata & (BUCKET_LEN-1) == 0) && metadata >= old_array.len()`. Multi-thread interactions verified.

### 3.3 Findings from Subagent D (TreeIndex)

**D1** (semantic limitation). `TreeIndex::clear` swaps the root (`tree_index.rs:131-136`); concurrent `insert*` may already be descending into the orphaned subtree. Memory-safe (EBR keeps subtree alive) but the insert may succeed without being reachable from the new root. CHANGELOG already lists multiple fixes for this class (3.2.0, 2.2.2, 2.1.16); the maintainer has not committed to full linearizability with `clear`.

**Disposition**: documented limitation; out of scope for the current modeling round (focus on hash side per the prompt).

**D2** (semantic limitation). `TreeIndex::remove_range` may silently drop concurrent inserts to a fully-contained child. Comments at `internal_node.rs:463-464` and `leaf_node.rs:464-465` document this.

**Disposition**: documented limitation.

**D3** (verified, sound). `LeafNode::push_back` marks the new leaf to inform scanners of the structural change. The comment at `leaf_node.rs:824-826` describes the invariant; subagent verified the call sites pass `true` for the mark argument.

### 3.4 Findings cross-referenced into Bug Families

| Subagent finding | Bug Family in Modeling Brief |
|---|---|
| B2 (no check_ref in single-bucket *_async) | F3 |
| B4 (Iter skip during resize) | F1 |
| C1 (partial_hash byte race) | F6 |
| C2 (extract_from window) | F2 |
| C4 (relocate_bucket_async lock leak — latent) | F5 |

---

## 4. Verification Discipline

### 4.1 Re-reads

The following claims were re-verified by directly reading the indicated lines after the subagent reports:

| Claim | Verified at |
|---|---|
| `optional_writer_async` lacks `check_ref` after `Writer::lock_async(...).await` | `hash_table.rs:418-452` re-read. Confirmed: line 442 has lock acquisition, lines 443-449 build `LockedBucket` directly with no `check_ref`. |
| `for_each_writer_async` has `check_ref` after lock acquisition | `hash_table.rs:618-694`, line 658: `if !async_guard.check_ref(self.bucket_array_var(), current_array, Acquire) { break; }`. |
| `extract_from` for INDEX uses Release on both publish-new and clear-old | `bucket.rs:329-368` and the post-`9573fa1` code. Confirmed: `mo = if TYPE == INDEX { Release } else { Relaxed }` at line ~439, used for both `link.metadata.occupied_bitmap.store(.., mo)` and `from_writer.metadata.occupied_bitmap.store(.., mo)`. |
| `mark_removed` writes partial_hash byte non-atomically before Release-storing removed_bitmap | `bucket.rs:222-249`. Confirmed: `write_cell` at lines 230, 240 uses `&mut *cell.get()`; Release-store at lines 238, 248. |
| `relocate_bucket_async` early-return at line 921-923 has no ExitGuard | `hash_table.rs:910-934`. Confirmed: ExitGuard at line 926 is installed *after* the early return at 921-923. |
| HashIndex::Iter::next allows duplicates per doc | `hash_index.rs:1141-1145` doc; iter logic at 2091-2165. Confirmed text: "the same key-value pair can be visited more than once if the [`HashIndex`] is being resized." |

### 4.2 Compensating mechanisms checked

- **C4 (lock leak)**: compensating mechanism is the bucket-lock-pins-old-array invariant, which makes the early-return unreachable.
- **C2 (extract_from window)**: compensating mechanism is publish-before-clear ordering plus reader's old-then-new lookup; ensures at-least-once observation.
- **C1 (partial_hash byte race)**: compensating mechanism is the full Acquire-Release ordering on bitmap atomics, which masks any byte read for slots not in the live bitmap. The byte read for live slots could see either old or new value, both safe paths in the search loop.

### 4.3 False positives explicitly excluded

- **Subagent C's "Concern 5" about `kill` precondition for INDEX**: re-verified that migration only clears occupied bits and never sets removed bits, so post-migration the remaining occupied/removed pair are equal (all tombstoned). *Not a bug.*
- **Subagent B's earlier draft suggestion that the iterator could observe a freed `(K,V)` via stale partial_hash byte**: re-verified that the search loop checks `key.equivalent(&entry.0)` after the partial_hash compare; even if partial_hash matches spuriously, the key compare would catch it. The Guard pins the slot so no UAF. *Not a bug.*
- **Subagent A's count of #84 as race**: actually a compiler-version regression (F9), not a concurrency race. Reclassified.
- **Issue #165 "get returns old value after insert"**: by-design (insert doesn't replace; user wanted `upsert`). *Not a bug.*

### 4.4 Findings rejected for current modeling round

- **TreeIndex split/merge races (Family 5 of bug archaeology)**: outside the prompt's "iter+modify+resize" focus on the hash side; many fixes already landed.
- **HashCache LRU bookkeeping**: structurally orthogonal; few unfixed bugs.
- **Allocator failure / OOM**: validated by previous round.
- **Memory-ordering relaxation as universal adversary**: explicitly limited to the Family 2 ordering question (pre-`9573fa1` state).

---

## 5. Coverage Summary

- **Files read in full (deep analysis)**: `hash_index.rs`, `hash_map.rs`, `hash_table.rs`, `hash_table/bucket.rs`, `hash_table/bucket_array.rs`, `tree_index.rs`, `tree_index/node.rs`, `tree_index/internal_node.rs`, `tree_index/leaf_node.rs`, `tree_index/leaf.rs`, `async_helper.rs`, `exit_guard.rs`, `lib.rs`.
- **Files NOT deeply read**: `hash_set.rs` (thin wrapper on HashMap, behavior subsumed), `hash_cache.rs` (Family 6 on bug archaeology — out of scope for this round), `serde.rs`, `equivalent.rs`, tests/.
- **Git commits analyzed**: 370 bug-fix commits identified; ~50 read in full diff for the recent (post-3.0) era.
- **GitHub issues read with full discussion**: 40+.
- **Subagents launched**: 4 in parallel for deep analysis + 1 for issue mining.

---

## 6. Output Files

- `/home/ubuntu/Specula/case-studies/scc_2/.specula-output/modeling-brief.md` — primary deliverable.
- `/home/ubuntu/Specula/case-studies/scc_2/.specula-output/analysis-report.md` — this file.
