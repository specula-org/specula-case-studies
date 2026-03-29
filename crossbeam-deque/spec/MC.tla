---- MODULE MC ----
(***************************************************************************)
(* Model Checking wrapper for crossbeam-deque base spec.                  *)
(*                                                                        *)
(* Counter-bounds fault-injection actions (resize, epoch reclaim).         *)
(* Normal operations (push, pop, steal) pass through unbounded.           *)
(*                                                                        *)
(* Hunting configs override skipRecheck and prematureReclaim to target     *)
(* specific bug families.                                                  *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* MC Constants
\* ========================================================================

CONSTANTS
    MaxResizeLimit,         \* Counter bound for ResizeGrow
    MaxEpochReclaimLimit,   \* Counter bound for EpochReclaim
    SkipRecheckSingle,      \* Override: skip re-check at single steal CAS
    SkipRecheckBatchFIFO,   \* Override: skip re-check at FIFO batch CAS
    SkipRecheckBatchLIFO,   \* Override: skip re-check at LIFO batch first CAS
    PrematureReclaimFlag    \* Override: allow premature epoch reclamation

\* ========================================================================
\* MC Variables
\* ========================================================================

VARIABLES
    resizeCount,            \* Counter for ResizeGrow invocations
    epochReclaimCount       \* Counter for EpochReclaim invocations

mcVars == <<resizeCount, epochReclaimCount>>
allVars == <<vars, mcVars>>

\* ========================================================================
\* MC Init
\* ========================================================================

MCInit ==
    /\ front = 0
    /\ back = 0
    /\ bufferID = 1
    /\ bufContent = (1 :> EmptyBuf)
    /\ sPC = [s \in Stealer |-> "Idle"]
    /\ sCachedFront = [s \in Stealer |-> 0]
    /\ sCachedBuf = [s \in Stealer |-> 0]
    /\ sReadVal = [s \in Stealer |-> NullVal]
    /\ sStolenCount = [s \in Stealer |-> 0]
    /\ sStealSite = [s \in Stealer |-> "single"]
    /\ wPC = "Idle"
    /\ nextPush = 1
    /\ flavor \in {"FIFO", "LIFO"}
    /\ pinned = [s \in Stealer |-> FALSE]
    /\ retired = {}
    /\ freed = {}
    \* Fault injection: overridden by constants
    /\ skipRecheck = ("single" :> SkipRecheckSingle)
                     @@ ("batchFIFO" :> SkipRecheckBatchFIFO)
                     @@ ("batchLIFOFirst" :> SkipRecheckBatchLIFO)
    /\ prematureReclaim = PrematureReclaimFlag
    /\ pushed = <<>>
    /\ consumed = {}
    /\ consumeCount = 0
    \* MC counters
    /\ resizeCount = 0
    /\ epochReclaimCount = 0

\* ========================================================================
\* Counter-Bounded Actions (fault injection / non-deterministic)
\* ========================================================================

\* ResizeGrow: bounded by MaxResizeLimit
MCResizeGrow ==
    /\ resizeCount < MaxResizeLimit
    /\ ResizeGrow
    /\ resizeCount' = resizeCount + 1
    /\ UNCHANGED epochReclaimCount

\* EpochReclaim: bounded by MaxEpochReclaimLimit
MCEpochReclaim ==
    /\ epochReclaimCount < MaxEpochReclaimLimit
    /\ EpochReclaim
    /\ epochReclaimCount' = epochReclaimCount + 1
    /\ UNCHANGED resizeCount

\* ========================================================================
\* Unbounded Actions (deterministic / reactive)
\* ========================================================================

MCPush == Push /\ UNCHANGED mcVars
MCLIFOPop == LIFOPop /\ UNCHANGED mcVars
MCFIFOPopAttempt == FIFOPopAttempt /\ UNCHANGED mcVars
MCFIFOPopRollback == FIFOPopRollback /\ UNCHANGED mcVars
MCStealBegin(s) == StealBegin(s) /\ UNCHANGED mcVars
MCBatchStealBeginFIFO(s) == BatchStealBeginFIFO(s) /\ UNCHANGED mcVars
MCBatchStealBeginLIFO(s) == BatchStealBeginLIFO(s) /\ UNCHANGED mcVars
MCStealReadTask(s) == StealReadTask(s) /\ UNCHANGED mcVars
MCStealCommit(s) == StealCommit(s) /\ UNCHANGED mcVars

\* ========================================================================
\* MC Next
\* ========================================================================

MCWorkerAction ==
    \/ MCPush
    \/ MCResizeGrow
    \/ MCLIFOPop
    \/ MCFIFOPopAttempt
    \/ MCFIFOPopRollback

MCStealerAction(s) ==
    \/ MCStealBegin(s)
    \/ MCBatchStealBeginFIFO(s)
    \/ MCBatchStealBeginLIFO(s)
    \/ MCStealReadTask(s)
    \/ MCStealCommit(s)

MCNext ==
    \/ MCWorkerAction
    \/ \E s \in Stealer : MCStealerAction(s)
    \/ MCEpochReclaim

MCSpec == MCInit /\ [][MCNext]_allVars

\* ========================================================================
\* Symmetry
\* ========================================================================

MCSymmetry == Permutations(Stealer)

\* ========================================================================
\* State Constraint (prune state space)
\* ========================================================================

MCStateConstraint ==
    /\ bufferID <= MaxResize + 1
    /\ Len(pushed) <= MaxVal
    /\ back - front <= BufferCap

====
