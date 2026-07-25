# Instrumentation Spec: scc HashMap

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON line (NDJSON) with these common fields:

```json
{
  "event": "<action_name>",
  "thread": "<thread_id>",
  "guard_active": true|false,
  "current_array": "<array_id>|null"
}
```

### State Fields

| Trace Field | TLA+ Variable | Source | Notes |
|------------|---------------|--------|-------|
| `thread` | Thread constant | `std::thread::current().id()` | Stringified thread ID |
| `guard_active` | `guardActive[t]` | Whether an EBR guard is held | Boolean |
| `current_array` | `currentArray` | `bucket_array_var().load()` pointer | Stringified pointer or generation counter |
| `key` | Key parameter | Hash or key value | Used for insert/remove/read events |
| `bucket` | Bucket parameter | `bucket_index(hash)` result | Bucket index |
| `old_array` | ArrayId parameter | Linked array pointer | For resize events |

### Message Fields (resize-specific)

| Trace Field | TLA+ Variable | When Captured |
|------------|---------------|---------------|
| `rehash_progress` | `rehashProgress[a]` | claim_rehash_range, relocate_bucket |
| `rehash_active` | `rehashActive[a]` | claim_rehash_range, end_rehash |
| `bucket_state` | `bucketState[a][b]` | relocate_bucket, dedup_bucket |

## Section 2: Action-to-Code Mapping

### EBR Guard Management

#### `create_guard`
- **Spec action**: `CreateGuard(t)`
- **Code location**: `sdd/src/collector.rs:126` (`new_guard`)
- **Trigger point**: After guard creation completes
- **Fields**: `thread`, `guard_active=true`
- **Notes**: The guard announces the current global epoch. Capture `guard.epoch()` if available.

#### `drop_guard`
- **Spec action**: `DropGuard(t)`
- **Code location**: `sdd/src/collector.rs:193` (`end_guard`), or `sdd/src/guard.rs` Drop impl
- **Trigger point**: Before guard is dropped
- **Fields**: `thread`, `guard_active=false`
- **Notes**: Must emit before drop, not after (guard is invalid after drop).

### Synchronous Read Path

#### `begin_sync_read`
- **Spec action**: `BeginSyncRead(t, k, b)`
- **Code location**: `hash_table.rs:306-310` (`reader_sync` — after Reader lock acquired)
- **Trigger point**: After `Reader::lock_sync()` returns `Some(reader)`
- **Fields**: `thread`, `key`, `bucket`, `guard_active=true`, `current_array`
- **Notes**: The dedup (lines 311-315) happens before lock. If modeling dedup separately, emit `dedup_bucket` first.

#### `access_data`
- **Spec action**: `AccessDataSync(t, k)`
- **Code location**: `hash_table.rs:320-326` (inside user callback `f`)
- **Trigger point**: At entry to the user-supplied closure/callback
- **Fields**: `thread`, `key`, `guard_active=true`
- **Notes**: This is inside the `f(&entry.0, &entry.1)` call. Instrument the closure wrapper.

#### `end_sync_read`
- **Spec action**: `EndSyncRead(t)`
- **Code location**: `hash_table.rs:326-328` (after callback returns, Reader dropped)
- **Trigger point**: After callback returns, before Reader drop
- **Fields**: `thread`, `guard_active=true`, `current_array`
- **Notes**: Reader lock is released on drop. Emit event while lock is still held.

### Synchronous Write Path

#### `insert`
- **Spec action**: `InsertSync(t, k, b)`
- **Code location**: `hash_map.rs` (insert method → `hash_table.rs:335` writer_sync)
- **Trigger point**: After entry is written to bucket (after `Writer` operations complete)
- **Fields**: `thread`, `key`, `bucket`, `guard_active=true`, `current_array`
- **Notes**: Multiple code paths: `insert`, `insert_if_not_present`, `upsert`. All go through writer_sync.

#### `remove`
- **Spec action**: `RemoveSync(t, k)`
- **Code location**: `hash_map.rs` (remove method → `hash_table.rs` writer_sync remove path)
- **Trigger point**: After entry is marked removed in bucket
- **Fields**: `thread`, `key`, `guard_active=true`, `current_array`

### Resize Protocol

#### `trigger_resize`
- **Spec action**: `TriggerResize(t)`
- **Code location**: `hash_table.rs:1307-1449` (`try_resize` — after new array allocated and swapped in)
- **Trigger point**: After `bucket_array_var().swap(new_array, ...)` succeeds
- **Fields**: `thread`, `current_array` (new array), `old_array` (previous array), `guard_active=true`
- **Notes**: CAS on `minimum_capacity_var` may fail — only emit on success.

#### `claim_rehash_range`
- **Spec action**: `ClaimRehashRange(t, oldArray)`
- **Code location**: `hash_table.rs:1098-1123` (`start_incremental_rehash`)
- **Trigger point**: After atomic increment of ref count succeeds
- **Fields**: `thread`, `old_array`, `rehash_progress`, `rehash_active`, `guard_active=true`
- **Notes**: Returns `None` if all buckets assigned — do not emit in that case.

#### `relocate_bucket`
- **Spec action**: `RelocateBucket(t, oldArray, b)`
- **Code location**: `hash_table.rs:1003-1094` (`relocate_bucket`)
- **Trigger point**: After all entries moved from old bucket to target bucket(s) and old bucket killed
- **Fields**: `thread`, `old_array`, `bucket`, `bucket_state="killed"`, `guard_active=true`
- **Notes**: Covers both sync (`relocate_bucket_sync`, line 948) and async variants.

#### `relocate_bucket_fail`
- **Spec action**: `RelocateBucketFail(t, oldArray, b)`
- **Code location**: `hash_table.rs:967-970` (try_lock failure path in `relocate_bucket_sync`)
- **Trigger point**: When `Writer::try_lock()` returns `Err(())`
- **Fields**: `thread`, `old_array`, `bucket`, `guard_active=true`
- **Notes**: Only for TRY_LOCK=true path. Entries remain in old bucket.

#### `end_rehash`
- **Spec action**: `EndRehash(t, oldArray)`
- **Code location**: `hash_table.rs:1127-1154` (`end_incremental_rehash`)
- **Trigger point**: After ref count decremented
- **Fields**: `thread`, `old_array`, `rehash_active`, `guard_active=true`, `current_array`

#### `finalize_resize`
- **Spec action**: `FinalizeResize(t, oldArray)`
- **Code location**: `hash_table.rs:1195-1200` (unlink old array + defer_reclaim)
- **Trigger point**: After `linked_array.swap(None, Release)` and before `defer_reclaim`
- **Fields**: `thread`, `old_array`, `current_array`, `guard_active=true`
- **Notes**: Only emitted by the thread whose `end_incremental_rehash` returns true (completed all buckets).

#### `dedup_bucket`
- **Spec action**: `DedupBucket(t, b)`
- **Code location**: `hash_table.rs:812-887` (`dedup_bucket_sync` / `dedup_bucket_async`)
- **Trigger point**: After entries migrated from old bucket and old bucket killed
- **Fields**: `thread`, `bucket`, `guard_active=true`
- **Notes**: Dedup is triggered implicitly during read/write. If not instrumenting separately, handle as a silent action in the trace spec.

### Async Read Path

#### `begin_async_read`
- **Spec action**: `BeginAsyncRead(t)`
- **Code location**: `hash_table.rs:270` (`reader_async` — `async_guard.load_unchecked(bucket_array)`)
- **Trigger point**: After array reference loaded
- **Fields**: `thread`, `current_array`, `guard_active=true`

#### `async_await`
- **Spec action**: `AsyncAwait(t)`
- **Code location**: `hash_table.rs:281` (any `.await` point in reader_async)
- **Trigger point**: Before await suspension (inside `lock_async_with` reset closure)
- **Fields**: `thread`, `guard_active=false`
- **Notes**: AsyncGuard::reset() is called. Instrument the reset closure.

#### `async_reacquire_guard`
- **Spec action**: `AsyncReacquireGuard(t)`
- **Code location**: `async_helper.rs:47` (`guard()` — lazy guard creation after resume)
- **Trigger point**: After guard re-created post-await
- **Fields**: `thread`, `guard_active=true`

#### `async_check_ref`
- **Spec action**: `AsyncCheckRef(t)`
- **Code location**: `async_helper.rs:72` (`check_ref`)
- **Trigger point**: After check_ref returns
- **Fields**: `thread`, `guard_active=true`, `current_array`, `ref_valid=true|false`
- **Notes**: If `ref_valid=false`, the async operation retries (loops back). The trace spec handles this via `AsyncCheckRef` updating `asyncStep` back to "idle".

#### `async_operate`
- **Spec action**: `AsyncOperate(t, k)`
- **Code location**: `hash_table.rs:288-295` (search and callback after ref validated)
- **Trigger point**: Before callback invocation
- **Fields**: `thread`, `key`, `guard_active=true`

#### `end_async_read`
- **Spec action**: `EndAsyncRead(t)`
- **Code location**: `hash_table.rs:296-300` (after callback, before function return)
- **Trigger point**: After callback returns
- **Fields**: `thread`, `guard_active=true`, `current_array`

### EBR Epoch Management

#### `advance_epoch`
- **Spec action**: `AdvanceEpoch`
- **Code location**: `sdd/src/collector.rs:410` (`scan` — after epoch advanced)
- **Trigger point**: After global epoch counter incremented
- **Fields**: `global_epoch` (new value)
- **Notes**: Global event, not per-thread. Rare — only when all threads quiescent.

#### `reclaim_array`
- **Spec action**: `ReclaimArray(a)`
- **Code location**: `hash_index.rs:1191-1218` (`dealloc_garbage`)
- **Trigger point**: After garbage array successfully deallocated
- **Fields**: `array` (the reclaimed array ID)
- **Notes**: Only for HashIndex. HashMap uses `sdd`'s automatic reclamation.

## Section 3: Special Considerations

### Array Identity

The spec uses integer array IDs (1, 2, 3, ...) but the implementation uses heap pointers. The instrumentation must maintain a mapping:
- Assign monotonically increasing IDs to each newly allocated `BucketArray`
- Use a thread-safe global counter (e.g., `AtomicUsize`)
- Store the ID in the `BucketArray` struct or a side-table
- Serialize the ID (not the pointer) in trace events

### Thread Identity

Use `std::thread::current().id()` for sync operations. For async operations, use the task ID or a custom identifier since async tasks may migrate between OS threads.

### Guard Lifecycle in Async

The `AsyncGuard` pattern complicates tracing:
- `reset()` drops the inner guard but doesn't create a new one immediately
- `guard()` lazily creates a new guard
- Between `reset()` and the next `guard()` call, `guard_active` is `false`
- The `lock_async_with(|| async_guard.reset())` pattern means reset happens during lock contention

### Dedup as Silent Action

In practice, `dedup_bucket` happens implicitly at the start of many read/write operations. Two options:
1. **Instrument explicitly**: Add trace events at each `dedup_bucket_sync/async` call site
2. **Handle as silent action**: Let the trace spec's `SilentDedupBucket` handle it

Option 1 is preferred for trace validation fidelity.

### Bucket Index Mapping

The implementation computes bucket index from hash: `hash >> hash_offset`. The trace must capture the computed bucket index, not the raw hash, to match the spec's `Bucket` set.

### Concurrent Events

Multiple threads emit events concurrently. The NDJSON file must use:
- A global sequence counter (AtomicUsize) to order events, OR
- Per-thread buffering with a merge step in preprocessing

A global counter is simpler and ensures total ordering.

### HashMap vs HashIndex

The spec primarily models HashMap (MAP type with reader-writer locks). HashIndex (INDEX type) uses optimistic lock-free reads. The instrumentation focuses on HashMap paths. To extend to HashIndex:
- Add events for optimistic read attempts and retries
- Track removed_bitmap epoch tagging (bucket.rs:231)
- Add `dealloc_garbage` events for the garbage chain

### Bootstrap State

The trace spec's `TraceInit` matches `Init`:
- One initial array (ID=1), all buckets active, no entries
- All threads idle, no guards held
- Global epoch = 0

If the system under test starts with pre-populated data, the harness must either:
1. Clear the HashMap before the test scenario, or
2. Adjust `TraceInit` to match the pre-populated state
