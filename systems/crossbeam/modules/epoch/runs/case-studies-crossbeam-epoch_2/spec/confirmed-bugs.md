# Confirmed Bug Report — crossbeam-epoch_2

## Summary

- Total findings reviewed: 11 (6 MC bug-family hunts + 5 code-review notes)
- Reproduced: 0
- Confirmed (code audit, reproduction failed): 0
- False positives / non-bugs: 11
- Inconclusive: 0
- Historical bugs re-verified as fixed: 2 (Issue #105, Issue #238)

**Bottom line**: This round found **no new bugs** in crossbeam-epoch. Model checking with adversarial-caller modeling exhausted the bounded state space across six fault families without violations. Code-review residuals are all defensive-coding or documentation suggestions that fail the Phase 0 system-level-consequence test. The two historical protocol bugs in scope remain fixed in source.

---

## Methodology and Filtering

I consolidated findings from two sources:

1. **`spec/bug-report.md`** — six MC hunt configs (F1 nested pin, F2 retire contract, F3 SC fence, F4 caller misuse, F5 stalled advance, F6 slot reuse). The report itself states "0 real implementation bugs"; the violations under F2 and F3 only fire after explicit adversary actions (`MCBuggyRetire`, `MCSkipFence`) that model hypothetical buggy implementations, not actual crossbeam-epoch code.
2. **`modeling-brief.md`** — Section 6.3 lists five "Code-Review-Only" notes (CR-1 … CR-5), explicitly classified by the brief itself as code-review suggestions, not bugs.

I applied the bug-confirmation skill's Phase 0 filter to every item. Items that fail any of the three Phase 0 filters (path ≠ bug, observable harm, developer intent) are recorded as path deviations and not pursued for reproduction. None of the items reached Phase 1 (code audit confirming a real, reachable bug).

---

## Findings 1–6: MC Bug-Family Hunts

### F1 — Reentrant pin / nested-protection epoch advance

- **Source**: MC hunt `MC_hunt_F1_nested_pin.cfg`
- **Status**: NOT A BUG (no violation)
- **MC result**: Exhaustive BFS to depth 66, 2,640,446 distinct states, 0 violations.
- **Code audit**: The `if guard_count == 0` gate in `Local::pin` at `crossbeam-epoch/src/internal.rs:560` correctly suppresses local-epoch publication and `collect()` on a nested pin. The gate is exactly the fix for historical Issue #105.
  ```rust
  // internal.rs:560
  if guard_count == 0 {
      let global_epoch = self.global().epoch.load(Ordering::Relaxed);
      ...
  }
  ```
- **Phase 0 classification**: No observable harm — the spec confirmed the gate is sound under the adversarial-caller harness (defer-that-pins, repin-after, arbitrary nesting).

### F2 — Retire-before-unlink lifetime mismatch

- **Source**: MC hunt `MC_hunt_F2_retire_contract.cfg`
- **Status**: NOT A BUG (violation only via explicit fault-injection action `MCBuggyRetire`)
- **MC result**: 16-step counterexample triggered by `MCBuggyRetire(t1, o1)`, the action that intentionally retires a still-reachable object. This action is a **bug-injection adversary**, not a model of crossbeam-epoch's real code.
- **Code audit**: `Queue::pop_internal` and `Queue::pop_if_internal` perform the tail-advance CAS *before* `defer_destroy(head)` when `head == tail`:
  ```rust
  // sync/queue.rs:131-136 (pop_internal) — same pattern at :163-168 (pop_if_internal)
  let tail = self.tail.load(Relaxed, guard);
  if head == tail {
      let _ = self.tail.compare_exchange(tail, next, Release, Relaxed, guard);
  }
  guard.defer_destroy(head);
  ```
  This is the fix from commit `2618830` (Issue #238). The retire-before-unlink contract is satisfied.
- **Phase 0 classification**: The MC violation is a "buggy variant" injection, not a real protocol bug. The invariant `RetireImpliesUnreachable` is sound; it correctly detects the fault class but the implementation does not exhibit the fault.

### F3 — Epoch-advance + bag-retire ordering across the SC fence boundary

- **Source**: MC hunt `MC_hunt_F3_sc_fence.cfg`
- **Status**: NOT A BUG (violation only via explicit fault-injection action `MCSkipFence`)
- **MC result**: 22-step counterexample triggered by `MCSkipFence("TryAdvFence")`, which removes the SeqCst fence in `try_advance`. This is again a **bug-injection adversary**.
- **Code audit**: The SC fences are present in both pairing sites. In `Local::pin` (`internal.rs:600-615`), x86 uses the cmpxchg-as-fence pattern (`compare_exchange(starting, pinned, SeqCst, SeqCst)`); other architectures use `store(Relaxed) + atomic::fence(SeqCst)`. In `Global::try_advance` (`internal.rs:239`), `atomic::fence(SeqCst)` is in place after the global-epoch load.
- **Phase 0 classification**: The violation only manifests under fence removal, which would itself be the bug. The current code is correct.

### F4 — Adversarial caller / Guard misuse

- **Source**: MC hunt `MC_hunt_F4_caller_misuse.cfg`
- **Status**: NOT A BUG (no violation)
- **MC result**: Exhaustive BFS to depth 90, 237,866,093 distinct states, 0 violations. Tested adversary actions: defer-that-pins (callback re-entry into `pin`/`defer`/`repin`), `repin_after` panic recovery, unprotected-defer immediate execution, arbitrary guard nesting and inter-thread defer execution.
- **Code audit**: Every adversarial-caller scenario explicitly listed in modeling-brief §2.4 was modeled and explored. The bookkeeping invariants (`guardCount == 0` gate, `handle_count = 1` during finalize, `is_pinned()` check on `Bag::drop`'s recursive defer) hold under all enumerated interleavings.
- **Phase 0 classification**: No observable harm. This is the round's main coverage extension over Round 1 and it cleared cleanly.

### F5 — Iterator stall in `try_advance` returning stale global

- **Source**: MC hunt `MC_hunt_F5_stalled_advance.cfg`
- **Status**: NOT A BUG (no safety violation; documented liveness gap)
- **MC result**: Exhaustive BFS to depth 88, 281,694,420 distinct states, 0 safety violations.
- **Code audit**: When `try_advance` aborts iteration with `IterError::Stalled`, it returns the cached initial `global_epoch` (`internal.rs:255`). The downstream `is_expired` cutoff is therefore stale-but-conservative — it under-reclaims rather than over-reclaims. Memory growth without bound under high `defer` traffic is acknowledged in open Issue #566. This is an explicitly acknowledged liveness/efficiency trade-off, not a safety bug.
- **Phase 0 classification**: No safety harm; liveness only. The developers documented the trade-off and accept it; the fix is to call `flush()` more aggressively at the caller side. CR-3 in the modeling brief asks for a doc-comment improvement, not a code change.

### F6 — Pointer/slot reuse for retired Local nodes

- **Source**: MC hunt `MC_hunt_F6_slot_reuse.cfg`
- **Status**: NOT A BUG (no violation)
- **MC result**: Exhaustive BFS to depth 65, 2,629,931 distinct states, 0 violations.
- **Code audit**: The intrusive list iterator in `try_advance` runs under a `Guard`, so any `Shared<Entry>` it observes is protected by the 2-epoch rule. `IsElement<Local>::finalize` (`internal.rs:583`) properly uses `guard.defer_destroy(...)`, ensuring Local destruction is deferred under a real Guard. The deletion-tag mechanism on the list combined with `objectGen` bumping prevents ABA on the entry slot.
- **Phase 0 classification**: No observable harm. The protocol's safety here was already conditional on the Family 3 SC-fence pair, which is intact.

---

## Findings 7–11: Code-Review-Only Notes (CR-1 … CR-5)

All five are listed in `modeling-brief.md` §6.3 under the explicit heading "Code-Review-Only" — meaning the brief itself classifies them as suggestions, not bugs. They all fail Phase 0 of the bug-confirmation guide.

### CR-1: `unpin` does not `debug_assert!(guard_count > 0)`

- **Source**: Code review (modeling-brief F10)
- **Status**: NOT A BUG (defensive-coding suggestion)
- **Location**: `crossbeam-epoch/src/internal.rs:662-663`
- **Phase 0**: Defensive-programming suggestion. Callers (`Guard::drop`) hold a live `Guard`, which is created only via a successful `pin()` that incremented `guard_count`. The contract is enforced by the Rust type system through the `Guard`'s lifetime; an extra `debug_assert!` would catch unsafe-internal-misuse only. **Filter 1 (path ≠ bug)**: this is robustness, not a missing safety check.

### CR-2: Pin's `relaxed-store + SeqCst-fence` pattern is not commented

- **Source**: Code review (Issue #977 cited)
- **Status**: NOT A BUG (documentation suggestion)
- **Location**: `crossbeam-epoch/src/internal.rs:580-615` already has a 30+-line block-comment explaining the pattern, including the x86 cmpxchg-as-fence trick and a compiler-fence rationale.
- **Phase 0**: **Filter 2 (no observable harm)**: there is no incorrect behavior, only a documentation request. The code itself is correct.

### CR-3: `try_advance`'s stale-return-on-Stalled consequence is undocumented

- **Source**: Code review (Issue #566 cited)
- **Status**: NOT A BUG (documentation suggestion; known liveness behavior)
- **Location**: `crossbeam-epoch/src/internal.rs:255`
- **Phase 0**: **Filter 3 (developer intent)**: the developers explicitly acknowledge memory growth under high defer traffic in Issue #566 and accept it as a documented trade-off (the user-side mitigation is `flush()`). The behavior is liveness-only; safety is preserved.

### CR-4: `Local::finalize`'s `handle_count = 1` recursion-prevention is subtle

- **Source**: Code review (modeling-brief F4)
- **Status**: NOT A BUG (documentation/defensive-coding suggestion)
- **Location**: `crossbeam-epoch/src/internal.rs:537-549`
- **Phase 0**: **Filter 1**: F4 hunt cleared 237M states without finding a counterexample where `finalize` recurses; the protection is functionally sound. The suggestion is to add an explanatory comment. **Filter 2**: no observable harm.

### CR-5: `MAX_OBJECTS = 4` under `crossbeam_sanitize` is not surfaced as a named constant

- **Source**: Code review (modeling-brief F11)
- **Status**: NOT A BUG (refactoring/style suggestion)
- **Phase 0**: **Filter 1**: this is a code-organization concern. The constant is correct; it's a `cfg`-flag-based tuning value. No correctness issue.

---

## Historical Bugs Re-Verified

Per the bug-confirmation skill, known/historical bugs (existing tickets) do not require reproduction. I confirmed both remain fixed in source:

| Bug | Where | Fix verified at |
|---|---|---|
| Issue #105 — nested-pin advance broke EBR invariant | `Local::pin` | `internal.rs:560` — `if guard_count == 0` gate suppresses inner-pin local-epoch publication and `collect()` |
| Issue #238 — `pop_internal` retired head while still reachable via tail | `Queue::pop_internal`, `Queue::pop_if_internal` | `sync/queue.rs:131-136` and `:163-168` — tail CAS before `defer_destroy(head)` (commit `2618830`) |

---

## Reproduction Status

Per the task instructions, every CONFIRMED bug requires a reproduction test. There are zero confirmed bugs in this case study, so no test files are required. The `repro/` directory contains a `NOTE.md` documenting this conclusion.

---

## Recommendation

No code changes are needed for crossbeam-epoch based on this round's findings. If the maintainers wish to act on the Code-Review-Only notes, the highest-value items would be:

1. **CR-2 / CR-3**: add explanatory comments at `internal.rs:580` (SC-fence Dekker pair) and `:255` (Stalled-return liveness trade-off). These are documentation-only and would improve readability for future contributors auditing the memory-ordering and reclamation logic.
2. **CR-1 / CR-4**: add `debug_assert!` and/or `// invariant:` comments to make the bookkeeping invariants self-checking. Optional; tests already cover the success paths.

The MC pipeline's adversarial-caller harness (Family 4) provided the round's main coverage extension over Round 1 and validated that crossbeam-epoch's bookkeeping is robust against legal-but-aggressive client sequences (defer-that-pins, repin-after panic, guard-across-yield, unprotected-defer mixing).
