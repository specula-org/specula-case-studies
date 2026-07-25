# Modeling Brief: papaya — Lock-Free Concurrent HashMap (Round 2)

## 1. System Overview

- **System**: papaya — Rust lock-free concurrent HashMap for read-heavy workloads
  (`ibraheemdev/papaya`, master = `b510b15` release 0.2.4)
- **Language**: Rust, ~3600 LOC core logic across `src/raw/{mod,alloc,probe,utils}.rs`
- **Category**: **Category B (Concurrent / Lock-Free)** — sub-category: **Concurrent
  Collections**. Justification: open-addressing hash table with epoch-based
  reclamation, tagged-pointer state machine for resize coordination, CAS-based
  linearization points; no message-passing, no consensus, no failure model in the
  distributed-systems sense.
- **Protocol**: Open-addressing with quadratic probing, hashbrown-style 7-bit metadata
  byte for cheap probing, per-slot `Tagged<*mut Entry>` pointers (3 tag bits:
  COPYING/COPIED/BORROWED), epoch reclamation via `seize`, two resize modes
  (Blocking / Incremental).
- **Concurrency model**: Lock-free for `get`, `insert`, `remove`, and `compute`;
  blocking only at (1) next-table allocation `Mutex`, (2) `Parker` wait for resize
  promotion, (3) `wait_copied` spin+park during incremental copy. All shared state
  via atomics with mixed Acquire/Release/AcqRel/SeqCst orderings.

## 2. Bug Families

This round preserves families 1-5 from round 1 and adds two new ones (6, 7) for
the explicitly-targeted coverage gaps.

### Family 1: Resize Copy/Insert Race Conditions (HIGH — unchanged from round 1)

**Mechanism**: Concurrent inserts, deletes, and the entry copy/migration protocol
during table resize interact through a multi-step tag state machine. 9 historical
bugs, all of the resize protocol's complexity remains in `mod.rs:2186-2820`.

**Suggested modeling**: Per-slot tag state machine `NONE → COPYING → COPIED`,
status atomic per table `PENDING → ABORTED|PROMOTED`, table chain with
`nextTable[T]` and copied/claim counters. Split `copy_at_*` into mark-COPYING,
insert-into-next, mark-COPIED actions.

**Priority**: High — most bug-dense area historically, complexity unchanged.

---

### Family 2: Memory Ordering Gaps (HIGH — unchanged from round 1)

**Mechanism**: Mixed `Ordering::*` annotations whose correctness depends on
cross-variable visibility (meta byte vs entry pointer; status vs unpark).

**Suggested modeling**: Label each load/store with the C11 ordering used in code;
write a bounded adversary (per `concurrent-analysis.md` § 5.5) that downgrades
suspected-load-bearing labels to Relaxed and verifies invariants still hold.
**Discipline**: do not attempt full TSO/ARM modeling.

**Priority**: High for cross-variable bridge sites (meta↔entry, status↔unpark);
defer microarchitectural relaxation modeling.

---

### Family 3: Parker / Unpark Routing (HIGH — UNFIXED ON UPSTREAM MASTER)

**Mechanism**: The blocking-mode abort path stores `ABORTED` to the destination
table's status atomic but unparks the SOURCE table's parker, on the SOURCE table's
status atomic key. Threads parked on the destination's parker are never woken.

**Evidence**:
- `raw/mod.rs:2282-2283` — `let state = table.state(); state.parker.unpark(&state.status);`
  inside the abort branch of `help_copy_blocking`. The store at line 2268 is on
  `next.state().status`. Threads at lines 2350-2352 park on `next.state().parker`
  keyed by `&next.state().status`. Different parker, different key.
- PR #92 proposed the fix (`next.state().parker.unpark(&next.state().status)`)
  but is **not present on upstream `master` (b510b15)** despite GitHub's "MERGED"
  flag (the PR was merged into the specula-org fork, not upstream).
- The repro test `tests/repro_parker_deadlock.rs` exists in the codebase and
  reproduces the deadlock with `RUSTFLAGS=--cfg papaya_stress`.

**Affected code paths**: `help_copy_blocking` lines 2212-2361; pairs with
`Parker::park` in `utils/parker.rs:32-99`.

**Suggested modeling**:
- Variables: `parker[table_id]` mapping `(key_atomic_addr) → Set(thread)`,
  `parked[thread]` ∈ `{None, Waiting(parker_id, key)}`.
- Actions: `Park(t, p, k, cond)` inserts thread under (p, k) iff cond holds;
  `Unpark(p, k)` removes and wakes all threads under (p, k).
- Granularity: model the abort as separate actions: `StoreAborted(next)` followed
  by `UnparkOnSource(table)`. The bug is exposed when the spec checks
  `EventuallyAllParkedAreWoken` (liveness): there exists a trace where a thread
  parks on `(next.parker, next.status)` and the only unpark is on
  `(table.parker, table.status)`.
- **Counterexample target**: a `□◇¬DeadlockedThread` violation under a
  parametrically-bounded harness with 2-3 threads, 1 abort.

**Priority**: **HIGH** — confirmed bug, reproducer in tree, not yet fixed
upstream. Liveness checking via TLC is the ideal verification.

---

### Family 4: Epoch-Based Reclamation Safety (MEDIUM — unchanged from round 1)

**Mechanism**: Entry lifecycle through deferred-retirement, particularly the
incremental-mode `defer_retire` walk that pushes onto a previous table's deferred
stack until the previous table itself is dropped.

**Suggested modeling**: Track entry-reachability across the table chain;
invariant `Reclaimed(e) ⇒ ¬Reachable(e)`. The `defer_retire` walk
(`mod.rs:2884-2938`) and `drop_table` (`mod.rs:3102-3120`) together implement
the deferral; spec should model the deferred stack as a per-table queue and
check the invariant on every reclamation event.

**Priority**: Medium — 5 historical bugs, deferred stack adds complexity,
but the most common failure modes (UAF) require Rust-type-system context that
TLA+ cannot fully express.

---

### Family 5: Tagged Pointer / Alignment (LOW — not TLA+-modelable)

**Mechanism**: Pointer tagging requires entries to have ≥8-byte alignment;
mis-using `entry.raw` (with tag bits) instead of `entry.ptr` causes UB.

**Suggested modeling**: Skip — these are Rust type-system issues, better
verified by Miri / sanitizer / code review. Three historical instances all
fixed.

---

### Family 6 (NEW this round): Adversarial Caller — Iter + Modify + Resize (HIGH)

**Mechanism**: A long-lived iterator captures a `table` snapshot at creation
time. Concurrent inserts, removes, and resizes that occur after iteration begins
can:

(a) Insert keys into a *new* root table that the iterator's snapshot does not
follow (silent missed-key under "weak snapshot" docs).

(b) Cause the same key to appear in two tables along the chain (when the iter
chases `next_table` chains, as draft PR #76 does for `drain`), risking
double-yield / double-action.

(c) Permit caller closures invoked from `compute_with` (`raw/mod.rs:1735-2032`)
to re-enter the map, triggering resize and stale snapshots — leading to extra
closure invocations beyond the documented "called for None at most once"
guarantee.

**Evidence**:
- Code: `raw/mod.rs:1400-1419` (iter), `2828-2843` (linearize),
  `2942-2999` (Iter::next).
- PR #76 (`drain` DRAFT) — author and owner both flag double-yield-during-resize
  as unsolved.
- PR #77 (`iter_mut`) — uses `&mut self` to *statically* prevent this hazard
  for the mutating-iter case; a useful precedent.
- Round-1 finding D-1 (two-phase insert) is the dual: iterator may see meta=h2
  with entry=null transiently (probe sees the chain alive but the slot is
  empty for this iteration).

**Affected code paths**:
- `Iter::next` and `linearize`.
- `compute_with` and `prepare_retry*` (re-entry hazard).
- Any future `drain`-style API following the table chain.

**Suggested modeling approach**:
- Variables: `iterTable[t]` (snapshot per iter), `iterIdx[t]`, `iterDone[t]`,
  `seenKeys[t]` (multiset of yielded keys).
- Actions: `IterBegin`, `IterAdvance(t, slot)`, `IterEnd(t)`. Concurrent
  Insert/Remove/Resize/Promote interleave normally.
- Granularity: the iter holds a single `table` reference for its lifetime;
  the spec must NOT auto-update it on promotion. Promote leaves `iterTable[t]`
  as the now-stale snapshot.
- Invariants:
  - **`IterNoDoubleYield`**: `∀t : ∀k ∈ seenKeys[t] : count(k, seenKeys[t]) ≤ 1`.
  - **`IterWeakSnapshot`**: a key K with insert_ts ≤ iter_begin_ts must appear
    in `seenKeys[t]` UNLESS it was removed before iter visited its slot.
    (This codifies the "weak snapshot" doc.)
- Fault injection: model `concurrent insert into new root` while iter is
  mid-traversal; verify whether the documented behavior matches the model
  semantics. The bug surfaces when a *future* API like `drain` is added — the
  spec then refutes the proposed design.

**Priority**: **HIGH** — explicit coverage gap from prompt; PR #76 makes the
hazard concrete; current iter is "weak snapshot" by docs but the formal
boundary is not pinned down.

---

### Family 7 (NEW this round): Slot Recycling / META Overwrite (MEDIUM)

**Mechanism**: The split between (1) CAS-publish entry pointer and (2) Release-store
the meta byte allows a third thread (loser of the same insert race) to fixup-write
the meta byte using h2(observed-key). If a remove tombstones the entry between
(1) and (2), (2) overwrites the TOMBSTONE meta with h2 — making the slot
unrecyclable until a full-table copy (slot leak / probe-chain bloat).

**Evidence**:
- Code: `raw/mod.rs:1014-1111` (insert_at). Winner store at line 1051;
  fixup load+store at 1106-1108. Yield-loop instrumentation at line 1047
  widens the window for repro.
- Slot recycling check: `mod.rs:1316, 2973` — only `meta::EMPTY|TOMBSTONE`
  qualifies a slot as reusable for fresh inserts.
- Repro test `tests/repro_bug1_meta_overwrite.rs` and `META_OVERWRITE_BUG_COUNT`
  static (`lib.rs:250`) confirm reproducibility under stress.

**Affected code paths**: `insert_at` (mod.rs:1014-1111), `insert_copy` meta-fixup
(mod.rs:2706-2724), `clear/retain` slot recycling (mod.rs:1316, 2973).

**Suggested modeling**:
- Variables: `meta[T][slot]` ∈ `{EMPTY, h2, TOMBSTONE}`, `entry[T][slot]` ∈
  `{NULL, EntryRef(k), TOMBSTONE_PTR}`, `slotReusable[T][slot]` ∈ BOOL.
- Actions: split `Insert` into:
  1. `InsertCAS(slot)` — CAS entry NULL → EntryRef(k).
  2. `InsertMetaStore(slot)` — store h2(k).
  3. `InsertMetaFixup(slot)` — different thread observes non-EMPTY entry,
     loads key, writes h2(observed-key) IF meta still EMPTY.
- Invariants:
  - **`MetaTombstoneStable`**: if `meta[T][s] = TOMBSTONE` and
    `entry[T][s] = TOMBSTONE_PTR`, then `meta[T][s]` must remain `TOMBSTONE`
    until the next successful insert into the slot.
  - **`SlotEventuallyReusable`** (liveness): any slot that has been logically
    deleted is eventually marked reusable (`meta = EMPTY|TOMBSTONE`).
- The spec exposes the bug as a violation of `MetaTombstoneStable`. This is
  *not* a memory-safety bug — `get`/`remove` still re-check the entry pointer
  — but is a slot-leak / probe-chain-bloat bug.

**Priority**: Medium — confirmed bug, instrumented repro, but consequences are
performance/leak rather than safety.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Tag state machine + status + chain (Family 1) | 9 historical resize bugs | per-slot tag, per-table status, table chain via `nextTable` |
| Parker/unpark with key-routing (Family 3) | Confirmed bug D2-1, reproducer present | parker keyed by atomic-address, unpark removes by (parker, key) |
| Iter snapshot + concurrent modify (Family 6) | Coverage gap, PR #76 hazard | snapshot table per iter, `seenKeys[t]` multiset, `IterNoDoubleYield` |
| Two-phase insert + meta fixup (Family 7) | Confirmed bug D2-4, reproducer present | split CAS/meta-store actions, `MetaTombstoneStable` |
| Memory ordering on meta↔entry and status↔unpark (Family 2) | Cross-variable bridge | label adversary that downgrades only suspected sites |
| Deferred retirement walk (Family 4) | 5 historical reclamation bugs | reachability-tracking inv `Reclaimed ⇒ ¬Reachable` |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| OOM-during-resize (Family 8 in report) | Implementation aborts process on OOM. No state-space property to verify. |
| Tagged pointer alignment (Family 5) | Rust type-system / Miri concern, not protocol logic. |
| Counter sum() saturation | Documented design; sum is approximate by intent. |
| Stack push Relaxed CAS | Sound under seize discipline; not a current bug. |
| compute_with re-entry semantics (Family 9 in report) | Documentation contract issue, not a state-space property. |
| Set wrapper, serde, hash function details | Not concurrency-relevant. |
| Full TSO/ARM weak-memory modeling | Per `concurrent-analysis.md` discipline — only adversary-downgrade specific sites. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Family |
|-----------|-----------|---------|--------|
| Per-slot tag state | `tag[T][s]` ∈ {NONE, COPYING, COPIED} | Resize protocol state | 1 |
| Per-table status | `status[T]` ∈ {PENDING, ABORTED, PROMOTED} | Resize coordination | 1, 3 |
| Table chain | `nextTable[T]`, `rootTable` | Multi-table writes/reads | 1 |
| Parker map | `parkerThreads[parker_id][key] → Seq(thread)` | Wakeup routing | 3 |
| Iterator snapshot | `iterTable[t]`, `iterIdx[t]`, `seenKeys[t]` | Iter+modify modeling | 6 |
| Per-slot meta byte | `meta[T][s]` ∈ {EMPTY, h2(k), TOMBSTONE} | Slot recycling check | 7 |
| Two-phase insert window | `insertPending[T][s][thread]` | Window between CAS and meta store | 7 |
| Deferred-retire stack | `deferred[T]` (set of entries) | Reclamation safety | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoLostEntry | Safety | A successfully inserted key is findable via `get` (modulo concurrent remove) | 1 |
| NoDuplicateEntry | Safety | A key exists in at most one table at any logical-state instant (modulo COPYING transition) | 1 |
| ProbeChainIntegrity | Safety | For any key K in table T, the probe sequence from `h1(K)` reaches K's slot without observing EMPTY first | 1, 7 |
| PromotionSafety | Safety | Root CAS only succeeds when copied-count = table.len() | 1 |
| AbortSafety | Safety | After abort, all threads converge to the replacement table | 1, 3 |
| **NoParkedThreadStranded** | Liveness | Every parked thread is eventually unparked on its parker+key | **3** |
| MetaTombstoneStable | Safety | Once meta = TOMBSTONE for a slot whose entry has been tombstoned, no h2 fixup can overwrite it | **7** |
| SlotEventuallyReusable | Liveness | A logically-deleted slot is eventually marked reusable | 7 |
| **IterNoDoubleYield** | Safety | Iter yields each key at most once during its lifetime | **6** |
| **IterWeakSnapshot** | Safety (relative) | A key inserted before iter began and not concurrently removed is yielded by iter | **6** |
| NoUseAfterReclaim | Safety | An entry is not reclaimed while reachable from any table in the chain | 4 |

Bolded invariants are net-new from round 2 and target the explicit coverage gaps.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|----------------------------|--------|
| MC-1 | Blocking abort unparks wrong parker (`mod.rs:2282`) — STILL UNFIXED ON MASTER | `NoParkedThreadStranded` | 3 |
| MC-2 | Two-phase insert + remove race overwrites TOMBSTONE meta (`mod.rs:1051,1106`) | `MetaTombstoneStable` | 7 |
| MC-3 | Iter snapshot misses entries inserted into post-iter-begin root | `IterWeakSnapshot` (relative formulation) or pin down exact semantics | 6 |
| MC-4 | Hypothetical `drain`-style iter following chain double-yields entries copied during traversal | `IterNoDoubleYield` | 6 |
| MC-5 | Nested resize (root → T1 → T2): copiedCount accounting under insert-into-T2-while-copying-T1 | `PromotionSafety` | 1 |
| MC-6 | compute_with closure re-entry causing extra invocations beyond doc-guaranteed bounds (informational, not safety) | None — bound not formal | 6 |
| MC-7 | Concurrent insert + remove + copy at same slot loses entry across tables | `NoLostEntry` | 1 |
| MC-8 | Probe chain bloat: removed entry's tombstone overwritten by h2 fixup, slot never reused | `SlotEventuallyReusable` | 7 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test |
|----|-------------|----------------|
| TV-1 | `MaybeUninit` value not dropped on panic in `compute_with` | Drop-tracking type with panic injection |
| TV-2 | Counter sum() returning negative-saturated 0 affects resize heuristic under heavy churn | Workload with 100k inserts then 100k removes; instrument `sum()` |
| TV-3 | OOM in `Box::new(Entry)` propagates through unwind without map corruption | Allocator-fault injection (e.g. `failpoints` style) |
| TV-4 | Reproduce parker deadlock on master b510b15 (without specula-org fork) | Run `tests/repro_parker_deadlock.rs` against upstream HEAD |
| TV-5 | Reproduce meta-overwrite race | `tests/repro_bug1_meta_overwrite.rs` already exists |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| CR-1 | Dead match arm in `insert_inner` for `Value(_)` from `insert_slow` | Replace with `unreachable!()` |
| CR-2 | `Stack::push` Relaxed CAS relies on seize-discipline for visibility — comment is implicit | Add a short safety comment naming seize as the synchronization edge |
| CR-3 | `defer_retire` walk's `unwrap()` (`mod.rs:2926`) relies on chain monotonicity | Document the invariant; consider a debug assert |
| CR-4 | `Iter` does not check tag bits; documented "weak snapshot" semantics deserves a louder API note | Add doc warning that resize-after-iter-begin can hide entries |
| CR-5 | PR #92 (parker fix) needs to land on upstream master | Request upstream merge or open new PR |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/papaya_2/.specula-output/analysis-report.md`
- **Key source files**:
  - `artifact/papaya/src/raw/mod.rs` (3156 LOC) — core lock-free hash table
  - `artifact/papaya/src/raw/alloc.rs` (233 LOC) — table allocation, OOM = abort
  - `artifact/papaya/src/raw/utils/parker.rs` (149 LOC) — Parker
  - `artifact/papaya/src/raw/utils/counter.rs` (61 LOC) — sharded counter
  - `artifact/papaya/src/raw/utils/stack.rs` (74 LOC) — deferred-retire stack
- **In-tree reproducers**:
  - `tests/repro_parker_deadlock.rs` — Family 3 (D2-1)
  - `tests/repro_bug1_meta_overwrite.rs` — Family 7 (D2-4)
- **GitHub references**:
  - PR #92 (parker fix on specula-org fork; NOT on upstream master)
  - PR #76 `drain` (draft; iter+modify+resize hazard explicit)
  - PR #77 `iter_mut`/`into_iter` (uses `&mut self` to prevent the hazard)
  - Issue #89 (capacity assertion, fixed in `731fb45`)
- **Round-1 outputs** (preserved as baseline):
  `case-studies/papaya/{modeling-brief.md, analysis-report.md}`
- **Trace validation**: Category B → use timebox-based trace approach for trace
  validation (per `concurrent-analysis.md` § 4 spec hints).
