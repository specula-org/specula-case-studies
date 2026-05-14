# Modeling Brief — tokio `sync::broadcast`

## 1. System Overview

- **Target**: `tokio::sync::broadcast` — multi-producer / multi-consumer broadcast channel where every active receiver observes every value sent after it subscribes.
- **Language**: Rust async (tokio runtime). Core: `tokio/src/sync/broadcast.rs` (~1,759 LOC, ~1,720 excluding tests).
- **Category**: **B (Concurrent / Lock-Free / Runtime)**, sub-category **channels / message passing**.
  - Justification: lock-coordinated ring buffer with intrusive waiter list, `AtomicUsize`/`AtomicBool` cross-lock signals, async-future cancel paths. No network/disk/RPC; bugs live in interleavings of `send`, `recv_ref`, `Recv::drop`, `Receiver::drop`, and `notify_rx`.
- **Concurrency model**:
  - One `Mutex<Tail>` (holds `pos`, `rx_cnt`, `closed`, intrusive `waiters: LinkedList<Waiter>`).
  - `Box<[Mutex<Slot<T>>]>` ring of size = capacity rounded to power of two.
  - Per-slot `AtomicUsize rem`, per-Recv `AtomicBool queued`.
  - Counters `num_tx`, `num_weak_tx` (Acquire/Release/AcqRel atomics).
  - Wakeups via tokio internal `Notify` (`notify_last_rx_drop`) + `WakeList` of `Waker` extracted before lock release.
- **Deviations from "textbook" broadcast**: power-of-two ring with per-slot `pos` + `rem` (Tokio's own design — there is no canonical reference algorithm). Slow-receiver semantics: silent overwrite + `Lagged(n)` rendezvous. Channel "closed" bit lives only on `Tail` after PR #4867; removed redundant slot-level closed flag.

---

## 2. Bug Families

### Family 1: Cancel / Drop / Close races (cross-state ordering through `tail`)

**Mechanism**: `Recv` future, `Receiver` value, `Sender` value, and explicit `close_channel` paths each trigger state transitions through the same `Tail` mutex. Inversion of any sub-step (taking the waker out of the `Waiter` after clearing `queued`, mutating `tail.closed` outside the lock, releasing `tail` before notifying) introduces lost wakeups, deadlocks, or use-after-free of the `Waiter`.

**Evidence**:
- Historical:
  - PR #2135 / issue #2123: `condvar.notify_one()` was called without holding `tail` → lost wakeup; `mem::drop(tail.lock())` pattern introduced.
  - PR #5578 / issue #5429: `notify_rx` woke wakers while still holding `tail`; a custom `Waker::drop` re-entered `tx.send()` → self-deadlock. Fix: extract wakers under lock, `wake_all` after lock release.
  - PR #6298: `Waiter.queued` was a non-atomic `bool`; `Recv::drop` raced with `notify_rx`'s clear under the lock. Fix: `AtomicBool` with Acquire/Release pairing; `Recv::drop` Acquire-loads first and only re-locks tail on the slow path.
  - PR #5925 / issue #5923: `notify_rx` looped indefinitely as receivers re-queued mid-loop. Fix: drain `tail.waiters` into a `GuardedLinkedList` once before the wake loop.
- Code analysis:
  - `broadcast.rs:1017-1028` (notify_rx must `take` waker before storing `queued = false, Release`) vs `broadcast.rs:1633-1648` (Recv::drop Acquire-load short-circuit) — single-pair synchronization protects waiter storage from use-after-free.
  - `broadcast.rs:1067-1073` Sender::Drop AcqRel `fetch_sub` then conditional `close_channel`. Window where `num_tx == 0` but `tail.closed == false` is publicly visible (`is_closed()`) — benign now, but invariant is implicit.
  - `broadcast.rs:889-903` `Sender::closed()` uses register-`notified()`-then-check-`tail.closed` idiom. Correct only because `Notify::notified` snapshots a counter and `Notify::notify_waiters` bumps it under its own lock (see notify.rs:565-575/1148).

**Affected code paths**: `Sender::send`, `Sender::Drop` → `close_channel` → `Shared::notify_rx`; `Receiver::Drop`; `Recv::poll` / `Recv::Drop`; `Sender::closed`; `WeakSender::upgrade`.

**Suggested modeling approach**:
- **Variables**: `tail = [pos, rxCnt, closed, waiters]`, `numTx`, per-slot `[pos, rem, val]`, per-active-Recv `waiter = [queued, waker, parked_at_pos]`, an explicit `wake_pending` set for "waker was extracted but not yet delivered".
- **Actions** (split at lock boundaries):
  - `Send_AcquireTail`, `Send_BumpPos`, `Send_LockSlot`, `Send_WriteSlot`, `Send_DropSlot`, `Send_TakeWaker(w)` for each waiter, `Send_ClearQueued(w)`, `Send_DropTailToWake`, `Send_WakeAll`, `Send_ReacquireTail` — at minimum split `notify_rx` into `Drain → DropTail → Wake → ReTake`.
  - `RecvDrop_Read_Queued_Acquire` (false → exit; true → continue), `RecvDrop_Lock_Tail`, `RecvDrop_Reread_Queued_Relaxed`, `RecvDrop_Unlink`.
  - `LastSenderDrop_FetchSub`, `LastSenderDrop_Close`, intermediate window action.
  - `LastReceiverDrop_DecCnt`, `LastReceiverDrop_NotifyClosed`, `LastReceiverDrop_DrainStep`.
- **Granularity rationale**: this family's bugs all live in the gap between `tail` lock release and a paired action elsewhere (Notify, slot, atomic flag). Coarsening `notify_rx` into one action hides #5578 and #6298.

**Priority**: **High**. Historically the densest single area (4 of the 8 confirmed correctness fixes).

---

### Family 2: Adversarial caller patterns (subscribe-while-send, drop-out-of-order, mixed close+drop, resubscribe-after-close)

**Mechanism**: Library's contract is unusually permissive — multiple senders, multiple receivers, dynamic subscribe/drop/close in any interleaving. Each public API serializes through `tail`, but the *combinations* exposed sequence-level invariants that earlier code violated.

**Evidence**:
- Historical:
  - Issue #4814 / PR #4867: `Receiver::resubscribe()` after the channel was already closed ran `recv()` forever — `new_receiver` did not adjust `next` for the slot-level `closed` marker. Fix: removed the slot-level `closed` flag entirely; `tail.closed` is the single source.
  - Issue #2533 / PR #3434: `Receiver::Drop` panicked with "unexpected empty broadcast channel" because the loop used `while self.next != until` and lag could push `self.next` past `until`. Fix: changed to `<` comparison.
  - PR #7629: `Sender::new(0)` left `tail.closed = false` despite `rx_cnt == 0`, so `Sender::closed()` blocked forever. Fix: `closed: rx_cnt == 0` at construction; `new_receiver` re-opens via `closed = false` when `rx_cnt == 0`.
  - PRs #2933 / #3020: `Clone for Receiver` reverted because two semantic interpretations existed (copy state vs. subscribe at tail).
- Code analysis (current code):
  - `broadcast.rs:631-666` Send vs `:924-942` new_receiver: serialized through `tail`. Sender snapshots `rem = rx_cnt` *before* a new subscriber can increment it, so the new subscriber correctly does **not** receive that send. Verified consistent with `:17-19` doc.
  - `broadcast.rs:1548-1574` Receiver::Drop drain loop: `until = tail.pos` is sampled under `tail`, so any send that completed before drop is included; sends after drop release see decremented `rx_cnt`. Lagged path inside the loop is bounded because each iteration advances `self.next` strictly toward `until`; values "skipped on lag" were already released by the overwriting send (`broadcast.rs:656` `Option::replace`).
  - `broadcast.rs:929-934` reopen: dropping all receivers sets `closed = true`; subsequent `subscribe()` flips it back. **But** the symmetric path — last `Sender` dropping — sets closed permanently (no reopen), creating two structurally different "closed" states in one variable. Not a bug, but the spec must distinguish them.
  - `broadcast.rs:451 / 927` `MAX_RECEIVERS = usize::MAX >> 2`: hard cap; `subscribe()` panics if hit.

**Affected code paths**: `new_receiver`, `Sender::send`, `Receiver::Drop`, `Recv::poll`, `Sender::Drop`, `WeakSender::upgrade`, `Sender::closed`, `Receiver::resubscribe`.

**Suggested modeling approach**:
- **Harness**: `ClientHarness` action set with bounded counters: `MAX_SUBSCRIBE`, `MAX_SEND`, `MAX_DROP_RECV`, `MAX_DROP_SEND`. Non-deterministically choose any legal call sequence including: subscribe between two sends, drop-receiver while a `Recv` is parked, drop-last-sender concurrent with subscribe-new-receiver, resubscribe after close.
- **Variables to add beyond Family 1**: `closeReason` ∈ `{none, all_senders_dropped, all_receivers_dropped}` to distinguish reopen-able vs. permanent close. Per-receiver `next : Nat` (its read cursor).
- **Actions**: `Subscribe_LockTail`, `Subscribe_ReopenIfRxZero`, `Subscribe_BumpRxCnt`, `Subscribe_TakeNext`. `DropReceiver_LockTail`, `DropReceiver_DecRxCnt`, `DropReceiver_MaybeClose`, `DropReceiver_DrainStep` (bounded loop).
- **Invariants** (see § 5):
  - `EveryDeliveredValueIsObservedAtMostOnce` — receiver doesn't re-read a slot after `recv_ref` succeeds.
  - `NoSlotLeak` — `rem == 0 ⇒ val == None` once all live receivers have advanced past it (closure: across drops + lags + overwrites, no `rem > 0 ∧ val = Some` if no receiver has `next ≤ slot.pos`).
  - `PostSubscribeAcquaintance` — value sent at `pos = N` reaches a subscriber iff that subscriber's `next ≤ N` at the moment its `Subscribe` action linearized.

**Priority**: **High**. The user's brief explicitly calls out that the prior round did *not* model adversarial-caller patterns; this family is the headline ask for this run.

---

### Family 3: u64 position wraparound and slot-pos arithmetic

**Mechanism**: All ring arithmetic uses `wrapping_add` / `wrapping_sub`. The "Empty vs Lagged" decision at `recv_ref:1252-1322` rests on `next_pos == self.next` where `next_pos = slot.pos.wrapping_add(capacity)`. The drop-drain loop uses `<` on `u64`. These are correct under the modular interpretation but break common monotonicity intuitions a spec author might import from a paper.

**Evidence**:
- Historical:
  - PR #3434 / issue #2533: `Receiver::Drop` `while self.next != until` looped forever / panicked when lag pushed `self.next` past `until`. Fix: `<`.
  - PR #5821 (closed without merge): proposal to switch position from `u64` → `usize` rejected because `RecvError::Lagged(u64)` is public.
  - Issue #7350: `channel(usize::MAX/2)` rounds-up overflows; doc-only fix.
  - Prior internal modeling (#109 panic, #110 leak in this project's numbering — not GitHub) reproduced two wraparound bugs in earlier rounds.
- Code analysis:
  - `broadcast.rs:558` slot.pos initial value `(i as u64).wrapping_sub(capacity as u64)` — negative wraparound at construction. Cold-start "empty" detection works because `next_pos = (-cap + i).wrapping_add(cap) = i = self.next` for `next == i`.
  - `broadcast.rs:1306-1308` `next = tail.pos.wrapping_sub(buffer.len())`, `missed = next.wrapping_sub(self.next)`. If `tail.pos` is small and `self.next` near `u64::MAX`, `missed` is some huge meaningless value but the receiver still resyncs to the oldest slot.
  - `broadcast.rs:1167` `Receiver::len` does `(next_send_pos - self.next) as usize` — **plain subtraction** without `wrapping_sub`. If wraparound happens, this panics in debug builds and silently underflows in release. (Theoretical only at 1 send/ns ≈ 580 years — but a spec author should still flag it.)

**Affected code paths**: every `pos` arithmetic site in `recv_ref`, `Receiver::Drop`, `Sender::len`, `Receiver::len`, `Sender::is_empty`.

**Suggested modeling approach**:
- **Variables**: model `pos` as `Int` (or `Nat ⊕ {INF}`) with explicit small modulus `M ≪ 2^64` to bound state. Inject `WraparoundEvent` action that bumps `tail.pos` by some chosen offset to simulate a wave near `M`.
- **Note**: prior rounds already reproduced 2 wraparound bugs; lower the modeling investment here unless adding explicit `Receiver::len` plain-`sub` panic check.

**Priority**: **Medium**. Two known prior bugs already reproduced; current code is plausibly correct under wrapping_*, but a small-state injection of wraparound is cheap to add.

---

### Family 4: Memory ordering on slot publication & T-Sync soundness

**Mechanism**: Cross-variable visibility between `slot.{pos, rem, val}` (under slot Mutex), `tail.pos` (under Tail Mutex), and `Waiter.queued` (atomic). The implementation does not rely solely on Mutex acquire/release; specific Acquire/Release annotations on `queued` and on `num_tx`/`num_weak_tx` are load-bearing.

**Evidence**:
- Historical:
  - PR #7232 (RUSTSEC-2025-0023, March 2025): the channel called `T::clone()` while holding only an `RwLock<Slot<T>>` *read* guard. For `!Sync` `T`, two receivers could call `T::clone()` concurrently on the same value — UB. Fix: replaced per-slot `RwLock` with `Mutex` so cloning is serialized; removed unsafe `Send/Sync` blanket impls on `Sender`/`Receiver`. Backported to 1.38.2/1.42.1/1.43.1/1.44.2.
  - PR #6298: `Waiter.queued` race between unlocked `Recv::drop` Acquire-load and `notify_rx` Release-store. Order-of-operations inside `notify_rx` (take waker → store queued=false) is mandated by comments at `:1025-1027`.
  - PR #2135: `condvar.notify_one()` outside lock → lost wakeup.
- Code analysis:
  - `broadcast.rs:653` `slot.rem.with_mut(|v| *v = rem)` — non-atomic write into `AtomicUsize` while holding slot lock. Safe but easy to misread.
  - `broadcast.rs:1715` `RecvGuard::Drop`: `slot.rem.fetch_sub(1, SeqCst)` while holding slot lock. SeqCst overkill given lock; if relaxed, an external observer (`Sender::len`/`is_empty` at `:755`/`:797`) might see stale values — but those also lock the slot, so even Relaxed would be sound. Spec should treat `rem` as plain mutable state under the slot lock.
  - `broadcast.rs:1283-1287` `recv_ref` enqueues waiter under `tail` lock with Relaxed `queued.load`/`store` — load-bearing only because tail lock is held.
  - `broadcast.rs:1633` Acquire-load and `:1028` Release-store form the sole synchronization between unlocked `Recv::Drop` short-circuit and `notify_rx`'s mutation of `Waiter`. Downgrading either to Relaxed makes the use-after-free of `Waiter` storage observable.
  - `broadcast.rs:1069` `num_tx.fetch_sub(1, AcqRel)` synchronizes with `:1082`/`:1107`/`:1332`/`:1363` Acquire loads in `WeakSender::upgrade`, `is_closed`, etc. The `tail.closed` flag and `num_tx == 0` form a 2-step transition; brief inconsistency window at `:1067-1073` is publicly observable but liveness-bounded by `close_channel` running immediately after.

**Affected code paths**: `notify_rx`, `recv_ref`, `Recv::Drop`, `Sender::Drop`, `WeakSender::upgrade`, `RecvGuard::Drop`, `clone_value`.

**Suggested modeling approach**:
- **Per-atomic ordering label**: tag each load/store in the spec with the C11 ordering used. Bounded adversary `MCRelaxLoad(site)` / `MCRelaxStore(site)` downgrades suspected cross-variable bridges (per `concurrent-analysis.md` §5.5 — *do not* attempt full TSO/ARM modeling).
- **Suspect sites to label**:
  1. `Waiter.queued` — Acquire (`:1633`), Release (`:1028`), Relaxed under tail lock (`:1283`/`:1286`/`:1648`).
  2. `num_tx` — AcqRel (`:1069`), Acquire (`:1082`/`:1332`/`:1363`/`:914`), Relaxed (`:1061`).
  3. `slot.rem` — non-atomic via `with_mut` under slot lock (`:653`); SeqCst fetch_sub under slot lock (`:1715`); SeqCst load under slot lock (`:755`/`:797`).
- **Composable with Family 1**: most of the cross-variable bridges are in `notify_rx` ↔ `Recv::Drop`, which is already split in Family 1.

**Priority**: **High**. User's brief specifically asks this run to focus on 5.5 memory ordering on slot publication. RUSTSEC-2025-0023 in 2025 confirms the area still surprises maintainers.

---

### Family 5: Slot reuse across send waves (slow-receiver semantics)

**Mechanism**: Buffer overwrites at the same idx by successive sends, with a slow receiver still pointing into the old wave. The "Empty vs Lagged vs Hit" classifier at `recv_ref:1252-1322` decides based on `slot.pos` modular comparison; off-by-one in this classifier has been the source of multiple bugs.

**Evidence**:
- Historical:
  - PR #2448 / issue #2425: at capacity 1, dropping the last sender wrote a sentinel that immediately overwrote the only real value; receivers then reported `Lagged` even when the channel had not actually exceeded capacity. Fix: introduce explicit `Tail.closed` flag; no sentinel slot.
  - PR #4867 / issue #4814: a separate slot-level closed flag created a redundant state. Fix: single `Tail.closed`.
  - PR #5925 / issue #5923: in `notify_rx`, freshly-woken receivers re-queued themselves and were re-woken in the same loop — quadratic blow-up. Fix: drain `tail.waiters` into `GuardedLinkedList` once at line 1007.
- Code analysis (current code):
  - `broadcast.rs:1252-1322` correctly distinguishes:
    - `slot.pos == self.next` ⇒ hit (return value).
    - `slot.pos.wrapping_add(cap) == self.next` ⇒ slot is the previous wave at this idx, not yet overwritten ⇒ Empty (and not closed).
    - else ⇒ slot has been overwritten ⇒ Lagged. Fast-forward `self.next = tail.pos − cap`.
  - `broadcast.rs:656` `Option::replace` releases the old `Some(value)` in place when overwriting — this is *the* mechanism that frees skipped values.
  - `broadcast.rs:1715-1717` `RecvGuard::Drop` decrements `rem`; when it hits 0, sets `slot.val = None`. So a value can be released by either (a) all live receivers reading it, or (b) a later send overwriting it. Both decrement-to-zero conditions must coexist without double-drop.
  - **Subtle**: between Family 2's `Receiver::Drop` drain and a concurrent send, the rem accounting on overwritten slots depends on `Option::replace` rather than rem-dec. Ensure spec models both paths.

**Affected code paths**: `Sender::send`, `recv_ref`, `RecvGuard::Drop`, `Receiver::Drop` drain.

**Suggested modeling approach**:
- **Variables**: per-slot `pos : Int (mod M)`, `rem : 0..MaxRx`, `val : Value ∪ {None}`. Per-receiver `next : Int (mod M)`.
- **Actions**: `Send_OverwriteSlot` releases `val` (replace with `Some(new)`); `RecvGuard_Drop_DecRem` releases `val` if `rem` hits 0. Two release paths must be modeled as alternative not exclusive transitions.
- **Invariants**:
  - `NoDoubleRelease`: no slot transitions val: Some→None twice without a Some assignment between.
  - `LaggedDoesNotMissValueAtCurrentIdx`: post-Lagged, the next `recv_ref` returns the value at `tail.pos − cap`, not Lagged again (unless another overflow occurred).

**Priority**: **Medium-High**. Three historical bugs but classifier in current code looks robust; modeling effort is moderate because the per-slot state is small.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Split `notify_rx` at `drop(tail)` boundary | Family 1 (PR #5578 deadlock fix lives here) | Two actions: `NotifyRx_DrainAndStoreFalse` (under tail), `NotifyRx_WakeAll_NoLock` (between drop and reacquire). Allow other actions to interleave between. |
| Split `Recv::Drop` at Acquire-load | Family 1, Family 4 (PR #6298) | Action 1: `RecvDrop_LoadQueued` returns boolean and may short-circuit; Action 2: `RecvDrop_LockTail_RereadAndUnlink`. |
| `Subscribe` action including `closed = false` reopen | Family 2 (PR #4867, #7629) | Single atomic action under tail lock. Capture `closeReason` to distinguish reopenable vs permanent close. |
| `Receiver::Drop` drain loop with `until` snapshot | Family 2 (PR #3434) | Bounded loop action + per-step recv_ref subactions; `until = tail.pos` snapshot is the linearization point. |
| Lag classifier in `recv_ref` | Family 5 (PR #2448, #2425) | Three branches based on modular comparison; encode as guarded transitions, not a single computation. |
| `Waiter.queued` atomic with explicit Acquire/Release labels | Family 1, Family 4 | Per-load/store ordering label; bounded `MCRelaxLoad/Store` adversary on the queued cross-variable bridge only. |
| `Sender::closed()` register-then-check pattern | Family 2 | Two-action sequence: `RegisterNotified` snapshots a counter, `CheckClosedThenAwait` may resolve immediately if counter advanced. Encode `notify_last_rx_drop` as a counter-Notify abstraction (don't import full Notify spec). |
| Interleaving (universal) | Always | Action granularity per concurrent-analysis.md §5.1 — model every observable boundary. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Full Tokio `Notify` internal state machine | Abstract via a 2-line counter (waiters, calls). Full Notify has its own spec; importing it inflates state space without adding value to broadcast invariants. |
| `WakeList` capacity / batching | Pure performance optimization in `notify_rx`. Spec can treat it as "extract all wakers, wake later". |
| `Sender::len` / `is_empty` binary search | Diagnostic API; not on a correctness-critical path. SeqCst loads are overkill but inert. |
| `WeakSender` clone arithmetic on `num_weak_tx` | `num_weak_tx` is read-only informational; never gates behavior. |
| `MAX_RECEIVERS = usize::MAX >> 2` panic | Defensive cap; cannot be reached at modeled scales. |
| Cooperative scheduling (`coop` budget) | Runtime-level fairness, not a correctness invariant. |
| `Receiver::len`'s plain `-` (vs `wrapping_sub`) | Theoretical only at 2^64 sends. Code-review-only. |
| Rust borrow-checker enforced ordering (Recv vs Receiver drop) | The borrow checker proves it; not a runtime invariant. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| **AdversarialClientHarness** | `bound_subscribe, bound_drop_recv, bound_drop_send, bound_resubscribe, bound_close_concurrent` (counters) | Drive subscribe/drop/close in arbitrary interleavings | Family 2 |
| **CloseReason** | `closeReason ∈ {none, sender_drop, receiver_drop}` | Distinguish reopenable receiver-drop close from permanent sender-drop close | Family 2 |
| **ParkedRecv** | per-Recv `{queued: Bool, parkedAtPos: Int, wakerExtracted: Bool}` | Model the Acquire/Release pairing on `queued` | Family 1, Family 4 |
| **WakeBuffer** | `extractedWakers: Set<Recv>` between `notify_rx`'s lock-drop and reacquire | Capture the unlocked window for `wake_all` | Family 1 |
| **NotifyCounter** | `notifyCalls : Nat` (abstraction of `notify_last_rx_drop`) | Allow `Sender::closed()` to detect missed notifications | Family 1 |
| **MemoryOrderLabels** | tag each load/store: `acq | rel | acqrel | relaxed | seq_cst | non_atomic_under_lock` | Bounded relaxation adversary | Family 4 |
| **WrappedPos** | `pos` modeled as `Int mod M` for small M (e.g. 16); inject one wraparound event | Spot-check ring math under wrap | Family 3 |
| **CloseReopenWindow** | flag for "Sender::Drop fetch_sub returned 1 but close_channel not yet called" | Capture transient `num_tx == 0 ∧ ¬tail.closed` window | Family 1 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| **NoLostMessage_PostSubscribe** | Safety | If receiver R's `Subscribe` linearized at `tail.pos = N`, every send that linearized at `pos ≥ N` either (a) appears in R's recv stream, or (b) was overwritten before R caught up (and R sees `Lagged`). | Family 2, Family 5 |
| **NoSpuriousLagged** | Safety | Receiver does not get `Lagged(k)` if no overwrite happened at any slot since its `next`. | Family 5 |
| **NoSlotLeak** | Safety | `(slot.rem == 0 ∧ slot.val ≠ None)` is impossible after slot mutation completes. | Family 5 |
| **NoDoubleRelease** | Safety | `slot.val` is not transitioned `Some → None` twice without a `Some` assignment between. | Family 5 |
| **NoUseAfterFree_Waiter** | Safety | `notify_rx` does not access `Waiter.waker` after `queued.store(false, Release)` for that waiter. | Family 1, Family 4 |
| **NoLostWakeup_Sender** | Liveness | If `Sender::send` linearized after some receiver parked, that receiver eventually wakes. | Family 1 |
| **NoLostWakeup_Closed** | Liveness | If `tail.closed` becomes true, every `Sender::closed()` await eventually returns. | Family 1 |
| **CloseReopenSemantics** | Safety | After `tail.closed = true` due to receiver-drop, a subsequent `Subscribe` makes `closed = false` again. After `tail.closed = true` due to last `Sender::Drop`, no `Subscribe` reopens. | Family 2 |
| **RxCntPositiveImpliesNotPermanentlyClosed** | Safety | `tail.rx_cnt > 0` implies `closeReason ≠ sender_drop`. | Family 2 |
| **DrainTerminates** | Liveness | `Receiver::Drop` drain loop terminates (bounded by `until − next`). | Family 2 |
| **SubscribeRespectsSendBoundary** | Safety | A receiver subscribed at `tail.pos = N` does NOT receive a value sent at `pos = N − 1` or earlier (per documented `subscribe` semantics). | Family 2 |
| **NumTxZeroEventuallyClosed** | Liveness | `num_tx == 0` ⇒ ◇ `tail.closed`. | Family 1 |
| **ConcurrentDropCloseIdempotent** | Safety | Multiple paths setting `tail.closed = true` are idempotent; no observer sees `closed` flip back to `false` except via `Subscribe`. | Family 2 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| M1 | `Recv::Drop`'s Acquire-load short-circuit is the only synchronization protecting `Waiter.waker` storage from `notify_rx`'s post-lock mutations. Downgrading to Relaxed should violate NoUseAfterFree_Waiter. | NoUseAfterFree_Waiter | F1, F4 |
| M2 | `notify_rx` extracting waker *before* clearing `queued = false` is order-critical; reordering should violate NoUseAfterFree_Waiter. | NoUseAfterFree_Waiter | F1, F4 |
| M3 | A subscribe-while-send adversary linearization should never let a new receiver observe a value sent before its subscribe linearization point. | SubscribeRespectsSendBoundary | F2 |
| M4 | A drop-while-send adversary should never leave `slot.rem > 0 ∧ slot.val = Some` after all live receivers have advanced past `slot.pos`. | NoSlotLeak | F2, F5 |
| M5 | Resubscribe after `closed = true` (receiver-drop reason) reopens; resubscribe after `closed = true` (sender-drop reason) does not. (PR #4814's bug pattern.) | CloseReopenSemantics | F2 |
| M6 | `Sender::closed()` future does not block forever under adversary that toggles closed=false→true via subscribe+drop pairs. | NoLostWakeup_Closed | F1, F2 |
| M7 | `Receiver::Drop` drain loop terminates even under burst-send adversary that keeps overflowing the ring. | DrainTerminates | F2, F3 |
| M8 | After a Lagged event, the immediately-next `recv_ref` returns either the oldest value or another Lagged (only if another overflow happened); never returns Empty when there is a value to read. | NoSpuriousLagged | F5 |
| M9 | Wraparound at `tail.pos` near `2^M` (small modulus): `recv_ref` classifier still distinguishes Empty/Lagged/Hit correctly. | NoSpuriousLagged + NoLostMessage_PostSubscribe | F3, F5 |
| M10 | Sender::Drop fetch_sub completes but close_channel has not run: `is_closed()` returns true while `tail.closed` is false. Liveness check that `tail.closed` follows. | NumTxZeroEventuallyClosed | F1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T1 | `notify_rx` no longer quadratic in number of receivers (PR #5925). | Loom + benchmark with N=1k receivers; `notify_rx` should iterate ≤ N times. |
| T2 | `Sender::len` / `Sender::is_empty` binary search returns correct count under interleaved send/recv. | Loom + property test on random send/recv schedules. |
| T3 | `Receiver::resubscribe()` to a closed (sender-drop) channel returns Closed (not hangs). | Existing test — ensure regression coverage stays. |
| T4 | `T: !Sync` clone is now serialized via Mutex (RUSTSEC-2025-0023 / PR #7232). | Miri + a test type whose `Clone` implements interior mutability. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| R1 | `Receiver::len` (broadcast.rs:1167) uses plain `-` instead of `wrapping_sub`. Theoretically panics in debug at u64 wraparound. | Pure code-review fix; switch to `wrapping_sub`. Not modelable at realistic scales. |
| R2 | `Sender::len` and `is_empty` use SeqCst on slot.rem load while holding slot lock — overkill but inert. | No action needed; document as redundant. |
| R3 | Two structurally-different `closed` states (sender-drop permanent vs. receiver-drop reopenable) share one bool. The `CloseReason` extension above formalizes; codebase could optionally add a debug assertion. | Add internal debug-only assertion; do not change public API. |
| R4 | `MAX_RECEIVERS` panic at `usize::MAX >> 2` is intentional; documented in code. | Confirm doc, no change. |
| R5 | The transient `num_tx == 0 ∧ ¬tail.closed` window (Sender::Drop between fetch_sub and close_channel) is observable via `is_closed()`. Benign because `close_channel` runs immediately, but the spec invariant is implicit. | Add internal comment cross-referencing model invariant `NumTxZeroEventuallyClosed`. |

---

## 7. Reference Pointers

- **Full analysis report**: `analysis-report.md`
- **Source key sites**:
  - `broadcast.rs:341-374` — `Shared`, `Tail` struct definitions
  - `broadcast.rs:543-578` — channel construction (`closed = (rx_cnt == 0)`)
  - `broadcast.rs:631-667` — `Sender::send` core (tail-lock-held critical section)
  - `broadcast.rs:889-910` — `Sender::closed`, `close_channel`
  - `broadcast.rs:924-942` — `new_receiver` (subscribe; reopen logic at 933)
  - `broadcast.rs:992-1056` — `Shared::notify_rx` (PR #5578, #5925, #6298)
  - `broadcast.rs:1067-1073` — `Sender::Drop` (AcqRel fetch_sub, close_channel)
  - `broadcast.rs:1223-1328` — `Receiver::recv_ref` (Empty/Lagged/Hit classifier)
  - `broadcast.rs:1548-1574` — `Receiver::Drop` drain loop (PR #3434 fix)
  - `broadcast.rs:1603-1623` — `Recv::poll`
  - `broadcast.rs:1625-1663` — `Recv::Drop` (Acquire-load short-circuit; PR #6298)
  - `broadcast.rs:1712-1719` — `RecvGuard::Drop` (`rem.fetch_sub`, `val = None`)
- **Loom tests**: `tokio/src/sync/tests/loom_broadcast.rs` — five tests covering send, two-receiver, wrap, drop_rx, drop_multiple_rx_with_overflow.
- **Key PRs**: #2135, #2448, #2509, #3434, #4867, #5578, #5925, #6298, #7232 (RUSTSEC-2025-0023), #7629.
- **Key issues**: #2123, #2425, #2533, #4814, #5429, #5923, #6649, #7350.
- **Reference algorithm**: no formal paper; Tokio's own design. Compare to `crossbeam-channel` (Stjepan Glavina's algorithm, different — Treiber-stack-based). Tokio uses ring + intrusive waiter list to avoid allocation per wait.

---

**Carry-forward note for Spec Generation**: This is a Category B target. Use `concurrent-analysis.md` modeling discipline (§5.1 thread-interleaving universally; §5.2 cancel/drop and §5.7 caller misuse and §5.5 memory ordering as the *primary* fault families per the channel sub-category and per the user's brief). Do **not** re-do the wraparound bugs from the prior round — this run's primary deliverable is the adversarial-client harness (Family 2) plus the Acquire/Release-on-`queued` invariant (Family 1 + 4).
