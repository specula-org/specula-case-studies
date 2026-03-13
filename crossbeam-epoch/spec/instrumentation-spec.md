# Instrumentation Spec: crossbeam-epoch

Maps TLA+ spec actions to source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "thread": "<thread_id>",
  "globalEpoch": <int>,
  "localEpoch": <int>,
  "pinned": <bool>,
  "guardCount": <int>,
  ... (action-specific fields)
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Access |
|---------------------|---------------|--------|
| `Global.epoch.load(Relaxed)` | `globalEpoch` | `self.global().epoch.load(Relaxed)` |
| `Local.epoch.load(Relaxed)` | `localEpoch` | `self.epoch.load(Relaxed)` — extract value, strip pinned bit |
| `Local.guard_count.get() > 0` | `pinned` | `self.guard_count.get() > 0` |
| `Local.guard_count.get()` | `guardCount` | `self.guard_count.get()` |
| `Local.handle_count.get()` | `handleCount` | `self.handle_count.get()` |

### Queue State Fields (captured at queue events)

| Implementation Field | TLA+ Variable | Access |
|---------------------|---------------|--------|
| `Queue.head.load(Acquire, guard)` | `qHead` | Pointer address as string |
| `Queue.tail.load(Acquire, guard)` | `qTail` | Pointer address as string |

## 2. Action-to-Code Mapping

### ReadGlobalForPin

- **Spec action**: `ReadGlobalForPin(t)`
- **Code location**: `internal.rs:410`
- **Trigger point**: After `self.global().epoch.load(Ordering::Relaxed)` but before storing local epoch
- **Trace event**: `ReadGlobalForPin`
- **Fields**: `thread`, `globalEpoch` (the value just read), `localEpoch` (still old/unpinned), `pinned` (false), `guardCount` (0)
- **Notes**: Only fires when `guard_count == 0` (outermost pin). The instrumentation point must be between the epoch read (line 410) and the CAS/store (line 434-446). This captures the TOCTOU window.

### CompletePin

- **Spec action**: `CompletePin(t)`
- **Code location**: `internal.rs:434-447` (after CAS/store + fence)
- **Trigger point**: After the SeqCst CAS (x86) or `fence(SeqCst)` (non-x86)
- **Trace event**: `CompletePin`
- **Fields**: `thread`, `globalEpoch`, `localEpoch` (newly stored value), `pinned` (true), `guardCount` (1)
- **Notes**: On x86, instrument after line 440 (after `compare_exchange`). On non-x86, after line 447 (after `fence(SeqCst)`). Can use `cfg!` to select.

### NestedPin

- **Spec action**: `NestedPin(t)`
- **Code location**: `internal.rs:406-408`
- **Trigger point**: After `guard_count.set(guard_count + 1)` when `guard_count > 0`
- **Trace event**: `NestedPin`
- **Fields**: `thread`, `guardCount` (new value), `pinned` (true), `localEpoch`
- **Notes**: Fires in the `guard_count != 0` branch of `pin()`. No epoch update happens.

### Unpin

- **Spec action**: `Unpin(t)`
- **Code location**: `internal.rs:466-479`
- **Trigger point**: After `guard_count.set(guard_count - 1)` and (if last) after `epoch.store(Epoch::starting())`
- **Trace event**: `Unpin`
- **Fields**: `thread`, `guardCount` (new value), `pinned` (new value), `localEpoch` (0 if last, unchanged if not)
- **Notes**: Must capture state AFTER the unpin completes. If `guard_count` was 1, this is the last guard — the epoch store (line 471) and potential finalize check (line 473) have executed.

### ScanForAdvance

- **Spec action**: `ScanForAdvance(t)`
- **Code location**: `internal.rs:237-270`
- **Trigger point**: After the scan loop completes successfully (all locals at current epoch), before the store
- **Trace event**: `ScanForAdvance`
- **Fields**: `thread`, `globalEpoch` (the epoch read at line 238), `pinned` (true)
- **Notes**: Only emit if the scan succeeds (does NOT return early at line 255 or 263). If the scan fails (some local at wrong epoch), do not emit. The trace validator uses absence of this event to infer the scan failed.

### StoreAdvancedEpoch

- **Spec action**: `StoreAdvancedEpoch(t)`
- **Code location**: `internal.rs:285-286`
- **Trigger point**: After `self.epoch.store(new_epoch, Release)`
- **Trace event**: `StoreAdvancedEpoch`
- **Fields**: `thread`, `globalEpoch` (new value = old + 1)
- **Notes**: This store uses Release ordering. The new epoch is `global_epoch.successor()`. Emit after the store so the trace captures the new global epoch value.

### PushLocalBag

- **Spec action**: `PushLocalBag(t)`
- **Code location**: `internal.rs:191-198`
- **Trigger point**: After `self.queue.push(bag.seal(epoch), guard)` at line 197
- **Trace event**: `PushLocalBag`
- **Fields**: `thread`, `globalEpoch` (epoch used for sealing, read at line 196), `bagSize` (number of deferred items)
- **Notes**: The SeqCst fence at line 194 happens before the epoch read. Emit after the push.

### CollectExpiredBag

- **Spec action**: `CollectExpiredBag(t)`
- **Code location**: `internal.rs:217-224`
- **Trigger point**: After each successful `try_pop_if` that returns Some
- **Trace event**: `CollectExpiredBag`
- **Fields**: `thread`, `globalEpoch`, `bagEpoch` (epoch of the collected bag)
- **Notes**: May fire up to `COLLECT_STEPS` (8) times per `collect()` call. Each emission represents one bag entry being destroyed.

### QueueLink

- **Spec action**: `QueueLink(t, n)`
- **Code location**: `sync/queue.rs:84-88` (CAS `onto.next` from Nil to new node)
- **Trigger point**: After the successful CAS that links the new node into the queue
- **Trace event**: `QueueLink`
- **Fields**: `thread`, `node` (address of new node), `qHead`, `qTail`
- **Notes**: This is the first CAS of push_internal. The tail-advance CAS (line 91-93) is a separate action. The push loop (line 107) may retry multiple times; only emit on the successful link CAS. Tail is NOT updated in this event.

### QueueAdvanceTail

- **Spec action**: `QueueAdvanceTail(t)`
- **Code location**: `sync/queue.rs:79-81` (help path) and `91-93` (link path)
- **Trigger point**: After successful CAS that advances the tail pointer
- **Trace event**: `QueueAdvanceTail`
- **Fields**: `thread`, `qTail` (new tail value)
- **Notes**: Fires from either the "help" path (line 79-81, when a thread notices a lagging tail during push) or the "self-advance" path (line 91-93, after linking). May not fire if the CAS fails (another thread already advanced it). The trace validator includes a `SilentQueueAdvanceTail` for cases where this is not separately traced.

### QueuePop

- **Spec action**: `QueuePop(t)`
- **Code location**: `sync/queue.rs:120-143`
- **Trigger point**: After successful CAS at line 127 and tail advancement (lines 129-135) and defer_destroy (line 136)
- **Trace event**: `QueuePop`
- **Fields**: `thread`, `node` (address of popped/retired head node), `qHead` (new head), `qTail` (possibly advanced)
- **Notes**: The `node` field is the OLD head that was retired via `defer_destroy`. The pop may fail (CAS contention at line 127); only emit on success.

### AccessNode

- **Spec action**: `AccessNode(t, n)`
- **Code location**: Various (any `Shared::deref()`, `load()`, `as_ref()`)
- **Trigger point**: After loading a `Shared<Node>` via any `Atomic::load()`
- **Trace event**: `AccessNode`
- **Fields**: `thread`, `node` (address of accessed node)
- **Notes**: This is a ghost event — it instruments pointer loads for verification. Key locations:
  - `queue.rs:121` — `head.load(Acquire, guard)` (loading head in pop)
  - `queue.rs:123` — `h.next.load(Acquire, guard)` (following next pointer)
  - `queue.rs:76` — `o.next.load(Acquire, guard)` (checking tail.next in push)
  - `list.rs:243` — `c.as_ref().next.load(Acquire, self.guard)` (list iteration)

### ReleaseHandle

- **Spec action**: `ReleaseHandle(t)`
- **Code location**: `internal.rs:514-527`
- **Trigger point**: After `handle_count.set(handle_count - 1)` at line 519
- **Trace event**: `ReleaseHandle`
- **Fields**: `thread`, `handleCount` (new value), `guardCount`
- **Notes**: If this triggers finalization (guard_count == 0 && old handle_count == 1), the Finalize event will follow.

### Finalize

- **Spec action**: `Finalize(t)`
- **Code location**: `internal.rs:531-569`
- **Trigger point**: After the full finalize completes (after `drop(collector)` at line 567)
- **Trace event**: `Finalize`
- **Fields**: `thread`, `globalEpoch`
- **Notes**: Finalize internally pins (line 545), pushes bag (line 548), unpins, bumps handle count temporarily (line 540), marks entry as deleted (line 562), drops collector (line 567). Emit a single event after all of this completes. The intermediate pin/push are NOT separately traced.

## 3. Special Considerations

### Thread ID Mapping

- Use `std::thread::current().id()` for thread IDs. Format as a stable string (e.g., `format!("{:?}", id)`).
- The mapping from thread IDs to spec constants (`ThreadMapping`) must be generated per-trace from the first occurrence of each thread.

### Node Address Mapping

- Use raw pointer addresses (`format!("{:p}", ptr)`) for node IDs.
- The sentinel node's address should be captured at queue creation and mapped to `N0`/`Sentinel`.
- New nodes get mapped to `N1`, `N2`, etc. in order of first push.

### Conditional Compilation

- Instrumentation should be behind a feature flag (`cfg(feature = "tla-trace")`) or environment variable (`CROSSBEAM_TRACE_FILE`).
- On x86 vs non-x86: `CompletePin` instrumentation point differs (line 440 vs 447). Use `cfg!` to select.

### Concurrency and Ordering

- Events from different threads may interleave in the trace file. The trace validator handles this via non-deterministic action matching.
- Use a shared `AtomicU64` sequence counter for global event ordering, or `std::time::Instant` with nanosecond precision.
- Write events to a thread-local buffer, flush at unpin or finalize to reduce contention.

### What NOT to Trace

- `TryAdvanceFail` — failed advance attempts produce no visible state change.
- `CollectOnPin` — the counter-based collection trigger is abstracted; individual `CollectExpiredBag` events cover it.
- Internal `defer` calls within `push_bag` or `finalize` — these are part of the atomic effect of the parent event.
- `Repin` — modeled as Unpin + Pin in the spec.

### Bootstrap State

- `TraceInit` expects: `globalEpoch = 0`, all threads active with `handleCount = 1`, `guardCount = 0`, queue with just Sentinel.
- If the trace starts after some initialization, the trace must include initial state events or the `TraceInit` must be adjusted.

### Bag Sealing Epoch

- The epoch used for sealing (`PushLocalBag`) is read AFTER the SeqCst fence (line 194-196). If the global epoch advances between pin and push_bag, the bag gets the newer epoch. This is correct and reflected in the spec.
