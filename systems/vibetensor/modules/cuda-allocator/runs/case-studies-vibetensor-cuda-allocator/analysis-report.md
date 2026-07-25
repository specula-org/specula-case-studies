# VibeTensor CUDA Caching Allocator — Analysis Report

**Target**: `NVlabs/vibetensor` — stream-ordered CUDA caching allocator (native backend + cudaMallocAsync backend)
**Scope**: `include/vbt/cuda/allocator{,_async}.h`, `src/vbt/cuda/allocator{,_async}.cc`, `src/vbt/cuda/event{,_pool}.cc`
**Language**: C++ (CUDA runtime)
**Classification**: **Category B — Concurrent / Lock-Free / Runtime** (shared `mu_` mutex; state-machine with release/reacquire lock windows; off-lock CUDA API calls; stream-ordered reclamation via events)

---

## Coverage Statistics

| Metric | Value |
|---|---|
| Repository commits (full history) | 1 (artifact drop; no archaeology signal) |
| Repository commits touching allocator | 1 |
| GitHub issues total | 0 |
| GitHub PRs total | 2 (both trivial: PEP-8 and DeepWiki badge) |
| Parallel deep-analysis subagents | 5 |
| Core allocator LoC analyzed | 4029 (`allocator.cc`) + 706 (`allocator.h`) + 319+96 (async) + 191+139 (event/event_pool) = **5,480 LoC** |
| Bug families identified | 7 |
| Total findings | 24 |

The repo was released as a single snapshot — no historical bug-fix commits and no GitHub issue backlog exist. Consequently **Phase 2 yielded nothing**, and the analysis is driven entirely by deep code reading (Phase 3).

---

## Phase 1 — Reconnaissance

### 1.1 Module Map

| File | Role | LoC |
|---|---|---|
| `include/vbt/cuda/allocator.h` | Public API, Block/Config/Stats types, size-class policy | 706 |
| `src/vbt/cuda/allocator.cc` | Native caching allocator (main implementation) | 4029 |
| `include/vbt/cuda/allocator_async.h` | Async backend API | 96 |
| `src/vbt/cuda/allocator_async.cc` | cudaMallocAsync-based backend | 319 |
| `include/vbt/cuda/event_pool.h` + `.cc` | Pooled event handles | ~190 |
| `src/vbt/cuda/event.cc` | CUDA event wrappers | 139 |

### 1.2 Core State (native backend)

All protected by a single `std::mutex mu_`:

```
by_ptr_           : unordered_map<void*, Block*>
active_blocks_    : unordered_set<Block*>
per_stream_free_  : unordered_map<StreamId, set<Block*, CmpSizeAddr>>
cross_stream_free_: set<Block*, CmpSizeAddr>
limbo_            : unordered_map<StreamId, deque<LimboEntry{token,event,Block*}>>
deferred_         : deque<DeferredFree{Block*, owner_sid, streams}>
idle_segments_    : vector<Segment>
graph_pools_      : unordered_map<uint64_t, GraphPrivatePool>
```

Per-block fields include `allocated`, `event_count`, `stream_uses`, `owner_stream`, `alloc_stream`, `graph_pool_id`, `is_split_tail`, `segment_head`, `gc_age`, `prev`, `next`, `size`, `requested_size`. Segment chain via `prev`/`next` is orthogonal to free-list indices.

### 1.3 Concurrency Model

- Single global mutex `mu_` per `Allocator` (per-device singleton).
- Multiple release/reacquire windows around blocking CUDA calls (`cudaMalloc`, `cudaFree`, `cudaEventRecord`, `cudaEventQuery`, `cudaDeviceSynchronize`).
- Atomic `routing_active_flag_`, `memory_fraction_`, `free_count_`.
- Thread-local `s_capture_tls` for graph-capture routing.
- `process_events` is invoked from: allocation fast path, free cadence, OOM retry, explicit calls — **no mutex/flag prevents concurrent invocations**.

### 1.4 Atomicity Boundaries

| Step | Lock held? | Comment |
|---|---|---|
| `raw_alloc` free-list take + `on_reuse_from_free_list` | mu_ | Single critical section |
| `raw_alloc` growth: `cudaMalloc` | **no** | Lock released across CUDA call |
| `raw_alloc` growth: `by_ptr_` insert + stats | mu_ | Second critical section |
| `raw_delete`: mark `allocated=false`, clear `stream_uses` | mu_ | First critical section |
| `raw_delete`: `cudaEventRecord` on each stream | **no** | Block has phantom state during this window |
| `raw_delete`: push to `limbo_`, bump `event_count` | mu_ | Second critical section |
| `process_events` deferred flush: snapshot `deferred_` | mu_ | Snapshot into local vector |
| `process_events` deferred flush: `cudaEventRecord` per entry | **no** | Concurrent threads can snapshot same entries |
| `process_events` deferred flush: erase + push to limbo | mu_ | Erase not conditioned on success flag |
| `maybe_run_fraction_gate`: read reserved/limit, run GC | mu_ released across GC/EC | Multiple snapshots, not atomic w.r.t. `cudaMalloc` that follows |

---

## Phase 2 — Bug Archaeology

### 2.1 Git History

`git log` returns a single commit `fe85461 update arXiv paper link`. The repository was published as a flat artifact — no bug-fix commits, no `fix:`/`bug:`/`race:` keywords, no TODO/FIXME/HACK markers in the allocator beyond normal comments.

### 2.2 GitHub Issues

`gh issue list -R NVlabs/vibetensor --state all --limit 100` returns **zero** issues. The two open PRs (#1 DeepWiki badge, #2 PEP-8 Python fixes) do not touch allocator code.

### 2.3 Reference Comparison (PyTorch `CUDACachingAllocator`)

The VibeTensor native allocator is strongly modeled on PyTorch's `CUDACachingAllocator.cpp` (pre-expandable-segments era), with the following differences worth noting in modeling:

- **VibeTensor keeps a block in the segment chain during its limbo/deferred state** (while PyTorch historically uses a "Pending Free" or hazard flag on the block — critically, PyTorch's `coalesce_*` paths check whether a neighbor is actually in a free list, not just whether it *looks* free). See Family 1 below — this omission is the origin of several serious bugs.
- **VibeTensor has an explicit `deferred_` queue for capture-time frees** — PyTorch defers captures via a separate recording mechanism that holds the block out of the segment chain's "free neighbor" predicate.
- **VibeTensor's `process_events` does not serialize against itself** — PyTorch historically guards the event-draining path with a `pe_in_progress` flag or restricts it to the main thread.

---

## Phase 3 — Deep Analysis

Seven bug families emerge from the analysis. Details below. Each finding includes file:line, mechanism, verification status, and TLA+ suitability.

---

### Family 1 — Phantom Free Block (Segment-Chain Eligibility Without Index Membership)

**Mechanism**: A block in the segment chain (`prev`/`next` linkage) whose flags read `allocated=false, event_count=0, stream_uses.empty(), graph_pool_id==target` satisfies the "free neighbor" predicate used by `coalesce_neighbors_unlocked::eligible_neighbor` (`allocator.cc:3767-3789`) and the "idle segment" predicate used by `find_candidate_heads_locked` (`allocator.cc:1832-1837`). Neither predicate verifies that the block is actually indexed in `per_stream_free_` or `cross_stream_free_`. Two runtime paths leave a block in exactly this phantom state:

#### F1.1 — raw_delete off-lock event-record window

`raw_delete` (`allocator.cc:1553-1585` then `1656-1663`) releases `mu_` between the flag-clear step and the limbo-push step. During lines 1586–1655, block `b` has `allocated=false, event_count=0, stream_uses empty`, is still in `by_ptr_` and `active_blocks_`, and is still in its segment chain.

**Bug**: A concurrent `raw_delete(Y)` on a sibling block `Y` that takes the same-stream immediate-reuse path (`allocator.cc:1575-1584`) calls `coalesce_neighbors_unlocked(Y)`, finds `b` as an eligible neighbor via `eligible_neighbor` (line 3770-3773), and deletes `b` at line 3817-3818 or 3859-3860. When the first thread reacquires `mu_` at line 1656, it dereferences freed `b` via `b->event_count += 1`. **Use-after-free.**

Symmetric scenarios: (a) a concurrent `emptyCache`/`process_events`/`run_gc_pass_if_eligible` walking segments reaches `b` via a sibling in `per_stream_free_` and detaches the whole segment including `b`.

**Verification**: re-read confirms lock release at line 1585 and re-acquire at 1657; `eligible_neighbor` checks exactly the phantom flag profile; segment chain membership is the only reachability from a free neighbor. Debug assertions at `allocator.cc:3706-3718` validate the center block's indices are empty but **do not** check neighbor index membership.

#### F1.2 — `deferred_` entries

The deferred path (`allocator.cc:1599-1609`) pushes `DeferredFree{b, owner_sid, streams}` to `deferred_` and returns. Block `b` keeps `allocated=false, event_count=0, stream_uses.empty()` and remains in `by_ptr_`, `active_blocks_`, and the segment chain — permanently in this phantom state until `process_events` drains it.

**Bug**: same as F1.1 but the phantom window is not microseconds but up to the duration of a graph capture. Any sibling-free or GC run during the capture can silently swallow the deferred block. When capture ends, `process_events` tries to flush `deferred_` and dereferences a dangling `df.b`.

**Verification**: `find_candidate_heads_locked` at line 1832 checks `graph_pool_id != 0u || allocated || event_count != 0` — a deferred block (which has `graph_pool_id == 0` for global allocations) passes this gate. The segment-walk at `detach_segment_for_gc_locked:1867-1890` unconditionally erases `by_ptr_`, `active_blocks_`, and `delete`s the block. No lookup of `deferred_` before deleting.

**Severity**: HIGH. Both failures are memory-unsafe UAF.

---

### Family 2 — Non-Idempotent Concurrent `process_events` Deferred Flush

**Mechanism**: `process_events` (`allocator.cc:1692-1807`) snapshots `deferred_` into a local `cands` vector under lock (`1696-1700`), iterates it **off-lock** calling `cudaEventRecord` per stream per entry (`1711-1721`), then re-acquires the lock and performs erase + push-to-limbo (`1727-1737`).

```cpp
for (auto it = deferred_.begin(); it != deferred_.end(); ++it) {
  if (it->b == df.b) { deferred_.erase(it); break; }
}
for (auto& p : pendings) {               // <-- unconditional
  df.b->event_count += 1;
  limbo_[p.sid].push_back(...);
}
stats_.deferred_flush_successes += 1;
```

**Bug**: Two threads T1 and T2 concurrently call `process_events` (which happens on every other allocation and every N frees). Both snapshot the same `df` into their `cands`. Both record events. Both re-acquire the lock. T1 erases `df` from `deferred_` and pushes N limbo entries, bumping `event_count` by N. T2's erase loop finds nothing (silently), but T2 **still pushes N limbo entries and bumps `event_count` by N** — because the push path is not gated by the erase-succeeded flag. Result:

- `limbo_` holds `2N` entries for `df.b`.
- `event_count` is `2N` instead of `N`.
- When all events drain, `event_count → 0` happens correctly at limbo pop `2N`, but each of the `N` "duplicate" events recorded by T2 is its own CUDA event that may fire at a different time. Between the first `N` drains and the last `N` drains, `event_count` transitions `N → 0` at drain N, triggering `process_events` to call `insert_free_block_unlocked(coalesce_neighbors_unlocked(b))` at `allocator.cc:1791-1796`. The block is now in the free list. Then the remaining N pops dereference `b` at `dq.front().b == b` (line 1782), bump `event_count` back above 0 via the `if (b->event_count > 0) --b->event_count` guard (line 1790), and on the final pop the `event_count==0 && !allocated` branch fires **again** — re-coalescing an already-free block (possibly re-merging a sibling that was already in the free list), causing free-list corruption.

**Verification**: confirmed in `process_events` (line 1727-1737). No guard on concurrent `process_events`. The `if (b->event_count > 0)` guard at line 1790 masks underflow from the duplicate entries but does not prevent the second coalesce.

**Severity**: HIGH. Memory corruption and free-list invariant violation.

---

### Family 3 — Lost Stream-Use Fence on `raw_delete` Rollback

**Mechanism**: On event-record failure, `raw_delete` rolls back (`allocator.cc:1626-1653`): sets `b->allocated = true`, restores `stream_uses` from the pre-read snapshot, re-credits stats.

**Bug**: During the off-lock window (lines 1615-1625), a concurrent `record_stream(ptr, S_new)` can execute. It acquires `mu_`, reads `b->allocated` which is `false`, and silently returns (line 1682). The caller believes the record_stream succeeded. On rollback, `b->allocated = true` and `b->stream_uses` is restored **from the pre-read snapshot** — the new stream use is **not** included. Subsequent true free will not fence against `S_new`.

Concrete consequence: a tensor freed-then-retried-on-rollback may be reused by another `raw_alloc` while stream `S_new` still has outstanding work referencing the block. Stream-ordered free invariant violated.

**Verification**: `record_stream` line 1682 — early return on `!b->allocated`. No record of "record_stream was attempted while freeing" is kept.

**Severity**: MEDIUM-HIGH. Requires the event-record failure path (rare) plus concurrent record_stream during the narrow window, but produces silent cross-stream reuse violations.

---

### Family 4 — Oversize Island Isolation (Permanent Non-Reuse)

**Mechanism**: Blocks satisfying `size >= M_cfg` (`is_oversize_size` at `allocator.cc:142-146`) are "islands":
- `should_split_unlocked` refuses to split them (`3271-3273`).
- `evaluate_candidate` refuses non-oversize-request tolerance-fills against oversize blocks (`3322-3340`).
- `coalesce_neighbors_unlocked` early-returns after left-merge if the merged block became oversize (`3824-3840`) — skipping right merge.

**Bug**: A coalesce that produces an oversize block creates a permanently unusable free fragment for non-oversize workloads. Example: `max_split_size_bytes=16 MiB`, left=12 MiB free, center=4 MiB freeing. Left-merge creates 16 MiB (`is_oversize` uses `>=`, so exactly 16 MiB is oversize). Right-merge is skipped. The 16 MiB block can only serve a ≥16 MiB request. In a workload with no oversize requests, the block is stranded until segment teardown.

Combined with the tolerance-fill rejection (`3338`), even a 15.9 MiB request against a 16 MiB oversize block is rejected (despite `rem=0.1 MiB ≪ T`).

**Verification**: all code paths re-read and confirmed. `is_oversize_size` uses `>=` at line 143.

**Severity**: MEDIUM (not memory-unsafe; causes fragmentation / OOM in pathological workloads).

---

### Family 5 — GC Ladder Non-Monotonicity Under Reshape

**Mechanism**: `gc_age` is tracked per segment head. Incremented in `run_gc_pass_if_eligible` (`allocator.cc:1986`) only for heads returned by `find_candidate_heads_locked` (which requires the whole segment to be idle). Reset on reuse (`on_reuse_from_free_list:3534`), on split (`split_block_unlocked:3688`), on coalesce (`coalesce_neighbors_unlocked:3878`), and in `gc_pool_locked:810`.

**Bug**: `gc_age` is stored on the current segment head. When `coalesce_neighbors_unlocked` merges left, `head = left` (the former neighbor), and `head->gc_age = 0` is set at line 3878. But if right-merge occurs (line 3842) and modifies the segment, and the "old head" block is deleted at line 3859, a subsequent split that re-promotes a different block to head gets whatever `gc_age` that block had. Worse: `find_candidate_heads_locked` excludes non-fully-idle segments (line 1832-1836), so a segment that becomes fully idle *after* reshaping carries a stale `gc_age` from its pre-reshape identity.

The `avg_age` threshold in `run_gc_pass_if_eligible` (1981-2014) filters candidates below the average. Over sustained cap pressure, segments with stale high `gc_age` are preferentially reclaimed; segments with stale low `gc_age` are preferentially kept — unrelated to actual idle time.

Additionally: `run_gc_pass_if_eligible` only increments `gc_passes` if `freed_bytes > 0` (`2051-2053, 2061`), so operator-visible counters undercount when GC ran but skipped all candidates.

**Severity**: MEDIUM. Affects GC progress/liveness, not memory safety directly.

---

### Family 6 — Graph Pool Lifecycle Races

**Mechanism**: Graph pools (`graph_pools_`) are managed via refcount + state flags (`active_capture_count`, `active_replay_count`, `prewarm_in_progress`). Multiple entry points mutate these; `AllocateToPoolGuard` is an RAII wrapper.

#### F6.1 — AllocateToPoolGuard stale-destruction clobbers a new capture

If the user calls the flat API `end_allocate_to_pool(id)` (public, `allocator.cc:648-650`) while still holding an `AllocateToPoolGuard` returned by `begin_allocate_to_pool`, then later begins a **new** capture on the same pool, then the first guard's destructor fires `cancel_allocate_to_pool_` (`allocator.cc:1131-1135`) which clears `s_capture_tls` and `routing_active_flag_` — **disarming the current live capture**. Subsequent `raw_alloc` during the new capture throws `kErrAllocatorCaptureDenied`.

#### F6.2 — `refcnt` unguarded uint32_t

`retain_pool_` (`allocator.cc:826-840`) increments `refcnt` via `prev + 1` without overflow check. At 2^32 retains, wraps to 0, and the next `release_pool_` triggers `gc_pool_locked` while callers still hold outstanding references. Theoretical but present.

#### F6.3 — Asymmetric error semantics

`retain_pool_` throws on unknown id (`832`); `release_pool_` silently returns (`847-850`). Double-release or release-after-gc is undetectable — refcount drift goes unobserved.

#### F6.4 — Boolean-counters mis-named

`active_capture_count` and `active_replay_count` are **assigned `= 1u`** in begin (lines 880, 957), not incremented. But end paths use `-= 1` (line 974). Semantics are flag, name implies count. If the precondition check (lines 872, 949) is ever bypassed (e.g., by a bug in caller), counters desync.

**Severity**: MEDIUM. F6.1 is an API contract bug with concrete reproduction.

---

### Family 7 — Fraction-Cap TOCTOU and Counter Observability

**Mechanism**: `maybe_run_fraction_gate` (`allocator.cc:338-453`) is called under a **released** lock from `raw_alloc` (line 1230, 1417). It takes and drops `mu_` multiple times internally to sample `reserved_bytes_all_current` before/after GC/emptyCache.

#### F7.1 — Gate vs. growth TOCTOU

Two threads can both clear the gate (`maybe_run_fraction_gate` returns without throwing) and independently call `cudaMalloc_with_hook`. Both then acquire `mu_` sequentially at lines 1322 / 1504 and grow `reserved_bytes_all_current` past the cap. No "admission slot" lock. Counter `fraction_cap_breaches` counts only breach observations; the actual post-growth overshoot is silent.

#### F7.2 — Counter non-monotonicity on fraction relaxation

If another thread calls `setMemoryFraction(1.0)` mid-gate, `limit_after_gc == MAX` triggers early return at line 408/430. The earlier `fraction_cap_breaches` increment at line 370 is paired with no `fraction_cap_misfires` increment. Operator observability: breach without misfire can now mean either "GC resolved" or "fraction relaxed" — ambiguous.

#### F7.3 — `emptyCache` bytes invisible to `gc_reclaimed_bytes`

When the gate's fallback `emptyCache` path reclaims (line 423), `emptyCache` (line 2123 comment) explicitly does not touch `gc_passes` / `gc_reclaimed_bytes`. Combined with F5's filter, counters undercount reclaimed bytes under sustained cap pressure.

**Severity**: MEDIUM. F7.1 is a real safety bug if fraction cap is load-bearing.

---

### Additional Standalone Findings

#### F8 — Async backend `used_bytes_` leak on deferred free (allocator_async.cc:186-196)

Capture-time frees push to `deferred_` without decrementing `used_bytes_`. If the entry never reaches non-capturing state, `used_bytes_` stays inflated, eventually causing spurious OOM at `used_bytes_ + size > limit_bytes_` (line 111). No periodic reconciliation.

#### F9 — Async backend holds mutex across `cudaDeviceSynchronize` (allocator_async.cc:207-214)

`emptyCache` synchronizes the whole device under `mu_`, blocking all concurrent `raw_alloc`/`raw_delete`. Potential deadlock if a device-resident kernel depends on another thread that needs the mutex.

#### F10 — Prewarm bypasses fraction cap and leaks Blocks on post-alloc exception (allocator.cc:1085-1124)

`prewarm_graph_pool_for_stream_` calls `cudaMalloc_with_hook` without consulting `maybe_run_fraction_gate`. If the subsequent Block-wrap loop throws (`new Block()`, map insert), already-malloc'd pointers are leaked (try/catch only covers the malloc loop).

#### F11 — Split-enabled vs no-split pool reuse asymmetry (allocator.cc:3373-3381 vs 3409-3417)

With splitting enabled, `try_take_free_block_unlocked` requires exact `graph_pool_id` match. Without splitting, pool allocations can claim global (`graph_pool_id==0`) free blocks. Enabling the splitting knob silently shrinks pool-alloc reuse inventory. Undocumented, not flagged by tests.

#### F12 — Split tails stranded on quiescent cross-stream owner (allocator.cc:3435-3502, 3644-3677)

When `try_take_from_cross_stream_unlocked` splits, the tail's `owner_stream` keeps the original block's owner — which may be a dead/quiescent stream. The tail lands in `per_stream_free_[dead_owner]` and is reachable only via cross-stream search (not per-stream fast path). In workloads where cross-stream fallback is disabled, tail is stranded until GC.

#### F13 — `coalesce_neighbors_unlocked` under-counts `inactive_split_blocks_all` on mid-segment merges (allocator.cc:3756-3764, 3878)

Every merged part's `is_split_tail` is consumed; the merged result never re-sets `is_split_tail=true` even when the result is mid-segment. If the policy is "track all mid-segment fragments," the gauge drifts low after each coalesce that produced a non-head mid-segment block.

#### F14 — `owns`/`getBaseAllocation` answer affirmatively for limbo/deferred blocks (allocator.cc:2199-2234)

`by_ptr_` retains the block while in limbo/deferred. Callers using `owns` to check "still allocated" get incorrect answers. Semantic bug rather than memory-unsafe.

#### F15 — `event_count > 0` guard on pop masks bug-2 underflow (allocator.cc:1790)

`if (b->event_count > 0) --b->event_count;` silently absorbs the symptom of F2's double-flush.

---

## Verification Discipline

| Finding | Re-read? | Compensating mechanism? | Design intent? | Production impact? |
|---|---|---|---|---|
| F1.1 raw_delete window | Yes (1530-1671, 3693-3789) | No | No — guard missing | Memory corruption under concurrency |
| F1.2 deferred swallow | Yes (1599-1609, 1811-1894) | No | No | Memory corruption at capture end |
| F2 concurrent flush | Yes (1692-1738) | Partial (F15 masks symptom) | No — no process_events lock | Free-list corruption |
| F3 rollback race | Yes (1626-1686) | No | No | Silent cross-stream UAF |
| F4 oversize island | Yes (3271-3340, 3824-3840) | No | Partial (policy) | Memory waste/OOM |
| F5 gc_age drift | Yes (1986, 3688, 3878) | avg_age smooths over time | Partial | GC liveness |
| F6.1 guard clobber | Yes (1128-1165, 891-922) | No | No | Capture fails mid-graph |
| F6.2 refcnt overflow | Yes (826-840) | No | N/A (theoretical) | Pool UAF at 2^32 |
| F6.3 asymmetric errors | Yes (826-859) | No | Partial | Undetectable drift |
| F6.4 bool-counters | Yes (880, 957, 974) | Precondition check | Partial | Desync if precondition bypassed |
| F7.1 cap TOCTOU | Yes (338-453, 1230-1328) | No | No | Cap breach without signal |
| F7.2 relaxation confusion | Yes (408, 430) | No | No | Observability |
| F7.3 emptyCache invisible | Yes (2123, 1897-2081) | No | Partial | Observability |
| F8 async used_bytes | Yes (allocator_async.cc:95-196) | No | No | Spurious OOM over time |
| F9 sync under lock | Yes (207-214) | No | No | Deadlock under kernel dep |
| F10 prewarm leak | Yes (1085-1124) | No | No | Leak on rare throw |
| F11 pool reuse asymmetry | Yes (3373-3417) | No | Undocumented | Reduced reuse |
| F12 stranded tails | Yes (3435-3677) | No | No | Memory waste |
| F13 gauge under-count | Yes (3756-3878) | No | Ambiguous policy | Observability |
| F14 owns semantics | Yes (2199-2234) | No | Intentional? | API contract |
| F15 event_count guard | Yes (1790) | Masks F2 | Defensive coding | Hides bugs |

---

## Reference Comparison Notes

Compared to PyTorch's historical `CUDACachingAllocator.cpp`:

1. **"Free neighbor" predicate** — PyTorch checks both index membership and block flags; VibeTensor checks only flags. Source of Family 1.
2. **`process_events` re-entrancy** — PyTorch's analogous `process_events` is gated by the allocator mutex and restricted in scope; VibeTensor's snapshot-then-off-lock model is novel and permits F2.
3. **`deferred_` queue** — PyTorch historically uses a Block flag (`pending_free`) rather than an external queue, so the block is never indistinguishable from a free-list block during capture.
4. **Graph pool refcount** — PyTorch uses `std::shared_ptr`-like semantics; VibeTensor's manual refcount + flat-API + guard-API combination allows F6.1.

---

## Summary for Modeling

**Top model-checkable bug families** (worth TLA+ investment):

1. **Family 1 — Phantom Free Block**: two-actor interleaving of raw_delete and a concurrent coalesce/GC path. Safety invariant: "no block referenced by `deferred_` or by in-flight raw_delete is deleted." Small finite state (3-4 blocks, 2 threads).
2. **Family 2 — Non-Idempotent process_events**: two-actor snapshot-then-publish without dedupe. Safety invariant: "for each DeferredFree `df`, exactly one `limbo_` entry per stream in `df.streams` is created." Very compact model.
3. **Family 3 — raw_delete Rollback**: three-actor race between raw_delete success/rollback and concurrent record_stream. Liveness invariant: "stream_uses contains every record_stream call observed during the free window."
4. **Family 6.1 — Guard stale destruction**: state-machine with TLS × global flag × pool state. Safety invariant: "routing_active_flag_ reflects the currently-live capture pool."
5. **Family 7.1 — Fraction cap TOCTOU**: two-actor admission race. Safety invariant: "`reserved_bytes_all_current <= limit` OR `fraction_cap_breaches` was incremented."

**Best deferred to test/code-review**: F4 (oversize isolation — policy question), F11 (documentation), F14 (API semantics), F10 (exception-safety of prewarm), F13 (gauge semantics).
