# Instrumentation Guide: crossbeam-epoch

## Overview

This harness instruments [crossbeam-epoch](https://github.com/crossbeam-rs/crossbeam/tree/master/crossbeam-epoch), an epoch-based memory reclamation (EBR) library for lock-free data structures in Rust. The instrumentation emits NDJSON trace events that are validated against a TLA+ specification (`spec/Trace.tla`).

## Architecture

```
harness/
  src/
    tla_trace.rs          # Trace emission module (added to crate)
    test_scenarios.rs      # Integration tests (copied as tests/tla_trace_scenarios.rs)
  patches/
    instrumentation.patch  # Patches internal.rs and lib.rs
  apply.sh                 # Apply instrumentation to artifact
  run.sh                   # End-to-end: apply, build, run, generate configs
  INSTRUMENTATION.md       # This file

spec/
  base.tla                 # Base EBR specification
  Trace.tla                # Trace validation spec
  Trace_*.cfg              # Per-trace TLC configs (auto-generated)

traces/
  *.ndjson                 # Collected traces
```

## Quick Start

```bash
cd case-studies/crossbeam-epoch
bash harness/run.sh
```

This applies instrumentation, builds, runs all 5 test scenarios, generates TLC config files, and prints a summary.

To validate a trace:
```bash
cd spec
java -jar ../../lib/tla2tools.jar \
  -config Trace_basic_pin.cfg Trace \
  -DJSON=../traces/basic_pin.ndjson
```

Successful validation: TLC reports "Deadlock reached" at `l = Len(TraceLog) + 1` (all events consumed).

## Activation

Tracing is activated by the `CROSSBEAM_TRACE_FILE` environment variable:

```bash
CROSSBEAM_TRACE_FILE=traces/my_trace.ndjson cargo test -p crossbeam-epoch ...
```

When unset, `tla_trace::is_active()` returns `false` and all instrumentation is a no-op.

The module is compiled only under `#[cfg(all(feature = "std", not(crossbeam_loom)))]`, so it has zero cost in no_std or Loom builds.

## Instrumented Events

### Epoch Protocol

| Event | Location | Trigger | Validation |
|-------|----------|---------|------------|
| `ReadGlobalForPin` | `internal.rs:410` | After `global().epoch.load(Relaxed)`, before storing local epoch | Strong (full epoch state) |
| `CompletePin` | `internal.rs:448` | After epoch store + SeqCst fence | Strong |
| `NestedPin` | `internal.rs:456` | `guard_count > 0` branch of `pin()` | Strong |
| `Unpin` | `internal.rs:470-479` | After `guard_count.set(guard_count - 1)` | Strong |
| `ScanForAdvance` | `internal.rs:276` | After scan loop succeeds (all locals at current epoch) | Weak (pinned + globalEpoch) |
| `StoreAdvancedEpoch` | `internal.rs:286` | After `self.epoch.store(new_epoch, Release)` | Weak |

### Garbage Collection

| Event | Location | Trigger | Validation |
|-------|----------|---------|------------|
| `PushLocalBag` | `internal.rs:197` | After `queue.push(bag.seal(epoch), guard)` | Weak |
| `CollectExpiredBag` | `internal.rs:223` | After each successful `try_pop_if` in `collect()` | Weak |

### Lifecycle

| Event | Location | Trigger | Validation |
|-------|----------|---------|------------|
| `ReleaseHandle` | `internal.rs:519` | After `handle_count.set(handle_count - 1)` | Lifecycle (handleCount, guardCount) |
| `Finalize` | `internal.rs:531-569` | After full finalize completes | Finalize (globalEpoch) |

### Not Instrumented

Queue operations (`QueueLink`, `QueueAdvanceTail`, `QueuePop`) and `AccessNode` are not instrumented. The spec handles this via silent actions and `UNCHANGED queueVars`. This is acceptable because:
- Bag operations (`PushLocalBag`, `CollectExpiredBag`) are validated independently
- `SafeReclamation` invariant holds trivially when `accessed = {}` (no ghost access events)

## Key Design Decisions

### Epoch Value Conversion

The implementation uses even numbers for epochs (LSB = pinned flag). The spec uses plain integers 0, 1, 2, 3.

```rust
pub(crate) fn epoch_to_spec(epoch: Epoch) -> i64 {
    epoch.wrapping_sub(Epoch::starting()) as i64
}
```

This computes `data >> 1`, mapping implementation epochs 0, 2, 4, 6 to spec epochs 0, 1, 2, 3.

### Finalize Suppression

`finalize()` internally calls `pin()`, `push_bag()`, and `unpin()`, but the spec models it as a single atomic `Finalize` action. A thread-local `SUPPRESS` flag prevents intermediate events from being emitted:

```rust
// At start of finalize():
crate::tla_trace::suppress(true);
// ... internal pin/push/unpin operations ...
// After finalize completes:
crate::tla_trace::suppress(false);
crate::tla_trace::emit_finalize_event(global_epoch);
```

### String Constants

The TLA+ trace spec uses trace strings directly as constants (no mapping layer):
- Thread IDs: `"T1"`, `"T2"`, ... (assigned in order of first trace appearance)
- Node IDs: `"N0"` (sentinel), `"N1"`, `"N2"`, ... (not used in current traces)
- `Nil = "Nil"`, `Sentinel = "N0"`

This avoids TLC config file limitations (`:>` operator not supported in `.cfg` files).

### OnceLock Initialization

`TraceWriter` uses `OnceLock<Option<Mutex<TraceWriter>>>` — initialized once per process from `CROSSBEAM_TRACE_FILE`. Each test scenario must run in a separate process (not just a separate test function) because `OnceLock` cannot be re-initialized.

## Adding a New Event

1. **Define the event in `instrumentation-spec.md`** — document the code location, trigger point, and captured fields.

2. **Add emission function to `tla_trace.rs`** (if existing `emit_*` functions don't fit):
   ```rust
   pub(crate) fn emit_my_event(field1: Type, field2: Type) {
       if let Some(mutex) = writer() {
           if let Ok(mut w) = mutex.lock() {
               let t = get_tid(&mut w);
               let _ = writeln!(w.file,
                   r#"{{"event":"MyEvent","thread":"{}","ts":{},"field1":{}}}"#,
                   t, ts_nanos(), field1
               );
               let _ = w.file.flush();
           }
       }
   }
   ```

3. **Add instrumentation to source code** (in the patch):
   ```rust
   #[cfg(all(feature = "std", not(crossbeam_loom)))]
   if crate::tla_trace::is_active() {
       crate::tla_trace::emit_my_event(field1, field2);
   }
   ```

4. **Add trace action wrapper to `Trace.tla`**:
   ```tla
   TraceMyEvent ==
       /\ ~TraceFinished
       /\ \E t \in Thread :
           /\ IsThreadEvent("MyEvent", t)
           /\ MyEvent(t)           \* base spec action
           /\ ValidatePostState(t) \* appropriate validation
           /\ l' = l + 1
   ```
   Add `\/ TraceMyEvent` to the `TraceNext` disjunction.

5. **Regenerate the patch**:
   ```bash
   cd artifact/crossbeam
   git diff > ../../harness/patches/instrumentation.patch
   git checkout -- .
   ```

## Test Scenarios

| Scenario | Events | What it exercises |
|----------|--------|-------------------|
| `basic_pin` | 10 | Single pin/unpin cycle, second cycle, advance, finalize |
| `nested_pin` | 9 | Nested guards (NestedPin), inner/outer unpin, finalize |
| `epoch_advance` | 987 | 300 pins with garbage, bag push/collect, epoch advancement |
| `concurrent_epoch` | 1994 | 3 threads x 200 pins, concurrent advance, interleaved events |
| `finalize` | 7 | Handle drop triggering ReleaseHandle + Finalize |

## Validated Traces

All 5 traces pass TLC trace validation against `Trace.tla` with invariants `TypeOK`, `SafeReclamation`, and `PinnedConsistency`.

| Trace | Events | TLC States | Depth |
|-------|--------|------------|-------|
| basic_pin | 10 | 91 | 11 |
| nested_pin | 9 | 70 | 10 |
| epoch_advance | 987 | 2237 | — |
| concurrent_epoch | 1994 | 1539 | — |
| finalize | 7 | 58 | 8 |
