# Instrumentation Guide — tokio::sync::broadcast Trace Harness

This document explains where each spec action is instrumented in
`tokio/src/sync/broadcast.rs` and how to adjust the harness when trace
validation surfaces a mismatch. The harness produces NDJSON traces that map
1:1 to the spec actions in `base.tla`.

## Layout

| Path (after `apply.sh`) | Purpose |
|--|--|
| `artifact/tokio/tokio/src/sync/tla_trace.rs` | Trace module: writer, rdtsc, actor scope, JSON helpers |
| `artifact/tokio/tokio/src/sync/broadcast.rs` | Instrumented broadcast (patched) |
| `artifact/tokio/tokio/src/sync/mod.rs` | Adds `pub mod tla_trace;` |
| `artifact/tokio/tokio/tests/tla_harness.rs` | 5 trace scenarios (`#[test]` functions) |
| `harness/patches/instrumentation.patch` | The instrumentation diff (idempotent; `apply.sh` re-applies it) |
| `harness/preprocess.py` | Merges raw NDJSON into `{ threads, events }` for TLC |

## Core idea

- Each `Sender`/`Receiver` is a **logical actor** (`s1`, `s2`, `r1`, `r2`,
  `r3`). Actor identity is set via `tla::ActorGuard` (a thread-local RAII guard
  scoped around each operation). Every emit call reads the current actor from
  the thread-local.
- Each emit produces one NDJSON line tagged `"tag":"trace"` with `name`,
  `thread` (= actor id), `start`, `end`, `state`, plus action-specific fields.
- Timestamps are `rdtsc()` (x86_64) or `clock_gettime(MONOTONIC)` fallback.
- Per-action-instance `start` and `end` capture a tight `[start, end]` window
  around the operation. Compressed to dense integers by `preprocess.py`.

## Action-to-Code Mapping

All line numbers refer to the **post-patch** `broadcast.rs`. The patch is in
`harness/patches/instrumentation.patch` and is applied idempotently.

| Spec action | Function | Trigger |
|---|---|---|
| `Send_AcquireTail` | `Sender::send` | After `tail.lock()` returns |
| `Send_BumpPos` | `Sender::send` | After `tail.pos = tail.pos.wrapping_add(1)` |
| `Send_LockSlot` | `Sender::send` | After `buffer[idx].lock()` returns |
| `Send_WriteSlot` | `Sender::send` | After `slot.val = Some(value)` |
| `Send_DropSlot` | `Sender::send` | After `drop(slot)` |
| `Send_NotifyRx_Enter` | `Sender::send` | Before `notify_rx(tail, …)` |
| `NotifyRx_DrainStep_Take` | `Shared::notify_rx` | After `queued.store(false, Release)` for each popped waiter |
| `NotifyRx_DropTail` | `Shared::notify_rx` | After `drop(tail)` (inner and final) |
| `NotifyRx_WakeOne` | `Shared::notify_rx` | Per extracted waiter, before `wakers.wake_all()` |
| `NotifyRx_Finish` | `Shared::notify_rx` | After all wakers woken |
| `Subscribe` | `new_receiver` | After `drop(tail)` |
| `Recv_PollEnter` | `Recv::poll` | Before `recv_ref(...)` |
| `Recv_LockSlotFirst` | `Receiver::recv_ref` | After `buffer[idx].lock()` returns |
| `Recv_HitFastPath` | `Receiver::recv_ref` | After `self.next.wrapping_add(1)` (fast path) |
| `Recv_DropSlotForTail` | `Receiver::recv_ref` | After `drop(slot)` (slow path) |
| `Recv_LockTail` | `Receiver::recv_ref` | After `tail.lock()` returns |
| `Recv_RelockSlot` | `Receiver::recv_ref` | After slot relocked |
| `Recv_RecheckMatch` | `Receiver::recv_ref` | When recheck succeeds (slot.pos == self.next) |
| `Recv_EmptyClosed` | `Receiver::recv_ref` | Before returning `Err(Closed)` |
| `Recv_ParkAsWaiter` | `Receiver::recv_ref` | Before returning `Err(Empty)`; waiter registered |
| `Recv_LaggedFastForward` | `Receiver::recv_ref` | At lagged catch-up (missed=0 or missed>0) |
| `RecvDrop_Begin` | `Drop for Recv` | At function entry |
| `RecvDrop_LoadQueued_Acquire` | `Drop for Recv` | After `queued.load(Acquire)` |
| `RecvDrop_LockTail_Reread` | `Drop for Recv` | After `tail.lock()` |
| `RecvDrop_RereadAndUnlink` | `Drop for Recv` | After `tail.waiters.remove(...)` |
| `RecvDrop_FinishIdle` | `Drop for Recv` | At function return |
| `RxDrop_Begin` | `Drop for Receiver` | At function entry |
| `RxDrop_LockTailDecCnt` | `Drop for Receiver` | After `tail.rx_cnt -= 1` (and possibly `tail.closed = true`) |
| `RxDrop_DropTail` | `Drop for Receiver` | After `drop(tail)` |
| `RxDrop_DrainStep` | `Drop for Receiver` | After each `recv_ref(None)` in the drain loop |
| `RxDrop_Finish` | `Drop for Receiver` | At function return |
| `TxClone` | `Clone for Sender` | After `num_tx.fetch_add(1)` |
| `TxDrop_FetchSub` | `Drop for Sender` | After `num_tx.fetch_sub(1, AcqRel)` |
| `TxDrop_CloseChannelEnter` | `Sender::close_channel` | After `tail.closed = true` |
| `TxDrop_NotifyEnter` | `Sender::close_channel` | Before `notify_rx(tail, …)` |
| `TxDrop_Finish` | `Drop for Sender` | At function return when `wasLast == false` |
| `TxDrop_AfterClose` | `Drop for Sender` | At function return when `wasLast == true` |

`Send_NoReceiversReturn` is intentionally **not** emitted — it has no wrapper
in `Trace.tla`'s `MatchEvent` dispatch table, so the implementation's
"return Err(SendError) on rx_cnt == 0" is silent in the trace.

## State capture

Each emit captures a snapshot of the relevant shared state (per
`instrumentation-spec.md` §1.2). For events that hold the tail mutex, the
snapshot is taken under that lock so `tailPos`, `tailRxCnt`, and `tailClosed`
are coherent. For events outside any lock, the snapshot is best-effort: 0/false
placeholders are emitted for fields the Trace.tla wrapper does not consume.

| Field | Where it's coherent | Where it's a placeholder |
|---|---|---|
| `tailPos`, `tailRxCnt`, `tailClosed` | All `Send_*` (under tail lock), `Subscribe`, `RxDrop_LockTailDecCnt`, `RecvDrop_LockTail_Reread`, `Recv_LockTail`, `Recv_RelockSlot`, `Recv_*Match/Park/Lagged`, `TxDrop_*` | `RecvDrop_Begin`, `RecvDrop_LoadQueued_Acquire`, `Recv_PollEnter`, drain steps, `Notify*` (after `drop(tail)`) |
| `slotPos[i]`, `slotRem`, `slotVal` | `Send_WriteSlot` (post-write, slot lock held) | Other Send_* events emit only `idx` |
| `numTx` | All Sender-local events (`Acquire` load before emit) | `Notify*` (zero placeholder is acceptable since wrapper does not check) |
| `tailWaiterCount` | Always 0 (the linked list has no `len()` accessor) | All events |
| `recvWaiterQueued`, `rxNext` | `Recv*`/`RxDrop*`/`RecvDrop*` events emit `queued` and `next` | `Notify*` (zero placeholder) |

If the Phase 3 agent finds a wrapper checking a field that's a placeholder
here, the fix is one of:
1. Move the capture into a code section where it's coherent (typically under
   the relevant lock).
2. Drop the wrapper's check on that field (it's spec/state divergence not
   captured by trace).
3. Use a "weak" wrapper variant (see `concurrent-timebox-guide.md`).

## How to adjust instrumentation

### Add a new field to an existing event

1. Open `tokio/src/sync/broadcast.rs` and locate the `tla::emit_*(...)` call
   site for the target action.
2. Append a new `","fieldName":<value>` fragment to the `extra` string passed
   to `emit_send` / `emit_recv` / `emit_generic`. (Use `tla::esc(...)` for
   strings.) Example:
   ```rust
   let extra = format!(
       r#","idx":{},"newField":{}"#,
       idx, new_value,
   );
   ```
3. Re-run `bash apply.sh` (which regenerates the patch from the artifact) or
   re-apply manually after editing.

### Move a capture point (before <-> after the action)

The `[start, end]` interval is whatever you bracket with `tla::now()`. To make
the capture cover *more* code, move `t_start = tla::now()` earlier or `t_end =
tla::now()` later. To tighten the interval, do the opposite. The state
snapshot lives wherever you read the shared variables; it doesn't have to be
inside the interval (per timebox methodology, it usually shouldn't be).

### Add a new event type

1. Pick the right emit helper (`emit_send`, `emit_recv`, `emit_generic`).
2. Add a `tla::emit_*(name, t0, t1, &actor, &extra, ...)` call at the trigger
   point.
3. Add a corresponding wrapper `W_NewEvent` to `Trace.tla` and an entry in the
   `MatchEvent` dispatch.

### Change actor scoping for a scenario

The scenario file `tokio/tests/tla_harness.rs` wraps each call in
`{ let _g = tla::ActorGuard::new("rN".to_string()); … }`. If you reorder
scopes or introduce new actors:
- The set of `thread` values in the trace will change.
- Update `Trace.cfg`'s `Receiver` / `Sender` constants if a new actor name
  appears.

### Rebuild + re-run

```bash
bash .specula-output/harness/run.sh
```

This:
1. Resets `broadcast.rs` and `mod.rs` to git HEAD, then re-applies
   `instrumentation.patch`.
2. Copies `tla_trace.rs` and `tla_harness.rs` into the artifact.
3. Builds and runs the 5 scenario tests with `cargo test --test tla_harness`.
4. Preprocesses each `<scenario>.ndjson` into
   `<scenario>.processed.ndjson` (single-line JSON of
   `{ threads, events }`).

To run trace validation against a specific scenario:

```bash
cd .specula-output/spec
JSON=../traces/park_and_wake.processed.ndjson tlc Trace.tla -config Trace.cfg
```

(or via the `mcp__tla-trace-debugger__run_trace_validation` tool).

## Known harness/spec adjustments already made

While bringing the trace into alignment with `Trace.tla`, three small spec
edits were necessary (and are committed alongside the harness):

1. `Trace.tla`: `TraceJson == ndJsonDeserialize(JsonFile)[1]`
   — the preprocessor emits one JSON object per file; `ndJsonDeserialize`
   returns a sequence, so we index `[1]`.
2. `Trace.tla`: `TraceThreads` converts the JSON `threads` array (sequence)
   into a TLA+ set via comprehension.
3. `Trace.tla`: `TraceInit` pins `rxAlive["r1"] = TRUE` and
   `txAlive["s1"] = TRUE` so the existential in `base!Init` does not fork
   over actor identities — all scenarios bootstrap `r1` and `s1` via
   `broadcast::channel(...)`.
4. `Trace.cfg`: `Receiver` / `Sender` / `Value` constants now use TLA+
   strings (e.g. `{"r1", "r2", "r3"}`) instead of model values, so the
   string-typed `thread` field in the trace matches them.
5. `Trace.tla`: action wrappers that validate state changed by their action
   now use **primed** variables (e.g. `recvWaiterQueued'[r]`,
   `rxNext'[r] = ev.nextAfter`) — they validate the post-state captured in
   the trace, not the pre-state.

If the Phase 3 agent encounters more wrapper / spec issues, the same pattern
applies: post-state checks in wrappers should use primed variables.

## Trace coverage

Across the 5 scenarios:

| Scenario | Lines | Threads | Triggers |
|---|---|---|---|
| `subscribe_while_send` | 80 | 6 | Subscribe (with `reopened=false`), HitFastPath, RxDrop, TxClone (none — single sender), TxDrop_AfterClose |
| `lagged_receiver` | 55 | 4 | LaggedFastForward (`missed > 0`), HitFastPath after lag, RxDrop_DrainStep |
| `park_and_wake` | 32 | 4 | ParkAsWaiter, NotifyRx_DrainStep_Take, NotifyRx_WakeOne, RecvDrop with `loaded=false` (post-wake) |
| `close_with_parked_receiver` | 27 | 3 | TxDrop_CloseChannelEnter (last-sender path), Recv_EmptyClosed, RecvDrop with `loaded=true` |
| `clone_drop_senders` | 55 | 6 | TxClone, TxDrop_FetchSub with `wasLast=false` then `wasLast=true` |

Five event types declared in the spec are not covered by these traces and
will need additional scenarios if they need validation in this round:

- `WeakSender::upgrade` paths (`weakPC`) — out of scope per
  `instrumentation-spec.md` §3.7.
- `Recv_HitFastPath` *during a parked wake* — covered transitively by
  `park_and_wake` (the post-wake re-poll hits fast path).
- `Recv_RecheckMatch` — emitted only when a slot recheck succeeds *and* the
  slot is no longer empty. Add a scenario where a slow receiver loses the tail
  lock to a sender mid-recheck if explicit coverage is needed.
