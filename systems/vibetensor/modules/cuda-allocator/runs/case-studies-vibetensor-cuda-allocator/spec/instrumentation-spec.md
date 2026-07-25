# Instrumentation Spec — VibeTensor CUDA Allocator

Target: `vbt::cuda::Allocator` (native backend) in
`vibetensor/src/vbt/cuda/allocator.cc` and
`vibetensor/include/vbt/cuda/allocator.h`.

**System category**: Category B (concurrent / lock-free / runtime).
Trace format: per-thread timebox traces (`[start, end]` intervals), as
described in `references/trace-spec-pattern.md`. The harness emits NDJSON
lines per event; a preprocessor converts them into a per-thread JSON object
for `Trace.tla`.

---

## Section 1 — Trace Event Schema

### Event envelope

Every event has this common envelope:

| Field         | Type           | Description                                    |
|---------------|----------------|------------------------------------------------|
| `name`        | string         | TLA+ action name (e.g. `raw_delete.mark`)      |
| `tid`         | integer        | Unix tid / `std::this_thread::get_id()` hash   |
| `start`       | integer (rdtsc)| Rdtsc / steady_clock ns at entry to region     |
| `end`         | integer (rdtsc)| Rdtsc / steady_clock ns at exit from region    |
| `state`       | object         | Post-action snapshot of `BaseState` fields     |
| `fields`      | object         | Event-specific payload                         |

Intervals `[start, end]` should bracket the *critical section* of the action
— typically the `MuLockGuard` region in the code. State snapshots are taken
**after `end`** to keep the interval tight while still validating the
post-state. The preprocessor maps raw rdtsc values to dense integers to keep
TLA+ comparisons cheap.

### `state` fields (captured at every event)

| Field                 | TLA+ variable       | Source                                 |
|-----------------------|---------------------|----------------------------------------|
| `existingBlockIds`    | `existingBlocks`    | keys of `by_ptr_`                      |
| `activeBlockIds`      | `activeBlocks`      | `active_blocks_`                       |
| `perStreamFree`       | `perStreamFree`     | `per_stream_free_` keys                |
| `crossStreamFree`     | `crossStreamFree`   | `cross_stream_free_` keys              |
| `deferredLen`         | `Len(deferredQ)`    | `deferred_.size()`                     |
| `limboLens`           | per-stream lengths  | `limbo_[sid].size()`                   |
| `reservedBytes`       | `reservedBytes`     | `stats_.reserved_bytes_all_current`    |
| `routingFlag`         | `routingFlag`       | `routing_active_flag_.load()`          |
| `tlsActive`           | `tls[t].active`     | `s_capture_tls.active`                 |
| `tlsPool`             | `tls[t].pool`       | `s_capture_tls.id.id`                  |
| `rdOutcome`           | *ghost*             | `"Published" | "RolledBack" | "Deferred"` |

### `fields` per-event types

See Section 2 for the exact fields per event.

### Block ID convention

Real allocator uses `Block*` pointers. The harness must assign a stable
integer ID per block — recommended: intern `reinterpret_cast<uintptr_t>(b)`
to a dense 1-based counter when the block is first observed, and recycle
IDs as they are freed. The preprocessor writes BlockIds as `b<N>`.

---

## Section 2 — Action-to-Code Mapping

> Trigger point convention: **"after critical section"** means *after the
> `MuLockGuard` destructor runs* — i.e. the lock is released and other
> threads can observe the new state. Use `end = rdtsc()` inside the block
> (just before `}`) and the state snapshot right after the block.

### `raw_alloc.new` — fresh cudaMalloc + block insertion

- **Code**: `allocator.cc:1310-1343` (nostream variant) and
  `allocator.cc:1497-1511` (stream variant). Trigger **after** the
  `MuLockGuard lg(mu_)` that inserts the new block into `by_ptr_` /
  `active_blocks_`.
- **Fields**: `{ bid: BlockId, sid: StreamId, pool: PoolId, size: Nat }`
- **Notes**: `sid = 0` for the nostream variant maps to the current-stream
  default; still emit the real stream id.

### `raw_alloc.reuse_stream` — per-stream free-list reuse

- **Code**: `allocator.cc:1204-1210` / `1391-1397`.
- **Trigger**: after `on_reuse_from_free_list` returns, under the same lock.
- **Fields**: `{ bid: BlockId, sid: StreamId, pool: PoolId, size: Nat }`

### `raw_alloc.reuse_cross` — cross-stream fallback

- **Code**: `allocator.cc:1213-1222` / `1400-1409`.
- **Fields**: `{ bid: BlockId, sid: StreamId }`

### `split` — split_block_unlocked

- **Code**: `allocator.cc:3572-3690` (exit line ~3690).
- **Trigger**: after allocator mutex released (still inside caller lock).
- **Fields**: `{ bid: BlockId, tail_bid: BlockId, take_size: Nat }`
- **Notes**: Emit the `gcAge` reset at `allocator.cc:3688` as a state
  observation; no separate trace event.

### `record_stream`

- **Code**: `allocator.cc:1673-1690`.
- **Trigger**: after the insert into `b->stream_uses` (inside same lock).
- **Fields**: `{ bid: BlockId, sid: StreamId }`
- **Notes**: Emit **even when the function early-returns** at 1682
  (`!b->allocated`); mark the field `was_dropped: true` in that case. The
  trace spec uses this to validate Family 3 (stream registration was lost
  because raw_delete cleared `allocated`).

### `raw_delete.mark` — phase 1

- **Code**: `allocator.cc:1553-1585` (ends at line 1585, `}`).
- **Trigger**: right **before** `lg` dtor runs (still under lock).
- **Fields**: `{ bid: BlockId, new_owner: StreamId, prev_owner: StreamId,
  snapshot_streams: [StreamId], fast_path: Bool }`
- **Notes**: If the fast-path branch fired (1575-1584), set
  `fast_path: true` and emit `raw_delete.same_stream_fast` **instead** —
  do not emit a separate `raw_delete.mark`.

### `raw_delete.same_stream_fast`

- **Code**: `allocator.cc:1575-1584`.
- **Fields**: `{ bid: BlockId, new_owner: StreamId }`

### `raw_delete.record_ok` — phase 2 success

- **Code**: `allocator.cc:1611-1625` (the `pendings` for-loop exits with
  `failure == false`).
- **Trigger**: off-lock, right after the last `cudaEventRecord` succeeds
  and *before* re-acquiring `mu_`.
- **Fields**: `{ bid: BlockId, recorded_streams: [StreamId] }`

### `raw_delete.record_fail` — phase 2 failure

- **Code**: `allocator.cc:1622` (when `cudaEventRecord != cudaSuccess`) or
  `1619` (when `!e.valid()`).
- **Trigger**: off-lock, immediately after detecting failure.
- **Fields**: `{ bid: BlockId, partial_recorded: [StreamId] }`

### `raw_delete.publish` — phase 3

- **Code**: `allocator.cc:1656-1663`.
- **Trigger**: after the `event_count += 1` loop and limbo push, after lock
  released.
- **Fields**: `{ bid: BlockId, recorded_streams: [StreamId],
  token_base: Nat }`

### `raw_delete.finish_rollback`

- **Code**: `allocator.cc:1626-1653`.
- **Trigger**: after the rollback re-sets `allocated = true` under lock.
- **Fields**: `{ bid: BlockId, restored_streams: [StreamId] }`

### `raw_delete.to_deferred`

- **Code**: `allocator.cc:1599-1608`.
- **Trigger**: after the `deferred_.push_back` and lock release.
- **Fields**: `{ bid: BlockId, owner_sid: StreamId,
  streams: [StreamId] }`

### `pe.snapshot` — process_events deferred snapshot

- **Code**: `allocator.cc:1696-1700`.
- **Trigger**: after `cands.assign(...)` and lock release.
- **Fields**: `{ cands_len: Nat }`
- **Notes**: Multiple threads can hit this nearly simultaneously — timebox
  intervals will overlap. `ViablePIDs` handles both orderings.

### `pe.skip_capturing`

- **Code**: `allocator.cc:1701-1706`.
- **Trigger**: per `df` that was skipped due to capturing.
- **Fields**: `{ df_bid: BlockId, df_owner_sid: StreamId }`

### `pe.record_ok`

- **Code**: `allocator.cc:1712-1721` exit without failure.
- **Trigger**: off-lock, after last `cudaEventRecord` success.
- **Fields**: `{ df_bid: BlockId, recorded_streams: [StreamId] }`

### `pe.record_fail`

- **Code**: `allocator.cc:1722-1725`.
- **Fields**: `{ df_bid: BlockId }`

### `pe.publish`

- **Code**: `allocator.cc:1727-1737`.
- **Trigger**: after the limbo pushes and lock release.
- **Fields**: `{ bid: BlockId, erased: Bool, event_count_after: Nat,
  duplicate_pushed: Bool }`
- **Notes**: `duplicate_pushed` is an **auditing** field — `true` if the
  linear-search erase found no matching entry (i.e., a peer flush already
  erased it) yet we still push to limbo. This directly exercises the
  Family 2 invariant.

### `pe.loop_done`

- Emitted at end of the `cands` loop with no remaining entries.
- **Fields**: `{}`

### `pe.pop_ready` — limbo drain head pop

- **Code**: `allocator.cc:1748-1802`.
- **Trigger**: after the pop + optional re-insert, lock released.
- **Fields**: `{ sid: StreamId, bid: BlockId, event_count_after: Nat,
  reinserted: Bool }`

### `coalesce.left` / `coalesce.right`

- **Code**: `allocator.cc:3798-3822` (left) / `3842-3861` (right).
- **Trigger**: inside the `insert_free_block_unlocked` caller's lock, after
  the merge.
- **Fields**: `{ bid: BlockId, merged_neighbor: BlockId,
  new_size: Nat, eligible_by_flag: Bool, eligible_by_index: Bool }`
- **Notes**: `eligible_by_flag` reflects the actual (bug-carrying) predicate
  at line 3767-3789. `eligible_by_index` is the harness-computed *correct*
  predicate (block in `per_stream_free_ ∪ cross_stream_free_`). The Family 1
  bug is the existence of events where `eligible_by_flag = true` but
  `eligible_by_index = false`.

### `gc.detach` — detach_segment_for_gc_locked

- **Code**: `allocator.cc:1849-1894`.
- **Trigger**: after the chain walk and lock release (before off-lock
  `cudaFree`).
- **Fields**: `{ head: BlockId, chain: [BlockId], freed_bytes: Nat }`

### `emptyCache`

- **Code**: `allocator.cc:2082-2138`.
- **Trigger**: after all `detach_segment_for_gc_locked` calls complete and
  lock is released (before the off-lock cudaFree loop).
- **Fields**: `{ heads: [BlockId], total_freed_bytes: Nat }`

### `pool.begin` / `pool.end_flat` / `pool.guard_destruct`

- **Code**:
  - `pool.begin`: `allocator.cc:861-888`.
  - `pool.end_flat`: `allocator.cc:891-913`.
  - `pool.guard_destruct`: `allocator.cc:1131-1135` (calls `cancel_` at
    `915-937`).
- **Trigger**: for `begin`, after both the `MuLockGuard` and the TLS +
  `routing_active_flag_` stores (so the state snapshot is fully coherent).
  For `end_flat` and `guard_destruct`, after the lock-guarded block exits.
- **Fields**: `{ pool: PoolId,
  pool_refcnt_after: Nat,
  pool_active_cap_after: Nat,
  tls_active_after: Bool,
  tls_pool_after: PoolId,
  routing_flag_after: Bool }`
- **Notes**: These three events are the primary Family 4 trigger sites.
  The `pool.guard_destruct` event must carry the thread id of the guard's
  **owner** (RAII frame), which may differ from the thread that last
  called `end_allocate_to_pool_`.

### `pool.retain` / `pool.release`

- **Code**: `allocator.cc:826-859`.
- **Fields**: `{ pool: PoolId, refcnt_after: Nat }`

### `fg.pass_gate`

- **Code**: `allocator.cc:338-400` (through step 6). The event covers
  steps 1-3 (sample + breach record); subsequent steps are separate events.
- **Trigger**: after lock released post breach-count increment (line 370)
  **or** on the early-return path at line 365 (`!cap_exceeded`) — emit both
  with a `breached: Bool` field.
- **Fields**: `{ limit_before: Nat, reserved_before: Nat, rounded: Nat,
  breached: Bool }`

### `fg.retry_misfire` / `fg.recovered`

- **Code**: `fg.retry_misfire`: `allocator.cc:439-446`.
  `fg.recovered`: `allocator.cc:418-420` (cap satisfied after GC).
- **Fields**: `{ limit_after: Nat, reserved_after: Nat }`

### `env.capture_start` / `env.capture_end`

- **Code**: The harness controls stream capture in the fault-injection
  wrapper; emit these events immediately before `cudaStreamBeginCapture` /
  after `cudaStreamEndCapture`.
- **Fields**: `{ sid: StreamId }`

---

## Section 3 — Special Considerations

### Thread ID normalization

The native allocator uses `std::this_thread::get_id()`. Normalize to the
set of integers `{1..N}` in insertion order (first-seen). The preprocessor
must remap raw OS tids to the `{t1, t2, t3}` set used in
`Trace.cfg`. Capture the mapping in the output JSON under `tidMap`.

### Timebox interval extraction

The `[start, end]` interval for each event must be:
- `start` = timestamp **immediately before** the first `MuLockGuard`
  involved in the action, or immediately before the action's first shared
  memory access.
- `end`   = timestamp **immediately after** the last `MuLockGuard` destructor
  runs (or last shared memory store).

Keeping these tight reduces spurious partial-order branching in `Trace.tla`.

### Per-block ID harness-side bookkeeping

The harness maintains a `std::unordered_map<Block*, int>` mapping live
`Block*` pointers to stable integer IDs. When `delete block` runs in
`coalesce_neighbors_unlocked` (3818, 3860) or
`detach_segment_for_gc_locked` (1890), **do not free the entry immediately**
— mark the mapping as "retired" so subsequent pe.publish events that name
the freed block (the F1/F2 dangling case) still have a stable ID. Retired
IDs become `b<N>-dangling` in the trace.

### Fraction cap integer units

TLA+ spec uses abstract units (1 per block). The harness reports
`reservedBytes` in bytes but emits a normalized `reservedBytesUnits =
reservedBytes / round_size(1)` field. The trace spec operates on the
normalized unit; the preprocessor can further scale.

### Fault-injection hooks

The MC spec explores fault cases (cudaEventRecord fail, cudaMalloc fail,
stream capture flips). For trace validation these are emitted via harness
wrappers that intercept `cudaEventRecord` and `cudaMalloc` — see
the harness-generation skill output.

### Granularity note — one trace event per spec action

Each of the three `raw_delete` phases (`mark`, `record_ok`/`record_fail`,
`publish`/`finish_rollback`) **must** emit its own event, despite the
public API appearing to be a single `raw_delete(ptr)` call. Same for
`pe.snapshot` / `pe.record_*` / `pe.publish`. Do not coalesce them — the
intermediate states are exactly where Family 1, 2, 3 bugs live (see
`references/trace-spec-pattern.md` § "Granularity Mismatch").

### State fields that validation depends on

Every `fields.bid` in the trace must correspond to a block ID that the
harness has seen before (or will see within this event, for `raw_alloc.new`
and `split`). The trace spec reads
`block`, `segPrev`, `segNext` for post-state checks; the harness does not
need to dump the full `block` record, but must populate:
- `rdOutcome` on every `raw_delete.*` event (for `ValidatePublish`)
- `deferredLen` on every `pe.snapshot` (for `ValidatePeSnapshot`)
- `tls_*` / `routing_flag_after` on every `pool.*` event (for
  `ValidateBeginCapture` / `ValidateEndCapture` / `ValidateGuardDestruct`)

Fields listed above but never captured will make the corresponding
`ValidateXxx` clause vacuously true — deliberately keep them
non-vacuous so the trace spec catches harness regressions.
