# Modeling Brief — crossbeam-epoch (Round 2)

## 1. System Overview

- **Name**: `crossbeam-epoch` (Rust)
- **Scale**: ~3.7 kLOC core; 9 source files.
- **Category**: **Category B — Concurrent / Lock-Free.** Sub-category per `concurrent-analysis.md` §5: **reader-writer separation / reclamation**. Justification: no network or persistence; correctness is entirely about thread-local participants coordinating with a global epoch via atomic stores, fences, and CAS to safely defer destruction.
- **Algorithm**: Epoch-Based Reclamation (Fraser-style). A pinned thread declares it is using shared data at the current global epoch. A bag of retired callbacks is sealed with the global epoch when full; the bag may be reclaimed when the global epoch has advanced by ≥ 2 (`internal.rs:160`). Advancing the global epoch is conditional on every pinned local being at the same epoch.
- **Key architectural choices**:
  - **Thread-local participant** (`Local`) on a global lock-free intrusive linked list (`sync/list.rs`), so pin/unpin only touches per-thread state on the hot path.
  - **Per-thread Bag** of `Deferred` (size 64) + global Michael-Scott queue of `SealedBag`s (`sync/queue.rs`).
  - **2-epoch reclamation rule** (`is_expired: global - bag.epoch >= 2`). The repo briefly switched to 3-epoch (commit `52a4e31`) and reverted (`389a60b`) once the underlying MS-Queue retire-before-unlink bug was fixed (`2618830`).
  - **Pin uses `relaxed-store(local) + SeqCst-fence + relaxed-load(global)` Dekker pattern**, *not* a SeqCst store. The fence is paired with the SeqCst fence in `try_advance`. On x86, an alternate `compare_exchange(starting, pinned, SeqCst, SeqCst)`-as-fence trick is used (`internal.rs:434-440`).
  - **`Cell<usize>` for `guard_count` / `handle_count`** — non-atomic per-thread counters that protect against re-finalization and reentrant pin.
- **Concurrency model**: Many threads, each owning a `LocalHandle` thread-local. Multiple `Guard`s per thread (reentrant pin). `Guard` is `!Send`. `unprotected()` returns a fake guard for single-threaded contexts.

---

## 2. Bug Families

### Family 1: Reentrant pin / nested-protection epoch advance

**Mechanism**: A pin operation that runs while the same thread already holds a `Guard` must NOT re-publish the local epoch nor trigger a `collect()` that would advance the local epoch. Without the `guard_count == 0` gate, an inner pin advances the local epoch out from under the outer guard's still-live references — UAF.

**Evidence**:
- Historical: Issue #105 — confirmed unsoundness; fixed by `if guard_count == 0` gate at `internal.rs:409`.
- Code analysis F4: `Local::finalize` itself calls `pin()` while temporarily setting `handle_count = 1` (`internal.rs:537-549`). The inner `unpin` resets epoch to `starting()` and only avoids re-finalizing because `handle_count` is held at 1 across the pin/unpin pair. This is fragile.
- Code analysis F6: `Bag::drop` calls user-supplied deferred functions; a deferred function may call `pin()` (re-entry) or `defer()` (which appends to the *same* Local's bag).

**Affected code paths**: `Local::pin`, `Local::unpin`, `Local::finalize`, `Local::defer`, `Bag::drop`, `Guard::repin_after`.

**Suggested modeling approach**:
- Variables: per-thread `guardCount: Nat`, `handleCount: Nat`, `localEpoch`, `pinCount`.
- Actions: `Pin(t)` split into `IncGuardCount(t)` and (if was 0) `PublishLocalEpoch(t)` + `MaybeCollect(t)`.
- `MCDeferCallbackPins(t)` — adversary action: while a Bag is being drained, the deferred fn pins/defers/repins.
- Granularity: every action that mutates `guardCount` is its own step; the SeqCst fence is its own step; collect is its own step.

**Priority**: **High**. Hits the core safety invariant. New Caller-Misuse modeling (defer-callback re-entry) was not in Round 1.
**Rationale**: Round-1 spec injected `MCNestedPinCollect` as a buggy variant; this round should turn it into adversarial-caller modeling so the *caller's* legal-but-aggressive sequences are exposed without injecting a buggy implementation.

---

### Family 2: Retire-before-unlink lifetime mismatch

**Mechanism**: `defer_destroy(p)` requires that `p` is no longer reachable from any atomic that another thread can load. When the implementation calls `defer_destroy` on a node that is still reachable through *another* atomic (e.g., MS-Queue tail), a thread that pins later than the bag's seal epoch can still load `p` through the surviving atomic, causing UAF.

**Evidence**:
- Historical: Issue #238 — `pop_internal` retired the head node before unlinking it from `tail` when `head == tail`. Closed by commit `2618830` (`sync/queue.rs:120-143`). Discussion explicitly stated that increasing the gap to 3 epochs would *not* fix this — only adding the tail CAS does.
- Historical: commits `52a4e31` / `389a60b` flip-flopped on 2-vs-3 epoch rule because of this same misunderstanding.
- Code analysis F12: the in-place 2-epoch rule's safety hinges on the caller obeying the retire-before-unlink contract.

**Affected code paths**: `Queue::pop_internal`, `Queue::pop_if_internal`, `Queue::push_internal`, `List::insert`, `List::Iter::next` (which retires entries it observes as deletion-tagged).

**Suggested modeling approach**:
- Treat the retire contract as an abstract **invariant** the model checks, rather than a faithful MS-Queue spec.
- Variables: `Retired: Set` of (object, sealEpoch); `Reachable: Set` of object pointers visible from any modeled atomic.
- Invariant: `\A o \in Retired: o \notin Reachable_at_seal`.
- Bounded fault injection `MCBuggyRetire`: a buggy variant retires a still-reachable object; spec should detect it via reader access.

**Priority**: **High**. Two historical bugs and the protocol's abstract contract.
**Rationale**: Round 1 had `MCQueuePopBuggy`. Promote it to a generic retire-contract invariant so any client (queue, list, future caller) is covered.

---

### Family 3: Epoch-advance + bag-retire ordering across the SeqCst boundary

**Mechanism**: Pin publishes `local.epoch = E_old` *before* loading shared atomics. Try_advance loads `global.epoch = E` *before* iterating local epochs. The two SeqCst fences (`internal.rs:447` in pin, `internal.rs:239` in try_advance) form a Dekker total order. If either fence is downgraded to release/acquire only, an advancing thread may observe a not-yet-pinned local while the pinning thread reads atomics under the now-advanced epoch — UAF.

**Evidence**:
- Code analysis F2 / F8: Relaxed loads on both sides depend on the SC fence pair for the safety argument.
- Issue #977: open question confirming the relaxed-store + SC-fence pattern is non-obvious.
- Issue #663, #1207: TSan keeps flagging this as a race because TSan does not model fences.
- Commits `52a4e31` → `389a60b`: a brief experiment with adding a *post-store validation re-load* in `pin()` (the load-validate retry loop), reverted once the 2-epoch rule's correctness was reaffirmed.

**Affected code paths**: `Local::pin` (both x86 cmpxchg-as-fence and non-x86 store-then-fence paths), `Global::try_advance`, `Local::repin` (which intentionally uses Release-only).

**Suggested modeling approach**:
- Action `Pin(t)` split into `StoreLocalEpoch(t)` (Relaxed-effect) → `FenceSeqCst(t)` → `LoadGlobalEpoch(t)`. `try_advance` similarly split: `LoadGlobalEpoch` → `FenceSeqCst` → `IterLocals` → … .
- Bounded adversary `MCRelaxStoreOrFence(siteId)`: downgrade one specific labeled site under counter bound and check whether any reader observes a stale pointer.
- Distinguish `Local::repin` (no SC fence, Release only) — the spec must not assume an SC sync at repin.

**Priority**: **High**.
**Rationale**: This is the single most subtle correctness argument in the protocol; per the §5 prioritization for reader-writer separation systems, MemOrder is the top non-headline family. Round 1 modeled `MCRepinUnsafe`; this round should also model the SC-fence pair explicitly and the adversary that downgrades one of the fences.

---

### Family 4: Adversarial Caller / Guard misuse

**Mechanism**: The public API has subtle contracts:
- Multiple `Guard`s per thread are legal (reentrant pin) — but only the *first* pin establishes the local epoch.
- `Guard` may be held across `await` points, blocking IO, or arbitrarily long (memory pressure).
- `repin_after` unpins, runs user code, re-pins — the user code may panic, allocate, or trigger another pin.
- Deferred functions (passed to `defer` / `defer_destroy`) may themselves call `pin`, `defer`, `repin`, or `flush` — and run on a *different* thread from the one that registered them.
- `unprotected()` guard's `defer` runs the closure immediately rather than queueing it; users mixing protected and unprotected guards may rely on either semantics.

Adversarial callers do nothing illegal but stress every interleaving of these contracts.

**Evidence**:
- Issue #1042: `epoch::pin()` panic — root cause was likely user mismanaging guards (and rust-lang/rust#47949 destructor non-execution in `repin_after`). Diagnosis: caller-side, not crossbeam, but exposes that protocol bookkeeping has no defensive checks (F10: no debug-assert against guard_count underflow).
- Code analysis F5: `repin_after` re-pins via `mem::forget(local.pin()) ; release_handle`. If the closure panics inside `f()`, the ScopeGuard re-pins. If the closure spawns work that *itself* uses crossbeam-epoch, behaviour is timing-dependent.
- Code analysis F6: deferred fn re-enters protocol.
- Code analysis F7: unprotected guard's `defer` runs immediately — caller mixing protected/unprotected can be surprised.
- The previous round's brief explicitly called this out as a coverage gap. Round 1 did not model the adversarial caller; this round must.

**Affected code paths**: `Guard::defer`, `Guard::repin_after`, `Guard::flush`, `Guard::repin`, `Local::pin` reentry, `Local::release_handle`, `Bag::drop`.

**Suggested modeling approach**:
- A separate `ClientHarness` action set (per `concurrent-analysis.md` §5.7), small in size:
  - `MCClientPin(t)` / `MCClientUnpin(t)` — legal pin/unpin sequences with arbitrary nesting and reordering.
  - `MCClientDeferThatPins(t)` — register a deferred fn whose body calls `Pin(t')` (potentially on a different thread when the bag is drained).
  - `MCClientGuardAcrossYield(t)` — model a thread holding `guardCount > 0` while another thread advances arbitrarily many epochs. Check that no retired bag from `local.epoch + 1` or earlier is reclaimed.
  - `MCClientRepinAfterPanic(t)` — panic in the closure, ensure ScopeGuard re-pins.
  - `MCClientUnprotectedDefer(t)` — call defer on `unprotected()` guard; verify closure runs immediately and protocol state is unchanged.
- The harness sits *outside* the library's internal state and chooses call sequences non-deterministically.

**Priority**: **High**. Explicitly flagged as Round-2 gap.
**Rationale**: Round 1 modeled buggy-variant injections (`MCQueuePopBuggy`, `MCNestedPinCollect`, `MCRepinUnsafe`). Those answer "does an internal mistake break safety?" The Caller Harness answers "does a *valid* but adversarial client break safety?" — a different question with different counterexamples.

---

### Family 5: Iterator stall in `try_advance` returning stale global

**Mechanism**: `Global::try_advance` loads global epoch under Relaxed at entry, then iterates locals. If iteration aborts (`IterError::Stalled`), it returns the *initial* `global_epoch` (`internal.rs:255`). If another thread has since advanced the global, the returned cutoff is stale. The caller (`Global::collect`) uses this as the `is_expired` cutoff. Stale cutoff → fewer bags reclaimed → memory growth (liveness, not safety).

**Evidence**:
- Code analysis F1: cited line.
- Issue #566 (open): unbounded memory growth observed in practice when bags fill faster than collect drains them.
- Combined with F11 (`MAX_OBJECTS = 64`), per-thread bag pressure is bounded but global queue may grow.

**Affected code paths**: `Global::try_advance` (return on Stalled), `Global::collect` (uses returned epoch).

**Suggested modeling approach**:
- Action `MCStalledAdvance(t)`: `try_advance` aborts mid-iteration after another thread has advanced the global.
- Liveness invariant: under fairness, every retired bag eventually expires. Optional — the headline safety properties don't depend on this.
- Variables: per-iterator state machine inside try_advance, or coarsely model the abort as a non-deterministic skip.

**Priority**: **Medium** (liveness, not safety; but informs whether the spec needs liveness checking).
**Rationale**: Issue #566 is open, has no fix, and reflects a known weakness. Worth a liveness invariant to document the gap.

---

### Family 6: Pointer/slot reuse for retired Local nodes

**Mechanism**: The lock-free linked list of `Local`s recycles deleted entries (via `defer_destroy`). A thread iterating `Global::try_advance` may hold a `Shared<Entry>` to a node that becomes deletion-tagged and ultimately freed/reallocated. The 2-epoch invariant + the iterator holding a `Guard` together protect this — but if either premise breaks (e.g., adversary advances epoch twice while iterator stalls in user-space scheduling), classic ABA on the entry slot is possible.

**Evidence**:
- Code analysis F4 / F8: `Local::finalize` does `entry.delete(unprotected())` after capturing the collector. The `unprotected()` guard is a fake guard; `delete` only sets the tag. The actual destruction is deferred to a future iteration — under whatever guard is active when the entry is unlinked.
- `IsElement<Local>::finalize` in `internal.rs:583` is `guard.defer_destroy(...)`. So Local destruction is properly deferred.
- The caller of try_advance is itself pinned (it has a Guard arg), so the iteration is protected. Verified safe in current code.

**Affected code paths**: `Global::try_advance`, `List::Iter::next`, `Entry::delete`, `Local::finalize`.

**Suggested modeling approach**:
- Variables: per-Local `state: {alive, tagged_deleted, retired, reclaimed}` and `slot_id` (so reuse is observable).
- Bounded adversary `MCSlotReuse`: a finalized Local's slot is reallocated to a new Local while a stale `Shared<Entry>` is held. Check that the iterator detects via the deletion tag.

**Priority**: **Medium**. Bug class is known (ABA), and the protocol's safety here is conditional on the 2-epoch rule which is already targeted by Family 3.
**Rationale**: Worth a focused invariant; not the most likely source of new bugs given how the iterator interacts with deletion tags.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Per-thread program counters for `Pin`, `Unpin`, `Repin`, `Defer`, `Flush`, `TryAdvance`, `Collect` | Action granularity exposes interleaving bugs (Family 3) | Split each implementation step (CAS / store / load / fence) into its own action |
| `localEpoch[t]`, `globalEpoch`, `guardCount[t]`, `handleCount[t]`, `pinCount[t]`, `bag[t]`, `sealedBags` | Mirror the implementation's state (Family 1, 2, 5) | One-to-one with `internal.rs` fields |
| Explicit `SeqCst-fence` actions on the pin and try_advance sides | Family 3 (memory ordering) requires the pair be modeled as one SC total order | Use TLA+'s default sequential consistency; *additionally* define a counter-bounded `MCRelaxStoreOrFence(siteId)` adversary that drops the fence at one labeled site |
| Reentrant pin model (no epoch advance when `guardCount > 0`) | Family 1 historical bug | `Pin(t)` checks `guardCount[t] = 0` before publishing local epoch |
| `Bag::drop` runs Deferreds, each of which can re-enter `Pin`/`Defer`/`Repin` | Family 1 / Family 4 caller misuse | `Drop(bag)` produces a bag of pending callbacks; a Defer-runs-Pin action exists |
| `Retired` set tagged with seal epoch; `is_expired` uses 2-epoch rule | Family 2 abstract contract | Spec invariant: `\A r \in Retired: r.sealEpoch + 2 > globalEpoch \/ r.is_unreachable` |
| ClientHarness with `MCClientGuardAcrossYield`, `MCClientDeferPins`, `MCClientRepinAfterPanic`, `MCClientUnprotectedDefer` | Family 4 — Round-2 explicit ask | Harness chooses call sequences nondeterministically; counter-bounded |
| Iterator stall on the linked list of locals | Family 5 (try_advance returns stale) | Action `MCStalledAdvance(t)` that aborts iteration mid-flight |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| The full Michael-Scott queue or intrusive linked list as faithful specs | State-space explosion. Both are battle-tested. Capture them via an abstract invariant ("retire-before-unlink") and a small bounded set of nodes. |
| `Pointable::init` allocator failure or alignment | Pure Rust language-level UB (Issues #689, #693). Test-verifiable, not model-checkable. |
| `Deferred`'s 3-word inline vs heap layout, MaybeUninit details | Pure Rust UB / type-system concerns (commits `b911157`, `385bf3e`). |
| Stacked-borrows / Tree-borrows / strict-provenance violations | Below TLA+'s abstraction level. Use Miri (commits `02fb08a`, Issues #545, #957, #993). |
| False sharing / cache-line layout (`CachePadded`) | Performance, not correctness (Issue #1020, commit `4bb27db`). |
| Epoch wraparound on 32-bit (AtomicUsize) | Practically unreachable on AtomicU64 path; on 32-bit it's a *liveness* issue (memory grows) not safety. Note in spec but don't model wraparound. |
| `MAX_OBJECTS = 64` exact value | Use a parameter `BAG_CAPACITY ∈ {2, 3}` for state-space tractability; check both ≥ 2. |
| TSan-friendly fence layout (Issue #1207) | Tooling artifact, not a protocol bug. |
| PEBR / Hazard-Pointer integration (Issue #221) | Research design; not in current code. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| ReentrantPinAware | `guardCount[t]`, `handleCount[t]` per-thread | Capture the `guardCount == 0` gate that protects local epoch | Family 1 |
| RetireContract | `Retired: Set of <ptr, sealEpoch, type>`, `Reachable: Set of ptr` | Enforce the retire-before-unlink invariant abstractly | Family 2 |
| SCFencePair | `seqcstOrder: Seq` of fence events, per-action ordering tags | Make the pin/try_advance fence pair explicit and challengeable | Family 3 |
| ClientHarness | `pendingClientCalls: Seq`, per-thread `mode: {Normal, RepinAfter, InDefer}` | Drive adversarial-caller sequences | Family 4 |
| StalledAdvance | `iterStalled[t]: Bool`, returned `cachedGlobalEpoch[t]` | Model try_advance returning stale global | Family 5 |
| SlotReuse | per-Local `slotId`, `state ∈ {Live, Tagged, Retired, Free, Reused}` | Observe ABA on the Local list | Family 6 |
| DeferReentry | per-Deferred `body: {Noop, Pin, Defer, Repin}` | Model defer-callback that re-enters protocol | Family 1, Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `NoUseAfterRetire` | Safety | No thread dereferences a pointer whose `Retired` entry has `sealEpoch + 2 ≤ globalEpoch` and which was reachable at retire time | F2, F12 |
| `RetireImpliesUnreachable` | Safety | At the moment a `Retired` entry is created, its pointer is not in any `Reachable` atomic | F2 |
| `LocalEpochBoundedByGlobal` | Safety | `\A t: localEpoch[t] = 0 \/ localEpoch[t].unpinned() ∈ {globalEpoch, globalEpoch.predecessor()}` | F3, F12 |
| `NoEpochAdvanceDuringNestedPin` | Safety | When `guardCount[t] > 0`, `localEpoch[t]` is not modified | F1 |
| `AdvanceRequiresAllPinnedAtCurrent` | Safety | `globalEpoch` advances only when every `localEpoch[t]` is unpinned or equal to current global | F3 |
| `BagSealedAtCurrentGlobal` | Safety | Every `SealedBag.sealEpoch ≤ globalEpoch` at the moment of seal | F12 |
| `IsExpiredImpliesGap2` | Safety | `is_expired(b, g) ⇒ g - b.sealEpoch ≥ 2` | F12 |
| `ReentrantPinDoesNotPublish` | Safety | Pin with `guardCount[t] > 0` does not store to `local.epoch` | F1 |
| `FinalizeDoesNotRecurse` | Safety | The pin/unpin pair inside `Local::finalize` does not retrigger `finalize` | F4 |
| `UnprotectedDeferRunsImmediately` | Safety | A defer call with `local == NULL` calls f() and does not enqueue | F7 |
| `EveryRetiredEventuallyReclaimed` | Liveness | Under fairness, every `Retired` entry is eventually freed | F5 (Issue #566) |
| `GuardCountNonNegative` | Safety | `\A t: guardCount[t] >= 0` | F10 |
| `HandleCountNonNegative` | Safety | `\A t: handleCount[t] >= 0` | F10 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC-1 | Adversarial caller registers a deferred fn that calls `pin()` on a different thread when the bag is drained | None expected — but violation would expose missing reentry guard | F1, F4 |
| MC-2 | Adversarial caller holds a `Guard` for many global advances while other threads run | `AdvanceRequiresAllPinnedAtCurrent` should hold | F3, F4 |
| MC-3 | Buggy retire variant: `defer_destroy(p)` while `p` still reachable from another atomic | `RetireImpliesUnreachable` violated | F2 |
| MC-4 | `try_advance` returns `cachedGlobalEpoch` after a stall; subsequent `is_expired` uses stale cutoff | `IsExpiredImpliesGap2` should still hold | F5 |
| MC-5 | Buggy variant of `pin()`: load global *after* SeqCst fence (skip the fence-after-store ordering) | `NoUseAfterRetire` violated | F3 |
| MC-6 | Buggy variant of `repin()` that compares pinned local to unpinned global (Bug `893a08d` reintroduced) | `LocalEpochBoundedByGlobal` violated; or repin no-op causes liveness failure | F1, historical |
| MC-7 | Reentrant pin mistakenly publishes local epoch (Bug Issue #105 reintroduced) | `NoEpochAdvanceDuringNestedPin` violated; downstream `NoUseAfterRetire` | F1, historical |
| MC-8 | Two threads, same address slot reused for a new `Local` while iterator holds old `Shared<Entry>` | Iterator should detect via deletion tag | F6 |
| MC-9 | `repin_after` panics inside `f()` and ScopeGuard re-pins; concurrent `try_advance` should be safe | `LocalEpochBoundedByGlobal` should hold | F4 |
| MC-10 | Defer registered on `unprotected()` guard; check it runs immediately and protocol state unchanged | `UnprotectedDeferRunsImmediately` should hold | F4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T-1 | Allocator failure paths in `Pointable::init` (Issues #689, #693) | Already covered by `cfg(crossbeam_sanitize)` builds + Miri |
| T-2 | `Deferred` inline-vs-heap correctness for closures of varying size | Existing `deferred::tests` module |
| T-3 | False sharing of `Local::epoch` (Issue #1020) | Microbenchmark; already addressed by `CachePadded` |
| T-4 | TSan / Miri runs on the test suite | Existing CI; nothing new |
| T-5 | Memory-growth bound under `defer`-heavy workload (Issue #566) | Stress test with `flush()` cadence |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `unpin` does not debug-assert `guard_count > 0` (F10) | Add `debug_assert!(guard_count > 0)`; consider safety-comment in docs |
| CR-2 | Pin's relaxed-store + SeqCst-fence pattern is not commented in `internal.rs:425-426` (Issue #977) | Add an explanatory comment referencing the Dekker pair with `try_advance` |
| CR-3 | `try_advance` returning a stale global on `IterError::Stalled` is documented in code but the *consequence* (memory growth) is not (F1, Issue #566) | Add a doc-comment explaining the lossy-but-safe semantics |
| CR-4 | `Local::finalize`'s reliance on `handle_count = 1` to prevent recursion is subtle (F4) | Add invariant comment or assertion |
| CR-5 | Reduced `MAX_OBJECTS = 4` under `crossbeam_sanitize` is invisible at the call site (F11) | Surface via a `pub(crate) const` named constant with a comment |

---

## 7. Reference Pointers

- **Full analysis report**: `analysis-report.md`
- **Key source files**:
  - `crossbeam-epoch/src/internal.rs:160` — `is_expired` (2-epoch rule)
  - `crossbeam-epoch/src/internal.rs:236-288` — `Global::try_advance`
  - `crossbeam-epoch/src/internal.rs:401-462` — `Local::pin`
  - `crossbeam-epoch/src/internal.rs:464-502` — `Local::unpin`, `Local::repin`
  - `crossbeam-epoch/src/internal.rs:529-569` — `Local::finalize`
  - `crossbeam-epoch/src/guard.rs:189-200` — `defer_unchecked` (unprotected fast path)
  - `crossbeam-epoch/src/guard.rs:366-393` — `repin_after` (panic-safe re-pin)
  - `crossbeam-epoch/src/sync/queue.rs:120-175` — `pop_internal` / `pop_if_internal` (the retire-before-unlink contract)
- **GitHub issues**:
  - Issue #105 (nested-pin advance, fixed)
  - Issue #238 (MS-Queue UAF, fixed by `2618830`)
  - Issue #566 (memory growth, open)
  - Issue #977 (pin SC-fence semantics, open)
  - Issue #1207 (TSan false positives, open)
  - Issue #221 (PEBR design, open / out-of-scope)
- **Key commits**:
  - `2618830` — MS-Queue retire-before-unlink fix
  - `893a08d` — repin pinned-bit fix
  - `52a4e31` / `389a60b` — 2-vs-3 epoch flip-flop (settled at 2)
  - `4bb27db` — false sharing fix
  - `088012e` — IsElement::finalize takes guard
  - `02fb08a` — stacked-borrows fixes
- **Reference algorithm**: Fraser EBR; `crossbeam-rs/rfcs:2017-07-23-relaxed-memory.md`; PEBR paper at <https://cp.kaist.ac.kr/gc/>.

