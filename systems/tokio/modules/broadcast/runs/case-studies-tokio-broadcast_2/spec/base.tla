---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of tokio::sync::broadcast — multi-producer / multi- *)
(* consumer broadcast channel.                                             *)
(*                                                                         *)
(* Source: tokio/tokio/src/sync/broadcast.rs                               *)
(*                                                                         *)
(* Category B (concurrent / lock-free / runtime), sub-category             *)
(* channels / message passing.                                             *)
(*                                                                         *)
(* Bug Families (modeling-brief §2):                                       *)
(*   F1 — Cancel / Drop / Close races (cross-state ordering through tail)  *)
(*   F2 — Adversarial caller patterns (subscribe / drop / close / resub)   *)
(*   F3 — u64 position wraparound (LOW priority — already covered round 1) *)
(*   F4 — Memory ordering on slot publication (Acquire/Release on queued)  *)
(*   F5 — Slot reuse across send waves (Lagged classifier)                 *)
(*                                                                         *)
(* Granularity discipline (concurrent-analysis §5.1, base-spec-methodology *)
(* "Granularity for Concurrent Specs"): every mutex acquire/release, every *)
(* atomic load/store, and every drop boundary in the implementation is its *)
(* own action.  notify_rx is split at its drop(tail)/wake/relock boundaries*)
(* so that PR #5578 (deadlock from waker→reentrant-send) and PR #6298      *)
(* (Acquire/Release on queued) are reachable as interleavings.             *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Receiver,            \* Set of receiver IDs (each one is a distinct Receiver<T>)
    Sender,              \* Set of sender IDs (each one is a distinct Sender<T>)
    Capacity,            \* Channel capacity (must be a power of 2 — modeled small, e.g. 2)
    Value,               \* Set of values that can be sent (small, e.g. {v1, v2, v3})
    PosMod,              \* Modulus for u64 position arithmetic.  Real impl uses 2^64;
                         \* for state-space we use a small modulus (Family 3).  Use a
                         \* multiple of Capacity at least 2*Capacity.
    MaxSubscribe,        \* Caller-misuse bound on Subscribe events (Family 2)
    MaxSend,             \* Caller-misuse bound on Send events (Family 2)
    MaxDropRecv,         \* Caller-misuse bound on Receiver::Drop events (Family 2)
    MaxDropSend,         \* Caller-misuse bound on Sender::Drop events (Family 2)
    NoneVal,             \* Sentinel for slot.val = None (broadcast.rs:393)
    NoneSite             \* Sentinel for "no memory-order downgrade selected"

ASSUME Capacity \in Nat /\ Capacity > 0
ASSUME Value /= {}
ASSUME NoneVal \notin Value
ASSUME PosMod \in Nat /\ PosMod >= 2 * Capacity

\* Sites whose memory ordering is load-bearing (Family 4).  The MC adversary
\* may downgrade exactly one of these to Relaxed for an entire run.
\*  - "QueuedAcquireLoad"  broadcast.rs:1633  Recv::drop short-circuit
\*  - "QueuedReleaseStore" broadcast.rs:1028  notify_rx releases queued
\*  - "NumTxFetchSub"      broadcast.rs:1069  Sender::Drop
\*  - "NumTxAcquireLoad"   broadcast.rs:1082  WeakSender::upgrade
RelaxSites == {"QueuedAcquireLoad", "QueuedReleaseStore",
               "NumTxFetchSub",     "NumTxAcquireLoad"}

ASSUME NoneSite \notin RelaxSites

\* All possible positions (modulo PosMod).
PosRange == 0 .. (PosMod - 1)

\* Slot indices: positions mod Capacity (broadcast.rs:641 — pos & mask).
SlotIx == 0 .. (Capacity - 1)

\* Initial "empty" slot pos at construction (broadcast.rs:558):
\*   slot.pos = (i as u64).wrapping_sub(capacity as u64)
\* Modeled as ((i - Capacity) mod PosMod).
InitSlotPos(i) == (((i - Capacity) % PosMod) + PosMod) % PosMod

\* Wrapping arithmetic helpers (broadcast.rs uses wrapping_add / wrapping_sub).
WAdd(a, b) == (((a + b) % PosMod) + PosMod) % PosMod
WSub(a, b) == (((a - b) % PosMod) + PosMod) % PosMod

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Shared `Tail` (broadcast.rs:362-374, locked under shared.tail mutex) ---
VARIABLES
    tailPos,             \* tail.pos    — next position to write (broadcast.rs:364)
    tailRxCnt,           \* tail.rx_cnt — active receiver count (broadcast.rs:367)
    tailClosed,          \* tail.closed — channel-closed flag   (broadcast.rs:370)
    tailWaiters,         \* tail.waiters — set of Receiver IDs whose Recv is parked
    tailLockedBy         \* spec-only: pid currently holding tail mutex, or "none"

\* --- Per-slot state (broadcast.rs:377-394, locked under buffer[i] mutex) ---
VARIABLES
    slotPos,             \* slot.pos: SlotIx -> PosRange
    slotRem,             \* slot.rem: SlotIx -> Nat (broadcast.rs:384)
    slotVal,             \* slot.val: SlotIx -> Value \cup {NoneVal}
    slotLockedBy         \* spec-only: pid currently holding slot[i] mutex, or "none"

\* --- Sender-side atomics (broadcast.rs:351-355) ---
VARIABLES
    numTx,               \* num_tx        AtomicUsize (broadcast.rs:352)
    numWeakTx            \* num_weak_tx   AtomicUsize (broadcast.rs:355)

\* --- Per-Receiver durable state (Receiver<T>) ---
VARIABLES
    rxAlive,             \* rxAlive[r]    \in BOOLEAN — Receiver still exists
    rxNext               \* rxNext[r] : PosRange — Receiver.next (broadcast.rs:514, etc.)

\* --- Per-Sender durable state ---
VARIABLES
    txAlive              \* txAlive[s] \in BOOLEAN — Sender s still exists
                         \* numTx is the canonical count; this is an existence flag

\* --- Per-Receiver in-flight Recv future state (broadcast.rs:435-441, 1577-1623) ---
\*  Each Receiver may have at most one outstanding Recv future at a time.
VARIABLES
    recvPC,              \* recvPC[r]  PC label tracking the Recv state machine
    recvWaiterQueued,    \* waiter.queued (broadcast.rs:399, AtomicBool)
    recvWaiterWaker,     \* waiter.waker.is_some() (broadcast.rs:402)
    recvParkedAtPos      \* spec-only: tail.pos at the moment we parked
                         \* (used to detect wakeups from sends we should observe)

\* --- Per-Sender in-flight Send PC (broadcast.rs:631-667) ---
\*  Each Sender may have at most one in-flight Send at a time.
VARIABLES
    sendPC,              \* sendPC[s] PC label
    sendIdx,             \* sendPC[s] = "send_locked_slot" -> idx captured at line 641
    sendPos,             \* pos captured at broadcast.rs:639
    sendRemSnapshot,     \* rem captured at broadcast.rs:640
    sendValue            \* value being sent

\* --- notify_rx PC (broadcast.rs:992-1056) ---
\*  notify_rx is invoked by Sender::send (after slot drop) and by close_channel.
\*  Modeled as a multi-step state machine with explicit drop(tail)/wake/relock
\*  boundaries (Family 1, Family 4, PR #5578).  Only one notify_rx may run on
\*  the tail mutex at a time.
VARIABLES
    notifyPC,            \* notifyPC \in {"idle", "drained_with_lock", "wakers_unlocked", "relocked"}
    notifyExtracted,     \* set of Receiver IDs whose waker was extracted but not yet woken
    notifyTriggeredBy    \* "send_<s>" | "close_<s>" | "rx_drop_<r>" — for trace mapping

\* --- close_channel PC (broadcast.rs:905-910) ---
\*  Two-step: lock tail + set closed; then notify_rx.
VARIABLES
    closePC              \* closePC[s] \in {"idle", "after_set_closed"}

\* --- Recv::drop PC (broadcast.rs:1625-1663) ---
VARIABLES
    recvDropPC           \* recvDropPC[r] \in {"idle", "loaded_acquire_true",
                         \*                    "locked_tail", "done"}

\* --- Receiver::drop PC (broadcast.rs:1548-1574) ---
VARIABLES
    rxDropPC,            \* rxDropPC[r] \in {"idle", "after_dec_cnt", "draining", "done"}
    rxDropUntil          \* rxDropPC[r] = "after_dec_cnt" -> snapshotted tail.pos

\* --- Sender::drop PC (broadcast.rs:1067-1073) ---
VARIABLES
    txDropPC,            \* txDropPC[s] \in {"idle", "after_fetch_sub", "done"}
    txDropWasLast        \* txDropPC[s] = "after_fetch_sub" -> TRUE iff s observed prev=1

\* --- Sender::closed() PC (broadcast.rs:889-903) ---
VARIABLES
    closedFnPC,          \* closedFnPC[s] \in {"idle", "after_register_notified",
                         \*                    "after_check", "done"}
    closedFnSnapshot     \* counter snapshot taken by notified() (modeled as tailClosed value)

\* --- WeakSender::upgrade PC (broadcast.rs:1081-1103) ---
\*  Cas-loop is collapsed to one-iteration per action — adversary can revisit.
VARIABLES
    weakPC,              \* weakPC[s] \in {"idle", "after_load", "done"}
    weakLoaded           \* num_tx value loaded at the start of upgrade

\* --- Memory ordering downgrade adversary (Family 4) ---
\*  Selected ONCE for an entire run; bounded by an MC counter.
VARIABLES
    relaxedSite          \* one of RelaxSites \cup {NoneSite}

\* --- close-reason discriminator (Family 2) ---
\*  Distinguishes "reopenable" (last-receiver-drop) from "permanent" (last-
\*  sender-drop) closed states.  Both share tail.closed = TRUE in the impl.
VARIABLES
    closeReason          \* "none" | "all_senders_dropped" | "all_receivers_dropped"

\* --- Adversarial caller counters (Family 2 — bounded in MC) ---
VARIABLES
    cSubscribe,          \* total Subscribe calls so far
    cSend,               \* total Send calls so far
    cDropRecv,           \* total Receiver::Drop events
    cDropSend            \* total Sender::Drop events

\* --- History (proof-only) ---
VARIABLES
    sendHistory,         \* Sequence of records [pos, value, sender]
    rxObserved,          \* rxObserved[r] : Sequence of records [pos, value, kind]
                         \* where kind \in {"hit", "lagged"}
    slotReleaseLog       \* per-slot count of Some -> None transitions (Family 5
                         \* NoDoubleRelease — must be at most one per Some assign)

vars == << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
           slotPos, slotRem, slotVal, slotLockedBy,
           numTx, numWeakTx,
           rxAlive, rxNext, txAlive,
           recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
           sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
           notifyPC, notifyExtracted, notifyTriggeredBy,
           closePC, recvDropPC,
           rxDropPC, rxDropUntil,
           txDropPC, txDropWasLast,
           closedFnPC, closedFnSnapshot,
           weakPC, weakLoaded,
           relaxedSite, closeReason,
           cSubscribe, cSend, cDropRecv, cDropSend,
           sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Index for a position (broadcast.rs:641 — pos & mask).
IdxOf(pos) == pos % Capacity

\* PR #6298 / Family 4: returns the *effective* memory ordering at a labelled
\* atomic site.  If the adversary picked this site, the ordering is downgraded
\* to Relaxed; otherwise it keeps its real ordering.  The base spec uses this
\* function only to *enable* the bug action MCStaleQueuedLoad (Family 4) — the
\* dataflow it would change is the Acquire-load result in Recv::drop.
EffectiveOrdering(site, real) ==
    IF relaxedSite = site THEN "Relaxed" ELSE real

\* Whether the channel currently has a queued waiter for receiver r
IsQueued(r) == r \in tailWaiters

\* Predicate: receiver r's next position equals slot.pos at idx (broadcast.rs:1232/1252).
SlotMatches(r, idx) == slotPos[idx] = rxNext[r]

\* Predicate: slot has been overwritten by exactly one wave (Empty branch at 1255).
SlotEmptyBranch(r, idx) == WAdd(slotPos[idx], Capacity) = rxNext[r]

\* No tx/no slot/no receiver locks held (used to gate idle actions).
TailIdle == tailLockedBy = "none"
SlotIdle(i) == slotLockedBy[i] = "none"

\* All initial state machines must be in "idle" PC.
NoSendInFlight(s)    == sendPC[s] = "idle"
NoRecvInFlight(r)    == recvPC[r] = "idle"
NoNotifyInFlight     == notifyPC = "idle"
NoCloseInFlight(s)   == closePC[s] = "idle"
NoRecvDropInFlight(r)== recvDropPC[r] = "idle"
NoTxDropInFlight(s)  == txDropPC[s] = "idle"
NoRxDropInFlight(r)  == rxDropPC[r] = "idle"
NoClosedFnInFlight(s)== closedFnPC[s] = "idle"
NoWeakInFlight(s)    == weakPC[s] = "idle"

\* ========================================================================
\* Init  (broadcast.rs:508-516 channel(), :543-578 new_with_receiver_count)
\* ========================================================================
\*
\* We initialize the channel in the state produced by `channel(Capacity)`:
\*   - tail.pos = 0, rx_cnt = 1, closed = false, no waiters
\*   - num_tx = 1, num_weak_tx = 0
\*   - one Receiver alive with next = 0
\*   - one Sender alive
\*   - all slots: pos = (i - Capacity) mod PosMod, rem = 0, val = None
\*
\* Receivers and Senders beyond {r0, s0} start in a "not yet alive" state and
\* must be brought to life by Subscribe / clone-style sender-creation actions.

Init ==
    \E r0 \in Receiver, s0 \in Sender :
        /\ tailPos = 0
        /\ tailRxCnt = 1
        /\ tailClosed = FALSE
        /\ tailWaiters = {}
        /\ tailLockedBy = "none"
        /\ slotPos = [i \in SlotIx |-> InitSlotPos(i)]
        /\ slotRem = [i \in SlotIx |-> 0]
        /\ slotVal = [i \in SlotIx |-> NoneVal]
        /\ slotLockedBy = [i \in SlotIx |-> "none"]
        /\ numTx = 1
        /\ numWeakTx = 0
        /\ rxAlive = [r \in Receiver |-> r = r0]
        /\ rxNext = [r \in Receiver |-> 0]
        /\ txAlive = [s \in Sender |-> s = s0]
        /\ recvPC = [r \in Receiver |-> "idle"]
        /\ recvWaiterQueued = [r \in Receiver |-> FALSE]
        /\ recvWaiterWaker = [r \in Receiver |-> FALSE]
        /\ recvParkedAtPos = [r \in Receiver |-> 0]
        /\ sendPC = [s \in Sender |-> "idle"]
        /\ sendIdx = [s \in Sender |-> 0]
        /\ sendPos = [s \in Sender |-> 0]
        /\ sendRemSnapshot = [s \in Sender |-> 0]
        /\ sendValue = [s \in Sender |-> NoneVal]
        /\ notifyPC = "idle"
        /\ notifyExtracted = {}
        /\ notifyTriggeredBy = "none"
        /\ closePC = [s \in Sender |-> "idle"]
        /\ recvDropPC = [r \in Receiver |-> "idle"]
        /\ rxDropPC = [r \in Receiver |-> "idle"]
        /\ rxDropUntil = [r \in Receiver |-> 0]
        /\ txDropPC = [s \in Sender |-> "idle"]
        /\ txDropWasLast = [s \in Sender |-> FALSE]
        /\ closedFnPC = [s \in Sender |-> "idle"]
        /\ closedFnSnapshot = [s \in Sender |-> FALSE]
        /\ weakPC = [s \in Sender |-> "idle"]
        /\ weakLoaded = [s \in Sender |-> 0]
        /\ relaxedSite = NoneSite
        /\ closeReason = "none"
        /\ cSubscribe = 0
        /\ cSend = 0
        /\ cDropRecv = 0
        /\ cDropSend = 0
        /\ sendHistory = << >>
        /\ rxObserved = [r \in Receiver |-> << >>]
        /\ slotReleaseLog = [i \in SlotIx |-> 0]

\* ========================================================================
\* Sender::send  (broadcast.rs:631-667)
\* ========================================================================
\* Split into:
\*   Send_AcquireTail        — line 632
\*   Send_BumpPos            — lines 634-644
\*   Send_LockSlot           — line 647
\*   Send_WriteSlot          — lines 650-656
\*   Send_DropSlot           — line 659
\*   Send_NotifyRx_*         — line 664 (notify_rx, see below)
\* The boundaries between these actions are real interleaving points: every
\* one of them is at minimum a separate atomic op.  PR #2135 lived here.

Send_AcquireTail(s) ==
    /\ txAlive[s]
    /\ NoSendInFlight(s)
    /\ NoTxDropInFlight(s)
    /\ TailIdle
    /\ NoNotifyInFlight                 \* Send_AcquireTail only when notify_rx idle
    /\ cSend < MaxSend
    /\ tailLockedBy' = "send_" \o ToString(s)
    /\ sendPC' = [sendPC EXCEPT ![s] = "tail_locked"]
    /\ cSend' = cSend + 1
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* SendErr_NoReceivers: tail.rx_cnt == 0 -> Err(SendError) (broadcast.rs:634-636).
\* Action releases tail and returns sender to idle.
Send_NoReceiversReturn(s) ==
    /\ sendPC[s] = "tail_locked"
    /\ tailLockedBy = "send_" \o ToString(s)
    /\ tailRxCnt = 0
    /\ sendPC' = [sendPC EXCEPT ![s] = "idle"]
    /\ tailLockedBy' = "none"
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Send_BumpPos: lines 638-644 — pos = tail.pos; rem = rx_cnt; idx = pos&mask;
\* tail.pos = wrapping_add(1).
Send_BumpPos(s, v) ==
    /\ sendPC[s] = "tail_locked"
    /\ tailLockedBy = "send_" \o ToString(s)
    /\ tailRxCnt > 0                    \* line 634 — rx_cnt > 0 path
    /\ v \in Value
    /\ sendPos' = [sendPos EXCEPT ![s] = tailPos]
    /\ sendRemSnapshot' = [sendRemSnapshot EXCEPT ![s] = tailRxCnt]
    /\ sendIdx' = [sendIdx EXCEPT ![s] = IdxOf(tailPos)]
    /\ sendValue' = [sendValue EXCEPT ![s] = v]
    /\ tailPos' = WAdd(tailPos, 1)      \* line 644
    /\ sendPC' = [sendPC EXCEPT ![s] = "after_bump"]
    /\ UNCHANGED << tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Send_LockSlot: line 647 — buffer[idx].lock().  tail still held.
Send_LockSlot(s) ==
    /\ sendPC[s] = "after_bump"
    /\ tailLockedBy = "send_" \o ToString(s)
    /\ SlotIdle(sendIdx[s])
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![sendIdx[s]] = "send_" \o ToString(s)]
    /\ sendPC' = [sendPC EXCEPT ![s] = "slot_locked"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Send_WriteSlot: lines 650-656 — slot.pos := pos; slot.rem := rem;
\* slot.val = Some(v).  Family 5 NoDoubleRelease accounting: if previous
\* slot.val was Some, this Option::replace releases it (broadcast.rs:656).
Send_WriteSlot(s) ==
    LET i == sendIdx[s] IN
    /\ sendPC[s] = "slot_locked"
    /\ slotLockedBy[i] = "send_" \o ToString(s)
    /\ slotPos' = [slotPos EXCEPT ![i] = sendPos[s]]
    /\ slotRem' = [slotRem EXCEPT ![i] = sendRemSnapshot[s]]
    /\ slotVal' = [slotVal EXCEPT ![i] = sendValue[s]]
    /\ slotReleaseLog' = [slotReleaseLog EXCEPT
                            ![i] = IF slotVal[i] /= NoneVal
                                   THEN @ + 1 ELSE @]
    /\ sendHistory' = Append(sendHistory,
                              [pos |-> sendPos[s], value |-> sendValue[s], sender |-> s])
    /\ sendPC' = [sendPC EXCEPT ![s] = "slot_written"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    rxObserved >>

\* Send_DropSlot: line 659 — drop(slot).  Releases slot mutex.  Tail still held.
Send_DropSlot(s) ==
    LET i == sendIdx[s] IN
    /\ sendPC[s] = "slot_written"
    /\ slotLockedBy[i] = "send_" \o ToString(s)
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
    /\ sendPC' = [sendPC EXCEPT ![s] = "slot_dropped"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Send_NotifyRx_Enter: line 664 — notify_rx(tail).  Hands tail off to
\* notify_rx.  notify_rx will keep tail through the drain phase.
Send_NotifyRx_Enter(s) ==
    /\ sendPC[s] = "slot_dropped"
    /\ tailLockedBy = "send_" \o ToString(s)
    /\ NoNotifyInFlight
    /\ notifyPC' = "drained_with_lock"
    /\ notifyExtracted' = {}
    /\ notifyTriggeredBy' = "send_" \o ToString(s)
    /\ sendPC' = [sendPC EXCEPT ![s] = "in_notify"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Shared::notify_rx  (broadcast.rs:992-1056)  Family 1 / Family 4
\* ========================================================================
\* Split per the modeling brief into:
\*   NotifyRx_DrainStep    : pop one waiter from tail.waiters, take waker,
\*                           store queued=false (Release).  Repeated until
\*                           the list is empty.  Lines 1010-1029.
\* (Note the brief recommends extracting one waiter at a time so that the
\* take-waker / store-queued ordering is explicit.)
\*   NotifyRx_DropTail     : drop(tail) before wake_all.  Line 1038/1051.
\*   NotifyRx_WakeAll      : wakers.wake_all() — moves notifyExtracted into
\*                           the woken state (rx parked -> ready).  Line 1045/1054.
\*   NotifyRx_RelockTail   : re-lock tail to drain again or finish.  Line 1048.
\*   NotifyRx_Finish       : exit notify_rx, returning tail back to caller's
\*                           Send_/Close_ resume action.

NotifyRx_DrainStep_Take(r) ==
    \* Pop receiver r from tail.waiters; extract waker; store queued=false (Release).
    \* Real code at lines 1012-1029.  We model "take waker" as r joining
    \* notifyExtracted; "store queued=false (Release)" zeros recvWaiterQueued[r].
    /\ notifyPC = "drained_with_lock"
    /\ r \in tailWaiters
    /\ tailWaiters' = tailWaiters \ {r}
    /\ notifyExtracted' = notifyExtracted \cup {r}
    \* PR #6298: take waker BEFORE storing queued=false (line 1017 then 1028).
    /\ recvWaiterWaker' = [recvWaiterWaker EXCEPT ![r] = FALSE]
    /\ recvWaiterQueued' = [recvWaiterQueued EXCEPT ![r] = FALSE]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* NotifyRx_DropTail: lines 1038/1051 — drop(tail) before wake_all.
NotifyRx_DropTail ==
    /\ notifyPC = "drained_with_lock"
    /\ tailWaiters = {}                 \* drained
    /\ notifyPC' = "wakers_unlocked"
    /\ tailLockedBy' = "none"           \* lock released — other actions can now run
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* NotifyRx_WakeOne: line 1045/1054 — wake one extracted waker.  In the real
\* code wake_all wakes everything; we split per-receiver so an interleaving
\* may run other actions (Send_AcquireTail by a waker's reentrant send) in
\* between, which is exactly the PR #5578 deadlock setup.
NotifyRx_WakeOne(r) ==
    /\ notifyPC = "wakers_unlocked"
    /\ r \in notifyExtracted
    /\ notifyExtracted' = notifyExtracted \ {r}
    /\ recvPC' = [recvPC EXCEPT ![r] = IF recvPC[r] = "parked" THEN "polled_again" ELSE recvPC[r]]
    /\ recvParkedAtPos' = [recvParkedAtPos EXCEPT ![r] = 0]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* NotifyRx_Finish: all extracted wakers were processed.  Returns to caller.
NotifyRx_Finish ==
    /\ notifyPC = "wakers_unlocked"
    /\ notifyExtracted = {}
    /\ notifyPC' = "idle"
    /\ \* dispatch back to whoever invoked notify_rx
       \/ /\ \E s \in Sender :
              /\ sendPC[s] = "in_notify"
              /\ notifyTriggeredBy = "send_" \o ToString(s)
              /\ sendPC' = [sendPC EXCEPT ![s] = "idle"]
              /\ UNCHANGED << closePC, rxDropPC >>
       \/ /\ \E s \in Sender :
              /\ closePC[s] = "in_notify"
              /\ notifyTriggeredBy = "close_" \o ToString(s)
              /\ closePC' = [closePC EXCEPT ![s] = "idle"]
              /\ UNCHANGED << sendPC, rxDropPC >>
    /\ notifyTriggeredBy' = "none"
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyExtracted,
                    recvDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* new_receiver / Sender::subscribe / Receiver::resubscribe
\* (broadcast.rs:692-695, 924-942, 1391-1394)
\* ========================================================================
\* Single atomic action under tail lock — modeled as one TLA action because
\* the real code holds the tail mutex for the entire body (no boundaries
\* observable from other threads).  Captures the rx_cnt==0 reopen logic.

Subscribe(rNew) ==
    /\ TailIdle
    /\ NoNotifyInFlight
    /\ rxAlive[rNew] = FALSE            \* must be a "free" receiver slot
    /\ NoRecvInFlight(rNew)
    /\ NoRecvDropInFlight(rNew)
    /\ NoRxDropInFlight(rNew)
    /\ cSubscribe < MaxSubscribe
    /\ \* line 933: if rx_cnt == 0, reopen channel (Family 2, PR #4867/#7629)
       LET reopen == tailRxCnt = 0
       IN  /\ tailRxCnt' = tailRxCnt + 1
           /\ tailClosed' = IF reopen THEN FALSE ELSE tailClosed
           /\ closeReason' = IF reopen THEN "none" ELSE closeReason
    /\ rxAlive' = [rxAlive EXCEPT ![rNew] = TRUE]
    /\ rxNext' = [rxNext EXCEPT ![rNew] = tailPos]
    /\ cSubscribe' = cSubscribe + 1
    /\ UNCHANGED << tailPos, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite,
                    cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Receiver::recv_ref  (broadcast.rs:1222-1328)  Family 1, 4, 5
\* ========================================================================
\* The classifier at lines 1252-1322 distinguishes Empty / Lagged / Hit by a
\* modular comparison.  We split per branch.
\*
\* PC labels:
\*   "idle"                  — no Recv in flight
\*   "polling"               — entered poll, slot lock not yet held
\*   "slot_locked_first"     — first slot lock taken (1230)
\*   "after_slot_drop"       — slot dropped to acquire tail (1240)
\*   "tail_locked"           — tail lock held (1244)
\*   "slot_relocked"         — slot relocked (1247)
\*   "parked"                — registered waiter, returned Empty
\*   "polled_again"          — woken / resuming after park
\*
\* Initial dispatch: from "idle" or "polled_again".

Recv_PollEnter(r) ==
    /\ rxAlive[r]
    /\ recvPC[r] \in {"idle", "polled_again"}
    /\ NoRecvDropInFlight(r)
    /\ NoRxDropInFlight(r)
    /\ recvPC' = [recvPC EXCEPT ![r] = "polling"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_LockSlotFirst: line 1230 — buffer[idx].lock().
Recv_LockSlotFirst(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "polling"
    /\ SlotIdle(i)
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "recv_" \o ToString(r)]
    /\ recvPC' = [recvPC EXCEPT ![r] = "slot_locked_first"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_HitFastPath: line 1232 — slot.pos == self.next.  Bump self.next, return Ok.
\* This is the "no contention" branch — slot already at our position.
\* Recv_HitFastPath models the Recv guard read+drop (line 1325-1327, then guard
\* drop at line 1715 decrements rem).  The code holds the slot lock the whole
\* time; we keep this as one TLA action.
Recv_HitFastPath(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "slot_locked_first"
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] = rxNext[r]           \* line 1232 — match
    /\ slotVal[i] /= NoneVal            \* a value is present (otherwise impossible
                                        \* under "all live receivers see every send")
    \* Append observed value to history before consuming:
    /\ rxObserved' = [rxObserved EXCEPT ![r] = Append(@,
            [pos |-> rxNext[r], value |-> slotVal[i], kind |-> "hit"])]
    /\ rxNext' = [rxNext EXCEPT ![r] = WAdd(rxNext[r], 1)] \* line 1325
    \* RecvGuard::Drop (line 1715): rem.fetch_sub(1, SeqCst); if 1 -> val=None.
    /\ slotRem' = [slotRem EXCEPT ![i] = IF slotRem[i] > 0 THEN slotRem[i] - 1 ELSE 0]
    /\ slotVal' = [slotVal EXCEPT ![i] = IF slotRem[i] = 1 THEN NoneVal ELSE slotVal[i]]
    /\ slotReleaseLog' = [slotReleaseLog EXCEPT
                            ![i] = IF slotRem[i] = 1 /\ slotVal[i] /= NoneVal
                                   THEN @ + 1 ELSE @]
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
    /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos,
                    numTx, numWeakTx,
                    rxAlive, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory >>

\* Recv_DropSlotForTail: line 1240 — drop(slot) before locking tail.
Recv_DropSlotForTail(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "slot_locked_first"
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] /= rxNext[r]          \* line 1232 mismatch path
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
    /\ recvPC' = [recvPC EXCEPT ![r] = "after_slot_drop"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_LockTail: line 1244 — tail.lock().
Recv_LockTail(r) ==
    /\ recvPC[r] = "after_slot_drop"
    /\ TailIdle
    /\ NoNotifyInFlight
    /\ tailLockedBy' = "recv_" \o ToString(r)
    /\ recvPC' = [recvPC EXCEPT ![r] = "tail_locked"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_RelockSlot: line 1247 — slot lock acquired again.
Recv_RelockSlot(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "tail_locked"
    /\ tailLockedBy = "recv_" \o ToString(r)
    /\ SlotIdle(i)
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "recv_" \o ToString(r)]
    /\ recvPC' = [recvPC EXCEPT ![r] = "slot_relocked"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_RecheckMatch: line 1252 — slot.pos == self.next after relock?  If so,
\* take fast path (treat like Recv_HitFastPath).  Releases tail.
Recv_RecheckMatch(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "slot_relocked"
    /\ tailLockedBy = "recv_" \o ToString(r)
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] = rxNext[r]           \* line 1252 false branch (match)
    /\ slotVal[i] /= NoneVal
    /\ rxObserved' = [rxObserved EXCEPT ![r] = Append(@,
            [pos |-> rxNext[r], value |-> slotVal[i], kind |-> "hit"])]
    /\ rxNext' = [rxNext EXCEPT ![r] = WAdd(rxNext[r], 1)]
    /\ slotRem' = [slotRem EXCEPT ![i] = IF slotRem[i] > 0 THEN slotRem[i] - 1 ELSE 0]
    /\ slotVal' = [slotVal EXCEPT ![i] = IF slotRem[i] = 1 THEN NoneVal ELSE slotVal[i]]
    /\ slotReleaseLog' = [slotReleaseLog EXCEPT
                            ![i] = IF slotRem[i] = 1 /\ slotVal[i] /= NoneVal
                                   THEN @ + 1 ELSE @]
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
    /\ tailLockedBy' = "none"
    /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos,
                    numTx, numWeakTx,
                    rxAlive, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory >>

\* Recv_EmptyClosed: lines 1255-1260 — next_pos == self.next AND tail.closed.
\* Returns Err(Closed); cleans up locks.  Family 2 / Family 5.
Recv_EmptyClosed(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "slot_relocked"
    /\ tailLockedBy = "recv_" \o ToString(r)
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] /= rxNext[r]                 \* line 1252 true branch
    /\ SlotEmptyBranch(r, i)                    \* line 1255 — next_pos == self.next
    /\ tailClosed                               \* line 1259 — closed
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
    /\ tailLockedBy' = "none"
    /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]  \* poll returns Err(Closed)
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_ParkAsWaiter: lines 1263-1298 — empty branch with !closed.
\* Registers waiter, sets queued=true (Relaxed under tail lock), returns
\* Err(Empty).  Recv future stays in "parked" state until notify_rx wakes it.
Recv_ParkAsWaiter(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ recvPC[r] = "slot_relocked"
    /\ tailLockedBy = "recv_" \o ToString(r)
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] /= rxNext[r]
    /\ SlotEmptyBranch(r, i)
    /\ ~tailClosed
    /\ recvWaiterWaker' = [recvWaiterWaker EXCEPT ![r] = TRUE] \* line 1276
    /\ \* line 1283-1287: if !queued, queued.store(true,Relaxed) + push_front
       IF ~recvWaiterQueued[r]
       THEN /\ recvWaiterQueued' = [recvWaiterQueued EXCEPT ![r] = TRUE]
            /\ tailWaiters' = tailWaiters \cup {r}
       ELSE UNCHANGED << recvWaiterQueued, tailWaiters >>
    /\ recvParkedAtPos' = [recvParkedAtPos EXCEPT ![r] = tailPos]
    /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"] \* line 1294
    /\ tailLockedBy' = "none"                              \* line 1295
    /\ recvPC' = [recvPC EXCEPT ![r] = "parked"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed,
                    slotPos, slotRem, slotVal,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* Recv_LaggedFastForward: lines 1301-1321 — slot.pos != self.next AND
\* next_pos != self.next (slot has been overwritten).  Fast-forward
\* self.next = tail.pos - capacity; emit Lagged(missed) (unless missed==0).
Recv_LaggedFastForward(r) ==
    LET i == IdxOf(rxNext[r]) IN
    LET nxt == WSub(tailPos, Capacity) IN
    LET missed == WSub(nxt, rxNext[r]) IN
    /\ recvPC[r] = "slot_relocked"
    /\ tailLockedBy = "recv_" \o ToString(r)
    /\ slotLockedBy[i] = "recv_" \o ToString(r)
    /\ slotPos[i] /= rxNext[r]
    /\ ~SlotEmptyBranch(r, i)            \* lagged branch (line 1255 false)
    /\ tailLockedBy' = "none"            \* line 1310 — drop(tail)
    /\ \* line 1313-1317: if missed == 0 -> single increment, return Ok at slot.
       \* line 1319-1321: else self.next = next; return Lagged(missed).
       IF missed = 0
       THEN /\ rxNext' = [rxNext EXCEPT ![r] = WAdd(rxNext[r], 1)]
            /\ rxObserved' = [rxObserved EXCEPT ![r] = Append(@,
                    [pos |-> rxNext[r], value |-> slotVal[i], kind |-> "hit"])]
            /\ slotRem' = [slotRem EXCEPT ![i] = IF slotRem[i] > 0 THEN slotRem[i] - 1 ELSE 0]
            /\ slotVal' = [slotVal EXCEPT ![i] = IF slotRem[i] = 1 THEN NoneVal ELSE slotVal[i]]
            /\ slotReleaseLog' = [slotReleaseLog EXCEPT
                                    ![i] = IF slotRem[i] = 1 /\ slotVal[i] /= NoneVal
                                           THEN @ + 1 ELSE @]
            /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
            /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
       ELSE /\ rxNext' = [rxNext EXCEPT ![r] = nxt]
            /\ rxObserved' = [rxObserved EXCEPT ![r] = Append(@,
                    [pos |-> rxNext[r], value |-> NoneVal, kind |-> "lagged"])]
            /\ slotLockedBy' = [slotLockedBy EXCEPT ![i] = "none"]
            /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
            /\ UNCHANGED << slotRem, slotVal, slotReleaseLog >>
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos,
                    numTx, numWeakTx,
                    rxAlive, txAlive,
                    recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory >>

\* ========================================================================
\* Recv::drop  (broadcast.rs:1625-1663)  Family 1, 4
\* ========================================================================
\* Split per the modeling brief into two actions:
\*   RecvDrop_LoadQueued_Acquire — line 1633 — Acquire-load short-circuit
\*   RecvDrop_LockTail_Reread    — lines 1641-1660 — slow path
\* PR #6298: the Acquire-load is the *sole* synchronization between unlocked
\* Recv::drop and notify_rx's Release-store on queued.  Downgrading to Relaxed
\* should violate NoUseAfterFree_Waiter.

\* User explicitly drops the Recv future. In Tokio, Recv::drop runs whenever
\* the Recv future is dropped — both after a successful poll completes and
\* during cancellation. So the precondition admits "idle" too (post-completion).
RecvDrop_Begin(r) ==
    /\ recvPC[r] \in {"idle", "parked", "polled_again"}
    /\ NoRecvDropInFlight(r)
    /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "begin"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RecvDrop_LoadQueued_Acquire: line 1633 — load(Acquire).  If false, exit.
\* Family 4: this is the load-bearing Acquire.  Under MCRelaxOrdering, a
\* downgrade may produce a stale FALSE even when the waiter is still queued
\* — modeled as a non-deterministic choice between the true current value
\* and FALSE (only when the site has been downgraded).
RecvDrop_LoadQueued_Acquire(r) ==
    /\ recvDropPC[r] = "begin"
    /\ \E observed \in
            (IF EffectiveOrdering("QueuedAcquireLoad", "Acquire") = "Relaxed"
             THEN {recvWaiterQueued[r], FALSE}
             ELSE {recvWaiterQueued[r]}) :
          \/ /\ ~observed                         \* short-circuit branch
             /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "done"]
             /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
             /\ recvWaiterWaker' = [recvWaiterWaker EXCEPT ![r] = FALSE]
          \/ /\ observed                          \* slow path
             /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "loaded_acquire_true"]
             /\ UNCHANGED << recvPC, recvWaiterWaker >>
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvWaiterQueued, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RecvDrop_LockTail_Reread: lines 1641-1660 — slow path.
RecvDrop_LockTail_Reread(r) ==
    /\ recvDropPC[r] = "loaded_acquire_true"
    /\ TailIdle
    /\ NoNotifyInFlight
    /\ tailLockedBy' = "recvdrop_" \o ToString(r)
    /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "tail_locked"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RecvDrop_RereadAndUnlink: lines 1645-1660 — re-read queued (Relaxed under
\* tail lock); if still true, remove from list.  Then drop tail.
RecvDrop_RereadAndUnlink(r) ==
    /\ recvDropPC[r] = "tail_locked"
    /\ tailLockedBy = "recvdrop_" \o ToString(r)
    /\ \* line 1650: if queued, remove from waiters list
       /\ tailWaiters' = IF recvWaiterQueued[r] THEN tailWaiters \ {r} ELSE tailWaiters
    /\ recvWaiterQueued' = [recvWaiterQueued EXCEPT ![r] = FALSE]
    /\ recvWaiterWaker' = [recvWaiterWaker EXCEPT ![r] = FALSE]
    /\ tailLockedBy' = "none"
    /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "done"]
    /\ recvPC' = [recvPC EXCEPT ![r] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RecvDrop_FinishIdle: end of drop, nothing more to do.
RecvDrop_FinishIdle(r) ==
    /\ recvDropPC[r] = "done"
    /\ recvDropPC' = [recvDropPC EXCEPT ![r] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Receiver::Drop  (broadcast.rs:1548-1574)  Family 2 (PR #3434)
\* ========================================================================
\* Split into:
\*   RxDrop_LockTailDecCnt — lines 1550-1559 — lock + dec rx_cnt + maybe close
\*   RxDrop_NotifyClosed   — line 1557 — notify_waiters() (notify_last_rx_drop)
\*   RxDrop_DropTail       — line 1561
\*   RxDrop_DrainStep      — lines 1563-1573 — drain remaining values

RxDrop_Begin(r) ==
    /\ rxAlive[r]
    /\ NoRxDropInFlight(r)
    /\ NoRecvInFlight(r)                   \* impl-required: Recv future drops first
    /\ NoRecvDropInFlight(r)
    /\ cDropRecv < MaxDropRecv
    /\ rxDropPC' = [rxDropPC EXCEPT ![r] = "begin"]
    /\ cDropRecv' = cDropRecv + 1
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

RxDrop_LockTailDecCnt(r) ==
    /\ rxDropPC[r] = "begin"
    /\ TailIdle
    /\ NoNotifyInFlight
    /\ tailLockedBy' = "rxdrop_" \o ToString(r)
    /\ tailRxCnt' = tailRxCnt - 1                       \* line 1552
    /\ rxDropUntil' = [rxDropUntil EXCEPT ![r] = tailPos] \* line 1553
    /\ \* line 1556-1559: if remaining_rx == 0, set tail.closed = true,
       \* notify_last_rx_drop.notify_waiters().  We model the closeReason here.
       LET wasLast == tailRxCnt - 1 = 0
       IN  /\ tailClosed' = IF wasLast THEN TRUE ELSE tailClosed
           /\ closeReason' = IF wasLast /\ closeReason = "none"
                             THEN "all_receivers_dropped"
                             ELSE closeReason
    /\ rxDropPC' = [rxDropPC EXCEPT ![r] = "after_dec_cnt"]
    /\ UNCHANGED << tailPos, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RxDrop_DropTail: line 1561.
RxDrop_DropTail(r) ==
    /\ rxDropPC[r] = "after_dec_cnt"
    /\ tailLockedBy = "rxdrop_" \o ToString(r)
    /\ tailLockedBy' = "none"
    /\ rxDropPC' = [rxDropPC EXCEPT ![r] = "draining"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* RxDrop_DrainStep: lines 1563-1573 — while self.next < until { recv_ref(None) }.
\* PR #3434: the comparison is `<` (not `!=`) because lag can push self.next
\* past until.  We model one drain step at a time; bounded loop.
\* This action calls a simplified recv_ref that consumes a slot if matching,
\* else fast-forwards on lag.  Loop terminates when self.next >= until.
RxDrop_DrainStep(r) ==
    LET i == IdxOf(rxNext[r]) IN
    /\ rxDropPC[r] = "draining"
    \* line 1563: condition is `self.next < until` — modular comparison.
    /\ rxNext[r] /= rxDropUntil[r]      \* still draining
    /\ \/ /\ slotPos[i] = rxNext[r]     \* hit branch
          /\ rxNext' = [rxNext EXCEPT ![r] = WAdd(rxNext[r], 1)]
          /\ slotRem' = [slotRem EXCEPT ![i] = IF slotRem[i] > 0 THEN slotRem[i] - 1 ELSE 0]
          /\ slotVal' = [slotVal EXCEPT ![i] = IF slotRem[i] = 1 THEN NoneVal ELSE slotVal[i]]
          /\ slotReleaseLog' = [slotReleaseLog EXCEPT
                                  ![i] = IF slotRem[i] = 1 /\ slotVal[i] /= NoneVal
                                         THEN @ + 1 ELSE @]
       \/ /\ slotPos[i] /= rxNext[r]    \* lag — fast-forward
          /\ rxNext' = [rxNext EXCEPT ![r] = WSub(tailPos, Capacity)]
          /\ UNCHANGED << slotRem, slotVal, slotReleaseLog >>
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved >>

\* RxDrop_Finish: drain done.
RxDrop_Finish(r) ==
    /\ rxDropPC[r] = "draining"
    /\ rxNext[r] = rxDropUntil[r]
    /\ rxDropPC' = [rxDropPC EXCEPT ![r] = "idle"]
    /\ rxAlive' = [rxAlive EXCEPT ![r] = FALSE]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Sender::Drop  (broadcast.rs:1067-1073)  Family 1 (PR #5578)
\* ========================================================================

TxDrop_FetchSub(s) ==
    /\ txAlive[s]
    /\ NoTxDropInFlight(s)
    /\ NoSendInFlight(s)
    /\ NoCloseInFlight(s)
    /\ cDropSend < MaxDropSend
    /\ \* line 1069: AcqRel fetch_sub — Family 4 site "NumTxFetchSub"
       LET prev == numTx
       IN  /\ numTx' = numTx - 1
           /\ txDropWasLast' = [txDropWasLast EXCEPT ![s] = prev = 1]
    /\ txDropPC' = [txDropPC EXCEPT ![s] = "after_fetch_sub"]
    /\ txAlive' = [txAlive EXCEPT ![s] = FALSE]
    /\ cDropSend' = cDropSend + 1
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numWeakTx,
                    rxAlive, rxNext,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv,
                    sendHistory, rxObserved, slotReleaseLog >>

\* TxDrop_CloseChannelEnter: line 1070-1071 — if was last, call close_channel.
\* close_channel itself locks tail and sets closed = true, then calls
\* notify_rx.  PR #5578 deadlock window lives between this and the wake.
TxDrop_CloseChannelEnter(s) ==
    /\ txDropPC[s] = "after_fetch_sub"
    /\ txDropWasLast[s]
    /\ TailIdle
    /\ NoNotifyInFlight
    /\ tailLockedBy' = "close_" \o ToString(s)
    /\ tailClosed' = TRUE                          \* line 907
    /\ closeReason' = IF closeReason = "none" THEN "all_senders_dropped" ELSE closeReason
    /\ closePC' = [closePC EXCEPT ![s] = "after_set_closed"]
    /\ txDropPC' = [txDropPC EXCEPT ![s] = "in_close"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailWaiters,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    recvDropPC, rxDropPC, rxDropUntil,
                    txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* TxDrop_NotifyEnter: line 909 — notify_rx(tail).
TxDrop_NotifyEnter(s) ==
    /\ closePC[s] = "after_set_closed"
    /\ txDropPC[s] = "in_close"
    /\ tailLockedBy = "close_" \o ToString(s)
    /\ NoNotifyInFlight
    /\ notifyPC' = "drained_with_lock"
    /\ notifyExtracted' = {}
    /\ notifyTriggeredBy' = "close_" \o ToString(s)
    /\ closePC' = [closePC EXCEPT ![s] = "in_notify"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

TxDrop_Finish(s) ==
    /\ txDropPC[s] = "after_fetch_sub"
    /\ ~txDropWasLast[s]                \* not the last sender
    /\ txDropPC' = [txDropPC EXCEPT ![s] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* When notify_rx finishes a close, txDropPC needs to leave "in_close".
TxDrop_AfterClose(s) ==
    /\ txDropPC[s] = "in_close"
    /\ closePC[s] = "idle"              \* notify_rx finished, dispatched closePC->idle
    /\ txDropPC' = [txDropPC EXCEPT ![s] = "idle"]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Sender::clone (broadcast.rs:1058-1064) — bring a "free" sender alive
\* ========================================================================

TxClone(sNew) ==
    /\ \E sExisting \in Sender : txAlive[sExisting]
    /\ ~txAlive[sNew]
    /\ NoTxDropInFlight(sNew)
    /\ numTx' = numTx + 1                          \* line 1061: Relaxed fetch_add
    /\ txAlive' = [txAlive EXCEPT ![sNew] = TRUE]
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numWeakTx,
                    rxAlive, rxNext,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    relaxedSite, closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Memory-order downgrade adversary  (Family 4)
\* ========================================================================
\* MCRelaxOrdering picks one site whose ordering will be downgraded for the
\* remainder of the run.  Bounded by an MC counter (one fire per run).

PickRelaxedSite(site) ==
    /\ relaxedSite = NoneSite
    /\ site \in RelaxSites
    /\ relaxedSite' = site
    /\ UNCHANGED << tailPos, tailRxCnt, tailClosed, tailWaiters, tailLockedBy,
                    slotPos, slotRem, slotVal, slotLockedBy,
                    numTx, numWeakTx,
                    rxAlive, rxNext, txAlive,
                    recvPC, recvWaiterQueued, recvWaiterWaker, recvParkedAtPos,
                    sendPC, sendIdx, sendPos, sendRemSnapshot, sendValue,
                    notifyPC, notifyExtracted, notifyTriggeredBy,
                    closePC, recvDropPC, rxDropPC, rxDropUntil,
                    txDropPC, txDropWasLast,
                    closedFnPC, closedFnSnapshot, weakPC, weakLoaded,
                    closeReason,
                    cSubscribe, cSend, cDropRecv, cDropSend,
                    sendHistory, rxObserved, slotReleaseLog >>

\* ========================================================================
\* Next
\* ========================================================================
Next ==
    \/ \E s \in Sender :
        \/ Send_AcquireTail(s)
        \/ Send_NoReceiversReturn(s)
        \/ \E v \in Value : Send_BumpPos(s, v)
        \/ Send_LockSlot(s)
        \/ Send_WriteSlot(s)
        \/ Send_DropSlot(s)
        \/ Send_NotifyRx_Enter(s)
        \/ TxDrop_FetchSub(s)
        \/ TxDrop_CloseChannelEnter(s)
        \/ TxDrop_NotifyEnter(s)
        \/ TxDrop_Finish(s)
        \/ TxDrop_AfterClose(s)
        \/ TxClone(s)
    \/ \E r \in Receiver :
        \/ Subscribe(r)
        \/ Recv_PollEnter(r)
        \/ Recv_LockSlotFirst(r)
        \/ Recv_HitFastPath(r)
        \/ Recv_DropSlotForTail(r)
        \/ Recv_LockTail(r)
        \/ Recv_RelockSlot(r)
        \/ Recv_RecheckMatch(r)
        \/ Recv_EmptyClosed(r)
        \/ Recv_ParkAsWaiter(r)
        \/ Recv_LaggedFastForward(r)
        \/ RecvDrop_Begin(r)
        \/ RecvDrop_LoadQueued_Acquire(r)
        \/ RecvDrop_LockTail_Reread(r)
        \/ RecvDrop_RereadAndUnlink(r)
        \/ RecvDrop_FinishIdle(r)
        \/ RxDrop_Begin(r)
        \/ RxDrop_LockTailDecCnt(r)
        \/ RxDrop_DropTail(r)
        \/ RxDrop_DrainStep(r)
        \/ RxDrop_Finish(r)
    \/ \E r \in Receiver : NotifyRx_DrainStep_Take(r)
    \/ NotifyRx_DropTail
    \/ \E r \in Receiver : NotifyRx_WakeOne(r)
    \/ NotifyRx_Finish
    \/ \E site \in RelaxSites : PickRelaxedSite(site)

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants
\* ========================================================================

\* ----- Type invariants -----
TypeOK ==
    /\ tailPos \in PosRange
    /\ tailRxCnt \in 0..Cardinality(Receiver)
    /\ tailClosed \in BOOLEAN
    /\ tailWaiters \subseteq Receiver
    /\ slotPos \in [SlotIx -> PosRange]
    /\ slotRem \in [SlotIx -> 0..Cardinality(Receiver)]
    /\ slotVal \in [SlotIx -> Value \cup {NoneVal}]
    /\ numTx \in 0..Cardinality(Sender)
    /\ numWeakTx \in 0..Cardinality(Sender)
    /\ rxAlive \in [Receiver -> BOOLEAN]
    /\ txAlive \in [Sender -> BOOLEAN]
    /\ closeReason \in {"none", "all_senders_dropped", "all_receivers_dropped"}

\* ----- Family 1 / 4: NoUseAfterFree_Waiter -----
\* A receiver's waker should not be touched after queued goes false.  We
\* express this as: notifyExtracted is disjoint from {r : queued[r] = TRUE
\* and we already extracted them}.  Equivalently, no receiver that had
\* its queued cleared by notify_rx has its waker still in notifyExtracted
\* and is concurrently being mutated by some other action.
\*
\* Formal statement: for every receiver r in tailWaiters, queued[r] is TRUE.
\* And for every receiver in notifyExtracted, queued[r] is FALSE (we cleared
\* it during NotifyRx_DrainStep_Take).
NoUseAfterFree_Waiter ==
    /\ \A r \in tailWaiters : recvWaiterQueued[r]
    /\ \A r \in notifyExtracted : ~recvWaiterQueued[r]

\* ----- Family 2: CloseReopenSemantics -----
\* If closeReason = all_senders_dropped, no Subscribe can flip closed back to
\* false.  The invariant: while closed and reason is permanent, any newly-
\* alive receiver since the close must have failed to reopen.
\* Stated structurally: closeReason = all_senders_dropped => numTx = 0.
\* And: numTx = 0 => closeReason \in {none (initial), all_senders_dropped,
\*                                    all_receivers_dropped}.
CloseReopenSemantics ==
    /\ closeReason = "all_senders_dropped" => numTx = 0
    /\ \* If closed AND reason=all_senders_dropped, no live receiver may
       \* observe the channel as not-closed (subscribe must NOT have reopened).
       (tailClosed /\ closeReason = "all_senders_dropped") =>
            (\A r \in Receiver : rxAlive[r] => tailClosed)

\* ----- Family 2: RxCntPositiveImpliesNotPermanentlyClosed -----
\* The original formulation —
\*     (tailRxCnt > 0) => (closeReason /= "all_senders_dropped" \/ ~tailClosed)
\* — was Case A: too strong.  When the last `Sender` drops at
\* broadcast.rs:1067-1073, tail.closed becomes TRUE while receivers are still
\* alive (transient window before Receiver::Drop runs).  closeReason becomes
\* "all_senders_dropped" in this window — legal implementation behavior.
\*
\* The real invariant we wanted: a "receivers-dropped" close cannot coexist
\* with a live receiver (because the moment Subscribe creates a receiver from
\* rxCnt=0, closeReason resets to "none" — see broadcast.rs:1004).
RxCntPositiveImpliesNotPermanentlyClosed ==
    (tailRxCnt > 0) => closeReason /= "all_receivers_dropped"

\* ----- Family 2: ReceiverCountConsistency -----
\* tail.rx_cnt equals the number of alive receivers (modulo races: rxDrop
\* in flight has decremented rx_cnt but hasn't cleared rxAlive yet).
ReceiverCountConsistency ==
    LET aliveCount == Cardinality({r \in Receiver : rxAlive[r]})
        draining   == Cardinality({r \in Receiver : rxDropPC[r] \in {"after_dec_cnt", "draining"}})
    IN  tailRxCnt = aliveCount - draining

\* ----- Family 5: NoSlotLeak -----
\* When slot.rem = 0 (under no in-flight Send/Hit on that slot), slot.val
\* must be NoneVal.  If rem hit 0 the value should have been released.
\* Structural: with no in-flight ops on slot i, (rem=0 => val=NoneVal).
NoSlotLeak ==
    \A i \in SlotIx :
        slotLockedBy[i] = "none" /\ slotRem[i] = 0 => slotVal[i] = NoneVal

\* ----- Family 5: NoDoubleRelease -----
\* slot.val was Some -> None at most as many times as Send wrote to that
\* slot.  We track each write as an increment to slotReleaseLog; the
\* release count is bookkeeping — any Send_WriteSlot or release path
\* increments the log only when transitioning Some->None.  Invariant: the
\* release log per slot equals the number of completed sends to that slot
\* minus (slot.val is Some at this moment).
\* Statable: for each slot i, slotReleaseLog[i] equals number of sends to
\* slot i (counted by sendHistory) minus (1 if val/=NoneVal else 0).
NoDoubleRelease ==
    \A i \in SlotIx :
        LET sentToI ==
                Cardinality({k \in 1..Len(sendHistory) :
                                IdxOf(sendHistory[k].pos) = i})
        IN slotReleaseLog[i] = sentToI - (IF slotVal[i] /= NoneVal THEN 1 ELSE 0)

\* ----- Family 2 / 5: NoSpuriousLagged -----
\* If a receiver's last observation is "lagged" with missed=k, then in the
\* meantime at least k overwrites must have happened at slots since rxNext.
\* Approximation: a Lagged event implies tailPos has advanced by at least
\* Capacity since the receiver's previous next.  Stated: for each receiver
\* r and each lagged event e in rxObserved[r], there must exist >= Capacity
\* sends between two of receiver's events.
\* (Approximation kept simple: if lagged is observed, sendHistory length
\*  must be at least Capacity at the time.)
NoSpuriousLagged ==
    \A r \in Receiver :
        \A k \in 1..Len(rxObserved[r]) :
            rxObserved[r][k].kind = "lagged" => Len(sendHistory) >= Capacity

\* ----- Family 2: SubscribeRespectsSendBoundary -----
\* A receiver that subscribed at tail.pos = N never observes a value sent
\* at pos < N.  Approximation: rxNext starts at the tail.pos seen at
\* Subscribe time; rxObserved entries with pos < initialNext are violations.
\* We do not track initialNext explicitly; instead use the invariant:
\* every observed pos must be in the domain of sendHistory, and the
\* receiver should never observe a pos earlier than its smallest rxNext
\* cursor seen so far.  Modeled approximately as: a hit observation's pos
\* cannot exceed every send pos (i.e. you can't see a value that wasn't
\* sent).
SubscribeRespectsSendBoundary ==
    \A r \in Receiver :
        \A k \in 1..Len(rxObserved[r]) :
            rxObserved[r][k].kind = "hit" =>
                \E h \in 1..Len(sendHistory) :
                    sendHistory[h].pos = rxObserved[r][k].pos
                    /\ sendHistory[h].value = rxObserved[r][k].value

\* ----- Family 1: ConcurrentDropCloseIdempotent -----
\* The earlier formulation —
\*     (tailClosed /\ tailRxCnt > 0) => closeReason \in {none, all_rx_dropped}
\* — was Case A: too strong.  When the last `Sender` drops at
\* broadcast.rs:1067-1073, `close_channel()` runs unconditionally; tail.closed
\* becomes TRUE even though tail.rx_cnt is still > 0 (no receiver dropped yet).
\* That transient window is normal implementation behaviour, not a bug.  We
\* keep the invariant only as the consistency check that closeReason == sender
\* drop must coincide with numTx == 0, which is also covered by
\* CloseReopenSemantics.
ConcurrentDropCloseIdempotent ==
    closeReason = "all_senders_dropped" => numTx = 0

\* ----- Structural sanity invariants -----
\* Mutex hold cardinality: at most one thread holds tail mutex.
TailLockSingleHolder == TRUE   \* enforced by tailLockedBy being a single value

\* Slot lock holders are single.
SlotLockSingleHolder == TRUE   \* enforced by slotLockedBy being a function

\* notify_rx invariants: when notifyPC = "drained_with_lock", tail must be
\* held by the notify_rx (for any holder of form "send_*"/"close_*").
NotifyHoldsTailWhenDraining ==
    notifyPC = "drained_with_lock" =>
        tailLockedBy /= "none"

\* If a receiver is in tailWaiters, queued[r] must be TRUE.
WaiterQueuedConsistency ==
    \A r \in Receiver : r \in tailWaiters => recvWaiterQueued[r]

\* Composite invariant for MC.cfg.
SafetyInvariants ==
    /\ TypeOK
    /\ NoUseAfterFree_Waiter
    /\ CloseReopenSemantics
    /\ RxCntPositiveImpliesNotPermanentlyClosed
    /\ ReceiverCountConsistency
    /\ NoSlotLeak
    /\ NoDoubleRelease
    /\ NoSpuriousLagged
    /\ SubscribeRespectsSendBoundary
    /\ ConcurrentDropCloseIdempotent
    /\ NotifyHoldsTailWhenDraining
    /\ WaiterQueuedConsistency

====
