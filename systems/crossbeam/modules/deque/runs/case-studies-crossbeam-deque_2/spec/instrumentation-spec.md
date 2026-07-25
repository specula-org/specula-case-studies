# Instrumentation Spec: crossbeam-deque (run 2)

Maps TLA+ spec actions in `base.tla` / `Trace.tla` to source code instrumentation points for trace generation.

- **Source file**: `crossbeam-deque/src/deque.rs`
- **Trace format**: per-thread NDJSON (Category B timebox), preprocessed to JSON
- **Env var**: `CROSSBEAM_DEQUE_TRACE_DIR=path/` — directory for per-thread trace files

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "start": <rdtsc_before>,
  "end": <rdtsc_after>,
  "thread": "<thread_id>",
  "state": {
    "front": <isize>,
    "back":  <isize>,
    "bufferID": <usize>
  },
  ... action-specific fields ...
}
```

### State Field Mapping

| Implementation expression                | TLA+ variable | Capture method |
|------------------------------------------|---------------|----------------|
| `inner.front.load(SeqCst)`               | `front`       | atomic load after the action's last write |
| `inner.back.load(Relaxed)`               | `back`        | atomic load after the action's last write |
| `inner.buffer.load(Acquire, guard)` ptr  | `bufferID`    | hash of buffer pointer → sequential ID    |

Buffer pointers are mapped to dense IDs (1, 2, 3, ...) by order of first encounter, recorded in a per-process hashmap. The TLA+ spec assigns the same numbering convention.

### Thread ID Mapping

| Thread role        | Trace ID         | TLA+ constant       |
|--------------------|------------------|---------------------|
| Worker             | `"worker"`       | `Worker` (string)   |
| Stealer threads    | `"s1"`, `"s2"`,…  | elements of `Stealer` |

## Section 2: Action-to-Code Mapping

### Worker Actions

#### PushWriteSlot
- **Spec action**: `PushWriteSlot`
- **Code location**: `deque.rs:399-419`
- **Trigger point**: After `buffer.write(b, MaybeUninit::new(task))` at line 419
- **Event name**: `"PushWriteSlot"`
- **Fields**:
  - `state.front`, `state.back`, `state.bufferID`
  - `val`: the value written (for verification)
- **Notes**: This corresponds to phase 1 of the push protocol — the slot has been written but `back` has not yet been incremented. Stealers cannot yet see the new task.

#### PushStoreBack
- **Spec action**: `PushStoreBack`
- **Code location**: `deque.rs:422-432`
- **Trigger point**: After `back.store(b+1, store_order)` at line 432
- **Event name**: `"PushStoreBack"`
- **Fields**:
  - `state.front`, `state.back` (= b+1), `state.bufferID`
- **Notes**: Phase 2 — Release fence + back.store is the visibility handshake (Family B). Capture `state.back` AFTER the store so stealers see the increment.

#### LIFOPopDecrFence
- **Spec action**: `LIFOPopDecrFence`
- **Code location**: `deque.rs:489-498`
- **Trigger point**: After `back.store(b-1)` at line 493 (and conceptually after the SeqCst fence at line 495). One event per LIFO pop attempt.
- **Event name**: `"LIFOPopDecrFence"`
- **Fields**:
  - `state.back`: decremented value
- **Notes**: The `f = front.load(Relaxed)` at line 498 is part of the same atomic-step decision boundary in the spec. The implementation reads it under the same hardware fence; treat it as part of this event.

#### LIFOPopDecide
- **Spec action**: `LIFOPopDecide`
- **Code location**: `deque.rs:500-543`
- **Trigger point**: After whichever path is taken: line 506 (empty restore), line 524 (CAS attempt), line 538 (multi-task pop).
- **Event name**: `"LIFOPopDecide"`
- **Fields**:
  - `state.front`, `state.back`
  - `result`: `"empty"` | `"last_cas_success"` | `"last_cas_fail"` | `"multi_pop"`
  - `val`: popped value (when present)
- **Notes**: Three sub-paths converge here. Use `result` field to discriminate. For the CAS contention case (line 515-524), capture whether the CAS succeeded.

#### FIFOPopAttempt
- **Spec action**: `FIFOPopAttempt`
- **Code location**: `deque.rs:465-486`
- **Trigger point**: After `front.fetch_add(1, SeqCst)` at line 467.
- **Event name**: `"FIFOPopAttempt"`
- **Fields**:
  - `state.front`: new front value (old f + 1)
  - `state.back`
  - `result`: `"success"` | `"rollback_needed"`
  - `val`: popped value (when success)

#### FIFOPopRollback
- **Spec action**: `FIFOPopRollback`
- **Code location**: `deque.rs:471`
- **Trigger point**: After `front.store(f, Relaxed)` at line 471.
- **Event name**: `"FIFOPopRollback"`
- **Fields**: `state.front`, `state.back`

#### ResizeGrow
- **Spec action**: `ResizeGrow`
- **Code location**: `deque.rs:289-322`
- **Trigger point**: After `buffer.swap(...)` at line 312, before `defer_unchecked` at line 315.
- **Event name**: `"ResizeGrow"`
- **Fields**:
  - `state.bufferID`: new buffer ID
  - `oldBufferID`: old buffer ID (the retired one)
- **Notes**: Capture between swap and defer to observe new buffer current and old buffer not yet retired.

### Stealer Actions

The single-steal protocol is split per the spec. Most events fire on every steal call; capture `cachedFront`, `cachedBack`, `cachedBuf` per thread.

#### StealLoadFront_Single
- **Spec action**: `StealLoadFront_Single`
- **Code location**: `deque.rs:643`
- **Trigger point**: Immediately after `front.load(Acquire)` at line 643.
- **Event name**: `"StealLoadFront_Single"`
- **Fields**:
  - `cachedFront`: the loaded value

#### StealLoadFront_BatchFifo / StealLoadFront_BatchLifo
- **Spec action**: `StealLoadFront_BatchFifo` / `StealLoadFront_BatchLifo`
- **Code location**: FIFO `deque.rs:757`; LIFO `deque.rs:999`
- **Trigger point**: After `front.load(Acquire)`.
- **Event name**: `"StealLoadFront_BatchFifo"` / `"StealLoadFront_BatchLifo"`
- **Fields**:
  - `cachedFront`
  - `batchSize`: requested size (computed at deque.rs:780 / 1022)

#### StealPin
- **Spec action**: `StealPin`
- **Code location**: `deque.rs:650-654` (and analogues at 1006-1010, etc.)
- **Trigger point**: After `epoch::pin()` returns and any conditional `fence(SeqCst)` has executed.
- **Event name**: `"StealPin"`
- **Fields**:
  - `wasReentrant`: bool — `epoch::is_pinned()` at entry (whether SeqCst fence was issued manually)

#### StealLoadBack
- **Spec action**: `StealLoadBack`
- **Code location**: `deque.rs:657` (single), `1013` (batch LIFO), `771` (batch FIFO)
- **Trigger point**: After `back.load(Acquire)` and the empty-check.
- **Event name**: `"StealLoadBack"`
- **Fields**:
  - `cachedBack`: the loaded value
  - `result`: `"empty"` | `"proceed"`

#### StealLoadBuffer
- **Spec action**: `StealLoadBuffer`
- **Code location**: `deque.rs:665` (single), `789` (FIFO batch), `1031` (LIFO batch)
- **Trigger point**: After `buffer.load(Acquire, guard)`.
- **Event name**: `"StealLoadBuffer"`
- **Fields**:
  - `cachedBuf`: buffer pointer ID

#### StealReadSlot
- **Spec action**: `StealReadSlot`
- **Code location**: `deque.rs:666` (single), `1034` (batch LIFO), `1117` (loop body)
- **Trigger point**: After `buffer.deref().read(f)`.
- **Event name**: `"StealReadSlot"`
- **Fields**:
  - `readVal`: the value read (post `assume_init`)
  - `readFromBuf`: buffer pointer ID actually read from (must equal cachedBuf)

#### StealRecheckCAS
- **Spec action**: `StealRecheckCAS`
- **Code location**: Four CAS sites:
  1. Single steal: `deque.rs:670-679`
  2. FIFO batch: `deque.rs:1061-1075`
  3. LIFO batch first CAS: `deque.rs:1083-1091` (NO re-check — MC-1)
  4. LIFO batch loop CAS: `deque.rs:1121-1136`
- **Trigger point**: After the buffer recheck (or directly the CAS for site #3) and after the `compare_exchange` returns.
- **Event name**: `"StealRecheckCAS"`
- **Fields**:
  - `state.front`: front value after CAS (success: f+n; failure: unchanged)
  - `site`: `"single"` | `"batchFIFO"` | `"batchLIFOFirst"` | `"batchLIFOLoop"`
  - `recheckResult`: `"present_pass"` | `"present_fail"` | `"absent"` (site has no re-check)
  - `casResult`: `"success"` | `"fail_cas"` | `"skip_due_to_recheck"`
  - `stolenCount`: number of items committed by this CAS

#### StealLIFOBatchIter
- **Spec action**: `StealLIFOBatchIter`
- **Code location**: `deque.rs:1102-1146`
- **Trigger point**: One event per loop iteration, emitted after the iteration's CAS (success or break).
- **Event name**: `"StealLIFOBatchIter"`
- **Fields**:
  - `state.front`
  - `iter`: iteration index (0-based)
  - `iterResult`: `"empty_break"` | `"recheck_break"` | `"cas_fail_break"` | `"success"`
  - `tmpVal`: the value read this iteration (for verification)

### Caller-Harness Events (Family C)

#### StealerCloneAdv
- **Spec action**: `StealerCloneAdv`
- **Code location**: `deque.rs:1181-1188` (`Clone` impl on `Stealer`)
- **Trigger point**: After the Arc::clone returns (so the new stealer is ready).
- **Event name**: `"StealerCloneAdv"`
- **Fields**:
  - `newStealer`: thread ID assigned to the new stealer (e.g., `"s3"`)
- **Notes**: Only emitted if the test harness explicitly clones a stealer at runtime. Otherwise omit.

#### WorkerDropAdv
- **Spec action**: `WorkerDropAdv`
- **Code location**: Worker `Drop` impl (synthesized by Rust; deque.rs has no explicit Drop for Worker — it relies on `Inner` being epoch-managed).
- **Trigger point**: At the start of the Worker's destructor (or equivalently, when the Worker handle is dropped explicitly via `drop(worker)`).
- **Event name**: `"WorkerDropAdv"`
- **Fields**: none beyond the envelope.

## Section 3: Special Considerations

### Timebox Instrumentation

Each event must capture `start` and `end` timestamps from `rdtsc` (or `mach_absolute_time` on macOS / `clock_gettime(CLOCK_MONOTONIC_RAW)` elsewhere). Place the rdtsc reads as tightly as possible around the critical section:

```rust
let start = unsafe { core::arch::x86_64::_rdtsc() };
// ... critical section ...
let end = unsafe { core::arch::x86_64::_rdtsc() };
emit_trace_event(...);
```

The preprocessor (`preprocess_trace.py`) merges per-thread NDJSON into a single JSON, compresses timestamps to dense integers, and sorts events within each thread by start time.

### Buffer Identity Tracking

The buffer pointer address (`*const Buffer<T>`) serves as the buffer identity. Map raw addresses to sequential IDs (1, 2, 3, ...) by order of first encounter using a thread-safe hashmap (e.g., `Lazy<Mutex<HashMap<usize, usize>>>`).

### Epoch Pin / Drop

`epoch::pin()` and the implicit `Guard` drop are not separately instrumented as events — they are folded into `StealPin` (entry) and `StealRecheckCAS`/`StealLIFOBatchIter` (exit). The TLA+ spec models the same fold via the `pinned` flag.

### Initial-State Metadata

The trace preprocessor emits a top-level `flavor` field:
```json
{ "flavor": "FIFO", "worker": [...], "s1": [...], "s2": [...] }
```
`Trace.tla::TraceInit` reads this to set the `flavor` variable.

### Concurrent Worker + Stealer Events

Worker events and stealer events live on different threads and overlap in time. The timebox mechanism (`ViablePIDs` in Trace.tla) handles ordering automatically. No additional synchronization is needed beyond accurate per-thread timestamps.

### Self-Steal Guard

`steal_batch_with_limit` and `steal_batch_with_limit_and_pop` short-circuit when `Arc::ptr_eq(&self.inner, &dest.inner)` (deque.rs:748, 991). Real harnesses should not exercise the self-steal path; if they do, model it as a worker pop, not a steal.

### Family-Specific Capture Notes

- **Family A** (buffer-resize): always capture `bufferID` in `state` and `cachedBuf` in stealer events. If `cachedBuf != state.bufferID` at `StealRecheckCAS`, the re-check path is exercised.
- **Family B** (memory ordering): traces are unfaulted (no relaxBackStore). The Trace.tla wrappers use `PublishDeferredSlot` as a silent action so the spec's pushSlotVisible model converges without explicit instrumentation.
- **Family C** (caller misuse): only emit `StealerCloneAdv` and `WorkerDropAdv` when the harness exercises them; otherwise the trace is consistent with `activeStealers = Stealer` and `wAlive = TRUE`.
- **Family D** (CAS_weak): not emitted — Worker LIFO last-task CAS is strong; the spec's weak-CAS adversary is for hunting only.
- **Family F** (batch loop): emit one `StealLIFOBatchIter` per iteration; this is the key event for the per-iteration interleaving.

### What This Run Adds Over Prior crossbeam-deque Spec

| Family | Mechanism                                  | Status in run 2          |
|--------|--------------------------------------------|--------------------------|
| A      | Buffer-resize / generation race            | inherited; expanded      |
| B      | Memory-ordering bridges (NEW)              | added: `relaxBackStore`, `skipStealerFence`, `PushSlotVisible` model |
| C      | Adversarial caller (NEW)                   | added: `StealerCloneAdv`, `WorkerDropAdv`, `activeStealers` |
| D      | CAS-weak spurious failure (NEW)            | added: `weakLIFOLastCAS` adversary on Worker LIFO last CAS |
| F      | Per-iteration LIFO batch loop (NEW)        | added: `StealLIFOBatchIter` action with explicit iteration |
| E      | Injector block lifecycle                   | OUT OF SCOPE — separate Injector model required |
