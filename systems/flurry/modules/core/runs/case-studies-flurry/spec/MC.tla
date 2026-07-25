---- MODULE MC ----
(***************************************************************************)
(* Model Checking Wrapper for flurry ConcurrentHashMap                     *)
(*                                                                         *)
(* Wraps base spec with counter-bounded fault-injection actions for        *)
(* exhaustive state space exploration.                                     *)
(*                                                                         *)
(* Bounded actions (introduce non-determinism):                            *)
(*   - PutEmptyBin, PutNodeBin, PutTreeBin: bounded by MaxPuts            *)
(*   - InitResize: bounded by MaxResizes                                   *)
(*   - AdvanceEpoch: bounded by MaxEpochAdvances                           *)
(*                                                                         *)
(* Unbounded actions (react to existing state):                            *)
(*   - ClaimRange, ClaimRangeExhausted, TransferBin, TransferFinishCheck   *)
(*   - FinishingSweep, CompleteResize, HelpTransfer, PutHelpTransfer       *)
(*   - TreeifyBin, EnterGuard, ExitGuard                                   *)
(*   - Reader/Writer lock actions (react to lock state)                    *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* Counter Constants
\* ========================================================================

CONSTANTS
    MaxPuts,            \* Max put operations (primary non-determinism source)
    MaxResizes,         \* Max resize initiations
    MaxEpochAdvances,   \* Max epoch advances for reclamation (Family 2)
    MaxTreeLockOps      \* Max tree lock acquire operations (Family 3)

\* ========================================================================
\* Counter Variables
\* ========================================================================

VARIABLES
    putCount,           \* Counter: put operations performed
    resizeCount,        \* Counter: resize initiations
    epochAdvanceCount,  \* Counter: epoch advances
    treeLockOpCount     \* Counter: tree lock operations

mcVars == <<putCount, resizeCount, epochAdvanceCount, treeLockOpCount>>
allVars == <<vars, mcVars>>

\* ========================================================================
\* Symmetry
\* ========================================================================

\* Threads are interchangeable
ModelSymmetry == Permutations(Thread)

\* ========================================================================
\* Counter-Bounded Actions
\* ========================================================================

\* Bounded: Put into empty bin (primary non-determinism)
MCPutEmptyBin(t, k) ==
    /\ putCount < MaxPuts
    /\ PutEmptyBin(t, k)
    /\ putCount' = putCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, treeLockOpCount>>

\* Bounded: Put into Node bin
MCPutNodeBin(t, k) ==
    /\ putCount < MaxPuts
    /\ PutNodeBin(t, k)
    /\ putCount' = putCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, treeLockOpCount>>

\* Bounded: Put into Tree bin
MCPutTreeBin(t, k) ==
    /\ putCount < MaxPuts
    /\ PutTreeBin(t, k)
    /\ putCount' = putCount + 1
    /\ UNCHANGED <<resizeCount, epochAdvanceCount, treeLockOpCount>>

\* Bounded: Resize initiation
MCInitResize(t) ==
    /\ resizeCount < MaxResizes
    /\ InitResize(t)
    /\ resizeCount' = resizeCount + 1
    /\ UNCHANGED <<putCount, epochAdvanceCount, treeLockOpCount>>

\* Bounded: Epoch advance (Family 2)
MCAdvanceEpoch ==
    /\ epochAdvanceCount < MaxEpochAdvances
    /\ AdvanceEpoch
    /\ epochAdvanceCount' = epochAdvanceCount + 1
    /\ UNCHANGED <<putCount, resizeCount, treeLockOpCount>>

\* Bounded: Tree lock acquisitions (Family 3)
MCReaderAcquire(t, b) ==
    /\ treeLockOpCount < MaxTreeLockOps
    /\ ReaderAcquire(t, b)
    /\ treeLockOpCount' = treeLockOpCount + 1
    /\ UNCHANGED <<putCount, resizeCount, epochAdvanceCount>>

MCWriterAcquireFast(t, b) ==
    /\ treeLockOpCount < MaxTreeLockOps
    /\ WriterAcquireFast(t, b)
    /\ treeLockOpCount' = treeLockOpCount + 1
    /\ UNCHANGED <<putCount, resizeCount, epochAdvanceCount>>

MCWriterSetWaiter(t, b) ==
    /\ treeLockOpCount < MaxTreeLockOps
    /\ WriterSetWaiter(t, b)
    /\ treeLockOpCount' = treeLockOpCount + 1
    /\ UNCHANGED <<putCount, resizeCount, epochAdvanceCount>>

\* ========================================================================
\* Unbounded (Reactive) Actions
\* ========================================================================

\* These actions react to existing state — do not bound them.

MCPutHelpTransfer(t, k) ==
    /\ PutHelpTransfer(t, k)
    /\ UNCHANGED mcVars

MCTreeifyBin(t) ==
    /\ TreeifyBin(t)
    /\ UNCHANGED mcVars

MCClaimRange(t) ==
    /\ ClaimRange(t)
    /\ UNCHANGED mcVars

MCClaimRangeExhausted(t) ==
    /\ ClaimRangeExhausted(t)
    /\ UNCHANGED mcVars

MCTransferBin(t) ==
    /\ TransferBin(t)
    /\ UNCHANGED mcVars

MCTransferFinishCheck(t) ==
    /\ TransferFinishCheck(t)
    /\ UNCHANGED mcVars

MCFinishingSweep(t) ==
    /\ FinishingSweep(t)
    /\ UNCHANGED mcVars

MCCompleteResize(t) ==
    /\ CompleteResize(t)
    /\ UNCHANGED mcVars

MCHelpTransfer(t) ==
    /\ HelpTransfer(t)
    /\ UNCHANGED mcVars

MCHelpTransferBail(t) ==
    /\ HelpTransferBail(t)
    /\ UNCHANGED mcVars

MCEnterGuard(t) ==
    /\ EnterGuard(t)
    /\ UNCHANGED mcVars

MCExitGuard(t) ==
    /\ ExitGuard(t)
    /\ UNCHANGED mcVars

MCReaderRelease(t, b) ==
    /\ ReaderRelease(t, b)
    /\ UNCHANGED mcVars

MCWriterAcquireContended(t, b) ==
    /\ WriterAcquireContended(t, b)
    /\ UNCHANGED mcVars

MCWriterRelease(t, b) ==
    /\ WriterRelease(t, b)
    /\ UNCHANGED mcVars

\* ========================================================================
\* Init and Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ putCount = 0
    /\ resizeCount = 0
    /\ epochAdvanceCount = 0
    /\ treeLockOpCount = 0

MCNext ==
    \* --- Bounded put operations ---
    \/ \E t \in Thread, k \in 0..MaxKey-1 :
        \/ MCPutEmptyBin(t, k)
        \/ MCPutNodeBin(t, k)
        \/ MCPutTreeBin(t, k)
        \/ MCPutHelpTransfer(t, k)
    \* --- Treeify (Family 4, unbounded) ---
    \/ \E t \in Thread : MCTreeifyBin(t)
    \* --- Bounded resize initiation ---
    \/ \E t \in Thread : MCInitResize(t)
    \* --- Transfer coordination (unbounded, reactive) ---
    \/ \E t \in Thread :
        \/ MCClaimRange(t)
        \/ MCClaimRangeExhausted(t)
        \/ MCTransferBin(t)
        \/ MCTransferFinishCheck(t)
        \/ MCFinishingSweep(t)
        \/ MCCompleteResize(t)
        \/ MCHelpTransfer(t)
        \/ MCHelpTransferBail(t)
    \* --- Guard lifecycle (unbounded) ---
    \/ \E t \in Thread :
        \/ MCEnterGuard(t)
        \/ MCExitGuard(t)
    \/ MCAdvanceEpoch
    \* --- TreeBin R/W lock (Family 3) ---
    \/ \E t \in Thread, b \in 0..NumBins-1 :
        \/ MCReaderAcquire(t, b)
        \/ MCReaderRelease(t, b)
        \/ MCWriterAcquireFast(t, b)
        \/ MCWriterSetWaiter(t, b)
        \/ MCWriterAcquireContended(t, b)
        \/ MCWriterRelease(t, b)

MCSpec == MCInit /\ [][MCNext]_allVars

\* ========================================================================
\* State Constraint (prune large state spaces)
\* ========================================================================

\* Exclude MC counters from state view to help symmetry reduction
MCView == vars

\* Constraint: limit total keys in map to prevent explosion
StateConstraint ==
    /\ count <= MaxKey
    /\ putCount <= MaxPuts

\* ========================================================================
\* Invariants — organized by category
\* ========================================================================

\* --- Structural (always check) ---
\* ResizeCoordination, BinTypeConsistency, CountNonNeg
\* EmptyBinNoKeys, MovedBinNoKeys, LockStateNonNeg

\* --- Extension / Bug Family (enable in hunting configs) ---
\* NoSkippedBins (F1), NoUseAfterFree (F2)
\* ReaderWriterMutex (F3), WaiterSafety (F3)
\* TreeifyNoPanic (F4), AllBinsTransferred (F1)

====
