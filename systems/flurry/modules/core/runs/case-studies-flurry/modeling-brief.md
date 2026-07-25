# Modeling Brief: jonhoo/flurry

## 1. System Overview

- **System**: flurry — Rust port of Java's `ConcurrentHashMap` (Doug Lea, JSR166)
- **Language**: Rust, ~5500 LOC core logic (map.rs + node.rs + raw/mod.rs)
- **Protocol**: Lock-free reads, per-bin locking for writes, cooperative resize via CAS on transfer_index
- **Key architectural choices**:
  - Uses `seize` crate for epoch-based memory reclamation (instead of Java GC)
  - Element count is a single `AtomicIsize` (Java uses sharded `CounterCell[]`)
  - TreeBin has a custom read-write lock (READER/WRITER/WAITER bit protocol on `AtomicI64`)
  - Transfer index loop uses `i = next_index` instead of Java's `i = nextIndex - 1` (map.rs:710)
- **Concurrency model**: Lock-free readers via atomic loads + guard-protected references. Writers lock the first node of each bin. Resize is cooperative — multiple threads claim ranges via CAS on `transfer_index`.

## 2. Bug Families

### Family 1: Resize/Transfer Coordination (HIGH)

**Mechanism**: The cooperative resize protocol uses `size_ctl`, `transfer_index`, and per-bin CAS to coordinate multiple threads transferring bins to a new table. Off-by-one errors, incorrect signaling, or missed coordination can cause bins to be skipped, processed twice, or transfer to hang.

**Evidence**:
- Historical: #29 / `e54f12e` — `resize_stamp` positive on 64-bit. The resize stamp encodes table size in `size_ctl`'s upper bits; incorrect sign broke resize initiation entirely on 64-bit.
- Historical: `e5e0a6b` — Transfer run-bit bug: last entry in bin's linked list not considered for run optimization, potentially placed in wrong half after split. Silent data corruption.
- Historical: `cdb8e5c` — Deadlock: Rust lock guard held through put→add_count→transfer because Java `synchronized` block exits earlier. Port mismatch.
- Code analysis: map.rs:710 — `i = next_index` vs Java's `i = nextIndex - 1`. After claiming a range, `i` points past the claimed range. On first outer loop iteration, `i >= n` triggers the finishing check prematurely. Helper threads return without processing their claimed range; the finishing thread's sweep recovers correctness by re-checking all bins.
- Code analysis: map.rs:1205 — TODO "figure out why this is rs + 2, not just rs". The `rs + 2` encodes "resize initiated + 1 active thread" but the developer flagged incomplete understanding.
- Code analysis: map.rs:1180 — `sc == rs + 1` check: if `rs` is the shifted resize stamp, `rs + 1` means "all helper threads have returned". But the `rs` computation must be exactly right for this check to work.

**Affected code paths**: `transfer()` (651-1086), `help_transfer()` (1088-1132), `add_count()` (1134-1213), `try_presize()` (538-649)

**Suggested modeling approach**:
- Variables: `sizeCtl : Int`, `transferIndex : Int`, `table : [BinState]`, `nextTable : [BinState]`, `threadState : [Thread -> {Idle, Transferring, Finishing}]`
- Actions: `InitResize` (set size_ctl to rs+2, create nextTable), `ClaimRange` (CAS transferIndex), `TransferBin` (lock bin, copy, store Moved), `FinishResize` (swap table), `HelpTransfer` (join via CAS size_ctl)
- Granularity: Each bin transfer is one action (atomic under bin lock). Range claiming and size_ctl updates are separate actions to expose interleavings.

**Priority**: High
**Rationale**: 4 historical bugs (#29 resize_stamp, `e5e0a6b` run-bit corruption, `cdb8e5c` deadlock, treeify race). The off-by-one (`i = next_index`) is a novel finding that may defeat cooperative parallelism. The resize protocol is the most complex concurrent coordination in the system and a prime TLA+ target.

---

### Family 2: Memory Reclamation Safety (HIGH)

**Mechanism**: Memory is reclaimed via epoch-based garbage collection (`seize`). Safety requires that: (a) guards protect all live references, (b) retired objects are only freed after all guards that could observe them are dropped, and (c) guards belong to the correct collector.

**Evidence**:
- Historical: #46 — External guards bypass collector association, enabling use-after-free
- Historical: #98 — Unsoundness in `clear()` with non-'static types
- Historical: `a9c6890` — References outlive map due to loose lifetime bounds
- Historical: `3753520` — Non-'static values freed while references held via global collector
- Historical: `52ffd22` — TreeBin waiter handle freed while another thread still dereferencing it
- Historical: `2a904cf` — Value leaked on failed no_replacement insert
- Historical: `4c0b1d7` — Stacked borrows violation in `put`: deref before retire created aliased mutable/shared references (Miri-detected UB)
- Historical: `eb6290d` — Guard check was actually disabled (commented out as TODO) — the #46 fix wasn't running
- Code analysis: map.rs:2497 — `replace_node` uses `store` (not `swap`) for value replacement. The old value is retired at line 2634, but the `store` approach doesn't verify the old pointer matches what we loaded.
- Open: #115 — Memory grows unbounded under certain web server patterns

**Affected code paths**: All operations that retire values/nodes: `put()`, `replace_node()`, `compute_if_present()`, `transfer()`, `treeify_bin()`, `drop()`

**Suggested modeling approach**:
- Variables: `retired : SET(Ptr)`, `activeGuards : SET(Guard)`, `reachable : Guard -> SET(Ptr)`, `freed : SET(Ptr)`
- Actions: `EnterGuard`, `ExitGuard`, `RetirePtr`, `FreeRetired` (free ptrs when no active guard can reach them)
- Invariant: `freed ∩ {p : ∃g ∈ activeGuards : p ∈ reachable[g]} = {}`
- Note: A simplified model of epoch-based reclamation is sufficient; we don't need to model the full seize protocol.

**Priority**: High
**Rationale**: 8 historical soundness bugs (including Miri-detected UB), 1 open issue. Memory safety bugs are the most severe class (undefined behavior). The epoch-based model is well-suited to TLA+ verification.

---

### Family 3: TreeBin Read-Write Lock Protocol (MEDIUM)

**Mechanism**: TreeBin uses a custom read-write lock via `lock_state : AtomicI64` with bit fields (WRITER=1, WAITER=2, READER=4+). Writers (holding the bin lock) must wait for readers to finish before restructuring the tree. Readers fall back to linear traversal when a writer is waiting.

**Evidence**:
- Historical: #84 — Segfault from use-after-free of waiter handle (fixed: `52ffd22`)
- Historical: #86 — Subtract overflow in tree bin (count going negative)
- Code analysis: node.rs:352-407 — `contended_lock()`: Complex state machine with thread parking
  - Writer stores thread handle at line 399, checks WAITER|WRITER at 357
  - Reader decrements at line 473: `fetch_add(-READER)`. If result == `READER|WAITER`, wakes writer.
  - Race window: between reader decrementing lock_state and loading the waiter handle (line 476), the writer could have already swapped the waiter to null (line 366). The current code handles this via `if !waiter.is_null()` check, but the waiter handle must survive until after `unpark()`.
- Code analysis: node.rs:460-486 — Reader tries CAS(s, s+READER). If s has WAITER|WRITER bits, falls to linear scan. No bounded retry — could spin indefinitely if writers keep arriving.

**Affected code paths**: `TreeBin::find()` (413-491), `TreeBin::lock_root()` (335-344), `TreeBin::contended_lock()` (352-407), `TreeBin::unlock_root()` (347-349)

**Suggested modeling approach**:
- Variables: `lockState : Int`, `waiter : Thread ∪ {null}`, `parked : SET(Thread)`, `readerCount : Nat`
- Actions: `ReaderAcquire` (CAS lock_state), `ReaderRelease` (fetch_add -READER, maybe unpark), `WriterAcquire` (CAS to WRITER), `WriterWait` (set WAITER, store handle, park), `WriterRelease` (store 0)
- Invariant: No WRITER while READER > 0 (mutual exclusion), No use-after-free of waiter handle

**Priority**: Medium
**Rationale**: 2 historical bugs. The protocol is a small, self-contained state machine ideal for model checking. The waiter lifecycle is the most subtle part.

---

### Family 4: Bin Lock + Treeify Race Window (MEDIUM)

**Mechanism**: `treeify_bin` is called AFTER releasing the bin lock in `put()`. Between lock release and `treeify_bin`, another thread can transfer the bin, remove nodes, or treeify it concurrently.

**Evidence**:
- Historical: #83 — Panic on treeifying a Moved entry
- Historical: f97487d — Fix: handle Moved and Tree entries gracefully in `treeify_bin`
- Code analysis: map.rs:1854,1942-1943 — `head_lock` dropped at 1854; `treeify_bin` called at 1943. In between, `add_count` at 1960 may trigger resize, which can transfer the bin.

**Affected code paths**: `put()` lines 1854-1943, `treeify_bin()` lines 2724-2855

**Suggested modeling approach**:
- Model `put` as two actions: `PutUnderLock` (insert node, release lock) and `MaybeTreeify` (re-acquire lock, check conditions, convert)
- Model `Transfer` as interleaving between these two actions
- Invariant: No panic/unreachable on any interleaving

**Priority**: Medium
**Rationale**: 2 historical bugs. The fix is in place but the race window still exists. Model checking can verify that all interleavings of put/treeify/transfer are handled.

---

### Family 5: Count Maintenance (LOW)

**Mechanism**: Element count is updated outside the bin lock via `AtomicIsize::fetch_add/fetch_sub`. This means count can temporarily be negative or inconsistent.

**Evidence**:
- Historical: #86 — Count underflow caused subtract overflow in tree bin test
- Code analysis: map.rs:1134-1141 — `add_count` uses separate fetch_add/fetch_sub
- Code analysis: map.rs:362-368 — `len()` clamps negative counts to 0
- Missing: Java CounterCell sharding (TODO at map.rs:1135)

**Affected code paths**: `add_count()`, `len()`, all callers of `add_count`

**Suggested modeling approach**:
- Not a high priority for model checking. The count is informational, not safety-critical.
- If modeled: variable `count : Int`, actions update count outside the bin lock.

**Priority**: Low
**Rationale**: Count inaccuracy is a known, accepted trade-off (same as Java). The underflow was fixed. Not safety-critical.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Cooperative resize protocol | Family 1: off-by-one finding, 2 historical bugs | Model `sizeCtl`, `transferIndex`, bin states; actions for range claiming, bin transfer, finishing |
| Per-bin locking | Family 4: treeify race | Track lock holder per bin; model put-then-treeify as two separate actions |
| Guard-based reclamation (simplified) | Family 2: 6 historical soundness bugs | Track retired-but-not-freed set; verify no access after free |
| TreeBin R/W lock state machine | Family 3: waiter lifecycle | Model lockState bits + parking/unparking |
| Bin types: Empty, Node, Tree, Moved | Families 1,4: type transitions during resize | Each bin has a type; transitions constrained by locking and resize state |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Hash computation | Pure function, no concurrency concern |
| Red-black tree rotations | Complex but correctness is tree-internal; model tree bin as atomic unit |
| Serde/Rayon implementations | Feature wrappers, not concurrent protocol |
| Key/value equality/ordering | Type system concern, not concurrency |
| Iterator traversal details | Traverser follows Moved pointers correctly (verified); model as atomic snapshot |
| CounterCell optimization | Performance optimization, not correctness (count is already modeled as approximate) |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Cooperative resize | `sizeCtl`, `transferIndex`, `binState[]`, `threadPhase[]` | Model multi-thread bin transfer coordination | Family 1 |
| Epoch-based reclaim (simplified) | `retired`, `activeGuards`, `freed` | Verify no use-after-free | Family 2 |
| TreeBin lock state | `lockState`, `waiter`, `parked` | Verify reader-writer mutual exclusion and waiter safety | Family 3 |
| Post-lock treeify | `binType[]`, `binLockHolder[]` | Verify treeify after lock release handles all bin types | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| AllBinsTransferred | Safety | After resize completes, every bin in old table is Moved | Family 1 |
| NoSkippedBins | Safety | Every bin index in [0, n) is processed by exactly one thread (or the finishing sweep) | Family 1 |
| ResizeTermination | Liveness | Resize eventually completes if at least one thread remains active | Family 1 |
| NoUseAfterFree | Safety | No thread accesses a pointer after it has been freed | Family 2 |
| ReaderWriterMutex | Safety | lock_state never has WRITER=1 while reader count > 0 | Family 3 |
| WaiterSafety | Safety | waiter handle is not freed while any thread holds a reference to it | Family 3 |
| BinTypeConsistency | Safety | A bin marked Moved is never modified by put/remove | Family 4 |
| TreeifyNoPanic | Safety | treeify_bin handles all possible bin types without panic | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-A | Transfer off-by-one: `i = next_index` vs `i = next_index - 1` causes helper threads to not process their claimed range | NoSkippedBins (benign — finishing sweep covers, but model can verify) | 1 |
| F1-B | size_ctl coordination: can `sc == rs + 1` check incorrectly signal completion when helper threads are still active? | ResizeTermination | 1 |
| F2-A | Can a thread access a retired value through a stale bin pointer loaded before resize? | NoUseAfterFree | 2 |
| F3-A | TreeBin: can the reader's fetch_add(-READER) and writer's waiter swap race such that unpark() is called on freed memory? | WaiterSafety | 3 |
| F4-A | Can treeify_bin encounter a bin type not handled by its match arms? | TreeifyNoPanic | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | Transfer parallelism: measure how many bins each helper thread actually processes | Multi-threaded insert with resize, count per-thread transfer ops |
| T2 | Count accuracy under high contention | N threads doing insert/remove, check final count matches expected |
| T3 | Memory reclamation under long-lived guards | Hold guard, insert/remove many items, check memory growth |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | `replace_node` uses `store` not `swap` for value replacement (map.rs:2497) | Harmless under bin lock, but inconsistent with `put` |
| C2 | Multiple TODO comments about incomplete understanding (map.rs:1205, node.rs:560) | Resolve and document |
| C3 | `compute_if_present` holds bin lock while calling user function (deadlock risk) | Document limitation, consider timeout or lock ordering |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/flurry/analysis-report.md`
- **Key source files**:
  - `artifact/flurry/src/map.rs` (core hashmap, 3552 lines)
  - `artifact/flurry/src/node.rs` (tree bins, 1628 lines)
  - `artifact/flurry/src/raw/mod.rs` (table structure, 325 lines)
- **Java reference**: `artifact/flurry/jsr166/src/ConcurrentHashMap.java`
- **GitHub issues**: #29 (resize_stamp), #46 (guard soundness), #84 (segfault), #86 (count overflow), #90 (unreachable), #98 (clear unsoundness), #115 (memory growth)
- **Key commits**: `e54f12e` (resize_stamp fix), `52ffd22` (waiter UAF fix), `a9c6890` (lifetime fix), `f97487d` (treeify race fix)
