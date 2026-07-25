# Instrumentation Spec: crossbeam-skiplist

Category B (concurrent/lock-free) — uses per-thread timebox traces with `[start, end]` intervals.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action name>",
  "tid": "<thread ID string>",
  "start": <rdtsc before critical section>,
  "end": <rdtsc after critical section>,
  "key": <key value>,
  "node": <node identity>,
  "state": { <post-state fields> }
}
```

### Thread ID Mapping

| Implementation | Trace ID |
|---|---|
| Thread 1 | `"t1"` |
| Thread 2 | `"t2"` |
| ... | `"tN"` |

Thread IDs assigned at first event emit. Use `thread_local!` counter or `std::thread::current().id()` mapped to sequential names.

### Node Identity Mapping

Nodes are identified by allocation order (sequential integer starting from 1). The harness maintains a `HashMap<*const Node, usize>` mapping raw pointers to sequential IDs. Head sentinel maps to `0`.

### State Fields

| Implementation Field | TLA+ Variable | Type | Notes |
|---|---|---|---|
| `refs_and_height >> HEIGHT_BITS` | `refCount[node]` | `Nat` | Reference count component |
| `tower[0].tag()` | `succMarked[node][0]` | `BOOLEAN` | Level-0 mark status |
| `hot_data.len` | `Cardinality(listMap)` | `Nat` | Logical list size |

## Section 2: Action-to-Code Mapping

### InsertBegin

| Field | Value |
|---|---|
| **Spec action** | `InsertBegin(t, k, h)` |
| **Code location** | `base.rs:1035-1065` (inside `insert_internal`, after `search_position` and node allocation) |
| **Trigger point** | After `Node::alloc` and `ptr::write` of key/value (base.rs:1058-1059), before level-0 CAS loop |
| **Event name** | `"InsertBegin"` |
| **Fields** | `key`, `node` (new node ID), `height`, `found` (existing node ID or "nil") |
| **State** | `nodeKey` (of new node) |
| **Notes** | Capture `search.found` before it might be invalidated. Height from `self.random_height()` (base.rs:1050). |

### InsertCAS

| Field | Value |
|---|---|
| **Spec action** | `InsertCAS(t)` |
| **Code location** | `base.rs:1076-1094` (level-0 `compare_exchange` result) |
| **Trigger point** | After CAS at base.rs:1078-1085, regardless of success/failure |
| **Event name** | `"InsertCAS"` |
| **Fields** | `key`, `node` (new node ID), `result` ("success" or "fail"), `oldNode` (marked old node ID or "nil") |
| **State** | `nodeKey`, `listSize` (hot_data.len after update) |
| **Notes** | On CAS success with replace: also capture whether `mark_tower` returned true for old node. The `start` timestamp should be taken before the CAS, `end` after (including the optional `mark_tower` call). |

### InsertBuildLevel

| Field | Value |
|---|---|
| **Spec action** | `InsertBuildLevel(t)` |
| **Code location** | `base.rs:1136-1218` (tower building loop, each level iteration) |
| **Trigger point** | After successful CAS at base.rs:1197-1199 that installs node at this level |
| **Event name** | `"InsertBuildLevel"` |
| **Fields** | `key`, `node`, `level` (the level just linked) |
| **State** | `level`, `refCount` (after fetch_add at base.rs:1192) |
| **Notes** | Only emit on CAS success. Failures (re-search) and duplicate-key skips are internal retries, not traced. If `succMarked[nn][lvl]` stops the build (base.rs:1149), do NOT emit — the build simply stops. |

### RemoveBegin

| Field | Value |
|---|---|
| **Spec action** | `RemoveBegin(t, k)` |
| **Code location** | `base.rs:1283-1294` (search + try_acquire) |
| **Trigger point** | After successful `try_acquire` at base.rs:1291-1294 |
| **Event name** | `"RemoveBegin"` |
| **Fields** | `key`, `node` (found node ID) |
| **State** | `refCount` (after try_increment) |
| **Notes** | Only emit if search finds the key AND try_acquire succeeds. If search returns None or try_acquire fails, the code retries internally — do not emit. |

### RemoveMarkTower

| Field | Value |
|---|---|
| **Spec action** | `RemoveMarkTower(t)` |
| **Code location** | `base.rs:1297` (call to `mark_tower`) and `base.rs:327-348` (mark_tower body) |
| **Trigger point** | After `mark_tower()` returns (base.rs:1297) |
| **Event name** | `"RemoveMarkTower"` |
| **Fields** | `key`, `node`, `won` (true if mark_tower returned true) |
| **State** | `removed` (succMarked[n][0] after mark) |
| **Notes** | This is the linearization point for remove. The `won` field determines whether the remove "succeeded" (returned Some). `start` before mark_tower call, `end` after. |

### RemoveUnlink

| Field | Value |
|---|---|
| **Spec action** | `RemoveUnlink(t)` |
| **Code location** | `base.rs:1304-1327` (unlink loop) |
| **Trigger point** | After the unlink loop completes (all levels attempted) |
| **Event name** | `"RemoveUnlink"` |
| **Fields** | `key`, `node`, `unlinkedLevels` (count of successful unlinks) |
| **State** | `refCount` (after all decrements) |
| **Notes** | The loop may break early if a CAS fails (base.rs:1325-1327). Capture `unlinkedLevels` as the number of successful CAS unlinks before the break. |

### Get

| Field | Value |
|---|---|
| **Spec action** | `Get(t, k)` |
| **Code location** | `base.rs` — various get/lower_bound entry points |
| **Trigger point** | After search completes and result is determined |
| **Event name** | `"Get"` |
| **Fields** | `key`, `found` (true/false) |
| **State** | (none — Get is a read-only action in the spec) |
| **Notes** | Get is modeled as atomic (no state change). Primary use: verify InsertGetConsistency invariant during trace replay. |

### ReleaseEntry

| Field | Value |
|---|---|
| **Spec action** | `ReleaseEntry(t)` |
| **Code location** | `base.rs:1654-1657` (`RefEntry::release`) and `base.rs:294-303` (`decrement`) |
| **Trigger point** | After `decrement` in release (base.rs:1656) |
| **Event name** | `"ReleaseEntry"` |
| **Fields** | `node` (the released node ID) |
| **State** | `refCount` (after decrement) |
| **Notes** | Also instrument `RefEntry::drop` / `release_with_pin` (base.rs:1661-1666). All paths that decrement refCount for an entry handle must emit this event. Critical for F1 (ref count lifecycle). |

### HelpUnlink (Silent — NOT instrumented)

`HelpUnlink` is a silent action in the trace spec. It fires as a side effect of `search_bound` / `search_position` / `next_node` when encountering marked nodes. Since it's internal bookkeeping, it is NOT instrumented.

The trace spec's `SilentHelpUnlink` allows TLC to fire HelpUnlink between any two traced events to maintain spec consistency.

## Section 3: Special Considerations

### Timebox Instrumentation

Use `rdtsc` (or `std::time::Instant`) for `start`/`end` timestamps:
- `start`: captured BEFORE the critical atomic operation (CAS, fetch_or)
- `end`: captured AFTER the operation completes and state is snapshotted
- Keep the interval tight: do NOT include retries or re-searches in the interval

```rust
let start = rdtsc();
// ... atomic operation ...
let end = rdtsc();
// ... capture state AFTER end ...
emit_event(Event { start, end, state, .. });
```

State is captured OUTSIDE the `[start, end]` interval (after `end`). This keeps intervals tight while allowing TLC to find a consistent interleaving.

### Node Identity Tracking

The harness must maintain a global `AtomicUsize` counter and a `HashMap<*const Node, usize>` (behind a `Mutex` or thread-local with merge):

```rust
static NODE_COUNTER: AtomicUsize = AtomicUsize::new(1); // 0 = Head

fn get_node_id(ptr: *const Node) -> usize {
    NODE_MAP.lock().entry(ptr).or_insert_with(|| {
        NODE_COUNTER.fetch_add(1, Ordering::Relaxed)
    })
}
```

### Concurrent Event Ordering

Since this is Category B, events from different threads may overlap in real time. The preprocessor converts raw per-thread NDJSON files into a single JSON with per-thread arrays and compressed timestamps.

Preprocessor steps:
1. Read all per-thread NDJSON files
2. Assign dense integer timestamps (compress `rdtsc` values to sequential ints preserving order)
3. Output: `{ "t1": [...], "t2": [...], "metadata": { ... } }`

### Bootstrap State

`TraceInit` matches the implementation's initial state:
- Empty skip list: Head with all successors = Nil, no marks
- All nodes in NodePool are free (not allocated)
- No thread holds any entry

### Epoch Pin and Guard

The crossbeam-epoch `Guard` / `pin()` mechanism is NOT modeled in the trace spec. The spec assumes all operations happen within a valid epoch pin. The harness must ensure tests pin before operations (which the `SkipMap` / `SkipList` API does internally).

### Insert Replace Window

During insert-replace, there is a window where both old and new nodes exist at level 0:
- After CAS: `pred → new → old → old.succ`
- After mark_tower(old): old is logically removed

The harness should emit `InsertCAS` with `oldNode` field to indicate the replace. The `mark_tower` call on the old node happens atomically within the InsertCAS event (not a separate event), matching the spec's atomic treatment.

### RefEntry Lifecycle (F1)

Every code path that increments/decrements `refCount` must be traced:
- `try_acquire` → captured in `RemoveBegin` and `InsertBegin`
- `decrement` → captured in `ReleaseEntry`, `RemoveUnlink`, and `HelpUnlink` (silent)
- `Clone for RefEntry` → must emit a separate event or be included in the containing operation

Missing any decrement path is exactly the bug pattern in Family 1.
