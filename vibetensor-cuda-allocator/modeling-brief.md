# Modeling Brief: VibeTensor CUDA Caching Allocator

## 1. System Overview

- **Name**: VibeTensor `vbt::cuda::Allocator` (native caching allocator) + `vbt::cuda::AsyncBackend` (cudaMallocAsync-based).
- **Language**: C++17 with CUDA Runtime API.
- **Scale**: ~5.5k LoC for allocator core (`allocator.cc` 4029; `allocator.h` 706; `allocator_async.{cc,h}` 415; `event{,_pool}.{cc,h}` ~330).
- **System category**: **Category B — Concurrent / Lock-Free / Runtime**. Justification: single `std::mutex mu_` per device with multiple release/reacquire windows around off-lock CUDA API calls (`cudaMalloc`, `cudaEventRecord/Query`, `cudaDeviceSynchronize`); stream-ordered memory reclamation via event counters; per-thread TLS (`s_capture_tls`) interacting with a process-wide atomic flag (`routing_active_flag_`); `process_events` invoked from multiple paths with no self-serialization.
- **Protocol/algorithm**: PyTorch-style caching allocator (size-classed free lists, per-stream + cross-stream pools, block splitting/coalescing, fraction-cap GC ladder, graph-private pools) with an additional cudaMallocAsync backend.
- **Deviations from reference**:
  - Blocks in `deferred_` and in-flight `raw_delete` remain in the segment chain with phantom flag state, while reference implementations (PyTorch) use a `pending_free` flag on the block to make the block structurally distinguishable from a free neighbor.
  - `process_events` snapshots `deferred_` and records events **off-lock** without serializing against concurrent invocations — PyTorch's analog is serialized by the allocator mutex.
  - Graph-pool lifecycle exposes a flat API (`begin/end/cancel`) in addition to the RAII `AllocateToPoolGuard`, permitting interleaved mutation of TLS and refcounts.
- **Concurrency model**: one global mutex per Allocator instance; atomic flags for routing and memory fraction; thread-local state for graph-capture routing; multiple threads can call every public method concurrently.

---

## 2. Bug Families

### Family 1: Phantom Free Block (Segment-Chain Eligibility Without Index Membership)

**Mechanism**: A block with `allocated=false, event_count=0, stream_uses.empty(), graph_pool_id==target` that is still reachable via the segment `prev`/`next` chain satisfies the "free neighbor" predicate in `coalesce_neighbors_unlocked::eligible_neighbor` and the "idle segment" predicate in `find_candidate_heads_locked` — even though the block is **not** in `per_stream_free_` or `cross_stream_free_`. Two runtime conditions produce this phantom state: the in-flight `raw_delete` event-record window and entries of `deferred_`.

**Evidence**:
- Code analysis: `allocator.cc:1553-1585` (raw_delete first critical section sets `allocated=false`, clears `stream_uses`) and `allocator.cc:1656-1663` (re-acquire to push limbo) — block is phantom between them.
- Code analysis: `allocator.cc:1599-1609` (deferred push keeps block in `by_ptr_`/`active_blocks_`/segment chain with phantom flags).
- Code analysis: `allocator.cc:3767-3789` `eligible_neighbor` — checks only flag profile, not index membership.
- Code analysis: `allocator.cc:1832-1837` `find_candidate_heads_locked` chain walk — same omission.
- Code analysis: `allocator.cc:3817-3818, 3859-3860` `coalesce_neighbors_unlocked` unconditionally `delete`s swallowed neighbors.
- Code analysis: `allocator.cc:1867-1890` `detach_segment_for_gc_locked` unconditionally `delete`s every block on the detached chain.

**Affected code paths**: `raw_delete`, `process_events` (deferred and limbo reclaim), `coalesce_neighbors_unlocked`, `find_candidate_heads_locked`, `detach_segment_for_gc_locked`, `emptyCache`, `run_gc_pass_if_eligible`, `debug_gc_pool_now_for_testing`.

**Suggested modeling approach**:
- **Variables**:
  - `Blocks : SUBSET BlockId` — all live blocks
  - `blockFlags : [BlockId → {allocated, eventCount, streamUses, graphPool}]`
  - `segChain : sequence of BlockId per Segment`
  - `freeIdx : SUBSET BlockId` — members of per-stream OR cross-stream free sets
  - `deferredQ : sequence of BlockId`
  - `limboQ : [StreamId → sequence of (eventToken, BlockId)]`
  - Per-thread PC for `rawDelete` (states: pre, marked, recording, pushed, rolledback) and `processEvents` (states: pre, snapshotted, recorded, published).
- **Actions**:
  - `RawDeleteMark(b)`, `RawDeleteRecord(b)`, `RawDeletePush(b)` — split into 3 atomic steps to expose the window.
  - `DeferredPush(b)` — explicit state.
  - `CoalesceOn(y)` — chooses a free neighbor eligible per the flag predicate.
  - `GCDetach(head)` — walks segment, deletes everything with flag-predicate true.
- **Granularity**: `raw_delete` must be split into 3 atomic steps (locked-mark, off-lock-record, locked-publish) to model the window. `process_events` deferred flush must be split into 3 atomic steps (snapshot, off-lock-record, locked-publish). `coalesce_neighbors_unlocked` is one atomic step (all under `mu_`).
- **Invariant**: `∀ b : b ∈ deferredQ ∪ inFlightDelete ⇒ b ∈ Blocks` (no deleted block referenced).

**Priority**: **HIGH**
**Rationale**: Produces concrete UAF via two-thread interleaving; covers at least 3 flavors of the same mechanism (F1.1 window, F1.2 deferred, F1.1+GC); small, tractable state space.

---

### Family 2: Non-Idempotent Concurrent `process_events` Deferred Flush

**Mechanism**: `process_events` snapshots `deferred_` into a local `cands` under lock, records CUDA events off-lock for each entry, then re-acquires lock and performs `erase(df) + push(limbo) + event_count += N` with no guard against concurrent invocation. The `erase` is linear-search-by-pointer; if the entry was already removed by a peer, the push still fires, double-incrementing `event_count` and producing duplicate limbo entries.

**Evidence**:
- Code analysis: `allocator.cc:1692-1807` `process_events` — no serialization.
- Code analysis: `allocator.cc:1727-1737` publish is unconditional on erase outcome.
- Code analysis: `allocator.cc:1790` `if (b->event_count > 0) --b->event_count;` — masks underflow symptom.
- Code analysis: `allocator.cc:1791-1796` — re-coalesce on second `event_count==0` transition corrupts free indices.
- Invocation sites: `raw_alloc` (nostream line 1196, stream 1385), `raw_delete` cadence (1589, 1606, 1651, 1666), OOM retry (1242, 1257, 1429, 1441), user-visible `process_events()` public.

**Affected code paths**: `process_events`, `insert_free_block_unlocked`, `coalesce_neighbors_unlocked`.

**Suggested modeling approach**:
- **Variables**: `deferredQ`, `limboQ[sid]`, `pendingFlush : SUBSET Thread` (threads that have snapshotted but not published), `snapshot[thread] : seq<BlockId>`.
- **Actions**: `Snapshot(t)`, `RecordOffLock(t)` (no-op state), `Publish(t)` — only `Publish` may find the entry already erased.
- **Granularity**: three atomic steps (snapshot-under-lock, off-lock-record, publish-under-lock).
- **Invariant**: `Cardinality({entry ∈ limboQ[sid] : entry.block = b and entry arose from DeferredFree df}) = 1 per (sid, df)`.

**Priority**: **HIGH**
**Rationale**: Memory corruption with clear invariant; 2-thread small state space.

---

### Family 3: Lost Stream-Use Fence on raw_delete Rollback

**Mechanism**: `raw_delete` on event-record failure rolls back: re-sets `allocated=true`, restores `stream_uses` from the pre-read snapshot. Any `record_stream(ptr, S)` call that arrived during the off-lock window and early-returned (because `allocated==false`) is silently dropped from the final `stream_uses`. Subsequent successful free won't fence stream S.

**Evidence**:
- Code analysis: `allocator.cc:1626-1653` — rollback restores from snapshot.
- Code analysis: `allocator.cc:1682` `record_stream` early-returns on `!b->allocated`.
- Code analysis: `allocator.cc:1563-1566` — snapshot built from `b->stream_uses` at moment of flag clear.

**Affected code paths**: `raw_delete` rollback, `record_stream`.

**Suggested modeling approach**:
- **Variables**: `b.streamUses : SUBSET StreamId`, `b.pendingFreeSnapshot : SUBSET StreamId`, per-thread PC for raw_delete (success/rollback).
- **Actions**: `RecordStream(b, s)` (guards on `b.allocated`), `RawDeleteMark`, `RawDeleteRecordFail`, `RawDeleteRollback` (restores from snapshot).
- **Granularity**: expose the off-lock window as a distinct state.
- **Invariant**: If `raw_delete` ever ultimately succeeds with pendings including streams recorded during its window, those streams must be in `limbo_`. (I.e., `record_stream` calls observed during a window that later rolled back must still be fenced on the NEXT successful free.)

**Priority**: **MEDIUM-HIGH**
**Rationale**: Cross-stream UAF in user memory, not allocator memory — subtle, easy to miss in testing.

---

### Family 4: Graph-Pool Lifecycle — Guard Stale Destruction and Boolean Counters

**Mechanism**: `AllocateToPoolGuard`'s destructor unconditionally calls `cancel_allocate_to_pool_`, which clears `s_capture_tls` and `routing_active_flag_`. If the user mixes the flat API (`end_allocate_to_pool(id)`) with the RAII guard, a stale guard can disarm a newly-begun capture. Compounded by `active_capture_count` / `active_replay_count` being semantically boolean but typed as counters, with asymmetric inc (`= 1u`) vs dec (`-= 1`).

**Evidence**:
- Code analysis: `allocator.cc:1128-1135` guard ctor/dtor; `1131-1135` dtor always cancels.
- Code analysis: `allocator.cc:891-922` `end_allocate_to_pool_` zeros the flag — then a subsequent flat-API `begin_allocate_to_pool` re-arms it — then guard dtor clears it.
- Code analysis: `allocator.cc:880` `gp.active_capture_count = 1u;` (not `+= 1`).
- Code analysis: `allocator.cc:957, 974` — replay begin assigns 1, end decrements.

**Affected code paths**: `begin_allocate_to_pool`, `end_allocate_to_pool`, `cancel_allocate_to_pool`, `mark_pool_replay_begin/end`, `AllocateToPoolGuard`.

**Suggested modeling approach**:
- **Variables**: `poolState[id] : {Idle, Capturing, Replaying, Prewarming}`, `poolRefcnt[id]`, `guardOwners : SUBSET (Thread × PoolId)`, `tls[t] : PoolId`, `routingFlag : Bool`.
- **Actions**: `BeginCapture(t, id)`, `EndCaptureFlat(t, id)`, `GuardDestruct(t, id)`, `BeginCapture2(t, id)` (re-begin after flat end).
- **Invariant**: `routingFlag = True ⇔ ∃ t : tls[t].active ∧ tls[t].pool = current-capture-pool`.

**Priority**: **MEDIUM**
**Rationale**: Concrete reproduction path; affects graph capture correctness.

---

### Family 5: Fraction-Cap TOCTOU (Gate vs. cudaMalloc)

**Mechanism**: `maybe_run_fraction_gate` samples `reserved_bytes_all_current` vs. `current_limit_bytes` with multiple lock release/reacquire cycles; on return, the caller drops the lock, calls `cudaMalloc` off-lock, then re-acquires to bump `reserved_bytes_all_current`. Two threads can independently pass the gate and both bump. No counter reflects post-growth overshoot.

**Evidence**:
- Code analysis: `allocator.cc:338-453` gate implementation — multiple lock scopes.
- Code analysis: `allocator.cc:1230-1328, 1417-1511` — gate-call then cudaMalloc then lock-bump pattern.
- Code analysis: `allocator.cc:370, 441-446` — breach vs misfire counters with ambiguous semantics.

**Affected code paths**: `maybe_run_fraction_gate`, `raw_alloc` (both variants), `setMemoryFraction`.

**Suggested modeling approach**:
- **Variables**: `reservedBytes`, `limit : ℕ ∪ {∞}`, per-thread PC (pre-gate, past-gate, bumped).
- **Actions**: `PassGate(t)` samples `reservedBytes` and `limit`; `CudaMalloc(t, size)` adds to pendings; `BumpReserved(t)` commits.
- **Invariant**: `reservedBytes ≤ limit ∨ fraction_cap_breaches > 0 OR fraction_cap_misfires > 0`.

**Priority**: **MEDIUM**
**Rationale**: Depends on whether fraction cap is load-bearing (it is for multi-tenant GPU sharing). Classic two-thread admission race.

---

### Family 6: GC Ladder Non-Monotonicity Under Reshape

**Mechanism**: `gc_age` is tracked per current segment head. When coalesce changes which block is the head, or when split/merge reshapes the chain, `gc_age` mappings are set/reset at various points. A segment that reshapes between GC passes carries a stale age (inherited from the new head block's prior life).

**Evidence**:
- Code analysis: `allocator.cc:1986` `++h->gc_age;` only for filtered candidates.
- Code analysis: `allocator.cc:3688, 3878` — reset sites.
- Code analysis: `allocator.cc:1981-2014` `avg_age` threshold filters below-average candidates.
- Code analysis: `allocator.cc:2051-2053, 2061` — gc_passes only incremented on success.

**Affected code paths**: `run_gc_pass_if_eligible`, `find_candidate_heads_locked`, `split_block_unlocked`, `coalesce_neighbors_unlocked`, `on_reuse_from_free_list`, `gc_pool_locked`.

**Suggested modeling approach**:
- **Variables**: `segAge : SegmentId → Nat`, `segIdentity : SegmentId → sequence of BlockId`, `headBlock : SegmentId → BlockId`.
- **Actions**: `GCPass` increments age per idle segment; `Split`, `Merge` reshape segment, apply age reset rules.
- **Invariant**: `∀ s : segAge[s] advances monotonically between full-idle periods; never decreases except on reshape-reset`.

**Priority**: **MEDIUM-LOW**
**Rationale**: Liveness property, no memory safety.

---

### Family 7: Async Backend `used_bytes_` Leak on Deferred Free

**Mechanism**: `AsyncBackend::raw_delete` on a capturing-stream pointer pushes to `deferred_` without decrementing `used_bytes_`. If the pointer's owner stream stays capturing indefinitely (or is recorded onto a newly-capturing stream before the drain runs), `used_bytes_` is not reconciled. Cap check `used_bytes_ + size > limit_bytes_` eventually rejects valid allocations.

**Evidence**:
- Code analysis: `allocator_async.cc:186-196` — deferred push; no `used_bytes_ -= u.size`.
- Code analysis: `allocator_async.cc:95-108` — drain-on-alloc path.
- Code analysis: `allocator_async.cc:111` — cap check.

**Affected code paths**: Async backend `raw_delete`, `mallocAsync_`.

**Suggested modeling approach**: Very small model; deferred bag + used_bytes counter. Invariant: `used_bytes = Σ {size : ptr in ptrs_}`.

**Priority**: **LOW-MEDIUM** (only if async backend is in scope; the task directive targets native backend primarily).
**Rationale**: Simple accounting bug; not memory-unsafe.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Split `raw_delete` into three atomic actions** (locked-mark, off-lock-record, locked-publish) with a rollback variant. **Why**: Family 1.1 and Family 3 both hinge on the off-lock window. **How**: per-thread program counter `rawDeletePc[t] ∈ {Idle, Marked, Recorded, Published, RolledBack}`.

- **Model `deferred_` as a distinct state for a block** (phantom + queued), not as "temporarily absent." **Why**: Family 1.2 requires the block to be simultaneously in `by_ptr_` and `deferredQ`, with coalesce eligibility. **How**: add `deferred : SUBSET BlockId` and make eligibility predicates match actual code (flag-only, not index-membership).

- **Model `process_events` deferred flush as three atomic actions per thread**: `PeSnapshot`, `PeOffLockRecord`, `PePublish`. **Why**: Family 2 needs concurrent snapshots to diverge. **How**: per-thread `peCands[t] : seq<DeferredFree>`; `PePublish` checks whether `df ∈ deferredQ` but **publishes to limbo unconditionally** to mirror the bug.

- **Model segment chain explicitly** (linked list via prev/next). **Why**: Families 1 and 6 operate on segment structure, not on set indices. **How**: `segChain[s] : seq<BlockId>`; `Split` and `Coalesce` are the only reshape actions.

- **Model graph-pool state as (refcnt, capture_flag, replay_flag, prewarm_flag, TLS, routingFlag)**. **Why**: Family 4 requires tracking the handshake. **How**: actions `BeginCapture`, `EndCaptureFlat` (flat API), `EndCaptureGuard` (RAII dtor), `BeginCapture2` (re-begin).

- **Model fraction cap as a global counter vs admission gate, separated from `cudaMalloc` action**. **Why**: Family 5 requires splitting gate-pass from reserved-increment. **How**: `PassGate` and `BumpReserved` are distinct actions; `ConcurrentTwoThreadBumps` is the reachable violation.

### 3.2 Do Not Model (with rationale)

- **`cudaMalloc`/`cudaFree` error injection beyond "succeeds or fails"**: the CUDA driver is external. Model as non-deterministic success/failure only. Do not model specific error codes.

- **`memcpyAsync` / `enablePeerAccess`**: orthogonal to allocator safety; out of scope.

- **Size-class computation (`round_size`, `classify`)**: purely computational, no state; unit tests cover this.

- **Tolerance-fill arithmetic**: `evaluate_candidate`'s `rem/tol_cap` comparisons are local; unit tests are the right tool.

- **`is_oversize` permanent unreachability** (Family 4 body F4 in analysis-report): modeling it adds many states for a **design-policy** question. Better surfaced as a code-review question ("should coalesce allow oversize results?"). Keep out of spec.

- **Counter undercount / observability** (F5 `gc_passes`, F7.2 relaxation confusion, F7.3 emptyCache invisibility, F14 `owns` semantics): these are observability bugs, not safety violations. Test-verifiable.

- **`cudaStream_t`/event pool internals**: model events as opaque tokens; do not model `cudaEventQuery` timing beyond "ready or not ready."

- **Async backend state machine**: the task directive targets the native backend; Family 7 is flagged but not modeled. If spec time permits later, it's a much smaller model than Family 1.

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Three-step raw_delete | `rawDeletePc[t]`, `deleteSnapshot[t]`, `rollbackFired[t]` | Expose off-lock window and rollback | 1, 3 |
| Segment chain | `segChain[s] : Seq<BlockId>`, `segHead[s]`, `prev/next` | Make coalesce neighbor eligibility reflect actual code | 1, 4, 6 |
| Deferred queue | `deferredQ : Seq<DeferredFree>`, `phantomBlocks : SUBSET BlockId` | Family 1.2 mechanism | 1 |
| Process-events snapshot | `peCands[t] : Seq<DeferredFree>`, `peState[t] ∈ {Pre, Snap, Rec, Pub}` | Family 2 mechanism | 2 |
| Record-stream race | `b.streamUses`, `b.pendingSnapshot`, `recordDuringWindow[t,s]` | Family 3 rollback | 3 |
| Graph-pool state | `pool.refcnt`, `pool.capture`, `pool.replay`, `tls[t]`, `routingFlag` | Family 4 handshake | 4 |
| Fraction cap gate | `reservedBytes`, `limit`, `pendingMalloc[t]` | Family 5 admission race | 5 |
| GC age ladder | `segAge[s]`, `avgAgeThreshold` | Family 6 monotonicity | 6 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `NoDanglingDeferred` | Safety | ∀ t,df : `df ∈ deferredQ_t` ⇒ `df.b ∈ Blocks` (block not deleted) | Family 1.2 |
| `NoDanglingLimbo` | Safety | ∀ sid,e : `e ∈ limboQ[sid]` ⇒ `e.b ∈ Blocks` | Family 1, 2 |
| `NoDanglingInFlight` | Safety | ∀ t in rawDelete off-lock: `b_t ∈ Blocks` | Family 1.1 |
| `UniqueDeferredFlush` | Safety | For each `df` ever in `deferredQ`, the total count of limbo entries attributable to `df` across all streams = `|df.streams|` (no duplicates) | Family 2 |
| `EventCountConsistent` | Safety | `b.event_count = Σ_sid |{e ∈ limboQ[sid] : e.b = b}|` | Family 2 |
| `StreamUsesPersist` | Safety | Any `record_stream(b, s)` call observed while `raw_delete` is marked-but-not-published, if `raw_delete` then rolls back, must leave `s ∈ b.stream_uses` | Family 3 |
| `RoutingFlagMatchesTLS` | Safety | `routingFlag = True ⇔ ∃ t : tls[t].active ∧ tls[t].pool ∈ CurrentCapturingPools` | Family 4 |
| `PoolRefcntWellFounded` | Safety | `pool.refcnt > 0 ⇒ pool ∈ graph_pools_` (no GC while outstanding) | Family 4 + F6.2 |
| `ReservedLimitRespected` | Safety | `reservedBytes ≤ limit ∨ fraction_cap_breaches > 0` | Family 5 |
| `GCAgeMonotone` | Liveness | ∀ s : segAge[s] is non-decreasing across GC passes between reshape events | Family 6 |
| `AllocEventuallySucceeds` | Liveness | Under a non-adversarial workload with eventually-idle streams, `raw_alloc` eventually returns non-null | Family 1, 2, 6, 7 |
| `NoDoubleFree` | Safety | Each `raw_delete(ptr)` with `b->allocated = true` at entry is matched by exactly one `b->allocated := false` transition | baseline |
| `StreamOrderedReuse` | Safety | ∀ reuse: block `b` handed to stream `S_alloc` at time `t` ⇒ all events on `{b.alloc_stream, b.owner_stream, stream_uses at free}` recorded at time `t_free < t` are complete | baseline PyTorch invariant |
| `MassConservation` | Safety | Sum of `Block.size` across all blocks in segment = segment.size; total active + reserved bytes match sums of corresponding blocks | baseline |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| M1 | Sibling-coalesce during raw_delete off-lock window deletes the in-flight block | `NoDanglingInFlight` | F1.1 |
| M2 | emptyCache/GC walking segment containing deferred block detaches it | `NoDanglingDeferred` | F1.2 |
| M3 | Concurrent process_events deferred flush produces duplicate limbo entries | `UniqueDeferredFlush`, `EventCountConsistent` | F2 |
| M4 | process_events repeats coalesce after event_count re-hits 0 due to duplicates | `NoDanglingLimbo` | F2 |
| M5 | record_stream dropped during raw_delete rollback leaves block reused with outstanding work | `StreamUsesPersist` or `StreamOrderedReuse` | F3 |
| M6 | AllocateToPoolGuard dtor after flat-api end + re-begin disarms live capture | `RoutingFlagMatchesTLS` | F6.1 |
| M7 | Two threads pass fraction gate and both bump reservedBytes past limit | `ReservedLimitRespected` | F7.1 |
| M8 | GC age inherited from stale head after coalesce reshape causes out-of-order reclamation | `GCAgeMonotone` | F5 |
| M9 | `retain_pool_` refcnt wraps to 0, GC-erases while callers hold refs | `PoolRefcntWellFounded` | F6.2 |
| M10 | Coalesce left-merge producing oversize block prevents further reuse | `AllocEventuallySucceeds` (bounded) | F4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| T1 | `owns`/`getBaseAllocation` return true for blocks in limbo/deferred | Unit test: free → query within window → assert contract |
| T2 | `gc_passes` counter undercounts when GC filters all candidates | Stress test with mixed ages and check counter monotonicity |
| T3 | `emptyCache` reclaims are invisible to `gc_reclaimed_bytes` | Unit test the stats after a fraction-cap emptyCache |
| T4 | Async backend `used_bytes_` inflated after capture-time free | Integration test with graph capture + alloc cycle |
| T5 | Async backend leaks unifying stream on allocator teardown | Leak test on process exit |
| T6 | Prewarm leaks Blocks on post-alloc exception | Fault injection on `new Block()` |
| T7 | Split-enabled vs no-split pool-from-global reuse asymmetry | Config-dependent reuse reachability test |
| T8 | Split tails stranded on quiescent owner stream after cross-stream steal | Workload with dying streams |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | `active_capture_count`/`active_replay_count` are semantically boolean but typed as counters — rename or enforce counter semantics | Rename to `*_active : bool` or implement full counter |
| C2 | `release_pool_` silently returns on unknown id vs `retain_pool_` throws — harmonize | Choose strict or permissive, apply uniformly |
| C3 | Async backend holds `mu_` across `cudaDeviceSynchronize` in `emptyCache` — potential deadlock | Drop lock around sync |
| C4 | `event_count > 0` guard on limbo pop masks F2 underflow — replace with invariant check | Replace with assert |
| C5 | `coalesce_neighbors_unlocked` eligibility predicate should also verify neighbor is in `per_stream_free_` ∪ `cross_stream_free_` | Add index-membership check |
| C6 | `find_candidate_heads_locked` should skip blocks present in `deferred_` | Add index-set check or use a `pending_free` flag on Block |
| C7 | `process_events` should hold a `pe_in_progress` flag to prevent concurrent deferred-flush | Add serialization |
| C8 | `oversize` policy asymmetry (skipped right-merge after left-merge becomes oversize) — document or fix | Design review |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/vibetensor-cuda-allocator/.specula-output/analysis-report.md`
- **Key source files**:
  - `include/vbt/cuda/allocator.h` (types): lines 33-73 (`RoundPolicy`, `round_size`, `classify`), 520-544 (`Config`), 619-639 (`Block`, `Segment`, `LimboEntry`, `DeferredFree`, `GraphPrivatePool`), 641-673 (`Allocator` private state).
  - `src/vbt/cuda/allocator.cc`:
    - Family 1: lines 1553-1671 (`raw_delete`), 1692-1807 (`process_events`), 1811-1894 (GC segment walk), 3693-3881 (`coalesce_neighbors_unlocked`), 3767-3789 (`eligible_neighbor`).
    - Family 2: lines 1696-1738 (deferred flush).
    - Family 3: lines 1626-1686 (rollback and `record_stream`).
    - Family 4: lines 338-453 (`maybe_run_fraction_gate`), 818-978 (pool lifecycle), 1128-1171 (`AllocateToPoolGuard`).
    - Family 5: same as Family 4.
    - Family 6: lines 1897-2081 (`run_gc_pass_if_eligible`), 1810-1894 (candidate scan).
  - `src/vbt/cuda/allocator_async.cc`: lines 36-214 (config, malloc, free, emptyCache, stats).
- **GitHub issues/PRs**: none relevant (zero issues, two non-allocator PRs).
- **Reference implementation**: PyTorch `CUDACachingAllocator.cpp` (pre-expandable-segments) — note the `pending_free` / "pool" flag pattern used by PyTorch that VibeTensor omits. Reference CUDA paper: Nvidia stream-ordered memory allocator documentation (`cudaMallocAsync`, `cudaFreeAsync`).

---

## Priority Summary

| Family | Priority | Severity | TLA+ Fit | Verification |
|---|---|---|---|---|
| F1 Phantom Free Block (window + deferred) | **HIGH** | Memory UAF | Excellent | Model-check |
| F2 Non-idempotent process_events | **HIGH** | Memory UAF + free-list corruption | Excellent | Model-check |
| F3 Lost stream-use fence on rollback | HIGH | Cross-stream UAF | Good | Model-check |
| F6 Graph-pool guard stale destruction | MEDIUM | Capture correctness | Good | Model-check |
| F5 Fraction-cap TOCTOU | MEDIUM | Cap violation | Good | Model-check |
| F6 GC age non-monotonicity | MEDIUM-LOW | Liveness | Fair | Model-check |
| F7 Async used_bytes_ leak | LOW-MEDIUM | Spurious OOM | Fair | Test or model-check |
| F4 Oversize island | MEDIUM | Fragmentation | Low | Test + design review |
| F10 Prewarm leak on throw | LOW | Leak | Low | Test |
| F11, F12, F13, F14, F15 | LOW | Observability / policy | Low | Code review |

**Recommended spec scope**: Families 1, 2, and 3 as the primary targets; Family 4 (graph pool) and Family 5 (fraction cap) as secondary if modeling budget permits. Families 6 and 7 as follow-ups.
