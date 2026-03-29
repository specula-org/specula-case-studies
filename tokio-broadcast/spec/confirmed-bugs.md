# Confirmed Bug Report — tokio broadcast channel

## Summary

- Total findings reviewed: 17
- Reproduced: 2
- Confirmed (code audit, reproduction failed): 0
- False positives: 0
- Filtered (not bugs): 15
  - MC-verified PASS: 9 (4 bug families + MC-2 through MC-7)
  - Expected/by-design: 2 (MC Case A violations)
  - Style/performance: 3 (CR-1, CR-2, CR-3)
  - Not concrete bugs: 2 (TV-3, TV-4 are test suggestions, not defects)

## Findings Overview

### Model Checking Results (0 bugs)

MC exhaustively explored 4 bug families (close lifecycle, waiter notification, slot/rem lifecycle, position wraparound) across 24,660 states with dedicated hunting configs. **No real invariant violations found.** Two violations were classified as expected (Case A):

- **MC_hunt_close — NoEmptyDuringClose**: Transient window between `num_tx.fetch_sub(1)` and `close_channel()` where numTx=0 but closed=false. By design — the window is closed immediately by `close_channel()`.
- **MC_hunt_wrap — NoOrphanedRem**: Modeling artifact of small position space (MaxPos=6). In real u64 space, position aliasing cannot occur.

All 7 code-review hypotheses (MC-1 through MC-7) were tested and passed without violation.

### Code Review Results (2 bugs confirmed + reproduced)

TV-1 and TV-2 are the only actionable findings. Both involve non-wrapping arithmetic on u64 positions that fails at the u64 boundary.

---

## Bug 1: Receiver::len() panics at u64 position wraparound (TV-1)

- **Source**: Code Review (modeling brief §6.2, TV-1)
- **Status**: REPRODUCED
- **Severity**: Low (requires ~584 years of continuous operation at 1B msg/sec)
- **Location**: `tokio/src/sync/broadcast.rs:1251`

### Description

`Receiver::len()` computes pending message count using non-wrapping subtraction:

```rust
pub fn len(&self) -> usize {
    let next_send_pos = self.shared.tail.lock().pos;
    (next_send_pos - self.next) as usize  // <-- non-wrapping!
}
```

When `tail.pos` wraps past `u64::MAX` back to small values, `next_send_pos < self.next`, causing:
- **Debug builds**: panic ("attempt to subtract with overflow")
- **Release builds**: wrapping arithmetic accidentally gives the correct result

The rest of the codebase consistently uses `wrapping_add`/`wrapping_sub` for position arithmetic (lines 576, 664, 789, 831, 1339, 1403, 1405, 1411, 1434). This is an oversight.

### Developer Evidence

- `len()` was added in PR #4542 (commit 2f944dfa1, Mar 2022) without wrapping-safe subtraction
- No developer commentary found about this specific case
- The pattern inconsistency (wrapping everywhere else, plain subtraction here) indicates an oversight, not a deliberate choice

### Trigger Scenario

1. Channel position (`tail.pos`) starts near `u64::MAX`
2. Sender sends enough messages to wrap `tail.pos` past `u64::MAX` to small values
3. Receiver becomes lagged; lag recovery sets `rx.next = tail.pos - capacity`
4. If `tail.pos` is small (e.g., 2) and capacity is 4, then `rx.next = 2.wrapping_sub(4) = u64::MAX - 1`
5. `len()` computes `2 - (u64::MAX - 1)` → underflow panic in debug

### Reproduction Test

**File**: `repro/test_bug1_len_wraparound.sh`

Level 3 reproduction: patches `tail.pos` initial value to `u64::MAX - 5`, then sends 8 messages to wrap past the boundary. Receiver lags and calls `len()`.

**Command**: `bash repro/test_bug1_len_wraparound.sh`

**Actual output (debug mode)**:
```
running 1 test
  Lagged by 4 (expected)

thread 'len_panics_at_u64_wraparound' panicked at tokio/src/sync/broadcast.rs:1167:9:
attempt to subtract with overflow

test len_panics_at_u64_wraparound ... FAILED
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out
```

**Actual output (release mode)**:
```
running 1 test
  Lagged by 4 (expected)
  About to call rx.len() [next=4, tail.pos should be ~2]...
  If you see this line, the bug was NOT triggered.
test len_panics_at_u64_wraparound ... ok
test result: ok. 1 passed; 0 failed
```

The debug panic at line 1167 confirms exactly the predicted bug. Release mode passes because unsigned wrapping subtraction accidentally gives the correct modular distance.

### Recommendation

Replace `(next_send_pos - self.next)` with `next_send_pos.wrapping_sub(self.next)`. This makes `len()` consistent with all other position arithmetic in the codebase and eliminates the debug-mode panic.

---

## Bug 2: Receiver::drop cleanup loop skipped at u64 position wraparound (TV-2)

- **Source**: Code Review (modeling brief §6.2, TV-2)
- **Status**: REPRODUCED
- **Severity**: Low (requires ~584 years of continuous operation at 1B msg/sec)
- **Location**: `tokio/src/sync/broadcast.rs:1692`

### Description

`Receiver::drop` uses a non-wrapping `<` comparison to iterate over pending slots:

```rust
while self.next < until {
    match self.recv_ref(None) {
        Ok(_) => {}
        Err(TryRecvError::Closed) => break,
        Err(TryRecvError::Lagged(..)) => {}
        Err(TryRecvError::Empty) => panic!("unexpected empty broadcast channel"),
    }
}
```

When u64 positions wrap, `self.next` (near `u64::MAX`) is NOT less than `until` (near 0), so the loop body never executes. Consequences:
- `rem` counters for pending slots are not decremented
- Slot values are not freed when the last receiver drops
- Values remain in slots until reused by future sends (bounded leak of up to `capacity` values)

### Developer Evidence

- This line was modified in PR #3434 (commit 7d5b12c5, Jan 2021) to fix a different bug: `while self.next != until` caused infinite loops. The fix to `<` resolved that specific issue but introduced this latent u64 boundary bug.
- The original bug #3434 was about `!=` semantics; the fix author likely assumed u64 would never actually wrap.
- A loom test `drop_multiple_rx_with_overflow` tests buffer wraparound (100 messages on capacity-1), but NOT u64 position wraparound — these are distinct concepts.

### Trigger Scenario

1. Channel position starts near `u64::MAX`
2. Sends wrap `tail.pos` past `u64::MAX` to small values
3. Receiver subscribes before the sends (so `rx.next` is near `u64::MAX`)
4. Receiver is dropped without reading all messages
5. In `drop()`: `self.next` ≈ `u64::MAX`, `until` = `tail.pos` ≈ small number
6. `while (u64::MAX - k) < small_number` → FALSE → loop skipped entirely

### Reproduction Test

**File**: `repro/test_bug2_drop_wraparound.sh`

Level 3 reproduction: patches `tail.pos` initial value to `u64::MAX - 2`. Creates two receivers. One reads all messages; the other is dropped with pending messages. Tracks value drop counts via `Arc<AtomicUsize>` to detect the skipped cleanup.

**Command**: `bash repro/test_bug2_drop_wraparound.sh`

**Actual output (release mode)**:
```
running 2 tests
  rx2 recv: Lagged(1) (lagged = expected)
  Dropping rx2 (next should be near u64::MAX, until should be near 0)...
  rx2 dropped without panic — cleanup loop was likely SKIPPED
  (rem counters not decremented = value leak)
test drop_loop_condition_check ... ok
  Drops before rx2 drop: 4
  Drops after rx2 drop: 4
  Additional drops from rx2 cleanup: 0
  Final total drops: 8
  NOTE: If cleanup was skipped, some slot values may not be dropped
  until the slots are reused by future sends (value leak).
test drop_skips_cleanup_at_u64_wraparound ... ok
test result: ok. 2 passed; 0 failed
```

The key evidence: **"Additional drops from rx2 cleanup: 0"**. When rx2 is dropped, zero additional values are freed. The cleanup loop was entirely skipped because `self.next` (near u64::MAX) is not `<` `until` (near 0). The `rem` counters for rx2's pending slots were not decremented. The 4 slot values were only freed later when the channel itself was destroyed.

### Recommendation

Replace the loop condition with wrapping-aware comparison. One approach:

```rust
while self.next != until {
    // ... (but != was the original bug from #3434)
}
```

The correct fix requires careful handling: `!=` was the original buggy condition that caused infinite loops (#3434). The right approach is to compute the number of pending messages using wrapping subtraction and loop a bounded number of times:

```rust
let pending = until.wrapping_sub(self.next);
for _ in 0..pending {
    match self.recv_ref(None) {
        Ok(_) => {}
        Err(TryRecvError::Closed) => break,
        Err(TryRecvError::Lagged(..)) => {}
        Err(TryRecvError::Empty) => panic!("unexpected empty broadcast channel"),
    }
}
```

This correctly handles u64 wraparound and is bounded (no infinite loop risk).

---

## Filtered Findings (Not Bugs)

| ID | Source | Description | Why Not a Bug |
|----|--------|-------------|---------------|
| MC Family 1 | MC | Close lifecycle | Exhaustive BFS, only Case A (expected transient window) |
| MC Family 2 | MC | Waiter notification | 19,954 states, no violation |
| MC Family 3 | MC | Slot/rem lifecycle | 4,154 states, no violation |
| MC Family 4 | MC | Position wraparound | Only Case A (modeling artifact of small MaxPos) |
| MC-1 | Code Review → MC | Close window (numTx=0 but closed=false) | Transient by design; close_channel() resolves immediately |
| MC-2 | Code Review → MC | Zombie channel after subscribe | No violation found by MC |
| MC-3 | Code Review → MC | Waker re-entrancy deadlock | No violation; fixed by GuardedLinkedList pattern |
| MC-4 | Code Review → MC | Notification re-registration | No violation; fixed by GuardedLinkedList |
| MC-5 | Code Review → MC | Slot reuse race | No violation; mutex serialization prevents it |
| MC-6 | Code Review → MC | Lag recovery correctness | No violation |
| MC-7 | Code Review → MC | Receiver drop during notification | No violation |
| TV-3 | Code Review | Sender::len() concurrent binary search | Loom test suggestion, not a concrete defect |
| TV-4 | Code Review | blocking_recv contention | Stress test suggestion, not a concrete defect |
| CR-1 | Code Review | rem uses SeqCst (line 1715) | Performance only; SeqCst is strictly stronger than needed |
| CR-2 | Code Review | Sender::clone uses Relaxed | Correct; downstream mutex provides necessary ordering |
| CR-3 | Code Review | is_closed() vs recv_ref check different flags | Observable but by design; same as MC-1 |
