# Confirmed Bug Report — left-right_2

## Summary

- Total findings reviewed: 3 (Bug 1 UAF, Bug 2 reentrant panic, Bug 3 liveness)
- Reproduced: 2 (Bug 1 via Level-3 instrumentation, Bug 2 black-box at Level 0)
- Confirmed (code audit, reproduction failed): 0
- Known/historical (cited): 1 (Bug 1 — PR #144 with TSAN evidence)
- False positives: 0
- Documented behavior (not a bug): 1 (Bug 3 — caller-misuse documented in lib.rs:142-143)

Both real implementation bugs (Bug 1 and Bug 2) were reproduced as Rust integration
tests in `repro/`. Bug 1 was already reported upstream as PR #144 with maintainer-
TSAN evidence, so it qualifies as a known/historical bug; we additionally
reproduce it locally via Level-3 instrumentation as corroborating evidence.
Bug 2 is **not yet reported upstream** — this is a new finding from Round 2
that must be brought to the maintainer's attention.

---

## Bug 1: `take_inner` stale-snapshot use-after-free

- **Source**: MC counterexample (`MC_hunt_F1_uaf.cfg`, `output/F1_uaf_bfs.out`,
  16-state trace at depth 20) + Code review + **Upstream PR #144**
- **Status**: **REPRODUCED** (Level 3) and **KNOWN-HISTORICAL** (PR #144)
- **Severity**: **Critical** (use-after-free; reader dereferences freed buffer)
- **Location**: `artifact/left-right/src/write.rs:175-180` (the NULL-swap and
  the wait that uses stale `last_epochs`); `write.rs:464-466` (the snap that
  occurs *before* the NULL-swap); `write.rs:272-274` (the skip rule that
  classifies `last_epochs[ri] % 2 == 0` as "quiesced")
- **Description**:
  `WriteHandle::take_inner` (called by `Drop` and `take`) NULLs the read
  pointer (`inner.swap(NULL, Release)` at `write.rs:175`), then calls
  `wait()` (`write.rs:180`). `wait()` uses `self.last_epochs`, which was
  populated by the prior `update_and_swap`'s per-reader Acquire load loop
  (`write.rs:464-466`) — *before* the NULL-swap. A reader who entered the
  data structure between that snapshot and the NULL-swap has odd `epoch[r]`
  but `last_epochs[r]` is even (or 0 from `last_epochs.resize` when the
  slab slot is new). The skip rule at `write.rs:272-274`
  (`if self.last_epochs[ri] % 2 == 0 { continue; }`) drops them on the
  floor; `wait` returns; both backing buffers are freed at `write.rs:190`
  (`drop_first`) and via `Taken::drop_second` (`write.rs:135`); the
  reader's guard still aliases one of those buffers — UAF.

- **Prerequisites**:
  - [code] `WriteHandle::take_inner` is reachable from `Drop` and the public
    `take` method: VERIFIED — `write.rs:218` (Drop calls `take_inner`),
    `write.rs:531-538` (take). Any code that drops a `WriteHandle` while
    other readers may still call `enter()` is exposed.
  - [code] The window between the most recent `update_and_swap` snap and
    the NULL-swap is reachable to a racing reader: VERIFIED — these are
    plain sequential statements separated by an `assert!` and an
    `Arc::clone`/`lock()` (write.rs:172-179); a context switch can land
    a reader's `enter()` between them. MC counterexample reaches this at
    depth 20 with 12 943 distinct states.
  - [code] `last_epochs[ri]` is even at snap time when reader r is idle:
    VERIFIED — readers' epochs start at 0 (read.rs:89, `AtomicUsize::new(0)`),
    and `last_epochs.resize(.., 0)` (write.rs:256) extends with 0 for new
    slots. After a reader's enter+exit cycle, their epoch is even again.
  - [spec] None applicable — this is a code-level data race, not a
    protocol question.

- **Counterfactual fix check**: applicable (system-wide property:
  "no reader ever holds a guard on a buffer that has been freed"). PR #144's
  fix has already been verified in the spec (`MC_hunt_F1_uaf_fixed.cfg`,
  diameter 78, 13 679 047 distinct states, **no violation**) — the
  counterfactual fix (refresh `last_epochs` after the NULL-swap) closes the
  bug within the modeled state space. Conclusion: original framing
  corroborated; PR #144's one-place fix is necessary and sufficient at the
  spec level.

- **Report Tier**: **A** (data corruption / use-after-free, externally
  observable, hard to recover; one of the most severe classes of concurrency
  bug).

- **Trigger scenario** (from MC counterexample at `output/F1_uaf_bfs.out`,
  steps 1-16):
  1. Init: `inner_ptr=L`, `writerCopy=R`, `last_epochs=[0,0]`, `first=TRUE`.
  2. Writer enters `take_inner`. `taken := TRUE`.
  3. Because `first=TRUE`, writer calls `publish()` internally
     (`write.rs:166-167`); the publish runs through wait + update_and_swap.
  4. Inside `update_and_swap`, the swap (`write.rs:455`) and the snap
     (`write.rs:464-466`) execute. `last_epochs[R1] := epoch[R1] = 0`.
  5. Between the snap and the NULL-swap (steps 9-12 of the MC trace),
     reader R1 runs `enter()`: bumps `epoch[R1] := 1`, loads
     `inner_ptr = R`, mints a `ReadGuard` aliasing R.
  6. Writer's NULL-swap fires: `inner_ptr := null`,
     `releasedCopy := R` (`write.rs:175`).
  7. Writer's `wait()` runs with stale `last_epochs[R1] = 0` (even); skip
     rule fires; wait returns immediately.
  8. Writer drops `w_handle` (write.rs:190) and `Taken::inner` carrying
     `releasedCopy` (write.rs:135) — *the buffer R1 still references*.
  9. R1's guard now points to freed memory: UAF.

- **Reproduction test**: `repro/test_bug1_take_inner_uaf_l3.rs`
  (also at `artifact/left-right/tests/repro_bug1_take_inner_uaf_l3.rs`).
  Level-3 escalation: a small env-var-gated `std::thread::sleep` was added
  in `write.rs` between line 172 (`assert!(self.oplog.is_empty())`) and
  line 175 (the NULL-swap), to deterministically widen the race window.
  The instrumentation is opt-in (only fires when `LR_REPRO_BUG1_SLEEP_US`
  is set in the environment) and does NOT alter the library's protocol
  logic. The test uses `Counter` with a `Drop` impl that writes a
  canary value (0x77777777) into the freed memory; readers observe the
  buffer contents change mid-guard, which is impossible without UAF
  (a held guard's epoch is odd and any correct `wait` would block on it).

- **Reproduction result**: **PASS — bug triggered**. With
  `LR_REPRO_BUG1_SLEEP_US=200` in `--release` mode, 100 iterations
  yielded **289/914 (~31.6%) reader observations** where the buffer's
  value changed during a single guard's lifetime
  (`v=0x1, v2=<heap-pointer-like-garbage>`). Sample output:
  ```
  BUG OBSERVED iter=0: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
  BUG OBSERVED iter=0: v=0x1 v2=0x3aadd031 (CANARY=0x77777777)
  iter=0/100 bugs=2 obs=8
  ...
  iter=80/100 bugs=232 obs=737
  ...
  Total bug observations: 289 / 914 reader observations
  test take_inner_stale_snapshot_uaf_l3 ... ok
  ```
  The fact that the second read returned a different value than the first
  while a guard was still held proves the buffer was freed and reused by
  the allocator while the reader still aliased it (UAF). The canary
  itself (0x77777777) was not observed because the allocator's reuse
  overwrote the canary before the second read.

  A non-Level-3 stress test
  (`repro/test_bug1_take_inner_uaf.rs`) also exists; it does NOT trigger
  reliably without TSAN — that file is included as documentation and to
  show the natural-window probability is too low for non-sanitizer
  detection.

- **Developer intent investigation**: PR #144 ("Fix data race on
  writehandle drop") by Fredi Raspall is OPEN and unmerged on
  `https://github.com/jonhoo/left-right/pull/144`. The commit message
  explicitly states the intent the bug violates: *"New readers should
  either cause the drop to be deferred (until they depart) or be denied
  access to the value, depending on when they enter(). However, in the
  current drop logic, there's a window of time where a read handle may
  successfully enter() and reference the T that is about to be dropped
  without the thread owning the writehandle waiting."* The PR's fix
  inserts exactly the same `last_epochs` refresh (after the NULL-swap,
  before the wait) that our `MCWriterTakeInnerResnapshot` action
  models. The developer intent is firmly *"this is a bug; we want
  drops to be deferred until readers depart."*

- **Recommendation**: Apply PR #144 (or an equivalent fix) — refresh
  `last_epochs` for every registered slot after the NULL-swap and before
  calling `wait`. This is the minimal change that closes the race. The
  spec's `MC_hunt_F1_uaf_fixed.cfg` BFS run confirms the fix is sufficient
  within the modeled state space (78 diameter, 13.7 M states,
  no violation).

---

## Bug 2: Reentrant `enter()` panics on dropped `WriteHandle`

- **Source**: MC counterexample (`MC_hunt_F2_panic.cfg`, `output/F2_panic_bfs.out`,
  16-state trace at depth 20) + Code review (modeling brief §2 F2).
  **Not yet reported upstream.**
- **Status**: **REPRODUCED** (Level 0 — pure black-box, no source modification).
- **Severity**: **Medium** (process-/thread-aborting panic via `unreachable!()`,
  but no UB; soundness-adjacent).
- **Location**: `artifact/left-right/src/read.rs:120-148`, specifically
  `unreachable!()` at `read.rs:146`. Trigger source: `write.rs:175` (the
  NULL-swap inside `take_inner`).
- **Description**:
  `ReadHandle::enter` has two paths. The non-reentrant path
  (`enters == 0`, `read.rs:177-214`) bumps the epoch, fences, loads
  `inner_ptr`, and **gracefully returns `None`** if the pointer is NULL
  (`read.rs:206-213`). The reentrant path (`enters != 0`,
  `read.rs:120-148`) does NOT bump the epoch (the outer guard's odd epoch
  is still in effect); it just reloads `inner_ptr` and **asserts non-NULL**
  via `unreachable!()` at `read.rs:146`. The reentrant branch's claim —
  *"if pointer is null, no ReadGuard should have been issued"* — is
  incorrect. A reader can mint an outer guard while `inner_ptr` is
  non-NULL, then have `inner_ptr` switched to NULL by a concurrent
  `WriteHandle::drop` → `take_inner`, and then call `enter()` again. The
  outer guard is still valid (the writer's `wait` inside `take_inner` is
  correctly blocked on the reader's odd epoch), but the *new* nested
  `enter()` cannot mint a guard from a NULL pointer and panics.

- **Prerequisites**:
  - [code] The reentrant branch is reachable when `enters > 0`: VERIFIED —
    `read.rs:121` (`if enters != 0 {`).
  - [code] `enters > 0` implies the outer guard is still alive
    (epoch odd): VERIFIED — `read.rs:194-195` increments enters when
    minting the guard, `guard.rs:120-124` decrements on drop and bumps
    the epoch when enters reaches 0.
  - [code] `inner_ptr = NULL` is reachable while `enters > 0`: VERIFIED —
    `take_inner`'s NULL-swap (`write.rs:175`) writes NULL atomically;
    the writer's `wait` inside `take_inner` blocks on the reader's odd
    epoch but does NOT block the reader from issuing further `enter()`
    calls.
  - [code] The non-reentrant path's NULL handling demonstrates the
    library's intent: VERIFIED — `read.rs:206-213` returns `None` from
    a NULL pointer load, so the "no guard from a NULL pointer" rule is
    the explicit contract.
  - [spec] None applicable — this is a code-level path that the
    reentrant branch failed to mirror; no protocol question.

- **Counterfactual fix check**: NOT APPLICABLE — the property is local
  ("the reentrant branch returns None from a NULL pointer load instead
  of panicking"). There is no system-wide bad outcome class to search
  alternative paths to; the bug is the missing NULL handling on this
  specific code path. Skipping per Phase 2 guidance for local
  properties.

- **Report Tier**: **A** (a panic that aborts the reader thread is
  externally observable hard-to-recover harm — particularly because
  Rust's `panic!()` from a library is *not* a graceful API contract;
  callers cannot distinguish it from a logic bug in their own code).
  Note: while the panic message says "internal error: entered
  unreachable code", it is fully reachable from public API usage; the
  message itself is misleading. The fix is one line.

- **Trigger scenario** (from MC counterexample at
  `output/F2_panic_bfs.out`, steps 1-16; concretized as the
  reproduction test below):
  1. Reader R takes outer guard via `r.enter()`. After the guard:
     `enters[R] == 1`, `epoch[R] := odd`. R holds a reference to the
     current `r_handle`.
  2. Writer W is dropped (or `take`d), calling `take_inner`.
     `take_inner` runs through publish, then NULL-swaps `inner` at
     `write.rs:175`.
  3. After the NULL-swap, `take_inner` calls `wait()`. `wait()`
     correctly sees R's odd epoch and starts spinning — the writer is
     blocked.
  4. Reader R, *while still holding the outer guard*, calls `enter()`
     again. `enters[R] != 0`, so the reentrant branch
     (`read.rs:120-148`) runs.
  5. The reentrant branch loads `inner_ptr` — sees NULL (the writer's
     swap from step 2). `as_ref()` returns None. The `else` arm at
     `read.rs:146` runs: `unreachable!("if pointer is null, no
     ReadGuard should have been issued")` — PANIC.
  6. The panic unwinds R's thread; R's outer `ReadGuard::Drop` runs
     during unwind, decrementing enters to 0 and bumping the epoch
     (now even). Writer's `wait()` then unblocks and the drops
     complete normally.

- **Reproduction test**: `repro/test_bug2_reentrant_panic.rs`
  (also at `artifact/left-right/tests/repro_bug2_reentrant_panic.rs`).
  Level 0 — pure black-box. Uses only public APIs:
  `left_right::new`, `WriteHandle::publish`, `WriteHandle::append`,
  `ReadHandle::clone`, `ReadHandle::enter`, `WriteHandle::drop`. No
  source modification. The test uses standard `std::sync::mpsc`
  channels and `std::thread` for synchronization between the reader,
  the writer-drop thread, and the test driver.

- **Reproduction result**: **PASS — bug triggered**.
  Command: `cargo test --test repro_bug2_reentrant_panic -- --nocapture`
  Actual output:
  ```
  Finished `test` profile [unoptimized + debuginfo] target(s) in 0.27s
       Running tests/repro_bug2_reentrant_panic.rs (target/debug/deps/...)

  running 1 test

  thread '<unnamed>' (3426751) panicked at
  /home/ubuntu/Specula/case-studies/left-right_2/artifact/left-right/src/read.rs:146:17:
  internal error: entered unreachable code:
  if pointer is null, no ReadGuard should have been issued
  note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
  BUG REPRODUCED: reader panicked with: internal error: entered unreachable
  code: if pointer is null, no ReadGuard should have been issued
  test reentrant_enter_on_dropped_writehandle_panics ... ok

  test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;
  0 filtered out; finished in 0.07s
  ```
  The reader thread panicked at `read.rs:146` with the *exact* message
  from the MC counterexample's invariant violation
  (`MCNoUnreachablePanic`). The test passes by virtue of catching the
  panic via `thread::JoinHandle::join().is_err()` and asserting the
  message matches.

- **Developer intent investigation**: No upstream issue or PR currently
  references this scenario. The two paths in `enter()` are clearly
  designed to handle the same thing — `read.rs:206-213` in the
  non-reentrant branch returns `None` for a NULL pointer; the reentrant
  branch's `unreachable!()` was written under the assumption that
  reaching the reentrant branch implies a previously-non-NULL load.
  That assumption is incorrect when a concurrent `take_inner` runs
  between the outer enter and the nested enter — the developer simply
  did not anticipate this interleaving. The fix mirrors the
  non-reentrant path's behavior (return `None` from NULL).

- **Recommendation**: Replace the `unreachable!()` at `read.rs:146`
  with a graceful `None` return:
  ```rust
  return if let Some(r_handle) = r_handle_ref {
      let __tla_new_enters = enters + 1;
      self.enters.set(__tla_new_enters);
      let __tla_guard = Some(ReadGuard {
          handle: guard::ReadHandleState::from(self),
          t: r_handle,
      });
      let __tla_end = crate::tla_trace::now_ns();
      let __tla_epoch = self.epoch.load(Ordering::Relaxed);
      crate::tla_trace::emit_reader_enter_nested(
          __tla_start, __tla_end, __tla_epoch, __tla_new_enters, __tla_ptr_addr,
      );
      __tla_guard
  } else {
      // OUTER guard is still valid (epoch was bumped before its load
      // saw a non-null ptr). We just cannot mint a NEW nested guard
      // from a NULL pointer. Return None.
      None
  };
  ```
  Callers of `enter()` already handle `None` from the non-reentrant
  path; they will continue to handle it identically for the nested
  case. The return type is already `Option<ReadGuard>`, so no API
  change is needed.

  This bug is a **good candidate for a small, standalone PR** — it
  shares the same root cause as PR #144 (concurrent `take_inner`
  exposing a NULL pointer to readers) but the fix is in `read.rs`
  rather than `write.rs` and is independent of PR #144.

---

## Bug 3 (informational): Long-held reader guard starves writer

- **Source**: MC counterexample (`MC_hunt_F3_liveness.cfg`,
  `output/F3_liveness_bfs.out`, 31-state trace; property
  `EventualPublish` violated under no-fairness).
- **Status**: **NOT A BUG — DOCUMENTED BEHAVIOR**.
- **Severity**: N/A (documented design constraint, not a defect).
- **Location**: `artifact/left-right/src/lib.rs:142-143` (the
  documentation that explicitly warns of this behavior); the underlying
  spin loop is at `write.rs:282-298`.
- **Description**: A reader holds a `ReadGuard` across an `await`,
  channel receive, slow user code, or any blocking call. The writer's
  `publish()` calls `wait()` which spins on `epoch.load(Acquire)` for
  that reader's slot. Since the reader's epoch stays odd until all
  guards drop, `wait` spins forever — the writer is starved.
- **Developer intent investigation**:
  The lib doc at `lib.rs:142-143` explicitly states:

  > Note also that for as long as the guard lives, a writer that tries
  > to call `WriteHandle::publish` will be blocked from making
  > progress.

  This is a documented contract. The MC's `EventualPublish` violation
  under unfair scheduling is exactly what the doc warns about — and
  the corresponding `MC_hunt_F3_liveness_fair.cfg` run, which adds
  weak fairness on `ClientHoldGuardRelease` (i.e. the documented
  contract is honored), shows `EventualPublish` HOLDS (no violation;
  diameter 43, 182 368 distinct states).

- **Prerequisites**: The "bug" requires the *reader* (i.e., the
  caller of `enter()`) to violate the documented contract by holding
  the `ReadGuard` across an indefinitely-slow operation. This is a
  caller-misuse scenario that the library author has explicitly
  documented and accepted as a trade-off. (Per the bug-confirmation
  skill, Phase 1 Step 3: "Developer says 'we know about this, it's a
  deliberate trade-off'" → Classify as NOT a bug.)

- **Report Tier**: **C** (no library defect; only flag this so the
  contract is explicit in any downstream usage audit).

- **Recommendation**: No library change required. Optionally, the
  library could add a `#[clippy::deny]`-style lint that flags a
  `ReadGuard` held across `.await` (catching the most common
  async-misuse form) but this is well outside the scope of the
  library proper and is an opt-in tooling addition, not a fix.

---

## Convergence and Notes

- **Reproduction file inventory** (in `repro/`):
  - `test_bug1_take_inner_uaf.rs` — Level-0/1 stress test (no source
    modification needed; documents the natural race window which is
    too narrow for reliable trigger without TSAN).
  - `test_bug1_take_inner_uaf_l3.rs` — **Level-3 deterministic test**
    (requires the env-var-gated sleep at `write.rs:175` already
    instrumented in the artifact; reproduces ~31.6% per reader
    observation).
  - `test_bug2_reentrant_panic.rs` — **Level-0 deterministic test**
    (pure black-box; reproduces every run).

- **Source instrumentation note**: For Bug 1's Level-3 reproduction
  test, the artifact's `src/write.rs:174-184` contains an
  env-var-gated `std::thread::sleep(LR_REPRO_BUG1_SLEEP_US)` between
  the last `publish()` and the NULL-swap. The instrumentation is
  fully opt-in (zero impact when the env var is unset) and was added
  per the Bug Confirmation skill's Phase 3 Level-3 escalation rules.
  This is similar in spirit to the existing `tla_trace` instrumentation
  scattered throughout the artifact.

- **Modeling brief findings (CR-1 through CR-5)**: These are
  code-review-only items flagged by the modeling brief (§6.3). They
  are documented in `analysis-report.md` but are out of scope for
  *bug confirmation* — they are defensive-coding suggestions / type
  system / robustness-hardening recommendations, not runtime
  correctness defects with concrete reachable harm. Per the bug
  confirmation guide ("Filter out defensive coding suggestions, style
  issues, and theoretical-only concerns"), these are not promoted to
  this report.

- **MC validation status** (from `bug-report.md`):
  - F1 UAF — VIOLATION confirmed at depth 20 with 12 943 distinct
    states; with PR #144 fix applied, no violation through depth 78
    with 13.7 M states.
  - F2 Panic — VIOLATION confirmed at depth 20 with 7 602 distinct
    states.
  - F3 Liveness — VIOLATION (expected) under no-fairness; no
    violation under reader-fairness (the documented contract).
  - F4 Snap consistency — no violation; per-reader snap is
    consistent.
  Together, these confirm that the bug-hunting effort directly
  produced the two reproductions in this report.
