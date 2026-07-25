# Modeling Brief: crossbeam-epoch

## 1. System Overview

- **System**: `crossbeam-epoch` — Epoch-based memory reclamation for lock-free data structures in Rust
- **Repository**: `crossbeam-rs/crossbeam` (monorepo), subcrate `crossbeam-epoch`
- **Language**: Rust, ~3500 LOC core logic (internal.rs 636, atomic.rs 1735, guard.rs 528, collector.rs 455, epoch.rs 148, deferred.rs 153, sync/list.rs 497, sync/queue.rs 475)
- **Protocol**: Epoch-based reclamation (EBR), variant of Keir Fraser's epoch-based safe memory reclamation
- **Key architectural choices**:
  - Global epoch advanced via `store` (not CAS) — idempotent but formally fragile (`internal.rs:286`)
  - x86-specific CAS-as-fence optimization in `pin()` — developer admits it is "not clear that this is permitted by the C++ memory model" (`internal.rs:420-432`)
  - 2-epoch gap for reclamation (`is_expired`: `global_epoch - bag_epoch >= 2`, `internal.rs:157-161`), with historical oscillation between 2 and 3
  - `Local` nodes stored in a lock-free intrusive linked list, scanned by `try_advance` on every collection cycle
- **Concurrency model**: Per-thread `Local` with `Cell`-based (non-atomic) counters; cross-thread synchronization via SeqCst fences + Relaxed loads; global epoch is a single `AtomicEpoch`

## 2. Bug Families

### Family 1: Epoch Advancement Protocol Races (HIGH)

**Mechanism**: The epoch advancement protocol relies on a subtle interleaving argument between SeqCst fences in `pin()` and `try_advance()`. Violations of this protocol — wrong ordering of local epoch update vs. garbage collection, incorrect epoch gap threshold, or missed newly-registered Locals — lead to premature reclamation (use-after-free).

**Evidence**:
- Historical: Issue #105 — `pin()` called `try_collect()` even in nested critical section, advancing local epoch while references were held (use-after-free)
- Historical: Issue #46 — local epoch updated BEFORE collecting garbage, creating a window where freshly-retired objects could be freed too early (segfaults on 8+ cores)
- Historical: Commits `52a4e31`/`389a60b` — epoch expiration threshold oscillated between `>= 2` and `>= 3`; the `>= 3` approach was reverted, restoring the fence-based `>= 2` scheme
- Historical: PR #755 — identified that `store` (not CAS) for global epoch advancement could theoretically allow epoch to decrease; PR was closed without formal resolution
- Code analysis: `internal.rs:420-432` — HACK comment admits CAS-as-fence on x86 is "not clear [to be] permitted by the C++ memory model"
- Code analysis: `internal.rs:441-444` — compiler fence described as "formally not enough to get rid of data races"

**Affected code paths**:
- `Global::try_advance()` (`internal.rs:237-288`) — reads global epoch (Relaxed), SeqCst fence, scans all Locals (Relaxed loads), Acquire fence, stores successor epoch (Release)
- `Local::pin()` (`internal.rs:403-462`) — reads global epoch (Relaxed), stores local epoch (SeqCst CAS on x86 / Relaxed + SeqCst fence on non-x86)
- `Local::unpin()` (`internal.rs:466-479`) — stores unpinned epoch (Release)
- `Global::collect()` (`internal.rs:208-226`) — calls try_advance, pops expired bags

**Suggested modeling approach**:
- Variables: `globalEpoch`, `localEpoch[Thread]`, `pinned[Thread]` (BOOLEAN), `bags` (set of `<<epoch, contents>>` tuples)
- Actions: `Pin(t)` — read global epoch, store local epoch with pinned flag; `Unpin(t)` — clear pinned; `TryAdvance(t)` — scan all locals, advance if all are current or unpinned; `Collect(t)` — pop bags where `globalEpoch - bag.epoch >= 2`; `Defer(t, obj)` — add to local bag; `PushBag(t)` — seal bag with current epoch, move to global queue
- Granularity: Pin must be split into "read global epoch" and "store local epoch" as two separate steps (with interleaving) to capture the TOCTOU window
- The `store` vs `CAS` for epoch advancement should be modeled as `store` (the actual implementation) to check if epoch monotonicity holds

**Priority**: High
**Rationale**: 3 critical historical bugs (#105, #46, threshold oscillation), known unresolved theoretical concern (PR #755), developer-acknowledged HACK in pinning. The epoch advancement protocol IS the core safety mechanism — if it fails, everything fails. TLA+ is ideal for exploring the interleaving space.

---

### Family 2: Data Structure / EBR Interaction (HIGH)

**Mechanism**: EBR correctness requires that retired objects are unreachable from shared memory within the epoch gap. If a data structure retires a node while it is still reachable (e.g., via a lagging `tail` pointer), no amount of epoch delay is sufficient. The reclamation protocol and the data structure protocol must be co-verified.

**Evidence**:
- Historical: Issue #238 / Commit `2618830` — MSQueue `pop` called `defer_destroy` on head while `tail` still pointed to it. When `head == tail`, the old sentinel was retired but still reachable, causing use-after-free. KAIST researchers proved E+2 was insufficient; E+3 was also buggy for a related scenario.
- Historical: Commit `088012e` — list `finalize` freed nodes immediately instead of deferring via epoch, causing use-after-free during concurrent iteration
- Historical: RUSTSEC-2018-0009 — MSQueue/SegQueue double-free: popped elements' destructors were still run by epoch GC
- Code analysis: `queue.rs:129-135` — the fix: advance `tail` before `defer_destroy(head)` when `head == tail`
- Code analysis: `list.rs:254-263` — physical unlinking CAS followed by `finalize()` which defers destruction. Only one CAS can succeed (atomicity), preventing double-finalize.

**Affected code paths**:
- `Queue::pop_internal()` (`queue.rs:120-143`) — head advancement, tail check, defer_destroy
- `Queue::push_internal()` (`queue.rs:68-97`) — tail advancement, helping
- `List::Iterator::next()` (`list.rs:241-298`) — physical unlinking during traversal
- `List::insert()` (`list.rs:175-196`) — head CAS

**Suggested modeling approach**:
- Variables: `head`, `tail`, `nodes[NodeId -> {next, data, deleted}]`, model the queue AND epoch together
- Actions: `Push(t, val)`, `Pop(t)`, `HelpAdvanceTail(t)` — model the full Michael-Scott queue protocol
- The key property: when `defer_destroy(node)` is called, verify that `node` is unreachable from both `head` and `tail`
- Model the list similarly: `Insert(t, entry)`, `Delete(t, entry)`, `Unlink(t, pred, curr)` with interleaving

**Priority**: High
**Rationale**: 3 critical bugs (MSQueue UAF, list immediate-free, double-free advisory). The interaction between EBR and data structure invariants is where the hardest bugs live. The MSQueue bug required formal analysis by KAIST researchers to fully understand. TLA+ can systematically explore whether the fix (tail advancement in pop) is complete.

---

### Family 3: Finalization and Thread Lifecycle (MEDIUM)

**Mechanism**: When a thread exits, its `Local` must be cleaned up: pending garbage flushed to the global queue, the `Local` node marked as deleted in the linked list, and the `Local`'s memory eventually reclaimed. The dual reference counting (`handle_count` / `guard_count`) creates complex orderings that must be correct for both "handle dropped last" and "guard dropped last" scenarios.

**Evidence**:
- Historical: Commit `893a08d` — `repin` bug: forgot to call `.pinned()` on epoch value, corrupting epoch tracking (could cause premature reclamation or infinite retention)
- Historical: Commit `9c95360` — memory leak through unprotected guard: deferred functions silently dropped
- Historical: Issue #422 — investigation into whether storing Guard in TLS is unsound (determined false alarm, but revealed the subtlety)
- Historical: Issue #1042 — `guard_count` overflow/underflow during `pin()`, possibly related to TLS destructor ordering bug in rustc (#47949)
- Code analysis: `internal.rs:531-569` — `finalize()` temporarily bumps `handle_count` to 1 to prevent re-entrant finalize during internal `pin()`. The ordering of read-collector-before-delete-entry at lines 556-567 is safety-critical.
- Code analysis: `default.rs:58-65` — `with_handle` fallback creates temporary `LocalHandle` after TLS destruction, registering a new `Local` that is immediately finalized after use

**Affected code paths**:
- `Local::finalize()` (`internal.rs:531-569`)
- `Local::release_handle()` (`internal.rs:514-527`)
- `Local::unpin()` (`internal.rs:466-478`)
- `default::with_handle()` (`default.rs:58-65`)

**Suggested modeling approach**:
- Variables: `handleCount[Thread]`, `guardCount[Thread]`, `localState[Thread -> {active, finalizing, deleted}]`
- Actions: `AcquireHandle(t)`, `ReleaseHandle(t)`, `Pin(t)`, `Unpin(t)`, `Finalize(t)`
- Key property: the `Local` is never accessed after its memory is freed; `finalize` is called exactly once

**Priority**: Medium
**Rationale**: The repin bug was critical. The finalization protocol is complex (temporary handle_count bump, ordering constraints). However, the `Cell`-based counters ensure single-thread access, limiting the interleaving space. The main risk is the interaction between finalization and concurrent `try_advance` scans.

---

### Family 4: Garbage Collection Timing & Liveness (MEDIUM)

**Mechanism**: Garbage is only collected during `pin()` calls (every `PINNINGS_BETWEEN_COLLECT` = 128 pins). If no thread pins, garbage accumulates indefinitely. If epoch advancement is blocked by a single slow/stalled thread, ALL garbage is retained. `mem::forget(Guard)` permanently stalls GC system-wide.

**Evidence**:
- Historical: Issue #273 — GC not triggered; fundamental EBR limitation
- Historical: Issue #566 — extreme memory usage in SkipList workloads
- Historical: Issue #852 — `try_advance` O(N) scan of all Locals; 500+ Rayon threads caused severe overhead (Solana validator)
- Historical: Issue #1001 — unnecessary `try_advance` in read-heavy workloads
- Code analysis: `internal.rs:456-458` — collection triggered only on `pin_count % PINNINGS_BETWEEN_COLLECT == 0`
- Code analysis: `internal.rs:249-270` — a single pinned thread at an old epoch blocks all advancement

**Affected code paths**:
- `Local::pin()` collection trigger (`internal.rs:456-458`)
- `Global::try_advance()` scan (`internal.rs:249-270`)
- `Global::collect()` (`internal.rs:208-226`)

**Suggested modeling approach**:
- Variables: `garbageCount` (global counter of uncollected items)
- Actions: Model the periodic collection trigger in `pin()`; model a `StallThread(t)` action that keeps a thread pinned indefinitely
- Key property (liveness): `<>[] (garbageCount = 0)` — all garbage is eventually collected (requires fairness)
- Key property (safety): `garbageCount` never exceeds `N * MAX_OBJECTS` for N threads (bounded accumulation)

**Priority**: Medium
**Rationale**: Multiple production reports of extreme memory usage. The O(N) scan is a known scalability bottleneck. However, these are primarily liveness/performance properties, not safety violations. TLA+ can verify the liveness property under fairness assumptions.

---

### Family 5: Low-Level Undefined Behavior (LOW for TLA+)

**Mechanism**: Rust-specific UB from `mem::uninitialized`, `assume_init` on partially-initialized data, Stacked Borrows violations, pointer provenance loss, and incorrect `memoffset` macro.

**Evidence**:
- Historical: Commits `f48c1c7`, `e0fd465` — `mem::uninitialized()` → `MaybeUninit`
- Historical: Commit `b911157` — `assume_init()` on partially-initialized `Deferred::Data`
- Historical: Commit `385bf3e` — `Pointable` size vs length confusion in `[MaybeUninit<T>]`
- Historical: Commit `02fb08a` / Issue #545 — pervasive Stacked Borrows violations, required API redesign (PR #871)
- Historical: Commit `b05e1e3` / Issue #957 — pointer provenance UB from ptr-to-int casts
- Historical: Issue #395 — `memoffset` crate's `offset_of!` macro was unsound

**Priority**: Low (for TLA+ modeling)
**Rationale**: These are Rust language-level UB issues, not protocol logic bugs. They cannot be found or verified by TLA+ model checking. They are best addressed by Miri, sanitizers, and code review. Many have already been fixed.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Pin/Unpin protocol | Family 1: core of all 3 critical bugs | Split pin into read-global-epoch + store-local-epoch; model the TOCTOU window |
| Epoch advancement | Family 1: store-not-CAS concern (PR #755) | Model `try_advance` scanning all locals, then storing successor. Use `store` not `CAS`. Check monotonicity. |
| Garbage collection & bag sealing | Family 1: threshold oscillation | Model `push_bag` sealing with global epoch; `collect` popping bags where gap >= 2 |
| Michael-Scott queue | Family 2: the hardest bugs hide here | Full MSQ with head/tail/sentinel + EBR. Verify tail advancement fix. |
| Intrusive linked list | Family 2: immediate-free bug + concurrent iteration | Two-phase deletion + epoch-deferred finalization |
| Defer & destroy scheduling | Family 1+2: when objects become eligible | Model the full lifecycle: defer → bag → sealed bag → collect → destroy |
| Thread registration & finalization | Family 3: complex lifecycle | Model register/finalize with handle_count/guard_count |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Memory ordering (SeqCst vs Acquire vs Relaxed) | TLA+ cannot model hardware memory ordering. The C++ memory model requires specialized tools (e.g., CDSChecker, GenMC, herd7). |
| Pointer tagging / alignment | Implementation detail. Tags are just metadata bits; they don't affect protocol logic. |
| Stacked Borrows / provenance | Rust-specific UB. Requires Miri, not TLA+. |
| `Deferred` inline vs heap storage | Implementation optimization with no protocol-level effect. |
| Cache padding / false sharing | Performance concern, not correctness. |
| 32-bit epoch wrapping | Theoretical concern; wrapping arithmetic handles it correctly. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Split pin | `readEpoch[t]`, `storedEpoch[t]` | Capture TOCTOU between reading global epoch and storing local epoch | Family 1 |
| Store-not-CAS advancement | `globalEpoch` (single variable, no CAS) | Check if concurrent stores can violate monotonicity | Family 1 |
| Epoch gap threshold | `bagEpoch` in sealed bags | Verify 2-epoch gap is sufficient (or if 3 is needed) | Family 1 |
| MSQueue tail tracking | `head`, `tail`, `nodes` | Capture head==tail scenario and verify fix | Family 2 |
| List deletion phases | `logicallyDeleted[entry]`, `physicallyUnlinked[entry]` | Two-phase deletion with concurrent iteration | Family 2 |
| Finalization lifecycle | `handleCount[t]`, `guardCount[t]`, `localState[t]` | Verify finalize is called exactly once | Family 3 |
| Garbage counter | `garbageCount` | Verify bounded accumulation and eventual collection | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SafeReclamation | Safety | No object is freed while any thread holds a reference to it (pinned at the object's epoch or earlier) | Family 1, Family 2 |
| EpochMonotonicity | Safety | Global epoch never decreases | Family 1 (PR #755) |
| NoDoubleFree | Safety | Each deferred object is destroyed exactly once | Family 2 (RUSTSEC-2018-0009) |
| TailReachability | Safety | When `defer_destroy(node)` is called, `node` is unreachable from `tail` | Family 2 (Issue #238) |
| FinalizeOnce | Safety | `Local::finalize()` is called exactly once per Local | Family 3 |
| BoundedGarbage | Safety | Total uncollected garbage is bounded by `N * MAX_OBJECTS + global_queue_size` | Family 4 |
| NoLeak | Liveness | All deferred destructors eventually execute (requires fairness: every thread eventually unpins) | Family 4 |
| EpochProgress | Liveness | If all threads cooperate (unpin periodically), the global epoch eventually advances | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Pin TOCTOU: thread reads epoch E, global advances to E+1 before thread stores. Can garbage from E be collected? | SafeReclamation | 1 |
| MC-2 | Two threads both call try_advance, both read epoch E, both store E+1. Can a third concurrent store cause epoch to decrease? | EpochMonotonicity | 1 |
| MC-3 | MSQueue pop when head==tail: verify the tail-advancement fix prevents TailReachability violation | TailReachability | 2 |
| MC-4 | List: concurrent insert at head + deletion + unlinking during iteration. Can finalize be called on a still-reachable node? | SafeReclamation | 2 |
| MC-5 | Thread exits with pending garbage: does finalize correctly flush bag and mark Local as deleted? Can try_advance still see the zombie Local? | FinalizeOnce | 3 |
| MC-6 | mem::forget(Guard): verify that epoch advancement is permanently blocked (safety holds but liveness fails) | NoLeak (expected failure) | 4 |
| MC-7 | Epoch gap = 2 with MSQueue: can the scenario from Issue #238 (thread pins at E, sleeps, another thread retires via tail, two advancements occur) cause UAF? | SafeReclamation | 1+2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Deferred function panic leaks remaining bag contents | Unit test: defer a panicking closure + normal closures, verify leak via drop counter |
| TV-2 | `with_handle` fallback after TLS destruction | Integration test: thread-local drop calls `pin()`, verify no panic/leak |
| TV-3 | Loom test for epoch advancement + garbage collection | Extend loom tests to trigger `collect()` by reducing `PINNINGS_BETWEEN_COLLECT` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | x86 CAS-as-fence HACK (`internal.rs:420-432`) | Formal review by memory model expert; consider removing optimization |
| CR-2 | `compiler_fence` insufficiency (`internal.rs:441-444`) | Same as above |
| CR-3 | `compare_exchange` API returns `new` on success (Issue #946) | API change planned in crossbeam-epoch 0.10 |
| CR-4 | `Deferred` has no `Drop` impl — leaked if not `call()`-ed | Design review: should it abort? Log? |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/crossbeam-epoch/analysis-report.md`
- **Key source files**:
  - `crossbeam-epoch/src/internal.rs` (636 lines) — `Global`, `Local`, epoch protocol
  - `crossbeam-epoch/src/guard.rs` (528 lines) — `Guard`, defer operations
  - `crossbeam-epoch/src/epoch.rs` (148 lines) — `Epoch`, `AtomicEpoch`
  - `crossbeam-epoch/src/sync/queue.rs` (475 lines) — Michael-Scott queue (used by GC)
  - `crossbeam-epoch/src/sync/list.rs` (497 lines) — lock-free intrusive linked list (used for Locals)
- **GitHub issues**: #105, #46, #238 (Family 1+2); #395, #545 (Family 5); #852, #566 (Family 4); #946 (API)
- **Security advisories**: RUSTSEC-2018-0009 (double-free), RUSTSEC-2022-0029 (ordering)
- **Correctness proof**: `crossbeam-rs/rfcs/text/2017-07-23-relaxed-memory.md` (informal, SeqCst fence argument)
- **Academic reference**: KAIST PEBR (PLDI 2020) — formal analysis of epoch-based reclamation
