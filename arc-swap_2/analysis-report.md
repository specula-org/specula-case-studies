# arc-swap Code Analysis Report

**Target**: vorner/arc-swap (v1.8.2 + post-1.8.2 fix `d5dd00c`)
**Repository**: `/home/ubuntu/Specula/case-studies/arc-swap_2/artifact/arc-swap`
**Date**: 2026-05-07
**Category**: B — Concurrent / Lock-Free / Runtime
**Sub-category**: Reader-writer separation (per `concurrent-analysis.md` § 5)

---

## Phase 1: Reconnaissance

### Codebase

~4,950 LOC across 21 source files. Core (concurrency-relevant) files:

| File | LOC | Role |
|------|-----|------|
| `src/lib.rs` | 1,328 | Public API: `ArcSwapAny`, `Guard`, `load`/`swap`/`compare_and_swap`/`rcu`/`Drop` |
| `src/strategy/hybrid.rs` | 239 | Default strategy: fast-path attempt + fallback (helping); writer pay-readers |
| `src/strategy/mod.rs` | 168 | Strategy trait, `DefaultStrategy = HybridStrategy<DefaultConfig>` |
| `src/debt/mod.rs` | 138 | `Debt::pay`, `Debt::pay_all` (writer side, walks all nodes) |
| `src/debt/list.rs` | 371 | Per-thread `Node` linked list (`LIST_HEAD`), claim/release lifecycle, cooldown |
| `src/debt/fast.rs` | 76 | 8 fast slots per node, fail-fast hazard pointer logic |
| `src/debt/helping.rs` | 334 | Wait-free fallback: helping/handover protocol with generation tagging |
| `src/cache.rs` | 343 | `Cache<A,T>` lazy revalidation wrapper |
| `src/access.rs` | 543 | `Access`/`Map` projection of substructure |
| `src/ref_cnt.rs` | 338 | `RefCnt` trait abstraction over Arc/Option<Arc>/Rc/Pin<Arc>/Pin<Rc>/Weak |

### Concurrency model

- One `AtomicPtr<T::Base>` per `ArcSwapAny`. Writers swap with SeqCst.
- Per-thread `Node` registered in a global prepend-only linked list (`LIST_HEAD`); a node is claimed via `compare_exchange(NODE_UNUSED → NODE_USED)`.
- Each Node has 8 fast `Debt` slots (AtomicUsize, sentinel `NONE = 0b11`) plus 1 helping slot with control word + active_addr + handover envelope.
- Reader fast path: `load(Relaxed)` ptr → claim slot via `swap(SeqCst)` → reload ptr `SeqCst` → if equal, success.
- Reader fallback: claim helping slot (publish gen+active_addr) → load ptr SeqCst → CAS-confirm vs gen. Writer can offer "helping" replacement if the address matches.
- Writer: `storage.swap(SeqCst)` → `wait_for_readers` → `Debt::pay_all` walks the entire node chain and CAS-pays slots holding the old pointer.
- Generation counter increments by 4 (low 2 bits = tag). On wraparound to 0, the node is sent to **cooldown** (NODE_COOLDOWN); writers can later move COOLDOWN → UNUSED once `active_writers == 0`.

### Atomicity boundaries (model granularity)

Each of these is a separate observable boundary the model must split:
1. Writer's `storage.swap(SeqCst)` (publish new pointer)
2. Writer's `LIST_HEAD.load(SeqCst)` (snapshot scan)
3. Writer's per-slot `Debt::pay` CAS
4. Reader fast: `load(Relaxed)` + `slot.swap(SeqCst)` + `load(SeqCst)` confirm — three actions
5. Reader fallback: `new_helping` SeqCst control swap + `load(SeqCst)` candidate + `confirm_helping` SeqCst control swap — three actions
6. Helper: `who.control` SeqCst load + `who.active_addr` SeqCst re-read + `who.control` SeqCst load (re-confirm) + `compare_exchange` (offer) — four actions
7. Reader's `Debt::pay` on guard drop — single CAS

---

## Phase 2: Bug Archaeology

### Coverage statistics

- **Git history**: 434 commits total. Mined all "fix"/"race"/"deadlock"/"sound"/"UB"/"ABA"/"miri" keyword commits — analyzed ~25 substantive bug-fix commits in detail.
- **GitHub issues**: 75 issues. Filtered to ~20 with bug-relevance, then **deeply read 18** (full comment threads via `gh issue view --comments`). Excluded ~5 as feature requests / docs / CI tooling.
- **Open PRs**: 12 open. Reviewed all titles; only #171 (shuttle compatibility) and #132 (mutable access) are non-dependabot — neither concerns concurrency correctness.
- **CHANGELOG**: read in full; cross-referenced soundness fixes (`#45`, `#80`, `#76`).

### Confirmed historical bugs

| Issue/PR | Commit | Mechanism | Severity | Fixed? |
|---|---|---|---|---|
| #1 | `d9b52ad` | Missing happens-before between writer's group-counter load and readers' fetch_sub | High | Yes (2018) |
| #45 (CVE-2020-35711) | `dfeb84b` | `MapGuard` assumed `Access::load` returns reference at stable address — fails for `Constant<T>` returning `&self.0` | High (UB in safe code) | Yes |
| #71 | (none) | TSan reports race in rcu drop | — | False positive (TSan limitation on Linux) |
| #76 | `6b644ff` etc. | Two SeqCst reads on different atomics do **not** form happens-before → reader's fast-path `confirm` can return stale ptr | High | Yes (multi-commit) |
| #156 | multiple | Same family as #76; multiple sub-bugs (cmpxchg failure ordering, allocation-reuse provenance) | High | Yes (chain of 5 commits) |
| #164 | `d849a2d` | Suspected race on debt-list head registration causing crashes in production (389-ds) | High | "Best guess" fix applied |
| #198 | `bd5d327`, `cccf354`, `d5dd00c` | UAF detected by miri across multiple ordering sites | High | Yes (3-commit cascade) |
| #200 | `cccf354` | Reader's `Debt::pay` CAS used `AcqRel/Acquire`, writer's swap is SeqCst — no SeqCst-total-order link | Theoretical UAF | Yes |
| #204 | `cccf354` | `compare_exchange` failure leg load doesn't participate in SeqCst total order | Theoretical UAF | Yes |
| PR #195 | `bd5d327` | `Debt::pay` failure ordering Relaxed allowed Arc strong-count visibility violation | High | Yes |
| (commit `63fa111`) | `63fa111` | Fast-path used `ptr` for `Self::new`; if allocation freed and reused, the wrong-provenance pointer was passed to `T::from_ptr` | High (UB under Stacked Borrows) | Yes |
| #81 | (open) | `ArcSwapAny<Option<Option<Arc<T>>>>` collapses None vs Some(None) | Medium (semantics) | Open; design discussion |
| #117 | (informational) | Apparent leak — actually retained per-thread bookkeeping | None | Documented |
| #89 | (informational) | Holding Guards across `.await` is sound but degrades to slow path | None | Documented |

### Bug pattern observation

**Every confirmed correctness bug since v1.0 has been a memory-ordering bug** — specifically, missed happens-before edges between cross-variable atomics. The protocol itself (debt-based hazard pointers + helping fallback + cooldown for ABA) is sound under sequential consistency. The maintainer has progressively strengthened orderings to SeqCst at every point where the abstract proof needs single-total-order. Quote from #156 thread: "*I've wrongly counted on a synchronization edge from `storage.swap(ptr, SeqCst)` in the writer thread and `slot.swap(debt, SeqCst)` in the reader thread and that one doesn't exist*."

This means: **arc-swap's bug surface is dominated by C11/Rust memory model corner cases**, not protocol logic errors. The coarse-grained protocol abstraction is correct; the leak is at the implementation-of-protocol layer.

### Maintainer's own assessment (from #156)

"*The library started with something reasonably simple, but as it grew, it grew to really complex. So now, it's kind of hard to reason about and mostly in stage when I try to somehow patch it to correctness. I already think about going back, dropping some of the requirements [wait-free guarantee] and rewriting it to something simpler.*"

This frames a 2.0 redesign as the long-term plan; 1.x is in patch-to-correctness mode.

---

## Phase 3: Deep Analysis

Three parallel subagents read all core files and applied the eight fault families from `concurrent-analysis.md` § 5. The findings below are synthesized and cross-referenced.

### Findings against fault-family taxonomy

#### 5.1 Thread Interleaving / Action Granularity (the headline)

The implementation has **at least 7 distinct atomicity boundaries** in a single reader call (see Phase 1 § Atomicity boundaries). Earlier model attempts (per the case-study brief) modeled `MaxOrderingGaps` and `StaleRead`, but did not faithfully split every observable interleaving point. **Most important modeling target.**

#### 5.2 Cancellation / Future Drop / Close

Issue #89 confirms `Guard` is `Send` and may live across `.await`. There is no async-cancellation hazard at the protocol level (the slot is paid out by Drop unconditionally). **Skip.**

#### 5.3 Allocator Failure / OOM

Allocation sites: `Box::leak(Box::<Node>::default())` in `list.rs:169` (only at thread first use, panics on OOM). Arc allocation by user. **Limited surface; skip.**

#### 5.4 CAS Spurious Failure

`compare_exchange_weak` used at exactly one site: `strategy/hybrid.rs:226` (`compare_and_swap` retry loop). The retry loop already handles spurious failure correctly (loops back to `load`). **Low priority.**

#### 5.5 Memory Ordering Relaxation — **TOP PRIORITY**

This is the family every confirmed bug since 2022 has belonged to. Key bridge sites still load-bearing:

| Site | Load/Store | Ordering | Bridge |
|---|---|---|---|
| `lib.rs:483` | `storage.swap` (writer) | SeqCst | publishes new ptr; pairs with reader's slot SC ops AND with LIST_HEAD load |
| `debt/list.rs:101` | `LIST_HEAD.load` (writer scan) | SeqCst | bridges to reader's `Node::get` SC prepend |
| `debt/list.rs:179` | `LIST_HEAD.compare_exchange_weak` (reader prepend) | SeqCst/SeqCst | publishes new node before storing debt |
| `debt/fast.rs:58` | `slot.swap(ptr)` (reader) | SeqCst | publishes debt before reload |
| `strategy/hybrid.rs:51` | `storage.load` confirm (reader fast) | SeqCst | bridges to writer's swap; was Acquire pre-`6b644ff` |
| `strategy/hybrid.rs:78` | `storage.load` candidate (reader fallback) | SeqCst | bridges to writer's swap; was Acquire pre-`d5dd00c` |
| `debt/helping.rs:209` | `control.swap(gen)` (reader) | SeqCst | publishes gen-acquire before slot read |
| `debt/helping.rs:312/317` | helping `slot.swap` + `control.swap(IDLE)` (reader confirm) | SeqCst/SeqCst | atomic confirm of gen→IDLE transition |
| `debt/mod.rs:77` | `Debt::pay` CAS (writer pay) | AcqRel / Acquire | both legs upgraded post-`cccf354`; the still-active question is whether ALL bridges converge here |

**Adversary**: downgrade exactly one of the SeqCst sites to Acquire/Release/Relaxed and check if any reader can hold a `Guard` whose underlying refcount has reached 0. This is exactly the test that historically reproduced #76, #156, #198, #200.

#### 5.6 ABA / Pointer Reuse

Two distinct ABA risks identified:

1. **Allocator-recycle ABA on stored pointer** (deep-analysis subagent C2/C3, #63fa111 family):
   - Even with SeqCst loads, if the allocator returns the same address for a new Arc after the old was freed, fast path's `ptr == confirm` succeeds. Pre-`63fa111` this used `ptr` (stale provenance); post-fix uses `confirm` (live provenance). Soundness now hinges on `confirm` being the live address at the time of `T::from_ptr(confirm)`.
   - Structural defense: any debt pre-pay holds the address pinned via refcount until pay_all observes & resolves the debt. **Sound under current code.**

2. **Caller-supplied raw pointer ABA in `compare_and_swap`** (subagent C3):
   - `as_raw.rs:60-72` permits `*const T::Base` / `*mut T::Base` as `current` for CAS.
   - If caller passes a raw pointer to a freed Arc and the address is reused for a different Arc that becomes the current value, `compare_and_swap` succeeds and reports "swap happened."
   - This is the documented semantic ("pointer-based comparison"), and `&Arc`/`Guard` callers are immune (their refcount keeps the address pinned). Only hand-written `*const`/`*mut` callers bypassing reference counting are vulnerable. **Code-review-only; not a TLA target unless we model the user harness.**

3. **Generation wraparound ABA in helping path** (`debt/helping.rs:191-213`):
   - Generation increments by 4. After `2^62` (or `2^30`) wraps it returns to 0. Then writer's `help` could match a stale gen value with current value.
   - Mitigated by: on wrap, `discard=true` triggers `start_cooldown()` and `self.node.take()` (lines 282-287). The node enters COOLDOWN; writers can only un-park it when no active_writers remain. So no writer that observed an "old" gen value is still in the help path when a new reader claims the same node with the wrapped gen.
   - **Subtle but defended.** Worth modeling as a counter-bounded action.

#### 5.7 Caller Misuse / Adversarial Client — **TOP PRIORITY (per brief)**

The earlier modeling round did NOT cover an adversarial caller. Patterns identified by subagent C-analysis:

- **C1**: `let g = arc_swap.load(); let bare = Guard::into_inner(g);` then ship `bare` to N threads, each cloning. Slot is released at `into_inner` time → no slot accounting hazard. **Sound.**
- **C3**: `compare_and_swap` with raw pointer (above).
- **C4**: Drop `ArcSwap` while another thread is still actively `load`-ing it — Drop waits for readers, but Rust's borrow checker forbids the reader still holding `&self`, so this requires the user to commit a separate UAF on `&self.ptr`. **Caller precondition; not TLA target.**
- **C9**: Send `Guard` to another thread, drop there. The slot is `&'static Debt` (lives forever in global list); pay is a CAS on global atomic. **Sound.**
- **C2/C11**: Cache used across threads (wrapped in Mutex) — ABA on cached_ptr is structurally prevented because the cache holds a strong ref. Liveness: Cache may serve stale value indefinitely if `revalidate` is never called (Relaxed load may stay stale). **By design.**

The most TLA-tractable adversarial-caller scenario is a **harness** that non-deterministically:
- Loads multiple Guards from one thread
- Sends them to other threads
- Drops them in any order, in any thread
- Concurrently performs writes (swap/store/compare_and_swap/rcu)
- Mixes `compare_and_swap` callers using each of `&Arc` / `Guard` / raw pointer as `current`

This is the missing coverage the brief calls out.

#### 5.8 Spurious / Lost Wakeup

No condvar/futex/parker. **Skip.**

### Findings new to this analysis (not in archaeology)

| New finding | Mechanism | Status |
|---|---|---|
| **N1** | `Cache::revalidate` uses Relaxed for the equality check (`cache.rs:164`); under aggressive SC, may serve stale value indefinitely between `load` calls. Documented but not formalized. | Code-review-only |
| **N2** | `compare_and_swap` retry loop's `compare_exchange_weak` uses `Relaxed` failure ordering (`hybrid.rs:226`). On failure we re-load with full SeqCst, so this is safe — but the assumption is implicit. | Code-review-only |
| **N3** | Generation wraparound + cooldown + node-reuse interleaving. The proof depends on `active_writers` reaching 0 being observable to the next claimant. The release-acquire on `NodeReservation::drop` + `start_cooldown` swap should suffice, but it's the most intricate piece in the codebase. | **Model-checkable** — high value |
| **N4** | `Debt::pay_all` walks ALL nodes (incl. NODE_COOLDOWN) so a debt held by a cooling-down node still gets paid. Verify this invariant explicitly: a node entering cooldown must not let any subsequent debt go unpaid by an in-flight writer. | **Model-checkable** |
| **N5** | `ArcSwap::Drop` calls `wait_for_readers` then `T::dec`. The `wait_for_readers`'s `replacement` closure recurses into `self.load(storage)` — relies on `&self.ptr` still being valid (it is, because Drop has `&mut self`), but is reentrant in a non-obvious way. | Code-review-only |
| **N6** | `ArcSwapOption` with `const_empty()`: drops without ever having allocated; `wait_for_readers(null, ...)` walks slots looking for `null as usize`. If a reader's slot legitimately holds `null` (a None debt), it gets "paid" by no-op `T::inc(None)`. Sound, but worth an explicit invariant. | Test-verifiable |

### Findings explicitly excluded as false positives

| ID | Why excluded |
|---|---|
| BUG-A-style stale LIST_HEAD snapshot | The chain `prepend(SC) → swap(SC) ; swap(SC) → load(SC)` provides total-order coverage; if writer doesn't see the new node, then reader's confirm-load sees the new ptr and aborts. **Defended.** |
| Writer scan order (fast then helping) | Reader's fast-confirm SeqCst forces it to retry/abort if the writer crossed in between. **Defended.** |
| TSan report on rcu drop (#71) | Maintainer + reporter agreed it's a TSan-on-Linux limitation, not reproducible on macOS. **False positive.** |
| Pin/Rc divergence | Verified `ref_cnt.rs` Pin/Rc impls return same logical pointer as Arc. **No divergence.** |

---

## Bug Family Synthesis

### Family A: Cross-variable SeqCst bridge — **HIGH PRIORITY**

**Mechanism**: Two atomic operations on different variables both tagged SeqCst do not, on their own, form a happens-before — they only contribute to a single total order over SeqCst events. Real protocol correctness depends on transitive chains of SC operations + load-store data dependencies.

**Evidence (8 historical bugs)**: #1, #76, #156, #164, #198, #200, #204, PR #195.

**Affected paths**:
- Reader fast confirm-load: `hybrid.rs:51`
- Reader fallback candidate-load: `hybrid.rs:78`
- Reader debt-store: `fast.rs:58`, `helping.rs:209`
- Reader pay: `mod.rs:77`
- Writer swap: `lib.rs:483`
- Writer LIST_HEAD scan: `list.rs:101`

**TLA approach**: model SeqCst as participating in a single total order; introduce a `MCRelaxOrdering(site)` adversary that downgrades one site at a time; verify `NoUseAfterFree` invariant.

### Family B: Allocator-reuse ABA on pointer identity

**Mechanism**: Same numeric pointer value reused for a different Arc allocation. Defended structurally by debt-pinning (refcount can't reach 0 while a debt exists), but every code change in the fast path risks re-introducing the issue (history: `63fa111` had to be patched in 1.8.0).

**Evidence**: `63fa111` fix; cousin pattern in #200.

**Affected paths**: `hybrid.rs:42-67` fast attempt (provenance via `confirm`).

**TLA approach**: model pointer identity as `(addr, generation)`; allow allocator non-determinism to re-use addresses with different generations; verify reader never sees a generation that was already freed.

### Family C: Adversarial caller — Guard lifecycle and CAS callers — **HIGH PRIORITY (gap from earlier round)**

**Mechanism**: The library's debt protocol assumes "guard is short-lived, dropped on its origin thread" but the API permits Send across threads, drop in any order, raw-pointer CAS callers, etc. None has produced a confirmed bug, but coverage is thin.

**Evidence**: Issues #89, #117, #199 (caller-misuse FAQ); deep-analysis findings C1, C3, C4, C9.

**Affected paths**: `hybrid.rs:106-127` Drop; `lib.rs:506-513` compare_and_swap; `as_raw.rs` raw-pointer impls.

**TLA approach**: build a `ClientHarness` action set that makes legal-but-adversarial sequences:
- multi-thread Guard ownership transfer
- variable-order Guard drops
- raw-pointer CAS (allow stale token)
- mix `swap`/`store`/`rcu` from any thread

### Family D: Generation wraparound + cooldown + node reuse

**Mechanism**: Helping-path generation is finite (62/30 bits). On wrap, the node enters cooldown; reuse must wait for `active_writers == 0`. The proof depends on careful release/acquire chain between `start_cooldown`, `NodeReservation::drop`, and `check_cooldown`.

**Evidence**: `helping.rs:54-75` design block; finding N3.

**Affected paths**: `helping.rs:191-213` get_debt; `list.rs:113-138` start/check_cooldown; `list.rs:151-194` Node::get.

**TLA approach**: bound generation to 2 or 3 to expose wrap; model COOLDOWN/UNUSED/USED state machine + active_writers counter; check no overlap between an old writer's "help" pointer and a new reader's claim.

### Family E: Writer-scan completeness vs in-flight reader

**Mechanism**: Writer's `pay_all` must observe every reader debt that was published before it dropped the old pointer. The chain spans LIST_HEAD load + per-node fast-slot scans + helping-slot scan + per-slot CAS-pay.

**Evidence**: Same family as A but worth distinguishing as the high-level invariant: at end of `pay_all`, no slot anywhere holds `old_ptr`.

**Affected paths**: `mod.rs:82-115`.

**TLA approach**: invariant `\A node \in nodes : \A slot \in node.slots : slot \notin {old_ptr}` after `pay_all` returns. Combined with Family A relaxation adversary.

### Family F: `Cache` revalidation staleness (low priority)

**Mechanism**: `Cache::revalidate` uses Relaxed compare; can return stale data indefinitely if the user never calls `load` "after" a write. Documented behavior.

**Evidence**: `cache.rs:164`; #199.

**TLA approach**: would require liveness modeling. **Skip** unless the spec also models writer-reader liveness.

---

## Coverage Statistics

- **Bug-fix commits analyzed**: 25 substantive (out of ~60 matching keywords)
- **GitHub issues deeply read**: 18 (full comment threads): #1, #45, #71, #76, #81, #89, #117, #150, #156, #164, #168, #187, #194, #195(PR), #196, #198, #199, #200, #204, #205
- **Open PRs reviewed**: 12 (no concurrency-correctness PRs open)
- **Issues confirmed as bugs**: 9 (memory ordering family) + 1 soundness (#45) + 1 semantics (#81)
- **Issues excluded as false positive / docs / feature**: 9
- **Core files read in full**: 7 (lib.rs portions, hybrid.rs, mod.rs, list.rs, fast.rs, helping.rs, cache.rs)
- **New findings (this round)**: 6 (N1–N6) — mostly model-checkable invariants rather than fresh bugs

## Excluded findings & rationale

- **Async cancellation** (5.2): `Guard` is Send, holding across await is documented as safe; no cancellation handler. Skip.
- **OOM** (5.3): only `Box::leak` site, panics on OOM; out of finite-state model.
- **Spurious wakeup** (5.8): no wait/notify primitives.
- **TSan #71**: Linux/glibc TSan limitation, not a bug.
- **#45 MapGuard CVE**: a Rust trait-soundness issue (closure address stability), not a concurrent protocol bug. Already fixed by `dfeb84b`. Out of scope for TLA.
- **#81 nested Option encoding**: a `RefCnt` API design issue (collapsing `Option<Option<Arc<T>>>`), not protocol-level. Code-review only.

---

## Hand-off

The Modeling Brief (`modeling-brief.md`) selects the high-priority families above and proposes concrete TLA+ extensions, focusing on Families A (memory ordering), C (adversarial caller — the explicit gap from the prior round), and D (generation wrap). Families B and E are companion invariants checkable inside the same model.
