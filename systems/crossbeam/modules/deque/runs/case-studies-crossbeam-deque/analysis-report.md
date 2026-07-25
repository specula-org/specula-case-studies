# Analysis Report: crossbeam-deque

## 1. System Overview

- **Name**: crossbeam-deque (part of crossbeam-rs/crossbeam workspace)
- **Language**: Rust
- **Core LOC**: ~2,400 (deque.rs: 2,233, lib.rs: 109, alloc_helper.rs: 85)
- **Algorithm**: Chase-Lev work-stealing deque (Chase & Lev, SPAA 2005; Le et al., PPoPP 2013)
- **Version analyzed**: v0.8.6 (commit in artifact/)

### Architecture

Three main data structures:
1. **Worker<T>** — single-threaded owner; push to back, pop from front (FIFO) or back (LIFO)
2. **Stealer<T>** — multi-threaded read-only handle; steal from front
3. **Injector<T>** — MPMC global FIFO queue (linked blocks of 63 slots each)

### Concurrency Model

- Worker is `!Sync` (single-threaded push/pop via `PhantomData<*mut ()>`)
- Stealer is `Send + Sync` (concurrent steals via CAS on `front`)
- Buffer is a circular array with epoch-based reclamation for safe resizing
- Injector uses CAS on tail (push) and head (steal) with WRITE/READ/DESTROY slot state machine

### Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `crossbeam-deque/src/deque.rs` | 2,233 | All core logic |
| `crossbeam-deque/src/lib.rs` | 109 | Public API re-exports |
| `crossbeam-deque/src/alloc_helper.rs` | 85 | Heap allocation helpers |

---

## 2. Reconnaissance Summary

### Atomic Operations Catalog

| Operation | Location | Ordering | Purpose |
|-----------|----------|----------|---------|
| `back.load` | Worker push/pop | Relaxed | Only worker writes back |
| `front.load` | Worker push | Acquire | Sync with stealer CAS |
| `front.load` | Worker LIFO pop | Relaxed | After SeqCst fence |
| `back.store` | Worker push | Relaxed | After Release fence |
| `back.store` | Worker LIFO pop | Relaxed | Tentative decrement |
| `fence(SeqCst)` | Worker push (424) | SeqCst | Release buffer write |
| `fence(SeqCst)` | Worker LIFO pop (495) | SeqCst | Pair with stealer fence |
| `front.fetch_add` | Worker FIFO pop | SeqCst | Claim front slot |
| `front.compare_exchange` | Worker LIFO pop | SeqCst/Relaxed | Single-element contention |
| `front.load` | Stealer steal | Acquire | Read front index |
| `back.load` | Stealer steal | Acquire | Read back index |
| `buffer.load` | Stealer steal | Acquire | Read buffer pointer |
| `buffer.load` | Stealer steal (re-check) | Acquire | CVE fix validation |
| `front.compare_exchange` | Stealer steal | SeqCst/Relaxed | Claim stolen slot(s) |
| `fence(SeqCst)` | Stealer (conditional) | SeqCst | When already pinned |
| `tail.index CAS` | Injector push | SeqCst/Acquire | Reserve slot |
| `head.index CAS` | Injector steal | SeqCst/Acquire | Claim slot |
| `slot.state fetch_or` | Injector push | Release | Set WRITE bit |
| `slot.state fetch_or` | Injector steal | AcqRel | Set READ bit |
| `fence(SeqCst)` | Injector steal | SeqCst | Head-before-tail ordering |

### Unsafe Code

37 unsafe blocks total. Categories:
- Buffer read/write (volatile ops): 4 blocks — **known UB** (documented)
- Epoch-protected buffer/block access: ~15 blocks — verified correct
- Drop implementations: 4 blocks — verified correct
- Allocation/deallocation: ~8 blocks — verified correct
- Pointer arithmetic (Buffer::at): 1 block — verified correct

---

## 3. Bug Archaeology

### Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits touching crossbeam-deque/src/ | 75 |
| Bug-fix commits identified | 10 |
| GitHub issues read in full (with comments) | 42+ |
| GitHub PRs read in detail | 30+ |
| Issues directly related to crossbeam-deque | 21 |
| Issues related to crossbeam-epoch (deque dependency) | 12 |
| Confirmed deque bugs (fixed) | 10 |
| Open/unresolved issues affecting deque | 5 |
| CVEs | 1 (CVE-2021-32810) |

### Historical Bugs (Chronological)

| # | Commit | Summary | Severity | Year |
|---|--------|---------|----------|------|
| 1 | `4cbbb7f` | Documented volatile read/write data race (UB) | Medium | 2018 |
| 2 | `89828aa` | Wrong buffer used in batch-steal reversal | Critical | 2019 |
| 3 | `4d574d4` | FIFO/LIFO cross-steal ordering wrong | High | 2019 |
| 4 | `6c9f76f` | Self-steal causes corruption | High | 2019 |
| 5 | `68e8708` | ManuallyDrop unsoundness in Injector slots | Critical | 2020 |
| 6 | `1df3ee7` | Injector::len() block-boundary edge case | Medium | 2020 |
| 7 | `38c07fc` | Steal race condition (stale buffer read) | Critical | 2021 |
| 8 | `83b44f9` | Stacked Borrows in Buffer::alloc (mem::forget) | Medium | 2022 |
| 9 | `8d7db8c` | Dangling Boxes / Stacked Borrows in buffer ops | Critical | 2022 |
| 10 | `698b84a` | Stack overflow on large types in Injector | High | 2024 |

### Open/Unresolved Issues

| Issue | Description | Status |
|-------|-------------|--------|
| #869 | M1 ARM segfault (MAX_OBJECTS change) | Mitigated (reverted), root cause unknown |
| #1207 | TSan warnings with multiple rayon pools | Open (by design) |
| #846 | Loom support for crossbeam-deque | Open (draft PR #849) |
| #730 | Add fuzzing tests | Open |
| #688 | Document unsafety use | Open |

---

## 4. Deep Analysis Findings

### Finding DA-1: Missing Buffer Re-check in steal_batch_with_limit_and_pop LIFO First CAS

**Location**: `deque.rs:1083-1087`

**Description**: In `steal_batch_with_limit_and_pop`, the LIFO path's *first* CAS on `front` does NOT include a buffer re-check before the CAS. This is the only CAS site in the Stealer that lacks this check — all 5 other CAS sites were patched as part of the CVE-2021-32810 fix.

**CAS sites comparison**:
1. `steal()` line 670-675: **has re-check**
2. `steal_batch_with_limit()` FIFO line 816-826: **has re-check**
3. `steal_batch_with_limit()` LIFO line 863-874: **has re-check**
4. `steal_batch_with_limit_and_pop()` FIFO line 1061-1072: **has re-check**
5. `steal_batch_with_limit_and_pop()` LIFO first CAS line 1083-1087: **NO re-check**
6. `steal_batch_with_limit_and_pop()` LIFO per-element CAS line 1121-1131: **has re-check**

**Risk assessment**: On 64-bit systems, exploiting this requires isize index wraparound (~2^63 operations), which is infeasible. On 32-bit systems, isize wraps after ~2^31 operations (~2B), which is theoretically reachable in a long-running system. Epoch protection prevents use-after-free of the old buffer, and resize faithfully copies data, so the stale read returns the correct value. The risk is limited to a scenario where the buffer is resized AND front wraps back to the exact same value — practically unexploitable but inconsistent with the defense-in-depth pattern applied everywhere else.

**Verdict**: Low-severity inconsistency. Likely an oversight in the CVE fix.

### Finding DA-2: Volatile Read/Write as Formal UB (Unfixed, Documented)

**Location**: `deque.rs:73-90` (Buffer::read and Buffer::write)

**Description**: `Buffer::read` and `Buffer::write` use `ptr::read_volatile` / `ptr::write_volatile` for concurrent buffer slot access between the worker (push) and stealers (steal). The code comments explicitly acknowledge this is "technically speaking a data race and therefore UB" and describe it as "a hack."

**Why it exists**: The Chase-Lev algorithm requires non-atomic concurrent access to buffer slots for arbitrary types `T`. Rust's atomic types only work for primitive types that fit in a machine word. There is no `AtomicT` for arbitrary `T`.

**Why it works in practice**: On x86, aligned word-sized loads/stores are hardware-atomic. On ARM, aligned loads/stores of pointer-size are similarly atomic. The algorithm only commits stolen data after a successful CAS, so torn reads (for large T) are detected and discarded.

**Remaining risk**: For `T` larger than a machine word (e.g., `(u64, u64)` on 32-bit), concurrent read/write can produce torn values. The CAS will NOT catch this because the CAS validates `front` (an index), not the data. The torn data is then returned as valid. This is a real correctness risk for large T on platforms without hardware-atomic wide loads.

**Verdict**: Known, documented, unfixable without redesigning the data structure. Model-checkable by modeling torn reads as a fault injection.

### Finding DA-3: Injector Obstruction-Freedom (Not Lock-Free)

**Location**: `deque.rs:1224-1229` (wait_write), `deque.rs:1272-1280` (wait_next)

**Description**: The Injector's `wait_write()` and `wait_next()` methods are unbounded spin loops. If a pusher CASes `tail.index` (reserving a slot) but is preempted before writing the data or linking the next block, ALL stealers will spin indefinitely.

**Timeline of vulnerability**:
1. Pusher succeeds CAS at line 1415 (reserves slot)
2. Pusher writes task at line 1434
3. Pusher sets WRITE bit at line 1435

Between steps 1 and 2, any stealer trying to consume this slot will spin in `wait_write()`. Between block boundary CAS and `block.next` store (lines 1427-1429), stealers crossing the block boundary spin in `wait_next()`.

**Verdict**: Design choice, not a bug. Important for the modeling brief — the Injector is obstruction-free, not lock-free. A stalled pusher can block all stealers.

### Finding DA-4: FIFO Pop Rollback Window

**Location**: `deque.rs:467-472`

**Description**: In FIFO mode, `pop()` uses `fetch_add(1, SeqCst)` on `front` (line 467). If the queue turns out to be empty (a stealer drained it), the worker rolls back `front` via `store(f, Relaxed)` (line 471). Between the `fetch_add` and the `store`, `front` is temporarily over-advanced by 1.

**Effect**: During this window (~nanoseconds), stealers see `front` past `back` and return `Empty` or `Retry`. No element duplication or loss occurs — it's a transient false-empty observation.

**Panic risk**: If the worker thread panics between `fetch_add` and `store`, `front` is permanently advanced by 1, causing one element to be leaked (never dequeued). This is consistent with Rust's leak-is-safe philosophy.

**Verdict**: Not a safety bug. Relevant for modeling: the FIFO pop is NOT linearizable at the `fetch_add` — the linearization point is either the `fetch_add` (success) or the `store` rollback (failure).

### Finding DA-5: 32-bit Index Overflow

**Location**: Throughout (all index arithmetic)

**Description**: The Worker uses `isize` indices; the Injector uses `usize` indices. On 32-bit platforms:
- Worker: isize wraps after ~2^31 operations. `wrapping_add`/`wrapping_sub` handle this correctly for the Worker/Stealer deque (the circular buffer mask handles any index value).
- Injector: usize wraps after ~2^32 pushes. The LAP-based block addressing (`index / LAP`) could produce incorrect block comparisons after wrapping. Specifically, `head >> SHIFT == tail >> SHIFT` could report equal when they are not (or vice versa).

**Verdict**: Extremely unlikely in practice but theoretically possible on 32-bit. Not fixable without using u64 indices. Noted for modeling scope.

### Finding DA-6: Injector Debug Impl Typo

**Location**: `deque.rs:2061`

**Description**: `Injector`'s `Debug` impl outputs `"Worker { .. }"` instead of `"Injector { .. }"`.

**Verdict**: Cosmetic bug. Not relevant for modeling.

### Finding DA-7: Speculative Batch Copy Creates Orphaned Data

**Location**: `deque.rs:797-828` (steal_batch_with_limit FIFO path)

**Description**: In the FIFO batch steal path, elements are speculatively copied to the destination buffer (lines 797-810) before the CAS validates the steal (line 820). If the CAS fails (another stealer won), the copied data in the destination buffer is orphaned — it exists at indices past `dest.inner.back` and will eventually be overwritten by future pushes.

**Safety**: Safe because `MaybeUninit<T>` has no drop glue, so the orphaned copies don't cause double-free. The destination's `back` pointer is not advanced on CAS failure, so no one reads the orphaned data.

**Verdict**: Safe by design. Relevant for modeling: the speculative copy is a separate action from the CAS commit.

---

## 5. Bug Family Analysis

### Family 1: Steal-Resize Buffer Race (TOCTOU)

**Mechanism**: The stealer reads data from the buffer, then validates via CAS on `front`. Between the read and the CAS, the worker can resize the buffer (allocate new, copy, swap pointer, retire old). The CAS on `front` alone is insufficient to detect the buffer swap because `front` is an index, not a buffer pointer.

**Evidence**:
- Historical: CVE-2021-32810 (`38c07fc`) — versions v0.7.0-v0.7.3 and v0.8.0 yanked
- Historical: M1 ARM segfault (#869) — root cause unknown, suspected epoch/deque interaction
- Code analysis: `deque.rs:1083-1087` — missing buffer re-check on first CAS in LIFO steal_batch_with_limit_and_pop (DA-1)

**Affected code paths**:
- `Stealer::steal()` (line 674)
- `Stealer::steal_batch_with_limit()` FIFO (line 820), LIFO (line 870)
- `Stealer::steal_batch_with_limit_and_pop()` FIFO (line 1067), LIFO first (line 1086 — **missing re-check**), LIFO loop (line 1127)

**Assessment**: 1 CVE, 1 unresolved segfault, 1 new finding. High severity. The CVE fix (buffer re-check before CAS) is correct and complete at 5 of 6 sites. The missing site (line 1083) is safe due to epoch protection but inconsistent.

**Priority**: **High**

### Family 2: Memory Model / Formal UB

**Mechanism**: The implementation uses volatile read/write operations (`ptr::read_volatile`/`ptr::write_volatile`) for concurrent buffer slot access. Under the C++/Rust memory model, these are non-atomic operations, making concurrent access a data race (UB). Additionally, prior to fixes, the code used `ManuallyDrop<T>` and `mem::forget` in ways that violated Stacked Borrows.

**Evidence**:
- Historical: `4cbbb7f` — documented volatile UB (2018, **still present**)
- Historical: `68e8708` — ManuallyDrop → MaybeUninit in Injector (2020)
- Historical: `8d7db8c` — Buffer read/write changed to MaybeUninit (2022, Ralf Jung)
- Historical: `83b44f9` — Buffer::alloc mem::forget → ManuallyDrop (2022)
- Code analysis: `deque.rs:73-90` — volatile read/write remains UB

**Affected code paths**:
- `Buffer::read()` (line 88-89) — volatile read
- `Buffer::write()` (line 78-79) — volatile write
- All push/pop/steal operations that call these

**Assessment**: 4 historical fixes, 1 unfixed (volatile UB). The unfixed issue is a known design tradeoff. For types T that fit in a machine word, hardware provides atomicity. For larger T, torn reads are theoretically possible.

**Priority**: **Medium** (documented, understood, but formally unsound)

### Family 3: Cross-Flavor and Batch Operation Correctness

**Mechanism**: The codebase supports 6 combinations of (source_flavor, dest_flavor) for batch steals, plus FIFO/LIFO modes for single steals. Code paths handling these combinations have historically contained ordering errors and copy-paste mistakes.

**Evidence**:
- Historical: `89828aa` — wrong buffer (source vs dest) in reversal code (Critical, 2019)
- Historical: `4d574d4` — missing reversal for cross-flavor batch steal (High, 2019)
- Historical: `6c9f76f` — self-steal corruption, no guard against stealing from own deque (High, 2019)

**Affected code paths**:
- `Stealer::steal_batch_with_limit()` LIFO reversal (lines 896-907)
- `Stealer::steal_batch_with_limit_and_pop()` LIFO reversal (lines 1149-1160)
- All batch steal paths with `dest: &Worker<T>`

**Assessment**: 3 historical bugs, all fixed. The current code correctly handles all flavor combinations. The reversal logic has been verified correct. Self-steal guard is present (lines 751-753, 993-996).

**Priority**: **Low** (all historical bugs fixed, verified correct)

### Family 4: Epoch-Deque Lifecycle Interaction

**Mechanism**: The deque relies on crossbeam-epoch for safe deferred deallocation of old buffers after resize. Bugs in epoch, or changes to epoch's reclamation timing, can cause use-after-free or other memory corruption in the deque.

**Evidence**:
- Historical: #869 — M1 ARM segfault from MAX_OBJECTS change in epoch (2022, mitigated, root cause UNKNOWN)
- Historical: #238 — UAF in MSQueue from epoch reclamation (fixed)
- Historical: #545 — Stacked Borrows violations in epoch (fixed by PR #871)
- Historical: #395 — unsound offsetof in epoch dependency (fixed)

**Affected code paths**:
- `Worker::resize()` (lines 305-321) — defers old buffer deallocation
- `Stealer::steal*()` — holds epoch Guard during steal
- All stealers — safety depends on epoch preventing premature buffer free

**Assessment**: 1 unresolved issue (#869, mitigated). The deque's correctness is coupled to epoch's correctness. If epoch has bugs, deque inherits them.

**Priority**: **Medium** (one unresolved issue, indirect dependency)

### Family 5: Injector Queue Internal Correctness

**Mechanism**: The Injector is a separate MPMC queue (not Chase-Lev) using linked blocks with slot-level state tracking (WRITE/READ/DESTROY bits). Its correctness depends on the cooperative destruction protocol and proper index management.

**Evidence**:
- Historical: `68e8708` — ManuallyDrop unsoundness in slots (Critical, 2020)
- Historical: `1df3ee7` — len() block-boundary edge case (Medium, 2020)
- Historical: `698b84a` — stack overflow from on-stack block construction (High, 2024)
- Code analysis: DA-3 — obstruction-freedom (wait_write/wait_next spin loops)
- Code analysis: DA-5 — 32-bit index overflow potential

**Affected code paths**:
- `Injector::push()` (lines 1388-1446) — slot reservation and block allocation
- `Injector::steal()` (lines 1464-1540) — slot consumption and block destruction
- `Block::destroy()` (lines 1284-1301) — cooperative WRITE/READ/DESTROY protocol
- `wait_write()` (lines 1224-1229) — unbounded spin

**Assessment**: 3 historical bugs, all fixed. The WRITE/READ/DESTROY protocol is verified correct. The obstruction-freedom is a design choice. 32-bit index overflow is theoretical.

**Priority**: **Medium** (separate from Chase-Lev, needs independent modeling)

---

## 6. Cross-Implementation Comparison

### Chase-Lev Reference vs. crossbeam

| Feature | Chase-Lev (2005) / Le et al. (2013) | crossbeam-deque |
|---------|--------------------------------------|-----------------|
| Pop direction | Back only (LIFO) | Back (LIFO) or Front (FIFO) |
| Steal direction | Front (top) | Front |
| Buffer resize | Grow, no shrink | Grow and shrink |
| Buffer reclamation | Unspecified (GC assumed) | Epoch-based (crossbeam-epoch) |
| Batch steal | Not supported | Supported (all-or-nothing FIFO, one-by-one LIFO) |
| Multiple stealers | Supported | Supported |
| Global injector | Not present | MPMC linked-block queue |
| Memory orderings | Specified by Le et al. | Matches Le et al. (verified) |
| Buffer access | "non-atomic" | Volatile read/write (UB) |

### Key Deviations Assessed

1. **FIFO pop** (fetch_add on front): Safe due to single-owner invariant. Introduces rollback window (DA-4).
2. **Buffer re-check** (CVE fix): Not in original algorithm, necessary extension for resize safety.
3. **Epoch-based reclamation**: Sound replacement for GC. Prevents ABA on buffer pointer.
4. **Batch steal**: New operations. FIFO batch is linearizable (single CAS). LIFO batch reduces to individual steals.
5. **Buffer shrink**: Not in Chase-Lev. Safe — only shrinks when len < cap/4, and only from the owner thread.

---

## 7. Coverage and Methodology Notes

### Commit Analysis
- Analyzed all 75 commits touching `crossbeam-deque/src/`
- Identified 10 bug-fix commits (13.3% of total)
- Read full diffs for all 10 bug-fix commits

### Issue/PR Analysis
- Searched 8 query categories across crossbeam-rs/crossbeam
- Read 42+ issues and 30+ PRs with full comment threads
- Also searched crossbeam-rs/crossbeam-deque standalone repo (4 issues, none bug-related)
- Checked 3 security advisories (RUSTSEC-2021-0093 directly relevant)

### Deep Analysis
- Read deque.rs (2,233 lines) in full, split across 4 parallel analysis agents
- Verified all atomic orderings against Le et al. PPoPP 2013
- Verified all 37 unsafe blocks for safety invariant correctness
- Checked all 6 CAS sites for buffer re-check consistency
- Traced all cross-flavor batch steal orderings with concrete examples

### False Positives Excluded
- TSan warnings (#589, #646, #1207): by-design data raciness, not real bugs
- ARM weak CAS issue (#609): LLVM/hardware bug, not crossbeam
- WASM panic (#1116): platform bug, not crossbeam
- Epoch TLS unsoundness claim (#422): retracted by reporter
