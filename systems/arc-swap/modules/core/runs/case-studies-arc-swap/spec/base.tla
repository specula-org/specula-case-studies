---- MODULE base ----
\* ===================================================================================
\* TLA+ Specification: arc-swap Debt-Based Reader Tracking
\* ===================================================================================
\*
\* Models the debt-based hazard pointer protocol used by arc-swap for lock-free
\* atomic pointer swap with lock-free reads.
\*
\* Bug Family 1: Cross-Variable SeqCst Ordering Gaps (CRITICAL)
\*   Open bugs: #198 (UAF in fallback), #200 (AcqRel gap in Debt::pay)
\*   Mechanism: Writer's AcqRel scan misses reader's SeqCst debt publication;
\*   fallback Acquire load reads stale pointer.
\*
\* Bug Family 2: ABA / Pointer Reuse Races (HIGH)
\*   Historical: e4fbadf, 00225f5, 63fa111, 7fcaa11
\*   Mechanism: Freed address reused by allocator causes false comparisons.
\*
\* Bug Family 3: Generation Counter Wraparound (MEDIUM)
\*   Historical: 343d1f5
\*   Mechanism: Helping generation wraps → cooldown state machine.
\*
\* Source: github.com/vorner/arc-swap (src/)

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ===================================================================================
\* Constants
\* ===================================================================================

CONSTANTS
    Thread,          \* Set of threads (can act as reader or writer)
    Ptr,             \* Set of abstract pointer addresses
    NumFastSlots,    \* Fast debt slots per thread (real: 8; MC: 1-2)
    InitPtr,         \* Initial pointer stored in ArcSwap
    NullPtr,         \* Sentinel for empty debt slot (real: 0b11, debt/mod.rs:39)
    GEN_MAX          \* Max generation counter before wraparound (Family 3)

ASSUME InitPtr \in Ptr
ASSUME NullPtr \notin Ptr
ASSUME NumFastSlots >= 1
ASSUME GEN_MAX >= 4

\* Derived sets
FastSlot    == 1..NumFastSlots
HelpSlotIdx == NumFastSlots + 1
Slot        == 1..(NumFastSlots + 1)   \* Fast (1..N) + helping (N+1)
AllPtrs     == Ptr \cup {NullPtr}

\* Node lifecycle states (list.rs:45-47)
NODE_USED     == "USED"
NODE_COOLDOWN == "COOLDOWN"
NODE_UNUSED   == "UNUSED"

\* ===================================================================================
\* Variables
\* ===================================================================================

VARIABLES
    \* --- Core protocol state ---
    storagePtr,      \* Ptr: current pointer in ArcSwap (lib.rs:318)

    \* --- Debt slots (Family 1) ---
    debtSlot,        \* [Thread -> [Slot -> AllPtrs]]
                     \* fast.rs:36 (fast slots) + helping.rs:151 (helping slot)

    \* --- Reference counting (Families 1, 2) ---
    refCount,        \* [Ptr -> Nat]: Arc strong reference count
    ptrAlive,        \* [Ptr -> BOOLEAN]: TRUE = pointer not yet freed

    \* --- Reader protocol state ---
    rPC,             \* [Thread -> reader program counter]
    rPtr,            \* [Thread -> AllPtrs]: pointer loaded from storage
    rSlot,           \* [Thread -> Slot \cup {0}]: slot holding reader's debt
    rHasDebt,        \* [Thread -> BOOLEAN]: whether reader holds a debt slot
    rPath,           \* [Thread -> {"none","fast","fallback"}]: load path taken

    \* --- Writer protocol state ---
    wPC,             \* [Thread -> writer program counter]
    wOldPtr,         \* [Thread -> AllPtrs]: old pointer being retired
    wScanned,        \* [Thread -> SUBSET (Thread \X Slot)]: scanned positions

    \* --- Pointer generation (Family 2: ABA detection) ---
    ptrGen,          \* [Ptr -> Nat]: allocation generation per address
    rPtrGen,         \* [Thread -> Nat]: generation captured at reader load time

    \* --- Generation counter and cooldown (Family 3) ---
    gen,             \* [Thread -> 0..GEN_MAX]: helping generation counter
    nodeState,       \* [Thread -> NODE_*]: node lifecycle state
    activeWriters    \* [Thread -> Nat]: writers touching this node

\* Variable groups for UNCHANGED
coreVars   == <<storagePtr>>
debtVars   == <<debtSlot>>
rcVars     == <<refCount, ptrAlive>>
readerVars == <<rPC, rPtr, rSlot, rHasDebt, rPath, rPtrGen>>
writerVars == <<wPC, wOldPtr, wScanned>>
genVars    == <<gen, nodeState, activeWriters>>
ptrVars    == <<ptrGen>>

vars == <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars, genVars>>

\* ===================================================================================
\* Helpers
\* ===================================================================================

\* All (thread, slot) positions for debt scanning
AllDebtPositions == Thread \X Slot

\* Count debt slots referencing a given pointer
DebtCount(ptr) ==
    Cardinality({<<t, s>> \in AllDebtPositions : debtSlot[t][s] = ptr})

\* Pointers that were ever allocated (have generation > 0)
\* Includes freed pointers — used for stale read modeling (Family 1)
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

\* ===================================================================================
\* Reader Actions: Fast Path (hybrid.rs:42-67)
\* ===================================================================================

\* Step 1: Load storage (Relaxed) + acquire fast debt slot (SeqCst swap)
\*   hybrid.rs:44  — storage.load(Relaxed)
\*   fast.rs:54    — slot.0.load(Relaxed) check for NONE
\*   fast.rs:58    — slot.0.swap(ptr, SeqCst)
ReaderAcquireFast(t) ==
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"          \* Cannot read while writing on same thread
    /\ nodeState[t] = NODE_USED                                  \* list.rs:271
    /\ \E s \in FastSlot :
        /\ debtSlot[t][s] = NullPtr                              \* fast.rs:54
        /\ debtSlot' = [debtSlot EXCEPT ![t][s] = storagePtr]   \* fast.rs:58 SeqCst
        /\ rSlot' = [rSlot EXCEPT ![t] = s]
    /\ rPtr'    = [rPtr    EXCEPT ![t] = storagePtr]             \* hybrid.rs:44 Relaxed
    /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[storagePtr]]    \* Family 2: capture gen
    /\ rPC'     = [rPC     EXCEPT ![t] = "r_fast_confirm"]
    /\ rPath'   = [rPath   EXCEPT ![t] = "fast"]
    /\ UNCHANGED <<coreVars, rcVars, rHasDebt, writerVars, ptrVars, genVars>>

\* Step 2: Confirm by re-reading storage (SeqCst)
\*   hybrid.rs:51  — storage.load(SeqCst)
\*   hybrid.rs:52  — if ptr == confirm
\*
\* Note: comparison is address-only (no generation check).
\* This is faithful to the code — ABA is detected by the invariant, not here.
ReaderConfirmFast(t) ==
    /\ rPC[t] = "r_fast_confirm"
    /\ IF rPtr[t] = storagePtr
       \* hybrid.rs:52-57: ptr == confirm → debt confirmed
       THEN /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = TRUE]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rPath,
                           rPtrGen, writerVars, ptrVars, genVars>>
       \* hybrid.rs:58-66: ptr != confirm → mismatch, need to resolve
       ELSE /\ rPC' = [rPC EXCEPT ![t] = "r_fast_resolve"]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rHasDebt,
                           rPath, rPtrGen, writerVars, ptrVars, genVars>>

\* Step 3: Resolve fast path mismatch
\*   hybrid.rs:58  — debt.pay::<T>(ptr) — CAS slot from ptr to NONE
\*   debt/mod.rs:65-78  — Debt::pay: CAS with AcqRel/Acquire
ReaderResolveFast(t) ==
    /\ rPC[t] = "r_fast_resolve"
    /\ IF debtSlot[t][rSlot[t]] = rPtr[t]
       \* hybrid.rs:58-61: CAS succeeds — paid own debt
       \* attempt() returns None → will retry or fallback
       THEN /\ debtSlot' = [debtSlot EXCEPT ![t][rSlot[t]] = NullPtr]
            /\ rPC'   = [rPC   EXCEPT ![t] = "r_idle"]
            /\ rSlot' = [rSlot EXCEPT ![t] = 0]
            /\ rPath' = [rPath EXCEPT ![t] = "none"]
            /\ UNCHANGED <<coreVars, rcVars, rPtr, rHasDebt, rPtrGen,
                           writerVars, ptrVars, genVars>>
       \* hybrid.rs:62-66: CAS fails — writer already paid our debt
       \* Writer did T::inc (refCount++) for us; we hold ptr without debt
       ELSE /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
            /\ rHasDebt' = [rHasDebt EXCEPT ![t] = FALSE]
            /\ UNCHANGED <<coreVars, debtVars, rcVars, rPtr, rSlot, rPath,
                           rPtrGen, writerVars, ptrVars, genVars>>

\* ===================================================================================
\* Reader Actions: Fallback Path (hybrid.rs:70-97)
\* ===================================================================================

\* Fallback: Load storage (Acquire) + acquire helping debt slot
\*   hybrid.rs:73   — node.new_helping(storage_addr)
\*   helping.rs:193  — gen wrapping_add(4)
\*   helping.rs:203  — active_addr.store(ptr, SeqCst)
\*   helping.rs:209  — control.swap(gen, SeqCst)
\*   hybrid.rs:77   — storage.load(Acquire)      ← ORDERING GAP (Family 1)
\*   helping.rs:312  — slot.0.swap(ptr, SeqCst)
\*   helping.rs:317  — control.swap(IDLE, SeqCst)
\*
\* KEY FAMILY 1 MECHANISM (Bug #198):
\* storage.load(Acquire) does NOT participate in the SeqCst total order.
\* The reader may load a stale pointer that was in storage before the most
\* recent writer swap. This stale pointer may have been freed.
\*
\* We model this by allowing the load to return any ever-allocated pointer,
\* including freed ones. This is an over-approximation of the real gap.
ReaderFallbackLoad(t) ==
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"          \* Cannot read while writing on same thread
    /\ nodeState[t] = NODE_USED                                  \* list.rs:280
    \* All fast slots full — need fallback (hybrid.rs:196)
    /\ \A s \in FastSlot : debtSlot[t][s] /= NullPtr
    /\ \E p \in Ptr :
        \* Load storage — may read stale due to Acquire ordering gap
        /\ \/ p = storagePtr                                     \* Normal: current
           \/ p \in EverAllocated                                \* Stale: ordering gap
        \* Write debt to helping slot (helping.rs:312)
        /\ debtSlot' = [debtSlot EXCEPT ![t][HelpSlotIdx] = p]
        /\ rPtr'    = [rPtr    EXCEPT ![t] = p]
        /\ rPtrGen' = [rPtrGen EXCEPT ![t] = ptrGen[p]]
    /\ rSlot'    = [rSlot    EXCEPT ![t] = HelpSlotIdx]
    /\ rPC'      = [rPC      EXCEPT ![t] = "r_holding"]
    /\ rHasDebt' = [rHasDebt EXCEPT ![t] = TRUE]
    /\ rPath'    = [rPath    EXCEPT ![t] = "fallback"]
    \* Family 3: increment generation counter (helping.rs:193)
    /\ LET newGen == (gen[t] + 4) % (GEN_MAX + 1)
       IN /\ gen' = [gen EXCEPT ![t] = newGen]
          \* Generation wrapped → start cooldown (list.rs:282-286)
          /\ IF newGen = 0
             THEN nodeState' = [nodeState EXCEPT ![t] = NODE_COOLDOWN]
             ELSE UNCHANGED nodeState
    /\ UNCHANGED <<coreVars, rcVars, writerVars, ptrVars, activeWriters>>

\* ===================================================================================
\* Reader Drop Guard (hybrid.rs:105-126)
\* ===================================================================================

\* Reader drops the guard, releasing the pointer.
\*   hybrid.rs:108  — match self.debt.take()
\*   hybrid.rs:114  — Some(debt) branch
\*   hybrid.rs:116  — debt.pay::<T>(ptr)
\*   hybrid.rs:124  — ManuallyDrop::drop (= T::dec)
ReaderDropGuard(t) ==
    /\ rPC[t] = "r_holding"
    /\ IF rHasDebt[t]
       THEN \* hybrid.rs:114-121: Has debt — try to pay it
            IF debtSlot[t][rSlot[t]] = rPtr[t]
            \* hybrid.rs:116-117: pay succeeds — cleared own slot, return
            \* No refcount change: debt was the only protection
            THEN /\ debtSlot' = [debtSlot EXCEPT ![t][rSlot[t]] = NullPtr]
                 /\ UNCHANGED rcVars
            \* hybrid.rs:119-121: pay fails — writer already paid
            \* Fall through to drop the Arc (dec refcount)
            ELSE /\ refCount' = [refCount EXCEPT ![rPtr[t]] = @ - 1]
                 /\ ptrAlive' = IF refCount'[rPtr[t]] = 0
                                THEN [ptrAlive EXCEPT ![rPtr[t]] = FALSE]
                                ELSE ptrAlive
                 /\ UNCHANGED debtVars
       ELSE \* hybrid.rs:109-111,124: No debt — drop the Arc (dec refcount)
            /\ refCount' = [refCount EXCEPT ![rPtr[t]] = @ - 1]
            /\ ptrAlive' = IF refCount'[rPtr[t]] = 0
                           THEN [ptrAlive EXCEPT ![rPtr[t]] = FALSE]
                           ELSE ptrAlive
            /\ UNCHANGED debtVars
    \* Reset reader state
    /\ rPC'      = [rPC      EXCEPT ![t] = "r_idle"]
    /\ rPtr'     = [rPtr     EXCEPT ![t] = NullPtr]
    /\ rSlot'    = [rSlot    EXCEPT ![t] = 0]
    /\ rHasDebt' = [rHasDebt EXCEPT ![t] = FALSE]
    /\ rPath'    = [rPath    EXCEPT ![t] = "none"]
    /\ rPtrGen'  = [rPtrGen  EXCEPT ![t] = 0]
    /\ UNCHANGED <<coreVars, writerVars, ptrVars, genVars>>

\* ===================================================================================
\* Writer Actions (lib.rs:477-488, debt/mod.rs:82-115)
\* ===================================================================================

\* Writer Step 1: Allocate new pointer and swap storage
\*   lib.rs:478  — T::into_ptr(new) — convert Arc to raw (no refcount change)
\*   lib.rs:483  — self.ptr.swap(new, SeqCst)
WriterSwap(t) ==
    /\ wPC[t] = "w_idle"
    /\ rPC[t] = "r_idle"       \* Same thread cannot read and write simultaneously
    /\ \E newPtr \in Ptr :
        /\ newPtr /= storagePtr
        /\ ~ptrAlive[newPtr]   \* Must allocate a new (or freed) pointer
        \* Allocate: set alive, refCount = 1 (user's Arc)
        /\ refCount' = [refCount EXCEPT ![newPtr] = 1]
        /\ ptrAlive' = [ptrAlive EXCEPT ![newPtr] = TRUE]
        \* Family 2: increment generation on (re)allocation
        /\ ptrGen' = [ptrGen EXCEPT ![newPtr] = @ + 1]
        \* Swap storage (lib.rs:483 SeqCst)
        /\ wOldPtr'    = [wOldPtr  EXCEPT ![t] = storagePtr]
        /\ storagePtr' = newPtr
    /\ wPC'      = [wPC      EXCEPT ![t] = "w_pay_init"]
    /\ wScanned' = [wScanned EXCEPT ![t] = {}]
    /\ UNCHANGED <<debtVars, readerVars, genVars>>

\* Writer Step 2: Pre-pay refcount in pay_all
\*   debt/mod.rs:88  — val = T::from_ptr(ptr)   (takes ownership of 1 ref)
\*   debt/mod.rs:90  — T::inc(&val)              (creates extra ref for swap return)
WriterPayInit(t) ==
    /\ wPC[t] = "w_pay_init"
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]      \* debt/mod.rs:90
    /\ wPC' = [wPC EXCEPT ![t] = "w_scanning"]
    /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, wOldPtr, wScanned,
                   ptrVars, genVars>>

\* Writer Step 3: Scan one debt slot
\*   debt/mod.rs:98-109  — iterate all slots, CAS each matching slot
\*   debt/mod.rs:105     — slot.pay::<T>(ptr) — CAS with AcqRel
\*   debt/mod.rs:107     — T::inc(&val)       — pre-pay for next debt
\*
\* BUG FAMILY 1 ORDERING GAP:
\*   The scan CAS uses AcqRel (debt/mod.rs:77), NOT SeqCst.
\*   The writer may non-deterministically MISS a debt written by a reader
\*   with SeqCst BEFORE the writer's SeqCst swap.
\*   Modeled as a non-deterministic choice to skip a matching slot.
WriterScanSlot(t) ==
    /\ wPC[t] = "w_scanning"
    /\ \E target \in Thread, slot \in Slot :
        /\ <<target, slot>> \notin wScanned[t]
        /\ \/ \* NORMAL PATH: see actual slot value
              IF debtSlot[target][slot] = wOldPtr[t]
              \* debt/mod.rs:105: CAS slot from oldPtr to NONE — pay debt
              THEN /\ debtSlot' = [debtSlot EXCEPT ![target][slot] = NullPtr]
                   \* debt/mod.rs:107: T::inc — pre-pay refcount
                   /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ + 1]
              \* Slot doesn't match — skip
              ELSE /\ UNCHANGED <<debtSlot, refCount>>
           \/ \* FAMILY 1 ORDERING GAP: miss the debt entirely
              \* Writer's AcqRel CAS does not observe reader's SeqCst store
              /\ UNCHANGED <<debtSlot, refCount>>
        /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {<<target, slot>>}]
    /\ UNCHANGED <<coreVars, ptrAlive, readerVars, wPC, wOldPtr, ptrVars, genVars>>

\* Writer Step 4: Finish pay_all — val drops (dec refcount)
\*   debt/mod.rs:113-114  — implicit T::dec by dropping val
WriterPayDone(t) ==
    /\ wPC[t] = "w_scanning"
    /\ wScanned[t] = AllDebtPositions    \* All slots scanned
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]      \* debt/mod.rs:113
    /\ wPC' = [wPC EXCEPT ![t] = "w_returning"]
    /\ UNCHANGED <<coreVars, debtVars, ptrAlive, readerVars, wOldPtr, wScanned,
                   ptrVars, genVars>>

\* Writer Step 5: Return old pointer to caller (caller drops it)
\*   lib.rs:486   — T::from_ptr(old) creates Arc
\*   Caller drops — T::dec (refcount -1)
\*   If refcount reaches 0: pointer is freed
WriterReturn(t) ==
    /\ wPC[t] = "w_returning"
    /\ refCount' = [refCount EXCEPT ![wOldPtr[t]] = @ - 1]
    /\ ptrAlive' = IF refCount'[wOldPtr[t]] = 0
                   THEN [ptrAlive EXCEPT ![wOldPtr[t]] = FALSE]
                   ELSE ptrAlive
    /\ wPC'     = [wPC     EXCEPT ![t] = "w_idle"]
    /\ wOldPtr' = [wOldPtr EXCEPT ![t] = NullPtr]
    /\ UNCHANGED <<coreVars, debtVars, readerVars, wScanned, ptrVars, genVars>>

\* ===================================================================================
\* Family 3: Cooldown State Machine (list.rs:112-145)
\* ===================================================================================

\* Writer reserves a node before scanning its slots
\*   list.rs:142-144  — active_writers.fetch_add(1, Acquire)
WriterReserveNode(t, target) ==
    /\ wPC[t] = "w_scanning"
    /\ activeWriters' = [activeWriters EXCEPT ![target] = @ + 1]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, nodeState>>

\* Writer releases a node after scanning
\*   list.rs:56  — active_writers.fetch_sub(1, Release)
WriterReleaseNode(t, target) ==
    /\ wPC[t] \in {"w_scanning", "w_returning", "w_idle"}
    /\ activeWriters[target] > 0
    /\ activeWriters' = [activeWriters EXCEPT ![target] = @ - 1]
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, nodeState>>

\* Check if a cooldown node can transition to unused
\*   list.rs:123-138  — check_cooldown
CheckCooldown(target) ==
    /\ nodeState[target] = NODE_COOLDOWN                         \* list.rs:129
    /\ activeWriters[target] = 0                                 \* list.rs:133
    /\ nodeState' = [nodeState EXCEPT ![target] = NODE_UNUSED]   \* list.rs:134-136
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   gen, activeWriters>>

\* Thread claims an unused node
\*   list.rs:153-166  — CAS(NODE_UNUSED, NODE_USED, SeqCst)
ClaimNode(t) ==
    /\ nodeState[t] = NODE_UNUSED
    /\ nodeState' = [nodeState EXCEPT ![t] = NODE_USED]
    /\ gen' = [gen EXCEPT ![t] = 0]   \* Reset generation on claim
    /\ UNCHANGED <<coreVars, debtVars, rcVars, readerVars, writerVars, ptrVars,
                   activeWriters>>

\* ===================================================================================
\* Next-State Relation
\* ===================================================================================

Next ==
    \/ \E t \in Thread :
        \* --- Reader actions ---
        \/ ReaderAcquireFast(t)
        \/ ReaderConfirmFast(t)
        \/ ReaderResolveFast(t)
        \/ ReaderFallbackLoad(t)
        \/ ReaderDropGuard(t)
        \* --- Writer actions ---
        \/ WriterSwap(t)
        \/ WriterPayInit(t)
        \/ WriterScanSlot(t)
        \/ WriterPayDone(t)
        \/ WriterReturn(t)
        \* --- Family 3: cooldown ---
        \/ ClaimNode(t)
        \/ \E target \in Thread :
            \/ WriterReserveNode(t, target)
            \/ WriterReleaseNode(t, target)
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
                           "r_holding"}]
    /\ rPtr \in [Thread -> AllPtrs]
    /\ rSlot \in [Thread -> Slot \cup {0}]
    /\ rHasDebt \in [Thread -> BOOLEAN]
    /\ rPath \in [Thread -> {"none", "fast", "fallback"}]
    /\ rPtrGen \in [Thread -> Nat]
    /\ wPC \in [Thread -> {"w_idle", "w_pay_init", "w_scanning",
                           "w_returning"}]
    /\ wOldPtr \in [Thread -> AllPtrs]
    /\ wScanned \in [Thread -> SUBSET AllDebtPositions]
    /\ ptrGen \in [Ptr -> Nat]
    /\ gen \in [Thread -> 0..GEN_MAX]
    /\ nodeState \in [Thread -> {NODE_USED, NODE_COOLDOWN, NODE_UNUSED}]
    /\ activeWriters \in [Thread -> Nat]

\* ===================================================================================
\* Safety Invariants
\* ===================================================================================

\* CRITICAL (Family 1): No debt slot references a freed pointer.
\* Violation = use-after-free: reader holds dangling reference.
NoUseAfterFree ==
    \A t \in Thread, s \in Slot :
        debtSlot[t][s] /= NullPtr => ptrAlive[debtSlot[t][s]]

\* CRITICAL (Family 1): Reader in holding state has an alive pointer.
ReaderHoldsAlivePtr ==
    \A t \in Thread :
        rPC[t] = "r_holding" => ptrAlive[rPtr[t]]

\* CRITICAL (Families 1, 2): Reference count never goes negative.
RefCountNonNeg ==
    \A p \in Ptr : refCount[p] >= 0

\* ===================================================================================
\* Extension Invariants (Bug-Family Specific)
\* ===================================================================================

\* Family 1: Writer should pay ALL debts on old pointer before freeing.
\* Expected to be VIOLATED by the AcqRel ordering gap — the bug we hunt.
WriterPaysAllDebts ==
    \A t \in Thread :
        (wPC[t] \in {"w_returning"} /\ wOldPtr[t] /= NullPtr) =>
            DebtCount(wOldPtr[t]) = 0

\* Family 2: Reader's pointer generation matches current allocation.
\* Violation = ABA: reader holds pointer from a previous allocation.
NoABAViolation ==
    \A t \in Thread :
        (rPC[t] = "r_holding" /\ rPtr[t] /= NullPtr /\ rPtr[t] \in Ptr) =>
            rPtrGen[t] = ptrGen[rPtr[t]]

\* Family 3: Cooldown prevents ABA on generation wraparound.
\* No node transitions COOLDOWN→UNUSED while writers active.
CooldownSafe ==
    \A t \in Thread :
        (nodeState[t] = NODE_COOLDOWN /\ activeWriters[t] > 0) =>
            nodeState[t] = NODE_COOLDOWN  \* Stays in cooldown (tautology as state inv)

\* Family 3: Node in COOLDOWN is not used for new reader transactions.
CooldownBlocksReaders ==
    \A t \in Thread :
        nodeState[t] /= NODE_USED =>
            rPC[t] \in {"r_idle", "r_holding"}

\* ===================================================================================
\* Structural Invariants
\* ===================================================================================

\* Storage always points to an alive pointer
StoragePtrAlive == ptrAlive[storagePtr]

\* Dead pointer has zero refcount
DeadRefCountZero ==
    \A p \in Ptr : ~ptrAlive[p] => refCount[p] = 0

\* Reader has valid slot when holding with debt
ValidReaderSlot ==
    \A t \in Thread :
        (rPC[t] = "r_holding" /\ rHasDebt[t]) => rSlot[t] \in Slot

\* Writer has a valid old pointer when active
ValidWriterOldPtr ==
    \A t \in Thread :
        wPC[t] /= "w_idle" => wOldPtr[t] \in Ptr

\* A thread cannot be both reading and writing
ReaderWriterExclusive ==
    \A t \in Thread :
        wPC[t] /= "w_idle" => rPC[t] = "r_idle"

====
