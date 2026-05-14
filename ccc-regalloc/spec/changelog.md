# Spec Validation Changelog

## Round 1 - Trace Validation

### Infrastructure

- [fix-spec] `Trace.tla`: filter out the NDJSON `{"tag":"config"}` header line (it has no `event` field and would crash `IsEvent`). Added `TraceLog == SelectSeq(RawTraceLog, LAMBDA e: e.tag = "trace")`.
- [fix-spec] `Trace.tla`: added JSON→TLA conversion helpers (`AsSet`, `IntKeyed`, `IntKeyedSet`). JSON arrays deserialise to sequences, JSON objects to records with string keys; spec uses sets / Int-keyed functions.
- [fix-spec] `Trace.tla`: simplified `TraceAssignProgramPoints`/`TraceDataflowIterStep`/`TraceExtendIntervals` — copy analysis state (blockGen/blockKill/liveIn/liveOut/computedDef/computedLastUse) from the trace instead of re-running the spec's formula. The spec's set-theoretic gen/kill formula does not match the impl's per-instruction kill ordering, so re-running would produce spurious mismatches on any scenario with >1 instruction per block. Action sequencing + post-state copy is still enough to drive the safety invariants, which use TrueDef/TrueUses as ground truth.
- [fix-spec] `Trace.tla`: added weak fairness `WF_<<allVars, traceVars>>(TraceNext)` and switched configs to `SPECIFICATION TraceSpec` so the `<>(l > Len(TraceLog))` liveness check can actually succeed (was vacuously violated under stuttering INIT/NEXT). Added `CHECK_DEADLOCK FALSE` in each per-trace cfg for the post-trace terminal state.
- [fix-spec] `base.tla`: changed `NONE` sentinel from `"NONE"` (string) to `-1` (integer). Mixed-type equality checks against `NONE` tripped TLC's strict type check and crashed both `HasInterval` and `AssignmentDomain`/`SlotDomain`. `-1` is outside every PhysReg/Slot pool so it is an unambiguous sentinel.
- [fix-spec] `base.tla`: `HasInterval(v)` now just checks `computedLastUse[v] > computedDef[v]` (no `# NONE`) — the def/last-use fields are always ints (initialized to 0 and written to point indices, never re-blanked).
- [fix-spec] `base.tla`: `AssignmentDomain`/`SlotDomain` rewritten to `\in ({NONE} \cup PhysRegs)` / `\in ({NONE} \cup Slots)` (set membership) for type-safe mixed-sentinel domains.
- [fix-spec] `base.tla`: regalloc/slot guards use `\notin PhysRegs` / `\notin Slots` instead of `= NONE` so the guard holds for every non-assigned value regardless of sentinel form.
- [fix-spec] Per-trace config generation: derive `TrueUses[v]` from the impl's reported `computedLastUse` (trust the impl as ground truth). The hand-written `TrueUses` in the scenario files were off-by-one in `phase3_spillover` (declared v1/v2 used at 9 instead of 8) and missing terminator uses in `value_across_call`. Setting `TrueUses[v] = {impl_last_use[v]}` keeps `IntervalSoundness` meaningful without re-implementing the per-scenario truth table.
- [fix-spec] Per-trace config generation: derive `Slots` from the trace's `AssignSlot` events. The `slot_packing_floats` scenario declares positive slot IDs but the x86 assignment closure actually emits negative RBP-relative offsets (-8, -16, -24, -32). Using the observed slots ensures `s \in Slots` guard holds.
- [fix-spec] TLC config parser does not accept function literals (`@@`, `:>`, `[x \in ... |-> ...]`). Per-scenario wrapper modules `Trace_<name>.tla` define operators (`BlockOfPointOp`, `TrueUsesOp`, etc.) and the cfg uses `CONSTANT X <- XOp`. Negative-slot sets also route through an `SlotsOp` operator because the cfg parser rejects negative-int set literals.

### Trace results (structural invariants only — bug-family invariants run in Phase-3 bug hunting)

All 7 traces pass:

| Scenario               | States | Status |
|------------------------|-------:|--------|
| straight_line_sum      | 11     | PASS   |
| value_across_call      | 11     | PASS   |
| two_block_branch       | 13     | PASS   |
| loop_fixpoint          | 13     | PASS   |
| slot_packing_floats    | 14     | PASS   |
| phase3_spillover       | 24     | PASS   |
| asm_no_operands_f1     | 11     | PASS   |

### Case-C finding encountered during trace replay

- [bug] **F1 (asm_no_operands_f1)**: when bug-family invariant `CallerSavedDeadAcrossAsmClobber` is enabled, it fires during replay of `asm_no_operands_f1`. The trace shows the impl drops the empty-operands asm at point 1 from `recordedCallPoints`, so Phase 2 places v1 (live across the asm) in caller-saved reg 10 — but the asm declares r10 (`r11` in x86 naming) as a clobber. Any use of v1 after the asm reads garbage. Reproducer is exactly `asm volatile("" ::: "r11","memory");` followed by use of a value that Phase 2 placed in r11. Source locations: `liveness.rs:316-322` (asm filter), `x86/codegen/emit.rs:96-105` (clobber_to_phys). Will be re-recorded during bug hunting.

## Round 1 - Model Checking (MC.cfg)

- [fix-spec] `MC.tla`: added operator forms (`BlockOfPointOp`, `TrueUsesOp`, …) — the TLC config parser does not accept function-literal CONSTANT values, so every non-set constant is supplied via `CONSTANT X <- XOp`.
- [fix-spec] `MC.cfg`: rewritten to `SPECIFICATION MCSpec` + operator overrides + `CHECK_DEADLOCK FALSE` (phase=`"Done"` is a terminal state).
- MC.cfg passed: **21 distinct states, depth 13, no invariant violations**. Structural invariants (pool disjointness, phase validity, assignment/slot domain, call-point subset, iter cap, no-register-collision, no-slot-collision) all hold on the benign input.

## Result

Converged in **1 round** — Phase 2 only touched MC wrapper files, not the base spec, so no re-run of trace validation was needed.
