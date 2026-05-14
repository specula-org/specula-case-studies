# arc-swap Analysis Report (Round 4)

Detailed audit trail backing the `modeling-brief.md`. Covers Reconnaissance, Bug Archaeology, Deep Analysis, and the synthesis decisions.

---

## Phase 0 — Classification

**Category**: B (Concurrent / Lock-Free).

**Sub-category**: Reader-writer separation (per `concurrent-analysis.md` § 5).

**Justification**: Single `AtomicPtr<T::Base>` is the publication boundary. Readers register debts in per-thread slot nodes; writers atomically swap the pointer and then walk all reader slots paying outstanding debts. No message passing, RPC, or persistence. Maps to the same pattern as `left-right`, `crossbeam-epoch`.

---

## Phase 1 — Reconnaissance

### Repository scale

| File | LOC | Role |
|---|---|---|
| `src/lib.rs` | 1331 | `ArcSwapAny`, `Guard`, public API, swap/compare_and_swap/rcu, Drop |
| `src/strategy/hybrid.rs` | 263 | `HybridProtection::{attempt, fallback}`, `compare_and_swap`, `wait_for_readers` |
| `src/strategy/mod.rs` | 168 | `Strategy` trait, `DefaultStrategy` alias |
| `src/strategy/rw_lock.rs` | 63 | RwLock fallback strategy (test only) |
| `src/debt/mod.rs` | 144 | `Debt::{pay, pay_all}` |
| `src/debt/list.rs` | 381 | Lock-free linked list of `Node`s, cooldown, `LocalNode` |
| `src/debt/helping.rs` | 339 | Helping-slot protocol (generation-tagged, envelope-passed handover) |
| `src/debt/fast.rs` | 77 | Fast hazard-pointer-style slots (8 per node) |
| `src/cache.rs` | 343 | `Cache` (stale-tolerant cached pointer) |
| `src/access.rs` | 543 | `Access`/`Map` projection trait |
| `src/ref_cnt.rs` | 338 | `RefCnt` trait — Arc / Rc / Pin<Arc> implementations |
| `src/weak.rs` | 118 | `ArcSwapWeak` |
| `src/tla_trace.rs` | 865 | Pre-existing trace-emission infrastructure for spec validation |

Total: ~5300 LOC, with **~1500 LOC of core lock-free logic**.

### Concurrency model

- Multi-threaded, no async runtime.
- Thread-local per-thread `LocalNode` via `thread_local!` (or `#[thread_local]` under `experimental-thread-local`).
- Writers are lock-free; fast-path readers are wait-free; helping-path readers are lock-free under generation collision.
- All cross-thread atomics use SeqCst at synchronization points (post-`6d3ef6d`, `d849a2d`, `d5dd00c`).

### Atomicity boundaries

| Operation | Granularity in code | Granularity in spec must be |
|---|---|---|
| Reader fast load | `attempt` (`hybrid.rs:42-72`) — load Relaxed, claim slot SeqCst, re-load SeqCst | 3 actions: LoadFirst, ClaimSlot, LoadConfirm |
| Reader fallback | `fallback` (`hybrid.rs:75-111`) — new_helping, candidate-load SeqCst, confirm_helping | 3+ actions: BeginHelping, LoadCandidate, ConfirmHelping (potentially Discard before Confirm) |
| Writer publish | `swap(new, SeqCst)` (`lib.rs:485`) | 1 atomic action |
| Writer scan | `pay_all` (`mod.rs:82-121`) | iterating action: per-node ScanNode_i, advancing through linked list |
| Writer free | `T::dec(old)` after `pay_all` returns | 1 action |
| Cooldown | `start_cooldown` (`list.rs:115-120`) + `check_cooldown` (`list.rs:125-145`) | 2 actions — split-step on `in_use` and `active_writers` |

The pre-existing `tla_trace.rs` already emits events at most of these boundaries (`emit_writer_swap`, `emit_writer_traverse_load`, `emit_writer_pay_init`, `emit_writer_help_node`, `emit_writer_scan_slot`, `emit_writer_pay_done`, `emit_check_cooldown`, `emit_reader_fast_*`, `emit_reader_fallback_*`).

---

## Phase 2 — Bug Archaeology

### Coverage statistics

- **Total commits in repo**: 434.
- **Bug-fix commits touching `src/`**: ~50 reviewed; analyzed in detail (full `git show`): 8 most-recent + 5 architectural commits = **13 commits read in full**.
- **GitHub issues collected**: 60 listed. **Deeply read with full discussion threads (via `gh issue view --comments`)**: **20 issues + 2 PRs** (#1, #45, #71, #75, #76, #81, #88, #89, #90, #94, #117, #118, #150, #156, #164, #194, #196, #198, #200, #204, PR #195, PR #186).
- **Confirmed bugs (already fixed in mainline)**: 6 — #1, #45, #156/#186, #195, #200/#198, #204.
- **Confirmed open issues that are not modeling targets**: 4 — #81 (non-soundness), #117 (design tradeoff), #94/#90 (API/UX).
- **False positives / user error**: 4 — #71, #75, #88, #196.
- **Inconclusive / suspicion-only**: 1 — #164 (defensive fix landed but reporter never confirmed).

### Recent bug-fix commits (chronological, most-recent first)

| Commit | Title | Component | Severity | Mechanism |
|---|---|---|---|---|
| `d5dd00c` | fix: upgrade fallback path storage.load from Acquire to SeqCst | `hybrid.rs:83` | **Critical** (UAF) | Memory ordering (cross-variable bridge) |
| `cccf354` | Upgrade the other ordering too, for transitivity | `mod.rs:77` | High | Memory ordering transitivity |
| `bd5d327` (PR #195) | Fix Debt::pay failure ordering | `mod.rs:65-79` | High | Memory ordering (failure case) |
| `63fa111` (PR #186) | Fix fast load when allocation is reused | `hybrid.rs:42-72` | High (UB on reuse) | Provenance |
| `d849a2d` | Use SeqCst in debt-lists | `list.rs:166, 188` | Defensive (no confirmed report) | Memory ordering |
| `add0945` | hybrid/helping: Proofs about orderings, reviews of orderings | `helping.rs` | Refactor | Documentation |

### GitHub issues / PRs deeply audited

| ID | Title | Status | Mechanism | Notes |
|---|---|---|---|---|
| #1 | Missing synchronization edge | CLOSED 2018 | Pre-hybrid lock counts | Self-reported by author; long-fixed |
| #45 | MapGuard dereferences to a dangling pointer (CVE-2020-35711) | CLOSED 1.1.0 | Projection lifetime | Closed CVE; fix in current code |
| #71 | Data race reported by thread sanitizer | CLOSED | False positive on TSan | Not a code bug |
| #75 | Const ArcSwapOption doesn't update | CLOSED | User error (Rust `const`) | Documented trap |
| #76 | Data race / UAF reported by Miri | CLOSED 2025 | Helping path, multi-writer | Subsumed by #156/#186/#195/#200 series |
| #81 | Two-layer Option folded | OPEN | Two-layer Option semantics | Maintainer reclassified: not unsoundness without custom unsafe RefCnt |
| #88 | How to implement concurrent hashmap | CLOSED | Out of scope | User question |
| #89 | Non-full loads across awaits | CLOSED | Async safety, Guard across await | Documented as legal; just slow |
| #90 | Guard<Option<Arc<T>>> → Option<Guard<Arc<T>>> | OPEN | Projection ergonomics | Feature request |
| #94 | try_rcu / fallible RCU | OPEN | API ergonomics | Feature request |
| #117 | Memory leaks? | OPEN | Per-thread node leak | Acknowledged design tradeoff (`uninit` Cargo feature proposal) |
| #118 | OK to use ArcSwap in async | CLOSED | Async safety | Question; explained |
| #150 | Confused docs about lock-freedom | CLOSED | Documentation | Doc fix |
| #156 | Miri detects UB in test-suite | CLOSED 2025-12 | Provenance + ordering | Fixed by PR #186 (`63fa111`) |
| #164 | Race in Debt Payment | CLOSED 2025-12 | Suspected ordering | Defensive fix `d849a2d`; reporter never confirmed |
| #194 | None-pointer load not optimized | OPEN | Performance | Maintainer warns optimization must preserve SeqCst promise |
| #195 (PR) | Fix Debt::pay failure ordering | MERGED 2026-01 | Memory ordering | Author 0xfMel; merged |
| #196 | Tests failing in CI | OPEN | CI tooling | Not a library bug |
| #198 | UAF detected by miri | CLOSED 2026-03 | Fallback ordering | Fixed by `d5dd00c` |
| #200 | Theoretical UAF from missing SeqCst | CLOSED 2026-03 | Fast-path ordering | Sibling fix to #198/#204 |
| #203 (PR) | Fix UAF in fallback path | CLOSED | (became `d5dd00c`) | Fix already in mainline |
| #204 | Pure load ordering still wrong (in `mod.rs#76`) | CLOSED 2026-04 | Transitivity | Fixed by `cccf354` |

**Key pattern**: 4 of the 6 confirmed bugs in 2025-2026 were memory-ordering downgrades that allowed cross-variable visibility gaps. The codebase has been undergoing systematic SeqCst saturation. **The current code is more SeqCst-heavy than the comments document** (#268, #270, #313 in `helping.rs` are stale).

### Cross-implementation comparison

`arc-swap` vs structurally similar systems:
- **`left-right`**: same reader-writer separation pattern. Earlier round of left-right yielded 5 bugs against the caller-misuse + stale-snapshot family. arc-swap has not been audited against the *same combination*.
- **`crossbeam-epoch`**: epoch-based reclamation; deeper reader/writer asymmetry. Different reclamation discipline.
- **Reference paper**: hazard pointers (Maged Michael 2004), flatter wait-free variant (Khyzha-Vechev / pvk.ca blog).

---

## Phase 3 — Deep Analysis

Conducted via three parallel subagents (one per major source file). Findings consolidated below with file:line citations.

### 3.1 `src/lib.rs` (top-level API)

**Writer's swap** (`lib.rs:479-491`):
- `let old = self.ptr.swap(new, Ordering::SeqCst);` — SeqCst ensures ordering with reader's `confirm` SeqCst load.
- `self.strategy.wait_for_readers(old, &self.ptr);` — drains debts via `pay_all`.
- `T::from_ptr(old)` — transfers ownership of one ref count to caller.

These are **three observable steps**. New readers can take debts on `new` between step 1 and step 2. The writer's `pay_all` only pays debts on `old`, so debts on `new` are untouched (correct).

**Drop for `ArcSwapAny`** (`lib.rs:338-349`):
- `let ptr = *self.ptr.get_mut();` (non-atomic; we have `&mut self`).
- `self.strategy.wait_for_readers(ptr, &self.ptr);` — drains all outstanding debts on `ptr`.
- `T::dec(ptr);` — decrements the storage's contribution.

Correct because Rust ownership prevents new loads via `&self` after `&mut self` is acquired. Outstanding Guards on other threads observed `ptr` earlier; their debts are paid.

**`into_inner`** (`lib.rs:401-407`): same as Drop but `mem::forget(self)` and `T::from_ptr` to transfer ownership.

**`compare_and_swap` and `rcu`** (`lib.rs:509-516, 617-634`): delegate to `strategy.compare_and_swap`. The `rcu` loop holds a Guard (`cur`) across user closure `f`; if `f` blocks, panics, or recurses, the Guard remains live. Slot exhaustion under recursive `rcu` falls back to refcount-clone (correct, just slower).

### 3.2 `src/strategy/hybrid.rs`

**`attempt`** (`hybrid.rs:42-72`):
- `let ptr = storage.load(Relaxed);` — line 44
- `let debt = node.new_fast(ptr as usize)?;` — claims slot
- `let confirm = storage.load(SeqCst);` — line 52, the **load-bearing re-read**
- If `ptr == confirm`: succeed using **`confirm`** (post-`63fa111`, must use confirm for provenance, not ptr).
- Else: `debt.pay::<T>(ptr)` to retract; if pay returns false, writer already paid → use ptr with no debt.

The two-load idiom is the classic hazard-pointer pattern. SeqCst on line 52 is what synchronizes with the writer's SeqCst swap.

**`fallback`** (`hybrid.rs:75-111`):
- `let gen = node.new_helping(storage as *const _ as usize);` — sets helping control to gen|GEN_TAG, writes active_addr.
- `let candidate = storage.load(SeqCst);` — line 83. **Post-`d5dd00c`** — was previously Acquire, upgraded after #198/#200. The comment at lines 80-82 documents the bug.
- `node.confirm_helping(gen, candidate as usize)` — swaps slot to `candidate`, swaps control to IDLE.
- If a writer helped during the gap: returns `Err((unused_debt, replacement))` and uses the replacement.

**`compare_and_swap`** (`hybrid.rs:227-263`):
- Loop: load via `<Self as InnerStrategy<T>>::load(self, storage)` (which itself takes a debt).
- Compare pointer to `current.as_raw()`; if not equal, return early without `wait_for_readers`.
- `compare_exchange_weak(current, new_raw, SeqCst, Relaxed)` — failure ordering Relaxed is **correct** here because the loop re-enters `load` which re-establishes SeqCst.
- On success: `T::into_ptr(new); wait_for_readers(self, old.as_ptr(), storage); T::dec(old.as_ptr())`.

**Refcount accounting in `compare_and_swap`**: `old` is debt-protected. `pay_all` walks the writer's *own* node (`mod.rs:101-104`); if it finds `old.debt`'s slot, it bumps the refcount and clears the slot. Then `T::dec(old.as_ptr())` (`hybrid.rs:257`) decrements once. Drop of `old` (`hybrid.rs:119-141`) checks: if `pay` returns false (already paid), `ManuallyDrop::drop` decrements once more. Total: pay_all increments once + dec at line 257 + drop dec = balanced (1 inc, 2 dec, but the inc was a "borrow" from pay_all's `T::inc`, so net 1 dec which is the correct cleanup).

**Drop of `HybridProtection`** (`hybrid.rs:119-141`):
- If `self.debt = Some(d) ∧ d.pay(self.ptr) = true`: clean exit (slot cleared, no owned ref).
- Else (debt None, or pay returned false because writer already paid): fall through to `ManuallyDrop::drop(&mut self.ptr)` which is `T::dec`.

The two branches encode different semantics for `self.ptr`. **Brittle but correct.**

### 3.3 `src/debt/mod.rs`

**`Debt::pay`** (`mod.rs:48-79`): `compare_exchange(ptr, NONE, AcqRel, Acquire)`. Post-`bd5d327` and `cccf354`, both success and failure orderings are upgraded to provide a happens-before with the Arc's strong-counter increments. Detailed comment at lines 67-77 cites the Arc memory model rationale.

**`Debt::pay_all`** (`mod.rs:82-121`):
1. `T::from_ptr(ptr)` and `T::inc(&val)` — pre-pay one ref.
2. `Node::traverse` — walks linked list. For each node:
   - `let _reservation = node.reserve_writer();` — Acquire fetch_add on `active_writers`.
   - `local.help(node, storage_addr, &replacement);` — try to fulfill the node's helping-slot if it's mid-load.
   - For each fast slot + helping slot: `slot.pay::<T>(ptr)`; if pays, `T::inc(&val)` to pre-pay the next.
3. `val` drops at end → final `T::dec` balances the pre-pay.

The reservation is what blocks COOLDOWN→UNUSED transitions while we're scanning.

### 3.4 `src/debt/list.rs`

**Linked list head** is `static LIST_HEAD: AtomicPtr<Node>`. Per-node `next: *const Node` is plain (not atomic) — set non-atomically before the SeqCst CAS publishing the node (`list.rs:185-202`).

**`Node::traverse`** (`list.rs:93-112`): `LIST_HEAD.load(SeqCst)` once (line 102), then walks `node.next.as_ref()` non-atomically. New nodes prepended after the load are missed. **Safety argument**: any reader on a missed node must have started its load *after* the writer's SeqCst swap of `storage.ptr`, so its `confirm` (fast) or `candidate` (fallback) load — also SeqCst — sees the new pointer and avoids debt on `old`.

**`start_cooldown`** (`list.rs:115-120`):
1. `_reservation = self.reserve_writer();` — fetch_add Acquire on `active_writers` (self-reservation).
2. `self.in_use.swap(NODE_COOLDOWN, Release)` — publishes the cooldown state.
3. Drop of `_reservation` → fetch_sub Release on `active_writers`.

**`check_cooldown`** (`list.rs:125-145`):
1. `if self.in_use.load(Acquire) == NODE_COOLDOWN {` — line 131
2. `if self.active_writers.load(Relaxed) == 0 {` — line 135
3. `compare_exchange(NODE_COOLDOWN, NODE_UNUSED, Relaxed, Relaxed)` — line 138

The Relaxed load on `active_writers` is justified by the comment at lines 128-130: "we know the 0 we observe happened some time after start_cooldown." But this argument depends on coherence ordering of `active_writers` (a single location), not happens-before between separate stores. The Acquire on `in_use` synchronizes with the `start_cooldown`'s Release-swap, but `start_cooldown`'s Drop-of-reservation happens-after that swap, not before. So **a third thread observing COOLDOWN via Acquire cannot conclude anything about the value of `active_writers`** through happens-before; it relies on the same-location coherence of `active_writers` to see at least the value at the time the start-cooldown's reservation was added. This is **subtle and worth model-checking**.

**`Node::get`** (`list.rs:158-204`):
- Try to find unused: `compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)` (line 166).
- Else: `Box::leak(Box::<Node>::default())`, then prepend via `LIST_HEAD.compare_exchange_weak(head, node, SeqCst, SeqCst)` (line 188).

Both are SeqCst, integrating into the global total order.

### 3.5 `src/debt/helping.rs`

**`get_debt`** (`helping.rs:191-217`):
1. `gen = local.generation.get().wrapping_add(4);` — non-atomic thread-local
2. `discard = (gen == 0)` — true on wrap
3. `self.active_addr.store(ptr, SeqCst)` — line 203
4. `let prev = self.control.swap(gen | GEN_TAG, SeqCst);` — line 210; asserts prev == IDLE

**`help`** (`helping.rs:219-306`):
- Loads `who.control` SeqCst.
- If GEN_TAG: load `active_addr` SeqCst, re-confirm control SeqCst (if address mismatch).
- Compute replacement (calls back into `load`!), load `who.space_offer` SeqCst, load `self.space_offer` SeqCst, write into `my_space` SeqCst, CAS `who.control` from gen to my_space|REPLACEMENT_TAG SeqCst.
- On success: `self.space_offer.store(their_space, SeqCst)` and forget the replacement.

Comments at lines 268, 270 say "Relaxed is fine"; **the actual code is SeqCst** (post-`6d3ef6d`). Stale documentation.

**`confirm`** (`helping.rs:312-338`):
1. `self.slot.0.swap(ptr, SeqCst)` — publish debt
2. `let control = self.control.swap(IDLE, SeqCst)` — clear control
3. If returned was the original gen: success
4. Else: REPLACEMENT_TAG path; load handover envelope SeqCst; `space_offer.store(handover, SeqCst)`; return Err(replacement)

### 3.6 NEW finding: `new_helping` / `confirm_helping` panic on generation wrap

Located independently during deep analysis. Not in any prior issue or commit.

**Trace**:
1. `LocalNode::with(|node| { ... })` — `node` is the per-thread `LocalNode`; `node.node` is `Cell<Option<&'static Node>>` initialized at start of `with`.
2. `HybridProtection::fallback(node, storage)`:
   - `let gen = node.new_helping(storage as *const _ as usize);` — `list.rs:288-298`:
     - Reads `self.node.get().expect(...)` → some `&'static Node` `n`.
     - Calls `n.helping.get_debt(...)`. `get_debt` writes `n.helping.active_addr` and swaps `n.helping.control` to `gen | GEN_TAG`.
     - If `gen == 0` (wrap), returns `discard = true`.
     - `n.start_cooldown()` — sets `n.in_use = COOLDOWN`.
     - `self.node.take()` — leaves `self.node = None`.
   - `let candidate = storage.load(SeqCst);`
   - `match node.confirm_helping(gen, candidate as usize) {` — `list.rs:307-319`:
     - `let node = &self.node.get().expect("LocalNode::with ensures it is set");`
     - `self.node.get()` is **None** (just take()'d).
     - **Panic** on `expect`.

**Aftermath**:
- The helping slot's `control` is left in `gen | GEN_TAG` state.
- The next thread to claim this node via `Node::get` (`list.rs:158-204`) successfully transitions UNUSED→USED, but `LocalNode::new_helping` will panic on the next call because `get_debt` asserts `prev == IDLE` at `helping.rs:213`.
- **The node is permanently poisoned.**

**Reachability**:
- 64-bit: `2^62` calls to `fallback` per thread (~`2^62` * tens-of-ns ≈ 4 * 10^9 seconds = 130 years).
- 32-bit: `2^30` calls per thread ≈ tens of seconds of stress testing.
- Panic, not memory unsafety. But real correctness bug.

**Mitigation in the spec**: model `new_helping` and `confirm_helping` as separate actions; assert `NoDanglingTransaction` invariant.

### 3.7 Stale comments (code-review-only)

Listed in modeling brief § 6.3. Most notable:
- `helping.rs:268, 270` — "Relaxed is fine" while code is SeqCst.
- `helping.rs:313-315` — "Release is to make sure control is observable" while code is SeqCst.
- `mod.rs:106-108` — "Note: Release is enough even here" while code is the post-AcqRel `Debt::pay`.

These are doc-rot from the SeqCst saturation refactor. Not safety bugs.

---

## Phase 4 — Synthesis

See `modeling-brief.md` for the prioritized output. Summary of decisions:

### Decided to model

- **Family 2 (Adversarial caller)**: explicit `ClientHarness` action set, per § 5.7. *This is the prompt's primary coverage gap.*
- **Family 3 (Stale snapshot in writer scan)**: split writer's `Publish → Scan → Free` into separate actions, per § 5.6 and the BUG-A pattern from left-right.
- **Family 5 (Action granularity audit, including the new_helping/confirm_helping panic finding)**: split helping transaction into `BeginHelping → DiscardNode? → ConfirmHelping`.
- **Family 4 (Cooldown + generation wrap)**: model `inflightHelp` predicate explicitly.
- **Family 1 (Memory ordering)**: faithful per-load-ordering labels; sensitivity hunts opt-in.

### Decided NOT to model

- `Cache::revalidate` Relaxed (documented stale-tolerant behavior).
- Two-layer `Option` issue #81 (requires custom unsafe RefCnt to manifest UB).
- `MapGuard` projection lifetime issue #45 (closed CVE; type-system-level fix).
- Stale doc comments (code-review fix).
- Per-thread node leak #117 (acknowledged design tradeoff).

### Re-derivation discipline (per `bug-archaeology.md` § 1.4)

The recently-fixed bugs `d5dd00c`, `cccf354`, `bd5d327`, `63fa111`, `d849a2d` are all in mainline. **None are listed as MC findings to reproduce.** They appear in §2 Evidence (as bug-prone-mechanism evidence) and §7 Reference Pointers (as historical context). The single sensitivity check (MC3 in the brief) is explicitly labeled as a robustness check, not a new finding.

The new MC findings (MC1, MC2, MC4, MC5, MC6) target unaudited mechanisms or unaudited-site combinations.

---

## Coverage Statistics

| Metric | Count |
|---|---|
| Total commits in repo | 434 |
| Bug-fix commits identified by keyword search | ~50 |
| Bug-fix commits read in full via `git show` | 13 |
| GitHub issues collected | 60 |
| Issues read with full discussion threads (`gh issue view --comments`) | 22 |
| Confirmed bugs | 6 |
| Confirmed already-fixed in mainline | 6 of 6 |
| Open design issues / non-modeling-targets | 4 |
| False positives / user error | 4 |
| Suspicion-only (defensive fix landed) | 1 |
| Core source files read in full | 6 (lib.rs partially, hybrid.rs, mod.rs, list.rs, fast.rs, helping.rs, cache.rs) |
| Parallel deep-analysis subagents launched | 3 |
| Issue-verification parallel subagents | 2 |
| Total parallel subagents | 5 |
| New bug findings (not in any commit/issue) | 1 (helping panic on wrap, F5) |
| Bug families identified | 5 |
| Code-review-only findings | 5 |
| Test-verifiable findings | 2 |
| Model-checkable findings | 6 (5 new + 1 sensitivity check) |

---

## Open Questions for Spec Author

1. **Should the spec model `Cache`?** It's a separate type from `ArcSwap` and uses a Relaxed load for revalidation. Including it would add complexity without clear benefit (the Relaxed is documented). Recommendation: **No**.
2. **Should `Pin<Arc>` and `Pin<Rc>` (`PR #185`) be modeled?** They are `RefCnt` impls that share the same protocol. The protocol is type-agnostic. Recommendation: **No, model the generic protocol**.
3. **What `MaxOrderingGaps` was modeled before?** Per the prompt, prior round modeled the fast-path SeqCst gap. This round should keep that and add Family 2 + Family 5 modeling on top.
4. **Trace replay against `tla_trace.rs` events**: the existing trace emission already covers the action boundaries listed in §3.1. The spec should align action names to these events for trace validation.

---

## Reference Pointers

- **Repository root**: `/home/ubuntu/Specula/case-studies/arc-swap/artifact/arc-swap`
- **Modeling brief**: `/home/ubuntu/Specula/case-studies/arc-swap_4/.specula-output/modeling-brief.md`
- **Existing trace infrastructure**: `src/tla_trace.rs` (865 LOC)
- **Reference papers**: Maged Michael, *Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects* (TPDS 2004); Khyzha & Vechev, flatter wait-free hazard pointers (https://pvk.ca/Blog/2020/07/07/flatter-wait-free-hazard-pointers/).
- **GitHub repo**: https://github.com/vorner/arc-swap (2200+ stars; 1.8.2 latest tagged release)
