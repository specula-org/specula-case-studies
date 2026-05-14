# Confirmed Bug Report — arc-swap_3

## Summary

- **Total findings reviewed**: 5 (all from MC counterexamples in
  `bug-report.md`, none new from code review).
- **Reproduced under Miri**: 4 of 5 (Bugs 1, 2, 3, 5).
- **Reproduction failed (bug still believed real)**: 1 of 5 (Bug 4 —
  reproduction limited by x86_64 Miri's TSO-leaning weak-memory emulation;
  upstream confirmed real via formal C++ MM proof in #200).
- **False positives**: 0.
- **Inconclusive**: 0.

All five MC findings are **historical UAF bugs already fixed in mainline**.
Each maps to a specific upstream issue/PR and a specific commit. The MC
results validate that the SeqCst / Acquire labels currently in the code at
the cited lines are *load-bearing*: downgrading any one of them re-introduces
the documented historical bug. This is the protocol's intended interpretation
("the SC labels close the cross-variable bridge") and the case study confirms
it on a per-site basis.

Per the bug-confirmation skill, known/historical bugs do not strictly require
reproduction (the existing JIRA/issue serves as confirmation). We attempted
reproduction anyway by reverting the historical fix one site at a time and
running aggressive multi-thread Miri stress tests; this rules out the
possibility that the MC counterexample is a model artifact rather than a real
property of the code.

### Reproduction infrastructure (per task requirement)

- `repro/test_bug1_debt_pay_failure_leg.sh` — Bug 1 reproduction
- `repro/test_bug2_fallback_load.sh` — Bug 2 reproduction
- `repro/test_bug3_fast_confirm_load.sh` — Bug 3 reproduction
- `repro/test_bug4_debt_pay_success_leg.sh` — Bug 4 reproduction (failed)
- `repro/test_bug5_list_head_load.sh` — Bug 5 reproduction
- `repro/test_harness_uaf_stress.rs` — multi-thread stress test (load/store/rcu)
- `repro/test_harness_dynamic_threads.rs` — multi-thread stress test that
  forces fresh debt-list nodes to be prepended mid-writer-scan
- `repro/evidence/bug{1..5}_miri_output.txt` — raw Miri error excerpts

Each script saves the source file, applies a single-line revert of the
historical fix, runs `cargo +nightly miri test`, restores the file, and
reports whether `error: Undefined Behavior` appeared. The harness tests
(`tests/uaf_stress.rs`, `tests/dynamic_threads.rs`) are added under
`artifact/arc-swap/tests/` for cargo to discover; copies are mirrored under
`repro/` for self-contained reference. `tests/fallback_uaf.rs` already exists
upstream as the regression test for #198.

---

## Bug 1: Debt::pay failure-leg downgrade leaks UAF (PR #195)

- **Source**: MC (counterexample 13 states, `MC_hunt_familyA.cfg` BFS depth 15)
- **Status**: REPRODUCED (Miri seed=4 with reverted fix; passes cleanly with fix)
- **Severity**: Critical (UAF)
- **Report Tier**: A — historical bug, already fixed upstream
- **Location**: `artifact/arc-swap/src/debt/mod.rs:77`

### Description
`Debt::pay`'s CAS uses `compare_exchange(ptr, NONE, success_ord, failure_ord)`.
PR #195 (commit `bd5d327`) upgraded the failure leg from `Relaxed` → `Acquire`
so that when the reader observes "writer paid the debt" (CAS failed), it has
acquired the writer's `T::inc` — preventing the reader from racing with the
writer's `Arc::drop_slow` on the same allocation.

### Trigger scenario
1. Reader t1 takes a fast-path Guard for ptr `a1`.
2. Writer t2 calls `WriterSwap` (a1 → a2), enters `pay_all`.
3. Writer t2 pays t1's slot (CAS slot from a1 → NONE), pre-pays a refcount
   inside `pay_all` via `T::inc(&val)`.
4. Reader t1 drops its Guard. `Debt::pay` CAS fails (slot is NONE) — failure
   leg fires. With Relaxed, t1 has *no* happens-before edge from the writer's
   pay_all → T::inc.
5. Reader t1 deref's its Guard's Arc; meanwhile writer t2 finishes pay_all
   and drops the old Arc. Race on the Arc allocation → UAF.

### Developer intent investigation
- PR #195 ("Fix Debt::pay failure ordering"), commit `bd5d327`, explicitly
  states the requirement: *"On failure, we have observed that the debt has
  been paid, but we need to establish a happens-before relationship with that
  debt being paid before we do anything that relies on the Arc's strong counter
  being incremented, so we need to Acquire."* This is currently the inline
  comment at `debt/mod.rs:65–73`.
- Subsequent commit `cccf354` (issue #204) further upgraded the success leg
  to AcqRel for transitivity — see Bug 4.

### Prerequisites
- [code] `Debt::pay` reachable from public API: VERIFIED — load() → fast()
  → guard → drop guard → debt.pay (`hybrid.rs:131`).
- [code] failure leg currently `Acquire` in mainline: VERIFIED — `debt/mod.rs:77`.
- [spec] arc-swap claims memory safety under concurrent load/store: VERIFIED
  by README and crate-level docs.

### Counterfactual fix check
Not applicable. The violated property (`MCNoUseAfterFree`) is local — a
specific cross-variable SC bridge between the reader's Debt::pay failure
leg and the writer's T::inc. Closing the bridge by upgrading the failure
leg to Acquire is exactly the upstream fix; there is no plausible alternative
path through which the same `addrAlive[a1] = FALSE & guard{a1, hasDebt=TRUE}`
state is reachable.

### Reproduction
- Script: `repro/test_bug1_debt_pay_failure_leg.sh`
- Test: `tests/dynamic_threads.rs::dynamic_thread_spawn` (multi-thread
  load/store/rcu/spawn pattern; 4 spawned waves of fresh reader threads).
- Command: `MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=4"
  cargo +nightly miri test --test dynamic_threads`.

**Result**: REPRODUCED. Miri reports
`error: Undefined Behavior: Data race detected between (1) non-atomic read
on thread unnamed-4 and (2) retag write of type usize on thread unnamed-3`,
with backtrace through `Arc::drop_slow → ManuallyDrop::drop →
HybridProtection::drop → Guard::drop → ArcSwapAny::rcu`. The race partner is
the reader's `**g` deref at line 37 inside the spawned reader closure.
With the fix restored (Acquire), seed=4 passes cleanly.

Full evidence: `repro/evidence/bug1_miri_output.txt`.

### Recommendation
Already fixed in mainline (PR #195 / `bd5d327`). The MC + Miri reproduction
confirms this fix is necessary and load-bearing. No code change needed.
A defensive comment is already present in source. **Any future change that
weakens this CAS leg below Acquire must be rejected.**

---

## Bug 2: Fallback storage.load downgrade leaks UAF (issue #198)

- **Source**: MC (counterexample 24 states, `MC_hunt_familyE.cfg` simulation)
- **Status**: REPRODUCED (Miri seed=39 with reverted fix; passes cleanly with fix)
- **Severity**: Critical (UAF and writer-scan miss)
- **Report Tier**: A — historical bug, already fixed upstream
- **Location**: `artifact/arc-swap/src/strategy/hybrid.rs:83`

### Description
The fallback path's `storage.load` must be SeqCst (not Acquire) so that the
load participates in the SC total order alongside the writer's swap. With
Acquire only, the reader can publish a debt slot for an address the writer
has already swapped out and freed — the writer's pay_all does not see the
slot (it scanned before the slot was published) and the reader holds a
debt for a freed pointer.

### Trigger scenario
1. Reader t1 enters fallback path; stores helping-slot for storage address.
2. Reader t1 loads `candidate = storage.load(Acquire)` — under Acquire-only,
   may observe a stale storage value.
3. Writer t2 swapped storage and finished pay_all; old Arc freed.
4. Reader t1 takes the freed pointer as the candidate, calls
   `Self::new(candidate, Some(debt)).into_inner()`. T::inc on the freed Arc.

### Developer intent investigation
- Commit `d5dd00c` ("fix: upgrade fallback path storage.load from Acquire
  to SeqCst") explicitly closes #198 with this exact change. Inline comment
  at `hybrid.rs:79–82` documents *"SeqCst is needed here (not just Acquire)
  so this load participates in the single total order with the writer's
  SeqCst swap on the same variable."*
- The maintainer added an upstream regression test `tests/fallback_uaf.rs`
  whose comment reads *"Triggers UAF under miri on aarch64 (e.g. seed=39)
  when storage.load uses Acquire instead of SeqCst in the fallback path."*

### Prerequisites
- [code] Fallback path reachable from public API: VERIFIED — load() →
  fallback() in `hybrid.rs:214`.
- [code] storage.load currently SeqCst: VERIFIED — `hybrid.rs:83`.
- [spec] same as Bug 1: VERIFIED.

### Counterfactual fix check
Not applicable (local fix; same shape as Bug 1).

### Reproduction
- Script: `repro/test_bug2_fallback_load.sh`
- Test: `tests/fallback_uaf.rs` (upstream regression test; uses
  FillFastSlots strategy to force every load through the fallback path).
- Command: `MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=39"
  cargo +nightly miri test --features internal-test-strategies --test fallback_uaf`.

**Result**: REPRODUCED. Miri reports
`error: Undefined Behavior: Data race detected between (1) retag write on
thread unnamed-4 and (2) retag read of type alloc::sync::ArcInner<usize>
on thread unnamed-2`. Backtrace: `T::inc → into_inner → fallback`. Race
partner is the writer's drop of the same Arc. With the fix restored, the
test passes cleanly.

Full evidence: `repro/evidence/bug2_miri_output.txt`.

### Recommendation
Already fixed in mainline (`d5dd00c`). The MC + Miri reproduction confirms
the SeqCst label is load-bearing.

---

## Bug 3: Fast confirm-load downgrade leaks UAF (issue #76)

- **Source**: MC (`MC_hunt_familyA.cfg` simulation, multiple instances)
- **Status**: REPRODUCED (Miri at every seed tried with reverted fix;
  passes cleanly with fix)
- **Severity**: Critical (UAF)
- **Report Tier**: A — historical bug, already fixed upstream
- **Location**: `artifact/arc-swap/src/strategy/hybrid.rs:52`

### Description
The fast-path's confirm-load must be SeqCst so that the readers participating
in the fast path collectively see the writer's swap-to-storage in the SC
total order. With Acquire only, the reader can take the success branch
(`ptr == confirm`) on a stale `confirm` value — the writer has already
swapped storage but the relaxed load returns the pre-swap pointer.

### Trigger scenario
1. Reader t1 starts fast-path. `ptr = storage.load(Relaxed)` returns a1.
2. t1 stores a1 as a debt in its fast slot.
3. t1 reloads `confirm = storage.load(Acquire)`. Under Acquire-only, can
   still observe a1 even after writer has swapped to a2.
4. t1 takes Guard{a1} via the success branch; the writer's pay_all does
   not see this Guard's slot acquisition (broken SC bridge).
5. Writer drops a1. Reader deref's a1 → UAF.

### Developer intent investigation
- Issue #76 (Miri UAF, RalfJung input, fixed pre-`6b644ff`).
- Inline comment at `hybrid.rs:49–51`: *"Acquire to get the data. // SeqCst
  to make sure the storage vs. the debt are well ordered."*

### Prerequisites
- [code] Fast path reachable from public API: VERIFIED — load() → attempt()
  in `hybrid.rs:210`.
- [code] confirm-load currently SeqCst: VERIFIED — `hybrid.rs:52`.

### Counterfactual fix check
Not applicable (local fix).

### Reproduction
- Script: `repro/test_bug3_fast_confirm_load.sh`
- Test: `tests/uaf_stress.rs::mixed_load_store_rcu`.
- Command: `MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=39"
  cargo +nightly miri test --test uaf_stress`.

**Result**: REPRODUCED. Miri reports `error: Undefined Behavior: Data race
detected between (1) non-atomic read on thread unnamed-8 and (2) retag write
of type usize on thread unnamed-11`. Race partner is the reader's `**g` deref
inside the load() arm. The bug fires at every seed I tried (1, 5, 13, 21,
39, 50, 71, 100, 150, 200) — far more reliably than Bug 1 or Bug 5,
because the fast path is exercised on every successful load() call.

Full evidence: `repro/evidence/bug3_miri_output.txt`.

### Recommendation
Already fixed in mainline. **The fast-path confirm-load must remain SeqCst.**

---

## Bug 4: Debt::pay success-leg downgrade (issue #204)

- **Source**: MC (`MC_hunt_familyA.cfg` simulation, 6+ instances)
- **Status**: REPRODUCTION FAILED (under x86_64 Miri); bug is still believed
  real per upstream record.
- **Severity**: High
- **Report Tier**: A — historical bug, already fixed upstream
- **Location**: `artifact/arc-swap/src/debt/mod.rs:77`

### Description
The success leg of `Debt::pay` is currently `AcqRel`; pre-`cccf354` it was
`Release`. The bug is about transitivity between the success and failure
legs of the CAS — both legs participate in the cross-variable SC total order
with the writer's pay_all, and neither alone is sufficient.

### Trigger scenario
- Reader t1 has Guard{a1, hasDebt=TRUE}; drops it. CAS success leg fires
  (slot was a1, becomes NONE).
- With Release-only on the success leg, the reader has released its writes
  but has *not* acquired writer-side state. A different writer-reader pair
  may then observe inconsistent ordering — the spec frames this as either
  a UAF or a `MCPayAllCompleteness` violation.

### Developer intent investigation
- Issue #204 + commit `cccf354` ("Upgrade the other ordering too, for
  transitivity"). Comment in `debt/mod.rs:75–76`: *"Upgraded to AcqRel for
  transitivity."* The maintainer's own framing — transitivity — explicitly
  acknowledges the SC chain spans both legs.
- Issue #200 contains the formal C++ memory model proof of the UAF.

### Prerequisites
- [code] Path reachable: VERIFIED.
- [code] success leg currently AcqRel: VERIFIED — `debt/mod.rs:77`.

### Counterfactual fix check
Not applicable (local fix to one ordering label; the violated property is
the same `MCNoUseAfterFree` as Bug 1).

### Reproduction
- Script: `repro/test_bug4_debt_pay_success_leg.sh`
- Test: `tests/dynamic_threads.rs`
- Command: `MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-many-seeds=0..32"
  cargo +nightly miri test --test dynamic_threads`.

**Result**: REPRODUCTION FAILED. Across all 32 seeds tried, Miri did NOT
report a data race. This is consistent with the upstream record: #204 was
identified through the formal C++ memory model proof in #200, *not* through
a Miri run. Miri's TSO-leaning weak-memory emulation on x86_64 is too strong
to expose the lost transitivity edge between the two CAS legs — on x86 even
`Release` CAS success has near-equivalent visibility to `AcqRel`.

This is the only one of the five MC findings whose Miri reproduction did not
fire. We **do not** classify this as a false positive: the upstream fix is
still correct (and load-bearing on weakly-ordered architectures), and the MC
counterexample is consistent with that fix. The Miri reproduction limit is
documented honestly rather than working around with state injection.

Full evidence: `repro/evidence/bug4_miri_output.txt`.

### Recommendation
Already fixed in mainline (`cccf354`). The MC counterexample, the upstream
PR description, and the formal proof in #200 together justify the fix. **The
success leg must remain at AcqRel** to maintain SC transitivity for ARM,
RISC-V, and any future weakly-ordered targets.

---

## Bug 5: LIST_HEAD load downgrade — stale snapshot in writer scan (issue #164)

- **Source**: MC (counterexample 18 states; 31 instances under simulation)
- **Status**: REPRODUCED (Miri at most seeds with reverted fix; passes
  cleanly with fix)
- **Severity**: High (the "stale snapshot in writer scan" pattern the brief
  specifically called out)
- **Report Tier**: A — historical bug, already fixed upstream
- **Location**: `artifact/arc-swap/src/debt/list.rs:102` (also `:185`)

### Description
The writer's `Node::traverse` (called from `Debt::pay_all`) loads the head
of the per-thread debt-node linked list. Per `d849a2d`, this load must be
SeqCst so that the writer sees nodes prepended to the list before its own
storage swap. With Acquire, the writer can miss a fresh node whose slot was
written before the writer's swap but whose link into the list head was not
yet visible; that node then holds a debt for an address the writer is about
to free.

### Trigger scenario
1. Reader t1 (newly spawned thread) calls `Node::get` to allocate a fresh
   node, prepends it to LIST_HEAD with SeqCst CAS.
2. t1 stores a debt for address a1 in its slot (post-swap of LIST_HEAD).
3. Writer t2 swaps storage a1 → a2, calls `pay_all`.
4. Writer t2 calls `Node::traverse`, doing `LIST_HEAD.load(Acquire)`. Under
   Acquire-only, may observe a list head that *predates* t1's prepend — t1's
   node is invisible.
5. Writer t2 finishes pay_all without paying t1's slot. `addrAlive[a1] = FALSE`.
6. t1's slot still holds a1 (now freed) → `MCPayAllCompleteness` violation,
   followed by UAF on subsequent deref.

### Developer intent investigation
- Commit `d849a2d` ("Use SeqCst in debt-lists") suspected to be the #164 fix.
- Inline comment at `debt/list.rs:94–101` is now: *"Furthermore, we need to
  see the newest version of the list in case we examine the debts — if a new
  one is added recently, we don't want a stale read -> SeqCst."*

### Prerequisites
- [code] Reachable from public API: VERIFIED.
- [code] currently SeqCst at both load (line 102) and store (line 185, 188):
  VERIFIED.

### Counterfactual fix check
Not applicable (local fix).

### Reproduction
- Script: `repro/test_bug5_list_head_load.sh`
- Test: `tests/dynamic_threads.rs::dynamic_thread_spawn` — designed to spawn
  reader threads in waves so fresh nodes get prepended mid-pay_all.
- Command: `MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-seed=1"
  cargo +nightly miri test --test dynamic_threads`.

**Result**: REPRODUCED. Miri reports `error: Undefined Behavior: Data race
detected between (1) non-atomic read on thread unnamed-3 and (2) retag write
of type usize on thread unnamed-2`. Race partner is the rcu reader's `**old`
deref vs the writer's `Arc::drop_slow` from `shared.store(...)`. Reproduces
at most of the seeds I tried (1, 5, 13, 21, 50, 100, 500, 1000, 2000, 5000;
seeds 39 and 200 happened to dodge it, which is also consistent with a
weak-memory race window not covered by every Miri schedule).

Full evidence: `repro/evidence/bug5_miri_output.txt`.

### Recommendation
Already fixed in mainline (`d849a2d`). The MC + Miri reproduction confirms
the SeqCst on LIST_HEAD load is load-bearing for `pay_all` completeness. **The
list-head load and CAS must remain SeqCst.** This validates the
`concurrent-analysis.md §5.5` "stale-snapshot in writer scan" modeling
approach — it is exactly the pattern the brief identified.

---

## What was tested but produced no violations (recap from bug-report.md)

The MC also explored bug families B, C, and D (allocator-reuse ABA;
adversarial caller including `Send`/`IntoInner`/CAS-RawStale/DropArcSwap;
generation wraparound + cooldown). None produced violations under the SC
labels of the current code:

- **Family B**: 38.4M states / 8.2M distinct, full state space — no UAF or
  torn-guard violation. The fast-path's `T::from_ptr(confirm)` (rather than
  `T::from_ptr(ptr)`) and the SC bridge together close the allocator-reuse
  ABA window addressed by `63fa111`.
- **Family C**: 1.4B states generated, 227M distinct, BFS depth 47. With
  `Send`/`IntoInner`/CAS-RawStale/DropArcSwap all enabled and 2 guards per
  thread, no `NoUseAfterFree`/`RefCountNonNeg`/`NoTornGuardState`/
  `CASIntendedSemantics` violation was found. The brief's hypothesis that
  the adversarial-caller × Family A combination would replicate the
  `left-right` BUG-A bugs does *not* apply: the bugs in arc-swap that exist
  on the Family A axis manifest already without caller adversariness, and
  the caller adversary alone cannot break the protocol on the SC labels.
- **Family D**: 38.4M states / 8.2M distinct, full state space — no
  concurrent-claim or stale-help-across-wrap violation. The cooldown
  protocol (release/acquire chain across `start_cooldown`,
  `NodeReservation::drop`, `check_cooldown`) is sound under MaxHelpGen=4.

These negative results are consistent with the modeling brief's assessment
that "every confirmed bug in modern history is in family A" and validate the
current SC labels' completeness with respect to the modeled bug families.

---

## Code-Review-Only and Pending findings (recap from modeling-brief.md §6.3)

The modeling brief identified five code-review-only / documentation-quality
items (CR1–CR5). None are protocol bugs in the current code; they are
documentation gaps. They are out of scope for this confirmation report.

The Test-Verifiable items (TV1–TV4) describe stress-test gaps that do not
correspond to bugs the MC found. They are out of scope.

---

## Conclusion

The model-checking effort confirmed five **historical** bugs, all already
fixed in mainline arc-swap. The cross-variable SC bridge ("Family A") is
the right model abstraction for arc-swap memory-safety: every confirmed bug
in eight years of arc-swap history sits on this axis, and every fix the
maintainer has merged closes a single SC-label downgrade exactly as the
adversarial relaxation in the spec does.

The Miri reproduction confirms the bugs are real for 4 of the 5 sites; the
fifth (Bug 4 / #204) is real per upstream's formal C++ MM proof but does
not surface under x86_64 Miri's weak-memory emulation. We document this
limitation explicitly rather than relax the standard.

**No new bugs are reported** to the upstream maintainer because all five
findings are already addressed in mainline. The submission to maintainers
would be a *validation report* — the SC labels at the cited five sites are
load-bearing and must not be downgraded.
