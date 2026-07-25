# Kanal Trace Instrumentation Guide

Guide for the Phase 3 validation agent to adjust instrumentation.

## Architecture

**Category B** (concurrent): per-thread NDJSON files with `[start, end]` timebox intervals.

```
Thread 0 → traces/<scenario>/trace-thread-0.ndjson
Thread 1 → traces/<scenario>/trace-thread-1.ndjson
  ↓ preprocess_trace.py
traces/<scenario>.json  →  Trace.tla (TLC)
```

## Files

| File | Purpose |
|------|---------|
| `harness/src/tla_trace.rs` | Trace emission module (per-thread writers, timestamp helpers) |
| `harness/src/trace_tests.rs` | Test scenarios that generate traces |
| `harness/src/preprocess_trace.py` | Merges per-thread files, compresses timestamps, remaps IDs |
| `harness/patches/instrumentation.patch` | Patch for `lib.rs`, `internal.rs`, `signal.rs` |
| `harness/apply.sh` | Applies patch + copies trace module |
| `harness/run.sh` | Full end-to-end: apply, build, run tests, preprocess |

## Instrumentation Points

After applying `harness/apply.sh`:

### lib.rs — Send/Recv paths

| Event | Location (post-apply) | Trigger |
|-------|----------------------|---------|
| `send_to_queue` | `Sender::send`, after `push_back(data)` | Queue has capacity |
| `send_direct_handoff` | `Sender::send`, after `next_recv()` returns Some | Receiver waiting |
| `send_block` | `Sender::send`, after `push_signal` | Queue full, no receiver |
| `send_closed` | `Sender::send`, after `recv_count == 0` check | Channel closed |
| `recv_from_queue` | `Receiver::recv`, after `pop_front()` + optional refill | Queue non-empty |
| `recv_direct_handoff` | `Receiver::recv`, after `next_send()` returns Some | Sender waiting |
| `recv_block` | `Receiver::recv`, after `push_signal` | Queue empty, no sender |
| `recv_closed` | `Receiver::recv`, after send_count/recv_count == 0 | Channel closed |
| `close` | `shared_impl!::close()`, after terminate+clear | Explicit close |

### internal.rs — Ref counting

| Event | Location | Trigger |
|-------|---------|---------|
| `clone_sender` | `Internal::clone_send`, after `inc_ref_count(true)` | Sender::clone |
| `clone_receiver` | `Internal::clone_recv`, after `inc_ref_count(false)` | Receiver::clone |
| `drop_sender` | `Internal::drop_send`, before `dec_ref_count(true)` | Sender::drop |
| `drop_receiver` | `Internal::drop_recv`, before `dec_ref_count(false)` | Receiver::drop |

### signal.rs — Signal lifecycle

| Event | Location | Trigger |
|-------|---------|---------|
| `signal_write_data` | `SyncSignal::write_data` / `read_data`, after `state.swap(UNLOCKED)` | Handoff complete |
| `signal_terminated` | `SyncSignal::terminate`, after `state.swap(TERMINATED)` | Signal cancelled |
| `wait_timeout` | `SyncSignal::wait`, after CAS(LOCKED → LOCKED_STARVATION) | Spin timeout, entering park |

### Test-level events

| Event | Location | Trigger |
|-------|---------|---------|
| `thread_reset` | Test code, after each send/recv operation | Between consecutive operations |

## How to Add a New Field to an Event

1. Edit `harness/src/tla_trace.rs`:
   - Add field to `ChannelState` struct if it's a channel state field
   - Update `to_json()` to include it
   - Or add a parameter to the relevant `emit_*` function

2. Update the emit call at the instrumentation point in `lib.rs` / `internal.rs` / `signal.rs`

3. Regenerate patch:
   ```bash
   cd artifact/kanal
   git diff -- src/lib.rs src/internal.rs src/signal.rs > ../../harness/patches/instrumentation.patch
   ```

## How to Add a New Event Type

1. Copy an existing emit pattern. For example, for a new channel event:
   ```rust
   if tla_trace::is_active() {
       let st = tla_trace::ChannelState { /* capture fields */ };
       tla_trace::emit_channel_event("new_event_name", _tla_start, &st, None);
   }
   ```

2. Insert at the correct trigger point in the source code

3. Add `MatchEvent` case in `Trace.tla`

## How to Move a Capture Point

To move state capture from "after operation" to "before operation" (or vice versa):
- Move the `if tla_trace::is_active()` block and state read before/after the operation
- Adjust `ValidatePostState` in Trace.tla accordingly (primed vs unprimed checks)

## Rebuild and Re-run

```bash
cd case-studies/kanal
bash harness/run.sh   # full clean rebuild + trace collection
```

Or for quick iteration:
```bash
cd artifact/kanal
cargo test --test trace_tests -- <test_name> --exact --nocapture
```

## Known Issues for Phase 3

1. **Multi-thread traces may need silent action tuning**: The `SilentSignalWaitSuccess` and `SilentThreadReset` guards may need adjustment for specific trace orderings. The `close_protocol` (single-thread) trace validates; multi-thread traces need iterative spec/trace alignment.

2. **Trace.tla fixes already applied**:
   - `ValidatePostState`: uses `Len(queue')` (primed) instead of `QueueLen` (un-primed)
   - `SilentThreadReset`: guards against consuming traced `thread_reset` events
   - Temporal property `TraceFullyConsumed` removed; uses deadlock detection instead

3. **`channelOpen` not emitted for drop events**: The spec only sets `channelOpen = FALSE` via explicit `Close`, not via DropSender/DropReceiver. Drop events emit only `sendCount` and `recvCount`.

4. **Events not yet instrumented**: `send_closed` (needs scenario where sender sees recv_count=0 before attempting), `signal_terminated` (needs channel close while threads are blocked), future-related events (async paths not instrumented in this phase).

5. **`recv_timeout` path not instrumented**: Only `recv()` is instrumented. If using `recv_timeout()` in test scenarios, those events won't be traced.
