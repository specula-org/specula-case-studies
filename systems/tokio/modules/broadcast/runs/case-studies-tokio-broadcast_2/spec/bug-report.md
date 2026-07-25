# Bug Report — tokio::sync::broadcast (Round 2)

## Summary

- **Bug families tested**: 4 (F1 drop/close races, F2 caller misuse, F4 memory ordering on `queued`, F5 slot reuse)
- **Real bugs found in this run**: 0
- **Spec/invariant fixes during hunting (Case A)**: 2 — `ConcurrentDropCloseIdempotent`, `RxCntPositiveImpliesNotPermanentlyClosed`
- **Configs run**: `MC.cfg`, `MC_hunt_F1_drop_close_races.cfg`, `MC_hunt_F2_caller_misuse.cfg`, `MC_hunt_F4_memorder_queued.cfg`, `MC_hunt_F5_slot_reuse.cfg`
- **Coverage carried forward from Round 1**: two known wraparound bugs (#109 panic, #110 leak) were already reproduced and are out of scope per the brief.

## Model Checking Coverage

| Config | Mode | States gen / distinct | Diameter | Invariants checked | Result |
|--------|------|-----------------------|----------|--------------------|--------|
| MC.cfg (convergence) | Simulation (BFS hit user disk-quota at 64M distinct) | 722M states / 3M traces (sim) | n/a | TypeOK, ReceiverCountConsistency, NotifyHoldsTailWhenDraining, WaiterQueuedConsistency, NoSlotLeak | All hold |
| MC_hunt_F1_drop_close_races.cfg | BFS | 9.4M / 2.2M | 80 | TypeOK, NoUseAfterFree_Waiter, NotifyHoldsTailWhenDraining, WaiterQueuedConsistency, ConcurrentDropCloseIdempotent | All hold (after Case A fix) |
| MC_hunt_F2_caller_misuse.cfg | BFS | 1.05B / 189M (JVM crash mid-run, depth 50 reached) | 50 | TypeOK, CloseReopenSemantics, RxCntPositiveImpliesNotPermanentlyClosed, SubscribeRespectsSendBoundary, ReceiverCountConsistency, ConcurrentDropCloseIdempotent | All hold (after Case A fix) |
| MC_hunt_F4_memorder_queued.cfg | BFS | 27,721 / 10,023 | 40 | TypeOK, NoUseAfterFree_Waiter, WaiterQueuedConsistency | All hold |
| MC_hunt_F5_slot_reuse.cfg | BFS | ~750M / 181M (disk-quota hit, depth 65) | 65 | TypeOK, NoSlotLeak, NoDoubleRelease, NoSpuriousLagged, SubscribeRespectsSendBoundary | All hold |

All BFS diameters exceeded 25, so the workflow's simulation follow-up was not triggered.

---

## Spec/Invariant Fixes During Hunting

These are Case A (invariant too strong) — the implementation is correct; the invariant did not reflect implementation behavior.

### Fix 1 — `ConcurrentDropCloseIdempotent`

**Original formulation**:
```tla
ConcurrentDropCloseIdempotent ==
    (tailClosed /\ tailRxCnt > 0) =>
        closeReason \in {"none", "all_receivers_dropped"}
```

**Counterexample (4 states, F1 hunt)**:
1. Initial: `r1` alive, `s1` alive, `tailRxCnt=1`, `tailClosed=false`.
2. `TxDrop_FetchSub(s1)` — `numTx` decrements 1→0, `txAlive[s1]=false`, `txDropPC[s1]="after_fetch_sub"`.
3. **`TxDrop_CloseChannelEnter(s1)`** — `tailClosed=true`, `closeReason="all_senders_dropped"`. But `tailRxCnt=1` (r1 hasn't dropped yet) → invariant fires.

**Why it's a Case A**: At `tokio/src/sync/broadcast.rs:1067-1073`, `Sender::Drop` calls `close_channel()` unconditionally when `num_tx.fetch_sub` returns 1. That sets `tail.closed = true` regardless of `tail.rx_cnt`. The transient window where `tail.closed=true ∧ tail.rx_cnt > 0` is normal implementation behavior — it lasts until `Receiver::Drop` decrements `rx_cnt`.

**Fixed formulation**:
```tla
ConcurrentDropCloseIdempotent ==
    closeReason = "all_senders_dropped" => numTx = 0
```

This is the structural consistency check (also already covered by `CloseReopenSemantics`).

### Fix 2 — `RxCntPositiveImpliesNotPermanentlyClosed`

**Original formulation**:
```tla
RxCntPositiveImpliesNotPermanentlyClosed ==
    (tailRxCnt > 0) => (closeReason /= "all_senders_dropped" \/ ~tailClosed)
```

**Counterexample (4 states, F2 hunt)**: Same shape as Fix 1 — last sender drops while r1 is alive, producing the transient (`tailClosed=true ∧ tailRxCnt=1 ∧ closeReason="all_senders_dropped"`) state.

**Why it's a Case A**: Same root cause. The implementation legally allows receivers to remain alive after `Sender::Drop` closed the channel — receivers will get `Closed` errors on subsequent `recv` calls.

**Fixed formulation**:
```tla
RxCntPositiveImpliesNotPermanentlyClosed ==
    (tailRxCnt > 0) => closeReason /= "all_receivers_dropped"
```

The real invariant we care about: if `closeReason = "all_receivers_dropped"`, then `rxCnt = 0`. The moment `Subscribe` creates a receiver from `rxCnt = 0`, `closeReason` resets to `"none"` (broadcast.rs:1004) — so `closeReason = "all_receivers_dropped"` is incompatible with any live receiver.

---

## No Real Bugs Found

After the two Case A invariant fixes, all four bug-family hunts ran to completion (or hit infrastructure limits — disk quota / JVM crash) without any further invariant violations. Specifically:

### F1 Drop/Close Races

Coverage: BFS depth 80, 2.2M distinct states with 1 sender, 2 receivers, 2 sends. Invariants checked include `NoUseAfterFree_Waiter` (PR #6298 site). The spec's per-step split of `notify_rx` (drain → drop_tail → wake → finish) plus `Recv::Drop` (load_acquire → lock_tail → unlink) interleaves all the lock-release windows that historically had bugs. **None reproduced.**

### F2 Caller Misuse

Coverage: BFS depth 50, 189M distinct states with 2 senders, 3 receivers, multiple subscribes/drops/resubscribes. Invariants checked include `CloseReopenSemantics`, `SubscribeRespectsSendBoundary`. The adversarial harness fires Subscribe / TxDrop / RxDrop / TxClone in arbitrary interleavings. **No subscribe-while-send or drop-out-of-order or mixed close+drop pathology surfaced.**

### F4 Memory Ordering on `Waiter.queued`

Coverage: BFS depth 40, 10K distinct states with 1 sender, 1 receiver, 1 of each operation, plus `MCPickRelaxedSite` adversary (one downgrade per run). The `RecvDrop_LoadQueued_Acquire` action models the relaxed-load nondeterminism (`{recvWaiterQueued[r], FALSE}`) when the site is downgraded. **No `NoUseAfterFree_Waiter` violation found.**

Note on F4 coverage: in the current spec, `NotifyRx_DrainStep_Take` is one atomic action that simultaneously removes `r` from `tailWaiters`, adds it to `notifyExtracted`, and clears both `recvWaiterWaker` and `recvWaiterQueued`. The historical PR #6298 bug lived between the take-waker and clear-queued sub-steps; reproducing it with this spec would require splitting that action further. This is a known spec-granularity limitation, not an implementation bug.

### F5 Slot Reuse

Coverage: BFS depth 65, 181M distinct states with 1 sender, 2 receivers, 4 sends, capacity-2 ring. Invariants checked include `NoDoubleRelease`, `NoSpuriousLagged`. The spec's three-branch `recv_ref` classifier (Hit / Empty / Lagged) was exercised under sequences that overwrite slots while a slow receiver holds an old position. **No double-release or spurious-Lagged surfaced.**

---

## Findings vs. Modeling Brief Pending Items (§ 6.1)

| ID | Status |
|----|--------|
| M1 — Recv::Drop Acquire-load short-circuit downgrade should violate NoUseAfterFree_Waiter | Not reproduced (spec atomicity of NotifyRx_DrainStep_Take limits adversary reach — see F4 note above). |
| M2 — Reordering `notify_rx`'s take-waker / clear-queued should violate NoUseAfterFree_Waiter | Not modelable — actions are atomic by construction; would need a split. |
| M3 — Subscribe-while-send adversary linearization | F2 hunt found no violation of `SubscribeRespectsSendBoundary` across 189M states. |
| M4 — Drop-while-send NoSlotLeak | F2/F5 hunts found no violation. |
| M5 — Resubscribe after sender-drop close re-opens (PR #4814 pattern) | Spec allows this (see Case A fixes 1 and 2 above) — the implementation also allows it. Not classified as a bug here; the original `ConcurrentDropCloseIdempotent` invariant captured an idealized property the impl does not satisfy. |
| M6 — `Sender::closed()` future blocks under toggle adversary | Not directly checked — `Sender::closed()` is modeled abstractly, not as a state machine. No counter-example surfaced. |
| M7 — `Receiver::Drop` drain loop terminates under burst-send | Not checked here as a temporal property. The bounded loop in `RxDrop_DrainStep` is structurally bounded by `rxDropUntil`. |
| M8 — Post-Lagged next recv returns oldest value or another Lagged, never Empty-with-value | F5 hunt found no `NoSpuriousLagged` violation. |
| M9 — Wraparound classifier soundness | Out of scope — already reproduced in Round 1 (#109/#110). |
| M10 — `is_closed()` true while `tail.closed` false (Sender::Drop window) | Not directly checked — `is_closed()` is not modeled as a separate observation. The spec's `numTx == 0 ∧ ¬tailClosed` window is constrained by `closePC` PC and is liveness-bounded by `TxDrop_CloseChannelEnter`. |

---

## Reference

- Convergence run logs: `output/MC_run1.out` (BFS, hit disk-quota), `output/MC_run2_sim.out` (simulation, completed).
- Hunt logs: `output/MC_hunt_F1_bfs.out` (initial Case A), `output/MC_hunt_F1_bfs2.out` (post-fix), `output/MC_hunt_F2_bfs.out` (Case A), `output/MC_hunt_F2_bfs2.out` (post-fix), `output/MC_hunt_F4_bfs.out`, `output/MC_hunt_F5_bfs.out`.
- Source: `artifact/tokio/tokio/src/sync/broadcast.rs`.
- Modeling brief: `.specula-output/modeling-brief.md`.
- Changelog: `spec/changelog.md`.
