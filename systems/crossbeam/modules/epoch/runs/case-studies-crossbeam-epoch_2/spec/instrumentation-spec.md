# Instrumentation Spec: crossbeam-epoch

Maps TLA+ spec actions to source code locations for trace harness generation.

> **Category B (concurrent / lock-free)** — uses **per-thread timebox traces**.
> Each event records `start` / `end` timestamps (compressed `rdtsc` ticks) so
> `Trace.tla`'s `ViablePIDs` can compute the partial order across threads.

## Section 1: Trace Event Schema

### Event Envelope

Per-thread events are emitted to a per-thread NDJSON shard, then merged and
preprocessed into a JSON file `traces/trace.ndjson` of the form:

```json
{
  "threads": {
    "t1": [
      {"event": "PinIncGuardCount", "start": 100, "end": 102, "guardCountAfter": 1},
      ...
    ],
    "t2": [...]
  }
}
```

A pre-processing script (Python) maps `rdtsc` ticks to dense integer indices
to keep `ViablePIDs` cheap and renames the OS thread ID to a `Thread`-constant
string (`t1`, `t2`).

### Common Fields (every event)

| Field        | Type          | Description                                          |
|--------------|---------------|------------------------------------------------------|
| `event`      | string        | Spec action name (matches `MatchEvent` dispatch)     |
| `start`      | uint64        | Compressed start `rdtsc`                             |
| `end`        | uint64        | Compressed end `rdtsc`                               |
| `thread`     | string        | Thread ID matching the `Thread` constant            |

### Per-Action Fields

| Action                  | Field                  | Source                                            |
|-------------------------|------------------------|---------------------------------------------------|
| PinIncGuardCount        | `guardCountAfter`      | `local.guard_count.get()` AFTER the `+1`          |
| PinLoadGlobal           | `capturedGlobal`       | The loaded `global.epoch` value                   |
| PinPublish              | `localEpochAfter`      | `local.epoch.load(Relaxed)` AFTER store           |
| PinMaybeCollect         | `pinCountAfter`        | `local.pin_count.get()` AFTER `+1`                |
| UnpinDec                | `guardCountAfter`      | `local.guard_count.get()` AFTER `-1`              |
| UnpinPublish            | (none — implicit UNPINNED) | n/a                                           |
| Repin                   | `localEpochAfter`      | `local.epoch.load(Relaxed)` AFTER possible store  |
| TryAdvLoadGlobal        | `capturedGlobal`       | The loaded `global.epoch` value                   |
| TryAdvIter              | `observedThread`, `observedEpoch` | The local being inspected and its epoch |
| TryAdvFinishStore       | `globalEpochAfter`     | The new global epoch (successor)                  |
| Defer                   | `obj`, `bagLenAfter`   | Object pointer (abstract ID) + bag length         |
| PushBag                 | `sealEpoch`, `sealedBagsLenAfter` | `seal` value + queue length            |
| Flush                   | (none beyond common)   | n/a                                               |
| CollectScan             | `popped`               | bool — whether a bag was popped                   |
| BagDrop                 | `idx`, `obj`           | Index into bag, current obj being dropped         |
| PublishObject           | `obj`                  | Object whose pointer was published                |
| UnlinkObject            | `obj`                  | Object whose pointer was unlinked                 |
| ReadAndDeref            | `obj`                  | Object whose pointer was loaded + deref'd         |

## Section 2: Action-to-Code Mapping

### PinIncGuardCount

- **Spec action**: `PinIncGuardCount`
- **Code location**: `crossbeam-epoch/src/internal.rs:407`
- **Trigger**: AFTER `self.guard_count.set(guard_count.checked_add(1).unwrap())`
- **Event name**: `"PinIncGuardCount"`
- **Fields**: `guardCountAfter` = `self.guard_count.get()` post-update.
- **Notes**: This is the F1 gate. If `guardCountAfter == 1`, this is the
  outer pin and the next event will be `PinLoadGlobal`. Otherwise (nested),
  the next event from this thread will be a non-pin event.

### PinLoadGlobal

- **Spec action**: `PinLoadGlobal`
- **Code location**: `crossbeam-epoch/src/internal.rs:410`
- **Trigger**: AFTER `let global_epoch = self.global().epoch.load(Ordering::Relaxed);`
- **Event name**: `"PinLoadGlobal"`
- **Fields**: `capturedGlobal` = the loaded `global_epoch` value.

### PinPublish

- **Spec action**: `PinPublish`
- **Code locations**:
  - x86 path: `crossbeam-epoch/src/internal.rs:434-444` (compare_exchange-as-fence)
  - generic path: `crossbeam-epoch/src/internal.rs:446-447`
    (`store(new_epoch, Relaxed) + atomic::fence(SeqCst)`)
- **Trigger**: AFTER the store / cmpxchg + after the SeqCst fence.
- **Event name**: `"PinPublish"`
- **Fields**: `localEpochAfter` = `self.epoch.load(Relaxed)` (pinned-bit stripped)

### PinMaybeCollect

- **Spec action**: `PinMaybeCollect` (and on the cold path, the body of
  `Global::collect`).
- **Code location**: `crossbeam-epoch/src/internal.rs:451-458`
- **Trigger**: AFTER `pin_count.set(...)`; emit ONE event per pin even if
  collect is not actually called this iteration.
- **Event name**: `"PinMaybeCollect"`
- **Fields**: `pinCountAfter`, `triggeredCollect` (bool — `count.0 % PINNINGS_BETWEEN_COLLECT == 0`)

### UnpinDec

- **Spec action**: `UnpinDec`
- **Code location**: `crossbeam-epoch/src/internal.rs:467-468`
- **Trigger**: AFTER `self.guard_count.set(guard_count - 1)`
- **Event name**: `"UnpinDec"`
- **Fields**: `guardCountAfter`

### UnpinPublish

- **Spec action**: `UnpinPublish`
- **Code location**: `crossbeam-epoch/src/internal.rs:471`
- **Trigger**: AFTER `self.epoch.store(Epoch::starting(), Ordering::Release)`
- **Event name**: `"UnpinPublish"`
- **Fields**: none beyond common.
- **Notes**: Only fires when guardCount hit 0 (outermost unpin).

### Repin

- **Spec action**: `Repin`
- **Code location**: `crossbeam-epoch/src/internal.rs:483-502`
- **Trigger**: AFTER the (possible) `self.epoch.store(global_epoch, Release)`
  at line 495.
- **Event name**: `"Repin"`
- **Fields**: `localEpochAfter`, `wasNoOp` (true if guardCount > 1 or epochs already match)
- **Notes**: Repin uses Release-only store, NOT a SC fence — distinguishing
  from PinPublish is critical (Family 3).

### RepinAfterStart / RepinAfterFinish

- **Spec actions**: `RepinAfterStart` / `RepinAfterFinish`
- **Code location**: `crossbeam-epoch/src/guard.rs:366-393`
- **Trigger**:
  - Start event AFTER `local.acquire_handle(); local.unpin();` (line 387)
  - Finish event AFTER `mem::forget(local.pin()); release_handle(local);`
    inside the `Drop for ScopeGuard` impl (lines 374-378)
- **Event names**: `"RepinAfterStart"` / `"RepinAfterFinish"`
- **Fields**: `panicked` (bool — true if `f()` panicked)
- **Notes**: F4 — verify ScopeGuard re-pins even on panic. The harness
  should run `repin_after(|| panic!())` and confirm the Finish event
  fires (caught with `catch_unwind`).

### TryAdvLoadGlobal

- **Spec action**: `TryAdvLoadGlobal`
- **Code location**: `crossbeam-epoch/src/internal.rs:238`
- **Trigger**: AFTER `let global_epoch = self.epoch.load(Ordering::Relaxed)`
- **Event name**: `"TryAdvLoadGlobal"`
- **Fields**: `capturedGlobal`

### TryAdvIter (per local visited)

- **Spec action**: `TryAdvIter`
- **Code location**: `crossbeam-epoch/src/internal.rs:249-270` (loop body)
- **Trigger**: AFTER `local.epoch.load(Ordering::Relaxed)` at line 258 each iteration.
- **Event name**: `"TryAdvIter"`
- **Fields**: `observedThread`, `observedEpoch`, `pinned`, `aborted`
- **Notes**: When the iterator hits `IterError::Stalled` at line 251, emit
  `{"event": "TryAdvIter", "aborted": "stalled"}` so Trace.tla can fire
  `SilentTryAdvAbortStalled`.

### TryAdvFinishStore

- **Spec action**: `TryAdvFinishStore`
- **Code location**: `crossbeam-epoch/src/internal.rs:285-286`
- **Trigger**: AFTER `self.epoch.store(new_epoch, Ordering::Release)`
- **Event name**: `"TryAdvFinishStore"`
- **Fields**: `globalEpochAfter`

### Defer

- **Spec action**: `Defer`
- **Code locations**:
  - `crossbeam-epoch/src/internal.rs:382-389` (`Local::defer`)
  - `crossbeam-epoch/src/guard.rs:189-200` (`Guard::defer_unchecked` —
    user-facing entry; emits `UnprotectedDefer` if `local.is_null()`)
- **Trigger**: AFTER `bag.try_push(deferred)` succeeded (the loop body
  may push_bag first; emit a separate `PushBag` event then re-emit `Defer`).
- **Event name**: `"Defer"`
- **Fields**: `obj` (the defer'd address as an ID), `bagLenAfter`

### PushBag

- **Spec action**: `PushBag`
- **Code location**: `crossbeam-epoch/src/internal.rs:191-198`
- **Trigger**: AFTER `self.queue.push(bag.seal(epoch), guard)`
- **Event name**: `"PushBag"`
- **Fields**: `sealEpoch`, `sealedBagsLenAfter`

### Flush

- **Spec action**: `Flush`
- **Code location**: `crossbeam-epoch/src/internal.rs:391-399`
- **Trigger**: AFTER the call returns (i.e., after `collect()` finishes).
- **Event name**: `"Flush"`
- **Fields**: none beyond common.

### CollectScan / BagDrop

- **Spec actions**: `CollectScan`, `BagDrop`
- **Code locations**:
  - `crossbeam-epoch/src/internal.rs:217-225` (`Global::collect` loop body)
  - `crossbeam-epoch/src/internal.rs:125-134` (`Bag::drop`)
- **Trigger**:
  - `CollectScan` AFTER each `try_pop_if` returns (with `popped` flag).
  - `BagDrop` once per deferred-call invocation inside `Bag::drop`.
- **Event names**: `"CollectScan"` / `"BagDrop"`
- **Fields**: `popped` (bool); `BagDrop`: `idx`, `obj`

### Caller-driven actions: PublishObject / UnlinkObject / ReadAndDeref

- **Spec actions**: `PublishObject`, `UnlinkObject`, `ReadAndDeref`
- **Code location**: instrumented at the user's data-structure level.
  For the test harness, this is the queue / list / skiplist code that
  exercises crossbeam-epoch (e.g., `crossbeam-epoch/src/sync/queue.rs:120-143`
  for the historical Issue #238 site).
- **Trigger**:
  - `PublishObject` AFTER a successful CAS that links a node into the
    structure (e.g., `compare_exchange` in `push_internal`).
  - `UnlinkObject` AFTER a successful CAS that removes a node.
  - `ReadAndDeref` AFTER `*ptr` (or `as_ref()`) is performed.
- **Event names**: `"PublishObject"` / `"UnlinkObject"` / `"ReadAndDeref"`
- **Fields**: `obj` (object ID).
- **Notes**: These bridge the F2 retire contract to the spec. Without
  them, the spec can never validate that a defer'd object was actually
  unreachable when defer'd.

## Section 3: Special Considerations

### Per-Thread Buffering

Each thread writes to its own NDJSON shard (e.g., `traces/t1.ndjson`).
A merge step combines them into the per-thread JSON object the spec
loads. Per-thread shards keep instrumentation lock-free; the merge
runs offline.

### Timestamp Compression

`rdtsc` returns 64-bit values. The preprocessor:

1. Sorts all events globally by `(start, end)`.
2. Maps each unique `start` and `end` to a dense integer index.
3. Emits `start` / `end` as those indices.

This keeps `ViablePIDs` from blowing up TLC state hashes on huge
timestamps.

### Tight Intervals

Capture `start = rdtsc()` immediately *before* the critical atomic
operation and `end = rdtsc()` immediately *after*. For multi-step
actions (`Pin` decomposes into 4 steps), each step gets its own
event with its own tight interval, so `ViablePIDs` can interleave
each step independently.

### Bootstrap

The first event from each thread should be `PinIncGuardCount` (the
thread's first pin), preceded only by per-`Local` registration which
the trace can omit (the spec's `Init` already creates one Local per
`Thread` constant).

### F1 Reentrant Pin Detection

To exercise Family 1 specifically: the harness must register a
deferred fn whose body calls `pin()`. Suggested pattern:

```rust
let g = epoch::pin();
unsafe {
    g.defer_unchecked(|| {
        let inner = epoch::pin();    // F1 — must NOT advance local epoch
        drop(inner);
    });
}
drop(g);
g.flush();    // run collect → Bag::drop → deferred fn → re-entrant pin
```

Confirm in trace: between two `BagDrop` events (one for the deferred
fn slot), there should be a `PinIncGuardCount` event with
`guardCountAfter == 2` (re-entry), but NO `PinLoadGlobal` /
`PinPublish` for the same thread within that interval.

### F4 Repin-After-Panic

```rust
let mut g = epoch::pin();
let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
    g.repin_after(|| panic!("boom"))
}));
assert!(result.is_err());
// The trace must show RepinAfterStart followed by RepinAfterFinish
// (via ScopeGuard::drop), with localEpoch returned to a pinned value.
```

### F5 Stalled Iterator Reproduction

The harness should occasionally cause `try_advance` iteration to abort
mid-flight. The simplest way: have one thread sleep inside `Local::pin`'s
publish step (between `epoch.compare_exchange` and the subsequent
`fence`) so a concurrent `try_advance` observes `IterError::Stalled`.
Emit `TryAdvIter` with `aborted = "stalled"` from the iterating thread.

### F6 Slot Reuse Reproduction

After a `Local` finalizes, its slot may be allocated to a freshly
registered `Local`. The harness can force this by calling
`drop(LocalHandle { ... })` and immediately registering a new handle
through the same collector. Capture the new `Local`'s slot address
in `objectGen` (incrementing on each reuse).

### Object IDs

The spec uses a finite `Object` set; the implementation has arbitrary
pointer addresses. The harness assigns a small dense ID to each
publish-able object the test exercises (typically the queue/list nodes
used in the test). Map pointer → ID at instrumentation time.
