# Instrumentation Spec: crossbeam-deque

Maps TLA+ spec actions to source code instrumentation points for trace generation.

**Source file**: `crossbeam-deque/src/deque.rs`
**Trace format**: Per-thread NDJSON with timebox timestamps (Category B)
**Env var**: `CROSSBEAM_DEQUE_TRACE_DIR=path/` — directory for per-thread trace files

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "start": <rdtsc_before>,
  "end": <rdtsc_after>,
  "state": {
    "front": <isize>,
    "back": <isize>,
    "bufferID": <usize>
  },
  "thread": "<thread_id>",
  ... action-specific fields ...
}
```

### State Fields

| Implementation field | TLA+ variable | Capture method |
|---------------------|---------------|----------------|
| `inner.front.load(SeqCst)` | `front` | Atomic load after action |
| `inner.back.load(Relaxed)` | `back` | Atomic load after action |
| Buffer pointer address | `bufferID` | Hash of `inner.buffer.load()` pointer, mapped to sequential ID |

### Thread ID Mapping

| Thread type | Trace ID | TLA+ constant |
|-------------|----------|---------------|
| Worker | `"worker"` | `Worker` |
| Stealer threads | `"s1"`, `"s2"`, ... | `Stealer` elements |

Thread IDs are assigned by order of first encounter in each trace.

## Section 2: Action-to-Code Mapping

### Worker Actions

#### Push
- **Spec action**: `Push`
- **Code location**: `deque.rs:399-433`
- **Trigger point**: After `back.store(b+1)` at line 432
- **Event name**: `"Push"`
- **Fields**:
  - `state.front`: `inner.front.load(SeqCst)`
  - `state.back`: new back value (b+1)
  - `val`: the pushed value (for verification)
- **Notes**: Capture state AFTER the store to back, so the pushed element is visible.

#### ResizeGrow
- **Spec action**: `ResizeGrow`
- **Code location**: `deque.rs:291-322`
- **Trigger point**: After `buffer.swap()` at line 312, before `defer_unchecked` at line 315
- **Event name**: `"ResizeGrow"`
- **Fields**:
  - `state.front`: `inner.front.load(SeqCst)`
  - `state.back`: `inner.back.load(Relaxed)`
  - `oldBufferID`: hash of old buffer pointer
  - `newBufferID`: hash of new buffer pointer
- **Notes**: Must capture between swap and defer to see the new buffer as current but old buffer not yet retired.

#### LIFOPop
- **Spec action**: `LIFOPop`
- **Code location**: `deque.rs:490-544`
- **Trigger point**: After the pop decision point (line 506 for empty, line 531 for last, line 538 for normal)
- **Event name**: `"LIFOPop"`
- **Fields**:
  - `state.front`: current front
  - `state.back`: current back
  - `result`: `"success"` | `"empty"` | `"contention_lost"`
  - `val`: popped value (if success)
- **Notes**: Three code paths converge. Emit one event after the decision is made. For the CAS contention case (line 515-524), capture the CAS result.

#### FIFOPopAttempt
- **Spec action**: `FIFOPopAttempt`
- **Code location**: `deque.rs:465-486`
- **Trigger point**: After `fetch_add` at line 467
- **Event name**: `"FIFOPopAttempt"`
- **Fields**:
  - `state.front`: new front (f+1)
  - `state.back`: back (from pre-check)
  - `result`: `"success"` | `"rollback_needed"`
  - `val`: popped value (if success)
- **Notes**: Emit immediately after fetch_add. If rollback is needed, a separate FIFOPopRollback event follows.

#### FIFOPopRollback
- **Spec action**: `FIFOPopRollback`
- **Code location**: `deque.rs:471`
- **Trigger point**: After `front.store(f)` at line 471
- **Event name**: `"FIFOPopRollback"`
- **Fields**:
  - `state.front`: restored front value
  - `state.back`: back
- **Notes**: Only emitted when FIFOPopAttempt detected empty after fetch_add.

### Stealer Actions

#### StealBegin
- **Spec action**: `StealBegin`
- **Code location**: `deque.rs:641-665`
- **Trigger point**: After loading buffer at line 665 (or after empty check at line 661)
- **Event name**: `"StealBegin"`
- **Fields**:
  - `cachedFront`: front value loaded at line 643
  - `cachedBack`: back value loaded at line 657
  - `cachedBuf`: buffer pointer hash
  - `result`: `"proceed"` | `"empty"`
- **Notes**: If queue is empty, emit with result="empty" and no further steal events.

#### BatchStealBeginFIFO
- **Spec action**: `BatchStealBeginFIFO`
- **Code location**: `deque.rs:746-789`
- **Trigger point**: After loading buffer at line 789
- **Event name**: `"BatchStealBeginFIFO"`
- **Fields**:
  - `cachedFront`, `cachedBack`, `cachedBuf` (same as StealBegin)
  - `batchSize`: computed batch size (line 780)
  - `result`: `"proceed"` | `"empty"`

#### BatchStealBeginLIFO
- **Spec action**: `BatchStealBeginLIFO`
- **Code location**: `deque.rs:989-1034`
- **Trigger point**: After loading buffer at line 1031
- **Event name**: `"BatchStealBeginLIFO"`
- **Fields**:
  - `cachedFront`, `cachedBack`, `cachedBuf`
  - `batchSize`: computed batch size (line 1022)
  - `result`: `"proceed"` | `"empty"`

#### StealReadTask
- **Spec action**: `StealReadTask`
- **Code location**: `deque.rs:666` / `deque.rs:1034`
- **Trigger point**: After `buffer.deref().read(f)` at the respective line
- **Event name**: `"StealReadTask"`
- **Fields**:
  - `readVal`: the value read from the buffer (for verification)
  - `readFrom`: buffer pointer hash (verify it matches cached buffer)
- **Notes**: The speculative read is the key point for Family 1. Capture which buffer was actually read from.

#### StealCommit
- **Spec action**: `StealCommit`
- **Code location**: Three CAS sites:
  1. `deque.rs:670-679` (single steal)
  2. `deque.rs:816-829` (FIFO batch)
  3. `deque.rs:1083-1091` (LIFO batch first — NO re-check, MC-1)
- **Trigger point**: After the CAS (success or failure)
- **Event name**: `"StealCommit"`
- **Fields**:
  - `state.front`: front value after CAS
  - `site`: `"single"` | `"batchFIFO"` | `"batchLIFOFirst"`
  - `casResult`: `"success"` | `"fail_cas"` | `"fail_recheck"`
  - `stolenCount`: number of items stolen (1 for single, n for batch)
- **Notes**: Distinguish the three CAS sites via the `site` field. For MC-1 verification, log whether the buffer re-check was performed or not.

## Section 3: Special Considerations

### Timebox Instrumentation

All events must capture `start` and `end` timestamps using `rdtsc` (or equivalent high-resolution monotonic counter). Place `rdtsc` calls as tightly as possible around the critical section:

```rust
let start = rdtsc();
// ... critical section (CAS, fetch_add, etc.) ...
let end = rdtsc();
```

The preprocessor (`preprocess_trace.py`) will:
1. Merge per-thread files into a single JSON with per-thread arrays
2. Compress timestamps to dense integers
3. Sort events within each thread by start time

### Buffer Identity Tracking

The buffer pointer address (`*const Buffer<T>`) serves as the buffer identity. Map raw addresses to sequential IDs (1, 2, 3, ...) by order of first encounter. This enables TLA+ comparison without modeling raw pointers.

### Epoch Pin State

The `epoch::pin()` and guard drop are implicit in the steal functions. Do not instrument epoch directly — the Trace spec models epoch via the `pinned` variable, which is set/unset in the StealBegin/StealCommit action wrappers.

### Initial State

The trace preprocessor should emit a metadata header:
```json
{"flavor": "FIFO"}
```
or
```json
{"flavor": "LIFO"}
```
This is used by `TraceInit` to set the deque flavor.

### Concurrent Worker + Stealer Events

Worker events and stealer events happen on different threads and will overlap in time. The timebox mechanism (ViablePIDs) handles ordering automatically. No special synchronization is needed beyond correct timestamps.

### Self-Steal Guard

The `steal_batch_with_limit` and `steal_batch_with_limit_and_pop` methods check `Arc::ptr_eq(&self.inner, &dest.inner)` to detect self-steal (lines 748, 991). This is an optimization path, not a separate spec action. If instrumented tests use self-steal, it maps to the worker's pop action, not a steal.
