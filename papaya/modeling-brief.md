# Modeling Brief: papaya — Lock-Free Concurrent HashMap

## 1. System Overview

- **System**: papaya — Rust lock-free concurrent HashMap for read-heavy workloads
- **Repository**: `ibraheemdev/papaya`, 182 commits, v0.2.3
- **Language**: Rust, ~2843 LOC core logic (`src/raw/mod.rs`), 6677 LOC total
- **Protocol**: Open-addressing hash table with quadratic probing, epoch-based reclamation (`seize`), tagged pointers for resize coordination
- **Key architectural choices**:
  - **Two resize modes**: Blocking (all threads wait) vs Incremental (concurrent copy with per-entry tag coordination)
  - **3-bit tagged pointers**: COPYING (0b001), COPIED (0b010), BORROWED (0b100) on entry pointers to coordinate resize state machine
  - **Two-phase insert**: Entry pointer CAS'd first, then metadata byte stored (non-atomic pair with accepted linearizability gap)
  - **Deferred retirement stack**: Entries removed from non-root tables during incremental resize are deferred until the source table is deallocated
- **Concurrency model**: Lock-free for reads and most writes. Blocking only during resize coordination (parker) and next-table allocation (Mutex). All shared state via atomics (AtomicPtr, AtomicU8, AtomicUsize).

## 2. Bug Families

### Family 1: Resize Copy/Insert Race Conditions (HIGH)

**Mechanism**: Concurrent inserts, deletes, and the entry copy/migration protocol during table resize interact through a multi-step tag state machine (COPYING → COPIED). Races between these operations have caused lost entries, duplicate entries, memory leaks, and metadata corruption.

**Evidence**:
- Historical: `9ea694b` — insert_copy returned wrong table during nested resize
- Historical: `f1453ee` — insert beating copy to new table lost copy count
- Historical: `e157a21` — insert racing copy caused leaked entries (221 lines changed)
- Historical: `00e63b0` — overwriting copied entry metadata broke probe chain
- Historical: `265c87a` — memory leak when insert races copy
- Historical: `f3e7c4c` — entry state machine needed 3rd tag bit (COPIED) to disambiguate
- Historical: `9371590` — insert/remove race: missing probe advance after finding deleted entry
- Historical: `c4bfe11` — infinite recursion in compute_with during copy
- Code analysis: `raw/mod.rs:2073-2074` — abort unpark targets wrong parker (see Family 3)

**Affected code paths**:
- `insert_inner()` / `insert_at()` / `insert_slow()` (lines 442-620, 881-939, 593-617)
- `copy_at_blocking()` / `copy_at_incremental()` (lines 2148-2190, 2300-2355)
- `insert_copy()` (lines 2358-2445)
- `try_promote()` (lines 2449-2508)
- `help_copy_blocking()` / `help_copy_incremental()` (lines 2018-2139, 2195-2289)

**Suggested modeling approach**:
- Variables: `table` (array of slots), `nextTable` (array of slots, or NULL), `entryTag[slot]` ∈ {NONE, COPYING, COPIED}, `status` ∈ {PENDING, ABORTED, PROMOTED}, `copiedCount`, `claimCount`
- Actions: `Insert(key, val)`, `Remove(key)`, `CopyEntry(slot)`, `InsertCopy(entry, slot)`, `TryPromote`, `AbortResize`, `AllocNextTable`
- Granularity: Split entry CAS and metadata store into two actions to capture the non-atomic window. Split copy into COPYING-mark, insert-to-next, COPIED-mark steps.
- Fault injection: `StallBetweenCASandMeta` (models the two-phase insert gap)

**Priority**: High
**Rationale**: 9 historical bug-fix commits (most of ANY area), several critical production crashes. The resize protocol is the most complex and error-prone component.

---

### Family 2: Memory Ordering Gaps (HIGH)

**Mechanism**: Incorrect memory orderings on atomic operations allow readers to observe stale or partially-written state, causing data races on entry contents.

**Evidence**:
- Historical: `e69e986` — massive ordering audit, 212 lines changed across ~40 atomics
- Historical: `3345c9d` — partial revert: fences insufficient, reverted to Acquire on entry loads
- Historical: `9792ded` — Release store on COPIED tag not visible to SeqCst parker checks
- Historical: `c353655` — documented remaining SeqCst requirements
- Code analysis: metadata Acquire/Release chain provides synchronization for entry pointer visibility

**Affected code paths**:
- All entry loads in `get()`, `insert_inner()`, `remove_if()`, `clear()`, `retain()`
- Copy coordination: `copy_at_incremental()` COPIED store (must be SeqCst for parker)
- `try_promote()` root CAS and status store orderings

**Suggested modeling approach**:
- Model memory orderings as visibility constraints: a write becomes visible to a reader only after proper synchronization (Acquire-Release pairing)
- Variables: `visibleTo[thread][var]` tracking which writes each thread can see
- Actions: Model `AcquireLoad`, `ReleaseStore`, `SeqCstStore` as different visibility propagation rules
- This is best modeled as a constraint on which interleavings are valid, not as separate actions

**Priority**: High
**Rationale**: 4 historical commits with repeated revisions. The ordering model was not formally specified. A TLA+ model can validate the minimum required orderings.

---

### Family 3: Parker/Synchronization Deadlocks (MEDIUM)

**Mechanism**: The thread parking protocol for blocking resize mode has ordering and targeting bugs that can cause threads to park indefinitely.

**Evidence**:
- Historical: `61d8eb4` — pending counter increment/insert ordering caused missed wakeups
- Historical: `74975e8` — spurious wakeup detection checked wrong condition
- Historical: `9792ded` — Release store not visible to SeqCst parker condition check
- Code analysis: `raw/mod.rs:2073-2074` — **Potential unfixed bug**: When resize is aborted, `unpark` is called on `table.state().parker` (the root/source table's parker) with key `&table.state().status`. But threads waiting for copy completion are parked on `next.state().parker` (the next/aborted table's parker) at line 2134-2136. These are different parker instances with different keys. A thread parked on the aborted table's parker before the ABORTED status store is never woken because no one unparks the correct parker.

**Affected code paths**:
- `help_copy_blocking()` abort path (lines 2060-2078)
- `help_copy_blocking()` wait-for-promotion loop (lines 2097-2137)
- `Parker::park()` / `Parker::unpark()` (`utils/parker.rs`)
- `try_promote()` unpark on promotion (line 2501)

**Suggested modeling approach**:
- Variables: `parked[thread]` ∈ {NONE, WAITING(parker_id, key)}, `parkerState[parker_id]` (thread registry)
- Actions: `Park(parker, key, condition)`, `Unpark(parker, key)`, `AbortResize`, `Promote`
- Key property: every parked thread is eventually unparked (liveness)

**Priority**: Medium
**Rationale**: 3 historical fixes, plus a potential unfixed deadlock. Only affects blocking resize mode with abort (rare). Liveness property is ideal for TLA+ temporal checking.

---

### Family 4: Epoch-Based Reclamation Safety (MEDIUM)

**Mechanism**: Interactions between the HashMap's entry lifecycle and the `seize` epoch-based garbage collector can create use-after-free, double-free, or leak conditions.

**Evidence**:
- Historical: `97a519b` / `8fb6410` — unsound AsLink impl (missing repr(C) allowed field reordering)
- Historical: `7267012` — FromIterator used unprotected guard, causing UAF on retired entries
- Historical: `72c7375` — recursive retirement during HashMap::drop
- Historical: `d3f4953` — insufficient Sync bounds (K/V dropped on wrong thread)
- Historical: `4edf66d` — variance hole allowing lifetime extension
- Code analysis: `defer_retire()` (lines 2571-2625) uses different retirement strategies based on BORROWED tag and table position

**Affected code paths**:
- `defer_retire()` (lines 2571-2625) — incremental mode deferred stack
- `drop_table()` (lines 2789-2808) — drains deferred stack
- `try_promote()` (lines 2486-2497) — retires old table
- `Drop for HashMap` (lines 2720-2756) — cleanup

**Suggested modeling approach**:
- Variables: `epoch[thread]`, `retired[entry]` (set of entries pending reclamation), `reachable[entry]` (set of entries reachable from any table)
- Actions: `RetireEntry`, `ReclaimEntry` (when all threads have advanced past the retirement epoch), `AdvanceEpoch`
- Invariant: `ReclaimedEntry ⇒ ¬ReachableFromAnyThread`

**Priority**: Medium
**Rationale**: 5 historical soundness bugs. The deferred retirement stack for incremental mode adds complexity. TLA+ can verify that no entry is reclaimed while still reachable.

---

### Family 5: Tagged Pointer Misuse (LOW)

**Mechanism**: Using tagged (raw) pointers vs untagged (ptr) pointers, and alignment requirements for tag bit storage.

**Evidence**:
- Historical: `0574e3e` — Entry alignment < 8 caused tag bits to corrupt pointer (CRITICAL, production crash)
- Historical: `02dae66` — `retain` dereferenced `entry.raw` instead of `entry.ptr` (CRITICAL, segfault)
- Historical: `01bd220` — table layout didn't respect entry alignment

**Affected code paths**:
- All code paths that dereference `Tagged<Entry<K,V>>` — must use `.ptr` not `.raw`
- `Entry` struct alignment — must be ≥ 8 for 3 tag bits

**Suggested modeling approach**: Not suitable for TLA+ modeling. These are Rust type-level issues (pointer tagging, alignment) better caught by Miri or careful code review.

**Priority**: Low (for TLA+ modeling)
**Rationale**: All known instances fixed. These are implementation-level issues, not protocol logic.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Entry slot state machine | Family 1: 9 bugs in tag transitions | Model NONE → COPYING → COPIED lifecycle with concurrent insert/remove interleaving |
| Resize copy protocol | Family 1: most bug-dense area | Model copy_at, insert_copy, try_promote as separate actions with claim/copied counters |
| Blocking resize abort | Family 3: potential unfixed deadlock | Model abort + re-allocation + thread parking to verify liveness |
| Probe chain consistency | Family 1: metadata/entry non-atomic | Model two-phase insert (CAS entry, then store meta) to check if gets can miss entries |
| Deferred retirement | Family 4: borrowed entries deferred until table drop | Model reachability tracking across table chain |
| Nested resize | Family 1: resize during resize | Model table chain (root → T1 → T2) with concurrent copy/promotion |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Tagged pointer alignment | Family 5: Rust type system issue, not protocol logic |
| Serde serialization | No concurrency concern |
| Hash function details | h1/h2 split is a performance optimization, not a correctness concern |
| Counter sharding | Approximate count is by design, no safety implication |
| Provenance tracking | Rust-specific memory model concern, not modelable in TLA+ |
| Set wrapper | Thin wrapper over HashMap, no independent logic |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Tag state machine | `tag[table][slot]` ∈ {NONE, COPYING, COPIED} | Track entry lifecycle during resize | Family 1 |
| Resize state | `status[table]` ∈ {PENDING, ABORTED, PROMOTED}, `copiedCount[table]`, `claimCount[table]` | Coordinate resize completion | Family 1, 3 |
| Table chain | `nextTable[table]`, `rootTable` | Model multi-table structure and promotion | Family 1 |
| Thread parking | `parked[thread]`, `parkerTarget[thread]` | Model park/unpark for deadlock checking | Family 3 |
| Entry reachability | `reachable[entry]` | Track which entries are accessible from any table | Family 4 |
| Two-phase insert | `metaWritten[table][slot]` | Capture the non-atomic CAS-then-meta-store window | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoLostEntry | Safety | A successfully inserted key is findable via get() (unless concurrently removed) | Family 1 |
| NoDuplicateEntry | Safety | Each key exists in at most one slot across all tables at any point | Family 1 |
| CopyCompleteness | Safety | After promotion, all non-tombstone entries from old table exist in new table | Family 1 |
| ProbeChainIntegrity | Safety | For any key K in the table, the probe sequence from h1(K) reaches K's slot (meta matches or continues past non-empty) | Family 1 |
| NoDeadlock | Liveness | Every parked thread is eventually unparked | Family 3 |
| NoUseAfterReclaim | Safety | No entry is reclaimed while reachable from any table in the chain | Family 4 |
| PromotionSafety | Safety | Root CAS only succeeds when all entries are copied | Family 1 |
| AbortSafety | Safety | After abort, all threads eventually converge to the replacement table | Family 1, 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Blocking resize abort: unpark targets wrong parker (raw/mod.rs:2073-2074) | NoDeadlock (thread parked on aborted table's parker never woken) | Family 3 |
| MC-2 | Two-phase insert (CAS entry then store meta): can a concurrent get() miss an entry? | ProbeChainIntegrity (meta still EMPTY while entry is non-null) | Family 1 |
| MC-3 | Nested resize: entry inserted into T2 instead of T1, is copiedCount for T1 still correct? | CopyCompleteness (entries in T2 not counted toward T1's promotion) | Family 1 |
| MC-4 | Concurrent insert + remove + copy at same slot: can entry be lost? | NoLostEntry | Family 1 |
| MC-5 | Deferred retirement: entry removed from non-root table, is it safely unreachable before table drop? | NoUseAfterReclaim | Family 4 |
| MC-6 | Abort during incremental copy: entries with COPYING set in old table, can they be re-copied correctly? | CopyCompleteness | Family 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | MaybeUninit value not dropped on panic in compute_with | Panic injection test with Drop-tracking type |
| TV-2 | Non-power-of-two initial capacity causes assertion on shrink (#89) | Unit test with odd capacity + heavy delete |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Dead code in insert_inner: match arm for Value status from insert_slow (line 575) | Add unreachable!() or remove |
| CR-2 | Relaxed load in insert_at meta fixup (line 934) could theoretically write wrong meta | Very low risk, document intent |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/papaya/analysis-report.md`
- **Key source files**:
  - `artifact/papaya/src/raw/mod.rs` (core lock-free hash table, 2843 lines)
  - `artifact/papaya/src/raw/alloc.rs` (table allocation, 233 lines)
  - `artifact/papaya/src/raw/utils/parker.rs` (thread parking, 149 lines)
  - `artifact/papaya/src/map.rs` (public API, 1669 lines)
- **GitHub issues**: #20 (UAF in FromIterator), #41 (variance/Sync unsoundness), #63 (retain segfault), #74 (alignment), #89 (capacity assertion)
- **Key commits**: `e69e986` (ordering audit), `e157a21` (copy race redesign), `61d8eb4` (parker deadlock), `0574e3e` (alignment fix)
- **Concurrency model**: Category B (concurrent/lock-free) — use timebox trace approach for trace validation
