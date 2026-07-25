# CCC Register Allocator + Liveness — Analysis Report

**Target**: `anthropics/claudes-c-compiler` (CCC). Module under study: `src/backend/regalloc.rs` (573 LOC) and `src/backend/liveness.rs` (1211 LOC), plus the supporting stack-layout / per-architecture prologue files that consume their results.

**Scope (per task brief)**: register allocator + liveness dataflow only. Frontend/parser/mem2reg/linker/codegen are out of scope.

**System category**: **Category B — Concurrent / Lock-Free / Runtime**, but specifically the *single-threaded compiler-pass* sub-flavour. There is no inter-thread concurrency; the safety question is whether two compile-time analyses (liveness dataflow, three-phase linear scan, Tier-2 stack packing, copy coalescing) commute and over-approximate consistently. Each pass is treated as a step transition over a shared state of `(intervals, assignments, slots)` whose invariants must hold globally.

---

## 1. Coverage Statistics

- **Bug-fix commits analysed**: 0 — the artifact is a single-commit snapshot (`git log` returns one commit `6f1b99a`). Git archaeology produces nothing for this case.
- **Open GH issues searched**: ~270 total in repo. Filters used: `regalloc`, `register`, `liveness`, `spill`, `alloc`, `callee`, `caller`, `clobber`, `stack slot`, `coalesce`, `copy`, `miscompile`, `wrong`, `corruption`, plus the `bug` label.
- **GH issues directly relevant to regalloc/liveness**: **0**. The bug tracker is dominated by frontend/parser/type-checker bugs (~120 closed P-tagged items). No filed issue mentions register allocation, spill correctness, or live-interval soundness.
  - The closest adjacent issue is #227 (Csmith/yarpgen fuzz results) — open, no specifics.
  - #167 ("Writes to global register variables silently dropped") and #174 (asm global-register output asserts) touch `asm` register handling but not the dataflow or linear scan.
  - The fact that the repo description says "None of it has been validated for correctness" plus the absence of regalloc bug reports does NOT mean the allocator is correct — it means nobody has filed bugs yet.
- **Core files read in full**: `regalloc.rs`, `liveness.rs`. Read in support: `stack_layout/regalloc_helpers.rs`, `stack_layout/slot_assignment.rs`, `stack_layout/inline_asm.rs`, `stack_layout/copy_coalescing.rs`, `stack_layout/mod.rs`, `state.rs`, plus consumer paths in `x86/codegen/prologue.rs`, `x86/codegen/emit.rs`, `arm/codegen/prologue.rs`, `riscv/codegen/prologue.rs`, `i686/codegen/prologue.rs`.
- **Findings excluded as false positives**: 6 (documented in §4 below).

Bug archaeology is therefore impoverished; the analysis depth comes overwhelmingly from Phase 3 deep code reading, against the algorithmic reference (Chaitin / classical linear scan).

---

## 2. Architectural Map

### 2.1 Liveness pipeline (`liveness.rs`)

```
compute_live_intervals(func):
  Phase 1   assign_program_points        → numbered points, def/use, gen/kill bitsets, call_points, setjmp_blocks
  Phase 1b  extend_gep_base_liveness     → keep GEP base alive through folded Load/Store
  Phase 1c  extend_f128_source_liveness  → keep F128 source ptr alive through Call reload
  Phase 2   build_successor_lists        → CFG including inline-asm goto labels
  Phase 2b  compute_loop_depth           → DFS back-edge detection, loop nesting weight
  Phase 3   run_backward_dataflow        → live_in/live_out fixpoint (CAP: 50 iterations)
  Phase 4   extend_intervals_from_liveness → live-in/live-out push def/use to block boundaries
  Phase 4b  extend_intervals_for_setjmp  → live-at-setjmp values pushed to func_end
  Phase 5   build_intervals              → final sorted intervals
```

Output: `LivenessResult { intervals, call_points, block_loop_depth }`.

### 2.2 Regalloc pipeline (`regalloc.rs`)

```
allocate_registers(func, config):
  if no regs available → return empty (callers fall back to all-stack)
  use_count, eligible (whitelist), non_gpr_values
  remove_ineligible_operands (atomic ptr / memcpy / va* / asm)
  Phase 1: callee-saved for call-spanning intervals
  Phase 2: caller-saved for non-call-spanning intervals
  Phase 3: callee-saved spillover for non-call-spanning intervals
```

Output: `RegAllocResult { assignments, used_regs, liveness }`. Liveness is cached so `calculate_stack_space_common` (Tier-2 packer) does not recompute.

### 2.3 Down-stream consumers

Each backend's `calculate_stack_space` calls `run_regalloc_and_merge_clobbers` (`stack_layout/regalloc_helpers.rs:23`), which:
1. Calls `allocate_registers`.
2. Stores `assignments` in the codegen state.
3. Merges asm-clobbered callee-saved regs into `used_callee_saved` for save/restore in prologue/epilogue.
4. Hands `cached_liveness` to `calculate_stack_space_common` for Tier-2 stack-slot packing.

Per-arch `prologue.rs` constructs `caller_saved_regs` (e.g., `X86_CALLER_SAVED = r11,r10,r8,r9,rdi,rsi,rcx,rdx`) and removes a few entries based on instruction-class heuristics (i128, atomic_rmw, indirect_call). Note: this pruning is by intrinsic-instruction-presence, NOT by inline-asm clobber lists.

---

## 3. Findings

### F1 (HIGH) — Inline-asm caller-saved clobbers do not trigger a call-point and are not removed from the caller-saved pool

**Files / lines**:
- `src/backend/liveness.rs:312-322` — only adds inline asm to `call_points` when `outputs` or `inputs` is non-empty; ignores `clobbers`.
- `src/backend/x86/codegen/emit.rs:96-105` — `clobber_to_phys` only recognises **callee-saved** names (rbx, r12-r15). Caller-saved clobbers (r8-r11, rdi, rsi, rcx, rdx) return `None` and are silently discarded.
- `src/backend/x86/codegen/prologue.rs:40-79` — `caller_saved_regs` is filtered only by `has_indirect_call`/`has_i128_ops`/`has_atomic_rmw`. The asm clobber list is never consulted to remove caller-saved registers from this pool.
- `src/backend/stack_layout/regalloc_helpers.rs:41-45` — asm-clobbered regs are merged into `used_callee_saved` for save/restore, but caller-saved clobbers were dropped earlier so they never reach this list.
- `src/backend/liveness.rs:1174-1210` — existing test `test_empty_inline_asm_barrier_not_call_point` LOCKS IN this behaviour for a `clobbers: ["memory"]` asm; the analogous case with `clobbers: ["r11"]` is untested.

**Mechanism**: a caller-saved physical register clobbered by an empty-operand inline asm is invisible to the regalloc. The allocator may legally assign that register to a value whose live interval crosses the asm. After the asm runs, the value in the register is destroyed but the compiler still believes it lives there.

**Reproduction sketch** (silent miscompile):
```c
long syscall_then_add(long a, long b) {
    asm volatile("syscall" ::: "rax","rcx","r11","memory");
    return a + b;
}
```
If `b` (or `a`) was placed by Phase 2 into r11, the return value is corrupted.

**Compensating mechanisms**: none observed. The codegen-level emitter (`emit_inline_asm_common`) does not re-emit save/restore around clobbers either. The arm/riscv/i686 versions of `clobber_to_phys` follow the same pattern (only callee-saved names matched).

**Severity**: silent miscompile. Real-world likelihood: high — the `syscall` and `cpuid` macro patterns in musl, glibc, Linux kernel headers all use this exact `asm volatile(... ::: clobber-list)` form.

**Verification path**: test-verifiable today (small C file, observe assembly). Also model-checkable by extending the live-interval state to include "asm-clobbered registers as dead at this point".

---

### F2 (MEDIUM) — `is_returns_twice_call` only recognises a hand-written setjmp name list

**File**: `src/backend/liveness.rs:940-946`.
```rust
fn is_returns_twice_call(inst: &Instruction) -> bool {
    if let Instruction::Call { func, .. } = inst {
        matches!(func.as_str(), "setjmp" | "_setjmp" | "sigsetjmp" | "__sigsetjmp")
    } else { false }
}
```

**Mechanism**: `extend_intervals_for_setjmp` extends every value live at one of these calls all the way to `func_end`, preventing Tier-2 slot reuse. That extension does NOT happen for:
- `vfork()` (returns twice — once in parent, once in child),
- `getcontext()` paired with `makecontext`/`setcontext`,
- arbitrary user functions tagged `__attribute__((returns_twice))` (the IR Call has no attribute metadata; only the symbol name is checked),
- weak-aliased setjmp under non-standard names (e.g., musl's `__setjmp` vs glibc's `setjmp`).

**Mechanism failure mode**: a stack slot containing a value live across vfork (or the missed case) gets reused by Tier-2 packing for an unrelated value defined between the two "returns". When the second return restores the program counter, the first value is gone.

**Compensating mechanisms**: none. Asm-driven setjmp-equivalent (e.g., `asm volatile("call setjmp@PLT" ...)`) bypasses the check entirely because only `Instruction::Call { func: "..." }` is examined.

**Severity**: silent miscompile for vfork/getcontext users. Narrower scope than F1.

**Verification path**: test-verifiable by C reproducer using `vfork()`.

---

### F3 (MEDIUM) — Backward-dataflow iteration cap of 50 is unsound on non-convergence

**File**: `src/backend/liveness.rs:466-494`.
```rust
const MAX_ITERATIONS: u32 = 50;
while changed && iteration < MAX_ITERATIONS {
    ...
    let in_changed = live_in[idx].assign_gen_union_out_minus_kill(...);
    changed |= in_changed;
}
```

**Mechanism**: live-in/live-out is a *may* fixpoint computed monotonically. The least-fixed-point grows; the loop exits when nothing changed. An early exit with `changed == true` returns an under-approximation — values that should be live are absent from `live_in`/`live_out`.

The intervals built from this under-approximation are too short. The downstream consequences:
- regalloc may assign one physical register to two intervals that are actually overlapping in the real semantics → silent miscompile.
- regalloc may classify a real call-spanning value as non-call-spanning → caller-saved register is destroyed by the call → silent miscompile.
- Tier-2 slot packing may share a slot between two values that are simultaneously live → silent data corruption.

**Trigger**: pathological reducible CFGs with a chain of mutually-dependent loop nests, or irreducible control flow (computed goto, switch-tail spaghetti) that needs more than 50 sweeps. For ordinary C, the round-robin backward sweep converges in roughly `2 × (max loop depth + 1)` iterations, so 50 is usually plenty. The risk is real for machine-generated C (parser generators, hand-rolled state machines, fuzzer outputs).

**Compensating mechanisms**: none. There is no assertion or warning when the cap is hit; the result is silently used.

**Severity**: silent miscompile under pathological CFGs. Less likely in production C but well within the reach of fuzzing campaigns.

**Verification path**: model-checkable (TLA+ can express "fixpoint reached before exit" as a state predicate); also test-verifiable by handcrafting a CFG that violates the bound.

---

### F4 (MEDIUM) — Tier-2 stack-slot packing is a *consequence* of liveness soundness, not an independent guarantee

**File**: `src/backend/stack_layout/slot_assignment.rs` (function `pack_values_into_slots`).

**Mechanism**: Tier-2 packs two values into the same slot iff their `LiveInterval`s do not overlap. The packer is locally correct, but it has no defense against an unsound input. Any of the bugs in F1 / F2 / F3 (caller-saved clobber missed, returns_twice missed, dataflow truncated) feed directly into Tier-2 and become *data corruption* rather than just register clobbering: the slot of value V and slot of value W coincide while V is still live.

**Why split out**: this is the dependency chain that makes F1-F3 worse than "merely a reg-allocation slip-up." Modeling Tier-2 packing requires modeling the live-interval invariant `forall v,w: same_slot(v,w) ⇒ disjoint_intervals(v,w)`.

**Compensating mechanisms**: none — Tier-2 trusts intervals.

**Severity**: amplifier. No new bug class on its own.

**Verification path**: model-checkable as the safety invariant `NoOverlappingSlotShare`.

---

### F5 (LOW) — Two-pool register encoding works because callee-saved and caller-saved IDs are disjoint per arch — but this is purely conventional

**Files**: `src/backend/regalloc.rs:248-317` (Phase 1/2/3) and per-arch `prologue.rs` (`X86_CALLEE_SAVED = [PhysReg(1..5)]`, `X86_CALLER_SAVED = [PhysReg(8..15)]`).

**Mechanism**: Phases 1 and 3 share the `reg_free_until[]` array indexed against `available_regs` (callee-saved). Phase 2 uses a disjoint `caller_free_until[]` array indexed against `caller_saved_regs`. There is no fundamental check that the two pools are disjoint in physical-register ID space — it is only true because each architecture lists them as disjoint constants. A future refactor that lets a register appear in both pools would silently double-assign.

**Compensating mechanisms**: a unit test would catch a mistakenly-overlapping pool, but none exists today.

**Severity**: latent / structural. No bug today.

**Verification path**: test-verifiable (an assertion at the top of `allocate_registers` that the two pools have empty intersection).

---

### F6 (LOW) — Register-assigned values still have a "phantom" stack slot at offset 0 and codegen is convention-bound

**Files**: `src/backend/state.rs:466-471` (`resolve_slot_addr` returns dummy `Indirect(StackSlot(0))` for register-assigned values), all per-arch codegen sites that read operands.

**Mechanism**: every codegen path that may emit a stack-relative load is required to first check `reg_assignments.contains_key(&value.0)` and dispatch to a register-aware accessor (e.g., `operand_to_rax`, `store_rax_to`, `operand_to_x0`, `operand_to_t0`). If a new code path forgets the check, it emits a load from `(rbp, 0)` — the saved frame pointer — instead. The bug would not be a panic; it would be a silent incorrect read that overlaps the prologue's spilled `rbp` value.

**Compensating mechanisms**: none enforced by the type system. This is purely "remember the convention."

**Severity**: latent / structural. No bug today, but a foot-gun for any future codegen extension.

**Verification path**: code-review-only. Would benefit from a sentinel `StackSlot::INVALID` that triggers a debug_assert when used.

---

### F7 (LOW) — Phi instruction operand iteration over-approximates liveness

**File**: `src/backend/liveness.rs:978`.

`Instruction::Phi` is iterated by visiting *all* incoming operands at the phi's program point. This treats every incoming value as live at the phi, regardless of which predecessor block actually executed. In `mem2reg`-output IR phi nodes are eliminated before register allocation runs (`eliminate_phis`), so the over-approximation never reaches regalloc in practice. Still, the dead branch in `for_each_operand_in_instruction` is misleading and would matter if the IR pipeline ever changes.

**Severity**: dead code / over-approximation. No bug today.

---

## 4. Excluded as false positive

These were investigated and discarded:

| # | Hypothesis | Why excluded |
|---|------------|--------------|
| X1 | `spans_any_call` boundary condition (`cp <= iv.end`) accidentally classifies a value last-used at the call as non-spanning | Code uses `cp <= iv.end`, INCLUDING the boundary — values used at the call are correctly classified as call-spanning (which is correct because they must be live in a register entering the call). |
| X2 | Phase 4 `extend_intervals_from_liveness` moves `def_points` BACKWARDS (to `block_start_points[idx]`) when a value is live-in to an earlier block, producing an interval that starts before the SSA def | The def_point can be moved earlier, but this is a strictly safer over-approximation — it cannot cause overlapping-register conflict, it only causes mild allocation pessimism. |
| X3 | F128 source pointer extension order issue: `extend_f128_source_liveness` runs before backward dataflow so it reads pre-dataflow `last_use_points[dest]` | Compensated by also inserting `pd` into `block_gen[bi]` for every block using `dest_id`. Backward dataflow then propagates the ptr live-in correctly, and Phase 4 extends the ptr's last_use_point. Subtle but correct. |
| X4 | Copy coalescing aliasing a stack-resident value to a register-resident value | Explicitly guarded at `copy_coalescing.rs:67` — coalescing is skipped when either side is register-assigned. |
| X5 | GEP folding extension fails to detect "other uses" via atomic ops | `for_each_operand_in_instruction` returns the atomic ptr operand; `for_each_value_use_in_instruction` returns Memcpy/Va*/InlineAsm-output ptrs. The `_ =>` arm in `extend_gep_base_liveness` correctly catches them all. Verified by reading both helpers and the GEP-foldability check. |
| X6 | ParamRef has no def_point because regalloc's eligible whitelist treats it specially | `inst.dest()` returns the dest for `ParamRef`, and Phase 1 sets `def_points[dense] = point` in the standard arm. Eligibility check is independent. |

---

## 5. Bug Families

Five mechanism-level groups emerge:

### Family 1 — Liveness under-approximation

**Mechanism**: a value that is actually live at point P is not in `live_in/live_out` at P, producing a too-short interval.
**Bugs**: F1, F2, F3.
**Why these group**: each one omits a hidden constraint (clobber, returns-twice, fixpoint-not-reached) that should have made the dataflow declare more values live. The downstream effect is identical — too-short intervals → wrong reg/slot assignment.

### Family 2 — Liveness-driven slot/register reuse without independent invariant check

**Mechanism**: regalloc and Tier-2 packing both *trust* the liveness output. There is no cross-check (e.g., "a register assigned at point P is not held by another value at P").
**Bugs**: F4 (consequence of F1-F3), F5 (latent disjointness assumption).
**Why these group**: structural fragility — soundness is composed, not enforced.

### Family 3 — Convention-only invariants between regalloc and codegen

**Mechanism**: `reg_assignments.contains_key(...)` checks are required at every operand-use site; missing one corrupts data via `(rbp, 0)`.
**Bugs**: F6.
**Why grouped**: stems from the same pattern of "trust the contract" rather than enforcing it.

### Family 4 — Inline-asm semantic underspecification

**Mechanism**: the IR `InlineAsm` instruction's `clobbers` field is not authoritative. Liveness ignores it for call-point classification (F1); regalloc-side mapping only handles callee-saved (F1 again); codegen-side mapping never re-emits save/restore. Empty-operand asm with register clobbers is the canonical hole.
**Bugs**: F1.
**Why distinct from Family 1**: the under-approximation here has a single concrete source — the asm-clobber list — and one obvious fix shape.

### Family 5 — Dead-code / future-pipeline hazards

**Mechanism**: phi-handling in `for_each_operand_in_instruction` is currently dead (phi elim runs first). It will be wrong if the order ever changes.
**Bugs**: F7.

---

## 6. Verification classification

| Finding | Model-checkable | Test-verifiable | Code-review-only |
|---------|-----------------|-----------------|------------------|
| F1 (asm caller-saved clobber) | yes (intervals × clobber sets) | yes (compile and inspect) | — |
| F2 (returns_twice list) | partial (vfork as another setjmp-like step) | yes | — |
| F3 (50-iter cap) | yes (fixpoint termination invariant) | yes (handcrafted CFG) | — |
| F4 (Tier-2 packer trust) | yes (NoOverlappingSlotShare) | yes (assertion in debug builds) | — |
| F5 (pool disjointness) | yes (assert disjoint) | yes (assertion) | — |
| F6 (slot-0 phantom) | — | partial | yes |
| F7 (phi over-approx) | — | — | yes |

---

## 7. Reference pointers

Modeling Brief: `./modeling-brief.md`.

Key files (CCC artifact root: `/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler`):
- `src/backend/liveness.rs:312-322` — inline-asm call-point classification (F1).
- `src/backend/liveness.rs:466-494` — backward dataflow loop with cap (F3).
- `src/backend/liveness.rs:544-568` and `940-946` — setjmp extension and detection (F2).
- `src/backend/regalloc.rs:80-324` — three-phase linear scan.
- `src/backend/regalloc.rs:490-493` — `spans_any_call`.
- `src/backend/stack_layout/slot_assignment.rs` — Tier-2 packing.
- `src/backend/stack_layout/regalloc_helpers.rs:23-50` — `run_regalloc_and_merge_clobbers`.
- `src/backend/x86/codegen/emit.rs:95-110` — `clobber_to_phys` (only callee-saved).
- `src/backend/x86/codegen/prologue.rs:36-85` — caller-saved pool construction (F1).

Reference algorithm: classical linear-scan register allocator (Poletto & Sarkar, 1999) with Chaitin-style "spill the longest-lived" prioritisation. The implementation is "no-split linear scan with priority sort" — values are not split across registers and stack; they get a register for their entire interval or none at all.
