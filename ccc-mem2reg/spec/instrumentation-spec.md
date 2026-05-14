# Instrumentation Spec — CCC mem2reg

This document maps each TLA+ spec action to the source location where the
implementation should emit a trace event, the trigger point (before/after),
and the JSON fields to capture.

Trace consumer: `Trace.tla` (cursor `l`, NDJSON file at
`../traces/<name>.ndjson`).

Source tree base: `claudes-c-compiler/src/`.

---

## Section 1 — Trace Event Schema

### 1.1 Event envelope

Each NDJSON record is one JSON object:

```json
{
  "tag": "trace",
  "ts":  <wall-clock-ns or sequence number>,
  "event": {
    "name":  "<spec action name>",
    "state": { /* post-action state snapshot, see §1.2 */ },
    /* event-specific fields (block id, alloca id, etc.) */
  }
}
```

`tag = "trace"` is mandatory; `Trace.tla` filters on it. Other tags
(e.g., `"log"` for human-readable diagnostics) are ignored.

### 1.2 State snapshot fields

A state snapshot captures the spec variables that the action **writes**.
Field names use snake_case in JSON, camelCase in the spec; the trace spec
maps explicitly. Capture only what the action modifies — the trace spec
checks fields lazily (`HasField(... ) => ...`), so missing fields silently
skip validation.

Common fields:

| JSON field | Spec variable | Notes |
|---|---|---|
| `phase` | `phase` | One of the `PHASES` constants. |
| `disqualified` | `disqualified` | Set encoded as JSON array of alloca ids. |
| `def_blocks` | `defBlocks` | Function: `{a: [b, ...], ...}`. Optional. |
| `use_blocks` | `useBlocks` | Same shape. Optional. |
| `succs` | `succs` | Function from block id → list of block ids. |
| `preds_count` | `predsCount` | Nested map `{t: {p: n, ...}}`. |
| `cfg_edges` | `cfgEdges` | Array of `[pred, succ, syn_id, kind]` records. |
| `rpo` | `rpo` | Sequence of block ids. |
| `idom` | `idom` | Function block → block (or -1). |
| `idom_iters` | `idomIters` | Integer. |
| `df` | `df` | Function block → array of blocks. |
| `dom_children` | `domChildren` | Function block → array of blocks. |
| `phi_sites_b` | `phiSites[b]` | Per-block; for IDF events. |
| `dropped_by_cost` | `droppedByCost` | Set of alloca ids. |
| `promoted` | `promoted` | Set of alloca ids. |
| `def_stacks` | `defStacks` | For RENAME steps. |
| `phi_incoming` | `phiIncoming` | Indexed `{b_a: [...]}`. |
| `removed_allocas` | `removedAllocas` | Set of alloca ids. |
| `trampolines` | `trampolines` | Array of `{pred, target}`. |
| `retargeted_syn` | `retargetedSyn` | Map `{p_t: syn_id}`. |
| `phi_copy_executed` | `phiCopyExecuted` | Map `{p_s_k: [a, ...]}`. |

### 1.3 Block / alloca identity

The implementation IRs use `Value(u32)` for SSA ids and `BlockId(u32)` for
labels. Capture both as raw `u32` integers in JSON. The spec uses block
indices (positions in `func.blocks`); the harness must map labels →
indices via `build_label_map`.

---

## Section 2 — Action-to-code mapping

Each entry: spec action name → code location → trigger point → fields.

### 2.1 INIT / FILTER

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `StartFilter` | `promote.rs:79-95` (start of `promote_function`) | After `find_promotable_allocas` returns, before CFG build | `phase` (= "FILTER") |
| `FilterStep` | `promote.rs:256-329` (per-instruction match arms) | After each match arm body | `block`, `pos`, `kind` (LOAD/STORE_PTR/...), `alloca`, `disqualified` (snapshot), `def_blocks_a`, `use_blocks_a` |
| `FilterDone` | `promote.rs:332-358` (final filter loop after instruction scan) | After the `.filter(...)` chain at line 337 returns its final list | `phase` (= "BUILD_CFG"), `disqualified` |

Notes on `FilterStep`:
- Emit one event per instruction touched, even if the alloca is not in
  `candidate_set` (the spec models the conditional `if a \in candidates`).
- The `kind` field must distinguish ASM_OUT_REG vs ASM_OUT_MEM via the
  `constraint_is_memory_only(constraint, false)` predicate.
- The `STORE_VAL` event corresponds to the inner branch at line 272-276.
- The `OTHER` event corresponds to the catch-all at line 313-319.

### 2.2 BUILD_CFG

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `BuildCFG` | `analysis.rs:110-187` (`build_cfg`) | Just before returning `(FlatAdj::from_vecs(preds), ...)` at line 186 | `phase` (= "IDOM"), `succs`, `preds_count`, `cfg_edges` |

Single atomic event: the body is short and faithful to the algorithm.
Capture `predsCount` as the multiset (BEFORE the FlatAdj packing).

### 2.3 IDOM

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `ComputeRPO` | `analysis.rs:192-213` (`compute_reverse_postorder` then `idom` array init at 251-255) | Right after `idom[rpo[0]] = rpo[0]` at line 255 | `rpo`, `rpo_number`, `idom`, `phase` |
| `IdomIterStep` | `analysis.rs:258-292` (one full pass of the `while changed` loop) | At the end of one iteration (line 292), if `changed=true` | `idom`, `idom_iters` |
| `IdomDone` | `analysis.rs:258-292` exit | At loop exit when `changed=false` | `phase` (= "DF") |

### 2.4 DF

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `ComputeDF` | `analysis.rs:302-326` (`compute_dominance_frontiers`) + `analysis.rs:332-340` (`build_dom_tree_children`) | After both functions return | `df`, `dom_children`, `phase` |

### 2.5 IDF

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `IdfInitAlloca` | `promote.rs:374-376` (worklist + ever_in_worklist init) | Right after line 376 | `alloca`, `def_blocks_a` |
| `IdfSkipAlloca` | (synthetic) for allocas filtered out before IDF | Before the for loop at line 372 | `alloca` |
| `IdfWorklistStep` | `promote.rs:378-387` (one `pop_front` + DF walk) | After the inner `for &df_block in &df[block]` completes | `alloca`, `block`, `phi_sites_b` (post), `worklist_remaining` |
| `IdfFinishAlloca` | (synthetic) when `worklist.pop_front` returns None | At the `while` exit | `alloca` |
| `IdfPhaseDone` | (synthetic) after the outer for loop in `insert_phis` returns | Just before `phi_locations` returns at line 390 | `phase` (= "COST_DROP") |

### 2.6 COST_DROP

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `CostDropAction` | `promote.rs:118-161` (cost calc + drop logic) | After the `alloca_infos = ...` reassignment at line 156 (or after the `if total_phi_cost > ...` check if not entering the branch) | `dropped_by_cost`, `total_phi_cost`, `phase` (= "REINSERT") |

### 2.7 REINSERT

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `ReinsertPhis` | `promote.rs:168` (re-call to `insert_phis`) | After the second `insert_phis` returns | `phi_sites`, `promoted`, `phase` (= "RENAME") |

### 2.8 RENAME

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `StartRename` | `promote.rs:464-475` (the call to `rename_block(0, ...)`) | Just before entering `rename_block(0, ...)` | `rename_stack_len` (= 1) |
| `RenamePushPhiDefs` | `promote.rs:500-512` (the push-phi-defs loop) | After the loop completes | `block`, `phi_pushed` (set of allocas) |
| `RenameInstStep` | `promote.rs:533-611` (per-instruction match arms) | After each arm | `block`, `pos`, `kind`, `alloca` |
| `RenameFillPhis` | `promote.rs:618-659` (the per-successor phi-incoming fill) | After the outer for loop | `block`, `succs_filled` |
| `RenameDescendChild` | `promote.rs:677-714` (one iteration of the `for child in children` loop, before the recursive call) | Just before the recursive call into `rename_block(child, ...)` | `block`, `child`, `is_goto` (BOOLEAN), `rename_stack_len` |
| `RenamePopFrame` | `promote.rs:716-719` (the pop-stack-depths loop) | After the final pop | `block`, `rename_stack_len` |
| `RenameDone` | (synthetic) at the return of the outermost `rename_block(0, ...)` | After the call returns in `rename_variables` | `phase` (= "REMOVE") |

Notes:
- `RenameDescendChild` must distinguish the asm-goto branch (line 677-699
  which pushes the snapshot) from the non-goto branch (line 700-713).
  Set `is_goto = true` for the snapshot-pushing branch.
- The asm-goto snapshot itself is observable via `goto_snap_by_label` —
  capture it during the corresponding `RenameInstStep` for kind
  `ASM_HAS_GOTO_LABELS`.

### 2.9 REMOVE

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `RemoveAction` | `promote.rs:748-807` (`remove_promoted_instructions`) | After the function returns (or after the final `block.instructions.retain` at line 805) | `removed_allocas`, `phase` (= "PHI_ELIM") |

### 2.10 PHI_ELIM

| Spec action | Code | Trigger | Event fields |
|---|---|---|---|
| `PhiElimPlan` | `phi_eliminate.rs:256-286` (`eliminate_phis_in_function`) followed by `apply_phi_transformations` (line 462-517) | After `apply_phi_transformations` returns | `trampolines`, `retargeted_syn`, `phi_copy_executed`, `phase` (= "DONE") |

For finer granularity (per-edge retarget, per-trampoline create), split
`PhiElimPlan` into:
  - `PhiElimCreateTrampoline(pred, target)` at `phi_eliminate.rs:181-189`
  - `PhiElimRetargetEdge(pred, old, new)` at `phi_eliminate.rs:499-505`
  - `PhiElimAppendTrampoline(label)` at `phi_eliminate.rs:508-516`

This split is recommended for **F6/D2 trace validation** because the bug
manifests at the per-edge retarget step.

---

## Section 3 — Special considerations

### 3.1 Stable identifiers

- **Block indices vs labels**: the implementation uses `BlockId(u32)`
  labels which are not the same as block indices. The trace must include
  the block **index** (post-`build_label_map`) to align with the spec.
  Emit both in events that carry `block` to ease debugging.
- **Alloca identity**: the spec uses an abstract `Allocas` set. Map each
  `Alloca.dest.0` (u32) to a stable spec id by maintaining a side table
  in the harness. The first alloca encountered = id 1, etc.

### 3.2 Order-of-events

Phases must emit events in source order. In particular:
- `BuildCFG` happens once, between `FilterDone` and `ComputeRPO`.
- IDF events for one alloca are contiguous; alloca order matches
  `alloca_infos` enumeration order.
- The rename DFS's traversal order must be reflected by interleaved
  `RenameDescendChild` / `RenamePopFrame` events.

### 3.3 Asm-goto snapshot bookkeeping

When `RenameInstStep` fires for `ASM_HAS_GOTO_LABELS`, also emit the
`goto_snap_by_label[block]` post-state under field
`goto_snapshot[label]` so that `Trace.tla` can validate the D3 snapshot
overwrite path.

### 3.4 Unmodeled phases

The `phi_eliminate` per-conflict cycle detection (F7) is only validated
at the aggregate `PhiElimPlan` level today. To trace cycle detection
specifically, split `PhiElimPlan` into:
  - `EmitSinglePhiCopies(block)` at `phi_eliminate.rs:301-317`
  - `EmitMultiPhiCopies(block)` at `phi_eliminate.rs:319-372`
  - `FindConflictingPhis(block, edge)` at `phi_eliminate.rs:199-235`

These are not currently in `base.tla` but can be added in a follow-up
without breaking the existing trace events.

### 3.5 Bootstrap state

`TraceInit` calls base `Init` plus pins `filterBlockOrder = << 0, 1, 2,
3 >>`. The harness must guarantee this iteration order — which the
implementation already does because it iterates `func.blocks` by index.

For larger inputs, extend `MCInit_*` in `MC.tla` to pin a longer
sequence and make sure the harness emits events in that exact order.

### 3.6 Field omission policy

Trace events use `HasField(...) => ...` patterns in `Trace.tla`, so a
missing optional field SKIPS validation. Always emit the **mandatory**
fields listed under each action; only auxiliary fields (e.g.,
`goto_snapshot`) are optional.

---

## Section 4 — Suggested instrumentation hook locations

A pragmatic minimal instrumentation that catches all bug families:

| Hook | Code site | Coverage |
|---|---|---|
| H1 | After every match-arm in `find_promotable_allocas`'s instruction scan (`promote.rs:259, 265, 285, 312`) | F1, F2 |
| H2 | After `compute_dominators` returns in `promote.rs:103` | F5/D4 |
| H3 | After `insert_phis` returns at `promote.rs:120` (before cost) and `promote.rs:168` (after cost) | F5 |
| H4 | At the head and tail of every `rename_block` invocation | F4, D8 |
| H5 | At every `goto_label_snapshots.insert(...)` line at `promote.rs:587` | F4/D3 |
| H6 | After every `retarget_block_edge_once` call at `phi_eliminate.rs:500-504` | F6/D2 |
| H7 | At the end of `remove_promoted_instructions` (line 806) | F2/D6 |

Each hook emits a single trace event; the trace driver concatenates them
all into a single NDJSON file for one mem2reg run.
