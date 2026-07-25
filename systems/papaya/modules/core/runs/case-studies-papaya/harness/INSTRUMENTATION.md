# Papaya Trace Instrumentation Guide

## Overview

Category B (concurrent/lock-free) instrumentation using per-thread files with rdtsc timestamps.

- **Trace module**: `src/tla_trace.rs` (copied from `harness/src/tla_trace.rs`)
- **Feature flag**: `tla-trace` — all instrumentation is behind `#[cfg(feature = "tla-trace")]`
- **Activation**: Set `PAPAYA_TRACE_DIR=/path/to/dir` environment variable
- **Output**: Per-thread NDJSON files (`trace-thread-{tid}.ndjson`), preprocessed to single JSON

## Instrumentation Points

All instrumentation is in `src/raw/mod.rs`:

| Event | Function | What it traces |
|-------|----------|----------------|
| `init_table` | `new()` (~line 246) and `init()` (~line 1916) | Table allocation (eager or lazy) |
| `insert_cas` | `insert_at()` (~line 903) | Phase 1: CAS null → new entry |
| `insert_meta` | `insert_at()` (~line 914) | Phase 2: meta store after CAS |
| `insert_update` | `update_at()` (~line 977) | CAS old → new (non-tombstone) |
| `remove` | `update_at()` (~line 977) | CAS entry → TOMBSTONE |
| `copy_mark_copying` | `copy_at_blocking()` (~line 2175) and `copy_at_incremental()` (~line 2382) | fetch_or COPYING tag |
| `copy_insert` | After `insert_copy()` calls in blocking (~line 2201) and incremental (~line 2408) | CAS entry into next table |
| `copy_mark_copied` | `copy_at_incremental()` (~line 2436) | Store COPIED tag |
| `alloc_next` | `get_or_alloc_next()` (~line 2042) | Next table allocation |
| `try_promote` | `try_promote()` (~line 2612) | CAS root to next table |
| `abort_resize` | `help_copy_blocking()` (~line 2141) | Store ABORTED status |
| `park` | `help_copy_blocking()` (~line 2218) and `help_copy_incremental()` (~line 2404) | Thread parks on parker |

## How to Add a New Field to an Event

1. Edit the `emit_*` function in `harness/src/tla_trace.rs` to accept the new parameter
2. Add it to the format string (JSON field)
3. At the instrumentation point in `raw/mod.rs`, pass the value to the emit call
4. Copy updated `tla_trace.rs` to `artifact/papaya/src/tla_trace.rs`
5. Rebuild: `cargo test --features tla-trace --test trace_tests --no-run`

## How to Add a New Event Type

1. Add a new `emit_new_event()` function in `tla_trace.rs` (copy pattern from existing)
2. At the target location in `raw/mod.rs`, add:
   ```rust
   #[cfg(feature = "tla-trace")]
   let _tla_start = crate::tla_trace::rdtsc();
   // ... the operation ...
   #[cfg(feature = "tla-trace")]
   {
       let _tla_end = crate::tla_trace::rdtsc();
       crate::tla_trace::emit_new_event(..., _tla_start, _tla_end);
   }
   ```
3. Rebuild and re-run

## How to Move a Capture Point

The `[start, end]` interval brackets the critical operation. To move:
- **Before → After**: Move `_tla_start` after the operation, capture both timestamps after
- **Tighter interval**: Place `_tla_start` right before the CAS/store and `_tla_end` right after

## Key/Value Extraction

Keys and values are extracted as raw bytes via `raw_to_i64()` — no Debug bound needed.
For i32 keys, this gives the integer directly. For other types, it gives a unique i64 identifier.

## Rebuild and Re-run

```bash
cd case-studies/papaya
bash harness/run.sh
```

Or manually:
```bash
cd artifact/papaya
cargo test --features tla-trace --test trace_tests <scenario> -- --exact --nocapture
```
