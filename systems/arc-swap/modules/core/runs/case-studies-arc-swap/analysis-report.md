# Analysis Report: vorner/arc-swap

## 1. Executive Summary

arc-swap is a ~3,560 LOC Rust library implementing atomic `Arc` pointer swapping with lock-free/wait-free reads via a novel debt-based hazard pointer mechanism. The analysis reveals a systematic pattern of **cross-variable memory ordering bugs** in the debt system, with 2 open critical bugs (#198 UAF, #200 formal ordering proof) and 6+ historical bugs sharing the same root cause. The debt mechanism coordinates SeqCst operations on different atomic variables (debt slots vs. storage pointer) but uses weaker orderings (AcqRel) for the bridging operations, violating the total-order invariant required for safety.

## 2. Coverage Statistics

| Category | Count |
|----------|-------|
| Git commits analyzed | 433 total, 19 significant bug-fix commits |
| GitHub issues read (full discussion) | 16 (all with comments) |
| GitHub issues collected | 20+ |
| Issues confirmed as real bugs | 10 |
| Issues excluded as false positive | 1 (#71, TSan false positive) |
| Issues classified as user error | 1 (#75, const vs static) |
| Core files deeply read | 11 files (all src/ modules) |
| Open PRs reviewed | 0 (none open at time of analysis) |

## 3. Codebase Structure

### 3.1 Module Map

```
src/
├── lib.rs           (1,328 lines) — ArcSwapAny, Guard, public API
├── strategy/
│   ├── mod.rs       (168 lines)   — Strategy trait (sealed)
│   ├── hybrid.rs    (238 lines)   — Default: debt-based hazard pointers
│   └── rw_lock.rs   (63 lines)    — RwLock strategy (testing only)
├── debt/
│   ├── mod.rs       (138 lines)   — Debt struct, pay, pay_all
│   ├── list.rs      (371 lines)   — Thread-local node linked list
│   ├── fast.rs      (76 lines)    — Fast slots (8 per thread)
│   └── helping.rs   (334 lines)   — Writer helping + collision resolution
├── cache.rs         (343 lines)   — Cache for repeated reads
├── access.rs        (543 lines)   — Access/Map/DynAccess traits
├── ref_cnt.rs       (338 lines)   — RefCnt trait for Arc/Rc/Weak/Pin
├── weak.rs          (118 lines)   — Weak pointer support
├── as_raw.rs        (72 lines)    — AsRaw sealed trait for CAS
└── serde.rs         (132 lines)   — Serialization support
```

### 3.2 Concurrency Model

**Readers** (load): Wait-free for first 8 concurrent Guards per thread via fast debt slots. Falls back to lock-free helping strategy when all fast slots are occupied.

**Writers** (store/swap): Lock-free. Atomically swap the pointer (SeqCst), then traverse all thread-local debt nodes paying outstanding debts by incrementing reference counts and CAS-clearing debt slots.

**Synchronization primitives**: Only atomics (AtomicPtr, AtomicUsize). No locks in the default HybridStrategy path. Thread-local state via `thread_local!` or `#[thread_local]`.

**Key atomic orderings**:
- `SeqCst`: Pointer swap (writer), debt slot write (reader), confirmation load (reader), list head operations
- `AcqRel`: Debt::pay CAS (writer scanning debts) — **this is the problematic ordering**
- `Acquire`: Storage load in fallback path — **also problematic**
- `Relaxed`: First pointer load in fast path (optimistic), cache staleness check

### 3.3 The Debt Protocol

```
READER (fast path):                         WRITER:

1. ptr = storage.load(Relaxed)
2. slot.swap(ptr, SeqCst)                   A. old = storage.swap(new, SeqCst)
3. confirm = storage.load(SeqCst)           B. for each node: for each slot:
4. if ptr == confirm: return Guard(debt)       slot.compare_exchange(old, NONE, AcqRel, Acquire)
   elif debt.pay(ptr): retry                   if succeeded: T::inc (bump refcount)
   else: return Guard(no debt, ptr paid)    C. drop old Arc (may free)
5. drop Guard: debt.pay or T::dec
```

The **fundamental ordering gap** is between step 2 (SeqCst on debt slot) and step B (AcqRel on same debt slot). Although step 2 and step A are both SeqCst and totally ordered, step B's AcqRel does not participate in the SeqCst total order, so it can observe a stale NONE value in the slot.

## 4. Bug-Fix Commit Analysis

### 4.1 All Significant Bug-Fix Commits

| # | Commit | Date | Category | Summary |
|---|--------|------|----------|---------|
| 1 | `e763639` | 2018-03-30 | Race | Fix race condition in load/store/swap (NULL hole protocol) |
| 2 | `e4fbadf` | 2018-07-22 | ABA | Fix ABA in compare_and_swap (AsRaw consumed value before CAS) |
| 3 | `00225f5` | 2018-07-22 | ABA | Fix ABA in rcu (closure consumed guard) |
| 4 | `a2bcd54` | 2018-10-20 | Ordering | Fix potentially weak ordering (GenLock::unlock Release→AcqRel) |
| 5 | `50f54ca` | 2018-10-21 | Ordering | Fix debt head CAS ordering (Release→AcqRel) |
| 6 | `1615477` | 2019-04-13 | Soundness | Prevent UB from guard counter overflow (abort on overflow) |
| 7 | `09cb648` | 2020-04-17 | API | Skip pause/yield on last wait_for_readers iteration |
| 8 | `7a3c506` | 2020-10-25 | Soundness | Seal AsRaw trait (prevent external UB implementations) |
| 9 | `11d1c09` | 2020-11-07 | API | Remove Clone impl (every use was a bug) |
| 10 | `dfeb84b` | 2020-12-10 | Soundness | Fix CVE-2020-35711: MapGuard dangling pointer (#45) |
| 11 | `7fcaa11` | 2020-12-25 | ABA | Fix time travel in helping strategy (stale generation) |
| 12 | `343d1f5` | 2020-12-30 | ABA | Fix generation overflow ABA (cooldown mechanism) |
| 13 | `eaeae27` | 2022-10-19 | SB | Fix Stacked Borrows in RefCnt::as_ptr |
| 14 | `6b644ff` | 2022-07-10 | Ordering | Upgrade list head + node claiming to SeqCst (#76) |
| 15 | `6d3ef6d` | 2022-07-22 | Ordering | Upgrade all helping strategy atomics to SeqCst |
| 16 | `97a65cd` | 2022-12-25 | SB | Store debt list as raw pointers, not references |
| 17 | `fd04e20` | 2022-12-25 | SB | Future-proof as_ptr with proper bracket closure |
| 18 | `d849a2d` | 2025-06-20 | Ordering | Upgrade debt-list failure orderings to SeqCst (#164) |
| 19 | `63fa111` | 2025-12-13 | Provenance | Use confirm (not ptr) in fast path for correct provenance (#186) |
| 20 | `bd5d327` | 2026-01-08 | Ordering | Upgrade Debt::pay failure ordering Relaxed→Acquire (#195) |
| 21 | `cccf354` | 2026-02-02 | Ordering | Upgrade Debt::pay success ordering Release→AcqRel (transitivity) |

### 4.2 Bug Hotspot Analysis

| File | Bug-fix commits | Categories |
|------|----------------|------------|
| `src/lib.rs` | 10 | Race, ABA, soundness, API |
| `src/debt/list.rs` | 3 | Ordering, Stacked Borrows |
| `src/debt/mod.rs` | 2 | Ordering |
| `src/debt.rs` (pre-refactor) | 2 | Ordering |
| `src/debt/helping.rs` | 2 | ABA, ordering |
| `src/strategy/hybrid.rs` | 2 | Ordering, provenance |
| `src/as_raw.rs` | 2 | ABA, soundness |
| `src/ref_cnt.rs` | 2 | Stacked Borrows |
| `src/access.rs` | 1 | Soundness (CVE) |

## 5. GitHub Issue Analysis

### 5.1 Confirmed Bugs (10)

| Issue | Severity | Status | Root Cause |
|-------|----------|--------|------------|
| #198 | CRITICAL | OPEN | UAF in fallback path; Miri reproducible with seed 3334 |
| #200 | HIGH | OPEN | Formal proof: Debt::pay AcqRel misses SeqCst debt publication |
| #76 | HIGH | Fixed (v1.7.0) | SeqCst on different variables doesn't create cross-variable sync |
| #45/CVE-2020-35711 | CRITICAL | Fixed (v1.1.0) | MapGuard dangling pointer from moved guard |
| PR #186 | MEDIUM | Fixed (v1.8.0) | Pointer provenance wrong on allocation reuse in fast path |
| PR #195 | MEDIUM | Fixed (v1.8.1) | Debt::pay failure ordering Relaxed insufficient for refcount visibility |
| #164 | MEDIUM | Fixed (v1.7.0) | Production crashes in concread/389-ds (likely #76 or #195) |
| #1 | MEDIUM | Fixed | Missing sync edge on group counts (early project) |
| PR #86 | LOW | Fixed (v1.6.0) | Stacked Borrows UB in RefCnt |
| #81 | MEDIUM | OPEN | Nested Option<Option<Arc<T>>> state collapse |

### 5.2 Non-Bugs (2)

| Issue | Classification | Reason |
|-------|---------------|--------|
| #71 | False positive | ThreadSanitizer false positive on Arc drops |
| #75 | User error | Used `const` instead of `static` for ArcSwapOption |

### 5.3 Design Limitations (2)

| Issue | Description |
|-------|-------------|
| #8 | Swap/store not wait-free (only lock-free); documented trade-off |
| #117 | Thread-local nodes never freed; documented trade-off |

## 6. Deep Analysis Findings

### 6.1 Ordering Gaps in Debt Lifecycle

**The Four Critical Operations:**

| Label | Operation | Location | Ordering |
|-------|-----------|----------|----------|
| Op_debt | `slot.0.swap(ptr, SeqCst)` | `debt/fast.rs:58` | SeqCst |
| Op_check | `storage.load(SeqCst)` | `strategy/hybrid.rs:51` | SeqCst |
| Op_swap | `self.ptr.swap(new, SeqCst)` | `lib.rs:483` | SeqCst |
| Op_scan | `slot.0.compare_exchange(ptr, NONE, AcqRel, Acquire)` | `debt/mod.rs:77` | **AcqRel** |

The SeqCst total order S includes Op_debt, Op_check, and Op_swap but NOT Op_scan. The formal argument (from #200):

1. If Op_check reads the old pointer: Op_check < Op_swap in S → Op_debt < Op_swap in S (transitivity via sequenced-before)
2. Op_scan uses AcqRel on `slot`, not SeqCst. Non-SeqCst ops don't participate in S.
3. Therefore Op_scan can observe a stale `NONE` (predating Op_debt) without violating any happens-before chain
4. Result: Writer clears all debts (sees none), frees old Arc → Reader holds dangling pointer

**Fallback path has an additional gap:** `storage.load(Acquire)` at `hybrid.rs:77` instead of SeqCst means even the reader's pointer load doesn't participate in the total order.

### 6.2 Paid-Debt Branch in Fast Path

At `hybrid.rs:58-66`, when the reader's debt was already paid by the writer:
```rust
if debt.pay::<T>(ptr as usize) {
    // We paid it back, it was ours. But the pointer may have
    // changed. Retry.
    None
} else {
    Some(Self::new(ptr as *mut _, None))
    //             ^^^ uses ptr, not confirm
}
```

The `else` branch constructs a `HybridProtection` from `ptr` (the initial Relaxed load at line 44), not from `confirm` (the SeqCst load at line 51). While the debt was already paid (refcount incremented), `ptr` carries provenance from the Relaxed load. If the allocation was freed and reused between the Relaxed and SeqCst loads, `ptr` has wrong provenance. The PR #186 fix addressed the `ptr == confirm` success branch but not this error branch.

**Assessment**: Potential provenance issue but not a safety bug in the current model (the refcount from the writer's payment keeps the allocation alive). However, under strict provenance rules, this could be UB.

### 6.3 Generation Wraparound Panic

In `debt/list.rs:278-286`:
```rust
let gen = local.generation.get().wrapping_add(4);
local.generation.set(gen);
let discard = gen == 0;
// ...
if discard {
    node.start_cooldown();
    self.node.take();  // sets self.node = None
}
```

Then `confirm_helping` at `list.rs:302`:
```rust
pub(crate) fn confirm_helping(&self, ...) -> ... {
    let node = self.node.get().expect("LocalNode::with ensures it is set");
    // PANICS if self.node was taken above
```

On 64-bit: requires ~4.6 × 10^18 fallback loads. Unreachable in practice.
On 32-bit: requires ~1.07 × 10^9 fallback loads. Reachable in long-running apps with heavy contention.

### 6.4 Refcount Accounting in pay_all

Verified correct through exhaustive path analysis:

```
from_ptr(old) → val owns 1 ref
T::inc(&val) → pre-pay, refcount +1
For each paid debt:
  slot.pay succeeds (CAS ptr→NONE)
  T::inc(&val) → pre-pay next, refcount +1
val drops → refcount -1 (reclaims unused pre-pay)
Net: +K for K paid debts (each balanced by reader's eventual drop)
```

The writer's `help` + `pay` sequence on the same reader is also correct: help provides a replacement (separate refcount), pay handles the old pointer's debt (independent increment).

### 6.5 Helping Protocol Correctness

The helping protocol in `debt/helping.rs` uses a multi-phase approach:
1. Reader publishes `active_addr` (SeqCst) and generation in `control` (SeqCst)
2. Writer observes generation, re-reads `active_addr`, re-checks `control` (triple-check protocol)
3. Writer loads replacement from storage, stores in handover envelope
4. Writer CAS-replaces `control` with envelope pointer
5. Reader discovers envelope, reads replacement, stores envelope back in `space_offer`

**Verified correct**: The `control` CAS serializes access. The triple-check protocol prevents stale `active_addr` reads. All handover memory is `'static` (inside leaked `Box<Node>`). Space_offer swaps are properly serialized through the control synchronization point.

### 6.6 Node Lifecycle State Machine

States: `NODE_USED (1)` → `NODE_COOLDOWN (2)` → `NODE_UNUSED (0)` → `NODE_USED (1)`

Transitions verified:
- `USED → COOLDOWN`: Only on generation wraparound, only by owning thread (`list.rs:282-286`)
- `COOLDOWN → UNUSED`: Only when `active_writers == 0` (`list.rs:145-151`)
- `UNUSED → USED`: Only via SeqCst CAS (`list.rs:153-165`)

The `active_writers` counter prevents ABA from generation wraparound: a preempted writer keeps `active_writers > 0`, preventing the node from transitioning through COOLDOWN → UNUSED → USED before the writer finishes.

### 6.7 Cache Module

Fully safe Rust (`#![deny(unsafe_code)]`). Relaxed ordering on staleness check (`cache.rs:164`) is intentional and documented — delayed visibility is a liveness concern, not safety. No TOCTOU issues found.

### 6.8 Access/Map Module

CVE-2020-35711 properly fixed. Current `MapGuard` re-applies projection on every `deref()` (`access.rs:306-307`), never caching a raw pointer. Fully safe Rust.

## 7. Bug Family Classification

### Family 1: Cross-Variable SeqCst Ordering Gaps — 8 bugs (2 open, 6 fixed)
- #200 (open), #198 (open), #76, #164, PR #195, `a2bcd54`, `50f54ca`, `6b644ff`, `6d3ef6d`, `d849a2d`

### Family 2: ABA / Pointer Reuse Races — 5 bugs (all fixed, 1 suspect)
- `e4fbadf`, `00225f5`, PR #186, `7fcaa11`, `343d1f5`
- Suspect: `hybrid.rs:65` (paid-debt branch uses `ptr` not `confirm`)

### Family 3: Generation Counter Wraparound — 1 bug (fixed) + 1 new finding
- `343d1f5` (ABA fix via cooldown)
- New: Panic on wraparound in confirm_helping (32-bit concern)

### Family 4: Soundness Holes — 5 bugs (all fixed)
- #45/CVE-2020-35711, `7a3c506`, `1615477`, `eaeae27`+`97a65cd`+`fd04e20`

## 8. Modeling Suitability Assessment

| Aspect | Score | Reasoning |
|--------|-------|-----------|
| Bug density | High | 19 bug-fix commits, 2 open critical bugs |
| TLA+ suitability | High | Protocol-level concurrency, expressible as interleaving model |
| State space | Medium | Per-thread slots × pointers × refcounts; manageable with small models |
| Ordering modeling | Medium | Need to model the AcqRel gap as non-deterministic miss; not full memory model |
| Expected findings | High | #198 and #200 are model-checkable; the debt protocol hasn't been formally verified |
| Novelty | High | No known TLA+ spec exists for this algorithm; original to arc-swap |

The debt-based hazard pointer mechanism is a prime candidate for TLA+ modeling because:
1. The protocol is abstract enough to express cleanly in TLA+ (slots, pointers, refcounts)
2. The known bugs are ordering issues that TLA+ can find via interleaving exploration
3. The non-deterministic miss model (for the AcqRel gap) is a standard TLA+ pattern
4. The author acknowledges a fundamental rewrite is needed — a TLA+ spec could guide the redesign
