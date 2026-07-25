# CCC mem2reg — Analysis Report (Audit Trail)

This report documents the full code-analysis process for CCC's mem2reg
(SSA-promotion) pass. It is the companion document to `modeling-brief.md`
and contains the raw evidence, file:line citations, coverage statistics, and
excluded/false-positive findings.

---

## Target and Scope

- **Target module**: `src/ir/mem2reg/` (SSA construction + phi elimination) and
  `src/ir/analysis.rs` (CFG, dominators, dominance frontiers). This is a
  single-module case study carved out of CCC (Claude's C Compiler, 143k LoC).
- **Algorithm reference**: Cytron et al. "Efficiently Computing Static Single
  Assignment Form and the Control Dependence Graph" (TOPLAS 1991), plus
  Cooper, Harvey, Kennedy, "A Simple, Fast Dominance Algorithm" (2001).
- **Artifact path**:
  `/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler`
- **Working directory**:
  `/home/ubuntu/Specula/case-studies/ccc-mem2reg/.specula-output`

### Files analyzed (read in full)

| File | LoC | Role |
|------|-----|------|
| `src/ir/analysis.rs` | 376 | CFG (CSR-format `FlatAdj`), Cooper-Harvey-Kennedy dominators, dominance frontiers, dom-tree children |
| `src/ir/mem2reg/mod.rs` | 6 | Re-exports |
| `src/ir/mem2reg/promote.rs` | 1350 | SSA construction: find promotable allocas, insert phis at iterated DF, dominator-tree-DFS variable renaming, asm-goto snapshotting, phi cost limit |
| `src/ir/mem2reg/phi_eliminate.rs` | 585 | Phi elimination: per-edge conflict detection, two-phase copies, trampoline blocks for critical edges, IndirectBranch special case |
| `src/ir/mem2reg/README.md` | 365 | Authoritative design doc (written by the implementers) |

Total: **~2,682 LoC** of core mem2reg logic.

---

## Phase 1 — Reconnaissance

### Classification

The target is **not a distributed system** (no network / RPC / persistence /
membership) and **not a concurrent / lock-free runtime** (no atomics, no
threads, no CAS loops, no memory reclamation). It is a **sequential pure
algorithm over in-memory IR**.

Because the code-analysis framework only formally supports Categories A and B,
this brief is filed under **Category B (concurrent / runtime-like)** as the
nearer of the two: the analytical lens that applies is "state machine with
subtle invariants over shared mutable state" (the def-stacks, phi worklist,
dominator tree) rather than "message-passing / failure injection". TLA+
modelling here will use a single-process, action-interleaving style: each
action is an algorithmic step (compute_dominators iteration, insert_phis
worklist step, rename_block DFS frame, phi elimination emit), not a concurrent
thread. See `modeling-brief.md` section 1 for the full justification.

### Architecture and atomicity

The pipeline is strictly sequential (no parallelism). For a single function:

```
  promote_function(func, promote_params):
     step 1  find_promotable_allocas           (scan all blocks)
     step 2  build_label_map / build_cfg       (CSR-format adjacency)
     step 3  compute_dominators                (Cooper-Harvey-Kennedy fixpoint over RPO)
     step 4  compute_dominance_frontiers       (runner walk, Cytron style)
     step 5  insert_phis                       (iterated DF worklist, per-alloca)
                compute total_phi_cost         (heuristic: sum of preds at each phi site)
                if > MAX_PHI_COPY_COST=50 000:  drop most-expensive allocas
                recompute insert_phis          (after any drops)
     step 6  rename_variables                  (dom-tree DFS with def-stacks and asm-goto snapshots)
     cleanup  remove_promoted_instructions     (remove promoted Alloca/Load/Store)
```

The pass runs **twice** in the pipeline:
1. `promote_allocas` — after IR lowering, before inlining. Skips parameter
   allocas (the inliner uses them as stores from the caller).
2. `promote_allocas_with_params` — after inlining. Also promotes param allocas
   whose IR has an explicit `ParamRef + Store` initialization sequence.

Phi elimination (`eliminate_phis`) is a separate, much-later module pass that
runs immediately before codegen. It lowers every phi into copy instructions,
handling swap/cycle conflicts and critical edges.

---

## Phase 2 — Bug Archaeology

### Coverage statistics

- **Upstream repo** (`anthropics/claudes-c-compiler`): single "initial commit"
  (`6f1b99a Add steps to reproduce kernel defconfig build`). Git log archaeology
  on upstream is **not useful** — the whole tree was committed at once.
- **GitHub issues**: 161 issues scanned. Of those, ~18 were keyword-filtered as
  potentially relevant (mem2reg / ssa / alloca / phi / promote / domin* / O2 /
  miscompile / optim / codegen / undefined). 3 deeply read:
  - `#184` "[SECURITY] CCC -O2 removes volatile loads" — confirmed bug that
    motivated PR #213 (add `volatile: bool` to IR Load/Store); touches DCE,
    GVN, LICM, simplify. **Related to mem2reg** only in that mem2reg
    already skips `volatile: true` allocas (promote.rs:203–206), so the bug
    was downstream, not in promotion. Excluded from brief.
  - `#227` "Result from fuzzing with csmith and yarpgen" — several confirmed
    miscompilations, mostly in initializers / struct-to-union / bool cast
    lowering. No mem2reg-specific bugs surfaced in the reductions posted.
  - `#247`, `#234`, `#228` — flagged "Tests missing", "CPython tests failing",
    "Hello world fails". No specific mem2reg bug identified.
- **Upstream PRs**: 102 total. Only 2 touch mem2reg files:
  - `#213` (merged) — volatile semantics; tangential to mem2reg.
  - `#252` (open, fork-author) — multi-phase optimizer from fork.
- **Real mem2reg development history** lives in the `regehr/claudes-c-compiler`
  fork. It imports the original single-commit upstream and then adds ~4000
  commits of continued development. **Git history on the fork is the primary
  archaeological source** for this case study. This is legitimate because
  commits of the form `Lock: fix_xxx` / `Unlock: fix_xxx` / `Fix ...` are the
  actual development record kept by the Claude-Opus-driven agents that built
  and maintained the compiler.

### Commits touching `src/ir/mem2reg/` or `src/ir/analysis.rs` (regehr fork)

The full curated list: 74 `Lock:`/`Unlock:` task records mention mem2reg / phi /
alloca / ssa / dominator. The bug-fix subset directly relevant to the SSA
construction / phi elimination module:

| SHA (fork) | Summary | Bug family |
|------------|---------|------------|
| `3d6458bd` | Initial `Implement SSA mem2reg pass with phi insertion and elimination` | — |
| `d7e042bb` | `fix_mem2reg_array_addr_promotion` — Store.val reference to an alloca must disqualify it (array-to-pointer decay: `Y.p = local_array`) | **F1 Alloca escape detection** |
| `baedaa75` | `fix_mem2reg_array_escape` — same issue, generalized; also fix `instruction_used_values` to include `Store.val` | **F1** |
| `bd5c2163` → `a0a7ff78` | `fix_riscv_mem2reg_inline_asm_output` — promote allocas used only as `"=r"` asm outputs (RISC-V set_satp_mode page fault) | **F1** |
| `b480e927` | `fix_mem2reg_asm_mem_output` — memory-constraint `"=m","=o","=V","=p"` outputs must disqualify the alloca | **F1** |
| `0f9ae39f` | `fix_alloca_hoisting_goto_into_scope` (fixed upstream) — allocas in unreachable/dead blocks were destroyed by CFG simplify; fix hoists all allocas to entry block in lowering | **F1 / F2** |
| `877dcf18` (`Lock` 26fd9011) | `fix_mem2reg_alloca_promotion_and_phi_simplification` — three sub-bugs: (a) `&&`/`||`/ternary allocas emitted in current block instead of entry; (b) mem2reg rejected allocas with `size > ir_type_size(ty)`; (c) Phi simplification compared IrConst by key so `I32(0) != I64(0)` | **F1 / F3** |
| `92072a32` | `Fix mem2reg SSA renaming for asm goto targets dominated by the goto block` — snapshot def-stacks before processing asm-goto outputs; use snapshots for phi incoming and for dom-tree recursion into goto-target children | **F4** |
| `8e7b537c` | `Fix asm goto missing from CFG edges` across `build_cfg`, `rename_block`, `successor_count`, `retarget_block_edge_once`, backend liveness | **F4** |
| `f99a57d6` | `Fix IrConst::narrowed_to() U32` — U32 case returned `I32(-1)` instead of `I64(v as u32 as i64)`, breaking mem2reg Store-narrowing | **F3** |
| `6b2d94ae` (`Lock` 254a577e) | `fix_phi_explosion_large_switch` — Lua VM dispatch with 84 opcodes × 339 allocas × 81 preds ≈ 2.2M copy insts → 18 MB stack frame → SIGSEGV; added `MAX_PHI_COPY_COST = 50 000` | **F5 (cost limit)** |
| `d9cc91d7` (`Lock` 21f49734) | `fix_phi_elimination_critical_edges` — TCC `label_pop`: copies placed at multi-succ pred corrupt values on not-taken edge; add trampoline blocks on critical edges | **F6** |
| `c3dee533` / `42979acc` (`Lock` c97ece71) | `fix_phi_elim_and_regalloc_liveness` — IndirectBranch (computed goto) bypasses trampoline blocks at runtime (hardware jump goes directly to label, not via CFG metadata); emit copies before terminator instead | **F6** |
| `ad702eb3` (`Lock` db9c801d) | `optimize_phi_elimination_reduce_copies` — was allocating temporaries for ALL phis in multi-phi blocks; now detects per-edge cyclic conflicts (swap: `a=b, b=a`, chain: `a=b, b=c`) | **F7 (copy cycles)** |
| `20a90734` | `fix_alloca_coalescing_overlap` — stack-slot coalescer was coalescing allocas whose pointers flowed through GEPs (related to **F1 escape**) | **F1** |
| `b959f528` | `fix_cfg_simplify_fold_const_phi_cleanup` — folding `CondBranch { cond: const }` to `Branch` did not clean up stale phi entries in the not-taken target; can propagate wrong values | **F3 (phi well-formedness)** |

### Bug-family summary from archaeology

Every mem2reg bug in the historical record falls into **one of seven**
mechanisms:

- **F1. Alloca eligibility / escape** — an alloca whose address escapes in a
  way the filter didn't catch (Store.val, GEP chain, asm `+m` input, asm `=m`
  output, alloca of non-entry block, alloca in unreachable block).
- **F2. Alloca placement** — alloca is emitted into the wrong block (short-
  circuit `&&`/`||`, ternary, goto-into-scope), so mem2reg refuses to promote
  or the alloca is destroyed by CFG cleanup.
- **F3. Phi / constant well-formedness** — `narrowed_to` bug for U32; phi
  simplification compares IrConst by hash so `I32(0) != I64(0)`; CFG simplify
  leaves stale phi incoming entries after const-branch folding.
- **F4. Asm-goto edges** — `InlineAsm.goto_labels` is an implicit CFG edge; it
  was missing from `build_cfg`, `rename_block`, `successor_count`,
  `retarget_block_edge_once`, and backend liveness. Also: definitions
  after the asm-goto instruction in the same block must NOT be visible along
  the goto edge (snapshot fix).
- **F5. Iterated DF cost** — phi placement at iterated DF can produce an
  explosion for dispatch-style CFGs (large switch / computed goto).
- **F6. Phi elimination edge placement** — critical edges need trampolines;
  computed goto (IndirectBranch) cannot use trampolines and must emit copies
  pre-terminator.
- **F7. Phi elimination copy cycles** — swap / chain / multi-way rotations
  require temporaries; getting the copy graph right is the classic
  "lost-copy problem".

These seven families are the skeleton of the modeling brief.

---

## Phase 3 — Deep Analysis

Deep analysis was performed by three parallel file-level subagents (one on
`analysis.rs`, one on `promote.rs`, one on `phi_eliminate.rs`). Each read its
file completely and applied the "split operation window", "missing guard",
"code path inconsistency", and "reference-deviation" patterns. The findings
below were cross-validated against the bug archaeology. Findings are numbered
**D1..Dn** to distinguish them from the historical-bug families **F1..F7**.

### D1 — CFG `build_cfg` does not de-duplicate predecessor entries

**Evidence**: `src/ir/analysis.rs:129-140, 153-166, 171-182`.

For a `CondBranch { true_label, false_label }` with `true_label ==
false_label`, the successor list correctly de-dupes (line 136:
`if !succs[i].contains(&f32v)`), but the predecessor list at line 139
**unconditionally pushes** the source block to `preds[f]`. Same pattern for
`Switch` (line 164) when `default == case_target`, and for `InlineAsm.goto_labels`
colliding with a terminator target (line 179).

**Effect**:

1. **Dominance frontier over-counts join points.** `compute_dominance_frontiers`
   at line 310 tests `if preds.len(b) < 2 { continue; }`. A block with a single
   logical predecessor that appears twice in `preds` will be treated as a join
   point and its DF will be populated. This can cause **spurious phi insertion**
   at a block that has only one real incoming CFG edge.
2. **Phi cost heuristic over-estimates.** `promote.rs:128` uses
   `preds.len(block_idx)` to estimate copy cost per phi. Duplicate entries
   inflate this number, potentially triggering the 50 000-cost limit and
   **dropping promotions that would otherwise fit**.
3. **NOT a direct correctness hazard** for the generated code, because the
   phi rename pass uses `get_successor_labels` (promote.rs:723), which
   **also de-dupes**, so the phi's `incoming` list does not grow a duplicate
   entry. Phi elimination operates on the `incoming` list, so each logical
   edge still emits one copy.

**Confidence**: **Confirmed** by re-reading both call sites. Severity: code
quality / compile-time efficiency, not miscompilation. Still an invariant
violation worth documenting.

### D2 — `retarget_block_edge_once` only retargets ONE syntactic occurrence

**Evidence**: `src/ir/mem2reg/phi_eliminate.rs:105-157`.

```rust
Terminator::Switch { cases, default, .. } => {
    if *default == old_target { *default = new_target; return; }
    else {
        for (_, t) in cases.iter_mut() {
            if *t == old_target { *t = new_target; return; }   // <-- returns after FIRST match
        }
    }
}
```

And likewise for `InlineAsm.goto_labels` (line 147-155) and for
`IndirectBranch.possible_targets` (line 123-130).

**Scenario**: A Switch with `default: B, cases: [(1, B), (2, B), (3, C)]` and a
phi at `B`. Phi elimination creates ONE trampoline `T` for `(pred_idx, B)`
and calls `retarget_block_edge_once(pred, B, T)`. Only `default` is rewritten
to `T`; `cases[0]` and `cases[1]` still branch directly to `B`. At runtime:

| taken edge | runs trampoline? |
|------------|-------------------|
| `default`  | yes — executes phi copies |
| case 1     | **no — phi destination undefined** |
| case 2     | **no — phi destination undefined** |

**Effect**: **Potential miscompilation** whenever a `Switch` (or an
`InlineAsm.goto_labels` list with duplicates, or an `IndirectBranch.possible_targets`
list with duplicates) has multiple syntactic edges to the same phi-target AND
the pred has multiple successors (so a trampoline is required).

**Caveats / compensating mechanisms**:
- `IndirectBranch` predecessors are specifically **excluded** from trampoline
  creation by `place_copy`/`place_copies` (lines 435, 449). So the
  `possible_targets` case of D2 is dead code; copies go pre-terminator
  instead. This compensates for `IndirectBranch`.
- For `Switch`: CCC's IR lowering typically produces canonical switches where
  `default` and `cases` are distinct. But constant folding + CFG simplify can
  produce degenerate switches. Worth modeling.
- For `InlineAsm.goto_labels`: Linux ALTERNATIVE macros are the main source of
  asm-goto; the typical pattern has distinct labels. But once asm-goto +
  computed goto are combined, a trampoline may coincide.

**Confidence**: **Confirmed by code inspection**. No compensating check
elsewhere. **High-priority model-checkable finding.**

### D3 — Multiple asm-goto instructions in same block overwrite snapshot

**Evidence**: `src/ir/mem2reg/promote.rs:531, 578-589`.

```rust
let mut goto_label_snapshots: FxHashMap<BlockId, Vec<Operand>> = FxHashMap::default();
for (inst_idx, inst) in func.blocks[block_idx].instructions.drain(..).enumerate() {
    match inst {
        Instruction::InlineAsm { ..., goto_labels, ... } => {
            if !goto_labels.is_empty() {
                let snapshot = ...;                     // captured at CURRENT def-stack state
                for (_, label) in &goto_labels {
                    goto_label_snapshots.insert(*label, snapshot.clone()); // <-- overwrites
                }
            }
            // then push asm output values into def_stacks
        }
        ...
    }
}
```

**Scenario**: block contains two inline-asm instructions asm-goto1 and
asm-goto2 in sequence, both targeting `L`. Asm-goto1 writes output `x`
(pushes onto def_stacks[x]). Asm-goto2 then captures its snapshot — which now
includes the new `x` — and inserts `goto_label_snapshots[L] = snapshot_2`,
overwriting asm-goto1's snapshot. The phi at `L` will be filled with the
post-asm-goto1 state, which is wrong for the edge asm-goto1 → L (that edge
should see the pre-output state captured at asm-goto1).

**Effect**: **Potential miscompilation** for the Linux ALTERNATIVE-style
pattern with two asm-gotos sharing a target. Rare but plausible.

**Confidence**: **Confirmed**.

### D4 — `compute_dominators` has no iteration limit

**Evidence**: `src/ir/analysis.rs:256-293`.

```rust
let mut changed = true;
while changed {
    changed = false;
    for &b in rpo.iter().skip(1) { ... if idom[b] != new_idom { idom[b] = new_idom; changed = true; } }
}
```

Cooper-Harvey-Kennedy is proven to converge in ≤ 2 passes for reducible CFGs
and in O(size) passes for irreducible CFGs. CCC never validates reducibility,
and there is no hard iteration cap. **Theoretical non-termination** for
adversarial irreducible CFGs (`goto`-heavy C, computed goto, `setjmp`-based
coroutines).

**Compensating mechanism**: The CHK algorithm converges on irreducible CFGs
too, but the bound is `O(#back_edges * n)`. No fuzz run has hit a non-terminating
case; this is a theoretical finding.

**Confidence**: **Likely**. Worth a liveness invariant in the model.

### D5 — `compute_reverse_postorder` is recursive (unbounded stack)

**Evidence**: `src/ir/analysis.rs:196-209`. DFS is implemented as a
non-tail-recursive Rust function. Deep CFGs (e.g., a long sequence of
fall-through switch cases, or a deeply nested `if/else if/else if/...`
chain) risk stack overflow.

**Compensating mechanism**: None. `compute_live_intervals` (regalloc) and
`find_natural_loops` (LICM) do the same thing.

**Confidence**: **Confirmed** by code inspection. Real-world risk is medium
(8 MB OS stack ÷ ~200 B/frame ≈ 40 000 blocks), but fuzzing could find it.

### D6 — `find_promotable_allocas` parameter-skip is positional

**Evidence**: `src/ir/mem2reg/promote.rs:189-200, 332-358, 752-764`.

The code counts **Alloca instructions in order of appearance in the entry
block** and skips the first `func.params.len()` allocas:

```rust
if !promote_params && idx < num_params {
    return None;
}
```

If IR lowering ever produces fewer than `num_params` param allocas in the entry
block (e.g., an inlined caller passes a parameter as a constant and its alloca
is optimized away, or a parameter of void type doesn't get an alloca), then
the first N allocas the loop sees are not all parameter allocas, and a
**local-variable alloca could be erroneously skipped** as if it were a param.

`remove_promoted_instructions` uses the same positional indexing at line 757
to decide which allocas to keep.

**Mitigation**: `func.param_alloca_values` (line 332) records the actual
parameter alloca `Value`s. It is used in a different filter that removes
param allocas *without stores* from promotion (lines 352-358), not for the
skip-first-N logic. So the positional skip and the value-set filter are two
independent mechanisms, and there is no cross-check.

**Confidence**: **Speculative** — depends on whether the IR lowering ever
produces fewer allocas than params. Low probability in practice but a clean
invariant target.

### D7 — `insert_phis` worklist per-alloca

**Evidence**: `src/ir/mem2reg/promote.rs:364-391`.

```rust
for (alloca_idx, info) in alloca_infos.iter().enumerate() {
    let mut worklist: VecDeque<usize> = info.def_blocks.iter().copied().collect();
    let mut has_phi: FxHashSet<usize> = FxHashSet::default();
    let mut ever_in_worklist: FxHashSet<usize> = info.def_blocks.clone();
    while let Some(block) = worklist.pop_front() {
        for &df_block in &df[block] {
            if has_phi.insert(df_block) {
                phi_locations[df_block].insert(alloca_idx);
                if ever_in_worklist.insert(df_block) {
                    worklist.push_back(df_block);
                }
            }
        }
    }
}
```

Straightforward Cytron iterated-DF algorithm. Both `has_phi` (cuts the
DF-propagation) and `ever_in_worklist` (avoids re-adding to the queue) are
per-alloca, so the termination is clean: each block is added to the worklist
at most once per alloca, so `insert_phis` is O(V × A) worst case where A is
the number of promoted allocas.

**Edge cases verified**:
- `def_blocks.is_empty()` but `use_blocks` non-empty — no phi added; Loads
  read zero constant (line 461). Correct for C semantics of uninitialized
  scalar locals.
- `def_blocks` entirely in unreachable blocks — these blocks are in `df`
  (compute_dominance_frontiers iterates `0..num_blocks`), but since
  `preds[unreachable] < 2`, their DF is empty, so no phi placement triggers.
  Benign.
- An alloca's DF entirely covered by pre-existing phis — `has_phi.insert`
  returns false and the DF step is a no-op.

No bug found here.

### D8 — `rename_block` asm-goto recursion uses pushed snapshot

**Evidence**: `src/ir/mem2reg/promote.rs:668-714`.

For each dom-tree child of the current block:
- If the child is an asm-goto target (i.e., its `BlockId` is in
  `goto_label_snapshots`), the code records `child_depths` **before** pushing
  the snapshot, pushes the snapshot onto each alloca's def-stack, recurses
  into the child, and then truncates the def-stacks back to `child_depths`.
- Otherwise, normal recursion.

This nesting is sound: the child's own `stack_depths`/truncate logic
(lines 498, 717) restores to the child's own pre-work depth (which equals
`child_depths + snapshot_pushes`), and the outer truncate then removes the
snapshot pushes.

One subtle interaction: if the **parent** block contains multiple asm-gotos,
`goto_label_snapshots` accumulates entries across the parent's scan (see D3).
When the parent then recurses into a dom-tree child that is an asm-goto target,
it uses whichever snapshot is currently stored in the map — which may be from
a different asm-goto than the one that created the edge.

### D9 — `get_successor_labels` vs `build_cfg` asymmetry (F4 cousin)

**Evidence**: `src/ir/mem2reg/promote.rs:723-745` (de-dupes) vs
`src/ir/analysis.rs:129-140, 153-166` (doesn't de-dupe preds, but does
de-dupe succs).

As described in D1: the two analyses agree on succs but disagree on preds.
The phi `incoming` list is driven by `get_successor_labels` (one entry per
unique successor label per predecessor). No direct miscompilation, but the
invariant `phi.incoming.len() == preds[block_idx].len()` is violated whenever
a Switch / CondBranch / InlineAsm-goto has duplicated edges to the phi block.
Any downstream code that relies on that invariant would be wrong.

### D10 — Defensive Load retention in `remove_promoted_instructions`

**Evidence**: `src/ir/mem2reg/promote.rs:797-802`.

```rust
Instruction::Load { ptr, .. } => {
    // Loads to promoted allocas have already been replaced with Copy
    // But there shouldn't be any left; just in case, keep them
    !alloca_to_idx.contains_key(&ptr.0)
}
```

The comment is misleading: `retain` keeps instructions where the closure
returns true. `!contains_key` returns true for `Load`s of **not-promoted**
allocas, so those are kept, and `Load`s of promoted allocas are removed. This
is correct. The comment "just in case, keep them" is wrong — the code removes
them. **Documentation bug only.**

---

## Cross-Reference Summary

| Deep-analysis finding | Maps to historical family |
|-----------------------|---------------------------|
| D1 preds duplication | relates to F4 (asm-goto edges) and F5 (phi cost) |
| D2 retarget-once | relates to F6 (phi elim critical edges) |
| D3 snapshot overwrite | relates to F4 (asm-goto) |
| D4 no fixpoint iteration limit | novel (algorithmic) |
| D5 recursive DFS | novel (implementation hazard) |
| D6 positional param skip | relates to F1 (alloca filter) |
| D7 insert_phis | no bug; validates algorithm |
| D8 asm-goto recursion | extends F4 (asm-goto) |
| D9 succ/pred asymmetry | duplicate of D1 |
| D10 defensive comment | documentation only |

---

## Excluded / False-Positive Findings

These were investigated and excluded from the modeling brief.

| Excluded finding | Why not reported |
|------------------|-------------------|
| "GEP of alloca escapes alloca" | `find_promotable_allocas`'s catch-all `_` arm at promote.rs:313-319 disqualifies any alloca appearing in `used_values()` of any instruction other than Load/Store/InlineAsm. Confirmed by reading `instruction.rs` `used_values`. |
| "Multiple phis share same dest" | Impossible: phi dests are fresh values allocated from `next_value`, guaranteed unique. |
| "Phi with zero incoming entries" | Confirmed possible only if every predecessor is unreachable (in which case the block itself is unreachable and should not be visited by rename_block). Rename only walks dom-tree children of entry. |
| "Store narrowing with Operand::Value source" | `narrowed_to` is only applied to `Operand::Const`; `Operand::Value` passes through unchanged (promote.rs:558-564). This is correct: SSA values are already typed; the narrowing is specifically to work around IR lowering always producing I64 literals. |
| "phi.incoming.len() smaller than preds.len()" causing miscompile | Verified: phi elimination iterates `phi.incoming`, not `preds`. So duplicated preds do not produce extra copies; each logical edge emits one copy. The invariant is violated but no code relies on it. |
| "InlineAsm output `"=a"` vs `"=r"` treatment" | Both are register-constraint outputs; treated identically by mem2reg. The `constraint_is_memory_only` predicate disqualifies only the memory-class constraints. |
| "Volatile Load/Store handling inside mem2reg" | mem2reg filters out volatile allocas at promote.rs:203-206. Volatile loads/stores of **non-alloca** pointers (volatile-qualified pointers to heap) are outside mem2reg's scope; see issue #184 and PR #213 for that side. |

---

## Coverage Statistics

- **Source files analyzed in full**: 4 (analysis.rs, mem2reg/mod.rs,
  promote.rs, phi_eliminate.rs), covering 2,682 LoC. README.md (365 LoC)
  also read.
- **Parallel subagents**: 3 (one per major file) for deep analysis.
- **Git commits reviewed**: 74 Lock/Unlock task records + ~15 direct fix
  commits in regehr fork; 1 commit in upstream (initial import).
- **GitHub issues read (full comment threads)**: 3 (#184 volatile, #227
  csmith/yarpgen, #115 alias analysis). Issues deeply considered: ~18.
- **GitHub PRs reviewed**: 4 (PR #213 volatile, PR #252 multi-phase
  optimizer, PR #17 -O levels, PR #89 regalloc F32/F64).
- **Deep-analysis findings (D)**: 10. Of these:
  - 2 are confirmed correctness bugs (D2, D3)
  - 1 is an invariant violation without direct miscompile (D1/D9)
  - 2 are robustness concerns (D4, D5)
  - 1 is speculative (D6)
  - 1 is documentation-only (D10)
  - 3 are verifications that no bug exists (D7, D8, D9)
- **Historical Bug Families (F)**: 7.

---

## Notes on Methodology

- **No git history in upstream**: as noted, the upstream anthropics repo has a
  single commit. All git archaeology was performed on the `regehr` fork,
  which captures the real development trajectory including the
  Lock/Unlock task-file convention used by the Claude-driven development loop.
- **Category mismatch**: this target is neither Category A (distributed) nor
  Category B (concurrent) — it is a sequential algorithm with state-machine
  invariants. The modeling brief explains that distinction and uses the
  concurrent-analysis playbook only as the closer template (single-process
  action interleaving rather than threads + atomics).
- **One-module focus**: per the task brief, frontend, regalloc, linker, and
  codegen are explicitly out of scope. Any finding that crosses the module
  boundary (e.g., `fix_i686_wide_phi_copy_propagation`, which interacts with
  backend wide-value tracking) is excluded from the model.

---

## Key File:Line Index

For the spec author's convenience:

| Concept | Location |
|---------|----------|
| `MAX_PROMOTABLE_ALLOCA_SIZE = 8` | `promote.rs:33` |
| `MAX_PHI_COPY_COST = 50_000` | `promote.rs:118` |
| alloca eligibility filter | `promote.rs:181-360` |
| asm-goto snapshot capture | `promote.rs:578-589` |
| asm-goto recursion with snapshot | `promote.rs:668-714` |
| iterated DF worklist | `promote.rs:364-391` |
| variable renaming | `promote.rs:485-720` |
| Cooper-Harvey-Kennedy idom | `analysis.rs:218-296` |
| Cytron-style DF | `analysis.rs:302-326` |
| conflict detection (swap/cycle) | `phi_eliminate.rs:199-235` |
| critical edge / trampoline | `phi_eliminate.rs:159-190, 434-458` |
| IndirectBranch special case | `phi_eliminate.rs:435, 449` |
| `retarget_block_edge_once` | `phi_eliminate.rs:105-157` |
