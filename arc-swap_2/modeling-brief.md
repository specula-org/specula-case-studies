# arc-swap — Modeling Brief

## 1. System Overview

- **Name**: arc-swap (vorner/arc-swap), v1.8.2 + post-1.8.2 commit `d5dd00c`.
- **Language**: Rust; ~4,950 LOC, ~2,200 LOC of concurrency core.
- **Category**: **B (Concurrent / Lock-Free / Runtime)** — sub-category **reader-writer separation** (per `concurrent-analysis.md` § 5 prioritization table). Justification: a single `AtomicPtr<T>` is the shared truth; readers acquire the pointer wait-free via debt-based hazard pointers; writers swap and reclaim by walking per-thread debt slots.
- **Algorithm**: hybrid hazard-pointer protocol with a fast-path (8 fail-fast slots per thread) and a wait-free fallback (helping protocol with generation tagging); ABA on generation wrap is mitigated by per-node cooldown.
- **Key deviations**: not a textbook hazard-pointer scheme — adds a "writer can hand a pre-protected pointer back to a struggling reader" helping path, plus a writer-cooperative cooldown for ABA.
- **Concurrency model**: arbitrary threads; per-thread `LocalNode` in a thread-local; nodes never freed; SeqCst-heavy on the hot path.

---

## 2. Bug Families

### Family A: Cross-variable SeqCst bridge — **HIGH**

**Mechanism**: Two SeqCst operations on different atomic variables only contribute to the single total order over SC events; they do **not** automatically synchronize-with each other. Real correctness depends on a chain `Op1(SC) → Op2(SC) ; Op3(SC) → Op4(SC)` with the right total order; downgrading any single op breaks reclamation.

**Evidence**:
- Historical: #1 (2018), #76 (Miri UAF, 2022), #156 (Miri UAF many seeds, 2025), #164 (production crash 389-ds, 2025), #198 (Miri UAF, 2026), #200 (formal MM proof of UAF, 2026), #204 (CAS failure-leg fix, 2026), PR #195 (Debt::pay failure-ordering fix, 2026). Eight bugs in this family in eight years.
- Code analysis: `strategy/hybrid.rs:51` (fast confirm-load — historically Acquire, now SC), `:78` (fallback candidate-load — fixed in `d5dd00c` to SC), `debt/mod.rs:77` (Debt::pay CAS — both legs now AcqRel/Acquire after `cccf354`), `debt/list.rs:101,179` (LIST_HEAD load/CAS — SC after `d849a2d`).

**Affected paths**: writer's `swap` + `wait_for_readers` + `pay_all`; reader's `attempt` + `fallback` + `confirm_helping` + `Debt::pay` (drop).

**Suggested modeling**:
- **Variables**: `storage_ptr`, per-node `fast_slots[i]`, per-node `helping_control`, `helping_active_addr`, `LIST_HEAD` as a sequence; tag each load/store action with its `Ordering` label (`SC`/`AcqRel`/`Acq`/`Rel`/`Rlx`).
- **Actions**: split each protocol step at the boundary of every atomic op (writer's `Swap`, `LoadHead`, `ScanFastSlot`, `PayCAS`; reader's `LoadCandidate`, `StoreDebtSwap`, `LoadConfirm`, `PayDrop`). Do **not** collapse "load + check + CAS" into one action.
- **Adversary**: `MCRelaxOrdering(site)` non-deterministically downgrades exactly one labeled site under a counter bound. Verify this reproduces #200 / #204.
- **Granularity**: do not collapse SC opps. The model must preserve the SC-total-order property and let the implementation's actual labels enable/disable transitions.

**Priority**: **High** — every confirmed bug in modern history is in this family.

---

### Family B: Allocator-reuse ABA on stored pointer — **MEDIUM**

**Mechanism**: A freed Arc's address is reallocated for a new Arc. Numeric pointer comparison succeeds (`ptr == confirm`), but provenance differs. Defended structurally (a debt holds the refcount above zero), but every change in the fast path risks regression — see `63fa111`.

**Evidence**:
- Historical: `63fa111` ("Fix fast load when allocation is reused").
- Cousin: #200 (theoretical UAF derivation also requires allocator reuse).

**Affected paths**: `strategy/hybrid.rs:42-67` (`HybridProtection::attempt`); secondarily `strategy/hybrid.rs:70-98` (fallback) — both use `confirm` for `T::from_ptr`.

**Suggested modeling**:
- **Variables**: model pointer identity as `<<address, generation>>`. Allocator action `MCAddrReuse` may reuse a freed address with a fresh generation.
- **Actions**: storage swap takes a `<addr, gen>` value; reader's confirm-load returns a `<addr, gen>` pair; equality only on `addr` (matching `ptr_eq`), but invariant tracks `gen`.
- **Invariant**: `NoStaleProtection` — no Guard exists whose `<addr, gen>` is no longer reachable from any currently-stored pointer **or** any in-flight protected slot.

**Priority**: **Medium**.

---

### Family C: Adversarial caller — Guard lifecycle, raw-pointer CAS — **HIGH (gap from prior round)**

**Mechanism**: The library's debt protocol is correct under "guard short-lived, dropped on origin thread" but the API explicitly permits Send across threads, fork via `Guard::into_inner` + `Arc::clone`, drop in any order, and `compare_and_swap` with raw `*const`/`*mut` pointers (potentially stale). The earlier modeling round (`MaxOrderingGaps` / `StaleRead` adversaries) covered writer-internal ordering but **not** the caller harness — exactly the gap that produced 5 bugs in the structurally similar `left-right` case.

**Evidence**:
- Historical: issue #89 (Guard across `.await`), #117 (apparent leak from per-thread retention), #199 (Cache shareability).
- Code analysis (deep-analysis subagent C-section):
  - C1 — Guard fork via `into_inner` (slot accounting)
  - C3 — `compare_and_swap` ABA on raw-pointer caller (`as_raw.rs:60-72` permits stale pointers; documented "pointer comparison" semantics, but undocumented as a hazard for raw callers)
  - C4 — Drop ArcSwap during reader help (caller-precondition; helping-slot identity reuse via `storage as *const _ as usize`)
  - C9 — Send Guard, drop on different thread (debt slot is `&'static`, sound but worth a model)

**Affected paths**:
- `lib.rs:191-193` (`Guard::into_inner`)
- `strategy/hybrid.rs:106-127` (`HybridProtection::Drop`)
- `strategy/hybrid.rs:138-158` (`Protected::into_inner`)
- `lib.rs:506-513` + `strategy/hybrid.rs:217-238` (`compare_and_swap`)
- `as_raw.rs:60-72` (raw pointer impls)
- `lib.rs:614-631` (`rcu` retry loop holding `cur` Guard)

**Suggested modeling**:
- **Variables**: per-thread `local_guards: Bag(GuardId)`; global `guard_owner[g]` may change as guards transfer via Send.
- **Harness actions**:
  - `Load(t)` — t loads, gets a Guard (claims slot in t's node)
  - `IntoInner(t, g)` — t converts g into bare Arc (slot freed)
  - `SendGuard(t1, t2, g)` — Move guard from t1 to t2
  - `DropGuard(t, g)` — t drops g; pays debt
  - `Swap(t)` / `Store(t)` / `Rcu(t)` / `CompareAndSwap(t, current_kind)` where `current_kind ∈ {Arc, Guard, RawPtr, StaleRawPtr}`
- **Invariants**:
  - `NoUseAfterFree`: no Guard exists whose underlying ptr's refcount has reached 0
  - `SlotEventuallyReleased`: every Guard-drop eventually CAS-pays its slot to NONE
  - `CASHasIntendedSemantics`: when `compare_and_swap` reports success with a non-stale `current`, the swap actually replaced the value the caller observed (ABA-safe for `Arc`/`Guard` callers; explicit hazard for raw)
- **Granularity**: keep harness external to the library spec; non-deterministic choice of action sequences. Bound number of guards and number of operations per scenario.

**Priority**: **High** — this is the explicit gap the brief calls out, and the historical `left-right` analog produced multiple confirmed bugs.

---

### Family D: Generation wraparound + cooldown + node reuse — **MEDIUM**

**Mechanism**: Helping-path generation increments by 4. On wrap to 0, the owning thread sends its node into NODE_COOLDOWN and surrenders the node (`self.node.take()`). Other threads can claim the node only after `active_writers` reaches 0 (proof of: every writer that observed the old generation has finished). The reasoning is the most intricate piece of the codebase and depends on a release/acquire chain across `start_cooldown` swap, `NodeReservation::drop`, and `check_cooldown`.

**Evidence**:
- Design block: `debt/helping.rs:54-75` (explicit ABA-protection design), `debt/list.rs:113-138` (`start_cooldown`/`check_cooldown` impl).
- Subtle: `start_cooldown` is `Release`, `check_cooldown` is `Acquire` — should establish the needed edge, but cross-checking would be valuable.

**Affected paths**:
- `debt/helping.rs:191-213` (`get_debt`, generation increment + cooldown trigger)
- `debt/list.rs:113-138` (cooldown state machine)
- `debt/list.rs:151-194` (`Node::get` claim)
- `debt/list.rs:142-145` (`reserve_writer`)

**Suggested modeling**:
- **Variables**: per-node `in_use ∈ {UNUSED, USED, COOLDOWN}`; `active_writers ∈ Nat`; per-node `gen ∈ Nat` (bounded mod K for wrap exposure).
- **Actions**: `ClaimNode(t, n)`, `ReserveWriter(t, n)`, `ReleaseWriter(t, n)`, `StartCooldown(t, n)`, `CheckCooldown(n)`, `BumpGen(t, n)`, `WrapGen(t, n)` (triggers cooldown + take).
- **Invariant**: `NoConcurrentClaim` — at most one thread has `in_use = USED` for a given node; `NoStaleHelpAcrossWrap` — when a node is claimed (UNUSED → USED), no writer is currently in `help` referring to a `gen` that the new owner will recycle.

**Priority**: **Medium** — no confirmed bug here, but the design comment is the longest in the codebase, signaling the maintainer's own uncertainty.

---

### Family E: Writer-scan completeness invariant — **HIGH (companion to A)**

**Mechanism**: After `Debt::pay_all` returns, no slot anywhere should hold the old pointer. This is the "writer drains" invariant that ties the SC bridge family together. Bug #76 violated this invariant via the Acquire/SC cross-variable confusion.

**Evidence**: derived from Family A; same code paths.

**Affected paths**: `debt/mod.rs:82-115` (`pay_all`).

**Suggested modeling**:
- **Invariant**: after `pay_all(old_ptr)` action completes, `\A node \in nodes : \A slot \in node.slots : slot.value # old_ptr`.
- **Action granularity**: `pay_all` is **not** a single action — it must be split per-node and per-slot so the invariant violation is observable when an interleaving misses a freshly-published debt.

**Priority**: **High** — natural top-level safety property.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| **Per-thread program counters** | Family A & C demand split actions at every observable atomic boundary | One PC per thread plus action labels for each atomic op |
| **Pointer identity as `<addr, gen>`** | Family B (allocator reuse ABA) | Tuple variable; reuse action introduces fresh `gen` for same `addr` |
| **All atomic ops labeled with C11 ordering** | Family A relaxation adversary needs labels | Tag each action with `SC`/`AcqRel`/`Acq`/`Rel`/`Rlx`; adversary downgrades one site under bound |
| **`MCRelaxOrdering(site)` adversary** | Reproduces #76, #156, #198, #200, #204 | Non-deterministically pick one labeled site to relax; bound to 1 per execution |
| **Caller harness with Guard lifecycle** | Family C — explicit gap from prior round | Separate spec module: `ClientHarness` with actions `Load`/`SendGuard`/`DropGuard`/`IntoInner`/`Swap`/`Cas(kind)` |
| **`compare_and_swap` with `current_kind`** | Family C — raw-pointer ABA hazard | Action takes flag `Arc/Guard/RawPtr/StaleRawPtr`; only `RawPtr` and `StaleRawPtr` permit ABA window |
| **Node lifecycle state machine** | Family D | UNUSED/USED/COOLDOWN + active_writers counter; bound gen wrap to a small K (e.g. 4-8) |
| **`pay_all` as multi-step action** | Family E — invariant violation hides if collapsed | Split into `LoadHead`, per-node `Reserve`/`ScanFastSlots(n)`/`ScanHelpingSlot(n)`/`ReleaseReservation` |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Full TSO/ARM weak-memory simulation | Per `concurrent-analysis.md` § 5.5: bounded label-downgrade adversary is the right granularity. Full WMM would explode and produce spurious traces. |
| Async cancellation / Future drop | Issue #89 confirms holding Guards across `.await` is safe by design; no cancellation handler |
| OOM allocation failure | Only `Box::leak(Node)` allocates; panics on OOM; not a finite-state target |
| Spurious wakeup | No wait/notify primitives in arc-swap |
| `MapGuard` soundness (#45) | Already fixed (`dfeb84b`); trait-soundness issue, not a concurrent protocol bug |
| `Cache::revalidate` Relaxed staleness (N1) | Documented behavior (cache is best-effort); not a safety bug; would require liveness |
| Nested `Option<Option<Arc<T>>>` semantics (#81) | API design issue, not a concurrent protocol bug |
| `Pin<Arc>`/`Pin<Rc>` provenance tricks in `ref_cnt.rs` | Single-thread soundness (Stacked Borrows compatibility) only; no protocol interaction |
| TSan #71 Linux false positive | Confirmed not a real bug |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| **OrderingLabels** | per-action `ordering: {SC, AcqRel, Acq, Rel, Rlx}` | Express SC vs Acq/Rel happens-before per site | A, E |
| **MCRelaxOrdering** | `relaxed_site` (∈ Sites), bound K=1 | Reproduce historical UAFs (#76/#198/#200/#204) | A |
| **PointerIdentity** | `<<addr, gen>>` for stored pointers; `freed_addrs` set; `MCAddrReuse(addr)` action | Allocator-reuse ABA | B |
| **ClientHarness** | `guards: Bag(GuardId)`, `guard_owner[g]: Thread`, `arcs[a]: Refcount` | Adversarial caller patterns | C |
| **CASCallerKind** | `cas_current_kind ∈ {Arc, Guard, RawFresh, RawStale}` | Distinguish raw-pointer ABA hazard | C |
| **NodeLifecycle** | `in_use[n] ∈ {UNUSED, USED, COOLDOWN}`, `active_writers[n]: Nat`, `gen[n]: Nat mod K` | Cooldown + ABA mitigation | D |
| **PayAllSplit** | `payall_pc[t]: {Idle, AtNode(n,phase)}` | Force pay_all to split per-node so invariant violation is visible | E |
| **HelpingHandover** | `control[n] ∈ {Idle, Gen(g), Replace(env)}`, `active_addr[n]`, `space_offer[n]` | Helping protocol fidelity | A, D |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| **NoUseAfterFree** | Safety | No Guard's underlying Arc has refcount 0 | A, B, C, E |
| **PayAllCompleteness** | Safety | After `pay_all(old_ptr)` action chain finishes, `\A n,s : slot[n][s] # old_ptr` | A, E |
| **NoConcurrentNodeClaim** | Safety | At most one thread has `in_use[n] = USED` simultaneously | D |
| **NoStaleHelpAcrossWrap** | Safety | When node n transitions COOLDOWN → UNUSED → USED-by-new-thread, no writer is mid-`help` for old gen of n | D |
| **SlotEventuallyReleased** | Liveness | Every Guard-drop eventually transitions its slot back to NONE (via Debt::pay or via writer's pay_all) | A, C |
| **CASIntendedSemantics** | Safety | When `compare_and_swap(current, new)` returns success, **either** the storage transitioned through a value pointer-equal to `current.as_raw()` (under `Arc`/`Guard` caller), **or** the caller used a raw stale pointer (documented hazard) | C |
| **NoTornGuardState** | Safety | A Guard observed via `Deref` always points to a value present in the storage at some recent time, not a fabricated address | A, B |
| **NoDoublePay** | Safety | A debt slot is paid at most once per debt-acquisition (no double `T::inc`) | A, E |
| **GenWrapTriggersCooldown** | Safety | Whenever the helping `gen` wraps to 0, the owning node enters COOLDOWN before the next `get_debt` succeeds | D |
| **CooldownReleaseObservesZero** | Safety | A node transitions COOLDOWN → UNUSED only after all writers active during its prior USED phase have called `ReleaseWriter` | D |

Standard concurrent-system invariants (sequential-consistency invariants on linearization order of swap/load) should also be checked for the protocol abstraction without the relaxation adversary, as a sanity baseline.

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC1 | Reader's fast-path confirm-load downgraded SC→Acquire (recreate #76 pre-`6b644ff` state) | NoUseAfterFree | A |
| MC2 | Fallback candidate-load downgraded SC→Acquire (recreate #198 pre-`d5dd00c`) | NoUseAfterFree | A |
| MC3 | `Debt::pay` failure-leg downgraded Acquire→Relaxed (recreate PR #195 pre-state) | NoUseAfterFree | A |
| MC4 | `Debt::pay` success-leg downgraded AcqRel→Release+Acquire failure (#204 pre-`cccf354`) | NoUseAfterFree | A |
| MC5 | LIST_HEAD load relaxed Acquire→Relaxed (#164 family) | PayAllCompleteness | A, E |
| MC6 | Allocator reuses freed pointer address while a reader is mid-fast-path with stale `ptr` (pre-`63fa111`) | NoTornGuardState | B |
| MC7 | Two threads share the same Guard (via Send + race to drop) | SlotEventuallyReleased / NoDoublePay | C |
| MC8 | `compare_and_swap` with raw stale pointer matches a recycled address; reports success | CASIntendedSemantics (with raw-pointer guard relaxed) | C |
| MC9 | Generation wraps without cooldown (model `discard=true` suppressed) | NoStaleHelpAcrossWrap | D |
| MC10 | `pay_all` collapsed to single action (fail to split per-node) — sanity check that splitting is needed | PayAllCompleteness | A, E |
| MC11 | Reader prepends new node mid-writer-scan; verify writer still drains its debt via subsequent CAS chain | PayAllCompleteness | A |
| MC12 | `ArcSwap::Drop` overlapping with reader on dead `&self.ptr` (model documented caller-precondition violation) | None expected (caller-precondition); verify model rejects this trace | C (negative) |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | const_empty `ArcSwapOption` drop with reader holding `None` debt | Add a stress test that loads-and-drops Nones across threads while construction/destruction races; run under miri |
| TV2 | `Cache` shared via `Mutex` actually serves consistent values per-handle | Multi-thread test with mutex-shared Cache; verify per-handle observation rules |
| TV3 | Helper handover envelope reuse across many wraps | Long-running stress test with many wraps; verify no envelope leak (memory growth bounded) |
| TV4 | `compare_and_swap` with intentionally stale raw pointer reports CAS-success on recycled address | Direct unit test demonstrating the documented hazard; should be added to `docs/limitations.rs` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `Cache::revalidate` Relaxed staleness (N1): document liveness contract | Add a clarifying note in `cache.rs:158-168` about the "best-effort revalidate" guarantee |
| CR2 | `compare_and_swap` raw-pointer hazard (C3): document explicitly | Add a §"ABA hazard for raw-pointer callers" to `lib.rs:506-513` doc comment |
| CR3 | `ArcSwap::Drop` reentrant load (N5): document the recursion is safe under `&mut self` Drop | Comment in `lib.rs:337-347` referring to the closure inside `wait_for_readers` |
| CR4 | `Node::get` linked-list traversal: never frees nodes — document that this is intentional and explain memory growth bound | Already covered in `debt/list.rs:6-9` |
| CR5 | Generation wraparound design block (helping.rs:54-75) is the most intricate proof in the codebase — add a TLA+ spec citation once available | Comment-only after spec lands |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/arc-swap_2/.specula-output/analysis-report.md`
- **Source files** (key line ranges):
  - `artifact/arc-swap/src/strategy/hybrid.rs:42-98` — fast attempt + fallback (top of stack for memory-ordering bugs)
  - `artifact/arc-swap/src/strategy/hybrid.rs:200-239` — wait_for_readers + compare_and_swap
  - `artifact/arc-swap/src/debt/mod.rs:65-115` — Debt::pay + pay_all (writer scan)
  - `artifact/arc-swap/src/debt/list.rs:50-205` — LIST_HEAD + Node lifecycle + cooldown
  - `artifact/arc-swap/src/debt/fast.rs:38-66` — fast slot allocation
  - `artifact/arc-swap/src/debt/helping.rs:186-333` — helping/handover protocol
  - `artifact/arc-swap/src/lib.rs:337-347, 477-488, 506-513, 614-631` — ArcSwapAny Drop, swap, compare_and_swap, rcu
  - `artifact/arc-swap/src/cache.rs:148-168` — Cache load/revalidate (out of priority but cross-referenced)
- **Critical fix commits** (read these alongside the source):
  - `bd5d327` — Fix Debt::pay failure ordering (PR #195)
  - `cccf354` — Upgrade the other ordering too, for transitivity (closes #204)
  - `d5dd00c` — Upgrade fallback path storage.load Acquire → SeqCst (closes remaining #198 case)
  - `63fa111` — Fast-path provenance fix (use `confirm` not `ptr`)
  - `d849a2d` — SeqCst on debt-list head (suspected #164 fix)
  - `dfeb84b` — MapGuard soundness fix (#45 / CVE-2020-35711) — out of TLA scope but historical context
- **Critical issues** (read full comment threads):
  - #200 https://github.com/vorner/arc-swap/issues/200 — formal C++ MM proof of UAF
  - #204 https://github.com/vorner/arc-swap/issues/204 — CAS failure-leg ordering
  - #198 https://github.com/vorner/arc-swap/issues/198 — Miri UAF
  - #156 https://github.com/vorner/arc-swap/issues/156 — Miri UAF (long discussion)
  - #76 https://github.com/vorner/arc-swap/issues/76 — Miri data race / UAF (RalfJung input)
- **Reference**: hazard-pointer literature; specifically the helping-path design echoes Paul Khuong's "Flatter Wait-Free Hazard Pointers" (2020) cited at `debt/helping.rs:3`.

---

## Notes for Spec Generation

1. **Action granularity is the lever**, not a parameter. The bug families above stand or fall on whether each atomic op is a separate action. If state-space pressure tempts a coarser granularity, prefer scenario bounds (e.g., 2 readers + 1 writer + bounded swaps) over collapsing actions.

2. **Family A's relaxation adversary should be a separate refinement**, not always-on. The base spec uses the actual SC labels from the implementation; the adversary refines by allowing one site to downgrade. Run both: base verifies "code as written is correct under SC interpretation"; adversary verifies "the SC labels are load-bearing — downgrading any one breaks safety."

3. **Family C's caller harness is external**. Keep the library spec pure (no harness inside it); compose with the harness at top level. This mirrors the case-study pattern from the brief: "earlier round modeled MaxOrderingGaps and StaleRead but did NOT model an adversarial caller."

4. **Generation bound for Family D**: keep K small (4-8) to expose wraparound within a checkable state space. The cooldown logic must execute its full state machine in the model.

5. **Liveness is out of scope** unless explicitly added later. All proposed invariants are safety. The maintainer's own "wait-free" guarantee is performance-bounded but not a TLA-checkable property at this scale.
