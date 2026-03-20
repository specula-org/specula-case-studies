---- MODULE MC_v2 ----
\* ===================================================================================
\* Model Checking Wrapper for arc-swap v2 (non-atomic helping)
\* ===================================================================================

EXTENDS base_v2

CONSTANTS
    MaxSwaps,
    MaxOrderingGaps,
    MaxStaleReads,
    MaxFallbacks,
    MaxHelps          \* Bound on writer help operations

VARIABLES
    swapCount,
    orderingGapCount,
    staleReadCount,
    fallbackCount,
    helpCount         \* Counter: writer helps performed

mcVars == <<swapCount, orderingGapCount, staleReadCount, fallbackCount, helpCount>>
allVars == <<vars, mcVars>>

ModelSymmetry == Permutations(Thread)

\* ===================================================================================
\* Counter-Bounded Actions
\* ===================================================================================

MCWriterSwap(t) ==
    /\ swapCount < MaxSwaps
    /\ WriterSwap(t)
    /\ swapCount' = swapCount + 1
    /\ UNCHANGED <<orderingGapCount, staleReadCount, fallbackCount, helpCount>>

MCCASSwap(t) ==
    /\ swapCount < MaxSwaps
    /\ CASSwap(t)
    /\ swapCount' = swapCount + 1
    /\ UNCHANGED <<orderingGapCount, staleReadCount, fallbackCount, helpCount>>

MCWriterScanSlot(t) ==
    /\ wPC[t] = "w_scanning"
    /\ \E target \in Thread, slot \in Slot :
        /\ <<target, slot>> \notin wScanned[t]
        /\ \/ \* NORMAL PATH
              /\ IF debtSlot[target][slot] = wOldPtr[t]
                 THEN /\ debtSlot' = [debtSlot EXCEPT ![target][slot] = NullPtr]
                      /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
                 ELSE /\ UNCHANGED <<debtSlot, refCount>>
              /\ UNCHANGED <<orderingGapCount>>
           \/ \* ORDERING GAP (bounded)
              /\ orderingGapCount < MaxOrderingGaps
              \* Guard: CAS (RMW) always reads latest for confirmed debts
              /\ ~(rPC[target] = "r_holding" /\ rHasDebt[target] /\ rSlot[target] = slot)
              /\ UNCHANGED <<debtSlot, refCount>>
              /\ orderingGapCount' = orderingGapCount + 1
        /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {<<target, slot>>}]
    /\ UNCHANGED <<coreVars, ptrAlive, readerVars, wPC, wOldPtr, ptrVars, genVars,
                   helpVars, swapCount, staleReadCount, fallbackCount, helpCount>>

MCReaderFallbackLoad(t) ==
    /\ rPC[t] = "r_fallback_reserve"
    /\ \E p \in Ptr :
        /\ \/ /\ p = storagePtr
              /\ UNCHANGED staleReadCount
           \/ /\ p \in EverAllocated
              /\ staleReadCount < MaxStaleReads
              /\ staleReadCount' = staleReadCount + 1
        /\ rCandidate' = [rCandidate EXCEPT ![t] = p]
        /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[p]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fallback_loaded"]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rHasDebt, rPath,
                   writerVars, ptrVars, genVars, helpState, helpRepl,
                   swapCount, orderingGapCount, fallbackCount, helpCount>>

MCReaderFallbackReserve(t) ==
    /\ fallbackCount < MaxFallbacks
    /\ ReaderFallbackReserve(t)
    /\ fallbackCount' = fallbackCount + 1
    /\ UNCHANGED <<swapCount, orderingGapCount, staleReadCount, helpCount>>

MCWriterHelpReader(t, target) ==
    /\ helpCount < MaxHelps
    /\ WriterHelpReader(t, target)
    /\ helpCount' = helpCount + 1
    /\ UNCHANGED <<swapCount, orderingGapCount, staleReadCount, fallbackCount>>

\* ===================================================================================
\* Init and Next
\* ===================================================================================

MCInit ==
    /\ Init
    /\ swapCount = 0
    /\ orderingGapCount = 0
    /\ staleReadCount = 0
    /\ fallbackCount = 0
    /\ helpCount = 0

MCNext ==
    \/ \E t \in Thread :
        \* --- Reader fast path (unbounded) ---
        \/ ReaderAcquireFast(t)       /\ UNCHANGED mcVars
        \/ ReaderConfirmFast(t)       /\ UNCHANGED mcVars
        \/ ReaderResolveFast(t)       /\ UNCHANGED mcVars
        \* --- Reader fallback (bounded, non-atomic) ---
        \/ MCReaderFallbackReserve(t)
        \/ MCReaderFallbackLoad(t)
        \/ ReaderFallbackStoreSlot(t) /\ UNCHANGED mcVars
        \/ ReaderFallbackConfirm(t)   /\ UNCHANGED mcVars
        \* --- Reader drop (unbounded) ---
        \/ ReaderDropGuard(t)         /\ UNCHANGED mcVars
        \* --- Writer ---
        \/ MCWriterSwap(t)
        \/ MCCASSwap(t)
        \/ WriterPayInit(t)           /\ UNCHANGED mcVars
        \/ MCWriterScanSlot(t)
        \/ WriterPayDone(t)           /\ UNCHANGED mcVars
        \/ WriterReturn(t)            /\ UNCHANGED mcVars
        \/ CASWriterReturn(t)         /\ UNCHANGED mcVars
        \* --- Writer help + cooldown ---
        \/ ClaimNode(t)               /\ UNCHANGED mcVars
        \/ \E target \in Thread :
            \/ MCWriterHelpReader(t, target)
            \/ WriterReserveNode(t, target) /\ UNCHANGED mcVars
            \/ WriterReleaseNode(t, target) /\ UNCHANGED mcVars
    \/ \E target \in Thread :
        CheckCooldown(target) /\ UNCHANGED mcVars

MCSpec == MCInit /\ [][MCNext]_allVars

\* ===================================================================================
\* State Space Constraint
\* ===================================================================================

MCStateConstraint ==
    /\ \A p \in Ptr : refCount[p] <= 10
    /\ \A t \in Thread : activeWriters[t] <= 2

\* ===================================================================================
\* Type + Structural Invariants
\* ===================================================================================

MCTypeOK ==
    /\ TypeOK
    /\ swapCount \in 0..MaxSwaps
    /\ orderingGapCount \in 0..MaxOrderingGaps
    /\ staleReadCount \in 0..MaxStaleReads
    /\ fallbackCount \in 0..MaxFallbacks
    /\ helpCount \in 0..MaxHelps

====
