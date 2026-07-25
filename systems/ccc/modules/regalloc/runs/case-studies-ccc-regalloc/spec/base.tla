---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of the CCC compiler's register allocator + liveness  *)
(* dataflow.                                                                *)
(*                                                                          *)
(* Source files (claudes-c-compiler):                                       *)
(*   src/backend/liveness.rs                  — backward dataflow liveness *)
(*   src/backend/regalloc.rs                  — three-phase linear scan    *)
(*   src/backend/stack_layout/slot_assignment.rs — Tier-2 slot packing    *)
(*   src/backend/stack_layout/regalloc_helpers.rs — clobber merge         *)
(*   src/backend/x86/codegen/emit.rs:96-105  — clobber_to_phys mapper      *)
(*                                                                          *)
(* System category: Category B (sequential composition of compiler passes  *)
(* whose joint invariants must hold over a global state of intervals,      *)
(* assignments, and slots). No multi-threading; the "linearization points" *)
(* are pass-to-pass boundaries.                                             *)
(*                                                                          *)
(* Bug Families modeled (from modeling-brief.md):                           *)
(*   F1 (Family 1, 3): inline-asm caller-saved clobber not recorded as     *)
(*                     call point because asm with empty inputs/outputs    *)
(*                     is filtered out (liveness.rs:312-322) AND because   *)
(*                     clobber_to_phys recognises only callee-saved names  *)
(*                     (x86/codegen/emit.rs:96-105).                       *)
(*   F2 (Family 1):    is_returns_twice_call hard-codes setjmp/_setjmp/   *)
(*                     sigsetjmp/__sigsetjmp; vfork/getcontext/           *)
(*                     returns_twice attr functions are missed             *)
(*                     (liveness.rs:940-946).                              *)
(*   F3 (Family 1):    backward dataflow caps at MAX_ITERATIONS = 50 and  *)
(*                     silently exits with under-approximated live sets   *)
(*                     when not converged (liveness.rs:466-494).          *)
(*   F4 (Family 2):    Tier-2 packer trusts intervals; under-approximated *)
(*                     interval lets two simultaneously-live values share *)
(*                     a slot (slot_assignment.rs:733-769).               *)
(*   F5 (Family 2):    available_regs/caller_saved_regs disjointness is   *)
(*                     convention-only (regalloc.rs:248-317).             *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants — describe the input IR function and the allocator config
\* ========================================================================

CONSTANTS
    Vals,                       \* IR value IDs eligible for regalloc
    Points,                     \* Program points (0..MaxPoint)
    FuncEnd,                    \* Last program point + 1 (liveness.rs:554)
    MaxIters,                   \* Cap on dataflow iterations (liveness.rs:471)
    Blocks,                     \* Basic block IDs
    BlockOfPoint,               \* Points -> Blocks
    BlockSuccs,                 \* Blocks -> SUBSET Blocks
    TrueDef,                    \* Vals -> Points (def site of value)
    TrueUses,                   \* Vals -> SUBSET Points (true use sites)
    CallPoints,                 \* SUBSET Points: real Call/CallIndirect points
                                \*   (liveness.rs:313-314)
    AsmPoints,                  \* SUBSET Points: InlineAsm instruction points
    AsmHasOperands,             \* AsmPoints -> BOOLEAN
                                \*   (liveness.rs:316-322; TRUE iff outputs or
                                \*    inputs are non-empty)
    AsmClobbers,                \* AsmPoints -> SUBSET PhysRegs
                                \*   (the caller-saved set named in clobbers)
    ReturnsTwicePoints,         \* SUBSET CallPoints: returns_twice calls
    IsRecognizedReturnsTwice,   \* ReturnsTwicePoints -> BOOLEAN
                                \*   (liveness.rs:940-946 hard-coded set)
    CalleeSavedRegs,            \* PhysReg pool used by Phase 1 and Phase 3
    CallerSavedRegs,            \* PhysReg pool used by Phase 2
    Slots,                      \* Available stack slot IDs
    Priority                    \* Vals -> Nat (weighted use count, regalloc.rs:108-130)

\* NONE is the "not-assigned" sentinel for `assignment` and `slotOf`. It is an
\* integer outside the union of all register / slot ID pools so that mixed
\* integer-vs-sentinel comparisons do not trip TLC's strict-equality type
\* check (no PhysReg or Slot is -1 under the current modelling conventions).
NONE == -1
PhysRegs == CalleeSavedRegs \cup CallerSavedRegs

\* Sanity assumptions (some of which are themselves bug surfaces).
ASSUME Vals \subseteq Nat
ASSUME Points \subseteq Nat
ASSUME Blocks \subseteq Nat
ASSUME CallPoints \subseteq Points
ASSUME AsmPoints \subseteq Points
ASSUME ReturnsTwicePoints \subseteq CallPoints
ASSUME MaxIters \in Nat \ {0}
ASSUME FuncEnd \in Nat
ASSUME \A v \in Vals : TrueDef[v] \in Points
ASSUME \A v \in Vals : TrueUses[v] \subseteq Points

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Pipeline phase ---
VARIABLE phase
\* phase progresses monotonically through the compiler passes:
\*   "AssignPoints"   — building call_points list (liveness.rs:288-407)
\*   "Dataflow"       — backward fixpoint iteration (liveness.rs:456-494)
\*   "ExtendIntervals"— Phase 4 / 4b (liveness.rs:497-568)
\*   "BuildIntervals" — Phase 5 (liveness.rs:572-583)
\*   "Phase1"         — callee-saved for call-spanning (regalloc.rs:248-264)
\*   "Phase2"         — caller-saved for non-call-spanning (regalloc.rs:269-295)
\*   "Phase3"         — callee-saved spillover (regalloc.rs:297-317)
\*   "PackSlots"      — Tier-2 packing (slot_assignment.rs:733-769)
\*   "Done"

\* --- Liveness pass state ---
VARIABLES
    recordedCallPoints, \* SUBSET Points: liveness's call_points field built in
                        \*   assign_program_points (liveness.rs:312-355).
                        \*   F1: asm with empty operands is dropped here.
    blockGen,           \* Blocks -> SUBSET Vals (liveness.rs:384, 401)
    blockKill,          \* Blocks -> SUBSET Vals (liveness.rs:393, 378)
    liveIn,             \* Blocks -> SUBSET Vals (liveness.rs:463)
    liveOut,            \* Blocks -> SUBSET Vals (liveness.rs:464)
    iter,               \* Nat: dataflow iteration counter (liveness.rs:470)
    fixpointReached,    \* BOOLEAN: TRUE iff dataflow converged before cap (F3)
    computedLastUse,    \* Vals -> Nat: built by Phase 1 + Phase 4/4b
    computedDef         \* Vals -> Nat: def_points (liveness.rs:280)

\* --- Regalloc state ---
VARIABLES
    assignment,         \* Vals -> PhysRegs \cup {NONE}
    regFreeUntil,       \* CalleeSavedRegs -> Nat (regalloc.rs:254, 308)
    callerFreeUntil,    \* CallerSavedRegs -> Nat (regalloc.rs:276)
    usedRegs            \* SUBSET CalleeSavedRegs (regalloc.rs:256)

\* --- Tier-2 slot packing state ---
VARIABLES
    slotOf,             \* Vals -> Slots \cup {NONE} (state.value_locations)
    slotFreeUntil       \* Slots -> Nat (slot_assignment.rs:749 min-heap)

\* --- Variable groups for UNCHANGED ---
livenessVars == <<recordedCallPoints, blockGen, blockKill, liveIn, liveOut,
                  iter, fixpointReached, computedLastUse, computedDef>>
regallocVars == <<assignment, regFreeUntil, callerFreeUntil, usedRegs>>
slotVars     == <<slotOf, slotFreeUntil>>
allVars      == <<phase, livenessVars, regallocVars, slotVars>>

\* ========================================================================
\* Helpers — ground-truth liveness, interval predicates
\* ========================================================================

\* "spans any call" boundary semantics: cp \in [start, end]
\* (regalloc.rs:490-493 — partition_point gives first cp >= start, then cp <= end)
SpansAnyCall(v, cps) ==
    \E cp \in cps : computedDef[v] <= cp /\ cp <= computedLastUse[v]

\* Ground-truth liveness: v is live at p iff the function actually uses v
\* somewhere on a path from p that doesn't redefine it. We approximate
\* with [TrueDef, max(TrueUses)] and require any returns_twice live-out.
TrueLastUseOf(v) ==
    LET extended ==
            IF \E p \in ReturnsTwicePoints :
                /\ TrueDef[v] <= p
                /\ \E u \in TrueUses[v] : u >= p   \* live across the rt call
            THEN FuncEnd
            ELSE 0
        usual == IF TrueUses[v] = {} THEN TrueDef[v]
                 ELSE CHOOSE m \in TrueUses[v] : \A u \in TrueUses[v] : u <= m
    IN IF extended > usual THEN extended ELSE usual

TrueLiveAt(p) ==
    {v \in Vals : TrueDef[v] <= p /\ p <= TrueLastUseOf(v)}

\* Computed (possibly under-approximated) liveness, derived from intervals.
ComputedLiveAt(p) ==
    {v \in Vals : computedDef[v] <= p /\ p <= computedLastUse[v]}

\* All values that have a non-trivial interval (regalloc.rs:515 — iv.end > iv.start).
\* `computedDef` / `computedLastUse` are initialised to 0 and later set to the
\* value's def/last-use point (never back to NONE), so we test non-triviality
\* by `end > start`.
HasInterval(v) == computedLastUse[v] > computedDef[v]

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    /\ phase = "AssignPoints"
    /\ recordedCallPoints = {}
    /\ blockGen = [b \in Blocks |-> {}]
    /\ blockKill = [b \in Blocks |-> {}]
    /\ liveIn  = [b \in Blocks |-> {}]
    /\ liveOut = [b \in Blocks |-> {}]
    /\ iter = 0
    /\ fixpointReached = FALSE
    /\ computedLastUse = [v \in Vals |-> 0]
    /\ computedDef = [v \in Vals |-> 0]
    /\ assignment = [v \in Vals |-> NONE]
    /\ regFreeUntil = [r \in CalleeSavedRegs |-> 0]
    /\ callerFreeUntil = [r \in CallerSavedRegs |-> 0]
    /\ usedRegs = {}
    /\ slotOf = [v \in Vals |-> NONE]
    /\ slotFreeUntil = [s \in Slots |-> 0]

\* ========================================================================
\* Pass 1: AssignProgramPoints — builds recordedCallPoints, def/use
\* ========================================================================

\* AssignProgramPoints
\* Models liveness.rs:288-407 (assign_program_points).
\* Key decisions reflected here:
\*   - liveness.rs:313-314: Call/CallIndirect always recorded
\*   - liveness.rs:316-322: InlineAsm recorded ONLY IF outputs or inputs
\*     non-empty. Caller-saved clobbers in `clobbers` field are IGNORED.
\*     This is Bug Family 1/3 (F1).
\*   - liveness.rs:328-353: Memcpy/VaArg/i128 div-rem/i128-float casts
\*     also recorded (modeled here as CallPoints membership).
\*   - liveness.rs:386-394: dest defined here -> kill set
\*   - liveness.rs:357: uses recorded for last_use
AssignProgramPoints ==
    /\ phase = "AssignPoints"
    /\ recordedCallPoints' =
            \* Real calls always recorded (liveness.rs:313)
            CallPoints
            \* Inline asm only if has operands (liveness.rs:316-322) — F1.
            \cup { p \in AsmPoints : AsmHasOperands[p] }
    /\ blockGen' = [b \in Blocks |->
            \* gen[b] = upward-exposed uses (liveness.rs:867-893)
            \* A use at point p is upward-exposed iff no kill (def) precedes
            \* it in the same block. We model this set-theoretically.
            { v \in Vals :
                \E p \in TrueUses[v] :
                    /\ BlockOfPoint[p] = b
                    /\ ~ \E p2 \in Points :
                        /\ BlockOfPoint[p2] = b
                        /\ p2 < p
                        /\ TrueDef[v] = p2 } ]
    /\ blockKill' = [b \in Blocks |->
            \* kill[b] = values defined in b (liveness.rs:393)
            { v \in Vals : BlockOfPoint[TrueDef[v]] = b } ]
    /\ computedDef' = [v \in Vals |-> TrueDef[v]]
    /\ computedLastUse' = [v \in Vals |->
            IF TrueUses[v] = {} THEN TrueDef[v]
            ELSE CHOOSE m \in TrueUses[v] : \A u \in TrueUses[v] : u <= m]
    /\ phase' = "Dataflow"
    /\ UNCHANGED <<liveIn, liveOut, iter, fixpointReached>>
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* ========================================================================
\* Pass 2: Dataflow — iterative backward fixpoint
\* ========================================================================

\* DataflowIterStep
\* Models the body of the while loop in run_backward_dataflow
\* (liveness.rs:472-491). Each step performs ONE full iteration over all
\* blocks in reverse order. We track convergence by comparing pre/post sets.
DataflowIterStep ==
    /\ phase = "Dataflow"
    /\ iter < MaxIters
    /\ ~fixpointReached
    /\ LET newOut == [b \in Blocks |->
            \* live_out[B] = union live_in[S] for S in successors[B]  (liveness.rs:478-479)
            UNION { liveIn[s] : s \in BlockSuccs[b] } ]
           newIn == [b \in Blocks |->
            \* live_in[B] = gen[B] \cup (live_out[B] \ kill[B])  (liveness.rs:487-489)
            blockGen[b] \cup (newOut[b] \ blockKill[b]) ]
           changed == (newIn # liveIn) \/ (newOut # liveOut)
       IN
       /\ liveIn' = newIn
       /\ liveOut' = newOut
       /\ iter' = iter + 1
       /\ \/ /\ ~changed
             /\ fixpointReached' = TRUE
             /\ phase' = "ExtendIntervals"
          \/ /\ changed
             /\ fixpointReached' = FALSE
             /\ UNCHANGED phase
    /\ UNCHANGED <<recordedCallPoints, blockGen, blockKill,
                   computedLastUse, computedDef>>
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* DataflowCapHit
\* Models the silent exit at iter == MAX_ITERATIONS with changed == TRUE
\* (liveness.rs:472 — while changed && iteration < MAX_ITERATIONS).
\* Bug Family 1 (F3): no assertion fires, fixpointReached stays FALSE,
\* live_in/live_out are silently under-approximated.
DataflowCapHit ==
    /\ phase = "Dataflow"
    /\ iter >= MaxIters
    /\ ~fixpointReached
    /\ phase' = "ExtendIntervals"
    /\ UNCHANGED <<recordedCallPoints, blockGen, blockKill, liveIn, liveOut,
                   iter, fixpointReached, computedLastUse, computedDef>>
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* ========================================================================
\* Pass 3: Extend intervals from liveness + returns-twice extension
\* ========================================================================

\* ExtendIntervalsFromLiveness
\* Models extend_intervals_from_liveness (liveness.rs:497-540) and
\* extend_intervals_for_setjmp (liveness.rs:544-568) in a single step.
\*
\* Phase 4: a value live-in to block b extends interval to [block_start, block_end].
\* Phase 4b: a value live at a *recognized* returns-twice call extends end to FuncEnd.
\*           F2 — IsRecognizedReturnsTwice gates this; vfork etc. are missed.
ExtendIntervalsFromLiveness ==
    /\ phase = "ExtendIntervals"
    /\ computedLastUse' = [v \in Vals |->
            LET base == computedLastUse[v]
                \* Phase 4: extend through every block where v is live-in or live-out.
                fromLiveness ==
                    LET ends == { p \in Points :
                                    \E b \in Blocks :
                                       /\ BlockOfPoint[p] = b
                                       /\ (v \in liveIn[b] \/ v \in liveOut[b]) }
                    IN IF ends = {}
                       THEN base
                       ELSE LET m == CHOOSE x \in ends : \A y \in ends : y <= x
                            IN IF m > base THEN m ELSE base
                \* Phase 4b: returns_twice extension (only recognized ones).
                rtExtended ==
                    IF \E p \in ReturnsTwicePoints :
                        /\ IsRecognizedReturnsTwice[p]
                        /\ \E b \in Blocks :
                              /\ BlockOfPoint[p] = b
                              /\ (v \in liveIn[b] \/ v \in liveOut[b])
                    THEN FuncEnd
                    ELSE fromLiveness
            IN rtExtended ]
    /\ phase' = "BuildIntervals"
    /\ UNCHANGED <<recordedCallPoints, blockGen, blockKill, liveIn, liveOut,
                   iter, fixpointReached, computedDef>>
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* BuildIntervals — Phase 5
\* Models build_intervals (liveness.rs:572-583). end := max(start, end).
\* In our model computedDef and computedLastUse are already finalized; this
\* is just a phase advance. We keep it as a separate action so the trace
\* spec can match the implementation's pass boundaries.
BuildIntervals ==
    /\ phase = "BuildIntervals"
    /\ phase' = "Phase1"
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* ========================================================================
\* Pass 4: Three-phase linear scan register allocator
\* ========================================================================

\* Phase1AllocateCalleeSaved(v, r)
\* Models the candidates loop in regalloc.rs:258-264 with find_best_callee_reg
\* (regalloc.rs:542-573). v must:
\*   - have an interval (regalloc.rs:515)
\*   - span at least one call point per recordedCallPoints (regalloc.rs:516-520
\*     with spans_call=Some(true))
\*   - not yet be assigned
\*   - r must be free at v's start (regalloc.rs:259, 554)
\* The find_best_callee_reg "prefer already used" heuristic is collapsed into
\* arbitrary choice (modeling brief §3.2 — pure heuristic, NoRegisterCollision
\* captures correctness).
Phase1Allocate(v, r) ==
    /\ phase = "Phase1"
    /\ v \in Vals
    /\ r \in CalleeSavedRegs
    /\ HasInterval(v)
    /\ assignment[v] \notin PhysRegs
    /\ SpansAnyCall(v, recordedCallPoints)              \* regalloc.rs:516-520
    /\ regFreeUntil[r] <= computedDef[v]                \* regalloc.rs:554
    /\ regFreeUntil' = [regFreeUntil EXCEPT ![r] = computedLastUse[v] + 1]
                                                        \* regalloc.rs:260
    /\ assignment' = [assignment EXCEPT ![v] = r]       \* regalloc.rs:261
    /\ usedRegs' = usedRegs \cup {r}                    \* regalloc.rs:262
    /\ UNCHANGED callerFreeUntil
    /\ UNCHANGED livenessVars
    /\ UNCHANGED slotVars
    /\ UNCHANGED phase

\* Phase1Done — exhaust Phase 1 and advance.
Phase1Done ==
    /\ phase = "Phase1"
    /\ ~ \E v \in Vals, r \in CalleeSavedRegs :
            /\ HasInterval(v)
            /\ assignment[v] \notin PhysRegs
            /\ SpansAnyCall(v, recordedCallPoints)
            /\ regFreeUntil[r] <= computedDef[v]
    /\ phase' = "Phase2"
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* Phase2AllocateCallerSaved(v, r)
\* Models regalloc.rs:269-295. v must NOT span any call point per
\* recordedCallPoints (regalloc.rs:516-520 with spans_call=Some(false)).
\* Bug Family 1, 3: if recordedCallPoints is missing an asm point with
\* caller-saved clobbers, a value alive across that asm gets a caller-saved
\* register and is silently corrupted by the asm (F1).
Phase2Allocate(v, r) ==
    /\ phase = "Phase2"
    /\ v \in Vals
    /\ r \in CallerSavedRegs
    /\ HasInterval(v)
    /\ assignment[v] \notin PhysRegs
    /\ ~ SpansAnyCall(v, recordedCallPoints)            \* regalloc.rs:516-520
    /\ callerFreeUntil[r] <= computedDef[v]             \* regalloc.rs:283
    /\ callerFreeUntil' = [callerFreeUntil EXCEPT ![r] = computedLastUse[v] + 1]
                                                        \* regalloc.rs:291
    /\ assignment' = [assignment EXCEPT ![v] = r]       \* regalloc.rs:292
    /\ UNCHANGED <<regFreeUntil, usedRegs>>
    /\ UNCHANGED livenessVars
    /\ UNCHANGED slotVars
    /\ UNCHANGED phase

Phase2Done ==
    /\ phase = "Phase2"
    /\ ~ \E v \in Vals, r \in CallerSavedRegs :
            /\ HasInterval(v)
            /\ assignment[v] \notin PhysRegs
            /\ ~ SpansAnyCall(v, recordedCallPoints)
            /\ callerFreeUntil[r] <= computedDef[v]
    /\ phase' = "Phase3"
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* Phase3AllocateSpillover(v, r)
\* Models regalloc.rs:297-317: callee-saved spillover for non-call-spanning
\* values that didn't fit in caller-saved pool. Reuses reg_free_until from
\* Phase 1 (regalloc.rs:308) — this sharing is what makes pool disjointness
\* matter (Bug Family 2, F5).
Phase3Allocate(v, r) ==
    /\ phase = "Phase3"
    /\ v \in Vals
    /\ r \in CalleeSavedRegs
    /\ HasInterval(v)
    /\ assignment[v] \notin PhysRegs
    /\ ~ SpansAnyCall(v, recordedCallPoints)            \* regalloc.rs:304 spans_call=Some(false)
    /\ regFreeUntil[r] <= computedDef[v]                \* regalloc.rs:308
    /\ regFreeUntil' = [regFreeUntil EXCEPT ![r] = computedLastUse[v] + 1]
                                                        \* regalloc.rs:309
    /\ assignment' = [assignment EXCEPT ![v] = r]       \* regalloc.rs:310
    /\ usedRegs' = usedRegs \cup {r}                    \* regalloc.rs:311
    /\ UNCHANGED callerFreeUntil
    /\ UNCHANGED livenessVars
    /\ UNCHANGED slotVars
    /\ UNCHANGED phase

Phase3Done ==
    /\ phase = "Phase3"
    /\ ~ \E v \in Vals, r \in CalleeSavedRegs :
            /\ HasInterval(v)
            /\ assignment[v] \notin PhysRegs
            /\ ~ SpansAnyCall(v, recordedCallPoints)
            /\ regFreeUntil[r] <= computedDef[v]
    /\ phase' = "PackSlots"
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* ========================================================================
\* Pass 5: Tier-2 slot packing — pack_values_into_slots
\* ========================================================================

\* AssignSlot(v, s)
\* Models pack_values_into_slots (slot_assignment.rs:733-769). Greedy
\* min-heap by interval end: take the slot with the earliest end (heap.peek);
\* if its end < new_start, reuse; else allocate a new slot.
\* Bug Family 2 (F4): the slot reuse condition is `slot_end < start`, which
\* uses the COMPUTED interval. If liveness under-approximated computedLastUse,
\* the slot is reused too early and a still-live value's slot is overwritten.
AssignSlot(v, s) ==
    /\ phase = "PackSlots"
    /\ v \in Vals
    /\ s \in Slots
    /\ HasInterval(v)
    /\ assignment[v] \notin PhysRegs                              \* skip reg-assigned
                                                         \* (slot_assignment.rs:423)
    /\ slotOf[v] \notin Slots
    /\ slotFreeUntil[s] <= computedDef[v]                \* slot_assignment.rs:754
    /\ slotOf' = [slotOf EXCEPT ![v] = s]                \* slot_assignment.rs:758
    /\ slotFreeUntil' = [slotFreeUntil EXCEPT ![s] = computedLastUse[v] + 1]
                                                         \* slot_assignment.rs:757
    /\ UNCHANGED phase
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars

PackSlotsDone ==
    /\ phase = "PackSlots"
    /\ ~ \E v \in Vals, s \in Slots :
            /\ HasInterval(v)
            /\ assignment[v] \notin PhysRegs
            /\ slotOf[v] \notin Slots
            /\ slotFreeUntil[s] <= computedDef[v]
    /\ phase' = "Done"
    /\ UNCHANGED livenessVars
    /\ UNCHANGED regallocVars
    /\ UNCHANGED slotVars

\* ========================================================================
\* Next
\* ========================================================================

Next ==
    \/ AssignProgramPoints
    \/ DataflowIterStep
    \/ DataflowCapHit
    \/ ExtendIntervalsFromLiveness
    \/ BuildIntervals
    \/ \E v \in Vals, r \in CalleeSavedRegs : Phase1Allocate(v, r)
    \/ Phase1Done
    \/ \E v \in Vals, r \in CallerSavedRegs : Phase2Allocate(v, r)
    \/ Phase2Done
    \/ \E v \in Vals, r \in CalleeSavedRegs : Phase3Allocate(v, r)
    \/ Phase3Done
    \/ \E v \in Vals, s \in Slots : AssignSlot(v, s)
    \/ PackSlotsDone

Spec == Init /\ [][Next]_allVars

\* ========================================================================
\* Standard structural invariants
\* ========================================================================

\* PoolDisjointness — Bug Family 2 (F5): regalloc.rs:248-317 implicitly
\* assumes available_regs and caller_saved_regs are disjoint at the PhysReg
\* ID level. Violation would silently corrupt assignments since both pools
\* are written to the same `assignment` map.
PoolDisjointness ==
    CalleeSavedRegs \cap CallerSavedRegs = {}

\* ValidPhases
ValidPhases ==
    phase \in {"AssignPoints","Dataflow","ExtendIntervals","BuildIntervals",
               "Phase1","Phase2","Phase3","PackSlots","Done"}

\* AssignmentDomain — use set-membership to avoid TLC's strict equality on
\* mixed (integer vs. string-sentinel) types.
AssignmentDomain ==
    \A v \in Vals : assignment[v] \in ({NONE} \cup PhysRegs)

SlotDomain ==
    \A v \in Vals : slotOf[v] \in ({NONE} \cup Slots)

\* ========================================================================
\* Bug-family extension invariants
\* ========================================================================

\* NoRegisterCollision — primary safety invariant.
\* Bug Families 1, 2, 3 (F1, F3, F4 manifest as).
\* If two distinct values are TRULY alive at the same point and assigned to
\* the same physical register, the register holds one but the value of the
\* other is lost.
NoRegisterCollision ==
    phase = "Done" =>
    \A p \in Points :
        \A v1, v2 \in TrueLiveAt(p) :
            (v1 # v2 /\ assignment[v1] \in PhysRegs /\ assignment[v2] \in PhysRegs)
                => assignment[v1] # assignment[v2]

\* NoSlotCollision — primary safety invariant for Tier-2 packer.
\* Bug Family 2 (F4) primary target.
\* If two distinct values both alive at a point share a slot, one is corrupted.
NoSlotCollision ==
    phase = "Done" =>
    \A p \in Points :
        \A v1, v2 \in TrueLiveAt(p) :
            (v1 # v2 /\ slotOf[v1] \in Slots /\ slotOf[v2] \in Slots)
                => slotOf[v1] # slotOf[v2]

\* CallerSavedDeadAcrossCall — Bug Family 1 (F1, F3).
\* If v is in a caller-saved register, its TRUE live interval must not
\* contain any real call point (per ground-truth CallPoints, NOT
\* recordedCallPoints — the under-approximation of recordedCallPoints is
\* exactly what F1 exploits).
CallerSavedDeadAcrossCall ==
    phase = "Done" =>
    \A v \in Vals :
        assignment[v] \in CallerSavedRegs =>
            ~ \E cp \in CallPoints :
                /\ TrueDef[v] <= cp
                /\ cp <= TrueLastUseOf(v)

\* CallerSavedDeadAcrossAsmClobber — Bug Family 3 (F1).
\* If v is held in physical register r, and r is in the clobber set of an
\* asm point p that lies inside v's TRUE live interval, then v's value is
\* destroyed. We model the "no Reload was inserted" assumption by checking
\* the assignment directly — the implementation never inserts reloads in
\* this code path, so any such v is a bug.
CallerSavedDeadAcrossAsmClobber ==
    phase = "Done" =>
    \A v \in Vals :
        assignment[v] \in PhysRegs =>
            ~ \E p \in AsmPoints :
                /\ TrueDef[v] <= p
                /\ p <= TrueLastUseOf(v)
                /\ assignment[v] \in AsmClobbers[p]

\* ReturnsTwiceLiveExtension — Bug Family 1 (F2).
\* For every returns_twice point p (whether or not recognised), values that
\* are TRUE-live at p must have computedLastUse extended to FuncEnd. The
\* implementation only does this for the hard-coded set, so values live
\* across vfork/getcontext/etc. fail this invariant.
ReturnsTwiceLiveExtension ==
    phase \in {"BuildIntervals","Phase1","Phase2","Phase3","PackSlots","Done"} =>
    \A p \in ReturnsTwicePoints :
        \A v \in TrueLiveAt(p) :
            computedLastUse[v] >= FuncEnd

\* FixpointReachedBeforeUse — Bug Family 1 (F3).
\* Phases that consume intervals (BuildIntervals onward, including all
\* regalloc and packing) must only fire after the dataflow fixpoint was
\* reached. The implementation drops this check.
FixpointReachedBeforeUse ==
    phase \in {"Phase1","Phase2","Phase3","PackSlots","Done"} =>
        fixpointReached = TRUE

\* IntervalSoundness — background invariant; F1 manifests as this failing.
\* The computed interval must contain every TRUE use point of the value.
IntervalSoundness ==
    phase \in {"BuildIntervals","Phase1","Phase2","Phase3","PackSlots","Done"} =>
    \A v \in Vals :
        \A u \in TrueUses[v] :
            (computedDef[v] <= u /\ u <= computedLastUse[v])

\* ========================================================================
\* Sanity / structural invariants
\* ========================================================================

\* UsedRegsConsistency: usedRegs contains exactly the callee-saved regs that
\* have been assigned so far.
UsedRegsConsistency ==
    usedRegs = { r \in CalleeSavedRegs :
                    \E v \in Vals : assignment[v] = r }

\* AssignmentImmutable: once assigned, assignment is not changed.
\* Implicit from the action structure (assignment[v] = NONE precondition).

\* RecordedCallPointsSubsetOfPoints
RecordedCallPointsSubset ==
    recordedCallPoints \subseteq Points

\* MaxIterCap: iteration counter never exceeds MaxIters.
IterCap == iter <= MaxIters

====
