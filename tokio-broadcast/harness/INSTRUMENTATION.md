# Instrumentation Guide: tokio broadcast channel

Guide for the Phase 3 (validation) agent to adjust instrumentation.

## Architecture

- **Trace module**: `harness/src/tla_trace.rs` → copied to `tokio/src/sync/tla_trace.rs`
- **Patch**: `harness/patches/instrumentation.patch` → modifies `broadcast.rs` + `sync/mod.rs`
- **Test scenarios**: `harness/src/trace_tests.rs` → copied to `tokio/tests/trace_broadcast.rs`
- **Preprocessor**: `harness/src/preprocess_trace.py` — merges per-thread NDJSON into JSON

Category B (concurrent) — timebox approach with per-thread `[start, end]` intervals.

## Instrumentation Points

After `apply.sh`, the instrumented locations in `broadcast.rs` are:

| Event | Code location | Trigger point | State captured |
|-------|--------------|---------------|----------------|
| **Subscribe** | `new_receiver()` (~line 960) | After `rx_cnt` increment, before `drop(tail)` | rxNext, rxCnt |
| **Subscribe** | `channel()` (~line 519) | After Receiver creation | rxNext=0, rxCnt=1 |
| **Send** | `Sender::send()` (~line 680) | After `notify_rx(tail)` returns | tailPos, rxCnt |
| **RecvSuccess** | `recv_ref()` fast path (~line 1380) | After `self.next = self.next.wrapping_add(1)` | rxNext |
| **RecvSuccess** | `recv_ref()` slow path missed==0 (~line 1368) | After `self.next` advance | rxNext |
| **RecvEmpty** | `recv_ref()` (~line 1353) | After dropping locks, before return | (none) |
| **RecvClosed** | `recv_ref()` (~line 1310) | Before return | (none) |
| **RecvLagged** | `recv_ref()` (~line 1378) | After `self.next = next` | rxNext |
| **SenderDrop** | `Sender::drop()` (~line 1117) | After `fetch_sub`, before `close_channel()` | numTx |
| **CloseChannel** | `close_channel()` (~line 945) | After `notify_rx(tail)` returns | closed |
| **SenderClone** | `Sender::clone()` (~line 1107) | After `fetch_add` | (none) |
| **ReceiverDrop** | `Receiver::drop()` (~line 1670) | After `rx_cnt -= 1`, before cleanup loop | rxCnt |
| **DeregisterWaiter** | `Recv::drop()` (~line 1790) | After removing from waiters list | (none) |

## Key Design Decisions

### Receiver Identity
- `trace_id: u64` field added to `Receiver` struct
- Assigned from `tla_trace::NEXT_RECEIVER_ID` (global `AtomicU64`, starts at 1)
- Emitted as `"r1"`, `"r2"`, etc. — matches TLA+ `Receiver` constants

### Value Identity
- Values cycle `"v1"`, `"v2"` via `tla_trace::NEXT_VALUE_ID` counter
- The actual Rust value `T` is not serialized (generic, no Debug bound)
- Value identity doesn't affect validation (spec only checks slot occupancy)

### Trace Suppression
- `trace_suppress: bool` field on `Receiver` — set to `true` during `Receiver::drop` cleanup loop
- Prevents spurious RecvSuccess/RecvLagged events from the cleanup `recv_ref` calls
- The cleanup is modeled atomically in the spec's `ReceiverDrop` action

### Timestamp Pattern
- `start` = `tla_trace::now_ns()` captured before lock acquisition
- `end` = captured after lock release (or after emit for in-lock events)
- State captured under lock, stored in locals, emitted after lock release

## How to Add a New Field to an Event

1. Add capture code in `broadcast.rs` at the instrumentation point (read under lock)
2. Add the field to the `emit_*` function signature in `tla_trace.rs`
3. Add the field to the JSON format string in the `emit_*` function body
4. Copy updated `tla_trace.rs` to artifact (or re-run `apply.sh`)

## How to Add a New Event Type

1. Add `pub fn emit_new_event(...)` in `tla_trace.rs`
2. Insert the emit call in `broadcast.rs` at the trigger point
3. Add the event to `MatchEvent` in `Trace.tla`
4. Re-run `apply.sh` then `run.sh`

## How to Move a Capture Point

Some events may need their trigger point adjusted (e.g., capture before vs after):

1. Find the emit call in `broadcast.rs` (search for `tla_trace::emit_`)
2. Move it to the new location
3. Adjust which state fields are captured (may need different lock context)
4. Regenerate patch: `cd artifact/tokio && git diff -- tokio/src/sync/broadcast.rs tokio/src/sync/mod.rs > ../../harness/patches/instrumentation.patch`

## How to Rebuild and Re-run

```bash
cd case-studies/tokio-broadcast
bash harness/run.sh
```

This reverts the artifact, re-applies instrumentation, builds, runs tests, and collects traces.

## Known Limitations

- **DeregisterWaiter** requires async recv cancellation (not covered by sync tests)
- **concurrent_send_recv** creates 3 receivers (r1, r2, r3) — Trace.cfg needs `Receiver = {"r1", "r2", "r3"}`
- Value cycling (`v1`, `v2`) doesn't match actual Rust values — acceptable for spec validation
- Cross-thread overlap is low (~0.5%) because `thread::sleep` creates gaps between operations

## Trace.cfg Adjustments for Validation

The default `Trace.cfg` uses `Receiver = {"r1", "r2"}`. Adjust per scenario:

| Scenario | Receivers | Capacity | Notes |
|----------|-----------|----------|-------|
| basic_send_recv | `{"r1", "r2"}` | 2 | Default config works |
| close_recv_race | `{"r1", "r2"}` | 2 | Default config works |
| lagged_receiver | `{"r1", "r2"}` | 2 | Default config works |
| concurrent_send_recv | `{"r1", "r2", "r3"}` | 2 | Need 3 receivers |

## SilentCloseChannel Guard

The `SilentCloseChannel` silent action in `Trace.tla` has a guard:
```tla
/\ \A tid \in ViablePIDs : traces[tid][pc[tid]].event /= "CloseChannel"
```
This prevents the silent action from consuming `closePending` when the trace has an explicit CloseChannel event.
