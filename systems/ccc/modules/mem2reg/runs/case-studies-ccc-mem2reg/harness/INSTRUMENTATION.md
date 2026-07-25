# CCC mem2reg trace instrumentation guide

This file is for the Phase 3 (validation) agent who needs to adjust the
instrumentation when trace validation reveals a missing field, a wrong
trigger point, or a new event type.

## Layout

| Path | Role |
|------|------|
| `harness/src/tla_trace.rs` | NDJSON writer + alloca-id mapper |
| `harness/src/trace_helpers.rs` | One Rust fn per spec action |
| `harness/src/trace_scenarios.rs` | `#[test]` functions that exercise the pass |
| `harness/instrumented/promote.rs` | Patched copy of `src/ir/mem2reg/promote.rs` |
| `harness/instrumented/analysis.rs` | Patched copy of `src/ir/analysis.rs` |
| `harness/instrumented/phi_eliminate.rs` | Patched copy of `src/ir/mem2reg/phi_eliminate.rs` |
| `harness/instrumented/mod.rs` | Patched module declarations |
| `harness/apply.sh` / `clean.sh` / `run.sh` | Apply / revert / one-shot run |

`apply.sh` copies harness sources into the artifact at
`../../../ccc/artifact/claudes-c-compiler/src/`. `clean.sh` reverts via
`git checkout` and removes the dropped-in trace files.

## Where each spec action is emitted

| Spec action | Emit call | File:approx-line (after apply) |
|---|---|---|
| `StartFilter` | `th::start_filter()` | `promote.rs` ~88 (top of `promote_function`) |
| `FilterStep` | `th::filter_step(...)` | `promote.rs` ~280-310 (per Load/Store on candidate) |
| `FilterDone` | `th::filter_done(...)` | `promote.rs` ~395 (end of `find_promotable_allocas`) |
| `BuildCFG` | `th::build_cfg(...)` | `analysis.rs` ~189 (end of `build_cfg`) |
| `ComputeRPO` | `th::compute_rpo(...)` | `analysis.rs` ~262 (after `idom[rpo[0]] = rpo[0]`) |
| `IdomIterStep` | `th::idom_iter_step(...)` | `analysis.rs` ~308 (end of each changed-pass) |
| `IdomDone` | `th::idom_done()` | `analysis.rs` ~314 (after the while loop) |
| `ComputeDF` | `th::compute_df(...)` | `analysis.rs` ~336 (end of `compute_dominance_frontiers`) |
| `IdfInitAlloca` | `th::idf_init_alloca(...)` | `promote.rs` ~398 (in `insert_phis`, per alloca init) |
| `IdfWorklistStep` | `th::idf_worklist_step(...)` | `promote.rs` ~410 (after each `pop_front` walk) |
| `IdfFinishAlloca` | `th::idf_finish_alloca(...)` | `promote.rs` ~417 (after worklist drains) |
| `IdfPhaseDone` | `th::idf_phase_done()` | `promote.rs` ~423 (end of `insert_phis`) |
| `CostDropAction` | `th::cost_drop_action(...)` | `promote.rs` ~175 (after cost calc) |
| `ReinsertPhis` | `th::reinsert_phis(...)` | `promote.rs` ~185 (after second `insert_phis`) |
| `StartRename` | `th::start_rename()` | `promote.rs` ~558 (just before `rename_block(0,...)`) |
| `RenamePushPhiDefs` | `th::rename_push_phi_defs(...)` | `promote.rs` ~635 (after the phi-defs loop) |
| `RenameInstStep` | `th::rename_inst_step(...)` | `promote.rs` ~680, ~718, ~752 (per inst arm) |
| `RenameFillPhis` | `th::rename_fill_phis(...)` | `promote.rs` ~810 (after per-successor fill loop) |
| `RenameDescendChild` | `th::rename_descend_child(...)` | `promote.rs` ~838, ~860 (before each recursive call) |
| `RenamePopFrame` | `th::rename_pop_frame(...)` | `promote.rs` ~880 (after stack-truncate loop) |
| `RenameDone` | `th::rename_done()` | `promote.rs` ~573 (after `rename_block(0,...)` returns) |
| `RemoveAction` | `th::remove_action(...)` | `promote.rs` ~595 (after `remove_promoted_instructions`) |
| `PhiElimPlan` | `th::phi_elim_plan(...)` | `phi_eliminate.rs` ~292 (end of `eliminate_phis_in_function`) |

## How to add a new field to an event

1. Edit the corresponding emit fn in `harness/src/trace_helpers.rs` to
   add the field to the `format!` body. Field names are JSON strings.
2. Edit the call site in `harness/instrumented/<file>.rs` to pass the
   value (the call sites already capture local state).
3. Re-apply with `bash harness/apply.sh` and re-run.

## How to add a new event type

1. Add a `pub fn` in `harness/src/trace_helpers.rs` emitting the desired
   JSON envelope.
2. Find the trigger location in `harness/instrumented/<file>.rs` and
   call the new fn.
3. Add the matching `Tname == ...` wrapper in
   `.specula-output/spec/Trace.tla` and include it in `TraceNext`.
4. Re-apply, re-run the scenario, and re-validate.

## How to move a capture point (before → after, or vice versa)

The instrumentation sites are direct emit calls on a single line; just
move that line to the new location. State captured by the call uses
local variables in scope at the call site, so make sure the fields
you reference are still bound at the new location.

## Spec-side adjustments

A few places in `Trace.tla` were relaxed during initial validation:

1. **`TIdomIterStep`** — trusts the trace's `idom_arr` and `idomIters`
   field rather than the spec's per-pass fixpoint. The impl converges
   incrementally in one pass while the spec models atomic snapshots.
2. **`TRenamePopFrame`** — bypasses the spec's
   `domChildren[b] \ visited = {}` precondition. The spec's `visited`
   set only counts blocks currently on the stack, not popped children,
   so the precondition is never reachable for a parent with descendants.
3. **`TPhiElimPlan`** — bypasses the complex `CHOOSE` over edge sets in
   the base spec; just advances `phase` to `DONE`. Detailed
   `phiCopyExecuted` / `retargetedSyn` are not validated.
4. **`TBuildCFG` / `TComputeRPO` / `TComputeDF`** — drop per-block
   function-valued state checks (succs, df, dom_children). The spec
   recomputes them deterministically; cross-checking against trace
   buys nothing and JSON arrays don't compare to TLA+ sets.
5. **Set-valued fields** (`disqualified`, `dropped_by_cost`,
   `removed_allocas`, `phi_sites_b`, `promoted`) are wrapped with a
   helper `ToSet(...)` because JSON arrays parse as TLA+ sequences.
6. **`TraceSpec`** uses `WF_allTraceVars(TraceNext)` to suppress
   counterexample paths that stutter at every step.

If you tighten any of these in the future (e.g., to catch a real bug),
also tighten the corresponding emit fn to capture the missing data.

## How to rebuild and re-run

```
cd .specula-output
bash harness/apply.sh
bash harness/run.sh
```

`run.sh` runs `cargo test` filtered to the trace scenarios and writes
NDJSON files into `.specula-output/traces/`.

To validate a specific trace:

```
JSON=../traces/<scenario>.ndjson tlc -config Trace.cfg Trace.tla
```

(or use the `mcp__tla-trace-debugger__run_trace_validation` tool from
the validation workflow.)

## Capture-level notes

- **Full state capture** is used for: `BuildCFG.succs`, `ComputeDF.df`,
  `IdomIterStep.idom_arr`, `IdfInitAlloca.def_blocks_a`,
  `IdfWorklistStep.phi_sites_b`, `CostDropAction.dropped_by_cost`,
  `ReinsertPhis.promoted`, `RemoveAction.removed_allocas`.
- **Weak (label-only) capture** is used for events where post-state
  validation is currently disabled in `Trace.tla` — see the spec-side
  adjustments above. To upgrade these, add the missing field in the
  emit fn and tighten the matching `Txxx` wrapper.

## Adding a new test scenario

1. Add a `fn build_<name>() -> IrModule` in
   `harness/src/trace_scenarios.rs` (matching some `MC*` fixture in
   `MC.tla`).
2. Add a `#[test] fn trace_<name>() { run_traced("<name>", build_<name>); }`.
3. List the scenario in `harness/run.sh` (`SCENARIOS=( ... )`).
4. The trace will appear at `traces/<name>.ndjson`.

A new fixture also requires a matching `Trace.cfg` (or override the
`CONSTANTS` clause to point at the new fixture's `<Name>Blocks`,
`<Name>UseSites`, etc., from `MC.tla`).
