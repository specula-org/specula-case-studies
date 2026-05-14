---- MODULE MC ----
\* ===================================================================================
\* Model Checking specification for arc-swap base spec (round 4).
\*
\* Wraps base.tla with counter-bounded fault-injection actions.
\*
\* Fault model coverage (per concurrent-analysis.md §5):
\*   5.1 Thread interleaving:    via per-step actions in base.tla (FastLoad / SlotAcquire
\*                               / ConfirmLoad / BranchHit / Resolve / WriterScanSlot /
\*                               ReaderFallbackDiscardNode etc.)  Family 5's split is the
\*                               headline 5.1 audit this round.
\*   5.2 Cancellation:           n/a (synchronous API; async drop is documented safe)
\*   5.3 OOM:                    skipped (target documented to abort on alloc failure)
\*   5.4 CAS_weak:               not modeled — compare_exchange_weak failures already
\*                               covered by CASExchangeFail's stale-storage branch
\*   5.5 MemOrder:               MCPickRelaxSite — base PickRelaxSite + counter bound
\*                               (covers stale-snapshot in writer scan via "ListHeadLoad",
\*                                stale fast-confirm via "FastConfirmLoad", etc.)
\*   5.6 ABA:                    via addr+gen tuple in base; address reuse in WriterSwap
\*   5.7 Caller misuse:          MCSendGuard / MCGuardClone / MCDropArcSwap / MCCASRawStale —
\*                               counter-bounded harness actions
\*   5.8 Lost wakeup:            n/a (no wait/notify primitives)
\*
\* Bug-family coverage (round 4 brief §2):
\*   F1 — counter MaxOrderingGaps (PickRelaxSite)
\*   F2 — counters MaxSendGuards, MaxGuardClones, MaxArcSwapDrops, MaxCASRawStale, MaxCASOps
\*   F3 — implicit (always on; per-slot WriterScanSlot + StaleSnapshotSafety invariant);
\*        also reachable via Family 1 relaxation of "ListHeadLoad" / "FallbackLoad"
\*   F4 — implicit (always on; MaxHelpGen drives wrap; inflightHelp tracks reservations)
\*   F5 — NEW: action granularity audit, NoDanglingTransaction invariant
\* ===================================================================================

EXTENDS base

CONSTANTS
    MaxOrderingGaps,    \* bound on PickRelaxSite (F1)
    MaxSendGuards,      \* bound on SendGuard (F2)
    MaxGuardClones,     \* bound on GuardClone (F2 NEW)
    MaxArcSwapDrops,    \* bound on DropArcSwap (F2)
    MaxCASRawStale,     \* bound on CASBegin with kind=RAWSTALE (F2)
    MaxSwaps,           \* bound on total WriterSwap (state space control)
    MaxCASOps           \* bound on total CASBegin

\* Counters (single record-style group to keep UNCHANGED clauses tight)
VARIABLES
    cOrderingGaps,
    cSendGuards,
    cGuardClones,
    cArcSwapDrops,
    cCASRawStale,
    cSwaps,
    cCASOps

mcCounters == <<cOrderingGaps, cSendGuards, cGuardClones, cArcSwapDrops,
                cCASRawStale, cSwaps, cCASOps>>

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
    /\ UNCHANGED <<cSendGuards, cGuardClones, cArcSwapDrops, cCASRawStale,
                   cSwaps, cCASOps>>

MCSendGuard(src, dst) ==
    /\ cSendGuards < MaxSendGuards
    /\ B!SendGuard(src, dst)
    /\ cSendGuards' = cSendGuards + 1
    /\ UNCHANGED <<cOrderingGaps, cGuardClones, cArcSwapDrops, cCASRawStale,
                   cSwaps, cCASOps>>

MCGuardClone(t) ==
    /\ cGuardClones < MaxGuardClones
    /\ B!GuardClone(t)
    /\ cGuardClones' = cGuardClones + 1
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cArcSwapDrops, cCASRawStale,
                   cSwaps, cCASOps>>

MCDropArcSwap ==
    /\ cArcSwapDrops < MaxArcSwapDrops
    /\ B!DropArcSwap
    /\ cArcSwapDrops' = cArcSwapDrops + 1
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cGuardClones, cCASRawStale,
                   cSwaps, cCASOps>>

\* CAS bounded; we additionally count RAWSTALE separately to bound the
\* documented-hazard interleavings without bounding ordinary CAS too tight.
MCCASBegin(t) ==
    /\ cCASOps < MaxCASOps
    /\ B!CASBegin(t)
    /\ cCASOps' = cCASOps + 1
    /\ IF casKind'[t] = CAS_KIND_RAWSTALE
       THEN /\ cCASRawStale < MaxCASRawStale
            /\ cCASRawStale' = cCASRawStale + 1
       ELSE UNCHANGED cCASRawStale
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cGuardClones, cArcSwapDrops, cSwaps>>

\* WriterSwap bounded — non-deterministic action that introduces new state.
MCWriterSwap(t) ==
    /\ cSwaps < MaxSwaps
    /\ B!WriterSwap(t)
    /\ cSwaps' = cSwaps + 1
    /\ UNCHANGED <<cOrderingGaps, cSendGuards, cGuardClones, cArcSwapDrops,
                   cCASRawStale, cCASOps>>

\* ===================================================================================
\* Init / Next
\* ===================================================================================

MCInit ==
    /\ B!Init
    /\ cOrderingGaps = 0
    /\ cSendGuards   = 0
    /\ cGuardClones  = 0
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
            \/ B!ReaderFallbackDiscardNode(t)
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
    \/ \E t \in Thread : MCGuardClone(t)
    \/ \E src \in Thread, dst \in Thread : MCSendGuard(src, dst)
    \/ \E s \in RelaxSites : MCPickRelaxSite(s)
    \/ MCDropArcSwap

MCSpec == MCInit /\ [][MCNext]_mcvars

\* ===================================================================================
\* Symmetry / view
\* ===================================================================================

MCSymmetry == Permutations(Thread) \cup Permutations(Addr)

MCView == <<allocVars, nodeVars, slotVars, threadOwnVars, readerVars, writerVars,
            casVars, clientVars, mcVars>>

\* ===================================================================================
\* Invariants — extension and structural
\* (Bug-family invariants are commented out in MC.cfg but enabled in MC_hunt_*.cfg)
\* ===================================================================================

MCTypeOK ==
    /\ B!TypeOK
    /\ cOrderingGaps \in 0..MaxOrderingGaps
    /\ cSendGuards   \in 0..MaxSendGuards
    /\ cGuardClones  \in 0..MaxGuardClones
    /\ cArcSwapDrops \in 0..MaxArcSwapDrops
    /\ cCASRawStale  \in 0..MaxCASRawStale
    /\ cSwaps        \in 0..MaxSwaps
    /\ cCASOps       \in 0..MaxCASOps

\* Re-export base invariants for readability and cfg use
MCNoUseAfterFree              == B!NoUseAfterFree
MCPayAllCompleteness          == B!PayAllCompleteness
MCStaleSnapshotSafety         == B!StaleSnapshotSafety
MCNoTornGuardState            == B!NoTornGuardState
MCRefCountNonNeg              == B!RefCountNonNeg
MCRefCountAccounting          == B!RefCountAccounting
MCCASIntendedSemantics        == B!CASIntendedSemantics
MCNoOrphanedDebt              == B!NoOrphanedDebt
MCNoConcurrentNodeClaim       == B!NoConcurrentNodeClaim
MCCooldownDrainSafety         == B!CooldownDrainSafety
MCNoStaleWithoutRelax         == B!NoStaleWithoutRelax
MCNoDanglingTransaction       == B!NoDanglingTransaction
MCDeadRefCountZero            == B!DeadRefCountZero
MCStorageLive                 == B!StorageLive
MCReaderWriterExclusive       == B!ReaderWriterExclusive
MCAllOccupantsAllocated       == B!AllOccupantsAllocated
MCInflightHelpBounded         == B!InflightHelpBounded
MCLocalNodeOwnership          == B!LocalNodeOwnership

====
