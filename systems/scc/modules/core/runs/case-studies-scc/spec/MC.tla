------------------------------ MODULE MC ------------------------------
(*
 * Model checking wrapper for scc base spec.
 * Counter-bounds fault-injection and bug-variant actions.
 * Normal (deterministic/reactive) actions pass through unbounded.
 *)
EXTENDS base

CONSTANTS
    MaxResizes,           \* Max number of TriggerResize actions
    MaxEpochAdvances,     \* Max number of AdvanceEpoch actions
    MaxBuggyActions,      \* Max number of bug-variant actions (F1/F2/F5)
    MaxAsyncOps           \* Max number of async read operations

\* ---------------------------------------------------------------
\* Counter variables
\* ---------------------------------------------------------------
VARIABLES
    resizeCount,          \* Number of TriggerResize actions taken
    epochAdvanceCount,    \* Number of AdvanceEpoch actions taken
    buggyActionCount,     \* Number of bug-variant actions taken
    asyncOpCount          \* Number of async read operations started

faultVars == <<resizeCount, epochAdvanceCount, buggyActionCount, asyncOpCount>>

\* ---------------------------------------------------------------
\* Counter-bounded wrappers
\* ---------------------------------------------------------------

\* --- Bounded: Resize triggers (introduces non-determinism) ---
MCTriggerResize(t) ==
    /\ resizeCount < MaxResizes
    /\ TriggerResize(t)
    /\ resizeCount' = resizeCount + 1
    /\ UNCHANGED <<epochAdvanceCount, buggyActionCount, asyncOpCount>>

\* --- Bounded: Epoch advancement ---
MCAdvanceEpoch ==
    /\ epochAdvanceCount < MaxEpochAdvances
    /\ AdvanceEpoch
    /\ epochAdvanceCount' = epochAdvanceCount + 1
    /\ UNCHANGED <<resizeCount, buggyActionCount, asyncOpCount>>

\* --- Bounded: Bug variant actions ---
MCBuggyReleaseLockEarly(t) ==
    /\ buggyActionCount < MaxBuggyActions
    /\ BuggyReleaseLockEarly(t)
    /\ buggyActionCount' = buggyActionCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, asyncOpCount>>

MCBuggyAsyncSkipCheckRef(t, k) ==
    /\ buggyActionCount < MaxBuggyActions
    /\ BuggyAsyncSkipCheckRef(t, k)
    /\ buggyActionCount' = buggyActionCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, asyncOpCount>>

MCBuggyReclaimArray(a) ==
    /\ buggyActionCount < MaxBuggyActions
    /\ BuggyReclaimArray(a)
    /\ buggyActionCount' = buggyActionCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, asyncOpCount>>

\* --- Bounded: Async operations ---
MCBeginAsyncRead(t) ==
    /\ asyncOpCount < MaxAsyncOps
    /\ BeginAsyncRead(t)
    /\ asyncOpCount' = asyncOpCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, buggyActionCount>>

\* --- Unbounded: deterministic/reactive actions ---
MCCreateGuard(t) ==
    /\ CreateGuard(t)
    /\ UNCHANGED faultVars

MCDropGuard(t) ==
    /\ DropGuard(t)
    /\ UNCHANGED faultVars

MCBeginSyncRead(t, k, b) ==
    /\ BeginSyncRead(t, k, b)
    /\ UNCHANGED faultVars

MCAccessDataSync(t, k) ==
    /\ AccessDataSync(t, k)
    /\ UNCHANGED faultVars

MCEndSyncRead(t) ==
    /\ EndSyncRead(t)
    /\ UNCHANGED faultVars

MCInsertSync(t, k, b) ==
    /\ InsertSync(t, k, b)
    /\ UNCHANGED faultVars

MCRemoveSync(t, k) ==
    /\ RemoveSync(t, k)
    /\ UNCHANGED faultVars

MCClaimRehashRange(t, a) ==
    /\ ClaimRehashRange(t, a)
    /\ UNCHANGED faultVars

MCRelocateBucket(t, a, b) ==
    /\ RelocateBucket(t, a, b)
    /\ UNCHANGED faultVars

MCRelocateBucketFail(t, a, b) ==
    /\ RelocateBucketFail(t, a, b)
    /\ UNCHANGED faultVars

MCEndRehash(t, a) ==
    /\ EndRehash(t, a)
    /\ UNCHANGED faultVars

MCFinalizeResize(t, a) ==
    /\ FinalizeResize(t, a)
    /\ UNCHANGED faultVars

MCDedupBucket(t, b) ==
    /\ DedupBucket(t, b)
    /\ UNCHANGED faultVars

MCAsyncAwait(t) ==
    /\ AsyncAwait(t)
    /\ UNCHANGED faultVars

MCAsyncReacquireGuard(t) ==
    /\ AsyncReacquireGuard(t)
    /\ UNCHANGED faultVars

MCAsyncCheckRef(t) ==
    /\ AsyncCheckRef(t)
    /\ UNCHANGED faultVars

MCAsyncOperate(t, k) ==
    /\ AsyncOperate(t, k)
    /\ UNCHANGED faultVars

MCEndAsyncRead(t) ==
    /\ EndAsyncRead(t)
    /\ UNCHANGED faultVars

MCReclaimArray(a) ==
    /\ ReclaimArray(a)
    /\ UNCHANGED faultVars

\* ---------------------------------------------------------------
\* Init and Next
\* ---------------------------------------------------------------
MCInit ==
    /\ Init
    /\ resizeCount = 0
    /\ epochAdvanceCount = 0
    /\ buggyActionCount = 0
    /\ asyncOpCount = 0

MCNext ==
    \/ \E t \in Thread :
        \/ MCCreateGuard(t)
        \/ MCDropGuard(t)
        \/ \E k \in Key, b \in Bucket :
            \/ MCBeginSyncRead(t, k, b)
            \/ MCInsertSync(t, k, b)
        \/ \E k \in Key :
            \/ MCAccessDataSync(t, k)
            \/ MCRemoveSync(t, k)
            \/ MCAsyncOperate(t, k)
        \/ MCEndSyncRead(t)
        \/ MCTriggerResize(t)
        \/ \E a \in ArrayId :
            \/ MCClaimRehashRange(t, a)
            \/ MCEndRehash(t, a)
            \/ MCFinalizeResize(t, a)
            \/ \E b \in Bucket :
                \/ MCRelocateBucket(t, a, b)
                \/ MCRelocateBucketFail(t, a, b)
        \/ \E b \in Bucket : MCDedupBucket(t, b)
        \/ MCBeginAsyncRead(t)
        \/ MCAsyncAwait(t)
        \/ MCAsyncReacquireGuard(t)
        \/ MCAsyncCheckRef(t)
        \/ MCEndAsyncRead(t)
    \/ MCAdvanceEpoch
    \/ \E a \in ArrayId : MCReclaimArray(a)

mcVars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ---------------------------------------------------------------
\* Symmetry
\* ---------------------------------------------------------------
MCSymmetry == Permutations(Thread) \union Permutations(Key)

\* ---------------------------------------------------------------
\* Structural invariants (always checked)
\* ---------------------------------------------------------------

\* Counter bounds are respected
CounterBounds ==
    /\ resizeCount <= MaxResizes
    /\ epochAdvanceCount <= MaxEpochAdvances
    /\ buggyActionCount <= MaxBuggyActions
    /\ asyncOpCount <= MaxAsyncOps

\* At most one thread is in rehashing state per old array
\* (simplification — the real system allows concurrent rehash but
\*  on different bucket ranges)

\* nextArrayId never exceeds MaxArrays + 1
ArrayIdBound == nextArrayId <= MaxArrays + 1

\* ---------------------------------------------------------------
\* Hunting config helpers
\* ---------------------------------------------------------------

\* MCNext without bug variants (for convergence testing)
MCNextNoBugs ==
    \/ \E t \in Thread :
        \/ MCCreateGuard(t)
        \/ MCDropGuard(t)
        \/ \E k \in Key, b \in Bucket :
            \/ MCBeginSyncRead(t, k, b)
            \/ MCInsertSync(t, k, b)
        \/ \E k \in Key :
            \/ MCAccessDataSync(t, k)
            \/ MCRemoveSync(t, k)
            \/ MCAsyncOperate(t, k)
        \/ MCEndSyncRead(t)
        \/ MCTriggerResize(t)
        \/ \E a \in ArrayId :
            \/ MCClaimRehashRange(t, a)
            \/ MCEndRehash(t, a)
            \/ MCFinalizeResize(t, a)
            \/ \E b \in Bucket :
                \/ MCRelocateBucket(t, a, b)
                \/ MCRelocateBucketFail(t, a, b)
        \/ \E b \in Bucket : MCDedupBucket(t, b)
        \/ MCBeginAsyncRead(t)
        \/ MCAsyncAwait(t)
        \/ MCAsyncReacquireGuard(t)
        \/ MCAsyncCheckRef(t)
        \/ MCEndAsyncRead(t)
    \/ MCAdvanceEpoch
    \/ \E a \in ArrayId : MCReclaimArray(a)

\* MCNext with F1 bug variants only
MCNextF1 ==
    \/ MCNextNoBugs
    \/ \E t \in Thread : MCBuggyReleaseLockEarly(t)

\* MCNext with F2 bug variants only
MCNextF2 ==
    \/ MCNextNoBugs
    \/ \E t \in Thread, k \in Key : MCBuggyAsyncSkipCheckRef(t, k)

\* MCNext with F5 bug variants only
MCNextF5 ==
    \/ MCNextNoBugs
    \/ \E a \in ArrayId : MCBuggyReclaimArray(a)

=============================================================================
