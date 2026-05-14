---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for `scc` base spec.                              *)
(*                                                                          *)
(* Counter-bounds fault-injection actions (TryResize, MigrateClearOld-      *)
(* RelaxedLegacy, ForcedSkipCheckRef, AdvanceGlobalEpoch). Reactive         *)
(* actions (Writer / Iter / Migrate) are NOT bounded -- they react to        *)
(* existing                                                                  *)
(* state and are required for the bug interleavings to be reachable.        *)
(*                                                                          *)
(* Fault-model coverage (per concurrent-analysis.md sec 5):                   *)
(*   5.1 Interleaving:    via fine-grained action splits (Writer 5-step,    *)
(*                        Iter 5-step, Migrate 4-step) -- base.tla           *)
(*   5.2 Cancellation:    skipped (operation futures don't carry observable *)
(*                        cancellation in the modeled paths)                *)
(*   5.3 OOM:             skipped (validated previous round, marginal)      *)
(*   5.4 CAS_weak:        skipped (atomic ops bottleneck out at lock level) *)
(*   5.5 MemOrder:        modeled via MCMigrateClearOldRelaxedLegacy as the *)
(*                        Family-2 Relaxed-clear adversary (pre-9573fa1)    *)
(*   5.6 ABA:             modeled via MaxArrays bounded fresh ArrayId set   *)
(*                        (each TryResize picks a new id; ABA on a re-used  *)
(*                        id surfaces if MaxArrays is small)                *)
(*   5.7 Caller misuse:   modeled via Iter + concurrent Writer + Resize     *)
(*                        interleaving (Family 1)                           *)
(*   5.8 Lost wakeup:     skipped (lock_async wake-up is correct via saa)   *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* Constants -- bounds for counter-bounded fault actions
\* ========================================================================

CONSTANTS
    MaxResize,           \* # of TryResize actions across all threads
    MaxLegacyClear,      \* # of legacy Relaxed-clear migrations (Family 2 adv)
    MaxSkipCheckRef,     \* # of forced check_ref skips (Family 3 adv)
    MaxEpochAdvance      \* # of AdvanceGlobalEpoch firings (Family 4 cap)

\* ========================================================================
\* Counter variables
\* ========================================================================

VARIABLES
    cResize,
    cLegacyClear,
    cSkipCheckRef,
    cEpochAdvance

mcVars == <<cResize, cLegacyClear, cSkipCheckRef, cEpochAdvance>>

\* ========================================================================
\* Counter-bounded fault wrappers
\* ========================================================================

MCTryResize(t) ==
    /\ cResize < MaxResize
    /\ TryResize(t)
    /\ cResize' = cResize + 1
    /\ UNCHANGED <<cLegacyClear, cSkipCheckRef, cEpochAdvance>>

MCMigrateClearOldRelaxedLegacy(t) ==
    /\ cLegacyClear < MaxLegacyClear
    /\ MigrateClearOldRelaxedLegacy(t)
    /\ cLegacyClear' = cLegacyClear + 1
    /\ UNCHANGED <<cResize, cSkipCheckRef, cEpochAdvance>>

MCMigratePublishNewLegacy(t) ==
    \* Reactive completion of the legacy split -- must not be bounded
    /\ MigratePublishNewLegacy(t)
    /\ UNCHANGED mcVars

MCForcedSkipCheckRef(t) ==
    /\ cSkipCheckRef < MaxSkipCheckRef
    /\ ForcedSkipCheckRef(t)
    /\ cSkipCheckRef' = cSkipCheckRef + 1
    /\ UNCHANGED <<cResize, cLegacyClear, cEpochAdvance>>

MCAdvanceGlobalEpoch ==
    /\ cEpochAdvance < MaxEpochAdvance
    /\ AdvanceGlobalEpoch
    /\ cEpochAdvance' = cEpochAdvance + 1
    /\ UNCHANGED <<cResize, cLegacyClear, cSkipCheckRef>>

\* ========================================================================
\* Reactive (unbounded) actions -- pass-through with UNCHANGED mcVars
\* ========================================================================

MCWriterStart(t, k, v) == WriterStart(t, k, v) /\ UNCHANGED mcVars
MCWriterMaybeRehashOK(t) == WriterMaybeRehashOK(t) /\ UNCHANGED mcVars
MCWriterMaybeRehashRetry(t) == WriterMaybeRehashRetry(t) /\ UNCHANGED mcVars
MCWriterAcquireLock(t) == WriterAcquireLock(t) /\ UNCHANGED mcVars
MCWriterCommitInsert(t) == WriterCommitInsert(t) /\ UNCHANGED mcVars
MCWriterCommitMarkRemoved(t) == WriterCommitMarkRemoved(t) /\ UNCHANGED mcVars
MCWriterRelease(t) == WriterRelease(t) /\ UNCHANGED mcVars

MCIterStart(t) == IterStart(t) /\ UNCHANGED mcVars
MCIterReadOccupied(t) == IterReadOccupied(t) /\ UNCHANGED mcVars
MCIterReadEmpty(t) == IterReadEmpty(t) /\ UNCHANGED mcVars
MCIterAdvanceWithinBucket(t) == IterAdvanceWithinBucket(t) /\ UNCHANGED mcVars
MCIterCrossArray(t) == IterCrossArray(t) /\ UNCHANGED mcVars
MCIterFinish(t) == IterFinish(t) /\ UNCHANGED mcVars

MCMigrateLockOldBucket(t) == MigrateLockOldBucket(t) /\ UNCHANGED mcVars
MCMigratePublishNew(t) == MigratePublishNew(t) /\ UNCHANGED mcVars
MCMigrateClearOld(t) == MigrateClearOld(t) /\ UNCHANGED mcVars
MCMigrateEmpty(t) == MigrateEmpty(t) /\ UNCHANGED mcVars
MCMigrateKillOldBucket(t) == MigrateKillOldBucket(t) /\ UNCHANGED mcVars
MCEndIncrementalRehash(t) == EndIncrementalRehash(t) /\ UNCHANGED mcVars
MCDeallocGarbage(t) == DeallocGarbage(t) /\ UNCHANGED mcVars
MCCheckRefMismatchAndBail(t) == CheckRefMismatchAndBail(t) /\ UNCHANGED mcVars

\* ========================================================================
\* Init / Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ cResize = 0
    /\ cLegacyClear = 0
    /\ cSkipCheckRef = 0
    /\ cEpochAdvance = 0

MCNext ==
    \/ \E t \in Thread :
        \/ \E k \in Key, v \in Value : MCWriterStart(t, k, v)
        \/ MCWriterMaybeRehashOK(t)
        \/ MCWriterMaybeRehashRetry(t)
        \/ MCWriterAcquireLock(t)
        \/ MCWriterCommitInsert(t)
        \/ MCWriterCommitMarkRemoved(t)
        \/ MCWriterRelease(t)
        \/ MCIterStart(t)
        \/ MCIterReadOccupied(t)
        \/ MCIterReadEmpty(t)
        \/ MCIterAdvanceWithinBucket(t)
        \/ MCIterCrossArray(t)
        \/ MCIterFinish(t)
        \/ MCTryResize(t)
        \/ MCMigrateLockOldBucket(t)
        \/ MCMigratePublishNew(t)
        \/ MCMigrateClearOld(t)
        \/ MCMigrateEmpty(t)
        \/ MCMigrateKillOldBucket(t)
        \/ MCEndIncrementalRehash(t)
        \/ MCDeallocGarbage(t)
        \/ MCMigrateClearOldRelaxedLegacy(t)
        \/ MCMigratePublishNewLegacy(t)
        \/ MCForcedSkipCheckRef(t)
        \/ MCCheckRefMismatchAndBail(t)
    \/ MCAdvanceGlobalEpoch

MCSpec == MCInit /\ [][MCNext]_<<allVars, mcVars>>

\* ========================================================================
\* Symmetry / View
\* ========================================================================

\* Threads are symmetric. (Keys, Values are NOT symmetric -- they are
\* witnesses to history invariants.)
Symmetry == Permutations(Thread)

\* Counters excluded from "view" since they're bookkeeping only.
McView == <<allVars>>

\* ========================================================================
\* State-space pruning constraint
\* ========================================================================

\* Cap total size of inserted/removed history sets and visited cardinality
\* to prevent unbounded growth from looping idle threads.
StateConstraint ==
    /\ Cardinality(inserted) <= 4
    /\ Cardinality(removedHistory) <= 4
    /\ \A t \in Thread : Cardinality(pc[t].visited) <= 4

\* ========================================================================
\* Re-exported invariants (hunting configs reference these)
\* ========================================================================

MCTypeOK == TypeOK
MCAtMostOneLive == AtMostOneLive
MCAtMostOneLinked == AtMostOneLinked
MCCurrentLive == CurrentLive
MCLinkedConsistent == LinkedConsistent

MCNoLiveKeyMissedByCompletedIter == NoLiveKeyMissedByCompletedIter
MCMigrationVisibleEverywhere == MigrationVisibleEverywhere
MCNoDuplicatePublication == NoDuplicatePublication
MCNoOrphanedLockedBucket == NoOrphanedLockedBucket
MCNoUseAfterFree == NoUseAfterFree
MCNoLeakedBucketLock == NoLeakedBucketLock
MCInsertedConsistency == InsertedConsistency

\* ========================================================================
\* Liveness (informational; not used in MC.cfg by default)
\* ========================================================================

\* IterEventuallyTerminates: once an iter starts, it eventually finishes.
IterEventuallyTerminates ==
    \A t \in Thread :
        (pc[t].kind = "iter") ~> (pc[t].kind = "idle")

====
