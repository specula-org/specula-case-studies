---- MODULE MC ----
\* ===================================================================================
\* Model Checking Wrapper for arc-swap Debt-Based Reader Tracking
\* ===================================================================================
\*
\* Wraps base spec with counter-bounded fault-injection actions for
\* exhaustive state space exploration.
\*
\* Bounded actions (introduce non-determinism):
\*   - WriterSwap: bounded by MaxSwaps
\*   - Ordering gap in WriterScanSlot: bounded by MaxOrderingGaps
\*   - Stale read in ReaderFallbackLoad: bounded by MaxStaleReads
\*
\* Unbounded actions (react to existing state):
\*   - ReaderAcquireFast, ReaderConfirmFast, ReaderResolveFast
\*   - ReaderDropGuard
\*   - WriterPayInit, WriterScanSlot (normal path), WriterPayDone, WriterReturn
\*   - CheckCooldown, ClaimNode, WriterReserveNode, WriterReleaseNode

EXTENDS base

CONSTANTS
    MaxSwaps,          \* Max writer swap operations (bounds pointer allocation)
    MaxOrderingGaps,   \* Max times writer can miss a debt (Family 1)
    MaxStaleReads,     \* Max times fallback can read stale (Family 1)
    MaxFallbacks       \* Max fallback loads (bounds state space)

VARIABLES
    swapCount,         \* Counter: writer swaps performed
    orderingGapCount,  \* Counter: ordering gaps exercised
    staleReadCount,    \* Counter: stale reads exercised
    fallbackCount      \* Counter: fallback loads performed

mcVars == <<swapCount, orderingGapCount, staleReadCount, fallbackCount>>
allVars == <<vars, mcVars>>

\* ===================================================================================
\* Symmetry
\* ===================================================================================

\* Threads are interchangeable (symmetric)
ModelSymmetry == Permutations(Thread)

\* ===================================================================================
\* Counter-Bounded Actions
\* ===================================================================================

\* Bounded: Writer swap (allocates new pointer = primary non-determinism source)
MCWriterSwap(t) ==
    /\ swapCount < MaxSwaps
    /\ WriterSwap(t)
    /\ swapCount' = swapCount + 1
    /\ UNCHANGED <<orderingGapCount, staleReadCount, fallbackCount>>

\* Writer scan with ordering gap tracking
\* Normal path (see actual value): unbounded
\* Ordering gap path (miss debt): bounded by MaxOrderingGaps
MCWriterScanSlot(t) ==
    /\ wPC[t] = "w_scanning"
    /\ \E target \in Thread, slot \in Slot :
        /\ <<target, slot>> \notin wScanned[t]
        /\ \/ \* NORMAL PATH: see actual slot value (unbounded)
              /\ IF debtSlot[target][slot] = wOldPtr[t]
                 THEN /\ debtSlot' = [debtSlot EXCEPT ![target][slot] = NullPtr]
                      /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
                 ELSE /\ UNCHANGED <<debtSlot, refCount>>
              /\ UNCHANGED <<orderingGapCount>>
           \/ \* ORDERING GAP: miss the debt (bounded)
              /\ orderingGapCount < MaxOrderingGaps
              \* Guard: CAS (RMW) always reads latest value in modification order
              \* (C++ [atomics.order]/10), so a confirmed debt cannot be missed.
              \* The gap can only occur for unconfirmed debts (r_fast_confirm)
              \* where the reader's SeqCst store and writer's AcqRel CAS have
              \* no happens-before chain through storagePtr yet.
              /\ ~(rPC[target] = "r_holding" /\ rHasDebt[target] /\ rSlot[target] = slot)
              /\ UNCHANGED <<debtSlot, refCount>>
              /\ orderingGapCount' = orderingGapCount + 1
        /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {<<target, slot>>}]
    /\ UNCHANGED <<coreVars, ptrAlive, readerVars, wPC, wOldPtr, ptrVars, genVars,
                   swapCount, staleReadCount, fallbackCount>>

\* Bounded: Fallback with stale read tracking
MCReaderFallbackLoad(t) ==
    /\ rPC[t] = "r_idle"
    /\ nodeState[t] = NODE_USED
    /\ \A s \in FastSlot : debtSlot[t][s] /= NullPtr
    /\ fallbackCount < MaxFallbacks
    /\ \E p \in Ptr :
        /\ \/ /\ p = storagePtr
              /\ UNCHANGED staleReadCount
           \/ /\ p \in EverAllocated
              /\ staleReadCount < MaxStaleReads
              /\ staleReadCount' = staleReadCount + 1
        /\ debtSlot' = [debtSlot EXCEPT ![t][HelpSlotIdx] = p]
        /\ rPtr'    = [rPtr    EXCEPT ![t] = p]
        /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[p]]
    /\ rSlot'    = [rSlot    EXCEPT ![t] = HelpSlotIdx]
    /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
    /\ rHasDebt' = [rHasDebt EXCEPT ![t] = TRUE]
    /\ rPath'    = [rPath    EXCEPT ![t] = "fallback"]
    /\ LET newGen == (gen[t] + 4) % (GEN_MAX + 1)
       IN /\ gen' = [gen EXCEPT ![t] = newGen]
          /\ IF newGen = 0
             THEN nodeState' = [nodeState EXCEPT ![t] = NODE_COOLDOWN]
             ELSE UNCHANGED nodeState
    /\ fallbackCount' = fallbackCount + 1
    /\ UNCHANGED <<coreVars, rcVars, writerVars, ptrVars, activeWriters, swapCount,
                   orderingGapCount>>

\* ===================================================================================
\* Init and Next
\* ===================================================================================

MCInit ==
    /\ Init
    /\ swapCount = 0
    /\ orderingGapCount = 0
    /\ staleReadCount = 0
    /\ fallbackCount = 0

MCNext ==
    \/ \E t \in Thread :
        \* --- Reader fast path (unbounded) ---
        \/ ReaderAcquireFast(t)   /\ UNCHANGED mcVars
        \/ ReaderConfirmFast(t)   /\ UNCHANGED mcVars
        \/ ReaderResolveFast(t)   /\ UNCHANGED mcVars
        \* --- Reader fallback (bounded) ---
        \/ MCReaderFallbackLoad(t)
        \* --- Reader drop (unbounded) ---
        \/ ReaderDropGuard(t)     /\ UNCHANGED mcVars
        \* --- Writer (swap bounded, rest unbounded) ---
        \/ MCWriterSwap(t)
        \/ WriterPayInit(t)       /\ UNCHANGED mcVars
        \/ MCWriterScanSlot(t)
        \/ WriterPayDone(t)       /\ UNCHANGED mcVars
        \/ WriterReturn(t)        /\ UNCHANGED mcVars
        \* --- Family 3: cooldown (unbounded) ---
        \/ ClaimNode(t)           /\ UNCHANGED mcVars
        \/ \E target \in Thread :
            \/ WriterReserveNode(t, target) /\ UNCHANGED mcVars
            \/ WriterReleaseNode(t, target) /\ UNCHANGED mcVars
    \/ \E target \in Thread :
        CheckCooldown(target) /\ UNCHANGED mcVars

MCSpec == MCInit /\ [][MCNext]_allVars

\* ===================================================================================
\* State Space Constraint
\* ===================================================================================

\* Limit refcount and activeWriters to prevent unbounded growth
MCStateConstraint ==
    /\ \A p \in Ptr : refCount[p] <= 10
    /\ \A t \in Thread : activeWriters[t] <= 2

\* ===================================================================================
\* Structural Invariants (always checked)
\* ===================================================================================

MCTypeOK ==
    /\ TypeOK
    /\ swapCount \in 0..MaxSwaps
    /\ orderingGapCount \in 0..MaxOrderingGaps
    /\ staleReadCount \in 0..MaxStaleReads
    /\ fallbackCount \in 0..MaxFallbacks

\* ===================================================================================
\* Temporal Properties
\* ===================================================================================

\* Liveness: Every reader eventually drops its guard (no permanent debt)
ReaderEventuallyDrops ==
    \A t \in Thread :
        rPC[t] = "r_holding" ~> rPC[t] = "r_idle"

\* Liveness: Every writer eventually completes its swap
WriterEventuallyCompletes ==
    \A t \in Thread :
        wPC[t] = "w_pay_init" ~> wPC[t] = "w_idle"

====
