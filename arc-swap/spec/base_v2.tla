---- MODULE base_v2 ----
\* ===================================================================================
\* TLA+ Specification: arc-swap Debt-Based Reader Tracking (v2)
\* ===================================================================================
\*
\* Extension of base.tla with NON-ATOMIC helping mechanism.
\* The fallback path is split into 4 steps (reserve, load, store-slot, complete)
\* and the writer can HELP a reader during its scan (providing a replacement).
\*
\* This models the actual code interleaving in:
\*   helping.rs:191-213 (get_debt), helping.rs:308-333 (confirm)
\*   helping.rs:215-302 (help), hybrid.rs:97-134 (fallback)

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    Thread, Ptr, NumFastSlots, InitPtr, NullPtr, GEN_MAX

ASSUME InitPtr \in Ptr
ASSUME NullPtr \notin Ptr
ASSUME NumFastSlots >= 1
ASSUME GEN_MAX >= 4

FastSlot    == 1..NumFastSlots
HelpSlotIdx == NumFastSlots + 1
Slot        == 1..(NumFastSlots + 1)
AllPtrs     == Ptr \cup {NullPtr}

NODE_USED     == "USED"
NODE_COOLDOWN == "COOLDOWN"
NODE_UNUSED   == "UNUSED"

\* ===================================================================================
\* Variables
\* ===================================================================================

VARIABLES
    \* --- Core protocol state (same as base) ---
    storagePtr, debtSlot, refCount, ptrAlive,
    rPC, rPtr, rSlot, rHasDebt, rPath, rPtrGen,
    wPC, wOldPtr, wScanned,
    ptrGen, gen, nodeState, activeWriters,
    \* --- NEW: Non-atomic helping mechanism ---
    helpState,    \* [Thread -> {"idle", "reserving", "helped"}]
    helpRepl,     \* [Thread -> AllPtrs]: replacement pointer (when helped)
    rCandidate    \* [Thread -> AllPtrs]: candidate loaded during fallback

coreVars   == <<storagePtr>>
debtVars   == <<debtSlot>>
rcVars     == <<refCount, ptrAlive>>
readerVars == <<rPC, rPtr, rSlot, rHasDebt, rPath, rPtrGen>>
writerVars == <<wPC, wOldPtr, wScanned>>
genVars    == <<gen, nodeState, activeWriters>>
ptrVars    == <<ptrGen>>
helpVars   == <<helpState, helpRepl, rCandidate>>

vars == <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars, genVars, helpVars>>

\* ===================================================================================
\* Helpers
\* ===================================================================================

AllDebtPositions == Thread \X Slot

DebtCount(ptr) ==
    Cardinality({<<t, s>> \in AllDebtPositions : debtSlot[t][s] = ptr})

EverAllocated == {p \in Ptr : ptrGen[p] > 0}

\* ===================================================================================
\* Init
\* ===================================================================================

Init ==
    /\ storagePtr = InitPtr
    /\ debtSlot   = [t \in Thread |-> [s \in Slot |-> NullPtr]]
    /\ refCount   = [p \in Ptr |-> IF p = InitPtr THEN 1 ELSE 0]
    /\ ptrAlive   = [p \in Ptr |-> (p = InitPtr)]
    /\ rPC        = [t \in Thread |-> "r_idle"]
    /\ rPtr       = [t \in Thread |-> NullPtr]
    /\ rSlot      = [t \in Thread |-> 0]
    /\ rHasDebt   = [t \in Thread |-> FALSE]
    /\ rPath      = [t \in Thread |-> "none"]
    /\ rPtrGen    = [t \in Thread |-> 0]
    /\ wPC        = [t \in Thread |-> "w_idle"]
    /\ wOldPtr    = [t \in Thread |-> NullPtr]
    /\ wScanned   = [t \in Thread |-> {}]
    /\ ptrGen     = [p \in Ptr |-> IF p = InitPtr THEN 1 ELSE 0]
    /\ gen           = [t \in Thread |-> 0]
    /\ nodeState     = [t \in Thread |-> NODE_USED]
    /\ activeWriters = [t \in Thread |-> 0]
    \* NEW
    /\ helpState  = [t \in Thread |-> "idle"]
    /\ helpRepl   = [t \in Thread |-> NullPtr]
    /\ rCandidate = [t \in Thread |-> NullPtr]

\* ===================================================================================
\* Reader Fast Path (same as base)
\* ===================================================================================

ReaderAcquireFast(t) ==
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"
    /\ nodeState[t] = NODE_USED
    /\ \E s \in FastSlot :
        /\ debtSlot[t][s] = NullPtr
        /\ debtSlot' = [debtSlot EXCEPT ![t][s] = storagePtr]
        /\ rSlot' = [rSlot EXCEPT ![t] = s]
    /\ rPtr'    = [rPtr    EXCEPT ![t] = storagePtr]
    /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[storagePtr]]
    /\ rPC'     = [rPC     EXCEPT ![t] = "r_fast_confirm"]
    /\ rPath'   = [rPath   EXCEPT ![t] = "fast"]
    /\ UNCHANGED <<coreVars, rcVars, rHasDebt, writerVars, ptrVars, genVars, helpVars>>

ReaderConfirmFast(t) ==
    /\ rPC[t] = "r_fast_confirm"
    /\ IF rPtr[t] = storagePtr
       THEN /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = TRUE]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rPath,
                           rPtrGen, writerVars, ptrVars, genVars, helpVars>>
       ELSE /\ rPC' = [rPC EXCEPT ![t] = "r_fast_resolve"]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rHasDebt,
                           rPath, rPtrGen, writerVars, ptrVars, genVars, helpVars>>

ReaderResolveFast(t) ==
    /\ rPC[t] = "r_fast_resolve"
    /\ IF debtSlot[t][rSlot[t]] = rPtr[t]
       THEN /\ debtSlot' = [debtSlot EXCEPT ![t][rSlot[t]] = NullPtr]
            /\ rPC'   = [rPC   EXCEPT ![t] = "r_idle"]
            /\ rSlot' = [rSlot EXCEPT ![t] = 0]
            /\ rPath' = [rPath EXCEPT ![t] = "none"]
            /\ UNCHANGED <<coreVars, rcVars, rPtr, rHasDebt, rPtrGen,
                           writerVars, ptrVars, genVars, helpVars>>
       ELSE /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = FALSE]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rPath,
                           rPtrGen, writerVars, ptrVars, genVars, helpVars>>

\* ===================================================================================
\* Reader Fallback Path: NON-ATOMIC (4 steps)
\* ===================================================================================

\* Step 1: Reserve helping slot (store gen in control)
\*   helping.rs:203 — active_addr.store(ptr, SeqCst)
\*   helping.rs:209 — control.swap(gen, SeqCst)
\* NOTE: In the real implementation, fallback triggers when all 8 fast slots
\* are full (from multiple nested load() calls). Since the spec models only
\* one reader state machine per thread, we allow non-deterministic fallback
\* to exercise this path. The fast slot guard is removed to prevent the
\* fallback path from being unreachable with NumFastSlots=1.
ReaderFallbackReserve(t) ==
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"
    /\ nodeState[t] = NODE_USED
    /\ helpState[t] = "idle"
    \* Store generation in control
    /\ helpState' = [helpState EXCEPT ![t] = "reserving"]
    \* Family 3: increment generation
    /\ LET newGen == (gen[t] + 4) % (GEN_MAX + 1)
       IN /\ gen' = [gen EXCEPT ![t] = newGen]
          /\ IF newGen = 0
             THEN nodeState' = [nodeState EXCEPT ![t] = NODE_COOLDOWN]
             ELSE UNCHANGED nodeState
    /\ rPC' = [rPC EXCEPT ![t] = "r_fallback_reserve"]
    /\ rPath' = [rPath EXCEPT ![t] = "fallback"]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rHasDebt, rPtrGen,
                   writerVars, ptrVars, activeWriters, helpRepl, rCandidate>>

\* Step 2: Load storage (Acquire — may read stale due to ordering gap)
\*   hybrid.rs:104 — storage.load(Acquire)
\*
\* KEY: Between step 1 and step 2, a writer may have changed storagePtr.
\* The Acquire load does NOT participate in SeqCst total order, so
\* the reader may see a stale pointer (Bug #198).
ReaderFallbackLoad(t) ==
    /\ rPC[t] = "r_fallback_reserve"
    /\ \E p \in Ptr :
        /\ \/ p = storagePtr               \* Normal: current value
           \/ p \in EverAllocated           \* Stale: ordering gap
        /\ rCandidate' = [rCandidate EXCEPT ![t] = p]
        /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[p]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fallback_loaded"]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rHasDebt, rPath,
                   writerVars, ptrVars, genVars, helpState, helpRepl>>

\* Step 3: Store candidate in debt slot
\*   helping.rs:312 — slot.0.swap(ptr, SeqCst)
\*
\* Between this step and step 4, a scanning writer can see rCandidate
\* in the helping slot and pay it (thinking it's a real debt).
ReaderFallbackStoreSlot(t) ==
    /\ rPC[t] = "r_fallback_loaded"
    /\ debtSlot' = [debtSlot EXCEPT ![t][HelpSlotIdx] = rCandidate[t]]
    /\ rSlot' = [rSlot EXCEPT ![t] = HelpSlotIdx]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fallback_stored"]
    /\ UNCHANGED <<coreVars, rcVars, rPtr, rHasDebt, rPath, rPtrGen,
                   writerVars, ptrVars, genVars, helpVars>>

\* Step 4: Confirm — swap control to IDLE, check if helped
\*   helping.rs:317 — control.swap(IDLE, SeqCst)
\*   helping.rs:318-332 — check control value
ReaderFallbackConfirm(t) ==
    /\ rPC[t] = "r_fallback_stored"
    /\ IF helpState[t] = "reserving"
       \* Nobody helped — reader got its debt confirmed
       THEN /\ helpState' = [helpState EXCEPT ![t] = "idle"]
            /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
            /\ rPtr'     = [rPtr     EXCEPT ![t] = rCandidate[t]]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = TRUE]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, writerVars, ptrVars,
                           genVars, helpRepl, rCandidate, rSlot, rPath, rPtrGen>>
       \* Writer helped — use replacement, pay back unused candidate debt
       \* helping.rs:322-331
       ELSE /\ helpState[t] = "helped"
            /\ helpState' = [helpState EXCEPT ![t] = "idle"]
            \* Reader holds replacement WITHOUT debt (writer already inc'd refcount)
            /\ rPtr' = [rPtr EXCEPT ![t] = helpRepl[t]]
            /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[helpRepl[t]]]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = FALSE]
            /\ rPC' = [rPC EXCEPT ![t] = "r_holding"]
            \* Pay back unused candidate from slot
            \* hybrid.rs:121-123
            /\ IF debtSlot[t][HelpSlotIdx] = rCandidate[t]
               \* CAS succeeds — clear slot, no refcount change
               THEN /\ debtSlot' = [debtSlot EXCEPT ![t][HelpSlotIdx] = NullPtr]
                    /\ UNCHANGED rcVars
               \* CAS fails — another writer already paid; dec refcount
               ELSE /\ refCount' = [refCount EXCEPT ![rCandidate[t]] = @ - 1]
                    /\ ptrAlive' = IF refCount'[rCandidate[t]] = 0
                                   THEN [ptrAlive EXCEPT ![rCandidate[t]] = FALSE]
                                   ELSE ptrAlive
                    /\ UNCHANGED debtVars
            /\ UNCHANGED <<coreVars, writerVars, ptrVars, genVars,
                           helpRepl, rCandidate, rSlot, rPath>>

\* ===================================================================================
\* Writer Help Reader (NEW action)
\* ===================================================================================

\* Writer helps a reader in fallback by providing a replacement pointer.
\*   helping.rs:215-302 — Slots::help
\*
\* Called during pay_all when writer sees a generation in reader's control.
\* Writer loads current storage value, increments refcount, offers as replacement.
WriterHelpReader(t, target) ==
    /\ wPC[t] = "w_scanning"
    /\ t /= target                          \* Can't help self (helping.rs:232)
    /\ helpState[target] = "reserving"      \* Reader is in fallback reservation
    \* Writer creates replacement by doing a full load: reads storagePtr, inc refcount
    \* helping.rs:258 — replacement()
    /\ refCount' = [refCount EXCEPT ![storagePtr] = @ + 1]
    \* CAS control: gen → envelope(replacement)
    \* helping.rs:278-280
    /\ helpState' = [helpState EXCEPT ![target] = "helped"]
    /\ helpRepl'  = [helpRepl  EXCEPT ![target] = storagePtr]
    /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, writerVars, ptrVars,
                   genVars, rCandidate>>

\* ===================================================================================
\* Reader Drop Guard (same as base)
\* ===================================================================================

ReaderDropGuard(t) ==
    /\ rPC[t] = "r_holding"
    /\ IF rHasDebt[t]
       THEN IF debtSlot[t][rSlot[t]] = rPtr[t]
            THEN /\ debtSlot' = [debtSlot EXCEPT ![t][rSlot[t]] = NullPtr]
                 /\ UNCHANGED rcVars
            ELSE /\ refCount' = [refCount EXCEPT ![rPtr[t]] = @ - 1]
                 /\ ptrAlive' = IF refCount'[rPtr[t]] = 0
                                THEN [ptrAlive EXCEPT ![rPtr[t]] = FALSE]
                                ELSE ptrAlive
                 /\ UNCHANGED debtVars
       ELSE /\ refCount' = [refCount EXCEPT ![rPtr[t]] = @ - 1]
            /\ ptrAlive' = IF refCount'[rPtr[t]] = 0
                           THEN [ptrAlive EXCEPT ![rPtr[t]] = FALSE]
                           ELSE ptrAlive
            /\ UNCHANGED debtVars
    /\ rPC'      = [rPC      EXCEPT ![t] = "r_idle"]
    /\ rPtr'     = [rPtr     EXCEPT ![t] = NullPtr]
    /\ rSlot'    = [rSlot    EXCEPT ![t] = 0]
    /\ rHasDebt' = [rHasDebt EXCEPT ![t] = FALSE]
    /\ rPath'    = [rPath    EXCEPT ![t] = "none"]
    /\ rPtrGen'  = [rPtrGen  EXCEPT ![t] = 0]
    /\ UNCHANGED <<coreVars, writerVars, ptrVars, genVars, helpVars>>

\* ===================================================================================
\* Writer Actions
\* ===================================================================================

WriterSwap(t) ==
    /\ wPC[t] = "w_idle"
    /\ rPC[t] = "r_idle"
    /\ \E newPtr \in Ptr :
        /\ newPtr /= storagePtr
        /\ ~ptrAlive[newPtr]
        /\ refCount' = [refCount EXCEPT ![newPtr] = 1]
        /\ ptrAlive' = [ptrAlive EXCEPT ![newPtr] = TRUE]
        /\ ptrGen' = [ptrGen EXCEPT ![newPtr] = @ + 1]
        /\ wOldPtr'    = [wOldPtr  EXCEPT ![t] = storagePtr]
        /\ storagePtr' = newPtr
    /\ wPC'      = [wPC      EXCEPT ![t] = "w_pay_init"]
    /\ wScanned' = [wScanned EXCEPT ![t] = {}]
    /\ UNCHANGED <<debtVars, readerVars, genVars, helpVars>>

\* ===================================================================================
\* CAS (Compare-And-Swap) Operation — hybrid.rs:253-280
\* ===================================================================================
\*
\* Thread holds a guard (r_holding) and atomically swaps storage if it
\* matches the guard's pointer. The thread then acts as BOTH reader AND
\* writer simultaneously: holding the old guard while scanning for debts.
\*
\* This violates ReaderWriterExclusive (which is relaxed for CAS mode).
\* The thread's OWN slot may contain the old pointer — pay_all will pay it.
\*
\* After pay_all, T::dec(old) is called (hybrid.rs:276), modeled by
\* CASWriterReturn which does dec WITHOUT dropping the guard.
\* The guard is dropped later via ReaderDropGuard.

CASSwap(t) ==
    /\ rPC[t] = "r_holding"
    /\ wPC[t] = "w_idle"
    /\ rPtr[t] = storagePtr                 \* hybrid.rs:262: old.as_ptr() == current
    /\ \E newPtr \in Ptr :
        /\ newPtr /= storagePtr
        /\ ~ptrAlive[newPtr]
        /\ refCount' = [refCount EXCEPT ![newPtr] = 1]
        /\ ptrAlive' = [ptrAlive EXCEPT ![newPtr] = TRUE]
        /\ ptrGen' = [ptrGen EXCEPT ![newPtr] = @ + 1]
        /\ wOldPtr'    = [wOldPtr  EXCEPT ![t] = storagePtr]
        /\ storagePtr' = newPtr
    /\ wPC'      = [wPC      EXCEPT ![t] = "w_pay_init"]
    /\ wScanned' = [wScanned EXCEPT ![t] = {}]
    \* NOTE: rPC stays "r_holding" — guard NOT dropped during CAS
    /\ UNCHANGED <<debtVars, rPC, rPtr, rSlot, rHasDebt, rPath, rPtrGen,
                   genVars, helpVars>>

\* CAS Writer Return: T::dec(old_ptr) + return guard
\*   hybrid.rs:276 — T::dec(old.as_ptr())
\*   hybrid.rs:277 — return old (guard stays in r_holding)
\*
\* Unlike normal WriterReturn which frees the pointer if refcount hits 0,
\* CAS return keeps the guard alive. The guard's ManuallyDrop::drop
\* (in ReaderDropGuard) handles the final decrement.
CASWriterReturn(t) ==
    /\ wPC[t] = "w_returning"
    /\ rPC[t] = "r_holding"                 \* CAS mode: guard still held
    /\ rPtr[t] = wOldPtr[t]                 \* Guard points to same old ptr
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]
    \* Don't free yet — guard still holds it
    /\ ptrAlive' = IF refCount'[wOldPtr[t]] = 0
                   THEN [ptrAlive EXCEPT ![wOldPtr[t]] = FALSE]
                   ELSE ptrAlive
    /\ wPC'     = [wPC     EXCEPT ![t] = "w_idle"]
    /\ wOldPtr' = [wOldPtr EXCEPT ![t] = NullPtr]
    /\ UNCHANGED <<coreVars, debtVars, readerVars, wScanned, ptrVars, genVars, helpVars>>

WriterPayInit(t) ==
    /\ wPC[t] = "w_pay_init"
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_scanning"]
    /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, wOldPtr, wScanned,
                   ptrVars, genVars, helpVars>>

WriterScanSlot(t) ==
    /\ wPC[t] = "w_scanning"
    /\ \E target \in Thread, slot \in Slot :
        /\ <<target, slot>> \notin wScanned[t]
        /\ \/ IF debtSlot[target][slot] = wOldPtr[t]
              THEN /\ debtSlot' = [debtSlot EXCEPT ![target][slot] = NullPtr]
                   /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
              ELSE /\ UNCHANGED <<debtSlot, refCount>>
           \/ \* ORDERING GAP: miss the debt
              /\ UNCHANGED <<debtSlot, refCount>>
        /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {<<target, slot>>}]
    /\ UNCHANGED <<coreVars, ptrAlive, readerVars, wPC, wOldPtr, ptrVars, genVars, helpVars>>

WriterPayDone(t) ==
    /\ wPC[t] = "w_scanning"
    /\ wScanned[t] = AllDebtPositions
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_returning"]
    /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, wOldPtr, wScanned,
                   ptrVars, genVars, helpVars>>

WriterReturn(t) ==
    /\ wPC[t] = "w_returning"
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]
    /\ ptrAlive' = IF refCount'[wOldPtr[t]] = 0
                   THEN [ptrAlive EXCEPT ![wOldPtr[t]] = FALSE]
                   ELSE ptrAlive
    /\ wPC'     = [wPC     EXCEPT ![t] = "w_idle"]
    /\ wOldPtr' = [wOldPtr EXCEPT ![t] = NullPtr]
    /\ UNCHANGED <<coreVars, debtVars, readerVars, wScanned, ptrVars, genVars, helpVars>>

\* ===================================================================================
\* Family 3: Cooldown (same as base)
\* ===================================================================================

WriterReserveNode(t, target) ==
    /\ wPC[t] = "w_scanning"
    /\ activeWriters' = [activeWriters EXCEPT ![target] = @ + 1]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, nodeState, helpVars>>

WriterReleaseNode(t, target) ==
    /\ wPC[t] \in {"w_scanning", "w_returning", "w_idle"}
    /\ activeWriters[target] > 0
    /\ activeWriters' = [activeWriters EXCEPT ![target] = @ - 1]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, nodeState, helpVars>>

CheckCooldown(target) ==
    /\ nodeState[target] = NODE_COOLDOWN
    /\ activeWriters[target] = 0
    /\ nodeState' = [nodeState EXCEPT ![target] = NODE_UNUSED]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, activeWriters, helpVars>>

ClaimNode(t) ==
    /\ nodeState[t] = NODE_UNUSED
    /\ nodeState' = [nodeState EXCEPT ![t] = NODE_USED]
    /\ gen' = [gen EXCEPT ![t] = 0]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   activeWriters, helpVars>>

\* ===================================================================================
\* Next-State Relation
\* ===================================================================================

Next ==
    \/ \E t \in Thread :
        \* --- Reader fast path ---
        \/ ReaderAcquireFast(t)
        \/ ReaderConfirmFast(t)
        \/ ReaderResolveFast(t)
        \* --- Reader fallback (NON-ATOMIC: 4 steps) ---
        \/ ReaderFallbackReserve(t)
        \/ ReaderFallbackLoad(t)
        \/ ReaderFallbackStoreSlot(t)
        \/ ReaderFallbackConfirm(t)
        \* --- Reader drop ---
        \/ ReaderDropGuard(t)
        \* --- Writer ---
        \/ WriterSwap(t)
        \/ CASSwap(t)
        \/ WriterPayInit(t)
        \/ WriterScanSlot(t)
        \/ WriterPayDone(t)
        \/ WriterReturn(t)
        \/ CASWriterReturn(t)
        \* --- Writer help (NEW) ---
        \/ \E target \in Thread :
            \/ WriterHelpReader(t, target)
            \/ WriterReserveNode(t, target)
            \/ WriterReleaseNode(t, target)
        \* --- Cooldown ---
        \/ ClaimNode(t)
    \/ \E target \in Thread :
        CheckCooldown(target)

Spec == Init /\ [][Next]_vars

\* ===================================================================================
\* Type Invariant
\* ===================================================================================

TypeOK ==
    /\ storagePtr \in Ptr
    /\ debtSlot \in [Thread -> [Slot -> AllPtrs]]
    /\ refCount \in [Ptr -> Nat]
    /\ ptrAlive \in [Ptr -> BOOLEAN]
    /\ rPC \in [Thread -> {"r_idle", "r_fast_confirm", "r_fast_resolve",
                           "r_holding",
                           "r_fallback_reserve", "r_fallback_loaded",
                           "r_fallback_stored"}]
    /\ rPtr \in [Thread -> AllPtrs]
    /\ rSlot \in [Thread -> Slot \cup {0}]
    /\ rHasDebt \in [Thread -> BOOLEAN]
    /\ rPath \in [Thread -> {"none", "fast", "fallback"}]
    /\ rPtrGen \in [Thread -> Nat]
    /\ wPC \in [Thread -> {"w_idle", "w_pay_init", "w_scanning", "w_returning"}]
    /\ wOldPtr \in [Thread -> AllPtrs]
    /\ wScanned \in [Thread -> SUBSET AllDebtPositions]
    /\ ptrGen \in [Ptr -> Nat]
    /\ gen \in [Thread -> 0..GEN_MAX]
    /\ nodeState \in [Thread -> {NODE_USED, NODE_COOLDOWN, NODE_UNUSED}]
    /\ activeWriters \in [Thread -> Nat]
    /\ helpState \in [Thread -> {"idle", "reserving", "helped"}]
    /\ helpRepl \in [Thread -> AllPtrs]
    /\ rCandidate \in [Thread -> AllPtrs]

\* ===================================================================================
\* Safety Invariants
\* ===================================================================================

NoUseAfterFree ==
    \A t \in Thread, s \in Slot :
        debtSlot[t][s] /= NullPtr => ptrAlive[debtSlot[t][s]]

ReaderHoldsAlivePtr ==
    \A t \in Thread :
        rPC[t] = "r_holding" => ptrAlive[rPtr[t]]

RefCountNonNeg ==
    \A p \in Ptr : refCount[p] >= 0

\* ===================================================================================
\* Extension Invariants
\* ===================================================================================

WriterPaysAllDebts ==
    \A t \in Thread :
        (wPC[t] = "w_returning" /\ wOldPtr[t] /= NullPtr) =>
            DebtCount(wOldPtr[t]) = 0

NoABAViolation ==
    \A t \in Thread :
        (rPC[t] = "r_holding" /\ rPtr[t] /= NullPtr /\ rPtr[t] \in Ptr) =>
            rPtrGen[t] = ptrGen[rPtr[t]]

CooldownBlocksReaders ==
    \A t \in Thread :
        nodeState[t] /= NODE_USED =>
            rPC[t] \in {"r_idle", "r_holding"}

\* NEW: Replacement pointer must be alive when offered
HelpReplacementAlive ==
    \A t \in Thread :
        helpState[t] = "helped" => ptrAlive[helpRepl[t]]

\* NEW: Candidate must be a valid (ever-allocated) pointer in fallback
FallbackCandidateValid ==
    \A t \in Thread :
        rPC[t] \in {"r_fallback_loaded", "r_fallback_stored"} =>
            rCandidate[t] \in EverAllocated

\* ===================================================================================
\* Structural Invariants
\* ===================================================================================

StoragePtrAlive == ptrAlive[storagePtr]

DeadRefCountZero ==
    \A p \in Ptr : ~ptrAlive[p] => refCount[p] = 0

ValidReaderSlot ==
    \A t \in Thread :
        (rPC[t] = "r_holding" /\ rHasDebt[t]) => rSlot[t] \in Slot

ValidWriterOldPtr ==
    \A t \in Thread :
        wPC[t] /= "w_idle" => wOldPtr[t] \in Ptr

\* Relaxed for CAS: a thread can be r_holding + writing simultaneously
ReaderWriterExclusive ==
    \A t \in Thread :
        wPC[t] /= "w_idle" => rPC[t] \in {"r_idle", "r_holding"}

====
