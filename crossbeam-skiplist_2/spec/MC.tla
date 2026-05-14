---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for crossbeam-skiplist base spec.                 *)
(*                                                                         *)
(* Counter-bounds on ambient background actions (EpochFinalize,            *)
(* HelpUnlink); operation issuance is bounded by base-level MaxOps.         *)
(*                                                                         *)
(* Fault model coverage (concurrent-analysis.md §5):                        *)
(*   5.1 Interleaving:    via base-level per-step actions                   *)
(*                          Insert: Begin / AllocCASLevel0 / MarkOld /      *)
(*                                  BuildLevel / PostBuildCheck / Done      *)
(*                          Remove: Begin / Acquire / MarkTower /           *)
(*                                  UnlinkLevel / Done                      *)
(*                          Iter:   Begin / Next / NextBack / Drop          *)
(*   5.2 Cancellation:    n/a — no async / cancellable futures              *)
(*   5.3 OOM:             skipped — base.rs:177 calls handle_alloc_error    *)
(*   5.4 CAS_weak:        n/a — only try_increment uses compare_exchange_weak*)
(*   5.5 MemOrder:        FaultMarkBottomUp drives F3 sensitivity probe.    *)
(*   5.6 ABA:             not modeled in spec; nodes are bounded and        *)
(*                          monotonically allocated (no slot reuse). UAF is *)
(*                          probed via FaultPrematureFree.                  *)
(*   5.7 Caller misuse:   EnableHarness drives F4 (concurrent iter+insert+  *)
(*                          remove + pop_front).                            *)
(*   5.8 Lost wakeup:     n/a — no wait/notify primitives                   *)
(*                                                                         *)
(* Per-family fault flags (driven by MC_hunt_*.cfg):                        *)
(*   FaultIterRewind     — F1 #1142 (Iter::next/next_back rewind)           *)
(*   FaultInsertReorder  — F2 #1023 (mark-old before level-0 CAS)           *)
(*   FaultMarkBottomUp   — F3 sensitivity (PostBuildCheck top-only read)    *)
(*   FaultPrematureFree  — F5 surface (UAF via early finalize)              *)
(***************************************************************************)

EXTENDS base

CONSTANTS
    MaxFinalizeLimit,       \* counter bound for EpochFinalize
    MaxHelpUnlinkLimit      \* counter bound for HelpUnlink

VARIABLES
    finalizeCount,
    helpUnlinkCount

mcVars == <<finalizeCount, helpUnlinkCount>>
allVars == <<vars, mcVars>>

\* ========================================================================
\* MC Init
\* ========================================================================

MCInit ==
    /\ Init
    /\ finalizeCount = 0
    /\ helpUnlinkCount = 0

\* ========================================================================
\* Counter-bounded ambient actions
\* ========================================================================

MCEpochFinalize ==
    /\ finalizeCount < MaxFinalizeLimit
    /\ EpochFinalize
    /\ finalizeCount' = finalizeCount + 1
    /\ UNCHANGED helpUnlinkCount

MCHelpUnlink ==
    /\ helpUnlinkCount < MaxHelpUnlinkLimit
    /\ HelpUnlink
    /\ helpUnlinkCount' = helpUnlinkCount + 1
    /\ UNCHANGED finalizeCount

\* ========================================================================
\* Pass-through wrappers for reactive base actions
\* (No counter — opCount in base bounds operation issuance per thread.)
\* ========================================================================

MCInsert_Begin(t, k, v)        == Insert_Begin(t, k, v)        /\ UNCHANGED mcVars
MCInsert_AllocCASLevel0(t)     == Insert_AllocCASLevel0(t)     /\ UNCHANGED mcVars
MCInsert_MarkOld(t)            == Insert_MarkOld(t)            /\ UNCHANGED mcVars
MCInsert_MarkOldFirst(t)       == Insert_MarkOldFirst(t)       /\ UNCHANGED mcVars
MCInsert_BuildLevel(t)         == Insert_BuildLevel(t)         /\ UNCHANGED mcVars
MCInsert_PostBuildCheck(t)     == Insert_PostBuildCheck(t)     /\ UNCHANGED mcVars
MCInsert_Done(t)               == Insert_Done(t)               /\ UNCHANGED mcVars

MCGet(t, k)                    == Get(t, k)                    /\ UNCHANGED mcVars

MCRemove_Begin(t, k)           == Remove_Begin(t, k)           /\ UNCHANGED mcVars
MCRemove_Acquire(t)            == Remove_Acquire(t)            /\ UNCHANGED mcVars
MCRemove_MarkTower(t)          == Remove_MarkTower(t)          /\ UNCHANGED mcVars
MCRemove_UnlinkLevel(t)        == Remove_UnlinkLevel(t)        /\ UNCHANGED mcVars
MCRemove_Done(t)               == Remove_Done(t)               /\ UNCHANGED mcVars

MCIter_Begin(t, k)             == Iter_Begin(t, k)             /\ UNCHANGED mcVars
MCIter_Next(t)                 == Iter_Next(t)                 /\ UNCHANGED mcVars
MCIter_NextBack(t)             == Iter_NextBack(t)             /\ UNCHANGED mcVars
MCIter_Drop(t)                 == Iter_Drop(t)                 /\ UNCHANGED mcVars

MCPopFront(t)                  == PopFront(t)                  /\ UNCHANGED mcVars

\* ========================================================================
\* MC Next
\* ========================================================================

MCNext ==
    \/ \E t \in Thread, k \in Key, v \in Value : MCInsert_Begin(t, k, v)
    \/ \E t \in Thread : MCInsert_AllocCASLevel0(t)
    \/ \E t \in Thread : MCInsert_MarkOld(t)
    \/ \E t \in Thread : MCInsert_MarkOldFirst(t)
    \/ \E t \in Thread : MCInsert_BuildLevel(t)
    \/ \E t \in Thread : MCInsert_PostBuildCheck(t)
    \/ \E t \in Thread : MCInsert_Done(t)
    \/ \E t \in Thread, k \in Key : MCGet(t, k)
    \/ \E t \in Thread, k \in Key : MCRemove_Begin(t, k)
    \/ \E t \in Thread : MCRemove_Acquire(t)
    \/ \E t \in Thread : MCRemove_MarkTower(t)
    \/ \E t \in Thread : MCRemove_UnlinkLevel(t)
    \/ \E t \in Thread : MCRemove_Done(t)
    \/ EnableHarness /\ \E t \in Thread, kind \in {"Iter", "Range"} : MCIter_Begin(t, kind)
    \/ EnableHarness /\ \E t \in Thread : MCIter_Next(t)
    \/ EnableHarness /\ \E t \in Thread : MCIter_NextBack(t)
    \/ EnableHarness /\ \E t \in Thread : MCIter_Drop(t)
    \/ EnableHarness /\ \E t \in Thread : MCPopFront(t)
    \/ MCHelpUnlink
    \/ MCEpochFinalize

MCSpec == MCInit /\ [][MCNext]_allVars

\* ========================================================================
\* Symmetry — threads, keys, values are symmetric
\* ========================================================================

MCSymmetry == Permutations(Thread) \cup Permutations(Key) \cup Permutations(Value)

\* ========================================================================
\* State-space pruning
\* ========================================================================

MCStateConstraint ==
    /\ nextNodeId <= MaxNodes + 1
    /\ Len(history) <= 6 * MaxOps
    /\ \A t \in Thread : opCount[t] <= MaxOps

\* ========================================================================
\* Type invariants
\* ========================================================================

MCTypeOK ==
    /\ nodes \subseteq NodeId
    /\ nextNodeId \in 1..(MaxNodes + 1)
    /\ lenCounter \in Int
    /\ \A n \in NodeId :
         /\ nRefcount[n] \in Nat
         /\ nState[n] \in {"alive", "retired", "freed"}

====
