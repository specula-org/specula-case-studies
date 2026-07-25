# CCC mem2reg — Modeling Brief

## 1. System Overview

- **System**: `ccc-mem2reg` — the SSA-promotion pass of *Claude's C Compiler*
  (CCC), a from-scratch C compiler written in Rust targeting x86-64 / AArch64 /
  RISC-V / i686. CCC itself is 143 k LoC across 351 `.rs` files, but this case
  study deliberately scopes to a **single module**:
  `src/ir/mem2reg/` + `src/ir/analysis.rs` ≈ **2 682 LoC** of core logic.
- **System category**: **Sequential pure algorithm**, filed under **Category B**
  as the nearer of the two supported categories. This is *not* a concurrent
  / lock-free system: there are no threads, atomics, CAS loops, or memory
  reclamation. But the analytical lens that applies is the Category B one —
  "state machine over shared mutable state (def-stacks, worklist, dominator
  tree) with subtle invariants" — rather than the Category A "message
  passing / failure injection" lens. TLA+ will use a single-process
  action-interleaving style: each action is an algorithmic step (one idom
  iteration, one IDF worklist step, one `rename_block` frame, one phi
  emission), not a concurrent thread.
- **Algorithm**: Classic Cytron et al. SSA construction (TOPLAS 1991) with
  the Cooper-Harvey-Kennedy iterative immediate-dominator algorithm (2001),
  followed by iterated dominance frontier phi placement and dominator-tree-DFS
  variable renaming. Phi elimination is a separate pass that lowers phis to
  parallel copies with Briggs-style conflict detection and trampoline blocks
  on critical edges.
- **Key deviations from textbook**:
  1. Scalar-only promotion (`MAX_PROMOTABLE_ALLOCA_SIZE = 8`), non-volatile,
     not address-taken. The "address-taken" check is open-coded across
     `Load`/`Store`/`InlineAsm`/everything-else arms.
  2. Cost-bounded phi placement (`MAX_PHI_COPY_COST = 50 000`). Expensive
     allocas are dropped from promotion instead of inserted.
  3. **Asm-goto snapshot semantics** for `InlineAsm.goto_labels` — definitions
     produced after an asm-goto must not be visible along its goto edges.
  4. Phi elimination uses **per-phi global temporary allocation** (if a phi
     is conflicting on any edge, it uses a temp on all edges) and **trampoline
     blocks on critical edges**, but places copies *pre-terminator* for
     `IndirectBranch` predecessors (computed goto bypasses CFG).
- **Concurrency model**: strictly sequential. A single pass visits each
  function once per invocation; mem2reg runs twice in the pipeline
  (before and after inlining).

## 2. Bug Families

The archaeology (`analysis-report.md` §2) plus deep analysis
(`analysis-report.md` §3) identifies **seven recurring mechanisms** in
CCC-mem2reg history. Each family groups multiple distinct historical bugs.

### Family F1 — Alloca eligibility / escape detection

**Mechanism**: an alloca is promotable only if its address never escapes. The
filter scans all uses of the alloca `Value` and disqualifies on any
non-Load/Store/InlineAsm use. Each historical bug is a use-site the filter
forgot to check.

**Evidence**:
- Historical:
  - `d7e042bb` / `baedaa75` — `Store.val` reference to alloca (array-to-pointer
    decay: `Y.p = local_array`) was missed. Mbedtls selftest SIGSEGV.
  - `0f9ae39f` / `fix_alloca_hoisting_goto_into_scope` — allocas emitted in
    non-entry blocks (goto-into-scope, `&&`/`||`/ternary) got destroyed by
    CFG simplify or never promoted.
  - `bd5c2163` → `a0a7ff78` — allocas used as `"=r"` InlineAsm outputs were
    disqualified instead of being promoted; RISC-V `set_satp_mode` page
    fault.
  - `b480e927` — memory-constraint (`"=m"`,`"=o"`,`"=V"`,`"=p"`) InlineAsm
    outputs must disqualify, not promote.
  - `877dcf18` sub-bug — `size > ir_type_size(ty)` (e.g., I32 with alignment
    padding to 8 bytes) rejected by `<=` check instead of `<=`.
  - `20a90734` — stack-slot coalescer also has a (separate) escape-analysis
    gap for GEP chains.
- Code analysis: **D6** — positional parameter-skip depends on
  `#allocas_in_entry == #params`, which can drift if lowering ever elides a
  param alloca.

**Affected code paths**: `find_promotable_allocas` (`promote.rs:181-360`),
`remove_promoted_instructions` (`promote.rs:748-807`),
`Instruction::used_values` in `instruction.rs`.

**Modeling approach**:
- Variables: abstract alloca set `Allocas`, address-taken flag per alloca,
  use-site kind set `{Load, Store_ptr, Store_val, GEP, Asm_out_reg,
  Asm_out_mem, Asm_in_val, Other}`.
- Actions: `DeclareAlloca`, `UseAsLoad`, `UseAsStore(kind)`, `UseAsAsm(kind)`,
  `UseAsOther`. `Promote(alloca)` is enabled iff no `Other` / `Store_val` /
  `GEP` / `Asm_in_val` / `Asm_out_mem` exists.
- Granularity: one action per use-site occurrence; promotion is a derived
  predicate.

**Priority**: **High**. Largest historical bug count; every miss is a
miscompile.

### Family F2 — Alloca placement (entry vs non-entry, reachable vs not)

**Mechanism**: mem2reg scans the entry block *and* all non-entry blocks for
allocas, but the filter and `remove_promoted_instructions` make positional
assumptions (first *N* allocas in entry block = parameters). Multiple bugs
stem from allocas being emitted in the wrong block or being destroyed.

**Evidence**:
- Historical: `0f9ae39f` (goto-into-scope), `877dcf18` sub-bug (`&&`/`||`
  ternary alloca in non-entry block), `11d133d7` / `a3307c7`
  (param-alloca promotion via explicit `ParamRef + Store`).
- Code analysis: **D6** — positional param skip. **D7** — verified that
  unreachable-block allocas are handled correctly by the CFG-reachability
  guards in DF.

**Affected code paths**: `promote.rs:189-200, 230-242, 332-358, 748-807`.

**Modeling approach**:
- Variables: each alloca has an `origin_block`. Block set includes reachable
  and unreachable blocks.
- Invariant: every promoted alloca's `Value` ID is either in
  `param_alloca_values` (kept in entry block) or is removed by cleanup.
- Invariant: the first *N* allocas in the entry block are exactly the
  parameter allocas.

**Priority**: **Medium-High**. Fewer historical bugs than F1 but same
miscompile severity.

### Family F3 — Phi / constant well-formedness

**Mechanism**: phi nodes and constants interact across passes. Bugs occur
when constants of different `IrType`s should be equal but are compared
structurally, or when stale phi operands linger after CFG simplification.

**Evidence**:
- Historical: `f99a57d6` (`IrConst::narrowed_to(U32)` returned `I32(-1)`
  instead of `I64((v as u32) as i64)`, breaking Store-narrowing);
  `877dcf18` sub-bug (phi simplification compared `IrConst` by hash:
  `I32(0) != I64(0)` preventing dead-code elimination);
  `b959f528` (`fix_cfg_simplify_fold_const_phi_cleanup` — const-fold of
  CondBranch left stale phi incoming entries).
- Code analysis: no new bug. `narrowed_to` is only applied to
  `Operand::Const` (promote.rs:559-563), which is correct — `Operand::Value`
  doesn't have the "I64 literal stored in I32 slot" issue.

**Affected code paths**: `promote.rs:558-564` (narrowing),
`cfg_simplify.rs` (outside scope, but interacts).

**Modeling approach**:
- Variables: phi `incoming` list `(Operand, pred_block)` per phi; predecessor
  set of each block.
- Invariant: `|phi.incoming| == |preds[phi_block]|`.
- Invariant: every `pred_block` in `phi.incoming` is an actual predecessor of
  `phi_block`.

**Priority**: **Medium**. Critical once triggered, but CCC's test suite
catches most of these.

### Family F4 — Asm-goto edges everywhere

**Mechanism**: `InlineAsm.goto_labels` are implicit CFG edges that must be
added by every CFG-analysis consumer. They were historically missing from
**five separate call sites** (`8e7b537c`). Additionally, definitions produced
*after* the asm-goto within the same block must not be visible along the
goto edge — hence the snapshot fix (`92072a32`).

**Evidence**:
- Historical: `8e7b537c` (CFG build + rename_block + successor_count +
  retarget + liveness); `92072a32` (snapshot fix for SSA renaming into
  asm-goto targets).
- Code analysis: **D3** — when two asm-goto instructions in the same block
  target the same label, the second's snapshot overwrites the first's in
  `goto_label_snapshots`. The phi fill for that label uses the *later*
  snapshot even on the edge from the *earlier* asm-goto.

**Affected code paths**: `analysis.rs:171-182` (`build_cfg`),
`promote.rs:531, 578-589, 632-659, 668-714` (snapshot + recursion),
`phi_eliminate.rs:92-100, 147-155` (successor_count / retarget).

**Modeling approach**:
- Variables: each block has a list of `(point_in_block, goto_targets)`
  anchors (one per asm-goto instruction).
- Actions: `InsertInstruction(point, kind, [goto_targets])`,
  `SnapshotDefStacks(point)`, `FillPhi(edge, snapshot)`.
- Granularity: distinguish *each asm-goto* as a separate action so a block
  with multiple asm-gotos produces distinct snapshots.

**Priority**: **High**. Large historical footprint; D3 is a confirmed new
edge case.

### Family F5 — Phi placement cost / iterated DF blow-up

**Mechanism**: iterated DF placement is O(|DefBlocks| × |IteratedDF|), which
blows up on dispatch-style CFGs (large switch / computed goto). Phi
elimination then multiplies by predecessor count → stack overflow or huge
code. CCC's mitigation is a **cost cap** that drops the most expensive
allocas from promotion.

**Evidence**:
- Historical: `6b2d94ae` / `fix_phi_explosion_large_switch` — Lua's
  `luaV_execute` (84 opcodes × 339 allocas × 81 preds) produced ~2.2 M
  copy instructions, ~18 MB stack frame, SIGSEGV.
- Code analysis: **D1** — `preds` duplication can inflate the cost estimate
  and cause an alloca to be dropped when it wouldn't otherwise be. **D4** —
  the `compute_dominators` fixpoint has no iteration cap; irreducible CFGs
  could theoretically diverge. **D5** — recursive DFS in
  `compute_reverse_postorder` could stack-overflow on a CFG with ~40 000+
  blocks.

**Affected code paths**: `promote.rs:118-161` (cost estimate + drop),
`promote.rs:364-391` (IDF), `analysis.rs:196-296` (DFS + idom fixpoint).

**Modeling approach**:
- Variables: per-alloca phi placement set, total estimated cost, dropped-set.
- Actions: `InsertPhi(alloca, block)`, `EstimateCost`,
  `DropExpensive(alloca)`.
- Invariant: after the drop step, `estimated_cost <= MAX_PHI_COPY_COST`.
- Invariant: the fixpoint terminates (no `DropExpensive` re-enabled after
  being disabled).

**Priority**: **Medium**. The cost cap hides real correctness-adjacent
questions (what if the drop logic itself has a bug and leaves a used alloca
without a phi?).

### Family F6 — Phi elimination edge placement

**Mechanism**: phi copies on a critical edge (pred has multiple successors,
target has phi) must not corrupt values on other edges. The fix is to split
the critical edge via a trampoline block. But trampolines are useless for
computed goto (`IndirectBranch`) — the runtime jump bypasses them. And the
retargeting step assumes one syntactic edge per logical edge, which fails
for switches and asm-gotos with duplicated targets.

**Evidence**:
- Historical: `d9cc91d7` / `fix_phi_elimination_critical_edges` (TCC segfault
  when copy corrupted other-branch value); `c3dee533` / `fix_phi_elim_and_regalloc_liveness`
  (IndirectBranch must use pre-terminator copies, not trampoline).
- Code analysis: **D2 — confirmed** correctness bug. For a `Switch` with
  `default: B, cases: [(1, B), (2, B), (3, C)]`, phi elimination creates ONE
  trampoline for `(pred, B)` and calls `retarget_block_edge_once` which
  **returns after the first match**, rewriting only `default` to the
  trampoline. Cases 1 and 2 still branch directly to `B`, skipping the phi
  copies → phi destination is uninitialized on those runtime paths. Same
  issue applies to `InlineAsm.goto_labels` with duplicate targets.

**Affected code paths**: `phi_eliminate.rs:105-157` (retarget-once),
`phi_eliminate.rs:159-190` (trampoline create),
`phi_eliminate.rs:434-458` (place_copy — IndirectBranch special case),
`phi_eliminate.rs:256-286` (main loop).

**Modeling approach**:
- Variables: `CFG_edges` = multiset of `(pred, succ, kind)` where kind distinguishes
  `Terminator_branch`, `Switch_case`, `Switch_default`, `Asm_goto`,
  `IndirectBranch_target`.
- Variables: `phi_copy_placement[edge]` — whether phi copies execute on this
  edge.
- Actions: `CreateTrampoline(pred, target)`, `RetargetEdge(edge, new_target)`.
- Invariant: for every edge `(pred, target)` with target having a phi, the
  phi's copy instructions execute along that edge.

**Priority**: **Very high**. D2 is a confirmed miscompile-capable bug with
clear reproducer potential.

### Family F7 — Phi elimination copy cycles

**Mechanism**: multiple phis on the same edge can form cycles (swap, chain,
rotation). Naive copies lose values; temporaries break the cycle.
CCC allocates **shared (per-phi, global across edges) temporaries** and
runs a two-phase protocol: save into temps in pred (phase 1), restore from
temps in target (phase 2).

**Evidence**:
- Historical: `ad702eb3` / `optimize_phi_elimination_reduce_copies` — was
  using temporaries for ALL phis; now only for cycle-involved phis.
- Code analysis: `find_conflicting_phis` (`phi_eliminate.rs:199-235`)
  uses a "conservative safety net" that over-approximates (marks any phi
  whose dest is read by a conflicting phi). Verified correct for 2-cycles,
  3-cycles, chains, self-copies.

**Affected code paths**: `phi_eliminate.rs:199-235, 321-372, 401-431`.

**Modeling approach**:
- Variables: per-edge copy graph `CopyGraph[edge] = {(dest, src) | phi}`.
- Actions: `DetectCycle`, `AllocateTemp`, `EmitSave(temp)`, `EmitRestore(temp)`.
- Invariant: after phase 1 + phase 2, every phi destination holds the
  semantically-correct incoming value for the edge taken.

**Priority**: **Medium**. The algorithm is well-tested; we verified the
conservative safety-net is sound by case analysis. Model-checking would
confirm the invariant holds for arbitrary copy graphs.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|------|-----|-----|
| Alloca eligibility as a predicate over use-site kinds | F1 is the largest bug family; every miss is a miscompile | State: alloca → use-site-kind multiset. Action: `UseAsKind(alloca, kind)`. Derived: `promotable(a) iff uses(a) ⊆ {Load, Store(ptr=a), Asm_out_reg}` |
| CFG with **multiset edges** distinguishing syntactic vs logical | D2 is driven by this asymmetry | Edge is `(pred, succ, syntactic_id)`; `syntactic_id` disambiguates e.g. `switch case 1` vs `switch case 2` both going to B |
| Dominator + DF computation as a two-step fixpoint | Validates D4 (termination) and D7 (IDF worklist) | Action: `IdomIterate` and `DF_propagate_step` |
| Iterated DF worklist with a `has_phi` bit per alloca | F5 cost analysis needs exact phi placement | Set-based state, per-alloca |
| `rename_block` as a state machine with `(block_idx, phi_pushed, load_emitted, store_popped, asm_snapshot)` | Captures F4 snapshot semantics + D3 multi-asm-goto interaction | Each instruction becomes one action; asm-goto captures snapshot BEFORE outputs |
| Phi elimination: per-edge copy graph + trampoline placement | F6 / F7 both hinge on this | Action: `CreateTrampoline(pred, target)`, `RetargetEdge(edge)`; invariant on "all logical paths that reach target via pred execute phi copies" |
| The full `IndirectBranch` special case | F6 — must verify copies-before-terminator is correct when asm-goto fallthrough exists too (D2 variant) | Model has both terminator kind and per-instruction asm-goto edges |

### 3.2 Do Not Model (with rationale)

| Item | Why NOT |
|------|---------|
| IR lowering (frontend → IR) | Out of scope; too much C semantics (types, qualifiers, expressions) |
| Backend codegen / regalloc / stack layout | Explicitly out of scope per task brief; modeled separately in `ccc-regalloc` |
| GVN / LICM / inliner / constant fold / CFG simplify | Downstream consumers of SSA form; their bugs live elsewhere. F3's `cfg_simplify` stale-phi bug is reported but not modeled here |
| Cost heuristic numeric tuning (`MAX_PHI_COPY_COST = 50 000`) | Pure performance parameter; no correctness invariant |
| `IrConst::narrowed_to` numeric semantics | Not an algorithmic invariant; better tested with a unit test at the `IrConst` level. F3 is noted but the bug is constant-folding, not mem2reg-structural |
| Asm template syntax / constraint parsing | mem2reg's contract is only the predicates `constraint_is_memory_only` and "does this input Value refer to an alloca"; the downstream asm-template semantics are out of scope |
| Stack overflow from deep recursion (D5) | Implementation detail (recursive DFS); better addressed by converting to an explicit stack |
| Non-termination of CHK on adversarial irreducible CFGs (D4) | Theoretical; no real-world reproducer. Can be covered by a liveness property if the spec already enables that |
| Debug printing (`CCC_DEBUG_MEM2REG`) | Purely observational |

---

## 4. Proposed Extensions (beyond a textbook SSA spec)

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| **AllocaUseKinds** | `uses: Alloca → Seq(UseKind)`, `UseKind = {LOAD, STORE_PTR, STORE_VAL, GEP, ASM_OUT_REG, ASM_OUT_MEM, ASM_IN_VAL, OTHER, TERMINATOR_USE}` | Expresses the full address-taken predicate as an enumerable finite-state check | F1 |
| **MultisetEdges** | `edges: SUBSET (BlockId × BlockId × Nat)` — third component is the syntactic-occurrence index | Distinguishes `switch default → B` from `switch case 1 → B`; needed for D2 | F6 |
| **AsmGotoAnchors** | `asm_gotos: Seq((block, point_in_block, SUBSET goto_targets))` | Captures the temporal order of multiple asm-gotos in one block (D3) | F4 |
| **PhiCopyExecuted** | `phi_copy_executed: (edge, phi) → BOOLEAN` — whether the copy runs on this runtime path | The SSA-correctness property expressed at the phi level | F6 |
| **PromotedAllocaBitmap** | `promoted: SUBSET Allocas`, `dropped_by_cost: SUBSET Allocas` | Separates "ineligible" from "eligible but dropped by cost cap" | F5 |
| **ParamAllocaPositions** | `param_allocas_in_entry: Seq(Alloca)` — positional ordering | Captures the "first N allocas are params" invariant (D6) | F2 |
| **DefStackSnapshot** | `snapshot_at_asm_goto: (block, asm_idx) → Alloca → Operand` | Per-asm-goto snapshot avoiding D3's overwrite | F4 |
| **IrreducibleEntryCount** (optional) | `idom_iterations: Nat` | Bounds CHK fixpoint iterations | D4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **SSA_Dominance** | Safety | Every `Load` of a promoted alloca observes the definition from the nearest dominating `Store` (or the zero-initializer) | F1, F2, F3, F4 |
| **PhiIncomingMatchesPreds** | Safety | For every phi `p` at block `b`: `{pred : exists (op, pred) ∈ p.incoming} == distinct_preds(b)` | F3, D1/D9 |
| **PhiCopiesOnEveryEdge** | Safety | For every CFG edge `(pred, target)` whose target has a phi: along that runtime edge, the phi's copy instructions execute exactly once | F6, D2 |
| **AddressTakenNeverPromoted** | Safety | `promoted(a) ⇒ every use of a is LOAD or STORE_PTR or ASM_OUT_REG` | F1 |
| **AsmGotoSnapshotCorrectness** | Safety | For every asm-goto edge `(pred, target)`, the phi at `target` receives the def-stack snapshot from the exact asm-goto point (not a later point in the same block) | F4, D3 |
| **ParamAllocaPrefix** | Safety | The first `|params|` allocas in the entry block, in emission order, are exactly the parameter allocas | F2, D6 |
| **CostCapBounded** | Safety | After `DropExpensive`, `sum_over_phi_sites(preds(block)) ≤ MAX_PHI_COPY_COST` | F5 |
| **IDFFixpointTerminates** | Liveness | The IDF worklist terminates for every alloca (already provable by monotonicity) | F5 |
| **CHKFixpointTerminates** | Liveness | Cooper-Harvey-Kennedy reaches a fixpoint in finitely many iterations on any finite CFG | D4 |
| **RenameStackMonotone** | Safety | In `rename_block`, after recursion returns the def-stack length equals the length recorded pre-recursion | F4 (asm-goto push/pop nesting) |
| **TrampolineReachability** | Safety | Every trampoline block is reachable from the retargeted predecessor and branches to its original target | F6, D2 |
| **NoStalePhiAfterSimplify** | Safety | After any CFG simplification that removes an edge, phi incoming entries referencing that edge are removed | F3 (out of module but worth stating) |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| M1 | Switch with `default == case_i` target: trampoline retarget applied to only one edge. Phi dest uninitialized on bypassed edges. | `PhiCopiesOnEveryEdge` violated on `(pred, B, syntactic_id ≠ default)` | F6 / D2 |
| M2 | `InlineAsm.goto_labels` with duplicate targets combined with critical-edge trampoline: same as M1. | `PhiCopiesOnEveryEdge` | F6 / D2 |
| M3 | Two asm-goto instructions in same block target the same label `L`. Phi at `L` sees the later snapshot even on the edge from the earlier asm-goto. | `AsmGotoSnapshotCorrectness` | F4 / D3 |
| M4 | IDF worklist + cost cap: a dropped alloca is still used in the rest of the function (rename must treat it as non-promoted). | `AddressTakenNeverPromoted` corollary: "if not promoted, `rename_block` must leave its Load/Store alone" | F5 |
| M5 | CondBranch with `true_label == false_label` at a block that is the target of multiple promoted-alloca definitions. Spurious phi insertion? Phi with 1-incoming in `incoming` list but `preds.len() == 2`. | `PhiIncomingMatchesPreds` | F3 / D1 |
| M6 | Irreducible CFG (e.g., classic `loop with two entries`): CHK fixpoint convergence. | `CHKFixpointTerminates` — bounded counterexample iteration count | D4 |
| M7 | Rename pass: an alloca's def-stack is pushed on entering a block and popped on exit. With multiple asm-gotos in the block, the nested push (snapshot before recursion) + inner rename_block push/pop must leave the def-stack length unchanged. | `RenameStackMonotone` | F4 / D8 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|--------------------------|
| T1 | Load-before-store reads zero constant (uninitialized C local). | Unit test: a function with `int x; return x;` → promoted alloca, Copy from `IrConst::I32(0)`. |
| T2 | `IrConst::narrowed_to(U32)` produces `I64((v as u32) as i64)`, not `I32(-1)`. | Unit test at the IrConst level. |
| T3 | Size-8-but-type-I32 alloca is promoted. | IR-level round-trip test. |
| T4 | Phi cost cap triggers on Lua VM dispatch; dropped allocas remain as stack loads/stores; result binary runs correctly. | Integration test: compile Lua VM, run test suite. |
| T5 | Phi elimination of 3-way cycle (`a = b, b = c, c = a`) produces three temporaries and restores correctly. | Synthetic IR test. |
| T6 | Asm-goto in the middle of a block: Linux ALTERNATIVE macro pattern. | Build the actual kernel RISC-V defconfig; booting to a known console message. |
| T7 | D5 — compile a function with 10 000 fall-through switch cases. | Synthetic stress test; verify no stack overflow. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-------------------|
| C1 | `preds` is not de-duplicated in `build_cfg` (D1/D9). | Either (a) add de-dup in `build_cfg`, or (b) document that `preds.len()` is a multiset count and fix `compute_dominance_frontiers`'s `preds.len(b) < 2` gate to count distinct preds. |
| C2 | Comment at `promote.rs:797-800` is misleading (says "keep Loads just in case" but the code removes them). | Fix the comment. |
| C3 | `compute_reverse_postorder` uses unbounded recursion (D5). | Convert to explicit stack iteratively; bounded for any finite CFG. |
| C4 | Positional param-alloca detection (D6) in `find_promotable_allocas` (line 189-200) and `remove_promoted_instructions` (line 757) duplicates logic and assumes `#allocas_in_entry >= #params`. | Use `func.param_alloca_values` consistently in both places. |
| C5 | `rename_block` `dom_children[block_idx].clone()` allocates per-block (line 668). | Could iterate by reference; pure perf. |
| C6 | `find_conflicting_phis` safety net (phi_eliminate.rs:223-232) is conservative; actual cycle detection via SCCs would be tighter. | Documented; no action needed unless perf becomes a concern. |

---

## 7. Reference Pointers

- Full audit trail: `./analysis-report.md` (this directory).
- Primary source files:
  - `src/ir/analysis.rs` — CFG + dominators + DF
  - `src/ir/mem2reg/promote.rs` — SSA construction
  - `src/ir/mem2reg/phi_eliminate.rs` — phi lowering
  - `src/ir/mem2reg/README.md` — authoritative design doc
- Historical fixes (fork `regehr/claudes-c-compiler`):
  - `3d6458bd` initial mem2reg
  - `92072a32` asm-goto snapshot fix
  - `8e7b537c` asm-goto CFG edges
  - `a0a7ff78` promote InlineAsm outputs
  - `b480e927` disqualify `=m` outputs
  - `d9cc91d7` critical edges
  - `c3dee533` IndirectBranch special case
  - `ad702eb3` smart phi elimination
  - `6b2d94ae` phi-explosion cost cap
  - `baedaa75` / `d7e042bb` array-escape fixes
  - `877dcf18` alloca promotion + phi simplification (three sub-bugs)
  - `f99a57d6` `narrowed_to(U32)` fix
  - `b959f528` `cfg_simplify` stale phi cleanup
- Upstream context:
  - Issue #184, PR #213 (volatile semantics) — tangential to mem2reg.
  - Issue #227 (csmith / yarpgen results) — context on fuzzing coverage.
- Reference algorithm: Cytron, Ferrante, Rosen, Wegman, Zadeck, "Efficiently
  Computing Static Single Assignment Form and the Control Dependence Graph",
  TOPLAS 1991. Cooper, Harvey, Kennedy, "A Simple, Fast Dominance Algorithm",
  Rice CS TR 2001.
