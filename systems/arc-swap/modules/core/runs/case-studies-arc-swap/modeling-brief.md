# Modeling Brief: vorner/arc-swap

## 1. System Overview

- **System**: arc-swap — Rust library for atomically swapping `Arc` pointers with lock-free reads
- **Language**: Rust, ~3,560 LOC core logic (src/)
- **Protocol**: Debt-based hazard pointers for lock-free atomic pointer swap
- **Key architectural choices**:
  - **Debt-based reader tracking** instead of epoch-based reclamation (crossbeam) or RWLock
  - **Two-tier slot system**: 8 fast slots per thread (wait-free) + 1 helping slot (lock-free fallback)
  - **Writer helping**: writers can help readers complete their load by providing a pre-loaded replacement
  - **Cross-variable SeqCst ordering** between debt slots and storage pointer — the core concurrency challenge
- **Concurrency model**: Lock-free/wait-free readers via per-thread debt slots; lock-free writers via atomic pointer swap + debt traversal. All state protected by atomics (no locks in default path). Thread-local debt nodes in an append-only linked list (never freed).

## 2. Bug Families

### Family 1: Cross-Variable SeqCst Ordering Gaps (CRITICAL)

**Mechanism**: The debt system requires coordinating SeqCst operations on *different* atomic variables (debt slots vs. storage pointer). The C++ memory model does NOT guarantee that non-SeqCst operations on one variable observe SeqCst operations on another variable, even when those SeqCst operations are totally ordered. This breaks the fundamental invariant that writers always see reader debts before freeing the old pointer.

**Evidence**:
- Open: #200 — Formal proof that `Debt::pay` at `AcqRel` (`debt/mod.rs:77`) cannot observe SeqCst debt publications on the same slot
- Open: #198 — Miri-reproducible UAF in fallback path; `storage.load(Acquire)` at `hybrid.rs:77` doesn't participate in SeqCst total order
- Historical: #76 — Miri found UAF from same root cause; partial fix in `d849a2d` (upgraded list traversal to SeqCst)
- Historical: PR #195 (`bd5d327`, `cccf354`) — Upgraded `Debt::pay` from Release/Relaxed to AcqRel/Acquire (still insufficient)
- Historical: `6b644ff`, `6d3ef6d`, `d849a2d` — Three rounds of SeqCst upgrades over 3 years, each fixing part of the problem
- Historical: `a2bcd54`, `50f54ca` — Early ordering fixes (2018) for related issues

**Affected code paths**:
- `Debt::pay()` (`debt/mod.rs:65-78`) — writer's debt scan CAS
- `HybridProtection::attempt()` (`strategy/hybrid.rs:42-67`) — reader fast path
- `HybridProtection::fallback()` (`strategy/hybrid.rs:70-97`) — reader fallback path
- `Debt::pay_all()` (`debt/mod.rs:82-115`) — writer's full debt traversal
- `Slots::get_debt()` (`debt/fast.rs:43-65`) — fast slot acquisition

**Suggested modeling approach**:
- Variables: `debtSlots[Thread][Slot]` (pointer or NONE), `storagePtr` (current pointer), `refCount[Ptr]`, `ptrFreed[Ptr]` (boolean)
- Actions: `ReaderAcquireDebt(t)` — write ptr to slot; `WriterSwap(t, newPtr)` — swap storage; `WriterScanDebt(t, slot)` — read debt slot (may see stale NONE); `WriterPayDebt(t, slot)` — CAS debt to NONE + inc refcount; `ReaderConfirm(t)` — re-read storage; `ReaderDropGuard(t)` — pay debt or dec refcount; `WriterFreeOld(t)` — dec refcount (may free)
- **Key**: Model the ordering gap by allowing `WriterScanDebt` to non-deterministically miss a debt that was written before the storage swap. This captures the effect of the AcqRel/SeqCst mismatch without modeling the full memory model.
- Invariant violation: `WriterFreeOld` when `ptrFreed[ptr] = TRUE` while any `debtSlots[t][s] = ptr`

**Priority**: High
**Rationale**: 2 open critical bugs (#198, #200), 6+ historical bugs with the same mechanism, and the author acknowledges a fundamental rewrite is needed. TLA+ can systematically enumerate the interleavings that Miri only finds probabilistically.

---

### Family 2: ABA / Pointer Reuse Races (HIGH)

**Mechanism**: When a pointer is freed and the allocator reuses the same address, comparisons (`ptr == confirm`, CAS expected values) can falsely succeed, causing the reader to operate on a different object than intended, or the writer to pay a debt for the wrong allocation.

**Evidence**:
- Historical: `e4fbadf` — ABA in `compare_and_swap`: `AsRaw` consumed guard before CAS, pointer could be recycled
- Historical: `00225f5` — ABA in `rcu`: closure consumed guard, same ABA window
- Historical: PR #186 (`63fa111`) — Pointer provenance on allocation reuse: fast path used `ptr` (stale provenance) instead of `confirm`
- Historical: `7fcaa11` — "Time travel" ABA in helping strategy due to stale generation
- Code analysis: `hybrid.rs:65` — The "debt was paid" else-branch in `attempt()` still uses `ptr` from the initial Relaxed load, not `confirm`

**Affected code paths**:
- `HybridProtection::attempt()` (`strategy/hybrid.rs:42-67`) — fast path confirmation
- `compare_and_swap()` (`strategy/hybrid.rs:210-237`) — CAS expected value
- `rcu()` (`lib.rs:614-631`) — read-copy-update loop
- `Helping::help()` (`debt/helping.rs:220-290`) — writer helping mechanism

**Suggested modeling approach**:
- Variables: `allocatedPtrs` (set of live pointers), `freedPtrs` (set of freed addresses that can be reused)
- Actions: `Allocate` — may return an address from `freedPtrs`; `Free(ptr)` — moves to `freedPtrs`
- Model pointer identity as (address, generation) pairs; comparisons match on address only
- Key: Check if a reader can operate on a freed-and-reallocated pointer

**Priority**: High
**Rationale**: 4 historical bugs, all fixed but the pattern keeps recurring. The Feb 2025 provenance fix (PR #186) shows this is still actively yielding bugs. One remaining suspect at `hybrid.rs:65`.

---

### Family 3: Generation Counter Wraparound (MEDIUM)

**Mechanism**: The helping strategy uses a per-thread generation counter (incremented by 4, wraps at `usize::MAX`) to distinguish between different reader transactions on the same slot. On wraparound, a writer could confuse an old and new transaction (ABA). The cooldown mechanism prevents this but introduces a panic bug.

**Evidence**:
- Historical: `343d1f5` — Generation overflow ABA fix: added cooldown mechanism with `NODE_COOLDOWN` state and `active_writers` counter
- Code analysis: `list.rs:282-286` + `list.rs:302` — On generation wraparound, `new_helping` sets `self.node` to `None` (cooldown), but `confirm_helping` immediately panics via `.expect()` because it re-reads the (now-None) node
- Code analysis: On 32-bit systems, wraparound occurs after ~10^9 fallback loads per thread (reachable in long-running apps)

**Affected code paths**:
- `LocalNode::new_helping()` (`debt/list.rs:265-289`) — starts cooldown on wraparound
- `LocalNode::confirm_helping()` (`debt/list.rs:296-308`) — panics if node is None
- `HybridProtection::fallback()` (`strategy/hybrid.rs:70-97`) — calls both sequentially

**Suggested modeling approach**:
- Variables: `generation[Thread]` (counter mod GEN_MAX), `nodeState[Thread]` (USED/COOLDOWN/UNUSED), `activeWriters` (count)
- Actions: `ReaderHelping(t)` — increment generation, check wraparound; `StartCooldown(t)` — transition node; `CheckCooldown(t)` — wait for writers; `ReuseNode(t)` — claim unused node
- Invariant: `activeWriters > 0` implies no node in COOLDOWN transitions to UNUSED

**Priority**: Medium
**Rationale**: The ABA protection is correct but the panic on wraparound is a real bug (on 32-bit). TLA+ can verify the cooldown state machine handles all transitions correctly and that the active_writers counter prevents premature reuse.

---

### Family 4: Soundness Holes in Type System Boundaries (LOW for TLA+)

**Mechanism**: Unsafe trait implementations and API design create opportunities for UB when invariants are violated at type-system boundaries. These are Rust-specific issues not suitable for protocol-level TLA+ modeling.

**Evidence**:
- Historical: #45/CVE-2020-35711 — `MapGuard` stored raw pointer, moved guard invalidated it (fixed: re-derive on every deref)
- Historical: #81 — `Option<Option<Arc<T>>>` collapses `None` and `Some(None)` (open, documented)
- Historical: `7a3c506` — Unsealed `AsRaw` trait allowed external UB implementations (fixed: sealed)
- Historical: `1615477` — Guard counter overflow could wrap to 0 (fixed: abort on overflow)
- Historical: `eaeae27`, `97a65cd`, `fd04e20` — Stacked Borrows violations in RefCnt and debt list (fixed)

**Priority**: Low (for TLA+ modeling)
**Rationale**: These are Rust type system / memory model issues, not protocol logic bugs. Better caught by Miri, fuzzing, or code review.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Debt slot lifecycle (acquire, confirm, pay, drop) | Family 1: core mechanism with 2 open bugs | Variables for each slot; split into fine-grained steps |
| Writer debt scan with non-deterministic miss | Family 1: captures AcqRel/SeqCst ordering gap | `WriterScanDebt` can non-deterministically return NONE for a slot that has been written |
| Fast path confirmation pattern | Family 1: the Relaxed-SeqCst-SeqCst triple-check | Model the two loads + debt write as separate actions |
| Fallback/helping path | Family 1: #198 occurs here; separate ordering gaps | Model generation, control slot, handover exchange |
| Pointer allocation and reuse | Family 2: ABA races from allocator reuse | Abstract allocator that can return previously freed addresses |
| Reference counting | Families 1+2: UAF occurs when refcount reaches 0 prematurely | Track refcount per pointer; invariant: refcount > 0 while any debt references it |
| Writer helping mechanism | Families 1+3: complex interaction between writer and reader | Model control slot states, replacement handover |
| Generation counter with wraparound | Family 3: cooldown correctness | Bounded counter with modular arithmetic |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Cache invalidation (`cache.rs`) | Relaxed load is intentional; staleness is a liveness/performance concern, not safety |
| Pin / Weak / Rc support | Type system features with no protocol-level implications |
| Stacked Borrows / provenance | Rust-specific memory model; not expressible in TLA+ |
| Access / Map projection | Fixed CVE; current impl is safe Rust with no unsafe |
| Serialization (serde) | Pure data transformation, no concurrency |
| Thread-local storage details | OS-level concern; model as abstract per-thread state |
| Node linked list append | Append-only, never freed; structurally simple |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Debt slots | `debtSlots[Thread][Slot]` : Ptr ∪ {NONE} | Track reader debts per thread | Family 1 |
| Storage pointer | `storagePtr` : Ptr | Current value in ArcSwap | Family 1 |
| Reference counting | `refCount[Ptr]` : Nat | Track ownership | Family 1, 2 |
| Pointer lifecycle | `ptrFreed[Ptr]` : BOOLEAN | Detect use-after-free | Family 1, 2 |
| Non-det ordering miss | (in WriterScanDebt action) | Model AcqRel gap | Family 1 |
| Pointer reuse | `freedAddrs` : SUBSET Addr | Model allocator ABA | Family 2 |
| Helping state | `controlSlot[Thread]` : {IDLE, Gen, Replacement} | Model helping protocol | Family 1, 3 |
| Generation counter | `generation[Thread]` : 0..GEN_MAX | Wraparound ABA | Family 3 |
| Node state | `nodeState[Thread]` : {USED, COOLDOWN, UNUSED} | Cooldown correctness | Family 3 |
| Active writers | `activeWriters` : Nat | Prevent premature reuse | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoUseAfterFree | Safety | No debt slot references a freed pointer: `∀ t, s: debtSlots[t][s] ≠ NONE ⇒ ¬ptrFreed[debtSlots[t][s]]` | Family 1 |
| RefCountPositive | Safety | If any debt or guard references a pointer, its refcount > 0 | Family 1, 2 |
| DebtImpliesAlive | Safety | Writer cannot free old pointer while any debt slot still references it | Family 1 |
| NoDoubleDecrement | Safety | Reference count never goes below the number of live references | Family 1 |
| WriterSeesAllDebts | Safety | After writer completes scan, all debts on old pointer are paid (violated by Family 1) | Family 1 |
| CooldownProtectsABA | Safety | No node in COOLDOWN transitions to UNUSED while `activeWriters > 0` | Family 3 |
| GenerationUnique | Safety | No two concurrent transactions on the same slot share the same generation value | Family 3 |
| NoPointerReuseBug | Safety | Reader never operates on a freed-and-reallocated pointer believing it's the original | Family 2 |
| ~~WriterSeesAllDebts~~ Liveness | WriterSeesAllDebts as liveness: eventually all debts are paid | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Writer's AcqRel debt scan misses reader's SeqCst debt publication | NoUseAfterFree, DebtImpliesAlive | 1 |
| MC-2 | Fallback path `storage.load(Acquire)` reads stale pointer after writer swap | NoUseAfterFree | 1 |
| MC-3 | Reader uses `ptr` (not `confirm`) in paid-debt branch of fast path (`hybrid.rs:65`) | NoPointerReuseBug | 2 |
| MC-4 | Allocator reuses freed address during CAS comparison | NoPointerReuseBug | 2 |
| MC-5 | Generation wraparound allows writer to confuse old/new transactions | GenerationUnique | 3 |
| MC-6 | Writer helps + pays same reader's debt: double refcount accounting | NoDoubleDecrement | 1 |
| MC-7 | Concurrent writers scanning same reader's debt slot: double pay | RefCountPositive | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T-1 | Generation wraparound panic on 32-bit | Run 10^9+ fallback loads with all fast slots full on 32-bit target |
| T-2 | Nested `Option<Option<Arc<T>>>` state collapse (#81) | Store `Some(None)` then load; verify vs store `None` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Stale comment at `debt/mod.rs:102-103` says "Release is enough" but code uses AcqRel | Update comment |
| CR-2 | `experimental-thread-local` path never runs Drop (nodes leak permanently) | Document as known limitation |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/arc-swap/analysis-report.md`
- **Key source files** (under `artifact/arc-swap/src/`):
  - `strategy/hybrid.rs` — Default strategy, fast path + fallback (238 lines)
  - `debt/mod.rs` — Debt::pay and pay_all (138 lines)
  - `debt/fast.rs` — Fast hazard pointer slots (76 lines)
  - `debt/helping.rs` — Writer helping mechanism (334 lines)
  - `debt/list.rs` — Node linked list and thread-local management (371 lines)
  - `lib.rs` — ArcSwapAny, Guard, store/load/swap/rcu/CAS (1,328 lines)
- **GitHub issues**: #198 (open UAF), #200 (open ordering proof), #76 (fixed ordering), #45/CVE-2020-35711 (fixed soundness), #81 (open nested Option)
- **Key commits**: `bd5d327`+`cccf354` (Debt::pay ordering), `63fa111` (provenance), `343d1f5` (gen overflow), `e4fbadf` (ABA in CAS)
- **Reference**: No formal paper; the algorithm is original to arc-swap's author (vorner). Closest related work: hazard pointers (Michael, 2004) and epoch-based reclamation (crossbeam)
