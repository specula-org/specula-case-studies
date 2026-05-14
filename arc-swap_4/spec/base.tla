---- MODULE base ----
\* ===================================================================================
\* TLA+ Specification: arc-swap (vorner/arc-swap, v1.8.2 + post-1.8.2 d5dd00c)
\*                     Round 4 — caller-misuse + stale-snapshot + helping-split focus
\* ===================================================================================
\*
\* Sub-category: reader-writer separation (concurrent-analysis.md §5).  A single
\* AtomicPtr<T> holds the current pointer; readers acquire wait-free debt slots
\* (fast or fallback); writers swap and walk all slots to "pay" matching debts
\* (CAS-clear + T::inc).
\*
\* Bug families covered (from modeling-brief.md §2):
\*   F1 — Memory-Ordering Bridges Across Variables          (HIGH)
\*   F2 — Caller Misuse / Adversarial Client                (HIGH — explicit gap from prior round)
\*   F3 — Stale Snapshot in Writer's Debt-List Traversal    (HIGH — BUG-A shape from left-right)
\*   F4 — Generation Wraparound + Cooldown ABA Window       (HIGH)
\*   F5 — Action Granularity Audit: new_helping/confirm_helping split (MEDIUM, NEW)
\*
\* Round 4 emphasis (per task brief):
\*   * Family 2 (Caller Misuse) — Guard::from_inner fork, send across threads,
\*     hold across writer swap-and-drop sequence; explicit GuardClone action.
\*   * Family 3 (Stale Snapshot) — writer's pay_all walks all reader slots; if
\*     snapshot was taken before a new reader appeared, new reader can hold
\*     freed pointer.  Same shape as BUG-A in left-right system.
\*   * Family 5 (NEW) — when generation wraps in get_debt, control was already
\*     swapped to GEN_TAG and start_cooldown takes the localNode; the next
\*     `confirm_helping` panics on node.get().expect().  Modeled by splitting
\*     `ReaderFallbackControlSwap` into control-swap + (conditional) discard-node,
\*     and gating later actions on localNode != NoneGid.
\*
\* Source files (paths under artifact/arc-swap/src/):
\*   strategy/hybrid.rs   :42-103, :119-141, :145-175, :217-263  reader load/drop/CaS
\*   debt/mod.rs          :48-122                                 Debt::pay + pay_all
\*   debt/list.rs         :40-204, :218-343                       LIST_HEAD + Node + LocalNode
\*   debt/fast.rs         :38-66                                  fast slot allocation
\*   debt/helping.rs      :186-339                                helping / handover protocol
\*   lib.rs               :212-216, :338-349, :478-491, :509-516  Guard / Drop / swap / CaS
\*
\* Granularity: every observable atomic op is its own action.  Per concurrent-
\* analysis.md §5.1, action splitting is the interleaving adversary; do not
\* collapse load → check → CAS into one action.

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ===================================================================================
\* Constants
\* ===================================================================================

CONSTANTS
    Thread,               \* threads (each thread t may own at most one node;
                          \*   threads with no node have localNode[t] = NoneGid)
    Addr,                 \* allocator addresses (F1/F3: reusable across allocations)
    InitAddr,             \* address of the first stored Arc
    NumFastSlots,         \* fast slots per node (real: 8; MC: 1-2)
    MaxHelpGen,           \* helping-generation bound; wrap at MaxHelpGen+1 triggers
                          \*   cooldown (Family 4 — helping.rs:191-217)
    MaxGuardsPerThread,   \* bound on per-thread in-flight Guards (Family 2)
    NullPtr,              \* sentinel for empty debt slot (debt/mod.rs:39 NONE)
    NoneGid,              \* sentinel "no guard / no node"
    NoneSite              \* sentinel "no relaxation site picked"

\* Named sites whose Ordering label can be downgraded by PickRelaxSite (Family 1).
\* Each site corresponds to one atomic op in the source.  Adversary downgrades
\* exactly one site per execution — see modeling-brief.md §2 Family 1.
\*
\* Sites with spec-level relaxation effect (used by IsSC).  The implementation
\* has additional SC-labelled sites (FastSlotSwap, WriterSwap, ControlSwap,
\* ConfirmHelping) that participate in the SC total order but whose individual
\* relaxation has no spec-observable effect in the current model: their effects
\* manifest only through the *paired* sites already enumerated.
RelaxSites == {
    "FastConfirmLoad",   \* hybrid.rs:52   storage.load(SeqCst)         (#76)
    "FallbackLoad",      \* hybrid.rs:83   storage.load(SeqCst)         (#198, #200)
    "DebtPaySuccess",    \* debt/mod.rs:77 CAS success leg              (#204)
    "DebtPayFailure",    \* debt/mod.rs:77 CAS failure leg              (#195)
    "ListHeadLoad"       \* debt/list.rs:102 LIST_HEAD.load(SeqCst)     (#164)
}

ASSUME InitAddr \in Addr
ASSUME NullPtr \notin Addr
ASSUME NoneGid \notin Addr
ASSUME NoneSite \notin RelaxSites
ASSUME NumFastSlots >= 1
ASSUME MaxHelpGen >= 4
ASSUME MaxGuardsPerThread >= 1

\* Derived
FastSlotIx  == 1..NumFastSlots
HelpSlotIx  == NumFastSlots + 1                  \* helping slot lives at end
SlotIx      == 1..(NumFastSlots + 1)
AllAddr     == Addr \cup {NullPtr}

\* Node lifecycle (debt/list.rs:45-47)
NODE_UNUSED   == "UNUSED"
NODE_USED     == "USED"
NODE_COOLDOWN == "COOLDOWN"

\* Helping-protocol control values (helping.rs:117-120)
CTRL_IDLE   == "IDLE"
CTRL_GEN    == "GEN"        \* tagged generation
CTRL_REPL   == "REPL"       \* replacement envelope tag

\* Guard kinds passed to compare_and_swap as `current` (Family 2, brief §4 ClientHarness).
\* lib.rs:509-516 + as_raw.rs:60-72.
CAS_KIND_ARC      == "Arc"        \* &Arc current (refcounted, alive by construction)
CAS_KIND_GUARD    == "Guard"      \* &Guard current (debt-protected, alive)
CAS_KIND_RAWFRESH == "RawFresh"   \* *const T equal to current live storage — no protection
CAS_KIND_RAWSTALE == "RawStale"   \* *const T from a freed allocation (documented hazard)

\* Reader phases — names match implementation control flow (hybrid.rs:42-103).
RPhases == {"r_idle",
            \* fast path — hybrid.rs:42-72
            "r_fast_after_load",       \* observed `ptr` from Relaxed load (line 44)
            "r_fast_after_slot",       \* fast slot acquired with SeqCst swap (fast.rs:58)
            "r_fast_after_confirm",    \* second SeqCst load done (line 52)
            \* fallback path — hybrid.rs:75-103, helping.rs:191-339, list.rs:288-319
            "r_fb_after_active_addr",  \* active_addr.store(SeqCst) done (helping.rs:203)
            "r_fb_after_ctrl_gen",     \* control.swap(gen, SeqCst) done (helping.rs:210)
            "r_fb_after_discard",      \* (Family 5) start_cooldown + take done (list.rs:295-296)
            "r_fb_after_candidate",    \* storage.load(SeqCst) for candidate (hybrid.rs:83)
            "r_fb_after_slot",         \* slot.swap(ptr, SeqCst) done (helping.rs:316)
            \* drop path — hybrid.rs:119-141
            "r_drop_paying",
            \* compare_and_swap retry loop — hybrid.rs:237-262
            "cas_after_load",
            "cas_after_compare",
            "cas_after_exchange_ok"
           }

\* Writer phases — pay_all walks list, scans each node (debt/mod.rs:82-122)
WPhases == {"w_idle",
            "w_after_swap",            \* storage.swap done (lib.rs:485)
            "w_pay_init",              \* T::inc done (debt/mod.rs:91)
            "w_traverse_loaded",       \* LIST_HEAD load done (debt/list.rs:102)
            "w_node_reserved",         \* active_writers++ for current node (list.rs:148-152)
            "w_after_help",            \* per-node `local.help(node, ...)` done (debt/mod.rs:98)
            "w_pay_done",              \* val drops (debt/mod.rs:118)
            "w_returning"              \* old returned to caller, then T::dec
           }

\* ===================================================================================
\* Variables
\* ===================================================================================

VARIABLES
    \* --- Allocator (F3: ABA via address reuse) ---
    storageAddr,        \* Addr — current pointer in ArcSwap (lib.rs:322)
    storageGen,         \* Nat — generation tag of currently-stored allocation
    addrAlive,          \* [Addr -> BOOLEAN]  — TRUE if currently allocated
    addrGen,            \* [Addr -> Nat]      — generation of *current* allocation at this addr
    refCount,           \* [Addr -> Nat]      — current strong refcount

    \* --- Per-node state (debt/list.rs) ---
    nodeState,          \* [Thread -> NODE_*]  list.rs:45-47, list.rs:66
    nodeOwner,          \* [Thread -> Thread \cup {NoneGid}]  who currently owns node n
    activeWriters,      \* [Thread -> Nat]    list.rs:73 active_writers atomic
    inflightHelp,       \* [Thread -> SUBSET Thread]   (F4) writers currently holding a
                        \*                              NodeReservation against node n
    helpGen,            \* [Thread -> 0..MaxHelpGen]  current generation counter (helping.rs:193)

    \* --- Slots ---
    fastSlot,           \* [Thread -> [FastSlotIx -> AllAddr]]   fast.rs Slots
    helpSlot,           \* [Thread -> AllAddr]                   helping slot Debt
    helpControl,        \* [Thread -> CTRL_IDLE | CTRL_GEN | CTRL_REPL]
    helpControlGen,     \* [Thread -> Nat]   generation tag if CTRL_GEN
    helpActiveAddr,     \* [Thread -> Nat]   storage address being loaded (helping.rs:203)
    helpReplAddr,       \* [Thread -> AllAddr]  if CTRL_REPL, the addr in the envelope

    \* --- Per-thread node ownership (NEW for F5) ---
    localNode,          \* [Thread -> Thread \cup {NoneGid}]
                        \*   the node thread t holds in its self.node Cell.  Becomes
                        \*   NoneGid after self.node.take() (list.rs:296).
    pendingHelpingTx,   \* [Thread -> BOOLEAN]
                        \*   TRUE if reader has an in-flight helping transaction
                        \*   (control set to gen | GEN_TAG, slot not yet stored).
                        \*   Set TRUE in ReaderFallbackControlSwap regardless of
                        \*   wrapped-gen value; the implementation's `gen | GEN_TAG`
                        \*   is always non-zero because GEN_TAG is non-zero, so
                        \*   even gen=0 produces a non-IDLE control value.

    \* --- Reader thread state ---
    rPC,                \* [Thread -> RPhases]
    rPath,              \* [Thread -> "fast"|"fallback"|"none"|"cas"]
    rOpAddr,            \* [Thread -> AllAddr]   address observed at first load
    rConfirmAddr,       \* [Thread -> AllAddr]   address from confirm load
    rConfirmGen,        \* [Thread -> Nat]
    rGenTagged,         \* [Thread -> Nat]   generation tag the reader inserted into control
    rDebtNode,          \* [Thread -> Thread \cup {NoneGid}]   which node holds reader's debt
    rDebtSlot,          \* [Thread -> SlotIx \cup {0}]
    rGotEnvelope,       \* [Thread -> BOOLEAN]   confirm_helping returned Err
    rEnvelopeAddr,      \* [Thread -> AllAddr]   replacement addr the writer offered
    rWrapDiscard,       \* [Thread -> BOOLEAN]   (F5) generation wrapped, discard pending

    \* --- Writer thread state ---
    wPC,                \* [Thread -> WPhases]
    wOldAddr,           \* [Thread -> AllAddr]
    wOldGen,            \* [Thread -> Nat]
    wToVisit,           \* [Thread -> SUBSET Thread] snapshot of nodes at LIST_HEAD load
    wCurNode,           \* [Thread -> Thread \cup {NoneGid}] node currently reserved
    wScanned,           \* [Thread -> SUBSET (Thread \X SlotIx)] all <<n,s>> already scanned
    wScanRemaining,     \* [Thread -> SUBSET (Thread \X SlotIx)] still to do for current node
    wFreedOld,          \* [Thread -> BOOLEAN]   (F3) writer has reached w_returning AND
                        \*                       T::dec on `old` brought refcount to 0

    \* --- compare_and_swap state (per thread, on the cas loop — hybrid.rs:237-262) ---
    casKind,            \* [Thread -> CAS_KIND_*]  what kind of `current` the caller passed
    casCurAddr,         \* [Thread -> AllAddr]      current.as_raw()
    casCurGen,          \* [Thread -> Nat]          gen at the time the kind was decided
    casNewAddr,         \* [Thread -> AllAddr]      the new pointer being written
    casNewGen,          \* [Thread -> Nat]
    casOldAddr,         \* [Thread -> AllAddr]      from the inner load
    casOldGen,          \* [Thread -> Nat]

    \* --- Adversarial caller harness: guards (Family 2) ---
    \* Each Guard is a record.  Bound the total per-thread; ids are local to a thread.
    \* fields: addr, gen, viaNode, viaSlot, hasDebt
    guards,

    \* --- Family 1 relaxation adversary ---
    relaxSite,          \* RelaxSites \cup {NoneSite}; the one site downgraded for this run

    \* --- ArcSwap object lifecycle (Family 2 caller-precondition hazard) ---
    arcSwapDropped      \* BOOLEAN — caller dropped the ArcSwap object (lib.rs:338-349)

\* Variable groupings for UNCHANGED clauses
allocVars   == <<storageAddr, storageGen, addrAlive, addrGen, refCount>>
nodeVars    == <<nodeState, nodeOwner, activeWriters, inflightHelp, helpGen>>
slotVars    == <<fastSlot, helpSlot, helpControl, helpControlGen, helpActiveAddr, helpReplAddr>>
threadOwnVars == <<localNode, pendingHelpingTx>>
readerVars  == <<rPC, rPath, rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged,
                 rDebtNode, rDebtSlot, rGotEnvelope, rEnvelopeAddr, rWrapDiscard>>
writerVars  == <<wPC, wOldAddr, wOldGen, wToVisit, wCurNode, wScanned, wScanRemaining,
                 wFreedOld>>
casVars     == <<casKind, casCurAddr, casCurGen, casNewAddr, casNewGen,
                 casOldAddr, casOldGen>>
clientVars  == <<guards>>
mcVars      == <<relaxSite, arcSwapDropped>>

vars == <<allocVars, nodeVars, slotVars, threadOwnVars, readerVars, writerVars,
          casVars, clientVars, mcVars>>

\* ===================================================================================
\* Helpers
\* ===================================================================================

AllSlotPositions == Thread \X SlotIx

\* Read the contents of any slot at <<n,s>>.  Helping slot lives at HelpSlotIx.
SlotValue(n, s) ==
    IF s = HelpSlotIx THEN helpSlot[n] ELSE fastSlot[n][s]

\* Set of slots <<n,s>> currently holding addr a.
SlotsHolding(a) ==
    {<<n, s>> \in AllSlotPositions : SlotValue(n, s) = a}

\* Family 1 — site is at SC unless adversary downgraded it.  Returns FALSE iff
\* the relaxation adversary picked this site for this run.
IsSC(site) == relaxSite # site

\* "Stale" addresses readable when SC label is downgraded — Family 1
\* over-approximation per concurrent-analysis.md §5.5.  A relaxed load may
\* return any value the writer has ever stored, including freed ones.
EverAllocated == {a \in Addr : addrGen[a] > 0}

GuardIxs(t) == {i \in 1..MaxGuardsPerThread : guards[t][i].addr # NullPtr}

FreeGuardSlot(t) ==
    IF \E i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    THEN CHOOSE i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    ELSE 0

EmptyGuard == [addr |-> NullPtr, gen |-> 0,
               viaNode |-> NoneGid, viaSlot |-> 0, hasDebt |-> FALSE]

\* No guard anywhere references a freed address (F1/F2/F3 headline UAF check).
NoStaleGuard ==
    \A t \in Thread :
        \A i \in 1..MaxGuardsPerThread :
            guards[t][i].addr # NullPtr =>
                /\ addrAlive[guards[t][i].addr]
                /\ guards[t][i].gen = addrGen[guards[t][i].addr]

\* ===================================================================================
\* Init
\* ===================================================================================

Init ==
    \* Allocator: only InitAddr is alive, with refcount 1 (the stored Arc) + gen 1.
    /\ storageAddr = InitAddr
    /\ storageGen  = 1
    /\ addrAlive   = [a \in Addr |-> a = InitAddr]
    /\ addrGen     = [a \in Addr |-> IF a = InitAddr THEN 1 ELSE 0]
    /\ refCount    = [a \in Addr |-> IF a = InitAddr THEN 1 ELSE 0]

    \* Nodes: each thread t starts with node t already claimed (THREAD_HEAD lazy-init
    \* in list.rs:346-353 — modeled as having claimed at startup).
    /\ nodeState     = [t \in Thread |-> NODE_USED]
    /\ nodeOwner     = [t \in Thread |-> t]
    /\ activeWriters = [t \in Thread |-> 0]
    /\ inflightHelp  = [t \in Thread |-> {}]
    /\ helpGen       = [t \in Thread |-> 0]

    /\ fastSlot       = [t \in Thread |-> [s \in FastSlotIx |-> NullPtr]]
    /\ helpSlot       = [t \in Thread |-> NullPtr]
    /\ helpControl    = [t \in Thread |-> CTRL_IDLE]
    /\ helpControlGen = [t \in Thread |-> 0]
    /\ helpActiveAddr = [t \in Thread |-> 0]
    /\ helpReplAddr   = [t \in Thread |-> NullPtr]

    /\ localNode        = [t \in Thread |-> t]
    /\ pendingHelpingTx = [t \in Thread |-> FALSE]

    /\ rPC          = [t \in Thread |-> "r_idle"]
    /\ rPath        = [t \in Thread |-> "none"]
    /\ rOpAddr      = [t \in Thread |-> NullPtr]
    /\ rConfirmAddr = [t \in Thread |-> NullPtr]
    /\ rConfirmGen  = [t \in Thread |-> 0]
    /\ rGenTagged   = [t \in Thread |-> 0]
    /\ rDebtNode    = [t \in Thread |-> NoneGid]
    /\ rDebtSlot    = [t \in Thread |-> 0]
    /\ rGotEnvelope = [t \in Thread |-> FALSE]
    /\ rEnvelopeAddr= [t \in Thread |-> NullPtr]
    /\ rWrapDiscard = [t \in Thread |-> FALSE]

    /\ wPC            = [t \in Thread |-> "w_idle"]
    /\ wOldAddr       = [t \in Thread |-> NullPtr]
    /\ wOldGen        = [t \in Thread |-> 0]
    /\ wToVisit       = [t \in Thread |-> {}]
    /\ wCurNode       = [t \in Thread |-> NoneGid]
    /\ wScanned       = [t \in Thread |-> {}]
    /\ wScanRemaining = [t \in Thread |-> {}]
    /\ wFreedOld      = [t \in Thread |-> FALSE]

    /\ casKind     = [t \in Thread |-> CAS_KIND_ARC]
    /\ casCurAddr  = [t \in Thread |-> NullPtr]
    /\ casCurGen   = [t \in Thread |-> 0]
    /\ casNewAddr  = [t \in Thread |-> NullPtr]
    /\ casNewGen   = [t \in Thread |-> 0]
    /\ casOldAddr  = [t \in Thread |-> NullPtr]
    /\ casOldGen   = [t \in Thread |-> 0]

    /\ guards = [t \in Thread |-> [i \in 1..MaxGuardsPerThread |-> EmptyGuard]]

    /\ relaxSite      = NoneSite
    /\ arcSwapDropped = FALSE

\* ===================================================================================
\* Reader: Fast Path  (strategy/hybrid.rs:42-72)
\* ===================================================================================
\* Five actions, one per atomic op observable to other threads.

\* hybrid.rs:44 — let ptr = storage.load(Relaxed).
\* Modeled as observing the *current* storage value.  The Relaxed load is paired
\* with the SeqCst confirm at line 52.
ReaderFastLoad(t) ==
    /\ ~arcSwapDropped
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"
    /\ localNode[t] # NoneGid                  \* (F5) requires self.node.get() = Some
    /\ nodeState[localNode[t]] = NODE_USED     \* list.rs:281 (debug_assert)
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = storageAddr]
    /\ rPC'     = [rPC     EXCEPT ![t] = "r_fast_after_load"]
    /\ rPath'   = [rPath   EXCEPT ![t] = "fast"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:47 — node.new_fast(ptr) — fast.rs:43-66.
\* fast.rs:54 Relaxed load + fast.rs:58 SeqCst swap.  Pick a free slot.
ReaderFastSlotAcquire(t) ==
    /\ rPC[t] = "r_fast_after_load"
    /\ localNode[t] # NoneGid
    /\ \E s \in FastSlotIx :
        /\ fastSlot[localNode[t]][s] = NullPtr        \* fast.rs:54 NONE check
        /\ fastSlot' = [fastSlot EXCEPT ![localNode[t]][s] = rOpAddr[t]]
        /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = s]
        /\ rDebtNode' = [rDebtNode EXCEPT ![t] = localNode[t]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fast_after_slot"]
    /\ UNCHANGED <<allocVars, nodeVars, helpSlot, helpControl, helpControlGen,
                   helpActiveAddr, helpReplAddr, threadOwnVars,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rPath,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:52 — let confirm = storage.load(SeqCst).  Family 1 site "FastConfirmLoad".
\* When SC: must observe a value consistent with writer's SeqCst storage.swap.
\* When relaxed (adversary downgraded): may return any prior / freed pointer.
ReaderFastConfirmLoad(t) ==
    /\ rPC[t] = "r_fast_after_slot"
    /\ \E observed \in (IF IsSC("FastConfirmLoad")
                        THEN {storageAddr}
                        ELSE EverAllocated \cup {storageAddr}) :
        LET observedGen ==
              IF observed = storageAddr THEN storageGen ELSE addrGen[observed]
        IN  /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = observed]
            /\ rConfirmGen'  = [rConfirmGen  EXCEPT ![t] = observedGen]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fast_after_confirm"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   rOpAddr, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard, rPath,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:54-60 — branch on ptr == confirm.
\* Success path: create guard from `confirm` (uses confirm, NOT ptr — F3 fix
\* 63fa111: address may be reused with different provenance).
ReaderFastBranchHit(t) ==
    /\ rPC[t] = "r_fast_after_confirm"
    /\ rOpAddr[t] = rConfirmAddr[t]
    /\ FreeGuardSlot(t) # 0
    /\ LET gi == FreeGuardSlot(t) IN
        guards' = [guards EXCEPT ![t][gi] =
                    [addr |-> rConfirmAddr[t], gen |-> rConfirmGen[t],
                     viaNode |-> rDebtNode[t], viaSlot |-> rDebtSlot[t],
                     hasDebt |-> TRUE]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmGen' = [rConfirmGen EXCEPT ![t] = 0]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = NoneGid]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = 0]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   rGenTagged, rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, casVars, mcVars>>

\* hybrid.rs:61-71 — debt.pay::<T>(ptr).  CAS slot from `ptr` to NONE.
\*   debt/mod.rs:65-79 — Debt::pay (success leg AcqRel; failure leg Acquire).
\* Family 1 sites: "DebtPaySuccess" / "DebtPayFailure".
ReaderFastResolve(t) ==
    /\ rPC[t] = "r_fast_after_confirm"
    /\ rOpAddr[t] # rConfirmAddr[t]
    /\ \/ \* CAS succeeds — we paid our own debt (debt/mod.rs:77 success leg)
          /\ fastSlot[rDebtNode[t]][rDebtSlot[t]] = rOpAddr[t]
          /\ fastSlot' = [fastSlot EXCEPT ![rDebtNode[t]][rDebtSlot[t]] = NullPtr]
          /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
          /\ rPath' = [rPath EXCEPT ![t] = "none"]
          /\ UNCHANGED <<guards, refCount>>
       \/ \* CAS fails — writer paid for us (debt/mod.rs:77 failure Acquire leg).
          \* Writer's `slot.pay` did `T::inc` (debt/mod.rs:111) — caller owns a ref.
          /\ fastSlot[rDebtNode[t]][rDebtSlot[t]] # rOpAddr[t]
          /\ FreeGuardSlot(t) # 0
          /\ LET gi == FreeGuardSlot(t) IN
              guards' = [guards EXCEPT ![t][gi] =
                          [addr |-> rOpAddr[t], gen |-> addrGen[rOpAddr[t]],
                           viaNode |-> NoneGid, viaSlot |-> 0, hasDebt |-> FALSE]]
          /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
          /\ rPath' = [rPath EXCEPT ![t] = "none"]
          /\ UNCHANGED <<fastSlot, refCount>>
       \/ \* Family 1 relaxation: DebtPayFailure (Acquire → Relaxed, PR #195).
          \* Spurious failure: slot still holds wOldAddr but reader's CAS fails,
          \* AND the writer's T::inc on rOpAddr is not yet visible.
          /\ ~IsSC("DebtPayFailure")
          /\ fastSlot[rDebtNode[t]][rDebtSlot[t]] = rOpAddr[t]
          /\ FreeGuardSlot(t) # 0
          /\ LET gi == FreeGuardSlot(t) IN
              guards' = [guards EXCEPT ![t][gi] =
                          [addr |-> rOpAddr[t], gen |-> addrGen[rOpAddr[t]],
                           viaNode |-> NoneGid, viaSlot |-> 0, hasDebt |-> FALSE]]
          /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
          /\ rPath' = [rPath EXCEPT ![t] = "none"]
          /\ UNCHANGED <<fastSlot, refCount>>
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmGen' = [rConfirmGen EXCEPT ![t] = 0]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = NoneGid]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = 0]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   helpSlot, helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   threadOwnVars, rGenTagged, rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, casVars, mcVars>>

\* ===================================================================================
\* Reader: Fallback / Helping Path  (strategy/hybrid.rs:75-111 + helping.rs:191-339
\*                                    + list.rs:288-319)
\* ===================================================================================
\*
\* Family 5 split: the implementation does
\*   helping.get_debt → (gen, discard);    [helping.rs:191-217]
\*   if discard: node.start_cooldown(); self.node.take();  [list.rs:292-296]
\*   ...
\*   confirm_helping(...) requires self.node.get() = Some  [list.rs:312]
\*
\* We split this into:
\*   ReaderFallbackActiveAddr     -- helping.rs:203 active_addr.store
\*   ReaderFallbackControlSwap    -- helping.rs:210 control.swap; sets pendingHelpingTx
\*                                   and may set rWrapDiscard
\*   ReaderFallbackDiscardNode    -- list.rs:295-296 (only if rWrapDiscard)
\*                                   start_cooldown + self.node.take() ⇒ localNode := None
\*   ReaderFallbackCandidate      -- hybrid.rs:83 storage.load(SeqCst)
\*   ReaderFallbackSlotStore      -- helping.rs:316 slot.swap(ptr, SeqCst)
\*   ReaderFallbackConfirm{OK,Helped} -- helping.rs:322 control.swap(IDLE, SeqCst)
\*   ReaderFallbackResolveEnvelope-- hybrid.rs:98-110 cleanup if helped

\* helping.rs:203 — active_addr.store(ptr, SeqCst).
ReaderFallbackActiveAddr(t) ==
    /\ ~arcSwapDropped
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"
    /\ localNode[t] # NoneGid
    /\ nodeState[localNode[t]] = NODE_USED
    /\ helpSlot[localNode[t]] = NullPtr               \* helping slot must be free
    /\ helpControl[localNode[t]] = CTRL_IDLE
    /\ ~pendingHelpingTx[t]                           \* (F5) no pending tx
    /\ helpActiveAddr' = [helpActiveAddr EXCEPT ![localNode[t]] = 1]   \* abstract storage_addr
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_active_addr"]
    /\ rPath' = [rPath EXCEPT ![t] = "fallback"]
    /\ UNCHANGED <<allocVars, nodeState, nodeOwner, activeWriters, inflightHelp, helpGen,
                   fastSlot, helpSlot, helpControl, helpControlGen, helpReplAddr,
                   threadOwnVars,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, casVars, clientVars, mcVars>>

\* helping.rs:191-217 — gen wrapping_add(4) + control.swap(gen, SeqCst).
\* When the new gen wraps to 0 (post-mod), set rWrapDiscard=TRUE and pendingHelpingTx
\* but DO NOT yet take the node — that happens in ReaderFallbackDiscardNode.
\* This is the F5 split point.
ReaderFallbackControlSwap(t) ==
    /\ rPC[t] = "r_fb_after_active_addr"
    /\ localNode[t] # NoneGid
    /\ LET newGen == (helpGen[t] + 4) % (MaxHelpGen + 1)
           wrapped == newGen = 0
       IN  /\ helpGen' = [helpGen EXCEPT ![t] = newGen]
           /\ helpControl' = [helpControl EXCEPT ![localNode[t]] = CTRL_GEN]
           /\ helpControlGen' = [helpControlGen EXCEPT ![localNode[t]] = newGen]
           /\ rGenTagged' = [rGenTagged EXCEPT ![t] = newGen]
           /\ rWrapDiscard' = [rWrapDiscard EXCEPT ![t] = wrapped]
           \* (F5) Mark the in-flight helping transaction.  TRUE until cleared
           \* by ReaderFallbackConfirm{OK,Helped}.  Implementation's
           \* `gen | GEN_TAG` is always non-zero (GEN_TAG is non-zero) — even
           \* when gen wraps to 0, the tagged control value is non-IDLE.
           /\ pendingHelpingTx' = [pendingHelpingTx EXCEPT ![t] = TRUE]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_ctrl_gen"]
    /\ UNCHANGED <<allocVars, nodeState, nodeOwner, activeWriters, inflightHelp,
                   fastSlot, helpSlot, helpActiveAddr, helpReplAddr, localNode,
                   rOpAddr, rConfirmAddr, rConfirmGen, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rPath,
                   writerVars, casVars, clientVars, mcVars>>

\* (F5 NEW) list.rs:295-296 — start_cooldown + self.node.take().
\* Only fires when generation wrapped (rWrapDiscard).  Models the bug surface:
\* between this action and the next ReaderFallback* action, localNode[t] = NoneGid
\* but pendingHelpingTx[t] # 0 ⇒ NoDanglingTransaction is violated.
\* In the implementation, after this state the next thing is confirm_helping which
\* panics on self.node.get().expect(...).  We model the panic by enabling guards
\* on subsequent actions: ReaderFallbackCandidate and onwards require localNode # NoneGid.
\* Hence the bug surfaces as a *deadlock* in the model unless we add a recovery
\* path.  We add ReaderRecoverFromDiscardPanic to make the deadlock explicit.
ReaderFallbackDiscardNode(t) ==
    /\ rPC[t] = "r_fb_after_ctrl_gen"
    /\ rWrapDiscard[t]
    /\ localNode[t] # NoneGid                          \* still set at this point
    \* start_cooldown sets in_use to COOLDOWN and the dropping NodeReservation
    \* later decrements active_writers (list.rs:54-58, list.rs:115-120).  Net
    \* delta to active_writers is zero; we only model the in_use transition.
    /\ nodeState' = [nodeState EXCEPT ![localNode[t]] = NODE_COOLDOWN]
    /\ nodeOwner' = [nodeOwner EXCEPT ![localNode[t]] = NoneGid]
    \* self.node.take() (list.rs:296)
    /\ localNode' = [localNode EXCEPT ![t] = NoneGid]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_discard"]
    /\ UNCHANGED <<allocVars, activeWriters, inflightHelp, helpGen, slotVars,
                   pendingHelpingTx,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard, rPath,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:83 — let candidate = storage.load(SeqCst).  Family 1 site "FallbackLoad".
\* This is the load that, before commit d5dd00c, was Acquire and caused the #198 UAF.
\*
\* (F5) Fires from BOTH "r_fb_after_ctrl_gen" (no-wrap path) AND "r_fb_after_discard"
\* (post-discard path).  Note: the implementation runs `storage.load(SeqCst)`
\* regardless of discard (hybrid.rs:83 — between new_helping and confirm_helping).
\* The localNode access happens only in confirm_helping (next action), so this
\* action does not require localNode # NoneGid.
ReaderFallbackCandidate(t) ==
    /\ \/ /\ rPC[t] = "r_fb_after_ctrl_gen"
          /\ ~rWrapDiscard[t]                          \* no-wrap path
       \/ rPC[t] = "r_fb_after_discard"                \* post-discard path (will panic next)
    /\ \E observed \in (IF IsSC("FallbackLoad")
                        THEN {storageAddr}
                        ELSE EverAllocated \cup {storageAddr}) :
        LET oGen == IF observed = storageAddr THEN storageGen ELSE addrGen[observed]
        IN  /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = observed]
            /\ rConfirmGen'  = [rConfirmGen  EXCEPT ![t] = oGen]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_candidate"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   rOpAddr, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard, rPath,
                   writerVars, casVars, clientVars, mcVars>>

\* (F5) After a wrap-discard, ReaderFallbackSlotStore would call
\* `node.helping_slot()` via `self.node.get().expect(...)` and panic.  We model
\* the panic as a deadlock at rPC[t] = "r_fb_after_candidate" when localNode = NoneGid,
\* and rely on the NoDanglingTransaction invariant to catch the inconsistent state.
\* No explicit panic action is added — that would be a recovery the impl doesn't have.

\* helping.rs:316 — slot.swap(ptr, SeqCst).
ReaderFallbackSlotStore(t) ==
    /\ rPC[t] = "r_fb_after_candidate"
    /\ localNode[t] # NoneGid
    /\ helpSlot' = [helpSlot EXCEPT ![localNode[t]] = rConfirmAddr[t]]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = localNode[t]]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = HelpSlotIx]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_slot"]
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpControl, helpControlGen,
                   helpActiveAddr, helpReplAddr, threadOwnVars,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard, rPath,
                   writerVars, casVars, clientVars, mcVars>>

\* helping.rs:322 — control.swap(IDLE, SeqCst).
\* Two cases get separate actions: success (prev == gen) and helped (prev == REPL).

\* Success: control still held our generation tag — slot debt is confirmed.
ReaderFallbackConfirmOK(t) ==
    /\ rPC[t] = "r_fb_after_slot"
    /\ localNode[t] # NoneGid
    /\ helpControl[localNode[t]] = CTRL_GEN
    /\ helpControlGen[localNode[t]] = rGenTagged[t]
    /\ FreeGuardSlot(t) # 0
    /\ helpControl'    = [helpControl    EXCEPT ![localNode[t]] = CTRL_IDLE]
    /\ helpControlGen' = [helpControlGen EXCEPT ![localNode[t]] = 0]
    /\ pendingHelpingTx' = [pendingHelpingTx EXCEPT ![t] = FALSE]   \* (F5) tx complete
    /\ LET gi == FreeGuardSlot(t) IN
        guards' = [guards EXCEPT ![t][gi] =
                    [addr |-> rConfirmAddr[t], gen |-> rConfirmGen[t],
                     viaNode |-> localNode[t], viaSlot |-> HelpSlotIx,
                     hasDebt |-> TRUE]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmGen' = [rConfirmGen EXCEPT ![t] = 0]
    /\ rGenTagged' = [rGenTagged EXCEPT ![t] = 0]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = NoneGid]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = 0]
    /\ rGotEnvelope' = [rGotEnvelope EXCEPT ![t] = FALSE]
    /\ rEnvelopeAddr' = [rEnvelopeAddr EXCEPT ![t] = NullPtr]
    /\ rWrapDiscard' = [rWrapDiscard EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpSlot, helpActiveAddr,
                   helpReplAddr, localNode, writerVars, casVars, mcVars>>

\* Helped: writer beat reader to the slot, placed a replacement envelope
\* (helping.rs:328-336).  rGotEnvelope=TRUE for the next cleanup action.
ReaderFallbackConfirmHelped(t) ==
    /\ rPC[t] = "r_fb_after_slot"
    /\ localNode[t] # NoneGid
    /\ helpControl[localNode[t]] = CTRL_REPL
    /\ helpControl'    = [helpControl    EXCEPT ![localNode[t]] = CTRL_IDLE]
    /\ helpControlGen' = [helpControlGen EXCEPT ![localNode[t]] = 0]
    /\ rGotEnvelope'   = [rGotEnvelope   EXCEPT ![t] = TRUE]
    /\ rEnvelopeAddr'  = [rEnvelopeAddr  EXCEPT ![t] = helpReplAddr[localNode[t]]]
    /\ pendingHelpingTx' = [pendingHelpingTx EXCEPT ![t] = FALSE]   \* (F5) tx complete
    /\ rPC' = [rPC EXCEPT ![t] = "r_drop_paying"]
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpSlot, helpActiveAddr,
                   helpReplAddr, localNode, rPath, rOpAddr, rConfirmAddr,
                   rConfirmGen, rGenTagged, rDebtNode, rDebtSlot, rWrapDiscard,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:98-110 — when confirm_helping returned Err: pay back unused debt
\* on the candidate; if pay fails (writer paid first), T::dec.  Then create
\* a Guard for the replacement (no debt).
ReaderFallbackResolveEnvelope(t) ==
    /\ rPC[t] = "r_drop_paying"
    /\ rGotEnvelope[t]
    /\ FreeGuardSlot(t) # 0
    /\ \/ \* paid_back: helpSlot still held candidate; clear it
          /\ helpSlot[rDebtNode[t]] = rConfirmAddr[t]
          /\ helpSlot' = [helpSlot EXCEPT ![rDebtNode[t]] = NullPtr]
          /\ UNCHANGED refCount
       \/ \* writer paid first: dec the candidate's refcount (hybrid.rs:103)
          /\ helpSlot[rDebtNode[t]] # rConfirmAddr[t]
          /\ refCount' = [refCount EXCEPT ![rConfirmAddr[t]] = @ - 1]
          /\ UNCHANGED helpSlot
    /\ LET gi == FreeGuardSlot(t) IN
        guards' = [guards EXCEPT ![t][gi] =
                    [addr |-> rEnvelopeAddr[t],
                     gen  |-> addrGen[rEnvelopeAddr[t]],
                     viaNode |-> NoneGid, viaSlot |-> 0, hasDebt |-> FALSE]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = NullPtr]
    /\ rConfirmGen' = [rConfirmGen EXCEPT ![t] = 0]
    /\ rGenTagged' = [rGenTagged EXCEPT ![t] = 0]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = NoneGid]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = 0]
    /\ rGotEnvelope' = [rGotEnvelope EXCEPT ![t] = FALSE]
    /\ rEnvelopeAddr' = [rEnvelopeAddr EXCEPT ![t] = NullPtr]
    /\ rWrapDiscard' = [rWrapDiscard EXCEPT ![t] = FALSE]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, fastSlot,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   threadOwnVars, writerVars, casVars, mcVars>>

\* ===================================================================================
\* Guard / ClientHarness (Family 2 — modeling-brief.md §2 F2, §4 ClientHarness)
\* ===================================================================================

\* lib.rs:212 + hybrid.rs:145-175 — Guard::into_inner.
\* If the guard had a debt: T::inc + try Debt::pay; if pay fails T::dec.
\* The user now owns a fully-loaded T (no debt slot held).
GuardIntoInner(t) ==
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[t][gi].addr # NullPtr
        /\ guards[t][gi].hasDebt
        /\ LET g == guards[t][gi] IN
            \/ \* pay succeeds — slot freed; T::inc gives caller the bare Arc ref
               /\ SlotValue(g.viaNode, g.viaSlot) = g.addr
               /\ refCount' = [refCount EXCEPT ![g.addr] = @ + 1]
               /\ IF g.viaSlot = HelpSlotIx
                  THEN /\ helpSlot' = [helpSlot EXCEPT ![g.viaNode] = NullPtr]
                       /\ UNCHANGED fastSlot
                  ELSE /\ fastSlot' = [fastSlot EXCEPT ![g.viaNode][g.viaSlot] = NullPtr]
                       /\ UNCHANGED helpSlot
               /\ guards' = [guards EXCEPT ![t][gi] =
                               [addr |-> g.addr, gen |-> g.gen,
                                viaNode |-> NoneGid, viaSlot |-> 0,
                                hasDebt |-> FALSE]]
            \/ \* pay fails — writer already paid; T::inc + T::dec (hybrid.rs:163-165)
               /\ SlotValue(g.viaNode, g.viaSlot) # g.addr
               /\ guards' = [guards EXCEPT ![t][gi] =
                               [addr |-> g.addr, gen |-> g.gen,
                                viaNode |-> NoneGid, viaSlot |-> 0,
                                hasDebt |-> FALSE]]
               /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   threadOwnVars, readerVars, writerVars, casVars, mcVars>>

\* (F2 NEW) lib.rs:212 — Guard::from_inner combined with Arc::clone(&*g).
\*
\*    let g  = arcswap.load();             // hasDebt=TRUE
\*    let arc = Arc::clone(&*g);           // bumps refCount[g.addr]
\*    let g2 = Guard::from_inner(arc);     // wraps Arc as new no-debt guard
\*
\* This produces TWO coexisting guards on the same address — one debted, one not.
\* Round 3 lacked this action; round 4 adds it as the explicit fork primitive.
GuardClone(t) ==
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[t][gi].addr # NullPtr
        /\ FreeGuardSlot(t) # 0
        /\ FreeGuardSlot(t) # gi
        /\ LET g == guards[t][gi]
               ngi == FreeGuardSlot(t)
           IN  /\ refCount' = [refCount EXCEPT ![g.addr] = @ + 1]
               /\ guards' = [guards EXCEPT ![t][ngi] =
                               [addr |-> g.addr, gen |-> g.gen,
                                viaNode |-> NoneGid, viaSlot |-> 0,
                                hasDebt |-> FALSE]]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   slotVars, threadOwnVars, readerVars, writerVars, casVars, mcVars>>

\* (F2) Send Guard between threads.  The guard wraps a &'static Debt slot, so
\* it is Send.  Move ownership; no atomic op happens here — the debt slot's
\* identity is unchanged.  This is a pure scheduler/program decision.
SendGuard(src, dst) ==
    /\ src # dst
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[src][gi].addr # NullPtr
        /\ FreeGuardSlot(dst) # 0
        /\ LET dgi == FreeGuardSlot(dst) IN
            /\ guards' = [guards EXCEPT
                            ![src][gi] = EmptyGuard,
                            ![dst][dgi] = guards[src][gi]]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   readerVars, writerVars, casVars, mcVars>>

\* hybrid.rs:119-141 + lib.rs Drop — drop a Guard.
\*  - If hasDebt: try Debt::pay; on success debt cleared; on failure T::dec.
\*  - If no debt: T::dec (caller owned a strong ref).
DropGuard(t) ==
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[t][gi].addr # NullPtr
        /\ LET g == guards[t][gi] IN
            \/ \* hasDebt branch — hybrid.rs:129-138
               /\ g.hasDebt
               /\ \/ \* pay succeeds (debt/mod.rs:77 success leg = AcqRel)
                     /\ SlotValue(g.viaNode, g.viaSlot) = g.addr
                     /\ IF g.viaSlot = HelpSlotIx
                        THEN /\ helpSlot' = [helpSlot EXCEPT ![g.viaNode] = NullPtr]
                             /\ UNCHANGED fastSlot
                        ELSE /\ fastSlot' = [fastSlot EXCEPT ![g.viaNode][g.viaSlot] = NullPtr]
                             /\ UNCHANGED helpSlot
                     /\ UNCHANGED refCount
                  \/ \* pay fails — writer paid; T::dec (hybrid.rs:139)
                     /\ SlotValue(g.viaNode, g.viaSlot) # g.addr
                     /\ refCount' = [refCount EXCEPT ![g.addr] = @ - 1]
                     /\ UNCHANGED <<fastSlot, helpSlot>>
            \/ \* no debt — hybrid.rs:126 — just T::dec
               /\ ~g.hasDebt
               /\ refCount' = [refCount EXCEPT ![g.addr] = @ - 1]
               /\ UNCHANGED <<fastSlot, helpSlot>>
            /\ guards' = [guards EXCEPT ![t][gi] = EmptyGuard]
    \* If refcount reached 0 the address is freed
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   threadOwnVars, readerVars, writerVars, casVars, mcVars>>

\* ===================================================================================
\* Writer: swap + pay_all (lib.rs:478-491 + debt/mod.rs:82-122 + debt/list.rs)
\* ===================================================================================

\* lib.rs:485 — let old = self.ptr.swap(new, SeqCst).
\* Family 1 site "WriterSwap".  We allow new pointer to be a previously-freed
\* address (F3: allocator reuses).
WriterSwap(t) ==
    /\ ~arcSwapDropped
    /\ wPC[t] = "w_idle"
    /\ rPC[t] = "r_idle"
    /\ \E newAddr \in Addr :
        /\ ~addrAlive[newAddr]                          \* must allocate (or reuse freed)
        /\ newAddr # storageAddr
        /\ addrAlive' = [addrAlive EXCEPT ![newAddr] = TRUE]
        /\ addrGen'   = [addrGen EXCEPT ![newAddr] = @ + 1]   \* fresh generation
        /\ refCount'  = [refCount EXCEPT ![newAddr] = 1]
        /\ wOldAddr'  = [wOldAddr EXCEPT ![t] = storageAddr]
        /\ wOldGen'   = [wOldGen  EXCEPT ![t] = storageGen]
        /\ storageAddr' = newAddr
        /\ storageGen'  = addrGen'[newAddr]
    /\ wPC' = [wPC EXCEPT ![t] = "w_after_swap"]
    /\ wFreedOld' = [wFreedOld EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<nodeVars, slotVars, threadOwnVars, readerVars,
                   wToVisit, wCurNode, wScanned, wScanRemaining,
                   casVars, clientVars, mcVars>>

\* debt/mod.rs:89-91 — let val = T::from_ptr(ptr); T::inc(&val).
WriterPayInit(t) ==
    /\ wPC[t] = "w_after_swap"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ + 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_pay_init"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen,
                   nodeVars, slotVars, threadOwnVars, readerVars,
                   wOldAddr, wOldGen, wToVisit, wCurNode, wScanned, wScanRemaining,
                   wFreedOld, casVars, clientVars, mcVars>>

\* debt/list.rs:102 — LIST_HEAD.load(SeqCst).  Family 1 site "ListHeadLoad".
\* Family 3 + brief §2: writer scans nodes — if snapshot misses recently-prepended
\* nodes (because LIST_HEAD load was relaxed), a freshly-arrived reader may hold
\* a freed pointer.  Same shape as BUG-A in left-right.
\*
\* Note: Node::traverse walks the full linked list regardless of in_use state.
\* Nodes are never freed (list.rs:6-9), so the writer's pay_all closure scans
\* every node — including UNUSED/COOLDOWN ones.  Filtering by nodeState here
\* would let a freshly-cooled-down node escape the scan.
WriterTraverseLoad(t) ==
    /\ wPC[t] = "w_pay_init"
    /\ LET livenodes == Thread IN
        \/ \* SC: snapshot is exactly the live set
           /\ IsSC("ListHeadLoad")
           /\ wToVisit' = [wToVisit EXCEPT ![t] = livenodes]
        \/ \* Family 1 relaxation: stale snapshot — may miss recently-prepended nodes
           /\ ~IsSC("ListHeadLoad")
           /\ \E sub \in SUBSET livenodes :
                wToVisit' = [wToVisit EXCEPT ![t] = sub]
    /\ wPC' = [wPC EXCEPT ![t] = "w_traverse_loaded"]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount,
                   nodeVars, slotVars, threadOwnVars, readerVars,
                   wOldAddr, wOldGen, wScanned, wScanRemaining, wFreedOld,
                   casVars, clientVars, mcVars>>

\* debt/mod.rs:96 + list.rs:148-152 — let _reservation = node.reserve_writer().
\* active_writers.fetch_add(1, Acquire).  Pick any node from the snapshot.
\* (F4) Add t to inflightHelp[node] — writer is now holding a NodeReservation.
WriterReserveNode(t) ==
    /\ wPC[t] = "w_traverse_loaded"
    /\ wToVisit[t] # {}
    /\ \E node \in wToVisit[t] :
        /\ wCurNode' = [wCurNode EXCEPT ![t] = node]
        /\ activeWriters' = [activeWriters EXCEPT ![node] = @ + 1]
        /\ inflightHelp' = [inflightHelp EXCEPT ![node] = @ \cup {t}]
        /\ wScanRemaining' = [wScanRemaining EXCEPT ![t] =
                                {<<node, s>> : s \in SlotIx}]
    /\ wPC' = [wPC EXCEPT ![t] = "w_node_reserved"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount,
                   nodeState, nodeOwner, helpGen, slotVars, threadOwnVars,
                   readerVars, wOldAddr, wOldGen, wToVisit, wScanned, wFreedOld,
                   casVars, clientVars, mcVars>>

\* debt/mod.rs:98 — local.help(node, storage_addr, &replacement).
\* helping.rs:219-306.  When the visited node has CTRL_GEN matching this writer's
\* storage_addr, the writer can offer a fresh replacement Arc and CAS the control
\* to CTRL_REPL.  Modeled as non-deterministic outcome.
WriterHelpNode(t) ==
    /\ wPC[t] = "w_node_reserved"
    /\ wCurNode[t] # NoneGid
    /\ \/ \* No-help branch: control IDLE/REPL, different addr, or self-node
          /\ \/ helpControl[wCurNode[t]] # CTRL_GEN
             \/ helpActiveAddr[wCurNode[t]] = 0
             \/ wCurNode[t] = t      \* helping.rs:235-238 "Refusing to help myself"
          /\ UNCHANGED <<refCount, helpControl, helpControlGen, helpReplAddr>>
       \/ \* Help branch: target reader is in CTRL_GEN for this addr
          /\ helpControl[wCurNode[t]] = CTRL_GEN
          /\ helpActiveAddr[wCurNode[t]] # 0
          /\ wCurNode[t] # t
          /\ refCount' = [refCount EXCEPT ![storageAddr] = @ + 1]
          /\ helpControl'    = [helpControl    EXCEPT ![wCurNode[t]] = CTRL_REPL]
          /\ helpControlGen' = [helpControlGen EXCEPT ![wCurNode[t]] = 0]
          /\ helpReplAddr'   = [helpReplAddr   EXCEPT ![wCurNode[t]] = storageAddr]
    /\ wPC' = [wPC EXCEPT ![t] = "w_after_help"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   fastSlot, helpSlot, helpActiveAddr, threadOwnVars,
                   readerVars, wOldAddr, wOldGen, wToVisit, wCurNode,
                   wScanned, wScanRemaining, wFreedOld, casVars, clientVars, mcVars>>

\* debt/mod.rs:101-114 — for slot in all_slots { if slot.pay::<T>(ptr) { T::inc(&val) } }.
\* Per-slot CAS at debt/mod.rs:109 (debt/mod.rs:65-79 internally — AcqRel/Acquire).
\* Family 1: "DebtPaySuccess" / "DebtPayFailure" — adversary can downgrade.
\* Family 3: split per-slot — an interleaved fresh debt by another reader AFTER
\*   writer's snapshot remains observable.
WriterScanSlot(t) ==
    /\ wPC[t] = "w_after_help"
    /\ wScanRemaining[t] # {}
    /\ \E pos \in wScanRemaining[t] :
        LET node == pos[1]
            slot == pos[2]
            slotVal == SlotValue(node, slot)
        IN  /\ \/ \* CAS hits — slot held wOldAddr[t] — debt/mod.rs:109
                  /\ slotVal = wOldAddr[t]
                  /\ IF slot = HelpSlotIx
                     THEN /\ helpSlot' = [helpSlot EXCEPT ![node] = NullPtr]
                          /\ UNCHANGED fastSlot
                     ELSE /\ fastSlot' = [fastSlot EXCEPT ![node][slot] = NullPtr]
                          /\ UNCHANGED helpSlot
                  /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ + 1]
                                  \* T::inc — pre-pay (debt/mod.rs:111)
               \/ \* CAS misses — slot held something else
                  /\ slotVal # wOldAddr[t]
                  /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
               \/ \* Family 1 relaxation on success leg: writer fails to see
                  \* a debt that reader published with full SC (recreates #76 / #204).
                  /\ ~IsSC("DebtPaySuccess")
                  /\ slotVal = wOldAddr[t]
                  /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
            /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {pos}]
            /\ wScanRemaining' = [wScanRemaining EXCEPT ![t] = @ \ {pos}]
            /\ wPC' = [wPC EXCEPT ![t] = "w_after_help"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   threadOwnVars, readerVars, wOldAddr, wOldGen, wToVisit, wCurNode,
                   wFreedOld, casVars, clientVars, mcVars>>

\* list.rs:54-58 — Drop for NodeReservation runs (active_writers.fetch_sub(1, Release)).
\* (F4) Remove t from inflightHelp[wCurNode[t]].
WriterReleaseNode(t) ==
    /\ wPC[t] = "w_after_help"
    /\ wScanRemaining[t] = {}
    /\ wCurNode[t] # NoneGid
    /\ activeWriters' = [activeWriters EXCEPT ![wCurNode[t]] = @ - 1]
    /\ inflightHelp' = [inflightHelp EXCEPT ![wCurNode[t]] = @ \ {t}]
    /\ wToVisit' = [wToVisit EXCEPT ![t] = @ \ {wCurNode[t]}]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ wPC' = IF wToVisit[t] \ {wCurNode[t]} = {}
              THEN [wPC EXCEPT ![t] = "w_pay_done"]
              ELSE [wPC EXCEPT ![t] = "w_traverse_loaded"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount,
                   nodeState, nodeOwner, helpGen, slotVars, threadOwnVars,
                   readerVars, wOldAddr, wOldGen, wScanned, wScanRemaining, wFreedOld,
                   casVars, clientVars, mcVars>>

\* debt/mod.rs:118 — implicit T::dec when val drops at end of pay_all closure.
WriterPayDone(t) ==
    /\ wPC[t] = "w_pay_done"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ - 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_returning"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   slotVars, threadOwnVars, readerVars,
                   wOldAddr, wOldGen, wToVisit, wCurNode, wScanned, wScanRemaining,
                   wFreedOld, casVars, clientVars, mcVars>>

\* lib.rs:489 — caller receives old Arc, drops it at end of swap().
\* (F3) wFreedOld marks whether refCount[wOldAddr] reached 0 here.  Used by
\* StaleSnapshotSafety to check the moment when `old` is actually freed.
WriterReturn(t) ==
    /\ wPC[t] = "w_returning"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ - 1]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ wFreedOld' = [wFreedOld EXCEPT ![t] = (refCount'[wOldAddr[t]] = 0)]
    /\ wPC' = [wPC EXCEPT ![t] = "w_idle"]
    /\ wOldAddr' = [wOldAddr EXCEPT ![t] = NullPtr]
    /\ wOldGen' = [wOldGen EXCEPT ![t] = 0]
    /\ wToVisit' = [wToVisit EXCEPT ![t] = {}]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ wScanned' = [wScanned EXCEPT ![t] = {}]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, slotVars,
                   threadOwnVars, readerVars, wScanRemaining, casVars,
                   clientVars, mcVars>>

\* ===================================================================================
\* CompareAndSwap (Family 2 — strategy/hybrid.rs:227-263 + lib.rs:509-516)
\* ===================================================================================
\* Loop:
\*   1. old = load(self)
\*   2. if old.as_ptr() != current.as_raw(): return old
\*   3. compare_exchange_weak(current.as_raw(), new_raw, SeqCst, Relaxed)
\*   4. on success: T::into_ptr(new); wait_for_readers(old); T::dec(old)

\* Caller pre-creates an Arc before the call: addr becomes alive, refCount=1.
\* If CAS succeeds, this ref transfers to storage; if it fails, the caller's Arc
\* is dropped (refCount-- → free).
CASBegin(t) ==
    /\ wPC[t] = "w_idle"
    /\ rPC[t] = "r_idle"
    /\ ~arcSwapDropped
    /\ \E newAddr \in Addr, kind \in {CAS_KIND_ARC, CAS_KIND_GUARD,
                                       CAS_KIND_RAWFRESH, CAS_KIND_RAWSTALE} :
        /\ ~addrAlive[newAddr]
        /\ newAddr # storageAddr
        /\ addrAlive' = [addrAlive EXCEPT ![newAddr] = TRUE]
        /\ addrGen'   = [addrGen   EXCEPT ![newAddr] = @ + 1]
        /\ refCount'  = [refCount  EXCEPT ![newAddr] = 1]
        /\ \E curAddr \in Addr, curGen \in 1..2 :
            /\ casKind'    = [casKind    EXCEPT ![t] = kind]
            /\ casCurAddr' = [casCurAddr EXCEPT ![t] = curAddr]
            /\ casCurGen'  = [casCurGen  EXCEPT ![t] =
                                IF kind = CAS_KIND_RAWSTALE THEN curGen
                                ELSE addrGen'[curAddr]]
            /\ casNewAddr' = [casNewAddr EXCEPT ![t] = newAddr]
            /\ casNewGen'  = [casNewGen  EXCEPT ![t] = addrGen'[newAddr]]
        /\ casOldAddr' = [casOldAddr EXCEPT ![t] = storageAddr]
        /\ casOldGen'  = [casOldGen  EXCEPT ![t] = storageGen]
    /\ rPC' = [rPC EXCEPT ![t] = "cas_after_load"]
    /\ rPath' = [rPath EXCEPT ![t] = "cas"]
    /\ UNCHANGED <<storageAddr, storageGen, nodeVars, slotVars, threadOwnVars,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, clientVars, mcVars>>

\* hybrid.rs:242-244 — if old.as_ptr() != current.as_raw(): return old.  No swap.
\* The pre-allocated `new` Arc is dropped: refCount[new] -= 1 → freed.
CASCompareNotEqual(t) ==
    /\ rPC[t] = "cas_after_load"
    /\ casOldAddr[t] # casCurAddr[t]
    /\ refCount' = [refCount EXCEPT ![casNewAddr[t]] = @ - 1]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ casKind' = [casKind EXCEPT ![t] = CAS_KIND_ARC]
    /\ casCurAddr' = [casCurAddr EXCEPT ![t] = NullPtr]
    /\ casCurGen' = [casCurGen EXCEPT ![t] = 0]
    /\ casNewAddr' = [casNewAddr EXCEPT ![t] = NullPtr]
    /\ casNewGen' = [casNewGen EXCEPT ![t] = 0]
    /\ casOldAddr' = [casOldAddr EXCEPT ![t] = NullPtr]
    /\ casOldGen' = [casOldGen EXCEPT ![t] = 0]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, slotVars,
                   threadOwnVars, rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged,
                   rDebtNode, rDebtSlot, rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   writerVars, clientVars, mcVars>>

\* hybrid.rs:247-251 — compare_exchange_weak(current, new, SeqCst, Relaxed).
\* On success: caller's new-Arc ref is moved into storage; old comes back.
\* Then proceed into the writer's pay_all state machine for the old.
CASExchangeOk(t) ==
    /\ rPC[t] = "cas_after_load"
    /\ casOldAddr[t] = casCurAddr[t]
    /\ storageAddr = casCurAddr[t]
    \* ABA hazard: RAWSTALE means caller had stale generation but address still
    \* equals storage's current address — CAS reports success spuriously.
    /\ casKind[t] = CAS_KIND_RAWSTALE \/ casCurGen[t] = storageGen
    /\ storageAddr' = casNewAddr[t]
    /\ storageGen'  = casNewGen[t]
    /\ wOldAddr' = [wOldAddr EXCEPT ![t] = casOldAddr[t]]
    /\ wOldGen' = [wOldGen EXCEPT ![t] = casOldGen[t]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ wPC' = [wPC EXCEPT ![t] = "w_after_swap"]
    /\ wFreedOld' = [wFreedOld EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<addrAlive, addrGen, refCount, nodeVars, slotVars,
                   threadOwnVars, rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged,
                   rDebtNode, rDebtSlot, rGotEnvelope, rEnvelopeAddr, rWrapDiscard,
                   wToVisit, wCurNode, wScanned, wScanRemaining, casVars,
                   clientVars, mcVars>>

\* hybrid.rs:259-260 failure leg — current was no longer in storage; retry.
CASExchangeFail(t) ==
    /\ rPC[t] = "cas_after_load"
    /\ casOldAddr[t] = casCurAddr[t]
    /\ storageAddr # casCurAddr[t]
    /\ casOldAddr' = [casOldAddr EXCEPT ![t] = storageAddr]
    /\ casOldGen' = [casOldGen EXCEPT ![t] = storageGen]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars, rPC, rOpAddr,
                   rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rWrapDiscard, rPath,
                   writerVars, casKind, casCurAddr, casCurGen,
                   casNewAddr, casNewGen, clientVars, mcVars>>

\* ===================================================================================
\* Family 4 — Cooldown state machine (debt/list.rs:115-145)
\* ===================================================================================

\* list.rs:125-145 — check_cooldown.  When in COOLDOWN with active_writers=0,
\* CAS COOLDOWN → UNUSED (Relaxed).  This is the release point.
\* (F4) Note: implementation does Acquire on in_use load + Relaxed on active_writers.
\* The Relaxed load is fine because start_cooldown's _reservation Drop chain via
\* active_writers' coherence order ensures we observe an up-to-date 0.
CheckCooldown(n) ==
    /\ nodeState[n] = NODE_COOLDOWN
    /\ activeWriters[n] = 0
    /\ nodeState' = [nodeState EXCEPT ![n] = NODE_UNUSED]
    /\ UNCHANGED <<allocVars, nodeOwner, activeWriters, inflightHelp, helpGen,
                   slotVars, threadOwnVars, readerVars, writerVars, casVars,
                   clientVars, mcVars>>

\* list.rs:158-204 — Node::get reuses an UNUSED node OR allocates a new one.
\* For our model, threads never spawn — set of nodes is fixed = Thread.  Reuse is
\* the only path: a thread without a localNode (post-discard, F5) claims an
\* UNUSED node.  CAS UNUSED → USED (SeqCst).
\*
\* Implementation: Node::get is invoked from LocalNode::with's lazy-init
\* (list.rs:243-244) — it fires only at the start of a new API call when
\* self.node = None (idle thread).  Therefore ClaimNode requires rPC[t] = r_idle
\* AND wPC[t] = w_idle: this prevents stale rConfirmAddr from being carried
\* into a fresh node (which would mask the F5 panic by re-armed continuation).
\*
\* (F5) Also clear pendingHelpingTx[t] on claim — the bookkeeping was associated
\* with the discarded node; re-armed transactions on the new node start at 0.
ClaimNode(t, n) ==
    /\ nodeState[n] = NODE_UNUSED
    /\ nodeOwner[n] = NoneGid
    /\ localNode[t] = NoneGid                 \* (F5) thread has no node — needs one
    /\ rPC[t] = "r_idle"                      \* idle: no in-flight reader op
    /\ wPC[t] = "w_idle"                      \* idle: no in-flight writer op
    /\ nodeState' = [nodeState EXCEPT ![n] = NODE_USED]
    /\ nodeOwner' = [nodeOwner EXCEPT ![n] = t]
    /\ localNode' = [localNode EXCEPT ![t] = n]
    /\ pendingHelpingTx' = [pendingHelpingTx EXCEPT ![t] = FALSE]
    /\ helpGen' = [helpGen EXCEPT ![n] = 0]
    \* Slots persist across owners (list.rs:6-9 — nodes are never freed).
    /\ UNCHANGED <<allocVars, activeWriters, inflightHelp, slotVars,
                   readerVars, writerVars, casVars,
                   clientVars, mcVars>>

\* ===================================================================================
\* Family 1 — relaxation adversary (PickRelaxSite)
\* ===================================================================================
\* The base spec exposes the relaxation as a one-shot non-deterministic choice
\* to pick exactly one site to downgrade.  The MC layer counter-bounds this.
\* Picking NoneSite means "execute as written" (SC labels respected).
PickRelaxSite(s) ==
    /\ relaxSite = NoneSite                  \* one-shot
    /\ s \in RelaxSites
    /\ relaxSite' = s
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, threadOwnVars,
                   readerVars, writerVars, casVars, clientVars, arcSwapDropped>>

\* ===================================================================================
\* Family 2 — DropArcSwap (caller-precondition hazard)
\* ===================================================================================
\* lib.rs:338-349.  Caller drops the ArcSwap object while readers may still hold
\* pointers.  Documented requirement: caller has unique &mut self, so no concurrent
\* loads on this object.  Modeled as an action; the precondition rejects traces
\* where any reader is mid-load or holds a guard.
DropArcSwap ==
    /\ ~arcSwapDropped
    \* Caller precondition (lib.rs:338-349): &mut self requires no concurrent users.
    /\ \A t \in Thread :
        /\ rPC[t] = "r_idle"
        /\ wPC[t] = "w_idle"
        /\ \A i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    /\ arcSwapDropped' = TRUE
    /\ refCount' = [refCount EXCEPT ![storageAddr] = @ - 1]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, slotVars,
                   threadOwnVars, readerVars, writerVars, casVars, clientVars, relaxSite>>

\* ===================================================================================
\* Next-State Relation
\* ===================================================================================

Next ==
    \/ \E t \in Thread :
        \* Reader fast path
        \/ ReaderFastLoad(t)
        \/ ReaderFastSlotAcquire(t)
        \/ ReaderFastConfirmLoad(t)
        \/ ReaderFastBranchHit(t)
        \/ ReaderFastResolve(t)
        \* Reader fallback path (F5 split)
        \/ ReaderFallbackActiveAddr(t)
        \/ ReaderFallbackControlSwap(t)
        \/ ReaderFallbackDiscardNode(t)
        \/ ReaderFallbackCandidate(t)
        \/ ReaderFallbackSlotStore(t)
        \/ ReaderFallbackConfirmOK(t)
        \/ ReaderFallbackConfirmHelped(t)
        \/ ReaderFallbackResolveEnvelope(t)
        \* Guard / client harness (F2)
        \/ GuardIntoInner(t)
        \/ GuardClone(t)
        \/ DropGuard(t)
        \* Writer
        \/ WriterSwap(t)
        \/ WriterPayInit(t)
        \/ WriterTraverseLoad(t)
        \/ WriterReserveNode(t)
        \/ WriterHelpNode(t)
        \/ WriterScanSlot(t)
        \/ WriterReleaseNode(t)
        \/ WriterPayDone(t)
        \/ WriterReturn(t)
        \* CAS (F2)
        \/ CASBegin(t)
        \/ CASCompareNotEqual(t)
        \/ CASExchangeOk(t)
        \/ CASExchangeFail(t)
    \/ \E src \in Thread, dst \in Thread : SendGuard(src, dst)
    \/ \E t \in Thread, n \in Thread : ClaimNode(t, n)
    \/ \E n \in Thread : CheckCooldown(n)
    \/ \E s \in RelaxSites : PickRelaxSite(s)
    \/ DropArcSwap

Spec == Init /\ [][Next]_vars

\* ===================================================================================
\* Type Invariant
\* ===================================================================================

TypeOK ==
    /\ storageAddr \in Addr
    /\ storageGen  \in Nat
    /\ addrAlive   \in [Addr -> BOOLEAN]
    /\ addrGen     \in [Addr -> Nat]
    /\ refCount    \in [Addr -> Nat]
    /\ nodeState   \in [Thread -> {NODE_UNUSED, NODE_USED, NODE_COOLDOWN}]
    /\ activeWriters \in [Thread -> Nat]
    /\ inflightHelp  \in [Thread -> SUBSET Thread]
    /\ helpGen     \in [Thread -> 0..MaxHelpGen]
    /\ fastSlot    \in [Thread -> [FastSlotIx -> AllAddr]]
    /\ helpSlot    \in [Thread -> AllAddr]
    /\ helpControl \in [Thread -> {CTRL_IDLE, CTRL_GEN, CTRL_REPL}]
    /\ localNode   \in [Thread -> Thread \cup {NoneGid}]
    /\ pendingHelpingTx \in [Thread -> BOOLEAN]
    /\ rPC         \in [Thread -> RPhases]
    /\ wPC         \in [Thread -> WPhases]
    /\ relaxSite   \in RelaxSites \cup {NoneSite}
    /\ arcSwapDropped \in BOOLEAN

\* ===================================================================================
\* Safety Invariants — bug-family driven
\* ===================================================================================

\* (F1/F2/F3) NoUseAfterFree: no Guard references a freed pointer.  The headline
\* UAF invariant per modeling-brief.md §5.  Slot values are CAS targets in the
\* debt protocol — never dereferenced; transient stale slot values are caught
\* by PayAllCompleteness instead.
NoUseAfterFree == NoStaleGuard

\* (F1/F3) PayAllCompleteness: once writer finishes pay_all (w_returning),
\* no slot anywhere should hold the old pointer.  Bug #76 violated this.
\* The stale-snapshot variant from F3 (writer's wToVisit missed a node)
\* surfaces as: a slot at an unvisited node still holds wOldAddr after w_returning.
PayAllCompleteness ==
    \A t \in Thread :
        wPC[t] = "w_returning" =>
            \A pos \in Thread \X SlotIx :
                SlotValue(pos[1], pos[2]) # wOldAddr[t]

\* (F3 NEW) StaleSnapshotSafety: at the moment writer freed the last refcount
\* of `old` (wFreedOld[t]=TRUE), every reader-node visible-to-the-system was
\* either scanned by pay_all OR holds debt on a strictly-newer pointer.
\* Stated as: after wFreedOld, no slot holds wOldAddr.  This is a strengthened
\* form of NoUseAfterFree at the freeing instant.
StaleSnapshotSafety ==
    \A t \in Thread :
        (wPC[t] = "w_idle" /\ wFreedOld[t]) =>
            \A pos \in Thread \X SlotIx :
                LET v == SlotValue(pos[1], pos[2]) IN
                v # NullPtr =>
                    /\ addrAlive[v]
                    /\ addrGen[v] >= storageGen

\* (F3) NoTornGuardState: a reader's confirmed addr/gen must match a real
\* allocation.  Fast-path uses `confirm` (not `ptr`) so the gen captured matches
\* the live allocation at the captured address.
NoTornGuardState ==
    \A t \in Thread :
        \A i \in 1..MaxGuardsPerThread :
            (guards[t][i].addr # NullPtr) =>
                guards[t][i].gen <= addrGen[guards[t][i].addr]

\* (F1/F2) RefCountNonNeg: refcounts never go negative.
RefCountNonNeg == \A a \in Addr : refCount[a] >= 0

\* (F1/F2 NEW) RefCountAccounting: the sum of references that the protocol
\* believes to be held equals the storage refCount.  More specifically:
\*   For an alive address a, refCount[a] >= |{guards holding a}|
\* This catches double-pay (refcount over-incremented relative to held guards)
\* and lost-pay (refcount under-incremented).  The strict "=" form is too tight
\* due to the writer's transient pre-pay (T::inc at debt/mod.rs:91 before
\* slots are paid); we check the ≥ form which is the safety lower bound.
RefCountAccounting ==
    \A a \in Addr :
        addrAlive[a] =>
            refCount[a] >= Cardinality({<<t,i>> \in Thread \X (1..MaxGuardsPerThread) :
                                         /\ guards[t][i].addr = a
                                         /\ ~guards[t][i].hasDebt})

\* (F2) CASIntendedSemantics: a successful CAS on a non-stale current implies
\* the storage transitioned through a value pointer-equal to current.  For
\* RAWSTALE callers, a generation-mismatch success is the documented hazard.
CASIntendedSemantics ==
    \A t \in Thread :
        (rPC[t] = "cas_after_load" /\ rPath[t] = "cas") =>
            casKind[t] \in {CAS_KIND_ARC, CAS_KIND_GUARD,
                            CAS_KIND_RAWFRESH, CAS_KIND_RAWSTALE}

\* (F2 NEW) NoOrphanedDebt: every fast-slot or helping-slot debt is either
\* alive on a live Guard, has been paid by a writer (slot cleared by the time
\* of the writer's WriterReturn for that pointer), or is in flight in a Guard
\* drop sequence (rPC indicates we're cleaning up).  Stated as: a slot value
\* that is a real address must correspond to either an alive Guard with that
\* address-and-debt-flag, OR a writer holding it as wOldAddr in mid-pay_all.
NoOrphanedDebt ==
    \A pos \in Thread \X SlotIx :
        LET n == pos[1]
            s == pos[2]
            v == SlotValue(n, s)
        IN  v # NullPtr =>
            \/ \* Some live debted Guard claims it
               \E t \in Thread, i \in 1..MaxGuardsPerThread :
                   /\ guards[t][i].addr = v
                   /\ guards[t][i].hasDebt
                   /\ guards[t][i].viaNode = n
                   /\ guards[t][i].viaSlot = s
            \/ \* Some reader is mid-load and will resolve via DropGuard/Resolve
               \E t \in Thread :
                   /\ rPC[t] # "r_idle"
                   /\ \/ rDebtNode[t] = n /\ rDebtSlot[t] = s
                      \/ rOpAddr[t] = v
                      \/ rConfirmAddr[t] = v
            \/ \* A writer holds the pointer pre-decrement
               \E t \in Thread :
                   /\ wPC[t] # "w_idle"
                   /\ wOldAddr[t] = v

\* (F4) NoConcurrentNodeClaim: at most one thread claims a node USED at a time.
NoConcurrentNodeClaim ==
    \A n \in Thread :
        nodeState[n] = NODE_USED =>
            (\E t \in Thread : nodeOwner[n] = t)

\* (F4 NEW) CooldownDrainSafety: when a node transitions COOLDOWN→UNUSED, the
\* set of writers holding NodeReservations on it (inflightHelp[n]) is empty.
\* Stated as the steady-state form: a UNUSED node has no inflightHelp.
\* If an old `help` context could still hold a reservation against a node that
\* has been reclaimed (UNUSED), an ABA scenario emerges.
CooldownDrainSafety ==
    \A n \in Thread :
        nodeState[n] = NODE_UNUSED => inflightHelp[n] = {}

\* (F1) NoStaleWithoutRelax: when no relaxation is active, the confirm-load
\* value must be the current storage value.
NoStaleWithoutRelax ==
    relaxSite = NoneSite =>
        \A t \in Thread :
            rPC[t] = "r_fast_after_confirm" => rConfirmAddr[t] = storageAddr

\* (F5 NEW) NoDanglingTransaction: if a reader has a pending helping transaction
\* (control was set to gen | GEN_TAG by ControlSwap), then either:
\*   (a) the reader still holds its localNode AND the slot's control still
\*       reflects the pending generation, OR
\*   (b) the reader has discarded the node (rWrapDiscard) — but then the next
\*       confirm_helping panics.
\* The bug surface: pendingHelpingTx[t] = TRUE ∧ localNode[t] = NoneGid.
\* That state is only reachable via rWrapDiscard; if it occurs while rPC[t]
\* expects to call confirm_helping (r_fb_after_discard waiting for r_fb_after_slot),
\* the implementation panics.
\*
\* We state the *strong* form: pendingHelpingTx[t] ⇒ localNode[t] # NoneGid.
\* This invariant is *expected to fail* in MC_hunt_family5.cfg with MaxHelpGen=4
\* and a reader entering fallback — that failure IS the bug.
NoDanglingTransaction ==
    \A t \in Thread :
        pendingHelpingTx[t] => localNode[t] # NoneGid

\* ===================================================================================
\* Structural Invariants
\* ===================================================================================

\* Storage points to a live allocation (or empty if dropped).
StorageLive == arcSwapDropped \/ addrAlive[storageAddr]

\* Dead address has zero refcount.
DeadRefCountZero == \A a \in Addr : ~addrAlive[a] => refCount[a] = 0

\* Reader and writer cannot run on the same thread simultaneously.
ReaderWriterExclusive ==
    \A t \in Thread : wPC[t] # "w_idle" => rPC[t] = "r_idle"

\* All slot occupants and all guards reference allocated (or once-allocated) memory.
AllOccupantsAllocated ==
    /\ \A t \in Thread, s \in SlotIx :
        SlotValue(t, s) # NullPtr =>
            (SlotValue(t, s) \in Addr /\ addrGen[SlotValue(t, s)] > 0)
    /\ \A t \in Thread, i \in 1..MaxGuardsPerThread :
        guards[t][i].addr # NullPtr => guards[t][i].addr \in Addr

\* (F4) inflightHelp[n] entries are writer threads currently mid-pay_all on n.
\* Structural sanity: |inflightHelp[n]| <= activeWriters[n].
InflightHelpBounded ==
    \A n \in Thread : Cardinality(inflightHelp[n]) <= activeWriters[n]

\* (F5) localNode/nodeOwner consistency: when localNode[t] = n (n # NoneGid),
\* nodeOwner[n] = t (in normal cases).  Exception: post-discard, localNode[t] =
\* NoneGid AND nodeOwner[discarded] = NoneGid — both detached.  This invariant
\* says: localNode[t] = n ⇒ nodeOwner[n] = t.
LocalNodeOwnership ==
    \A t \in Thread :
        localNode[t] # NoneGid => nodeOwner[localNode[t]] = t

\* State constraint used in base.cfg: only run the SC-respecting protocol.
NoRelaxation == relaxSite = NoneSite

====
