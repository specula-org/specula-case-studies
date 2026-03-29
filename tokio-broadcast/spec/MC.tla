---- MODULE MC ----
\* ===========================================================================
\* Model Checking Spec for tokio broadcast channel
\* ===========================================================================
\*
\* Wraps base spec with counter-bounded fault injection and non-deterministic
\* actions for exhaustive state space exploration.
\*
\* Bounded actions: Send, Subscribe, SenderDrop, SenderClone
\* Unbounded (reactive): RecvSuccess, RecvEmpty, RecvLagged, CloseChannel,
\*                        ReceiverDrop, DeregisterWaiter

EXTENDS base

\* ===========================================================================
\* MC Constants (limits for bounded actions)
\* ===========================================================================

CONSTANTS
    MaxSends,           \* Max number of Send actions
    MaxSubscribes,      \* Max number of Subscribe actions
    MaxSenderDrops,     \* Max number of SenderDrop actions
    MaxSenderClones     \* Max number of SenderClone actions

\* ===========================================================================
\* Counter variables
\* ===========================================================================

VARIABLES
    sendCount,          \* Number of Send actions taken
    subscribeCount,     \* Number of Subscribe actions taken
    senderDropCount,    \* Number of SenderDrop actions taken
    senderCloneCount    \* Number of SenderClone actions taken

faultVars == <<sendCount, subscribeCount, senderDropCount, senderCloneCount>>

mcVars == <<vars, faultVars>>

\* ===========================================================================
\* Counter-bounded wrappers
\* ===========================================================================

\* --- Bounded: Send ---
MCSend(v) ==
    /\ sendCount < MaxSends
    /\ Send(v)
    /\ sendCount' = sendCount + 1
    /\ UNCHANGED <<subscribeCount, senderDropCount, senderCloneCount>>

\* --- Bounded: Subscribe ---
MCSubscribe(r) ==
    /\ subscribeCount < MaxSubscribes
    /\ Subscribe(r)
    /\ subscribeCount' = subscribeCount + 1
    /\ UNCHANGED <<sendCount, senderDropCount, senderCloneCount>>

\* --- Bounded: SenderDrop ---
MCSenderDrop ==
    /\ senderDropCount < MaxSenderDrops
    /\ SenderDrop
    /\ senderDropCount' = senderDropCount + 1
    /\ UNCHANGED <<sendCount, subscribeCount, senderCloneCount>>

\* --- Bounded: SenderClone ---
MCSenderClone ==
    /\ senderCloneCount < MaxSenderClones
    /\ SenderClone
    /\ senderCloneCount' = senderCloneCount + 1
    /\ UNCHANGED <<sendCount, subscribeCount, senderDropCount>>

\* --- Unbounded (reactive): pass through with UNCHANGED faultVars ---

MCRecvSuccess(r) ==
    /\ RecvSuccess(r)
    /\ UNCHANGED faultVars

MCRecvEmpty(r) ==
    /\ RecvEmpty(r)
    /\ UNCHANGED faultVars

MCRecvLagged(r) ==
    /\ RecvLagged(r)
    /\ UNCHANGED faultVars

MCCloseChannel ==
    /\ CloseChannel
    /\ UNCHANGED faultVars

MCReceiverDrop(r) ==
    /\ ReceiverDrop(r)
    /\ UNCHANGED faultVars

MCDeregisterWaiter(r) ==
    /\ DeregisterWaiter(r)
    /\ UNCHANGED faultVars

\* ===========================================================================
\* MC Init and Next
\* ===========================================================================

MCInit ==
    /\ Init
    /\ sendCount = 0
    /\ subscribeCount = 0
    /\ senderDropCount = 0
    /\ senderCloneCount = 0

MCNext ==
    \/ \E v \in Value : MCSend(v)
    \/ \E r \in Receiver : MCSubscribe(r)
    \/ \E r \in Receiver : MCRecvSuccess(r)
    \/ \E r \in Receiver : MCRecvEmpty(r)
    \/ \E r \in Receiver : MCRecvLagged(r)
    \/ MCSenderDrop
    \/ MCSenderClone
    \/ MCCloseChannel
    \/ \E r \in Receiver : MCReceiverDrop(r)
    \/ \E r \in Receiver : MCDeregisterWaiter(r)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ===========================================================================
\* Symmetry reduction
\* ===========================================================================

\* Receivers are interchangeable
ModelSymmetry == Permutations(Receiver)

\* ===========================================================================
\* State space constraint
\* ===========================================================================

\* Prevent unbounded growth
StateConstraint ==
    /\ numTx <= 4
    /\ rxCnt <= Cardinality(Receiver) + 1
    /\ tailPos \in 0..(MaxPos - 1)

\* ===========================================================================
\* View (exclude counters from state fingerprint for symmetry)
\* ===========================================================================

MCView == vars

\* ===========================================================================
\* Temporal properties
\* ===========================================================================

\* Family 1: If close is pending, it eventually completes
\* (requires weak fairness on CloseChannel)
CloseEventuallyCompletes ==
    closePending ~> ~closePending

\* Family 2: A waiting receiver is eventually woken or deregistered
\* (requires weak fairness on Send/CloseChannel/DeregisterWaiter)
WaiterEventuallyResolved ==
    \A r \in Receiver :
        (r \in waiters) ~> (r \notin waiters)

====
