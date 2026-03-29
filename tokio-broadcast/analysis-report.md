# Analysis Report: tokio broadcast channel

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits touching broadcast.rs | 87 |
| Bug-fix commits analyzed in detail | 13 |
| GitHub issues collected | 16 |
| GitHub issues deeply read (full discussion) | 15 |
| Confirmed real bugs | 7 issues + 6 additional commit-only fixes |
| Excluded as user error/not-a-bug | 5 (#4057, #4625, #4647, #5083, #5254) |
| Open issues reviewed | 5 (#5465, #7313, #4958, #7347, #3183) |
| Open PRs reviewed | 2 (#7900, #7962) |
| Source files analyzed | 1 (broadcast.rs, 1759 LOC) |
| Test files analyzed | 3 (sync_broadcast.rs, loom_broadcast.rs, sync_broadcast_weak.rs) |

---

## Phase 1: Reconnaissance

### Structural Map

The tokio broadcast channel is implemented as a single file: `tokio/src/sync/broadcast.rs` (1759 lines).

**Public types**: `Sender<T>`, `Receiver<T>`, `WeakSender<T>`
**Error types**: `SendError<T>`, `RecvError` (Closed, Lagged), `TryRecvError` (Empty, Closed, Lagged)

**Internal structures**:
- `Shared<T>` — central shared state: buffer (Box<[Mutex<Slot<T>>]>), mask, tail (Mutex<Tail>), num_tx (AtomicUsize), num_weak_tx (AtomicUsize)
- `Tail` — pos (u64), rx_cnt (usize), closed (bool), waiters (LinkedList<Waiter>)
- `Slot<T>` — rem (AtomicUsize), pos (u64), val (Option<T>)
- `Waiter` — queued (AtomicBool), waker (Option<Waker>), pointers
- `RecvGuard<'a, T>` — holds MutexGuard<Slot<T>>, decrements rem on drop
- `Recv<'a, T>` — Future implementation for async recv
- `WaitersList<'a, T>` — GuardedLinkedList wrapper for safe notification iteration

**Concurrency model**:
- Global `tail` Mutex serializes: send positioning, receiver count, close state, waiter list
- Per-slot Mutex serializes: value access, rem counter, position stamp
- Lock ordering: tail lock → slot lock (never reversed; recv_ref temporarily drops slot to acquire tail, then re-acquires slot)
- Atomics: num_tx (AcqRel on drop, Relaxed on clone), num_weak_tx (same pattern), slot.rem (SeqCst), waiter.queued (Release/Acquire)

**Ring buffer design**:
- Capacity rounded to power of two at initialization
- Index = `pos & mask` (bitwise AND with capacity - 1)
- Slot `pos` stamp distinguishes generations: if `slot.pos != receiver.next`, the slot is from a different cycle
- Sender writes `tail.pos` to slot, increments `tail.pos` by 1 (wrapping)
- Receiver reads slot if `slot.pos == self.next`, then increments `self.next` by 1 (wrapping)

### File Map

| File | Lines | Purpose |
|------|-------|---------|
| `tokio/src/sync/broadcast.rs` | 1759 | Core implementation |
| `tokio/tests/sync_broadcast.rs` | 722 | 32 functional tests |
| `tokio/tests/sync_broadcast_weak.rs` | 181 | 9 WeakSender tests |
| `tokio/src/sync/tests/loom_broadcast.rs` | 207 | 5 loom concurrency tests |
| `benches/sync_broadcast.rs` | 82 | Performance benchmarks |
| `tokio-stream/src/wrappers/broadcast.rs` | 102 | Stream adapter |

---

## Phase 2: Bug Archaeology

### Complete Bug-Fix Commit Analysis

#### 1. `f9ea576c` — sync: fix broadcast bugs (#2135) [2020-01-22]

**Root cause**: Three distinct concurrency bugs in the early slot-based lock protocol.
- Lost wakeup: condvar notification without holding tail mutex
- Wrong sender woken: `notify_one()` instead of `notify_all()`
- Panic on concurrent send: `fetch_add(1)` on writer lock allowed double-entry

**Fix**: Acquire tail lock before condvar notify; use `notify_all`; use `fetch_or(1)` for idempotent writer lock.
**Severity**: HIGH (deadlocks, panics)

#### 2. `a8195848` — sync: fix slow receivers in broadcast (#2448) [2020-04-27]

**Root cause**: Channel close sent `None` into ring buffer, consuming a slot and overwriting the oldest value.
**Fix**: Close via `closed` boolean on Tail struct + CLOSED bit on slot lock; no buffer slot consumed.
**Severity**: HIGH (data loss on capacity-1 channels)

#### 3. `fb7dfcf4` — sync: use intrusive list strategy for broadcast (#2509) [2020-05-12]

**Root cause**: Waiter nodes in atomic Treiber stack leaked when receivers dropped without receiving.
**Fix**: Intrusive linked list under tail mutex; nodes removed on Recv/Receiver drop.
**Severity**: HIGH (unbounded memory leak)

#### 4. `7d5b12c5` — sync: fix panic in broadcast::Receiver drop (#3434) [2021-01-20]

**Root cause**: `Receiver::drop` loop `while self.next != until` could skip past `until` when lag recovery jumped `self.next` forward.
**Fix**: Changed to `while self.next < until`.
**Severity**: MEDIUM (panic on drop under concurrent sends)

#### 5. `9d9488db` — sync: remove broadcast channel slot level closed flag (#4867) [2022-08-10]

**Root cause**: Receiver created after close had inconsistent index relative to per-slot closed flag.
**Fix**: Removed per-slot closed flag; rely solely on `tail.closed`.
**Severity**: MEDIUM (receiver hangs forever on closed channel)

#### 6. `8497f379` — sync: avoid deadlocks in broadcast with custom wakers (#5578) [2023-04-16]

**Root cause**: Custom waker `drop`/`wake` re-entering broadcast send while tail lock held.
**Fix**: Collect wakers, release lock, then wake. Save old waker and drop after releasing both locks.
**Severity**: HIGH (deadlock)

#### 7. `3dd5f7ae` — sync: move broadcast waiters into separate list before waking (#5925) [2023-08-14]

**Root cause**: Woken receivers re-registered in waiter list during same notification loop iteration, causing O(n²) behavior.
**Fix**: Move all waiters to separate GuardedLinkedList before waking; new registrations go to fresh main list.
**Severity**: MEDIUM (quadratic performance regression)

#### 8. `4b174ce2` — sync: fix cloning value when receiving from broadcast channel [2025-03-31]

**Root cause**: Buffer used RwLock allowing concurrent `.clone()` on `!Sync` values — undefined behavior.
**Fix**: Changed RwLock to Mutex; removed explicit unsafe Send/Sync impls.
**Severity**: CRITICAL (unsoundness, RUSTSEC-2025-0023)

#### 9. `6d1ae628` — sync: close the broadcast::Sender in broadcast::Sender::new() (#7629) [2025-09-20]

**Root cause**: `Sender::new()` (no initial receiver) left `tail.closed = false`.
**Fix**: Set `closed: receiver_count == 0` in constructor.
**Severity**: LOW (incorrect closed() future behavior)

#### 10. `484cb52d` — sync: return TryRecvError::Disconnected (#7686) [2025-10-18]

**Root cause**: mpsc fix, not broadcast (touched broadcast file incidentally).
**Severity**: N/A for broadcast

#### 11. `826fc21a` / `5c71268b` — Keep lock until sender notified / revert [2020-03]

**Root cause**: Attempted fix that was unnecessary; reverted.
**Severity**: N/A

#### 12. `8bfb1c92` — revert Clone impl for broadcast::Receiver (#3020) [2020-10-21]

**Root cause**: Clone gave receiver at tail position, not same position — semantically wrong.
**Fix**: Reverted Clone; later added `resubscribe()` with correct semantics.
**Severity**: MEDIUM (semantic correctness)

#### 13. `21df16d7` — apply cooperative scheduling (#6870) [2024-09-26]

**Root cause**: Busy receiver starved other tasks by not yielding.
**Fix**: Wrapped recv in `cooperative()`.
**Severity**: MEDIUM (task starvation)

### GitHub Issue Analysis

#### Confirmed Bugs

| Issue | Title | Root Cause | Fixed |
|-------|-------|-----------|-------|
| #2123 | sync::broadcast buggy | Race condition in slot locking: lost condvar, overflow panic | Yes (rewrite) |
| #2425 | Lagged error when capacity not exceeded | Close sentinel consumed buffer slot | Yes (a8195848) |
| #2533 | Receiver panics on drop | Race in drop loop: `!=` vs `<` | Yes (7d5b12c5) |
| #4814 | Resubscribe to closed hangs on recv | Slot-level closed flag inconsistency | Yes (9d9488db) |
| #5923 | Quadratic slowdown in send | Waiter re-registration during notify loop | Yes (3dd5f7ae) |
| #6855 | Receiver not cooperative | Missing coop budget integration | Yes (21df16d7) |
| #5465 | Reduce contention | Single tail mutex bottleneck | **Open** |

#### Excluded (Not Bugs)

| Issue | Title | Reason |
|-------|-------|--------|
| #4057 | Get nothing if send > capacity | User error: ignoring Lagged errors |
| #4625 | Sender doesn't notify on drop | User error: `let _ = x` doesn't drop |
| #4647 | Only some receivers received | User error (no repro) |
| #5083 | Receiver skips messages | User misunderstanding of subscribe semantics |
| #5254 | broadcast channel not recv | User error: ignoring Lagged errors |

#### Investigated and Found Safe

| Issue | Title | Conclusion |
|-------|-------|-----------|
| #5479 | Deadlock in tokio::sync | broadcast.rs line 915 confirmed safe by Alice Ryhl |
| #5482 | High-risk line confirmation | All broadcast lines confirmed safe |

---

## Phase 3: Deep Analysis

### 3.1 Send/Recv/Close Interaction Analysis

**Send path (lines 631-667)**: VERIFIED safe. Tail lock → slot lock ordering. Slot released before notification. Mutex provides happens-before for woken receivers.

**Sender::drop close path (lines 1067-1073)**: Observable inconsistency window where `num_tx == 0` but `tail.closed == false`. `is_closed()` reads num_tx (line 1361); `recv_ref` reads tail.closed (line 1259). Functionally benign: waiter gets woken by subsequent `close_channel` → `notify_rx`. But a poll of `is_closed()` + `try_recv()` can see contradictory state.

**new_receiver re-open (lines 929-934)**: VERIFIED unreachable through public API for the dead-channel scenario (subscribe needs live Sender; resubscribe needs live Receiver). However, the state transition (`closed = false` on subscribe) is important to model.

**Receiver::drop (lines 1548-1574)**: VERIFIED safe. rx_cnt decremented before cleanup loop; concurrent sends don't count this receiver in new rem values. Per-slot mutex prevents data races.

**RecvGuard::drop (lines 1712-1719)**: VERIFIED safe. RecvGuard holds slot MutexGuard continuously from pos check through rem decrement and value drop. No TOCTOU.

**WeakSender::upgrade CAS (lines 1082-1103)**: VERIFIED safe. Relaxed on CAS success is sufficient; downstream send acquires tail mutex for data visibility.

### 3.2 Position Arithmetic Analysis

**Wrapping operations (17 total)**: All correct. Consistent use of `wrapping_add`/`wrapping_sub` for slot initialization, send position advance, recv position advance, lag recovery, and position comparison.

**Non-wrapping exceptions**:
1. **Line 1167**: `(next_send_pos - self.next) as usize` in `Receiver::len()` — would panic in debug mode at u64 wraparound. Should use `wrapping_sub`.
2. **Line 1563**: `while self.next < until` in `Receiver::drop` — would exit early at u64 wraparound, leaking slot values. Should use wrapping comparison.

Both are practically unreachable (require ~18.4 quintillion sends) but represent genuine inconsistencies with the rest of the codebase.

**Lag recovery (lines 1300-1322)**: VERIFIED correct. Dual-lock re-check protocol (drop slot, acquire tail, re-acquire slot, re-check) handles race with concurrent sends. The `missed == 0` case correctly identifies a slow-but-not-lagged receiver.

**Sender::len() binary search (lines 746-763)**: The monotonicity assumption (`rem == 0` for older slots, `rem > 0` for newer) can be violated by concurrent receivers decrementing rem. Result is approximate. Acceptable for an inherently racy informational method.

### 3.3 Test Gap Analysis

**Not tested under loom**:
1. Close+send race (concurrent sender drop + send)
2. Subscribe+close race (subscribe racing with last receiver drop)
3. Receiver drop during notify_rx iteration
4. WeakSender::upgrade racing with last Sender::drop
5. Multiple all-lagged receivers with concurrent sends
6. Position near u64::MAX wraparound
7. Waiter batch boundary (>32 waiters, WakeList overflow)
8. Resubscribe while Recv future is pending
9. Clone panic with concurrent receivers

**Developer signals**: Zero TODO/FIXME/HACK/BUG/XXX/WARN comments in broadcast.rs or test files. Code has 11 unsafe blocks and 3 unsafe trait impls, all with safety comments.

### 3.4 Lock Ordering Map

```
tail (Mutex<Tail>) → slot[i] (Mutex<Slot<T>>)
  send: tail.lock() → slot.lock()
  recv_ref (lag path): slot.lock() → drop(slot) → tail.lock() → slot.lock()  [re-acquires with re-check]
  recv_ref (normal): slot.lock() only
  notify_rx: tail already held → drop(tail) → wake → tail.lock() [batch loop]
  new_receiver: tail.lock() only
  Receiver::drop: tail.lock() → drop(tail) → [recv_ref loop]
  Recv::drop: tail.lock() → waiter.remove
```

No lock inversion is possible: recv_ref explicitly releases the slot lock before acquiring the tail lock (lines 1240-1247), then re-acquires the slot lock while holding tail.

### 3.5 Atomics Ordering Map

| Variable | Read ordering | Write ordering | Justification |
|----------|--------------|----------------|---------------|
| num_tx | Acquire (line 1082, 1107, 1363) | Relaxed (clone, line 1061), AcqRel (drop, line 1069) | Counter only; AcqRel on drop ensures close_channel sees all prior operations |
| num_weak_tx | Acquire (line 1112) | Relaxed (clone, line 1119), AcqRel (drop, line 1127) | Same pattern as num_tx |
| slot.rem | SeqCst (len/is_empty reads) | SeqCst (fetch_sub in RecvGuard::drop, line 1715), with_mut (send, line 653) | Overly conservative; Mutex already provides ordering |
| waiter.queued | Relaxed (under tail lock, lines 1283, 1648), Acquire (without lock, line 1631) | Relaxed (under tail lock, line 1286), Release (during notify, line 1028) | Release in notify synchronizes with Acquire in Recv::drop |

---

## Bug Family Summary

| Family | Historical Bugs | Severity | Model-Checkable | Priority |
|--------|----------------|----------|-----------------|----------|
| 1. Channel Close Lifecycle | 3 (#2425, #4814, #7629) | HIGH | Yes | HIGH |
| 2. Waiter Notification Protocol | 4 (#2135, #2509, #5578, #5923) | HIGH | Yes | HIGH |
| 3. Slot Value Lifecycle / rem | 2 (RUSTSEC-2025-0023, #3434) | CRITICAL | Yes | MEDIUM |
| 4. Position Wraparound / Lag | 1 (#3434) + 2 code findings | MEDIUM | Yes | MEDIUM |
| 5. Sender/Receiver Ref Counting | 1 (#3020) | LOW | No (loom) | LOW |
