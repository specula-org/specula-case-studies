# Modeling Brief: crossbeam-deque (Chase-Lev Work-Stealing Deque)

## 1. System Overview

- **System**: `crossbeam-deque` (Rust), the work-stealing deque underpinning tokio's multi-thread runtime executor and rayon.
- **Code scale**: ~2,233 LOC in one file (`crossbeam-deque/src/deque.rs`); 109 LOC in `lib.rs`.
- **Category**: **B (Concurrent / Lock-Free / Runtime)** — pure shared-memory CAS-based deque on `AtomicIsize`/`AtomicUsize`/`Atomic<Buffer>` with crossbeam-epoch reclamation. No RPC, no disk, no message passing. Fits the "lock-free data structures" sub-category from `concurrent-analysis.md` § 5.
- **Algorithms**:
  - **Worker/Stealer**: Chase-Lev dynamic circular work-stealing deque (SPAA 2005), with Le-Pop-Cohen-Nardelli weak-memory refinements (PPoPP 2013).
  - **Injector**: linked list of fixed-size 31-slot blocks (LAP=64, BLOCK_CAP=63, SHIFT=1, HAS_NEXT bit), MPMC FIFO style, slot lifecycle via `WRITE`/`READ`/`DESTROY` bits.
- **Key deviations from textbook Chase-Lev**:
  - Buffer is epoch-managed (`crossbeam_epoch::Atomic<Buffer<T>>`) so resized old buffers can be retired safely while stealers hold pinned references.
  - `Buffer::read`/`write` use `ptr::read_volatile`/`write_volatile` on `MaybeUninit<T>` — intentionally racy at LLVM level; safe because `MaybeUninit` has no `Drop` so a spuriously-read garbage value is forgotten without UB.
  - Worker-side `fence(Release)` + `back.store(Relaxed)` pattern (since commit `23b68fb3`, Feb 2026) to keep ThreadSanitizer happy without full Release on every store.
  - LIFO and FIFO worker flavors share the deque; batch-steal between FIFO and LIFO requires a reversal pass on `dest_buffer`.
- **Concurrency model**: one Worker thread (queue is `!Sync`, `_marker: PhantomData<*mut ()>`) + N Stealer threads (`Stealer<T: Send>: Send + Sync + Clone`) sharing `Arc<CachePadded<Inner<T>>>`. Injector is full MPMC.

## 2. Bug Families

### Family A: Buffer-Resize / Generation Race (CVE-2021-32810 family)

**Mechanism**: Stealer reads slot at index `f` from buffer pointer `B1`, then CAS-claims `front` from `f` to `f+1`. Between read and CAS, worker may resize and swap `Inner::buffer` to `B2`. Without a re-check, the stealer's CAS succeeds against the new generation, returning a value that may have been double-consumed or never written.

**Evidence**:
- Historical: CVE-2021-32810 fix in commit `38c07fcf` (PR #726, Jul 2021) and v0.7 backport `180b462b` (PR #728). Diff added `self.inner.buffer.load(Ordering::Acquire, guard) != buffer ||` before each `front.compare_exchange` in `steal`, `steal_batch_with_limit` (Fifo and Lifo), and the in-loop CAS of `steal_batch_with_limit_and_pop` Lifo.
- Historical (UB residual): commit `8d7db8c0` (PR #855, Jul 2022) — the read-volatile-of-`T` itself was UB when `T` contained a `Box<U>`, regardless of whether the value was used. Fixed by switching `Buffer::read`/`write` to operate on `MaybeUninit<T>` (deque.rs:78-90) so no validity invariant is asserted on a stale read.
- Code analysis: deque.rs:1083 — `steal_batch_with_limit_and_pop` Lifo *first* CAS is the **only** stealer-side `front.compare_exchange` call site that lacks a `self.inner.buffer.load(Ordering::Acquire, guard) != buffer` guard. All four peers (deque.rs:670, 816, 863, 1061, 1121) include it. The asymmetry is currently safe because (a) the buffer pointer is captured under `guard` so the read at deque.rs:1034 is not UB, and (b) `Worker::resize` (deque.rs:299-303) preserves logical indices on copy. But the safety derives from an undocumented invariant ("resize is index-preserving") that no type or comment enforces — a refactor that compacted the new buffer would silently introduce a double-take.

**Affected code paths**: `Stealer::steal` (deque.rs:641-683); `Stealer::steal_batch_with_limit` (deque.rs:746-925); `Stealer::steal_batch_with_limit_and_pop` (deque.rs:989-1178); `Worker::resize` (deque.rs:289-322); `Worker::push` resize trigger (deque.rs:411-414); `Worker::pop` shrink triggers (deque.rs:481-483, 533-538).

**Suggested modeling approach**:
- Variables: `front`, `back`, `buffer_generation` (counter advancing on each resize), `slot_value[gen][index]`, per-stealer `pinned_gen` (the generation the stealer's `guard.read` saw), per-stealer local `f`.
- Actions: split the steal into `Steal_LoadFront`, `Steal_LoadBuffer`, `Steal_ReadSlot`, `Steal_RecheckBuffer`, `Steal_CASFront` — five actions, each interleavable with `Worker_Resize`, `Worker_Push`, `Worker_PopBackOnly`, `Worker_PopLastTask`.
- Granularity: explicitly model the `Steal_RecheckBuffer` step as conditional in the spec (omit it for line 1083 in one variant) so the model checker can demonstrate why every other site needs it. Composing this with a "Worker_ResizeCompact" alternative resize action exposes the latent dependency on the index-preservation invariant.
- Invariant: every `Steal::Success(v)` corresponds to a unique element previously pushed (no double-take); every push event eventually appears in exactly one `Success` or in the deque (no skip).

**Priority**: **High**. Direct production-impact (CVE level), still has an asymmetric site, and prior verification did not include any fault injection.

### Family B: Memory Ordering Across the Worker/Stealer Boundary

**Mechanism**: Multiple atomic load/store pairs synchronize state across the worker/stealer cut. Worker `push` uses `fence(Release)` + `back.store(Relaxed)` (or `Release` under TSan); stealer reads `back` `Acquire`. Worker LIFO `pop` uses the textbook Dekker pattern: `back.store(b-1, Relaxed)` → `fence(SeqCst)` → `front.load(Relaxed)` → conditional `front.compare_exchange(SeqCst, Relaxed)`. Stealer mirrors this with `front.load(Acquire)` → conditional `fence(SeqCst)` (only when `epoch::is_pinned()`) → `back.load(Acquire)` → CAS. Wrong relaxation on any of these atoms loses the synchronization.

**Evidence**:
- Historical: commit `23b68fb3` (Feb 2026, PR #1233) split the back-store into `Release` (under TSan) vs `Relaxed` (production), guarded by a `cfg(crossbeam_sanitize_thread)`. The author's note in the diff makes the safety argument architecturally explicit: TSan does not model fences, so it would falsely flag `Relaxed` after a fence.
- Historical: comment at deque.rs:645-652 explicitly notes that the SeqCst fence on the steal path is conditional on whether `epoch::pin()` will issue one; the implementation depends on `crossbeam-epoch` issuing a SeqCst-equivalent fence on first pin.
- Code analysis: deque.rs:402 (`front.load(Acquire)` in `push`) and deque.rs:643 (`front.load(Acquire)` in `steal`) are paired with deque.rs:467 (`fetch_add(SeqCst)` in FIFO pop), 521 (`compare_exchange(SeqCst, Relaxed)` in LIFO pop), 674/820/867/1086/1125 (stealer `compare_exchange(SeqCst, Relaxed)`). Mismatching any of these to weaker orderings would be a real bug.

**Affected code paths**: `Worker::push` fence-and-store (deque.rs:418-432); `Worker::pop` LIFO fence pattern (deque.rs:489-528); `Worker::pop` FIFO fetch_add + Relaxed restore (deque.rs:467-471); all `Stealer::steal*` SeqCst fences (deque.rs:651, 765, 846, 1007, 1105) and CASes (deque.rs:674, 820, 867, 1086, 1125); `Injector::push` Release stores at block install (deque.rs:1427-1429, 1435); `Injector::steal` SeqCst fence (deque.rs:1488).

**Suggested modeling approach**:
- Variables: each Atomic gets an explicit "ordering label" in the spec (`SeqCst`, `Release`, `Acquire`, `Relaxed`); a bounded `MCRelaxDowngrade(label)` adversary downgrades suspected bridge labels under counter limit.
- Actions: split `Worker_Push` into `Push_Write_Slot`, `Push_Fence`, `Push_Store_Back`. Split LIFO `Worker_Pop` into `Pop_Store_Back`, `Pop_Fence`, `Pop_Load_Front`, `Pop_CAS_Front`, `Pop_Restore_Back`.
- Granularity: model the `is_pinned() ? fence(SeqCst) : ()` choice on the stealer side as non-deterministic — both branches must be safe.
- Invariant: when `is_empty() == true` is observed at the linearization point of the SeqCst load of `front`, no successful `Steal::Success` can be linearized in a state where the queue was non-empty between the push and the steal.

**Priority**: **High**. Memory-ordering bridges are the textbook Chase-Lev failure mode; prior coverage did not include any relaxation adversary.

### Family C: Adversarial Caller Harness — Multi-Stealer, `Stealer::clone`, Drop-While-Borrowed

**Mechanism**: Documented contract is "one Worker, many Stealers" but the API allows: cloning a `Stealer` while another steal is in flight; concurrently executing N stealers against the same `Inner`; dropping the `Worker` while Stealers still hold an `Arc` reference (the `Inner` survives via stealer's Arc; `Worker::drop` does not touch shared state explicitly but `Inner::drop` runs at refcount==0 only). `Stealer::clone` is just `Arc::clone` so it's a synchronization-free pure-data operation; the concern is rather (a) two stealers racing on `front` via SeqCst CAS, (b) a stealer beginning a steal while the worker concurrently resizes, and (c) panics in the middle of `Injector::push` leaving `wait_write`/`wait_next` spinning forever.

**Evidence**:
- Historical: `Stealer<T: Send>: Send + Sync + Clone` (deque.rs:582-583, 1181-1188).
- Historical: `Worker` has `_marker: PhantomData<*mut ()>` (deque.rs:208) making it `!Send + !Sync`; only the original thread can call `push`/`pop`/`resize`. This is the contract crossbeam-deque relies on.
- Code analysis: `Inner::drop` (deque.rs:125-145) uses `epoch::unprotected()` and `get_mut`. Sound only when no concurrent access — guaranteed by `Arc` refcount==0.
- Code analysis: `Injector::push` mid-operation panic (deque.rs:1421-1438): if the pusher's CAS succeeds at deque.rs:1418 but the thread panics before deque.rs:1435 (`slot.state.fetch_or(WRITE, Release)`), every other stealer reaching that slot's `wait_write()` (deque.rs:1224-1229) spins indefinitely.

**Affected code paths**: All public Stealer APIs (deque.rs:585-1178); `Injector::push`/`steal*` (deque.rs:1388-1952); `Block::wait_next`/`Slot::wait_write` (deque.rs:1224-1229, 1272-1281).

**Suggested modeling approach**:
- Variables: a small `ClientHarness` action set with per-thread program counter; allow N stealers to non-deterministically interleave with worker.
- Actions: `Steal_Begin`, `Steal_Read`, `Steal_CAS`, `Steal_Commit` per stealer; explicit `Stealer_Clone` transition that adds a fresh stealer thread; `Worker_Drop` that disables further Worker actions.
- Granularity: keep the harness outside the deque spec — let it pick which stealer fires next.
- Invariant: at most one `Steal::Success` per pushed element; the deque's logical state (slots between `front` and `back`) refines the multiset of pushed-but-not-yet-stolen elements.

**Priority**: **Medium**. Production schedulers (rayon, tokio) only spawn ~num_cpus stealers; harness is well-controlled. But the prior verification had no adversarial caller.

### Family D: CAS-Weak Spurious Failure (Injector)

**Mechanism**: `Injector::push` uses `compare_exchange_weak` on `tail.index` (deque.rs:1415). Spurious failure paths (deque.rs:1439-1443) reload `tail` and `block` and retry; pre-allocated `next_block` in `Option<Box<Block<T>>>` is preserved across retries to avoid repeated allocations. The artifact at HEAD `03919fed` *also* uses `compare_exchange_weak` for `head.index` in all three Injector steal sites (deque.rs:1506, 1658, 1861) — the strong-CAS fix in commit `1015b21d` (Feb 2026, post-HEAD) is **not** in this snapshot. Spurious failure on `head.index` CAS triggers `Steal::Retry`, which is a liveness/perf concern (test doctests assumed `weak` would not fail and broke under Miri's spurious-fail injection) but not a safety concern.

**Evidence**:
- Historical: commit `1015b21d` (Feb 2026) — "deque: Use strong CAS in Injector::steal*" — switched the three steal CASes from `_weak` to strong because some sequential doctests assumed weak CAS would not fail. Removed the `-Zmiri-compare-exchange-weak-failure-rate=0.0` Miri flag in `ci/miri.sh`. **Not in artifact HEAD.**
- Code analysis: `grep -n "compare_exchange" deque.rs` shows: 4 strong (Worker LIFO 518, Stealer 4×), 4 weak (Injector push 1415, Injector steal 1506/1658/1861).
- Worker/Stealer side audit: every front-CAS uses `compare_exchange` (strong) — see deque.rs:518, 674, 820, 867, 1086, 1125. **Strong by design**, since spurious failure on the LIFO last-task CAS would discard a real popped task (the `task.take()` at deque.rs:527 would clear it).

**Affected code paths**: `Injector::push` retry loop (deque.rs:1394-1444); `Injector::steal` (deque.rs:1503-1510); `Injector::steal_batch_with_limit` (deque.rs:1655-1662); `Injector::steal_batch_with_limit_and_pop` (deque.rs:1858-1865).

**Suggested modeling approach**:
- Variables: per-CAS `weak_or_strong` tag.
- Actions: each `compare_exchange_weak` site gets an extra `MCSpuriousFail` branch under counter bound; each strong site does not.
- Invariant: spurious-fail branches must always retry (liveness — eventually some CAS succeeds in absence of true contention) and must never produce an incorrect `Steal::Success`.
- Verify the loop at deque.rs:1394 correctly handles spurious fail: pre-allocated `next_block` is preserved (deque.rs:1407-1410), so no double-allocation; on actual contention or spurious fail we just retry.

**Priority**: **Medium-Low**. Liveness, not safety; Worker/Stealer side is already strong.

### Family E: Block Lifecycle Invariant in Injector (READ / DESTROY bits)

**Mechanism**: `Injector` blocks have a 31-slot lifecycle. Pusher sets `WRITE` bit (deque.rs:1435). Stealer/batch-stealer sets `READ` bit on consumed slots and calls `Block::destroy(block, count)` (deque.rs:1284-1301) when finishing a slot at the block boundary or when observing `DESTROY` on a peer slot. The walker in `Block::destroy` descends from `count-1` to 0, sets `DESTROY` on the first `READ=0` slot it finds, then returns. The mid-batch loop at deque.rs:1731-1738 / 1940-1947 iterates ascending `[offset..new_offset)` and **breaks early** on first observed `DESTROY` — leaving `[i+1..new_offset)` un-`READ`-marked. The end-of-block batch path (deque.rs:1728-1729 / 1937-1938) calls `Block::destroy(block, offset)` *without* setting `READ` on slots `[offset..BLOCK_CAP)` at all. Both shortcuts are safe under the invariant: foreign walkers can only have anchor `count ≥ new_offset`, descend to slot `new_offset-1` (the topmost slot of our batch), set DESTROY there, and return — never touching `[offset..new_offset-1)`. The ascending loop visits `new_offset-1` last, so `break` fires only after all earlier slots are READ-marked.

**Evidence**:
- Code analysis: deque.rs:1284-1301 (walker), 1731-1738 / 1940-1947 (mid-batch break loop), 1728-1729 / 1937-1938 (end-of-block path), 1532-1535 (single-task `steal()` end-of-block), 1300 (final `drop(Box::from_raw(this))`).
- Reasoning: see Phase-3 Injector deep-analysis; the invariant "walker descends and stops at the first READ=0 slot ≥ offset; the topmost slot of any consumed range is its last to be READ-marked" is non-obvious and not commented in the code.

**Affected code paths**: `Block::destroy` (deque.rs:1284-1301); `Slot::wait_write` (deque.rs:1224-1229); `Injector::steal` end-of-block path (deque.rs:1530-1536); `Injector::steal_batch_with_limit` destroy loop (deque.rs:1726-1739); `Injector::steal_batch_with_limit_and_pop` destroy loop (deque.rs:1935-1948).

**Suggested modeling approach**:
- Variables: per-slot `state` ∈ {NONE, WRITE, WRITE+READ, WRITE+READ+DESTROY, WRITE+DESTROY}; per-block `next` pointer; a counter for live readers.
- Actions: split each consumer into `Read_Slot`, `Mark_Read`, `Maybe_Destroy_Walk`. Model walker as a separate atomic action that descends and stops at first READ=0.
- Invariant: every block is eventually freed (no leak); no slot is ever read after its block is freed (no use-after-free); `WRITE` set ⇒ task value at that slot is the value the pusher wrote.

**Priority**: **Medium**. Subtle invariant; if the walker logic is ever refactored or batch-loop gains an early-return, the invariant breaks silently.

### Family F: Empty / Non-Empty Race in Steal-Batch Loop

**Mechanism**: `Stealer::steal_batch_with_limit` Lifo (deque.rs:835-908) loads `front` *once* outside the loop at deque.rs:757, then iterates the per-step CAS up to `batch_size` times. Each iteration re-fences `SeqCst`, re-loads `back` (deque.rs:849), checks `b - f <= 0` → exit, re-reads slot at `f` from the **original** `buffer` pointer, then CAS. The protocol is: at most one task stolen per CAS, with `f` advancing locally only on success. The risk: between iterations, the worker may resize, push, or pop; the loop's re-loads catch some of these but not all. Specifically, the buffer pointer is captured once outside the loop and never reloaded — instead the `buffer.load() != buffer` re-check (deque.rs:863) acts as a generation guard, breaking the loop on resize. The MaybeUninit reads from the old buffer in already-stolen iterations remain safe because of resize index-preservation (Family A).

**Evidence**:
- Code analysis: deque.rs:757-908 (Lifo `steal_batch_with_limit`); deque.rs:1080-1162 (Lifo `steal_batch_with_limit_and_pop`).
- Historical: commit `4d574d40` and `89828aac` (Jan 2019) — fixed an earlier "wrong order" bug in steal_batch when source-Fifo/dest-Lifo or source-Lifo/dest-Fifo, and a typo where the reversal step used `buffer.deref()` (source) instead of `dest_buffer`. Confirms this loop is bug-prone.

**Affected code paths**: `Stealer::steal_batch_with_limit` Lifo (deque.rs:835-908); `Stealer::steal_batch_with_limit_and_pop` Lifo (deque.rs:1080-1162); FIFO→LIFO reversal pass (deque.rs:895-907, 1148-1160).

**Suggested modeling approach**:
- Variables: per-stealer `i` (current iteration), `f_local` (advancing front), `dest_b_local`, `task_holding` (mem::replace pattern in steal_batch_and_pop).
- Actions: split the loop into `BatchIter_LoadBack`, `BatchIter_ReadSlot`, `BatchIter_CheckBuffer`, `BatchIter_CAS`, `BatchIter_WriteDest`. Each iteration is interleavable.
- Invariant: the multiset of values copied to `dest_buffer[dest_b_orig..dest_b_local)` is a contiguous prefix of the source's `[f_orig..f_orig+batch_size_actual)` slots, with dest values reversed if `dest.flavor != source.flavor`.

**Priority**: **Medium**. Two prior bugs in this exact loop; complex; prior verification had no adversary.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Worker push/pop split into atomic-step actions | Family B — interleaving is the headline fault | One TLA+ action per atomic load/store/fence; LIFO pop is 5+ actions |
| Stealer steal split into 5+ actions | Family A — buffer-resize race has 5 distinguishable steps | `Steal_LoadFront`, `Steal_LoadBuffer`, `Steal_ReadSlot`, `Steal_RecheckBuffer`, `Steal_CASFront` |
| Buffer generation counter + per-stealer pinned generation | Family A — model the resize generation explicitly | `buffer_gen ∈ Nat`; `stealer_pin[s] ∈ Nat`; `slot_value[gen][i]` |
| Multi-stealer harness with `Stealer::clone` adversary | Family C — adversarial caller | Bounded `MCStealerClone` action; per-stealer PC |
| Memory-ordering relaxation adversary on flagged bridges | Family B — inverse-engineer the ordering proof | `MCRelaxDowngrade(label)` with bounded counter; only on labels documented as load-bearing |
| CAS-weak spurious failure on Injector pushes/steals | Family D — verify retry-loop correctness | `MCSpuriousFail` branch on `compare_exchange_weak` sites |
| Injector block lifecycle (WRITE/READ/DESTROY bits) | Family E — non-obvious walker invariant | Explicit per-slot state machine + walker action |
| Steal-batch Lifo loop with per-iteration interleaving | Family F — two prior bugs in this loop | Loop unrolled into iter-actions; per-iter CheckBuffer |
| Asymmetric absence of `buffer.load() != buffer` at deque.rs:1083 | Family A — verify whether the safety is actually invariant | Spec includes a flag `model_with_recheck` on each CAS site; flip the line-1083 site to test |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Volatile-read-vs-volatile-write data race in `Buffer::read`/`write` | LLVM-level data race that is by-design under `MaybeUninit`; not a TLA-checkable property. Documented in commit `8d7db8c0` and discussed in #589/#646. |
| ThreadSanitizer false positives on the deque | TSan does not understand fences (commit `23b68fb3` adds a TSan-specific cfg-gated branch); modeling TSan's view is not the spec author's job. |
| `wait_write` / `wait_next` infinite spin on pusher panic | Algorithm precondition: pushers must not abort mid-operation. Out of scope for safety modeling. |
| Allocation failure inside `Buffer::alloc` | `Box::new` via `Global` calls `handle_alloc_error`/abort; deque is documented to abort on OOM. (Note: Block::new at deque.rs:1254-1268 *does* check null via `Global.allocate_zeroed` since #1159 — relevant, but the allocator-failure path just aborts.) |
| Panic-safety of user task `T::drop` during `Inner::drop` | Out of TLA scope; pure Rust safety concern. |
| Pure performance / cache-padding decisions | Family-A-adjacent (`CachePadded` around `Inner::buffer` was added in `89828aac` as a perf fix) but no protocol-level state machine to verify. |
| Asymmetric `Block::next` Release-store ordering vs `wait_next` Acquire-spin | By-design liveness — eventual visibility under any non-trivial ordering, not a safety concern. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Buffer generation tracking | `buffer_gen`, `slot_value[gen][i]`, `pinned_gen[stealer]` | Catch resize / read-recheck-CAS races | A |
| Memory-ordering label on each atomic | `ord[atomic_op]` ∈ {SC,Rel,Acq,Rlx} | Drive `MCRelaxDowngrade` adversary | B |
| Multi-stealer client harness | `pc[stealer]`, `local_state[stealer]`, `n_stealers` | Drive concurrent steals + clones | C |
| Weak/strong CAS tagging | `weak[cas_site]: BOOLEAN` | Drive `MCSpuriousFail` on weak sites only | D |
| Slot state-machine bits | `slot_state[block][slot] ∈ {NONE, W, WR, WD, WRD}` | Verify walker / destroy invariant | E |
| Steal-batch loop iteration variables | `iter[stealer]`, `f_local[stealer]`, `dest_b_local[stealer]` | Per-iteration interleaving | F |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `LinearizableSteal` | Safety | Every `Steal::Success(v)` value `v` was `push`ed exactly once and is consumed exactly once across all paths (worker pop + all stealers + injector ops). | A, B, C, F |
| `NoStaleGenSteal` | Safety | If a stealer's CAS on `front` succeeds at value `f`, the value committed (`task.assume_init`) equals the slot value that was *logically* at index `f` at the time of the CAS, regardless of buffer generation. | A |
| `NoSkippedPush` | Safety | Every `Worker::push(v)` either ends up in some Steal::Success, some Worker::pop, or is in the deque at quiescence. No drops. | A, F |
| `NoDoubleConsume` | Safety | At most one of {`pop`, `steal`, `steal_batch*`} returns a given pushed value. | A, B, F |
| `EmptyImpliesLinearizable` | Safety | If `is_empty()` returns `true` linearized at point P, no `Steal::Success` linearized after P can return a value pushed before P. | B |
| `BlockNoUseAfterFree` | Safety | No thread reads from a Block slot after the Block's `drop(Box::from_raw)` at deque.rs:1300. | E |
| `BlockNoLeak` | Liveness | Every Block allocated by `Block::new` is eventually freed once head advances past it AND all stealers in flight finish their operations. | E |
| `WorkerExclusive` | Safety | At any state, at most one Worker action is "in flight"; Stealer actions can be N-fold concurrent. (Reflects `Worker: !Sync`.) | C |
| `RetryEventuallyMakesProgress` | Liveness | Spurious-fail loops on `compare_exchange_weak` cannot livelock when there is no true contention. | D |
| `SteadyStateMatchesPush` | Safety | At any state, `back - front` equals the number of pushes minus the number of successful pops/steals. | A, F |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Asymmetric absence of `buffer.load() != buffer` at deque.rs:1083 ⇒ stealer commits stale-generation value if `Worker::resize` is allowed to compact (rebase) indices instead of preserving them. | `NoStaleGenSteal` violated when resize is non-index-preserving. | A |
| MC-2 | Downgrade `Worker::push` back-store from Release-fence-Relaxed to pure Relaxed ⇒ stealer may observe new `back` without observing slot write. | `EmptyImpliesLinearizable` and `NoSkippedPush` violated. | B |
| MC-3 | Downgrade Stealer's conditional SeqCst fence (omit it even when not pinned) ⇒ Worker LIFO last-task CAS races stealer CAS without total order. | `NoDoubleConsume` violated. | B |
| MC-4 | Two stealers race on `front` while Worker resizes ⇒ both CAS-succeed against different generations. | `NoStaleGenSteal` violated. | A, C |
| MC-5 | `compare_exchange_weak` on Injector `head.index` spuriously fails ⇒ stealer returns Retry; verify retry loop converges. | `RetryEventuallyMakesProgress` (liveness check). | D |
| MC-6 | Mid-batch break loop in `steal_batch_with_limit` Lifo: hypothetical reordering of READ-set ascending → descending ⇒ walker sets DESTROY on a non-top slot → block leak. | `BlockNoLeak` violated under reordering. | E |
| MC-7 | `steal_batch_with_limit_and_pop` Lifo: first CAS at deque.rs:1086 races a Worker resize-then-pop sequence in a way the in-loop guard cannot catch. | `NoDoubleConsume` or `NoStaleGenSteal`. | A |
| MC-8 | Mixed source-Lifo / dest-Fifo batch steal: reversal at deque.rs:895-907 against concurrent destination stealers (impossible by design but worth confirming) — verify that the worker-only resize/dest-write window is maintained. | `LinearizableSteal`. | F |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| T-1 | Stress-test `Stealer::clone` while another steal is in flight, with N = 16 cloners. | loom or shuttle with `cfg(loom)` gating. |
| T-2 | Inject `MaybeUninit::uninit()` reads in `Buffer::read` to confirm `MaybeUninit::forget` path is sound under concurrent resize. | Miri with `-Zmiri-preemption-rate=0.5`. |
| T-3 | `Injector::push` with `T = [u8; 32_768]` to reproduce #1146/#1147 stack-overflow / null-alloc paths post-fix. | Existing test at `crossbeam-deque/tests/injector.rs::stack_overflow` (added in PR #1159). |
| T-4 | Worker drop while N stealers in flight. | Helgrind / TSan stress run. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Asymmetric absence of `buffer.load() != buffer` at deque.rs:1083 — even if currently safe, document the resize-preserves-indices invariant or add the check for symmetry. | Add a `// SAFETY:` comment citing the resize invariant; consider adding the check defensively. |
| CR-2 | Walker invariant in `Block::destroy` (Family E) is non-obvious; document it. | Add a doc comment citing "walker descends from count-1 and stops at top READ=0; consumer ranges' top slot is visited last, so early break is safe." |
| CR-3 | `Injector::steal*` in artifact HEAD `03919fed` still uses `compare_exchange_weak` (commit `1015b21d` not yet merged into this branch). Once `1015b21d` lands, MC-5 becomes moot. | Track the upstream merge; re-run model check post-merge. |
| CR-4 | `crossbeam-deque#869` (MacOS M1 Rayon segfault) is still open with no root-cause fix; worked around by reverting `#552`. The maintainer (taiki-e) suspects an underlying deque bug. | Fold into Family A — model the aggressive-epoch-GC interleaving and check whether the buffer-generation race expands to expose this. |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/crossbeam-deque_2/.specula-output/analysis-report.md`
- **Source file**: `/home/ubuntu/Specula/case-studies/crossbeam-deque_2/artifact/crossbeam/crossbeam-deque/src/deque.rs`
- **Reference algorithms**:
  - Chase & Lev. *Dynamic circular work-stealing deque.* SPAA 2005. — https://dl.acm.org/citation.cfm?id=1073974
  - Le, Pop, Cohen, Nardelli. *Correct and efficient work-stealing for weak memory models.* PPoPP 2013. — https://dl.acm.org/citation.cfm?id=2442524
  - Norris & Demsky. *CDSchecker: checking concurrent data structures written with C/C++ atomics.* OOPSLA 2013. — https://dl.acm.org/citation.cfm?id=2509514
- **Key historical commits**:
  - `38c07fcf` / PR #726 — CVE-2021-32810 fix (buffer-resize race)
  - `8d7db8c0` / PR #855 — MaybeUninit conversion (dangling-Box residual)
  - `89828aac` — `dest_buffer` typo + CachePadded buffer field
  - `4d574d40` — wrong steal-direction reversal (FIFO ↔ LIFO)
  - `761d0b67` / PR #1159 — Block::new stack-overflow + null-alloc fix
  - `23b68fb3` / PR #1233 — TSan-aware fence + Relaxed-store
  - `1015b21d` (post-HEAD) — Injector strong-CAS migration
- **Open issue with no root-cause fix**: `crossbeam-rs/crossbeam#869` (MacOS M1 Rayon segfault).
- **Fault-model adversary inventory**: see `concurrent-analysis.md` § 5; this brief invokes families 5.1 (Thread Interleaving — universal), 5.4 (CAS spurious), 5.5 (Memory ordering), 5.6 (ABA / pointer reuse on resize), 5.7 (Caller misuse). 5.2 (Cancellation) and 5.8 (Wakeup) do not apply (no async, no parker).
