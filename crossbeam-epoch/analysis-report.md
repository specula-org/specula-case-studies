# Analysis Report: crossbeam-epoch

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed | 29 |
| GitHub issues deeply read (full comments) | 48 |
| GitHub PRs reviewed | 16 |
| RUSTSEC/CVE advisories checked | 6 |
| Core source files fully read | 8 |
| Lines of code analyzed | ~5,200 |
| Bug families identified | 5 |
| Confirmed historical bugs | 22 |
| False positives excluded | 5 |

---

## Phase 1: Reconnaissance — Structural Map

### Codebase Scale

```
Source Files (crossbeam-epoch/src/):
  lib.rs                     187 lines
  internal.rs                636 lines  ← most critical (Global, Local, epoch protocol)
  collector.rs               455 lines
  guard.rs                   528 lines
  atomic.rs                 1735 lines  ← largest (Atomic<T>, Shared, Owned, Pointable)
  epoch.rs                   148 lines
  deferred.rs                153 lines
  default.rs                 101 lines
  alloc_helper.rs             85 lines
  sync/list.rs               497 lines  ← lock-free intrusive linked list
  sync/queue.rs              475 lines  ← Michael-Scott queue

Tests:
  tests/loom.rs              161 lines

Total core logic: ~3,500 LOC
```

### Core Data Structures

| Struct | File | Purpose |
|--------|------|---------|
| `Global` | internal.rs:166 | Shared GC state: locals list, garbage queue, global epoch |
| `Local` | internal.rs:287 | Per-thread state: bag, guard/handle counts, local epoch |
| `Bag` | internal.rs:96 | Fixed-size array of deferred destructors (64 or 4 under sanitizers) |
| `SealedBag` | internal.rs:143 | Bag + epoch at which it was sealed |
| `Guard` | guard.rs:70 | RAII proof of pinned epoch |
| `Epoch` | epoch.rs:34 | Epoch value with pinned flag in LSB |
| `AtomicEpoch` | epoch.rs:99 | Atomic wrapper for Epoch |
| `Collector` | collector.rs:22 | Public API: `Arc<Global>` wrapper |
| `LocalHandle` | collector.rs:76 | Per-thread handle, holds `*const Local` |
| `Deferred` | deferred.rs:14 | Inline or boxed `FnOnce()` (3-word inline storage) |
| `Atomic<T>` | atomic.rs:299 | Epoch-protected atomic pointer with tagging |
| `Shared<'g, T>` | atomic.rs:1197 | Epoch-protected reference, lifetime-tied to Guard |
| `Owned<T>` | atomic.rs:938 | Exclusive ownership pointer |
| `List<T>` | sync/list.rs:113 | Lock-free intrusive singly-linked list |
| `Queue<T>` | sync/queue.rs:36 | Michael-Scott lock-free queue |

### Concurrency Model

- **Per-thread state** (`Local`): uses `Cell<usize>` for guard_count, handle_count, pin_count — NOT atomic, designed for single-thread access only
- **Cross-thread sync**: SeqCst fences in `pin()` and `try_advance()` form the core synchronization mechanism
- **Global shared state** (`Global`): epoch is `AtomicEpoch`, locals is a lock-free `List`, garbage is a lock-free `Queue`
- **No locks anywhere** — entirely lock-free design

### Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_OBJECTS` | 64 (4 under sanitizers) | Max deferred items per Bag |
| `PINNINGS_BETWEEN_COLLECT` | 128 | How often `pin()` triggers GC |
| `COLLECT_STEPS` | 8 | Bags to try collecting per cycle |

---

## Phase 2: Bug Archaeology

### 2.1 Critical Bug-Fix Commits

| # | Commit | Summary | Root Cause | Component | Severity |
|---|--------|---------|------------|-----------|----------|
| 1 | `2618830` | MSQueue pop use-after-free | Missing tail advancement when head==tail | sync/queue.rs | Critical |
| 2 | `f48c1c7` | `mem::uninitialized()` UB in queue | Sentinel node created with UB | sync/queue.rs | Critical |
| 3 | `e0fd465` | `mem::uninitialized()` UB in deferred | Buffer created with UB | deferred.rs | Critical |
| 4 | `b911157` | `assume_init()` on partial data | Deferred buffer only partially initialized | deferred.rs | Critical |
| 5 | `385bf3e` | Pointable size/length confusion | Byte size passed as element count | atomic.rs | Critical |
| 6 | `893a08d` | Repin missing `.pinned()` | Local epoch set without pinned flag | internal.rs | Critical |
| 7 | `52a4e31` | Epoch threshold changed to >= 3 | 2-epoch gap deemed insufficient | internal.rs | Critical |
| 8 | `389a60b` | Reverted back to >= 2 | 3-epoch approach had issues; restored fence-based 2-epoch | internal.rs | Critical |
| 9 | `088012e` | List finalize freed immediately | `finalize()` should defer, not free directly | sync/list.rs | Critical |
| 10 | `02fb08a` | Pervasive Stacked Borrows UB | References where raw pointers needed | multiple | Critical |
| 11 | `9c95360` | Memory leak via unprotected guard | Deferred functions silently dropped when local==null | guard.rs | High |
| 12 | `b05e1e3` | Pointer provenance UB | ptr-to-int casts strip provenance | atomic.rs | High |
| 13 | `7169d4f` | memoffset soundness | Upstream dependency had UB | Cargo.toml | High |
| 14 | `d94e5ee` | Missing compiler fence in pin | Theoretical LLVM reordering | internal.rs | Medium |
| 15 | `fdc168f` | CAS-as-fence documented as dubious | C++ memory model concern | internal.rs | Medium |
| 16 | `4399c72` | List iteration stall | Unnecessary restarts on CAS failure | sync/list.rs | Medium |
| 17 | `032cf7a` | TSan compatibility | TSan doesn't understand fences | internal.rs | Medium |
| 18 | `4bb27db` | False sharing in Local | epoch field on same cache line | internal.rs | Medium |
| 19 | `290735b` | Guard Clone removed | Clone was semantically questionable | guard.rs | Medium |
| 20 | `d4bc8db` | unprotected() transmute UB | Transmuting usize to Guard | guard.rs | Medium |

### 2.2 GitHub Issues — Confirmed Bugs

| Issue | Title | Classification | Root Cause | Fixed? |
|-------|-------|---------------|------------|--------|
| #105 | Thread-epoch advanced with pin held | Confirmed bug | pin() called try_collect() in nested critical section | Yes |
| #46 | MsQueue race condition | Confirmed bug | Local epoch updated before garbage collection | Yes |
| #238 | Use-after-free in MSQueue | Confirmed bug | pop defer_destroy when head==tail, tail still reachable | Yes (E+3 + queue fix) |
| #395 | offsetof unsound | Confirmed bug | memoffset macro created null reference | Yes (PR #402) |
| #545 | Miri Stacked Borrows violation | Confirmed bug | References where raw pointers needed | Yes (PR #871) |
| #347 | Reads of uninitialized data | Confirmed bug | Related to mem::uninitialized usage | Yes (PR #458) |
| #37 | Participant data leak | Confirmed bug | No reuse of participant nodes | Yes |
| #91 | Queue/Stack leak unpopped nodes | Confirmed bug | Missing Drop implementations | Yes |
| #191 | TreiberStack double-free | Confirmed bug | Drop called on moved-from data | Yes |
| #97 | Incorrect MSQueue orderings | Confirmed bug | Missing Acquire/Release | Yes |
| #116 | CAS was wrong | Confirmed bug | Not performing actual CAS | Yes |
| #107 | MsQueue segfault | Confirmed bug | Related to #46/#238 | Yes |
| #869 | M1 segfaults | Confirmed bug | MAX_OBJECTS reduction exposed deque race | Yes (reverted #552) |

### 2.3 GitHub Issues — Design Defects / Limitations

| Issue | Title | Classification | Status |
|-------|-------|---------------|--------|
| #273 | GC not triggered | Design limitation | Open (fundamental to EBR) |
| #566 | Extreme memory usage | Design limitation | Workaround: `guard.flush()` |
| #852 | O(N) try_advance overhead | Performance bug | Workaround: separate Collector per pool |
| #946 | Confusing compare_exchange API | Design defect | Fix in progress (0.10 release) |
| #206 | Panics in deferred functions | Design issue | Open |
| #1001 | Unnecessary try_advance in reads | Performance issue | Open |

### 2.4 GitHub Issues — Excluded (False Positives)

| Issue | Title | Why Excluded |
|-------|-------|-------------|
| #422 | Guard in TLS unsound | Reporter retracted after deeper analysis; lifecycle is correct |
| #133 | SegQueue ordering bug | Reporter retracted; stale read is safe (queue appears empty) |
| #285 | Strange memory leak with rayon | Expected behavior; thread-local data is intentionally not freed |
| #464 | Memory leak from Deferred::new | Miri false positive; statics are intentionally "leaked" |
| #579 | Miri memory leak with pin() | Miri limitation; fixed upstream in Miri |

### 2.5 Security Advisories

| Advisory | Crate | Severity | Description | Fixed |
|----------|-------|----------|-------------|-------|
| RUSTSEC-2018-0009 | crossbeam | Critical | MsQueue/SegQueue double-free | >= 0.4.1 |
| RUSTSEC-2022-0029 | crossbeam | Memory corruption | MSQueue wrong orderings | >= 0.3.0 |
| RUSTSEC-2022-0020 | crossbeam | Unsound | SegQueue mem::zeroed() | >= 0.7.0 |
| RUSTSEC-2025-0024 | crossbeam-channel | Double free | discard_all_messages race | >= 0.5.15 |
| GHSA-pqqp-xmhj-wgcw | crossbeam-deque | High | Stealer::steal race | >= 0.8.1 |
| GHSA-qc84-gqf4-9926 | crossbeam-utils | High | AtomicCell alignment | >= 0.8.7 |

No RUSTSEC advisory filed directly against crossbeam-epoch.

---

## Phase 3: Deep Analysis

### 3.1 internal.rs — Epoch Protocol

**Epoch Advancement (`try_advance`, lines 237-288)**

The protocol:
1. Load global epoch with `Relaxed` (line 238)
2. `SeqCst` fence (line 239)
3. Iterate all Locals, load each local epoch with `Relaxed` (line 258)
4. If any pinned Local has epoch != global epoch, abort (lines 262-264)
5. `Acquire` fence (line 276)
6. Store successor epoch with `Release` (line 286)

**Key finding**: The global epoch is advanced via `store` (not CAS). The comment at lines 278-284 argues this is safe: the calling thread is pinned at epoch E, so no other thread can advance past E+1, making the store idempotent. However, PR #755 identified a potential issue: without an additional global epoch re-read + CAS, the epoch could theoretically decrease if a delayed thread stores an old value. The current code has the Acquire fence + Release store which should prevent this, but no formal proof exists.

**Pin/Unpin (`pin`, lines 403-462; `unpin`, lines 466-479)**

The x86 optimization at lines 416-448 replaces `store(Relaxed) + fence(SeqCst)` with `compare_exchange(SeqCst, SeqCst)`. The HACK comment admits this is "not clear [to be] permitted by the C++ memory model" but "experimental evidence suggests that this works fine." The compiler fence at line 444 is described as "formally not enough."

**TOCTOU in pin()**: Between loading global epoch (line 410) and storing local epoch (line 434/446), the global epoch could advance. This is safe: the thread appears pinned at a stale epoch, which is conservative (blocks further advancement, doesn't cause premature reclamation).

**Garbage Collection (`collect`, lines 208-226)**

`is_expired` at line 157-161 uses `global_epoch - bag_epoch >= 2`. This 2-epoch gap is the fundamental safety property. The historical oscillation between 2 and 3 (commits `52a4e31`/`389a60b`) was resolved in favor of 2 with the SeqCst fence approach.

**Finalization (`finalize`, lines 531-569)**

Complex protocol with temporary `handle_count` bump (line 540) to prevent re-entrant finalize. The ordering constraint at lines 556-558 is critical: the `Collector` reference must be read BEFORE the entry is deleted, because after deletion another thread could free the `Local` via epoch-deferred destruction.

### 3.2 guard.rs — Guard Safety

- `Guard` is `!Send` and `!Sync` automatically (via `*const Local`) — correct
- `mem::forget(Guard)` permanently stalls GC — known limitation, not UB
- `unprotected()` returns `&'static Guard` with null local — requires exclusive access
- `defer_unchecked` omits `Send` bound intentionally (for `Shared<T>` which is `!Send`)
- `repin()` uses `&mut self` which statically prevents dangling `Shared` pointers
- `repin_after()` has panic safety via `ScopeGuard` (lines 371-381)
- Deferred function panic leaks remaining bag contents (known issue #206)

### 3.3 epoch.rs — Epoch Representation

- LSB encodes pinned/unpinned flag; `wrapping_sub` correctly handles this via `>> 1` shift
- `successor()` adds 2 (skips LSB) — correct for all values (adding even preserves LSB parity)
- 32-bit platforms use `AtomicUsize` (31 effective epoch bits) — TODO at line 14 suggests `AtomicCell` for 64-bit on 32-bit platforms
- No torn reads on any platform (`AtomicUsize` always natively atomic)

### 3.4 atomic.rs — Pointer Operations

- Pointer tagging uses alignment bits; zero tag bits for align-1 types (correct but surprising)
- `store` silently drops old value — no guard required, caller must handle old value
- `compare_exchange` API (Issue #946): returns `new` on success, confusing relative to `std`
- `map_addr` helper is provenance-safe (uses `wrapping_add` on original pointer)
- Non-Miri path uses `AtomicUsize` cast for fetch_* operations — permissive-provenance compatible
- No `Drop` for `Deferred` — leaked if not `call()`-ed (design choice)

### 3.5 sync/list.rs — Lock-Free Intrusive List

- Michael (2002) algorithm, not Harris — physical unlinking during iteration only
- Two-phase deletion: `fetch_or(1, Release)` for logical delete, CAS for physical unlink
- Physical unlink CAS uses `Acquire/Acquire` (unusual but valid — successor was already published)
- `finalize()` called exactly once per node (CAS atomicity ensures single winner)
- ABA prevented by epoch-based reclamation, not the list algorithm
- Iterator can miss concurrently-inserted nodes — documented, intentional

### 3.6 sync/queue.rs — Michael-Scott Queue

- Faithful MSQ with epoch-based reclamation instead of hazard pointers
- head==tail bug fix at lines 129-135: advance tail before `defer_destroy(head)`
- `try_pop_if` evaluates condition BEFORE CAS — side effects may fire for elements not popped
- `T: Sync` required for `try_pop_if` (concurrent reads before CAS determines winner)
- Memory orderings relaxed from original paper's SC to Acquire/Release — standard practice
- Drop correctly handles all nodes including final sentinel

### 3.7 collector.rs + default.rs — Lifecycle

- `Collector` wraps `Arc<Global>`, each `Local` holds its own clone — `Global` outlives all `Collector`s
- `LocalHandle` holds raw `*const Local` — safe via dual handle_count/guard_count reference counting
- `with_handle` fallback after TLS destruction creates temporary `LocalHandle` (lines 58-65)
- `OnceLock<Collector>` for default collector — race-free initialization
- Loom tests do NOT exercise epoch advancement, garbage collection timing, or finalization

### 3.8 Developer Signals

| Location | Signal | Content |
|----------|--------|---------|
| internal.rs:420-432 | HACK | "It is not clear that this is permitted by the C++ memory model" |
| internal.rs:441-444 | Comment | "Formally, this is not enough to get rid of data races" |
| internal.rs:246-248 | TODO | Linked list traversal slow due to cache misses |
| internal.rs:325-329 | TODO | Size assertion for Local commented out (Issue #869) |
| epoch.rs:14 | TODO | Use AtomicCell on platforms without AtomicU64 |
| lib.rs:81-86 | FIXME | Loom does not support compiler_fence |

---

## Phase 4: Bug Family Analysis

### Family 1: Epoch Advancement Protocol Races — HIGH

**Mechanism**: Incorrect ordering of operations in the epoch advancement / pin / unpin / collect cycle leads to premature reclamation.

**Historical bug count**: 4 critical (Issues #105, #46; commits `52a4e31`/`389a60b`, `893a08d`)
**Unresolved concerns**: PR #755 (epoch monotonicity), HACK comment (CAS-as-fence)
**TLA+ suitability**: Excellent — the protocol is a pure interleaving problem with shared state and multiple threads

### Family 2: Data Structure / EBR Interaction — HIGH

**Mechanism**: Data structure operations (push/pop/insert/delete) interact with EBR's epoch-based protection in ways that violate the "retired objects are unreachable" invariant.

**Historical bug count**: 3 critical (Issue #238, commit `2618830`, commit `088012e`) + 1 advisory (RUSTSEC-2018-0009)
**TLA+ suitability**: Excellent — co-verifying the MSQueue/list protocol with the EBR protocol is exactly what TLA+ excels at

### Family 3: Finalization and Thread Lifecycle — MEDIUM

**Mechanism**: Complex dual reference counting for `Local` lifetime management, with multiple drop orderings to handle correctly.

**Historical bug count**: 2 (commits `893a08d`, `9c95360`) + 1 investigation (Issue #422)
**TLA+ suitability**: Good — lifecycle state machine with interleaving

### Family 4: Garbage Collection Timing & Liveness — MEDIUM

**Mechanism**: GC is only triggered during `pin()`, and epoch advancement is blocked by any thread pinned at an old epoch.

**Historical bug count**: 0 critical (design limitations: Issues #273, #566, #852)
**TLA+ suitability**: Good for liveness properties (eventual collection under fairness)

### Family 5: Low-Level Undefined Behavior — LOW (for TLA+)

**Mechanism**: Rust-specific UB from memory initialization, aliasing model, pointer provenance.

**Historical bug count**: 8+ (but all Rust-specific, not protocol-level)
**TLA+ suitability**: Not applicable — requires Miri/sanitizers

---

## Appendix: Complete Atomic Operations Inventory

### internal.rs

| Line | Operation | Ordering | Context |
|------|-----------|----------|---------|
| 194 | `fence` | SeqCst | push_bag: order bag writes before epoch read |
| 196 | `global.epoch.load` | Relaxed | push_bag: read epoch for sealing |
| 238 | `global.epoch.load` | Relaxed | try_advance: read current epoch |
| 239 | `fence` | SeqCst | try_advance: core synchronization |
| 258 | `local.epoch.load` | Relaxed | try_advance: scan each local |
| 273 | `local.epoch.load` | Acquire | try_advance: TSan path only |
| 276 | `fence` | Acquire | try_advance: ensure reads complete before store |
| 286 | `global.epoch.store` | Release | try_advance: publish new epoch |
| 410 | `global.epoch.load` | Relaxed | pin: read current epoch |
| 434-438 | `local.epoch.compare_exchange` | SeqCst/SeqCst | pin: x86 path |
| 444 | `compiler_fence` | SeqCst | pin: x86 extra barrier |
| 446 | `local.epoch.store` | Relaxed | pin: non-x86 path |
| 447 | `fence` | SeqCst | pin: non-x86 synchronization |
| 471 | `local.epoch.store` | Release | unpin: mark as unpinned |
| 488 | `local.epoch.load` | Relaxed | repin: read own epoch |
| 489 | `global.epoch.load` | Relaxed | repin: read current epoch |
| 495 | `local.epoch.store` | Release | repin: update epoch |

### sync/list.rs

| Line | Operation | Ordering | Context |
|------|-----------|----------|---------|
| 152 | `next.fetch_or(1)` | Release | Logical deletion |
| 183 | `head.load` | Relaxed | Insert: read head |
| 188 | `entry.next.store` | Relaxed | Insert: set new node's next |
| 189 | `head.compare_exchange_weak` | Release/Relaxed | Insert CAS |
| 214 | `head.load` | Acquire | Iterator: begin |
| 243 | `entry.next.load` | Acquire | Iterator: read successor |
| 254-256 | `pred.compare_exchange` | Acquire/Acquire | Physical unlinking |

### sync/queue.rs

| Line | Operation | Ordering | Context |
|------|-----------|----------|---------|
| 76 | `tail.next.load` | Acquire | Push: read tail's next |
| 80-81 | `tail.compare_exchange` | Release/Relaxed | Push: help advance tail |
| 87 | `tail.next.compare_exchange` | Release/Relaxed | Push: link new node |
| 92-93 | `tail.compare_exchange` | Release/Relaxed | Push: advance tail |
| 121 | `head.load` | Acquire | Pop: read head |
| 123 | `head.next.load` | Acquire | Pop: read next |
| 127 | `head.compare_exchange` | Release/Relaxed | Pop: advance head |
| 129 | `tail.load` | Relaxed | Pop: check head==tail |
| 133-134 | `tail.compare_exchange` | Release/Relaxed | Pop: advance lagging tail |
