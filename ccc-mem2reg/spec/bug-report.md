# Bug Report — CCC mem2reg

## Summary

- Bug families tested: 6 (F1, F2, F3, F4/D3, F5, F6/D2)
- Bugs found: **1** — the D3 asm-goto snapshot overwrite (Family F4)
- Configs run: `MC.cfg`, `MC_hunt_F1.cfg`, `MC_hunt_F4_D3.cfg`, `MC_hunt_F6_D2.cfg`, `MC_hunt_default_combined.cfg` (covers F2 + F3 + F5 on the Default fixture)

---

## Bug 1: Multi-asm-goto same-target overwrites `goto_label_snapshots`

- **Bug Family**: F4 / D3
- **Severity**: High — silent miscompile whenever two or more `InlineAsm` instructions with `goto_labels` in the same block target the same label. Any promoted alloca whose definition changes between the two asm-goto sites will use the wrong value on the edge from the earlier asm-goto.
- **Invariant violated**: `NoOverlappingAsmGotoTargets`
- **Config**: `MC_hunt_F4_D3.cfg` (fixture `D3Blocks = {0,1}`, `D3UseSites` for b0 = `<<STORE_PTR(a1), ASM_HAS_GOTO_LABELS(→{1}), STORE_PTR(a1), ASM_HAS_GOTO_LABELS(→{1})>>`)
- **Counterexample**: initial-state violation (`spec/output/F4_D3_bfs_v2.out` — run finished in 0 s)

### Trace Summary

The invariant is a *structural* check on the input IR:

```
NoOverlappingAsmGotoTargets ==
    \A b \in Blocks :
        \A i, j \in 1..Len(UseSites[b]) :
            ( /\ i < j
              /\ UseSites[b][i].kind = "ASM_HAS_GOTO_LABELS"
              /\ UseSites[b][j].kind = "ASM_HAS_GOTO_LABELS" )
            =>
              UseSites[b][i].goto_targets \cap
              UseSites[b][j].goto_targets = {}
```

TLC reports a counterexample immediately because the `D3UseSites` fixture encodes exactly the shape the invariant forbids: block 0 contains two `ASM_HAS_GOTO_LABELS` instructions whose `goto_targets` sets both contain block 1. This IR is legal and realistic (e.g. Linux kernel `ALTERNATIVE` / `static_branch` patterns), so the violation shows the implementation is *vulnerable* to this shape.

The operational consequence is visible in the `base.tla` model of `RenameInstStep`:

```
[] u.kind = "ASM_HAS_GOTO_LABELS" ->
      LET snap == [a2 \in Allocas |-> StackTop(a2)]
      IN
      /\ defStacks' = defStacks
      /\ gotoSnapByLabel' = [gotoSnapByLabel EXCEPT ![b] =
              [t \in Blocks |->
                  IF t \in u.goto_targets
                  THEN snap
                  ELSE @[t]]]
```

Each asm-goto writes a *full replacement* of `gotoSnapByLabel[b][t]` for every `t` in its `goto_targets`. When the second asm-goto shares a target with the first, the second snapshot *overwrites* the first — the earlier snapshot is irretrievable. Then in `RenameFillPhis`:

```
valueFor(sb, a) ==
    IF isGotoTarget(sb) /\ gotoSnapByLabel[b][sb][a] /= "ZERO"
    THEN gotoSnapByLabel[b][sb][a]
    ELSE StackTop(a)
```

the phi at `sb` reads the *later* snapshot on the edge from the *earlier* asm-goto — that's the miscompile.

### Root Cause

`goto_label_snapshots` in `src/ir/mem2reg/promote.rs:531` is keyed by `(block, target-label)`; each new `ASM_HAS_GOTO_LABELS` encountered in the block for that target unconditionally replaces the entry. There is no per-instruction index in the key, so when two asm-gotos in the same block point at the same label, the algorithm loses the earlier snapshot.

### Affected Code

- `src/ir/mem2reg/promote.rs:531` — the `goto_label_snapshots` map (keyed `[block] → [label] → [alloca] → Operand`, missing the intra-block asm-goto occurrence index).
- `src/ir/mem2reg/promote.rs:579-589` — snapshot write site.
- `src/ir/mem2reg/promote.rs:618-659` — phi fill (reads the snapshot).
- `src/ir/mem2reg/promote.rs:632-714` — rename recursion into asm-goto targets.

### Recommendation

Extend the key of `goto_label_snapshots` to include an intra-block asm-goto index, so each `ASM_HAS_GOTO_LABELS` instruction keeps its own snapshot for each of its `goto_targets`. When building phi incoming values for a target block `sb`, the `RenameFillPhis` loop must enumerate every asm-goto in the current block `b` whose `goto_targets` contains `sb` and append one incoming entry per such occurrence (indexed by the new asm-goto occurrence counter), instead of reading a single overwritten snapshot. The corresponding spec change is to turn `gotoSnapByLabel[b][sb]` into `gotoSnapByLabel[b][sb][asmIdx]` (already hinted at by the `asmCursor` field on rename frames, which is captured but unused for snapshot lookup in the current spec).

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| F1 (address-taken / escape) | `MC_hunt_F1.cfg` | 32 distinct, depth 29 (BFS exhausted) | No violation. The filter correctly disqualifies the escape-case alloca (`STORE_VAL(a1)`). |
| F2 (param alloca retained) | `MC_hunt_default_combined.cfg` | 347M distinct, depth 140 (30-min timeout) | No violation. The Default fixture has no parameter allocas, so the invariant is vacuously satisfied; more interesting fixtures would need `is_param = TRUE`. |
| F3 (phi incoming matches preds) | `MC_hunt_default_combined.cfg` | 347M distinct, depth 140 (30-min timeout) | No violation *after the Round-2 spec fix*. The initial run on this invariant exposed a spec-modeling issue, not a real bug — see "Spec fixes during hunting" below. |
| F5 (cost cap + IDOM termination) | `MC_hunt_default_combined.cfg` | 347M distinct, depth 140 (30-min timeout) | No violation. On the Default fixture the aggregate phi cost stays at 2 (well under `MaxPhiCopyCost = 100`), and the CHK fixpoint terminates in ≤ 2 iterations. |
| F6 / D2 (switch-default duplicate target → retarget-once) | `MC_hunt_F6_D2.cfg` | 55 distinct, depth 26 (BFS exhausted) | **Not testable with this fixture.** `D2UseSitesReal` gives block 0 a `SWITCH <<3, 3, 4>>` terminator, so block 3 has only one *distinct* predecessor even though `predsCount[3][0] = 2`. Because `WalkReaches(p=0, runner, stop=idom[3]=0, …)` short-circuits at `r = stop`, no runner lands in `df[runner]` for b = 3, so no phi is ever inserted at block 3 and `PhiCopiesOnEveryEdge` is vacuously true. D2 is real per the analysis report but the fixture needs a second *distinct* predecessor of the phi-bearing block (e.g., another pred b2 with `STORE_PTR(a1)` branching to b3) before D2 becomes reachable in model checking. |

---

## Spec fixes during hunting

One Case B spec issue was found and fixed during bug hunting:

- **`RenameDone` precondition** — `base.tla` originally guarded `RenameDone` with `\E a \in Allocas : Len(defStacks[a]) >= 1`, which is trivially true from the initial state (`defStacks[a] = << "ZERO" >>`). TLC therefore allowed `RenameDone` to fire directly after `ReinsertPhis`, skipping the whole rename pass. This produced a spurious `PhiIncomingMatchesPreds` counterexample in `MC_hunt_F3.cfg`. Fixed by introducing a Boolean `renameStarted` variable (false initially, set true by `StartRename`, required true by `RenameDone`), added to `renameVars` and to the explicit `UNCHANGED` lists in `ReinsertPhis`, `RenameInstStep`, `TRenamePopFrame`, and `TPhiElimPlan`. Trace validation and MC.cfg both still pass after the fix.
