---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for CCC mem2reg.                                *)
(*                                                                         *)
(* Bounds & strategy:                                                      *)
(*  - Algorithm phases are sequential and deterministic given the input,  *)
(*    so the only non-determinism comes from input shape (chosen via      *)
(*    CONSTANTS) and from RPO orders / IDF worklist orders / cost-drop   *)
(*    subset choices.                                                    *)
(*  - There are no fault-injection actions to bound (no concurrency,     *)
(*    no crashes). Bounds for liveness are MaxIdomIters and              *)
(*    MaxRenameDepth from the base spec.                                 *)
(*                                                                         *)
(* Hunting configs override fixture operators (Default... vs D2.../D3...) *)
(* via the CONSTANTS clause to plant a bug-family-specific pattern.       *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* DEFAULT FIXTURE — diamond CFG with one promotable alloca and a phi.
\*    b0 (entry, store a1, cond) -> b1 (store a1) -> b3 (load a1, ret)
\*                                -> b2 (store a1) -> b3
\* ========================================================================

DefaultBlocks       == {0, 1, 2, 3}
DefaultEntry        == 0
DefaultAllocas      == {1}

DefaultAllocaInfo ==
    [ a \in DefaultAllocas |->
         [ origin |-> 0, size |-> 4, type_size |-> 4,
           volatile |-> FALSE, is_param |-> FALSE ] ]

NoTargets == {}

UseRec(k, a, gt) == [kind |-> k, alloca |-> a, goto_targets |-> gt]

DefaultUseSites ==
    [ b \in DefaultBlocks |->
         IF b = 0 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE IF b = 1 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE IF b = 2 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE IF b = 3 THEN << UseRec("LOAD", 1, NoTargets) >>
         ELSE << >> ]

DefaultTermKind ==
    [ b \in DefaultBlocks |->
         IF b = 0 THEN "COND_BRANCH"
         ELSE IF b = 1 THEN "BRANCH"
         ELSE IF b = 2 THEN "BRANCH"
         ELSE "RETURN" ]

DefaultTermTargets ==
    [ b \in DefaultBlocks |->
         IF b = 0 THEN << 1, 2 >>
         ELSE IF b = 1 THEN << 3 >>
         ELSE IF b = 2 THEN << 3 >>
         ELSE << >> ]

\* ========================================================================
\* HUNT FIXTURE — F1 (address-taken): alloca used as STORE_VAL.
\* The algorithm must disqualify a1; a1 must NOT be promoted.
\* AddressTakenNeverPromoted should HOLD (sanity check).
\* ========================================================================

F1Blocks       == {0, 1}
F1Allocas      == {1, 2}     \* a2 is the address container

F1AllocaInfo ==
    [ a \in F1Allocas |->
         [ origin |-> 0, size |-> 4, type_size |-> 4,
           volatile |-> FALSE, is_param |-> FALSE ] ]

\* a1 has STORE_VAL (its address stored into something); should be disqualified.
\* a2 has only STORE_PTR (defining a1's contents in itself); promotable.
F1UseSites ==
    [ b \in F1Blocks |->
         IF b = 0 THEN
            << UseRec("STORE_PTR", 1, NoTargets),
               UseRec("STORE_PTR", 2, NoTargets),
               UseRec("STORE_VAL", 1, NoTargets),  \* a1 escape
               UseRec("LOAD",      2, NoTargets) >>
         ELSE << >> ]

F1TermKind    == [ b \in F1Blocks |-> IF b = 0 THEN "BRANCH" ELSE "RETURN" ]
F1TermTargets == [ b \in F1Blocks |-> IF b = 0 THEN << 1 >> ELSE << >> ]

\* ========================================================================
\* HUNT FIXTURE — F4/D3 (multi-asm-goto same target).
\* Block b0 has two ASM_HAS_GOTO_LABELS instructions with overlapping
\* goto_targets. NoOverlappingAsmGotoTargets must FAIL on this fixture
\* (counterexample = D3 confirmation).
\* ========================================================================

D3Blocks   == {0, 1}
D3Allocas  == {1}

D3AllocaInfo ==
    [ a \in D3Allocas |->
         [ origin |-> 0, size |-> 4, type_size |-> 4,
           volatile |-> FALSE, is_param |-> FALSE ] ]

D3UseSites ==
    [ b \in D3Blocks |->
         IF b = 0 THEN
            << UseRec("STORE_PTR", 1, NoTargets),
               UseRec("ASM_HAS_GOTO_LABELS", 1, {1}),
               UseRec("STORE_PTR", 1, NoTargets),
               UseRec("ASM_HAS_GOTO_LABELS", 1, {1}) >>  \* SAME target = D3
         ELSE << UseRec("LOAD", 1, NoTargets) >> ]

D3TermKind    == [ b \in D3Blocks |-> IF b = 0 THEN "BRANCH" ELSE "RETURN" ]
D3TermTargets == [ b \in D3Blocks |-> IF b = 0 THEN << 1 >> ELSE << >> ]

\* ========================================================================
\* HUNT FIXTURE — F6/D2 (switch default == case duplicates target).
\* Block b0 has switch [(1, b3), (2, b3), default: b3] all going to b3.
\* b3 has phi for a1. retarget_block_edge_once rewrites only one of the
\* three switch entries, leaving two syntactic edges bypassing the
\* trampoline. PhiCopiesOnEveryEdge must FAIL.
\* ========================================================================

D2Blocks   == {0, 3}
D2Allocas  == {1}

D2AllocaInfo ==
    [ a \in D2Allocas |->
         [ origin |-> 0, size |-> 4, type_size |-> 4,
           volatile |-> FALSE, is_param |-> FALSE ] ]

D2UseSites ==
    [ b \in D2Blocks |->
         IF b = 0 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE IF b = 3 THEN << UseRec("LOAD", 1, NoTargets) >>
         ELSE << >> ]

\* Block 0: SWITCH with default = 3, case 1 = 3, case 2 = 3 (all dups)
\*   TermTargets[0] = << 3, 3, 3 >>  -- syn_ids 1, 2, 3 all to b3.
\* Multi-succ? After dedup in succs: SuccsOf(0) = {3} (single succ).
\* So multiSucc[0] = FALSE, no trampoline triggered. To make D2 reachable,
\* we need TWO distinct successors so multiSucc is TRUE. Use a non-dup
\* extra case to a different block (b4).
D2BlocksReal == {0, 3, 4}
D2AllocasReal == D2Allocas
D2AllocaInfoReal == D2AllocaInfo
D2UseSitesReal ==
    [ b \in D2BlocksReal |->
         IF b = 0 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE IF b = 3 THEN << UseRec("LOAD", 1, NoTargets) >>
         ELSE IF b = 4 THEN << UseRec("STORE_PTR", 1, NoTargets) >>
         ELSE << >> ]
D2TermKindReal ==
    [ b \in D2BlocksReal |->
         IF b = 0 THEN "SWITCH"
         ELSE "RETURN" ]
D2TermTargetsReal ==
    [ b \in D2BlocksReal |->
         IF b = 0 THEN << 3, 3, 4 >>   \* default=3, case1=3 (DUP), case2=4
         ELSE << >> ]

\* ========================================================================
\* MC parameters (apply to all fixtures; override per-fixture as needed).
\* ========================================================================

MCMaxPhiCopyCost == 100
MCMaxIdomIters   == 6
MCMaxRenameDepth == 8
MCMaxSynId       == 5

\* For MC tractability, fix filterBlockOrder to a single canonical order
\* (matches the actual code's iteration order: by block index).
\* Each fixture defines its own MCInit_* below.

\* ========================================================================
\* MCInit / MCNext — fixture-specific Init that pins filterBlockOrder.
\* ========================================================================

MCInit_Default ==
    /\ Init
    /\ filterBlockOrder = << 0, 1, 2, 3 >>

MCInit_F1 ==
    /\ Init
    /\ filterBlockOrder = << 0, 1 >>

MCInit_D3 ==
    /\ Init
    /\ filterBlockOrder = << 0, 1 >>

MCInit_D2Real ==
    /\ Init
    /\ filterBlockOrder = << 0, 3, 4 >>

MCNext == Next

MCSpec_Default == MCInit_Default /\ [][MCNext]_allVars
MCSpec_F1      == MCInit_F1      /\ [][MCNext]_allVars
MCSpec_D3      == MCInit_D3      /\ [][MCNext]_allVars
MCSpec_D2Real  == MCInit_D2Real  /\ [][MCNext]_allVars

\* Default alias kept for backward-compat with MC.cfg
MCInit == MCInit_Default
MCSpec == MCSpec_Default

\* ========================================================================
\* State constraint
\* ========================================================================

StateConstraint ==
    /\ idomIters <= MaxIdomIters
    /\ Len(renameStack) <= MaxRenameDepth

====
