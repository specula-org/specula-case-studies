# Modeling Brief: jonhoo/left-right (Round 2)

## 1. System Overview

- **System**: left-right — Rust concurrency primitive for many-reader, single-writer data structures (foundation of `evmap`)
- **Language**: Rust, ~1980 LOC core logic
- **Category**: **B (Concurrent / Lock-Free)** — single-writer / many-reader split with two backing buffers, AtomicPtr selection, per-reader epoch counters with parity bits, and a SeqCst-fence-based publish protocol. No network, no protocol-level state machine.
- **Sub-category**: Reader-writer separation (per concurrent-analysis.md § 5).
- **Protocol**: Two-copy left-right with epoch-based reader quiescence detection; single-writer enforced at the type level (`ReadHandle: !Sync`).
- **Concurrency model**: One writer thread + N reader threads, each with its own `ReadHandle` and per-reader epoch slot. Shared state: `Arc<AtomicPtr<T>>` (read pointer) + `Arc<Mutex<Slab<Arc<CachePadded<AtomicUsize>>>>>` (epoch slab).
- **Key architectural choices that diverge from the textbook left-right**:
  - `take_inner()` (writer drop / explicit `take`) NULLs the read pointer and waits for readers — *with a stale `last_epochs` snapshot*.
  - `try_publish()` (added 0.11.6) is a non-blocking publish variant that skips the spin-and-retry.
  - `enter()` supports reentrant calls (nested guards) without re-bumping the epoch.
  - `Aliased<T, D>` (aliasing.rs) lets `Absorb` impls share values across the two buffers with a phantom drop-behavior witness.
  - `first` / `second` flags optimize the pre-publish window: writes go directly to `w_handle` until the first publish, then `sync_with` copies on the second publish.

## 2. Bug Families

This round focuses on **caller-misuse and action-granularity gaps** that the prior round did not cover. The prior round's `MCSkipReaderFence` / `MCSkipWriterFence` adversaries (Family 1: Memory Ordering) found 0 bugs, confirming the fence placements. We do not re-model that family; we focus on the gaps.

### Family 1: take_inner stale-snapshot UAF (HIGH)

**Mechanism**: `WriteHandle::take_inner` (called by `Drop` and `take`) NULLs the read pointer (`inner.swap(NULL, Release)` at write.rs:175), then calls `wait()` (write.rs:180). `wait()` uses `self.last_epochs`, which was last updated in the *prior* publish's `update_and_swap` (write.rs:464-466), *before* the NULL swap. A reader who entered after the prior publish snapshot but before the NULL swap has odd epoch but `last_epochs[ri]` is even — `wait()` skips them (write.rs:272-274). The writer then drops both backing buffers (write.rs:190 + Taken's `drop_second`), while the reader's guard still aliases one of those buffers.

**Evidence**:
- Historical: PR #144 "Fix data race on writehandle drop" (OPEN, by Fredi-raspall, no maintainer review). TSAN-confirmed in a stress test where one thread repeatedly creates and drops `WriteHandle<V>` while other threads create new `ReadHandle`s via the factory and call `enter()`.
- Code analysis: write.rs:166-200 (`take_inner` body) + write.rs:247-307 (`wait` skip rule) + write.rs:464-466 (snapshot timing). The action gap is between the second `publish()` returning and the NULL swap.
- The prior modeling brief (MC-3) recorded `take_inner` as "verified safe via SeqCst ordering, but the reasoning is subtle" — which turned out to be incorrect.

**Affected code paths**:
- `WriteHandle::take_inner()` (write.rs:149-210)
- `WriteHandle::wait()` (write.rs:247-307) — the `last_epochs[ri] % 2 == 0 → continue` skip rule (write.rs:272)
- `Drop for WriteHandle` (write.rs:217-221) — calls take_inner

**Suggested modeling approach**:
- Variables: `inner_ptr` (`Buffer | NULL`), `lastEpochs[r] ∈ Nat`, `epochs[r] ∈ Nat`, `enters[r] ∈ Nat` (per-reader), `state ∈ {AbsorbBefore, Swapped, Snapshotted, NullSwapped, AfterWait, Drops}` (writer phase tracker), per-reader guard set.
- Actions: split `WriterTakeInner` into at least four actions:
  1. `WTI_PrePublish` — already abstracted as composing `WriterPublish` actions.
  2. `WTI_NullSwap` — the `inner.swap(NULL, Release)`.
  3. `WTI_Wait` — uses `lastEpochs` from prior `update_and_swap`. The skip rule must be expressed exactly.
  4. `WTI_Drop` — drops both buffers; this is the action where the UAF invariant violation is observed.
- Adversary action: `ReaderEnterBetweenSnapAndNullSwap` — a reader fires `enter()` after `WTI_Wait`'s prior `last_epochs` was set but before `WTI_NullSwap` runs. Their epoch becomes odd; their guard references the soon-dropped buffer.
- Granularity: **MUST NOT** collapse `WTI_NullSwap`, `WTI_Wait`, and `WTI_Drop` into one atomic action. The bug lives in the gap.
- Proposed fix's spec model: an additional `WTI_RefreshLastEpochs` action between `WTI_NullSwap` and `WTI_Wait` (the PR #144 fix); verify that this restores safety.

**Priority**: HIGH
**Rationale**: Confirmed real UAF via TSAN; PR open and unmerged; production-impacting (any code that drops a `WriteHandle` while readers may be cloned via factory). This is the headline finding of this round.

---

### Family 2: Reentrant `enter()` panics on shutdown (MEDIUM)

**Mechanism**: When `enter()` is called with `enters > 0` (a guard already exists), it skips the epoch bump and just reloads `inner` (read.rs:122-126). If `inner` is NULL (because WriteHandle was dropped after the outer guard was taken), `as_ref()` returns `None` and the code hits `unreachable!("if pointer is null, no ReadGuard should have been issued")` (read.rs:146) — a panic.

**Evidence**:
- Code analysis: read.rs:120-148 (reentrant path) vs read.rs:206-214 (non-reentrant graceful NULL handling).
- Trigger sequence: (a) reader takes outer guard on buffer P; (b) writer's drop runs `take_inner` and `inner.swap(NULL)`; (c) reader calls `enter()` again. The outer guard is still valid because the writer's `wait` (in take_inner — possibly the buggy one from Family 1, possibly correct after the PR #144 fix) is gated on the outer guard's odd epoch. But the nested `enter()` cannot mint a new guard from a NULL pointer.
- The non-reentrant path explicitly handles NULL by returning `None`; the reentrant path's claim of unreachability is incorrect.

**Affected code paths**:
- `ReadHandle::enter()` reentrant branch (read.rs:120-148)
- `WriteHandle::take_inner()` NULL swap (write.rs:175)

**Suggested modeling approach**:
- Variables: `enters[r] ∈ Nat`, `inner_ptr ∈ {Buffer, NULL}` (already present from Family 1).
- Action: `ReaderEnterNested` distinct from `ReaderEnter`. `ReaderEnterNested` does not bump epoch; it loads `inner_ptr`. If `inner_ptr = NULL` and `enters[r] > 0`, the action panics (model as `STUCK` or invariant violation).
- Invariant: `NoReentrantPanic ≡ ∀r: enters[r] > 0 ⇒ inner_ptr ≠ NULL ∨ no nested enter taken in this state`.

**Priority**: MEDIUM
**Rationale**: Soundness-adjacent panic (no UB, but unexpected termination). Reachable in stress tests. Easy fix (return `None` mirroring the non-reentrant path). Demonstrates the value of modeling reentrant semantics, which the prior round did not surface.

---

### Family 3: Caller-misuse — long-held guard blocks publish (MEDIUM, liveness)

**Mechanism**: A reader holds a `ReadGuard` across an `await`, channel receive, slow user code, or any blocking call. Writer's `publish()` calls `wait()` which spins on `epoch.load(Acquire)` for that reader's slot (write.rs:276). Since the reader's epoch stays odd until all guards drop (guard.rs:120-124), `wait` spins forever — writer is starved.

**Evidence**:
- Code analysis: write.rs:282-298 (wait spin loop with `thread::yield_now()`); read.rs:120-215 (enter does not constrain guard lifetime); guard.rs:117-130 (Drop bumps epoch).
- The lib doc (lib.rs:142-143) explicitly warns "for as long as the guard lives, a writer that tries to call `WriteHandle::publish` will be blocked from making progress" — i.e. this is documented but unguarded by the type system.

**Affected code paths**:
- `WriteHandle::wait()` (write.rs:247-307)
- `WriteHandle::publish()` (write.rs:370-391) and `WriteHandle::take_inner()` (write.rs:149-210)
- `ReadGuard` (no Drop guard or yield-point detection)

**Suggested modeling approach**:
- Variables: `guard_held[r] ∈ BOOLEAN` (or a counter), `writer_state ∈ {Idle, Waiting, Publishing}`.
- Actions: `ReaderHoldGuardLong` — a reader fires `enter` and stays in critical section indefinitely.
- Liveness property: `WriterEventuallyPublishes ≡ writer_state = Waiting ⇒ ◇ writer_state = Idle` under the fairness assumption that no reader holds a guard forever. Without that fairness, the property is intentionally falsifiable, demonstrating the caller-misuse vulnerability.
- Spec hint: model under both fair and unfair reader assumptions to show that the protocol is *correct under the documented contract* but *vulnerable to its violation*.

**Priority**: MEDIUM
**Rationale**: Documented behavior, but a real production failure mode (e.g. a reader holding a guard across `tokio::time::sleep`). Modeling makes the dependency on the unwritten contract explicit. Distinct from data-race bugs; this is liveness.

---

### Family 4: Action granularity in `update_and_swap` (MEDIUM)

**Mechanism**: `update_and_swap` (write.rs:397-474) performs three observable atomic events plus user code: (1) absorb_first/absorb_second on `w_handle` (writes to soon-to-be-r_handle), (2) `inner.swap(Release)` (publish), (3) `fence(SeqCst)`, (4) per-reader `epoch.load(Acquire)` snapshot. Between (2) and (4), a new reader can enter, see the new pointer, and have their odd epoch captured into `last_epochs`. The wait skip rule then correctly picks them up in the *next* publish — but only because the snapshot is taken *after* (2).

**Evidence**:
- Code analysis: write.rs:397-474. The same code path is shared by `publish()` and `try_publish()` via the extracted helper.
- The prior round modeled `MCSkipWriterFence` (skipping the fence at write.rs:462) but found 0 bugs. This round identifies the action structure itself as the spec target — not the fence placement.

**Affected code paths**:
- `WriteHandle::update_and_swap()` (write.rs:397-474)
- `WriteHandle::publish()` (write.rs:370-391)
- `WriteHandle::try_publish()` (write.rs:320-362)

**Suggested modeling approach**:
- Already partially modeled in the prior round; this brief asks for the granularity to be sharpened.
- Actions: split `WriterPublish` into:
  1. `Pub_Absorb` — apply oplog ops to `w_handle`. Multiple absorbs may compose.
  2. `Pub_Swap` — `inner.swap`. Single atomic.
  3. `Pub_Fence` — SeqCst fence (already modeled by prior `MCSkipWriterFence`).
  4. `Pub_Snapshot(r)` — per-reader epoch snapshot. **Per-reader, not bulk**, because the slab iterator is not atomic; readers can interleave changes between two slot snapshots in the same loop iteration.
- Invariant: between `Pub_Swap` and `Pub_Snapshot(r)` for the LAST reader r, new readers' epoch transitions are observable in `last_epochs` if and only if they happen-before that reader's snapshot in the SC order.

**Priority**: MEDIUM
**Rationale**: This is partly already modeled; the new claim is that the snapshot loop must be split per-reader, not bulk. Useful for reasoning about Bug Family 1's fix (PR #144 also iterates per-reader for refresh).

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| `take_inner` action sequence (NullSwap, Wait, Drop) | Family 1: confirmed UAF in PR #144 | Distinct actions; introduce reader-arrives-between-snap-and-null adversary |
| Stale-snapshot wait condition | Family 1: the skip rule's correctness depends on snapshot timing | Express `wait()`'s skip rule explicitly; check the safety invariant that no reader holds a stale guard when buffers are dropped |
| Reentrant `enter` semantics | Family 2: panic on NULL | Distinct `ReaderEnterNested` action; check `NoReentrantPanic` invariant |
| Long-held guard | Family 3: liveness under caller misuse | `ReaderHoldGuardLong` action; check `WriterEventuallyPublishes` under fairness |
| Per-reader snapshot in `update_and_swap` | Family 4: snapshot loop is not atomic | Split `Pub_Snapshot` into per-reader actions |
| Slab slot reuse | Carry-over from prior round; intersects Bug A (new reader at reused slot) | Already modeled; ensure interaction with Bug A is captured |
| `take_inner` first/second handling | The maintainer flagged this as load-bearing for safety in #119 | Keep the `first`/`second` flags in the spec; do not collapse |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| SeqCst fence skipping (`MCSkipReaderFence`, `MCSkipWriterFence`) | Already model-checked in prior round; 0 bugs found. Re-running is no new information. |
| Aliased<T, D> internal mechanics | User-supplied `Absorb` impls cannot be modeled generically; the `change_drop` direction documentation gap (CM-5) is a code-review item. |
| Send/Sync trait bounds | Type system / compiler concern; no protocol logic. |
| Cache padding | Performance optimization (commit `3f48163`); no correctness implication. |
| `ReadGuard::map`/`try_map` | Trivial reference forwarding; epoch lifetime correctly transferred via `mem::forget`. |
| `ReadHandleFactory` | Thin wrapper around clone; no additional protocol logic. |
| Memory ordering from absorb_first/absorb_second user code | User-supplied; cannot model generically. The Family 2 (oplog determinism) of the prior brief covers this. |
| `tla_trace.rs` | Instrumentation only. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Take-inner phase | `wState ∈ {Idle, Pub1, Pub2, NullSwapped, Waited, Dropping, Done}` | Capture the take_inner action sequence | 1 |
| Refresh-snapshot fix toggle | `applyPR144Fix ∈ BOOLEAN` | Compare buggy vs fixed version of take_inner | 1 |
| Reader-holds-long counter | `holdLongCount[r] ∈ Nat`, bounded fairness | Model long-held guard scenarios | 3 |
| Per-reader snapshot step | `snapDone[r] ∈ BOOLEAN` | Split bulk snapshot loop per-reader | 4 |
| Reentrant guard count | `enters[r] ∈ Nat` | Distinguish first vs nested enter | 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoUAFInTakeInner | Safety | When buffers are dropped, no reader holds a guard referencing them | Family 1 |
| StaleSnapshotIsCaught | Safety | The wait skip rule (`last_epochs even ⇒ skip`) is sound only if `last_epochs` was sampled after the relevant pointer write | Family 1 |
| NoReentrantPanic | Safety | `enters[r] > 0 ∧ inner_ptr = NULL ⇒ ReaderEnterNested is not enabled` (or returns None instead of panic) | Family 2 |
| WriterEventuallyPublishes | Liveness | Under reader-fairness, `wait` always terminates | Family 3 |
| LongHeldGuardBlocksWriter | Bug-hunting | Without reader-fairness, writer can be starved | Family 3 |
| PerReaderSnapshotConsistency | Safety | After `update_and_swap` returns, `last_epochs[r]` reflects an epoch value `≥` reader r's epoch at the moment the swap was observable | Family 4 |
| (carryover) NoWriteWhileRead | Safety | Writer never mutates a buffer while any reader holds a reference to it | All |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | If a reader enters between the prior publish's snapshot and `take_inner`'s NULL swap, can the writer drop a buffer while the reader still holds a guard? | NoUAFInTakeInner | 1 |
| MC-2 | After applying PR #144's fix (refresh `last_epochs` after NULL swap), does NoUAFInTakeInner hold? | should pass | 1 |
| MC-3 | If a reader holds an outer guard and the WriteHandle is dropped, can a nested `enter` reach the `unreachable!()` at read.rs:146? | NoReentrantPanic | 2 |
| MC-4 | Under reader-fairness, does `wait` always terminate? Without fairness, can it spin forever? | WriterEventuallyPublishes (with fairness); LongHeldGuardBlocksWriter (without) | 3 |
| MC-5 | If `update_and_swap`'s snapshot loop is split per-reader and a reader's epoch transitions during the loop, is `last_epochs` still self-consistent for the wait skip rule? | PerReaderSnapshotConsistency | 4 |
| MC-6 | Does `try_publish` provide the same safety as `publish` under all the above scenarios? | NoWriteWhileRead | 1, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Reproduce PR #144's TSAN race | Run `cargo test --target ... -Zsanitizer=thread` on a stress test that drops WriteHandle in a loop while readers create new handles via the factory and call `enter()`. The PR includes such a test. |
| TV-2 | Reentrant enter on dropped WriteHandle panics | Spawn a reader holding an outer guard; drop the WriteHandle; observe `unreachable!()` panic on next nested enter. (Requires careful ordering — best done with `loom` after fixing the loom SeqCst limitation, or with manual atomic-orderings test.) |
| TV-3 | Long-held guard starves writer | Reader holds a guard across `thread::sleep(60s)`; assert writer's publish does not return within that window. (Documented behavior; test is for the spec's liveness model, not for fix.) |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `Aliased::change_drop` direction-asymmetry: doc warns about NoDrop→DoDrop direction, but DoDrop→NoDrop is also unsound unless `self` is the last alias | Update aliasing.rs:206-218 doc comment to flag both directions, OR enforce direction at the type level. |
| CR-2 | `raw_write_handle()` not marked `unsafe` despite a non-trivial safety contract (TODO at write.rs:515) | Make the function `unsafe` or change to `Option<&mut T>` as the TODO suggests. |
| CR-3 | sync.rs:9 FIXME: loom downgrades SeqCst to Acquire | Track tokio-rs/loom#117; existing loom test (read_before_publish in tests/loom.rs) cannot exercise SeqCst-dependent paths. |
| CR-4 | `ReadHandle::Drop` (read.rs:55-63) propagates poisoned-mutex panic, leading to slab leak and writer deadlock | Use a poison-tolerant lock or `try_lock` with a leak-on-error fallback. Robustness, not protocol. |
| CR-5 | `WriteHandle::Drop` (write.rs:217-221) double-panics if `take_inner`'s `publish` panics on poisoned mutex | Same robustness category as CR-4. |
| CR-6 | The reentrant-enter NULL-handling fix (Family 2) is small and clean — return `None` instead of `unreachable!()` | One-line diff to read.rs:145-147; safe to land independently of any spec verification. |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/left-right_2/.specula-output/analysis-report.md`
- **Prior modeling brief** (round 1): `/home/ubuntu/Specula/case-studies/left-right/modeling-brief.md`
- **Key source files**:
  - `artifact/left-right/src/write.rs` (838 lines) — writer, publish, wait, take_inner
  - `artifact/left-right/src/read.rs` (275 lines) — reader, enter, factory
  - `artifact/left-right/src/read/guard.rs` (130 lines) — ReadGuard with Drop-based parity restoration
  - `artifact/left-right/src/aliasing.rs` (430 lines) — Aliased<T, D> for cross-buffer aliasing
  - `artifact/left-right/src/sync.rs` (22 lines) — loom/std abstraction
- **Critical line ranges**:
  - take_inner: write.rs:149-210 (the NULL swap and stale wait)
  - wait skip rule: write.rs:272-274 (`last_epochs[ri] % 2 == 0 → continue`)
  - update_and_swap snapshot: write.rs:464-466 (per-reader Acquire load)
  - reentrant enter NULL panic: read.rs:122-148 (enters>0 path) vs read.rs:206-214 (graceful NULL)
- **GitHub PRs**:
  - **#144 (OPEN)** "Fix data race on writehandle drop" — TSAN-confirmed UAF in take_inner; fix proposes refreshing `last_epochs` after the NULL swap.
  - #119 (CLOSED) — maintainer rejected refactor that would remove first/second flags; "load-bearing for safety" with Box-aliasing Absorb impls.
  - #145 (DRAFT) — proposes replacing `Mutex<Slab>` with `cordyceps::TransferStack`; redesigns the epoch tracking; adopts `Arc::strong_count` for liveness.
- **GitHub Issues** (for context, none unfixed-and-modeling-relevant beyond PR #144):
  - #74 (Box<T> aliasing UB) — fixed via aliasing.rs.
  - #75 (Send/Sync bounds) — fixed.
  - #17 (loom testing) — open; loom SeqCst limitation persists.
  - #77 (rollback) — feature request, irrelevant.
- **Reference paper**: Ramalhete & Correia, "Left-Right: A Concurrency Control Technique" (2015), https://hal.archives-ouvertes.fr/hal-01207881/document
- **Production usage**: `evmap` and downstream high-throughput Rust services.

## Notes for Spec Author

- The prior round's spec already covers Family 1 of *that* brief (memory ordering) with `MCSkipReaderFence` / `MCSkipWriterFence`. **Do not re-implement those adversaries** — they found 0 bugs and re-running is no new information.
- This round's headline is **Bug Family 1: take_inner stale-snapshot UAF** (PR #144). The spec must:
  - Express `take_inner` as a sequence of distinct actions (NullSwap → Wait → Drop), not a single atomic step.
  - Express `wait`'s skip rule (`last_epochs[ri] % 2 == 0 → continue`) literally.
  - Allow a reader to fire `enter` between the prior publish's snapshot and the NULL swap.
  - Verify that `NoUAFInTakeInner` is **violated** in the current code and **restored** when PR #144's fix is applied.
- This is one of the *target-painting* concerns flagged by `bug-archaeology.md` § 1.4 — but in this case, the bug is **not yet fixed upstream**, so it is a legitimate forward-looking modeling target. The model checks the *current state* of the code (with the bug) and *the proposed fix* (without it). Both are useful: the first confirms TSAN's finding through a different methodology, the second validates the proposed fix.
- Bug Family 2 (Reentrant enter panic) is **not yet reported upstream**. The spec should produce a counterexample trace that can be turned into a bug report and a one-line fix.
- Bug Family 3 (long-held guard) is *intended* behavior under the API contract, but the spec should make the contract explicit and check it under both fair and unfair reader assumptions.
- The maintainer comment on #119 ("first/second is load-bearing") implies the spec **must keep** the `first`/`second` flags. Do not collapse them.
