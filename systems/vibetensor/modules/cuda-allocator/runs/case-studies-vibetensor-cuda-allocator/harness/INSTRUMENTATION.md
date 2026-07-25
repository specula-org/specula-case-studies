# VibeTensor CUDA Allocator — Trace Harness

This directory contains the Phase 2.5 trace harness for the native stream-ordered
CUDA caching allocator in `vbt::cuda::Allocator`. It builds the **real**
allocator source (split / coalesce / free-list / GC ladder / deferred-queue
logic) against a minimal in-process CUDA runtime stub, instruments it with
timebox trace emit calls at the sites listed in `spec/instrumentation-spec.md`,
and produces per-thread NDJSON traces that `spec/Trace.tla` consumes.

## Layout

```
harness/
├── apply.sh                 # Copy instrumented allocator into artifact
├── clean.sh                 # Restore original allocator and clean builds
├── run.sh                   # One-command build + run + collect traces
├── preprocess_trace.py      # Merge per-thread NDJSON → Trace.tla JSON
├── patches/                 # (reserved for future git-based patches)
├── src/
│   ├── allocator_patched.cc # allocator.cc + VBT_TRACE-gated emit calls
│   ├── vbt_trace.{h,cc}     # Per-thread timebox writer (Category B)
│   ├── vbt_alloc_instrument.h  # Macros + state-capture helper used by
│   │                             allocator_patched.cc
│   ├── scenario_basic_alloc_free.cc
│   ├── scenario_concurrent_alloc.cc
│   └── scenario_deferred_capture.cc
└── stubs/
    ├── cuda_runtime_api.h   # Fake <cuda_runtime_api.h>
    ├── cuda.h               # Fake <cuda.h> (driver API)
    ├── cuda_stub.cc         # In-process cudaMalloc/Event/Stream/... impls
    ├── graphs_stub.cc       # Minimal vbt::cuda::graphs symbols
    ├── allocator_async_stub.cc  # Empty AsyncBackend (never called)
    ├── absl/base/config.h
    └── dlpack/dlpack.h
```

## Building and running

```bash
cd .specula-output
bash harness/run.sh
```

This will:

1. Back up and overwrite `artifact/vibetensor/src/vbt/cuda/allocator.cc` with
   the instrumented copy (see `apply.sh`).  `clean.sh` restores it.
2. Compile the real allocator + `stream.cc`, `event.cc`, `event_pool.cc`,
   `guard.cc`, `device_count.cc` plus the CUDA stubs and trace module.
3. Build three scenario binaries and run each.
4. Invoke `preprocess_trace.py` to merge per-thread NDJSON into a single
   `<scenario>.json` per run.
5. Print per-scenario event counts.

Traces land in `.specula-output/traces/`:
- `<scenario>-thread-<N>.ndjson` — raw per-thread output
- `<scenario>.json`              — merged + timestamp-compressed (Trace.tla)

## Trace event coverage

`run.sh` currently produces events for:

| Event | Scenario(s) that fire it |
|-------|--------------------------|
| `raw_alloc.new` | all |
| `raw_alloc.reuse_stream` | `concurrent_alloc`, `basic_alloc_free` |
| `record_stream` | `basic_alloc_free`, `concurrent_alloc` |
| `raw_delete.mark` | multi-stream free in all scenarios |
| `raw_delete.same_stream_fast` | `concurrent_alloc` (same-stream frees) |
| `raw_delete.record_ok` | multi-stream free path |
| `raw_delete.publish` | multi-stream free path |
| `raw_delete.to_deferred` | `deferred_capture` |
| `pe.snapshot`, `pe.publish`, `pe.pop_ready` | all (`process_events`) |
| `emptyCache`, `gc.detach` | `concurrent_alloc` end-of-run flush |
| `env.capture_start`, `env.capture_end` | `deferred_capture` |

Events **defined in the spec but not yet covered** — add a scenario or
enable the config knob to exercise them:

- `raw_alloc.reuse_cross`   → set `VBT_NATIVE_ENABLE_CROSS_STREAM_FALLBACK=1`
- `raw_delete.record_fail`, `raw_delete.finish_rollback`
    → flip `vbt_trace::fail_next_event_record = true` around a `raw_delete`
- `pe.record_fail`          → same trick in a `process_events` iteration
- `pe.skip_capturing`, `pe.loop_done` → require an active capture during
      `process_events` (not yet wired into scenarios)
- `split`, `coalesce.left`, `coalesce.right`
    → set `VBT_NATIVE_ENABLE_BLOCK_SPLITTING=1` and request sizes that fit
      split heuristics
- `pool.*`, `pool.retain`, `pool.release`
    → exercise `Allocator::begin_allocate_to_pool` APIs (not instrumented
      here; see "How to add a new event" below)
- `fg.pass_gate`, `fg.retry_misfire`, `fg.recovered`
    → exercise `Allocator::setMemoryFraction` to a fraction that forces
      a breach (not yet instrumented)

## Instrumentation map (file:line in `allocator_patched.cc`)

After `apply.sh` runs, the same lines exist in
`artifact/vibetensor/src/vbt/cuda/allocator.cc`.  Search by event name:

| Event | Grep pattern |
|-------|--------------|
| `raw_alloc.new`            | `VBT_TRACE_BEGIN("raw_alloc.new")` |
| `raw_alloc.reuse_stream`   | `VBT_TRACE_BEGIN("raw_alloc.reuse_stream")` |
| `raw_alloc.reuse_cross`    | `VBT_TRACE_BEGIN("raw_alloc.reuse_cross")` |
| `raw_delete.mark`          | `VBT_TRACE_BEGIN("raw_delete.mark")` |
| `raw_delete.same_stream_fast` | inside `mark` block, `__vbt_tb.name = "raw_delete.same_stream_fast"` |
| `raw_delete.record_ok/fail`| `VBT_TRACE_BEGIN(failure ? ...)` |
| `raw_delete.publish`       | `VBT_TRACE_BEGIN("raw_delete.publish")` |
| `raw_delete.finish_rollback` | `VBT_TRACE_BEGIN("raw_delete.finish_rollback")` |
| `raw_delete.to_deferred`   | `VBT_TRACE_BEGIN("raw_delete.to_deferred")` |
| `record_stream`            | `VBT_TRACE_BEGIN("record_stream")` |
| `pe.snapshot`              | `VBT_TRACE_BEGIN("pe.snapshot")` |
| `pe.publish`               | `VBT_TRACE_BEGIN("pe.publish")` |
| `pe.pop_ready`             | `VBT_TRACE_BEGIN("pe.pop_ready")` |
| `split`                    | `VBT_TRACE_BEGIN("split")` |
| `coalesce.left/right`      | `VBT_TRACE_BEGIN("coalesce.left")` / `.right` |
| `gc.detach`                | `VBT_TRACE_BEGIN("gc.detach")` |
| `emptyCache`               | `VBT_TRACE_BEGIN("emptyCache")` |

## How to adjust instrumentation

### Add a new field to an existing event

Find the `VBT_TRACE_EMIT` call for that event in `allocator_patched.cc`.  The
call site always looks like:

```cpp
std::ostringstream __fields;
__fields << "\"bid\":" << __bid << ",\"sid\":\"s" << ... << "\"";
VBT_TRACE_EMIT(__state, __fields);
```

Append another `<<` to `__fields` before the `VBT_TRACE_EMIT`.  Re-run
`bash harness/run.sh` — it will re-apply, rebuild, re-run.

### Add a new event type

1. Pick the allocator line where you want to trace.  Wrap the relevant
   statements with:

   ```cpp
   #if defined(VBT_TRACE) && VBT_TRACE
     VBT_TRACE_BEGIN("<action_name>");
   #endif
     ... existing statements ...
   #if defined(VBT_TRACE) && VBT_TRACE
     VBT_TRACE_MARK_END();
     VBT_TRACE_CAPTURE_STATE(__state);
     std::ostringstream __fields;
     __fields << "\"fieldA\":" << valA << ",\"fieldB\":" << valB;
     VBT_TRACE_EMIT(__state, __fields);
   #endif
   ```

2. Ensure the `VBT_TRACE_BEGIN` and the paired `MARK_END` / `EMIT` live in
   the same C++ block (the macro declares `__vbt_tb` as a local variable).
   Wrap the whole thing in `{ ... }` if needed to avoid a redeclaration
   collision with a surrounding trace block.

3. Update `spec/Trace.tla`'s `MatchEvent` to include a new branch for the
   event name.

### Move a capture point (before → after a lock)

Move the `VBT_TRACE_CAPTURE_STATE(__state)` call.  Because `__state` is a
local `std::ostringstream`, nothing else needs to change.  If you move it
outside the `MuLockGuard`, you lose the lock-coherent snapshot — the
validator will need to tolerate that (e.g. via `ValidatePostStateWeak`
semantics).

### Add a new scenario binary

1. Copy `scenario_basic_alloc_free.cc` to `scenario_<name>.cc`.
2. Add `<name>` to the `SCENARIOS` array in `run.sh`.
3. `run.sh` compiles each scenario as `build/scenario_<name>` and writes
   traces to `traces/<name>-thread-<N>.ndjson`.

## Implementation notes

- **Category B** timebox methodology per `references/concurrent-timebox-guide.md`.
  Per-thread trace files, `rdtsc` start/end intervals, state snapshotted
  under the critical-section lock.
- **Probe effect**: the allocator holds a single global `mu_` around every
  action.  Because the critical sections are already serialized, timebox
  overhead (a thread-local `FILE*` append plus one `std::ostringstream`) is
  dominated by the lock itself; instrumentation does not change observable
  behaviour.
- **CUDA stubbing**: the stub implements `cudaMalloc` with host `malloc` and
  `cudaEventQuery` as always-ready, so the limbo pop path is exercised
  deterministically.  Scenarios that want capture semantics call
  `vbt_trace::set_capture_active(sid, true)` which the stub's
  `cudaStreamIsCapturing` reads.
- **Ghost state**: the instrumentation spec includes `rdOutcome`,
  `tlsActive`, `tlsPool`.  The current helper populates them with stub
  values (`"", false, 0`).  Add a per-site override when instrumenting the
  pool / capture APIs; `Trace.tla` reads `rdOutcome` in `ValidatePublish`.
- **Block ID stability**: `vbt_trace::register_block` interns `Block*`
  pointers into 1-based IDs.  When the allocator `delete`s a Block (in
  coalesce / gc.detach) we call `retire_block` so later events referencing
  the freed block still use its stable id with a `-dangling` sentinel (see
  `retired_block_id_of`).
