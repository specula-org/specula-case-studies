# Instrumentation Spec — CCC Register Allocator + Liveness

This document maps each TLA+ spec action to the CCC source location that
must be instrumented to emit the corresponding trace event. The harness
agent (Phase 2.5) uses this as the single source of truth for what to
patch.

> **Target system**: Sequential compiler pipeline (no concurrency).
> Trace format: single linear NDJSON file, one event per line, in the
> order the events fire. The trace cursor `l` in `Trace.tla` walks the
> file front-to-back.

---

## Section 1 — Trace Event Schema

### Common Envelope

Every event line is a JSON object with the following common fields:

| Field    | Type     | Description                                                                |
|----------|----------|----------------------------------------------------------------------------|
| `event`  | string   | Spec action name (e.g. `"AssignProgramPoints"`, `"Phase1Allocate"`).      |
| `func`   | string   | Function name being compiled (for human-readable filtering).               |
| `seq`    | integer  | Monotonic per-trace event sequence number; redundant with line order.     |
| `state`  | object   | Post-action state snapshot (only the fields the action modified).         |

Action-specific top-level fields (e.g. `value`, `reg`, `slot`) are added
where called out in Section 2.

### State-field Mapping

Mapping from impl identifier (Rust) → TLA+ variable. Captured in the
`state` object of any event whose action modifies the variable.

| Impl identifier (Rust)                                       | TLA+ variable          | Encoding                              |
|--------------------------------------------------------------|------------------------|---------------------------------------|
| `LivenessResult.call_points` (post `assign_program_points`)  | `recordedCallPoints`   | sorted list of u32 program points     |
| `ProgramPointState.def_points` (dense → sparse via value_id) | `computedDef`          | object: value_id → u32                |
| `ProgramPointState.last_use_points` (dense → sparse)         | `computedLastUse`      | object: value_id → u32                |
| `block_gen[b]` BitSet (decoded to value_id set)              | `blockGen[b]`          | object: block_idx → list of value_id  |
| `block_kill[b]` BitSet                                       | `blockKill[b]`         | object: block_idx → list of value_id  |
| `live_in[b]` BitSet                                          | `liveIn[b]`            | object: block_idx → list of value_id  |
| `live_out[b]` BitSet                                         | `liveOut[b]`           | object: block_idx → list of value_id  |
| `iteration` local (run_backward_dataflow)                    | `iter`                 | u32                                   |
| `changed && iteration < MAX_ITERATIONS` (negation)           | `fixpointReached`      | boolean                               |
| `RegAllocResult.assignments`                                 | `assignment`           | object: value_id → reg_id (or absent) |
| `reg_free_until` (regalloc.rs:254)                           | `regFreeUntil`         | object: reg_id → u32                  |
| `caller_free_until` (regalloc.rs:276)                        | `callerFreeUntil`      | object: reg_id → u32                  |
| `used_regs_set` (regalloc.rs:256)                            | `usedRegs`             | sorted list of reg_id                 |
| `state.value_locations` (slot_assignment.rs:758)             | `slotOf`               | object: value_id → slot_offset        |
| derived per-slot end (heap entry `Reverse((u32,usize))`)     | `slotFreeUntil`        | object: slot_offset → u32             |
| pipeline phase marker (synthesised by harness)               | `phase`                | one of the spec phase strings         |

> All maps are emitted as JSON objects keyed by the integer (printed as
> a string in JSON). The trace deserialiser converts them back to TLA+
> functions.

---

## Section 2 — Action-to-Code Mapping

One entry per spec action. Each entry lists:
- **Spec action**: TLA+ action name in `base.tla`.
- **Code location**: `file:line` where the harness must insert the emit.
- **Trigger**: when (before/after) to take the snapshot.
- **Trace event**: the `event` field value.
- **Fields**: top-level event fields (in addition to `state`).
- **Notes**: anything non-obvious.

### 2.1 — `AssignProgramPoints`

| | |
|---|---|
| **Spec action**     | `AssignProgramPoints` (base.tla) |
| **Code location**   | `src/backend/liveness.rs:410` (return statement of `assign_program_points`) |
| **Trigger**         | Immediately AFTER the function builds and returns `ProgramPointState` (i.e. emit just before the `return`). |
| **Trace event**     | `"AssignProgramPoints"` |
| **Fields**          | `func` (function name) |
| **State captured**  | `recordedCallPoints`, `computedDef`, `computedLastUse`, `blockGen`, `blockKill` |
| **Notes**           | Emit `phase = "Dataflow"` to mark the post-state phase advance. The asm-with-no-operand filter at `liveness.rs:316-322` is the **F1** bug surface; capture the full `recordedCallPoints` so the trace shows whether each asm point was included. |

### 2.2 — `DataflowIterStep`

| | |
|---|---|
| **Spec action**     | `DataflowIterStep` |
| **Code location**   | `src/backend/liveness.rs:491` (end of `for idx in (0..num_blocks).rev()` body, after the per-iteration update loop completes) |
| **Trigger**         | AFTER each full sweep of the inner `for idx in (0..num_blocks).rev()` loop, i.e. once per outer-loop iteration. |
| **Trace event**     | `"DataflowIterStep"` |
| **Fields**          | (none beyond envelope) |
| **State captured**  | `iter` (post-increment), `liveIn`, `liveOut`, `fixpointReached` (= `!changed`) |
| **Notes**           | Emit one event per iteration. The final iteration where `changed == false` should set `fixpointReached = true` and `phase = "ExtendIntervals"`. **F3 surface**: the iteration that exits because `iteration >= MAX_ITERATIONS` while `changed == true` should emit a separate `DataflowCapHit` event (see 2.3) instead of (or in addition to) this one. |

### 2.3 — `DataflowCapHit`

| | |
|---|---|
| **Spec action**     | `DataflowCapHit` |
| **Code location**   | `src/backend/liveness.rs:492` (just after the `while` loop exits, when `iteration == MAX_ITERATIONS && changed`) |
| **Trigger**         | Conditional: emit only if loop exited because of the cap (test: `iteration == MAX_ITERATIONS && changed`). |
| **Trace event**     | `"DataflowCapHit"` |
| **Fields**          | (none beyond envelope) |
| **State captured**  | `phase = "ExtendIntervals"`, `fixpointReached = false` |
| **Notes**           | This is the exact production bug (**F3**). The trace event existing at all is itself the smoking gun. |

### 2.4 — `ExtendIntervalsFromLiveness`

| | |
|---|---|
| **Spec action**     | `ExtendIntervalsFromLiveness` |
| **Code location**   | `src/backend/liveness.rs:200` (after both `extend_intervals_from_liveness` and `extend_intervals_for_setjmp` complete in `compute_live_intervals`) |
| **Trigger**         | AFTER both Phase-4 and Phase-4b extensions are applied; before `build_intervals` is called. |
| **Trace event**     | `"ExtendIntervalsFromLiveness"` |
| **Fields**          | (none beyond envelope) |
| **State captured**  | `computedLastUse` (post-extension) |
| **Notes**           | **F2 surface**: `extend_intervals_for_setjmp` is gated by `setjmp_block_indices`, which is only populated by `is_returns_twice_call` (`liveness.rs:940-946`). vfork / getcontext / `__attribute__((returns_twice))` calls are NOT in this list, so `computedLastUse` for live-at-vfork values will not reach `FuncEnd`. The trace lets the validator detect this directly. |

### 2.5 — `BuildIntervals`

| | |
|---|---|
| **Spec action**     | `BuildIntervals` |
| **Code location**   | `src/backend/liveness.rs:203` (after `build_intervals` returns inside `compute_live_intervals`) |
| **Trigger**         | AFTER `build_intervals` completes. |
| **Trace event**     | `"BuildIntervals"` |
| **Fields**          | (none beyond envelope) |
| **State captured**  | `phase = "Phase1"` |
| **Notes**           | Marker event, no payload beyond phase advance. |

### 2.6 — `Phase1Allocate`

| | |
|---|---|
| **Spec action**     | `Phase1Allocate(v, r)` |
| **Code location**   | `src/backend/regalloc.rs:262` (inside the `for interval in &candidates` loop, immediately after `assignments.insert(...)`, when `find_best_callee_reg` returned `Some(reg_idx)`) |
| **Trigger**         | AFTER each successful Phase-1 assignment. Skip iterations that returned `None`. |
| **Trace event**     | `"Phase1Allocate"` |
| **Fields**          | `value` = `interval.value_id` (u32), `reg` = `config.available_regs[reg_idx].0` (u8) |
| **State captured**  | `regFreeUntilAtR` (post update for the chosen reg), `usedRegs` (post insert), `assignment[v]` |
| **Notes**           | The harness must capture the just-updated `reg_free_until[reg_idx]` and the `used_regs_set` snapshot. Emit one event per assignment so the trace replays the per-step preconditions in TLA+. |

### 2.7 — `Phase1Done`

| | |
|---|---|
| **Spec action**     | `Phase1Done` |
| **Code location**   | `src/backend/regalloc.rs:264` (after the `for interval in &candidates` loop ends, before Phase 2 starts) |
| **Trigger**         | AFTER the Phase-1 candidates loop exits. |
| **Trace event**     | `"Phase1Done"` |
| **State captured**  | `phase = "Phase2"` |
| **Notes**           | Marker event. |

### 2.8 — `Phase2Allocate`

| | |
|---|---|
| **Spec action**     | `Phase2Allocate(v, r)` |
| **Code location**   | `src/backend/regalloc.rs:292` (immediately after `assignments.insert(...)` inside the `if let Some(reg_idx) = best` branch) |
| **Trigger**         | AFTER each successful Phase-2 assignment. |
| **Trace event**     | `"Phase2Allocate"` |
| **Fields**          | `value`, `reg` |
| **State captured**  | `callerFreeUntilAtR` (post update), `assignment[v]` |
| **Notes**           | **F1 / F4 surface**: if a value is alive across an asm-no-operand point that was dropped from `recordedCallPoints`, this action will assign it a caller-saved register and the spec invariant `CallerSavedDeadAcrossAsmClobber` will fire. The trace makes the v→r choice visible. |

### 2.9 — `Phase2Done`

| | |
|---|---|
| **Spec action**     | `Phase2Done` |
| **Code location**   | `src/backend/regalloc.rs:295` (closing brace of Phase 2 block) |
| **Trigger**         | AFTER the Phase-2 loop exits (or after the `if !config.caller_saved_regs.is_empty()` block as a whole). |
| **Trace event**     | `"Phase2Done"` |
| **State captured**  | `phase = "Phase3"` |

### 2.10 — `Phase3Allocate`

| | |
|---|---|
| **Spec action**     | `Phase3Allocate(v, r)` |
| **Code location**   | `src/backend/regalloc.rs:311` (immediately after `assignments.insert(...)` in the spillover loop, when `find_best_callee_reg` returned `Some(reg_idx)`) |
| **Trigger**         | AFTER each successful Phase-3 assignment. |
| **Trace event**     | `"Phase3Allocate"` |
| **Fields**          | `value`, `reg` |
| **State captured**  | `regFreeUntilAtR` (post update), `usedRegs`, `assignment[v]` |
| **Notes**           | **F5 surface**: the spec invariant `PoolDisjointness` would catch the case where `r` is in both `available_regs` and `caller_saved_regs`. |

### 2.11 — `Phase3Done`

| | |
|---|---|
| **Spec action**     | `Phase3Done` |
| **Code location**   | `src/backend/regalloc.rs:317` (closing brace of the Phase-3 block, before the `RegAllocResult` is returned) |
| **Trigger**         | AFTER the Phase-3 loop exits. |
| **Trace event**     | `"Phase3Done"` |
| **State captured**  | `phase = "PackSlots"` |

### 2.12 — `AssignSlot`

| | |
|---|---|
| **Spec action**     | `AssignSlot(v, s)` |
| **Code location**   | `src/backend/stack_layout/slot_assignment.rs:758` (the `state.value_locations.insert(dest_id, StackSlot(slot_offset))` call inside the reuse branch) AND `src/backend/stack_layout/slot_assignment.rs:764` (the same in the new-slot branch) |
| **Trigger**         | AFTER each `state.value_locations.insert` call in `pack_values_into_slots`. |
| **Trace event**     | `"AssignSlot"` |
| **Fields**          | `value` = `dest_id`, `slot` = `slot_offset` (i64; emit as integer) |
| **State captured**  | `slotFreeUntilAtS` = the `end` value pushed onto the heap with this slot index, `slotOf[v]` |
| **Notes**           | **F4 surface**: the slot reuse branch (`slot_assignment.rs:752-760`) is the bug-prone one — it trusts `slot_end < start` against possibly-under-approximated intervals. The trace shows when reuse happens; the spec invariant `NoSlotCollision` validates against ground-truth liveness. |

### 2.13 — `PackSlotsDone`

| | |
|---|---|
| **Spec action**     | `PackSlotsDone` |
| **Code location**   | `src/backend/stack_layout/slot_assignment.rs:728` (after `pack_values_into_slots` returns for both 8-byte and 16-byte pools, plus the `no_interval` loop) |
| **Trigger**         | AFTER `assign_tier2_liveness_packed_slots` returns. |
| **Trace event**     | `"PackSlotsDone"` |
| **State captured**  | `phase = "Done"` |

---

## Section 3 — Special Considerations

### 3.1 Hidden Asm Clobber Set (F1)

The `Instruction::InlineAsm.clobbers` field is a `Vec<String>`. The
harness must:

1. Resolve each clobber name to a `PhysReg` via the per-target
   `clobber_to_phys` mapper that LIVENESS would use, **not** just the
   one regalloc uses. For F1 detection, the harness should additionally
   resolve caller-saved register names (rax, rcx, rdx, rsi, rdi,
   r8–r11) so the spec input `AsmClobbers[p]` is the **complete**
   clobber set, not the under-approximation visible to the production
   code.
2. Emit `AsmHasOperands[p]` as `outputs.is_empty() && inputs.is_empty()`
   inverted — exactly the test at `liveness.rs:319`. This ensures the
   spec sees the implementation's actual classification.

The bug surface is the gap between the *true* clobber set (from #1) and
the *recorded* call point set (from #2 → `recordedCallPoints`).

### 3.2 Returns-Twice Recognition (F2)

`is_returns_twice_call` (`liveness.rs:940`) hard-codes 4 names. The
harness should expose `IsRecognizedReturnsTwice[p]` by re-running this
exact predicate at instrumentation time, AND independently classify
real returns-twice functions (`vfork`, `getcontext`, the
`__attribute__((returns_twice))` set) as `ReturnsTwicePoints` from the
front-end (or symbol attributes if available). The harness emits both
sets so the spec invariant can distinguish "should be extended" from
"was extended".

### 3.3 Block-Granular Dataflow Snapshots (F3)

`run_backward_dataflow` (`liveness.rs:456-494`) iterates blocks within
each outer pass. For trace fidelity we record one `DataflowIterStep`
event per OUTER iteration (not per inner block update), capturing the
full `liveIn`/`liveOut` arrays at end-of-iteration. This matches the
spec's granularity (`DataflowIterStep` updates all blocks in one TLA+
step). Per-block events would over-instrument and hide the convergence
boundary that matters.

### 3.4 BitSet Decoding

The implementation uses dense `BitSet` keyed by a remapped value index
(`id_to_dense`, `liveness.rs:227-265`). The harness must decode each
bitset back to the sparse `value_id` set BEFORE emitting. The spec sees
sparse value IDs only; emitting dense indices would silently break
trace replay because `Vals` in the spec config is the sparse set.

### 3.5 Phase Boundary Ordering

The implementation has no explicit "phase done" markers; the harness
must insert them at the syntactic boundaries listed in section 2 (e.g.
`Phase1Done` is emitted at the end of the Phase-1 candidates loop, not
when no `find_best_callee_reg` returns `Some`). This matches the spec's
`PhaseNDone` actions, which are pure phase-advance disjuncts.

### 3.6 CONSTANTS Generation

For each compiled function the harness must emit (separately from the
trace) a CONSTANTS block matching the spec's parameter shape. Suggested
sidecar file: `traces/<func>.constants.cfg`, generated by walking the
IR once before instrumentation kicks in. The validation harness then
runs TLC with `-config <func>.constants.cfg -DJSON=<func>.ndjson`.

### 3.7 What the Harness Must NOT Capture

- **Per-iteration block visit order**. The spec's `DataflowIterStep` is
  one logical step per iteration, not per block update. Capturing every
  block update would force the spec to model intermediate states that
  are not externally observable.
- **Loop-depth weighting** (`regalloc.rs:108-130`). This is a pure
  heuristic; the spec abstracts to an opaque `Priority`. No event.
- **`find_best_callee_reg` "prefer already used" tiebreak** (`regalloc.
  rs:548-573`). Pure heuristic; safety captured by `NoRegisterCollision`.
- **GEP base / F128 source extensions** (`liveness.rs:597-812`). Both
  confirmed sound by the modeling brief; explicitly out of scope.
- **Phi operand iteration** (modeling brief Family 5 — F7). Dead code
  post `eliminate_phis`. Do not emit events for it.
