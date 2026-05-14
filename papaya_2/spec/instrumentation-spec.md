# Instrumentation Spec: papaya Lock-Free Concurrent HashMap (Round 2)

## System Category

**Category B** (concurrent / lock-free) — use the timebox trace approach with per-thread `[start, end]` intervals captured via `rdtsc` (or `Instant::now()` on platforms without TSC).

Round 2 extends round 1 with new event types for **Family 6 (iter+modify+resize)** and **Family 7 (META overwrite)**. Round-1 events are preserved verbatim; only fields and the meta-fixup event are new.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "tid":   "<thread_id>",
  "start": <u64_timestamp>,
  "end":   <u64_timestamp>,
  ...event-specific fields...,
  ...common state snapshot fields (captured outside [start, end])...
}
```

### Timebox Instrumentation

Each event captures `start` immediately before the critical atomic operation and `end` immediately after. Keep the interval as tight as possible around the linearization point so `ViablePIDs` prunes aggressively.

```rust
let _t_start = if crate::tla_trace::is_enabled() { crate::tla_trace::timestamp_ns() } else { 0 };
// ... critical atomic CAS / store / load ...
let _t_end = crate::tla_trace::timestamp_ns();
crate::tla_trace::emit_<event>(_t_start, _t_end, ...fields...);
```

### Common State Fields

Captured at every event (outside the `[start, end]` interval) — used by `ValidatePostState`:

| Impl field | TLA+ variable | How to capture |
|---|---|---|
| `self.table.load(Acquire)` | `rootTable` | Global table-id registry → `usize` |
| `table.entry(i).load(Acquire)` (`Tagged`) | `tableEntry[t][s]` | Pointer + tag bits |
| `table.meta(i).load(Acquire)` | `tableMeta[t][s]` | byte ∈ {EMPTY=0x80, TOMBSTONE=0xFE, h2(k)} |
| `table.state().next.load(Acquire)` | `nextTable[t]` | Next-table id or 0 |
| `table.state().status.load(Acquire)` | `resizeStatus[t]` | byte (0=PENDING, 1=ABORTED, 2=PROMOTED) |
| `table.state().copied.load(Acquire)` | `copiedCount[t]` | usize |
| `table.state().claim.load(Acquire)` | `claimCount[t]` | usize |

State capture for the slot being acted on (`tableEntry[t][s]`, `tableMeta[t][s]`, `metaWritten[t][s]`) is mandatory; capturing the full table tensor is optional and rate-limited (e.g. only on `init_table`, `try_promote`).

### Table-ID Registry

Real `*mut RawTable<...>` pointers must be mapped to small integer IDs. Use a global registry behind a `Mutex<HashMap<usize, usize>>` plus `AtomicUsize` counter (already exists in `tla_trace::table_id`).

### Slot Indices

Physical probe index `i: usize` maps directly to the `Slot` set (`s1`, `s2`, …). Trace.cfg's `Slot` set must cover the table size used in tests.

## Section 2: Action-to-Code Mapping

### Round-1 events (preserved)

#### 1. `insert_cas` — Phase 1 of two-phase insert  *(maps to `InsertCASEntry`)*

| Field | Value |
|---|---|
| **Spec action** | `InsertCASEntry(tid, k, v, t, s)` |
| **Code location** | `raw/mod.rs:1028-1044` (winner CAS path of `insert_at`) |
| **Trigger point** | Around `guard.compare_exchange(entry, null, new_entry, Release, Acquire)` at line 1028 |
| **Event name** | `insert_cas` |
| **Fields** | `key`, `value`, `table` (id), `slot` (`i`), `pre_meta`, `pre_entry` |
| **Notes** | Emit only on `Ok(_)`. After the CAS, the winner sleeps in the yield-loop at line 1047, widening the META OVERWRITE window — DO NOT remove that loop while validating Family 7. |

#### 2. `insert_meta` — Phase 2 winner unconditional store  *(maps to `InsertStoreMeta`)*

| Field | Value |
|---|---|
| **Spec action** | `InsertStoreMeta(tid, t, s)` |
| **Code location** | `raw/mod.rs:1051` (`meta_entry.store(meta, Release)`) |
| **Trigger point** | Around the `meta_entry.store(...)` call |
| **Event name** | `insert_meta` |
| **Fields** | `table`, `slot`, `meta` (the byte being stored), `entry_at_store` (`tableEntry[t][s]` after store) |
| **Notes** | This is the buggy site for Family 7 D2-4. Capture `entry_at_store` so trace validation can detect the case where the entry is `null` (tombstoned) but `meta = h2(k)` is being written. The detection logic at `raw/mod.rs:1054-1059` already increments `META_OVERWRITE_BUG_COUNT`; emit a separate `meta_overwrite` event when the count increments. |

#### 3. `insert_meta_fixup` — Loser fixup path  *(maps to `InsertMetaFixup`)* — **NEW (Family 7)**

| Field | Value |
|---|---|
| **Spec action** | `InsertMetaFixup(tid, t, s)` |
| **Code location** | `raw/mod.rs:1106-1108` (`if meta_entry.load(Relaxed) == EMPTY then meta_entry.store(meta, Release)`) |
| **Trigger point** | Around the `meta_entry.store(meta, Ordering::Release)` at line 1107 |
| **Event name** | `insert_meta_fixup` |
| **Fields** | `table`, `slot`, `observed_key` (key captured from the slot at line 1091), `meta_pre` (prior meta byte), `meta` (newly stored value) |
| **Notes** | Emit only when the fixup actually executes the inner store (i.e. the EMPTY-check at 1106 succeeded). Skip when the load already saw a non-EMPTY value. |

#### 4. `insert_update` — Replace existing entry value  *(maps to `InsertUpdate`)*

| Field | Value |
|---|---|
| **Spec action** | `InsertUpdate(tid, k, v, t, s)` |
| **Code location** | `raw/mod.rs:1124-1180` (`update_at`) — CAS old → new |
| **Trigger point** | Around `guard.compare_exchange_weak(entry, current, new_entry, Release, Acquire)` |
| **Event name** | `insert_update` |
| **Fields** | `key`, `value`, `table`, `slot`, `old_value` |
| **Notes** | Emit only on `Ok(_)`. Also covers `insert_slow` retry loop. |

#### 5. `remove` — CAS entry → TOMBSTONE  *(maps to `Remove`)*

| Field | Value |
|---|---|
| **Spec action** | `Remove(tid, k, t, s)` |
| **Code location** | `raw/mod.rs:769-792` (via `update_at` to `TOMBSTONE_PTR`, then meta store) |
| **Trigger point** | Around the `update_at` CAS at 769; capture `start` before and `end` after the meta tombstone store at 782-786 |
| **Event name** | `remove` |
| **Fields** | `key`, `table`, `slot` |
| **Notes** | Emit only on `UpdateStatus::Replaced`. |

#### 6. `copy_mark_copying` — Set COPYING tag on source  *(maps to `CopyMarkCopying`)*

| Field | Value |
|---|---|
| **Spec action** | `CopyMarkCopying(tid, srcT, s)` |
| **Code location** | `raw/mod.rs:2162-2164` (blocking) and `raw/mod.rs:2310-2311` (incremental) |
| **Trigger point** | Around `entry.fetch_or(Entry::COPYING, AcqRel)` |
| **Event name** | `copy_mark_copying` |
| **Fields** | `table` (src), `slot`, `mode` ("blocking"/"incremental") |
| **Notes** | Skip if the prior tag already had COPYING (lost the race). |

#### 7. `copy_mark_copying_null` — Tombstone null/empty source slot  *(maps to `CopyMarkCopyingNull`)*

| Field | Value |
|---|---|
| **Spec action** | `CopyMarkCopyingNull(tid, srcT, s)` |
| **Code location** | `raw/mod.rs:2166-2178` |
| **Trigger point** | Around the meta TOMBSTONE store at 2176 |
| **Event name** | `copy_mark_copying_null` |
| **Fields** | `table`, `slot` |
| **Notes** | If too noisy, leave the silent-batch action `SilentBatchCopyNullSlots` to handle the bulk. |

#### 8. `copy_insert` — Insert copied entry into next table  *(maps to `CopyInsertToNext`)*

| Field | Value |
|---|---|
| **Spec action** | `CopyInsertToNext(tid, srcT, srcS, dstT, dstS)` |
| **Code location** | `raw/mod.rs:2396-2407` (`insert_copy`, CAS null → entry in `dst`) |
| **Trigger point** | Around `guard.compare_exchange(entry, null, new_entry, Release, Acquire)` at 2396 |
| **Event name** | `copy_insert` |
| **Fields** | `src_table`, `src_slot`, `dst_table`, `dst_slot`, `key` |
| **Notes** | Emit only on `Ok(_)`. `insert_copy` may retry in nested tables; record where it actually landed. |

#### 9. `copy_mark_copied` — Set COPIED tag on source  *(maps to `CopyMarkCopied`)*

| Field | Value |
|---|---|
| **Spec action** | `CopyMarkCopied(tid, srcT, srcS)` |
| **Code location** | `raw/mod.rs:2342-2351` (incremental: `entry.store(copied, SeqCst)`) |
| **Trigger point** | Around `entry.store(copied, Ordering::SeqCst)` at 2351 |
| **Event name** | `copy_mark_copied` |
| **Fields** | `table` (src), `slot` |
| **Notes** | Incremental mode only. |

#### 10. `alloc_next` — Allocate next table  *(maps to `AllocNextTable`)*

| Field | Value |
|---|---|
| **Spec action** | `AllocNextTable(tid, t)` |
| **Code location** | `raw/mod.rs:1980-1981` (`state.next.store(next.raw, Release)`) |
| **Trigger point** | After `state.next.store(...)` at 1981 |
| **Event name** | `alloc_next` |
| **Fields** | `table` (src), `next_table` (new id), `capacity` |

#### 11. `try_promote` — CAS root to next table  *(maps to `TryPromote`)*

| Field | Value |
|---|---|
| **Spec action** | `TryPromote(tid, t)` |
| **Code location** | `raw/mod.rs:2475-2484` (CAS root + status store) |
| **Trigger point** | Around `self.table.compare_exchange(table.raw, next.raw, Release, Acquire)` at 2476 |
| **Event name** | `try_promote` |
| **Fields** | `old_root`, `new_root`, `copied_count` |
| **Notes** | Emit on success. The PROMOTED status store (2484) and unpark (2501) immediately follow. |

#### 12. `abort_resize` — Abort current resize  *(maps to `AbortResize`)* — **Family 3 / D2-1**

| Field | Value |
|---|---|
| **Spec action** | `AbortResize(tid, srcT, abortedT)` |
| **Code location** | `raw/mod.rs:2268` (`status.store(ABORTED, SeqCst)`) and the buggy unpark at 2282-2283 |
| **Trigger point** | Around `next.state().status.store(State::ABORTED, Ordering::SeqCst)` at 2268 |
| **Event name** | `abort_resize` |
| **Fields** | `src_table`, `aborted_table`, `parker_used` (the buggy parker target), `key_used` (the buggy key target) |
| **Notes** | Capture both `parker_used` and `key_used` so trace validation can confirm the spec mirrors the buggy routing. PR #92's fix would change these fields. |

#### 13. `init_table` — Lazy init  *(maps to `InitTable`)*

| Field | Value |
|---|---|
| **Spec action** | `InitTable(tid)` |
| **Code location** | `raw/mod.rs:1867-1874` (CAS null → new table) |
| **Trigger point** | Around `self.table.compare_exchange(null, new.raw, Release, Acquire)` |
| **Event name** | `init_table` |
| **Fields** | `table` (new id), `capacity` |

#### 14. `park` — Thread parks  *(maps to `ParkThread`)* — **Family 3**

| Field | Value |
|---|---|
| **Spec action** | `ParkThread(tid, t)` |
| **Code location** | `raw/mod.rs:2350-2352` (incremental) and `raw/mod.rs:2134-2136` (blocking) |
| **Trigger point** | Before `state.parker.park(...)` |
| **Event name** | `park` |
| **Fields** | `table` (the parker's table), `key_addr` (address of `state.status` used as key) |
| **Notes** | The `end` timestamp is set when `park()` returns (after unpark). Capture both fields to disambiguate the (parker, key) tuple from the buggy abort path. |

### Round-2 NEW events

#### 15. `iter_begin` — Iterator snapshot  *(maps to `IterBegin`)* — **NEW (Family 6)**

| Field | Value |
|---|---|
| **Spec action** | `IterBegin(tid)` |
| **Code location** | `raw/mod.rs:1400-1419` (`HashMap::iter`) |
| **Trigger point** | After `let table = self.linearize(root, guard)` at line 1417 |
| **Event name** | `iter_begin` |
| **Fields** | `snapshot_table` (id of the table the Iter holds), `started_keys` (snapshot of `insertedKeys`, optional but useful for IterWeakSnapshot validation) |
| **Notes** | The captured `snapshot_table` is the linearized table; it may differ from current `rootTable` if a resize happens later. |

#### 16. `iter_yield` — Iterator yields one entry  *(maps to `IterAdvanceYield`)* — **NEW (Family 6)**

| Field | Value |
|---|---|
| **Spec action** | `IterAdvanceYield(tid)` |
| **Code location** | `raw/mod.rs:2960-2998` (`Iter::next` returning `Some`) |
| **Trigger point** | At the `return Some(...)` at 2998 |
| **Event name** | `iter_yield` |
| **Fields** | `key`, `slot` (`self.i - 1` after the increment at 2997), `snapshot_table` (echoed for invariant cross-check) |
| **Notes** | One event per yield. Crucial for `IterNoDoubleYield`. |

#### 17. `iter_skip` — Iterator skips empty/tombstone slot  *(maps to `IterAdvanceSkip`)* — **NEW (Family 6)**

| Field | Value |
|---|---|
| **Spec action** | `IterAdvanceSkip(tid)` |
| **Code location** | `raw/mod.rs:2972-2975` (meta == EMPTY/TOMBSTONE branch) and `raw/mod.rs:2987-2989` (entry.ptr.is_null branch) |
| **Trigger point** | At the `self.i += 1; continue;` |
| **Event name** | `iter_skip` |
| **Fields** | `slot` (`self.i` before increment), `reason` ("empty" / "tombstone" / "null_entry") |
| **Notes** | Optional but recommended for fine-grained timebox tracing. May be batched if too noisy. |

#### 18. `iter_end` — Iterator exhausted  *(maps to `IterEnd`)* — **NEW (Family 6)**

| Field | Value |
|---|---|
| **Spec action** | `IterEnd(tid)` |
| **Code location** | `raw/mod.rs:2962-2965` (`if self.i >= self.table.len() return None`) |
| **Trigger point** | At the `return None` at 2964 |
| **Event name** | `iter_end` |
| **Fields** | `snapshot_table`, `total_yielded` (Len of seenKeys at end) |

## Section 3: Special Considerations

### 3.1 Two-Phase Insert: `insert_cas` → `insert_meta` (Family 7 D2-4)

These MUST be emitted as separate events with separate `[start, end]` intervals. The yield-loop at `raw/mod.rs:1047` deliberately widens the gap; preserve it during stress runs (`RUSTFLAGS=--cfg papaya_stress`).

For the buggy meta-overwrite to be observed in a trace:

1. Thread A: `insert_cas` succeeds at `(t, s)` with key `k`.
2. Thread B: `remove` of `k` at `(t, s)` lands during A's yield loop.
3. Thread A: `insert_meta` stores `h2(k)` over `META_TOMBSTONE`.

The harness can additionally emit a one-shot `meta_overwrite` event when `META_OVERWRITE_BUG_COUNT` increments (raw/mod.rs:1057), but the trace already captures enough to detect the violation via `NoStaleMetaOnEmptySlot` in MC.

### 3.2 Iterator Trace Format

Iterator events form a per-thread sub-sequence: `iter_begin → (iter_yield | iter_skip)+ → iter_end`. The `seenKeys` sequence and `iterTable` snapshot are reconstructed by the trace spec.

For PR #76 `drain` simulations, additional `iter_chain_advance` events would be needed; the current spec models the **single-table** snapshot only (matching released `iter`). Do not instrument PR #76 unless the harness explicitly tests it.

### 3.3 Parker Wakeup Routing (Family 3 D2-1)

`abort_resize` MUST capture `parker_used` and `key_used` separately from `aborted_table`. PR #92's fix changes these fields; the trace records the actual parker target so the trace spec can detect the bug.

If `parker_used = aborted_table` (correct, post-#92), the spec's buggy `AbortResize` would NOT match — trace validation fails to consume the event. The trace spec is therefore implicitly biased toward the upstream-master (buggy) behavior. To validate the patched fork, swap the buggy AbortResize body to unpark `abortedT` instead of `srcT`.

### 3.4 Table-ID Stability

Tables are re-allocated on every test run. Use the existing `tla_trace::table_id` registry. Never reuse a freed table's id.

### 3.5 Bootstrap

`TraceInit` matches `Init`. The first event in any trace must be `init_table`.

### 3.6 Concurrency / Per-Thread Trace Files

Each thread writes its own NDJSON file (e.g. `traces/thread_<tid>.ndjson`). A preprocessor merges these into the consolidated JSON consumed by `Trace.tla`:

```json
{ "threads": { "t1": [ ... ], "t2": [ ... ], "t3": [ ... ] } }
```

Timestamps are compressed to dense integers (rdtsc → 0,1,2,…) preserving the partial order. This keeps `ViablePIDs` cheap.

### 3.7 Field Omission

Several events have optional fields (e.g., `pre_meta`, `pre_entry`, `started_keys`). The trace spec uses `HasField(logline, name)` to make these checks conditional. If you choose not to emit a field, validation skips it — but per skill rules, do NOT add a check for a field the harness never emits, and do NOT capture a field that the spec ignores.

### 3.8 Family 6 Limitations

`IterWeakSnapshot` is a *relative* invariant — it holds vacuously when the snapshot table is no longer in the chain (post-promote). Trace validation does not enforce it (it is gated to MC hunting). The trace's role for Family 6 is to confirm `iter_*` events linearly produce a `seenKeys` sequence consistent with the snapshot's slot contents at those moments.
