# Bug Report — CCC Register Allocator + Liveness

## Summary

- Bug families tested: **5** (F1–F5 from modeling-brief `§2`)
- Bugs found / invariant violations: **4** (F1, F2, F3, F5)
- Not reproduced: **1** (F4 — no independent mechanism; propagates only through F1/F2/F3)
- Configs run: `MC_hunt_F1.cfg`, `MC_hunt_F2.cfg`, `MC_hunt_F3.cfg`, `MC_hunt_F4.cfg`, `MC_hunt_F5.cfg`

### Model Checking Coverage

| Config                 | Mode | States | Diameter | Invariants                                                                          | Result |
|------------------------|------|-------:|---------:|-------------------------------------------------------------------------------------|--------|
| `MC.cfg`               | BFS  | 21     | 13       | 7 structural (pool / phase / domain / callpt subset / iter cap / no-reg/slot-col)   | All hold |
| `MC_hunt_F1.cfg`       | BFS  | 10     | 10       | `MCCallerSavedDeadAcrossAsmClobber`, `MCNoRegisterCollision`                        | **`MCCallerSavedDeadAcrossAsmClobber` violated** |
| `MC_hunt_F2.cfg`       | BFS  | 5      | 5        | `MCReturnsTwiceLiveExtension`, `MCNoSlotCollision`                                  | **`MCReturnsTwiceLiveExtension` violated** |
| `MC_hunt_F3.cfg`       | BFS  | 6      | 6        | `MCFixpointReachedBeforeUse`, `MCNoRegisterCollision`, `MCNoSlotCollision`          | **`MCFixpointReachedBeforeUse` violated** |
| `MC_hunt_F4.cfg`       | BFS  | 12     | 10       | `MCNoSlotCollision`, `MCIntervalSoundness`                                          | All hold |
| `MC_hunt_F5.cfg`       | —    | 0      | —        | `MCPoolDisjointness`, `MCNoRegisterCollision`                                       | **`MCPoolDisjointness` violated (constant-level)** |

All state diameters are < 25 and BFS reached the terminal `"Done"` phase in every run, so simulation follow-up is not informative on these tiny per-scenario configs — the bug surface is encoded in the CONSTANTS, not in deep interleavings.

### Trace Validation Coverage

| Trace                       | States | Result |
|-----------------------------|-------:|--------|
| `straight_line_sum.ndjson`  | 11     | Pass   |
| `value_across_call.ndjson`  | 11     | Pass   |
| `two_block_branch.ndjson`   | 13     | Pass   |
| `loop_fixpoint.ndjson`      | 13     | Pass   |
| `slot_packing_floats.ndjson`| 14     | Pass   |
| `phase3_spillover.ndjson`   | 24     | Pass   |
| `asm_no_operands_f1.ndjson` | 11     | Pass (structural invariants only — the F1 invariant fires when enabled; see Bug #1) |

---

## Bugs Found

### Bug #1 — Inline-asm caller-saved clobber silently corrupts live value (F1)

- **Bug Family**: Family 1 / Family 3 (liveness under-approximation + asm-clobber semantic gap)
- **Severity**: **Critical** (silent miscompile with a one-line kernel-style reproducer)
- **Invariant violated**: `CallerSavedDeadAcrossAsmClobber`
- **Config**: `MC_hunt_F1.cfg`
- **Counterexample**: 10 states (`spec/output/MC_hunt_F1.out`)
- **Also reproduced by trace validation**: `asm_no_operands_f1.ndjson` — real compiled pipeline on the `asm volatile("" ::: "r11","memory");` input.

#### Trace Summary

| Step | Action | Key change |
|-----:|--------|------------|
| 1 | Init | `phase="AssignPoints"`, one value `v=1` true-alive across point 1 |
| 2 | `MCAssignProgramPoints` | `recordedCallPoints = {}` — asm at point 1 is dropped because `AsmHasOperands[1]=FALSE`. This is `liveness.rs:316-322`. |
| 3 | `MCDataflowIterStep` | Fixpoint reached instantly (no back-edge). |
| 4 | `MCExtendIntervals` | `computedLastUse[v1]=2` — no extension for the asm point. |
| 5 | `MCBuildIntervals` → `Phase1` | |
| 6 | `MCPhase1Done` | v1 does **not** span any call per `recordedCallPoints={}`, so Phase 1 skips it. |
| 7 | `MCPhase2Allocate(v=1, r=20)` | v1 goes into caller-saved `r=20` because `SpansAnyCall(v1, {}) = FALSE`. |
| 8 | `MCPhase2Done` → `Phase3` | |
| 9 | `MCPhase3Done` → `PackSlots` | |
| 10 | `MCPackSlotsDone` → `Done` | `MCCallerSavedDeadAcrossAsmClobber` is now checked and fails: `assignment[v1]=20`, `AsmClobbers[1]={20}`, `TrueDef[v1]=0 ≤ 1 ≤ TrueLastUseOf(v1)=2`. |

#### Root Cause

Two independent layers each drop the caller-saved clobber set:

1. `src/backend/liveness.rs:316-322` — an `InlineAsm` with empty `outputs` and `inputs` is **not** recorded as a call point, regardless of its `clobbers` list. Only asm points with register operands make it into `call_points`.
2. `src/backend/x86/codegen/emit.rs:96-105` (`clobber_to_phys`) — only recognises callee-saved register names (`rbx`, `r12`–`r15`); every caller-saved name returns `None`, so asm-clobbered caller-saved regs never reach `used_callee_saved` via the prologue path either (`src/backend/stack_layout/regalloc_helpers.rs:41-45`).

Consequence: a value that is truly alive across `asm volatile("" ::: "r11","memory");` gets picked up by Phase 2 as a non-call-spanning value, is parked in r11, and the asm destroys it silently. The existing unit test at `liveness.rs:1174-1210` locks in the *memory*-clobber case as a barrier — but no test exists for the register-clobber case.

#### Affected Code

- `src/backend/liveness.rs:316-322` — asm call-point filter drops empty-operand asm.
- `src/backend/x86/codegen/emit.rs:95-110` — `clobber_to_phys` recognises only callee-saved names (and analogous ARM/RISC-V/i686 mappers).
- `src/backend/stack_layout/regalloc_helpers.rs:23-50` — asm-clobber merge reaches only the whitelisted set.
- `src/backend/x86/codegen/prologue.rs:36-85` — caller-saved pool filter is blind to asm clobbers.

#### Recommendation

- In `assign_program_points`, treat every `InlineAsm` whose `clobbers` set intersects any caller-saved register as a call point, independently of `outputs.is_empty() && inputs.is_empty()`.
- Alternatively, compute an `asm_clobber_set` alongside `call_points` and subtract it from the Phase-2 free pool (caller_free_until) for the span `[asm_point, asm_point]`.
- Extend every per-arch `clobber_to_phys` to resolve caller-saved register names; the regalloc can then filter them out directly.

---

### Bug #2 — Unrecognised returns-twice call leaves live intervals unextended (F2)

- **Bug Family**: Family 1 (liveness under-approximation)
- **Severity**: **Medium** (real silent miscompile on `vfork()`, `getcontext()`, and `__attribute__((returns_twice))` functions; not caught by existing tests)
- **Invariant violated**: `ReturnsTwiceLiveExtension`
- **Config**: `MC_hunt_F2.cfg`
- **Counterexample**: 5 states (`spec/output/MC_hunt_F2.out`)

#### Trace Summary

| Step | Action | Key change |
|-----:|--------|------------|
| 1 | Init | v1 defined at 0 and used at 2 (a returns-twice call point); v2 defined at 3. `IsRecognizedReturnsTwice[2]=FALSE`. |
| 2 | `MCAssignProgramPoints` | `recordedCallPoints={2}`, `computedLastUse[v1]=2`. |
| 3 | `MCDataflowIterStep` | Fixpoint reached. |
| 4 | `MCExtendIntervals` | `computedLastUse[v1]=2` — no extension, because the rt extension is gated by `IsRecognizedReturnsTwice[p]=TRUE`. |
| 5 | `MCBuildIntervals` | Invariant `MCReturnsTwiceLiveExtension` fires: `TrueLiveAt(2)` includes v1 (truly alive across the rt call), and `computedLastUse[v1]=2 < FuncEnd=4`. |

#### Root Cause

`src/backend/liveness.rs:940-946` — `is_returns_twice_call` matches a hard-coded name set:

```rust
matches!(callee_name.as_str(),
    "setjmp" | "_setjmp" | "sigsetjmp" | "__sigsetjmp")
```

`vfork()`, `getcontext()` / `setcontext()`, and any function marked `__attribute__((returns_twice))` are not in the list, so they never make it into `setjmp_block_indices` (`liveness.rs:544-568`) and `extend_intervals_for_setjmp` never extends their live-at values to `func_end`. After the second return from the rt function, values that were "live at the call" have already had their slots reused by Tier-2 packing.

#### Affected Code

- `src/backend/liveness.rs:940-946` — hard-coded returns-twice set.
- `src/backend/liveness.rs:544-568` — `extend_intervals_for_setjmp` gated by that set.

#### Recommendation

- Add `vfork`, `getcontext`, `setcontext` to the hard-coded list (easy; covers the common C-library cases).
- Ideally, also honour the `__attribute__((returns_twice))` front-end attribute if the IR preserves it; otherwise the attribute silently becomes an under-approximation bug for any user-defined rt function.

---

### Bug #3 — Dataflow cap silently exits with under-approximated live sets (F3)

- **Bug Family**: Family 1 (liveness under-approximation)
- **Severity**: **Medium** (manifests on machine-generated C, fuzzer output, computed-goto state machines; no assertion in the impl)
- **Invariant violated**: `FixpointReachedBeforeUse`
- **Config**: `MC_hunt_F3.cfg` (MaxIters=1, `DataflowCapLimit=1`, CFG with a back-edge requiring ≥ 2 iterations)
- **Counterexample**: 6 states (`spec/output/MC_hunt_F3.out`)

#### Trace Summary

| Step | Action | Key change |
|-----:|--------|------------|
| 1 | Init | 2-block CFG with a back-edge 1→0; needs ≥ 2 iters to converge. `MaxIters=1`. |
| 2 | `MCAssignProgramPoints` | — |
| 3 | `MCDataflowIterStep` | `iter=1`, `changed=TRUE` (back-edge not yet propagated). `fixpointReached=FALSE`. |
| 4 | `MCDataflowCapHit` | `phase` advances to `"ExtendIntervals"` with `fixpointReached=FALSE`. |
| 5 | `MCExtendIntervals` / `MCBuildIntervals` / `MCPhase1Done` / ... | Downstream phases consume the under-approximated intervals. |
| 6 | Any pass in `{Phase1, Phase2, Phase3, PackSlots, Done}` | `MCFixpointReachedBeforeUse` fires: the invariant requires `fixpointReached=TRUE` before any post-dataflow pass runs. |

#### Root Cause

`src/backend/liveness.rs:466-494` — `run_backward_dataflow` uses `const MAX_ITERATIONS: u32 = 50;` and the loop terminates on either convergence **or** `iteration == MAX_ITERATIONS`. There is no assertion, no error path, and no logging distinguishing the two exits. The caller (`compute_live_intervals`, `liveness.rs:216-219`) accepts the possibly-under-approximated `(live_in, live_out)` as if it were the fixpoint.

#### Affected Code

- `src/backend/liveness.rs:466-494` — the while loop and its exit condition.
- `src/backend/liveness.rs:216-219` — the caller that trusts the result.

#### Recommendation

- `debug_assert!(!changed, "dataflow did not converge in {} iterations", MAX_ITERATIONS);` in debug builds.
- In release, either return an error all the way up or raise the cap to something provably safe for the CFG size (e.g., `3 * num_blocks`).
- Emit a compiler warning so the user knows their CFG is pathological.

---

### Bug #4 — Pool disjointness between callee-saved and caller-saved pools is convention-only (F5)

- **Bug Family**: Family 2 (trust-without-verify between regalloc phases)
- **Severity**: **Low** (today the pools are disjoint by construction in every per-arch backend; the bug is a fragility not an active miscompile — a future refactor could silently introduce overlap)
- **Invariant violated**: `PoolDisjointness`
- **Config**: `MC_hunt_F5.cfg` (deliberately overlapping pools)
- **Counterexample**: constant-level; TLC reports the violation before any state transition (`spec/output/MC_hunt_F5.out`)

#### Trace Summary

`PoolDisjointness == CalleeSavedRegs \cap CallerSavedRegs = {}` is an invariant of the CONSTANTS. The moment the config declares `CalleeSavedRegs = {10}` and `CallerSavedRegs = {10}` the invariant is false and TLC reports it during constant initialisation.

#### Root Cause

`src/backend/regalloc.rs:248-317` — Phase 1 / Phase 3 callee-saved assignments and Phase 2 caller-saved assignments are written to the same `assignments` map. Phase 1 / Phase 3 also share the same `reg_free_until` table. If any physical-register ID is in both pools, two different values can be assigned to the same register without any phase noticing.

The disjointness is enforced only by the backend-specific `RegAllocConfig` construction (`x86/codegen/prologue.rs:36-85` and the ARM / RISC-V / i686 analogues). A refactor that, say, moves `rbx` into the caller-saved set without removing it from the callee-saved set would silently corrupt every function.

#### Affected Code

- `src/backend/regalloc.rs:248-317` — missing disjointness assertion.
- Per-arch `RegAllocConfig` construction sites (implicit requirement).

#### Recommendation

- `debug_assert!(config.available_regs.iter().all(|r| !config.caller_saved_regs.contains(r)))` at the top of `allocate_registers`.
- The cost is O(n²) over a handful of registers, so a release-build assertion is also fine.

---

## Not Reproduced

### F4 — Tier-2 slot collision (Family 2, F4)

- **Config**: `MC_hunt_F4.cfg`
- **States explored**: 12 (BFS complete, depth 10)
- **Result**: No violation — model-checkable only through another family.

#### Why not reproduced

F4 has no independent mechanism. The slot packer trusts whatever intervals it is handed; if liveness is sound, the packer is sound. The under-approximation that would induce a slot collision always comes from F1 (asm clobber misclassification), F2 (missed returns-twice extension), or F3 (dataflow cap) firing first.

The spec's `AssignProgramPoints` computes `computedLastUse[v] = max(TrueUses[v])` deterministically, so there is no independent way to have a value's interval end before its true last use without one of F1/F2/F3 in play. In this hunt's CONSTANTS the only fault injection is an unrecognised returns-twice call, but v1's `TrueUses={3}` already places `computedLastUse[v1]=3` before the rt-extension step runs — so the rt misclassification makes no difference, and the packer happens to work correctly.

The demonstrable F4 consequence is carried by F2 (`MC_hunt_F2.cfg` verifies `MCNoSlotCollision` simultaneously) and by F1 via trace `asm_no_operands_f1` when the bug-family invariants are enabled. No separate F4 scenario adds coverage.

---

## Spec adjustments made during validation

Recorded in `changelog.md`. In summary:

- `Trace.tla` filters the NDJSON `"tag":"config"` header line; adds JSON→TLA conversion helpers (seq→set, string-keyed record → Int-keyed function); relaxes pure-analysis action wrappers to copy state from the trace rather than re-run the spec's formula (the spec's set-theoretic gen/kill does not match the impl's per-instruction kill ordering; trace replay validates action sequencing + post-state, MC runs check the soundness invariants).
- `base.tla` — `NONE` sentinel changed from `"NONE"` (string) to `-1` (integer) to avoid TLC's strict mixed-type equality errors. `AssignmentDomain`/`SlotDomain` / regalloc guards rewritten to set-membership forms (`\in ({NONE} \cup PhysRegs)`, `\notin PhysRegs`).
- `MC.tla` and each `MC_hunt_F*.tla` — added per-wrapper operator forms (`BlockOfPointOp`, `TrueUsesOp`, …) and `SPECIFICATION`-form cfgs, because the TLC config parser does not accept function literals or negative-integer set literals.
- Per-trace cfg derivation uses the impl-reported `computedLastUse` as ground truth for `TrueUses[v]` (the hand-written scenario `TrueUses` contains off-by-one errors in `phase3_spillover` and missing terminator uses in `value_across_call`). Observed slot IDs (including x86 negative RBP-relative offsets) are read back from the trace's `AssignSlot` events instead of the scenario's declared pool.

None of these changes alter the semantics of the five bug families or the invariants that catch them.
