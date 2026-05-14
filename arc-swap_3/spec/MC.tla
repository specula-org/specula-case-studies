---- MODULE MC ----
\* ===================================================================================
\* Model Checking specification for arc-swap base spec (round 3).
\*
\* Wraps base.tla with counter-bounded fault-injection actions.
\*
\* Fault model coverage (per concurrent-analysis.md §5):
\*   5.1 Thread interleaving:    via per-step actions in base.tla (FastLoad / SlotAcquire
\*                               / ConfirmLoad / BranchHit / Resolve / WriterScanSlot etc.)
\*   5.2 Cancellation:           n/a (synchronous API; async drop is documented safe)
\*   5.3 OOM:                    skipped (target documented to abort on alloc failure)
\*   5.4 CAS_weak:               not modeled — compare_exchange_weak failures already
\*                               covered by CASExchangeFail's stale-storage branch
\*   5.5 MemOrder:               MCPickRelaxSite — base PickRelaxSite + counter bound
\*                               (covers stale-snapshot in writer scan via "ListHeadLoad",
\*                                "WriterScanCAS" relaxation sites)
\*   5.6 ABA:                    via addr+gen tuple in base; address reuse in WriterSwap
\*   5.7 Caller misuse:          MCSendGuard / MCDropArcSwap / MCCASRawStale —
\*                               counter-bounded harness actions
\*   5.8 Lost wakeup:            n/a (no wait/notify primitives)
\*
\* Bug-family coverage:
\*   A — counter MaxOrderingGaps (PickRelaxSite)
\*   B — implicit (always on; modeled in base via storageGen + addrGen)
\*   C — counters MaxSendGuards, MaxArcSwapDrops, MaxCASRawStale, MaxCASOps
\*   D — implicit (always on; MaxHelpGen drives wrap)
\*   E — implicit (per-slot WriterScanSlot; PayAllCompleteness invariant); also
\*       reachable via Family A relaxation of "ListHeadLoad" / "WriterScanCAS"
\* ===================================================================================

EXTENDS base

CONSTANTS
    MaxOrderingGaps,    \* bound on PickRelaxSite (Family A)
    MaxSendGuards,      \* bound on SendGuard (Family C)
    MaxArcSwapDrops,    \* bound on DropArcSwap (Family C)
    MaxCASRawStale,     \* bound on CASBegin with kind=RAWSTALE (Family C)
    MaxSwaps,           \* bound on total WriterSwap (state space control)
    MaxCASOps           \* bound on total CASBegin

\* Counters (single record to keep UNCHANGED clauses tight)
VARIABLES
    cOrderingGaps,
    cSendGuards,
    cArcSwapDrops,
    cCASRawStale,
    cSwaps,
    cCASOps

mcCounters == <<cOrderingGaps, cSendGuards, cArcSwapDrops, cCASRawStale,
                cSwaps, cCASOps>>

mcvars == <<vars, mcCounters>>

\* base instance for original operator access (cfg overrides operators)
B == INSTANCE base

\* ===================================================================================
\* Counter-bounded fault wrappers
\* ===================================================================================

MCPickRelaxSite(s) ==
    /\ cOrderingGaps < MaxOrderingGaps
    /\ B!PickRelaxSite(s)
    /\ cOrderingGaps' = cOrderingGaps + 1
    /\ UNCHANGED <<cSendGuards, cArcSwapDrops, cCASRawStale, cSwaps, cCASOps>>

MCSendGuard(src, dst) ==
    /\ cSendGuards < MaxSendGuards
    /\ B!SendGuard(src, dst)
    /\ cSendGuards' = cSendGuards + 1
    /\ UNCHANGED <<cOrderingGaps, cArcSwapDrops, cCASRawStale, cSwaps, cCASOps>>

MCDropArcSwap ==
    /\ cArcSwapDrops < MaxArcSwapDrops
    /\ B!DropArcSwap
    /\ cArcSwapDrops' = cArcSwapDrops + 1
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cCASRawStale, cSwaps, cCASOps>>

\* CAS bounded; we additionally count RAWSTALE separately to bound the
\* documented-hazard interleavings without bounding ordinary Arc/Guard CAS too tight.
MCCASBegin(t) ==
    /\ cCASOps < MaxCASOps
    /\ B!CASBegin(t)
    /\ cCASOps' = cCASOps + 1
    /\ IF casKind'[t] = CAS_KIND_RAWSTALE
       THEN /\ cCASRawStale < MaxCASRawStale
            /\ cCASRawStale' = cCASRawStale + 1
       ELSE UNCHANGED cCASRawStale
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cArcSwapDrops, cSwaps>>

\* WriterSwap bounded — non-deterministic action that introduces new state.
MCWriterSwap(t) ==
    /\ cSwaps < MaxSwaps
    /\ B!WriterSwap(t)
    /\ cSwaps' = cSwaps + 1
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cArcSwapDrops, cCASRawStale, cCASOps>>

\* ===================================================================================
\* Init / Next
\* ===================================================================================

MCInit ==
    /\ B!Init
    /\ cOrderingGaps = 0
    /\ cSendGuards   = 0
    /\ cArcSwapDrops = 0
    /\ cCASRawStale  = 0
    /\ cSwaps        = 0
    /\ cCASOps       = 0

\* All non-fault-injection actions pass through unchanged to mcCounters.
MCNonFaultStep ==
    /\ \/ \E t \in Thread :
            \/ B!ReaderFastLoad(t)
            \/ B!ReaderFastSlotAcquire(t)
            \/ B!ReaderFastConfirmLoad(t)
            \/ B!ReaderFastBranchHit(t)
            \/ B!ReaderFastResolve(t)
            \/ B!ReaderFallbackActiveAddr(t)
            \/ B!ReaderFallbackControlSwap(t)
            \/ B!ReaderFallbackCandidate(t)
            \/ B!ReaderFallbackSlotStore(t)
            \/ B!ReaderFallbackConfirmOK(t)
            \/ B!ReaderFallbackConfirmHelped(t)
            \/ B!ReaderFallbackResolveEnvelope(t)
            \/ B!GuardIntoInner(t)
            \/ B!DropGuard(t)
            \/ B!WriterPayInit(t)
            \/ B!WriterTraverseLoad(t)
            \/ B!WriterReserveNode(t)
            \/ B!WriterHelpNode(t)
            \/ B!WriterScanSlot(t)
            \/ B!WriterReleaseNode(t)
            \/ B!WriterPayDone(t)
            \/ B!WriterReturn(t)
            \/ B!CASCompareNotEqual(t)
            \/ B!CASExchangeOk(t)
            \/ B!CASExchangeFail(t)
       \/ \E t \in Thread, n \in Thread : B!ClaimNode(t, n)
       \/ \E n \in Thread : B!CheckCooldown(n)
    /\ UNCHANGED mcCounters

MCNext ==
    \/ MCNonFaultStep
    \/ \E t \in Thread : MCWriterSwap(t)
    \/ \E t \in Thread : MCCASBegin(t)
    \/ \E src \in Thread, dst \in Thread : MCSendGuard(src, dst)
    \/ \E s \in RelaxSites : MCPickRelaxSite(s)
    \/ MCDropArcSwap

MCSpec == MCInit /\ [][MCNext]_mcvars

\* ===================================================================================
\* Symmetry / view
\* ===================================================================================

MCSymmetry == Permutations(Thread) \cup Permutations(Addr)

MCView == <<allocVars, nodeVars, slotVars, readerVars, writerVars, casVars,
            clientVars, mcVars>>

\* ===================================================================================
\* Invariants — extension and structural
\* (Bug-family invariants are commented out in MC.cfg but enabled in MC_hunt_*.cfg)
\* ===================================================================================

MCTypeOK ==
    /\ B!TypeOK
    /\ cOrderingGaps \in 0..MaxOrderingGaps
    /\ cSendGuards   \in 0..MaxSendGuards
    /\ cArcSwapDrops \in 0..MaxArcSwapDrops
    /\ cCASRawStale  \in 0..MaxCASRawStale
    /\ cSwaps        \in 0..MaxSwaps
    /\ cCASOps       \in 0..MaxCASOps

\* Re-export base invariants for readability and cfg use
MCNoUseAfterFree              == B!NoUseAfterFree
MCPayAllCompleteness          == B!PayAllCompleteness
MCNoTornGuardState            == B!NoTornGuardState
MCRefCountNonNeg              == B!RefCountNonNeg
MCCASIntendedSemantics        == B!CASIntendedSemantics
MCNoConcurrentNodeClaim       == B!NoConcurrentNodeClaim
MCCooldownReleaseObservesZero == B!CooldownReleaseObservesZero
MCNoStaleWithoutRelax         == B!NoStaleWithoutRelax
MCNoDoublePay                 == B!NoDoublePay
MCGenWrapTriggersCooldown     == B!GenWrapTriggersCooldown
MCDeadRefCountZero            == B!DeadRefCountZero
MCStorageLive                 == B!StorageLive
MCReaderWriterExclusive       == B!ReaderWriterExclusive
MCAllOccupantsAllocated       == B!AllOccupantsAllocated

====
