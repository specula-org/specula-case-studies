# Instrumentation Spec — `scc` (scalable-concurrent-containers)

Maps TLA+ spec actions in `base.tla` to source-code locations in
`artifact/scc/src/`. The harness produces a per-thread JSON trace consumed
by `Trace.tla` (Category B timebox pattern).

## Section 1 — Trace Event Schema

### Output file layout

Single JSON document, NDJSON-encoded (one record per line):

```json
{
  "threads": ["t1", "t2", "t3"],
  "events": {
    "t1": [ {start, end, event, ...}, ... ],
    "t2": [ ... ],
    "t3": [ ... ]
  }
}
```

`start` and `end` are `rdtsc()` values (compressed in a preprocessing step
to dense u32 indices — see `harness-generation` skill's
`concurrent-timebox-guide.md`).

### Common event envelope

| Field | Type | Description |
|-------|------|-------------|
| `start` | u32 | Compressed rdtsc at action begin (refine to the critical section) |
| `end` | u32 | Compressed rdtsc at action end |
| `event` | string | One of the spec action names (see Section 2) |
| `state` | object | Post-action snapshot of the spec variables this action modifies |

### Per-thread state snapshot fields

Captured in `state` after the action (subset varies per action — see Section 2):

| Field | Spec variable | Source-code accessor |
|-------|---------------|---------------------|
| `kind` | `pc[tid].kind` | derived from PC label |
| `step` | `pc[tid].step` | derived from PC label |
| `cachedArray` | `pc[tid].cachedArray` | thread-local `current_array` ptr → small u32 id |
| `bucketIdx` | `pc[tid].bucketIdx` | local `bucket_index` var |
| `currentArray` | `currentArray` | `bucket_array_var().load(Acquire, &guard)` → mapped to id |
| `occBit` | `occBit[<<aid, bidx>>]` | `metadata.occupied_bitmap.load(Relaxed) & (1<<bidx)` |
| `remBit` | `remBit[<<aid, bidx>>]` | `metadata.removed_bitmap.load(Relaxed) & (1<<bidx)` |
| `key` | `slotKey[<<aid, bidx>>]` | data block content at slot |
| `val` | `slotVal[<<aid, bidx>>]` | data block content at slot |

### Thread ID

Use a stable `usize` per worker (e.g., `tokio::task_id()` or a per-thread
counter assigned at `spawn`). Map to `t1`, `t2`, ... before serializing.

### Bucket-array ID mapping

Real `BucketArray` instances live at heap addresses. The harness maintains
an in-memory `HashMap<*const BucketArray<...>, u32>` and assigns the next
available `u32` on first observation. Reset on `dealloc_garbage`.

---

## Section 2 — Action-to-Code Mapping

One entry per spec action (`base.tla`). All locations refer to
`artifact/scc/src/`.

### WriterStart

- **Spec action**: `WriterStart(t, k, v)`
- **Code location**:
  - `hash_table.rs:336` — `let async_guard = AsyncGuard::default();` start of `writer_async`
  - `hash_table.rs:386` — `let guard = Guard::new();` start of `writer_sync`
- **Trigger**: AFTER the bucket-array-var Acquire-load completes
  (line 337 / 388) — *before* any potential rehash
- **Event name**: `"WriterStart"`
- **Fields**: `kind`, `step`, `cachedArray`, `key`, `val`
- **Notes**: This is the linearization point for the writer's "snapshot of
  bucket_array_var". Subsequent steps may see this snapshot become stale.

### WriterMaybeRehashOK / WriterMaybeRehashRetry

- **Spec actions**: `WriterMaybeRehashOK(t)`, `WriterMaybeRehashRetry(t)`
- **Code location**:
  - `hash_table.rs:343-354` — call to `incremental_rehash_async` +
    `dedup_bucket_async`; the `if !... { continue; }` retry branch
- **Trigger**: AFTER `dedup_bucket_async` returns; emit OK if it returned
  `true`, Retry if it returned `false`
- **Event name**: `"WriterMaybeRehashOK"` / `"WriterMaybeRehashRetry"`
- **Fields**: `kind`, `step`, `cachedArray`
- **Notes**: When `current_array.has_linked_array()` is false, the rehash
  is skipped entirely — emit `"WriterMaybeRehashOK"` directly without
  invoking dedup_bucket_async.

### WriterAcquireLock

- **Spec action**: `WriterAcquireLock(t)`
- **Code location**:
  - `hash_table.rs:370` — `if let Some(writer) = Writer::lock_async(bucket, &async_guard).await`
  - `hash_table.rs:403` — `if let Some(writer) = Writer::lock_sync(bucket)`
- **Trigger**: AFTER the lock-async future resolves and returns `Some(writer)`
- **Event name**: `"WriterAcquireLock"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`
- **Notes**: writer_async/optional_writer_async/reader_async DO NOT
  call `check_ref` here (Family 3 surface) — instrument the missing
  check by emitting an additional `"ForcedSkipCheckRef"` synthetic event
  immediately after this one IF the harness detects `cachedArray` no
  longer matches `bucket_array_var().load(Acquire, &guard)` at this point.

### WriterCommitInsert

- **Spec action**: `WriterCommitInsert(t)`
- **Code location**:
  - `hash_table/bucket.rs:438-460` — `insert_entry` (called from
    `Bucket::insert` at `bucket.rs:144-177` via `LockedBucket::insert`)
  - For HashMap: `hash_map.rs` insert/upsert paths via `LockedBucket`
  - For HashIndex: `hash_index.rs` insert paths via `LockedBucket`
- **Trigger**: AFTER `metadata.occupied_bitmap.store(.., Release)` at
  `bucket.rs:456-459` (Release for INDEX, Relaxed otherwise)
- **Event name**: `"WriterCommitInsert"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`,
  `key`, `val`, `state.occBit`, `state.remBit`
- **Notes**: The release-store on `occupied_bitmap` is the linearization
  point. If your harness uses a wrapper around `insert_entry`, emit the
  trace event from inside the wrapper after the bitmap store.

### WriterCommitMarkRemoved

- **Spec action**: `WriterCommitMarkRemoved(t)`
- **Code location**:
  - `hash_table/bucket.rs:220-249` — `mark_removed`
- **Trigger**: AFTER `metadata.removed_bitmap.store(..., Release)` at
  `bucket.rs:238` / `bucket.rs:248`
- **Event name**: `"WriterCommitMarkRemoved"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`,
  `key`, `state.occBit` (still TRUE), `state.remBit` (now TRUE)
- **Notes**: For non-INDEX types, `mark_removed` is not used — the
  remove path goes through `Bucket::remove` instead. The harness should
  emit the matching event for non-INDEX as well (mapped to `WriterCommitMarkRemoved`).

### WriterRelease

- **Spec action**: `WriterRelease(t)`
- **Code location**:
  - `hash_table.rs:1` — wherever `LockedBucket` is dropped (caller-site
    cleanup at end of public API method)
- **Trigger**: AFTER the `Writer`'s `Drop` impl releases the lock
- **Event name**: `"WriterRelease"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`
- **Notes**: A Writer drop is a single Release-store on the lock state.
  Instrument via `Drop` impl on `Writer` or wrapper.

### IterStart

- **Spec action**: `IterStart(t)`
- **Code location**:
  - `hash_index.rs:1170-1180` — `HashIndex::iter` constructor
  - `hash_index.rs:2104-2113` — first-call branch of `Iter::next`
    (lazy initialization)
- **Trigger**: AFTER the lazy-init branch of `Iter::next` sets
  `self.bucket_array.replace(array)`
- **Event name**: `"IterStart"`
- **Fields**: `kind`, `step`, `cachedArray` (id of the chosen array —
  old or current per `linked_array(guard).is_some()`)
- **Notes**: The `Guard` pin happens at `iter()` construction time;
  iter_start_live snapshot must be taken before any concurrent writer
  has had a chance to act after the iterator's guard pin.

### IterReadOccupied / IterReadEmpty

- **Spec action**: `IterReadOccupied(t)`, `IterReadEmpty(t)`
- **Code location**:
  - `hash_index.rs:2117-2123` — `if entry_ptr.move_to_next(bucket) { ... return Some((k,v)); }`
- **Trigger**: AFTER `entry_ptr.move_to_next` returns
- **Event name**: `"IterReadOccupied"` (return Some) / `"IterReadEmpty"`
  (return None — falls through to advance loop)
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`,
  for occupied: `key`, `val`
- **Notes**: `IterReadEmpty` does not advance the iterator's PC — it
  represents the body of the loop returning `None` from the bucket scan
  before advancing.

### IterAdvanceWithinBucket

- **Spec action**: `IterAdvanceWithinBucket(t)`
- **Code location**: `hash_index.rs:2159-2161` — `self.index += 1; self.bucket.replace(array.bucket(self.index));`
- **Trigger**: AFTER `self.index` is incremented
- **Event name**: `"IterAdvanceWithinBucket"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`
- **Notes**: Captures the post-increment `bucketIdx`.

### IterCrossArray

- **Spec action**: `IterCrossArray(t)`
- **Code location**: `hash_index.rs:2127-2155` — the index-end branch
  with all three sub-cases (current==cached → done, linked==cached →
  cross to current, otherwise → cross to old of current)
- **Trigger**: AFTER `self.bucket_array.replace(...)` (or break for the
  done case)
- **Event name**: `"IterCrossArray"`
- **Fields**: `kind`, `step`, `cachedArray` (post-cross), `bucketIdx` (= 0)
- **Notes**: Three sub-cases. They all collapse into the same trace
  event — disambiguation is via the `cachedArray` field.

### IterFinish

- **Spec action**: `IterFinish(t)`
- **Code location**: `hash_index.rs:2163` — `None` return after the
  break out of the outer `loop`
- **Trigger**: AFTER `Iter::next` returns `None` (the terminating call)
- **Event name**: `"IterFinish"`
- **Fields**: `kind`, `step`
- **Notes**: Only emit on the terminating `None` — not on per-bucket
  empty returns.

### TryResize

- **Spec action**: `TryResize(t)`
- **Code location**:
  - `hash_table.rs:1419-1428` — `try_resize` allocate-and-swap branch
- **Trigger**: AFTER `bucket_array_var.swap((Some(new), Tag::None), Release)`
  succeeds (line 1426)
- **Event name**: `"TryResize"`
- **Fields**: `state.currentArray` (new array id)
- **Notes**: The drop-table branch (line 1413-1418) is a different
  operation — emit a separate `"DropTable"` event (not modeled in current
  spec; the harness can elide).

### MigrateLockOldBucket

- **Spec action**: `MigrateLockOldBucket(t)`
- **Code location**:
  - `hash_table.rs:1177-1188` — incremental_rehash_async writer-lock-on-old
  - `hash_table.rs:828-829` — dedup_bucket_async writer-lock-on-old
- **Trigger**: AFTER the `Writer::lock_async(old_bucket, ..).await`
  returns `Some(writer)` (one of the call sites)
- **Event name**: `"MigrateLockOldBucket"`
- **Fields**: `kind`, `step`, `cachedArray` (current_array id),
  `bucketIdx` (old_index)
- **Notes**: The migrating record's `old_aid`, `target_aid`, `bidx` are
  derived from `cachedArray` and `bucketIdx`.

### MigratePublishNew

- **Spec action**: `MigratePublishNew(t)`
- **Code location**:
  - `hash_table/bucket.rs:341-346` — `extract_from`'s `self.insert(data_block, hash, entry)` call
  - `hash_table/bucket.rs:438-460` — `insert_entry` (target bucket Release)
- **Trigger**: AFTER `metadata.occupied_bitmap.store(.., Release)` on
  the NEW bucket's bitmap (line 456-459 with INDEX → Release)
- **Event name**: `"MigratePublishNew"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`
- **Notes**: This is half of the Family-2 split. The other half
  (`MigrateClearOld`) instruments the source-bucket clear.

### MigrateClearOld

- **Spec action**: `MigrateClearOld(t)`
- **Code location**:
  - `hash_table/bucket.rs:348-364` — `extract_from`'s store on the
    source bucket's `occupied_bitmap` with `mo` (Release for INDEX,
    Relaxed for HashMap)
- **Trigger**: AFTER `from_writer.metadata.occupied_bitmap.store(..., mo)`
- **Event name**: `"MigrateClearOld"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`
- **Notes**: For HashMap (non-INDEX), the ordering is `Relaxed` — that
  ordering downgrade was the historical (pre-9573fa1) bug for HashIndex.
  The harness should NOT inject the legacy ordering — the `MCMigrateClear-
  OldRelaxedLegacy` action is for model-checking only.

### MigrateEmpty

- **Spec action**: `MigrateEmpty(t)`
- **Code location**:
  - `hash_table.rs:899-905` — `relocate_bucket_async` `if old_writer.len() == 0 { ... old_writer.kill(); return; }`
  - `hash_table.rs:955-958` — sync analog
- **Trigger**: AFTER the kill call returns when `old_writer.len() == 0`
- **Event name**: `"MigrateEmpty"`
- **Fields**: `kind`, `step`, `cachedArray`, `bucketIdx`

### MigrateKillOldBucket

- **Spec action**: `MigrateKillOldBucket(t)`
- **Code location**: `hash_table.rs:903` / `hash_table.rs:942` — `old_writer.kill()`
- **Trigger**: AFTER `kill()` returns (lock transitions to terminal "killed")
- **Event name**: `"MigrateKillOldBucket"`
- **Fields**: `kind`, `step`

### EndIncrementalRehash

- **Spec action**: `EndIncrementalRehash(t)`
- **Code location**:
  - `hash_table.rs:1192-1200` — `end_incremental_rehash` returned drain-success path
  - `hash_table.rs:1244-1251` — sync analog
- **Trigger**: AFTER `linked_array_var.swap((None, Tag::None), Release)` (line 1195)
  AND `defer_reclaim` is called (line 1198)
- **Event name**: `"EndIncrementalRehash"`
- **Fields**: `state.currentArray`
- **Notes**: defer_reclaim → garbage_chain push (hash_index.rs:1374-1389).

### DeallocGarbage

- **Spec action**: `DeallocGarbage(t)`
- **Code location**: `hash_index.rs:1191-1218` — `dealloc_garbage`
- **Trigger**: AFTER the CAS on `garbage_chain` succeeds and the
  drop_in_place loop completes (line 1213)
- **Event name**: `"DeallocGarbage"`
- **Fields**: `kind`, `step`
- **Notes**: The harness must emit this event only on the path that
  actually freed memory — not the "set_has_garbage" defer branch
  (line 1216).

---

## Section 3 — Special Considerations

### State capture timing for Category B

Spec state captured in `state.*` is taken **outside** the `[start, end]`
interval — typically immediately AFTER the action's release/store
linearization point but BEFORE any subsequent atomic op that another
thread could observe. The interval `[start, end]` is the critical-section
window used by `ViablePIDs`.

### Bucket-array ID stability across runs

Heap addresses are not stable across runs. The harness maintains a
per-process `BucketArrayId` counter (`AtomicU32`). On first observation
of a `*const BucketArray` (via `bucket_array_var().load(...)`), assign
the next id. Re-observations of the same address return the same id.
On `dealloc_garbage`, the id is NOT recycled — to avoid spurious ABA
in trace replay.

### Threads not modeled

- `dedup_bucket_async` retry loops: emit `WriterMaybeRehashRetry`
  only once per outer continue. Inner loop iterations are silent.
- `try_enlarge` / `try_shrink`: emit a `TryResize` only if it actually
  triggers `try_resize` (line 1277, 1300).
- `for_each_*_async` `check_ref` failure path (line 546-549, 658-661):
  emit `CheckRefMismatchAndBail` for the writer/reader path; the harness
  may map to `IterFinish` for iterator-style scans if applicable.

### Bootstrap state

The trace should begin AFTER the HashIndex/HashMap/HashSet has been
constructed but BEFORE any worker thread spawns. Initial state:

```
arrayState[1] = "live"  (one bucket-array allocated by first writer)
currentArray = 1
all slots empty
all bucketLocks unlocked
globalEpoch = 1, garbageHead = NONE
```

Match `Init` in `base.tla`.

### Unmodeled paths

- `tree_index/*` — out of scope for this round (per modeling-brief.md)
- `HashCache` LRU — out of scope
- `try_resize` capacity-doubling-vs-shrink decision — abstracted
- `partial_hash_array` byte-tearing — formal-UB, not protocol level

### Trace size / preprocessing

A typical 5-second 4-thread workload generates ~1M events. The harness
must:

1. Per-thread ring buffer sized by `max_events_per_thread`
2. Flush-on-overflow strategy (drop with warning, not block)
3. Post-run preprocessing: timestamp compression (rdtsc → dense u32),
   bucket-array-id assignment, key/value canonicalization
4. Emit single JSON document with `threads` and `events` keys

For a 100-event-per-thread trace with 3 threads, the validation should
take seconds in TLC.

### Runtime hooks needed

The instrumentation injects code at the listed `file:line` locations.
For the user-facing API (`HashIndex::insert_sync`, `iter`, etc.), wrap
each at the public API boundary as well so events can be correlated to
user-visible operations.

---

## Section 4 — Field-Capture Summary (cross-reference for Trace.tla)

| Trace event | `cachedArray` | `bucketIdx` | `state.occBit` | `state.remBit` | `state.currentArray` | `key`, `val` |
|---|---|---|---|---|---|---|
| `WriterStart` | ✓ | — | — | — | — | ✓ |
| `WriterMaybeRehashOK` | ✓ | — | — | — | — | — |
| `WriterMaybeRehashRetry` | ✓ | — | — | — | — | — |
| `WriterAcquireLock` | ✓ | ✓ | — | — | — | — |
| `WriterCommitInsert` | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| `WriterCommitMarkRemoved` | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| `WriterRelease` | ✓ | ✓ | — | — | — | — |
| `IterStart` | ✓ | — | — | — | — | — |
| `IterReadOccupied` | ✓ | ✓ | — | — | — | ✓ |
| `IterReadEmpty` | ✓ | ✓ | — | — | — | — |
| `IterAdvanceWithinBucket` | ✓ | ✓ | — | — | — | — |
| `IterCrossArray` | ✓ | — | — | — | — | — |
| `IterFinish` | — | — | — | — | — | — |
| `TryResize` | — | — | — | — | ✓ | — |
| `MigrateLockOldBucket` | ✓ | ✓ | — | — | — | — |
| `MigratePublishNew` | ✓ | ✓ | — | — | — | — |
| `MigrateClearOld` | ✓ | ✓ | — | — | — | — |
| `MigrateEmpty` | ✓ | ✓ | — | — | — | — |
| `MigrateKillOldBucket` | — | — | — | — | — | — |
| `EndIncrementalRehash` | — | — | — | — | ✓ | — |
| `DeallocGarbage` | — | — | — | — | — | — |

`✓` = captured; `—` = not captured.
