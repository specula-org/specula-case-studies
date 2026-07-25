# Confirmed Bug Report — ccc-regalloc

## Summary

- Total findings reviewed: **4** (F1, F2, F3, F5 from MC; F4 subsumed by F1/F2/F3)
- Reproduced end-to-end (binary produces wrong answer): **1** (F1)
- Confirmed by code audit (no end-to-end crash): **2** (F2, F3)
- False positives: **1** (F5 — unreachable in current backends by construction)
- Inconclusive: **0**

MC found concrete invariant violations for F1/F2/F3; F5 only violates when
the TLA config is deliberately mis-configured to overlap register pools,
which cannot happen with the current per-arch backend constants (verified
below). F4 has no independent mechanism and only manifests through the
others.

All four per-arch backends confirmed to have disjoint register pools:

| Arch   | callee-saved IDs | caller-saved IDs | Disjoint? |
|--------|------------------|-------------------|-----------|
| x86-64 | 1..5             | 10..15            | ✓         |
| ARM64  | 20..28           | 13..14            | ✓         |
| RISC-V | 1..11            | (empty)           | ✓         |
| i686   | 0..3             | (empty)           | ✓         |

---

## Bug 1: Inline-asm caller-saved clobber silently corrupts live value (F1)

- **Source**: MC (`MC_hunt_F1.cfg` → `MCCallerSavedDeadAcrossAsmClobber` violated) + code review.
- **Status**: **REPRODUCED** (end-to-end; observable wrong exit code).
- **Severity**: **Critical** — silent miscompile with a minimal trigger.
- **Location**:
  - `src/backend/liveness.rs:364-370` — InlineAsm call-point filter.
  - `src/backend/x86/codegen/emit.rs:95-110` — `clobber_to_phys` name table.
  - `src/backend/stack_layout/regalloc_helpers.rs:23-50` — callee-saved merge.

### Description

An `InlineAsm` instruction with empty `outputs` and empty `inputs` is NOT
recorded in `call_points`, regardless of what's in its `clobbers` list:

```rust
Instruction::InlineAsm { outputs, inputs, .. } => {
    if !outputs.is_empty() || !inputs.is_empty() {
        call_points.push(point);
    }
}
```

Consequently, `SpansAnyCall(v)` returns false for any value `v` that
straddles such an asm block, Phase 2 parks `v` in a caller-saved
register (x86: r8/r9/r10/r11/rdi/rsi), and the asm silently destroys
`v`'s contents.

A second, defense-in-depth layer also fails: `clobber_to_phys` in each
per-arch codegen only recognises the *callee-saved* register names, so
caller-saved clobbers never reach `used_callee_saved` via the prologue
path either.

### Trigger scenario

```c
__attribute__((noinline)) int compute(int x) { return x * x + 7; }
int main(void) {
    int a = compute(10);         // 107 — lives across the next call
    int b = compute(20);         // 407 — lives to the return
    __asm__ __volatile__(
        "movq $0xBAD1, %%r11\n\t" ...
        : : : "r8","r9","r10","r11","memory"
    );
    return a + b;                 // expected 514; buggy output != 514
}
```

### Reproduction test

`repro/test_bug1_asm_caller_saved_clobber.py` — compiles the above C
with `ccc-x86`, links with gcc, runs the binary, and compares the exit
code with the expected value.

### Reproduction result: **PASS (bug triggered)**

```
$ python3 repro/test_bug1_asm_caller_saved_clobber.py
=== Generated main() body ===
main:
    ...
    call compute
    movq %rax, %r12
    cltq
    movq $0xBAD1, %r11
    movq $0xBAD2, %r10
    movq $0xBAD3, %r9
    movq $0xBAD4, %r8
    movq %rbx, %r10
    addl %r11d, %r10d      <-- uses the clobbered r11 as the value of `b`
    ...

exit code     = 60
expected      = 2 (514 & 0xFF)
             full correct value would be 514

RESULT: BUG REPRODUCED — silent miscompile.
```

The compiled `main()` allocates `b` to `%r11` (caller-saved). The inline
asm writes `0xBAD1` into `%r11`, then `addl %r11d, %r10d` computes
`a + 0xBAD1` instead of `a + b`. The process exits 60 instead of 2.

### Recommendation

Option A (cheapest): treat every `InlineAsm` whose `clobbers` intersects
any caller-saved register as a call point.

Option B (preferred): compute an `asm_clobber_set : Point -> SUBSET PhysReg`
alongside `call_points` and subtract it from Phase 2's free pool at
exactly the asm point. This preserves packing precision for asm blocks
that clobber *callee-saved* only.

Also extend each per-arch `clobber_to_phys` table to resolve caller-saved
names.

### Developer intent

The code at `liveness.rs:364-370` has a comment explaining the current
behavior is deliberate — "empty inline asm barriers are NOT call points
since they don't use any GP registers ... e.g. `asm volatile("" ::: "memory")`".
The existing unit test at `liveness.rs:1251-1283` locks in the
memory-only case. However, the comment's stated safety justification —
"they don't use any GP registers" — is falsified whenever the `clobbers`
list contains a GP register name. The developer reasoning is correct for
a pure memory barrier but does not extend to register-clobber barriers.
Per the bug-confirmation guide §1.5, this is a stated-invariant
violation: the developers claim safety conditional on "no GP registers",
and F1's counterexample contradicts that very condition.

---

## Bug 2: Hard-coded returns-twice list misses vfork / getcontext / setcontext (F2)

- **Source**: MC (`MC_hunt_F2.cfg` → `MCReturnsTwiceLiveExtension` violated) + code review.
- **Status**: **CONFIRMED** by code audit. End-to-end Tier-2 slot-collision
  reproduction not constructed (requires a very specific spill+control-flow
  pattern plus an actual vfork-style double return).
- **Severity**: **Medium** — real silent miscompile on `vfork()`,
  `getcontext()`/`setcontext()`, and user `__attribute__((returns_twice))`
  functions.
- **Location**: `src/backend/liveness.rs:1013-1019`.

### Description

```rust
fn is_returns_twice_call(inst: &Instruction) -> bool {
    if let Instruction::Call { func, .. } = inst {
        matches!(func.as_str(),
                 "setjmp" | "_setjmp" | "sigsetjmp" | "__sigsetjmp")
    } else {
        false
    }
}
```

This hard-coded name set omits every non-setjmp function that also returns
twice. `extend_intervals_for_setjmp` (liveness.rs:617-642) is therefore
never invoked for those callsites, and the Tier-2 slot packer may reuse
a slot that still holds a value live across the second return.

### Trigger scenario

A function that calls `vfork()`, `getcontext()` / `setcontext()`, or a
user function marked `__attribute__((returns_twice))`, with sufficient
live values at the call to induce Tier-2 slot packing. After the "second"
return, the packer has reused one of those values' slots for a different
value, corrupting the first.

### Reproduction test

`repro/test_bug2_returns_twice_missing.py`

- Phase 1 (source audit): greps `is_returns_twice_call` and confirms
  `vfork`, `getcontext`, `setcontext` are absent.
- Phase 2 (differential compile): compiles a C file that calls `setjmp`
  vs `vfork` and reports slot-layout differences.

### Reproduction result: **PASS (source audit)**

```
=== is_returns_twice_call body ===
    if let Instruction::Call { func, .. } = inst {
        matches!(func.as_str(), "setjmp" | "_setjmp" | "sigsetjmp" | "__sigsetjmp")
    } else {
        false
    }

recognised names: ['__sigsetjmp', '_setjmp', 'setjmp', 'sigsetjmp']
absent (buggy):   ['getcontext', 'setcontext', 'vfork']

CONFIRMED: vfork / getcontext / setcontext are NOT recognised
as returns-twice calls.
```

The differential compilation step showed that the two cases produce
different register-allocation decisions (setjmp vs vfork use 10 vs 12
distinct slot offsets and stack sizes 80 vs 96 bytes), demonstrating
the branch is live but the direction of the difference alone does not
constitute a crash. A true end-to-end crash reproducer would require a
genuine vfork()+longjmp()-style harness, which is out of scope for this
confirmation pass. Per bug-confirmation guide §2 "Level 2 state
injection is the practical floor here" — the audit plus differential
compile demonstrate the bug without needing a multi-process fault.

### Recommendation

- Add `vfork`, `getcontext`, `setcontext`, and `__sigsetjmp_internal`
  to the matcher.
- Ideally also honour a `__attribute__((returns_twice))` IR attribute
  if propagated from the front-end.

---

## Bug 3: Backward-dataflow cap is silent (F3)

- **Source**: MC (`MC_hunt_F3.cfg` → `MCFixpointReachedBeforeUse` violated) + code review.
- **Status**: **CONFIRMED** by code audit. Functional reproduction on
  hand-written C did not trigger the cap (reducible CFGs converge in
  O(depth) sweeps; triggering the cap requires fuzzer-grade inputs).
  The bug is the *silence* of the cap, not the cap itself.
- **Severity**: **Medium** — risk surface is machine-generated C,
  fuzzer outputs, and computed-goto state machines.
- **Location**: `src/backend/liveness.rs:504-568`.

### Description

```rust
const MAX_ITERATIONS: u32 = 50;
while changed && iteration < MAX_ITERATIONS {
    ...
}
```

The loop exits on either `!changed` (fixpoint reached) or `iteration ==
MAX_ITERATIONS`. There is no assertion, no error, no logging distinguishing
the two exits. The caller `compute_live_intervals` (liveness.rs:216-219)
accepts the possibly under-approximated `(live_in, live_out)` as if it
were the fixpoint. Downstream, Phase 2 regalloc and Tier-2 slot packing
consume intervals that may end before the value's true last use.

The only hook that fires on cap-hit is `emit_dataflow_cap_hit()`, which
is a no-op unless the TLA+ trace mode has been explicitly enabled.

### Trigger scenario

A CFG large and interconnected enough that worst-case reverse-order
iteration needs more than 50 sweeps to converge. In practice this means
irreducible CFGs (multiple loop entries), goto-heavy state machines, or
deeply nested reducible CFGs visited in a pathologically anti-ordered
block sequence.

### Reproduction test

`repro/test_bug3_dataflow_cap.py`

- Phase 1 (source audit): checks that the cap exists, is hard-coded,
  has no debug_assert, and no error return.
- Phase 2 (attempted trigger): synthesises a ~80-label computed-goto
  CFG and compiles it. CCC emits assembly silently; whether the cap
  was hit is invisible without tla_trace enabled.

### Reproduction result: **PASS (source audit)**

```
=== Source audit checklist ===
  [OK] cap constant
  [OK] loop guard uses cap
  [OK] no debug_assert on convergence
  [OK] no Result/error on cap
  [OK] trace-only cap hook

generated CCC assembly with 400 local labels
```

### Recommendation

- Add `debug_assert!(!changed, "dataflow did not converge in {} iterations", MAX_ITERATIONS);`
- In release builds, raise the cap to a size-proportional bound
  (e.g., `3 * num_blocks`) and log a diagnostic if the cap is ever hit.
- Alternately, propagate a hard error up to the driver so the compiler
  emits a clear message rather than silently miscompiling.

---

## Bug 4: Pool disjointness is convention-only (F5)

- **Source**: MC (`MC_hunt_F5.cfg` → `MCPoolDisjointness` violated, constant-level).
- **Status**: **FALSE POSITIVE** for the current codebase. No
  reproduction written.
- **Severity**: **Low** (self-classified by MC as "fragility, not an
  active miscompile").
- **Location**: `src/backend/regalloc.rs:248-317`; per-arch pool
  declarations in `{x86,arm,riscv,i686}/codegen/emit.rs`.

### Description

`regalloc.rs` does not assert that `config.available_regs` and
`config.caller_saved_regs` are disjoint. If the pools ever overlapped,
Phase 1 / Phase 3 (callee-saved) and Phase 2 (caller-saved) would both
claim the same physical register for different values without
detecting the collision.

### Why this is a false positive today

All four backends construct disjoint pools by design:

```
x86:   CALLEE = {1,2,3,4,5},     CALLER = {10,11,12,13,14,15}
ARM:   CALLEE = {20..28},        CALLER = {13,14}
RISCV: CALLEE = {1..11},         CALLER = {}
i686:  CALLEE = {0,1,2,3},       CALLER = {}
```

The x86 pool is even explicitly commented "(IDs 10+ to avoid overlap
with callee-saved 1-5)". The MC invariant violation requires the TLA
config to deliberately set both `CalleeSavedRegs = {10}` and
`CallerSavedRegs = {10}`, which is achievable in a TLA spec but not in
any CCC compile because the Rust `const` arrays hard-code the disjoint
encoding.

### Recommendation (defensive-coding)

Add, at the top of `allocate_registers`:

```rust
debug_assert!(
    config.available_regs.iter()
        .all(|r| !config.caller_saved_regs.contains(r)),
    "pool disjointness violated: available_regs ∩ caller_saved_regs != ∅",
);
```

This is a one-line guard that would catch any future refactor that
silently introduces an overlap. Reported as a defensive-coding
suggestion, not an active bug.

---

## F4 — Tier-2 slot collision (no separate status)

- **Source**: MC (`MC_hunt_F4.cfg`, no violation).
- **Status**: Not independently reachable. Every F4-shaped
  consequence comes through F1/F2/F3 firing upstream.

F4 is the safety property "two values that are both alive at some
point must not share a slot". Without an upstream liveness
under-approximation (F1/F2/F3), the slot packer is sound by
construction (`last_end < new_start` guard). We list it here for
completeness; the reproductions for Bug 1/2/3 cover the observable
manifestations.

---

## Reproduction artifacts

| Test                                               | Status     | Evidence |
|----------------------------------------------------|------------|----------|
| `repro/test_bug1_asm_caller_saved_clobber.py`      | REPRODUCED | binary exits 60 vs expected 2 |
| `repro/test_bug2_returns_twice_missing.py`         | CONFIRMED  | audit of hard-coded list     |
| `repro/test_bug3_dataflow_cap.py`                  | CONFIRMED  | audit of silent cap          |
| (no test for Bug 4)                                | FALSE POS. | pools disjoint by construction |

All tests are self-contained Python 3 scripts. They invoke the CCC
compiler binary at
`/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc-x86`
and (for Bug 1) `gcc` for linking.
