# Instrumentation Spec: kanal MPMC Channel

## Category

**Category B (Concurrent)** — per-thread timebox traces with `[start, end]` intervals.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<string>",
  "thread": "<thread_id>",
  "start": <u64_timestamp>,
  "end": <u64_timestamp>,
  "state": { ... },
  "data": "<optional_data_id>"
}
```

### Timestamp Capture

Use `std::time::Instant` or `rdtsc` for start/end timestamps. The preprocessor will compress to dense integers.

- `start`: captured BEFORE the instrumented operation
- `end`: captured AFTER the instrumented operation
- Keep intervals as tight as possible around the critical section / atomic operation

### State Fields

| Trace field | TLA+ variable | Source | Capture timing |
|---|---|---|---|
| `state.queueLen` | `QueueLen` | `internal.queue.len()` | After operation, under lock |
| `state.sendCount` | `sendCount` | `internal.send_count` | After operation, under lock |
| `state.recvCount` | `recvCount` | `internal.recv_count` | After operation, under lock |
| `state.channelOpen` | `channelOpen` | `send_count > 0 \|\| recv_count > 0` | After operation, under lock |
| `state.waitListLen` | `Len(waitList)` | `internal.wait_list.len()` | After operation, under lock |
| `state.recvBlocking` | `recvBlocking` | `internal.recv_blocking` | After operation, under lock |

### Data Identity

Data values need stable identifiers across threads. Use a monotonic counter assigned at send time:

```rust
static DATA_ID: AtomicU64 = AtomicU64::new(1);
```

Wrap the data `T` with an ID at channel creation or use a side-channel hashmap.

## Section 2: Action-to-Code Mapping

### Send Actions

#### 1. `send_direct_handoff`

- **Spec action**: `SendDirectHandoff(sender)`
- **Code location**: `lib.rs:614-618` (Sender::send, `next_recv()` returns Some)
- **Trigger**: After `first.send(data)` completes, before `return Ok(())`
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.sendCount`, `state.recvCount`, `data`
- **Notes**: `start` before `acquire_internal`, `end` after `first.send(data)` returns. The receiver signal is resolved outside the lock.

#### 2. `send_to_queue`

- **Spec action**: `SendToQueue(sender)`
- **Code location**: `lib.rs:620-623` (Sender::send, queue push path)
- **Trigger**: After `internal.queue.push_back(data)`, before dropping lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.sendCount`, `state.recvCount`, `data`
- **Notes**: `start` before `acquire_internal`, `end` after push_back. State captured under lock.

#### 3. `send_block`

- **Spec action**: `SendBlock(sender)`
- **Code location**: `lib.rs:625-629` (Sender::send, push signal to waitlist)
- **Trigger**: After `internal.push_signal(sig.dynamic_ptr())`, before `drop(internal)`
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.waitListLen`, `data`
- **Notes**: `start` before `acquire_internal`, `end` after push_signal but before drop(internal). Thread then blocks on `sig.wait()`.

#### 4. `send_closed`

- **Spec action**: `SendClosed(sender)`
- **Code location**: `lib.rs:610-612` (Sender::send, recv_count == 0)
- **Trigger**: After checking `recv_count == 0`, before returning error
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`, `data`

### Recv Actions

#### 5. `recv_from_queue`

- **Spec action**: `RecvFromQueue(receiver)`
- **Code location**: `lib.rs:1067-1075` (Receiver::recv, queue pop path)
- **Trigger**: After `queue.pop_front()` and optional sender refill, before returning
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.sendCount`, `state.recvCount`, `data`
- **Notes**: If a sender is refilled (`next_send()` returns Some), the sender's signal is resolved inline. `data` is the value popped from queue front.

#### 6. `recv_direct_handoff`

- **Spec action**: `RecvDirectHandoff(receiver)`
- **Code location**: `lib.rs:1077-1081` (Receiver::recv, direct handoff from sender)
- **Trigger**: After `p.recv()` completes
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.sendCount`, `state.recvCount`, `data`
- **Notes**: `start` before `acquire_internal`, `end` after `p.recv()` returns. The sender signal read happens outside the lock.

#### 7. `recv_block`

- **Spec action**: `RecvBlock(receiver)`
- **Code location**: `lib.rs:1087-1091` (Receiver::recv, push recv signal to waitlist)
- **Trigger**: After `internal.push_signal(sig.dynamic_ptr())`, before `drop(internal)`
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`, `state.waitListLen`

#### 8. `recv_closed`

- **Spec action**: `RecvClosed(receiver)`
- **Code location**: `lib.rs:1064-1065` or `lib.rs:1082-1083`
- **Trigger**: After detecting closed condition, before returning error
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`

### Signal Lifecycle Actions

#### 9. `signal_write_data`

- **Spec action**: `SignalWaitSuccess(t)`
- **Code location**: `signal.rs:161-168` (SyncSignal::write_data) or `signal.rs:171-177` (SyncSignal::read_data)
- **Trigger**: After `state.swap(UNLOCKED, Ordering::AcqRel)` completes
- **Fields**: `event`, `thread`, `start`, `end`, `signalState`
- **Notes**: This event is emitted by the BLOCKING thread when it wakes up and observes UNLOCKED. `start` = when thread starts checking after wake, `end` = after confirming state.

#### 10. `signal_terminated`

- **Spec action**: `SignalWaitFailure(t)`
- **Code location**: `signal.rs:195-232` (SyncSignal::wait, TERMINATED path)
- **Trigger**: After observing `state == TERMINATED`
- **Fields**: `event`, `thread`, `start`, `end`, `signalState`

### Timeout Actions

#### 11. `wait_timeout`

- **Spec action**: `WaitTimeout(t)`
- **Code location**: `signal.rs:241-246` (SyncSignal::wait_timeout, CAS to LOCKED_STARVATION)
- **Trigger**: After CAS(LOCKED → LOCKED_STARVATION) succeeds
- **Fields**: `event`, `thread`, `start`, `end`
- **Notes**: `start` before CAS, `end` after CAS succeeds.

#### 12. `wait_timeout_recheck`

- **Spec action**: `WaitTimeoutRecheck(t)`
- **Code location**: `signal.rs:254-255` (deadline exceeded, final state load)
- **Trigger**: After final `state.load(Ordering::Acquire)` returns UNLOCKED or TERMINATED
- **Fields**: `event`, `thread`, `start`, `end`, `signalState`

#### 13. `wait_timeout_cancel`

- **Spec action**: `WaitTimeoutCancel(t)`
- **Code location**: `lib.rs:801-806` (cancel_send_signal) or `lib.rs:1149-1151` (cancel_recv_signal)
- **Trigger**: After `cancel_send_signal`/`cancel_recv_signal` returns true
- **Fields**: `event`, `thread`, `start`, `end`, `state.waitListLen`

### Future Drop Actions

#### 14. `drop_recv_future_rendezvous`

- **Spec action**: `DropRecvFutureRendezvous(t)`
- **Code location**: `future.rs:240-244` (ReceiveFuture::drop, cap==0 path)
- **Trigger**: After `self.sig.drop_data()`
- **Fields**: `event`, `thread`, `start`, `end`

#### 15. `drop_recv_future_buffered`

- **Spec action**: `DropRecvFutureBuffered(t)`
- **Code location**: `future.rs:246-249` (ReceiveFuture::drop, push_front path)
- **Trigger**: After `queue.push_front(...)` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.queueLen`
- **Notes**: This is the bug-hunting target for F2-1 (capacity violation).

#### 16. `drop_recv_future_cancel`

- **Spec action**: `DropRecvFutureCancel(t)`
- **Code location**: `future.rs:223-227` (ReceiveFuture::drop, cancel in waitlist)
- **Trigger**: After `cancel_recv_signal` returns true
- **Fields**: `event`, `thread`, `start`, `end`, `state.waitListLen`

#### 17. `drop_send_future_cancel`

- **Spec action**: `DropSendFutureCancel(t)`
- **Code location**: `future.rs:77-79` (SendFuture::drop, cancel in waitlist)
- **Trigger**: After `cancel_send_signal` returns true
- **Fields**: `event`, `thread`, `start`, `end`, `state.waitListLen`

#### 18. `drop_send_future_wait`

- **Spec action**: `DropSendFutureWait(t)`
- **Code location**: `future.rs:82-85` (SendFuture::drop, signal taken, blocking_wait)
- **Trigger**: After `blocking_wait()` returns
- **Fields**: `event`, `thread`, `start`, `end`

### Ref Counting / Close Actions

#### 19. `clone_sender`

- **Spec action**: `CloneSender`
- **Code location**: `internal.rs:84-88` (Internal::clone_send → inc_ref_count)
- **Trigger**: After `inc_ref_count(true)` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`

#### 20. `clone_receiver`

- **Spec action**: `CloneReceiver`
- **Code location**: `internal.rs:66-71` (Internal::clone_recv → inc_ref_count)
- **Trigger**: After `inc_ref_count(false)` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`

#### 21. `drop_sender`

- **Spec action**: `DropSender`
- **Code location**: `internal.rs:93-98` (Internal::drop_send → dec_ref_count)
- **Trigger**: After `dec_ref_count(true)` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`, `state.waitListLen`

#### 22. `drop_receiver`

- **Spec action**: `DropReceiver`
- **Code location**: `internal.rs:75-80` (Internal::drop_recv → dec_ref_count)
- **Trigger**: After `dec_ref_count(false)` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`, `state.queueLen`

#### 23. `close`

- **Spec action**: `Close`
- **Code location**: `lib.rs:237-247` (close() method)
- **Trigger**: After `terminate_signals()` + `queue.clear()` under lock
- **Fields**: `event`, `thread`, `start`, `end`, `state.sendCount`, `state.recvCount`, `state.channelOpen`

### Lifecycle

#### 24. `thread_reset`

- **Spec action**: `ThreadReset(t)`
- **Code location**: N/A (harness-level: after a send/recv completes and thread re-enters idle)
- **Trigger**: After the send/recv operation returns
- **Fields**: `event`, `thread`, `start`, `end`
- **Notes**: This is a harness-level event, not from the library itself. Emit between consecutive operations by the same thread.

## Section 3: Special Considerations

### Mutex-Protected State

All channel state (queue, wait_list, ref counts) is protected by a single mutex. State snapshots in events are **consistent** (no torn reads) when captured under the lock. For events that happen outside the lock (signal write/read, blocking wait), only signal-specific state is available.

### Signal Operations Outside Lock

`SyncSignal::write_data`, `read_data`, and `terminate` happen **outside** the mutex. These are the critical race windows for Family 1. The timebox intervals for these events should be:
- `start`: just before the pointer dereference / data copy
- `end`: just after the `state.swap()` atomic operation

### Thread Identity

Use `std::thread::current().id()` for thread identity. Map to TLA+ Thread constants in the preprocessor (first encounter order: t1, t2, t3, ...).

### Data Identity Tracking

Since kanal transfers ownership of `T` through the channel, we need stable data identifiers:
- Option A: Wrap `T` in a `(u64, T)` tuple where u64 is a monotonic ID
- Option B: Use a concurrent hashmap keyed by pointer address for short-lived tracking
- Option C: For test harness, use `u64` as `T` and the value itself as the identity

For trace validation, Option C is simplest and sufficient.

### Async vs Sync Paths

The spec models both sync and async paths. For initial trace validation:
- Instrument **sync** paths first (`Sender::send`, `Receiver::recv`)
- Async paths (`SendFuture::poll`, `ReceiveFuture::poll`) share the same internal logic but with signal state transitions spread across multiple poll calls

### Bootstrap State

`TraceInit` matches the library's `Internal::new`:
- `queue = <<>>`, `recvBlocking = FALSE`, `waitList = <<>>`
- `sendCount = 1`, `recvCount = 1`, `refCount = 2`
- All threads idle

No special bootstrap handling needed — the library starts in this exact state.

### Preprocessor

The trace preprocessor must:
1. Parse NDJSON → group by thread ID
2. Compress timestamps to dense integers (monotonic within thread, comparable across threads)
3. Map thread IDs to model constants (t1, t2, ...)
4. Map data values to model constants (d1, d2, ...)
5. Output as JSON: `{ "t1": [{event, start, end, state, ...}, ...], "t2": [...] }`
