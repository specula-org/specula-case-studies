---- MODULE MC ----
\* Model checking wrapper for crossbeam-epoch EBR specification.
\* Adds counter-bounded fault injection, symmetry, and structural constraints.

EXTENDS base

CONSTANTS
    \* Thread and Node sets (overridden in .cfg)
    T1, T2, T3,
    N0, N1, N2, N3,

    \* Counter bounds for non-deterministic actions
    MaxPushes,          \* Max QueuePush actions (introduces new nodes)
    MaxPops,            \* Max QueuePop actions (retires nodes)
    MaxPins,            \* Max outermost pin operations (ReadGlobalForPin)
    MaxNestedPins,      \* Max nested pin operations
    MaxUnpins,          \* Max unpin operations
    MaxHandleReleases,  \* Max ReleaseHandle actions
    MaxBagPushes,       \* Max PushLocalBag actions

    \* Buggy action bounds (0 = disabled)
    MaxBuggyPops,       \* Max QueuePopBuggy (Family 2 hunting)
    MaxNestedCollects,  \* Max NestedPinCollect (Family 1 hunting, Issue #105)

    \* Hunt extension bounds (0 = disabled)
    MaxRepins,              \* Max safe Repin (H2)
    MaxRepinsUnsafe,        \* Max unsafe RepinUnsafe (H2)
    MaxStaleBagPushes,      \* Max PushLocalBagStale (H3)
    MaxNonAtomicScans,      \* Max StartScan (H1)
    MaxNonAtomicFinalizes   \* Max FinalizeStart (H4)

VARIABLES
    \* Counter record for bounded actions
    actionCount

mcVars == <<actionCount>>
mcAllVars == <<allVars, mcVars>>

\* ============================================================================
\* Counter-Bounded Action Wrappers
\* ============================================================================

\* Helper: check and increment a counter field
CheckAndIncrement(field, max) ==
    /\ actionCount[field] < max
    /\ actionCount' = [actionCount EXCEPT ![field] = @ + 1]

\* --- Bounded non-deterministic actions ---

MCQueueLink(t, n) ==
    /\ CheckAndIncrement("pushes", MaxPushes)
    /\ QueueLink(t, n)

MCQueuePop(t) ==
    /\ CheckAndIncrement("pops", MaxPops)
    /\ QueuePop(t)

MCReadGlobalForPin(t) ==
    /\ CheckAndIncrement("pins", MaxPins)
    /\ ReadGlobalForPin(t)

MCNestedPin(t) ==
    /\ CheckAndIncrement("nestedPins", MaxNestedPins)
    /\ NestedPin(t)

MCUnpin(t) ==
    /\ CheckAndIncrement("unpins", MaxUnpins)
    /\ Unpin(t)

MCReleaseHandle(t) ==
    /\ CheckAndIncrement("handleReleases", MaxHandleReleases)
    /\ ReleaseHandle(t)

MCPushLocalBag(t) ==
    /\ CheckAndIncrement("bagPushes", MaxBagPushes)
    /\ PushLocalBag(t)

\* --- Bounded buggy actions (0 = disabled by default) ---

MCQueuePopBuggy(t) ==
    /\ CheckAndIncrement("buggyPops", MaxBuggyPops)
    /\ QueuePopBuggy(t)

MCNestedPinCollect(t) ==
    /\ CheckAndIncrement("nestedCollects", MaxNestedCollects)
    /\ NestedPinCollect(t)

\* --- Bounded hunt extension actions ---

MCRepin(t) ==
    /\ CheckAndIncrement("repins", MaxRepins)
    /\ Repin(t)

MCRepinUnsafe(t) ==
    /\ CheckAndIncrement("repinsUnsafe", MaxRepinsUnsafe)
    /\ RepinUnsafe(t)

MCPushLocalBagStale(t) ==
    /\ CheckAndIncrement("staleBagPushes", MaxStaleBagPushes)
    /\ PushLocalBagStale(t)

MCStartScan(t) ==
    /\ CheckAndIncrement("nonAtomicScans", MaxNonAtomicScans)
    /\ StartScan(t)

MCFinalizeStart(t) ==
    /\ CheckAndIncrement("nonAtomicFinalizes", MaxNonAtomicFinalizes)
    /\ FinalizeStart(t)

\* --- Unbounded reactive/deterministic actions ---
\* These react to existing state and don't introduce new non-determinism.

MCCompletePin(t) ==
    /\ CompletePin(t)
    /\ UNCHANGED mcVars

MCScanForAdvance(t) ==
    /\ ScanForAdvance(t)
    /\ UNCHANGED mcVars

MCStoreAdvancedEpoch(t) ==
    /\ StoreAdvancedEpoch(t)
    /\ UNCHANGED mcVars

MCCollectExpiredBag(t) ==
    /\ CollectExpiredBag(t)
    /\ UNCHANGED mcVars

MCQueueAdvanceTail(t) ==
    /\ QueueAdvanceTail(t)
    /\ UNCHANGED mcVars

MCAccessNode(t, n) ==
    /\ AccessNode(t, n)
    /\ UNCHANGED mcVars

MCFinalize(t) ==
    /\ Finalize(t)
    /\ UNCHANGED mcVars

\* --- Unbounded hunt extension reactive actions ---

MCScanOneThread(t, t2) ==
    /\ ScanOneThread(t, t2)
    /\ UNCHANGED mcVars

MCCompleteScan(t) ==
    /\ CompleteScan(t)
    /\ UNCHANGED mcVars

MCAbortScan(t) ==
    /\ AbortScan(t)
    /\ UNCHANGED mcVars

MCFinalizePushAndUnpin(t) ==
    /\ FinalizePushAndUnpin(t)
    /\ UNCHANGED mcVars

MCFinalizeComplete(t) ==
    /\ FinalizeComplete(t)
    /\ UNCHANGED mcVars

\* ============================================================================
\* MC Init and Next
\* ============================================================================

MCInit ==
    /\ Init
    /\ actionCount = [
           pushes |-> 0,
           pops |-> 0,
           pins |-> 0,
           nestedPins |-> 0,
           unpins |-> 0,
           handleReleases |-> 0,
           bagPushes |-> 0,
           buggyPops |-> 0,
           nestedCollects |-> 0,
           repins |-> 0,
           repinsUnsafe |-> 0,
           staleBagPushes |-> 0,
           nonAtomicScans |-> 0,
           nonAtomicFinalizes |-> 0
       ]

MCNext ==
    \E t \in Thread :
        \* --- Pin/Unpin ---
        \/ MCReadGlobalForPin(t)
        \/ MCCompletePin(t)
        \/ MCNestedPin(t)
        \/ MCUnpin(t)
        \* --- Epoch Advancement (atomic scan) ---
        \/ MCScanForAdvance(t)
        \/ MCStoreAdvancedEpoch(t)
        \* --- Garbage Collection ---
        \/ MCPushLocalBag(t)
        \/ MCCollectExpiredBag(t)
        \* --- MSQueue ---
        \/ MCQueuePop(t)
        \/ \E n \in Node \ {Sentinel} : MCQueueLink(t, n)
        \/ MCQueueAdvanceTail(t)
        \/ \E n \in Node : MCAccessNode(t, n)
        \* --- Thread Lifecycle ---
        \/ MCReleaseHandle(t)
        \/ MCFinalize(t)
        \* --- Buggy actions (bounded, 0 = disabled) ---
        \/ MCQueuePopBuggy(t)
        \/ MCNestedPinCollect(t)
        \* --- Hunt H1: Non-atomic scan ---
        \/ MCStartScan(t)
        \/ \E t2 \in Thread : MCScanOneThread(t, t2)
        \/ MCCompleteScan(t)
        \/ MCAbortScan(t)
        \* --- Hunt H2: Repin ---
        \/ MCRepin(t)
        \/ MCRepinUnsafe(t)
        \* --- Hunt H3: Stale bag sealing ---
        \/ MCPushLocalBagStale(t)
        \* --- Hunt H4: Non-atomic finalize ---
        \/ MCFinalizeStart(t)
        \/ MCFinalizePushAndUnpin(t)
        \/ MCFinalizeComplete(t)

MCSpec == MCInit /\ [][MCNext]_mcAllVars

\* ============================================================================
\* Symmetry
\* ============================================================================

\* Thread symmetry: all threads are interchangeable
MCSymmetry == Permutations({T1, T2, T3})

\* Note: Node symmetry is NOT safe because Sentinel is distinguished.
\* We could use Permutations(Node \ {Sentinel}) but the gain is small.

\* ============================================================================
\* State Space Constraints
\* ============================================================================

\* Limit sealed bag size to prevent explosion
MaxSealedBags == 8
SealedBagConstraint == Cardinality(sealedBags) <= MaxSealedBags

\* Limit epoch range (epoch only increases, so this bounds the search)
MaxEpochValue == 6
EpochConstraint == globalEpoch <= MaxEpochValue

MCConstraint ==
    /\ SealedBagConstraint
    /\ EpochConstraint

\* ============================================================================
\* State View (exclude counters from state fingerprint for symmetry)
\* ============================================================================

\* Counters don't affect correctness, only pruning.
\* Excluding them from the view reduces duplicate states.
MCView == <<epochVars, gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Structural Invariants (always enabled)
\* ============================================================================

\* All base structural invariants apply
MCStructuralInvariants ==
    /\ TypeOK
    /\ PinnedConsistency
    /\ QueueStructure
    /\ AccessRequiresPin
    /\ NoOrphanedBags
    /\ DeletedInactive

\* ============================================================================
\* Safety Invariants (always enabled)
\* ============================================================================

MCSafetyInvariants ==
    /\ SafeReclamation
    /\ NoDoubleFree

\* ============================================================================
\* Extension Invariants (for bug hunting — commented out in MC.cfg)
\* ============================================================================

\* EpochMonotonicity — uncomment for Family 1 (MC-2) hunting
\* TailReachability — uncomment for Family 2 (MC-3) hunting
\* FinalizeOnce — uncomment for Family 3 (MC-5) hunting

====
