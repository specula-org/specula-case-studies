---- MODULE MC ----
\* ===================================================================================
\* Model Checking Wrapper for kanal MPMC Channel
\* ===================================================================================
\*
\* Counter-bounded fault-injection actions for exhaustive state space exploration.
\* Wraps base.tla with bounded non-deterministic actions.

EXTENDS base

\* ===================================================================================
\* MC Constants (counter bounds)
\* ===================================================================================

CONSTANTS
    MaxSendLimit,      \* Max number of send operations
    MaxRecvLimit,      \* Max number of receive operations
    MaxTimeoutLimit,   \* Max number of timeout events (Family 1)
    MaxPreemptLimit,   \* Max preemptions (Family 1 fault injection)
    MaxDropFuture,     \* Max future drops (Family 2 fault injection)
    MaxCloneLimit,     \* Max sender/receiver clones (Family 3)
    MaxDropLimit,      \* Max sender/receiver drops (Family 3)
    MaxCloseLimit      \* Max close() calls (Family 3)

\* ===================================================================================
\* Counter Variables
\* ===================================================================================

VARIABLES
    cSend,        \* Send operation counter
    cRecv,        \* Recv operation counter
    cTimeout,     \* Timeout counter
    cPreempt,     \* Preemption counter
    cDropFuture,  \* Future drop counter
    cClone,       \* Clone counter
    cDrop,        \* Drop sender/receiver counter
    cClose        \* Close counter

faultVars == <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

mcVars == <<vars, faultVars>>

\* ===================================================================================
\* MCInit
\* ===================================================================================

MCInit ==
    /\ Init
    /\ cSend = 0
    /\ cRecv = 0
    /\ cTimeout = 0
    /\ cPreempt = 0
    /\ cDropFuture = 0
    /\ cClone = 0
    /\ cDrop = 0
    /\ cClose = 0

\* ===================================================================================
\* Counter-Bounded Actions: Send (bounded — introduces non-determinism)
\* ===================================================================================

MCSendDirectHandoff(t) ==
    /\ cSend < MaxSendLimit
    /\ SendDirectHandoff(t)
    /\ cSend' = cSend + 1
    /\ UNCHANGED <<cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCSendToQueue(t) ==
    /\ cSend < MaxSendLimit
    /\ SendToQueue(t)
    /\ cSend' = cSend + 1
    /\ UNCHANGED <<cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCSendBlock(t) ==
    /\ cSend < MaxSendLimit
    /\ SendBlock(t)
    /\ cSend' = cSend + 1
    /\ UNCHANGED <<cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCSendClosed(t) ==
    /\ cSend < MaxSendLimit
    /\ SendClosed(t)
    /\ cSend' = cSend + 1
    /\ UNCHANGED <<cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Recv (bounded — introduces non-determinism)
\* ===================================================================================

MCRecvFromQueue(t) ==
    /\ cRecv < MaxRecvLimit
    /\ RecvFromQueue(t)
    /\ cRecv' = cRecv + 1
    /\ UNCHANGED <<cSend, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCRecvDirectHandoff(t) ==
    /\ cRecv < MaxRecvLimit
    /\ RecvDirectHandoff(t)
    /\ cRecv' = cRecv + 1
    /\ UNCHANGED <<cSend, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCRecvBlock(t) ==
    /\ cRecv < MaxRecvLimit
    /\ RecvBlock(t)
    /\ cRecv' = cRecv + 1
    /\ UNCHANGED <<cSend, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

MCRecvClosed(t) ==
    /\ cRecv < MaxRecvLimit
    /\ RecvClosed(t)
    /\ cRecv' = cRecv + 1
    /\ UNCHANGED <<cSend, cTimeout, cPreempt, cDropFuture, cClone, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Timeout (Family 1 — bounded fault injection)
\* ===================================================================================

MCWaitTimeout(t) ==
    /\ cTimeout < MaxTimeoutLimit
    /\ WaitTimeout(t)
    /\ cTimeout' = cTimeout + 1
    /\ UNCHANGED <<cSend, cRecv, cPreempt, cDropFuture, cClone, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Preemption (Family 1 — bounded fault injection)
\* ===================================================================================

MCPreempt(t) ==
    /\ cPreempt < MaxPreemptLimit
    /\ Preempt(t)
    /\ cPreempt' = cPreempt + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cDropFuture, cClone, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Future Drops (Family 2 — bounded fault injection)
\* ===================================================================================

MCDropRecvFutureRendezvous(t) ==
    /\ cDropFuture < MaxDropFuture
    /\ DropRecvFutureRendezvous(t)
    /\ cDropFuture' = cDropFuture + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cClone, cDrop, cClose>>

MCDropRecvFutureBuffered(t) ==
    /\ cDropFuture < MaxDropFuture
    /\ DropRecvFutureBuffered(t)
    /\ cDropFuture' = cDropFuture + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cClone, cDrop, cClose>>

MCDropRecvFutureCancel(t) ==
    /\ cDropFuture < MaxDropFuture
    /\ DropRecvFutureCancel(t)
    /\ cDropFuture' = cDropFuture + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cClone, cDrop, cClose>>

MCDropSendFutureCancel(t) ==
    /\ cDropFuture < MaxDropFuture
    /\ DropSendFutureCancel(t)
    /\ cDropFuture' = cDropFuture + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cClone, cDrop, cClose>>

MCDropSendFutureWait(t) ==
    /\ cDropFuture < MaxDropFuture
    /\ DropSendFutureWait(t)
    /\ cDropFuture' = cDropFuture + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cClone, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Clone (Family 3 — bounded)
\* ===================================================================================

MCCloneSender ==
    /\ cClone < MaxCloneLimit
    /\ CloneSender
    /\ cClone' = cClone + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cDrop, cClose>>

MCCloneReceiver ==
    /\ cClone < MaxCloneLimit
    /\ CloneReceiver
    /\ cClone' = cClone + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cDrop, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Drop (Family 3 — bounded)
\* ===================================================================================

MCDropSender ==
    /\ cDrop < MaxDropLimit
    /\ DropSender
    /\ cDrop' = cDrop + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cClone, cClose>>

MCDropReceiver ==
    /\ cDrop < MaxDropLimit
    /\ DropReceiver
    /\ cDrop' = cDrop + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cClone, cClose>>

\* ===================================================================================
\* Counter-Bounded Actions: Close (Family 3 — bounded)
\* ===================================================================================

MCClose ==
    /\ cClose < MaxCloseLimit
    /\ Close
    /\ cClose' = cClose + 1
    /\ UNCHANGED <<cSend, cRecv, cTimeout, cPreempt, cDropFuture, cClone, cDrop>>

\* ===================================================================================
\* Unconstrained Actions (reactive — no counter needed)
\* ===================================================================================

MCSignalWaitSuccess(t) ==
    /\ SignalWaitSuccess(t)
    /\ UNCHANGED faultVars

MCSignalWaitFailure(t) ==
    /\ SignalWaitFailure(t)
    /\ UNCHANGED faultVars

MCWaitTimeoutRecheck(t) ==
    /\ WaitTimeoutRecheck(t)
    /\ UNCHANGED faultVars

MCWaitTimeoutCancel(t) ==
    /\ WaitTimeoutCancel(t)
    /\ UNCHANGED faultVars

MCWaitTimeoutFallback(t) ==
    /\ WaitTimeoutFallback(t)
    /\ UNCHANGED faultVars

MCThreadReset(t) ==
    /\ ThreadReset(t)
    /\ UNCHANGED faultVars

\* ===================================================================================
\* MCNext
\* ===================================================================================

MCNext ==
    \* --- Send (bounded) ---
    \/ \E t \in Thread : MCSendDirectHandoff(t)
    \/ \E t \in Thread : MCSendToQueue(t)
    \/ \E t \in Thread : MCSendBlock(t)
    \/ \E t \in Thread : MCSendClosed(t)
    \* --- Recv (bounded) ---
    \/ \E t \in Thread : MCRecvFromQueue(t)
    \/ \E t \in Thread : MCRecvDirectHandoff(t)
    \/ \E t \in Thread : MCRecvBlock(t)
    \/ \E t \in Thread : MCRecvClosed(t)
    \* --- Signal completion (reactive) ---
    \/ \E t \in Thread : MCSignalWaitSuccess(t)
    \/ \E t \in Thread : MCSignalWaitFailure(t)
    \* --- Timeout/starvation (Family 1, bounded) ---
    \/ \E t \in Thread : MCWaitTimeout(t)
    \/ \E t \in Thread : MCWaitTimeoutRecheck(t)
    \/ \E t \in Thread : MCWaitTimeoutCancel(t)
    \/ \E t \in Thread : MCWaitTimeoutFallback(t)
    \* --- Preemption (Family 1, bounded fault injection) ---
    \/ \E t \in Thread : MCPreempt(t)
    \* --- Future cancellation (Family 2, bounded fault injection) ---
    \/ \E t \in Thread : MCDropRecvFutureRendezvous(t)
    \/ \E t \in Thread : MCDropRecvFutureBuffered(t)
    \/ \E t \in Thread : MCDropRecvFutureCancel(t)
    \/ \E t \in Thread : MCDropSendFutureCancel(t)
    \/ \E t \in Thread : MCDropSendFutureWait(t)
    \* --- Clone/Drop/Close (Family 3, bounded) ---
    \/ MCCloneSender
    \/ MCCloneReceiver
    \/ MCDropSender
    \/ MCDropReceiver
    \/ MCClose
    \* --- Thread lifecycle (reactive) ---
    \/ \E t \in Thread : MCThreadReset(t)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ===================================================================================
\* Symmetry Reduction
\* ===================================================================================

ModelSymmetry == Permutations(Thread) \union Permutations(Data)

\* ===================================================================================
\* State Constraint (pruning)
\* ===================================================================================

StateConstraint ==
    /\ QueueLen <= Capacity + 2  \* Allow 2 over capacity to detect push_front bug

====
