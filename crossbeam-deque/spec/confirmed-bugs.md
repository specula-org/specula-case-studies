# Confirmed Bug Report — crossbeam-deque

## Summary

- Total findings reviewed: 10 (after deduplication across MC and code review)
- Confirmed: 2 (0 reproduced, 2 code-audit only)
- False positives: 5
- Not a bug (known limitations): 3

**Bottom line**: No safety-critical bugs were found. The crossbeam-deque implementation is correct under normal operation. The two confirmed findings are: (1) an incomplete application of the CVE-2021-32810 mitigation (defense-in-depth gap, not independently exploitable), and (2) a Debug formatting typo.

---

## Confirmed Findings

### Bug 1: Missing Buffer Re-check at LIFO First CAS

- **Source**: MC (VF-2) + Code Review (MC-1/CR-1)
- **Status**: CONFIRMED (code audit) — defense-in-depth gap, not independently exploitable
- **Severity**: Low (defense-in-depth inconsistency; not a safety violation under normal epoch)
- **Location**: `crossbeam-deque/src/deque.rs:1191-1198` (LIFO first CAS in `steal_batch_with_limit_and_pop`)

**Description**:

The CVE-2021-32810 fix (commit `38c07fc`, PR #726) added buffer identity re-checks before every CAS in steal operations to prevent stealers from committing reads from a stale (resized-away) buffer. However, one CAS site was missed: the **first** CAS in the LIFO branch of `steal_batch_with_limit_and_pop()`.

Five CAS sites in steal operations — all have the re-check pattern:
1. `steal()` single CAS (line ~758) — **HAS re-check** ✓
2. `steal_batch_with_limit()` FIFO CAS (line ~924) — **HAS re-check** ✓
3. `steal_batch_with_limit()` LIFO loop CAS (line ~785) — **HAS re-check** ✓
4. `steal_batch_with_limit_and_pop()` FIFO CAS (line ~1169) — **HAS re-check** ✓
5. `steal_batch_with_limit_and_pop()` LIFO loop CAS (line ~1229) — **HAS re-check** ✓

One CAS site — missing the re-check:
6. `steal_batch_with_limit_and_pop()` LIFO **first** CAS (line 1191) — **NO re-check** ✗

The missing site:
```rust
// Line 1189-1198: LIFO first CAS — no buffer re-check
Flavor::Lifo => {
    if self
        .inner
        .front
        .compare_exchange(f, f.wrapping_add(1), Ordering::SeqCst, Ordering::Relaxed)
        .is_err()
    {
        return Steal::Retry;
    }
```

Compare with the LIFO loop CAS just below (line 1229), which has the re-check:
```rust
// Line 1229-1244: LIFO loop CAS — HAS buffer re-check
if self.inner.buffer.load(Ordering::Acquire, guard) != buffer
    || self
        .inner
        .front
        .compare_exchange(f, f.wrapping_add(1), Ordering::SeqCst, Ordering::Relaxed)
        .is_err()
{
    batch_size = i;
    break;
}
```

**Origin of the gap**: The CVE fix (commit `38c07fc`) modified the existing `steal_batch_and_pop()` function but missed the LIFO first CAS. Later, commit `39ffb85` (PR #903) refactored `steal_batch_and_pop()` into `steal_batch_with_limit_and_pop()`, inheriting the missing re-check.

**Trigger scenario**: A stealer calls `steal_batch_with_limit_and_pop` on a LIFO deque. Between the buffer read (line 1142) and the first CAS (line 1191), the worker pushes enough elements to trigger a resize, swapping the buffer pointer from B1 to B2. The CAS succeeds (front hasn't changed), and the stealer returns the value read from the old buffer B1.

**Why it's benign under normal operation**:
1. The epoch pin (line 1118) prevents the old buffer B1 from being freed while the stealer holds its guard
2. The old buffer is frozen after resize — the worker only writes to the new buffer B2
3. The value at B1[front] is the same as B2[front] (resize copies all elements)
4. The CAS on front ensures exclusive ownership of the slot

The returned value is always correct. Model checking confirmed: 8.3M states exhaustively explored with `SkipRecheckBatchLIFO=TRUE` (simulating this exact gap), all 6 safety invariants passed. The violation only occurs when combined with `prematureReclaim=TRUE` (epoch failure), which is prevented by crossbeam-epoch's design.

**Reproduction**: Not attempted. The bug cannot be triggered through public APIs without an epoch failure. A successful steal from the old buffer returns the correct value — no observable anomaly is possible under normal operation.

**Recommendation**: Add the buffer re-check for consistency with all other CAS sites:
```rust
Flavor::Lifo => {
    if self.inner.buffer.load(Ordering::Acquire, guard) != buffer  // ADD THIS
        || self
            .inner
            .front
            .compare_exchange(f, f.wrapping_add(1), Ordering::SeqCst, Ordering::Relaxed)
            .is_err()
    {
        return Steal::Retry;
    }
```

---

### Bug 2: Injector Debug Formatting Typo

- **Source**: Code Review (CR-2)
- **Status**: CONFIRMED (code audit)
- **Severity**: Cosmetic
- **Location**: `crossbeam-deque/src/deque.rs:2169`

**Description**:

The `Debug` implementation for `Injector<T>` incorrectly displays `"Worker { .. }"` instead of `"Injector { .. }"`:

```rust
// Line 2167-2171
impl<T> fmt::Debug for Injector<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad("Worker { .. }")  // BUG: should be "Injector { .. }"
    }
}
```

For comparison, `Worker` correctly displays `"Worker { .. }"` (line 613) and `Stealer` correctly displays `"Stealer { .. }"` (line 1300).

**Trigger scenario**: Any code that formats an `Injector` with `{:?}` (e.g., `println!("{:?}", injector)`) will see `"Worker { .. }"` instead of `"Injector { .. }"`.

**Reproduction**: Trivially observable from code. `format!("{:?}", Injector::<i32>::new())` returns `"Worker { .. }"`.

**Recommendation**: Change `"Worker { .. }"` to `"Injector { .. }"`.

---

## False Positives

### FP-1: CVE-2021-32810 Pattern (VF-1/MC-2)

- **Source**: MC (fault injection)
- **Why false positive**: This is a reproduction of the **known, fixed** CVE-2021-32810. The fault injection (`skipRecheck=ALL`, `prematureReclaim=TRUE`) simulates removing the CVE fix + epoch failure. The fix (buffer re-check before CAS) is present in the current code at 4 of 5 CAS sites, and epoch prevents the remaining gap from being exploitable.

### FP-2: FIFO Pop Rollback (MC-4/Family 4)

- **Source**: MC + Code Review
- **Why false positive**: Model checking exhaustively verified 197K states. The FIFO pop rollback mechanism (fetch_add then conditional store) is safe. During the rollback window, `front > back` causes stealers to see false-empty (returning `Steal::Empty`), but no elements are lost and no double-consumption occurs. Protected by the single-owner invariant (only the Worker calls pop).

### FP-3: Batch Steal Consistency (MC-5)

- **Source**: MC
- **Why false positive**: Model checking verified all-or-nothing semantics for FIFO batch steal and one-by-one semantics for LIFO batch steal across 8.3M states. No double-consumption or element loss.

### FP-4: Single-Element Contention (MC-6)

- **Source**: MC
- **Why false positive**: The CAS on `front` correctly resolves contention between Worker LIFO pop and Stealer. Model checking confirmed NoDoublePop across all state space.

### FP-5: Self-Steal Guard (TV-2)

- **Source**: Code Review
- **Why false positive**: All steal methods check `Arc::ptr_eq(&self.inner, &dest.inner)` at the top, correctly falling back to a simple pop when stealing from self. Working as designed.

---

## Not a Bug (Known Limitations)

### NB-1: Volatile Read/Write UB (Family 2/CR-3/TV-1)

- **Source**: Code Review
- **Description**: Buffer slot access uses `ptr::read_volatile`/`ptr::write_volatile` (lines 78-89), which is not atomic under the C++/Rust memory model. For `T` larger than a machine word, concurrent read/write can produce torn values.
- **Why not a bug**: Known, documented since 2018 (commit `4cbbb7f`). Comments in the code explicitly acknowledge this as "a hack." For word-sized T (the common case, including `Box`, `Arc`, function pointers), hardware provides atomicity. Cannot be fixed without redesigning the data structure to use generic atomics, which Rust doesn't support for arbitrary `T`. This is a fundamental design trade-off, not an oversight.

### NB-2: Epoch Lifecycle Coupling (VF-3/MC-3/Family 3)

- **Source**: MC + Code Review
- **Description**: The deque's safety depends entirely on crossbeam-epoch preventing premature deallocation of old buffers after resize.
- **Why not a bug**: This is by design. Epoch-based reclamation is a well-established technique. The deque correctly pins the epoch before buffer access and defers buffer deallocation. Model checking confirmed that under normal epoch operation, no use-after-free occurs (8.3M states). The fault injection finding (premature reclaim → UAF) confirms the design dependency, not a bug.

### NB-3: Injector Obstruction-Freedom (Family 5/TV-3)

- **Source**: Code Review
- **Description**: The Injector's steal path spins in `wait_write()`/`wait_next()` when a pusher has reserved a slot but hasn't completed the write. A preempted/crashed pusher blocks all stealers indefinitely.
- **Why not a bug**: This is an inherent property of the lock-free linked-block design. The Injector provides obstruction-freedom (progress if a thread runs in isolation), not lock-freedom. This is a deliberate design trade-off for better throughput in non-adversarial conditions. No historical bugs reported from this behavior.
