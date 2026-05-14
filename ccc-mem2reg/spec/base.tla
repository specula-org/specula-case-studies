---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of CCC mem2reg — SSA construction (Cytron 1991 +    *)
(* Cooper-Harvey-Kennedy 2001) and phi elimination.                        *)
(*                                                                         *)
(* Source files (claudes-c-compiler):                                     *)
(*   src/ir/analysis.rs           — CFG, dominators, DF                    *)
(*   src/ir/mem2reg/promote.rs    — find/IDF/rename                        *)
(*   src/ir/mem2reg/phi_eliminate.rs — phi lowering                       *)
(*                                                                         *)
(* Category: B (sequential pure algorithm; state machine over def-stacks, *)
(* IDF worklist, dominator tree).                                          *)
(*                                                                         *)
(* Bug Families covered (modeling-brief.md §2):                           *)
(*   F1 — Alloca eligibility / escape detection                           *)
(*   F2 — Alloca placement (entry vs non-entry, params)                   *)
(*   F3 — Phi well-formedness vs predecessors                             *)
(*   F4 — Asm-goto snapshot semantics (and D3 multi-asm-goto)             *)
(*   F5 — Phi cost cap and IDF blow-up (D1 preds duplication, D4 idom)    *)
(*   F6 — Phi elimination critical-edge / D2 retarget-once                *)
(*   F7 — Phi elimination copy cycles                                     *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC, Naturals

\* ========================================================================
\* Constants — input IR shape
\* ========================================================================

CONSTANTS
    Blocks,           \* Set of block IDs
    Entry,            \* Entry block ID
    Allocas,          \* Set of alloca IDs
    AllocaInfo,       \* [Allocas -> [origin, size, type_size, volatile, is_param]]
    UseSites,         \* [Blocks -> Seq([kind, alloca, goto_targets])]
    TermKind,         \* [Blocks -> TERM_KINDS]
    TermTargets,      \* [Blocks -> Seq(Blocks)] — preserves syntactic order
    MaxPhiCopyCost,   \* cost cap (50_000 in source; small here)
    MaxIdomIters,     \* upper bound on CHK fixpoint passes (D4 liveness)
    MaxRenameDepth,   \* bound on rename DFS recursion depth
    MaxSynId          \* upper bound on syntactic-edge IDs (terminator
                      \* occurrences max + 1 for asm-goto label). Keep
                      \* small for MC tractability.

PHASES == { "INIT", "FILTER", "BUILD_CFG", "IDOM", "DF", "IDF",
            "COST_DROP", "REINSERT", "RENAME", "REMOVE",
            "PHI_ELIM", "DONE" }

USE_KINDS == { "LOAD", "STORE_PTR", "STORE_VAL",
               "ASM_OUT_REG", "ASM_OUT_MEM", "ASM_IN_VAL",
               "ASM_HAS_GOTO_LABELS", "OTHER" }

TERM_KINDS == { "BRANCH", "COND_BRANCH", "INDIRECT_BRANCH", "SWITCH",
                "RETURN", "UNREACHABLE" }

ASSUME Entry \in Blocks
ASSUME MaxPhiCopyCost \in Nat
ASSUME MaxIdomIters \in Nat \ {0}
ASSUME MaxRenameDepth \in Nat \ {0}
ASSUME MaxSynId \in Nat \ {0}

\* UNDEF sentinel.  We use -1 (an Integer) so that TLC may safely test
\* equality and ordering against any integer value (block IDs, RPO numbers).
\* Mixing string sentinels with integers triggers TLC type errors at runtime.
UNDEF == -1

\* Operand domain markers used by the rename pass.
Operand == { "ZERO", "PHI_DEF", "STORE_VAL", "ASM_OUT" }

\* Bounded syntactic-edge ID domain. Syntactic IDs are 1..N for terminator
\* occurrences (N <= number of switch cases / indirect targets); 100 used
\* for asm-goto edges (single bucket — D2 still triggers via dup syn_id at
\* the terminator level).
SynIds == 0..MaxSynId

\* ========================================================================
\* Variables
\* ========================================================================

VARIABLES
    phase,

    \* Phase 1: find_promotable_allocas (promote.rs:181-360)
    candidates,
    disqualified,
    defBlocks,
    useBlocks,
    filterIdx,
    filterBlockOrder,

    \* Phase 2: build_cfg (analysis.rs:110-187)
    \* predsCount[t][p] = number of syntactic edges p -> t (D1: NOT deduped)
    predsCount,
    succs,
    cfgEdges,

    \* Phase 3: compute_dominators (analysis.rs:235-296)
    rpo,
    rpoNumber,
    idom,
    idomIters,

    \* Phase 4: compute_dominance_frontiers (analysis.rs:302-326)
    df,
    domChildren,

    \* Phase 5/7: insert_phis (promote.rs:364-391)
    phiSites,
    idfWorklist,       \* [Allocas -> SUBSET Blocks] (worklist as set; order
                       \* irrelevant for monotone IDF correctness)
    idfHasPhi,
    idfEverInWl,
    idfInited,
    idfDone,

    \* Phase 6: cost cap (promote.rs:118-161)
    droppedByCost,

    \* Phase 8: rename (promote.rs:397-720)
    promoted,
    defStacks,
    phiIncoming,       \* [Blocks \X Allocas -> Seq([op, pred])]
    gotoSnapByLabel,   \* [Blocks -> [Blocks -> [Allocas -> Operand]]]
                       \* Models goto_label_snapshots (promote.rs:531) —
                       \* later asm-goto OVERWRITES earlier (D3 source).
    renameStack,
    renameStarted,     \* TRUE once StartRename fires; blocks RenameDone
                       \* from firing before rename actually runs.

    \* Phase 9: remove_promoted_instructions (promote.rs:748-807)
    paramAllocaPositional,
    removedAllocas,

    \* Phase 10: eliminate_phis (phi_eliminate.rs:256-286)
    multiSucc,
    isIndirectBranch,
    trampolines,       \* SUBSET [pred, target]
    retargetedSyn,     \* [pred, target -> Nat] — the ONE syn_id rewritten (D2)
    phiCopyExecuted    \* [pred, succ, syn_id (in SynIds) -> SUBSET Allocas]

filterVars  == << candidates, disqualified, defBlocks, useBlocks,
                  filterIdx, filterBlockOrder >>
cfgVars     == << predsCount, succs, cfgEdges, multiSucc, isIndirectBranch >>
domVars     == << rpo, rpoNumber, idom, idomIters >>
dfVars      == << df, domChildren >>
idfVars     == << phiSites, idfWorklist, idfHasPhi, idfEverInWl,
                  idfInited, idfDone >>
costVars    == << droppedByCost >>
renameVars  == << promoted, defStacks, phiIncoming, gotoSnapByLabel,
                  renameStack, renameStarted >>
removeVars  == << paramAllocaPositional, removedAllocas >>
elimVars    == << trampolines, retargetedSyn, phiCopyExecuted >>

allVars == << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
              costVars, renameVars, removeVars, elimVars >>

\* ========================================================================
\* Helpers
\* ========================================================================

NumParamAllocas == Cardinality({a \in Allocas : AllocaInfo[a].is_param})
MAX_PROMOTABLE == 8

ShapeEligible(a) ==
    /\ ~AllocaInfo[a].volatile
    /\ AllocaInfo[a].size <= MAX_PROMOTABLE
    /\ AllocaInfo[a].type_size <= MAX_PROMOTABLE

\* PredsLen models analysis.rs:309 — preds.len(b) (multiset count, D1).
RECURSIVE SumOver(_, _, _)
SumOver(f(_), S, acc) ==
    IF S = {} THEN acc
    ELSE LET x == CHOOSE y \in S : TRUE
         IN SumOver(f, S \ {x}, acc + f(x))

PredsLen(b) ==
    LET f(p) == predsCount[b][p]
    IN  SumOver(f, Blocks, 0)

TermSuccsSeq(b) == TermTargets[b]

AsmGotoLabels(b) ==
    UNION { UseSites[b][i].goto_targets :
              i \in { j \in 1..Len(UseSites[b]) :
                        UseSites[b][j].kind = "ASM_HAS_GOTO_LABELS" } }

SuccsOf(b) ==
    LET tts == TermSuccsSeq(b)
        termSet == { tts[i] : i \in 1..Len(tts) }
    IN termSet \cup AsmGotoLabels(b)

\* Number of syntactic edges from p to t (analysis.rs:122-184).
SynEdgeCount(p, t) ==
    LET tts == TermSuccsSeq(p)
        termCount == Cardinality({i \in 1..Len(tts) : tts[i] = t})
        asmCount  == IF t \in AsmGotoLabels(p) THEN 1 ELSE 0
    IN termCount + asmCount

\* def-stack top, defaulting to ZERO (promote.rs:582-584, 649-650)
StackTop(a) ==
    IF Len(defStacks[a]) > 0
    THEN defStacks[a][Len(defStacks[a])]
    ELSE "ZERO"

\* Reachable blocks from Entry through succs.
RECURSIVE ExpandReach(_)
ExpandReach(R) ==
    LET R2 == R \cup UNION { succs[b] : b \in R }
    IN  IF R2 = R THEN R ELSE ExpandReach(R2)

ReachableSet == ExpandReach({Entry})

\* Distinct predecessor set (multiplicities collapsed to set membership)
PredSet(t) == { p \in Blocks : predsCount[t][p] > 0 }

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    /\ phase = "INIT"
    /\ candidates = { a \in Allocas : ShapeEligible(a) }
    /\ disqualified = {}
    /\ defBlocks = [a \in Allocas |-> {}]
    /\ useBlocks = [a \in Allocas |-> {}]
    /\ filterIdx = 0
    /\ filterBlockOrder \in
         { s \in [1..Cardinality(Blocks) -> Blocks] :
             \A b \in Blocks :
               \E i \in 1..Cardinality(Blocks) : s[i] = b }
    /\ predsCount = [t \in Blocks |-> [p \in Blocks |-> 0]]
    /\ succs = [b \in Blocks |-> {}]
    /\ cfgEdges = {}
    /\ rpo = << >>
    /\ rpoNumber = [b \in Blocks |-> UNDEF]
    /\ idom = [b \in Blocks |-> UNDEF]
    /\ idomIters = 0
    /\ df = [b \in Blocks |-> {}]
    /\ domChildren = [b \in Blocks |-> {}]
    /\ phiSites = [b \in Blocks |-> {}]
    /\ idfWorklist = [a \in Allocas |-> {}]
    /\ idfHasPhi = [a \in Allocas |-> {}]
    /\ idfEverInWl = [a \in Allocas |-> {}]
    /\ idfInited = {}
    /\ idfDone = {}
    /\ droppedByCost = {}
    /\ promoted = {}
    /\ defStacks = [a \in Allocas |-> << "ZERO" >>]
    /\ phiIncoming = [b \in Blocks, a \in Allocas |-> << >>]
    /\ gotoSnapByLabel = [b \in Blocks |->
                            [t \in Blocks |->
                                [a \in Allocas |-> "ZERO"]]]
    /\ renameStack = << >>
    /\ renameStarted = FALSE
    /\ paramAllocaPositional = { a \in Allocas : AllocaInfo[a].is_param }
    /\ removedAllocas = {}
    /\ multiSucc = [b \in Blocks |-> FALSE]
    /\ isIndirectBranch = [b \in Blocks |-> TermKind[b] = "INDIRECT_BRANCH"]
    /\ trampolines = {}
    /\ retargetedSyn = [p \in Blocks, t \in Blocks |-> 0]
    /\ phiCopyExecuted = [p \in Blocks, s \in Blocks, k \in SynIds |-> {}]

\* ========================================================================
\* PHASE: INIT -> FILTER
\* ========================================================================

StartFilter ==
    /\ phase = "INIT"
    /\ phase' = "FILTER"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: FILTER  — find_promotable_allocas (promote.rs:181-360)
\* One step per use-site event in the iteration order
\* (filterBlockOrder, then UseSites order within each block).
\* ========================================================================

\* Resolve filterIdx -> (block, position-within-block)
RECURSIVE ResolveIdx(_, _)
ResolveIdx(i, idx) ==
    IF i > Len(filterBlockOrder) THEN [done |-> TRUE]
    ELSE
        LET b == filterBlockOrder[i]
            blen == Len(UseSites[b])
        IN IF idx < blen
           THEN [done |-> FALSE, block |-> b, pos |-> idx + 1]
           ELSE ResolveIdx(i + 1, idx - blen)

FilterCurrent == ResolveIdx(1, filterIdx)

FilterStep ==
    /\ phase = "FILTER"
    /\ ~FilterCurrent.done
    /\ LET b == FilterCurrent.block
           pos == FilterCurrent.pos
           u == UseSites[b][pos]
           a == u.alloca
       IN
       /\ CASE u.kind = "LOAD" ->
              \* promote.rs:259-263
              /\ defBlocks' = defBlocks
              /\ disqualified' = disqualified
              /\ useBlocks' = IF a \in candidates /\ a \notin disqualified
                              THEN [useBlocks EXCEPT ![a] = @ \cup {b}]
                              ELSE useBlocks
            [] u.kind = "STORE_PTR" ->
              \* promote.rs:265-267
              /\ useBlocks' = useBlocks
              /\ disqualified' = disqualified
              /\ defBlocks' = IF a \in candidates /\ a \notin disqualified
                              THEN [defBlocks EXCEPT ![a] = @ \cup {b}]
                              ELSE defBlocks
            [] u.kind = "STORE_VAL" ->
              \* promote.rs:272-276 — alloca address as data
              /\ defBlocks' = defBlocks
              /\ useBlocks' = useBlocks
              /\ disqualified' = IF a \in candidates
                                 THEN disqualified \cup {a}
                                 ELSE disqualified
            [] u.kind = "ASM_OUT_REG" ->
              \* promote.rs:289-300 (output, register constraint)
              /\ useBlocks' = useBlocks
              /\ disqualified' = disqualified
              /\ defBlocks' = IF a \in candidates /\ a \notin disqualified
                              THEN [defBlocks EXCEPT ![a] = @ \cup {b}]
                              ELSE defBlocks
            [] u.kind = "ASM_OUT_MEM" ->
              \* promote.rs:291-295 — memory-only constraint disqualifies
              /\ defBlocks' = defBlocks
              /\ useBlocks' = useBlocks
              /\ disqualified' = IF a \in candidates
                                 THEN disqualified \cup {a}
                                 ELSE disqualified
            [] u.kind = "ASM_IN_VAL" ->
              \* promote.rs:304-310 — input as Value (address-taken)
              /\ defBlocks' = defBlocks
              /\ useBlocks' = useBlocks
              /\ disqualified' = IF a \in candidates
                                 THEN disqualified \cup {a}
                                 ELSE disqualified
            [] u.kind = "ASM_HAS_GOTO_LABELS" ->
              /\ defBlocks' = defBlocks
              /\ useBlocks' = useBlocks
              /\ disqualified' = disqualified
            [] OTHER ->
              \* OTHER kind: any other use disqualifies (promote.rs:313-319)
              /\ defBlocks' = defBlocks
              /\ useBlocks' = useBlocks
              /\ disqualified' = IF a \in candidates
                                 THEN disqualified \cup {a}
                                 ELSE disqualified
       /\ filterIdx' = filterIdx + 1
       /\ candidates' = candidates
       /\ filterBlockOrder' = filterBlockOrder
    /\ UNCHANGED << phase, cfgVars, domVars, dfVars, idfVars, costVars,
                    renameVars, removeVars, elimVars >>

FilterDone ==
    /\ phase = "FILTER"
    /\ FilterCurrent.done
    \* Final pass: disqualify allocas with no uses or param-no-defs
    \* (promote.rs:347, 352-358).
    /\ disqualified' = disqualified \cup
         { a \in candidates :
             \/ defBlocks[a] = {} /\ useBlocks[a] = {}
             \/ AllocaInfo[a].is_param /\ defBlocks[a] = {} }
    /\ phase' = "BUILD_CFG"
    /\ UNCHANGED << candidates, defBlocks, useBlocks, filterIdx,
                    filterBlockOrder >>
    /\ UNCHANGED << cfgVars, domVars, dfVars, idfVars, costVars,
                    renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: BUILD_CFG  — build_cfg (analysis.rs:110-187), atomic.
\* ========================================================================

\* Helper sets used in BuildCFG
TermEdgesOf(p) ==
    LET tts == TermTargets[p]
    IN { [pred |-> p, succ |-> tts[i],
          syn_id |-> i, kind |-> TermKind[p]] : i \in 1..Len(tts) }

\* Asm-goto edges get syn_ids continuing AFTER terminator slot count.
\* This matches the source's retarget order (terminator first).
AsmEdgesOf(p) ==
    LET base == Len(TermTargets[p])
        labels == AsmGotoLabels(p)
        ord == CHOOSE seq \in [1..Cardinality(labels) -> labels] :
                  \A i, j \in 1..Cardinality(labels) :
                     i /= j => seq[i] /= seq[j]
    IN { [pred |-> p, succ |-> ord[i],
          syn_id |-> base + i,
          kind |-> "ASM_GOTO"] : i \in 1..Cardinality(labels) }

BuildCFG ==
    /\ phase = "BUILD_CFG"
    /\ succs' = [b \in Blocks |-> SuccsOf(b)]
    /\ predsCount' = [t \in Blocks |->
                        [p \in Blocks |-> SynEdgeCount(p, t)]]
    /\ cfgEdges' = (UNION { TermEdgesOf(p) : p \in Blocks })
                   \cup (UNION { AsmEdgesOf(p) : p \in Blocks })
    /\ multiSucc' = [b \in Blocks |-> Cardinality(SuccsOf(b)) > 1]
    /\ phase' = "IDOM"
    /\ UNCHANGED << filterVars, isIndirectBranch, domVars, dfVars,
                    idfVars, costVars, renameVars, removeVars,
                    trampolines, retargetedSyn, phiCopyExecuted >>

\* ========================================================================
\* PHASE: IDOM  — Cooper-Harvey-Kennedy (analysis.rs:235-296)
\* ========================================================================

ComputeRPO ==
    /\ phase = "IDOM"
    /\ rpo = << >>
    /\ \E ord \in [1..Cardinality(ReachableSet) -> ReachableSet] :
         /\ ord[1] = Entry
         /\ \A i, j \in 1..Cardinality(ReachableSet) :
              i /= j => ord[i] /= ord[j]
         /\ rpo' = ord
         /\ rpoNumber' = [b \in Blocks |->
                            IF b \in ReachableSet
                            THEN CHOOSE k \in 1..Cardinality(ReachableSet) :
                                    ord[k] = b
                            ELSE UNDEF]
    /\ idom' = [b \in Blocks |-> IF b = Entry THEN Entry ELSE UNDEF]
    /\ idomIters' = 0
    /\ UNCHANGED << phase, filterVars, cfgVars, dfVars, idfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* CHK intersect (analysis.rs:218-233), bounded by |Blocks|.
\* Guards every comparison so we never hit "compare integer with UNDEF".
RECURSIVE Intersect2(_, _, _)
Intersect2(f1, f2, n) ==
    IF n = 0 \/ f1 = f2 \/ f1 = UNDEF \/ f2 = UNDEF
    THEN f1
    ELSE IF rpoNumber[f1] = UNDEF \/ rpoNumber[f2] = UNDEF
         THEN f1
         ELSE IF rpoNumber[f1] > rpoNumber[f2]
              THEN IF idom[f1] = UNDEF
                   THEN f1
                   ELSE Intersect2(idom[f1], f2, n - 1)
              ELSE IF rpoNumber[f2] > rpoNumber[f1]
                   THEN IF idom[f2] = UNDEF
                        THEN f1
                        ELSE Intersect2(f1, idom[f2], n - 1)
                   ELSE f1

NewIdomFor(b) ==
    IF b = Entry THEN Entry
    ELSE IF rpoNumber[b] = UNDEF THEN UNDEF
    ELSE
        LET defPreds == { p \in PredSet(b) : idom[p] /= UNDEF } IN
        IF defPreds = {} THEN UNDEF
        ELSE
            LET RECURSIVE foldI(_, _)
                foldI(acc, S) ==
                  IF S = {} THEN acc
                  ELSE LET p == CHOOSE x \in S : TRUE
                       IN foldI(Intersect2(acc, p, Cardinality(Blocks)),
                                S \ {p})
                anyP == CHOOSE p \in defPreds : TRUE
            IN foldI(anyP, defPreds \ {anyP})

IdomIterStep ==
    /\ phase = "IDOM"
    /\ rpo /= << >>
    /\ idomIters < MaxIdomIters
    /\ \E b \in Blocks : NewIdomFor(b) /= idom[b]   \* fixpoint not reached
    /\ idom' = [b \in Blocks |-> NewIdomFor(b)]
    /\ idomIters' = idomIters + 1
    /\ UNCHANGED << phase, filterVars, cfgVars, rpo, rpoNumber,
                    dfVars, idfVars, costVars, renameVars, removeVars,
                    elimVars >>

IdomDone ==
    /\ phase = "IDOM"
    /\ rpo /= << >>
    /\ \A b \in Blocks : NewIdomFor(b) = idom[b]
    /\ phase' = "DF"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: DF  — compute_dominance_frontiers (analysis.rs:302-326)
\* ========================================================================

\* WalkReaches: starting from r, walking via idom, do we hit `target`
\* before hitting `stop` or UNDEF? Bounded by n.
RECURSIVE WalkReaches(_, _, _, _)
WalkReaches(r, target, stop, n) ==
    IF n = 0 \/ r = stop \/ r = UNDEF
    THEN FALSE
    ELSE r = target \/ ( IF r = idom[r] THEN FALSE
                         ELSE WalkReaches(idom[r], target, stop, n - 1) )

DFOf ==
    [ runner \in Blocks |->
        { b \in Blocks :
            /\ PredsLen(b) >= 2
            /\ \E p \in PredSet(b) :
                 WalkReaches(p, runner, idom[b], Cardinality(Blocks)) } ]

ComputeDF ==
    /\ phase = "DF"
    /\ df' = DFOf
    /\ domChildren' = [ b \in Blocks |->
                          { c \in Blocks :
                              c /= Entry /\ idom[c] = b /\ c /= b } ]
    /\ phase' = "IDF"
    /\ UNCHANGED << filterVars, cfgVars, domVars, idfVars, costVars,
                    renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: IDF  — insert_phis (promote.rs:364-391)
\* Worklist held as a SET (order doesn't affect correctness for monotone IDF).
\* ========================================================================

IdfInitAlloca ==
    /\ phase = "IDF"
    /\ \E a \in Allocas \ idfInited :
         /\ a \in candidates /\ a \notin disqualified
         /\ idfWorklist' = [idfWorklist EXCEPT ![a] = defBlocks[a]]
         /\ idfEverInWl' = [idfEverInWl EXCEPT ![a] = defBlocks[a]]
         /\ idfInited' = idfInited \cup {a}
         /\ UNCHANGED << idfHasPhi, idfDone, phiSites >>
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars,
                    costVars, renameVars, removeVars, elimVars >>

IdfSkipAlloca ==
    /\ phase = "IDF"
    /\ \E a \in Allocas \ idfInited :
         /\ ~(a \in candidates /\ a \notin disqualified)
         /\ idfInited' = idfInited \cup {a}
         /\ idfDone' = idfDone \cup {a}
         /\ UNCHANGED << idfWorklist, idfHasPhi, idfEverInWl, phiSites >>
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* One worklist iteration: pop one block, walk DF, insert phis.
\* Models promote.rs:378-387.
IdfWorklistStep ==
    /\ phase = "IDF"
    /\ \E a \in Allocas : \E b \in idfWorklist[a] :
         LET newPhi == { d \in df[b] : d \notin idfHasPhi[a] }
             newWl  == { d \in newPhi : d \notin idfEverInWl[a] }
         IN
         /\ idfHasPhi' = [idfHasPhi EXCEPT ![a] = @ \cup newPhi]
         /\ phiSites' = [b2 \in Blocks |->
                            IF b2 \in newPhi
                            THEN phiSites[b2] \cup {a}
                            ELSE phiSites[b2]]
         /\ idfEverInWl' = [idfEverInWl EXCEPT ![a] = @ \cup newWl]
         /\ idfWorklist' = [idfWorklist EXCEPT ![a] = (@ \ {b}) \cup newWl]
         /\ UNCHANGED << idfInited, idfDone >>
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars,
                    costVars, renameVars, removeVars, elimVars >>

IdfFinishAlloca ==
    /\ phase = "IDF"
    /\ \E a \in Allocas \ idfDone :
         /\ a \in idfInited
         /\ idfWorklist[a] = {}
         /\ idfDone' = idfDone \cup {a}
         /\ UNCHANGED << idfInited, idfWorklist, idfHasPhi, idfEverInWl,
                         phiSites >>
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars,
                    costVars, renameVars, removeVars, elimVars >>

IdfPhaseDone ==
    /\ phase = "IDF"
    /\ idfDone = Allocas
    /\ phase' = "COST_DROP"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: COST_DROP  — phi-cost cap (promote.rs:118-161)
\* D1 lives here: PerAllocaCost uses PredsLen which is the multiset count.
\* ========================================================================

PerAllocaCost(a) ==
    LET S == { b \in Blocks : a \in phiSites[b] }
        f(b) == PredsLen(b)
    IN  SumOver(f, S, 0)

PromotableSet == { a \in idfDone : a \in candidates /\ a \notin disqualified }

TotalPhiCost ==
    LET f(a) == PerAllocaCost(a)
    IN  SumOver(f, PromotableSet, 0)

CostDropAction ==
    /\ phase = "COST_DROP"
    /\ IF TotalPhiCost <= MaxPhiCopyCost
       THEN /\ droppedByCost' = {}
            /\ phase' = "REINSERT"
       ELSE
            \E rem \in SUBSET PromotableSet :
              /\ rem /= {}
              /\ \A a1 \in rem, a2 \in PromotableSet \ rem :
                   PerAllocaCost(a1) >= PerAllocaCost(a2)
              /\ LET keep == PromotableSet \ rem
                     g(a) == PerAllocaCost(a)
                 IN SumOver(g, keep, 0) <= MaxPhiCopyCost
              /\ droppedByCost' = rem
              /\ phase' = "REINSERT"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: REINSERT  — re-run insert_phis after drop (promote.rs:168)
\* ========================================================================

ReinsertPhis ==
    /\ phase = "REINSERT"
    /\ phiSites' = [b \in Blocks |-> phiSites[b] \ droppedByCost]
    /\ promoted' = PromotableSet \ droppedByCost
    /\ phase' = "RENAME"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars,
                    idfWorklist, idfHasPhi, idfEverInWl, idfInited,
                    idfDone, costVars >>
    /\ UNCHANGED << defStacks, phiIncoming, gotoSnapByLabel,
                    renameStack, renameStarted, removeVars, elimVars >>

\* ========================================================================
\* PHASE: RENAME  — rename_block (promote.rs:484-720).
\* renameStack frame: [block, depths, cursor, asmCursor].
\* cursor walks: 0 (push phi defs) -> 1..|US| (instructions) ->
\*               |US|+1 (fill phis) -> |US|+2 (descend / pop).
\* ========================================================================

StartRename ==
    /\ phase = "RENAME"
    /\ renameStack = << >>
    /\ renameStarted = FALSE
    /\ defStacks = [a \in Allocas |-> << "ZERO" >>]   \* fresh for a re-pass
    /\ renameStack' = << [block |-> Entry,
                          depths |-> [a \in Allocas |-> Len(defStacks[a])],
                          cursor |-> 0,
                          asmCursor |-> 0] >>
    /\ renameStarted' = TRUE
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, defStacks, phiIncoming, gotoSnapByLabel,
                    promoted, removeVars, elimVars >>

RenamePushPhiDefs ==
    /\ phase = "RENAME"
    /\ renameStack /= << >>
    /\ LET top == renameStack[Len(renameStack)] IN
       /\ top.cursor = 0
       /\ defStacks' = [a \in Allocas |->
                          IF a \in phiSites[top.block] /\ a \in promoted
                          THEN Append(defStacks[a], "PHI_DEF")
                          ELSE defStacks[a]]
       /\ renameStack' = [renameStack EXCEPT
                            ![Len(renameStack)] = [top EXCEPT !.cursor = 1]]
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, phiIncoming, gotoSnapByLabel,
                    promoted, removeVars, elimVars, renameStarted >>

RenameInstStep ==
    /\ phase = "RENAME"
    /\ renameStack /= << >>
    /\ LET frame == renameStack[Len(renameStack)]
           b == frame.block
           pos == frame.cursor
       IN
       /\ pos >= 1 /\ pos <= Len(UseSites[b])
       /\ LET u == UseSites[b][pos]
              a == u.alloca
              advance == [frame EXCEPT !.cursor = pos + 1,
                                       !.asmCursor =
                                         IF u.kind = "ASM_HAS_GOTO_LABELS"
                                         THEN @ + 1 ELSE @]
          IN
          /\ CASE u.kind = "STORE_PTR" ->
                  \* promote.rs:550-571 — push narrowed val onto def-stack
                  /\ (IF a \in promoted
                      THEN defStacks' = [defStacks EXCEPT ![a] =
                                            Append(@, "STORE_VAL")]
                      ELSE defStacks' = defStacks)
                  /\ gotoSnapByLabel' = gotoSnapByLabel
              [] u.kind = "ASM_HAS_GOTO_LABELS" ->
                  \* promote.rs:579-589 — snapshot BEFORE outputs.
                  \* D3 SOURCE: any later asm-goto with overlapping
                  \* goto_targets overwrites the earlier snap.
                  LET snap == [a2 \in Allocas |-> StackTop(a2)]
                  IN
                  /\ defStacks' = defStacks
                  /\ gotoSnapByLabel' = [gotoSnapByLabel EXCEPT ![b] =
                          [t \in Blocks |->
                              IF t \in u.goto_targets
                              THEN snap
                              ELSE @[t]]]
              [] u.kind = "ASM_OUT_REG" ->
                  \* promote.rs:592-599 — push fresh SSA value
                  /\ (IF a \in promoted
                      THEN defStacks' = [defStacks EXCEPT ![a] =
                                            Append(@, "ASM_OUT")]
                      ELSE defStacks' = defStacks)
                  /\ gotoSnapByLabel' = gotoSnapByLabel
              [] OTHER ->
                  \* LOAD, STORE_VAL, ASM_OUT_MEM, ASM_IN_VAL, OTHER:
                  \* no def-stack effect at rename time.
                  /\ defStacks' = defStacks
                  /\ gotoSnapByLabel' = gotoSnapByLabel
          /\ renameStack' = [renameStack EXCEPT
                                ![Len(renameStack)] = advance]
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, phiIncoming, promoted, removeVars, elimVars,
                    renameStarted >>

\* Fill incoming phi values in successors (promote.rs:618-659).
RenameFillPhis ==
    /\ phase = "RENAME"
    /\ renameStack /= << >>
    /\ LET frame == renameStack[Len(renameStack)]
           b == frame.block
       IN
       /\ frame.cursor = Len(UseSites[b]) + 1
       /\ LET succsOfB == succs[b]
              isGotoTarget(t) ==
                  \E i \in 1..Len(UseSites[b]) :
                     /\ UseSites[b][i].kind = "ASM_HAS_GOTO_LABELS"
                     /\ t \in UseSites[b][i].goto_targets
              valueFor(sb, a) ==
                  IF isGotoTarget(sb) /\ gotoSnapByLabel[b][sb][a] /= "ZERO"
                  THEN gotoSnapByLabel[b][sb][a]
                  ELSE StackTop(a)
          IN
          phiIncoming' =
            [ << sb, a >> \in Blocks \X Allocas |->
                  IF sb \in succsOfB /\ a \in phiSites[sb] /\ a \in promoted
                  THEN Append(phiIncoming[sb, a],
                              [op |-> valueFor(sb, a), pred |-> b])
                  ELSE phiIncoming[sb, a] ]
       /\ renameStack' = [renameStack EXCEPT ![Len(renameStack)] =
                            [frame EXCEPT !.cursor = frame.cursor + 1]]
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, defStacks, gotoSnapByLabel, promoted,
                    removeVars, elimVars, renameStarted >>

\* Descend into next dom-tree child (promote.rs:677-714).
RenameDescendChild ==
    /\ phase = "RENAME"
    /\ renameStack /= << >>
    /\ Len(renameStack) < MaxRenameDepth
    /\ LET frame == renameStack[Len(renameStack)]
           b == frame.block
           visited == { renameStack[i].block : i \in 1..Len(renameStack) }
       IN
       /\ frame.cursor = Len(UseSites[b]) + 2
       /\ \E child \in domChildren[b] \ visited :
            LET isGoto ==
                  \E i \in 1..Len(UseSites[b]) :
                     /\ UseSites[b][i].kind = "ASM_HAS_GOTO_LABELS"
                     /\ child \in UseSites[b][i].goto_targets
                pushedStacks ==
                  IF isGoto
                  THEN [a \in Allocas |->
                           IF a \in promoted
                           THEN Append(defStacks[a],
                                       gotoSnapByLabel[b][child][a])
                           ELSE defStacks[a]]
                  ELSE defStacks
                childDepths == [a \in Allocas |-> Len(pushedStacks[a])]
            IN
            /\ defStacks' = pushedStacks
            /\ renameStack' = Append(renameStack,
                                  [block |-> child,
                                   depths |-> childDepths,
                                   cursor |-> 0,
                                   asmCursor |-> 0])
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, phiIncoming, gotoSnapByLabel,
                    promoted, removeVars, elimVars, renameStarted >>

RenamePopFrame ==
    /\ phase = "RENAME"
    /\ renameStack /= << >>
    /\ LET frame == renameStack[Len(renameStack)]
           b == frame.block
           visited == { renameStack[i].block : i \in 1..Len(renameStack) }
       IN
       /\ frame.cursor = Len(UseSites[b]) + 2
       /\ domChildren[b] \ visited = {}
       /\ defStacks' = [a \in Allocas |->
                          SubSeq(defStacks[a], 1, frame.depths[a])]
       /\ renameStack' = SubSeq(renameStack, 1, Len(renameStack) - 1)
    /\ UNCHANGED << phase, filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, phiIncoming, gotoSnapByLabel,
                    promoted, removeVars, elimVars, renameStarted >>

RenameDone ==
    /\ phase = "RENAME"
    /\ renameStack = << >>
    /\ renameStarted = TRUE
    /\ phase' = "REMOVE"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, removeVars, elimVars >>

\* ========================================================================
\* PHASE: REMOVE  — remove_promoted_instructions (promote.rs:748-807)
\* ========================================================================

RemoveAction ==
    /\ phase = "REMOVE"
    /\ removedAllocas' =
         { a \in promoted : a \notin paramAllocaPositional }
    /\ phase' = "PHI_ELIM"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, paramAllocaPositional, elimVars >>

\* ========================================================================
\* PHASE: PHI_ELIM  — eliminate_phis (phi_eliminate.rs)
\* Atomic: plan trampolines, retarget edges (D2), set phiCopyExecuted.
\* ========================================================================

\* The set of (pred, target) pairs that need a trampoline
\* (phi_eliminate.rs:435-438).
TrampNeeders ==
    { <<p, t>> \in Blocks \X Blocks :
        /\ multiSucc[p]
        /\ ~isIndirectBranch[p]
        /\ \E e \in cfgEdges : e.pred = p /\ e.succ = t
        /\ phiSites[t] \cap promoted /= {} }

PhiElimPlan ==
    /\ phase = "PHI_ELIM"
    /\ trampolines' =
         { [pred |-> p, target |-> t] : <<p, t>> \in TrampNeeders }
    \* D2 SOURCE: only the FIRST matching syn_id gets rewritten
    \* (phi_eliminate.rs:105-157 — return after first match).
    /\ retargetedSyn' =
         [ p \in Blocks, t \in Blocks |->
             IF <<p, t>> \in TrampNeeders
             THEN
                LET edges == { e \in cfgEdges : e.pred = p /\ e.succ = t }
                IN IF edges = {} THEN 0
                   ELSE LET ids == { e.syn_id : e \in edges }
                        IN CHOOSE k \in ids : \A k2 \in ids : k <= k2
             ELSE 0 ]
    \* phiCopyExecuted: which alloca-phis run on each runtime edge.
    /\ phiCopyExecuted' =
         [ p \in Blocks, s \in Blocks, k \in SynIds |->
             LET edge == { e \in cfgEdges :
                              e.pred = p /\ e.succ = s /\ e.syn_id = k }
                 phisHere == phiSites[s] \cap promoted
             IN
             IF edge = {} \/ phisHere = {} THEN {}
             ELSE
                IF multiSucc[p] /\ ~isIndirectBranch[p]
                THEN IF <<p, s>> \in TrampNeeders
                     THEN
                        IF k = ( IF <<p, s>> \in TrampNeeders
                                 THEN LET ids2 == { e.syn_id : e \in edge \cup
                                          { ee \in cfgEdges :
                                              ee.pred = p /\ ee.succ = s } }
                                      IN CHOOSE k3 \in ids2 :
                                           \A k4 \in ids2 : k3 <= k4
                                 ELSE 0 )
                        THEN phisHere
                        ELSE {}    \* D2: bypassed syntactic edge
                     ELSE phisHere
                ELSE phisHere ]
    /\ phase' = "DONE"
    /\ UNCHANGED << filterVars, cfgVars, domVars, dfVars, idfVars,
                    costVars, renameVars, removeVars >>

\* ========================================================================
\* Next-state relation
\* ========================================================================

Next ==
    \/ StartFilter
    \/ FilterStep
    \/ FilterDone
    \/ BuildCFG
    \/ ComputeRPO
    \/ IdomIterStep
    \/ IdomDone
    \/ ComputeDF
    \/ IdfInitAlloca
    \/ IdfSkipAlloca
    \/ IdfWorklistStep
    \/ IdfFinishAlloca
    \/ IdfPhaseDone
    \/ CostDropAction
    \/ ReinsertPhis
    \/ StartRename
    \/ RenamePushPhiDefs
    \/ RenameInstStep
    \/ RenameFillPhis
    \/ RenameDescendChild
    \/ RenamePopFrame
    \/ RenameDone
    \/ RemoveAction
    \/ PhiElimPlan

Spec == Init /\ [][Next]_allVars

\* ========================================================================
\* Invariants
\* ========================================================================

ValidPhase == phase \in PHASES

DisqualifiedSubsetOfCandidates == disqualified \subseteq candidates

DefUseBlocksWellFormed ==
    \A a \in Allocas, b \in Blocks :
        ( b \in defBlocks[a] \/ b \in useBlocks[a] ) =>
            ( a \in candidates )

\* --- F1 — Address-taken never promoted (modeling-brief.md §5) ---
AddressTakenNeverPromoted ==
    phase \in {"REMOVE", "PHI_ELIM", "DONE"} =>
        \A a \in promoted :
            \A b \in Blocks :
                \A i \in 1..Len(UseSites[b]) :
                    ( UseSites[b][i].alloca = a ) =>
                        UseSites[b][i].kind \in
                           { "LOAD", "STORE_PTR", "ASM_OUT_REG",
                             "ASM_HAS_GOTO_LABELS" }

\* --- F2 — Param alloca prefix retained (modeling-brief.md §5, D6) ---
ParamAllocaRetained ==
    phase = "DONE" =>
        \A a \in paramAllocaPositional : a \notin removedAllocas

\* --- F3 — Phi incoming matches predecessors (modeling-brief.md §5) ---
PhiIncomingMatchesPreds ==
    phase \in {"REMOVE", "PHI_ELIM", "DONE"} =>
        \A b \in Blocks, a \in Allocas :
            ( a \in phiSites[b] /\ a \in promoted ) =>
                LET incoming == phiIncoming[b, a]
                    incPreds == { incoming[i].pred : i \in 1..Len(incoming) }
                IN incPreds = PredSet(b)

\* --- F4 — Asm-goto snapshot uniqueness (modeling-brief.md §5, D3) ---
\* If two asm-goto instructions in the same block share a target, the
\* later snapshot OVERWRITES the earlier one in gotoSnapByLabel — D3.
\* We assert no such overlap; counterexamples expose D3.
NoOverlappingAsmGotoTargets ==
    \A b \in Blocks :
        \A i, j \in 1..Len(UseSites[b]) :
            ( /\ i < j
              /\ UseSites[b][i].kind = "ASM_HAS_GOTO_LABELS"
              /\ UseSites[b][j].kind = "ASM_HAS_GOTO_LABELS" )
            =>
              UseSites[b][i].goto_targets \cap
              UseSites[b][j].goto_targets = {}

\* --- F5 — Cost cap bounded after drop (modeling-brief.md §5) ---
CostCapBounded ==
    phase \in {"REINSERT", "RENAME", "REMOVE", "PHI_ELIM", "DONE"} =>
        TotalPhiCost <= MaxPhiCopyCost

\* --- F6 / D2 — Phi copies execute on every syntactic edge ---
PhiCopiesOnEveryEdge ==
    phase = "DONE" =>
        \A e \in cfgEdges :
            \A a \in (phiSites[e.succ] \cap promoted) :
                a \in phiCopyExecuted[e.pred, e.succ, e.syn_id]

\* --- F5 / D4 — IDOM termination ---
IdomTerminates == idomIters <= MaxIdomIters

TypeOK ==
    /\ ValidPhase
    /\ DisqualifiedSubsetOfCandidates
    /\ DefUseBlocksWellFormed

\* --- Liveness ---
EventuallyDone == <>(phase = "DONE")

====
