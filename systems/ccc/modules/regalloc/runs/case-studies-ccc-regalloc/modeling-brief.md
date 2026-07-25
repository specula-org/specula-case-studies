# Modeling Brief — CCC Register Allocator + Liveness

## 1. System Overview

- **Name**: `ccc-regalloc` — register allocator + liveness dataflow of CCC, an LLM-authored Rust C compiler (`anthropics/claudes-c-compiler`).
- **Scope**: only `src/backend/regalloc.rs` (573 LOC) and `src/backend/liveness.rs` (1211 LOC). Per-arch consumers (`x86/codegen/prologue.rs`, etc.) are read for context but not modeled. Frontend / parser / mem2reg / linker / codegen are out of scope.
- **Algorithm**: classical no-split linear-scan register allocator with three phases (callee-saved for call-spanning intervals → caller-saved for non-call-spanning → callee-saved spillover for unfit non-call-spanning), driven by backward-dataflow liveness with bitset gen/kill.
- **System category**: **Category B (Concurrent / Lock-Free / Runtime)** — single-threaded compiler, but treated as a sequential composition of analysis passes whose joint invariants must hold over a global state of `(intervals, assignments, slots)`. There is no inter-thread concurrency, no message passing, no persistence boundary; the open questions are (a) does liveness over-approximate everywhere it must, (b) does the regalloc/Tier-2 packing trust the right interval, and (c) what hidden constraints (asm clobbers, returns-twice calls, fixpoint convergence) silently break that trust. This is the "single-threaded sequential pass with cross-pass invariants" sub-flavour of Category B; see `concurrent-analysis.md` §2.4 ("retire / reclaim lifetime mismatch") for the analogous pattern (here, "kill / reuse interval mismatch").
- **Concurrency model**: none at runtime; compile-time pass composition only.
- **Reference**: classical linear scan (Poletto & Sarkar 1999) with Chaitin-style longest-lived-first priority. CCC deviates from textbook linear scan in three ways: (i) no live-range splitting (a value gets one register for its whole interval or none at all); (ii) priority is not interval length but loop-depth-weighted use count; (iii) eligibility is a whitelist over IR opcodes rather than over operand types.

---

## 2. Bug Families

### Family 1: Liveness under-approximation

**Mechanism**: a value that is actually live at point P is missing from `live_in` / `live_out` at P, producing a too-short `LiveInterval`. Downstream passes (regalloc Phase 2 and Tier-2 stack packing) treat the value as dead and reuse its register / slot, corrupting it.

**Evidence**:
- F1 (HIGH): `liveness.rs:312-322` — inline-asm with empty `outputs`/`inputs` is NOT a call point even when `clobbers` lists caller-saved registers. The `clobber_to_phys` mappers in `x86/codegen/emit.rs:96-105` (and arm/riscv/i686 equivalents) only recognise callee-saved register names, so caller-saved clobbers vanish from every filter on the way to the regalloc. Test `liveness.rs:1174-1210` explicitly locks in this behaviour for the memory-clobber case; the register-clobber case is untested. Reproducer is one line: `asm volatile("syscall" ::: "rax","rcx","r11","memory");` followed by use of a value that Phase 2 placed in r11.
- F2 (MEDIUM): `liveness.rs:940-946` — `is_returns_twice_call` matches a hard-coded list (`setjmp/_setjmp/sigsetjmp/__sigsetjmp`). `vfork()`, `getcontext`/`setcontext`, and arbitrary `__attribute__((returns_twice))` functions are missed. Tier-2 will pack a slot that was live across the second return.
- F3 (MEDIUM): `liveness.rs:466-494` — `MAX_ITERATIONS = 50`. On non-convergence the loop exits with `changed == true`; `live_in/live_out` are silently under-approximated. No assertion fires. Risk surface: machine-generated C, fuzzer outputs, computed-goto state machines.

**Affected code paths**: `compute_live_intervals` (every consumer) → `RegAllocResult.intervals` → Phase 1/2/3 of `allocate_registers` → `pack_values_into_slots` in Tier-2.

**Suggested modeling approach**:
- **Variables**: `liveAt[point] : SUBSET ValueId`, `clobberAt[point] : SUBSET PhysReg`, `assignment : ValueId -> PhysReg ∪ {STACK(slot)}`, `slotOf : ValueId -> SlotId`.
- **Actions**: split `ComputeLiveness` into per-block updates so we can model the fixpoint cap. Add an explicit `AsmClobber(p, regset)` action distinct from `CallPoint(p)`. Add a `ReturnsTwiceCall(p)` action with the post-condition that all values live at `p` have their `last_use` extended to `func_end`.
- **Granularity**: model dataflow at block granularity with a counter; introduce a `FixpointReached` flag that the regalloc step requires before firing. Model intervals as `[def, last_use]` derived from `liveAt`.

**Priority**: **High** — F1 in particular has a one-line reproducer pattern that matches real syscall macros.
**Rationale**: real silent miscompile, no compensating mechanism, no existing test.

---

### Family 2: Trust-without-verify between liveness, regalloc, and Tier-2 packer

**Mechanism**: the regalloc and the Tier-2 stack packer both consume `LiveInterval`s and assume they are sound. There is no independent invariant ("a register is held by at most one value at any program point"; "a stack slot is held by at most one value at any point"). Any flaw in Family 1 propagates into a register or slot collision without anything noticing.

**Evidence**:
- F4 (MEDIUM): `stack_layout/slot_assignment.rs` `pack_values_into_slots` — min-heap by `last_end < new_start`; correct relative to its inputs but no defense against unsound input.
- F5 (LOW): `regalloc.rs:248-317` — Phase 1 and Phase 3 share `reg_free_until[]`; Phase 2 uses the disjoint `caller_free_until[]`. Disjointness of `available_regs` (callee-saved) and `caller_saved_regs` (caller-saved) at the physical-register-ID level is by convention, not assertion. A future refactor could collide them silently.

**Affected code paths**: `pack_values_into_slots` (Tier-2), `allocate_registers` (regalloc).

**Suggested modeling approach**:
- **Invariants**:
  - `NoRegisterCollision`: ∀ p ∈ ProgramPoints, ∀ v1≠v2 with v1 alive at p ∧ v2 alive at p ⇒ assignment[v1] ≠ assignment[v2] (when both are physical regs).
  - `NoSlotCollision`: same but for stack slots.
  - `PoolDisjointness`: `available_regs ∩ caller_saved_regs = ∅`.
- **Variables**: `assignment`, `slotOf`, `liveAt` (from Family 1 spec).
- **Actions**: Tier-2 packing as one or more `AssignSlot(v, s)` actions guarded by the no-collision condition (so a counterexample exposes the violating trace).

**Priority**: **High** — modeling F1-F3 is much more powerful when paired with these explicit safety invariants, because the failure mode is "model-checkable invariant violation" rather than "compiles silently wrong."

---

### Family 3: Asm clobber semantics underspecified

**Mechanism**: `Instruction::InlineAsm.clobbers` is a `Vec<String>`. Three independent layers (liveness call-point classification, regalloc clobber-to-PhysReg mapping, codegen asm emitter) all consult it inconsistently. Every layer drops caller-saved register names. The IR field is descriptively present but semantically invisible.

**Evidence**:
- F1 (already in Family 1, also a member here).
- `x86/codegen/emit.rs:96-105`: only callee-saved (rbx, r12-r15) recognised; everything else returns `None`.
- `stack_layout/inline_asm.rs:86-103`, `stack_layout/regalloc_helpers.rs:41-45`: asm-clobbered regs are merged into `used_callee_saved`, but caller-saved entries never reach this list because they were dropped earlier.

**Affected code paths**: every per-arch `clobber_to_phys`, `caller_saved_regs` filter in `*/codegen/prologue.rs`, `emit_inline_asm_common`.

**Suggested modeling approach**:
- **Variables**: `asmClobberAt[p] : SUBSET PhysReg` separate from `callPointAt[p]`.
- **Actions**: an `AsmClobber(p, R)` action that "kills" every value `v` such that `assignment[v] ∈ R` and `liveAt[v]` straddles `p`, by requiring such `v` to be re-loaded before its next use (modeled as a `Reload(v, p)` step). Counterexample: trace where a value needs `Reload` but the regalloc never inserts one.
- **Granularity**: keep `AsmClobber` distinct from `CallPoint` so the spec can express the intent of F1 as one rule per kind.

**Priority**: **High** — single most likely real-world miscompile in this module.

---

### Family 4: Convention-only invariants between regalloc and codegen

**Mechanism**: `state.rs:466-471` returns a dummy `Indirect(StackSlot(0))` when a register-assigned value is asked for its stack slot. Every codegen path that emits a memory operand must check `reg_assignments.contains_key(...)` first; otherwise it loads from `(rbp, 0)` (the saved frame pointer) instead. The discipline is enforced only by code review.

**Evidence**:
- F6 (LOW): `state.rs:466-471` and the per-arch operand-access sites.

**Affected code paths**: every `operand_to_*` and `store_*_to` in per-arch codegen.

**Suggested modeling approach**: out of scope for TLA+ — this is structural/interface fragility. Model only as an axiom of the spec ("regalloc emits only `RegMove(v)` actions for register-assigned values; stack-emit actions are illegal"); the violation is then a code-review issue, not a model-checker counterexample.

**Priority**: Low.

---

### Family 5: Dead-now-but-fragile pipeline assumption

**Mechanism**: `for_each_operand_in_instruction` (`liveness.rs:978`) treats Phi as a use of all incoming operands at the phi's program point. Phi nodes are eliminated by `eliminate_phis` before regalloc runs, so this code is currently unreachable. It will be wrong (over-approximation, not under-approximation, so safe but wasteful) if the IR pipeline order changes.

**Evidence**: F7.

**Affected code paths**: `for_each_operand_in_instruction`.

**Suggested modeling approach**: ignore. Note explicitly in the spec's "do not model" list.

**Priority**: Low.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Backward-dataflow liveness with explicit fixpoint counter | Captures Family 1 (F3) | Iterate `live_in / live_out` block updates as separate TLA+ actions; set `FixpointReached` when no change in a sweep; cap iteration count and let invariant violation expose under-approximation when the cap is hit. |
| Inline-asm clobber as a first-class step `AsmClobber(p, R)` | Captures Family 3 (F1) | Distinct from `CallPoint`. A `RegisterCollision` invariant fires when a value holds a clobbered reg across the asm point without an inserted reload. |
| Returns-twice generalisation | Captures Family 1 (F2) | Action `ReturnsTwiceCall(p)` extends `last_use` of all values live at `p` to `func_end`. Spec lists which functions are recognised; an extension predicate `IsReturnsTwice(funcName)` should be a parameter so we can model the missing-vfork case as the spec parameter shrinking. |
| Three-phase linear scan with shared `reg_free_until` | Captures Family 2 (F4, F5) | Phase 1, 2, 3 as separate TLA+ actions; pool disjointness as a system-level invariant; per-step `NoRegisterCollision` invariant. |
| Tier-2 slot packing as `AssignSlot(v, s)` | Captures Family 2 (F4) | Guarded by `NoSlotCollision` invariant; counterexample = under-approximated interval lets two simultaneously-live values share a slot. |
| `spans_any_call` boundary semantics (`cp ≤ iv.end`) | Sanity check | One-line action; verify the boundary case in TLC. |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Whitelist of regalloc-eligible IR opcodes | Pure performance heuristic; not a safety question. Eligibility errors fall back to stack, which is correct. |
| Loop-depth weighting of use counts | Pure priority heuristic. Spec uses an abstract priority. |
| GEP base-liveness extension and F128 source-pointer extension | Both are confirmed sound (no bug found); they are local, well-tested optimisations. |
| Phi operand iteration | Dead code (F7). |
| Per-arch register name → PhysReg map | Naming convention; the bugs are about what `clobber_to_phys` *misses*, which we model as set membership. |
| Codegen-side phantom-slot convention (F6) | Cross-module fragility; not a TLA+ target. |
| Tier-3 block-local slot reuse | Outside our scope; same correctness shape as Tier-2 once Family 2 invariants hold. |
| `find_best_callee_reg` "prefer already-saved" heuristic | Pure heuristic; safety captured by `NoRegisterCollision`. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Inline-asm clobber tracking | `asmClobberAt : Point -> SUBSET PhysReg` | Distinguish asm-clobber from call-point (F1) | 1, 3 |
| Returns-twice predicate parameter | `IsReturnsTwice : FuncName -> BOOLEAN` (CONSTANT) | Let the spec instantiate either the buggy 4-name set or the corrected vfork-inclusive set (F2) | 1 |
| Fixpoint convergence flag | `fixpointReached : BOOLEAN`, `iterationCount : Nat`, CONSTANT `MaxIters` | Force regalloc/packing to wait for convergence; counterexample if cap is hit (F3) | 1 |
| Per-point register map | `regHeldBy : (Point × PhysReg) -> ValueId ∪ {NONE}` | Express `NoRegisterCollision` invariant directly | 2 |
| Per-point slot map | `slotHeldBy : (Point × SlotId) -> ValueId ∪ {NONE}` | Express `NoSlotCollision` invariant directly | 2 |
| Pool disjointness | derived from `availableRegs ∩ callerSavedRegs` | Express `PoolDisjointness` invariant | 2 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `NoRegisterCollision` | Safety | At every program point `p`, no two distinct values both alive at `p` are mapped to the same physical register. | Family 1, 2 (F1, F3, F4) |
| `NoSlotCollision` | Safety | At every program point `p`, no two distinct values both alive at `p` are mapped to the same stack slot. | Family 1, 2 (F1, F2, F3, F4) |
| `CallerSavedDeadAcrossCall` | Safety | If `assignment[v] ∈ callerSavedRegs` then `liveInterval[v]` does not contain any `callPointAt`. | Family 1 (F1, F3) |
| `CallerSavedDeadAcrossAsmClobber` | Safety | If `assignment[v] ∈ R` and `R ⊆ asmClobberAt[p]` and `p ∈ liveInterval[v]`, then a `Reload(v, p)` step is inserted before the next use. | Family 3 (F1) |
| `ReturnsTwiceLiveExtension` | Safety | For every `p` with `IsReturnsTwiceAt[p]`, every value live at `p` has `last_use ≥ func_end`. | Family 1 (F2) |
| `FixpointReachedBeforeUse` | Safety | `allocate_registers` and `pack_values_into_slots` may only fire after `fixpointReached = TRUE`. | Family 1 (F3) |
| `PoolDisjointness` | Safety | `availableRegs ∩ callerSavedRegs = ∅`. | Family 2 (F5) |
| `IntervalSoundness` (background) | Safety | `def_point[v] ≤ first_use[v]` and `last_use[v] ≥ every actual use of v`. Violations are how Family 1 manifests. | Family 1 |

The **two** primary safety invariants for the spec are `NoRegisterCollision` and `NoSlotCollision`. Every Family 1 and Family 3 bug shows up as one of these failing.

---

## 6. Findings Pending Verification

### 6.1 Model-checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| F1 | Inline-asm caller-saved clobber not a call-point; caller-saved pool not filtered by asm clobbers | `CallerSavedDeadAcrossAsmClobber` (or `NoRegisterCollision` if expressed differently) | 1, 3 |
| F2 | `is_returns_twice_call` misses vfork/getcontext/`returns_twice` attribute | `ReturnsTwiceLiveExtension` violated → `NoSlotCollision` violation in trace using vfork | 1 |
| F3 | Backward-dataflow capped at 50 iterations; under-approximation on non-convergence | `FixpointReachedBeforeUse` violated; downstream `NoRegisterCollision` / `NoSlotCollision` | 1 |
| F4 | Tier-2 packer trusts intervals; a too-short interval lets two live values share a slot | `NoSlotCollision` | 2 |
| F5 | `available_regs` / `caller_saved_regs` disjointness is convention | `PoolDisjointness` (sanity invariant; violation requires deliberate spec misconfig) | 2 |

### 6.2 Test-verifiable

| ID | Description | Suggested test approach |
|----|-------------|--------------------------|
| F1 | Caller-saved clobber via `asm volatile("syscall" ::: "rax","rcx","r11","memory")` | Add a unit test mirroring `test_empty_inline_asm_barrier_not_call_point` (`liveness.rs:1174-1210`) but with `clobbers: vec!["r11".to_string()]`; assert the asm point IS in `result.call_points`. Plus an end-to-end C test compiling the syscall pattern and observing the resulting assembly. |
| F2 | `vfork` not extending live intervals to func_end | C reproducer: define values, `pid_t p = vfork();`, use the values in the parent branch; compile and observe Tier-2 reuse of those slots between vfork and parent return. |
| F3 | 50-iter cap | Synthesise a CFG (e.g., a switch with 100 cases each branching back to a header) that needs >50 iterations; assert dataflow converged before exit. |
| F5 | Pool disjointness | Add `debug_assert!` at the top of `allocate_registers` that `available_regs.iter().all(|r| !caller_saved_regs.contains(r))`. |

### 6.3 Code-review-only

| ID | Description | Suggested action |
|----|-------------|------------------|
| F6 | Phantom `StackSlot(0)` for register-assigned values; codegen-by-convention | Introduce a sentinel `StackSlot::INVALID` with `debug_assert!` on use; document in `state.rs` and `regalloc.rs`. |
| F7 | Phi operand over-approximation in `for_each_operand_in_instruction` | Add a comment that this branch is dead post `eliminate_phis`; consider `unreachable!()` to enforce the invariant. |

---

## 7. Reference Pointers

- Full audit: `./analysis-report.md`.
- Source tree: `/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler`.
- Hot files:
  - `src/backend/liveness.rs:312-322` (asm call-point — F1)
  - `src/backend/liveness.rs:466-494` (dataflow cap — F3)
  - `src/backend/liveness.rs:544-568, 940-946` (setjmp — F2)
  - `src/backend/regalloc.rs:80-324` (three-phase linear scan)
  - `src/backend/regalloc.rs:490-493` (`spans_any_call`)
  - `src/backend/stack_layout/regalloc_helpers.rs:23-50` (regalloc + clobber merge)
  - `src/backend/stack_layout/slot_assignment.rs` (Tier-2 packing — F4)
  - `src/backend/x86/codegen/emit.rs:95-110` (`clobber_to_phys` — F1)
  - `src/backend/x86/codegen/prologue.rs:36-85` (caller-saved pool — F1)
- Related GH issues (none directly on regalloc; closest adjacents): #167, #174, #227.
- Reference algorithm: Poletto & Sarkar, "Linear Scan Register Allocation," 1999; Chaitin et al., "Register Allocation via Coloring," 1981 — the priority-by-use-count and longest-lives-first heuristics borrow from both.
- Category playbook: `references/concurrent-analysis.md` — single-threaded compositional invariants apply; treat each pass as an action, treat shared `(intervals, assignments, slots)` as the analogous shared state, and put the safety invariants on the post-state of each step.
