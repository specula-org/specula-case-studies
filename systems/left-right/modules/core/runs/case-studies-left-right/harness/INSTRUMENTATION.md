# Instrumentation Guide: left-right

## Overview

Category B (concurrent/lock-free) system using timebox trace approach:
- Per-thread NDJSON files (no mutex contention)
- `SystemTime` timestamps for `[start, end]` intervals
- State captured outside the interval
- Preprocessor merges into JSON for TLC

## Instrumentation Points

All instrumentation is in `tests/tla_scenarios.rs` (external to library code).
Accessor methods are patched into `src/read.rs` and `src/write.rs` by `apply.sh`.

### Reader Events

| Event | Location | State Fields |
|-------|----------|-------------|
| ReaderEnter | After `r.enter()` returns | `epoch`, `enters` |
| ReaderExit | After `drop(guard)` | `epoch`, `enters` |

Accessors: `r.trace_epoch()` (read.rs), `r.trace_enters()` (read.rs)

### Writer Events

| Event | Location | State Fields |
|-------|----------|-------------|
| WriterAppend | After `w.append(op)` returns | `copyL`, `copyR`, `first`, `totalOps` |
| WriterPublish | After `w.publish()` returns | `pointer`, `copyL`, `copyR`, `first`, `second`, `totalOps` |

Accessors: `w.trace_first()` (write.rs), `w.trace_second()` (write.rs)

Copy values read via `CopyTracker` (unsafe raw pointer reads, safe at instrumentation points).
Pointer identity via address comparison with initial L/R addresses.

## How to Modify

### Add a new state field to an event

1. Edit `tla_scenarios.rs` — find the `emit_*` call for the event
2. Add the field to the format string and pass the value
3. Run `bash harness/run.sh` to regenerate traces

### Add a new event type

1. Add a new `emit_*` method to `TraceWriter` in `tla_scenarios.rs`
2. Insert the emit call at the appropriate point in the test scenario
3. Add matching logic in `Trace.tla` (MatchEvent)
4. Run `bash harness/run.sh`

### Move a capture point

The timebox `[start, end]` wraps the actual operation. State is captured after `end`.
To move it: adjust where `now_ns()` calls are placed relative to the operation.

### Rebuild and re-run

```bash
cd case-studies/left-right
bash harness/run.sh
```

This cleans the artifact, re-applies patches, builds, runs tests, and preprocesses traces.

## Copy Identification

"L" = initial reader copy (the one `AtomicPtr` points to at construction)
"R" = initial writer copy (the one `WriteHandle::w_handle` points to at construction)

Addresses are captured at construction and compared throughout. Swaps change which copy
the reader/writer sees, but the L/R labels are fixed to the initial allocation addresses.
