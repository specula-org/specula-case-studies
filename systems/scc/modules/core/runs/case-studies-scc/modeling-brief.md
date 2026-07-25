# Modeling Brief: scc (scalable-concurrent-containers)

## 1. System Overview

- **System**: scc — high-performance concurrent data structures for Rust (HashMap, HashIndex, HashCache, TreeIndex)
- **Language**: Rust, ~21K LOC total (~11K LOC core logic in `src/`)
- **Protocol/Algorithm**: Lock-free/lock-based concurrent hash tables with incremental resizing, epoch-based reclamation (EBR)
- **Key architectural choices**:
  - Custom EBR (`sdd` crate) with 64 rotating epochs and 3-epoch grace period, not crossbeam-epoch
  - HashMap (`MAP` type) uses per-bucket reader-writer locks; HashIndex (`INDEX` type) uses lock-free optimistic reads
  - Resize via linked BucketArray chain: new array becomes current, old array linked and entries migrated incrementally
  - Bucket is a 32-slot fixed-size array with linked overflow buckets; metadata tracked via atomic bitmaps
  - Async operations use `AsyncGuard`/`SendableGuard` that must revalidate references after every await point
- **Concurrency model**: Multi-threaded with per-bucket locking (MAP/CACHE) or lock-free reads (INDEX). EBR guards are thread-local. Resize is cooperative — every thread that touches the hash table helps migrate entries.

## 2. Bug Families

### Family 1: Guard/Lock Lifetime vs. Data Access Window (CRITICAL)

**Mechanism**: Reader lock or EBR guard is dropped before the user's callback finishes accessing the protected data, causing use-after-free.

**Evidence**:
- Historical: Issue #176 — `HashMap::read` and `HashCache::read` dropped Reader lock before user callback completed. **Versions 2.0–2.3 yanked from crates.io.**
- Historical: Fix `ad75430` — kept Reader guard alive until after callback returns by threading `r` through the return tuple
- Historical: Issue #198 — `HashIndex::peek` allowed references to outlive the HashIndex; fix `576bf8c`, `b8a30ad`
- Code analysis: The pattern of creating a lock guard, extracting a reference, then dropping the guard before the reference is used is structurally fragile

**Affected code paths**:
- `hash_table.rs:306` `reader_sync` — Reader lock scope must cover user callback
- `hash_table.rs:266` `reader_async` — AsyncGuard validity across awaits
- `hash_index.rs` peek/iter — reference lifetimes must not outlive Guard
- `hash_cache.rs` read operations

**Suggested modeling approach**:
- Variables: `guardActive[Thread]`, `lockHeld[Thread, Bucket]`, `dataAccessWindow[Thread]`
- Actions: `AcquireGuard`, `AcquireLock`, `AccessData`, `ReleaseGuard`, `ReleaseLock`
- Key: model the ordering constraint — data access must be bracketed by guard/lock
- Split read into two actions: `BeginRead` (acquire lock, get reference) and `EndRead` (callback returns, release lock)

**Priority**: High
**Rationale**: Caused version yanking (production-severity). The pattern recurs across MAP, INDEX, and CACHE types. Model checking can systematically verify all read paths.

---

### Family 2: Async Reference Invalidation (ABA/Stale Reference) (HIGH)

**Mechanism**: The `bucket_array` pointer can change between await points in async operations. References obtained before an await become stale when a resize swaps in a new array, leading to operations on wrong/freed memory.

**Evidence**:
- Historical: Issue #190, fix `94303a4` — ABA in checking references in async code. Added `check_ref()` to validate bucket_array hasn't changed across awaits.
- Historical: Fix `c8bc10d` — data race when async reading: writers failing bucket relocation leave entries in both old and new arrays; reader must retry if array changed.
- Historical: Fix `bf6ebb4` — reference check must come BEFORE sampling decision (potential data race in async shrink).
- Historical: Fix `4939622` — robust reference checking across awaits; replaced `load` with `check_ref` in multiple async paths.
- Historical: Fix `b915090` — async iteration omitted entries; reference check needed AFTER lock is acquired, not before.

**Affected code paths**:
- `hash_table.rs` all async methods: `writer_async`, `reader_async`, `optional_writer_async`, `for_each_writer_async`, `for_each_reader_async`
- `async_helper.rs:72` `check_ref()` — the guard against ABA

**Suggested modeling approach**:
- Variables: `currentArray`, `threadSeenArray[Thread]`, `awaitPoint[Thread]`
- Actions: model async operations as split into steps with interleaving between them
- `BeginAsyncOp` (load array ref) → `AwaitLock` (thread yields, array may change) → `CheckRef` (validate ref) → `CompleteOp`
- Model `Resize` action that can swap the array between any two async steps

**Priority**: High
**Rationale**: 5 distinct bug fixes over a short period, all with the same mechanism. The async/await interleaving is naturally expressed as TLA+ action interleaving.

---

### Family 3: Incremental Resize Protocol Correctness (HIGH)

**Mechanism**: During resize, entries are incrementally migrated from old to new array. The multi-step protocol (start_rehash → lock old bucket → lock target buckets → extract entries → kill old bucket → reclaim old array) has many edge cases around partial migration, lock failure, and concurrent operations.

**Evidence**:
- Historical: Fix `34e5e55` — optimistic locking caused infinite loop during concurrent read + resize (missing `break` in reader path)
- Historical: Fix `9573fa1` — iterator reading outdated bucket state during rehash
- Historical: Fix `c8bc10d` — writers failing relocation leave entries in both old and new arrays
- Historical: CHANGELOG 3.0.5-3.0.6 — duplicate key issue if `insert_*` fails to allocate memory during resize
- Historical: Fix `8afa6b4` — improper OOM handling during resize left inconsistent state
- Historical: Fix `f6afe5c` — capacity management errors causing incorrect resize decisions
- Code analysis: `hash_table.rs:948-997` `relocate_bucket_sync` — locks old bucket, then locks N target buckets; if any target lock fails, previously locked targets must be unlocked (line 967-970); entry is in old bucket until extract_from moves it

**Affected code paths**:
- `hash_table.rs:1098` `start_incremental_rehash` — CAS on rehashing_metadata to claim bucket range
- `hash_table.rs:1127` `end_incremental_rehash` — decrement ref count, potentially swap out old array
- `hash_table.rs:1003` `relocate_bucket` — entry-by-entry migration with pre-allocation for shrink
- `hash_table.rs:306` `reader_sync` — must dedup then search current array only
- `hash_table.rs:224` `peek_entry` — must search old then new array, retry if array changed

**Suggested modeling approach**:
- Variables: `entryLocation[Key] ∈ {OldArray, NewArray, Both}`, `bucketState[ArrayId, BucketIdx] ∈ {Active, Locked, Killed}`, `rehashProgress`, `linkedArray`
- Actions: `TriggerResize` (allocate new array, set linkedArray), `ClaimRehashRange` (CAS on metadata), `LockOldBucket`, `LockTargetBuckets`, `ExtractEntry` (move from old to new), `KillBucket` (poison lock), `FinalizeResize` (swap out old array, defer reclaim)
- Model `try_lock` failure paths (return without completing migration)
- Key invariant: at every point, every key is findable by at least one reader

**Priority**: High
**Rationale**: Highest bug density. The protocol has inherent complexity from cooperative incremental migration. The entry-in-both-arrays state during migration is the key correctness concern.

---

### Family 4: TreeIndex Concurrent Structure Modification (MEDIUM)

**Mechanism**: The lock-free B+ tree uses optimistic locking for structure changes (node split, merge, clear). When `clear` races with `insert`, structural changes (new nodes from split) can reference cleared/freed nodes.

**Evidence**:
- Historical: 5+ data race fixes for #153 and related issues
- Historical: Fix `57af878` — clear+insert race: structural changes not rolled back when container cleared
- Historical: Fix `124cb66`, `027333f` — more clear+insert race variants
- Historical: Fix `b7c252c` — more data races in TreeIndex
- Historical: Fix `7a54a8c` — dependent load ordering (load → acquire)
- Historical: Fix `218ce4b` — Range intermittently misses first node
- Historical: Fix `17acb14` — assertion failure on OOM during root-splitting

**Affected code paths**:
- `tree_index/internal_node.rs:617` `split_node` — creates new nodes, installs them; must check if tree was cleared
- `tree_index/leaf_node.rs` `split`, `insert` — leaf splitting with concurrent readers
- `tree_index.rs` `clear` — marks root as retired, but concurrent inserts may still reference old structure

**Suggested modeling approach**:
- Variables: `root`, `nodeState[NodeId] ∈ {Active, Retired, Freed}`, `nodeChildren[NodeId]`
- Actions: `Insert`, `Split`, `Clear`, `Read`
- Focus on the split+clear interleaving
- Secondary priority — the tree structure is more complex to model than the hash table

**Priority**: Medium
**Rationale**: Many historical bugs, but the most dangerous ones (5 data races) have been fixed. The remaining risk is in split/merge edge cases during concurrent clear. Lower priority than hash table resize because the tree's lock-based split provides stronger atomicity guarantees.

---

### Family 5: EBR Epoch Advancement + Garbage Reclamation Timing (MEDIUM)

**Mechanism**: The custom EBR uses 3 garbage queues rotated with epoch advancement. If the epoch advances too aggressively (or the in_same_generation check has edge cases), garbage can be reclaimed while readers still hold references.

**Evidence**:
- Historical: Issue #200 — epoch acceleration in HashIndex caused entries to not be deallocated properly; fix `b52baaf` reverted the acceleration
- Historical: Fix `0074979` — entries not deallocated on drop
- Code analysis: `collector.rs:410` `scan()` — advances epoch only if all active threads are in the same epoch; uses SeqCst fence for global ordering
- Code analysis: `collector.rs:354` `epoch_updated()` — rotates garbage queues: next←prev, prev←current, current←∅; drops what was in next (2 epochs old)
- Code analysis: `epoch.rs:56` `in_same_generation()` — returns true if other is within 2 epochs

**Affected code paths**:
- `collector.rs:126` `new_guard` — announces epoch, SeqCst barrier
- `collector.rs:193` `end_guard` — may trigger scan
- `collector.rs:410` `scan` — chain lock, check all collectors, advance if all quiescent or same epoch

**Suggested modeling approach**:
- Variables: `globalEpoch`, `threadEpoch[Thread]`, `garbageQueue[Thread, QueueIdx]`, `retiredMemory[MemId] → epoch`
- Actions: `CreateGuard`, `DropGuard`, `RetireMemory`, `ScanAndAdvanceEpoch`, `ReclaimGarbage`
- Key invariant: `NoUAF` — memory retired in epoch E is not reclaimed until all threads have observed epoch E+3

**Priority**: Medium
**Rationale**: The EBR is fundamental to all data structures' safety. The epoch acceleration revert (#200) shows this area is fragile. However, the 64-epoch rotation and 3-epoch grace period are standard EBR design, reducing the likelihood of fundamental bugs.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| HashMap resize protocol | Family 3: highest bug density, most complex interaction | BucketArray chain, incremental rehash, entry migration actions |
| Concurrent read during resize | Families 1, 3: entry visibility during migration | Split reader into dedup-then-search; model entry location |
| Guard/lock scope vs data access | Family 1: caused version yanking | `guardActive`, `dataAccessWindow` variables; split read into acquire/access/release |
| Async operation interleaving | Family 2: 5 fixes for stale reference after await | Model async ops as multi-step with interleaving between steps |
| EBR epoch advancement | Family 5: foundational safety mechanism | 3-queue rotation, scan, global epoch, per-thread announced epoch |
| `try_lock` failure during rehash | Family 3: entries left in both arrays on failure | Model lock failure as non-deterministic; check entry still findable |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| TreeIndex B+ tree structure | Complex tree structure would dominate state space without targeting highest-priority bugs. Can be added as a separate spec later. |
| HashCache LRU eviction | LRU is a per-bucket doubly-linked list managed under lock — no concurrency bug risk beyond what hash table model covers. |
| 32-bit architecture issues | Fixed implementation bugs (wrong array sizes), not protocol-level issues. Test-verifiable. |
| Serde serialization | No concurrency component. |
| Async Future size optimization (#194) | Performance/memory issue, not correctness. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Resize protocol | `entryLocation[Key]`, `bucketState[Array,Idx]`, `linkedArray`, `rehashProgress` | Model entry migration during resize | Family 3 |
| Guard/lock scope | `guardActive[Thread]`, `lockHeld[Thread,Bucket]`, `accessingData[Thread]` | Detect UAF from premature guard/lock release | Family 1 |
| Async interleaving | `asyncStep[Thread]`, `seenArray[Thread]` | Model stale reference after await | Family 2 |
| EBR reclamation | `globalEpoch`, `threadEpoch[Thread]`, `retiredAt[MemoryId]`, `reclaimed[MemoryId]` | Verify no premature reclamation | Family 5 |
| Lock failure | `lockResult ∈ {Acquired, Failed}` | Model try_lock failure leaving partial state | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| EntryReachability | Safety | Every inserted, non-removed key is findable by at least one reader at every state | Family 3 |
| NoUseAfterFree | Safety | No thread accesses memory (entry data, bucket, array) after it has been reclaimed by EBR | Families 1, 5 |
| NoLostEntryDuringResize | Safety | During resize, no entry disappears from both old and new arrays simultaneously | Family 3 |
| NoDeadlock | Safety | No cycle in lock acquisition order (old bucket → target buckets always in index order) | Family 3 |
| GuardBracketsAccess | Safety | Data access occurs only while guard/lock is held: `accessingData[t] => guardActive[t] ∧ lockHeld[t, bucket]` | Family 1 |
| AsyncRefValidity | Safety | After an await point, the thread's seen array reference matches the current array | Family 2 |
| EpochSafety | Safety | Memory retired in epoch E is not reclaimed until globalEpoch ≥ E + 3 | Family 5 |
| EntryUniqueness | Safety | No two slots in the hash table contain the same key | Family 3 |
| RehashCompleteness | Liveness | Eventually, all entries are migrated to the new array and old array is reclaimed | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | try_lock failure during rehash leaves entry in both old and new arrays; concurrent reader doing dedup on same range → entry temporarily unfindable | EntryReachability | 3 |
| MC-2 | Resize triggered during reader_sync after dedup but before Reader lock → reader loops, loads new array, dedup again → entry already migrated, found correctly (verify this is always correct) | EntryReachability | 3 |
| MC-3 | Async read across await point: array changes between lock acquisition and data access → stale bucket reference | AsyncRefValidity, NoUseAfterFree | 2 |
| MC-4 | Two threads concurrently doing incremental_rehash_sync on overlapping bucket ranges → one thread kills bucket while other still migrating | EntryReachability | 3 |
| MC-5 | Reader drops guard before callback returns (the yanked-version pattern) → EBR advances and reclaims entry | NoUseAfterFree, GuardBracketsAccess | 1 |
| MC-6 | HashIndex optimistic read during entry migration: removed_bitmap updated but entry not yet in new array | EntryReachability | 3, 5 |
| MC-7 | EBR epoch advances when only one thread is active but has garbage → premature reclamation of memory another thread loaded a pointer to | EpochSafety | 5 |
| MC-8 | Garbage chain linkage race: `defer_reclaim` swaps chain head then links prev_head non-atomically (`hash_index.rs:1381-1388`). Concurrent `dealloc_garbage` between steps loses prev_head → memory leak | GarbageChainIntegrity | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | OOM during resize: insert fails to allocate LinkedBucket → duplicate key | Fault injection test with custom allocator that fails after N allocations |
| TV-2 | Iterator skipping entries during concurrent resize | Stress test: concurrent insert/remove + iterator, verify all expected entries seen |
| TV-3 | HashIndex entry deallocation on drop after epoch acceleration | Unit test: create HashIndex, insert many entries, accelerate epoch, drop, verify all entries dropped |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `partial_hash_array` is `UnsafeCell<u8>` (non-atomic). For INDEX type, concurrent readers access it without lock. Technically a data race under C++ memory model, though functionally benign due to bitmap ordering. | Evaluate whether `AtomicU8` would be more correct |
| CR-2 | `bucket.rs:171` — `self.len.store(self.len.load(Relaxed) + 1, Relaxed)` is a non-atomic increment under lock, safe only because Writer lock is exclusive. Verify no path increments without lock. | Audit all `len` modifications |
| CR-3 | `hash_table.rs:975` — `Writer::lock_sync(current_array.bucket(i)).unwrap_unchecked()` — assumes lock always succeeds for non-killed buckets in the new array. Could panic if bucket was killed by concurrent resize. | Verify kill ordering prevents this |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/scc/analysis-report.md`
- **Key source files**:
  - `artifact/scc/src/hash_table.rs` (1684 lines — resize protocol, read/write paths)
  - `artifact/scc/src/hash_table/bucket.rs` (1565 lines — bucket locking, entry storage, optimistic reads)
  - `artifact/scc/src/hash_table/bucket_array.rs` (252 lines — array allocation, linked array chain)
  - `artifact/scc/src/hash_map.rs` (2383 lines — HashMap API)
  - `artifact/scc/src/hash_index.rs` (2181 lines — HashIndex with lock-free reads)
  - `artifact/scc/src/hash_cache.rs` (1835 lines — HashCache with LRU)
  - `artifact/scc/src/tree_index/` (4505 lines — B+ tree)
- **EBR source** (vendored):
  - `/tmp/scc-vendor/sdd/src/collector.rs` (639 lines — EBR collector with 3-queue rotation)
  - `/tmp/scc-vendor/sdd/src/guard.rs` (197 lines — Guard API)
  - `/tmp/scc-vendor/sdd/src/epoch.rs` (135 lines — 64-epoch rotation)
- **GitHub issues**: #176 (yanked UAF), #190 (ABA async), #198 (HashIndex lifetime), #200 (epoch acceleration), #153 (TreeIndex races), #194 (future size)
- **GitHub repo**: `wvwwvwwv/scalable-concurrent-containers`
