# Analysis Report: papaya — Lock-Free Concurrent HashMap

## Coverage Statistics

| Metric | Value |
|--------|-------|
| Total commits | 182 |
| Bug-fix commits analyzed | 30 |
| GitHub issues scanned | 42 |
| GitHub issues deeply read (full comments) | 42 |
| Confirmed bugs from issues | 7 |
| Open PRs reviewed | 38 |
| Core source files fully read | 12 (all .rs files) |
| Total LOC analyzed | 6677 |
| Parallel subagents used | 6 |

---

## Phase 1: Reconnaissance

### Codebase Structure

```
src/
├── lib.rs              (243 LOC)  — Crate root, exports
├── map.rs             (1669 LOC)  — Public HashMap/HashMapRef API
├── set.rs              (894 LOC)  — HashSet wrapper
├── serde_impls.rs      (218 LOC)  — Serde support
└── raw/
    ├── mod.rs         (2843 LOC)  — Core lock-free hash table ★
    ├── alloc.rs        (233 LOC)  — Table memory layout & allocation
    ├── probe.rs         (43 LOC)  — Quadratic probing sequence
    └── utils/
        ├── mod.rs      (117 LOC)  — Guard wrapper, CachePadded
        ├── counter.rs   (61 LOC)  — Sharded atomic counter
        ├── parker.rs   (149 LOC)  — Thread parking for resize
        ├── stack.rs     (74 LOC)  — Lock-free append-only stack
        └── tagged.rs   (133 LOC)  — Tagged pointer operations
```

### Concurrency Model

- **Lock-free reads**: get() uses Acquire loads on metadata + entry pointers, no blocking
- **Lock-free writes**: insert/remove use CAS on entry pointers, Relaxed count updates
- **Blocking points**: (1) Mutex for next-table allocation serialization, (2) Parker for blocking resize wait, (3) `wait_copied` spin+park for incremental mode
- **Memory reclamation**: `seize` crate (epoch-based GC), deferred retirement via `guard.defer_retire()`
- **Atomics**: AtomicPtr (entry pointers, table pointer), AtomicU8 (metadata), AtomicUsize (counters)
- **Memory orderings**: Acquire on reads, Release on writes, AcqRel on CAS, SeqCst on parker coordination

### Entry Tag State Machine

```
         [NULL / EMPTY]
              |
        (insert CAS)
              |
         [IN TABLE] ←——— (concurrent get/insert/remove)
              |
     (copy: fetch_or COPYING)
              |
        [COPYING] ——— writers must wait or help copy
              |
    (insert to next table)
              |
   (fetch_or COPIED, blocking)  OR  (store COPYING|COPIED, incremental)
              |
         [COPIED] ——— readers follow to next table
              |
       (table promoted)
              |
      [RETIRED / FREED]
```

### Resize Protocol Overview

1. **Trigger**: Probe limit exceeded during insert, or explicit `reserve()`
2. **Allocation**: One thread wins Mutex, allocates next table (2x or 0.5x capacity)
3. **Blocking mode**: All threads claim chunks, copy entries, spin-wait for promotion
4. **Incremental mode**: Each insert helps copy a chunk, entries marked BORROWED in new table
5. **Promotion**: When all entries copied, CAS root pointer to new table
6. **Abort**: If next table fills up (blocking only), allocate replacement, retry

---

## Phase 2: Bug Archaeology

### Bug-Fix Commits (30 total)

#### Critical — Memory Safety / Unsoundness (6)

| Commit | Summary | Root Cause | File |
|--------|---------|------------|------|
| `0574e3e` | Tagged pointer alignment unsoundness | Entry<i32,i32> only 4-byte aligned, needs 8 for 3 tag bits | raw/mod.rs, tagged.rs |
| `97a519b` | Unsound AsLink impl for Entry | Missing repr(C), field reordering broke offset assumption | raw/mod.rs |
| `8fb6410` | Unsound AsLink impl for TableLayout | Same repr(C) issue for table | raw/alloc.rs |
| `d3f4953` | Insufficient Sync bounds | Missing Send bound, values dropped on wrong thread | map.rs |
| `4edf66d` | HashMap covariant in K/V | Missing PhantomData, allowed lifetime extension | raw/alloc.rs, raw/mod.rs |
| `7267012` | UAF via unprotected guard in FromIterator | seize::unprotected() used with retiring operations | map.rs |

#### High — Correctness (12)

| Commit | Summary | Root Cause | File |
|--------|---------|------------|------|
| `e69e986` | Massive atomic ordering audit | ~40 orderings too strong or too weak | raw/mod.rs (212 lines) |
| `3345c9d` | Revert fence approach, use Acquire on entry loads | Fences insufficient when metadata overwritten | raw/mod.rs |
| `9371590` | Insert/remove race: missing probe advance | Null status after concurrent delete didn't advance probe | raw/mod.rs |
| `61d8eb4` | Parker deadlock: pending counter ordering | fetch_add AFTER insert, should be BEFORE | raw/mod.rs, parker.rs |
| `74975e8` | Parker spurious wakeup check wrong condition | is_none() vs contains_key() for thread presence | parker.rs |
| `9792ded` | Copy completion store not visible to parker | Release store, needed SeqCst for parker protocol | raw/mod.rs, parker.rs |
| `9ea694b` | insert_copy returned wrong table in nested resize | Only returned index, needed (table, index) | raw/mod.rs |
| `f1453ee` | Insert beating copy lost copy count | No copy count update when insert wins race | raw/mod.rs |
| `e157a21` | Insert racing copy: leaked entry | Redesigned to wait for copy instead of racing | raw/mod.rs (221 lines) |
| `00e63b0` | Overwriting copied entry metadata | TOMBSTONE written for COPIED entry, broke probe chain | raw/mod.rs |
| `c4bfe11` | Infinite recursion in compute_with during copy | help_copy=true passed through recursive call | raw/mod.rs (1-line) |
| `02dae66` | retain used entry.raw instead of entry.ptr | Tag bits in raw pointer caused wrong memory access | raw/mod.rs |

#### Medium — Memory Leaks (4)

| Commit | Summary | Root Cause | File |
|--------|---------|------------|------|
| `265c87a` | Leak when insert races copy | Overwritten copy entry never retired | raw/mod.rs |
| `3b25374` | Leak after failed compute_with update | Box<Entry> not freed on None return path | raw/mod.rs |
| `9f16615` | Table state leaked on dealloc | Missing drop_in_place before dealloc | raw/alloc.rs |
| `72c7375` | Recursive retire during HashMap::drop | Collector partially dropped during reclamation | raw/mod.rs |

#### Low — Logic/API (8)

| Commit | Summary | File |
|--------|---------|------|
| `65b02f0` / `f732842` | Incomplete entry migration algorithm | raw/mod.rs |
| `f3e7c4c` | Entry state machine needed 3rd tag bit | raw/mod.rs |
| `01bd220` | Table entry alignment in allocation | raw/alloc.rs |
| `bf330be` | Resize direction wrong (shrink vs grow) | raw/mod.rs |
| `6e818e2` | Incorrect assertion during nested resize | raw/mod.rs |
| `88115e1` | AtomicPtr fetch_or provenance under Miri | raw/mod.rs, tagged.rs |
| `ccb2371` | retain took &mut self instead of &self | map.rs |
| `9279a19` | No backoff in wait_copied | raw/mod.rs |

### Bug Hotspot Analysis

| File | Bug-fix commits | % of all fixes |
|------|----------------|----------------|
| src/raw/mod.rs | 25 | 83% |
| src/raw/alloc.rs | 4 | 13% |
| src/raw/utils/parker.rs | 3 | 10% |
| src/map.rs | 3 | 10% |
| src/raw/utils/tagged.rs | 2 | 7% |

### GitHub Issues — Confirmed Bugs (7)

| Issue | Title | Severity | Status |
|-------|-------|----------|--------|
| #20 | Segfault in FromIterator (UAF) | CRITICAL | Fixed (PR #21, v0.1.3) |
| #41 | Variance unsoundness + insufficient Sync | CRITICAL | Fixed (PR #42/#43, v0.1.7) |
| #63 | retain segfault (tagged pointer deref) | CRITICAL | Fixed (PR #64, v0.2.1) |
| #74 | Tagged pointer alignment unsoundness | HIGH | Fixed (PR #74, v0.2.2) |
| #89 | Non-power-of-two capacity assertion | MEDIUM | Open (PR #91 pending) |
| #61 | retain takes &mut self instead of &self | LOW | Fixed (ccb2371) |
| #79 | HashSet::retain same API issue | LOW | Fixed (PR #80) |

### Temporal Analysis

- **Nov 2023**: Initial development, foundational resize bugs (entry migration incomplete)
- **Mar 2024**: Soundness audit wave (AsLink repr(C), Miri provenance)
- **May 2024**: Memory ordering overhaul (e69e986, 212 lines)
- **Jul 2024**: Intensive stabilization (12 bug fixes in 27 days — resize races, parker deadlocks, leaks)
- **Dec 2024**: Type safety audit (variance, Sync bounds)
- **Mar 2025**: Post-release fixes (retain bugs)
- **Jun 2025**: Alignment unsoundness (tagged pointer fix)

---

## Phase 3: Deep Analysis

### raw/mod.rs Lines 1-1400 (Get, Insert, Remove, Compute)

**Finding D-1: Two-phase insert non-atomicity (lines 894, 904)**
- Insert is CAS-entry-first, store-meta-second. Between these operations, a concurrent probe can see EMPTY metadata and terminate the probe chain early, missing entries at later slots.
- **Status**: Known/accepted. Comments at lines 776-779 acknowledge this trade-off. The authors chose to sacrifice rare reads over adding RMW overhead.
- **Model-checkable**: Yes — can verify whether this causes persistent (not just transient) entry loss.

**Finding D-2: Dead code in insert_inner (line 575)**
- `insert_slow` internally retries on `Value(found)`, so the match arm at line 575 for `UpdateStatus::Found(EntryStatus::Value(_))` is unreachable.
- **Status**: Not a bug, just dead code.

**Finding D-3: MaybeUninit value not dropped on panic in compute_with (lines 1606-1608)**
- If a panic occurs between writing the value into the LazyEntry (MaybeUninit::new) and reading it back, V's destructor is not run.
- **Status**: Minor leak on panic path. Not a safety bug.

### raw/mod.rs Lines 1400-2843 (Resize, Copy, Promote, Retire)

**Finding D-4: Blocking abort unparks wrong parker (lines 2073-2074) — POTENTIAL BUG**
- When `copy_at_blocking` fails (table full), the code stores ABORTED on `next.state().status` (line 2067) then calls `table.state().parker.unpark(&table.state().status)` (lines 2073-2074).
- **Problem**: Threads waiting for copy completion are parked on `next.state().parker` with key `&next.state().status` (lines 2134-2136). The unpark call targets the ROOT table's parker with the ROOT table's status as key — a completely different parker instance and key.
- **Race scenario**: Thread A parks on aborted table's parker (line 2136) BEFORE Thread B stores ABORTED. Thread B stores ABORTED, unparks wrong parker. Thread A never woken. No subsequent code unparks the aborted table's parker.
- **Mitigating factors**: (1) Blocking resize mode only, (2) requires table to be too small (rare with 2x growth), (3) spin-wait (SPIN_WAIT=7) provides a window for the abort store to become visible before parking.
- **Severity**: Medium — deadlock under specific conditions.
- **Model-checkable**: Yes — a liveness check (NoDeadlock) should catch this.

**Finding D-5: try_promote uses Relaxed load for root check (line 2467)**
- `self.table.load(Ordering::Relaxed)` used to check if table is root before CAS.
- **Status**: Not a bug. The subsequent CAS at line 2476-2478 uses proper Release/Acquire and provides the real safety guarantee. The Relaxed pre-check is a correct optimization.

**Finding D-6: Nested resize entry accounting**
- When `insert_copy` probes past the limit in incremental mode (line 2437-2443), it allocates a next-next table and inserts there. The `copiedCount` for the first next table is still incremented for this entry.
- **Status**: Appears correct — the entry is reachable via the table chain (T1 → T2), and get() follows next_table links. But warrants model-checking verification.

### Utility Files (alloc.rs, parker.rs, stack.rs, tagged.rs, counter.rs)

**Finding D-7: Stack has no Drop impl (stack.rs)**
- If a Stack is dropped without drain(), Node heap allocations leak.
- **Status**: Not a bug. `drop_table()` at raw/mod.rs:2799-2802 always drains the deferred stack before deallocation. The Drop impl for HashMap at lines 2737-2755 walks all tables and calls `drop_table()`.

**Finding D-8: Parker pending counter is AtomicUsize, can wrap on 32-bit (parker.rs:17)**
- **Status**: Fixed in commit `61d8eb4` (was already changed). Current code uses `AtomicUsize` which is 64-bit on 64-bit platforms. The count tracking via u64 at line 23 is separate and sufficient.

**Finding D-9: Counter sum() can transiently return 0 for non-empty map (counter.rs:51-60)**
- **Status**: Known/accepted. Comment at lines 57-59 explicitly handles this. Used only for resize heuristics (grow/shrink decision), not for safety.

**Finding D-10: Tagged pointer provenance loss (tagged.rs:33, 108-112)**
- **Status**: Known/accepted. Standard pre-stabilization pattern. Miri fallback path provides correct semantics. The strict_provenance API stabilized in Rust 1.84.0.

---

## Bug Family Grouping

### Family 1: Resize Copy/Insert Race Conditions — 9 historical + 2 new findings
- Commits: `9ea694b`, `f1453ee`, `e157a21`, `00e63b0`, `265c87a`, `f3e7c4c`, `9371590`, `c4bfe11`, `bf330be`
- New: D-1 (two-phase insert), D-6 (nested resize accounting)
- **Assessment**: Most bug-dense area. Every aspect of the resize protocol has had bugs. High priority for TLA+ modeling.

### Family 2: Memory Ordering Gaps — 4 historical
- Commits: `e69e986`, `3345c9d`, `9792ded`, `c353655`
- **Assessment**: Ordering model was not formally specified, leading to repeated revisions. TLA+ can model visibility constraints.

### Family 3: Parker/Synchronization Deadlocks — 3 historical + 1 new finding
- Commits: `61d8eb4`, `74975e8`, `9792ded`
- New: D-4 (abort unpark targets wrong parker)
- **Assessment**: Thread parking is inherently tricky. Liveness checking via TLA+ is ideal.

### Family 4: Epoch-Based Reclamation Safety — 5 historical
- Commits: `97a519b`, `8fb6410`, `7267012`, `72c7375`, `d3f4953`, `4edf66d`
- **Assessment**: Seize interaction bugs are diverse. Some (AsLink, variance) are Rust type-system issues not modelable in TLA+. The deferred retirement stack (D-7) is modelable.

### Family 5: Tagged Pointer Misuse — 3 historical
- Commits: `0574e3e`, `02dae66`, `01bd220`
- **Assessment**: Not suitable for TLA+ modeling. Rust type-level issues.

---

## Excluded Findings (False Positives)

| Finding | Why Excluded |
|---------|-------------|
| clear/retain direct CAS without guard.protect | Epoch-based reclamation protects all pointers loaded during guard's epoch, not just those explicitly protected |
| get() following COPIED to next table may miss deleted entry | Valid linearization — deletion happened between reads |
| remove_if re-evaluates should_remove after CAS failure | Correct behavior — condition checked at linearization point |
| defer_retire infinite loop risk (line 2613 unwrap) | Guard prevents table chain from being reclaimed; table always reachable from root |
| insert_copy skips non-empty meta without key check | COPYING bit ensures only one copier per key; writers wait for copy |
| count goes negative transiently | By design; clamped to 0 at read time |
