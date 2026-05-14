# Confirmed Bug Report — arc-swap_4

## Summary
- Total findings reviewed: 7
  - 1 from MC bug-report (Bug 1: Family 5 — generation-wrap panic)
  - 1 from MC bug-report classified upfront as "Case A — invariant too strong" (Bug 2: Family 4 — CooldownDrainSafety)
  - 5 from MC bug-report sensitivity hunts (F1/F3 relaxation counter-factuals; all known-historical / already fixed in mainline)
- Reproduced (new bugs): 1 (Bug 1)
- Confirmed without reproduction (known-historical, upstream-accepted): 5 (sensitivity findings)
- False positives / spec-too-strict: 1 (Bug 2)
- Inconclusive: 0

The new-bug count is 1 (Family 5 generation-wrap panic).  The reproduction in
`repro/test_bug1_arc_swap.patch` + `repro/test_bug1_run.sh` triggers the panic
deterministically with one `cargo test` invocation.

---

## Bug 1: Family 5 — Generation Wrap Panic in `LocalNode::confirm_helping`

- **Source**: MC (counterexample `output/MC_family5_bfs.out`, 28 states, BFS, 6 s)
- **Status**: REPRODUCED
- **Severity**: Medium — panic surface; practically unreachable on 64-bit, reachable on 32-bit after `2^30` fallback calls (≈1 billion)
- **Location**:
  - `src/debt/list.rs:288-298` — `LocalNode::new_helping`
  - `src/debt/helping.rs:191-217` — `Slots::get_debt`
  - `src/debt/list.rs:308-320` — `LocalNode::confirm_helping`
  - `src/strategy/hybrid.rs:75-111` — `HybridProtection::fallback` (call site)
- **Description**:
  When `helping::Slots::get_debt`'s per-thread generation counter wraps to 0
  (`local.generation.wrapping_add(4) == 0`), `discard` is set to `true`.
  `LocalNode::new_helping` then calls `node.start_cooldown()` and
  `self.node.take()`, leaving `self.node = None`.  The caller in
  `HybridProtection::fallback` (`hybrid.rs:88`) immediately invokes
  `node.confirm_helping(gen, candidate)`, whose first line is
  `let node = &self.node.get().expect("LocalNode::with ensures it is set");`
  — which now panics because the cell was just emptied by `take()`.

  Secondary consequence: the helping slot's `control` was set to `gen | GEN_TAG = 2`
  before the panic, and is never reset to `IDLE`.  Any subsequent thread that
  claims this Node will hit `debug_assert_eq!(IDLE, prev, "Left control in
  wrong state")` on its first `get_debt` call — the Node is **poisoned**.
  We observed this cascade directly in the test runner when running parallel
  tests.

- **Prerequisites**:
  - [code] `LocalNode::with` is reachable from the public `ArcSwap::load`
    path: VERIFIED — `ArcSwapAny::load` → `HybridStrategy::load` →
    `LocalNode::with` (`src/strategy/hybrid.rs:207-216`, `src/lib.rs:466-469`).
  - [code] Fallback path can be hit in steady state: VERIFIED — fallback
    fires whenever the 8 fast slots on a thread are full
    (`src/strategy/hybrid.rs:209-214`) or when fast confirm fails.
  - [code] Generation counter is only updated through `wrapping_add(4)` in
    one place: VERIFIED — `src/debt/helping.rs:202` is the unique writer of
    `Local::generation`.
  - [code] No `is_some()` / `is_none()` guard on `confirm_helping`'s
    `self.node.get()`: VERIFIED — `src/debt/list.rs:313` calls `.expect(...)`
    unconditionally.
  - [spec] N/A — this is a code-level invariant violation in `expect`, not a
    protocol-semantic claim.

- **Counterfactual fix check**: Not applicable — the violated property is
  *local* (a specific function panics on a specific input state), not
  system-wide.  Per `phases/02-counterfactual-check.md` this phase is for
  system-wide properties; we skip it.

- **Report Tier**: **B**.  Hard-to-recover panic on legitimate input is a
  real defect, but reachability is bounded:  on 64-bit, requires `2^62`
  fallback calls per thread (effectively unreachable in practice).  On 32-bit,
  reachable after ~1 billion fallback calls — long-running stress, not
  routine.  No data corruption, no UAF.  Maintainer triage (per
  `bug-report.md` §"Recommendation") is consistent with treating this as a
  hardening defect rather than hot-path.

- **Trigger scenario** (production):
  1. A long-lived 32-bit reader thread loads from an ArcSwap repeatedly,
     and the fast slots are saturated each time so each load goes to the
     fallback path.
  2. After ≈ 2^30 calls the per-thread `Local::generation` cell, advanced
     by 4 each iteration, wraps to 0.
  3. `Slots::get_debt` returns `(gen=0|GEN_TAG, discard=true)`.
  4. `LocalNode::new_helping` calls `node.start_cooldown(); self.node.take();`
     — the LocalNode's slot for the current Node is now `None`.
  5. `HybridProtection::fallback` (`src/strategy/hybrid.rs:88`) then calls
     `node.confirm_helping(gen, candidate)`, which begins with
     `let node = &self.node.get().expect("LocalNode::with ensures it is set");`
     — panic, with the literal message `"LocalNode::with ensures it is set"`.

- **Trigger scenario** (test): we reach the same state by seeding
  `Local::generation` to `usize::MAX & !3` (= `usize::MAX - 3`) via a
  `#[cfg(test)]` accessor, so `wrapping_add(4)` overflows on the first call
  to `new_helping`.  The remainder of the path is unmodified.

- **Developer intent investigation**:
  - **Comment trail in `helping.rs:54-71`** explicitly documents the ABA
    risk and the cooldown mitigation: *"every time the counter overflows we
    take the current node and un-assign it from our current thread.  We mark
    it as in 'cooldown' and let it in there until there are no writers messing
    with that node any more."*  The intent is clearly that the cooldown
    mechanism *defers reuse* of the Node, but says nothing about the
    half-completed transaction on the dead Node.
  - **Commit `08efd1f` ("Hybrid debt reservation: split the check")** —
    this is the specific commit that split the previously-atomic acquire
    into two steps (`new_helping` and `confirm_helping`) for performance.
    The commit message reads *"We are allowed to do it in two operations and
    it's faster that way."*  The split was performance-motivated and the
    interaction with the discard branch was not considered.
  - **No issue or PR found** that mentions the panic-on-wrap.  Existing
    tests (`tests/dynamic_threads.rs`, `tests/uaf_stress.rs`,
    `tests/random.rs`) do not exercise generation wrap; the practical
    counts they hit are far below 2^30.
  - **Verdict**: this is a real bug.  The developer's documented intent
    (defer Node reuse on wrap; the rest of the protocol must be
    invariant-preserving) is violated by the `take()` + immediate
    `expect()` pair.

- **Reproduction test**: `repro/test_bug1_arc_swap.patch` + `repro/test_bug1_run.sh`.
  - `test_bug1_arc_swap.patch` adds two `#[cfg(test)]` hooks to arc-swap:
    - `helping::Local::seed_generation_for_test` — pre-load the per-thread
      generation counter to a chosen value.  Justified as Level-2 state
      injection per the bug-confirmation skill: the counter is private and
      the natural path to wrap is impractical.
    - `helping::Slots::reset_for_test` — clean up after the panic so the
      test is hermetic.  Used only in the test.
  - The new unit test `confirm_helping_panic_after_generation_wrap` in
    `src/debt/list.rs::tests` seeds the generation, drives `new_helping`
    and `confirm_helping`, captures the panic via `catch_unwind`, and
    asserts the panic message matches the literal `expect(...)` string.
  - All other state — node allocation, cooldown lifecycle, helping-slot
    control swap — runs unmodified through the public `LocalNode` API.
  - `test_bug1_run.sh` runs the test with `cargo test --lib
    confirm_helping_panic_after_generation_wrap -- --nocapture
    --test-threads=1` and grep-verifies the expected panic line.

- **Reproduction result**: PASS (bug triggered).
  Captured output (excerpt from `repro/test_bug1_run_output.txt`):
  ```
  thread 'debt::list::tests::confirm_helping_panic_after_generation_wrap' (3124419) panicked at src/debt/list.rs:313:37:
  LocalNode::with ensures it is set
  note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
  CAPTURED PANIC MESSAGE: LocalNode::with ensures it is set
  test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 36 filtered out; finished in 0.00s
  >>> REPRODUCED: panic at src/debt/list.rs:313 with the documented message.
  ```
  Panic file/line `src/debt/list.rs:313:37` is the `expect(...)` at the top
  of `confirm_helping`, exactly as predicted by the modeling brief and the
  MC counterexample.

- **Recommendation** (matches MC bug-report §Bug 1):
  Either:
  1. Defer `self.node.take()` until *after* `confirm_helping` returns
     (preferred — keeps the slot's `control` reachable for
     `confirm_helping`'s SeqCst swap → IDLE).
  2. Add an early-return path in `LocalNode::confirm_helping` that returns
     an `Err` (caller-side cleanup, returning the candidate's debt) when
     `self.node.is_none()`, instead of panicking.
  Either fix should also reset the helping slot's `control` to `IDLE`
  before the take, to defuse the cascading-panic on subsequent claims.
  Triggering requires `2^62` fallback calls per thread on 64-bit
  (effectively unreachable) or `2^30` on 32-bit (reachable in long-lived
  stress).

---

## Bug 2: Family 4 — CooldownDrainSafety (Steady-State Form) Violated Under SC

- **Source**: MC (counterexample `output/MC_family4_bfs.out`, 33 states, BFS, 6 s)
- **Status**: FALSE POSITIVE (Case A — invariant too strong; no actual unsafety exhibited)
- **Severity**: Low–Medium (precondition for documented ABA only; downstream unsafety not witnessed under SC + 2 threads)
- **Location**:
  - `src/debt/list.rs:93-112` — `Node::traverse` walks all nodes including
    UNUSED.
  - `src/debt/list.rs:148-152` — `reserve_writer` has no `nodeState != UNUSED`
    guard.
  - `src/debt/list.rs:115-145` — cooldown lifecycle (`start_cooldown` /
    `check_cooldown`).

- **Description**:
  The MC spec's `CooldownDrainSafety` invariant in *steady-state* form
  reads: *"a node in `UNUSED` state has `inflightHelp = ∅`."*  The
  counterexample shows that after `CheckCooldown(t1)` transitions a node
  COOLDOWN→UNUSED, a *concurrent* `WriterReserveNode(t2)` can then reserve
  that node (incrementing `active_writers`) — putting an "inflight help"
  context on a UNUSED node.  The invariant is violated.

  The bug-report itself (per §Bug 2 — "Classification") classifies this
  as **Case A (invariant too strong)**: the implementation deliberately
  allows writers to reserve UNUSED nodes during `pay_all`.  The actual
  ABA unsafety the cooldown mechanism is designed to prevent requires
  ≥3 threads + at least one ordering relaxation (Family 1) — neither of
  which is enabled in `MC_hunt_family4.cfg` (`Threads = {t1, t2}`,
  `MaxOrderingGaps = 0`).

- **Prerequisites**:
  - [code] `Node::traverse` walks all nodes regardless of `in_use` state:
    VERIFIED — `src/debt/list.rs:93-112`, no `if node.in_use != UNUSED` filter.
  - [code] `reserve_writer` is unconditional: VERIFIED —
    `src/debt/list.rs:148-152`, just `active_writers.fetch_add(1, Acquire)`.
  - [spec] The cooldown mechanism is supposed to prevent writer reservation
    on UNUSED nodes that have an inflight help context: NOT VERIFIED —
    bug-report §Classification states the implementation *deliberately
    allows* this; safety relies on the slot-pay CAS at `debt/mod.rs:109`
    matching exactly on `wOldAddr` and the help CAS at `helping.rs:235-238`
    matching exactly on `(gen, GEN_TAG)`, both of which hold under SC.

- **Counterfactual fix check** (system-wide property, applicable):
  - Applied edit: this would be "add a `nodeState != UNUSED` guard to
    `reserve_writer` and `WriterReserveNode`."
  - MC config re-run: not necessary.  The bug-report itself documents that
    the *actual* ABA exhibitor (`MC4`) needs `Threads = {t1, t2, t3}` and a
    Family-1 relaxation to manifest a downstream `NoUseAfterFree` violation.
    Under the model's BFS at `MaxOrderingGaps = 0` and 2 threads, the
    invariant fires at the precondition state but no downstream UAF/safety
    counterexample is reachable.
  - Result: **PROPERTY HOLDS at the safety level** (no UAF / wrong-pay
    observed), even though the steady-state form of `CooldownDrainSafety` is
    violated.
  - Conclusion: **reframed as spec hygiene**.  The invariant should be
    transitional ("at the *moment* of COOLDOWN→UNUSED, `inflightHelp = ∅`"),
    not steady-state.  The implementation's safety argument is sound under SC.

- **Report Tier**: **C** (record only; not submitted by default).  Spec
  bug, not implementation bug.  No externally observable consequence in the
  modeled state space.

- **Trigger scenario**: Per the BFS counterexample, t1 enters helping path,
  helpGen wraps, ReaderFallbackControlSwap triggers wrap-discard,
  ReaderFallbackDiscardNode sets nodeState=COOLDOWN, CheckCooldown(t1)
  transitions COOLDOWN→UNUSED, then WriterReserveNode(t2) reserves the
  UNUSED node — invariant fires.  No data anomaly downstream (verified by
  the absence of any `NoUseAfterFree` / `RefCountAccounting` violation in
  `output/MC_family4_bfs.out`).

- **Developer intent investigation**:
  - **Comment in `helping.rs:54-71`**: documents the ABA risk and the
    cooldown mitigation explicitly.  The cooldown defers *claim* (UNUSED→USED
    via the CAS in `Node::get`), not *writer reservation*.  This is the
    intended design.
  - **Comments at `list.rs:25-27`**: *"We also do release-acquire 'send'
    from the start-cooldown to check-cooldown to make sure we see at least
    as up to date value of the writers as when the cooldown started."*  The
    cooldown's contract is described in terms of "claim acquired by another
    reader," not "writer reservation."
  - **Verdict**: developer intent is consistent with allowing writer
    reservation on UNUSED nodes; the safety argument lives in the slot-pay
    and help CAS exact-match checks.  This is not a bug.

- **Reproduction test**: not applicable — false positive at the spec level.
  No reproduction file for this finding.

- **Reproduction result**: N/A.

- **Recommendation**: change the spec's `CooldownDrainSafety` invariant
  from steady-state to transition form ("when a node transitions
  COOLDOWN→UNUSED, `inflightHelp(n) = ∅`"), or expand the model to 3
  threads + Family-1 relaxation to expose the downstream ABA the brief is
  actually trying to detect.  No implementation change recommended.

---

## Sensitivity Findings (Case A — counter-factual to past upstream fixes)

Each finding is a **counter-factual relaxation** of an SC site that is
*currently* SeqCst in mainline as a result of an accepted upstream fix.  The
spec exhibits the relaxation's documented bug under the relaxation
configuration, confirming the spec is faithful enough to expose pre-fix
bugs.  None are new bugs.  All five are KNOWN-HISTORICAL and exempt from
reproduction per the bug-confirmation guide.

### Bug 3: F1 — DebtPayFailure Relaxation → UAF

- **Source**: MC (sensitivity hunt under `MCPickRelaxSite("DebtPayFailure")`)
- **Status**: KNOWN-HISTORICAL (already fixed)
- **Severity**: High (UAF) — but only under the counter-factual relaxation
- **Location**: `src/debt/mod.rs:65-78` (`Debt::pay`)
- **Description**: with `Debt::pay`'s failure ordering downgraded to
  Relaxed, the spurious-failure leg creates a `Guard` with `hasDebt=FALSE`
  while the writer's `T::inc` is not yet visible to the reader, leading to
  a decrement of an unincremented refcount → UAF.
- **Prerequisites**: Spec citation — this is precisely the bug fixed by
  upstream PR #195 / commit `bd5d327` ("Fix Debt::pay failure ordering",
  Relaxed → Acquire), later strengthened by PR #204 / `cccf354`
  (Acquire → AcqRel for transitivity).
- **Counterfactual fix check**: not applicable — already fixed; the MC
  result is the counter-factual *of* the fix.
- **Report Tier**: C (already-fixed historical bug; included as evidence of
  spec faithfulness, not as a new finding).
- **Reproduction**: existing arc-swap regression test
  `tests/uaf_stress.rs` plus historical commit messages serve as the
  upstream evidence.  No new reproduction needed.
- **Recommendation**: none — the fix is already in mainline.

### Bug 4: F1 / F3 — FallbackLoad Relaxation → UAF / StaleSnapshot / PayAllCompleteness

- **Source**: MC (sensitivity hunt under `MCPickRelaxSite("FallbackLoad")`)
- **Status**: KNOWN-HISTORICAL (already fixed)
- **Severity**: High (UAF) — but only under the counter-factual relaxation
- **Location**: `src/strategy/hybrid.rs:83` (`storage.load(SeqCst)` in
  fallback path)
- **Description**: with the fallback path's storage load downgraded to
  Acquire, the reader's fallback `candidate` load can return an
  already-freed pointer; the slot-store publishes a debt on the freed
  pointer, the next writer can't see this debt, frees the still-alive
  stale pointer → UAF.
- **Prerequisites**: Spec citation — this is exactly the bug fixed by
  upstream PR #203 / commit `d5dd00c` ("fix: upgrade fallback path
  storage.load from Acquire to SeqCst"); related issues #198 and #200.
  Regression test: `tests/fallback_uaf.rs`.
- **Counterfactual fix check**: not applicable.
- **Report Tier**: C.
- **Reproduction**: `tests/fallback_uaf.rs` + commit `d5dd00c`.
- **Recommendation**: none — fix already in mainline.

### Bug 5: F1 / F3 — ListHeadLoad Relaxation → PayAllCompleteness

- **Source**: MC (sensitivity hunt under `MCPickRelaxSite("ListHeadLoad")`)
- **Status**: KNOWN-HISTORICAL (already fixed)
- **Severity**: High — but only under the counter-factual relaxation
- **Location**: `src/debt/list.rs:178-202` (`Node::get` prepend CAS)
- **Description**: with the list-head load downgraded, the writer's
  `LIST_HEAD.load` may miss recently-prepended nodes; their slots hold
  debts on `wOldAddr` and the writer never pays them.
- **Prerequisites**: Spec citation — fixed by upstream commit `d849a2d`
  (issue #164, "Use SeqCst in debt-lists" — debt-list CAS upgraded to
  SeqCst-on-failure to mitigate a suspected crash).
- **Counterfactual fix check**: not applicable.
- **Report Tier**: C.
- **Reproduction**: commit `d849a2d` + the issue.
- **Recommendation**: none — fix already in mainline.

### Bug 6: F1 — DebtPaySuccess Relaxation → wrong-pay

- **Source**: MC (sensitivity hunt under `MCPickRelaxSite("DebtPaySuccess")`)
- **Status**: KNOWN-HISTORICAL (already fixed)
- **Severity**: High — but only under the counter-factual relaxation
- **Location**: `src/debt/mod.rs:65-78` (`Debt::pay`'s success ordering)
- **Description**: writer's pay-CAS spuriously fails to see a debt the
  reader published with full SC.  Recreates the bug fixed by PR #204 / commit
  `cccf354` (success ordering Release → AcqRel for transitivity).
- **Prerequisites**: spec citation — upstream PR #204 / `cccf354`.
- **Counterfactual fix check**: not applicable.
- **Report Tier**: C.
- **Reproduction**: PR #204.
- **Recommendation**: none — fix already in mainline.

### Bug 7: F1 — FastConfirmLoad Relaxation → stale-pointer past confirm

- **Source**: MC (sensitivity hunt under `MCPickRelaxSite("FastConfirmLoad")`)
- **Status**: KNOWN-HISTORICAL (already fixed)
- **Severity**: High — but only under the counter-factual relaxation
- **Location**: `src/strategy/hybrid.rs:52` (fast `attempt`'s confirm load)
- **Description**: under a stale fast confirm load, the reader can carry an
  already-freed pointer past the confirm.  Counter-factual to issue #76 and
  related work in #186 / commit `63fa111` ("Fix fast load when allocation
  is reused").
- **Prerequisites**: spec citation — issue #76 + commit `63fa111`.
- **Counterfactual fix check**: not applicable.
- **Report Tier**: C.
- **Reproduction**: existing tests + the historical commits.
- **Recommendation**: none — fix already in mainline.

---

## Investigation Notes

### Coverage gaps that produced *no* counterexample

Per `bug-report.md` §"Not Reproduced", the following high-priority hunts
ran with substantial state-space coverage and found no SC-only violation:

| Family | Config | Coverage | Result |
|--------|--------|----------|--------|
| F2 — Caller misuse | `MC_hunt_family2.cfg` BFS | 1.34B states, 198M distinct, depth 44, 30 min | No violation |
| F2 — Caller misuse | `MC_hunt_family2.cfg` simulation | 489M states / 1.84M traces, ~10 min | No violation |
| F3 — Stale snapshot under SC | `MC_hunt_family3.cfg` BFS | 27,803 states, depth 15 | No SC-only violation; all 80,430 sim violations require a relaxation |

For our purposes, this means:
- **Family 2 (adversarial caller, the prompt's primary coverage gap)** is
  empirically *not* exhibiting a bug under the modeled adversaries
  (`MCSpawn`, `MCMoveGuard`, `MCDelayDrop`, `MCInterleavingDrop`).
- **Family 3 (stale snapshot, the BUG-A shape from left-right)** is *not*
  exhibiting a bug under SC; all violations require a relaxation.

These results are not bugs.  No reproduction is needed.

### Why we did not write reproductions for the sensitivity findings

Per the bug-confirmation guide, *known/historical bugs* (matching an
existing JIRA, CVE, upstream issue, or already-accepted maintainer fix) are
exempt from new reproduction.  All five sensitivity findings (F1
DebtPayFailure, F1/F3 FallbackLoad, F1/F3 ListHeadLoad, F1 DebtPaySuccess,
F1 FastConfirmLoad) are counter-factuals to upstream-accepted PRs that have
already shipped — `bd5d327` (#195), `cccf354` (#204), `d5dd00c` (#198/#200/PR
#203), `d849a2d` (#164), `63fa111` (#186).  Existing regression tests
(`tests/fallback_uaf.rs`, `tests/uaf_stress.rs`, etc.) cover them.  We cite
the upstream commits rather than writing redundant reproductions.

### Why we did not run the counterfactual check on Bug 1

The `CounterfactualFixCheck` phase applies only to *system-wide* properties
(availability, exhaustion, eventual consistency, etc.).  Bug 1's violation
is local: a specific function panics on a specific input state.  There is
no broader bad-outcome class to search alternative paths to — the bug *is*
the missing `is_some()` guard at one specific code site.  Per
`phases/02-counterfactual-check.md` §"When NOT to apply", we skip this
phase.

---

## Files in `repro/`

- `test_bug1_arc_swap.patch` — the patch that makes the unit test
  reproducible.  Adds two `#[cfg(test)]` hooks (gated; no production
  impact) and one unit test in `src/debt/list.rs::tests`.
- `test_bug1_run.sh` — wrapper script that runs `cargo test ...
  confirm_helping_panic_after_generation_wrap -- --nocapture
  --test-threads=1` and grep-verifies the expected panic.
- `test_bug1_run_output.txt` — captured output from the wrapper, including
  the panic line `panicked at src/debt/list.rs:313:37: LocalNode::with
  ensures it is set` and the test-runner's `test result: ok. 1 passed`.

The patch is *already applied* to the round-4 working tree at
`/home/ubuntu/Specula/case-studies/arc-swap_4/artifact/arc-swap`, so the
script can be run directly.
