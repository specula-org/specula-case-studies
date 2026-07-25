# Instrumentation Guide — CCC Regalloc / Liveness Trace Harness

Practical guide for Phase 3 (validation) agents making small adjustments to
the trace harness. For the full story of **why** each event exists, see
`../spec/instrumentation-spec.md`.

---

## Layout

```
.specula-output/harness/
├── apply.sh                     # idempotent installer (git-restore + patch + copy)
├── run.sh                       # one-command build + test + collect traces
├── INSTRUMENTATION.md           # this file
├── patches/
│   └── instrumentation.patch    # unified diff against a pristine artifact
└── src/
    ├── tla_trace.rs             # trace emission library (no external deps)
    └── tla_trace_scenarios.rs   # test scenarios that drive the real pipeline
```

The harness targets `../../ccc/artifact/claudes-c-compiler` (a Rust crate).
`apply.sh` drops `tla_trace.rs` + `tla_trace_scenarios.rs` into
`src/backend/` and applies the unified diff to four files:
`src/backend/mod.rs`, `src/backend/liveness.rs`, `src/backend/regalloc.rs`,
`src/backend/stack_layout/slot_assignment.rs`.

Override `ARTIFACT_DIR` to point at a different checkout:
```
ARTIFACT_DIR=/path/to/ccc bash harness/apply.sh
```

---

## Where each event fires

All locations given as `<file>:<line-after-apply>` inside the artifact.

| Spec action                  | File / emit call site                                           |
|------------------------------|-----------------------------------------------------------------|
| `AssignProgramPoints`        | `src/backend/liveness.rs` around the first emit guarded by       |
|                              | `if super::tla_trace::is_active()`                               |
| `DataflowIterStep`           | `src/backend/liveness.rs` inside `run_backward_dataflow` at end  |
|                              | of each outer `while` sweep                                      |
| `DataflowCapHit`             | `src/backend/liveness.rs` right after the same `while` exits,    |
|                              | guarded by `changed && iteration >= MAX_ITERATIONS`              |
| `ExtendIntervalsFromLiveness`| `src/backend/liveness.rs` after `extend_intervals_for_setjmp`    |
| `BuildIntervals`             | `src/backend/liveness.rs` after `build_intervals` returns        |
| `Phase1Allocate` / `Phase1Done` | `src/backend/regalloc.rs` inside/after the Phase-1 for loop   |
| `Phase2Allocate` / `Phase2Done` | same file — inside/after the Phase-2 caller-saved block       |
| `Phase3Allocate` / `Phase3Done` | same file — inside/after the Phase-3 spillover block          |
| `AssignSlot`                 | `src/backend/stack_layout/slot_assignment.rs` in both branches  |
|                              | (reuse + new-slot) of `pack_values_into_slots`                   |
| `PackSlotsDone`              | `src/backend/stack_layout/slot_assignment.rs` at the bottom and  |
|                              | all early-returns of `assign_tier2_liveness_packed_slots`        |

The tla_trace module itself lives in `src/backend/tla_trace.rs`; every
instrumentation point calls into it via `super::tla_trace::emit_*`.

---

## Scenarios

Each `#[test]` in `tla_trace_scenarios.rs` opens its own trace file via
`tla_trace::open`, emits one `config` line, drives the real
`allocate_registers` + `calculate_stack_space_common` pipeline on a
hand-built `IrFunction`, and closes the file. Trace filenames match the
test-function name minus the `scenario_` prefix.

| Scenario                   | Purpose                                                   |
|----------------------------|-----------------------------------------------------------|
| `straight_line_sum`        | Minimal path — no calls, no asm, converges immediately.    |
| `value_across_call`        | Fires `Phase1Allocate` (callee-saved across a real call). |
| `two_block_branch`         | Multi-block dataflow, Phase 4 extends intervals.          |
| `asm_no_operands_f1`       | **F1 bug surface** — asm dropped from `recordedCallPoints`. |
| `slot_packing_floats`      | Forces Tier-2 packing; fires `AssignSlot`.                |
| `phase3_spillover`         | 9 values → exhausts caller-saved → fires `Phase3Allocate`. |
| `loop_fixpoint`            | Back-edge forces 3 `DataflowIterStep` events.             |

### Events intentionally not covered

| Event           | Reason                                                            |
|-----------------|-------------------------------------------------------------------|
| `DataflowCapHit`| Requires > `MAX_ITERATIONS = 50` outer sweeps. That only happens  |
|                 | on pathological irreducible CFGs; cannot be produced reliably     |
|                 | with a small hand-built IR. Add a scenario with a synthetic IR   |
|                 | that forces 50+ iterations if Phase 3 needs it.                   |

---

## Adjusting instrumentation

### Add a new field to an existing event

1. Edit the corresponding `emit_*` function in `tla_trace.rs` — append the
   field to the `"state":{…}` object printed by its `buf.push_str`.
2. Update the call site(s) in the instrumented file to pass the new value.
3. Re-generate the patch: `git -C <artifact> diff > harness/patches/…`.
4. `bash harness/run.sh` to rebuild and regenerate traces.

### Add a new event type

1. Add an `emit_<name>` function in `tla_trace.rs` following the pattern
   of the existing ones (envelope_prefix + state object + `write_line`).
2. Insert a call at the desired instrumentation point and regenerate the
   patch.
3. Cover the new event in at least one scenario (extend
   `tla_trace_scenarios.rs`), otherwise Phase 3 cannot exercise it.

### Move a capture point (before ↔ after an action)

1. Relocate the `super::tla_trace::emit_*(...)` call in the artifact.
2. Adjust the state-building snippet so it still reads the fields the
   spec expects.
3. Regenerate the patch.

### Rebuild + re-run

```
bash harness/run.sh
```

This reapplies the patch (idempotent), builds in release, runs every
scenario, and prints a per-file line count. Output land in
`.specula-output/traces/`.

---

## Known caveats / follow-ups for Phase 3

1. **`Trace.cfg` constants**: the generated `Trace.cfg` uses function
   literals like `(0 :> 0 @@ 1 :> 0 @@ 2 :> 1)` which TLC's config parser
   does not accept. Phase 3 must rewrite these as operator overrides
   (e.g. `CONSTANT BlockOfPoint <- BlockOfPointOp`) and supply the
   `BlockOfPointOp` definition either in `MC.tla` or a per-scenario
   wrapper module. Each trace's leading `{"tag":"config", ...}` line
   contains the exact constants values for that run.

2. **`dense`/`sparse` value IDs**: the instrumentation decodes dense
   `BitSet` indices back to sparse value IDs before emitting, so the
   trace always speaks sparse IDs. If you see `dense` indices in a
   trace (e.g., `blockGen: {"0":[42]}` where 42 is improbably large),
   the decoding step got skipped — check that the emission site calls
   `value_ids[i]` rather than `i`.

3. **Thread locality**: `tla_trace` uses thread-local state (`CTX`).
   Each `#[test]` runs in its own thread, so `--test-threads=N` is
   safe. Calling the pipeline from multiple threads within a single
   test would mix traces; don't do that.

4. **Feature flag**: no Cargo feature gates the trace module. The emit
   calls are effectively no-op when `tla_trace::is_active()` is false
   (no file opened), so leaving the instrumentation in place does not
   affect normal compilation.
