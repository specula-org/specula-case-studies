# ccc-mem2reg Spec Validation — Changelog

## Round 1 - Trace Validation
- [pass] `diamond.ndjson` (43 events, 350 states) validated against Trace.cfg on first attempt. No spec changes required.

## Round 1 - Model Checking (MC.cfg)
- [pass] BFS over `MCSpec_Default` reached depth 142 after 30-min timeout; 378M states generated, 361M distinct, queue ~46M. No invariant violations for `TypeOK` / `DisqualifiedSubsetOfCandidates` / `DefUseBlocksWellFormed` / `IdomTerminates`.
- Output: `spec/output/MC_run1.out`.

## Round 1 - Bug Hunting (revealed Case B)
- `MC_hunt_F3.cfg` exposed a spec-modeling bug: `RenameDone`'s precondition `\E a \in Allocas : Len(defStacks[a]) >= 1` is trivially satisfied by the initial state, so TLC could fire `RenameDone` immediately after `ReinsertPhis`, skipping all rename actions. With no rename, `phiIncoming[b, a] = << >>` and `PhiIncomingMatchesPreds` is violated for the phi at block 3.
- Counterexample: 23 states, `Initial -> StartFilter -> 4 × FilterStep -> FilterDone -> BuildCFG -> ComputeRPO -> 2 × IdomIterStep -> IdomDone -> ComputeDF -> IdfInitAlloca -> 4 × IdfWorklistStep -> IdfFinishAlloca -> IdfPhaseDone -> CostDropAction -> ReinsertPhis -> RenameDone` (no rename in between).
- Output: `spec/output/F3_bfs.out` (pre-fix).

## Round 2 - Spec Fix (Case B)
- [fix-spec] Added a Boolean `renameStarted` variable to `base.tla`. Initialized `FALSE`, set `TRUE` inside `StartRename`, required `TRUE` in `RenameDone`. Added to `renameVars` tuple and to the explicit `UNCHANGED` lists of `ReinsertPhis`, `RenameInstStep`, and the Trace-spec wrappers (`TRenamePopFrame`, `TPhiElimPlan`). This prevents `RenameDone` from firing before `StartRename` has actually run.

## Round 2 - Trace Validation
- [pass] `diamond.ndjson` still validates (350 states) after the spec fix.

## Round 2 - Model Checking (MC.cfg, partial)
- [pass] Re-run reached depth 133 with 89M distinct states explored before being stopped so the broader combined hunt could start. Same spec-level invariants as Round 1 — no violations. Output: `spec/output/MC_run2.out`.

## Round 2 - Bug Hunting
- `MC_hunt_F1.cfg`: BFS exhausted, 32 distinct states at depth 29. `AddressTakenNeverPromoted` holds for the F1 fixture (escape correctly disqualifies a1). (`spec/output/F1_bfs_v2.out`)
- `MC_hunt_F4_D3.cfg`: **Case C** — `NoOverlappingAsmGotoTargets` violated in the initial state (structural: the fixture deliberately contains two asm-gotos in block 0 with the same target). This is the expected D3 confirmation: the implementation's single-slot `gotoSnapByLabel[b][sb]` is overwritten by the later asm-goto, so the phi fill at `sb` uses the later snapshot on the earlier asm-goto's edge. (`spec/output/F4_D3_bfs_v2.out`)
- `MC_hunt_F6_D2.cfg`: BFS exhausted, 55 distinct states at depth 26, no violation. **Fixture limitation**: the three-successor block 0 in `D2UseSitesReal` (switch targets `<<3, 3, 4>>`) leaves block 3 with only ONE distinct predecessor (block 0). `PredsLen(3) = 2` counts the multiset, but `WalkReaches` in `DFOf` can't place block 3 in any DF because `idom[3] = 0` and walking back from the only pred 0 to the runner stops immediately at `idom[3]`. No phi is inserted at block 3, so `PhiCopiesOnEveryEdge` is vacuously satisfied. To actually exercise D2, the fixture needs a second distinct predecessor of the phi-bearing block with a store on the same alloca. (`spec/output/F6_D2_bfs_v2.out`)
- `MC_hunt_default_combined.cfg`: combined run covering F2 (`ParamAllocaRetained`), F3 (`PhiIncomingMatchesPreds`), F5 (`CostCapBounded` + `IdomTerminates`), plus `TypeOK` and `AddressTakenNeverPromoted` on the Default fixture. BFS reached depth 140 with 347M distinct states at 30-min timeout — no violations. (`spec/output/combined_bfs.out`)

## Result
Converged in 2 rounds. Bug hunting: **1 real bug confirmed (D3 asm-goto snapshot overwrite)** + 1 fixture limitation (D2 not reproduced by the current fixture shape).
