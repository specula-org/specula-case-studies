# Analysis Report: jonhoo/left-right (Round 2)

## 0. Coverage Statistics

| Metric | Count |
|---|---|
| Core source files read in full | 7 (lib.rs, write.rs, read.rs, read/guard.rs, read/factory.rs, aliasing.rs, sync.rs) |
| Total core LOC | ~1980 |
| Tests read | tests/deque.rs, tests/loom.rs, tests/trace_tests.rs |
| Total commits | 449 (HEAD) / 451 (all branches) |
| Commits touching core files | 118 |
| Bug-fix commits identified | ~25 (including ones from rust-evmap era) |
| GitHub issues collected | 50 |
| Issues deeply read (full thread) | 16 (#74, #75, #65, #76, #77, #80, #114, #93, #85, #71, #70, #69, #53, #45, #33, #24) |
| GitHub PRs reviewed in detail | 7 (#144, #145, #147, #138, #119, #120, #97) |
| Confirmed unfixed bugs | 2 (PR #144 awaiting merge; reentrant enter `unreachable!` on shutdown) |
| False positives excluded | #65 (user error), #76 (already-the-case), #80 (rejected design) |

## 1. System Classification

**Category**: B (Concurrent / Lock-Free / Runtime)
**Sub-category**: Reader-writer separation (per concurrent-analysis.md § 5)
**Justification**: Single-writer / many-reader split with two backing buffers, an `AtomicPtr` for buffer selection, per-reader epoch counters with parity bits, and a SeqCst-fence-based publish protocol. No network, no persistent storage, no protocol-level state machine.

Per the prioritization table in concurrent-analysis.md § 5, the relevant fault families are:
- 5.1 Thread Interleaving (universal)
- 5.5 Memory Ordering / Visibility — already covered by prior round (`MCSkipReaderFence`, `MCSkipWriterFence`)
- 5.6 Reuse / pointer-recycle — slot reuse in slab; reuse of buffer addresses across publishes
- 5.7 Caller misuse — explicit focus of this round per `.prompt-extra.md`

## 2. Reconnaissance: Structural Map

### Core files

| File | LOC | Role |
|---|---|---|
| lib.rs | 304 | Public API, `Absorb` trait, constructors `new` / `new_from_empty` |
| write.rs | 838 | `WriteHandle`, `publish`, `try_publish`, `wait`, `update_and_swap`, `take_inner`, `Drop` |
| read.rs | 275 | `ReadHandle`, `enter` (with reentrant path), `was_dropped`, `raw_handle`, `factory` |
| read/guard.rs | 130 | `ReadGuard`, `map`, `try_map`, `Drop` |
| read/factory.rs | 39 | `ReadHandleFactory` (Sync wrapper for spawning ReadHandles) |
| aliasing.rs | 430 | `Aliased<T,D>`, `DropBehavior`, `alias()`, `change_drop()` for cross-buffer aliasing |
| sync.rs | 22 | loom/std abstraction with FIXME for loom SeqCst downgrade |
| tla_trace.rs | 318 | Instrumentation only — not on the correctness path |

### Concurrency model

- Shared state: `Arc<AtomicPtr<T>>` (current read pointer), `Arc<Mutex<Slab<Arc<CachePadded<AtomicUsize>>>>>` (epoch slab), per-reader `CachePadded<AtomicUsize>` (epoch).
- Reader: `enter()` does `epoch.fetch_add(1, AcqRel)` → `fence(SeqCst)` → `inner.load(Acquire)`. Drop bumps epoch back to even.
- Writer: `publish()` takes `epochs.lock()`, calls `wait()` (spin until snapshotted-odd readers advance), calls `update_and_swap()` (absorb on w_handle, `inner.swap(Release)`, `fence(SeqCst)`, snapshot epochs into `last_epochs`).
- `try_publish()` is non-blocking: scans epochs once, returns false if any snapshotted-odd reader is unchanged.
- `take_inner()` (called by Drop and `take`) drains oplog via two publishes, then `inner.swap(NULL, Release)`, then `wait()`, then `fence(SeqCst)`, then drops both boxes.

### Atomicity boundaries (must remain split in spec)

| Site | Operation | Action boundary |
|---|---|---|
| read.rs:180 | `epoch.fetch_add(1, AcqRel)` | After this, reader is "in" |
| read.rs:183 | `fence(SeqCst)` | Reader-side fence |
| read.rs:186 | `inner.load(Acquire)` | Reader observes the buffer |
| write.rs:455 | `inner.swap(..., Release)` | Publish point |
| write.rs:462 | `fence(SeqCst)` | Writer-side fence |
| write.rs:464-466 | `epoch.load(Acquire)` per reader | Snapshot into `last_epochs` |
| write.rs:175 | `inner.swap(NULL, Release)` (take_inner) | NULL publish point |
| write.rs:183 | `fence(SeqCst)` (take_inner) | Trailing fence before drops |
| write.rs:190 | `drop_first(self.w_handle)` | First buffer drop |
| write.rs:198+ | `Box::from_raw(r_handle)` → Taken → drop_second | Second buffer drop |
| write.rs:570-573 | first-mode extend writes directly | Writer mutates w_handle without publish |

## 3. Bug Archaeology

### 3.1 Confirmed bugs already fixed upstream (reference context only)

| Commit / PR | Bug | Status |
|---|---|---|
| ce1082d | `Box::from_raw + mem::forget` aliased a still-live pointer (UB under stacked-borrows) | Fixed |
| 02eb63b | Reader registration deadlocked against `refresh()` | Fixed |
| 73a6729 | Panic in user closure left writer waiting forever; added drop-guard for parity | Fixed via current `ReadGuard::Drop` |
| 78cf502 | Epoch slot leaked when ReadHandle dropped (issue #53) | Fixed via slab |
| ec87c59 | Memory leak when `WriteHandle` dropped without `destroy()` (issue #24) | Fixed; introduced the take_inner NULL-swap pattern |
| 416ccef (PR #83) | `Box<T>` aliasing UB (issue #74) | Fixed via `aliasing.rs` (`Aliased<T,D>`) |
| c3d206e | Incorrect `Send + Sync` blanket impls (issue #75) | Fixed via conditional impls |
| 6529287 / 1066dc9 / de8664a / 50d931b | Multiple rounds of memory-ordering fixes; established the SeqCst-fence-on-both-sides pattern | Fixed; current invariant |
| f8a59f1 (PR #97) | New API: `WriteHandle::take` extracted from Drop | Released 0.11.3 |
| d5f31dd (PR #120) | New API: `try_publish` for non-blocking publish | Released 0.11.6 |
| 3f48163 | False sharing on epoch counters; introduced `CachePadded` | Fixed; perf-only |

These are documented as **reference context for bug-prone mechanisms**, not as modeling targets. Per bug-archaeology.md § 1.4, re-deriving them via TLA+ adds no new information.

### 3.2 Confirmed unfixed bugs (modeling targets)

#### Bug A: take_inner UAF — `wait` uses stale `last_epochs` snapshot

**Source**: PR #144 "Fix data race on writehandle drop" (OPEN, by Fredi-raspall, no maintainer review yet as of 2026-05-10).

**Mechanism**:
1. Writer's prior `publish()`/`update_and_swap()` ends with snapshotting `last_epochs` from current epoch values.
2. After `update_and_swap` returns, but before take_inner's `inner.swap(NULL, Release)` (write.rs:175), a reader can: bump epoch to odd (read.rs:180), fence (read.rs:183), load the still-valid pointer (read.rs:186) → has guard on the buffer about to be dropped.
3. take_inner's `wait()` (write.rs:180) iterates over the slab and **skips entries with `last_epochs[ri] % 2 == 0`** (write.rs:272-274). For the new reader, `last_epochs[ri]` is the value sampled at the prior publish snapshot — even (reader was out then). So `wait` skips them.
4. Writer proceeds past `wait`, drops both `w_handle` (write.rs:190) and the boxed `r_handle` returned from the NULL swap (write.rs:198 → Taken's `drop_second`).
5. Reader's outstanding guard now points to dropped memory.

**Confirmation**: TSAN-detected by author of PR #144 in a stress test where T1 repeatedly creates and drops `WriteHandle<V>` while other threads create new ReadHandles via the factory and call `enter()`. TSAN reports a race where threads read a `bool` within `V` while T1 drops it.

**Why prior round missed it**: The prior modeling brief (§ MC-3) recorded "verified safe via SeqCst ordering, but the reasoning is subtle" — but the SeqCst fence at write.rs:183 is *after* the `wait`, and even the reader-side SeqCst fence does not put epoch values from new readers into the prior publish's `last_epochs` snapshot. The key gap is that the prior publish's `update_and_swap` snapshotted `last_epochs` *before* take_inner's NULL swap, not *after*.

**Proposed fix in PR #144**: After the NULL swap and before `wait`, refresh `last_epochs` by reloading every reader's epoch under `epochs.lock()`. This catches readers that entered between the prior publish snapshot and the NULL swap.

**Spec implication**: `take_inner` must be modeled as a sequence of distinct actions, and the spec must NOT collapse the NULL-swap and the wait into one atomic step. The bug appears precisely in the gap.

#### Bug B: Reentrant `enter()` after WriteHandle is dropped panics

**Source**: Found by deep analysis (read.rs:120-148).

**Mechanism**:
1. Reader holds an outer `ReadGuard` (epoch is odd, `enters == 1`).
2. WriteHandle is dropped on another thread. take_inner runs, performs `inner.swap(NULL, Release)` (write.rs:175).
3. While the outer guard is still alive, the reader calls `enter()` again (nested). Since `enters > 0` (read.rs:122), the reentrant path executes: it skips `epoch.fetch_add` and just does `inner.load(Acquire)` (read.rs:126).
4. The load returns NULL (post-NULL-swap).
5. `r_handle.as_ref()` returns `None`. The branch at read.rs:145-147 hits `unreachable!("if pointer is null, no ReadGuard should have been issued")` and panics.

**Why this is reachable**: The non-reentrant path explicitly handles the NULL case (read.rs:206-214) by returning `None` and bumping the epoch. The reentrant path's claim is wrong: the outer ReadGuard remains valid (the writer's wait is gated on the outer guard's odd epoch — see Bug A scenario for the reverse case where wait is *not* gated), but the nested `enter()` cannot mint a new guard because the pointer is now NULL.

**Severity**: Soundness-adjacent panic (no UB, but unexpected termination on shutdown). Easy to trigger in a stress test that drops WriteHandle while a reader holds a guard and calls `enter()` again.

**Proposed fix**: Mirror the non-reentrant path's `else` branch. Return `None` (without bumping the epoch since we are still inside the outer critical section).

### 3.3 Disputed / closed without fix

| Issue | Disposition |
|---|---|
| #65 "Thread Safety Error on ReadHandler" | User error: tried to share single ReadHandle across threads (it is `!Sync` by design). |
| #76 "Relaxation of epoch invariant" | Already-the-case: jonhoo's reply notes the check is already `!=`, no overflow panic risk. |
| #80 "A potential alternative to epochs" | Rejected on perf grounds (single-cache-line contention). |

### 3.4 Open feature requests (not bugs)

| Issue | Description |
|---|---|
| #77 "rollback" | Feature request, never implemented. |
| #101 "no_std support" | Driving PR #145 cordyceps proposal. |
| #145 "Replace Mutex with cordyceps::TransferStack" | Open redesign of epoch tracking; not yet reviewed. |
| #147 "Make loom dev-dependency" | Trivial cleanup. |
| #138 "Accumulator type" | Closed; out of scope. |
| #119 "Refactor publish to remove first/second" | Closed unmerged: maintainer noted the first/second distinction is **load-bearing for safety** of `Box`-aliasing `Absorb` impls. Important context: do not collapse this in the spec. |

## 4. Deep Analysis Findings

### 4.1 Action-granularity boundaries that must NOT be collapsed

| Action | Substep | What can interleave |
|---|---|---|
| `update_and_swap` | absorb_first/absorb_second on w_handle (write.rs:426-434) | New readers arrive on r_handle; safe (different buffer) |
| `update_and_swap` | `inner.swap(Release)` (write.rs:455) | After this, new readers see new buffer |
| `update_and_swap` | `fence(SeqCst)` (write.rs:462) | StoreLoad barrier — readers' subsequent epoch bumps may or may not be visible |
| `update_and_swap` | epoch snapshot loop (write.rs:464-466) | A reader entering between snapshot of slot k-1 and slot k may show even-then-odd |
| `take_inner` | `publish()` × {1,2} (write.rs:167, 170) | Standard publish |
| `take_inner` | `inner.swap(NULL, Release)` (write.rs:175) | **Gap before this and the prior publish's snapshot is where Bug A lives** |
| `take_inner` | `epochs.lock()` + `wait()` (write.rs:179-180) | wait uses stale `last_epochs` |
| `take_inner` | drop_first / drop_second (write.rs:190+) | The actual dangerous point if Bug A triggers |
| `enter()` | `epoch.fetch_add(AcqRel)` (read.rs:180) | Reader is "in" but pointer not yet loaded |
| `enter()` | `fence(SeqCst)` (read.rs:183) | StoreLoad barrier on reader side |
| `enter()` | `inner.load(Acquire)` (read.rs:186) | Reader observes a buffer |
| `extend` (first mode) | direct write to `raw_write_handle` (write.rs:567-574) | Special pre-publish mode |
| `Drop for ReadGuard` | decrement enters → maybe fetch_add(epoch) (guard.rs:120-124) | Reader leaves; if last guard, epoch parity restored |

### 4.2 Caller misuse scenarios (focus of this round)

#### CM-1: Long-held guard blocks publish indefinitely

A reader holds a `ReadGuard` across an `await` point, channel receive, slow user computation, etc. Writer's `publish()`/`take_inner()` calls `wait()`, which spins on `epoch.load(Acquire)` for that reader's slot. Since the reader's epoch stays odd, `wait` spins forever.

This is documented behavior — the API contract is "guards must not be held across yield points" — but it is exactly the kind of caller misuse the prompt asks to expose. The spec should permit "long-held guard" scenarios that produce a writer-starvation/liveness violation in a model with a fairness assumption.

#### CM-2: Caller drops WriteHandle while readers hold guards

This is what take_inner is supposed to handle gracefully. The intended semantics is:
- Existing readers' guards remain valid (referenced data is not freed until they release).
- New readers (post-drop) see NULL and `enter()` returns `None`.

But Bug A breaks both:
- A reader entering between the prior publish snapshot and the NULL swap is *neither* the existing-reader case (their epoch was even at last snap) *nor* the post-drop case (they got the still-valid pointer before NULL).
- Bug B compounds this for nested enters.

#### CM-3: Concurrent `ReadHandle::clone()` while writer is publishing

`ReadHandle::clone` calls `new_with_arc`, which takes `epochs.lock().unwrap().insert(...)` (read.rs:91). The writer's `publish()` also holds `epochs.lock()` for the entire wait + update_and_swap. So a clone and a publish are serialized by the mutex.

Subtle case: between two writer publishes, a clone adds a new slot. The new slot's epoch is 0 (initial). The writer's *next* `update_and_swap` snapshot includes this slot at value 0. Wait skips even-last_epochs slots, so this works correctly for the publish path. But this same property is what Bug A exploits in take_inner.

#### CM-4: Misuse of `raw_write_handle()`

Returns `NonNull<T>` to the user (write.rs:517-519). The function is **not marked `unsafe`**, but the docstring (write.rs:508-514) imposes a non-trivial safety contract: "only safe to mutate through this pointer if you know there are no readers in this copy." The TODO at write.rs:515 acknowledges this should return `Option<&mut T>`. A caller can trivially produce UB by mutating after the first publish; the type system gives no protection.

#### CM-5: Aliased<T, D>::change_drop() direction

`change_drop()` (aliasing.rs:211-218) is unsafe but does not internally enforce the direction constraint. The doc says "going from dropping `D` to non-dropping `D` is always safe; going the other way is only safe if `self` is the last alias." The implementation does `std::ptr::read(&self.aliased)`, which **does not call `mem::forget(self)`** — but that's fine because `MaybeUninit` is `Copy`-like (no destructor for the inner data) and the outer `Aliased`'s Drop runs based on `D::DO_DROP`, not on the inner data's identity.

Actually, on careful re-reading: change_drop does `ptr::read` of the `MaybeUninit<T>`, then constructs a new `Aliased<T, D2>`. The original `self` IS dropped (the function consumes it via `self`). If `D::DO_DROP == false`, the original Drop is a no-op — fine. If `D::DO_DROP == true` and `D2::DO_DROP == false`, the original Drop runs `drop_in_place` on the inner T (line 250) — this drops the value, then the new `Aliased<T, D2>` aliases freed memory. **This direction (DoDrop → NoDrop) is unsound** unless `self` is the last alias — but the docs only flag the *opposite* direction. The deque test in tests/deque.rs does NoDrop → DoDrop, which is the only direction actually used in practice. **This is a documentation gap, not necessarily a code bug**, but worth noting.

### 4.3 Memory ordering — verification

| Site | Ordering | Sound? |
|---|---|---|
| `inner.swap(Release)` (write.rs:455) ↔ `inner.load(Acquire)` (read.rs:186) | Release-Acquire | Yes; canonical pair |
| `epoch.fetch_add(AcqRel)` (read.rs:180) ↔ `epoch.load(Acquire)` (write.rs:276, 465) | AcqRel-Acquire | Yes |
| `fence(SeqCst)` (write.rs:462) and `fence(SeqCst)` (read.rs:183) | StoreLoad barrier | **NECESSARY** — pairing the writer's swap+fence with reader's epoch+fence is the linchpin of the algorithm. Downgrading either to Acquire/Release breaks the cross-variable visibility. The prior round modeled this with `MCSkipReaderFence` / `MCSkipWriterFence` and found 0 bugs — confirming the fences are placed correctly. |
| `fence(SeqCst)` in take_inner (write.rs:183) | After wait, before drops | Sound for the wait-to-drop ordering, but **does not save Bug A** because `wait` itself returns prematurely. |
| try_publish's epoch scan (write.rs:329-341) | Acquire load only, no fence before scan | Sound — the prior swap+fence (from the previous publish cycle) ensures the snapshot used by this scan is consistent. |

### 4.4 Findings worth recording but not modeling

- **read.rs:59 — `epochs.lock().unwrap()` in ReadHandle::Drop** — if poisoned, double-panic during drop and slab slot leaks (writer would deadlock on missing parity restoration). Robustness issue, not a protocol bug.
- **write.rs:217-221 — Drop calls take_inner which calls publish; if publish panics (poisoned mutex), Drop double-panics → abort.** Robustness issue.
- **sync.rs:9 FIXME** — loom 0.7.2 does not support SeqCst fences; sync.rs downgrades to Acquire under loom. This means loom tests cannot detect SeqCst-related bugs. Tracked upstream at tokio-rs/loom#117.
- **`raw_write_handle()` not marked `unsafe`** — discussed above as CM-4; docs flag the contract but compiler does not enforce.
- **Aliased::change_drop direction-asymmetry** — documented above as CM-5.

## 5. Cross-Reference with Prior Round

The prior round (`/home/ubuntu/Specula/case-studies/left-right/modeling-brief.md`) covered:
- Family 1 (Memory Ordering) — `MCSkipReaderFence`, `MCSkipWriterFence` adversaries; 0 bugs found.
- Family 2 (Oplog determinism) — covered via aliasing model; not the focus of this round.
- Family 3 (Reader lifecycle) — clone+publish deadlock; covered.
- Family 4 (Publish variants) — listed `take_inner` correctness as MC-3 but assumed safe.

This round adds:
- **NEW: Confirmed bug in take_inner** (Bug A / PR #144), supersedes the prior MC-3 assumption.
- **NEW: Reentrant enter panic on shutdown** (Bug B), not in prior brief.
- **NEW: Caller-misuse focus** — long-held guards (CM-1), drop-with-readers (CM-2), raw_write_handle misuse (CM-4).
- **Action granularity in `take_inner` and `update_and_swap`** is the key gap to fix from the prior modeling.

## 6. Verification Method Per Finding

| Finding | Method | Reason |
|---|---|---|
| Bug A: take_inner UAF | Model checking | Action granularity bug; spec should reproduce and confirm fix |
| Bug B: Reentrant enter `unreachable!` | Code review (verifiable by stress test) | Trivial fix; clear logic gap |
| CM-1: Long-held guard liveness | Model checking | Liveness property; needs fairness model |
| CM-2: Drop-with-readers | Model checking (subsumed by Bug A) | Same mechanism |
| CM-3: Clone+publish ordering | Model checking | Already covered by prior round; no new bug |
| CM-4: raw_write_handle | Code review | API design; Rust type system limitation |
| CM-5: change_drop direction | Code review | Documentation gap |
| Memory ordering (SeqCst fences) | Already model-checked (prior round) | 0 bugs; confirms fence placement |
| Aliased determinism | Code review | User-supplied; cannot be model-checked generically |
| Poisoned-mutex panic propagation | Code review | Robustness, not protocol |

## 7. References

- **Prior modeling brief**: `/home/ubuntu/Specula/case-studies/left-right/modeling-brief.md`
- **Prior analysis report**: `/home/ubuntu/Specula/case-studies/left-right/analysis-report.md`
- **Source files** (line refs in this report):
  - `artifact/left-right/src/write.rs` (838 lines)
  - `artifact/left-right/src/read.rs` (275 lines)
  - `artifact/left-right/src/read/guard.rs` (130 lines)
  - `artifact/left-right/src/aliasing.rs` (430 lines)
- **Open PR**: jonhoo/left-right#144 ("Fix data race on writehandle drop") — TSAN-detected, awaiting maintainer review.
- **Reference paper**: Left-Right concurrency scheme (Ramalhete & Correia, 2015) — https://hal.archives-ouvertes.fr/hal-01207881/document
- **Production usage**: `evmap` and downstream high-throughput Rust services.
