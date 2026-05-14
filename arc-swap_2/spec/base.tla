---- MODULE base ----
\* ===================================================================================
\* TLA+ Specification: arc-swap (v1.8.2 + post-1.8.2 d5dd00c) Debt-Based Hazard Pointer
\*                     Round 2 — adversarial caller + helping-protocol fidelity
\* ===================================================================================
\*
\* Sub-category: reader-writer separation. Single AtomicPtr<T>; readers take a debt
\* slot; writers swap and walk all slots to "pay" (CAS-clear + inc) any matching debt.
\*
\* Bug families covered (from modeling-brief.md §2):
\*   A — Cross-variable SeqCst bridge  (HIGH)
\*   B — Allocator-reuse ABA           (MEDIUM)
\*   C — Adversarial caller harness    (HIGH — explicit gap from prior round)
\*   D — Generation wrap + cooldown    (MEDIUM)
\*   E — Writer-scan completeness      (HIGH, companion of A)
\*
\* Source files (paths under artifact/arc-swap/src/):
\*   strategy/hybrid.rs   :42-98, :106-127, :138-158, :200-239   reader load + drop + CaS
\*   debt/mod.rs          :48-115                                 Debt::pay + pay_all
\*   debt/list.rs         :50-205                                 LIST_HEAD + Node lifecycle
\*   debt/fast.rs         :38-66                                  fast slot allocation
\*   debt/helping.rs      :186-333                                helping/handover protocol
\*   lib.rs               :337-347, :477-488, :506-513, :614-631  Drop/swap/CaS/rcu
\*
\* Granularity: every observable atomic op is its own action. Per concurrent-analysis
\* §5.1, action splitting *is* the interleaving adversary; do not collapse load → check
\* → CAS into one action. (base-spec-methodology.md "Granularity for Concurrent Specs")

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ===================================================================================
\* Constants
\* ===================================================================================

CONSTANTS
    Thread,               \* threads (also indexes nodes 1:1 — we treat thread t's
                          \* "owned" node as having identity t for simplicity)
    Addr,                 \* allocator addresses (Family B: addresses can be reused)
    InitAddr,             \* address of the first stored Arc
    NumFastSlots,         \* fast slots per node (real: 8; MC: 1-2)
    MaxHelpGen,           \* helping-generation bound; wrap at this value triggers
                          \* cooldown (Family D — helping.rs:191-213)
    MaxGuardsPerThread,   \* bound on per-thread in-flight Guards (Family C)
    NullPtr,              \* sentinel for empty debt slot (debt/mod.rs:39 NONE)
    NoneGid,              \* sentinel "no guard"
    NoneSite              \* sentinel "no relaxation site picked"

\* Named sites whose Ordering label can be downgraded by MCRelaxOrdering (Family A).
\* Each site corresponds to one atomic op in the source. Adversary downgrades exactly
\* one site for the entire run — see modeling-brief.md §2 Family A.
RelaxSites == {
    "FastConfirmLoad",   \* hybrid.rs:51   storage.load(SeqCst)   (#76 family)
    "FallbackLoad",      \* hybrid.rs:78   storage.load(SeqCst)   (#198, fixed by d5dd00c)
    "DebtPaySuccess",    \* debt/mod.rs:77 CAS success leg (#204, fixed by cccf354)
    "DebtPayFailure",    \* debt/mod.rs:77 CAS failure leg (PR #195)
    "ListHeadLoad",      \* debt/list.rs:101 LIST_HEAD.load(SeqCst) (#164 family)
    "FastSlotSwap",      \* debt/fast.rs:58 slot.swap(ptr, SeqCst)
    "WriterSwap",        \* lib.rs:483    storage.swap(SeqCst)
    "ControlSwap",       \* helping.rs:209 control.swap(gen, SeqCst)
    "ConfirmHelping"     \* helping.rs:317 control.swap(IDLE, SeqCst)
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

\* Guard kinds passed to compare_and_swap as `current` (Family C, brief §4 CASCallerKind).
\* lib.rs:506-513 + as_raw.rs:60-72.
CAS_KIND_ARC      == "Arc"        \* &Arc current (refcounted, alive by construction)
CAS_KIND_GUARD    == "Guard"      \* &Guard current (debt-protected, alive)
CAS_KIND_RAWFRESH == "RawFresh"   \* *const T currently equal to a live ptr — no protection
CAS_KIND_RAWSTALE == "RawStale"   \* *const T from a freed allocation (documented hazard)

\* Reader phases — names match implementation control flow.
RPhases == {"r_idle",
            \* fast path — hybrid.rs:42-67
            "r_fast_after_load",       \* observed `ptr` from Relaxed load (line 44)
            "r_fast_after_slot",       \* fast slot acquired with SeqCst swap (fast.rs:58)
            "r_fast_after_confirm",    \* second SeqCst load done (line 51)
            \* fallback path — hybrid.rs:70-98
            "r_fb_after_active_addr",  \* active_addr.store(SeqCst) done (helping.rs:203)
            "r_fb_after_ctrl_gen",     \* control.swap(gen, SeqCst) done (helping.rs:209)
            "r_fb_after_candidate",    \* storage.load(SeqCst) for candidate (hybrid.rs:78)
            "r_fb_after_slot",         \* slot.swap(ptr, SeqCst) done (helping.rs:312)
            \* drop path — hybrid.rs:106-127
            "r_drop_paying",
            \* compare_and_swap retry loop — hybrid.rs:217-237
            "cas_after_load",
            "cas_after_compare",
            "cas_after_exchange_ok"
           }

\* Writer phases — pay_all walks list, scans each node (debt/mod.rs:82-115)
WPhases == {"w_idle",
            "w_after_swap",            \* storage.swap done (lib.rs:483)
            "w_pay_init",              \* T::inc done (debt/mod.rs:90)
            "w_traverse_loaded",       \* LIST_HEAD load done (debt/list.rs:101)
            "w_node_reserved",         \* active_writers++ for current node (list.rs:142-144)
            "w_after_help",            \* per-node `local.help(node, ...)` done (debt/mod.rs:96)
            "w_after_release",         \* active_writers-- (list.rs:55-58)
            "w_pay_done",              \* val drops (debt/mod.rs:113)
            "w_returning"              \* old returned to caller, then T::dec
           }

\* ===================================================================================
\* Variables
\* ===================================================================================

VARIABLES
    \* --- Allocator (Family B: ABA via address reuse) ---
    storageAddr,        \* Addr — current pointer in ArcSwap (lib.rs:321)
    storageGen,         \* Nat — generation tag of currently-stored allocation
    addrAlive,          \* [Addr -> BOOLEAN]  — TRUE if currently allocated
    addrGen,            \* [Addr -> Nat]      — generation of *current* allocation at this addr
    refCount,           \* [Addr -> Nat]      — current strong refcount

    \* --- Per-node state (debt/list.rs) ---
    nodeState,          \* [Thread -> NODE_*]  list.rs:45-47
    nodeOwner,          \* [Thread -> Thread \cup {NoneGid}]  who owns this node now
    activeWriters,      \* [Thread -> Nat]    list.rs:72
    helpGen,             \* [Thread -> 0..MaxHelpGen]  current generation counter (helping.rs:126)

    \* --- Slots ---
    fastSlot,           \* [Thread -> [FastSlotIx -> AllAddr]]   fast.rs Slots (debt/fast.rs:36)
    helpSlot,           \* [Thread -> AllAddr]                   helping slot Debt (helping.rs:151)
    helpControl,        \* [Thread -> CTRL_IDLE | CTRL_GEN | CTRL_REPL]
    helpControlGen,     \* [Thread -> Nat]   generation tag if CTRL_GEN
    helpActiveAddr,     \* [Thread -> Nat]   storage address being loaded (helping.rs:153)
    helpReplAddr,       \* [Thread -> AllAddr]  if CTRL_REPL, the addr in the envelope

    \* --- Reader thread state ---
    rPC,                \* [Thread -> RPhases]
    rPath,              \* [Thread -> "fast"|"fallback"|"none"|"cas"]
    rOpAddr,            \* [Thread -> AllAddr]   address observed at first load
    rConfirmAddr,       \* [Thread -> AllAddr]   address from confirm load (Family B uses this)
    rConfirmGen,        \* [Thread -> Nat]
    rGenTagged,         \* [Thread -> Nat]   generation tag the reader inserted into control
    rDebtNode,          \* [Thread -> Thread \cup {NoneGid}]   which node holds reader's debt
    rDebtSlot,          \* [Thread -> SlotIx \cup {0}]
    rGotEnvelope,       \* [Thread -> BOOLEAN]   confirm_helping returned Err (envelope path)
    rEnvelopeAddr,      \* [Thread -> AllAddr]   replacement addr the writer offered

    \* --- Writer thread state ---
    wPC,                \* [Thread -> WPhases]
    wOldAddr,           \* [Thread -> AllAddr]
    wOldGen,            \* [Thread -> Nat]
    wToVisit,           \* [Thread -> SUBSET Thread] snapshot of USED nodes at LIST_HEAD load
    wCurNode,           \* [Thread -> Thread \cup {NoneGid}] node currently reserved
    wScanned,           \* [Thread -> SUBSET (Thread \X SlotIx)] all <<n,s>> already scanned
    wScanRemaining,     \* [Thread -> SUBSET (Thread \X SlotIx)] still to do for current node

    \* --- compare_and_swap state (per thread, on the cas loop — hybrid.rs:217-237) ---
    casKind,            \* [Thread -> CAS_KIND_*]  what kind of `current` the caller passed
    casCurAddr,         \* [Thread -> AllAddr]      current.as_raw()
    casCurGen,          \* [Thread -> Nat]          gen at the time the kind was decided
    casNewAddr,         \* [Thread -> AllAddr]      the new pointer being written
    casNewGen,          \* [Thread -> Nat]
    casOldAddr,         \* [Thread -> AllAddr]      from the inner load
    casOldGen,          \* [Thread -> Nat]

    \* --- Adversarial caller harness: guards (Family C) ---
    \* Each Guard is a record. We bound the total number of guards per thread; ids
    \* are local to a thread. A "sent" guard is moved between threads via SendGuard.
    guards,             \* [Thread -> [1..MaxGuardsPerThread -> guard record | NoneGid]]
                        \* guard record fields: addr, gen, viaNode, viaSlot, hasDebt

    \* --- Family A relaxation adversary ---
    relaxSite,          \* RelaxSites \cup {NoneSite}; the one site downgraded for this run

    \* --- ArcSwap object lifecycle (Family C, C4) ---
    arcSwapDropped      \* BOOLEAN — caller dropped the ArcSwap object (lib.rs:337-347)

\* Variable groupings for UNCHANGED clauses
allocVars   == <<storageAddr, storageGen, addrAlive, addrGen, refCount>>
nodeVars    == <<nodeState, nodeOwner, activeWriters, helpGen>>
slotVars    == <<fastSlot, helpSlot, helpControl, helpControlGen, helpActiveAddr, helpReplAddr>>
readerVars  == <<rPC, rPath, rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged,
                 rDebtNode, rDebtSlot, rGotEnvelope, rEnvelopeAddr>>
writerVars  == <<wPC, wOldAddr, wOldGen, wToVisit, wCurNode, wScanned,
                 wScanRemaining>>
casVars     == <<casKind, casCurAddr, casCurGen, casNewAddr, casNewGen, casOldAddr,
                 casOldGen>>
clientVars  == <<guards>>
mcVars      == <<relaxSite, arcSwapDropped>>

vars == <<allocVars, nodeVars, slotVars, readerVars, writerVars, casVars,
          clientVars, mcVars>>

\* ===================================================================================
\* Helpers
\* ===================================================================================

\* All <<node, slot>> debt positions
AllSlotPositions == Thread \X SlotIx

\* Read the contents of any slot at <<n,s>>. Helping slot lives at HelpSlotIx.
SlotValue(n, s) ==
    IF s = HelpSlotIx THEN helpSlot[n] ELSE fastSlot[n][s]

\* Set of slots <<n,s>> currently holding addr a.
SlotsHolding(a) ==
    {<<n, s>> \in AllSlotPositions : SlotValue(n, s) = a}

\* Is site labelled SC effectively? Returns FALSE iff the adversary downgraded it.
\* (Family A — modeling-brief.md §2)
IsSC(site) == relaxSite # site

\* "Stale" addresses readable when SC label is downgraded — Family A over-approximation
\* per modeling-brief.md §2: a relaxed load can return any value the writer has ever
\* stored, including freed ones.
EverAllocated == {a \in Addr : addrGen[a] > 0}

\* Set of guards held by t (non-empty slots)
GuardIxs(t) == {i \in 1..MaxGuardsPerThread : guards[t][i].addr # NullPtr}

\* Free guard slot (or 0 if none)
FreeGuardSlot(t) ==
    IF \E i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    THEN CHOOSE i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    ELSE 0

\* The default "empty" guard record
EmptyGuard == [addr |-> NullPtr, gen |-> 0,
               viaNode |-> NoneGid, viaSlot |-> 0, hasDebt |-> FALSE]

\* Check no guard anywhere references a freed address
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

    \* Nodes: each thread t starts with node t already claimed (matches `THREAD_HEAD`
    \* lazy-init in list.rs:336 — we treat the thread as having claimed at startup).
    /\ nodeState     = [t \in Thread |-> NODE_USED]
    /\ nodeOwner     = [t \in Thread |-> t]
    /\ activeWriters = [t \in Thread |-> 0]
    /\ helpGen       = [t \in Thread |-> 0]

    /\ fastSlot       = [t \in Thread |-> [s \in FastSlotIx |-> NullPtr]]
    /\ helpSlot       = [t \in Thread |-> NullPtr]
    /\ helpControl    = [t \in Thread |-> CTRL_IDLE]
    /\ helpControlGen = [t \in Thread |-> 0]
    /\ helpActiveAddr = [t \in Thread |-> 0]
    /\ helpReplAddr   = [t \in Thread |-> NullPtr]

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

    /\ wPC            = [t \in Thread |-> "w_idle"]
    /\ wOldAddr       = [t \in Thread |-> NullPtr]
    /\ wOldGen        = [t \in Thread |-> 0]
    /\ wToVisit       = [t \in Thread |-> {}]
    /\ wCurNode       = [t \in Thread |-> NoneGid]
    /\ wScanned       = [t \in Thread |-> {}]
    /\ wScanRemaining = [t \in Thread |-> {}]

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
\* Reader: Fast Path  (strategy/hybrid.rs:42-67)
\* ===================================================================================

\* hybrid.rs:44 — let ptr = storage.load(Relaxed).
\* Relaxed by design (paired with the SeqCst confirm at line 51). We model the
\* read as observing the *current* storage value here — at this site we never
\* relax, since the implementation does not require synchronization yet.
ReaderFastLoad(t) ==
    /\ ~arcSwapDropped
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"                   \* same thread can't read+write
    /\ nodeState[t] = NODE_USED            \* list.rs:271 (debug_assert)
    /\ rOpAddr' = [rOpAddr EXCEPT ![t] = storageAddr]
    /\ rPC'     = [rPC     EXCEPT ![t] = "r_fast_after_load"]
    /\ rPath'   = [rPath   EXCEPT ![t] = "fast"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, rConfirmAddr, rConfirmGen,
                   rGenTagged, rDebtNode, rDebtSlot, rGotEnvelope, rEnvelopeAddr,
                   writerVars, casVars, clientVars, mcVars>>

\* hybrid.rs:46 — node.new_fast(ptr) — fast.rs:43-65.
\* fast.rs:54 Relaxed load + fast.rs:58 SeqCst swap. Implementation iterates slots
\* and, for the first NONE slot, swaps in the address. We model the slot choice as
\* a non-deterministic free slot.
ReaderFastSlotAcquire(t) ==
    /\ rPC[t] = "r_fast_after_load"
    /\ \E s \in FastSlotIx :
        /\ fastSlot[t][s] = NullPtr        \* fast.rs:54
        \* fast.rs:58 — swap is SeqCst unless the adversary downgraded it.
        /\ fastSlot' = [fastSlot EXCEPT ![t][s] = rOpAddr[t]]
        /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = s]
        /\ rDebtNode' = [rDebtNode EXCEPT ![t] = t]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fast_after_slot"]
    /\ UNCHANGED <<allocVars, nodeVars, helpSlot, helpControl, helpControlGen,
                   helpActiveAddr, helpReplAddr, rOpAddr, rConfirmAddr, rConfirmGen,
                   rGenTagged, rPath, rGotEnvelope, rEnvelopeAddr, writerVars,
                   casVars, clientVars, mcVars>>

\* hybrid.rs:51 — let confirm = storage.load(SeqCst).
\* Family A site "FastConfirmLoad". When SC: must observe a value consistent with
\* writer's SeqCst storage.swap. When relaxed (adversary): may return any prior /
\* freed pointer (over-approximation per concurrent-analysis §5.5).
ReaderFastConfirmLoad(t) ==
    /\ rPC[t] = "r_fast_after_slot"
    /\ \E observed \in (IF IsSC("FastConfirmLoad")
                        THEN {storageAddr}                \* SC: see most recent swap
                        ELSE EverAllocated \cup {storageAddr}) :
        LET observedGen ==
              IF observed = storageAddr THEN storageGen ELSE addrGen[observed]
        IN  /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = observed]
            /\ rConfirmGen'  = [rConfirmGen  EXCEPT ![t] = observedGen]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fast_after_confirm"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, rOpAddr, rGenTagged, rDebtNode,
                   rDebtSlot, rGotEnvelope, rEnvelopeAddr, rPath, writerVars, casVars,
                   clientVars, mcVars>>

\* hybrid.rs:52 — branch on ptr == confirm.
\* Success path (line 53-57): create guard from `confirm` (uses confirm, NOT ptr,
\* since the address may be reused with different provenance — Family B fix 63fa111).
ReaderFastBranchHit(t) ==
    /\ rPC[t] = "r_fast_after_confirm"
    /\ rOpAddr[t] = rConfirmAddr[t]
    \* Allocate a guard slot — ClientHarness side effect (Family C: enables Send/Drop)
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
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, rGenTagged, rGotEnvelope,
                   rEnvelopeAddr, writerVars, casVars, mcVars>>

\* hybrid.rs:58 — debt.pay::<T>(ptr).  CAS slot from `ptr` to NONE.
\*   debt/mod.rs:65-79 — Debt::pay (success leg AcqRel; failure leg Acquire).
\* Success: returns None (line 60), debt was on outdated ptr — caller will retry/fallback.
\* Failure: writer already paid; we hold a free Arc ref (line 64-65, "Some(...)").
ReaderFastResolve(t) ==
    /\ rPC[t] = "r_fast_after_confirm"
    /\ rOpAddr[t] # rConfirmAddr[t]
    /\ \/ \* CAS succeeds — we paid our own debt (debt/mod.rs:77 success leg)
          /\ fastSlot[t][rDebtSlot[t]] = rOpAddr[t]
          /\ fastSlot' = [fastSlot EXCEPT ![t][rDebtSlot[t]] = NullPtr]
          \* Reset and try again from idle (caller falls back per hybrid.rs:60-61)
          /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
          /\ rPath' = [rPath EXCEPT ![t] = "none"]
          /\ UNCHANGED <<guards, refCount>>
       \/ \* CAS fails — writer paid for us (debt/mod.rs:77 failure Acquire leg).
          \* Writer's `slot.pay` did `T::inc` (debt/mod.rs:107) — we now own a ref.
          /\ fastSlot[t][rDebtSlot[t]] # rOpAddr[t]
          \* Allocate a guard with no debt (we own a strong ref outright).
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
                   rGenTagged, rGotEnvelope, rEnvelopeAddr, writerVars, casVars, mcVars>>

\* ===================================================================================
\* Reader: Fallback / Helping Path  (strategy/hybrid.rs:70-98 + helping.rs:186-333)
\* ===================================================================================

\* hybrid.rs:73 -> helping.rs:191-213 (`get_debt`).  Two atomic ops:
\*  (1) helping.rs:203 — active_addr.store(SeqCst)
\*  (2) helping.rs:209 — control.swap(gen, SeqCst)
\* We split each as a separate action.

\* helping.rs:203 — active_addr.store(ptr, SeqCst). Also: helping.rs:191-198 prepares
\* `gen = local.gen + 4` and sets `discard = (gen == 0)`.
ReaderFallbackActiveAddr(t) ==
    /\ ~arcSwapDropped
    /\ rPC[t] = "r_idle"
    /\ wPC[t] = "w_idle"
    /\ nodeState[t] = NODE_USED
    \* All fast slots full, so we fall back (hybrid.rs:196-197).
    /\ \A s \in FastSlotIx : fastSlot[t][s] # NullPtr
    /\ helpSlot[t] = NullPtr               \* helping slot must be free
    /\ helpControl[t] = CTRL_IDLE
    /\ helpActiveAddr' = [helpActiveAddr EXCEPT ![t] = 1]   \* abstract storage_addr
    \* Note: helpGen incremented in next step (we group with control.swap)
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_active_addr"]
    /\ rPath' = [rPath EXCEPT ![t] = "fallback"]
    /\ UNCHANGED <<allocVars, nodeState, nodeOwner, activeWriters, helpGen,
                   fastSlot, helpSlot, helpControl, helpControlGen, helpReplAddr,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, writerVars, casVars, clientVars, mcVars>>

\* helping.rs:191-213 — gen wrapping_add(4) + control.swap(gen, SeqCst).
\* When gen wraps to 0, set discard=TRUE and start_cooldown is invoked
\* (list.rs:282-286 in `LocalNode::new_helping`).
\* This is Family D: generation wrap → cooldown.
ReaderFallbackControlSwap(t) ==
    /\ rPC[t] = "r_fb_after_active_addr"
    /\ LET newGen == (helpGen[t] + 4) % (MaxHelpGen + 1)
           wrapped == newGen = 0
       IN  /\ helpGen' = [helpGen EXCEPT ![t] = newGen]
           /\ helpControl' = [helpControl EXCEPT ![t] = CTRL_GEN]
           /\ helpControlGen' = [helpControlGen EXCEPT ![t] = newGen]
           /\ rGenTagged' = [rGenTagged EXCEPT ![t] = newGen]
           /\ IF wrapped
              THEN /\ nodeState' = [nodeState EXCEPT ![t] = NODE_COOLDOWN]
                   /\ nodeOwner' = [nodeOwner EXCEPT ![t] = NoneGid]
                   \* list.rs:115-120 — start_cooldown's `let _reservation = reserve_writer();`
                   \* increments active_writers but the NodeReservation drops at end of scope,
                   \* decrementing it back. Net change is zero; modeled as UNCHANGED.
                   /\ UNCHANGED activeWriters
              ELSE UNCHANGED <<nodeState, nodeOwner, activeWriters>>
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_ctrl_gen"]
    /\ UNCHANGED <<allocVars, fastSlot, helpSlot, helpActiveAddr, helpReplAddr,
                   rOpAddr, rConfirmAddr, rConfirmGen, rDebtNode, rDebtSlot,
                   rGotEnvelope, rEnvelopeAddr, rPath, writerVars, casVars, clientVars,
                   mcVars>>

\* hybrid.rs:78 — let candidate = storage.load(SeqCst).  Family A site "FallbackLoad".
\* This is the load that, before commit d5dd00c, was Acquire and caused the #198 UAF.
ReaderFallbackCandidate(t) ==
    /\ rPC[t] = "r_fb_after_ctrl_gen"
    /\ \E observed \in (IF IsSC("FallbackLoad")
                        THEN {storageAddr}
                        ELSE EverAllocated \cup {storageAddr}) :
        LET oGen == IF observed = storageAddr THEN storageGen ELSE addrGen[observed]
        IN  /\ rConfirmAddr' = [rConfirmAddr EXCEPT ![t] = observed]
            /\ rConfirmGen'  = [rConfirmGen  EXCEPT ![t] = oGen]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_candidate"]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, rOpAddr, rGenTagged, rDebtNode,
                   rDebtSlot, rGotEnvelope, rEnvelopeAddr, rPath, writerVars, casVars,
                   clientVars, mcVars>>

\* hybrid.rs:82 -> helping.rs:308-333 (`confirm_helping`).
\*  (1) helping.rs:312 — slot.swap(ptr, SeqCst)
\*  (2) helping.rs:317 — control.swap(IDLE, SeqCst)
ReaderFallbackSlotStore(t) ==
    /\ rPC[t] = "r_fb_after_candidate"
    /\ helpSlot' = [helpSlot EXCEPT ![t] = rConfirmAddr[t]]
    /\ rDebtNode' = [rDebtNode EXCEPT ![t] = t]
    /\ rDebtSlot' = [rDebtSlot EXCEPT ![t] = HelpSlotIx]
    /\ rPC' = [rPC EXCEPT ![t] = "r_fb_after_slot"]
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpControl, helpControlGen,
                   helpActiveAddr, helpReplAddr, rOpAddr, rConfirmAddr, rConfirmGen,
                   rGenTagged, rGotEnvelope, rEnvelopeAddr, rPath, writerVars, casVars,
                   clientVars, mcVars>>

\* helping.rs:317 — control.swap(IDLE, SeqCst).  Family A site "ConfirmHelping".
\* Two cases get separate actions: success (prev==gen) and helped (prev==REPL).

\* Success: control still held our generation tag — slot debt is confirmed real
\*   (helping.rs:318-320, hybrid.rs:84-86).
ReaderFallbackConfirmOK(t) ==
    /\ rPC[t] = "r_fb_after_slot"
    /\ helpControl[t] = CTRL_GEN
    /\ helpControlGen[t] = rGenTagged[t]
    /\ FreeGuardSlot(t) # 0
    /\ helpControl'    = [helpControl    EXCEPT ![t] = CTRL_IDLE]
    /\ helpControlGen' = [helpControlGen EXCEPT ![t] = 0]
    /\ LET gi == FreeGuardSlot(t) IN
        guards' = [guards EXCEPT ![t][gi] =
                    [addr |-> rConfirmAddr[t], gen |-> rConfirmGen[t],
                     viaNode |-> t, viaSlot |-> HelpSlotIx,
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
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpSlot, helpActiveAddr,
                   helpReplAddr, writerVars, casVars, mcVars>>

\* Helped: writer beat reader to the slot, placed a replacement envelope
\*   (helping.rs:321-332).  This sets `rGotEnvelope=TRUE` for the next action,
\*   which performs the cleanup at hybrid.rs:88-95.
ReaderFallbackConfirmHelped(t) ==
    /\ rPC[t] = "r_fb_after_slot"
    /\ helpControl[t] = CTRL_REPL
    /\ helpControl'    = [helpControl    EXCEPT ![t] = CTRL_IDLE]
    /\ helpControlGen' = [helpControlGen EXCEPT ![t] = 0]
    /\ rGotEnvelope'   = [rGotEnvelope   EXCEPT ![t] = TRUE]
    /\ rEnvelopeAddr'  = [rEnvelopeAddr  EXCEPT ![t] = helpReplAddr[t]]
    /\ rPC' = [rPC EXCEPT ![t] = "r_drop_paying"]
    /\ UNCHANGED <<allocVars, nodeVars, fastSlot, helpSlot, helpActiveAddr,
                   helpReplAddr, rPath, rOpAddr, rConfirmAddr, rConfirmGen,
                   rGenTagged, rDebtNode, rDebtSlot, writerVars, casVars,
                   clientVars, mcVars>>

\* hybrid.rs:88-95 — when confirm_helping returned Err: pay back the unused debt
\* on the candidate; if the pay fails (writer paid first), T::dec. Then create
\* a Guard for the replacement (no debt).
ReaderFallbackResolveEnvelope(t) ==
    /\ rPC[t] = "r_drop_paying"
    /\ rGotEnvelope[t]
    /\ FreeGuardSlot(t) # 0
    /\ \/ \* paid_back: helpSlot still held candidate; clear it
          /\ helpSlot[t] = rConfirmAddr[t]
          /\ helpSlot' = [helpSlot EXCEPT ![t] = NullPtr]
          /\ UNCHANGED refCount
       \/ \* writer paid first: dec the candidate's refcount (hybrid.rs:91)
          /\ helpSlot[t] # rConfirmAddr[t]
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
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, fastSlot,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   writerVars, casVars, mcVars>>

\* ===================================================================================
\* Guard / ClientHarness (Family C — modeling-brief.md §2 C, brief §4 ClientHarness)
\* ===================================================================================

\* lib.rs:191 + hybrid.rs:138-158 — Guard::into_inner.
\* If the guard had a debt: T::inc + try Debt::pay; if pay fails T::dec; the user
\* now owns a fully-loaded T (no debt slot held).  We just convert: drop the guard
\* (the user's bare Arc is bookkept by refCount).
\* We model the resulting Arc as remaining "in user space" via a guard with
\* hasDebt=FALSE (acts as a strong ref that doesn't tie up a slot).
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
            \/ \* pay fails — writer already paid; T::inc happened, then T::dec
               \* (hybrid.rs:146-149): net change zero. Caller has the bare Arc.
               /\ SlotValue(g.viaNode, g.viaSlot) # g.addr
               /\ guards' = [guards EXCEPT ![t][gi] =
                               [addr |-> g.addr, gen |-> g.gen,
                                viaNode |-> NoneGid, viaSlot |-> 0,
                                hasDebt |-> FALSE]]
               /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   readerVars, writerVars, casVars, mcVars>>

\* lib.rs C9 — Send Guard between threads.  The guard is just a wrapper around a
\* &'static Debt slot, so it is Send.  Move ownership; no atomic op happens here —
\* this is a pure scheduler/program decision (debt slot identity is unchanged).
SendGuard(src, dst) ==
    /\ src # dst
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[src][gi].addr # NullPtr
        /\ FreeGuardSlot(dst) # 0
        /\ LET dgi == FreeGuardSlot(dst) IN
            /\ guards' = [guards EXCEPT
                            ![src][gi] = EmptyGuard,
                            ![dst][dgi] = guards[src][gi]]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, readerVars, writerVars, casVars,
                   mcVars>>

\* hybrid.rs:106-127 + lib.rs Drop — drop a Guard.
\*  - if guard had debt: try Debt::pay; on success debt cleared; on failure T::dec.
\*  - if no debt: T::dec (we owned a strong ref).
DropGuard(t) ==
    /\ \E gi \in 1..MaxGuardsPerThread :
        /\ guards[t][gi].addr # NullPtr
        /\ LET g == guards[t][gi] IN
            \/ \* hasDebt branch — hybrid.rs:114-122
               /\ g.hasDebt
               /\ \/ \* pay succeeds (debt/mod.rs:77 success leg = AcqRel)
                     /\ SlotValue(g.viaNode, g.viaSlot) = g.addr
                     /\ IF g.viaSlot = HelpSlotIx
                        THEN /\ helpSlot' = [helpSlot EXCEPT ![g.viaNode] = NullPtr]
                             /\ UNCHANGED fastSlot
                        ELSE /\ fastSlot' = [fastSlot EXCEPT ![g.viaNode][g.viaSlot] = NullPtr]
                             /\ UNCHANGED helpSlot
                     /\ UNCHANGED refCount
                  \/ \* pay fails — writer paid; T::dec (hybrid.rs:124)
                     /\ SlotValue(g.viaNode, g.viaSlot) # g.addr
                     /\ refCount' = [refCount EXCEPT ![g.addr] = @ - 1]
                     /\ UNCHANGED <<fastSlot, helpSlot>>
            \/ \* no debt — hybrid.rs:109-111,124 — just T::dec
               /\ ~g.hasDebt
               /\ refCount' = [refCount EXCEPT ![g.addr] = @ - 1]
               /\ UNCHANGED <<fastSlot, helpSlot>>
            /\ guards' = [guards EXCEPT ![t][gi] = EmptyGuard]
    \* If refcount reached 0 the address is freed
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   readerVars, writerVars, casVars, mcVars>>

\* ===================================================================================
\* Writer: swap + pay_all (hybrid.rs:200-208 + debt/mod.rs:82-115 + debt/list.rs)
\* ===================================================================================

\* lib.rs:483 — let old = self.ptr.swap(new, SeqCst).
\* Family A site "WriterSwap".  Adversary cannot relax this without breaking
\* fundamental assumptions (we only model relaxing reader-side here), but we keep
\* it as a labelled site for symmetry.
WriterSwap(t) ==
    /\ ~arcSwapDropped
    /\ wPC[t] = "w_idle"
    /\ rPC[t] = "r_idle"
    /\ \E newAddr \in Addr :
        /\ ~addrAlive[newAddr]                          \* must allocate
        /\ newAddr # storageAddr
        /\ addrAlive' = [addrAlive EXCEPT ![newAddr] = TRUE]
        /\ addrGen'   = [addrGen EXCEPT ![newAddr] = @ + 1]
        /\ refCount'  = [refCount EXCEPT ![newAddr] = 1]
        /\ wOldAddr'  = [wOldAddr EXCEPT ![t] = storageAddr]
        /\ wOldGen'   = [wOldGen  EXCEPT ![t] = storageGen]
        /\ storageAddr' = newAddr
        /\ storageGen'  = addrGen'[newAddr]
    /\ wPC' = [wPC EXCEPT ![t] = "w_after_swap"]
    /\ UNCHANGED <<nodeVars, slotVars, readerVars, wToVisit, wCurNode,
                   wScanned, wScanRemaining, casVars, clientVars, mcVars>>

\* debt/mod.rs:88-90 — `let val = T::from_ptr(ptr); T::inc(&val);`
\* The first creates a "borrow" that we represent as the kept ref; T::inc adds
\* a pre-pay ref count for the first slot we'll find with this ptr.
WriterPayInit(t) ==
    /\ wPC[t] = "w_after_swap"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ + 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_pay_init"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars, slotVars,
                   readerVars, wOldAddr, wOldGen, wToVisit, wCurNode, wScanned,
                   wScanRemaining, casVars, clientVars, mcVars>>

\* debt/list.rs:101 — LIST_HEAD.load(SeqCst).  Family A site "ListHeadLoad".
\* Snapshot the set of USED nodes the writer will visit.  Family A: when this
\* site is downgraded, the writer may snapshot only a subset of nodes — modeling
\* the #164-style stale read of LIST_HEAD that misses freshly-prepended nodes.
WriterTraverseLoad(t) ==
    /\ wPC[t] = "w_pay_init"
    \* debt/list.rs:93-112 — Node::traverse walks the WHOLE linked list, regardless
    \* of each node's in_use state.  Nodes are never freed (list.rs:6-9), so the
    \* writer's pay_all closure scans every node — including UNUSED ones (which
    \* simply have NULL slots).  Filtering by nodeState here would let a
    \* freshly-cooled-down node (whose slots may still hold reader debts) escape
    \* the scan, producing a false UAF in the spec.
    /\ LET livenodes == Thread IN
        \/ \* SC: snapshot is exactly the live set
           /\ IsSC("ListHeadLoad")
           /\ wToVisit' = [wToVisit EXCEPT ![t] = livenodes]
        \/ \* Family A relaxation: stale snapshot — may miss recently-prepended nodes
           /\ ~IsSC("ListHeadLoad")
           /\ \E sub \in SUBSET livenodes :
                wToVisit' = [wToVisit EXCEPT ![t] = sub]
    /\ wPC' = [wPC EXCEPT ![t] = "w_traverse_loaded"]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount, nodeVars,
                   slotVars, readerVars, wOldAddr, wOldGen, wScanned, wScanRemaining,
                   casVars, clientVars, mcVars>>

\* debt/mod.rs:93-94 + list.rs:142-145 — `let _reservation = node.reserve_writer();`
\* active_writers.fetch_add(1, Acquire).  Pick any node from the snapshot.
WriterReserveNode(t) ==
    /\ wPC[t] = "w_traverse_loaded"
    /\ wToVisit[t] # {}
    /\ \E node \in wToVisit[t] :
        /\ wCurNode' = [wCurNode EXCEPT ![t] = node]
        /\ activeWriters' = [activeWriters EXCEPT ![node] = @ + 1]
        /\ wScanRemaining' = [wScanRemaining EXCEPT ![t] =
                                {<<node, s>> : s \in SlotIx}]
    /\ wPC' = [wPC EXCEPT ![t] = "w_node_reserved"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount, nodeState,
                   nodeOwner, helpGen, slotVars, readerVars, wOldAddr, wOldGen,
                   wToVisit, wScanned, casVars, clientVars, mcVars>>

\* debt/mod.rs:96 — local.help(node, storage_addr, &replacement).
\* helping.rs:215-302.  When the visited node has CTRL_GEN matching this writer's
\* storage_addr, the writer can offer a fresh replacement Arc (full load) and
\* CAS the control to CTRL_REPL.  We model the helping outcome non-deterministically
\* but faithfully: either writer succeeds in placing an envelope (control becomes
\* CTRL_REPL with a fresh, ref-counted addr), or no help happens.
WriterHelpNode(t) ==
    /\ wPC[t] = "w_node_reserved"
    /\ wCurNode[t] # NoneGid
    /\ \/ \* No-help branch: control IDLE/REPL or different addr or self-node
          /\ \/ helpControl[wCurNode[t]] # CTRL_GEN
             \/ helpActiveAddr[wCurNode[t]] = 0
             \/ wCurNode[t] = t      \* helping.rs:230-234 "Refusing to help myself"
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
                   fastSlot, helpSlot, helpActiveAddr,
                   readerVars, wOldAddr, wOldGen, wToVisit, wCurNode,
                   wScanned, wScanRemaining, casVars, clientVars, mcVars>>

\* debt/mod.rs:101-109 — for slot in all_slots { if slot.pay::<T>(ptr) { T::inc(&val) } }.
\* Per-slot CAS at debt/mod.rs:105 (debt/mod.rs:77 internally — AcqRel/Acquire).
\* Family A: "DebtPaySuccess" / "DebtPayFailure" sites — adversary can downgrade
\*   the success leg from AcqRel to Release (#204) or the failure leg from Acquire
\*   to Relaxed (PR #195).
\* Family E: split per-slot so that an interleaved fresh debt by another reader
\*   AFTER this writer's snapshot remains observable.
WriterScanSlot(t) ==
    /\ wPC[t] = "w_after_help"
    /\ wScanRemaining[t] # {}
    /\ \E pos \in wScanRemaining[t] :
        LET node == pos[1]
            slot == pos[2]
            slotVal == SlotValue(node, slot)
        IN  /\ \/ \* CAS hits — slot held wOldAddr[t]
                  /\ slotVal = wOldAddr[t]
                  /\ IF slot = HelpSlotIx
                     THEN /\ helpSlot' = [helpSlot EXCEPT ![node] = NullPtr]
                          /\ UNCHANGED fastSlot
                     ELSE /\ fastSlot' = [fastSlot EXCEPT ![node][slot] = NullPtr]
                          /\ UNCHANGED helpSlot
                  /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ + 1]
                                  \* T::inc — pre-pay (debt/mod.rs:107)
               \/ \* CAS misses — slot held something else
                  /\ slotVal # wOldAddr[t]
                  /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
               \/ \* Family A relaxation: success-leg downgrade can cause writer
                  \* to MISS a debt that was published with full SC by reader
                  \* (modeling as: even though slot=wOldAddr, writer may not see it).
                  /\ ~IsSC("DebtPaySuccess")
                  /\ slotVal = wOldAddr[t]
                  /\ UNCHANGED <<fastSlot, helpSlot, refCount>>
            /\ wScanned' = [wScanned EXCEPT ![t] = @ \cup {pos}]
            /\ wScanRemaining' = [wScanRemaining EXCEPT ![t] = @ \ {pos}]
            /\ wPC' = [wPC EXCEPT ![t] = "w_after_help"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars,
                   helpControl, helpControlGen, helpActiveAddr, helpReplAddr,
                   readerVars, wOldAddr, wOldGen, wToVisit, wCurNode,
                   casVars, clientVars, mcVars>>

\* list.rs:55-58 — `Drop for NodeReservation` runs (active_writers.fetch_sub(1, Release)).
WriterReleaseNode(t) ==
    /\ wPC[t] = "w_after_help"
    /\ wScanRemaining[t] = {}
    /\ wCurNode[t] # NoneGid
    /\ activeWriters' = [activeWriters EXCEPT ![wCurNode[t]] = @ - 1]
    /\ wToVisit' = [wToVisit EXCEPT ![t] = @ \ {wCurNode[t]}]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ wPC' = IF wToVisit[t] \ {wCurNode[t]} = {}
              THEN [wPC EXCEPT ![t] = "w_pay_done"]
              ELSE [wPC EXCEPT ![t] = "w_traverse_loaded"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, refCount, nodeState,
                   nodeOwner, helpGen, slotVars, readerVars, wOldAddr, wOldGen,
                   wScanned, wScanRemaining, casVars, clientVars, mcVars>>

\* debt/mod.rs:113 — implicit T::dec when val drops at end of pay_all closure.
WriterPayDone(t) ==
    /\ wPC[t] = "w_pay_done"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ - 1]
    /\ wPC' = [wPC EXCEPT ![t] = "w_returning"]
    /\ UNCHANGED <<storageAddr, storageGen, addrAlive, addrGen, nodeVars, slotVars,
                   readerVars, wOldAddr, wOldGen, wToVisit, wCurNode, wScanned,
                   wScanRemaining, casVars, clientVars, mcVars>>

\* lib.rs:486-487 — caller receives old Arc, drops it at end of swap().
WriterReturn(t) ==
    /\ wPC[t] = "w_returning"
    /\ refCount' = [refCount EXCEPT ![wOldAddr[t]] = @ - 1]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ wPC' = [wPC EXCEPT ![t] = "w_idle"]
    /\ wOldAddr' = [wOldAddr EXCEPT ![t] = NullPtr]
    /\ wOldGen' = [wOldGen EXCEPT ![t] = 0]
    /\ wToVisit' = [wToVisit EXCEPT ![t] = {}]
    /\ wCurNode' = [wCurNode EXCEPT ![t] = NoneGid]
    /\ wScanned' = [wScanned EXCEPT ![t] = {}]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, slotVars, readerVars,
                   wScanRemaining, casVars, clientVars, mcVars>>

\* ===================================================================================
\* CompareAndSwap (Family C — strategy/hybrid.rs:217-237 + lib.rs:506-513)
\* ===================================================================================
\* Loop:
\*   1. old = load(self)
\*   2. if old.as_ptr() != current.as_raw(): return old
\*   3. compare_exchange_weak(current.as_raw(), new_raw, SeqCst, Relaxed)
\*   4. on success: T::into_ptr(new); wait_for_readers(old); T::dec(old)
\* For brevity we model the load step as picking a current snapshot (the inner
\* load does its own protocol); we keep the raw-pointer hazard on `current`.

\* Caller pre-creates an Arc before the call: addr becomes alive, refCount=1
\* (the caller's Arc).  If CAS succeeds, this ref transfers to storage; if it
\* fails, the caller's Arc is dropped (refCount-- → free).
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
                                IF kind \in {CAS_KIND_RAWSTALE} THEN curGen
                                ELSE addrGen'[curAddr]]
            /\ casNewAddr' = [casNewAddr EXCEPT ![t] = newAddr]
            /\ casNewGen'  = [casNewGen  EXCEPT ![t] = addrGen'[newAddr]]
        /\ casOldAddr' = [casOldAddr EXCEPT ![t] = storageAddr]
        /\ casOldGen'  = [casOldGen  EXCEPT ![t] = storageGen]
    /\ rPC' = [rPC EXCEPT ![t] = "cas_after_load"]
    /\ rPath' = [rPath EXCEPT ![t] = "cas"]
    /\ UNCHANGED <<storageAddr, storageGen, nodeVars, slotVars, rOpAddr, rConfirmAddr,
                   rConfirmGen, rGenTagged, rDebtNode, rDebtSlot, rGotEnvelope,
                   rEnvelopeAddr, writerVars, clientVars, mcVars>>

\* hybrid.rs:220-221 — if old.as_ptr() != current.as_raw() return old.  No swap.
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
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode,
                   rDebtSlot, rGotEnvelope, rEnvelopeAddr, writerVars,
                   clientVars, mcVars>>

\* hybrid.rs:225-228 — compare_exchange_weak(current, new, SeqCst, Relaxed).
\* On success: caller's new-Arc ref is moved into storage; old comes back.
\* Then we proceed into the writer's pay_all state machine for the old.
CASExchangeOk(t) ==
    /\ rPC[t] = "cas_after_load"
    /\ casOldAddr[t] = casCurAddr[t]
    /\ storageAddr = casCurAddr[t]
    \* ABA hazard: RAWSTALE means caller had stale generation but address still
    \* equals storage's current address — CAS reports success spuriously.
    \* For Arc/Guard/RAWFRESH, gen-equality must hold.
    /\ casKind[t] = CAS_KIND_RAWSTALE \/ casCurGen[t] = storageGen
    \* Move caller's pre-existing Arc into storage; refCount unchanged on new.
    /\ storageAddr' = casNewAddr[t]
    /\ storageGen'  = casNewGen[t]
    /\ wOldAddr' = [wOldAddr EXCEPT ![t] = casOldAddr[t]]
    /\ wOldGen' = [wOldGen EXCEPT ![t] = casOldGen[t]]
    \* Hand off to the writer pay_all state machine
    /\ rPC' = [rPC EXCEPT ![t] = "r_idle"]
    /\ rPath' = [rPath EXCEPT ![t] = "none"]
    /\ wPC' = [wPC EXCEPT ![t] = "w_after_swap"]
    /\ UNCHANGED <<addrAlive, addrGen, refCount, nodeVars, slotVars,
                   rOpAddr, rConfirmAddr, rConfirmGen, rGenTagged, rDebtNode,
                   rDebtSlot, rGotEnvelope, rEnvelopeAddr,
                   wToVisit, wCurNode, wScanned, wScanRemaining, casVars,
                   clientVars, mcVars>>

\* hybrid.rs:225-228 failure leg — current was no longer in storage; retry the
\* loop after re-loading.  No state change yet; the next iteration's "old =
\* load" picks up storageAddr, then if `casCurAddr` no longer matches the new
\* loaded value, CASCompareNotEqual will return the loaded value as `old`.
CASExchangeFail(t) ==
    /\ rPC[t] = "cas_after_load"
    /\ casOldAddr[t] = casCurAddr[t]
    /\ storageAddr # casCurAddr[t]
    \* Re-load and retry — update casOldAddr to current
    /\ casOldAddr' = [casOldAddr EXCEPT ![t] = storageAddr]
    /\ casOldGen' = [casOldGen EXCEPT ![t] = storageGen]
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, rPC, rOpAddr, rConfirmAddr,
                   rConfirmGen, rGenTagged, rDebtNode, rDebtSlot, rGotEnvelope,
                   rEnvelopeAddr, rPath, writerVars, casKind, casCurAddr, casCurGen,
                   casNewAddr, casNewGen, clientVars, mcVars>>


\* ===================================================================================
\* Family D — Cooldown state machine (debt/list.rs:113-145)
\* ===================================================================================

\* list.rs:123-138 — check_cooldown.  When in COOLDOWN with active_writers=0,
\* CAS COOLDOWN -> UNUSED (Relaxed).  This is the release point.
CheckCooldown(n) ==
    /\ nodeState[n] = NODE_COOLDOWN
    /\ activeWriters[n] = 0
    /\ nodeState' = [nodeState EXCEPT ![n] = NODE_UNUSED]
    /\ UNCHANGED <<allocVars, nodeOwner, activeWriters, helpGen, slotVars,
                   readerVars, writerVars, casVars, clientVars, mcVars>>

\* list.rs:147-194 — Node::get.  Some other thread (or the original) may claim
\* the unused node.  CAS UNUSED -> USED (SeqCst).
ClaimNode(t, n) ==
    /\ nodeState[n] = NODE_UNUSED
    /\ nodeOwner[n] = NoneGid
    /\ nodeState' = [nodeState EXCEPT ![n] = NODE_USED]
    /\ nodeOwner' = [nodeOwner EXCEPT ![n] = t]
    /\ helpGen' = [helpGen EXCEPT ![n] = 0]
    \* Slots remain (per debt/list.rs:6-9 — nodes are never freed; per-slot data
    \* persists across owners, but new owner's first reservation will overwrite).
    /\ UNCHANGED <<allocVars, activeWriters, slotVars, readerVars, writerVars,
                   casVars, clientVars, mcVars>>

\* ===================================================================================
\* Family A — adversarial caller relaxation (MCRelaxOrdering)
\* ===================================================================================
\* The *base* spec exposes the relaxation as a one-shot non-deterministic choice
\* to pick exactly one site to downgrade.  The MC layer counter-bounds this so it
\* may pick at most one site per execution.
\*
\* Picking NoneSite means "execute as written" (SC labels respected).
PickRelaxSite(s) ==
    /\ relaxSite = NoneSite                  \* one-shot
    /\ s \in RelaxSites
    /\ relaxSite' = s
    /\ UNCHANGED <<allocVars, nodeVars, slotVars, readerVars, writerVars, casVars,
                   clientVars, arcSwapDropped>>

\* ===================================================================================
\* Family C — DropArcSwap (caller-precondition hazard, brief §2 C4)
\* ===================================================================================
\* lib.rs:337-347.  Caller drops the ArcSwap object while readers may still be
\* holding pointers.  Documented requirement: caller has unique &mut self, so all
\* loads on this object must already have started/finished.  We model the action
\* but invariant DropOK rejects traces where any reader is mid-load on this object.
DropArcSwap ==
    /\ ~arcSwapDropped
    \* Caller precondition (lib.rs:337-347): &mut self requires no concurrent users.
    \* We enforce it as an action guard; the MC12 check (brief §6.1) verifies that
    \* no reachable state ever has a guard pointing to a dropped allocation.
    /\ \A t \in Thread :
        /\ rPC[t] = "r_idle"
        /\ wPC[t] = "w_idle"
        /\ \A i \in 1..MaxGuardsPerThread : guards[t][i].addr = NullPtr
    /\ arcSwapDropped' = TRUE
    /\ refCount' = [refCount EXCEPT ![storageAddr] = @ - 1]
    /\ addrAlive' = [a \in Addr |-> IF refCount'[a] = 0 THEN FALSE ELSE addrAlive[a]]
    /\ UNCHANGED <<storageAddr, storageGen, addrGen, nodeVars, slotVars, readerVars,
                   writerVars, casVars, clientVars, relaxSite>>

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
        \* Reader fallback path
        \/ ReaderFallbackActiveAddr(t)
        \/ ReaderFallbackControlSwap(t)
        \/ ReaderFallbackCandidate(t)
        \/ ReaderFallbackSlotStore(t)
        \/ ReaderFallbackConfirmOK(t)
        \/ ReaderFallbackConfirmHelped(t)
        \/ ReaderFallbackResolveEnvelope(t)
        \* Guard / client harness
        \/ GuardIntoInner(t)
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
        \* CAS
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
    /\ helpGen     \in [Thread -> 0..MaxHelpGen]
    /\ fastSlot    \in [Thread -> [FastSlotIx -> AllAddr]]
    /\ helpSlot    \in [Thread -> AllAddr]
    /\ helpControl \in [Thread -> {CTRL_IDLE, CTRL_GEN, CTRL_REPL}]
    /\ rPC         \in [Thread -> RPhases]
    /\ wPC         \in [Thread -> WPhases]
    /\ relaxSite   \in RelaxSites \cup {NoneSite}
    /\ arcSwapDropped \in BOOLEAN

\* ===================================================================================
\* Safety Invariants
\* ===================================================================================

\* Family A/B/C/E: No Guard references a freed pointer.  This is the headline UAF
\* invariant per modeling-brief.md §5 ("No Guard's underlying Arc has refcount 0").
\* Slot values themselves are not refs — they are CAS targets in the debt protocol,
\* never dereferenced by readers.  A slot may transiently hold a wOldAddr that has
\* already been freed (writer's pay_all finished without scanning the slot because
\* the reader had not yet acquired it); the next SC confirm load + Resolve CAS
\* will clear the stale entry without ever dereferencing it.  PayAllCompleteness
\* covers the "writer returned with debts unpaid" case at the slot level.
NoUseAfterFree == NoStaleGuard

\* Family A/E (PayAllCompleteness): once writer finishes pay_all (w_returning),
\* no slot anywhere should hold the old pointer.  Bug #76 violated this.
PayAllCompleteness ==
    \A t \in Thread :
        wPC[t] = "w_returning" =>
            \A pos \in Thread \X SlotIx :
                SlotValue(pos[1], pos[2]) # wOldAddr[t]

\* Family B (PointerIdentity): a reader's confirmed addr/gen must match a real
\* allocation that was reachable.  In particular, fast-path uses `confirm` (not
\* `ptr`) so the gen captured matches the live allocation at the captured address.
NoTornGuardState ==
    \A t \in Thread :
        \A i \in 1..MaxGuardsPerThread :
            (guards[t][i].addr # NullPtr) =>
                \* gen captured matches current allocation OR a previous live alloc
                \* still kept alive by a slot (writer-paid case).
                guards[t][i].gen <= addrGen[guards[t][i].addr]

\* Family C: refcount never goes negative; lifecycle integrity.
RefCountNonNeg == \A a \in Addr : refCount[a] >= 0

\* Family C (CASIntendedSemantics): when CAS reports success with non-stale current,
\* the storage must have transitioned through the value the caller observed.
\* For RAWSTALE, success on a generation-mismatch is permitted (documented hazard).
CASIntendedSemantics ==
    \A t \in Thread :
        (rPC[t] = "cas_after_load" /\ rPath[t] = "cas") =>
            casKind[t] \in {CAS_KIND_ARC, CAS_KIND_GUARD,
                            CAS_KIND_RAWFRESH, CAS_KIND_RAWSTALE}

\* Family D (NoConcurrentNodeClaim): at most one thread claims a node USED.
NoConcurrentNodeClaim ==
    \A n \in Thread :
        nodeState[n] = NODE_USED =>
            (\E t \in Thread : nodeOwner[n] = t)

\* Family D (CooldownReleaseObservesZero): a node only leaves COOLDOWN when no
\* writer is currently in pay_all on that node (active_writers = 0).  Modeled
\* directly by CheckCooldown's guard, but we restate as an invariant.
CooldownReleaseObservesZero ==
    \A n \in Thread :
        nodeState[n] = NODE_UNUSED => activeWriters[n] = 0

\* Family A baseline sanity invariant: when no relaxation is active, the
\* confirm-load value must be the current storage value.
NoStaleWithoutRelax ==
    relaxSite = NoneSite =>
        \A t \in Thread :
            rPC[t] = "r_fast_after_confirm" => rConfirmAddr[t] = storageAddr

\* ===================================================================================
\* Structural Invariants
\* ===================================================================================

\* Storage points to a live allocation (or empty if dropped)
StorageLive == arcSwapDropped \/ addrAlive[storageAddr]

\* State constraint used in base.cfg: only run the SC-respecting protocol
\* (no Family A label downgrading).  MC.cfg lifts this and counter-bounds
\* PickRelaxSite to enable bug hunting.
NoRelaxation == relaxSite = NoneSite

\* Dead address has zero refcount
DeadRefCountZero == \A a \in Addr : ~addrAlive[a] => refCount[a] = 0

\* Reader and writer cannot run on the same thread simultaneously
ReaderWriterExclusive ==
    \A t \in Thread : wPC[t] # "w_idle" => rPC[t] = "r_idle"

\* Sum of refs from slots/guards should not exceed refCount.  Loose form: all
\* slot occupants and all guards reference allocated memory.
AllOccupantsAllocated ==
    /\ \A t \in Thread, s \in SlotIx :
        SlotValue(t, s) # NullPtr =>
            (SlotValue(t, s) \in Addr /\ addrGen[SlotValue(t, s)] > 0)
    /\ \A t \in Thread, i \in 1..MaxGuardsPerThread :
        guards[t][i].addr # NullPtr => guards[t][i].addr \in Addr

====
