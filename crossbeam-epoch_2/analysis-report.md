# crossbeam-epoch — Analysis Report

Audit trail for the code analysis. The actionable handoff lives in `modeling-brief.md`; this file documents coverage, evidence, and exclusions.

---

## 1. Reconnaissance

### 1.1 Scope

- **System**: `crossbeam-epoch` — Rust epoch-based memory reclamation (EBR).
- **Repo path**: `artifact/crossbeam/crossbeam-epoch/`
- **LOC** (core, excluding tests): ~3.7 kLOC across 9 files.
- **Public API**: `pin()`, `Guard` (`defer`, `defer_destroy`, `flush`, `repin`, `repin_after`), `unprotected()`, `Atomic`, `Owned`, `Shared`, `Collector`, `LocalHandle`.

### 1.2 Core files (read in full)

| File | LOC | Role |
|---|---:|---|
| `src/internal.rs` | 636 | `Global`, `Local`, `Bag`, `SealedBag`; pin/unpin/repin/finalize/try_advance |
| `src/guard.rs` | 528 | `Guard`, `defer_unchecked`, `defer_destroy`, `flush`, `repin`, `repin_after`, `unprotected` |
| `src/epoch.rs` | 148 | `Epoch` (LSB = pinned bit), `AtomicEpoch`, `wrapping_sub`, `successor` |
| `src/collector.rs` | 455 | `Collector`, `LocalHandle::pin/release_handle` |
| `src/default.rs` | 101 | thread-local `HANDLE`; `pin()` shim |
| `src/deferred.rs` | 153 | `Deferred` (3-word inline + heap fallback), `Deferred::call` |
| `src/atomic.rs` | 1735 | `Atomic`, `Owned`, `Shared`, `Pointable`, `compare_exchange*` |
| `src/sync/queue.rs` | 475 | Michael–Scott queue for `SealedBag` |
| `src/sync/list.rs` | 497 | Lock-free intrusive list for `Local`s |

### 1.3 System category

**Category B — Concurrent / Lock-Free / Runtime.** Sub-category per `concurrent-analysis.md` §5: **reader-writer separation / reclamation.** Justification: no network/RPC; the entire correctness story is per-thread state machines coordinating an atomic `global.epoch`, a per-thread `local.epoch`, and a global queue of retired bags via CAS, fences, and reads. Recommended fault-family priority (after 5.1 Thread Interleaving): **5.5 Memory Ordering**, **5.6 Pointer Reuse**, **5.7 Caller Misuse**.

### 1.4 Atomicity boundaries identified

| Operation | Splittable steps |
|---|---|
| `Local::pin` (cold path, `guard_count == 0`) | `guard_count++` → `local.epoch.store(global.pinned(), …)` → SeqCst fence → `pin_count++` → maybe `collect()` |
| `Local::unpin` (cold path, `guard_count == 1`) | `guard_count--` → `local.epoch.store(starting, Release)` → maybe `finalize()` |
| `Local::repin` | load local → load global → if differs `local.epoch.store(global.pinned(), Release)` (no SeqCst fence) |
| `Local::defer` | `bag.try_push` → if full: `push_bag` (SeqCst fence + global.epoch.load + queue.push) |
| `Global::try_advance` | load global (Relaxed) → SeqCst fence → iterate locals → on Stalled return → Acquire fence → store global.successor (Release) |
| `Global::collect` | `try_advance` → loop: queue.try_pop_if(is_expired) → drop SealedBag (runs Deferreds) |
| `Local::finalize` (under handle_count temporarily set to 1) | pin → push_bag → set handle_count=0 → ptr::read collector → entry.delete → drop collector |
| MS-Queue `pop_internal` | head.load(Acq) → next.load(Acq) → CAS head → if head==tail: CAS tail → defer_destroy(head) → return data |

These boundaries drive the action granularity for the spec.

---

## 2. Bug Archaeology

### 2.1 Coverage

- **Total commits to crossbeam-epoch**: 301 (`git log --oneline --all -- crossbeam-epoch/`).
- **Bug-fix-flavoured commits** (after grep on fix/race/UB/leak/etc.): ~85.
- **Commits read in detail** via `git show`: 12 (listed below).
- **GitHub issues collected**: 60+.
- **Issues read with full discussion**: 24 (across 3 parallel subagents + manual `gh issue view`).
- **Issues confirmed as protocol bugs**: 1 (`#105`); confirmed-and-fixed: 1 more (`#238`); confirmed-but-pure-Rust-UB or perf: 6.
- **Excluded as false positives / non-bugs**: 14 (sanitizer false positives, design proposals, doc requests, user misuse, miri tooling gaps).

### 2.2 Confirmed protocol bugs (historical)

| ID | What | Where | Status |
|---|---|---|---|
| Issue #105 | `pin()` from inside an outer pin advanced the local epoch via `try_collect`, breaking the EBR invariant | `Local::pin` | Fixed long ago by gating epoch update on `guard_count == 0` (`internal.rs:409`) |
| Issue #238 / commit `2618830` | MS-Queue `pop_internal` retired the dequeued head before unlinking it from `tail` when `head == tail`, causing UAF via tail | `sync/queue.rs:120-143` | Fixed: head==tail → tail CAS before `defer_destroy(head)` |
| Commit `893a08d` | `repin()` compared local pinned epoch to global epoch's *raw* (un-pinned) value, so they never matched and repin never updated | `internal.rs:489` | Fixed by `.pinned()` on the global epoch value |
| Commits `52a4e31` / `389a60b` | "2-epoch" rule was suspected unsafe under thread-stall; switched to "3-epoch + load-validate retry in pin"; later reverted to 2-epoch after re-analysis | `internal.rs` is_expired, push_bag, pin | Currently 2-epoch (`global - bag.epoch >= 2` at `internal.rs:160`); the validation loop is gone |

### 2.3 Confirmed implementation/UB bugs (not protocol-level)

| ID | What | Severity |
|---|---|---|
| `f48c1c7` | `mem::uninitialized::<ManuallyDrop<T>>()` in queue sentinel → switched to `MaybeUninit<T>` | critical UB |
| `b911157` | `MaybeUninit::<Data>::assume_init()` over `[usize; 3]` could be smaller than the stored `FnOnce` | critical UB |
| `385bf3e` / Issue #693 | `<[MaybeUninit<T>] as Pointable>::init` stored byte size as slice length → buffer overflow on deref | critical UB |
| `8f487bd` / Issue #689 | `Pointable::init` for `[MaybeUninit<T>]` ignored `alloc::alloc` returning null | high (crash on OOM) |
| `02fb08a` / Issues #545, #957, #993 | Stacked-borrows violations; `IsElement::element_of` and `Pointable::deref` returned `&T` while caller held a raw pointer | latent UB under SB |
| `9c95360` | `defer_unchecked` on an `unprotected` guard dropped the closure without running, leaking captured destructors | high (leak) |
| `4bb27db` / Issue #1020 | `Local.epoch` shared a cache line with hot fields → false sharing | medium (perf) |
| `088012e` | `IsElement::finalize` was called from `List::Drop` without a guard; reshaped to take `&Guard` so unprotected execution is explicit | medium (API) |
| `6bc0447` | `Vec::from_raw_parts(ptr, len, len)` in test lost the original `cap` | medium (test-only UB) |

### 2.4 Open issues that remain relevant

| ID | What it implies for modeling |
|---|---|
| `#566` | Garbage accumulates without bound under high `defer` traffic if `flush` is not called. Memory growth, not safety. **Liveness, not safety.** Worth a *fairness/progress* invariant in the spec. |
| `#977` | Open question about whether `relaxed-store + SeqCst-fence` in `pin()` is equivalent to `seqcst-store`. Confirms the pin's SeqCst fence is load-bearing and undocumented in source. |
| `#1207` | TSan flags fences as data races; not a real bug, but documents that the protocol's correctness depends on fences TSan does not model. |
| `#287` | Design proposal for dedicated GC thread; not actionable. |
| `#221` | PEBR (Hazard + EBR) research track; not actionable for current spec. |

### 2.5 Excluded as non-bugs / out-of-scope

`#1006`, `#1064`, `#1108`, `#1027`, `#1042`, `#1175`, `#1164`, `#1165`, `#960`, `#685`, `#464`, `#347`, `#820`, `#398` — closed as user-question, miri bug, static-analyzer false-positive, or feature request.

---

## 3. Deep Analysis Findings

The following are findings produced by reading the code directly (not from issues). Each was verified by re-reading the cited line(s).

### F1. `try_advance` returns the old global_epoch on `IterError::Stalled`

`internal.rs:251-256`. When the lock-free iterator over `locals` aborts due to a concurrent insert/delete, `try_advance` returns `global_epoch` — the value loaded at the start of the function under `Relaxed`. If another thread advanced the global epoch in the meantime, the *return value* is stale. The caller is `collect()` which uses it as the cutoff for `is_expired`. A stale (smaller) cutoff just means fewer bags are reclaimed this round — **safe but lossy**. Worth modeling because the spec author may otherwise assume `try_advance` returns the "real" current global.

### F2. `try_advance` uses `Relaxed` for the global load before the SeqCst fence

`internal.rs:238`. The argument that this is correct is the standard SC-fence Dekker pattern: every pinning thread also issues `local.store(_, Relaxed); SC fence; …`, and the SC-fence total order guarantees the cross-thread visibility. The relaxed load → fence pattern is **documented in code**, but the symmetry between `pin`'s side and `try_advance`'s side is not explicitly tied together. Spec must capture both fences as the same SC-order sync point.

### F3. `repin()` does NOT issue a SeqCst fence after the new local epoch store

`internal.rs:493-501` and the comment at `:497-499`. Repin only does a Release store. The author asserts: "we don't need a following SeqCst fence, because it is safe for memory accesses from the new epoch to be executed before updating the local epoch. At worst, other threads will see the new epoch late and delay GC slightly." Verified the safety argument: if a load is reordered before the Release store, it's protected by the *old* local epoch (because old epoch ≤ new epoch in terms of GC protection). The model can capture this by treating `repin` as a *non-blocking advancement* of local epoch with no fence.

### F4. `Local::finalize` calls `pin()` with `handle_count` set to 1, then a guard's `Drop` runs `unpin()`

`internal.rs:537-549`. The temporary handle_count = 1 prevents recursive finalization when the pin/unpin pair inside finalize completes. After the inner unpin sets `local.epoch = starting()`, handle_count is checked (still 1, so no recursion), then handle_count is reset to 0, then the Local entry is deleted from the global list and the Collector reference is dropped. **The cleanup ordering is critical**: collector reference is read before `entry.delete` so that the Local's collector pointer is captured before the Local node may be reclaimed. Worth modeling because the wrong ordering would dangle the Arc.

### F5. `repin_after` re-pins via `mem::forget(local.pin())` then `release_handle`

`guard.rs:366-393`. When `repin_after` is called and the user's closure `f()` runs in unpinned state, the panic-safe `ScopeGuard` re-pins at exit. But the inner `pin()` issues a SC fence and may also trigger `collect()` (because `pin_count % 128 == 0` is reachable). So the closure's final cleanup is non-trivial. Worth modeling the action sequence: `acquire_handle` → `unpin` → run f → `pin` (with potential fence + collect) → `release_handle`.

### F6. `Bag::drop` runs deferred functions; a deferred function may call `pin`

`internal.rs:125-134`. When a `SealedBag` is dropped (during `collect`), `Bag::drop` iterates through deferreds and calls each. A deferred function is user-supplied; it can re-enter `pin`/`defer`. This is **reentrant** — the outer caller (the collecting thread) already holds a `Guard`. The reentrant pin sees `guard_count > 0` and skips epoch update. The reentrant `defer` adds to the same Local's bag. So the protocol survives this. The model must capture that Bag drop is interleavable with the rest of the protocol.

### F7. `Guard::defer_unchecked` short-circuits for the unprotected guard

`guard.rs:194-200`. If `self.local.is_null()`, the closure is **executed immediately**. This is a different code path from a pinned guard's defer. Consequence for adversarial callers: a destructor running an unprotected `defer` is a regular function call, not a deferred one. This was the source of commit `9c95360` (a previous version dropped the closure without calling it).

### F8. `try_advance` does not validate after the loop

`internal.rs:236-288`. After scanning all locals and concluding that everyone is at `global_epoch`, the function unconditionally stores `successor`. It does **not** re-check whether another thread has already advanced the epoch. The store is `Release` and may overwrite a newer value. The comment at `:281-284` argues this is safe because "the global epoch cannot be advanced two steps ahead" of the calling thread (which is pinned at `global_epoch`). Verified: this is correct given the 2-epoch invariant, but it depends on the caller being pinned. If `try_advance` is ever called from a non-pinned guard, this argument breaks. Worth a defensive invariant in the spec.

### F9. `wrapping_sub` epoch arithmetic on 32-bit may permit unbounded delay

`epoch.rs:49-54`. With `AtomicUsize` (32-bit fallback), the epoch can wrap. `is_expired` uses signed arithmetic and rejects bags whose `wrapping_sub` is negative — a bag old enough to wrap around past its true age would be considered "not expired" and stay in the queue forever. **Liveness issue, not safety**, but worth flagging. AtomicU64 path (commit `0b3732d`) makes this practically impossible.

### F10. `guard_count` and `handle_count` underflow not defended

`internal.rs:466-478`. `unpin` does `self.guard_count.set(guard_count - 1)` with no debug_assert. If called when guard_count == 0, underflow. Not reachable through public API (Guard::Drop is called once per pin; `repin_after` is bracketed). **Code-review-only**, but adversarial-caller modeling could expose it if the spec allows arbitrary unpin actions.

### F11. `MAX_OBJECTS = 64` (regular) / `4` (sanitize/miri); silent capacity bound

`internal.rs:65-69`. The fact that `MAX_OBJECTS` is reduced under sanitize flags is invisible to a spec author who reads only the production constant. Spec should use a parameter `BAG_CAPACITY` and check both small-N and bounded-bigger-N configurations.

### F12. `SealedBag::is_expired` uses the global epoch passed in by `collect`

`internal.rs:157-161`. Currently 2-epoch rule (`>= 2`). Note: the bag is sealed with the current global epoch (read inside `push_bag` after a SeqCst fence at `internal.rs:194-197`). So a bag retired in epoch E expires when global ≥ E + 2 — i.e., after one *full* advance. The historical 3-epoch debate (commit 52a4e31 → 389a60b) is settled by the in-place tail-advance fix in MS-Queue (commit 2618830). The spec should make this rule a checkable invariant.

---

## 4. Verification Notes

For each finding, I re-read the cited lines, traced the call sites, and checked for compensating mechanisms. None of F1–F12 is an actionable "bug" today; they are all **modeling considerations** — places where the spec author must be careful about action granularity, fence ordering, and adversarial caller behaviour.

The two genuine *bugs* in this analysis are historical (#105 and #238) and have been verified to be fixed in the current code. They remain valuable as **modeling targets** to confirm the spec's invariants would catch them in the buggy variant.

---

## 5. Limitations

- The spec language is TLA+; we cannot directly model TSO/ARM weak-memory effects. Memory-ordering bugs are modeled as bounded fault injections per `concurrent-analysis.md` §5.5.
- The MS-Queue (`sync/queue.rs`) is itself a non-trivial lock-free structure; a complete spec of it would dominate state space. Suggest modeling its retire-before-unlink contract as an *abstract* invariant ("any pointer passed to `defer_destroy` is unreachable from any reachable atomic at the time of the call") rather than a faithful queue spec, unless a queue bug is the explicit target.
- The intrusive list (`sync/list.rs`) is similarly non-trivial. Its main role is hosting `Local`s. Model with a small bounded set of Locals and a coarse "delete tag" action.

---

## 6. Reference Pointers

- Issue #105: <https://github.com/crossbeam-rs/crossbeam/issues/105>
- Issue #238: <https://github.com/crossbeam-rs/crossbeam/issues/238>
- Issue #221 (PEBR design): <https://github.com/crossbeam-rs/crossbeam/issues/221>
- Issue #566 (memory growth): <https://github.com/crossbeam-rs/crossbeam/issues/566>
- Issue #977 (pin's SC fence): <https://github.com/crossbeam-rs/crossbeam/issues/977>
- Commit 2618830 (MS-Queue UAF fix), 893a08d (repin bug fix), 52a4e31, 389a60b (2-vs-3 epoch flip-flop)
- Reference algorithm: relaxed-memory RFC `crossbeam-rs/rfcs:2017-07-23-relaxed-memory.md`; PEBR paper at <https://cp.kaist.ac.kr/gc/>

