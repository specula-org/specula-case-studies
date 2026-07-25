---- MODULE base ----
\* ===================================================================================
\* TLA+ Specification: kanal — High-Performance MPMC Channel (Rust)
\* ===================================================================================
\*
\* Models the concurrent bounded/unbounded MPMC channel with mutex-based
\* synchronization and signal-based rendezvous.
\*
\* Bug Family 1: Signal Lifecycle Races (HIGH)
\*   Historical: 8+ race condition bugs (Issues #2, #8, #11, #14, #15, #17, #19)
\*   Mechanism: Signal handoff protocol (push to wait_list → pop → write/read → signal)
\*   has timing windows. wait() CAS failure with LOCKED_STARVATION after wait_timeout()
\*   can cause premature return → use-after-free / data race.
\*
\* Bug Family 2: Async Future Cancellation / Drop (HIGH)
\*   Historical: Issues #24, #47, #50, #59
\*   Mechanism: ReceiveFuture::drop push_front can exceed capacity.
\*   SendManyFuture silently drops data on error. ReceiveFuture cancellation on
\*   rendezvous channel loses data.
\*
\* Bug Family 3: Close Protocol and Half-Close Detection (MEDIUM)
\*   Historical: Issues #13, #59; commit cb130b6
\*   Mechanism: Channel close must terminate all pending signals and coordinate
\*   with in-progress operations via ref_count protocol.
\*
\* Source: github.com/fereidani/kanal

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ===================================================================================
\* Constants
\* ===================================================================================

CONSTANTS
    Thread,       \* Set of threads participating in channel operations
    Data,         \* Set of data values that can be sent through the channel
    Capacity,     \* Channel buffer capacity (0 = rendezvous)
    NilData       \* Sentinel for "no data"

ASSUME Capacity >= 0
ASSUME NilData \notin Data

\* ===================================================================================
\* Signal States (signal.rs:19-25)
\* ===================================================================================

LOCKED           == "LOCKED"
LOCKED_STARVATION == "LOCKED_STARVATION"
UNLOCKED         == "UNLOCKED"
TERMINATED       == "TERMINATED"

\* ===================================================================================
\* Signal Ownership Tracking (Family 1: signal lifecycle)
\* ===================================================================================

OWN_WAITLIST == "WaitList"     \* Signal is in the wait_list
OWN_SENDER   == "Sender"       \* Counterpart (sender) popped signal
OWN_RECEIVER == "Receiver"     \* Counterpart (receiver) popped signal
OWN_NONE     == "None"         \* Signal not active

\* ===================================================================================
\* Data Location Tracking (Family 1 + Family 2)
\* ===================================================================================

LOC_SENDER    == "SenderStack"    \* Data owned by sender
LOC_INLINE    == "Inline"         \* Data in signal's data field
LOC_RECEIVER  == "ReceiverStack"  \* Data transferred to receiver
LOC_CONSUMED  == "Consumed"       \* Data consumed/dropped
LOC_QUEUE     == "Queue"          \* Data in channel queue
LOC_LOST      == "Lost"           \* Data lost (Family 2: cancel bug)

\* ===================================================================================
\* Thread Roles
\* ===================================================================================

ROLE_IDLE     == "Idle"
ROLE_SENDER   == "Sender"
ROLE_RECEIVER == "Receiver"

\* ===================================================================================
\* Variables
\* ===================================================================================

VARIABLES
    \* --- Channel Core State (internal.rs:141-156) ---
    queue,           \* Seq(Data): bounded buffer (internal.rs:144)
    recvBlocking,    \* BOOLEAN: TRUE if wait_list holds recv signals (internal.rs:146)
    waitList,        \* Seq(Thread): ordered wait_list of signal owners (internal.rs:149)

    \* --- Ref Counting (internal.rs:151-155, Family 3) ---
    sendCount,       \* Nat: number of alive senders (internal.rs:152)
    recvCount,       \* Nat: number of alive receivers (internal.rs:154)
    refCount,        \* Nat: total alive handles (internal.rs:155)

    \* --- Signal State Machine (signal.rs, Family 1) ---
    signalState,     \* [Thread -> {LOCKED, LOCKED_STARVATION, UNLOCKED, TERMINATED}]
    signalOwner,     \* [Thread -> {OWN_WAITLIST, OWN_SENDER, OWN_RECEIVER, OWN_NONE}]
    signalData,      \* [Thread -> Data \cup {NilData}]: data attached to signal

    \* --- Data Ownership Tracking (Family 1 + Family 2) ---
    dataLocation,    \* [Data -> {LOC_SENDER, LOC_INLINE, ..., LOC_LOST}]

    \* --- Thread State ---
    role,            \* [Thread -> {ROLE_IDLE, ROLE_SENDER, ROLE_RECEIVER}]
    threadData,      \* [Thread -> Data \cup {NilData}]: data thread is working with
    threadDone,      \* [Thread -> BOOLEAN]: whether thread completed its operation

    \* --- Timeout + Starvation (signal.rs:217-261, Family 1) ---
    timedOut,        \* [Thread -> BOOLEAN]: thread's wait_timeout expired

    \* --- Async Future State (future.rs, Family 2) ---
    futureDropped,   \* [Thread -> BOOLEAN]: future was cancelled/dropped mid-operation

    \* --- Channel Open State (Family 3) ---
    channelOpen      \* BOOLEAN: FALSE after explicit close()

\* Variable groups for UNCHANGED
channelVars   == <<queue, recvBlocking, waitList>>
refVars       == <<sendCount, recvCount, refCount>>
signalVars    == <<signalState, signalOwner, signalData>>
dataVars      == <<dataLocation>>
threadVars    == <<role, threadData, threadDone>>
timeoutVars   == <<timedOut>>
futureVars    == <<futureDropped>>
closeVars     == <<channelOpen>>

vars == <<channelVars, refVars, signalVars, dataVars, threadVars,
          timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Helpers
\* ===================================================================================

\* Queue helpers
QueueLen      == Len(queue)
QueueNotFull  == Capacity > 0 /\ QueueLen < Capacity
QueueNotEmpty == Capacity > 0 /\ QueueLen > 0

\* Waitlist helpers — next_recv (internal.rs:193-204)
HasRecvWaiter == recvBlocking /\ Len(waitList) > 0

\* Waitlist helpers — next_send (internal.rs:172-183)
HasSendWaiter == ~recvBlocking /\ Len(waitList) > 0

\* Remove first element from sequence
RemoveFirst(s) == SubSeq(s, 2, Len(s))

\* Remove element at index from sequence
RemoveAt(s, i) == SubSeq(s, 1, i-1) \o SubSeq(s, i+1, Len(s))

\* Check if thread t is in the waitList
InWaitList(t) == \E i \in 1..Len(waitList) : waitList[i] = t

\* ===================================================================================
\* Init
\* ===================================================================================

Init ==
    \* Channel starts with empty queue, recv_blocking=false (internal.rs:43-51)
    /\ queue = <<>>
    /\ recvBlocking = FALSE
    /\ waitList = <<>>
    \* Initial ref counts: 1 sender, 1 receiver, ref_count=2 (internal.rs:48-50)
    /\ sendCount = 1
    /\ recvCount = 1
    /\ refCount = 2
    \* All signals start inactive
    /\ signalState = [t \in Thread |-> LOCKED]
    /\ signalOwner = [t \in Thread |-> OWN_NONE]
    /\ signalData = [t \in Thread |-> NilData]
    \* All data starts with sender (in abstract, not yet in system)
    /\ dataLocation = [d \in Data |-> LOC_SENDER]
    \* All threads idle
    /\ role = [t \in Thread |-> ROLE_IDLE]
    /\ threadData = [t \in Thread |-> NilData]
    /\ threadDone = [t \in Thread |-> FALSE]
    /\ timedOut = [t \in Thread |-> FALSE]
    /\ futureDropped = [t \in Thread |-> FALSE]
    /\ channelOpen = TRUE

\* ===================================================================================
\* Action: Send (lib.rs:607-637)
\* Sender acquires lock, checks if receivers exist, tries to hand off directly,
\* buffer in queue, or push signal to waitlist.
\* ===================================================================================

\* --- Path 1: Direct handoff to waiting receiver (lib.rs:614-618) ---
SendDirectHandoff(sender) ==
    /\ role[sender] = ROLE_IDLE
    /\ sendCount > 0
    /\ channelOpen
    /\ \E d \in Data :
        /\ dataLocation[d] = LOC_SENDER
        \* Acquire lock, check recv_count > 0 (lib.rs:610)
        /\ recvCount > 0
        \* next_recv() returns a receiver signal (internal.rs:193-204)
        /\ HasRecvWaiter
        /\ LET receiver == Head(waitList) IN
           \* Pop the first receiver from waitlist (internal.rs:196)
           /\ waitList' = RemoveFirst(waitList)
           \* Toggle recvBlocking if waitList now empty (internal.rs:199)
           /\ recvBlocking' = IF Len(waitList) = 1 THEN FALSE ELSE recvBlocking
           \* DynamicSignal::send → write_data (signal.rs:161-168)
           \* Step 1: copy data into signal (signal.rs:163-164)
           /\ signalData' = [signalData EXCEPT ![receiver] = d]
           \* Step 2: swap state to UNLOCKED (signal.rs:166)
           /\ signalState' = [signalState EXCEPT ![receiver] = UNLOCKED]
           /\ signalOwner' = [signalOwner EXCEPT ![receiver] = OWN_SENDER]
           \* Data moves from sender to receiver
           /\ dataLocation' = [dataLocation EXCEPT ![d] = LOC_RECEIVER]
           /\ threadData' = [threadData EXCEPT ![sender] = d]
           /\ threadDone' = [threadDone EXCEPT ![sender] = TRUE]
           /\ role' = [role EXCEPT ![sender] = ROLE_SENDER]
    /\ UNCHANGED <<queue, refVars, timeoutVars, futureVars, closeVars>>

\* --- Path 2: Buffer in queue (lib.rs:620-623) ---
SendToQueue(sender) ==
    /\ role[sender] = ROLE_IDLE
    /\ sendCount > 0
    /\ channelOpen
    /\ \E d \in Data :
        /\ dataLocation[d] = LOC_SENDER
        \* Acquire lock, check recv_count > 0 (lib.rs:610)
        /\ recvCount > 0
        \* No waiting receiver: next_recv returns None (internal.rs:193-204)
        /\ ~HasRecvWaiter
        \* Queue has capacity (lib.rs:620)
        /\ QueueNotFull
        \* push_back(data) (lib.rs:622)
        /\ queue' = Append(queue, d)
        /\ dataLocation' = [dataLocation EXCEPT ![d] = LOC_QUEUE]
        /\ threadData' = [threadData EXCEPT ![sender] = d]
        /\ threadDone' = [threadDone EXCEPT ![sender] = TRUE]
        /\ role' = [role EXCEPT ![sender] = ROLE_SENDER]
    /\ UNCHANGED <<recvBlocking, waitList, refVars, signalVars, timeoutVars,
                   futureVars, closeVars>>

\* --- Path 3: Block on signal in waitlist (lib.rs:625-636) ---
SendBlock(sender) ==
    /\ role[sender] = ROLE_IDLE
    /\ sendCount > 0
    /\ channelOpen
    /\ \E d \in Data :
        /\ dataLocation[d] = LOC_SENDER
        \* Acquire lock, check recv_count > 0 (lib.rs:610)
        /\ recvCount > 0
        \* No waiting receiver (internal.rs:193-204)
        /\ ~HasRecvWaiter
        \* Queue full or zero capacity (lib.rs:620 condition fails)
        /\ ~QueueNotFull
        \* Create signal, push to waitlist (lib.rs:627-628)
        /\ signalState' = [signalState EXCEPT ![sender] = LOCKED]
        /\ signalOwner' = [signalOwner EXCEPT ![sender] = OWN_WAITLIST]
        /\ signalData' = [signalData EXCEPT ![sender] = d]
        /\ dataLocation' = [dataLocation EXCEPT ![d] = LOC_INLINE]
        \* Push signal to waitlist — recv_blocking stays false as we are
        \* adding a send signal (internal.rs:187-189)
        /\ waitList' = Append(waitList, sender)
        /\ recvBlocking' = FALSE
        /\ role' = [role EXCEPT ![sender] = ROLE_SENDER]
        /\ threadData' = [threadData EXCEPT ![sender] = d]
        /\ threadDone' = [threadDone EXCEPT ![sender] = FALSE]
    /\ UNCHANGED <<queue, refVars, timeoutVars, futureVars, closeVars>>

\* --- Send returns error when recv_count == 0 (lib.rs:610-612) ---
SendClosed(sender) ==
    /\ role[sender] = ROLE_IDLE
    /\ sendCount > 0
    /\ \E d \in Data :
        /\ dataLocation[d] = LOC_SENDER
        \* recv_count == 0 (lib.rs:610)
        /\ recvCount = 0
        \* Data stays with sender (returned in SendError)
        /\ threadData' = [threadData EXCEPT ![sender] = d]
        /\ threadDone' = [threadDone EXCEPT ![sender] = TRUE]
        /\ role' = [role EXCEPT ![sender] = ROLE_SENDER]
    /\ UNCHANGED <<channelVars, refVars, signalVars, dataVars,
                   timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: Recv (lib.rs:1061-1106)
\* Receiver acquires lock, checks queue, tries direct handoff from sender,
\* or pushes recv signal to waitlist.
\* ===================================================================================

\* --- Path 1: Pop from queue + refill from sender (lib.rs:1067-1075) ---
RecvFromQueue(receiver) ==
    /\ role[receiver] = ROLE_IDLE
    /\ recvCount > 0
    /\ channelOpen
    \* Acquire lock, check recv_count > 0 (lib.rs:1064)
    /\ recvCount > 0
    \* Queue not empty (lib.rs:1068)
    /\ QueueNotEmpty
    /\ LET v == Head(queue) IN
       \* pop_front (lib.rs:1068)
       /\ queue' = IF HasSendWaiter
                   THEN \* Refill: take sender's data, push to queue (lib.rs:1069-1072)
                        LET senderT == Head(waitList) IN
                        LET senderData == signalData[senderT] IN
                        RemoveFirst(queue) \o <<senderData>>
                   ELSE RemoveFirst(queue)
       /\ waitList' = IF HasSendWaiter THEN RemoveFirst(waitList) ELSE waitList
       /\ recvBlocking' = IF HasSendWaiter /\ Len(waitList) = 1
                          THEN recvBlocking  \* was already false
                          ELSE recvBlocking
       \* If sender signal was popped: complete the signal handoff
       /\ signalState' = IF HasSendWaiter
                         THEN LET senderT == Head(waitList) IN
                              [signalState EXCEPT ![senderT] = UNLOCKED]
                         ELSE signalState
       /\ signalOwner' = IF HasSendWaiter
                         THEN LET senderT == Head(waitList) IN
                              [signalOwner EXCEPT ![senderT] = OWN_RECEIVER]
                         ELSE signalOwner
       /\ signalData' = IF HasSendWaiter
                        THEN LET senderT == Head(waitList) IN
                             [signalData EXCEPT ![senderT] = NilData]
                        ELSE signalData
       /\ dataLocation' = IF HasSendWaiter
                          THEN LET senderT == Head(waitList) IN
                               LET senderData == signalData[senderT] IN
                               [dataLocation EXCEPT
                                   ![v] = LOC_RECEIVER,
                                   ![senderData] = LOC_QUEUE]
                          ELSE [dataLocation EXCEPT ![v] = LOC_RECEIVER]
       /\ threadData' = [threadData EXCEPT ![receiver] = v]
       /\ threadDone' = [threadDone EXCEPT ![receiver] = TRUE]
       /\ role' = [role EXCEPT ![receiver] = ROLE_RECEIVER]
    /\ UNCHANGED <<refVars, timeoutVars, futureVars, closeVars>>

\* --- Path 2: Direct handoff from waiting sender (lib.rs:1077-1081) ---
RecvDirectHandoff(receiver) ==
    /\ role[receiver] = ROLE_IDLE
    /\ recvCount > 0
    /\ channelOpen
    /\ recvCount > 0
    \* Queue empty or zero-capacity (lib.rs:1067 condition fails)
    /\ ~QueueNotEmpty
    \* next_send() returns a sender signal (internal.rs:172-183)
    /\ HasSendWaiter
    /\ LET senderT == Head(waitList) IN
       LET d == signalData[senderT] IN
       \* Pop sender from waitlist (internal.rs:176)
       /\ waitList' = RemoveFirst(waitList)
       \* Toggle recvBlocking if waitList now empty (internal.rs:179)
       /\ recvBlocking' = IF Len(waitList) = 1 THEN TRUE ELSE recvBlocking
       \* DynamicSignal::recv → read_data (signal.rs:171-177)
       \* Step 1: read data from signal (signal.rs:173)
       \* Step 2: swap state to UNLOCKED (signal.rs:174)
       /\ signalState' = [signalState EXCEPT ![senderT] = UNLOCKED]
       /\ signalOwner' = [signalOwner EXCEPT ![senderT] = OWN_RECEIVER]
       /\ signalData' = [signalData EXCEPT ![senderT] = NilData]
       /\ dataLocation' = [dataLocation EXCEPT ![d] = LOC_RECEIVER]
       /\ threadData' = [threadData EXCEPT ![receiver] = d]
       /\ threadDone' = [threadDone EXCEPT ![receiver] = TRUE]
       /\ role' = [role EXCEPT ![receiver] = ROLE_RECEIVER]
    /\ UNCHANGED <<queue, refVars, timeoutVars, futureVars, closeVars>>

\* --- Path 3: Block on signal in waitlist (lib.rs:1085-1095) ---
RecvBlock(receiver) ==
    /\ role[receiver] = ROLE_IDLE
    /\ recvCount > 0
    /\ channelOpen
    /\ recvCount > 0
    \* Queue empty (lib.rs:1067-1068)
    /\ ~QueueNotEmpty
    \* No waiting sender (internal.rs:172-183)
    /\ ~HasSendWaiter
    \* send_count > 0 (lib.rs:1082)
    /\ sendCount > 0
    \* Create recv signal, push to waitlist (lib.rs:1087-1090)
    /\ signalState' = [signalState EXCEPT ![receiver] = LOCKED]
    /\ signalOwner' = [signalOwner EXCEPT ![receiver] = OWN_WAITLIST]
    /\ signalData' = [signalData EXCEPT ![receiver] = NilData]
    /\ waitList' = Append(waitList, receiver)
    /\ recvBlocking' = TRUE
    /\ role' = [role EXCEPT ![receiver] = ROLE_RECEIVER]
    /\ threadData' = [threadData EXCEPT ![receiver] = NilData]
    /\ threadDone' = [threadDone EXCEPT ![receiver] = FALSE]
    /\ UNCHANGED <<queue, refVars, dataVars, timeoutVars, futureVars, closeVars>>

\* --- Recv returns error when send_count == 0 and queue empty (lib.rs:1082-1083) ---
RecvClosed(receiver) ==
    /\ role[receiver] = ROLE_IDLE
    /\ recvCount > 0
    /\ \/ recvCount = 0
       \/ (/\ ~QueueNotEmpty
           /\ ~HasSendWaiter
           /\ sendCount = 0)
    /\ threadDone' = [threadDone EXCEPT ![receiver] = TRUE]
    /\ role' = [role EXCEPT ![receiver] = ROLE_RECEIVER]
    /\ threadData' = [threadData EXCEPT ![receiver] = NilData]
    /\ UNCHANGED <<channelVars, refVars, signalVars, dataVars,
                   timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: Signal Wait Completes (signal.rs:195-232)
\* After a thread blocks, the counterpart writes data and swaps state.
\* The blocking thread's wait() returns true (UNLOCKED) or false (TERMINATED).
\* ===================================================================================

\* --- Signal wait returns success: data transferred (signal.rs:199,209) ---
SignalWaitSuccess(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ signalOwner[t] /= OWN_WAITLIST  \* signal was popped by counterpart
    /\ signalState[t] = UNLOCKED
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    \* Receiver reads data from signal on wakeup (signal.rs:171-177)
    /\ IF role[t] = ROLE_RECEIVER /\ signalData[t] /= NilData
       THEN threadData' = [threadData EXCEPT ![t] = signalData[t]]
       ELSE UNCHANGED threadData
    /\ UNCHANGED <<channelVars, refVars, signalVars, dataVars,
                   timeoutVars, futureVars, closeVars>>
    /\ UNCHANGED role

\* --- Signal wait returns failure: terminated (signal.rs:231) ---
SignalWaitFailure(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ signalOwner[t] /= OWN_WAITLIST
    /\ signalState[t] = TERMINATED
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    \* For sender: data returns to sender (SendError) (lib.rs:634)
    /\ IF role[t] = ROLE_SENDER /\ threadData[t] /= NilData
       THEN dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
       ELSE UNCHANGED dataLocation
    /\ UNCHANGED <<channelVars, refVars, signalVars,
                   timeoutVars, futureVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* ===================================================================================
\* Action: WaitTimeout — CAS to LOCKED_STARVATION (signal.rs:241-260, Family 1)
\* Thread's wait_timeout expires, CAS(LOCKED → LOCKED_STARVATION).
\* If CAS fails because state is already UNLOCKED/TERMINATED, return immediately.
\* ===================================================================================

WaitTimeout(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ ~timedOut[t]
    /\ signalOwner[t] = OWN_WAITLIST  \* still in waitlist
    /\ signalState[t] = LOCKED        \* CAS succeeds only from LOCKED
    \* CAS(LOCKED → LOCKED_STARVATION) (signal.rs:241-246)
    /\ signalState' = [signalState EXCEPT ![t] = LOCKED_STARVATION]
    /\ timedOut' = [timedOut EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<channelVars, refVars, signalOwner, signalData, dataVars,
                   threadVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: WaitTimeoutRecheck — After timeout, check if signal was resolved
\* (signal.rs:248-255, Family 1: LOCKED_STARVATION gap)
\* If counterpart set state to UNLOCKED/TERMINATED between our CAS and this
\* check, the loop continues. But if we return false prematurely while
\* counterpart is still processing, that's the bug.
\* ===================================================================================

WaitTimeoutRecheck(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ timedOut[t]
    \* After timeout, re-check state (signal.rs:254-255)
    /\ signalState[t] \in {UNLOCKED, TERMINATED}
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ IF signalState[t] = TERMINATED /\ role[t] = ROLE_SENDER
          /\ threadData[t] /= NilData
       THEN dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
       ELSE UNCHANGED dataLocation
    /\ UNCHANGED <<channelVars, refVars, signalVars,
                   timeoutVars, futureVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* ===================================================================================
\* Action: WaitTimeoutCancel — After timeout, cancel signal from waitlist
\* (lib.rs:801-806: cancel_send_signal / lib.rs:1149-1151: cancel_recv_signal)
\* ===================================================================================

WaitTimeoutCancel(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ timedOut[t]
    /\ signalState[t] = LOCKED_STARVATION  \* still LOCKED_STARVATION
    /\ InWaitList(t)  \* signal still in waitlist
    \* cancel_send_signal / cancel_recv_signal (internal.rs:208-239)
    /\ waitList' = RemoveAt(waitList, CHOOSE idx \in 1..Len(waitList) : waitList[idx] = t)
    /\ signalOwner' = [signalOwner EXCEPT ![t] = OWN_NONE]
    /\ signalState' = [signalState EXCEPT ![t] = TERMINATED]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    \* For sender: data returns to sender (timeout error)
    /\ IF role[t] = ROLE_SENDER /\ threadData[t] /= NilData
       THEN /\ dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
            /\ signalData' = [signalData EXCEPT ![t] = NilData]
       ELSE UNCHANGED <<dataLocation, signalData>>
    /\ UNCHANGED <<queue, recvBlocking, refVars, timeoutVars, futureVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* ===================================================================================
\* Action: WaitTimeoutFallback — After timeout, cancel fails, must re-wait
\* (lib.rs:808-813: sig.wait() after cancel fails)
\* Signal was popped by counterpart between timeout and cancel attempt.
\* ===================================================================================

WaitTimeoutFallback(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    /\ timedOut[t]
    /\ ~InWaitList(t)  \* signal no longer in waitlist (counterpart popped it)
    /\ signalState[t] = LOCKED_STARVATION
    \* Must re-wait: counterpart will eventually write data and set UNLOCKED
    \* or terminate. The LOCKED_STARVATION state means counterpart will unpark
    \* this thread after completing (signal.rs:166-168).
    \* This is a no-op — thread continues waiting.
    /\ UNCHANGED vars

\* ===================================================================================
\* Action: Preempt — Delay counterpart between pop and write/read
\* (Family 1: fault injection for signal lifecycle race)
\* Models arbitrary preemption of the thread that popped a signal from waitlist.
\* ===================================================================================

Preempt(t) ==
    /\ role[t] \in {ROLE_SENDER, ROLE_RECEIVER}
    /\ ~threadDone[t]
    \* Signal was popped but state still LOCKED (counterpart hasn't written yet)
    /\ signalOwner[t] \in {OWN_SENDER, OWN_RECEIVER}
    /\ signalState[t] = LOCKED
    \* No-op: just delays the counterpart, allowing timeout thread to proceed
    /\ UNCHANGED vars

\* ===================================================================================
\* Action: DropRecvFuture — Async receive future dropped mid-operation
\* (future.rs:218-255, Family 2)
\* ===================================================================================

\* --- DropRecvFuture on rendezvous channel: data lost (future.rs:240-244) ---
DropRecvFutureRendezvous(t) ==
    /\ role[t] = ROLE_RECEIVER
    /\ ~threadDone[t]
    /\ ~futureDropped[t]
    /\ Capacity = 0  \* rendezvous (future.rs:239)
    \* Signal was completed — sender wrote data (future.rs:232)
    /\ signalState[t] = UNLOCKED
    /\ signalData[t] /= NilData
    \* Data is dropped — LOST (future.rs:244: self.sig.drop_data())
    /\ dataLocation' = [dataLocation EXCEPT ![signalData[t]] = LOC_LOST]
    /\ futureDropped' = [futureDropped EXCEPT ![t] = TRUE]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ signalData' = [signalData EXCEPT ![t] = NilData]
    /\ UNCHANGED <<channelVars, refVars, signalState, signalOwner,
                   timeoutVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* --- DropRecvFuture on buffered channel: push_front (future.rs:246-249) ---
\* BUG: push_front can exceed capacity! (Family 2, finding F2-1)
DropRecvFutureBuffered(t) ==
    /\ role[t] = ROLE_RECEIVER
    /\ ~threadDone[t]
    /\ ~futureDropped[t]
    /\ Capacity > 0  \* buffered channel (future.rs:245)
    \* Signal was completed — sender wrote data (future.rs:232)
    /\ signalState[t] = UNLOCKED
    /\ signalData[t] /= NilData
    \* push_front: data goes back to queue (future.rs:247-249)
    /\ queue' = <<signalData[t]>> \o queue
    /\ dataLocation' = [dataLocation EXCEPT ![signalData[t]] = LOC_QUEUE]
    /\ futureDropped' = [futureDropped EXCEPT ![t] = TRUE]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ signalData' = [signalData EXCEPT ![t] = NilData]
    /\ UNCHANGED <<recvBlocking, waitList, refVars, signalState, signalOwner,
                   timeoutVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* --- DropRecvFuture: cancel signal still in waitlist (future.rs:223-227) ---
DropRecvFutureCancel(t) ==
    /\ role[t] = ROLE_RECEIVER
    /\ ~threadDone[t]
    /\ ~futureDropped[t]
    /\ InWaitList(t)
    /\ signalState[t] \in {LOCKED, LOCKED_STARVATION}
    \* cancel_recv_signal succeeds (internal.rs:226-239)
    /\ waitList' = RemoveAt(waitList, CHOOSE idx \in 1..Len(waitList) : waitList[idx] = t)
    /\ signalOwner' = [signalOwner EXCEPT ![t] = OWN_NONE]
    /\ futureDropped' = [futureDropped EXCEPT ![t] = TRUE]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<queue, recvBlocking, refVars, signalState, signalData, dataVars,
                   timeoutVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* ===================================================================================
\* Action: DropSendFuture — Async send future dropped mid-operation
\* (future.rs:67-93, Family 2)
\* ===================================================================================

\* --- DropSendFuture: cancel signal still in waitlist (future.rs:77-79) ---
DropSendFutureCancel(t) ==
    /\ role[t] = ROLE_SENDER
    /\ ~threadDone[t]
    /\ ~futureDropped[t]
    /\ InWaitList(t)
    /\ signalState[t] \in {LOCKED, LOCKED_STARVATION}
    \* cancel_send_signal succeeds (internal.rs:208-222)
    /\ waitList' = RemoveAt(waitList, CHOOSE idx \in 1..Len(waitList) : waitList[idx] = t)
    /\ signalOwner' = [signalOwner EXCEPT ![t] = OWN_NONE]
    \* Data stays with sender — will be dropped (future.rs:89)
    /\ IF threadData[t] /= NilData
       THEN dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
       ELSE UNCHANGED dataLocation
    /\ signalData' = [signalData EXCEPT ![t] = NilData]
    /\ futureDropped' = [futureDropped EXCEPT ![t] = TRUE]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<queue, recvBlocking, refVars, signalState,
                   timeoutVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* --- DropSendFuture: signal already taken, wait for completion (future.rs:82-85) ---
DropSendFutureWait(t) ==
    /\ role[t] = ROLE_SENDER
    /\ ~threadDone[t]
    /\ ~futureDropped[t]
    /\ ~InWaitList(t)
    /\ signalState[t] \in {UNLOCKED, TERMINATED}
    \* Receiver took data: don't drop it (future.rs:84)
    /\ IF signalState[t] = UNLOCKED
       THEN UNCHANGED dataLocation  \* receiver owns data
       ELSE IF threadData[t] /= NilData
            THEN dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
            ELSE UNCHANGED dataLocation
    /\ futureDropped' = [futureDropped EXCEPT ![t] = TRUE]
    /\ threadDone' = [threadDone EXCEPT ![t] = TRUE]
    /\ signalData' = [signalData EXCEPT ![t] = NilData]
    /\ UNCHANGED <<channelVars, refVars, signalState, signalOwner,
                   timeoutVars, closeVars>>
    /\ UNCHANGED <<role, threadData>>

\* ===================================================================================
\* Action: ThreadReset — Thread completes and becomes idle again
\* ===================================================================================

ThreadReset(t) ==
    /\ threadDone[t]
    /\ role' = [role EXCEPT ![t] = ROLE_IDLE]
    /\ threadData' = [threadData EXCEPT ![t] = NilData]
    /\ threadDone' = [threadDone EXCEPT ![t] = FALSE]
    /\ signalOwner' = [signalOwner EXCEPT ![t] = OWN_NONE]
    /\ signalState' = [signalState EXCEPT ![t] = LOCKED]
    /\ signalData' = [signalData EXCEPT ![t] = NilData]
    /\ timedOut' = [timedOut EXCEPT ![t] = FALSE]
    /\ futureDropped' = [futureDropped EXCEPT ![t] = FALSE]
    \* Recycle consumed data: receiver's data returns to sender pool
    /\ IF role[t] = ROLE_RECEIVER /\ threadData[t] /= NilData
          /\ dataLocation[threadData[t]] = LOC_RECEIVER
       THEN dataLocation' = [dataLocation EXCEPT ![threadData[t]] = LOC_SENDER]
       ELSE UNCHANGED dataVars
    /\ UNCHANGED <<channelVars, refVars, closeVars>>

\* ===================================================================================
\* Action: CloneSender / CloneReceiver (internal.rs:270-285, Family 3)
\* ===================================================================================

CloneSender ==
    /\ sendCount > 0
    /\ sendCount' = sendCount + 1
    /\ refCount' = refCount + 1
    /\ UNCHANGED <<channelVars, recvCount, signalVars, dataVars, threadVars,
                   timeoutVars, futureVars, closeVars>>

CloneReceiver ==
    /\ recvCount > 0
    /\ recvCount' = recvCount + 1
    /\ refCount' = refCount + 1
    /\ UNCHANGED <<channelVars, sendCount, signalVars, dataVars, threadVars,
                   timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: DropSender (internal.rs:288-295, Family 3)
\* When send_count → 0 and recv_count != 0: terminate signals
\* ===================================================================================

DropSender ==
    /\ sendCount > 0
    /\ sendCount' = sendCount - 1
    /\ refCount' = refCount - 1
    \* If send_count becomes 0 and recv_count != 0: terminate_signals (internal.rs:293-294)
    /\ IF sendCount = 1 /\ recvCount > 0
       THEN \* Terminate all pending signals in waitlist (internal.rs:162-168)
            /\ signalState' = [t \in Thread |->
                 IF InWaitList(t) THEN TERMINATED ELSE signalState[t]]
            /\ waitList' = <<>>
       ELSE /\ UNCHANGED <<signalState, waitList>>
    /\ UNCHANGED <<queue, recvBlocking, recvCount, signalOwner, signalData,
                   dataVars, threadVars, timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: DropReceiver (internal.rs:296-303, Family 3)
\* When recv_count → 0: terminate signals AND clear queue
\* ===================================================================================

DropReceiver ==
    /\ recvCount > 0
    /\ recvCount' = recvCount - 1
    /\ refCount' = refCount - 1
    \* If recv_count becomes 0: terminate_signals + clear queue (internal.rs:299-301)
    /\ IF recvCount = 1
       THEN /\ signalState' = [t \in Thread |->
                 IF InWaitList(t) THEN TERMINATED ELSE signalState[t]]
            /\ waitList' = <<>>
            /\ queue' = <<>>
       ELSE /\ UNCHANGED <<signalState, waitList, queue>>
    /\ UNCHANGED <<recvBlocking, sendCount, signalOwner, signalData,
                   dataVars, threadVars, timeoutVars, futureVars, closeVars>>

\* ===================================================================================
\* Action: Close (lib.rs:237-247, Family 3)
\* Explicitly close channel: set both counts to 0, terminate all, clear queue.
\* ===================================================================================

Close ==
    /\ channelOpen
    /\ \/ sendCount > 0
       \/ recvCount > 0
    /\ sendCount' = 0
    /\ recvCount' = 0
    \* terminate_signals (internal.rs:162-168)
    /\ signalState' = [t \in Thread |->
         IF InWaitList(t) THEN TERMINATED ELSE signalState[t]]
    /\ waitList' = <<>>
    /\ queue' = <<>>
    /\ channelOpen' = FALSE
    /\ UNCHANGED <<recvBlocking, refCount, signalOwner, signalData,
                   dataVars, threadVars, timeoutVars, futureVars>>

\* ===================================================================================
\* Next State
\* ===================================================================================

Next ==
    \* --- Send paths ---
    \/ \E t \in Thread : SendDirectHandoff(t)
    \/ \E t \in Thread : SendToQueue(t)
    \/ \E t \in Thread : SendBlock(t)
    \/ \E t \in Thread : SendClosed(t)
    \* --- Recv paths ---
    \/ \E t \in Thread : RecvFromQueue(t)
    \/ \E t \in Thread : RecvDirectHandoff(t)
    \/ \E t \in Thread : RecvBlock(t)
    \/ \E t \in Thread : RecvClosed(t)
    \* --- Signal completion ---
    \/ \E t \in Thread : SignalWaitSuccess(t)
    \/ \E t \in Thread : SignalWaitFailure(t)
    \* --- Timeout/starvation (Family 1) ---
    \/ \E t \in Thread : WaitTimeout(t)
    \/ \E t \in Thread : WaitTimeoutRecheck(t)
    \/ \E t \in Thread : WaitTimeoutCancel(t)
    \/ \E t \in Thread : WaitTimeoutFallback(t)
    \* --- Preemption (Family 1 fault injection) ---
    \/ \E t \in Thread : Preempt(t)
    \* --- Future cancellation (Family 2) ---
    \/ \E t \in Thread : DropRecvFutureRendezvous(t)
    \/ \E t \in Thread : DropRecvFutureBuffered(t)
    \/ \E t \in Thread : DropRecvFutureCancel(t)
    \/ \E t \in Thread : DropSendFutureCancel(t)
    \/ \E t \in Thread : DropSendFutureWait(t)
    \* --- Thread lifecycle ---
    \/ \E t \in Thread : ThreadReset(t)
    \* --- Ref counting / close (Family 3) ---
    \/ CloneSender
    \/ CloneReceiver
    \/ DropSender
    \/ DropReceiver
    \/ Close

Spec == Init /\ [][Next]_vars

\* ===================================================================================
\* Invariants
\* ===================================================================================

\* --- Standard Safety: No data race on signal (Family 1) ---
\* Data attached to a signal must not be accessed concurrently by sender and receiver.
\* If signalState is LOCKED or LOCKED_STARVATION, only the owner (waitlist side) may touch data.
NoDataRace ==
    \A t \in Thread :
        signalState[t] \in {LOCKED, LOCKED_STARVATION} =>
            \/ signalOwner[t] = OWN_WAITLIST
            \/ signalOwner[t] = OWN_NONE

\* --- Standard Safety: Signal single use (Family 1) ---
\* A signal in UNLOCKED or TERMINATED state must not be in the waitlist
SignalSingleUse ==
    \A t \in Thread :
        signalState[t] \in {UNLOCKED, TERMINATED} =>
            ~InWaitList(t)

\* --- Extension: Wait Correctness (Family 1 — LOCKED_STARVATION bug) ---
\* If a thread timed out and its signal is LOCKED_STARVATION, and the signal
\* is no longer in the waitlist (counterpart popped it), the thread must NOT
\* consider the operation complete until counterpart finishes (sets UNLOCKED/TERMINATED).
WaitCorrectness ==
    \A t \in Thread :
        /\ timedOut[t]
        /\ signalState[t] = LOCKED_STARVATION
        /\ ~InWaitList(t)
        => ~threadDone[t]

\* --- Extension: No data loss (Family 2) ---
\* Every datum is either with sender, in queue, with receiver, or inline (in signal).
\* It must never be LOC_LOST.
NoDataLoss ==
    \A d \in Data :
        dataLocation[d] /= LOC_LOST

\* --- Extension: Capacity bound (Family 2 — push_front bug) ---
\* Queue length must never exceed capacity for bounded channels.
CapacityBound ==
    Capacity > 0 => QueueLen <= Capacity

\* --- Extension: No double free (Family 3) ---
\* ref_count must be non-negative (modeled as >= 0)
NoDoubleFree ==
    refCount >= 0

\* --- Extension: No hanging signals (Family 3) ---
\* When both send_count and recv_count are 0, no signals should be pending in waitlist.
NoHangingSignals ==
    (sendCount = 0 /\ recvCount = 0) => Len(waitList) = 0

\* --- Extension: Close terminates all (Family 3) ---
\* After close, no pending signals remain.
CloseTerminatesAll ==
    ~channelOpen => Len(waitList) = 0

\* --- Extension: Half-close detection (Family 3) ---
\* If recv_count = 0, senders with channelOpen should get errors.
\* If send_count = 0 and queue empty, receivers should get errors.
HalfCloseDetection ==
    /\ (recvCount = 0 => \A t \in Thread :
          (role[t] = ROLE_IDLE /\ sendCount > 0) =>
          \* Any new send attempt will return error (checked by SendClosed action)
          TRUE)
    /\ (sendCount = 0 /\ QueueLen = 0 => \A t \in Thread :
          (role[t] = ROLE_IDLE /\ recvCount > 0) =>
          \* Any new recv attempt will return error (checked by RecvClosed action)
          TRUE)

\* --- Structural: WaitList mode consistency ---
WaitListModeConsistency ==
    \* If recvBlocking, all waitlist entries must be receivers
    \* If ~recvBlocking, all waitlist entries must be senders
    \* (simplified: we just check the list isn't mixed)
    /\ recvBlocking => \A i \in 1..Len(waitList) :
         role[waitList[i]] = ROLE_RECEIVER \/ signalState[waitList[i]] = TERMINATED
    /\ ~recvBlocking => \A i \in 1..Len(waitList) :
         role[waitList[i]] = ROLE_SENDER \/ signalState[waitList[i]] = TERMINATED

\* --- Structural: Queue only contains valid data ---
QueueDataValid ==
    \A i \in 1..Len(queue) :
        /\ queue[i] \in Data
        /\ dataLocation[queue[i]] = LOC_QUEUE

\* --- Structural: Ref count consistency ---
RefCountConsistency ==
    refCount >= sendCount + recvCount

====
