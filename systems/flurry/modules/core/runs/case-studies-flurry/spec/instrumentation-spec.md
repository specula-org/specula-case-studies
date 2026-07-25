# Instrumentation Spec: flurry ConcurrentHashMap

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope (Category B — Timebox)

```json
{
  "event": "<action_name>",
  "thread": "<thread_id>",
  "start": <rdtsc_before>,
  "end": <rdtsc_after>,
  "state": { ... },
  "bin": <optional_bin_index>,
  "key": <optional_key>
}
```

### State Fields

| Implementation Field | TLA+ Variable | Capture Method |
|---|---|---|
| `self.count.load(SeqCst)` | `count` | `AtomicIsize::load` |
| `self.size_ctl.load(SeqCst)` | `sizeCtl` | `AtomicIsize::load` |
| `self.transfer_index.load(SeqCst)` | `transferIndex` | `AtomicIsize::load` |
| `table.len()` | `tableSize` | Table length |
| `next_table.len()` (if non-null) | `nextTableSize` | Next table length or 0 |
| `tree_bin.lock_state.load(SeqCst)` | `lockState[b]` | `AtomicI64::load` |

## Section 2: Action-to-Code Mapping

### Put Events

#### `put_empty_bin`
- **Spec action**: `PutEmptyBin(t, k)`
- **Code location**: `map.rs:1708` — `t.cas_bin(bini, bin, node, guard)` success path
- **Trigger**: AFTER successful CAS (inside `Ok(_old_null_ptr)` arm, map.rs:1709)
- **Fields**: `event`, `thread`, `start/end`, `key`, `bin` (= bini), `state.count`
- **Notes**: Capture `start` before the CAS, `end` after. The count is incremented at map.rs:1710, capture after `add_count`.

#### `put_node_bin`
- **Spec action**: `PutNodeBin(t, k)`
- **Code location**: `map.rs:1770-1854` — Node bin path with lock
- **Trigger**: AFTER `head_lock` acquired AND operation complete, BEFORE `drop(head_lock)` at map.rs:1854
- **Fields**: `event`, `thread`, `start/end`, `key`, `bin`, `state.count`
- **Notes**: `start` before `head.lock.lock()`, `end` after the insert/update loop completes. Count update happens after lock release (map.rs:1960), so capture count AFTER add_count for inserts.

#### `put_tree_bin`
- **Spec action**: `PutTreeBin(t, k)`
- **Code location**: `map.rs:1858-1931` — Tree bin path with lock
- **Trigger**: AFTER tree bin lock acquired AND operation complete, BEFORE `drop(head_lock)` at map.rs:1931
- **Fields**: `event`, `thread`, `start/end`, `key`, `bin`
- **Notes**: Similar to `put_node_bin` but inside Tree arm.

#### `put_help_transfer`
- **Spec action**: `PutHelpTransfer(t, k)`
- **Code location**: `map.rs:1750-1752` — Moved bin path
- **Trigger**: WHEN `BinEntry::Moved` is matched at map.rs:1750
- **Fields**: `event`, `thread`, `start/end`, `key`, `bin`
- **Notes**: Capture before `help_transfer` call.

### Treeify Events (Family 4)

#### `treeify_bin`
- **Spec action**: `TreeifyBin(t)`
- **Code location**: `map.rs:2724-2855` — `treeify_bin` function
- **Trigger**: At entry to function (map.rs:2724) for `start`, at exit for `end`
- **Fields**: `event`, `thread`, `start/end`, `bin` (= index parameter)
- **Notes**: Must capture which branch was taken (Node→convert, Moved→skip, Tree→skip). Add a `result` field: "converted", "moved", "already_tree".

### Resize Events (Family 1)

#### `init_resize`
- **Spec action**: `InitResize(t)`
- **Code location**: `map.rs:1199-1207` — `add_count` initiates resize via CAS on size_ctl
- **Trigger**: AFTER successful CAS `size_ctl.compare_exchange(sc, rs + 2, ...)` at map.rs:1201
- **Fields**: `event`, `thread`, `start/end`, `state.sizeCtl`, `state.tableSize`, `state.count`
- **Notes**: Also triggered from `try_presize` at map.rs:637. Instrument both paths.

#### `claim_range`
- **Spec action**: `ClaimRange(t)`
- **Code location**: `map.rs:704-710` — CAS on transfer_index
- **Trigger**: AFTER successful CAS `transfer_index.compare_exchange(next_index, next_bound, ...)` at map.rs:706
- **Fields**: `event`, `thread`, `start/end`, `state.transferIndex`, `bound` (= next_bound), `i` (= next_index)
- **Notes**: The `i = next_index` (map.rs:710) vs Java's `i = nextIndex - 1` is the off-by-one finding.

#### `claim_range_exhausted`
- **Spec action**: `ClaimRangeExhausted(t)`
- **Code location**: `map.rs:693-696` — transfer_index <= 0
- **Trigger**: WHEN `next_index <= 0` check succeeds at map.rs:693
- **Fields**: `event`, `thread`, `start/end`

#### `transfer_bin`
- **Spec action**: `TransferBin(t)`
- **Code location**: `map.rs:785-1084` — per-bin transfer under lock
- **Trigger**: AFTER each bin is processed (after `table.store_bin(i, moved)`)
  - Empty bin: map.rs:786-794 (after CAS to Moved)
  - Node bin: map.rs:908 (after `table.store_bin(i, ...)`)
  - Tree bin: map.rs:1063 (after `table.store_bin(i, ...)`)
- **Fields**: `event`, `thread`, `start/end`, `bin` (= i), `bin_type` ("empty"/"node"/"tree")

#### `transfer_finish_check`
- **Spec action**: `TransferFinishCheck(t)`
- **Code location**: `map.rs:755-772` — CAS size_ctl - 1
- **Trigger**: AFTER successful CAS `size_ctl.compare_exchange(sc, sc - 1, ...)` at map.rs:757
- **Fields**: `event`, `thread`, `start/end`, `state.sizeCtl`, `finishing` (boolean)

#### `finishing_sweep`
- **Spec action**: `FinishingSweep(t)`
- **Code location**: `map.rs:771` + loop re-entry — finishing thread re-checks bins
- **Trigger**: Each bin check during the finishing sweep (when `finishing == true`)
- **Fields**: `event`, `thread`, `start/end`, `bin` (= i)

#### `complete_resize`
- **Spec action**: `CompleteResize(t)`
- **Code location**: `map.rs:719-751` — finishing thread swaps tables
- **Trigger**: AFTER `self.table.swap(next_table_ptr, ...)` at map.rs:722
- **Fields**: `event`, `thread`, `start/end`, `state.tableSize`, `state.sizeCtl`

#### `help_transfer`
- **Spec action**: `HelpTransfer(t)`
- **Code location**: `map.rs:1122-1128` — CAS size_ctl + 1 to join
- **Trigger**: AFTER successful CAS `size_ctl.compare_exchange(sc, sc + 1, ...)` at map.rs:1124
- **Fields**: `event`, `thread`, `start/end`, `state.sizeCtl`

### Guard Events (Family 2)

#### `enter_guard`
- **Spec action**: `EnterGuard(t)`
- **Code location**: At call to `collector.enter()` or `map.pin()` / `map.guard()`
- **Trigger**: AFTER guard is created
- **Fields**: `event`, `thread`, `start/end`
- **Notes**: In flurry, guards are created via `HashMap::pin()` (returns `HashMapRef`) or `HashMap::guard()`. Instrument the collector's `enter()` method.

#### `exit_guard`
- **Spec action**: `ExitGuard(t)`
- **Code location**: At `Guard::drop()` or end of `HashMapRef` scope
- **Trigger**: BEFORE guard is dropped
- **Fields**: `event`, `thread`, `start/end`

### TreeBin Lock Events (Family 3)

#### `reader_acquire`
- **Spec action**: `ReaderAcquire(t, b)`
- **Code location**: `node.rs:460-463` — CAS(s, s + READER) success
- **Trigger**: AFTER successful CAS in `TreeBin::find`
- **Fields**: `event`, `thread`, `start/end`, `bin`, `state.lockState` (= s + READER)

#### `reader_release`
- **Spec action**: `ReaderRelease(t, b)`
- **Code location**: `node.rs:473` — `fetch_add(-READER)`
- **Trigger**: AFTER `fetch_add` returns
- **Fields**: `event`, `thread`, `start/end`, `bin`, `state.lockState` (= result of fetch_add - READER), `unparked` (boolean: was READER|WAITER?)

#### `writer_acquire_fast`
- **Spec action**: `WriterAcquireFast(t, b)`
- **Code location**: `node.rs:337-338` — CAS(0, WRITER) success
- **Trigger**: AFTER successful CAS in `lock_root`
- **Fields**: `event`, `thread`, `start/end`, `bin`

#### `writer_set_waiter`
- **Spec action**: `WriterSetWaiter(t, b)`
- **Code location**: `node.rs:393-401` — CAS(s, s | WAITER) success
- **Trigger**: AFTER successful CAS + waiter store + park
- **Fields**: `event`, `thread`, `start/end`, `bin`, `state.lockState`

#### `writer_acquire_contended`
- **Spec action**: `WriterAcquireContended(t, b)`
- **Code location**: `node.rs:359-363` — CAS(state, WRITER) success after unpark
- **Trigger**: AFTER successful CAS in contended_lock's first branch
- **Fields**: `event`, `thread`, `start/end`, `bin`

#### `writer_release`
- **Spec action**: `WriterRelease(t, b)`
- **Code location**: `node.rs:348` — `store(0, Release)`
- **Trigger**: AFTER the store
- **Fields**: `event`, `thread`, `start/end`, `bin`

## Section 3: Special Considerations

### Timebox Instrumentation (Category B)

All events must capture `[start, end]` timestamps using `rdtsc` or `std::time::Instant`. The preprocessor will compress timestamps to dense integers and produce per-thread arrays for the Trace spec.

```rust
let start = rdtsc();
// ... critical section ...
let end = rdtsc();
emit_trace_event(event, thread_id, start, end, state);
```

### Guard Lifecycle

- Guards in flurry are created implicitly via `HashMap::pin()` or explicitly via `HashMap::guard()`.
- The `seize` crate's `Collector::enter()` is the actual entry point.
- Guard drop happens when `Guard` goes out of scope or `HashMapRef` is dropped.
- Instrument at the `seize` boundary, not at the flurry API boundary.

### Treeify Race Window (Family 4)

- `treeify_bin` is called AFTER the bin lock is released (map.rs:1854 → 1942-1943).
- Between lock release and treeify, `transfer` can move the bin.
- Instrumentation must capture the re-check at map.rs:2740 to observe which branch is taken.

### Transfer Off-by-One (Family 1)

- After `ClaimRange`, the thread has `i = next_index` (map.rs:710).
- On first outer loop iteration, `i -= 1` (map.rs:686) gives `i = next_index - 1`.
- This differs from Java's `i = nextIndex - 1` at claim time.
- The net effect is the same (first bin processed is next_index - 1), but the finishing check at map.rs:716 (`i < 0 || i >= n`) fires on the FIRST iteration because `i = next_index >= n` (since next_index starts at n).
- Trace events should capture both `i` and `bound` to verify range coverage.

### Bin Lock Observability

- The `parking_lot::Mutex` lock in Node bins is not directly observable as an atomic.
- For trace purposes, emit lock acquire/release events around the critical section.
- The TreeBin `lock_state` (AtomicI64) IS directly observable.

### Count Accuracy

- `count` is updated via `fetch_add`/`fetch_sub` OUTSIDE the bin lock.
- Trace events may observe temporarily inconsistent counts.
- Strong validation of count should only be done after the atomic update completes.

### Preprocessor Requirements

The trace preprocessor must:
1. Parse per-thread NDJSON files (one file per thread, or filtered from a merged file)
2. Compress `start`/`end` timestamps to dense integers
3. Output a single JSON file with per-thread arrays for `JsonDeserialize`

Format:
```json
{
  "t1": [
    {"event": "enter_guard", "start": 1, "end": 2, "state": {}},
    {"event": "put_empty_bin", "start": 3, "end": 5, "key": 0, "bin": 0, "state": {"count": 1}}
  ],
  "t2": [
    {"event": "enter_guard", "start": 2, "end": 3, "state": {}},
    {"event": "put_node_bin", "start": 4, "end": 7, "key": 4, "bin": 0, "state": {"count": 2}}
  ]
}
```
