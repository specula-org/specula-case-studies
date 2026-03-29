# Modeling Brief: crossbeam-deque

## 1. System Overview

- **System**: crossbeam-deque — Rust work-stealing deque used by Rayon, Tokio, and the broader Rust async ecosystem
- **Language**: Rust, ~2,400 LOC core logic (single file: `deque.rs`)
- **Protocol**: Chase-Lev work-stealing deque (Chase & Lev, SPAA 2005; Le et al., PPoPP 2013) + MPMC Injector queue
- **Key architectural choices**:
  - Two pop modes: **FIFO** (pop from front via `fetch_add`) and **LIFO** (pop from back, classic Chase-Lev)
  - **Batch steal** operations (not in original algorithm) — all-or-nothing CAS for FIFO, one-by-one for LIFO
  - Buffer slots use **volatile read/write** (formally UB) for concurrent access — no generic atomic for arbitrary `T`
  - **Epoch-based reclamation** (crossbeam-epoch) for safe deferred deallocation of old buffers after resize
  - **Buffer re-check** before CAS in steal (CVE-2021-32810 fix) — extension to Chase-Lev to handle resize races
- **Concurrency model**: Single-owner Worker (`!Sync`); multiple concurrent Stealers; buffer protected by epoch guards

## 2. Bug Families

### Family 1: Steal-Resize Buffer Race (HIGH)

**Mechanism**: TOCTOU between speculative buffer read and CAS commit. A stealer reads data from the buffer, then CAS-validates `front`. Between the read and CAS, the worker can resize (swap buffer pointer), causing the stealer to return data from a stale buffer. The CAS on `front` alone is insufficient — it validates the index, not the buffer identity.

**Evidence**:
- Historical: CVE-2021-32810 (commit `38c07fc`) — 5 crate versions yanked; stealer reads freed/stale buffer
- Historical: #869 — M1 ARM segfault after epoch MAX_OBJECTS change; root cause UNKNOWN, suspected deque/epoch timing
- Code analysis: `deque.rs:1083-1087` — missing buffer re-check on first CAS in LIFO `steal_batch_with_limit_and_pop` (only CAS site without the CVE fix pattern)

**Affected code paths**:
- `Stealer::steal()` (line 674) — re-check present
- `Stealer::steal_batch_with_limit()` FIFO (line 820) / LIFO (line 870) — re-check present
- `Stealer::steal_batch_with_limit_and_pop()` FIFO (line 1067) — re-check present
- `Stealer::steal_batch_with_limit_and_pop()` LIFO first CAS (line 1086) — **NO re-check**
- `Stealer::steal_batch_with_limit_and_pop()` LIFO loop CAS (line 1127) — re-check present

**Suggested modeling approach**:
- Variables: `buffer` (per-deque, models current buffer identity), `staleBuffer` (stealer's cached buffer pointer)
- Actions: Split `Steal` into `SpeculativeRead` (reads from cached buffer) + `CommitSteal` (CAS on front + buffer re-check). Model `Resize` as an action that swaps the buffer pointer and copies data.
- Fault injection: `SkipBufferRecheck` — omit the buffer re-check to reproduce CVE-2021-32810 pattern; apply selectively to test the missing re-check at line 1083

**Priority**: High
**Rationale**: 1 CVE with 5 yanked versions, 1 unresolved segfault, 1 new finding (missing re-check). The buffer re-check is a protocol-level extension to Chase-Lev that is model-checkable. The missing re-check at site #5 can be verified.

---

### Family 2: Torn Read / Memory Model Violations (MEDIUM)

**Mechanism**: Buffer slot access uses volatile read/write (`ptr::read_volatile`/`ptr::write_volatile`), which is not atomic under the C++/Rust memory model. For `T` larger than a machine word, concurrent read/write can produce torn values (half old, half new). The CAS on `front` validates slot ownership but does NOT validate data integrity.

**Evidence**:
- Historical: `4cbbb7f` — documented volatile UB (2018, **unfixed**, Ralf Jung)
- Historical: `68e8708` — ManuallyDrop unsoundness (zeroed memory ≠ valid T)
- Historical: `8d7db8c` — Stacked Borrows violation in Buffer read/write (Ralf Jung fix)
- Historical: `83b44f9` — Stacked Borrows in Buffer::alloc (mem::forget provenance)
- Code analysis: `deque.rs:73-90` — volatile UB remains; comments acknowledge "a hack"

**Affected code paths**:
- `Buffer::read()` (line 88-89) — used in every pop and steal
- `Buffer::write()` (line 78-79) — used in every push and batch steal dest write

**Suggested modeling approach**:
- Variables: `slotValue` (per buffer slot, the written value), `tornRead` (boolean fault injection)
- Actions: `Push` writes to slot atomically (models word-sized T). `TornPush` writes partial value (models large T). `StealRead` reads slot — if `tornRead` is enabled, may read partial value that passes CAS but returns garbage.
- This models the scenario where torn data is returned as valid after a successful CAS.

**Priority**: Medium
**Rationale**: Documented, understood, unfixable without redesigning the data structure. For word-sized T (the common case), hardware provides atomicity. Model-checkable via fault injection for large T.

---

### Family 3: Epoch-Deque Lifecycle Coupling (MEDIUM)

**Mechanism**: The deque's correctness depends on epoch-based reclamation preventing premature deallocation of old buffers. If epoch reclaims too early (or a thread fails to pin), use-after-free occurs. The deque has no defense against epoch bugs — it trusts epoch completely.

**Evidence**:
- Historical: #869 — M1 segfault from epoch MAX_OBJECTS change (mitigated, root cause UNKNOWN)
- Historical: #238 — UAF in MSQueue from incorrect epoch reclamation scheme
- Historical: #545 — Stacked Borrows violations in epoch internals
- Code analysis: `deque.rs:305-321` (resize: defer old buffer), `deque.rs:650-654` (steal: epoch pin)

**Affected code paths**:
- `Worker::resize()` — defers old buffer via epoch
- All `Stealer::steal*()` — epoch Guard keeps old buffer alive during steal
- Buffer ABA prevention — relies entirely on epoch (old buffer address cannot be reused while pinned)

**Suggested modeling approach**:
- Variables: `pinned[Thread]` (boolean), `retired[Buffer]` (deferred for GC), `freed[Buffer]` (actually deallocated)
- Actions: `Pin`, `Unpin`, `AdvanceEpoch`, `Reclaim` (frees buffers retired 2+ epochs ago)
- Fault injection: `PrematureReclaim` — reclaim buffer while a stealer is still reading from it
- The model should verify: if all threads properly pin/unpin, no use-after-free occurs; if a thread fails to pin, UAF becomes possible

**Priority**: Medium
**Rationale**: 1 unresolved issue (#869). Epoch is a well-studied mechanism, but the interaction with deque resize is subtle. Modeling epoch at an abstract level (pin/unpin/reclaim) is feasible and can verify the defense-in-depth.

---

### Family 4: FIFO Pop Rollback Atomicity (LOW)

**Mechanism**: FIFO pop uses `fetch_add` to speculatively advance `front`, then checks if the queue was actually empty. If empty, it rolls back `front` via a non-atomic `store`. Between `fetch_add` and `store`, `front` is temporarily past `back`, causing stealers to see a false-empty state.

**Evidence**:
- Code analysis: `deque.rs:467-472` — fetch_add then conditional store rollback
- No historical bugs (single-owner invariant prevents races on the rollback)

**Affected code paths**:
- `Worker::pop()` FIFO mode (lines 465-486)

**Suggested modeling approach**:
- Variables: `front`, `back` (standard Chase-Lev)
- Actions: Split FIFO pop into `FIFOPopAttempt` (fetch_add) and `FIFOPopRollback` (store). Model stealers observing `front > back` as returning Empty.
- Property: NoElementLoss — every pushed element is eventually popped or stolen (liveness)

**Priority**: Low
**Rationale**: No historical bugs. Protected by single-owner invariant. Interesting for modeling completeness but unlikely to reveal new issues.

---

### Family 5: Injector Obstruction-Freedom (LOW)

**Mechanism**: The Injector's steal path spins in `wait_write()` / `wait_next()` when a pusher has reserved a slot (via CAS on tail) but hasn't completed the write or block linkage. A preempted/crashed pusher blocks all stealers indefinitely.

**Evidence**:
- Code analysis: `deque.rs:1224-1229` (wait_write spin loop), `deque.rs:1272-1280` (wait_next spin loop)
- Historical: `698b84a` — stack overflow in Block::new (fixed, but shows fragility of block allocation path)

**Affected code paths**:
- `Injector::steal()` (line 1527 — wait_write)
- `Injector::steal_batch*()` (lines 1691, 1702 — wait_write)
- Block boundary transitions (wait_next)

**Suggested modeling approach**:
- If modeling the Injector: add `pusherStalled` boolean fault injection. After the tail CAS, the pusher can stall before WRITE is set. Model stealers spinning (or timing out) in this state.
- Property: InjectorLockFreedom — a stealer eventually completes if at least one pusher makes progress (this will FAIL, proving obstruction-freedom)

**Priority**: Low
**Rationale**: The Injector is a separate data structure from the Chase-Lev deque. Modeling it independently is possible but lower priority than the core deque.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Worker push + LIFO pop (Chase-Lev) | Core algorithm, reference comparison | Standard Chase-Lev actions from Le et al. |
| Worker FIFO pop (fetch_add) | Extension to Chase-Lev, rollback pattern | Split into attempt + conditional rollback |
| Multiple concurrent stealers | Primary concurrency dimension | N stealer processes, CAS on front |
| Buffer resize | Root cause of CVE-2021-32810 (Family 1) | Resize action swaps buffer identity; stealers track cached buffer |
| Buffer re-check before CAS | CVE fix, 1 missing site (Family 1) | Guard on CommitSteal; removable for fault injection |
| Batch steal (FIFO all-or-nothing) | Non-trivial extension, speculative copy | Single CAS for batch_size slots |
| Batch steal (LIFO one-by-one) | Different mechanism, loop with per-element CAS | Loop action with per-iteration CAS |
| Epoch pin/unpin (abstract) | Family 3, buffer lifecycle | Boolean per-thread; buffers freed only when all unpinned |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Volatile read/write UB (Family 2) | Cannot model torn reads in TLA+ without extensive encoding; better verified by Miri/LKMM tools |
| Stacked Borrows violations | Rust provenance model, not protocol logic; already caught by Miri |
| Buffer shrink | Never caused bugs; symmetric to grow; adds state space without targeting known issues |
| Injector queue | Separate data structure (not Chase-Lev); lower priority; adds significant spec complexity |
| Cross-flavor reversal | All historical bugs fixed; reversal logic verified correct; purely implementation-level |
| Memory allocation (stack overflow) | Implementation detail, not protocol logic |
| 32-bit index overflow | Extremely unlikely; requires 2^31 operations; not practical to model |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Buffer identity tracking | `currentBuffer`, `cachedBuffer[Stealer]` | Detect stale buffer reads after resize | Family 1 |
| Buffer re-check guard | (split action: read → re-check → CAS) | Model CVE fix; removable for fault injection | Family 1 |
| FIFO pop rollback | (split action: fetch_add → rollback) | Model transient front over-advance | Family 4 |
| Batch steal | `batchSize` parameter on steal actions | Model all-or-nothing vs one-by-one semantics | Family 1, 3 |
| Abstract epoch | `pinned[Thread]`, `retired[Buffer]` | Model buffer lifecycle and reclamation | Family 3 |
| Fault: skip re-check | `skipRecheck[CAS_site]` | Reproduce CVE-2021-32810; test missing re-check at line 1083 | Family 1 |
| Fault: premature reclaim | `prematureReclaim` | Model epoch bug reclaiming buffer while stealer reads | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoDoublePop | Safety | Every pushed element is consumed (popped or stolen) at most once | Family 1 |
| NoElementLoss | Safety | Every pushed element is eventually consumed (not leaked by CAS rollback) | Family 1, 4 |
| StealReturnsValid | Safety | A successful steal returns the value that was pushed at that index | Family 1, 2 |
| BufferCheckPreventsStale | Safety | If buffer re-check is present, no steal returns data from a stale buffer | Family 1 |
| NoUseAfterFree | Safety | No thread reads from a buffer that has been freed (epoch violation) | Family 3 |
| FIFOOrder | Safety | FIFO pop returns elements in push order; steal returns elements in push order | Standard |
| LIFOOrder | Safety | LIFO pop returns elements in reverse push order | Standard |
| DequeConsistency | Safety | `front <= back` (modulo wrapping) at all linearization points | Standard |
| StealProgress | Liveness | If the deque is non-empty and no new pushes/pops occur, a stealer eventually succeeds or sees Empty | Standard |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Missing buffer re-check at `deque.rs:1083` (LIFO steal_batch_with_limit_and_pop first CAS) | StealReturnsValid, NoDoublePop (with skipRecheck fault) | Family 1 |
| MC-2 | CVE-2021-32810 reproduction — remove ALL buffer re-checks | NoDoublePop, StealReturnsValid (with skipRecheck fault) | Family 1 |
| MC-3 | Premature epoch reclamation causing stale buffer access | NoUseAfterFree (with prematureReclaim fault) | Family 3 |
| MC-4 | FIFO pop rollback: verify no element loss during rollback window | NoElementLoss | Family 4 |
| MC-5 | Batch steal: verify all-or-nothing semantics (no partial commit) | NoDoublePop, NoElementLoss | Family 1 |
| MC-6 | Single-element contention: worker LIFO pop vs stealer CAS | NoDoublePop | Family 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | Torn read for large T (e.g., `(u64, u64)` on 32-bit) | Miri test with `T = [u8; 128]`, concurrent push/steal |
| TV-2 | Self-steal guard completeness | Unit test: create Worker, get Stealer, call steal_batch on self |
| TV-3 | Injector wait_write stall (liveness) | Thread test: pusher stalls after CAS, stealer times out |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Missing buffer re-check at line 1083 | Submit PR adding re-check for consistency |
| CR-2 | Injector Debug impl typo (line 2061: "Worker" should be "Injector") | Cosmetic fix |
| CR-3 | Volatile read/write UB documentation | Already documented; no action needed |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/crossbeam-deque/analysis-report.md`
- **Key source file**: `artifact/crossbeam/crossbeam-deque/src/deque.rs` (2,233 lines)
- **GitHub issues**: CVE-2021-32810 (PR #726), #869 (M1 segfault), #589/#646/#1207 (TSan)
- **Security advisory**: RUSTSEC-2021-0093, GHSA-pqqp-xmhj-wgcw
- **Reference algorithm**: Chase & Lev, SPAA 2005; Le et al., PPoPP 2013 (memory orderings)
- **Epoch dependency**: `artifact/crossbeam/crossbeam-epoch/` (buffer lifecycle)
- **CHANGELOG**: `artifact/crossbeam/crossbeam-deque/CHANGELOG.md`
