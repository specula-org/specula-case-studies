# Bug Report — tokio broadcast channel

## Summary

- Bug families tested: 4
- Bugs found: 0
- Configs run: MC_hunt_close.cfg, MC_hunt_waiter.cfg, MC_hunt_rem.cfg, MC_hunt_wrap.cfg

---

## Not Reproduced

| Bug Family | Config | States Explored | Depth | Result |
|------------|--------|-----------------|-------|--------|
| Family 1: Close Lifecycle | MC_hunt_close.cfg | 216 generated, 123 distinct | 7 | NoEmptyDuringClose violated (Case A, expected — see below) |
| Family 2: Waiter Notification | MC_hunt_waiter.cfg | 19,954 generated, 4,583 distinct | 15 | No violation (exhaustive BFS) |
| Family 3: Slot/rem Lifecycle | MC_hunt_rem.cfg | 4,154 generated, 1,156 distinct | 14 | No violation (exhaustive BFS) |
| Family 4: Position Wraparound | MC_hunt_wrap.cfg | 336 generated, 171 distinct | 8 | NoOrphanedRem violated (Case A, modeling artifact — see below) |

---

## Case A: Expected / Modeling Artifact Violations

### MC_hunt_close — NoEmptyDuringClose (Expected)

**Invariant**: `numTx = 0 => waiters = {}`

**Counterexample** (4 states, `output/MC_hunt_close_bfs.out`):
1. Init: channel created (numTx=1, rxCnt=0, closed=TRUE)
2. Subscribe(r1): r1 subscribes, channel re-opens (rxCnt=1, closed=FALSE)
3. RecvEmpty(r1): r1 finds channel empty, registers as waiter (waiters={r1})
4. SenderDrop: last sender drops (numTx=0, closePending=TRUE) — **violation**: numTx=0 but waiters={r1}

**Classification**: Case A (invariant too strong). This window is by design — it's the gap between `num_tx.fetch_sub(1, AcqRel)` (broadcast.rs:1069) and `close_channel()` (broadcast.rs:1071). The `close_channel()` call acquires the tail lock, sets `closed=TRUE`, and notifies all waiters (clearing the waiter set). The invariant comment in `base.tla` explicitly marks this as "EXPECTED VIOLATION during closePending window".

### MC_hunt_wrap — NoOrphanedRem (Modeling Artifact)

**Invariant**: `slotVal[i] /= Nil => slotRem[i] <= Cardinality({r \in AliveReceivers : SlotPendingFor(i, r)})`

**Counterexample** (8 states, `output/MC_hunt_wrap_bfs.out`):
1. Init (MaxPos=6, Capacity=2)
2. Subscribe(r1): r1 subscribes at position 0
3-7. Send(v1) x5: 5 values sent, tailPos advances through 1,2,3,4,5
8. Send(v1): 6th send, tailPos wraps to 0 — **violation**: slotRem[0]=1, slotVal[0]=v1, but PendingCount(r1) = WrapSub(0, 0) = 0, so no receiver has slot 0 as pending.

**Classification**: Case A (modeling artifact of small MaxPos). With MaxPos=6, position 0 wraps to alias with rxNext[r1]=0, making `WrapSub(tailPos, rxNext)` return 0 instead of 6. In the real implementation, positions are u64 (MaxPos ~ 1.8 * 10^19), so position aliasing cannot occur in practice. The slot's rem=1 is correct from the last Send, but the invariant can't detect that the receiver is actually lagged because the wrapping arithmetic has lost the lag information.

---

## Convergence

Converged in 1 round (no spec modifications during model checking):
- **Trace validation**: 4/4 traces pass (basic_send_recv, close_recv_race, lagged_receiver, concurrent_send_recv)
- **Model checking (MC.cfg)**: 33,975 states, 7,302 distinct, depth 16 — all 8 invariants pass

## Spec Coverage

| Invariant | MC.cfg | hunt_close | hunt_waiter | hunt_rem | hunt_wrap |
|-----------|--------|------------|-------------|----------|-----------|
| TypeOK | PASS | PASS | PASS | PASS | PASS |
| RemNonNegative | PASS | — | — | PASS | PASS |
| ValueLifecycle | PASS | — | — | PASS | PASS |
| LagBounded | PASS | — | — | — | PASS |
| CloseConsistency | PASS | — | — | — | — |
| RxCntConsistency | PASS | PASS | PASS | PASS | PASS |
| WaitersAlive | PASS | — | PASS | — | — |
| ClosePendingImpliesNoSenders | PASS | — | — | — | — |
| NoEmptyDuringClose | — | VIOLATED (Case A) | — | — | — |
| NoStaleWaiter | — | PASS | PASS | — | — |
| NoOrphanedRem | — | — | — | PASS | VIOLATED (Case A) |
