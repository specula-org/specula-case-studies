# Modeling Brief: crossbeam-skiplist

## 1. System Overview

- **System**: crossbeam-skiplist — lock-free concurrent ordered map/set (part of crossbeam-rs/crossbeam)
- **Language**: Rust, ~2367 LOC core logic (`base.rs`), 819 LOC map wrapper, 661 LOC set wrapper
- **Algorithm**: Lock-free skip list with epoch-based memory reclamation (crossbeam-epoch)
- **Key architectural choices**:
  - Uses **pointer tag bits** for logical deletion (mark-before-unlink protocol; `mark_tower` marks top-down)
  - **Level-0 CAS** is the linearization point for insert/remove; higher-level links are optional optimization
  - **Reference counting** in `refs_and_height` (combined with height in a single `AtomicUsize`) tracks both level links and user-held `RefEntry` handles
  - **Epoch-based reclamation** via `crossbeam-epoch`: `Node::finalize` is deferred, not immediate
  - All critical CAS operations use **SeqCst** (8 TODOs from maintainer asking about relaxation)
- **Concurrency model**: Fully lock-free. Multiple threads can concurrently insert, remove, and iterate. No mutexes or locks. Atomic CAS operations provide synchronization.

## 2. Bug Families

### Family 1: Reference Count Lifecycle Errors (HIGH)

**Mechanism**: Missing `decrement`/`release` calls on `RefEntry`/`NodeRef`, causing permanent memory leaks. The ref count never reaches 0, so `Node::finalize` is never called and node memory is never freed.

**Evidence**:
- Historical: `8dd9e9b` — `Entry` had no `Drop` impl; every Entry drop leaked memory
- Historical: `4b0c5c5` — `pop_front`/`pop_back` leaked ref counts when entry was already removed
- Historical: `a7caaf1`, `4e0c17c`, `e7ccb30` — three separate fixes for `RefRange` leaking ref counts
- Historical: `e6d70ca` — `RefIter` leaked ref counts while iterating
- Historical: `46c8b53` — `decrement_with_pin` didn't check guard collector
- Issue #671, #672, #614, PR #337, PR #735, PR #1217 — all memory leak reports

**Affected code paths**: `RefEntry::release`, `RefIter::next`/`next_back`/`drop_impl`, `RefRange::next`/`next_back`/`drop_impl`, `Entry::drop`, `pop_front`, `pop_back`

**Suggested modeling approach**:
- Variables: `refCount[node]` — tracks reference count per node. `linkedLevels[node]` — set of levels where node is linked.
- Actions: Each action that acquires/releases a reference must update `refCount`. `Finalize` action fires when `refCount` reaches 0.
- Invariant: `RefCountCorrect == \A n \in Nodes : refCount[n] = Cardinality(linkedLevels[n]) + numEntryHandles[n]`
- Key: Model `RefEntry` lifetime explicitly — clone increments, release/drop decrements.

**Priority**: High
**Rationale**: 7+ historical bugs (most bug-dense family). The interaction between epoch-deferred finalization and manual reference counting is the root cause. Model checking can verify that all code paths maintain the ref count invariant.

---

### Family 2: Concurrent Insert/Remove Linearizability (HIGH)

**Mechanism**: Race conditions between concurrent `insert` (replace path) and `remove`/`get` that violate the expected linearizable semantics: insert-then-get returns None, or multiple removes return Some.

**Evidence**:
- Historical: `e7b5922` / Issue #1023 — `insert` then `get` returns `None` because `mark_tower()` on old node happened before new node CAS install
- Historical: `7121fbd` / PR #1143 — multiple threads calling `remove()` on same key all get `Some(entry)` (139,447 removes returned Some for 100,000 keys on M1)
- Historical: `bbe386e` — `remove()` returned entry from wrong scope
- Code analysis: `insert_internal` lines 1088-1092 — window where both old and new nodes exist during replace
- Code analysis: `compare_insert` closure called on potentially-removed node's value (semantic concern)

**Affected code paths**: `insert_internal` (replace path), `remove`, `compare_insert`

**Suggested modeling approach**:
- Variables: `list` (abstract ordered set of (key,value) pairs), `nodeState[node] \in {"live","marked","finalized"}`
- Actions: `Insert(key,val)`, `Remove(key)`, `Get(key)` — each with concurrent interleavings
- Split `Insert` into: `InsertCAS` (level-0 CAS, linearization point), `MarkOldNode`, `BuildTower`
- Split `Remove` into: `FindAndAcquire`, `MarkTower` (linearization point), `UnlinkLevels`
- Key invariant: `RemoveLinearizability == \A key : Cardinality({t \in Threads : removeResult[t][key] = "Some"}) <= 1`
- Key invariant: `InsertGetConsistency == \A key : (key \in list) => Get(key) # None`

**Priority**: High
**Rationale**: 3 critical historical bugs. The insert-replace + concurrent get interleaving is subtle and directly model-checkable. The level-0 CAS as linearization point can be verified against a sequential spec.

---

### Family 3: Iterator Exhaustion and Ordering (MEDIUM)

**Mechanism**: Guard-based iterators (`Iter`, `Range`) use `None` for both "not started" and "exhausted" states, causing iteration to restart from the beginning after the range/list end is reached.

**Evidence**:
- Issue #1142 (OPEN, unfixed) — `Range` rewinds to head after exhaustion
- Historical: Issue #737 / `e6d70ca` — iterator resumes from beginning after reaching end
- Historical: `3406d84` — `RefRange::next_back()` used wrong bound directions
- Code analysis: `Range::next()` lines 2002-2008 — `None` matches both initial and exhausted state
- Code analysis: `Iter::next()` lines 1813-1821 — same pattern
- **Not affected**: `RefRange` and `RefIter` (ref-counted variants) — they preserve `self.head` on exhaustion

**Affected code paths**: `Iter::next`, `Iter::next_back`, `Range::next`, `Range::next_back`

**Suggested modeling approach**:
- Variables: `iterState \in {"notStarted","active","exhausted"}`, `cursor` (current position)
- Actions: `IterNext` — advances cursor, transitions to exhausted when past range end
- Invariant: `IteratorMonotonic == cursor' >= cursor` (keys never go backward)
- Invariant: `ExhaustedStaysExhausted == (iterState = "exhausted") => (iterState' = "exhausted")`

**Priority**: Medium
**Rationale**: 1 unfixed open bug (#1142). Pattern is well-understood. Not a safety issue (no memory corruption) but violates FusedIterator expectation. Simple to model.

---

### Family 4: Tower Marking Protocol Correctness (MEDIUM)

**Mechanism**: The top-down marking protocol (`mark_tower` marks from highest level to level 0) creates transient states where a node is partially disconnected from higher levels but still live at level 0. Concurrent insert tower-building and remove tower-marking can interleave in complex ways.

**Evidence**:
- Code analysis: `mark_tower` lines 327-348 — top-down fetch_or with SeqCst
- Code analysis: `insert_internal` lines 1136-1218 — tower building interacts with concurrent marking
- Code analysis: Lines 1148-1151 — check for concurrent marking during tower build
- Code analysis: Lines 1220-1229 — cleanup if tower marked during/after build
- Code analysis: Lines 1171-1177 — duplicate key successor during tower build (potential loop)

**Affected code paths**: `mark_tower`, `help_unlink`, `insert_internal` (tower building), `remove` (unlink loop)

**Suggested modeling approach**:
- Variables: `tower[node][level] \in {"null","linked","marked"}`, `height[node]`
- Actions: `MarkLevel(node, level)`, `LinkLevel(node, level)`, `HelpUnlink(pred, curr, level)`
- Model 2-3 levels (not full 32) to keep state space bounded
- Invariant: `MarkingOrder == \A node, l1, l2 : (l1 > l2 /\ tower[node][l2] = "marked") => tower[node][l1] = "marked"`
- Invariant: `Level0Authoritative == is_removed(node) <=> tower[node][0] = "marked"`

**Priority**: Medium
**Rationale**: No known bugs in current code (the protocol is well-designed), but the interleavings are complex and hard to reason about manually. Model checking can provide confidence in the marking protocol's safety. The interaction with tower building is particularly subtle.

---

### Family 5: Epoch Reclamation Safety (LOW for skiplist-specific modeling)

**Mechanism**: Epoch-based reclamation delays deallocation. Nodes marked for removal may persist in memory for an unbounded time. Under certain workloads, memory grows continuously.

**Evidence**:
- Issue #540 (OPEN, design limitation) — memory not released for 2-3 hours
- Issue #1178, #1127 — duplicates of #540
- Issue #852 — O(n²) GC overhead with many threads (Solana production impact)
- Issue #878 / PR #871 — Stacked Borrows violations in Tower ZST pattern
- Issue #105 — epoch can advance while pin held (fixed)
- Code analysis: 8 TODO comments about relaxing SeqCst (lines 334, 1075, 1143, 1182, 1196, 1226, 1305, 1309)

**Priority**: Low (for TLA+ modeling)
**Rationale**: Epoch semantics are a separate system from the skip list protocol. The delayed deallocation is an inherent design tradeoff, not a bug. The Stacked Borrows issues are Rust-specific aliasing concerns, not protocol logic. Memory ordering relaxation requires weak-memory model tools (GenMC/CDSChecker), not TLA+.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Level-0 CAS linearization | Family 2: root cause of insert/get and remove races | Atomic `InsertCAS` action as linearization point; `MarkTower` as remove linearization point |
| Insert-replace with concurrent get | Family 2: confirms #1023 fix | Split insert into: search, CAS-install, mark-old-node. Concurrent `Get` action |
| Concurrent remove linearizability | Family 2: confirms #1143 fix | Multiple threads call Remove on same key; check exactly one gets Some |
| Reference count state machine | Family 1: 7+ historical bugs | Track refCount per node; verify it equals (linked levels + entry handles) at all times |
| Top-down tower marking | Family 4: core correctness of mark protocol | Model 2-3 levels; mark from top-down; verify level-0 is authoritative |
| help_unlink during concurrent removal | Family 4: subtle CAS interaction | Model predecessor being marked while help_unlink operates |
| Iterator state machine | Family 3: confirms #1142 | Model exhaustion state; verify monotonic key order |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Epoch-based GC internals | Separate system; epoch provides the "deferred finalize" abstraction. Model as: when refcount=0, node eventually becomes inaccessible. |
| Memory ordering (SeqCst relaxation) | Requires weak-memory model tools (GenMC), not TLA+ |
| Stacked Borrows / pointer provenance | Rust-specific aliasing model; not protocol logic |
| Random height generation | Performance optimization; doesn't affect correctness (all heights 1..MAX_HEIGHT are valid) |
| `SkipSet` / `SkipMap` wrappers | Thin wrappers over `base::SkipList`; no independent logic |
| Custom comparators | Orthogonal to concurrency; assume a total order on keys |
| Allocation failure handling | OOM is outside protocol scope |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Reference counting | `refCount[node]`, `entryHandles[node]` | Track ref count lifecycle; detect leaks and premature finalize | Family 1 |
| Insert-replace protocol | `nodeState[node] \in {"allocating","live","marked","finalized"}` | Model the insert-replace window | Family 2 |
| Multi-level tower | `tower[node][level] \in {"null","linked","marked"}` | Model top-down marking and tower building | Family 4 |
| Iterator state | `iterState \in {"notStarted","active","exhausted"}`, `cursor` | Model iterator lifecycle | Family 3 |
| Concurrent operations | `threadOp[t] \in {"insert","remove","get","iterate","idle"}` | Model concurrent thread operations | Family 2, 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| RefCountCorrect | Safety | refCount[n] = |linkedLevels[n]| + |entryHandles[n]| for all live nodes | Family 1 |
| NoUseAfterFinalize | Safety | No thread accesses a finalized node's key/value | Family 1 |
| RemoveLinearizability | Safety | At most one concurrent remove() for the same key returns Some | Family 2 |
| InsertGetConsistency | Safety | If insert(k,v) linearized before get(k), then get returns Some | Family 2 |
| Level0Authoritative | Safety | A node is logically removed iff its level-0 pointer is marked | Family 4 |
| MarkingOrderTopDown | Safety | If level L is marked, all levels > L are also marked | Family 4 |
| TowerBuildingSafety | Safety | A node being tower-built that gets concurrently marked stops building | Family 4 |
| IteratorMonotonic | Safety | Iterator returns keys in strictly increasing order | Family 3 |
| ListSorted | Safety | Level-0 chain is sorted by key (considering only unmarked nodes) | Structural |
| NoOrphanNodes | Liveness | Every marked node is eventually unlinked from all levels | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Insert-replace + concurrent get: can get() return None for an always-present key? | InsertGetConsistency | 2 |
| MC-2 | Concurrent remove: can two threads both get Some for the same key? | RemoveLinearizability | 2 |
| MC-3 | Tower build + concurrent mark: does tower building terminate and leave consistent state? | TowerBuildingSafety | 4 |
| MC-4 | Reference count balance: do all paths maintain the ref count invariant? | RefCountCorrect | 1 |
| MC-5 | help_unlink + concurrent predecessor removal: is the CAS sufficient for safety? | Level0Authoritative | 4 |
| MC-6 | Duplicate-key successor loop: does tower building terminate when same-key nodes exist at higher levels? | (Liveness) | 4 |
| MC-7 | pop_front under contention: does try_pin_loop make progress? | (Liveness) | 1, 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Range/Iter exhaustion restart (#1142) | Create range, drain to None, call next() again — should return None |
| TV-2 | compare_insert closure on removed node | Two threads: one removes, other compare_inserts with a closure checking old value |
| TV-3 | clear() under concurrent insertion | One thread clears, another inserts; check list is non-empty after clear |
| TV-4 | next_node O(N) help-unlink chain | Insert many, remove all but last, measure iteration latency |
| TV-5 | IntoIter with marked nodes | Insert, remove some, call into_iter(); verify correct key/value recovery |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | 8 SeqCst TODO comments from Amanieu — relaxation requires weak-memory analysis | Needs GenMC/CDSChecker, not TLA+ |
| CR-2 | decrement ordering (Release fetch_sub + Acquire fence) follows Arc::drop pattern | Correct; no action needed |
| CR-3 | clear() not linearizable under contention (by design) | Documentation improvement |
| CR-4 | Issue #1130: Send bound asymmetry between insert and get_or_insert | API review needed |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/crossbeam-skiplist/analysis-report.md`
- **Key source files**:
  - `artifact/crossbeam/crossbeam-skiplist/src/base.rs` (core skip list, 2367 lines)
  - `artifact/crossbeam/crossbeam-skiplist/src/map.rs` (SkipMap wrapper, 819 lines)
  - `artifact/crossbeam/crossbeam-skiplist/src/set.rs` (SkipSet wrapper, 661 lines)
- **GitHub issues**: #1023, PR #1143 (Family 2); #671, #672, #614 (Family 1); #1142, #737 (Family 3); #878 (Family 4/5); #540 (Family 5)
- **Key commits**: `e7b5922` (insert/get race), `7121fbd` (remove linearizability), `b8c88aa` (Stacked Borrows), `4b0c5c5`/`a7caaf1`/`e6d70ca` (memory leaks)
- **Category**: B (concurrent/lock-free) — use timebox trace approach for trace validation
