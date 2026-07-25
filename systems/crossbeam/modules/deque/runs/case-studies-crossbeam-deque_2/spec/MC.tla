---- MODULE MC ----
(***************************************************************************)
(* Model-checking wrapper for crossbeam-deque base spec.                   *)
(*                                                                        *)
(* Counter-bounds the fault-injection / non-deterministic actions:        *)
(*   - ResizeGrow          (Family A enabling step)                       *)
(*   - EpochReclaim        (Family A reclamation)                         *)
(*   - StealerCloneAdv     (Family C — adversarial caller)                *)
(*   - WorkerDropAdv       (Family C)                                     *)
(*   - EnableRelaxBackStore  (Family B fault toggle)                      *)
(*   - EnableSkipStealerFence (Family B fault toggle)                     *)
(*   - PublishDeferredSlot (Family B liveness companion)                  *)
(*                                                                        *)
(* Reactive / deterministic actions (push, pop, steal phases) pass through *)
(* unbounded — bounding them would suppress legitimate interleavings.     *)
(*                                                                        *)
(* Fault-coverage block (per concurrent-analysis.md § 5):                 *)
(*   5.1 Interleaving:    via per-step actions in base spec               *)
(*                         (Push split, LIFOPop split, Steal split)        *)
(*   5.2 Cancellation:    n/a (synchronous deque API)                    *)
(*   5.3 OOM:             skipped — deque aborts on alloc failure        *)
(*   5.4 CAS_weak:        modeled via weakLIFOLastCAS flag (Family D)    *)
(*   5.5 MemOrder:        modeled via relaxBackStore + skipStealerFence   *)
(*                         (Family B; back-store and stealer-fence are    *)
(*                          the two load-bearing bridges in the brief)    *)
(*   5.6 ABA:             modeled via bufferID generation +              *)
(*                         per-stealer sCachedBuf (Family A)             *)
(*   5.7 Caller misuse:   modeled via StealerCloneAdv + WorkerDropAdv     *)
(*                         + activeStealers harness (Family C)            *)
(*   5.8 Lost wakeup:     n/a — no wait/notify primitives in deque.       *)
(*                                                                        *)
(* Out of scope (deferred):                                               *)
(*   - Injector block-lifecycle (Family E) — separate MPMC structure     *)
(*   - Injector weak-CAS (Family D, Injector side) — same                *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* MC Constants
\* ========================================================================

CONSTANTS
    MaxResizeLimit,            \* counter bound for ResizeGrow
    MaxReclaimLimit,           \* counter bound for EpochReclaim
    MaxCloneLimit,             \* counter bound for StealerCloneAdv (Family C)
    MaxWorkerDropLimit,        \* counter bound for WorkerDropAdv (Family C)
    MaxRelaxBackLimit,         \* counter bound for EnableRelaxBackStore (B)
    MaxSkipFenceLimit,         \* counter bound for EnableSkipStealerFence (B)
    MaxPublishLimit,           \* counter bound for PublishDeferredSlot (liveness)
    MaxWeakCASLimit,           \* counter bound for EnableWeakLIFOLastCAS (D)
    MaxPrematureReclaimLimit,  \* counter bound for EnablePrematureReclaim (A)
    MaxSkipRecheckLimit        \* counter bound for EnableSkipRecheck (A)

\* ========================================================================
\* MC Variables (counters)
\* ========================================================================

VARIABLES
    cResize,
    cReclaim,
    cClone,
    cWorkerDrop,
    cRelaxBack,
    cSkipFence,
    cPublish,
    cWeakCAS,
    cPremReclaim,
    cSkipRecheck

mcVars  == <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
             cSkipFence, cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>
allVars == <<vars, mcVars>>

\* ========================================================================
\* MC Init
\* ========================================================================

MCInit ==
    /\ Init
    /\ cResize       = 0
    /\ cReclaim      = 0
    /\ cClone        = 0
    /\ cWorkerDrop   = 0
    /\ cRelaxBack    = 0
    /\ cSkipFence    = 0
    /\ cPublish      = 0
    /\ cWeakCAS      = 0
    /\ cPremReclaim  = 0
    /\ cSkipRecheck  = 0

\* ========================================================================
\* Counter-Bounded Wrappers (fault injection / non-determinism)
\* ========================================================================

\* Helper: counter-bumping wrapper.
\* All wrappers UNCHANGED-everything except their own counter to keep
\* the cross-product small.

MCResizeGrow ==
    /\ cResize < MaxResizeLimit
    /\ ResizeGrow
    /\ cResize' = cResize + 1
    /\ UNCHANGED <<cReclaim, cClone, cWorkerDrop, cRelaxBack, cSkipFence,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCEpochReclaim ==
    /\ cReclaim < MaxReclaimLimit
    /\ EpochReclaim
    /\ cReclaim' = cReclaim + 1
    /\ UNCHANGED <<cResize, cClone, cWorkerDrop, cRelaxBack, cSkipFence,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCStealerCloneAdv(s) ==
    /\ cClone < MaxCloneLimit
    /\ StealerCloneAdv(s)
    /\ cClone' = cClone + 1
    /\ UNCHANGED <<cResize, cReclaim, cWorkerDrop, cRelaxBack, cSkipFence,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCWorkerDropAdv ==
    /\ cWorkerDrop < MaxWorkerDropLimit
    /\ WorkerDropAdv
    /\ cWorkerDrop' = cWorkerDrop + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cRelaxBack, cSkipFence,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCEnableRelaxBackStore ==
    /\ cRelaxBack < MaxRelaxBackLimit
    /\ EnableRelaxBackStore
    /\ cRelaxBack' = cRelaxBack + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cSkipFence,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCEnableSkipStealerFence ==
    /\ cSkipFence < MaxSkipFenceLimit
    /\ EnableSkipStealerFence
    /\ cSkipFence' = cSkipFence + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
                   cPublish, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCPublishDeferredSlot ==
    /\ cPublish < MaxPublishLimit
    /\ PublishDeferredSlot
    /\ cPublish' = cPublish + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
                   cSkipFence, cWeakCAS, cPremReclaim, cSkipRecheck>>

MCEnableWeakLIFOLastCAS ==
    /\ cWeakCAS < MaxWeakCASLimit
    /\ EnableWeakLIFOLastCAS
    /\ cWeakCAS' = cWeakCAS + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
                   cSkipFence, cPublish, cPremReclaim, cSkipRecheck>>

MCEnablePrematureReclaim ==
    /\ cPremReclaim < MaxPrematureReclaimLimit
    /\ EnablePrematureReclaim
    /\ cPremReclaim' = cPremReclaim + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
                   cSkipFence, cPublish, cWeakCAS, cSkipRecheck>>

MCEnableSkipRecheck(site) ==
    /\ cSkipRecheck < MaxSkipRecheckLimit
    /\ EnableSkipRecheck(site)
    /\ cSkipRecheck' = cSkipRecheck + 1
    /\ UNCHANGED <<cResize, cReclaim, cClone, cWorkerDrop, cRelaxBack,
                   cSkipFence, cPublish, cWeakCAS, cPremReclaim>>

\* ========================================================================
\* Unbounded Reactive Actions
\* ========================================================================

MCPushWriteSlot       == PushWriteSlot       /\ UNCHANGED mcVars
MCPushStoreBack       == PushStoreBack       /\ UNCHANGED mcVars
MCLIFOPopDecrFence    == LIFOPopDecrFence    /\ UNCHANGED mcVars
MCLIFOPopDecide       == LIFOPopDecide       /\ UNCHANGED mcVars
MCFIFOPopAttempt      == FIFOPopAttempt      /\ UNCHANGED mcVars
MCFIFOPopRollback     == FIFOPopRollback     /\ UNCHANGED mcVars

MCStealLoadFront_Single(s)    == StealLoadFront_Single(s)    /\ UNCHANGED mcVars
MCStealLoadFront_BatchFifo(s) == StealLoadFront_BatchFifo(s) /\ UNCHANGED mcVars
MCStealLoadFront_BatchLifo(s) == StealLoadFront_BatchLifo(s) /\ UNCHANGED mcVars
MCStealPin(s)                 == StealPin(s)                 /\ UNCHANGED mcVars
MCStealLoadBack(s)            == StealLoadBack(s)            /\ UNCHANGED mcVars
MCStealLoadBuffer(s)          == StealLoadBuffer(s)          /\ UNCHANGED mcVars
MCStealReadSlot(s)            == StealReadSlot(s)            /\ UNCHANGED mcVars
MCStealRecheckCAS(s)          == StealRecheckCAS(s)          /\ UNCHANGED mcVars
MCStealLIFOBatchIter(s)       == StealLIFOBatchIter(s)       /\ UNCHANGED mcVars

\* ========================================================================
\* MC Next
\* ========================================================================

MCWorkerAction ==
    \/ MCPushWriteSlot
    \/ MCPushStoreBack
    \/ MCLIFOPopDecrFence
    \/ MCLIFOPopDecide
    \/ MCFIFOPopAttempt
    \/ MCFIFOPopRollback
    \/ MCResizeGrow

MCStealerAction(s) ==
    \/ MCStealLoadFront_Single(s)
    \/ MCStealLoadFront_BatchFifo(s)
    \/ MCStealLoadFront_BatchLifo(s)
    \/ MCStealPin(s)
    \/ MCStealLoadBack(s)
    \/ MCStealLoadBuffer(s)
    \/ MCStealReadSlot(s)
    \/ MCStealRecheckCAS(s)
    \/ MCStealLIFOBatchIter(s)

MCCallerHarness ==
    \/ \E s \in Stealer : MCStealerCloneAdv(s)
    \/ MCWorkerDropAdv

MCFaultInjection ==
    \/ MCEnableRelaxBackStore
    \/ MCEnableSkipStealerFence
    \/ MCEnableWeakLIFOLastCAS
    \/ MCEnablePrematureReclaim
    \/ \E site \in DOMAIN skipRecheck : MCEnableSkipRecheck(site)
    \/ MCPublishDeferredSlot

MCNext ==
    \/ MCWorkerAction
    \/ \E s \in Stealer : MCStealerAction(s)
    \/ MCEpochReclaim
    \/ MCCallerHarness
    \/ MCFaultInjection

MCSpec == MCInit /\ [][MCNext]_allVars

\* ========================================================================
\* Symmetry & State-Space Pruning
\* ========================================================================

MCSymmetry == Permutations(Stealer)

\* View hides the counter variables — counters do not change behavior, only
\* bound it.
MCView == vars

\* Bound the search depth via state constraint.
MCStateConstraint ==
    /\ bufferID <= MaxResize + 1
    /\ Len(pushed) <= MaxVal
    /\ back - front <= BufferCap
    /\ Cardinality(activeStealers) <= Cardinality(Stealer)
    /\ \A s \in Stealer : sBatchIter[s] <= MaxBatchIters

\* ========================================================================
\* Liveness (optional)
\* ========================================================================

\* Eventually the relaxBackStore window closes (deferred slot publishes).
\* This documents the expected behavior; not enabled by default.
EventuallyConsistent ==
    \A id \in DOMAIN bufContent :
        \A pos \in 0..(back-1) :
            (ReadBuf(id, pos) /= NullVal)
                ~> (SlotVisible(id, pos) \/ id \in freed)

====
