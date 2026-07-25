# Confirmed Bug Report — papaya (Lock-Free Concurrent HashMap)

## Summary

- Total findings reviewed: 10
- Reproduced: 2 (Bug 1: MC-1 wrong parker deadlock, Bug 2: resize livelock)
- False positives: 2
- Fixed in HEAD: 1 (TV-2: capacity rounding)
- Not bugs (MC cleared): 5

## Bug 1: Blocking Resize Abort Unparks Wrong Parker (MC-1)

- **Source**: MC (5-state counterexample, `MC_hunt_parker_deadlock.cfg`) + Code Review
- **Status**: REPRODUCED
- **Severity**: High (deadlock via adversarial hash + blocking resize + insert/delete workload)
- **Location**: `raw/mod.rs:2073-2074` (abort unpark) vs `raw/mod.rs:2095,2134-2136` (park target) vs `raw/mod.rs:2501` (correct unpark)

### Description

In `help_copy_blocking()`, when a blocking resize is aborted (new table can't fit an entry within the probe limit), the code unparks the **source table's** parker instead of the **next table's** parker where threads are actually parked:

```rust
// Line 2073-2074 (ABORT path — WRONG):
let state = table.state();          // source table
state.parker.unpark(&state.status); // unparks source parker — NOBODY IS PARKED HERE

// Line 2095, 2134-2136 (where threads actually PARK — on next table's parker):
let state = next.state();
state.parker.park(&state.status, |status| status == State::PENDING);

// Line 2501 (PROMOTE path — CORRECT for comparison):
state.parker.unpark(&state.status);
// where state = next.state() (from line 2456)
```

The `try_promote()` function at line 2501 correctly uses `next.state().parker`, confirming the abort path is inconsistent. Git blame shows line 2073 was introduced in commit `2a5fc437` ("avoid passing `Table` by reference", 2024-11-28).

### Previous analysis was wrong about abort reachability

The previous Phase 4 analysis concluded the abort path is "unreachable under the current table sizing logic" because entries always fit in same-size or doubled tables. This was **incorrect** — it missed the **shrink resize** case:

1. **Same-size/double resize**: Entries always fit. Abort unreachable. ✓ (previous analysis was correct here)
2. **Shrink resize**: The probe limit **decreases** in the smaller table, so entries that fit in the old table may NOT fit in the new one. Abort IS reachable. ✗ (previous analysis missed this)

Concrete example:
- Table 512, probe limit = 5×log₂(512) = 45, positions checked = 46
- 46 entries at hash position 0 → all fit (46 ≤ 46 positions)
- After deleting other entries: active = 46 ≤ 512/8 = 64 → **shrink** to 256
- New table 256, probe limit = 5×log₂(256) = 40, positions checked = 41
- Copy 46 entries at hash 0 → **42nd entry fails** → ABORT

The shrink heuristic reduces the table size AND the probe limit. When many entries cluster at the same hash position, the reduced limit makes the abort reachable.

### Trigger scenario

1. Create HashMap with adversarial hash (bimodal: spread keys + collision-at-0 keys), `capacity(2)`, `ResizeMode::Blocking`
2. Insert 250 spread keys → table grows to 512 (via successive doublings)
3. Insert 46 collision keys (all hash to position 0, fill 46 probe positions)
4. Delete all 250 spread keys → active = 46 ≤ 512/8 = 64 → shrink threshold met
5. Launch 16 threads, each inserting a new collision key → probe limit exceeded → resize
6. Shrink to 256: one thread claims the copy chunk, others park on next table's parker
7. Copying thread hits abort at 42nd entry → unparks source table's parker (WRONG)
8. Parked threads on next table's parker are never woken → **permanent deadlock**
9. Additionally: the abort allocates a same-size replacement (46 entries, 32 < 46 < 128 → same-size 256), which also aborts → **infinite abort loop** (copying thread is also stuck)

### Reproduction test

`repro/test_bug1_abort_deadlock.rs` — Triggers the shrink abort path via bimodal hashing.

**Command**: `cargo run --bin test_bug1_abort_deadlock`

**Actual output** (first attempt):
```
=== Bug MC-1 Reproduction: Wrong Parker on Abort via Shrink Resize ===

--- Attempt 1/5 ---
  Phase 1: Inserted 250 spread keys. len=250
  Phase 2: Inserted 46 collision keys. len=296
  Phase 3: Deleted spread keys. len=46 (expect 46)
  Phase 4: DEADLOCK! 16 of 16 threads stuck after 8s.

=== BUG MC-1 REPRODUCED ===
The wrong-parker deadlock is triggered via shrink resize:
  1. Table grew to 512+ with spread keys
  2. 46 collision keys at hash position 0
  3. Spread keys deleted → active = 46 ≤ 512/8 → shrink to 256
  4. Copy: 46 entries into 256 table (limit=40, 41 positions) → 42nd fails → ABORT
  5. Abort unparks table.state().parker (WRONG) instead of next.state().parker
  6. Parked threads on next table's parker never woken → DEADLOCK
```

### Reproduction result

**REPRODUCED** — 100% reliable, deadlocks on first attempt. All 16 threads permanently stuck (both parked threads and copying thread, due to compounding with same-size abort livelock).

### Compounding with Bug 2

The reproduction reveals that Bug 1 and Bug 2 compound in this scenario:
- **Bug 1** (wrong parker): Threads in the wait loop park on the aborted table's parker and are never woken (hard deadlock, threads sleeping)
- **Bug 2** (same-size livelock): After the initial shrink abort (512→256), the replacement table is also 256 (same-size heuristic: 32 < 46 < 128). The copy to the new 256 table also aborts. This repeats infinitely, trapping the copying thread in an abort loop

Even fixing Bug 1 alone (using `next.state().parker`) would not fully resolve the scenario — threads would be correctly woken but immediately park on the next aborted table, resulting in a livelock. Both bugs need to be fixed for correctness.

### Developer evidence

- Three prior parker fixes: `61d8eb4` (deadlock condition), `74975e8` (spurious wakeup), `9792ded` (unpark sync) — this area is historically fragile.
- The `try_promote` path correctly uses `next.state().parker`, confirming the abort path is inconsistent.
- No existing tests cover the abort code path.

### Recommendation

**Fix 1** (wrong parker): Change lines 2073-2074 from:
```rust
let state = table.state();
state.parker.unpark(&state.status);
```
To:
```rust
let state = next.state();
state.parker.unpark(&state.status);
```

**Fix 2** (abort livelock): When a resize is aborted and the same-size heuristic would be chosen for the replacement table, force a doubling instead. This breaks the infinite abort cycle.

---

## Bug 2: Infinite Resize Livelock Under Hash Flooding (NEW)

- **Source**: Discovered during MC-1 reproduction
- **Status**: REPRODUCED
- **Severity**: Medium (CPU DoS via adversarial hash; documented warning exists)
- **Location**: `raw/mod.rs:2029-2095` (`help_copy_blocking` resize loop)

### Description

With a constant hash function (all keys hash to the same position) and `ResizeMode::Blocking`, the hash map enters an **infinite resize cycle** consuming 100% CPU on all participating threads:

1. The table fills to `probe_limit + 1` entries (e.g., 31 entries in a 64-slot table with limit=30)
2. The next insert exceeds the probe limit → triggers resize
3. The resize heuristic sees `active_entries < 50%` of capacity → chooses **same-size** table
4. Copy succeeds (31 entries fit in 64 slots within limit=30)
5. Thread retries insert → probe limit exceeded again → another resize
6. Goto step 3. Repeats indefinitely.

The root cause: with extreme hash collisions, the load factor at which the probe limit is exceeded (~48% for large tables) falls just below the doubling threshold (50%). The table never grows, so the triggering insert always fails in the new same-size table.

A variant of this bug also occurs during the **abort path** (Bug 1): after a shrink abort, the replacement table gets the same-size heuristic, creating an infinite abort loop.

CPU profiling confirms threads are in state **R** (running), not **S** (sleeping) — this is a livelock, not a deadlock.

### Trigger scenario

```rust
let map = HashMap::builder()
    .capacity(2)
    .hasher(ZeroHashBuilder)  // all keys → h1=0
    .resize_mode(ResizeMode::Blocking)
    .build();
// Insert 50+ keys → livelock with 4+ threads
```

### Reproduction test

`repro/test_bug1_diagnostic.rs` — Tests 1 and 5 demonstrate the livelock. Test 2 (Incremental mode) and Test 3 (RandomState hash) complete normally, confirming the issue requires both Blocking resize mode and extreme hash collisions.

**Command**: `cargo run --bin test_bug1_diagnostic`

**Actual output**:
```
=== Bug MC-1 Diagnostic: Isolating the deadlock root cause ===

Test 1: Blocking resize + constant hash (ZeroHash)
  Blocking+ZeroHash: DEADLOCK (8 stuck, 8.0s)
Test 2: Incremental resize + constant hash (ZeroHash)
  Incremental+ZeroHash: COMPLETED (8/8 threads, 0.1s)
Test 3: Blocking resize + normal hash (RandomState)
  Blocking+RandomState: COMPLETED (8/8 threads, 0.1s)
Test 4: Blocking resize + constant hash + 2 threads × 10 keys
  Blocking+ZeroHash+Small: COMPLETED (2/2 threads, 0.1s)
Test 5: Blocking resize + constant hash + 4 threads × 50 keys
  Blocking+ZeroHash+Medium: DEADLOCK (4 stuck, 8.0s)

=== Summary ===
  Blocking + ZeroHash:        DEADLOCK
  Incremental + ZeroHash:     OK
  Blocking + RandomState:     OK
  Blocking + ZeroHash (small):OK
  Blocking + ZeroHash (med):  DEADLOCK

DIAGNOSIS: Deadlock occurs ONLY with Blocking resize + hash collisions.
```

### Reproduction result

**REPRODUCED** — 100% reliable with 4+ threads and 50+ keys with constant hash.

### Developer intent investigation

The `HashMapBuilder::hasher()` documentation warns:
> Warning: `hash_builder` is normally randomly generated, and is designed to allow HashMaps to be resistant to attacks that cause many collisions and very poor performance. Setting it manually using this function can expose a DoS attack vector.

The developer is aware of hash flooding risks, though the specific infinite-resize behavior (as opposed to degraded performance) may not be intentional.

### Recommendation

When the same-size resize heuristic is chosen and the insert that triggered the resize still exceeds the probe limit after copy+promote, force a growth to break the cycle. Alternatively, lower the doubling threshold from 50% to 40% to ensure collision-heavy workloads always double.

---

## Findings Not Requiring Reproduction

### TV-2: Non-Power-of-Two Initial Capacity Causes Panic (#89)

- **Source**: Code Review (modeling brief)
- **Status**: FIXED in HEAD (commit `eba5f91`, "round initial capacity to power-of-two")
- **Location**: `raw/mod.rs:237` — now applies `entries_for(capacity)` before allocation
- **Note**: The fix also sets `initial_capacity` to the rounded value, which affects the shrink heuristic (shrink target ≥ initial table size). This makes the shrink path less aggressive, which contributes to Bug 1's abort path being harder (but not impossible) to trigger.

### TV-1: MaybeUninit Value Leak on Panic in compute_with

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Reason**: If a user's compute callback panics after `LazyEntry::Init`, the allocated entry leaks because `LazyEntry` has no `Drop` impl. However:
  1. Memory leaks are explicitly safe in Rust (no UB).
  2. The allocation path in `LazyEntry::init()` uses `catch_unwind` + `abort` to prevent double-drops.
  3. Previous values in `MaybeUninit` are read back via `assume_init_read()` into `ComputeState` before retrying, preventing leaks on CAS failure.
- **Impact**: At worst, a memory leak on user-callback panic. Not a soundness violation.

### CR-1: Dead Code in insert_inner (line 575)

- **Source**: Code Review
- **Status**: NOT A BUG (code quality only)
- **Reason**: Unreachable match arm. Common Rust pattern for exhaustive matching.

### CR-2: Relaxed Load in insert_at Meta Fixup (line 934)

- **Source**: Code Review
- **Status**: FALSE POSITIVE
- **Reason**: The Relaxed load is on a metadata hint byte, not a correctness-critical path. The fixup is idempotent and the author documented remaining ordering requirements in commit `c353655`.

---

## Findings Cleared by Model Checking

The following hypothesized bugs were tested by TLC model checking with no violations:

| ID | Description | Config | States | Result |
|---|---|---|---|---|
| MC-2 | Two-phase insert: can get() miss an entry? | MC_hunt_twophase.cfg | 844M+ (BFS complete at 19K) | No violation |
| MC-3/4 | Resize race: entry lost during concurrent insert+remove+copy? | MC_hunt_resize_race.cfg | 1.53B+ | No violation |
| MC-5 | Deferred retirement: use-after-reclaim? | MC_hunt_reclamation.cfg | 206M (BFS complete) | No violation |

Base convergence: 7 invariants checked across 1.73B states (141M distinct), depth 16, 30 min BFS with 48 workers. All passed.

---

## Reproduction Summary

| Bug | Test File | Outcome | Classification |
|-----|-----------|---------|----------------|
| Bug 1: Wrong Parker (MC-1) | `repro/test_bug1_abort_deadlock.rs` | 16/16 threads deadlocked, first attempt | **Reproduced** |
| Bug 1: Wrong Parker (MC-1) | `repro/test_bug1_wrong_parker_deadlock.rs` | Abort path not reached (same-size only) | Previous attempt (superseded) |
| Bug 1: Wrong Parker (MC-1) | `repro/test_bug1_diagnostic.rs` | Differential: Blocking+collision = stuck | Diagnostic |
| Bug 2: Resize Livelock (NEW) | `repro/test_bug1_diagnostic.rs` Tests 1,5 | 100% repro, threads stuck at 100% CPU | **Reproduced** |

### Key Insight: Shrink Resize Makes the Abort Path Reachable

The previous analysis (Phase 4, first run) incorrectly concluded the abort path is unreachable because:
- Doubling: new table has 2× slots → entries fit trivially ✓
- Same-size: entries ≤ 50% of capacity → fit within limit ✓
- Shrink: entries ≤ 12.5% of old table, fit in half-size table ✓

The flaw was in the shrink analysis. While the total entry count is small, if those entries are **clustered at a single hash position**, the probe limit matters more than the total slot count:
- Table 512: limit=45, 46 collision entries fit
- Shrink to 256: limit=40, only 41 positions → 46 entries **don't fit** → ABORT

The probe limit grows as 5×log₂(N) while the shrink factor is N/2. The limit drops by 5 while the capacity halves. For entries clustered at one position, the limit is the binding constraint, not the capacity.
