---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for the Round-2 left-right base spec.            *)
(*                                                                         *)
(* Round-2 focus (per modeling brief §2):                                  *)
(*   F1 — take_inner stale-snapshot UAF (PR #144 OPEN)                     *)
(*   F2 — Reentrant enter() panics on NULL pointer                         *)
(*   F3 — Long-held guard blocks publish (liveness)                        *)
(*   F4 — Per-reader snapshot in update_and_swap (granularity)             *)
(*                                                                         *)
(* Fault model coverage (per references/mc-spec-pattern.md):               *)
(*   5.1 Interleaving:    via per-step actions in base spec                *)
(*                        (publish split into Apply/Swap/Fence/SnapReader; *)
(*                         take_inner split into 10+ stages)               *)
(*   5.2 Cancellation:    n/a (synchronous API; no async tasks)            *)
(*   5.3 OOM:             skipped (target documented to abort)             *)
(*   5.4 CAS_weak:        n/a (uses swap/RMW, no compare_exchange)         *)
(*   5.5 MemOrder:        SKIPPED — prior round's MCSkipReaderFence /      *)
(*                        MCSkipWriterFence found 0 bugs; brief §3.2       *)
(*                        explicitly excludes re-running.                  *)
(*   5.6 ABA:             n/a (no compare-and-set; reader slot reuse is    *)
(*                        already handled by the wait skip rule).          *)
(*   5.7 Caller misuse:   MCClientHoldGuardSet/Release (F3 long-held       *)
(*                        guard).  MCWriterStartTakeInner counter-bounds   *)
(*                        the writer-drop adversary that triggers F1.      *)
(*   5.8 Lost wakeup:     n/a (writer spins via thread::yield_now, not     *)
(*                        condvar/notify).                                 *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* Counter-bound constants
\* ========================================================================

CONSTANTS
    MaxPublish,             \* total publish() calls (also gates apply)
    MaxTryPublish,          \* total try_publish() calls
    MaxTakeInner,           \* WriteHandle::drop / take adversary (F1)
    MaxClientHolds          \* F3 long-held guard adversary

\* ========================================================================
\* Counter variables
\* ========================================================================

VARIABLES
    publishCount,
    tryPublishCount,
    takeInnerCount,
    clientHoldCount

mcVars == <<publishCount, tryPublishCount, takeInnerCount, clientHoldCount>>

\* ========================================================================
\* Counter-bounded fault / adversary wrappers
\* ========================================================================

\* Bound the *entry* points of multi-step protocols, not the per-step
\* reactive transitions inside.  Once we entered a publish (or take_inner)
\* the rest is reactive.
MCWriterStartPublish ==
    /\ publishCount < MaxPublish
    /\ WriterStartPublish
    /\ publishCount' = publishCount + 1
    /\ UNCHANGED <<tryPublishCount, takeInnerCount, clientHoldCount>>

MCWriterStartTryPublish ==
    /\ tryPublishCount < MaxTryPublish
    /\ WriterStartTryPublish
    /\ tryPublishCount' = tryPublishCount + 1
    /\ UNCHANGED <<publishCount, takeInnerCount, clientHoldCount>>

\* F1 trigger: WriteHandle::drop -> take_inner.
MCWriterStartTakeInner ==
    /\ takeInnerCount < MaxTakeInner
    /\ WriterStartTakeInner
    /\ takeInnerCount' = takeInnerCount + 1
    /\ UNCHANGED <<publishCount, tryPublishCount, clientHoldCount>>

\* F3 trigger: reader pins guard.
MCClientHoldGuardSet(r) ==
    /\ clientHoldCount < MaxClientHolds
    /\ ClientHoldGuardSet(r)
    /\ clientHoldCount' = clientHoldCount + 1
    /\ UNCHANGED <<publishCount, tryPublishCount, takeInnerCount>>

\* ========================================================================
\* Pass-through wrappers for reactive actions
\* ========================================================================

MCReaderEnterFreshBumpEpoch(r) == ReaderEnterFreshBumpEpoch(r) /\ UNCHANGED mcVars
MCReaderEnterFreshLoad(r)      == ReaderEnterFreshLoad(r)      /\ UNCHANGED mcVars
MCReaderEnterNestedLoad(r)     == ReaderEnterNestedLoad(r)     /\ UNCHANGED mcVars
MCReaderExit(r)                == ReaderExit(r)                /\ UNCHANGED mcVars
MCClientHoldGuardRelease(r)    == ClientHoldGuardRelease(r)    /\ UNCHANGED mcVars

MCWriterAppend                  == WriterAppend                  /\ UNCHANGED mcVars
MCWriterWait                    == WriterWait                    /\ UNCHANGED mcVars
MCWriterPubApply                == WriterPubApply                /\ UNCHANGED mcVars
MCWriterPubSwap                 == WriterPubSwap                 /\ UNCHANGED mcVars
MCWriterPubFence                == WriterPubFence                /\ UNCHANGED mcVars
MCWriterPubBeginSnap            == WriterPubBeginSnap            /\ UNCHANGED mcVars
MCWriterPubSnapReader(r)        == WriterPubSnapReader(r)        /\ UNCHANGED mcVars
MCWriterPubFinishSnap           == WriterPubFinishSnap           /\ UNCHANGED mcVars
MCWriterTryPublishSucceed       == WriterTryPublishSucceed       /\ UNCHANGED mcVars
MCWriterTryPublishFail          == WriterTryPublishFail          /\ UNCHANGED mcVars
MCWriterTakeInnerMaybePublishGo   == WriterTakeInnerMaybePublishGo   /\ UNCHANGED mcVars
MCWriterTakeInnerMaybePublishSkip == WriterTakeInnerMaybePublishSkip /\ UNCHANGED mcVars
MCWriterTakeInnerPubWait          == WriterTakeInnerPubWait          /\ UNCHANGED mcVars
MCWriterTakeInnerPubApply         == WriterTakeInnerPubApply         /\ UNCHANGED mcVars
MCWriterTakeInnerPubSwap          == WriterTakeInnerPubSwap          /\ UNCHANGED mcVars
MCWriterTakeInnerPubFence         == WriterTakeInnerPubFence         /\ UNCHANGED mcVars
MCWriterTakeInnerPubBeginSnap     == WriterTakeInnerPubBeginSnap     /\ UNCHANGED mcVars
MCWriterTakeInnerPubSnapReader(r) == WriterTakeInnerPubSnapReader(r) /\ UNCHANGED mcVars
MCWriterTakeInnerPubFinishSnap    == WriterTakeInnerPubFinishSnap    /\ UNCHANGED mcVars
MCWriterTakeInnerNullSwap         == WriterTakeInnerNullSwap         /\ UNCHANGED mcVars
MCWriterTakeInnerLock             == WriterTakeInnerLock             /\ UNCHANGED mcVars
MCWriterTakeInnerResnapshot       == WriterTakeInnerResnapshot       /\ UNCHANGED mcVars
MCWriterTakeInnerWait             == WriterTakeInnerWait             /\ UNCHANGED mcVars
MCWriterTakeInnerFence            == WriterTakeInnerFence            /\ UNCHANGED mcVars
MCWriterTakeInnerDropFirst        == WriterTakeInnerDropFirst        /\ UNCHANGED mcVars
MCWriterTakeInnerDropSecond       == WriterTakeInnerDropSecond       /\ UNCHANGED mcVars

\* ========================================================================
\* Init + Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ publishCount = 0
    /\ tryPublishCount = 0
    /\ takeInnerCount = 0
    /\ clientHoldCount = 0

MCNext ==
    \/ \E r \in Reader :
        \/ MCReaderEnterFreshBumpEpoch(r)
        \/ MCReaderEnterFreshLoad(r)
        \/ MCReaderEnterNestedLoad(r)
        \/ MCReaderExit(r)
        \/ MCClientHoldGuardSet(r)
        \/ MCClientHoldGuardRelease(r)
        \/ MCWriterPubSnapReader(r)
        \/ MCWriterTakeInnerPubSnapReader(r)
    \/ MCWriterAppend
    \/ MCWriterStartPublish
    \/ MCWriterWait
    \/ MCWriterPubApply
    \/ MCWriterPubSwap
    \/ MCWriterPubFence
    \/ MCWriterPubBeginSnap
    \/ MCWriterPubFinishSnap
    \/ MCWriterStartTryPublish
    \/ MCWriterTryPublishSucceed
    \/ MCWriterTryPublishFail
    \/ MCWriterStartTakeInner
    \/ MCWriterTakeInnerMaybePublishGo
    \/ MCWriterTakeInnerMaybePublishSkip
    \/ MCWriterTakeInnerPubWait
    \/ MCWriterTakeInnerPubApply
    \/ MCWriterTakeInnerPubSwap
    \/ MCWriterTakeInnerPubFence
    \/ MCWriterTakeInnerPubBeginSnap
    \/ MCWriterTakeInnerPubFinishSnap
    \/ MCWriterTakeInnerNullSwap
    \/ MCWriterTakeInnerLock
    \/ MCWriterTakeInnerResnapshot
    \/ MCWriterTakeInnerWait
    \/ MCWriterTakeInnerFence
    \/ MCWriterTakeInnerDropFirst
    \/ MCWriterTakeInnerDropSecond

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

\* ========================================================================
\* State-space pruning
\* ========================================================================

\* Bound things that grow without natural fixpoint.  totalOps is bounded
\* by MaxOps in the base spec; bound epoch and enters here.
MCStateConstraint ==
    /\ totalOps <= MaxOps
    /\ \A r \in Reader : epoch[r] <= 4 * MaxOps + 6
    /\ \A r \in Reader : lastEpochs[r] <= 4 * MaxOps + 6
    /\ \A r \in Reader : enters[r] <= 2

\* ========================================================================
\* Symmetry — readers are interchangeable.
\* ========================================================================

MCSymmetry == Permutations(Reader)

\* ========================================================================
\* Liveness fairness for F3 hunting.
\* ========================================================================
\* Two variants:
\*   MCSpecWithReleaseFairness — F3 fix is NOT in scope (reader contract
\*       requires guard to be released eventually).  Liveness HOLDS.
\*   MCSpec (no fairness) — represents the *bug* of caller misuse: a
\*       reader holding forever starves the writer.  Liveness VIOLATES.

MCSpecWithReleaseFairness ==
    /\ MCSpec
    /\ \A rh \in Reader : WF_<<vars, mcVars>>(MCClientHoldGuardRelease(rh))
    /\ WF_<<vars, mcVars>>(MCWriterStartPublish)
    /\ WF_<<vars, mcVars>>(MCWriterWait)
    /\ WF_<<vars, mcVars>>(MCWriterPubApply)
    /\ WF_<<vars, mcVars>>(MCWriterPubSwap)
    /\ WF_<<vars, mcVars>>(MCWriterPubFence)
    /\ WF_<<vars, mcVars>>(MCWriterPubBeginSnap)
    /\ WF_<<vars, mcVars>>(MCWriterPubFinishSnap)
    /\ \A rs \in Reader : WF_<<vars, mcVars>>(MCWriterPubSnapReader(rs))

\* Liveness property: once an append is queued and we are in publishable
\* state (not taken, oplog non-empty after first publish), we eventually
\* leave the "first" state — i.e., a publish completes.
\* Without ClientHoldGuardRelease fairness the property is intentionally
\* falsifiable (caller-misuse violation).
EventualPublish ==
    [] (totalOps > 0 /\ ~taken /\ first ~> ~first)

\* ========================================================================
\* Always-on / structural invariants
\* ========================================================================

MCTypeOK              == TypeOK
MCEpochParity         == EpochParity
MCPointerDisjoint     == PointerCopyDisjoint

\* ========================================================================
\* Bug-family invariants (commented in MC.cfg; enabled by hunt configs)
\* ========================================================================

MCNoWriteWhileRead              == NoWriteWhileRead              \* general
MCNoDropWhileRead               == NoDropWhileRead               \* F1
MCStaleSnapshotIsCaught         == StaleSnapshotIsCaught         \* F1
MCNoUnreachablePanic            == NoUnreachablePanic            \* F2
MCPerReaderSnapshotConsistency  == PerReaderSnapshotConsistency  \* F4

====
