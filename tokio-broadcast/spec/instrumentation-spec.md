# Instrumentation Spec: tokio broadcast channel

Maps TLA+ spec actions to source code locations for trace harness generation.

**Source file**: `tokio/src/sync/broadcast.rs`
**Category**: B (concurrent) — timebox trace approach with per-thread `[start, end]` intervals.

---

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "thread": "<thread_id>",
  "start": <u64_timestamp>,
  "end": <u64_timestamp>,
  "receiver": "<receiver_id>",     // for receiver-specific actions
  "value": "<value_id>",           // for Send
  "state": {                        // post-state snapshot
    "tailPos": <u64>,
    "rxCnt": <usize>,
    "closed": <bool>,
    "numTx": <usize>,
    "rxNext": <u64>,               // for the acting receiver
    "slotRem": <usize>             // for the affected slot
  }
}
```

### Timestamp Capture

Use `std::time::Instant` or `rdtsc` for `[start, end]` intervals:
- `start`: captured immediately before the critical section (lock acquire)
- `end`: captured immediately after the critical section (lock release)
- Keep intervals tight around the mutex-guarded sections.

### State Fields

| Impl field | TLA+ variable | Access method |
|---|---|---|
| `tail.pos` | `tailPos` | Read under tail lock |
| `tail.rx_cnt` | `rxCnt` | Read under tail lock |
| `tail.closed` | `closed` | Read under tail lock |
| `shared.num_tx` | `numTx` | `num_tx.load(Acquire)` |
| `self.next` | `rxNext` | Direct field access on Receiver |
| `slot.rem` | `slotRem` | `rem.load(SeqCst)` under slot lock |

---

## Section 2: Action-to-Code Mapping

### Send

| Field | Value |
|---|---|
| **Spec action** | `Send(v)` |
| **Code location** | `broadcast.rs:631-667` (`Sender::send`) |
| **Trigger point** | After `slot.val = Some(value)` (line 656), before `drop(slot)` (line 659) |
| **Event name** | `"Send"` |
| **Fields** | `value`, `state.tailPos` (= new pos after wrapping_add), `state.rxCnt` |
| **Notes** | Capture AFTER tail.pos is advanced (line 644) and slot is written (lines 650-656). The tail lock is still held, so state is consistent. |

### Subscribe

| Field | Value |
|---|---|
| **Spec action** | `Subscribe(r)` |
| **Code location** | `broadcast.rs:924-942` (`new_receiver`) |
| **Trigger point** | After `tail.rx_cnt` increment (line 936), before `drop(tail)` (line 939) |
| **Event name** | `"Subscribe"` |
| **Fields** | `receiver` (new receiver ID), `state.rxNext` (= tail.pos), `state.rxCnt` |
| **Notes** | Called from `Sender::subscribe` (line 694) and `Receiver::resubscribe` (line 1393). Instrument `new_receiver` to cover both paths. |

### RecvSuccess

| Field | Value |
|---|---|
| **Spec action** | `RecvSuccess(r)` |
| **Code location** | `broadcast.rs:1325-1328` (fast path return) and `broadcast.rs:1313-1316` (slow path missed==0 return) |
| **Trigger point** | After `self.next = self.next.wrapping_add(1)` (line 1325), before returning `Ok(RecvGuard)` |
| **Event name** | `"RecvSuccess"` |
| **Fields** | `receiver`, `state.rxNext` (= new next after advance) |
| **Notes** | Two code paths return Ok: fast path (line 1325-1327) and slow-path recovery (lines 1313-1316). Instrument both. RecvGuard::drop (rem decrement) happens later but is under slot lock — the state at this point reflects the read. |

### RecvEmpty

| Field | Value |
|---|---|
| **Spec action** | `RecvEmpty(r)` |
| **Code location** | `broadcast.rs:1298` (`return Err(TryRecvError::Empty)`) |
| **Trigger point** | Just before return (line 1298), after waiter registration (lines 1280-1288) |
| **Event name** | `"RecvEmpty"` |
| **Fields** | `receiver` |
| **Notes** | No state change to validate (rxNext unchanged). Waiter registration is internal. |

### RecvClosed

| Field | Value |
|---|---|
| **Spec action** | `RecvClosed(r)` |
| **Code location** | `broadcast.rs:1260` (`return Err(TryRecvError::Closed)`) |
| **Trigger point** | Just before return (line 1260) |
| **Event name** | `"RecvClosed"` |
| **Fields** | `receiver` |
| **Notes** | No state change (UNCHANGED vars in spec). |

### RecvLagged

| Field | Value |
|---|---|
| **Spec action** | `RecvLagged(r)` |
| **Code location** | `broadcast.rs:1321` (`return Err(TryRecvError::Lagged(missed))`) |
| **Trigger point** | After `self.next = next` (line 1319), before return |
| **Event name** | `"RecvLagged"` |
| **Fields** | `receiver`, `state.rxNext` (= new next, the oldest position) |
| **Notes** | The missed==0 case (lines 1313-1316) maps to RecvSuccess, not RecvLagged. |

### SenderDrop

| Field | Value |
|---|---|
| **Spec action** | `SenderDrop` |
| **Code location** | `broadcast.rs:1067-1073` (`Sender::drop`) |
| **Trigger point** | After `num_tx.fetch_sub(1, AcqRel)` (line 1069), before `close_channel()` call |
| **Event name** | `"SenderDrop"` |
| **Fields** | `state.numTx` (= new count after decrement) |
| **Notes** | Emit BEFORE close_channel() is called. The close_channel step is either a separate CloseChannel event or handled as a SilentCloseChannel. |

### CloseChannel

| Field | Value |
|---|---|
| **Spec action** | `CloseChannel` |
| **Code location** | `broadcast.rs:905-910` (`close_channel`) |
| **Trigger point** | After `tail.closed = true` (line 907), before `notify_rx` (line 909) |
| **Event name** | `"CloseChannel"` |
| **Fields** | `state.closed` (= true) |
| **Notes** | Called from `Sender::drop` when last sender. Can be modeled as silent action if not separately instrumented (SilentCloseChannel in Trace.tla). If instrumented, emit between setting closed and notifying. |

### SenderClone

| Field | Value |
|---|---|
| **Spec action** | `SenderClone` |
| **Code location** | `broadcast.rs:1058-1064` (`Sender::clone`) |
| **Trigger point** | After `num_tx.fetch_add(1, Relaxed)` (line 1061) |
| **Event name** | `"SenderClone"` |
| **Fields** | (none required; numTx can be validated if captured) |
| **Notes** | Low priority for instrumentation — cloning is simple. |

### ReceiverDrop

| Field | Value |
|---|---|
| **Spec action** | `ReceiverDrop(r)` |
| **Code location** | `broadcast.rs:1548-1574` (`Receiver::drop`) |
| **Trigger point** | After `tail.rx_cnt -= 1` (line 1552), before `drop(tail)` (line 1561) |
| **Event name** | `"ReceiverDrop"` |
| **Fields** | `receiver`, `state.rxCnt` (= new count after decrement) |
| **Notes** | Capture under tail lock (lines 1550-1561) BEFORE the cleanup loop (lines 1563-1573). The cleanup loop's effects are modeled atomically in the spec. |

### DeregisterWaiter

| Field | Value |
|---|---|
| **Spec action** | `DeregisterWaiter(r)` |
| **Code location** | `broadcast.rs:1625-1662` (`Recv::drop`) |
| **Trigger point** | After removing from waiters list (line 1657) |
| **Event name** | `"DeregisterWaiter"` |
| **Fields** | `receiver` |
| **Notes** | Only emitted if the waiter was actually queued (line 1638, 1650). |

---

## Section 3: Special Considerations

### 1. Receiver Identity

Each Receiver needs a unique ID for the trace. Options:
- Assign monotonic IDs in `new_receiver` (simplest)
- Use pointer address (requires mapping in preprocessor)
- Use Arc reference count as proxy (not unique)

**Recommendation**: Add a `trace_id: u64` field to Receiver, assigned from an `AtomicU64` counter in `new_receiver`. Map to spec constants (r1, r2, ...) in the preprocessor.

### 2. Sender Identity

Senders are interchangeable in the spec (only `numTx` count matters). Trace events from senders don't need per-sender IDs, just the thread ID for timebox ordering.

### 3. Timestamp Precision

For Category B timebox validation, timestamps must be monotonic within each thread and provide meaningful ordering across threads. Use:
- `std::time::Instant::now()` for cross-thread ordering (sufficient for mutex-based system)
- Keep intervals tight: `start` before lock, `end` after lock release

### 4. Conditional Compilation

All instrumentation should be behind `#[cfg(feature = "tla-trace")]` or `#[cfg(test)]` to avoid runtime overhead. Use an environment variable (`BROADCAST_TRACE_FILE`) to specify the output file.

### 5. Trace Preprocessing

Raw per-thread NDJSON traces must be preprocessed into a single JSON file with per-thread arrays and compressed timestamps. Use the standard timebox preprocessor:

```
python3 preprocess_trace.py --input traces/raw/ --output traces/trace.json
```

### 6. RecvGuard::drop Timing

The `RecvGuard::drop` (rem decrement, line 1715) happens when the guard goes out of scope, which is AFTER `recv_ref` returns. This is still under the slot lock (the guard holds `MutexGuard<Slot>`). The RecvSuccess event should be emitted inside `recv_ref` before returning, capturing the pre-decrement state. The rem decrement is part of the spec's `RecvSuccess` action.

### 7. Close Sequence Split

`Sender::drop` performs two steps:
1. `num_tx.fetch_sub(1)` — atomic, no lock
2. `close_channel()` — acquires tail lock

For Family 1 validation, these MUST be separate events (SenderDrop + CloseChannel). If only one event is emitted, use SilentCloseChannel in the trace spec.
