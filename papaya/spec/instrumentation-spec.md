# Instrumentation Spec: papaya Lock-Free Concurrent HashMap

## System Category

**Category B** (concurrent/lock-free) — use timebox trace approach with per-thread `[start, end]` intervals via `rdtsc` or `Instant`.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "tid": "<thread_id>",
  "start": <u64_timestamp>,
  "end": <u64_timestamp>,
  "key": "<key_debug>",
  "value": "<value_debug>",
  "table": <table_id>,
  "slot": <slot_index>,
  "tag": "<tag_bits>",
  "state": { ... }
}
```

### Timebox Instrumentation

Each event captures `start` before the critical operation and `end` after. The critical section should be as tight as possible around the atomic CAS/store that constitutes the linearization point.

```rust
let start = std::arch::x86_64::_rdtsc(); // or Instant::now()
// ... critical atomic operation ...
let end = std::arch::x86_64::_rdtsc();
```

### State Fields

Captured at every event (outside the `[start, end]` interval):

| Impl field | TLA+ variable | How to capture |
|---|---|---|
| `self.table.load(Acquire)` | `rootTable` | Table pointer identity (as integer ID) |
| `table.entry(i).load(Acquire)` | `tableEntry[t][s]` | Entry pointer + tag bits |
| `table.meta(i).load(Acquire)` | `tableMeta[t][s]` | Metadata byte |
| `table.state().next.load(Acquire)` | `nextTable[t]` | Next table pointer (as integer ID) |
| `table.state().status.load(Acquire)` | `resizeStatus[t]` | Status byte (0=PENDING, 1=ABORTED, 2=PROMOTED) |
| `table.state().copied.load(Acquire)` | `copiedCount[t]` | Copied counter |
| `table.state().claim.load(Acquire)` | `claimCount[t]` | Claim counter |

### Table ID Mapping

Real table pointers must be mapped to small integers (1, 2, 3, ...) in order of first encounter, similar to authority ID mapping in Substrate GRANDPA. Use a global `AtomicUsize` counter + `HashMap<*mut RawTable, usize>` protected by a mutex.

## Section 2: Action-to-Code Mapping

### 1. `insert_cas` — Phase 1 of two-phase insert

| Field | Value |
|---|---|
| **Spec action** | `InsertCASEntry(tid, k, v, t, s)` |
| **Code location** | `raw/mod.rs:894-907` (`insert_at`, CAS null → new_entry) |
| **Trigger point** | Around `guard.compare_exchange(entry, null, new_entry, Release, Acquire)` at line 894 |
| **Event name** | `insert_cas` |
| **Fields** | `key`, `value`, `table` (table ID), `slot` (probe index `i`), full state snapshot |
| **Notes** | Only emit on `Ok(_)` (successful CAS). The `start` timestamp goes before the CAS, `end` after. Metadata is NOT yet stored — this is the two-phase gap. |

### 2. `insert_meta` — Phase 2 of two-phase insert

| Field | Value |
|---|---|
| **Spec action** | `InsertStoreMeta(tid, t, s)` |
| **Code location** | `raw/mod.rs:903-904` (`meta_entry.store(meta, Release)`) |
| **Trigger point** | Around `meta_entry.store(meta, Ordering::Release)` at line 904 |
| **Event name** | `insert_meta` |
| **Fields** | `table`, `slot`, `meta` (h2 value) |
| **Notes** | Emitted immediately after the meta store. The gap between `insert_cas` and `insert_meta` is where MC-2 (two-phase insert race) can manifest. |

### 3. `insert_update` — Replace existing entry value

| Field | Value |
|---|---|
| **Spec action** | `InsertUpdate(tid, k, v, t, s)` |
| **Code location** | `raw/mod.rs:964-970` (`update_at`, CAS old → new) |
| **Trigger point** | Around `guard.compare_exchange_weak(entry, current, new_entry, Release, Acquire)` at line 964 |
| **Event name** | `insert_update` |
| **Fields** | `key`, `value`, `table`, `slot`, `old_value` (previous value for debugging) |
| **Notes** | Only emit on `Ok(_)` (successful CAS). Also covers `insert_slow` (line 605) which loops calling `update_at`. |

### 4. `remove` — CAS entry → TOMBSTONE

| Field | Value |
|---|---|
| **Spec action** | `Remove(tid, k, t, s)` |
| **Code location** | `raw/mod.rs:769-770` (via `update_at`, CAS entry → TOMBSTONE) |
| **Trigger point** | Around the `update_at` CAS in `remove_if` at line 769 |
| **Event name** | `remove` |
| **Fields** | `key`, `table`, `slot` |
| **Notes** | Only emit on `UpdateStatus::Replaced`. The meta tombstone store (line 782-786) and count decrement are not separately traced. |

### 5. `copy_mark_copying` — Set COPYING tag on source

| Field | Value |
|---|---|
| **Spec action** | `CopyMarkCopying(tid, srcT, s)` |
| **Code location** | `raw/mod.rs:2162-2163` (blocking) or `raw/mod.rs:2310-2311` (incremental) |
| **Trigger point** | Around `table.entry(i).fetch_or(Entry::COPYING, AcqRel)` |
| **Event name** | `copy_mark_copying` |
| **Fields** | `table` (source table ID), `slot`, `old_entry` (pre-fetch_or value) |
| **Notes** | Emit for both blocking and incremental paths. Skip if entry was already COPYING (lost the race). Also skip tombstone/null entries (emit nothing or a separate null-copy event). |

### 6. `copy_insert` — Insert copied entry into next table

| Field | Value |
|---|---|
| **Spec action** | `CopyInsertToNext(tid, srcT, srcS, dstT, dstS)` |
| **Code location** | `raw/mod.rs:2396-2407` (`insert_copy`, CAS null → entry in next table) |
| **Trigger point** | Around `guard.compare_exchange(entry, null, new_entry, Release, Acquire)` at line 2396 |
| **Event name** | `copy_insert` |
| **Fields** | `src_table`, `src_slot`, `dst_table`, `dst_slot`, `key` |
| **Notes** | Only emit on `Ok(_)`. The `insert_copy` method may retry in nested tables if the first is full — track which table the insert actually lands in. |

### 7. `copy_mark_copied` — Set COPIED tag on source

| Field | Value |
|---|---|
| **Spec action** | `CopyMarkCopied(tid, srcT, srcS)` |
| **Code location** | `raw/mod.rs:2351` (incremental: `entry.store(copied, SeqCst)`) |
| **Trigger point** | Around the `entry.store(copied, Ordering::SeqCst)` at line 2351 |
| **Event name** | `copy_mark_copied` |
| **Fields** | `table` (source), `slot` |
| **Notes** | Only in incremental mode. In blocking mode, entries go COPYING but not COPIED (the COPIED bit is unused in blocking mode per comment at line 146-147). |

### 8. `alloc_next` — Allocate next table for resize

| Field | Value |
|---|---|
| **Spec action** | `AllocNextTable(tid, t)` |
| **Code location** | `raw/mod.rs:1980-1981` (`state.next.store(next.raw, Release)`) |
| **Trigger point** | After `state.next.store(next.raw, Ordering::Release)` at line 1981 |
| **Event name** | `alloc_next` |
| **Fields** | `table` (source), `next_table` (new table ID), `capacity` |
| **Notes** | Only the thread that wins the allocation lock emits this event. |

### 9. `try_promote` — CAS root to next table

| Field | Value |
|---|---|
| **Spec action** | `TryPromote(tid, t)` |
| **Code location** | `raw/mod.rs:2475-2484` (CAS root + status store) |
| **Trigger point** | Around `self.table.compare_exchange(table.raw, next.raw, Release, Acquire)` at line 2476 |
| **Event name** | `try_promote` |
| **Fields** | `old_root` (table ID), `new_root` (next table ID), `copied_count` |
| **Notes** | Only emit on successful CAS. The PROMOTED status store (line 2484) and unpark (line 2501) happen immediately after. |

### 10. `abort_resize` — Abort current resize

| Field | Value |
|---|---|
| **Spec action** | `AbortResize(tid, srcT, abortedT)` |
| **Code location** | `raw/mod.rs:2067` (`status.store(ABORTED, SeqCst)`) |
| **Trigger point** | Around `next.state().status.store(State::ABORTED, Ordering::SeqCst)` at line 2067 |
| **Event name** | `abort_resize` |
| **Fields** | `src_table`, `aborted_table` |
| **Notes** | Rare event — only when next table is full during blocking copy. |

### 11. `init_table` — Lazy table initialization

| Field | Value |
|---|---|
| **Spec action** | `InitTable(tid)` |
| **Code location** | `raw/mod.rs:1867-1874` (CAS null → new table) |
| **Trigger point** | Around `self.table.compare_exchange(null, new.raw, Release, Acquire)` at line 1867 |
| **Event name** | `init_table` |
| **Fields** | `table` (new table ID), `capacity` |
| **Notes** | Only emit on successful CAS (winner of the init race). |

### 12. `park` — Thread parks for resize completion

| Field | Value |
|---|---|
| **Spec action** | `ParkThread(tid, t)` |
| **Code location** | `raw/mod.rs:2134-2136` (blocking) or `raw/mod.rs:2288-2290` (incremental) |
| **Trigger point** | Before `state.parker.park(...)` call |
| **Event name** | `park` |
| **Fields** | `table` (the next table whose parker is used) |
| **Notes** | The `end` timestamp should be set when `park()` returns (after unpark). |

## Section 3: Special Considerations

### 3.1 Table Pointer → ID Mapping

Real table pointers (`*mut RawTable<Entry<K,V>>`) must be mapped to stable integer IDs for the TLA+ spec. Use a global registry:

```rust
use std::sync::{Mutex, atomic::{AtomicUsize, Ordering}};
use std::collections::HashMap;

static TABLE_ID_COUNTER: AtomicUsize = AtomicUsize::new(1);
static TABLE_ID_MAP: Mutex<HashMap<usize, usize>> = Mutex::new(HashMap::new());

fn table_id(ptr: *mut impl Sized) -> usize {
    let addr = ptr as usize;
    let mut map = TABLE_ID_MAP.lock().unwrap();
    *map.entry(addr).or_insert_with(|| TABLE_ID_COUNTER.fetch_add(1, Ordering::Relaxed))
}
```

### 3.2 Slot Abstraction

Physical slot indices map directly to the `Slot` set in the spec. For trace validation, emit the raw probe index `i` as `slot`. The Trace.cfg will need `Slot` set large enough to cover the actual table size used in tests.

### 3.3 Two-Phase Insert Timing

The `insert_cas` and `insert_meta` events MUST be separate trace events with separate `[start, end]` intervals. This is critical for validating MC-2 (Family 1): the window where `get()` cannot find the entry because metadata hasn't been stored yet.

### 3.4 Blocking vs Incremental Mode

Some events only occur in specific resize modes:
- `copy_mark_copied`: Only in incremental mode (blocking mode doesn't use COPIED bit)
- `park`: Both modes, but different parker targets
- `abort_resize`: Only in blocking mode (incremental copy always succeeds, just may spill to nested table)

The trace harness should record `resize_mode` in a header event so the preprocessor can validate expectations.

### 3.5 Concurrent Thread Interleaving

All operations are lock-free (except `get_or_alloc_next` which uses a Mutex for allocation). Events from different threads will interleave at nanosecond granularity. The timebox approach handles this naturally — overlapping `[start, end]` intervals cause TLC to explore all viable orderings.

### 3.6 Key/Value Serialization

Keys and values must be serialized to strings matching the TLA+ constant names. For tests using integer keys, map them to `"k1"`, `"k2"`, etc. Use `Debug` or a custom formatter.

### 3.7 Guard Lifecycle

The epoch-based guard (`seize::Guard`) is entered before operations and exited after. Entry/exit of guards is NOT traced (too frequent, too low-level). The simplified epoch model in the spec handles this abstractly.

### 3.8 Preprocessor Requirements

The raw per-thread NDJSON traces must be preprocessed into the consolidated JSON format expected by `Trace.tla`:

```json
{
  "threads": {
    "t1": [ {event, start, end, ...}, ... ],
    "t2": [ {event, start, end, ...}, ... ]
  }
}
```

Timestamps should be compressed to dense integers (0, 1, 2, ...) preserving relative order. This reduces TLC search space.
