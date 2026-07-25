# Confirmed Bug Report — ccc-mem2reg

## Summary

- **Total findings reviewed**: 9 (across families F1–F7 and code-review items
  D1, D2, D3, D4, D5, D6)
- **Reproduced**: **2** (D3 multi-asm-goto snapshot overwrite,
  D2 retarget-once bypass)
- **Confirmed but no reproduction**: 0
- **False positives / not real bugs**: 4 (F1, F2, F3, F7 — see § "Not Bugs")
- **Code-quality / theoretical**: 3 (D1 preds-multiset, D4 CHK-termination,
  D5 deep-recursion — none with concrete miscompile path; carried as
  hardening recommendations)

Both reproduced bugs were already known to the bug-hunting pipeline:
* **Bug 1 (D3)** was MC-confirmed (counterexample in `MC_hunt_F4_D3.cfg`,
  initial-state violation of `NoOverlappingAsmGotoTargets`).
* **Bug 2 (D2)** was code-audit-only in the bug report ("not testable with
  this fixture"); we constructed a CCC-accepted C input that drives the
  buggy IR shape and triggers an observable miscompile.

---

## Bug 1: Multi-asm-goto same-target overwrites `goto_label_snapshots`

- **Source**: MC counterexample (Family F4 / D3) + code audit
- **Status**: **REPRODUCED**
- **Severity**: High — silent miscompile of any function that has two or
  more `InlineAsm` instructions with `goto_labels` in the same block
  targeting the same label, with a promoted-alloca store between them.
  Realistic in Linux kernel `ALTERNATIVE` / `static_branch` patterns.
- **Location**:
  - `src/ir/mem2reg/promote.rs:653` — `goto_label_snapshots: FxHashMap<BlockId, Vec<Operand>>` keyed only by target label.
  - `src/ir/mem2reg/promote.rs:717-727` — snapshot write site (`insert` overwrites prior snapshot for same target).
  - `src/ir/mem2reg/promote.rs:785-808` — phi-fill site (reads single overwritten snapshot).
  - `src/ir/mem2reg/promote.rs:820-870` — recursive descent into asm-goto targets uses `goto_target_indices` derived from the same hashmap.

### Description

`rename_block` keeps a `goto_label_snapshots: FxHashMap<BlockId, Vec<Operand>>`
that records, for each asm-goto target label, the def-stack tops at the
asm-goto point. The intent is to ensure phi nodes at goto-targets receive
the correct value — definitions produced *after* the asm-goto in the same
block must not be visible along the goto edge.

The map is keyed only by the target `BlockId`; every new
`ASM_HAS_GOTO_LABELS` instruction in the block unconditionally
`insert`s, overwriting any earlier snapshot for the same label. When two
asm-goto instructions in one block share a goto target, the second
asm-goto's snapshot replaces the first — and the phi-fill loop later reads
that single (later) snapshot for the runtime edge from the *earlier*
asm-goto. The result: any alloca whose value differs between the two
asm-goto sites is lowered to the wrong incoming value on the earlier edge.

### Trigger Scenario

```c
int check(int cond) {
    int v = 0;
    asm goto("testl %0, %0\n\tjz  %l[bail]" : : "r"(cond) : "cc" : bail);
    v = 1;
    asm goto("testl %0, %0\n\tjnz %l[bail]" : : "r"(cond) : "cc" : bail);
    v = 2;
    return v;
bail:
    return v;
}
```

* `check(0)` should return `0` — first asm-goto's `jz` taken with v == 0.
* `check(1)` should return `1` — second asm-goto's `jnz` taken after `v = 1`.

### Reproduction Test

`repro/test_bug1_d3_asm_goto_snapshot.py`

The script writes the C source to a temp file, invokes the CCC release
binary at
`/home/ubuntu/Specula/case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc`
to emit assembly, links via system `gcc`, then runs the binary and checks
its output against the expected `(0, 1)` pair.

### Reproduction Result: **PASS**

```
$ python3 repro/test_bug1_d3_asm_goto_snapshot.py
check(0) = 1 (expected 0)
check(1) = 1 (expected 1)
BUG REPRODUCED: mem2reg D3 asm-goto snapshot overwrite

[REPRO RESULT] PASS — bug triggered
```

GCC's output on the same source is `check(0) = 0`, `check(1) = 1` (correct),
confirming the C source is well-defined and the divergence is a CCC bug.

### Root-cause confirmation in generated assembly

The `bail:` label compiles to a single unconditional `movq $1, %rax`,
proving the lowering used a single phi-incoming (the second snapshot,
v=1) on every edge into `bail`. Compare against the multi-incoming structure
GCC emits (a phi → conditional select).

### Recommendation

Extend the snapshot key by an intra-block asm-goto occurrence index:

```rust
goto_label_snapshots: FxHashMap<(BlockId /*target*/, u32 /*asm_idx*/), Vec<Operand>>
```

Then in the phi-fill loop, enumerate every asm-goto in `b` whose
`goto_targets` contains `succ_label` and append one phi-incoming entry per
occurrence. The corresponding spec change (already hinted at by the
`asmCursor` field on rename frames) is to turn `gotoSnapByLabel[b][sb]`
into `gotoSnapByLabel[b][sb][asmIdx]`.

---

## Bug 2: `retarget_block_edge_once` rewrites only one of multiple duplicate edges

- **Source**: Code audit (Family F6 / D2). Bug report classified D2 as
  "**not testable** with this fixture" — we built a CCC-accepted C input
  and reproduced an observable miscompile.
- **Status**: **REPRODUCED**
- **Severity**: High in principle; the *natural* C trigger surface is
  narrow (CCC's frontend doesn't naturally produce the duplicate-target
  IR shape from a `switch`), but any future optimization or input that
  produces a switch / asm-goto with duplicate IR edges to a phi-bearing
  block will silently miscompile.
- **Location**:
  - `src/ir/mem2reg/phi_eliminate.rs:107-159` — `retarget_block_edge_once`
    early-`return`s after the first matching edge in either the terminator
    (Switch / IndirectBranch / CondBranch) or the InlineAsm `goto_labels`
    list. Other matching edges retain the pre-trampoline target.
  - `src/ir/mem2reg/phi_eliminate.rs:443-453` — `place_copy` /
    `place_copies` create the trampoline once per `(pred, target)` pair,
    so all duplicate edges *should* share one trampoline; the retarget
    fails to actually redirect them all.

### Description

When eliminating phis at a target block `B`, the pass detects that the edge
`(P, B)` is critical (P has multiple distinct successors). It builds a
trampoline block `T` containing the phi-copy and a `Branch(B)`, then calls
`retarget_block_edge_once(P, B, T)` to redirect P's outgoing edge to land
in `T` instead of `B`.

The retarget walks P's terminator and InlineAsm `goto_labels`, but `return`s
after rewriting *the first* matching `B`. If P's terminator (or one of its
asm-gotos) has *multiple* edges to `B`, the un-rewired duplicates still
branch directly to `B` at runtime, bypassing `T`'s phi-copy. The phi
destination at `B` is therefore consulted with whatever value happened to
sit in the destination register on that runtime path — i.e. uninitialised.

The bug-report's MC fixture had a `Switch <<3, 3, 4>>` shape (block 3 has
two switch edges from block 0), but with only one *distinct* predecessor
the IDF gate kept any phi from being inserted at block 3, so the invariant
was vacuously true. Adding a second distinct predecessor turns this latent
defect into a reachable miscompile.

### Trigger Scenario

CCC's `switch` lowering creates a fresh empty block per case label, so
naturally-written switches do not produce the
`Switch { default: B, cases: [(_, B), …] }` shape required by D2. The
remaining reachable trigger is an asm-goto with duplicate label entries,
which CCC's parser accepts (more permissive than GCC):

```c
int test(int cond, int x) {
    int v;
    if (cond) { v = 100; goto bail; }   /* direct edge to bail (v=100)    */
    v = 7;
    asm goto("jmp %l1" : : : : bail, bail);  /* %l1 = SECOND label entry  */
    v = 99;
    if (x) goto other;          /* makes the asm block multi-successor   */
    return v;
other:
    v = 88;
    return v;
bail:
    return v;
}
```

Block C (containing the asm-goto) has three distinct successors
`{bail, other, ret_block}` → the `(C, bail)` edge is critical → trampoline
`T: Copy(phi_dest, 7); Branch(bail)` is created. `retarget_block_edge_once`
walks C's CondBranch (no match) then the asm-goto's `goto_labels =
[("bail", B), ("bail", B)]` and rewrites the FIRST entry to `T`, returning
immediately. The second entry still resolves to `B`. The asm template's
`%l1` is a positional reference to the second entry, so the runtime jump
goes directly to `bail`, bypassing `T`. The phi destination at `bail` is
loaded from whatever register held a stale value.

* Expected: `test(0, 0)` returns `7`, `test(1, 0)` returns `100`.
* Buggy: `test(0, 0)` returns garbage (observed `515` in our run); the
  `cond=1` path uses a non-critical direct edge and works correctly.

### Reproduction Test

`repro/test_bug2_d2_dup_asm_goto_target.py`

Uses the same compile/link/run pipeline as Bug 1.

### Reproduction Result: **PASS**

```
$ python3 repro/test_bug2_d2_dup_asm_goto_target.py
test(0, 0) = 515 (expected 7)
test(1, 0) = 100 (expected 100)
BUG REPRODUCED: mem2reg D2 retarget-once bypassed phi copy
                (test(0,0) = 515, expected 7 — phi dest uninitialised)

[REPRO RESULT] PASS — bug triggered
```

The `cond=0` path should arrive at `bail` with v=7 (the snapshot at the
asm-goto site). It instead returns the dword that happens to occupy the
phi destination register at runtime — concretely 515 here, but the
underlying defect (uninitialised read of the phi destination) is what the
test asserts.

### Note on test legitimacy

`asm goto(... : : : : bail, bail)` with duplicate label names is rejected by
GCC. CCC's parser accepts it, the IR-lowering preserves both entries, and
the inline-asm backend resolves `%l1` to the second entry. The reproduction
exploits that combination, so it is *CCC-specific input* — but the
underlying defect (`retarget_block_edge_once` early-`return`) would also
fire on any other IR shape with duplicate edges to a phi-bearing block:

* **Switch with `default == case_i`** (the bug-report's M1) — currently
  unreachable via natural C `switch` lowering, but possible if a future
  pass coalesces case-block targets, or if any frontend / IR builder
  produces it.
* **IndirectBranch with the same target listed twice** in
  `possible_targets` — currently unreachable from `&&label` patterns
  (CCC tracks distinct labels), but the same retarget defect applies.

A defensive fix is single-line.

### Recommendation

Make `retarget_block_edge_once` rewrite *every* matching edge instead of
returning after the first. Replace the early `return`s with continue-loop
logic for Switch cases / IndirectBranch targets / InlineAsm `goto_labels`,
and remove the early `return` between the terminator block and the
InlineAsm scan. Renaming to `retarget_block_edges` (no "once") would also
make the contract clear at call sites in `apply_phi_transformations`
(`phi_eliminate.rs:507-514`).

---

## Not Bugs / False Positives

| Family | What MC tested | Outcome |
|--------|----------------|---------|
| F1 (alloca eligibility / escape detection) | Disqualifier coverage of `STORE_VAL`, `GEP`, asm-mem outputs, etc. | **Not a bug.** The current `find_promotable_allocas` filter (promote.rs:210-360) lists every disallowed use kind explicitly; MC's `MC_hunt_F1.cfg` exhausted 32 distinct states with no violation. Historical F1 bugs are all fixed. |
| F2 (alloca placement, parameter detection) | Param-alloca prefix invariant, unreachable-block alloca handling | **Not a bug.** MC ran 30 min / 347 M states with no violation. The positional-skip code in promote.rs:218-242 is correct as long as `#allocas_in_entry >= #params`, which holds today. D6 (positional dependency) is hardening (see Recommendations). |
| F3 (phi well-formedness) | `PhiIncomingMatchesPreds`, narrowed-const correctness | **Not a bug.** MC's spurious counterexample was caused by a spec issue (`RenameDone` precondition), now fixed. The actual code path is correct. |
| F7 (phi-elim copy cycles) | Conservative safety-net of `find_conflicting_phis` | **Not a bug.** Verified by case analysis (2-cycles, 3-cycles, chains, self-copies). The over-approximation is intentional and correct. |

## Code-Quality / Theoretical Findings (not reproduced as bugs)

These are real code-quality issues called out in the modeling brief but
do not produce an observable miscompile on any inputs we could construct:

* **D1 — `preds` is a multiset, not a set** (analysis.rs:119-186 builds
  `preds` without de-duplication). The `compute_dominance_frontiers` gate
  `preds.len(b) < 2` therefore counts duplicate edges. Worst-case effect
  is overestimating phi cost (causing an alloca to be dropped from
  promotion) — *not* a miscompile. MC's F5 hunt found no violation across
  347 M states.
* **D4 — CHK fixpoint termination** is unproven for adversarial irreducible
  CFGs but holds for any finite CFG by monotonicity. No real-world
  divergence reproducer.
* **D5 — `compute_reverse_postorder` recursion depth** scales with CFG
  block count. Concerning at >40 000 blocks; not reachable in practice.

---

## Methodology Notes

* The CCC binary is the pre-built release at
  `case-studies/ccc/artifact/claudes-c-compiler/target/release/ccc`.
* Both reproduction tests use only the public CLI (`ccc -S source.c -o out.s`)
  and the system `gcc` for linking. No internal API was called and the IR
  was not constructed by hand.
* Each test asserts an end-to-end runtime miscompile (a wrong return
  value), not an "intermediate variable looks wrong" check.
* The bug-confirmation skill's escalation ladder was not needed past
  Level 0 — both bugs trigger from natural compile-link-run flows on the
  default x86-64 target, with no failpoints, no timing tweaks and no
  source-code modifications.
