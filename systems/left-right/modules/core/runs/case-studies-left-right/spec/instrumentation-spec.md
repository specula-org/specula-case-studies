# Instrumentation Spec: left-right

Action-to-code mapping for generating trace harness patches.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "event": "<string>",
  "thread": "<string>",
  "start": <u64>,
  "end": <u64>,
  "state": { ... }
}
```

- `thread`: `"writer"` for writer, `"r1"`, `"r2"`, etc. for readers
- `start`/`end`: rdtsc timestamps bracketing the operation (timebox)
- `state`: post-operation snapshot (fields depend on event)

### State Fields — Reader Events

| Trace field    | Code accessor                      | TLA+ variable   |
|----------------|------------------------------------|-----------------|
| `epoch`        | `self.epoch.load(Ordering::Relaxed)`| `epoch[r]`     |
| `enters`       | `self.enters.get()`                | `enters[r]`    |

### State Fields — Writer Events

| Trace field    | Code accessor                        | TLA+ variable       |
|----------------|--------------------------------------|----------------------|
| `pointer`      | `"L"` or `"R"` based on ptr identity | `pointer`            |
| `copyL`        | abstract data counter for copy L     | `copyData["L"]`      |
| `copyR`        | abstract data counter for copy R     | `copyData["R"]`      |
| `first`        | `self.first`                         | `first`              |
| `second`       | `self.second`                        | `second`             |
| `totalOps`     | oplog length + applied count         | `totalOps`           |

## 2. Action-to-Code Mapping

### ReaderEnter

- **Spec action**: `TraceReaderEnter` (combined BumpEpoch + LoadPointer)
- **Code location**: `read.rs:120-194` (`ReadHandle::enter()`)
- **Trigger point**: After the `enter()` call completes (guard returned)
- **Event name**: `"ReaderEnter"`
- **Fields**: `epoch`, `enters`
- **Notes**:
  - Capture state OUTSIDE the `[start, end]` timebox
  - `start` = rdtsc before `self.epoch.fetch_add(1)` at `read.rs:169`
  - `end` = rdtsc after `self.inner.load()` at `read.rs:175`
  - For nested enters (`enters > 1`), emit `"ReaderNestedEnter"` instead

### ReaderNestedEnter

- **Spec action**: `ReaderNestedEnter`
- **Code location**: `read.rs:121-139` (enters != 0 branch)
- **Trigger point**: After the nested enter completes
- **Event name**: `"ReaderNestedEnter"`
- **Fields**: `epoch`, `enters`
- **Notes**:
  - `start`/`end` bracket the `self.inner.load(Ordering::Acquire)` at `read.rs:125`

### ReaderExit

- **Spec action**: `ReaderExit`
- **Code location**: `read/guard.rs:117-126` (`ReadGuard::drop()`)
- **Trigger point**: After the guard is dropped
- **Event name**: `"ReaderExit"`
- **Fields**: `epoch`, `enters`
- **Notes**:
  - `start` = rdtsc before `self.handle.enters.set(enters)` at `guard.rs:120`
  - `end` = rdtsc after `self.handle.epoch.fetch_add(1)` at `guard.rs:123` (if last guard)
  - If not last guard (enters > 0 after decrement), `end` = rdtsc after `enters.set()`

### ReaderRegister

- **Spec action**: `ReaderRegister`
- **Code location**: `read.rs:87-101` (`ReadHandle::new_with_arc()`)
- **Trigger point**: After the new handle is constructed
- **Event name**: `"ReaderRegister"`
- **Fields**: (none — registration is structural)
- **Notes**:
  - Called from `ReadHandle::clone()` (read.rs:74-78) and `ReadHandleFactory::handle()`
  - `start`/`end` bracket the `epochs.lock().unwrap().insert()` at `read.rs:91`

### ReaderDeregister

- **Spec action**: `ReaderDeregister`
- **Code location**: `read.rs:55-63` (`ReadHandle::drop()`)
- **Trigger point**: After the handle is dropped
- **Event name**: `"ReaderDeregister"`
- **Fields**: (none)
- **Notes**:
  - `start`/`end` bracket the `epochs.lock().unwrap().remove()` at `read.rs:59`

### WriterAppend

- **Spec action**: `WriterAppend`
- **Code location**: `write.rs:463-465` (`WriteHandle::append()`) and `write.rs:515-533` (`WriteHandle::extend()`)
- **Trigger point**: After the operation is appended/applied
- **Event name**: `"WriterAppend"`
- **Fields**: `copyL`, `copyR`, `first`, `totalOps`
- **Notes**:
  - When `first == true`, ops are applied directly to writerCopy (`write.rs:519-529`)
  - When `first == false`, ops go to the oplog (`write.rs:531`)
  - `start`/`end` bracket the `absorb_second` or `oplog.extend` call

### WriterPublish

- **Spec action**: `TraceWriterPublish` (combined lock+wait+apply+swap+fence+snapshot)
- **Code location**: `write.rs:343-357` (`WriteHandle::publish()`)
- **Trigger point**: After `publish()` returns
- **Event name**: `"WriterPublish"`
- **Fields**: `pointer`, `copyL`, `copyR`, `first`, `second`, `totalOps`
- **Notes**:
  - `start` = rdtsc before `self.epochs.lock()` at `write.rs:351`
  - `end` = rdtsc after the epoch snapshot loop at `write.rs:430-432`
  - Captures full cycle: lock → wait → apply → swap → fence → snapshot
  - `pointer` should be the post-swap value (which copy readers now see)

### WriterTryPublish

- **Spec action**: `TraceWriterTryPublishSucceed` or `TraceWriterTryPublishFail`
- **Code location**: `write.rs:309-335` (`WriteHandle::try_publish()`)
- **Trigger point**: After `try_publish()` returns
- **Event name**: `"WriterTryPublish"`
- **Fields**: `pointer`, `copyL`, `copyR`, `first`, `second`, `totalOps`, `success` (boolean)
- **Notes**:
  - `success = true` → TraceWriterTryPublishSucceed (publish happened)
  - `success = false` → TraceWriterTryPublishFail (no state change)
  - `start` = rdtsc before `self.epochs.lock()` at `write.rs:310`
  - `end` = rdtsc after return

### WriterTakeInner

- **Spec action**: `TraceWriterTakeInner`
- **Code location**: `write.rs:149-199` (`WriteHandle::take_inner()`)
- **Trigger point**: After `take_inner()` returns
- **Event name**: `"WriterTakeInner"`
- **Fields**: `pointer` (should be `"null"`)
- **Notes**:
  - `start` = rdtsc before the null swap at `write.rs:170`
  - `end` = rdtsc after the fence at `write.rs:178`
  - `take_inner()` calls `publish()` internally — those should NOT emit
    separate WriterPublish events (suppress instrumentation during take_inner)

## 3. Special Considerations

### Thread Identification

Each `ReadHandle` is `!Sync` (thread-local). Use `std::thread::current().id()` to generate stable thread identifiers. Map to string IDs ("r1", "r2", ...) in order of first encounter. The single writer thread is always "writer".

### Copy Identification

The two copies are identified by pointer address. Assign "L" and "R" at construction time (`lib.rs:271-280`). The `pointer` field in trace events reports which copy the `AtomicPtr` currently points to.

### Abstract Data Counter

The spec uses an abstract integer counter (`copyData`) rather than actual data values. The harness should maintain a shadow counter that tracks the number of operations applied to each copy:
- On `absorb_second`: increment the target copy's counter
- On `absorb_first`: increment the target copy's counter
- On `sync_with`: set the target copy's counter to the source's value

This requires wrapping the `Absorb` trait or adding a test-only counter.

### Timebox Precision

For lock-free operations (epoch bump, pointer load), use `rdtsc` for tight timeboxes. For mutex-guarded operations (publish, register), the timebox can be wider since the mutex serializes them.

### Suppressing Events During Internal Calls

`take_inner()` calls `publish()` internally. The harness must suppress `WriterPublish` events during `take_inner()` to avoid double-counting. Use a boolean flag in the writer state.

### Trace Preprocessing

Raw traces with per-thread NDJSON files must be preprocessed into the JSON format expected by `Trace.tla`:

```json
{
  "threads": {
    "writer": [
      {"event": "WriterAppend", "start": 1, "end": 2, "state": {...}},
      {"event": "WriterPublish", "start": 5, "end": 10, "state": {...}}
    ],
    "r1": [
      {"event": "ReaderEnter", "start": 3, "end": 4, "state": {...}},
      {"event": "ReaderExit", "start": 7, "end": 8, "state": {...}}
    ]
  }
}
```

Timestamps should be compressed to dense integers by the preprocessor.
