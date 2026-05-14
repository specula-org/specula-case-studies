# arc-swap Modeling Brief (Round 4)

## 1. System Overview

- **System**: `arc-swap` — atomically swappable `Arc<T>` for Rust. ~5300 LOC across 17 files; ~1500 LOC of core lock-free logic in `src/debt/{fast,helping,list,mod}.rs` + `src/strategy/hybrid.rs` + `src/lib.rs`.
- **Category**: **B (Concurrent / Lock-Free)**. Sub-category: **reader-writer separation** (per `concurrent-analysis.md` § 5 prioritization). Justification: a single `AtomicPtr<T::Base>` is the publication boundary; readers register debts in per-thread slot nodes; the writer scans all reader slots, paying any debt it finds. There is no message passing, no cluster membership, no disk/network I/O.
- **Algorithm**: Hybrid hazard-pointer protocol. Each thread owns a `Node` in a global lock-free linked list. A `Node` carries 8 *fast* slots (hazard-pointer style: load → store → re-confirm) and 1 *helping* slot (generation-tagged with writer-side help: reader publishes a generation, writer can complete the load on the reader's behalf via a swapped `Handover` envelope). When a generation wraps, the node enters cooldown to defeat ABA.
- **Concurrency model**: Multi-threaded, no async runtime. Thread-local `LocalNode` (via `thread_local!` or `#[thread_local]` under the experimental feature). Writers are lock-free; fast-path readers are wait-free; helping-path readers are lock-free. `wait_for_readers` walks the entire linked list. SeqCst is used at every cross-thread synchronization point (writer swap, head insert, slot store, control swap).
- **Architectural choice that matters for spec**: writer's `swap → wait_for_readers → drop_old` is **three observable steps**. New readers can take debts on the *new* pointer between step 1 and step 2; new readers can prepend a new node into the list between step 2's `LIST_HEAD.load(SeqCst)` and the actual scan reaching that node. Action granularity in the TLA+ spec must reflect all three.

---

## 2. Bug Families

### Family 1: Memory-Ordering Bridges Across Variables (5.5)

**Mechanism**: The protocol's safety requires a single SeqCst total order across at least four variables: (a) writer's `storage.swap` (`lib.rs:485`), (b) `LIST_HEAD.compare_exchange` (`list.rs:188`), (c) reader's debt-store (`fast.rs:58`, `helping.rs:210`/`316`), (d) reader's confirm-load (`hybrid.rs:52` for fast path, `hybrid.rs:83` for fallback). Any single weakening downgrades a cross-variable bridge into a single-location coherence claim and silently breaks the safety argument.

**Evidence**:
- Historical (closed): #195 / commit `bd5d327` — `Debt::pay` failure ordering upgraded `Relaxed → Acquire`. #204 / `cccf354` — extended that to `AcqRel` for transitivity. #200 / #198 / PR #203 / `d5dd00c` — fallback `storage.load` upgraded `Acquire → SeqCst` (added regression test `tests/fallback_uaf.rs`). #164 / `d849a2d` — `LIST_HEAD` and `Node::get` CAS upgraded to `SeqCst, SeqCst`.
- Code (current): stale comments at `helping.rs:268, 270` say "Relaxed is fine" while the code is now `SeqCst` (post-`6d3ef6d`). Spec authors who read the docstring rather than the code will mis-model this.

**Affected code paths**: `swap` / `compare_and_swap` (`lib.rs:479`, `hybrid.rs:227`); fast path `attempt` (`hybrid.rs:42`); fallback `fallback` (`hybrid.rs:75`); `pay_all` (`mod.rs:82`); `Node::traverse` and `Node::get` (`list.rs:93`, `list.rs:158`); `helping::get_debt` / `confirm` / `help` (`helping.rs:191`, `312`, `219`).

**Suggested modeling approach**:
- **Variables**: model each store/load with the exact ordering label currently used. Track per-variable C11 mod-orderings explicitly.
- **Actions**: split each CAS into `LoadOld → CAS` so the reader confirm and the writer swap can interleave at the right granularity.
- **Granularity**: model the writer's `storage.swap` and `wait_for_readers` as separate actions. Do not collapse.
- **Sensitivity check** (per § 5.5): one separate hunt config that downgrades the fallback `storage.load` from SeqCst to Acquire is allowed *as a robustness check*, but counterexamples are sensitivity findings, not implementation bugs.

**Priority**: **High** — this is the densest historical bug area (4 fixes in 16 months) and the entire SeqCst-everywhere design has been evolving. The spec must lock down the *current* labels and confirm the safety argument under them.

---

### Family 2: Caller Misuse / Adversarial Client (5.7) — *new in this round*

**Mechanism**: A `Guard` holds a fast-slot debt or refcount and is `Send` — the caller can move it across thread boundaries, hold it across arbitrarily long await points (in async runtimes that move tasks between worker threads), drop it out of order relative to other guards, or fork it via `Arc::clone(&*g)` + `Guard::from_inner` (`lib.rs:212`). The library asserts safety regardless. Earlier rounds modeled `MaxOrderingGaps` and `StaleRead` adversaries; this round focuses on **adversarial caller behavior interleaved with concurrent writers**.

**Evidence**:
- Historical (closed): #89 — holding Guard across await is documented as legal-but-slow. #45 (CVE-2020-35711) — `MapGuard` projection lifetime hole (closed in 1.1.0). #117 — per-thread node leak (acknowledged design tradeoff). #88 — out-of-scope adversarial use was rejected by maintainer.
- Code (current): `Guard::from_inner` (`lib.rs:212`) constructs a debtless guard from any `Arc`. `HybridProtection::Drop` (`hybrid.rs:119-141`) has two branches (debt paid by us / debt paid by writer). `pay_all` (`mod.rs:82-121`) walks the writer's *own* node too; the writer's local guard `old` (`hybrid.rs:239`) can have its debt paid from inside `wait_for_readers` (`hybrid.rs:254`).

**Affected code paths**: `Guard::from_inner` and `Guard` `Send`/`Sync` impls; `HybridProtection::{Drop, into_inner}`; `compare_and_swap` (`hybrid.rs:227-263`) where the writer holds its own debt-protected `old` while running `wait_for_readers`.

**Suggested modeling approach**:
- **Variables**: per-thread `Guards: Set` of (slot_id, ptr_observed, debt_paid_by_writer flag).
- **Actions**: `ClientHarness` action set (per § 5.7) — `MCSpawn(parent, child)` to fork a guard via `from_inner`; `MCMoveGuard(t1, t2)` to send a guard across threads; `MCDelayDrop(g)` to defer drop arbitrarily; `MCInterleavingDrop(g1, g2)` to drop in a non-natural order.
- **Granularity**: each guard's lifecycle (`Acquire → Hold → Drop`) is split, with an arbitrary number of `Hold` steps in between during which any number of writer swaps can occur.
- **Invariant**: every fast-slot or helping-slot debt is either still owned by an alive Guard, or has been paid by a writer (refcount bumped). No orphaned debt; no double-pay.

**Priority**: **High** — this is the requested coverage gap. The structurally-similar `left-right` system produced 5 bugs against the same family. arc-swap's larger debt mechanism (8 fast slots + 1 helping slot per thread, recursive load via `replacement` closure inside `pay_all`) provides more interleaving surface, not less.

---

### Family 3: Stale Snapshot in Writer's Debt-List Traversal (5.5 + 5.6)

**Mechanism**: `pay_all` snapshots the global `LIST_HEAD` at `list.rs:102` (SeqCst) and then walks `node.next` (plain pointer reads). New threads prepend nodes via SeqCst CAS at `list.rs:188`. A node prepended *after* the writer's load is invisible to that writer's scan. Safety hinges on the four-variable SeqCst total order: any reader on a missed node must have started its load *after* the writer's swap, hence its `confirm` re-read sees the new pointer and the reader either takes a debt on the new pointer (which the *next* writer pays) or falls back into `helping`. **This is precisely the BUG-A-shaped finding from `left-right` that motivated this round.**

**Evidence**:
- Historical (closed): #200 / #198 — the fallback path was previously `Acquire` and could let a stale reader hold a debt on a freed pointer. The fix `d5dd00c` is the most recent edit to the file (`hybrid.rs:83`). The same pattern still exists in the fast path — under SeqCst it is correct, but it has never been formally model-checked end-to-end.
- Code (current): `Node::traverse` (`list.rs:93-112`); `Node::get` prepend (`list.rs:178-202`); `swap` (`lib.rs:485`); fast confirm (`hybrid.rs:52`); fallback candidate-load (`hybrid.rs:83`).

**Affected code paths**: `Debt::pay_all`, `Node::traverse`, `Node::get`, fast attempt, fallback.

**Suggested modeling approach**:
- **Variables**: `linkedListHead` (the head pointer); per-node `next` (immutable after publication); per-node `slots` (fast + helping); `pendingPublish: Set` of nodes that exist but haven't been linked yet.
- **Actions**: split `Node::get` into `AllocateNode → SetNext → CASListHead`. Split reader's `attempt` into `LoadFirst → ClaimSlot → LoadConfirm`.
- **Granularity**: writer's `pay_all` is a multi-step iteration — `LoadHead → ScanNode_i → AdvanceNext`. Each `ScanNode_i` is its own action; a new node can prepend between any two of them, but the writer should not back up.
- **Invariant** (`StaleSnapshotSafety`): if writer freed `old` after `pay_all`, no reader holds a debt on `old`. Equivalently: every reader-node visible-to-the-system at the time of `freeOld` was either scanned by `pay_all` or holds a debt on the *new* value.

**Priority**: **High** — directly mirrors the BUG-A finding from left-right; the action-granularity audit (Family 5 below) is the lever that exposes it.

---

### Family 4: Generation Wraparound + Cooldown ABA Window (5.6)

**Mechanism**: The helping path's `get_debt` (`helping.rs:191-217`) increments a per-thread generation by 4 (`wrapping_add(4)`). When the result is exactly `0`, `discard` is set, and the caller (`new_helping`, `list.rs:288-298`) calls `node.start_cooldown()` and `self.node.take()`. Cooldown blocks reuse until `active_writers == 0`. Concern: `check_cooldown` (`list.rs:125-145`) does an Acquire load on `in_use` and a Relaxed load on `active_writers`. The Relaxed load is justified by the argument that `start_cooldown`'s self-reservation Drop happens-before the COOLDOWN swap is observable — but `start_cooldown` does the reservation Drop *after* the COOLDOWN swap (`list.rs:115-120`), so the chain is via `active_writers`'s coherence order, not happens-before. A racing writer's `fetch_add(Acquire)` on `active_writers` (`list.rs:149`) may not synchronize-with the start-cooldown's `fetch_sub(Release)`.

**Evidence**:
- Historical: commits `343d1f5` (introduced the wraparound mitigation), `d849a2d` (#164 — debt-list CAS upgraded to SeqCst-on-failure to mitigate a suspected crash; reporter never confirmed). Comments at `helping.rs:54-71` explicitly document the ABA risk and the cooldown mitigation.
- Code (current): `start_cooldown` (`list.rs:115-120`); `check_cooldown` (`list.rs:125-145`); `reserve_writer` (`list.rs:148-152`); `NodeReservation::Drop` (`list.rs:54-58`).

**Affected code paths**: cooldown lifecycle (`list.rs:115-145`); generation wraparound (`helping.rs:193-216`); `LocalNode::new_helping` (`list.rs:288-298`).

**Suggested modeling approach**:
- **Variables**: per-node `nodeState ∈ {UNUSED, USED, COOLDOWN}`; per-node `activeWriters: Nat`; per-node `inflightHelp: SUBSET Threads` (writers currently holding a `_reservation` against this node); per-thread `generation: Nat` (bounded for state space, e.g. 0..8).
- **Actions**: `MCStartCooldown(t, n)`, `MCCheckCooldown(t, n)`, `MCReserveWriter(t, n)`, `MCDropReservation(t, n)`, `MCClaimNode(t, n)`. Each action writes only the variables it touches; ordering of `activeWriters` decrement vs `nodeState=COOLDOWN` set is a separate scheduling choice.
- **Bound**: small `MaxGenerations = 8` (the trace constant in the existing `tla_trace.rs`) makes wrap reachable in BFS.
- **Invariant** (`CooldownDrainSafety`): when a node transitions COOLDOWN→UNUSED, `inflightHelp(n) = ∅`. If this fails, an old `help` context can offer a stale-typed pointer to a new reader — exactly the ABA scenario the cooldown is designed to prevent.

**Priority**: **High** — this is bug family 4 from the prompt, and the safety argument is *not* trivial. The Relaxed load + Release/Acquire chain is the kind of bridge that has historically been wrong (Family 1 has 4 prior fixes against weakenings).

---

### Family 5: Action Granularity Audit — `new_helping`/`confirm_helping` Split (5.1) — *new code-review finding*

**Mechanism**: When `discard = (gen == 0)` triggers in `helping::get_debt` (`helping.rs:197`), the local generation has already been bumped, the helping slot's `active_addr` has been written, and `control` has been swapped to `gen | GEN_TAG` (`helping.rs:203, 210`). `LocalNode::new_helping` then calls `node.start_cooldown()` + `self.node.take()` (`list.rs:295-296`). Immediately afterward, the caller (`HybridProtection::fallback` at `hybrid.rs:88`) calls `node.confirm_helping(...)`, which begins with `let node = &self.node.get().expect("LocalNode::with ensures it is set");` (`list.rs:312`). After `take()`, `self.node.get()` is `None` — `expect()` panics. Furthermore, the helping slot's `control` is left in `gen | GEN_TAG` state; the next claim of this node would assert `IDLE == prev` in `get_debt` and panic again. The node is effectively poisoned.

**Evidence**:
- Code (current, this run): `helping.rs:191-217` (`get_debt` writes control before computing discard); `list.rs:288-298` (`new_helping` takes node when discard is true); `list.rs:312` (`confirm_helping` immediately re-reads `self.node`).
- Historical: commit `08efd1f` ("Hybrid debt reservation: split the check") split the previously-atomic acquire into two steps for performance. The original (`343d1f5`) had no separation issue because cooldown was triggered atomically with slot acquisition.
- Triggering: requires `2^62` calls to the fallback path on a single thread (64-bit) or `2^30` (32-bit). Practically unreachable, but real.

**Affected code paths**: `LocalNode::new_helping`, `LocalNode::confirm_helping`, `helping::get_debt`.

**Suggested modeling approach**:
- **Variables**: per-thread `localNode: Option(NodeId)`; per-thread `pendingHelpingTransaction: Option(Gen)`.
- **Actions**: split into three: `MCBeginHelping(t)` (writes control, may set discard), `MCDiscardNode(t)` (only if discard, sets node to cooldown and clears localNode), `MCConfirmHelping(t)` (requires localNode = Some; reads slot).
- **Granularity decision**: this is exactly the kind of split-step where 5.1 (Thread Interleaving) exposes bugs. With small `MaxGenerations`, a configuration where wrap occurs *during* a fallback call is reachable in BFS.
- **Invariant** (`NoDanglingTransaction`): if `pendingHelpingTransaction(t) = Some(_)`, then `localNode(t) ≠ None` and the slot's control matches the pending generation. The bug: the implementation can satisfy `pendingHelpingTransaction(t) = Some(_) ∧ localNode(t) = None`.

**Priority**: **Medium** — the practical reachability is essentially nil, but it is a real correctness bug with a clear modeling target, and is exactly the action-granularity audit (Family 5 from the prompt). Worth modeling as a demonstration that the split-step pattern catches real bugs even in well-reviewed code.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Adversarial caller harness (Guard fork, cross-thread move, delayed drop) | Family 2 — primary coverage gap from prior round | `MCSpawn`, `MCMoveGuard`, `MCDelayDrop` actions on top of existing reader/writer model |
| Split writer into `Publish → Scan → Free` actions | Families 3, 5 — exposes BUG-A-shape stale snapshots | Three sequential actions with arbitrary interleavings of new readers in between |
| Split `new_helping → confirm_helping` into separate actions | Family 5 — exposes panic-on-wrap | Three actions: `BeginHelping`, `DiscardNode` (conditional), `ConfirmHelping` |
| Cooldown lifecycle as separate state machine | Family 4 — Relaxed/Acquire bridge across `active_writers` and `in_use` | `nodeState`, `activeWriters`, `inflightHelp` per node; transitions guarded by ordering labels |
| Per-variable C11 ordering labels | Family 1 — model the *current* SeqCst saturation | Annotate every load/store; `MCWeakenOrder(label)` only as a separate sensitivity hunt |

### 3.2 Do Not Model

| What | Why |
|---|---|
| `Cache::revalidate` Relaxed staleness (`cache.rs:158`) | Documented behavior — Cache is explicitly stale-tolerant. Code-review-only. |
| Two-layer `Option<Option<Arc<T>>>` collision (#81) | Maintainer reclassified: cannot trigger UB without a custom `unsafe` `RefCnt` impl. Out of safety scope. |
| `MapGuard` projection lifetimes (#45) | Closed CVE; fix is type-system-level. Not a protocol-level modeling target. |
| Stale doc comments at `helping.rs:268-273` | Code-review-only nit; comments are stale post-`6d3ef6d`. Docs fix, not a spec target. |
| Recursive load in `replacement` closure | After re-verification, recursion always re-enters with a *different* `who` than `self`; the public-API contract on the closure is not exposed. Code-review-only. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| `ClientHarness` | `guardSet[t]`, `delayedDrop[t]`, `forkedGuards` | Drive arbitrary legal call sequences | F2 |
| `WriterStages` | `writerPC[t] ∈ {Idle, Published, Scanning, Freed}` | Split writer into observable steps | F3, F5 |
| `HelpingTransaction` | `pendingHelpingTx[t]`, `localNode[t]: Option(NodeId)` | Capture new_helping/confirm_helping split | F5 |
| `CooldownLifecycle` | `nodeState[n]`, `activeWriters[n]`, `inflightHelp[n]: SUBSET Threads` | Cooldown drain semantics | F4 |
| `MemoryOrderLabels` | per-load/store `order ∈ {Relaxed, Acquire, Release, AcqRel, SeqCst}` | Faithful to current code; sensitivity hunts opt-in | F1 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `NoUseAfterFree` | Safety | If writer freed `old`, no reader holds a debt or refcount on `old`. | F1, F3 |
| `NoOrphanedDebt` | Safety | Every fast-slot or helping-slot debt is either alive on a live Guard, paid by a writer, or returned via `Drop`. No leaked debts. | F2 |
| `StaleSnapshotSafety` | Safety | At the moment writer drops the last refcount of `old`, every reader-node existing in the system was either scanned by `pay_all` or holds debt on a strictly-newer pointer. | F3 |
| `CooldownDrainSafety` | Safety | A node transitioning COOLDOWN→UNUSED has `inflightHelp(n) = ∅`. | F4 |
| `NoDanglingTransaction` | Safety | `pendingHelpingTx[t] = Some(g) ⇒ localNode[t] ≠ None ∧ slot.control[t] matches g`. | F5 |
| `RefCountAccounting` | Safety | Sum of (storage refcount + per-Guard refcount + per-paid-debt refcount) equals total live refcount of any pointer. | F1, F2 |
| `WaitForReadersTermination` | Liveness | `wait_for_readers` eventually completes (bounded under fixed reader/writer counts). | F4 (cooldown stalls) |
| `EventualVisibility` | Liveness | After `swap`, some load eventually returns the new pointer. | F1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Adversarial caller forks Guard via `from_inner`, holds across multiple `swap`s, drops in reverse order; can the writer's debt accounting ever go negative or skip? | `NoOrphanedDebt`, `RefCountAccounting` | F2 |
| MC2 | New reader prepends a node and writes a debt on `old` *between* the writer's `LIST_HEAD.load(SeqCst)` and the writer's call to `T::dec(old)` at the very end of `wait_for_readers`. | `NoUseAfterFree`, `StaleSnapshotSafety` | F3 |
| MC3 | Sensitivity check: downgrade fallback `storage.load` from SeqCst to Acquire (counterfactual to the upstream fix `d5dd00c`); confirm the model exhibits the documented UAF. *This is a sensitivity / robustness check — counterexample is expected, treated as confirmation of the spec, not a new bug.* | `NoUseAfterFree` | F1 |
| MC4 | Cooldown lifecycle: a writer's `reserve_writer` arrives just after `start_cooldown`'s self-reservation Drop has decremented `active_writers` to 0 but before the COOLDOWN store is visible to a *third* thread's `check_cooldown`. Can a third thread claim the node while this writer holds an `inflightHelp` context referring to the previous generation? | `CooldownDrainSafety` | F4 |
| MC5 | Generation wrap during fallback: forced `discard = true`; immediate `confirm_helping` panics due to `self.node = None`; *this is a panic, not a safety violation, but the model should expose the unreachable-state assertion.* Reachable on 32-bit machines after `2^30` fallback calls. | `NoDanglingTransaction` | F5 |
| MC6 | Concurrent `compare_and_swap` from N threads: each holds a debt-protected `old` while running `wait_for_readers`; their `pay_all` walks each others' nodes. Verify no interleaving produces double-pay (refcount over-incremented) or missed-pay (refcount under-incremented). | `RefCountAccounting` | F2, F3 |

Note on closed-bug reproductions: per `bug-archaeology.md` §1.4, MC3 is included only as a **sensitivity / robustness check** — re-deriving the UAF that PR #203 already fixed produces no information beyond `git revert d5dd00c && cargo test`. It is here to confirm the spec is faithful enough to expose a known-bad ordering, not as a new finding.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Cache::revalidate freshness on weakly-ordered hardware | ARM-specific stress test where writer stores once and reader's Cache::load is checked across many iterations |
| T2 | Recursive `replacement` closure does not exceed bounded stack depth under generation-wrap pressure | Targeted test forcing wrap on a 32-bit target |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | Stale comments at `helping.rs:268, 270` claim "Relaxed is fine" while code is `SeqCst` (post-`6d3ef6d`) | Update comments to match code (or revert to Relaxed if perf-justified, with proof) |
| C2 | `confirm` comment at `helping.rs:313-315` claims "Release is to make sure control is observable" but the swap is SeqCst | Reconcile docstring with code |
| C3 | `Node::traverse`'s reliance on `node.next` being immutable-after-publish (`list.rs:69-72`) is sound but undocumented at the call site (`list.rs:109`) | Add a comment cross-referencing the publication invariant |
| C4 | `HybridProtection::Drop` (`hybrid.rs:119-141`) silently changes the meaning of `self.ptr` between the two branches; brittle to refactor | Extract the "owned ref / no owned ref" distinction into a typed enum |
| C5 | `replacement` closure in `wait_for_readers` is a hardcoded contract baked into a closure expression (`hybrid.rs:222`); future refactors that expose the closure are unsafe by construction | Document the closure contract explicitly, or wrap it in a private trait |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/arc-swap_4/.specula-output/analysis-report.md`
- **Core source files**:
  - `src/lib.rs:319-516` (ArcSwapAny, swap, compare_and_swap, rcu, Drop, into_inner, load)
  - `src/strategy/hybrid.rs:42-263` (attempt, fallback, wait_for_readers, compare_and_swap)
  - `src/debt/mod.rs:48-122` (Debt::pay, Debt::pay_all)
  - `src/debt/list.rs:88-204` (Node::traverse, start_cooldown, check_cooldown, Node::get)
  - `src/debt/list.rs:218-343` (LocalNode methods incl. new_helping/confirm_helping)
  - `src/debt/fast.rs:38-67` (Slots::get_debt)
  - `src/debt/helping.rs:191-339` (Slots::get_debt, help, confirm)
  - `src/cache.rs:148-168` (Cache::load, revalidate)
- **Recent fixes (do not re-derive — already in mainline)**:
  - `d5dd00c` — fallback `storage.load` Acquire → SeqCst (#198, #200, PR #203)
  - `cccf354` — `Debt::pay` `Release → AcqRel` for transitivity (#204)
  - `bd5d327` — `Debt::pay` failure ordering Relaxed → Acquire (#195)
  - `63fa111` — fast `attempt` provenance fix: use `confirm` not `ptr` (#186, #156)
  - `d849a2d` — debt-list CAS SeqCst on failure (#164 mitigation)
- **Open issues that are NOT modeling targets**:
  - #81 — two-layer Option (non-soundness, requires custom `unsafe` `RefCnt`)
  - #117 — per-thread node leak (acknowledged design tradeoff)
  - #94 / #90 — API/UX feature requests
  - #194 — None-load optimization (perf, not correctness)
- **Pre-existing TLA+ infrastructure**: `src/tla_trace.rs` (865 LOC) emits trace events at every observable boundary — `emit_writer_swap`, `emit_writer_traverse_load`, `emit_reader_fast_*`, `emit_reader_fallback_*`, `emit_writer_pay_init`/`pay_done`, `emit_check_cooldown`, etc. Use these for trace-validated spec.
- **Reference algorithm**: hazard-pointer protocol (Maged Michael 2004); flatter wait-free hazard pointers (Khyzha-Vechev style — see comments at `helping.rs:1-7` referencing https://pvk.ca/Blog/2020/07/07/flatter-wait-free-hazard-pointers/).
