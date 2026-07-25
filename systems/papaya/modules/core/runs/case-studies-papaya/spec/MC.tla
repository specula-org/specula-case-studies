-------------------------------- MODULE MC ---------------------------------
(* Model checking wrapper for papaya lock-free HashMap.
 *
 * Adds counter-bounded fault injection for:
 *   - Insert operations (InsertLimit)
 *   - Remove operations (RemoveLimit)
 *   - Resize triggers (ResizeLimit)
 *   - Abort resize (AbortLimit)         [Family 3: parker deadlock]
 *   - StallBetweenCASandMeta (StallLimit) [Family 1: two-phase gap]
 *   - Epoch advance (EpochLimit)         [Family 4: reclamation]
 *
 * Does NOT bound: CopyMarkCopying, CopyInsertToNext, CopyMarkCopied,
 *   TryPromote, InsertStoreMeta, ReclaimEntry (reactive/deterministic)
 *)
EXTENDS base

CONSTANTS
    InsertLimit,        \* Max insert operations
    RemoveLimit,        \* Max remove operations
    ResizeLimit,        \* Max next-table allocations
    AbortLimit,         \* Max resize aborts [Family 3]
    EpochLimit,         \* Max epoch advances [Family 4]
    ParkLimit           \* Max park operations [Family 3]

VARIABLES
    faultCounters       \* Record of fault injection counters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

(* ================================================================
 * COUNTER-BOUNDED WRAPPERS
 * ================================================================ *)

MCInit ==
    /\ Init
    /\ faultCounters = [
        inserts   |-> 0,
        removes   |-> 0,
        resizes   |-> 0,
        aborts    |-> 0,
        epochs    |-> 0,
        parks     |-> 0
       ]

(* --- Bounded actions (introduce non-determinism) --- *)

MCInsertCASEntry(tid, k, v, t, s) ==
    /\ faultCounters.inserts < InsertLimit
    /\ InsertCASEntry(tid, k, v, t, s)
    /\ faultCounters' = [faultCounters EXCEPT !.inserts = @ + 1]

MCRemove(tid, k, t, s) ==
    /\ faultCounters.removes < RemoveLimit
    /\ Remove(tid, k, t, s)
    /\ faultCounters' = [faultCounters EXCEPT !.removes = @ + 1]

MCAllocNextTable(tid, t) ==
    /\ faultCounters.resizes < ResizeLimit
    /\ AllocNextTable(tid, t)
    /\ faultCounters' = [faultCounters EXCEPT !.resizes = @ + 1]

MCAbortResize(tid, srcT, abortedT) ==
    /\ faultCounters.aborts < AbortLimit
    /\ AbortResize(tid, srcT, abortedT)
    /\ faultCounters' = [faultCounters EXCEPT !.aborts = @ + 1]

MCAdvanceEpoch(tid) ==
    /\ faultCounters.epochs < EpochLimit
    /\ AdvanceEpoch(tid)
    /\ faultCounters' = [faultCounters EXCEPT !.epochs = @ + 1]

MCParkThread(tid, t) ==
    /\ faultCounters.parks < ParkLimit
    /\ ParkThread(tid, t)
    /\ faultCounters' = [faultCounters EXCEPT !.parks = @ + 1]

(* --- Unconstrained actions (reactive/deterministic) --- *)

MCInitTable(tid) ==
    /\ InitTable(tid)
    /\ UNCHANGED faultVars

MCInsertStoreMeta(tid, t, s) ==
    /\ InsertStoreMeta(tid, t, s)
    /\ UNCHANGED faultVars

MCInsertUpdate(tid, k, v, t, s) ==
    /\ faultCounters.inserts < InsertLimit
    /\ InsertUpdate(tid, k, v, t, s)
    /\ faultCounters' = [faultCounters EXCEPT !.inserts = @ + 1]

MCCopyMarkCopying(tid, srcT, s) ==
    /\ CopyMarkCopying(tid, srcT, s)
    /\ UNCHANGED faultVars

MCCopyMarkCopyingNull(tid, srcT, s) ==
    /\ CopyMarkCopyingNull(tid, srcT, s)
    /\ UNCHANGED faultVars

MCCopyInsertToNext(tid, srcT, srcS, dstT, dstS) ==
    /\ CopyInsertToNext(tid, srcT, srcS, dstT, dstS)
    /\ UNCHANGED faultVars

MCCopyMarkCopied(tid, srcT, srcS) ==
    /\ CopyMarkCopied(tid, srcT, srcS)
    /\ UNCHANGED faultVars

MCTryPromote(tid, t) ==
    /\ TryPromote(tid, t)
    /\ UNCHANGED faultVars

MCReclaimEntry(entry) ==
    /\ ReclaimEntry(entry)
    /\ UNCHANGED faultVars

(* ================================================================
 * MC NEXT
 * ================================================================ *)

MCNext ==
    \/ \E tid \in Thread :
        \/ MCInitTable(tid)
        \/ \E t \in 1..MaxTables :
            \/ MCAllocNextTable(tid, t)
            \/ \E s \in Slot :
                \/ \E k \in Key, v \in Value :
                    \/ MCInsertCASEntry(tid, k, v, t, s)
                    \/ MCInsertUpdate(tid, k, v, t, s)
                \/ MCInsertStoreMeta(tid, t, s)
                \/ \E k \in Key : MCRemove(tid, k, t, s)
                \/ MCCopyMarkCopying(tid, t, s)
                \/ MCCopyMarkCopyingNull(tid, t, s)
                \/ MCCopyMarkCopied(tid, t, s)
                \/ \E dstT \in 1..MaxTables, dstS \in Slot :
                    MCCopyInsertToNext(tid, t, s, dstT, dstS)
            \/ MCTryPromote(tid, t)
            \/ MCParkThread(tid, t)
            \/ \E abortedT \in 1..MaxTables :
                MCAbortResize(tid, t, abortedT)
    \/ \E entry \in retired : MCReclaimEntry(entry)
    \/ \E tid \in Thread : MCAdvanceEpoch(tid)

MCSpec == MCInit /\ [][MCNext]_mcVars

(* ================================================================
 * SYMMETRY
 * ================================================================ *)

ModelSymmetry == Permutations(Thread) \cup Permutations(Key) \cup Permutations(Value)

(* ================================================================
 * STATE SPACE CONSTRAINT
 * ================================================================ *)

StateConstraint ==
    /\ Cardinality(retired) <= Cardinality(Key) * Cardinality(Slot)

(* ================================================================
 * INVARIANTS
 * ================================================================ *)

\* All invariants from base spec are available.
\* MC.cfg controls which are active.

============================================================================
