---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for crossbeam-epoch.                             *)
(*                                                                         *)
(* Fault model coverage (concurrent-analysis.md §5):                       *)
(*   5.1 Interleaving:    via per-step actions                             *)
(*                          PinIncGuardCount / PinLoadGlobal / PinPublish, *)
(*                          UnpinDec / UnpinPublish,                       *)
(*                          TryAdvLoadGlobal / TryAdvFence / TryAdvIter /  *)
(*                          TryAdvFinishStore,                             *)
(*                          BagDrop / InDeferCallbackPin /                 *)
(*                          InDeferCallbackDefer.                          *)
(*   5.2 Cancellation:    n/a (no async/await in scope)                    *)
(*   5.3 OOM:             skipped (caller responsibility)                  *)
(*   5.4 CAS_weak:        n/a (impl uses strong CAS)                       *)
(*   5.5 MemOrder:        MCSkipFence — Family 3 (SC fence pair)           *)
(*   5.6 ABA:             modeled via SlotReuse + objectGen (Family 6)     *)
(*   5.7 Caller misuse:   MCBuggyRetire / MCDeferThatPins /                *)
(*                        MCRepinAfter / MCUnprotectedDefer (Family 4)     *)
(*   5.8 Lost wakeup:     n/a (no wait/notify)                             *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* MC constants
\* ========================================================================

CONSTANTS
    PinLimit,           \* Max number of PinIncGuardCount fires
    AdvanceLimit,       \* Max number of TryAdvFinishStore fires
    BuggyRetireLimit,   \* Max number of BuggyRetire fires (Family 2)
    SkipFenceLimit,     \* Max number of SkipFence fires (Family 3)
    DeferLimit,         \* Max number of Defer (any kind) fires (Family 4)
    RepinAfterLimit,    \* Max number of RepinAfterStart fires (Family 4)
    UnprotectedDeferLimit,  \* Max UnprotectedDefer fires (Family 4)
    SlotReuseLimit,     \* Max SlotReuse fires (Family 6)
    StalledIterLimit    \* Max times TryAdvIter takes the Stalled branch (F5)

\* ========================================================================
\* Counter variables
\* ========================================================================

VARIABLES
    cPin,
    cAdvance,
    cBuggyRetire,
    cSkipFence,
    cDefer,
    cRepinAfter,
    cUnprotectedDefer,
    cSlotReuse,
    cStalledIter

mcVars == <<cPin, cAdvance, cBuggyRetire, cSkipFence, cDefer,
            cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* ========================================================================
\* Bounded actions (fault injection only)
\* ========================================================================

\* Bound Pin to keep state space bounded; pins drive most of the work.
MCPinIncGuardCount(t) ==
    /\ cPin < PinLimit
    /\ PinIncGuardCount(t)
    /\ cPin' = cPin + 1
    /\ UNCHANGED <<cAdvance, cBuggyRetire, cSkipFence, cDefer,
                   cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Bound Advance — limits how often the global epoch advances.
MCTryAdvFinishStore(t) ==
    /\ cAdvance < AdvanceLimit
    /\ TryAdvFinishStore(t)
    /\ cAdvance' = cAdvance + 1
    /\ UNCHANGED <<cPin, cBuggyRetire, cSkipFence, cDefer,
                   cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Family 2 — BuggyRetire (one-shot via base spec, also bounded here).
MCBuggyRetire(t, o) ==
    /\ cBuggyRetire < BuggyRetireLimit
    /\ BuggyRetire(t, o)
    /\ cBuggyRetire' = cBuggyRetire + 1
    /\ UNCHANGED <<cPin, cAdvance, cSkipFence, cDefer,
                   cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Family 3 — SkipFence
MCSkipFence(site) ==
    /\ cSkipFence < SkipFenceLimit
    /\ SkipFence(site)
    /\ cSkipFence' = cSkipFence + 1
    /\ UNCHANGED <<cPin, cAdvance, cBuggyRetire, cDefer,
                   cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Family 4 — Defer (caller-driven): we bound how often the harness
\* registers a deferred fn (any body kind).
MCDefer(t, o, kind) ==
    /\ cDefer < DeferLimit
    /\ Defer(t, o, kind)
    /\ cDefer' = cDefer + 1
    /\ UNCHANGED <<cPin, cAdvance, cBuggyRetire, cSkipFence,
                   cRepinAfter, cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Family 4 — RepinAfter
MCRepinAfterStart(t) ==
    /\ cRepinAfter < RepinAfterLimit
    /\ RepinAfterStart(t)
    /\ cRepinAfter' = cRepinAfter + 1
    /\ UNCHANGED <<cPin, cAdvance, cBuggyRetire, cSkipFence, cDefer,
                   cUnprotectedDefer, cSlotReuse, cStalledIter>>

\* Family 4 — UnprotectedDefer
MCUnprotectedDefer(t, o) ==
    /\ cUnprotectedDefer < UnprotectedDeferLimit
    /\ UnprotectedDefer(t, o)
    /\ cUnprotectedDefer' = cUnprotectedDefer + 1
    /\ UNCHANGED <<cPin, cAdvance, cBuggyRetire, cSkipFence, cDefer,
                   cRepinAfter, cSlotReuse, cStalledIter>>

\* Family 6 — SlotReuse
MCSlotReuse(t) ==
    /\ cSlotReuse < SlotReuseLimit
    /\ SlotReuse(t)
    /\ cSlotReuse' = cSlotReuse + 1
    /\ UNCHANGED <<cPin, cAdvance, cBuggyRetire, cSkipFence, cDefer,
                   cRepinAfter, cUnprotectedDefer, cStalledIter>>

\* ========================================================================
\* Unconstrained reactive actions — pass through with UNCHANGED mcVars
\* ========================================================================

MCPinLoadGlobal(t)               == PinLoadGlobal(t)               /\ UNCHANGED mcVars
MCPinPublish(t)                  == PinPublish(t)                  /\ UNCHANGED mcVars
MCPinMaybeCollect(t)             == PinMaybeCollect(t)             /\ UNCHANGED mcVars
MCPinCollectFinish(t)            == PinCollectFinish(t)            /\ UNCHANGED mcVars
MCUnpinDec(t)                    == UnpinDec(t)                    /\ UNCHANGED mcVars
MCUnpinPublish(t)                == UnpinPublish(t)                /\ UNCHANGED mcVars
MCRepin(t)                       == Repin(t)                       /\ UNCHANGED mcVars
MCRepinAfterFinish(t)            == RepinAfterFinish(t)            /\ UNCHANGED mcVars
MCTryAdvLoadGlobal(t)            == TryAdvLoadGlobal(t)            /\ UNCHANGED mcVars
MCTryAdvFence(t)                 == TryAdvFence(t)                 /\ UNCHANGED mcVars
MCTryAdvIter(t)                  == TryAdvIter(t)                  /\ UNCHANGED mcVars
MCTryAdvAbortStalled(t)          == TryAdvAbortStalled(t)          /\ UNCHANGED mcVars
MCTryAdvAbortDifferentEpoch(t)   == TryAdvAbortDifferentEpoch(t)   /\ UNCHANGED mcVars
MCCollectScan(t)                 == CollectScan(t)                 /\ UNCHANGED mcVars
MCBagDrop(t)                     == BagDrop(t)                     /\ UNCHANGED mcVars
MCInDeferCallbackPin(t)          == InDeferCallbackPin(t)          /\ UNCHANGED mcVars
MCInDeferCallbackUnpin(t)        == InDeferCallbackUnpin(t)        /\ UNCHANGED mcVars
MCInDeferCallbackDefer(t)        == InDeferCallbackDefer(t)        /\ UNCHANGED mcVars
MCFinalize(t)                    == Finalize(t)                    /\ UNCHANGED mcVars
MCFinalizePushBag(t)             == FinalizePushBag(t)             /\ UNCHANGED mcVars
MCFinalizeMarkDeleted(t)         == FinalizeMarkDeleted(t)         /\ UNCHANGED mcVars
MCPushBag(t)                     == PushBag(t)                     /\ UNCHANGED mcVars
MCFlush(t)                       == Flush(t)                       /\ UNCHANGED mcVars
MCPublishObject(t, o)            == PublishObject(t, o)            /\ UNCHANGED mcVars
MCUnlinkObject(t, o)             == UnlinkObject(t, o)             /\ UNCHANGED mcVars
MCReadAndDeref(t, o)             == ReadAndDeref(t, o)             /\ UNCHANGED mcVars

\* ========================================================================
\* MC Init / Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ cPin = 0
    /\ cAdvance = 0
    /\ cBuggyRetire = 0
    /\ cSkipFence = 0
    /\ cDefer = 0
    /\ cRepinAfter = 0
    /\ cUnprotectedDefer = 0
    /\ cSlotReuse = 0
    /\ cStalledIter = 0

MCNext ==
    \/ \E t \in Thread :
        \/ MCPinIncGuardCount(t)
        \/ MCPinLoadGlobal(t)
        \/ MCPinPublish(t)
        \/ MCPinMaybeCollect(t)
        \/ MCPinCollectFinish(t)
        \/ MCUnpinDec(t)
        \/ MCUnpinPublish(t)
        \/ MCRepin(t)
        \/ MCRepinAfterStart(t)
        \/ MCRepinAfterFinish(t)
        \/ MCTryAdvLoadGlobal(t)
        \/ MCTryAdvFence(t)
        \/ MCTryAdvIter(t)
        \/ MCTryAdvAbortStalled(t)
        \/ MCTryAdvAbortDifferentEpoch(t)
        \/ MCTryAdvFinishStore(t)
        \/ MCCollectScan(t)
        \/ MCBagDrop(t)
        \/ MCInDeferCallbackPin(t)
        \/ MCInDeferCallbackUnpin(t)
        \/ MCInDeferCallbackDefer(t)
        \/ MCFinalize(t)
        \/ MCFinalizePushBag(t)
        \/ MCFinalizeMarkDeleted(t)
        \/ MCPushBag(t)
        \/ MCFlush(t)
        \/ MCSlotReuse(t)
        \/ \E o \in Object : \E k \in {"Noop", "Pin", "Defer"} : MCDefer(t, o, k)
        \/ \E o \in Object : MCBuggyRetire(t, o)
        \/ \E o \in Object : MCUnprotectedDefer(t, o)
        \/ \E o \in Object : MCPublishObject(t, o)
        \/ \E o \in Object : MCUnlinkObject(t, o)
        \/ \E o \in Object : MCReadAndDeref(t, o)
    \/ \E s \in {"PinFence", "TryAdvFence"} : MCSkipFence(s)

MCSpec == MCInit /\ [][MCNext]_<<allVars, mcVars>>

\* ========================================================================
\* State constraint
\* ========================================================================

StateConstraint ==
    /\ globalEpoch <= MaxEpoch
    /\ Len(sealedBags) <= 4
    /\ Cardinality(retired) <= 6
    /\ \A t \in Thread : pinCount[t] <= 4
    /\ \A t \in Thread : objectGen[t] <= 2

\* ========================================================================
\* Symmetry
\* ========================================================================

Symmetry == Permutations(Thread) \cup Permutations(Object)

\* ========================================================================
\* View — exclude counters from state hash
\* ========================================================================

View == <<globalEpoch, sealedBags, retired,
          localEpoch, guardCount, handleCount, pinCount, bag, localState,
          pc, pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Invariants — re-export under MC names
\* ========================================================================

\* Standard / structural
MCGuardCountNonNegative          == GuardCountNonNegative
MCHandleCountNonNegative         == HandleCountNonNegative
MCValidPC                        == ValidPC
MCValidLocalState                == ValidLocalState
MCSealedBagsMonotone             == SealedBagsMonotone
MCLocalPinnedWhenGuarded         == LocalPinnedWhenGuarded
MCAdvanceRequiresAllPinnedAtCurrent == AdvanceRequiresAllPinnedAtCurrent

\* Family-specific (commented out in MC.cfg by default; enabled in hunt)
MCRetireImpliesUnreachable       == RetireImpliesUnreachable
MCNoUseAfterRetire               == NoUseAfterRetire
MCLocalEpochBoundedByGlobal      == LocalEpochBoundedByGlobal
MCFinalizeDoesNotRecurse         == FinalizeDoesNotRecurse
MCIsExpiredImpliesGap2           == IsExpiredImpliesGap2

====
