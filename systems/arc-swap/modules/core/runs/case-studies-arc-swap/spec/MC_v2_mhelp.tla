---- MODULE MC_v2_mhelp ----
\* ===================================================================================
\* Model Checking Wrapper for arc-swap v2 with MANDATORY HELPING
\* ===================================================================================
\*
\* Same as MC_v2 but the writer MUST attempt to help all other threads
\* during scanning before calling WriterPayDone. This models the real
\* pay_all code which always calls help() for every node in the linked list.
\*
\* We add a variable wHelpAttempted to track which targets each writer has
\* attempted to help during the current scan cycle.

EXTENDS base_v2

CONSTANTS
    MaxSwaps,
    MaxOrderingGaps,
    MaxStaleReads,
    MaxFallbacks,
    MaxHelps

VARIABLES
    swapCount,
    orderingGapCount,
    staleReadCount,
    fallbackCount,
    helpCount,
    wHelpAttempted     \* [Thread -> SUBSET Thread]: targets writer has attempted to help

mcVars == <<swapCount, orderingGapCount, staleReadCount, fallbackCount, helpCount, wHelpAttempted>>
allVars == <<vars, mcVars>>

ModelSymmetry == Permutations(Thread)

\* ===================================================================================
\* Counter-Bounded Actions (same as MC_v2 except where noted)
\* ===================================================================================

MCWriterSwap(t) ==
    /\ swapCount < MaxSwaps
    /\ WriterSwap(t)
    /\ swapCount' = swapCount + 1
    /\ wHelpAttempted' = [wHelpAttempted EXCEPT ![t] = {}]
    /\ UNCHANGED <<orderingGapCount, staleReadCount, fallbackCount, helpCount>>

MCCASSwap(t) ==
    /\ swapCount < MaxSwaps
    /\ CASSwap(t)
    /\ swapCount' = swapCount + 1
    /\ wHelpAttempted' = [wHelpAttempted EXCEPT ![t] = {}]
    /\ UNCHANGED <<orderingGapCount, staleReadCount, fallbackCount, helpCount>>

MCWriterScanSlot(t) ==
    /\ wPC[t] = "w_scanning"
    /\ \E target \in Thread, slot \in Slot :
        /\ <<target, slot>> \notin wScanned[t]
        \* KEY: Writer must attempt help for target BEFORE scanning target's slots.
        \* This models pay_all: for each node, help() is called before scanning slots.
        /\ target = t \/ target \in wHelpAttempted[t]
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
                   helpVars, swapCount, staleReadCount, fallbackCount, helpCount, wHelpAttempted>>

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
                   swapCount, orderingGapCount, fallbackCount, helpCount, wHelpAttempted>>

MCReaderFallbackReserve(t) ==
    /\ fallbackCount < MaxFallbacks
    /\ ReaderFallbackReserve(t)
    /\ fallbackCount' = fallbackCount + 1
    /\ UNCHANGED <<swapCount, orderingGapCount, staleReadCount, helpCount, wHelpAttempted>>

\* ===================================================================================
\* Mandatory Help Attempt (NEW)
\* ===================================================================================
\*
\* Writer must attempt to help each target before finishing scan.
\* If target is in "reserving" state: perform actual help (WriterHelpReader)
\* If target is not in "reserving": no-op, just mark as attempted

MCWriterHelpAttempt(t, target) ==
    /\ wPC[t] = "w_scanning"
    /\ t /= target
    /\ target \notin wHelpAttempted[t]
    /\ IF helpState[target] = "reserving"
       THEN /\ helpCount < MaxHelps
            /\ WriterHelpReader(t, target)
            /\ helpCount' = helpCount + 1
       ELSE UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                        genVars, helpVars, helpCount>>
    /\ wHelpAttempted' = [wHelpAttempted EXCEPT ![t] = @ \cup {target}]
    /\ UNCHANGED <<swapCount, orderingGapCount, staleReadCount, fallbackCount>>

\* ===================================================================================
\* Guarded WriterPayDone: requires all targets to have been help-attempted
\* ===================================================================================

MCWriterPayDone(t) ==
    /\ \A target \in Thread : target /= t => target \in wHelpAttempted[t]
    /\ WriterPayDone(t)
    /\ UNCHANGED mcVars

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
    /\ wHelpAttempted = [t \in Thread |-> {}]

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
        \/ MCWriterPayDone(t)
        \/ WriterReturn(t)            /\ UNCHANGED mcVars
        \/ CASWriterReturn(t)         /\ UNCHANGED mcVars
        \* --- Mandatory help attempt + cooldown ---
        \/ ClaimNode(t)               /\ UNCHANGED mcVars
        \/ \E target \in Thread :
            \/ MCWriterHelpAttempt(t, target)
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
    /\ wHelpAttempted \in [Thread -> SUBSET Thread]

====
