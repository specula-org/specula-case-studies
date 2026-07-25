# Instrumentation Spec — tokio::sync::broadcast

This document specifies how to instrument `tokio/src/sync/broadcast.rs` to produce traces consumable by `Trace.tla`. The trace format is per-thread (per-task) timebox NDJSON, preprocessed into `{ threads, events }` JSON for TLC.

## 1. Trace Event Schema

### 1.1 Event Envelope

Every trace event is a JSON object with these common fields:

| Field | Type | Description |
|---|---|---|
| `name` | string | Spec action name (1:1 with base.tla actions) |
| `thread` | string | Task / thread identifier (Receiver or Sender id, e.g. `"r1"`, `"s1"`) |
| `start` | u64 | Compressed timestamp at event start (rdtsc-derived) |
| `end` | u64 | Compressed timestamp at event end |
| `state` | object | Snapshot of relevant shared state (see §1.2) |

### 1.2 State Snapshot Fields

`state` is the captured snapshot of shared state at the **end** of the event (post-action). Capture only what the action visibly modified or read; do not capture unrelated state.

| Spec variable | Snapshot field | Capture as |
|---|---|---|
| `tailPos` | `state.tailPos` | `u64` (taken from `tail.pos` under tail lock) |
| `tailRxCnt` | `state.tailRxCnt` | `usize` |
| `tailClosed` | `state.tailClosed` | `bool` |
| `tailWaiters` | `state.tailWaiterCount` | usize: `tail.waiters.len()` if exposable; else omit |
| `slotPos[idx]` | `state.slotPos` | `u64` (only events that touch slot idx) |
| `slotRem[idx]` | `state.slotRem` | `usize` |
| `slotVal[idx]` | `state.slotVal` | string ("Some" or "None") |
| `numTx` | `state.numTx` | `usize` (Acquire load) |
| `recvWaiterQueued[r]` | `state.queued` | `bool` (only Recv*/RecvDrop* events) |
| `rxNext[r]` | `state.next` | `u64` (only Recv*/RxDrop* events) |

### 1.3 Action-Specific Fields

| Spec action | Extra fields |
|---|---|
| Send_AcquireTail | `sender`: thread id |
| Send_BumpPos | `sender`, `value`, `pos` (pre-bump), `idx` |
| Send_LockSlot | `sender`, `idx` |
| Send_WriteSlot | `sender`, `idx`, `pos`, `value`, `rem` |
| Send_DropSlot | `sender`, `idx` |
| Send_NotifyRx_Enter | `sender` |
| NotifyRx_DrainStep_Take | `receiver` (the woken waiter), `triggeredBy` |
| NotifyRx_DropTail | `triggeredBy` |
| NotifyRx_WakeOne | `receiver`, `triggeredBy` |
| NotifyRx_Finish | `triggeredBy` |
| Subscribe | `receiver` (newly alive), `next` (assigned cursor), `reopened`: bool |
| Recv_PollEnter | `receiver` |
| Recv_LockSlotFirst | `receiver`, `idx` |
| Recv_HitFastPath | `receiver`, `idx`, `value`, `nextAfter` |
| Recv_DropSlotForTail | `receiver`, `idx` |
| Recv_LockTail | `receiver` |
| Recv_RelockSlot | `receiver`, `idx` |
| Recv_RecheckMatch | `receiver`, `idx`, `value`, `nextAfter` |
| Recv_EmptyClosed | `receiver`, `idx` |
| Recv_ParkAsWaiter | `receiver`, `idx`, `parkedAtPos` |
| Recv_LaggedFastForward | `receiver`, `idx`, `missed`, `nextAfter` |
| RecvDrop_Begin | `receiver` |
| RecvDrop_LoadQueued_Acquire | `receiver`, `loaded`: bool |
| RecvDrop_LockTail_Reread | `receiver` |
| RecvDrop_RereadAndUnlink | `receiver`, `wasQueued`: bool |
| RecvDrop_FinishIdle | `receiver` |
| RxDrop_Begin | `receiver` |
| RxDrop_LockTailDecCnt | `receiver`, `rxCntAfter`, `closedAfter`, `until` |
| RxDrop_DropTail | `receiver` |
| RxDrop_DrainStep | `receiver`, `idx`, `kind` ("hit"/"lag"), `nextAfter` |
| RxDrop_Finish | `receiver` |
| TxDrop_FetchSub | `sender`, `numTxAfter`, `wasLast`: bool |
| TxDrop_CloseChannelEnter | `sender` |
| TxDrop_NotifyEnter | `sender` |
| TxDrop_Finish | `sender` |
| TxDrop_AfterClose | `sender` |
| TxClone | `sender` (newly cloned), `numTxAfter` |

## 2. Action-to-Code Mapping

For each spec action: code location, trigger point, event fields. All line numbers refer to `tokio/src/sync/broadcast.rs` (current branch HEAD).

### Send path (`Sender::send`, broadcast.rs:631-667)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `Send_AcquireTail` | line 632 | **after** `tail.lock()` returns | `sender`, snapshot of tail.{pos,rx_cnt,closed} |
| `Send_NoReceiversReturn` | line 635 | **before** returning `Err(SendError(value))` | `sender` |
| `Send_BumpPos` | line 644 | **after** `tail.pos = tail.pos.wrapping_add(1)` | `sender`, `value`, `pos` (the value bumped from), `idx` |
| `Send_LockSlot` | line 647 | **after** `buffer[idx].lock()` returns | `sender`, `idx` |
| `Send_WriteSlot` | line 656 | **after** `slot.val = Some(value)` | `sender`, `idx`, `pos`, `value`, `rem` |
| `Send_DropSlot` | line 659 | **after** `drop(slot)` | `sender`, `idx` |
| `Send_NotifyRx_Enter` | line 664 | **before** `notify_rx(tail)` is called | `sender` |

Tail mutex is held continuously through `Send_AcquireTail` ... `Send_NotifyRx_Enter`. Slot mutex is held only between `Send_LockSlot` and `Send_DropSlot`.

### `Shared::notify_rx` (broadcast.rs:992-1056)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `NotifyRx_DrainStep_Take` | lines 1012-1029 | **after** `queued.store(false, Release)` for each popped waiter | `receiver` (popped waiter), `triggeredBy` ("send_*"/"close_*"/"rx_drop_*") |
| `NotifyRx_DropTail` | line 1038 (inner) or 1051 (outer) | **after** `drop(tail)` | `triggeredBy` |
| `NotifyRx_WakeOne` | line 1045 (inner) or 1054 (outer) | **after** each `waker.wake_by_ref()` (instrument `WakeList::wake_all` with a per-iteration callback) | `receiver`, `triggeredBy` |
| `NotifyRx_Finish` | end of function | **after** all wakers woken and notify_rx returns | `triggeredBy` |

**Notes**:
- Real code calls `wakers.wake_all()` as a single op; instrumentation must hook into the per-element loop inside `WakeList::wake_all` so each `NotifyRx_WakeOne` is its own event.
- The drain may loop (if more than `WakeList` capacity waiters): subsequent iterations re-acquire tail (line 1048). Each iteration produces another set of `NotifyRx_DrainStep_Take` events followed by `NotifyRx_DropTail` and `NotifyRx_WakeOne`.

### Subscribe / new_receiver (broadcast.rs:692-695, 924-942, 1391-1394)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `Subscribe` | line 939 | **after** `drop(tail)` in `new_receiver` | `receiver` (newly alive), `next`, `reopened` (true if rx_cnt was 0 pre-call, line 929) |

### `Receiver::recv_ref` (broadcast.rs:1222-1328)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `Recv_PollEnter` | broadcast.rs:1614 (Recv::poll, just before recv_ref call) | **before** `receiver.recv_ref(...)` | `receiver` |
| `Recv_LockSlotFirst` | line 1230 | **after** `buffer[idx].lock()` returns | `receiver`, `idx` |
| `Recv_HitFastPath` | line 1325 | **after** `self.next = self.next.wrapping_add(1)` AND **after** RecvGuard drop (line 1715) — single composite event, since the guard drop is implicit in the same lexical scope | `receiver`, `idx`, `value`, `nextAfter` |
| `Recv_DropSlotForTail` | line 1240 | **after** `drop(slot)` | `receiver`, `idx` |
| `Recv_LockTail` | line 1244 | **after** `tail.lock()` returns | `receiver` |
| `Recv_RelockSlot` | line 1247 | **after** slot relocked | `receiver`, `idx` |
| `Recv_RecheckMatch` | line 1252 (false branch) | **after** RecvGuard drop completes | `receiver`, `idx`, `value`, `nextAfter` |
| `Recv_EmptyClosed` | line 1260 | **before** `return Err(TryRecvError::Closed)` | `receiver`, `idx` |
| `Recv_ParkAsWaiter` | line 1298 | **before** `return Err(TryRecvError::Empty)` | `receiver`, `idx`, `parkedAtPos` (= tail.pos at park time) |
| `Recv_LaggedFastForward` | line 1316 (missed=0) or line 1321 | **before** return | `receiver`, `idx`, `missed`, `nextAfter` |

### `Recv::drop` (broadcast.rs:1625-1663)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `RecvDrop_Begin` | line 1626 | **at function entry** | `receiver` |
| `RecvDrop_LoadQueued_Acquire` | line 1633 | **after** `load(Acquire)` | `receiver`, `loaded` (bool) |
| `RecvDrop_LockTail_Reread` | line 1641 | **after** `tail.lock()` returns | `receiver` |
| `RecvDrop_RereadAndUnlink` | lines 1645-1660 | **after** `tail.waiters.remove(...)` (or after the conditional skip) | `receiver`, `wasQueued` |
| `RecvDrop_FinishIdle` | end of fn | **at function return** | `receiver` |

**Note**: PR #6298 — the load at line 1633 is the load-bearing Acquire. Trace must capture `loaded` so `RecvDrop_LoadQueued_Acquire` can validate the spec branch (short-circuit vs slow path).

### `Receiver::Drop` (broadcast.rs:1548-1574)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `RxDrop_Begin` | line 1549 | **at function entry** | `receiver` |
| `RxDrop_LockTailDecCnt` | line 1559 | **after** `tail.closed = true` (or skipped if remaining_rx>0) | `receiver`, `rxCntAfter`, `closedAfter`, `until` |
| `RxDrop_DropTail` | line 1561 | **after** `drop(tail)` | `receiver` |
| `RxDrop_DrainStep` | inside loop body, lines 1564-1572 | **after** each `recv_ref(None)` call | `receiver`, `idx`, `kind` ("hit" if Ok, "lag" if Lagged), `nextAfter` |
| `RxDrop_Finish` | line 1574 (loop exit) | **at function return** | `receiver` |

**Note**: PR #3434 changed the loop condition from `!=` to `<`. Modular `<` here is a wrapping comparison on u64; in our spec we approximate with `rxNext /= rxDropUntil`, accepting bounded-arithmetic divergence (Family 3 — covered in earlier round).

### `Sender::Drop` and `Sender::clone` (broadcast.rs:1058-1073)

| Spec action | Location | Trigger | Event fields |
|---|---|---|---|
| `TxClone` | line 1063 | **after** `num_tx.fetch_add(1, Relaxed)` | `sender` (newly cloned), `numTxAfter` |
| `TxDrop_FetchSub` | line 1069 | **after** `num_tx.fetch_sub(1, AcqRel)` | `sender`, `numTxAfter`, `wasLast` |
| `TxDrop_CloseChannelEnter` | broadcast.rs:907 (close_channel) | **after** `tail.closed = true` | `sender` |
| `TxDrop_NotifyEnter` | broadcast.rs:909 | **before** `notify_rx(tail)` | `sender` |
| `TxDrop_Finish` | broadcast.rs:1072 (post-fn end, !wasLast) | **at function return** | `sender` |
| `TxDrop_AfterClose` | broadcast.rs:1072 (wasLast, after close returned) | **at function return** | `sender` |

## 3. Special Considerations

### 3.1 Per-task interleaving

Tokio's `broadcast` is consumed from async tasks running on the runtime. Each task is a distinct "thread" for tracing purposes. The harness must:

1. Map each task to a stable id (e.g. via `task::id()` or an explicit `task_local!` slot).
2. Buffer per-task events into a per-task ring; flush at task drop or test end.
3. Preprocess raw NDJSON into `{ threads, events: { tid -> [...] } }` form before TLC reads it.

### 3.2 Timestamp compression

Use `rdtsc` (or `Instant::now().elapsed_nanos()`) for `start`/`end`. Compress raw values into dense integers via the standard preprocessor (see `harness-generation/references/concurrent-timebox-guide.md`):

1. Collect all start/end values.
2. Sort, deduplicate, build a `raw -> dense` map.
3. Rewrite all events using dense ids.

### 3.3 State capture timing

Capture state **outside** the `[start, end]` interval — i.e. take the snapshot immediately after the action's last write completes, before `end` is timestamped, OR before the action's first read, before `start` is timestamped. This keeps intervals tight.

For events that take or release the tail mutex, snapshot **under the lock**, just before the lock is released or just after it is taken (still under the same critical section).

### 3.4 Bootstrap state

`channel(N)` constructs the channel with one Sender and one Receiver, both alive. The trace's first events should reflect this. The trace harness should not emit events for the construction itself; instead, `TraceInit` mirrors `Init` (one alive `Sender` and `Receiver`).

If the test uses `Sender::new(N)` (no initial receiver), the harness should emit a single bootstrap event setting `tailRxCnt = 0`, `tailClosed = true`, `numTx = 1` — but for this round, restrict to the `channel(N)` constructor.

### 3.5 Memory ordering capture (Family 4)

The Acquire-load at `broadcast.rs:1633` is the most subtle site. Capture the *value loaded* in the trace event (`RecvDrop_LoadQueued_Acquire.loaded`). When TLC replays this event, the spec's branch (`short-circuit` vs `slow path`) must match the captured `loaded` value.

This is one place where a buggy build could be detected: if the implementation downgrades the ordering and produces a stale `false`, the trace would show `loaded = false` but spec state would still have `recvWaiterQueued[r] = true`, exposing the bug.

### 3.6 Concurrent receivers / senders

Tokio broadcast is heavily concurrent. The `ViablePIDs` machinery in `Trace.tla` handles concurrent events via interval comparison; do not artificially serialize tasks. Tighter intervals = less branching. Place `start` immediately before the action's first lock acquire / atomic op, and `end` immediately after the last write to instrumented state.

### 3.7 Out-of-scope (do not instrument)

- `Sender::len`, `Sender::is_empty` (diagnostic, not on correctness path).
- `Receiver::len`, `Receiver::is_empty` (likewise).
- `WeakSender::*` paths beyond `TxClone` (Family 4 wraps `num_weak_tx` are not modeled).
- `Sender::closed()` / `notify_last_rx_drop` machinery (modeled via spec invariants only — `notify::Notify` is not instrumented as a separate trace).
- `Sender::strong_count`, `weak_count`, `same_channel`, `receiver_count` (read-only getters).

## 4. Validation Quick Checklist

After producing a trace and running `Trace.cfg`:

- `TraceFullyConsumed` should hold (all events consumed; no thread stuck).
- `TraceSafety` invariants should hold on every recorded execution.
- A `pc` cursor that fails to advance for one thread indicates either a missing spec action wrapper, a mismatched event name, or a state divergence between trace and spec — diagnose by comparing the failing event's captured state against `slotPos`/`slotRem`/`tailPos` etc. in the TLC error trace.

## 5. Related References

- **Modeling Brief**: `.specula-output/modeling-brief.md`
- **Base Spec**: `spec/base.tla`
- **MC Spec**: `spec/MC.tla` (+ `MC_hunt_F1`, `MC_hunt_F2`, `MC_hunt_F4`, `MC_hunt_F5`)
- **Trace Spec**: `spec/Trace.tla`
- **Source**: `artifact/tokio/tokio/src/sync/broadcast.rs`
