---- MODULE base ----
\* ===========================================================================
\* TLA+ Specification: tokio broadcast channel
\* ===========================================================================
\*
\* Models the tokio broadcast channel — bounded MPMC broadcast queue.
\* Source: tokio/src/sync/broadcast.rs
\*
\* Bug Families:
\*   1. Channel Close Lifecycle (HIGH)
\*   2. Waiter Notification Protocol (HIGH)
\*   3. Slot Value Lifecycle / rem Counter (MEDIUM)
\*   4. Position Wraparound / Lag Arithmetic (MEDIUM)

EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Receiver,       \* Set of possible receiver IDs
    Value,          \* Set of values that can be sent
    Capacity,       \* Ring buffer capacity (must be power of 2)
    MaxPos,         \* Position space for wrapping arithmetic (>> 2 * Capacity)
    Nil             \* Null value marker

\* ===========================================================================
\* Derived constants
\* ===========================================================================

SlotIdx == 0..(Capacity - 1)

\* ===========================================================================
\* Wrapping position arithmetic
\* Models u64 wrapping_add / wrapping_sub -- broadcast.rs:644, 1306, 1308
\* ===========================================================================

WrapAdd(x, y) == (x + y) % MaxPos
WrapSub(x, y) == (x + MaxPos - y) % MaxPos

\* Ring buffer index from position -- broadcast.rs:641: (pos & mask) as usize
Idx(pos) == pos % Capacity

\* ===========================================================================
\* Variables
\* ===========================================================================

VARIABLES
    \* --- Tail struct (mutex-guarded) -- broadcast.rs:362-374 ---
    tailPos,        \* u64: next write position -- broadcast.rs:364
    rxCnt,          \* usize: active receiver count -- broadcast.rs:367
    closed,         \* bool: channel closed flag -- broadcast.rs:370

    \* --- Sender state ---
    numTx,          \* AtomicUsize: outstanding sender count -- broadcast.rs:352
    closePending,   \* Extension (Family 1): numTx hit 0 but close_channel()
                    \* not yet called -- models window in broadcast.rs:1069-1071

    \* --- Per-receiver state ---
    rxNext,         \* [Receiver -> 0..MaxPos-1]: next position to read -- broadcast.rs:244
    rxAlive,        \* [Receiver -> BOOLEAN]: whether receiver is subscribed

    \* --- Per-slot state (Slot struct, per-slot mutex) -- broadcast.rs:377-394 ---
    slotPos,        \* [SlotIdx -> 0..MaxPos-1]: position tag -- broadcast.rs:387
    slotRem,        \* [SlotIdx -> Nat]: remaining receivers to read -- broadcast.rs:384
    slotVal,        \* [SlotIdx -> Value ∪ {Nil}]: stored value -- broadcast.rs:393

    \* --- Waiter state (Family 2) -- broadcast.rs:370-374 ---
    waiters         \* Subset of Receiver: receivers waiting for a value

\* Variable grouping for UNCHANGED
coreVars    == <<tailPos, rxCnt, closed>>
senderVars  == <<numTx, closePending>>
rxVars      == <<rxNext, rxAlive>>
slotVars    == <<slotPos, slotRem, slotVal>>
waiterVars  == <<waiters>>

vars == <<coreVars, senderVars, rxVars, slotVars, waiterVars>>

\* ===========================================================================
\* Type invariant
\* ===========================================================================

TypeOK ==
    /\ tailPos \in 0..(MaxPos - 1)
    /\ rxCnt \in Nat
    /\ closed \in BOOLEAN
    /\ numTx \in Nat
    /\ closePending \in BOOLEAN
    /\ rxNext \in [Receiver -> 0..(MaxPos - 1)]
    /\ rxAlive \in [Receiver -> BOOLEAN]
    /\ slotPos \in [SlotIdx -> 0..(MaxPos - 1)]
    /\ slotRem \in [SlotIdx -> Nat]
    /\ \A i \in SlotIdx : slotVal[i] \in Value \cup {Nil}
    /\ waiters \subseteq Receiver

\* ===========================================================================
\* Helpers
\* ===========================================================================

\* Set of currently alive receivers
AliveReceivers == {r \in Receiver : rxAlive[r]}

\* Wrapping distance: number of pending messages for receiver r
PendingCount(r) == WrapSub(tailPos, rxNext[r])

\* Whether slot i holds a value pending for receiver r
\* (slotPos[i] is in the wrapping range [rxNext[r], tailPos))
SlotPendingFor(i, r) ==
    /\ PendingCount(r) > 0
    /\ WrapSub(slotPos[i], rxNext[r]) < PendingCount(r)

\* Minimum of two naturals
Min(a, b) == IF a < b THEN a ELSE b

\* ===========================================================================
\* Init
\* ===========================================================================
\* Models Sender::new(capacity) -- broadcast.rs:526-528
\* Channel starts with 1 sender, 0 receivers, closed=TRUE
\* (channel() would additionally create 1 receiver via new_receiver)

Init ==
    /\ tailPos = 0
    /\ rxCnt = 0
    /\ closed = TRUE                                    \* broadcast.rs:569: closed = (rx_count == 0)
    /\ numTx = 1                                        \* broadcast.rs:572
    /\ closePending = FALSE
    /\ rxNext = [r \in Receiver |-> 0]
    /\ rxAlive = [r \in Receiver |-> FALSE]
    \* Slots initialized with pos = i.wrapping_sub(capacity) -- broadcast.rs:558
    /\ slotPos = [i \in SlotIdx |-> WrapSub(i, Capacity)]
    /\ slotRem = [i \in SlotIdx |-> 0]                 \* broadcast.rs:557
    /\ slotVal = [i \in SlotIdx |-> Nil]                \* broadcast.rs:559: val: None
    /\ waiters = {}

\* ===========================================================================
\* Actions
\* ===========================================================================

\* --------------------------------------------------------------------------
\* Send(v): Sender broadcasts value v to the ring buffer
\* broadcast.rs:631-667
\*
\* Acquires tail lock, checks rx_cnt > 0, computes position,
\* advances tail, acquires slot lock, writes value + rem,
\* releases slot lock, calls notify_rx, releases tail lock.
\* --------------------------------------------------------------------------
Send(v) ==
    /\ numTx > 0                                        \* sender must exist
    /\ ~closePending                                    \* not mid-close sequence
    /\ LET pos == tailPos
           idx == Idx(pos)
       IN
       \* Check for receivers -- broadcast.rs:634: if tail.rx_cnt == 0
       /\ rxCnt > 0
       \* Advance tail position -- broadcast.rs:644: tail.pos = tail.pos.wrapping_add(1)
       /\ tailPos' = WrapAdd(pos, 1)
       \* Write to slot under slot lock -- broadcast.rs:647-656
       /\ slotPos' = [slotPos EXCEPT ![idx] = pos]     \* broadcast.rs:650: slot.pos = pos
       /\ slotRem' = [slotRem EXCEPT ![idx] = rxCnt]   \* broadcast.rs:653: *v = rem
       /\ slotVal' = [slotVal EXCEPT ![idx] = v]        \* broadcast.rs:656: slot.val = Some(value)
       \* Notify waiting receivers -- broadcast.rs:664: self.shared.notify_rx(tail)
       \* Modeled as atomic clear (see Family 2 discussion in MC spec)
       /\ waiters' = {}
    /\ UNCHANGED <<rxCnt, closed, senderVars, rxVars>>

\* --------------------------------------------------------------------------
\* Subscribe(r): New receiver subscribes to the channel
\* broadcast.rs:924-942 (new_receiver)
\*
\* Called via Sender::subscribe (requires live sender) or
\* Receiver::resubscribe (requires live receiver).
\* Acquires tail lock, potentially re-opens channel, increments rx_cnt.
\* --------------------------------------------------------------------------
Subscribe(r) ==
    /\ ~rxAlive[r]                                      \* not already subscribed
    \* Must have a way to call subscribe:
    \*   Sender::subscribe -- broadcast.rs:692: requires numTx > 0
    \*   Receiver::resubscribe -- broadcast.rs:1391: requires live receiver
    /\ numTx > 0 \/ Cardinality(AliveReceivers) > 0
    \* Under tail lock -- broadcast.rs:925: let mut tail = shared.tail.lock()
    \* Re-open if rx_cnt was 0 -- broadcast.rs:929-933
    /\ closed' = IF rxCnt = 0 THEN FALSE ELSE closed
    \* Increment rx_cnt -- broadcast.rs:936: tail.rx_cnt = tail.rx_cnt.checked_add(1)
    /\ rxCnt' = rxCnt + 1
    \* Set next to current tail -- broadcast.rs:937: let next = tail.pos
    /\ rxNext' = [rxNext EXCEPT ![r] = tailPos]
    /\ rxAlive' = [rxAlive EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<tailPos, senderVars, slotVars, waiterVars>>

\* --------------------------------------------------------------------------
\* RecvSuccess(r): Receiver reads a value from the ring buffer
\* broadcast.rs:1222-1328 (recv_ref) + broadcast.rs:1712-1719 (RecvGuard::drop)
\*
\* Fast path: slot.pos == self.next -- broadcast.rs:1232
\* Slow path recovery: slot.pos changed during lock shuffle -- broadcast.rs:1313
\* Combined with RecvGuard::drop which decrements rem.
\* --------------------------------------------------------------------------
RecvSuccess(r) ==
    /\ rxAlive[r]
    /\ r \notin waiters                                 \* not currently waiting
    /\ LET idx == Idx(rxNext[r]) IN
       \* Slot has value at expected position -- broadcast.rs:1232: if slot.pos != self.next
       /\ slotPos[idx] = rxNext[r]
       /\ slotVal[idx] /= Nil                           \* value present
       \* Advance receiver position -- broadcast.rs:1325: self.next = self.next.wrapping_add(1)
       /\ rxNext' = [rxNext EXCEPT ![r] = WrapAdd(rxNext[r], 1)]
       \* RecvGuard::drop -- broadcast.rs:1715: rem.fetch_sub(1, SeqCst)
       /\ slotRem' = [slotRem EXCEPT ![idx] = @ - 1]
       \* Drop value if last receiver -- broadcast.rs:1716: self.slot.val = None
       /\ slotVal' = IF slotRem[idx] = 1
                     THEN [slotVal EXCEPT ![idx] = Nil]
                     ELSE slotVal
    /\ UNCHANGED <<coreVars, senderVars, rxAlive, slotPos, waiterVars>>

\* --------------------------------------------------------------------------
\* RecvEmpty(r): Receiver finds channel empty, registers as waiter
\* broadcast.rs:1252-1298 (recv_ref slow path, empty case)
\*
\* Entered when slot.pos != self.next after acquiring tail lock.
\* next_pos == self.next indicates no value written yet.
\* --------------------------------------------------------------------------
RecvEmpty(r) ==
    /\ rxAlive[r]
    /\ r \notin waiters                                 \* not already waiting
    /\ LET idx == Idx(rxNext[r]) IN
       \* Slot position mismatch -- broadcast.rs:1252: if slot.pos != self.next
       /\ slotPos[idx] /= rxNext[r]
       \* Empty check -- broadcast.rs:1253-1255: next_pos = slot.pos.wrapping_add(cap)
       \* next_pos == self.next → empty
       /\ WrapAdd(slotPos[idx], Capacity) = rxNext[r]
       \* Channel not closed -- broadcast.rs:1259: if tail.closed
       /\ ~closed
    \* Register as waiter -- broadcast.rs:1280-1288
    /\ waiters' = waiters \cup {r}
    /\ UNCHANGED <<coreVars, senderVars, rxVars, slotVars>>

\* --------------------------------------------------------------------------
\* RecvClosed(r): Receiver finds channel closed and empty
\* broadcast.rs:1259-1260 (recv_ref, tail.closed check)
\* --------------------------------------------------------------------------
RecvClosed(r) ==
    /\ rxAlive[r]
    /\ LET idx == Idx(rxNext[r]) IN
       \* Channel empty for this receiver -- broadcast.rs:1252-1255
       /\ slotPos[idx] /= rxNext[r]
       /\ WrapAdd(slotPos[idx], Capacity) = rxNext[r]
       \* Channel is closed -- broadcast.rs:1259: if tail.closed
       /\ closed
    \* No state change; caller receives Err(Closed)
    /\ UNCHANGED vars

\* --------------------------------------------------------------------------
\* RecvLagged(r): Receiver has lagged behind, recovers to oldest position
\* broadcast.rs:1300-1321 (recv_ref lag recovery)
\*
\* Slot was overwritten; receiver computes oldest available position
\* and either reads it (missed==0) or jumps ahead (missed>0).
\* --------------------------------------------------------------------------
RecvLagged(r) ==
    /\ rxAlive[r]
    /\ r \notin waiters
    /\ LET idx == Idx(rxNext[r]) IN
       \* Slot position mismatch -- broadcast.rs:1252
       /\ slotPos[idx] /= rxNext[r]
       \* NOT empty (overwritten, not waiting) -- broadcast.rs:1255
       /\ WrapAdd(slotPos[idx], Capacity) /= rxNext[r]
       \* Compute oldest position -- broadcast.rs:1306
       /\ LET oldest == WrapSub(tailPos, Capacity)
              missed == WrapSub(oldest, rxNext[r])
          IN
          IF missed = 0
          THEN
              \* Slow but caught up -- broadcast.rs:1313-1316
              \* Read the value at current slot (fast path succeeded after re-lock)
              /\ slotVal[idx] /= Nil
              /\ rxNext' = [rxNext EXCEPT ![r] = WrapAdd(rxNext[r], 1)]
              /\ slotRem' = [slotRem EXCEPT ![idx] = @ - 1]
              /\ slotVal' = IF slotRem[idx] = 1
                            THEN [slotVal EXCEPT ![idx] = Nil]
                            ELSE slotVal
              /\ UNCHANGED <<coreVars, senderVars, rxAlive, slotPos, waiterVars>>
          ELSE
              \* Actually lagged — skip to oldest -- broadcast.rs:1319
              /\ rxNext' = [rxNext EXCEPT ![r] = oldest]
              /\ UNCHANGED <<coreVars, senderVars, rxAlive, slotVars, waiterVars>>

\* --------------------------------------------------------------------------
\* SenderDrop: A sender handle is dropped (step 1 of close sequence)
\* broadcast.rs:1067-1073 (Sender::drop)
\*
\* Atomically decrements num_tx. If last sender, sets closePending.
\* Family 1: Split into two steps to model the inconsistency window
\* where numTx=0 but closed=FALSE (between fetch_sub and close_channel).
\* --------------------------------------------------------------------------
SenderDrop ==
    /\ numTx > 0
    /\ ~closePending
    \* Atomic decrement -- broadcast.rs:1069: num_tx.fetch_sub(1, AcqRel)
    /\ numTx' = numTx - 1
    \* If last sender, begin close sequence -- broadcast.rs:1069-1071
    /\ closePending' = (numTx = 1)
    /\ UNCHANGED <<coreVars, rxVars, slotVars, waiterVars>>

\* --------------------------------------------------------------------------
\* CloseChannel: Complete the close sequence (step 2)
\* broadcast.rs:905-910 (close_channel)
\*
\* Acquires tail lock, sets closed=TRUE, notifies waiters.
\* Family 1: This fires AFTER SenderDrop when closePending=TRUE.
\* --------------------------------------------------------------------------
CloseChannel ==
    /\ closePending
    \* Acquire tail lock -- broadcast.rs:906: let mut tail = self.shared.tail.lock()
    \* Set closed flag -- broadcast.rs:907: tail.closed = true
    /\ closed' = TRUE
    /\ closePending' = FALSE
    \* Notify waiting receivers -- broadcast.rs:909: self.shared.notify_rx(tail)
    /\ waiters' = {}
    /\ UNCHANGED <<tailPos, rxCnt, numTx, rxVars, slotVars>>

\* --------------------------------------------------------------------------
\* SenderClone: A sender handle is cloned
\* broadcast.rs:1058-1064
\* --------------------------------------------------------------------------
SenderClone ==
    /\ numTx > 0                                        \* must have a sender to clone
    /\ ~closePending
    \* Atomic increment -- broadcast.rs:1061: num_tx.fetch_add(1, Relaxed)
    /\ numTx' = numTx + 1
    /\ UNCHANGED <<coreVars, closePending, rxVars, slotVars, waiterVars>>

\* --------------------------------------------------------------------------
\* ReceiverDrop(r): Receiver is dropped, cleans up pending slots
\* broadcast.rs:1548-1574
\*
\* Under tail lock: decrement rx_cnt, set closed if last.
\* Then cleanup loop: call recv_ref for each pending slot to decrement rem.
\* Family 4: Uses non-wrapping `<` comparison (broadcast.rs:1563).
\*
\* Cleanup is modeled as atomic decrement of rem for all pending slots.
\* This over-approximates the last-receiver case (where the loop would
\* break on Closed for lagged slots), but is sound because the channel
\* is dead after the last receiver drops.
\* --------------------------------------------------------------------------
ReceiverDrop(r) ==
    /\ rxAlive[r]
    /\ LET until == tailPos IN
       \* Under tail lock -- broadcast.rs:1550
       \* Decrement rx_cnt -- broadcast.rs:1552: tail.rx_cnt -= 1
       /\ rxCnt' = rxCnt - 1
       \* Set closed if last receiver -- broadcast.rs:1556-1558
       /\ closed' = IF rxCnt = 1 THEN TRUE ELSE closed
       \* Mark receiver as dead
       /\ rxAlive' = [rxAlive EXCEPT ![r] = FALSE]
       \* Remove from waiters if present
       /\ waiters' = waiters \ {r}
       \* Cleanup loop -- broadcast.rs:1563-1573
       \* BUG FAMILY 4: `while self.next < until` uses non-wrapping comparison.
       \* With wrapping positions, rxNext[r] > until (in standard arithmetic)
       \* causes the loop to skip entirely, leaving rem un-decremented.
       /\ LET loopRuns == rxNext[r] < until             \* NON-WRAPPING (broadcast.rs:1563)
          IN
          /\ slotRem' = [i \in SlotIdx |->
              IF /\ loopRuns
                 /\ slotRem[i] > 0
                 /\ SlotPendingFor(i, r)
              THEN slotRem[i] - 1
              ELSE slotRem[i]]
          /\ slotVal' = [i \in SlotIdx |->
              IF /\ loopRuns
                 /\ slotRem[i] > 0
                 /\ SlotPendingFor(i, r)
                 /\ slotRem[i] = 1                      \* last reader drops value
              THEN Nil
              ELSE slotVal[i]]
    /\ UNCHANGED <<tailPos, senderVars, rxNext, slotPos>>

\* --------------------------------------------------------------------------
\* DeregisterWaiter(r): Waiting receiver's Recv future is dropped
\* broadcast.rs:1625-1662 (Recv::drop)
\*
\* Removes receiver from waiters list under tail lock.
\* Models cancellation of async recv().
\* --------------------------------------------------------------------------
DeregisterWaiter(r) ==
    /\ r \in waiters
    /\ waiters' = waiters \ {r}
    /\ UNCHANGED <<coreVars, senderVars, rxVars, slotVars>>

\* ===========================================================================
\* Next-state relation
\* ===========================================================================

Next ==
    \/ \E v \in Value : Send(v)
    \/ \E r \in Receiver : Subscribe(r)
    \/ \E r \in Receiver : RecvSuccess(r)
    \/ \E r \in Receiver : RecvEmpty(r)
    \/ \E r \in Receiver : RecvLagged(r)
    \/ SenderDrop
    \/ SenderClone
    \/ CloseChannel
    \/ \E r \in Receiver : ReceiverDrop(r)
    \/ \E r \in Receiver : DeregisterWaiter(r)

Spec == Init /\ [][Next]_vars

\* ===========================================================================
\* Safety Invariants
\* ===========================================================================

\* --- Family 3: Slot value lifecycle ---

\* rem never goes negative
RemNonNegative ==
    \A i \in SlotIdx : slotRem[i] >= 0

\* Value dropped iff rem reaches 0
\* (RecvGuard::drop sets val=Nil when rem hits 0 -- broadcast.rs:1715-1717)
ValueLifecycle ==
    \A i \in SlotIdx :
        slotRem[i] = 0 => slotVal[i] = Nil

\* --- Family 4: Position bounds ---

\* After lag recovery (RecvLagged), receiver is within valid range.
\* Note: PendingCount(r) > Capacity is NORMAL before lag recovery —
\* the receiver discovers lag on next recv_ref call.
\* This invariant checks a weaker bound: positions are always valid.
LagBounded ==
    \A r \in Receiver :
        rxAlive[r] => PendingCount(r) < MaxPos

\* ===========================================================================
\* Extension Invariants (Bug Family targets — for MC hunting configs)
\* ===========================================================================

\* --- Family 1: Close lifecycle ---

\* After close sequence completes, closed flag must be TRUE
CloseConsistency ==
    (numTx = 0 /\ ~closePending) => closed

\* No receiver should be waiting on a fully closed channel
\* (CloseChannel and ReceiverDrop both clear waiters when setting closed)
NoStaleWaiter ==
    closed => waiters = {}

\* If numTx=0, no receiver should see Empty (should see Closed)
\* EXPECTED VIOLATION during closePending window (Family 1 MC-1 finding)
NoEmptyDuringClose ==
    numTx = 0 => waiters = {}

\* --- Family 3: rem bounded by actual readers ---

\* Slot rem should not exceed the number of alive receivers that still
\* need to read it. Violation indicates cleanup failure.
NoOrphanedRem ==
    \A i \in SlotIdx :
        slotVal[i] /= Nil =>
            slotRem[i] <= Cardinality({r \in AliveReceivers : SlotPendingFor(i, r)})

\* ===========================================================================
\* Structural Invariants
\* ===========================================================================

\* rx_cnt matches the number of alive receivers
RxCntConsistency ==
    rxCnt = Cardinality(AliveReceivers)

\* Only alive receivers can be waiters
WaitersAlive ==
    waiters \subseteq AliveReceivers

\* closePending implies numTx = 0
ClosePendingImpliesNoSenders ==
    closePending => numTx = 0

\* Closed channel with receivers means no senders
\* (closed is set by CloseChannel or last ReceiverDrop)
ClosedConsistentWithSenders ==
    (closed /\ rxCnt > 0) => (numTx = 0 \/ closePending)

====
