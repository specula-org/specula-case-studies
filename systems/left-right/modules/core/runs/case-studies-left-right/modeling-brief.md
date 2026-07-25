# Modeling Brief: jonhoo/left-right

## 1. System Overview

- **System**: left-right — Rust concurrency primitive for high-throughput reads over a single-writer data structure
- **Language**: Rust, ~1780 LOC core logic
- **Protocol**: Two-copy read-write separation with epoch-based reader quiescence detection
- **Key architectural choices**:
  - Two copies of data: readers see one, writer mutates the other, then swaps (`AtomicPtr`)
  - Per-reader epoch counters (odd=reading, even=idle) for quiescence detection
  - SeqCst fences between operations on different atomics (epoch counter vs pointer) for cross-variable ordering
  - Operational log (oplog) replayed to both copies for consistency
  - Single writer enforced at type level (`!Sync`)
- **Concurrency model**: Single writer thread; N reader threads each with own `ReadHandle` and epoch. Shared state: `AtomicPtr<T>` (pointer), `Mutex<Slab<Arc<AtomicUsize>>>` (epoch registry)
- **Category**: B (concurrent/lock-free) — use timebox trace approach

## 2. Bug Families

### Family 1: Memory Ordering Protocol (HIGH)

**Mechanism**: The reader/writer synchronization requires SeqCst fences on both sides to establish a total order between operations on different atomic variables (epoch counter vs. data pointer). Weaker orderings allow CPU/compiler reorderings that break the "either writer sees reader's epoch, or reader sees writer's swap" invariant.

**Evidence**:
- Historical: 4 rounds of ordering fixes: `6529287` (asm barrier), `1066dc9` (SeqCst atomics), `de8664a` (simplified protocol), `50d931b` (Release + SeqCst fence)
- Code: SeqCst fences at write.rs:428 (between swap and epoch read) and read.rs:172 (between epoch bump and pointer load) are the correctness linchpin
- Gap: sync.rs:9 FIXME — loom downgrades SeqCst to Acquire; Issue #17 (loom testing incomplete)

**Affected code paths**:
- `ReadHandle::enter()` (read.rs:120-194)
- `WriteHandle::wait()` (write.rs:236-296)
- `WriteHandle::update_and_swap()` (write.rs:363-440)
- `WriteHandle::try_publish()` (write.rs:309-335)

**Suggested modeling approach**:
- Variables: `pointer` (which copy readers see), `epoch[r]` (per-reader epoch counter), `last_epochs[r]` (writer's snapshot), `w_handle` / `r_handle` (which copy is which)
- Actions: `ReaderEnter` (bump epoch, load pointer), `ReaderExit` (bump epoch), `WriterPublish` (wait + apply oplog + swap + snapshot), `WriterTryPublish` (non-blocking variant)
- Granularity: Split reader enter into 3 steps (epoch bump, fence, pointer load) to model reordering. Split writer publish into wait, apply, swap, snapshot steps.
- Memory model: Model the SeqCst fence as establishing a total order. Model weaker orderings (AcqRel, Acquire, Release) with visibility constraints. Key invariant: the fence(SeqCst) on both sides ensures mutual visibility.

**Priority**: HIGH
**Rationale**: 4 critical historical bugs, core correctness property never machine-verified, loom cannot test SeqCst semantics.

---

### Family 2: Oplog Dual-Apply Determinism (HIGH)

**Mechanism**: Operations are applied twice — once to each copy via `absorb_first` (by reference) and `absorb_second` (by value). If these applications produce different results (non-deterministic Hash/Eq, non-deterministic iteration order, state-dependent behavior), the two copies diverge. Since values may be aliased across copies, divergence causes use-after-free or double-free.

**Evidence**:
- Historical: `6a678e7` (HashBag drain order mismatch → UAF), `338ef95` (duplicate shrink → double-free)
- Historical: evmap #1 (non-deterministic PartialEq → segfault), `c57756c` (retain made unsafe)
- Historical: Issue #74, PR #83 (Box aliasing UB → Aliased<T,D> redesign)
- Code: aliasing.rs:211-218 — `change_drop()` missing `mem::forget(self)` (DoDrop→anything direction unsound)

**Affected code paths**:
- `WriteHandle::update_and_swap()` (write.rs:388-400) — applies `absorb_second` then `absorb_first`
- `Absorb::absorb_first`, `Absorb::absorb_second` — user-provided, must be deterministic
- `Aliased::alias()`, `Aliased::change_drop()`, `Aliased::drop()` (aliasing.rs)

**Suggested modeling approach**:
- Variables: `copy_left[key]`, `copy_right[key]` (representing both data copies), `oplog` (sequence of operations)
- Actions: `AbsorbFirst(op)` (apply by-ref to left), `AbsorbSecond(op)` (apply by-value to right), `NonDeterministicAbsorb(op)` (fault injection: apply differently to left vs right)
- Invariant: After each publish cycle, both copies are identical (`CopiesConsistent`)
- Fault injection: Model a non-deterministic absorb that removes different elements from the two copies. Check if aliased values can be double-freed or used-after-free.

**Priority**: HIGH
**Rationale**: 5+ historical bugs, fundamental architectural tension. Model checking can prove that the oplog replay protocol correctly synchronizes copies when absorb is deterministic, and show exactly how divergence leads to safety violations when it's not.

---

### Family 3: Reader Lifecycle / Epoch Management (MEDIUM)

**Mechanism**: Reader handles register/deregister epoch slots through a shared Mutex. Interactions between reader creation (clone), destruction (drop), epoch tracking, and writer's publish create potential for deadlock or missed readers.

**Evidence**:
- Historical: `02eb63b` (clone deadlock), `73a6729` (panic blocks writer), `78cf502` (epoch slot leak)
- Code: ReadHandle::clone while holding ReadGuard + concurrent publish → deadlock (reader holds epoch odd, needs mutex; writer holds mutex, needs epoch even)
- Code: Slab reuse of epoch indices — writer may see stale `last_epochs` for reused slot (verified safe by mutex exclusion during wait, but subtle)

**Affected code paths**:
- `ReadHandle::clone()` / `ReadHandleFactory::handle()` (read.rs:74-78, factory.rs:36-38)
- `ReadHandle::drop()` (read.rs:55-63)
- `WriteHandle::wait()` (write.rs:236-296)

**Suggested modeling approach**:
- Variables: `readers` (set of active reader IDs), `epoch[r]` (per-reader), `epoch_registered[r]` (in slab), `mutex_holder` (who holds epochs mutex), `guard_count[r]` (nested enters)
- Actions: `CreateReader`, `DestroyReader`, `ReaderEnter`, `ReaderExit`, `ReaderClone` (acquires mutex), `WriterWait` (acquires mutex, checks epochs)
- Deadlock property: No circular wait between mutex and epoch tracking

**Priority**: MEDIUM
**Rationale**: Historical deadlock bug (fixed), one remaining potential deadlock scenario with clone+guard. Model checking can verify that the fixed protocol is deadlock-free and identify if the clone+guard scenario is reachable.

---

### Family 4: Publish Path Variants (MEDIUM)

**Mechanism**: Three code paths perform the publish operation: `publish()` (blocking), `try_publish()` (non-blocking), and `take_inner()` (destruction). Each must provide the same guarantee: the writer never modifies data a reader is using. The `try_publish` path (PR #120, v0.11.6) is newest and least tested.

**Evidence**:
- Historical: `d21b680` (wait before swap, not after)
- Code: `try_publish` (write.rs:309-335) — skips `wait()`, does inline epoch check, then `update_and_swap`
- Code: `take_inner` (write.rs:149-199) — swaps to NULL, waits, but uses epoch snapshot from PREVIOUS publish (verified safe via SeqCst ordering, but the reasoning is subtle)
- Code: write.rs:178 — fence comment doesn't match placement (redundant)

**Affected code paths**:
- `WriteHandle::publish()` (write.rs:343-357)
- `WriteHandle::try_publish()` (write.rs:309-335)
- `WriteHandle::take_inner()` (write.rs:149-199)

**Suggested modeling approach**:
- Actions: `WriterPublish`, `WriterTryPublish`, `WriterTakeInner` (three variants of the swap protocol)
- Key property: `NoWriteWhileRead` — writer never mutates `w_handle` while any reader has a reference to it
- The `first`/`second` flags and `swap_index` tracking should be modeled to verify the first-publish optimization

**Priority**: MEDIUM
**Rationale**: `try_publish` is new and untested by loom. `take_inner` has the most subtle correctness argument (relying on SeqCst from a previous publish). Model checking can verify all three variants.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Reader enter protocol (3-step) | Family 1: core ordering property, 4 historical bugs | Split into epoch bump, fence, pointer load. Model reordering. |
| Writer publish protocol | Family 1, 4: wait + apply + swap + snapshot | Split into discrete steps. Model all 3 variants (publish, try_publish, take_inner). |
| SeqCst fence ordering | Family 1: the correctness linchpin, never machine-verified | Model fence as establishing visibility. Either writer sees epoch OR reader sees pointer. |
| Epoch tracking (odd/even) | Family 1, 3: quiescence detection mechanism | Per-reader epoch variable. Writer checks parity and equality. |
| Dual-copy oplog replay | Family 2: determinism invariant | Two copy variables. Apply ops to both. Fault: non-deterministic apply. |
| Reader lifecycle (create/destroy/clone) | Family 3: deadlock potential | Model mutex acquisition during clone/destroy vs writer wait. |
| Slab reuse of epoch indices | Family 3: subtle reuse correctness | Model reader destroy → new reader at same index. |
| First-publish optimization | Family 4: first/second/sync_with state machine | Model the pre-publish direct-write path and sync_with. |
| Nested enter (guard count) | Family 1: epoch only bumped on first enter | Model guard_count, epoch only changes when count goes 0→1 or 1→0. |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Aliased<T,D> implementation | Code-level bug (change_drop missing mem::forget), not protocol logic. Code-review-only. |
| Send/Sync trait bounds | Type system concern (Family 5), fixed in current version. Not protocol logic. |
| Oplog memory management | VecDeque growth/drain is a performance concern, not correctness. |
| ReadGuard::map/try_map | Trivial reference forwarding, no concurrency implications. |
| ReadHandleFactory | Thin wrapper around clone, no additional protocol logic. |
| Crossbeam CachePadding | Performance optimization (commit `3f48163`), no correctness impact. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Multi-step reader enter | `reader_state[r] ∈ {Idle, EpochBumped, FenceDone, PointerLoaded}` | Model reordering between epoch bump and pointer load | Family 1 |
| SeqCst fence model | `fence_order` (total order on fence events) | Capture the mutual visibility guarantee | Family 1 |
| Multi-step writer publish | `writer_state ∈ {Idle, Waiting, Applied, Swapped, Snapshotted}` | Model the wait-apply-swap-snapshot sequence | Family 1, 4 |
| Publish variants | `PublishMode ∈ {Blocking, TryPublish, TakeInner}` | Verify all three paths provide identical safety | Family 4 |
| Non-deterministic absorb | `fault_nondet_absorb` (boolean) | Inject divergent operations between copies | Family 2 |
| Reader lifecycle | `reader_registered[r]`, `mutex_holder` | Model clone/drop mutex interaction | Family 3 |
| First-publish state | `first`, `second` (booleans) | Verify pre-publish optimization correctness | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoWriteWhileRead | Safety | Writer never modifies a copy that any reader has a reference to | Family 1, 4 |
| EpochVisibility | Safety | If writer sees reader's epoch as even/changed, reader is not using old copy | Family 1 |
| MutualVisibility | Safety | After both SeqCst fences: either writer sees reader's epoch OR reader sees new pointer | Family 1 |
| CopiesConsistent | Safety | After publish, both copies contain identical data (when absorb is deterministic) | Family 2 |
| NoDoubleFreeDeterministic | Safety | When absorb is deterministic, no aliased value is freed while still referenced | Family 2 |
| DivergenceUnsafe | Bug-hunting | When absorb is non-deterministic, copies diverge and aliased value may be double-freed | Family 2 |
| NoDeadlock | Liveness | No circular wait between epoch tracking and mutex | Family 3 |
| PublishProgress | Liveness | If no reader holds a guard indefinitely, publish eventually completes | Family 1 |
| VariantEquivalence | Safety | try_publish and take_inner provide same safety guarantee as publish | Family 4 |
| FirstPublishCorrect | Safety | Pre-publish direct writes are correctly propagated via sync_with | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Can weakening SeqCst fences to AcqRel allow a reader to see freed data? | NoWriteWhileRead, MutualVisibility | 1 |
| MC-2 | Does try_publish provide same guarantees as publish? | VariantEquivalence | 4 |
| MC-3 | Does take_inner (NULL swap + wait with old epoch snapshot) correctly wait for all readers? | NoWriteWhileRead | 4 |
| MC-4 | Can non-deterministic absorb cause aliased value double-free? | NoDoubleFreeDeterministic | 2 |
| MC-5 | Can ReadHandle::clone while holding guard + concurrent publish deadlock? | NoDeadlock | 3 |
| MC-6 | Is slab reuse of epoch indices safe? (new reader gets old slot) | EpochVisibility | 3 |
| MC-7 | Is the first-publish optimization (direct write + sync_with) correct? | FirstPublishCorrect, CopiesConsistent | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | ReadHandle::clone deadlock under contention | Spawn writer publishing in tight loop, reader holding guard and cloning |
| TV-2 | try_publish returns correct results under concurrent reads | Loom test with try_publish + concurrent enters |
| TV-3 | take_inner/drop correctness with concurrent readers | Loom test: drop WriteHandle while readers are entering |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | aliasing.rs:211-218 — change_drop() missing mem::forget(self) | Add mem::forget(self) after ptr::read, or document that DoDrop→anything is UB |
| CR-2 | write.rs:178 — SeqCst fence comment doesn't match placement | Fix comment or remove redundant fence |
| CR-3 | sync.rs:9 — FIXME about loom SeqCst downgrade | Track loom issue tokio-rs/loom#117 for upstream fix |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/left-right/analysis-report.md`
- **Key source files**:
  - `artifact/left-right/src/write.rs` (writer: publish, wait, swap — 793 lines)
  - `artifact/left-right/src/read.rs` (reader: enter protocol, epoch — 249 lines)
  - `artifact/left-right/src/read/guard.rs` (guard: RAII epoch restore — 126 lines)
  - `artifact/left-right/src/aliasing.rs` (aliased value management — 430 lines)
  - `artifact/left-right/src/sync.rs` (loom compatibility — 22 lines)
- **GitHub issues**: #17 (loom testing), #74 (Box UB), #75 (Send/Sync), #77 (rollback), #24 (leak), #53 (epoch bloat)
- **Key commits**: `1066dc9` (SeqCst ordering), `de8664a` (simplified protocol), `02eb63b` (deadlock fix), `6a678e7` (drain order UAF)
- **Reference paper**: [Left-Right concurrency scheme](https://hal.archives-ouvertes.fr/hal-01207881/document) (2015)
- **Downstream**: [evmap](https://github.com/jonhoo/evmap) — concurrent hash map built on left-right
