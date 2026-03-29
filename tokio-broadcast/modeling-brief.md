# Modeling Brief: tokio broadcast channel

## 1. System Overview

- **System**: tokio broadcast channel — bounded MPMC broadcast queue from the tokio async runtime
- **Language**: Rust, ~1759 LOC in `tokio/src/sync/broadcast.rs`
- **Protocol**: Power-of-two ring buffer with per-slot Mutex, global tail Mutex, intrusive waiter linked list
- **Key architectural choices**:
  - Ring buffer indexed by `pos & mask` where mask = capacity - 1 (power of two)
  - `tail.pos` (u64) monotonically increments via `wrapping_add(1)` per send
  - Per-slot `rem` (AtomicUsize) tracks remaining receivers; last decrementer drops the value
  - Channel closure tracked in two places: `tail.closed` (mutex-guarded) and `num_tx` (atomic)
  - Waiter linked list moved to separate `GuardedLinkedList` during notification to prevent re-registration loops
  - Values cloned on demand per receiver under slot Mutex (changed from RwLock after RUSTSEC-2025-0023)
- **Concurrency model**: Multi-producer (Sender is Clone + Send + Sync), multi-consumer (each Receiver is single-owner). Slot access serialized by per-slot Mutex. Tail access serialized by global Mutex. Waiter management under tail lock.

## 2. Bug Families

### Family 1: Channel Close Lifecycle (HIGH)

**Mechanism**: Channel closure state is tracked by multiple flags (`tail.closed`, `num_tx`, historically per-slot closed bit). Interactions between close, subscribe/resubscribe, and recv create windows where the close signal is lost, misrepresented, or the channel is incorrectly re-opened.

**Evidence**:
- Historical: `a8195848` (#2425) — close sentinel `None` overwrote the oldest buffer slot, causing spurious `Lagged` on capacity-1 channels
- Historical: `9d9488db` (#4814) — receiver created after close hung forever; slot-level closed flag was inconsistent with channel-level flag
- Historical: `6d1ae628` (#7629) — `Sender::new()` left `tail.closed = false` with 0 receivers, breaking `closed()` future
- Code analysis: `is_closed()` (line 1361) reads `num_tx == 0` while `recv_ref` (line 1259) reads `tail.closed` — observable window where `is_closed()` returns true but `try_recv()` returns `Empty`
- Code analysis: `new_receiver` (line 929-934) re-opens channel (`tail.closed = false`) when `rx_cnt == 0` — designed for subscribe-after-all-receivers-dropped, but introduces state transitions that interact with sender drop

**Affected code paths**:
- `Sender::drop` → `close_channel` (lines 1067-1073, 905-910)
- `Receiver::drop` → sets `tail.closed = true` when last rx (lines 1548-1559)
- `new_receiver` → re-opens channel (lines 924-942)
- `recv_ref` → checks `tail.closed` for Empty vs Closed (line 1259)
- `Sender::closed()` → checks `tail.closed` (lines 889-903)

**Suggested modeling approach**:
- Variables: `closed` (boolean), `numTx` (integer), `rxCnt` (integer), `tail_pos` (integer)
- Actions: `Send`, `Close` (last sender drop), `Subscribe` (new receiver), `RecvEmpty` (check closed), `LastReceiverDrop` (re-close)
- Granularity: `Close` should be split into two steps: (1) decrement numTx atomically, (2) set closed + notify. This captures the inconsistency window.

**Priority**: High
**Rationale**: 3 historical bugs with the same mechanism. The dual-flag close state is the most error-prone design choice in the channel. Model checking can explore interleaving between close, subscribe, and recv to find remaining edge cases.

---

### Family 2: Waiter Notification Protocol (HIGH)

**Mechanism**: The intrusive linked list of waiting receivers and the notification protocol have been repeatedly buggy — lost wakeups, memory leaks, deadlocks from waker re-entrancy, and quadratic performance from re-registration during notification.

**Evidence**:
- Historical: `f9ea576c` (#2135) — lost condvar notification; receiver woke wrong sender
- Historical: `fb7dfcf4` (#2509) — waiter nodes leaked when receivers dropped without receiving
- Historical: `8497f379` (#5578) — deadlock when custom waker's `drop` or `wake` re-entered broadcast send
- Historical: `3dd5f7ae` (#5923) — O(n²) notification loop: woken receivers re-register while sender is still iterating waiters
- Open: #5465 — single tail mutex is a contention bottleneck with many receivers

**Affected code paths**:
- `notify_rx` (lines 993-1055) — moves waiters to GuardedLinkedList, wakes in batches
- `recv_ref` waiter registration (lines 1264-1291) — pushes to waiter list under tail lock
- `Recv::drop` waiter deregistration (lines 1625-1662) — removes waiter under tail lock

**Suggested modeling approach**:
- Variables: `waiters` (set of receiver IDs), `wakeList` (set), `tailLocked` (boolean)
- Actions: `RegisterWaiter`, `NotifyBatch` (wake subset, release lock), `WakerReentry` (send during waker drop), `DeregisterWaiter`
- Key property: every registered waiter is eventually woken or deregistered (liveness)
- The GuardedLinkedList pattern should be modeled abstractly as "move all waiters to temp set, iterate temp set"

**Priority**: High
**Rationale**: 4 historical bugs in the same subsystem. The notification protocol is the most complex part of the channel and interacts with external code (custom wakers). Model checking can verify that no waker is lost and no deadlock occurs under re-entrant waking.

---

### Family 3: Slot Value Lifecycle / rem Counter (MEDIUM)

**Mechanism**: Each slot has an atomic `rem` counter tracking how many receivers still need to read the value. The last receiver to decrement `rem` to 0 drops the value. Concurrent decrement, value cloning, and slot reuse by senders create subtle synchronization requirements.

**Evidence**:
- Historical: RUSTSEC-2025-0023 (`4b174ce2`) — unsoundness: `.clone()` on `!Sync` values without synchronization (fixed by switching RwLock → Mutex)
- Historical: `7d5b12c5` (#3434) — panic in Receiver::drop from incorrect loop termination while decrementing rem
- Code analysis: `RecvGuard::drop` (line 1715) uses `SeqCst` for `rem.fetch_sub(1)` — overly strong ordering but safe
- Code analysis: `send` (line 653) sets `rem` via `with_mut` (exclusive access under slot lock)

**Affected code paths**:
- `send` → write slot value, set rem = rx_cnt (lines 647-656)
- `recv_ref` → acquire slot lock, read value (lines 1222-1328)
- `RecvGuard::clone_value` → clone T under slot lock (lines 1703-1709)
- `RecvGuard::drop` → decrement rem, drop value if last (lines 1712-1719)
- `Receiver::drop` → loop decrementing rem for all pending slots (lines 1563-1573)

**Suggested modeling approach**:
- Variables: `slotVal[idx]` (value or Nil), `slotPos[idx]` (position), `slotRem[idx]` (counter)
- Actions: `WriteSlot` (sender writes value + sets rem), `ReadSlot` (receiver clones + decrements rem), `ReclaimSlot` (rem hits 0, value dropped)
- Key invariant: `slotRem[idx] >= 0` always; value is dropped iff `rem == 0`; no receiver reads a slot after value is dropped

**Priority**: Medium
**Rationale**: The RUSTSEC unsoundness was a real issue, but it was in the locking mechanism (RwLock vs Mutex), not the protocol logic. The rem counter protocol itself is straightforward. Model checking can verify value lifecycle invariants and catch any slot reuse race.

---

### Family 4: Position Wraparound / Lag Arithmetic (MEDIUM)

**Mechanism**: Position arithmetic uses wrapping u64 throughout, but inconsistently — two operations use non-wrapping math that would fail at u64 boundary. Lag recovery logic is complex: determining whether a receiver is empty, caught up, or lagged requires comparing positions across wrapping boundaries.

**Evidence**:
- Code analysis: `Receiver::len` (line 1167) — `next_send_pos - self.next` uses non-wrapping subtraction; panics in debug at u64 wraparound
- Code analysis: `Receiver::drop` (line 1563) — `while self.next < until` uses non-wrapping comparison; skips cleanup at u64 wraparound
- Historical: `7d5b12c5` (#3434) — `while self.next != until` changed to `while self.next < until` (different arithmetic bug in same location)
- Code analysis: lag recovery (lines 1300-1322) uses dual-lock re-check protocol correctly

**Affected code paths**:
- `recv_ref` (lines 1222-1328) — position comparison and lag detection
- `Receiver::len` (lines 1165-1167) — non-wrapping subtraction
- `Receiver::drop` (lines 1548-1574) — non-wrapping loop condition
- `send` (line 644) — `wrapping_add(1)` on tail.pos

**Suggested modeling approach**:
- Use small position space (e.g., 0..8) with wraparound to model the ring buffer
- Variables: `tail_pos` (wrapping integer), `next[rx]` (wrapping integer per receiver)
- Actions: `Send` (advance tail_pos with wrap), `Recv` (advance next with wrap), `LagRecovery` (jump next to oldest)
- Key invariant: `next[rx]` is always within [tail_pos - capacity, tail_pos] (modular)

**Priority**: Medium
**Rationale**: The u64 wraparound bugs are practically unreachable but reveal the complexity of the position arithmetic. Model checking with a small wrap-around space can verify lag recovery correctness and find edge cases in the position comparison logic.

---

### Family 5: Sender/Receiver Reference Counting (LOW)

**Mechanism**: Three independent counters (`num_tx` atomic, `num_weak_tx` atomic, `rx_cnt` mutex-guarded) interact with channel lifecycle. Different orderings on the same counter (Relaxed for clone, AcqRel for drop) and the split between atomic and mutex-guarded counts create a rich interaction space.

**Evidence**:
- Code analysis: `Sender::clone` uses `Relaxed` (line 1061); `Sender::drop` uses `AcqRel` (line 1069) — correct but subtle
- Code analysis: `WeakSender::upgrade` CAS uses `Relaxed` success / `Acquire` failure (line 1093) — verified safe, compensated by downstream mutex
- Historical: `8bfb1c92` — Clone for Receiver reverted due to semantic incorrectness (wrong position)

**Priority**: Low
**Rationale**: The reference counting is standard Rust Arc-style pattern. The orderings are correct and well-understood. Not suitable for model checking — this is better verified by loom tests.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Ring buffer with position-based indexing | Core data structure; families 3, 4 | `slots` array indexed by `pos % capacity`, with pos, rem, val fields |
| Send with slot overwrite | Captures lag scenario and rem/value lifecycle | `Send` action writes to `slots[tail_pos % cap]`, sets rem = rx_cnt |
| Recv with lag detection | Family 4: complex position arithmetic | `Recv` action compares next vs slot.pos; returns Lagged, Empty, Closed, or value |
| Channel close (split) | Family 1: dual-flag inconsistency | Two-step close: (1) `DecrementNumTx` sets numTx=0, (2) `SetClosed` sets closed=true + notifies |
| Subscribe / new_receiver | Family 1: re-open dead channel edge case | `Subscribe` action increments rx_cnt, potentially clears closed flag |
| Receiver drop with rem cleanup | Family 3: value lifecycle | `DropReceiver` decrements rx_cnt, then loops through pending slots decrementing rem |
| Waiter registration and notification | Family 2: lost wakeup / deadlock | Abstract waiter set: `RegisterWaiter`, `NotifyAll` (moved list pattern), `WakerReentry` |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WeakSender | Reference counting mechanism, no protocol bugs. Better verified by loom. |
| Cooperative scheduling (coop) | Runtime-level fairness mechanism, not channel protocol logic. |
| Memory ordering (Relaxed/AcqRel/SeqCst) | Low-level atomics. Loom tests are the right tool. |
| Clone panic recovery | Implementation detail of Rust's panic mechanism, not protocol logic. |
| Waker identity management (will_wake) | Optimization; does not affect correctness. |
| u64 position space | Use small wrapping integers (e.g., 0..8) instead; the bugs are in the arithmetic patterns, not the size. |
| BroadcastStream wrapper | Thin adapter over Receiver, no independent logic. |
| blocking_recv | Thin wrapper over async recv, no independent logic. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Dual close flags | `numTx`, `closed` | Capture window where numTx=0 but closed=false | Family 1 |
| Re-open on subscribe | `closed` toggle in Subscribe | Capture subscribe-after-all-rx-dropped reopening | Family 1 |
| Waiter set + batched notify | `waiters`, `wakeList`, `notifying` | Capture lost wakeup and re-registration loop | Family 2 |
| Waker re-entrancy | `WakerReentry` action (send during notify) | Capture deadlock from custom waker callback | Family 2 |
| Slot rem lifecycle | `slotRem[idx]`, `slotVal[idx]` | Capture value drop timing and slot reuse safety | Family 3 |
| Wrapping position space | Modular arithmetic on small domain | Capture lag recovery edge cases | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| CloseReachability | Safety | If all senders have dropped, every receiver eventually sees Closed (not Empty/Pending forever) | Family 1 |
| NoLostClose | Safety | A receiver created after channel close must see Closed on first recv, not Empty | Family 1 |
| SubscribeReopen | Safety | If subscribe re-opens a channel, subsequent recv returns Empty (not Closed) until all senders drop again | Family 1 |
| WakerCompleteness | Liveness | Every registered waiter is eventually woken or deregistered | Family 2 |
| NoDeadlock | Safety | No state where all threads are blocked (waker re-entrancy) | Family 2 |
| ValueLifecycle | Safety | `slotVal[idx] != Nil` implies `slotRem[idx] > 0`; value dropped iff last receiver decrements rem to 0 | Family 3 |
| NoUseAfterFree | Safety | No receiver reads a slot value after it has been dropped (rem reached 0) | Family 3 |
| LagBounded | Safety | After lag recovery, `next[rx]` is within `[tail_pos - capacity, tail_pos]` (modular) | Family 4 |
| RemNonNegative | Safety | `slotRem[idx] >= 0` for all slots at all times | Family 3 |
| OrderPreservation | Safety | If receiver rx sees value A before value B, then A was sent before B (FIFO per receiver) | All |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Close window: numTx=0 but closed=false; receiver gets Empty instead of Closed | CloseReachability (transient) | 1 |
| MC-2 | Subscribe after all receivers dropped + sender already dropped: channel re-opened as zombie | NoLostClose | 1 |
| MC-3 | Waker re-entrancy: send() during notify_rx causes deadlock (or action interleaving shows no deadlock after fix) | NoDeadlock | 2 |
| MC-4 | Notification with re-registration: receivers re-add to waiter list during notification loop | WakerCompleteness | 2 |
| MC-5 | Slot reuse race: sender overwrites slot while last receiver is decrementing rem | ValueLifecycle, NoUseAfterFree | 3 |
| MC-6 | Lag recovery correctness: receiver skips to oldest message after falling behind by > capacity | LagBounded, OrderPreservation | 4 |
| MC-7 | Receiver drop during active notification: waiter removed from GuardedLinkedList mid-iteration | WakerCompleteness | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `Receiver::len` non-wrapping subtraction at u64 boundary | Initialize channel with position near u64::MAX, verify len() doesn't panic in debug |
| TV-2 | `Receiver::drop` non-wrapping comparison at u64 boundary | Same setup, verify drop completes correctly with positions crossing u64::MAX |
| TV-3 | `Sender::len()` binary search with concurrent receivers | Loom test: concurrent recv during len() call, verify result is bounded |
| TV-4 | `blocking_recv` under contention | Stress test with multiple threads calling blocking_recv concurrently |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `rem` uses SeqCst (line 1715) but Mutex already provides ordering | Could relax to Release for performance, but not a correctness issue |
| CR-2 | `Sender::clone` uses Relaxed fetch_add (line 1061) | Correct but unusual; document why Relaxed suffices (downstream mutex compensates) |
| CR-3 | `is_closed()` vs `recv_ref` check different close state | Document that `is_closed()` may return true before `try_recv()` returns Closed |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/tokio-broadcast/analysis-report.md`
- **Key source file**: `artifact/tokio/tokio/src/sync/broadcast.rs` (1759 lines — entire implementation)
- **Test files**:
  - `artifact/tokio/tokio/tests/sync_broadcast.rs` (722 lines, 32 tests)
  - `artifact/tokio/tokio/src/sync/tests/loom_broadcast.rs` (207 lines, 5 loom tests)
  - `artifact/tokio/tokio/tests/sync_broadcast_weak.rs` (181 lines, 9 tests)
- **GitHub issues**: #2123, #2425, #2533 (Family 1/3); #4814 (Family 1); #5578, #5923 (Family 2); #5465 (open, contention)
- **Security advisory**: RUSTSEC-2025-0023 (Family 3)
- **Category**: B (concurrent/lock-free) — use timebox trace approach for trace validation
