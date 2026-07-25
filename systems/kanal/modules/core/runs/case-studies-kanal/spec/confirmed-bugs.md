# Confirmed Bug Report — kanal

## Summary
- Total findings reviewed: 9 (2 MC bugs, 5 code review findings, 2 code review style issues)
- Reproduced: 3
- Confirmed (code audit only): 0
- False positives: 1
- Documented/known: 1
- Filtered (style/defensive): 4

## Bug K-1: ReceiveFuture::drop push_front Exceeds Bounded Capacity

- **Source**: MC (MC_hunt_future_cancel.cfg, BFS, 5-state counterexample)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `future.rs:246-249`
- **Description**: When an async `ReceiveFuture` is dropped after a sender completed a direct handoff to its signal, the drop handler pushes data back to the channel queue via `push_front` WITHOUT checking if the queue is already at capacity. On a bounded channel, this causes `queue.len() > capacity`.
- **Trigger scenario**: (1) ReceiveFuture polled once → Pending (registered in wait_list). (2) Sender does direct handoff → signal state = UNLOCKED. (3) Another sender fills queue to capacity. (4) ReceiveFuture is dropped → push_front → queue overflow.
- **Root cause**: The developer added a capacity check (`if self.internal.capacity() == 0`) to decide WHETHER to push back to queue vs drop data, but did NOT check `queue.len() < capacity` before the actual push_front. This is a TOCTOU gap introduced in commit b6c0fb90 during async/sync unification.
- **Developer intent**: Comments at line 233-237 say "this is actually a bug in user code but we should handle it gracefully." The push_front was intended as a graceful recovery mechanism for cancel-unsafe futures. The capacity violation was not considered.
- **Reproduction test**: `repro/src/bin/test_k1_capacity_overflow.rs`
- **Reproduction result**: PASS (bug triggered deterministically)
- **Reproduction output**:
```
=== Bug K-1: ReceiveFuture::drop push_front exceeds bounded capacity ===

[1] ReceiveFuture polled → Pending (registered in wait_list)
[2] Sender did handoff: sent 100 to recv signal
[3] Sender filled queue: sent 200 to queue
[*] Queue length before drop: 1 (capacity: 1)
[4] Dropped ReceiveFuture (triggers push_front)
[*] Queue length after drop: 2 (capacity: 1)

*** BUG K-1 CONFIRMED ***
Queue length 2 exceeds declared capacity 1
Items received: [100, 200] (count: 2)
Expected max items in queue: 1
```
- **Reproduction method**: Level 0 (pure black-box). Manual Future polling with noop waker controls the exact sequence: poll recv once → sync send does handoff → sync send fills queue → drop recv future.
- **Impact**: Queue exceeds bounded channel's advertised capacity. Code that assumes `queue.len() <= capacity` may misbehave. Affects any `select!` or cancellation scenario on bounded channels.
- **Recommendation**: Add `if queue.len() < capacity` guard before `push_front` in `ReceiveFuture::drop`, or drop the data with a warning when the queue is full (consistent with the rendezvous path).

---

## Bug F2-2: SendManyFuture Error Path Silently Drops Data

- **Source**: Code Review (F2-2 from modeling brief)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `future.rs:486-495`
- **Description**: When the inner `SendFuture` inside `SendManyFuture` returns an error (channel closed) but there are still remaining elements in the VecDeque, the error result — which contains the in-flight element — is silently dropped. The loop continues and returns an error with a DIFFERENT element, losing the original one.
- **Trigger scenario**: (1) `send_many([1, 2, 3])` on bounded(1) channel. (2) Element 1 goes to queue, element 2 goes to signal in wait_list. (3) All receivers dropped → element 2's signal terminated. (4) Poll send_many → inner future returns `Err(SendError(2))`, but `elements=[3]` is not empty → error dropped → element 2 LOST. (5) Loop continues, sees `recv_count=0`, returns `Err(SendError(3))`.
- **Root cause**: In `SendManyFuture::poll` (lines 486-495), when `fut.poll(cx)` returns `Poll::Ready(res)` and `res` is an error, the code only returns the error if `this.elements.is_empty()`. Otherwise, the error is silently dropped. This was present in the original implementation (commit e61273e) and survived the "fix" in commit 87b352b.
- **Developer intent**: The developer intended to send all elements sequentially, reusing a single `SendFuture`. The fix in 87b352b restructured the code but did NOT fix the error handling: when the inner future fails and elements remain, the error is still dropped instead of being returned to the caller.
- **Reproduction test**: `repro/src/bin/test_f2_2_send_many_data_loss.rs`
- **Reproduction result**: PASS (bug triggered deterministically)
- **Reproduction output**:
```
=== Bug F2-2: SendManyFuture error path silently drops data ===

[*] Initial elements: [1, 2, 3]
[1] send_many polled → Pending
    Elements 1 → queue, 2 → signal (in wait_list)
[*] Queue length: 1 (element 1 in queue)
[2] Dropped receiver (terminates element 2's signal)
[3] send_many polled again
    Returned error with element: 3
    Remaining elements in VecDeque: []

*** BUG F2-2 CONFIRMED ***
Element 2 was silently lost!
  - Element 1: in channel queue (sent successfully)
  - Element 2: LOST (error Err(SendError(2)) was dropped internally)
  - Element 3: returned in error to caller
  Expected: Err(SendError(2)) with element 3 still in VecDeque
  Actual:   Err(SendError(3)) with element 2 gone
```
- **Reproduction method**: Level 0 (pure black-box). Manual Future polling: poll send_many once (elements 1→queue, 2→signal), drop receiver (terminates signal), poll again (error dropped, wrong element returned).
- **Impact**: Data loss on async `send_many` when channel closes mid-operation. The in-flight element is silently dropped, and the caller receives an error containing a different element. Affects any scenario where `send_many` is used with a channel that may close.
- **Recommendation**: When the inner `SendFuture` returns `Err(SendError(data))` and elements remain, immediately return the error to the caller (or push the data back into elements). Do not continue the loop.

---

## Bug F1-1: wait() After wait_timeout() Mishandles LOCKED_STARVATION State

- **Source**: Code Review (F1-1 from modeling brief)
- **Status**: REPRODUCED (Level 3 — minimal code modification)
- **Severity**: High (potential use-after-free)
- **Location**: `signal.rs:233-253` (wait), `signal.rs:256-282` (wait_timeout), `lib.rs:842-861` (send_timeout recovery), `lib.rs:1234-1248` (recv_timeout recovery)
- **Description**: When `send_timeout` or `recv_timeout` times out and the cancel attempt fails (counterpart already popped the signal), the recovery code calls `wait()` to block until the counterpart finishes. However, `wait()` only handles the case where the signal state is LOCKED (= 1). After `wait_timeout()`, the state is LOCKED_STARVATION (= 2). The `wait()` CAS expects LOCKED → LOCKED_STARVATION, but with state already LOCKED_STARVATION, the CAS fails with `Err(2)`, and `2 == UNLOCKED(usize::MAX)` evaluates to `false`. This causes `wait()` to return `false`, which the caller interprets as "channel closed." The sender/receiver reclaims data and returns, but the counterpart still holds the signal pointer and will eventually write to/read from it → **use-after-free**.
- **Trigger scenario**: (1) Sender calls `send_timeout(data, 10ms)` on rendezvous channel. No receiver waiting → signal pushed to wait_list. (2) Receiver arrives, pops sender's signal (under lock), releases lock, begins `read_data`. (3) Receiver is delayed >50μs between lock release and state swap in `read_data`. (4) Sender's `wait_timeout` fires (timeout). (5) Sender tries cancel → acquires lock, signal NOT in wait_list → cancel fails. (6) Sender calls `wait()` → state is LOCKED_STARVATION → CAS fails → returns false. (7) Sender returns `Err(Closed(data))` — reclaims data on a **live** channel. (8) Receiver finishes `read_data` → reads from freed signal → UAF.
- **Root cause**: `wait()` was designed to be called on signals in LOCKED state. The developers did not consider the scenario where `wait()` is called on a signal already in LOCKED_STARVATION state (set by a prior `wait_timeout()` call). The CAS at signal.rs:233 only handles `LOCKED → LOCKED_STARVATION`, not `LOCKED_STARVATION → LOCKED_STARVATION`. The failure path at line 252 (`Err(v) => v == UNLOCKED`) incorrectly treats LOCKED_STARVATION as a terminal failure.
- **Developer intent**: Commit dc47624 introduced the wait_timeout logic with LOCKED_STARVATION parking. The developers expected that if cancel fails, `wait()` would block until the counterpart completes. They assumed `wait()` would see LOCKED (not LOCKED_STARVATION) because they didn't account for the state being ALREADY set by `wait_timeout()`. No comments or tests address this interaction.
- **Reproduction test**: `repro/src/bin/test_f1_1_starvation_race.rs`
- **Reproduction result**: PASS (Level 3 — bug triggered 20/20 runs)
- **Reproduction output**:
```
=== Bug F1-1: wait() after wait_timeout() LOCKED_STARVATION race ===

Mode: Level 3 (delay injected in SyncSignal::read_data)

  Run 0: BUG — sender got Closed (data=0xdeadbeefcafebabe), receiver got 0xdeadbeefcafebabe
  Run 1: BUG — sender got Closed (data=0xdeadbeefcafebabe), receiver got 0xdeadbeefcafebabe
  Run 2: BUG — sender got Closed (data=0xdeadbeefcafebabe), receiver got 0xdeadbeefcafebabe
  ...
  Run 19: BUG — sender got Closed (data=0xdeadbeefcafebabe), receiver got 0xdeadbeefcafebabe

=== Results (20 runs) ===
Sender got data back (timeout/closed): 20
Receiver got a value: 20
Double deliveries: 0
Spurious 'Closed' errors: 20
Data corruptions: 0

*** BUG F1-1 CONFIRMED (Level 3) ***
  wait() returned false due to LOCKED_STARVATION CAS mismatch
  → sender interpreted it as channel-closed on live channel
```
- **Reproduction method**: Level 3 (minimal code modification). A 100ms `sleep` was injected in `SyncSignal::read_data` (via Cargo feature `repro-f1-1`) between popping the signal and swapping state to UNLOCKED. This widens the race window so the sender's 10ms timeout fires reliably. The sender gets a spurious "Closed" error and reclaims data, while the receiver ALSO reads the same data from the signal — both own the value. Level 0 stress test (5 rounds × 10s, ~350K timeouts) did not trigger the bug due to the narrow ~50μs race window.
- **Modification**: `signal.rs:read_data` — added `#[cfg(feature = "repro-f1-1")] std::thread::sleep(100ms)` before `ptr.read()`. This delay is between the lock release (when the signal was popped from wait_list) and the state swap to UNLOCKED. The delay only widens the existing race window; it does not alter the protocol logic.
- **Impact**: Sender gets spurious "Closed" error on a live channel, reclaims data, but counterpart still holds signal pointer → use-after-free. For `u64` and similar Copy types, this manifests as double delivery (sender and receiver both have the value). For heap-allocated types (String, Vec), this is a double-free. Affects `send_timeout` and `recv_timeout` under any scheduling delay >50μs between signal pop and data transfer completion.
- **Recommendation**: Fix `wait()` to handle the LOCKED_STARVATION state. When `wait()` is called after `wait_timeout()`, the state is already LOCKED_STARVATION. The CAS should handle this by entering the park loop directly (state is already LOCKED_STARVATION, no transition needed). Alternatively, `wait_timeout()` could reset state back to LOCKED on timeout failure before the caller invokes `wait()`.

---

## Finding K-2: ReceiveFuture::drop on Rendezvous Channel Loses Data

- **Source**: MC (MC_hunt_future_rendezvous.cfg, BFS, 6-state counterexample)
- **Status**: KNOWN/DOCUMENTED — no reproduction required
- **Severity**: Low
- **Location**: `future.rs:239-244`
- **Description**: When a `ReceiveFuture` is dropped on a rendezvous channel (capacity=0) after the sender completed the handoff, the data is silently discarded via `drop_data()`. The sender returned `Ok(())`, so from its perspective the send succeeded, but no receiver ever processes the value.
- **Developer evidence**: Code comment at line 233-236: "this is actually a bug in user code but we should handle it gracefully." The library explicitly documents that it is not cancel-safe. This is a deliberate design choice.
- **Classification**: Known design limitation. Not a new bug.

---

## Finding F3-1: Close Protocol Interleaving — FALSE POSITIVE

- **Source**: Code Review (F3-1 from modeling brief)
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `internal.rs:288-306`
- **Description**: The modeling brief suggested that interleaving of `DropSender + DropReceiver + Close` with pending signals could cause hanging signals or double-free.
- **Safeguard**: All ref_count, send_count, recv_count operations, signal termination, and queue clearing happen under the same mutex (`acquire_internal`). The `dec_ref_count` function atomically (under lock) decrements the count, terminates signals if needed, and checks if ref_count reaches 0. No interleaving is possible because all operations are serialized by the mutex. MC confirmed: 17,142 BFS states + 1.58B simulation states — no violations of NoDoubleFree, NoHangingSignals, CloseTerminatesAll, HalfCloseDetection, or RefCountConsistency.
- **Classification**: False positive. The single-mutex design eliminates the theorized race.

---

## Filtered Findings (Not Bugs)

The following code review findings (C1-C4 from modeling brief) were filtered as style/defensive coding issues, not logic bugs:

- **C1**: `SendFuture::drop` redundant `need_drop = true` at line 81 — dead code, no impact
- **C2**: `AsyncSignal::cancel` is a no-op with misleading comment — misleading but correct
- **C3**: `drain_into` returns `required_cap` as "number received" — naming issue
- **C4**: `unsafe impl<T> Sync for Internal<T>` has no `T: Send` bound — potential soundness issue but requires `T: !Send`, which is atypical for channel payloads. Not a protocol-level bug.

---

## Reproduction Infrastructure

All reproduction tests are in `case-studies/kanal/repro/`:

```
repro/
├── Cargo.toml
└── src/bin/
    ├── test_k1_capacity_overflow.rs      — K-1: deterministic, Level 0
    ├── test_f2_2_send_many_data_loss.rs  — F2-2: deterministic, Level 0
    └── test_f1_1_starvation_race.rs      — F1-1: Level 0 stress + Level 3 delay
```

Build and run:
```bash
cd case-studies/kanal/repro

# K-1: capacity overflow (deterministic)
cargo run --release --bin test_k1_capacity_overflow

# F2-2: send_many data loss (deterministic)
cargo run --release --bin test_f2_2_send_many_data_loss

# F1-1: starvation race — Level 0 stress test (unlikely to trigger)
cargo run --release --bin test_f1_1_starvation_race

# F1-1: starvation race — Level 3 with injected delay (deterministic)
# Requires adding "repro-f1-1 = []" feature to kanal's Cargo.toml
# and "#[cfg(feature = "repro-f1-1")] sleep(100ms)" in signal.rs:read_data
cargo run --release --features repro-f1-1 --bin test_f1_1_starvation_race
```
