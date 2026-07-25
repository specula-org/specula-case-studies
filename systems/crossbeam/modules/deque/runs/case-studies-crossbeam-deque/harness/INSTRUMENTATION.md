# Instrumentation Guide: crossbeam-deque

Quick reference for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Category B** (concurrent/lock-free): per-thread trace files, rdtsc timestamps
- **Trace module**: `src/tla_trace.rs` (copied into artifact by `apply.sh`)
- **Instrumentation**: `patches/instrumentation.patch` modifies `lib.rs` + `deque.rs`
- **Tests**: `tests/trace_tests.rs` (copied into artifact by `apply.sh`)
- **Env var**: `CROSSBEAM_DEQUE_TRACE_DIR=<dir>` activates tracing

## Instrumented Events

| Event | File:Line (after apply) | Trigger |
|-------|------------------------|---------|
| Push | `deque.rs:push()` | After `back.store(b+1)` |
| ResizeGrow | `deque.rs:resize()` | After `buffer.swap()`, before `defer_unchecked` |
| LIFOPop | `deque.rs:pop()` Lifo branch | At each exit point (empty/success/contention_lost) |
| FIFOPopAttempt | `deque.rs:pop()` Fifo branch | After `fetch_add` (success/rollback_needed) |
| FIFOPopRollback | `deque.rs:pop()` Fifo branch | After `front.store(f)` rollback |
| StealBegin | `deque.rs:steal()` | After loading buffer (proceed/empty) |
| StealReadTask | `deque.rs:steal()` | After `buffer.deref().read(f)` |
| StealCommit | `deque.rs:steal()` | After buffer re-check + CAS (success/fail_cas/fail_recheck) |

## How To...

### Add a new field to an event

1. Edit the `emit_*` function in `tla_trace.rs` to accept the new parameter
2. Add it to the JSON format string
3. Update the call site in `deque.rs` to pass the new value
4. Rebuild: `cd artifact/crossbeam/crossbeam-deque && cargo build`

### Add a new event type

1. Add an `emit_new_event(...)` function in `tla_trace.rs` (copy pattern from existing)
2. Insert trace calls in `deque.rs` at the desired trigger point:
   ```rust
   let _tla_ts = if crate::tla_trace::is_active() { crate::tla_trace::rdtsc() } else { 0 };
   // ... operation ...
   if crate::tla_trace::is_active() {
       let _tla_te = crate::tla_trace::rdtsc();
       crate::tla_trace::emit_new_event(_tla_ts, _tla_te, ...);
   }
   ```
3. Add a `TraceNewEvent` case in `Trace.tla:MatchEvent`

### Move a capture point (before -> after or vice versa)

The pattern for each event is:
```
ts_start = rdtsc()    // BEFORE the operation
<operation>
ts_end = rdtsc()      // AFTER the operation
state = capture()     // OUTSIDE the interval (doesn't widen timebox)
emit(ts_start, ts_end, state)
```
Move the `ts_start`/`emit` calls to change what the timebox wraps.

### Rebuild and re-run after changes

```bash
# If you modified tla_trace.rs or trace_tests.rs in harness/src/:
bash harness/apply.sh

# If you modified deque.rs directly in the artifact:
# (regenerate patch: cd artifact/crossbeam && git diff -- crossbeam-deque/ > ../../harness/patches/instrumentation.patch)

# Build + run + collect:
bash harness/run.sh
```

## Not Yet Instrumented

- `steal_batch_with_limit()` — FIFO batch steal (BatchStealBeginFIFO + StealCommit batchFIFO)
- `steal_batch_with_limit_and_pop()` — LIFO batch steal (BatchStealBeginLIFO + StealCommit batchLIFOFirst)

These can be added by following the same pattern as `steal()`. The key MC-1 finding
(missing buffer re-check at `batchLIFOFirst` CAS site) is in `steal_batch_with_limit_and_pop()`,
line ~1083.

## Per-Thread File Format

Each thread writes `trace-{tid}.ndjson` in `CROSSBEAM_DEQUE_TRACE_DIR`:
```json
{"tag":"trace","event":"Push","thread":"worker","start":48372719384,"end":48372719410,"state":{"front":0,"back":1}}
```

The preprocessor (`preprocess_trace.py`) merges per-thread files, compresses timestamps
to dense integers, and outputs a single JSON file for TLC.
