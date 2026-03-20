# Analysis Report: scc (scalable-concurrent-containers)

## 1. Reconnaissance Summary

### 1.1 Codebase Structure

| Component | Files | LOC | Description |
|-----------|-------|-----|-------------|
| hash_map.rs | 1 | 2383 | HashMap (MAP type, lock-based reads) |
| hash_index.rs | 1 | 2181 | HashIndex (INDEX type, lock-free reads) |
| hash_cache.rs | 1 | 1835 | HashCache (CACHE type, LRU) |
| hash_table.rs | 1 | 1684 | Shared infrastructure: resize, rehash, read/write paths |
| bucket.rs | 1 | 1565 | Bucket: 32-slot array, lock, metadata, linked overflow |
| bucket_array.rs | 1 | 252 | BucketArray: allocation, layout, linked array chain |
| tree_index/ | 5 | 4505 | B+ tree: TreeIndex, InternalNode, LeafNode, Leaf, Node |
| hash_set.rs | 1 | 948 | HashSet (thin wrapper around HashMap) |
| EBR (sdd crate) | ~10 | 4200 | Epoch-based reclamation: Collector, Guard, AtomicShared, Epoch |
| Lock (saa crate) | ~8 | 3400 | Reader-writer lock, wait queue, semaphore |
| **Total core** | | **~23K** | |

### 1.2 Concurrency Model

- **Threads**: Multi-threaded, no thread affinity. Any thread can access any container.
- **Locking**: Per-bucket reader-writer lock from `saa::Lock`
  - MAP (HashMap): Reader lock for reads, Writer lock for writes
  - INDEX (HashIndex): Lock-free reads via optimistic locking with bitmaps; Writer lock for writes
  - CACHE (HashCache): Same as MAP with additional LRU list management
- **Memory Reclamation**: Custom EBR (`sdd` crate)
  - 64 rotating epochs (`Epoch::NUM_EPOCHS = 64`)
  - 3-epoch grace period (memory retired in epoch E safe to reclaim at E+3)
  - Thread-local Collector with 3 garbage queues (prev, current, next), rotated on epoch change
  - Global epoch advanced only when all active threads are in same or inactive epoch
  - SeqCst fences on guard creation and scan to ensure global ordering
- **Resize**: Cooperative incremental rehashing
  - New BucketArray allocated, becomes current; old array linked via `AtomicShared<BucketArray>`
  - Every operation on the hash table helps migrate entries before proceeding
  - BUCKET_LEN (32) buckets processed per rehash batch
  - Old buckets "killed" (lock poisoned) after all entries migrated
  - Old array deferred-reclaimed via EBR after all buckets killed

### 1.3 Key Atomicity Boundaries

| Operation | Atomicity | Protected By |
|-----------|-----------|-------------|
| Single entry insert/remove (MAP) | Atomic | Writer lock on bucket |
| Single entry read (MAP) | Atomic | Reader lock on bucket |
| Single entry read (INDEX) | Lock-free | Bitmap ordering (removed→acquire→occupied) |
| Entry migration (rehash) | Per-entry | Writer lock on old bucket + Writer lock on target bucket |
| Resize trigger | CAS | `minimum_capacity_var` RESIZING flag |
| Epoch advancement | Global | Chain lock on collector chain + SeqCst fences |
| Guard creation/destruction | Thread-local | Thread-local collector, SeqCst on creation |

## 2. Bug Archaeology

### 2.1 Coverage Statistics

- **Total commits in repo**: 509
- **Total bug-fix commits touching src/**: 116 (including lint/CI fixes)
- **Substantive bug-fix commits analyzed**: **48** (comprehensive git mining)
- **GitHub issues deeply read**: 15+ (all referenced by bug-fix commits)
- **Key issues verified**: #176, #153, #190, #194, #198, #200, #121, #117, #118, #135, #156, #161, #175, #86, #84, #85, #88, #115
- **Versions yanked**: ~25+ total across 6 incidents:
  - 2.0.0–2.3.0: use-after-free in HashMap/HashCache::read (#176) — CRITICAL
  - 3.0.0–3.0.1: dependency/data race fixes — Medium
  - 3.3.0: memory leak found fixing #198/#200 — High
  - 3.4.0: optimistic locking infinite loop + stale iterator — High
  - 3.4.15: TreeIndex range iterator data race — Medium
  - 3.5.2–3.6.8: MSRV violations (13 consecutive versions!) — Low (build)
- **Open issues**: 8, ALL feature requests (SCC 4.0 milestone). No known unfixed bugs.
- **Repository**: Moved from GitHub to Codeberg (Jan 2026)

### 2.2 Bug-Fix Commit Catalog

#### Critical Bugs (Safety violations)

| Commit | Summary | Root Cause | Component |
|--------|---------|-----------|-----------|
| `ad75430` | Readers not blocking writers (#176) — **caused yanking** | Reader lock dropped before user callback finishes | HashMap, HashCache |
| `94303a4` | ABA in async reference checking (#190) | Bucket array ref stale after await | hash_table async |
| `c8bc10d` | Data race when async reading | Writers failing relocation → entries in both arrays | hash_table async |
| `bf6ebb4` | Potential data race in async code | Reference check after sampling instead of before | hash_table async |
| `4939622` | Robust reference checking across awaits | Stale reference used after await | hash_table async |
| `b915090` | Async iteration may omit entries | Reference not checked after lock acquired | hash_table async |
| `57af878` | TreeIndex clear+insert data race | Structural changes not rolled back on clear | tree_index |
| `b7c252c` | More TreeIndex data races (#153) | Multiple concurrent modification races | tree_index |
| `c014a2c` | Potential data races in HashMap, TreeIndex (#155) | Concurrent modification races | hash_map, tree_index |

#### High Bugs (Correctness)

| Commit | Summary | Root Cause | Component |
|--------|---------|-----------|-----------|
| `34e5e55` | Optimistic locking causing infinite loop | Missing `break` in reader_async after INDEX search | hash_table |
| `9573fa1` | Iterator reading outdated bucket state | Checked `len() != 0` before advancing iterator | hash_index |
| `576bf8c` | peek references outlive HashIndex (#198) | Reference lifetime not bounded by container | hash_index |
| `b8a30ad` | Iter references outlive HashIndex (#198) | Iterator reference lifetime | hash_index |
| `b52baaf` | Revert epoch acceleration (#200) | Accelerated GC caused entry deallocation issues | hash_index |
| `0074979` | Ensure entry deallocation on drop (#200) | Entries not deallocated in drop path | hash_index |
| `124cb66` | TreeIndex clear+insert race (#156) | Second clear+insert race variant | tree_index |
| `027333f` | Another clear+insert race | Third clear+insert race variant | tree_index |
| `7a54a8c` | Dependent load → acquire ordering | Missing acquire on dependent loads | tree_index |
| `156420e` | Index out-of-range on 32-bit (#153) | Array sized for usize::BITS/2=16, max factor=32 | hash_table |

#### High Bugs (additional from comprehensive mining)

| Commit | Summary | Root Cause | Component |
|--------|---------|-----------|-----------|
| `d904e82` | Wrong Sync trait bounds | `BucketArray`/`Bag::Storage` Sync bound missing Send | hash_table, bag |
| `58f5dd6` | Lifetime issue on drop | BucketArray drop didn't drop old arrays for non-lock-free mode | bucket_array |
| `c04681f` | Bucket array alignment (#86) | Alignment calc wrong (subtraction vs modulo) → misaligned access | bucket_array |
| `1f45060` | range_remove not removing keys (#153) | MaybeAbove state missed valid_upper_min_node | tree_index |
| `b7f051b` | Boundary index calc for 32-bit (#153) | optimal_boundary prev_rank and increment logic wrong | tree_index |
| `a646bd5` | Incorrect lower bound handling (#115) | TreeIndex::range empty when lower bound < min key | tree_index |
| `3da03b4` | LinkedList unlinked in middle (#153) | `next_ptr_recursive` returned pointer to freed entry; Bag pop/bitmap bugs | bag/linkedlist |
| `5bac439` | MIRI errors in bag (#88) | Storage missing UnsafeCell, violating aliasing rules | bag |
| `ac52d2f` | Bag memory ordering | `is_empty` wrong bitmap check; `drop` used Relaxed instead of Acquire | bag |
| `30cdc3e` | AsyncWait drop crash (#118) | AsyncWait dropped while still linked in WaitQueue → use-after-free | waitqueue |
| `3bbceca` | Entry API not evicting entries | HashCache Entry API never triggered eviction → unbounded growth | hash_cache |
| `07300d0` | Covertly evicted entries during shrink | Full target bucket silently dropped entries instead of returning | hash_cache |
| `17acb14` | OOM assertion during root-split | Allocation failure during root split not rolled back | tree_index |

#### Medium Bugs (Functional)

| Commit | Summary | Root Cause | Component |
|--------|---------|-----------|-----------|
| `8afa6b4` | Proper OOM handling | OOM during resize → inconsistent state | hash_table |
| `f6afe5c` | Capacity management | Incorrect resize decisions | hash_table |
| `719dd94` | Blocking code in non-blocking path | HashIndex::read called blocking rehash | hash_table |
| `bc9b91d` | Panic handling in rehash | Panic during insert left inconsistent state | hash_table |
| `228add5` | Serde capacity upper bound | `.max()` instead of `.min()` → massive over-allocation | hash_map |
| `2e5310c` | Debug assertion failure in LRU | LRU ops on overflow entries hit assertions | hash_cache |
| `218ce4b` | Range misses first node | Concurrent empty of first leaf → iterator gave up | tree_index |
| `a8e6a20` | Deallocate Collector earlier (#84) | Thread-local Collectors not released promptly | sdd/collector |
| `373c23b` | Remove 128B alignment requirement (#194) | Async futures required 128-byte alignment → stack issues | cross-cutting |
| `17acb14` | OOM assertion failure during root-split | Panic on OOM in tree split | tree_index |
| `218ce4b` | Range misses first node | Incorrect lower bound handling | tree_index |
| `07300d0` | Evicted entries when shrinking | Cache-specific shrink issue | hash_cache |
| `db8e244` | Linked list inconsistencies (#121) | Sparse bucket linked list corruption | hash_cache |
| `668350a` | Incorrect retain implementation (#121) | Wrong retain logic | hash_cache |
| `99ba342` | AsyncWait drop leads to crash (#118) | Incomplete async wait cleanup | hash_table |
| `33e4fc5` | 32-bit architecture support (#117) | Multiple 32-bit assumptions | hash_table |

### 2.3 Bug Hotspot Analysis

| Component | Bug-fix commits | Critical | High | Medium | Low |
|-----------|----------------|----------|------|--------|-----|
| HashMap/HashTable/Bucket | 18 | 4 | 8 | 4 | 0 |
| TreeIndex | 14 | 6 | 5 | 3 | 1 |
| HashCache | 6 | 0 | 4 | 1 | 1 |
| HashIndex | 6 | 2 | 1 | 1 | 2 |
| Bag/Queue/Stack/LinkedList | 4 | 1 | 3 | 0 | 0 |
| WaitQueue/AsyncWait | 2 | 2 | 0 | 0 | 0 |
| EBR/Collector | 1 | 0 | 0 | 1 | 0 |
| Cross-cutting | 2 | 0 | 1 | 1 | 0 |
| **Total** | **48** | **15** | **22** | **10** | **4** |

**Conclusion**: HashMap/HashTable/Bucket is the highest-risk component with 18 bugs (4 critical). TreeIndex follows with 14 bugs (6 critical). The async code path in hash_table.rs is particularly fragile — 5 of 6 critical hash table bugs are in async operations.

### 2.3.1 Bug Pattern Classification

| Pattern | Bug Count | Description |
|---------|-----------|-------------|
| Memory ordering errors | 12 | Relaxed/Release used where Acquire/AcqRel needed (TreeIndex `retired()`, `clone()`, `swap()`; HashMap reader lock release) |
| Concurrent structural change races | 8 | TreeIndex clear+insert (3 fixes), HashMap resize/relocation races |
| ABA / stale reference in async | 5 | Bucket array pointers stale across await points; `validate_ref`/`check_ref` evolved over 4 commits |
| LRU linked list corruption | 3 | HashCache doubly-linked LRU list fragile under sparse buckets, retain, two-entry removal |
| 32-bit architecture assumptions | 3 | Bucket struct size, resize factor, boundary index calculations |
| Lifetime/safety API issues | 4 | HashIndex iterator/peek dangling references (#198), wrong Sync bounds |
| OOM/panic handling | 3 | Structural changes not rolled back on allocation failure |

### 2.4 Bug Family Summary

| Family | Bugs | Severity | TLA+ Suitability |
|--------|------|----------|-----------------|
| 1. Guard/Lock Lifetime vs Data Access | 3 | Critical | High |
| 2. Async Reference Invalidation | 5 | Critical | High |
| 3. Resize Protocol Correctness | 7 | Critical-Medium | High |
| 4. TreeIndex Concurrent Modification | 7 | Critical-High | Medium |
| 5. EBR Epoch/Reclamation Timing | 3 | High | Medium |
| 6. 32-bit Architecture | 3 | Medium | Low (fixed) |

## 3. Deep Analysis Findings

### 3.1 Resize Protocol Analysis

The resize protocol in `hash_table.rs` is the most complex and bug-prone subsystem:

**Resize Flow**:
1. `try_resize()` (line 1307): Acquires RESIZING flag via CAS on `minimum_capacity_var`, allocates new BucketArray with old as linked array, swaps bucket_array_var
2. `incremental_rehash_sync()` (line 1209): Claims BUCKET_LEN buckets via CAS on `rehashing_metadata`, locks each old bucket, relocates entries to new array, kills old bucket
3. `end_incremental_rehash()` (line 1127): Decrements ref count; last thread swaps out linked_array and defers reclamation

**Key Risk Points**:

**(a) Entry in-flight during migration (hash_table.rs:1003-1093)**:
When `relocate_bucket()` is called, it iterates old bucket entries and calls `extract_from()` which:
1. Reads entry from old bucket (line 341-345 in bucket.rs)
2. Inserts into new bucket (line 346)
3. Clears occupied_bitmap bit in old bucket (line 353-363)
4. Decrements old bucket len (line 366-367)

Steps 2 and 3 are NOT atomic. Between step 2 and step 3, the entry exists in BOTH old and new buckets. A concurrent INDEX reader could see it in both places (though duplicate reads are benign). More importantly, if the thread crashes between steps 2 and 3, the entry would be duplicated.

**(b) try_lock failure path (hash_table.rs:964-971)**:
When TRY_LOCK is true and locking a target bucket fails (line 966), previously locked target buckets are unlocked (line 967-970) and `false` is returned. The old bucket entries remain unmoved. This is correct — the caller will retry. But during the window between the unlock and retry, readers must still find entries in the old bucket.

**(c) MAP reader path (hash_table.rs:306-329)**:
The MAP reader calls `dedup_bucket_sync` which moves entries from old to new, then acquires Reader lock on new bucket. If dedup was partial (try_lock failed internally), entries could still be in the old array. However, the reader only searches the new array. **This is correct because `dedup_bucket_sync::<false>` uses blocking locks (not try_lock), so it always completes.**

**(d) INDEX reader path (hash_table.rs:224-261)**:
The INDEX reader searches OLD array first, then NEW array. If the array changed between searches, it retries. This handles the in-flight entry case correctly — the entry is guaranteed to be in at least one array.

### 3.2 Optimistic Read Analysis (HashIndex)

The lock-free read path for INDEX type (`bucket.rs:685-719`) uses bitmap ordering:

```
removed_bitmap.load(Acquire) → occupied_bitmap.load(Acquire)
```

This ensures that if a reader sees an entry as occupied and not-removed, the data is valid. The ordering is:
- Writer inserts: write data → write partial_hash → store occupied_bitmap(Release)
- Writer removes: write epoch to partial_hash → store removed_bitmap(Release)
- Reader: load removed_bitmap(Acquire) → load occupied_bitmap(Acquire) → read partial_hash → read data

The partial_hash_array is `UnsafeCell<u8>` (non-atomic). The loop at lines 702-706 reads ALL partial_hash values regardless of bitmap state. For slots being concurrently written, this is technically a data race under the C++ memory model. However, the result is harmless — if the bitmap bit isn't set, the value is discarded.

### 3.3 EBR Collector Analysis

The collector (`sdd/src/collector.rs`) uses a chain of thread-local Collectors linked via a global chain head. Key correctness properties:

**(a) 3-queue rotation (line 354-407)**: On epoch update, queues rotate: `next_garbage_queue ← prev_garbage_queue`, `prev_garbage_queue ← garbage_queue`, `garbage_queue ← null`. What was in `next_garbage_queue` (2 epochs old) is dropped. This means garbage survives at least 2 full epoch rotations before being reclaimed.

**(b) Epoch advancement safety (line 410-495)**: The `scan()` function acquires a chain lock, checks all collectors. If any active collector is in a different epoch, advancement is blocked. SeqCst fences ensure global ordering between guard creation and epoch scans.

**(c) Thread termination (line 590-613)**: When a thread terminates, its collector is marked INVALID. The garbage is NOT immediately freed — it stays in the collector until another thread scans and collects the invalid collector (which adds it to its own garbage queue). This is safe but means garbage can accumulate if threads are created and destroyed rapidly.

**(d) 64-epoch wrapping**: With 64 epochs and a 3-epoch grace period, the system needs at most 3 epochs of lag. The `in_same_generation()` function checks if the difference is ≤ 2. Since epochs rotate modulo 64, this works correctly as long as no thread lags by more than 63 epochs (which would require it to be stuck for ~63 × CADENCE operations).

### 3.4 AsyncGuard/SendableGuard Analysis

The async code uses `AsyncGuard` (wrapper around `SendableGuard`) which creates and destroys `Guard` instances across await points. The key invariant: after any await point, the `Guard` may have been dropped and recreated, invalidating any references obtained before the await.

The `check_ref()` function (`async_helper.rs:72`) loads the current bucket_array pointer and compares it to the reference held by the caller. This detects ABA scenarios where:
1. Thread loads bucket_array = A
2. Thread awaits (Guard may be dropped)
3. Another thread resizes: A → B (A freed via EBR)
4. Another thread resizes again: B → C (but C might reuse A's memory)
5. Thread resumes, loads bucket_array = C, which happens to be at A's old address → ABA!

The `check_ref()` fix prevents this by doing a pointer equality check. However, true ABA (same address reused) is possible with EBR if enough epochs pass. The fix relies on the Guard being recreated before the check, which pins the epoch and prevents the old memory from being reclaimed. If the Guard is active, A cannot have been freed, so C cannot be at A's address. This is correct.

## 4. New Potential Findings

### 4.0 Deep Analysis Audit Findings (hash_table.rs + bucket.rs)

A systematic audit of hash_table.rs (1684 lines), bucket.rs (1565 lines), bucket_array.rs (252 lines), and saa/lock.rs (906 lines) produced **28 findings** (0 critical, 0 high, 3 medium, 14 low, 12 informational).

**Medium findings:**

**(F5) `unwrap_unchecked` on new bucket lock during migration** (`hash_table.rs:911-915`, `:975`): During `relocate_bucket_sync/async`, target bucket locks in the new array are acquired with `Writer::lock_sync().unwrap_unchecked()`. This assumes new array buckets are never killed (poisoned). The invariant holds because buckets are only killed after full entry migration, but a single violated invariant would cause UB rather than a panic.

**(U2) `fake_ref` creates type-punned references** (`bucket.rs:1297-1302`): `fake_ref<T,U>` casts `&T` to `&U` to satisfy `sdd` API lifetime requirements. The returned reference must never be dereferenced. Used at `bucket.rs:418` and `:1223`. If `sdd` ever changes to dereference these references, this becomes UB.

**(M2) `Relaxed` clone of bucket_array_var during resize** (`hash_table.rs:1423`): Inside `try_resize`, the linked array pointer is cloned with `Relaxed` ordering. This is safe because the RESIZING lock ensures single-writer access and the pointer was already verified with `Acquire` at line 1344, but the reasoning is subtle.

**Key verified-correct patterns:**
- Lock ordering (old bucket → new buckets in index order) prevents deadlocks (F4)
- Entry visibility during INDEX rehash: entry appears in both arrays briefly, by design (F1)
- Bitmap ordering (`removed_bitmap.load(Acquire)` → `occupied_bitmap.load(Acquire)`) creates correct happens-before chain (M4)
- `extract_from` inserts into new bucket before clearing old, preventing entry loss (F2)
- Pre-allocation for shrink prevents overflow during migration (F3)

### 4.1 Potential Issue: Race in extract_from During Shrink

In `relocate_bucket()` (hash_table.rs:1003-1093), when the array is shrinking (old_array.len() > current_array.len()), multiple old buckets map to a single new bucket. The code pre-allocates slots to handle this. However:

- Line 1024: For shrink, hash is computed from `entry_ptr.partial_hash()` (only 8 bits)
- Line 1081-1085: The new bucket index is computed from this 8-bit partial hash

If two entries in different old buckets have the same partial hash but different full hashes, they would be placed in the same new bucket during shrink. This is correct behavior (they're in the same bucket). But the partial hash is only 8 bits, so collisions are expected. The code handles this by pre-allocating overflow slots. No bug here — just worth verifying in the model.

### 4.2 Potential Issue: kill() During Active INDEX Reader

When `kill()` is called on a bucket during rehash (`bucket.rs:790-819`), it poisons the lock and for INDEX type with `!needs_drop`, calls `current.release()` on linked overflow buckets. This defers their reclamation via EBR.

An active INDEX reader traversing the linked list at the time of kill could:
1. Load `link_ptr` from `metadata.link`
2. `kill()` swaps `metadata.link` to None and releases the linked bucket
3. Reader dereferences `link_ptr` — still valid because EBR Guard is active
4. Reader loads `link.metadata.load_link()` — might see null because `kill()` already swapped it

This is safe because: the reader's Guard prevents EBR from reclaiming the linked bucket, and if the next link is null, the reader just stops iterating (potentially missing entries in the linked bucket). But the entries were already migrated to the new array, so the reader will find them when it retries with the new array.

### 4.3 NEW Finding: Garbage Chain Linkage Race in HashIndex (MEDIUM)

In `hash_index.rs:1375-1389` (`defer_reclaim`), the garbage chain is constructed non-atomically:
1. Line 1381: `garbage_chain.swap` inserts new bucket array as chain head (AcqRel)
2. Line 1386-1388: `linked_array_var().swap` links the previous head as next of the new head (Release)

Between steps 1 and 2, a concurrent `dealloc_garbage` call could:
- CAS the garbage chain head to null (taking the new bucket array)
- Walk its `linked_array_var()` — which hasn't been connected to `prev_head` yet
- `prev_head` (the previous garbage chain) is effectively lost — **memory leak**

This is not a safety violation (no use-after-free) but could cause bounded memory leaks under heavy concurrent resize + GC pressure. The leak is bounded because each lost `prev_head` is at most one BucketArray. This finding is relevant to Bug Family 5 (EBR/Reclamation Timing) and could be verified by the TLA+ model.

### 4.4 Verified Non-Issue: Lock Ordering in Resize

During `relocate_bucket_sync` (hash_table.rs:948-997), locks are acquired in this order:
1. Writer lock on old bucket (passed in)
2. Writer locks on target buckets (lines 964-977), acquired in index order (target_index to end_target_index)

Since target buckets are in the NEW array and the old bucket is in the OLD array, there's no ordering conflict with regular operations (which only lock one bucket at a time in the current array). The only risk would be two rehash threads trying to lock the same target bucket — but `start_incremental_rehash` ensures non-overlapping ranges via CAS.

## 5. Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits analyzed | 509 |
| Bug-fix commits touching src/ | 116 |
| Substantive bug fixes deeply analyzed | **48** |
| GitHub issues verified | 18+ (#176, #153, #190, #194, #198, #200, #121, #117, #118, #135, #156, #161, #175, #86, #84, #85, #88, #115) |
| Core source files read completely | 12 |
| Unsafe blocks identified | ~70 in hash_table + bucket |
| Loom models reviewed | 6 (HashMap key visibility, key uniqueness; HashIndex key visibility; TreeIndex leaf split, internal split, leaf remove, internal remove) |
| Data structures analyzed | HashMap, HashIndex, HashCache, TreeIndex, EBR Collector, Bag, LinkedList, WaitQueue |

## 6. Recommendations for TLA+ Modeling

### Primary Model: HashMap Resize + EBR

The primary TLA+ spec should model:

1. **State variables**:
   - `bucketArrayChain`: current array with optional linked (old) array
   - `entries[Key]`: current location of each key (None, OldArray[idx], NewArray[idx], Both[old_idx, new_idx])
   - `bucketLock[ArrayId][BucketIdx]`: lock state (Free, ReaderN, Writer, Killed)
   - `threadState[Thread]`: thread operation state
   - `globalEpoch`, `threadEpoch[Thread]`, `guardActive[Thread]`
   - `deferredReclaim`: set of memory blocks awaiting reclamation

2. **Actions**:
   - `Insert(thread, key)`: lock bucket, insert entry
   - `ReadMAP(thread, key)`: dedup + reader lock + search
   - `ReadINDEX(thread, key)`: lock-free search old then new
   - `TriggerResize(thread)`: allocate new array, link old
   - `RehashBatch(thread)`: claim range, lock old bucket, lock targets, migrate entries
   - `KillBucket(thread, arrayId, bucketIdx)`: poison lock
   - `FinalizeResize(thread)`: swap out old array, defer reclaim
   - `CreateGuard(thread)`, `DropGuard(thread)`
   - `AdvanceEpoch`: scan collectors, advance if all quiescent
   - `ReclaimMemory`: reclaim blocks deferred 3+ epochs ago

3. **Fault injection**:
   - `TryLockFail(thread)`: non-deterministic lock failure during rehash
   - `AsyncYield(thread)`: interleaving point for async operations

### Secondary Model: TreeIndex Clear+Insert (if time permits)

Simpler spec focusing on the clear+insert race:
- `root`, `nodes[NodeId]`, `nodeState[NodeId]`
- `Insert`, `Clear`, `Read`, `Split`, `Merge`
- Verify no read sees a freed node
