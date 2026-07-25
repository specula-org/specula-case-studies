-------------------------------- MODULE MC ---------------------------------
(* Model checking wrapper for papaya lock-free HashMap (round 2).
 *
 * Fault model coverage (per concurrent-analysis.md § 5):
 *   5.1 Interleaving:    via per-step actions (CAS/StoreMeta/Fixup, MarkCopying/Insert/MarkCopied,
 *                        IterBegin/Advance/End — see base spec)
 *   5.2 Cancellation:    n/a (synchronous API)
 *   5.3 OOM:             skipped — implementation aborts process on alloc failure (modeling brief § 3.2)
 *   5.4 CAS_weak:        skipped — papaya uses compare_exchange (strong) at all hot paths
 *   5.5 MemOrder:        partial — modeled implicitly via action splits (winner store / loser fixup)
 *   5.6 ABA:             implicit — slot/generation handled via tag bits + insertWindow; no separate counter
 *   5.7 Caller misuse:   MODELED via IterBegin/IterAdvance — adversarial caller iter+modify+resize
 *   5.8 Lost wakeup:     MODELED via AbortResize unparking wrong (parker, key); Park / Promote routing
 *
 * Counter-bounded fault injection:
 *   - InsertLimit:   max insert CAS operations
 *   - RemoveLimit:   max remove operations
 *   - ResizeLimit:   max next-table allocations
 *   - AbortLimit:    max blocking-resize aborts          [Family 3]
 *   - EpochLimit:    max epoch advances                  [Family 4]
 *   - ParkLimit:     max park operations                 [Family 3]
 *   - IterLimit:     max iter-begin operations           [Family 6 NEW]
 *   - FixupLimit:    max insert-meta fixup writes        [Family 7 NEW]
 *
 * Does NOT bound (reactive/deterministic): InsertStoreMeta, InsertUpdate,
 *   CopyMarkCopying, CopyMarkCopyingNull, CopyInsertToNext, CopyMarkCopied,
 *   TryPromote, ReclaimEntry, IterAdvance*, IterEnd.
 *)
EXTENDS base

CONSTANTS
    InsertLimit,
    RemoveLimit,
    ResizeLimit,
    AbortLimit,
    EpochLimit,
    ParkLimit,
    IterLimit,
    FixupLimit

VARIABLES
    faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

(* ================================================================
 * MC INIT
 * ================================================================ *)

MCInit ==
    /\ Init
    /\ faultCounters = [
        inserts |-> 0,
        removes |-> 0,
        resizes |-> 0,
        aborts  |-> 0,
        epochs  |-> 0,
        parks   |-> 0,
        iters   |-> 0,
        fixups  |-> 0
       ]

(* ================================================================
 * BOUNDED ACTIONS (introduce non-determinism)
 * ================================================================ *)

MCInsertCASEntry(tid, k, v, t, s) ==
    /\ faultCounters.inserts < InsertLimit
    /\ InsertCASEntry(tid, k, v, t, s)
    /\ faultCounters' = [faultCounters EXCEPT !.inserts = @ + 1]

MCInsertUpdate(tid, k, v, t, s) ==
    /\ faultCounters.inserts < InsertLimit
    /\ InsertUpdate(tid, k, v, t, s)
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

MCIterBegin(tid) ==
    /\ faultCounters.iters < IterLimit
    /\ IterBegin(tid)
    /\ faultCounters' = [faultCounters EXCEPT !.iters = @ + 1]

MCInsertMetaFixup(tid, t, s) ==
    /\ faultCounters.fixups < FixupLimit
    /\ InsertMetaFixup(tid, t, s)
    /\ faultCounters' = [faultCounters EXCEPT !.fixups = @ + 1]

(* ================================================================
 * UNCONSTRAINED (reactive/deterministic) ACTIONS
 * ================================================================ *)

MCInitTable(tid) ==
    /\ InitTable(tid)
    /\ UNCHANGED faultVars

MCInsertStoreMeta(tid, t, s) ==
    /\ InsertStoreMeta(tid, t, s)
    /\ UNCHANGED faultVars

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

MCIterAdvanceYield(tid) ==
    /\ IterAdvanceYield(tid)
    /\ UNCHANGED faultVars

MCIterAdvanceSkip(tid) ==
    /\ IterAdvanceSkip(tid)
    /\ UNCHANGED faultVars

MCIterEnd(tid) ==
    /\ IterEnd(tid)
    /\ UNCHANGED faultVars

(* ================================================================
 * MC NEXT
 * ================================================================ *)

MCNext ==
    \/ \E tid \in Thread :
        \/ MCInitTable(tid)
        \/ MCIterBegin(tid)
        \/ MCIterAdvanceYield(tid)
        \/ MCIterAdvanceSkip(tid)
        \/ MCIterEnd(tid)
        \/ MCAdvanceEpoch(tid)
        \/ \E t \in 1..MaxTables :
            \/ MCAllocNextTable(tid, t)
            \/ MCTryPromote(tid, t)
            \/ MCParkThread(tid, t)
            \/ \E abortedT \in 1..MaxTables : MCAbortResize(tid, t, abortedT)
            \/ \E s \in Slot :
                \/ \E k \in Key, v \in Value :
                    \/ MCInsertCASEntry(tid, k, v, t, s)
                    \/ MCInsertUpdate(tid, k, v, t, s)
                \/ MCInsertStoreMeta(tid, t, s)
                \/ MCInsertMetaFixup(tid, t, s)
                \/ \E k \in Key : MCRemove(tid, k, t, s)
                \/ MCCopyMarkCopying(tid, t, s)
                \/ MCCopyMarkCopyingNull(tid, t, s)
                \/ MCCopyMarkCopied(tid, t, s)
                \/ \E dstT \in 1..MaxTables, dstS \in Slot :
                    MCCopyInsertToNext(tid, t, s, dstT, dstS)
    \/ \E entry \in retired : MCReclaimEntry(entry)

MCSpec == MCInit /\ [][MCNext]_mcVars

(* ================================================================
 * SYMMETRY
 * ================================================================ *)

ModelSymmetry == Permutations(Thread) \cup Permutations(Key) \cup Permutations(Value)

(* ================================================================
 * STATE SPACE CONSTRAINTS
 * ================================================================ *)

StateConstraint ==
    /\ Cardinality(retired) <= Cardinality(Key) * Cardinality(Slot)
    /\ \A tid \in Thread : Len(seenKeys[tid]) <= Cardinality(Slot) + 1

(* ================================================================
 * INVARIANTS — base spec invariants are inherited; MC.cfg controls activation
 * ================================================================ *)

============================================================================
