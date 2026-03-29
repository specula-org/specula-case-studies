# Instrumentation Guide: crossbeam-skiplist

Category B (concurrent/lock-free) — per-thread timebox traces with rdtsc intervals.

## Architecture

```
harness/
  src/
    tla_trace.rs        # Trace emission module (copied to artifact/src/)
    trace_tests.rs      # Test scenarios (copied to artifact/tests/)
    preprocess_trace.py # Merge per-thread files + compress timestamps
  patches/
    instrumentation.patch  # Patches base.rs, lib.rs, map.rs, Cargo.toml
  apply.sh              # Applies instrumentation
  run.sh                # End-to-end: apply + build + run + preprocess
```

## Instrumentation Points (after apply.sh)

All in `crossbeam-skiplist/src/base.rs`:

| Event | Location | Trigger |
|-------|----------|---------|
| InsertBegin | `insert_internal`, after `Node::alloc` | Before level-0 CAS loop |
| InsertCAS | `insert_internal`, around level-0 CAS | After CAS success |
| InsertBuildLevel | `insert_internal`, tower build loop | After installation CAS success |
| RemoveBegin | `remove`, after `try_acquire` | Successful refcount increment |
| RemoveMarkTower | `remove`, after `mark_tower()` | Both won=true and won=false paths |
| RemoveUnlink | `remove`, after unlink loop | After all CAS attempts |
| Get | `get`, after `search_bound` | Only when key found (not-found skipped) |
| ReleaseEntry | `RefEntry::release` and `release_with_pin` | After `decrement` call |

Additional changes:
- `Cargo.toml`: `tla-trace` feature flag
- `lib.rs`: `pub mod tla_trace;` (conditional)
- `map.rs`: `inner_head_ptr()` method on SkipMap
- `base.rs`: `inner_head_ptr()` method on SkipList, `use crate::tla_trace;`

## How to Add a New Field to an Event

1. Edit `harness/src/tla_trace.rs`: add parameter to the `emit_*` function
2. Update the `format!` string to include the new field in the JSON
3. Edit `base.rs`: capture the field value at the instrumentation point
4. Update `Trace.tla` if needed (add validation in `ValidatePostState*`)

## How to Add a New Event Type

1. Add `emit_new_event(...)` function to `harness/src/tla_trace.rs`
2. Add instrumentation call in `base.rs` at the trigger point, wrapped in `#[cfg(feature = "tla-trace")]`
3. Add `TraceNewEvent(tid, logline)` case in `Trace.tla`'s `MatchEvent`

## How to Move a Capture Point

Trace events wrap the critical operation with `[start, end]` timestamps:
```rust
#[cfg(feature = "tla-trace")]
let _tla_start = if tla_trace::is_active() { tla_trace::rdtsc() } else { 0 };

// ... critical atomic operation ...

#[cfg(feature = "tla-trace")]
if tla_trace::is_active() {
    let t_end = tla_trace::rdtsc();
    // capture state AFTER end
    tla_trace::emit_event(_tla_start, t_end, ...);
}
```

To move before → after: move the emit block after the operation.

## Rebuild and Re-run

```bash
cd case-studies/crossbeam-skiplist
bash harness/run.sh
```

Or manually:
```bash
bash harness/apply.sh
cd artifact/crossbeam/crossbeam-skiplist
cargo test --features tla-trace --test trace_tests -- --nocapture --test-threads=1
```

## Known Issues

- **Get + ReleaseEntry**: Get is a no-op in the spec but the implementation returns an Entry handle. Dropping it emits ReleaseEntry, which the spec doesn't expect. The harness only emits Get when found; not-found is skipped. For Get-acquired entries, the Phase 3 agent should either model Get's entry acquisition or add a SilentRelease action.
- **Node ID type**: All node IDs are emitted as JSON strings ("1", "2", "nil"). Trace.tla's `NodeMap` uses `StringToNat` to convert back to integers.
- **Thread IDs**: Emitted as strings ("t1", "t2"). Trace.cfg must use `Thread = {"t1", "t2"}` (strings, not model values).
- **Temporal property**: `TraceMatched` may fail due to lack of fairness. Use `-deadlock` flag or check that tracePC reached the end of all thread traces.
