# Round-2 Trace Harness for papaya

This harness instruments the real `papaya` source code in `artifact/papaya/`
to emit round-2 spec events. It is built on top of the round-1 instrumentation
already present in the artifact's `src/raw/mod.rs`.

## Files

| Path | Purpose |
|---|---|
| `src/tla_trace.rs` | Trace emission module. Replaces the artifact's existing tla_trace.rs. Contains both the round-2 emit functions and round-1 shims that forward old call sites onto round-2 event names. |
| `src/trace_tests.rs` | Round-2 test scenarios. Replaces the artifact's `tests/trace_tests.rs`. |
| `src/preprocess_trace.py` | Merges per-thread NDJSON into the `{ "threads": { "<tid>": [...] } }` JSON expected by Trace.tla; also compresses raw nanosecond timestamps to dense integers. |
| `patches/round2_mod_rs.patch` | The diff applied to `artifact/papaya/src/raw/mod.rs` to add new round-2 instrumentation points (`insert_meta_fixup`, `init_table`, `iter_*`) and update the existing `abort_resize`, `try_promote`, `insert_meta`, and `copy_insert` call sites to use the round-2 signatures. |
| `apply.sh` | Resets `tla_trace.rs`, `trace_tests.rs`, and `src/raw/mod.rs` to the round-1 baseline, then re-applies the round-2 patch and copies. Idempotent. |
| `run.sh` | End-to-end: `apply.sh` → `cargo test` per scenario → preprocess → write merged JSON to `.specula-output/traces/<scenario>.ndjson`. |

## Round-2 Event Locations

| Event | File:Line (post-apply) | Trigger |
|---|---|---|
| `init_table` | `raw/mod.rs:` (init() success branch) | Successful CAS of root pointer in `fn init`. |
| `insert_cas` | `raw/mod.rs:` (insert_at success branch ~line 1041) | Winner CAS NULL→entry succeeds. Loser path emits no event. |
| `insert_meta` | `raw/mod.rs:` (~line 1064) | After `meta_entry.store(meta, Release)`. Captures `entry_at_store_null` = (entry pointer is NULL after store) — true on the Family 7 D2-4 bug window. |
| `insert_meta_fixup` | `raw/mod.rs:` (~line 1107) | Loser fixup path, when the EMPTY-check at `if meta_entry.load(Relaxed) == EMPTY` succeeded and stored. |
| `insert_update` | `raw/mod.rs:` (update_at success ~line 1154) | Successful CAS of new value in `fn update_at`. |
| `remove` | `raw/mod.rs:` (update_at success ~line 1152) | Same CAS path with `new_entry == Entry::TOMBSTONE`. Includes the meta tombstone store at lines 906-918. |
| `copy_mark_copying` | `raw/mod.rs:2419, 2658` | `entry.fetch_or(COPYING, AcqRel)` succeeds (blocking and incremental). Mode field hardcoded to "blocking" by the round-1 shim — Trace.tla doesn't validate it. |
| `copy_mark_copying_null` | `raw/mod.rs:2395, 2406, 2634, 2645` | Tombstone null/empty source slot during copy. |
| `copy_insert` | `raw/mod.rs:` (insert_copy success ~line 2745) | `compare_exchange` of dst slot succeeds in `fn insert_copy`. Uses `pending_copy_src` thread-local set by the caller (`copy_at_blocking`, `copy_at_incremental`). |
| `copy_mark_copied` | `raw/mod.rs:2638` | Incremental `entry.store(copied, SeqCst)`. |
| `alloc_next` | `raw/mod.rs:2174` | After `state.next.store(next.raw, Release)` in `get_or_alloc_next`. |
| `try_promote` | `raw/mod.rs:` (try_promote success ~line 2789) | CAS of root succeeds in `fn try_promote`. |
| `abort_resize` | `raw/mod.rs:2274` | `next.state().status.store(ABORTED, SeqCst)`. Captures `parker_used = key_used = src_table` mirroring the buggy unpark target at `state.parker.unpark(&state.status)` (where `state == table.state()`, i.e. the source table). |
| `park` | `raw/mod.rs:2346, 2538` | Before `state.parker.park(...)` in blocking and incremental help-copy. |
| `iter_begin` | `raw/mod.rs:` (after `linearize` in `fn iter` ~line 1422) | After `linearize` returns, captures `snapshot_table`. |
| `iter_yield`, `iter_skip`, `iter_end` | `raw/mod.rs:` (`Iter::next`) | Per-step inside the `Iterator::next` loop. Uses the thread-local `ITER_KEY_FMT` to format the key as a string. Tests must call `set_iter_key_fmt` before iterating. |

## How to make adjustments

### Add a new field to an event

1. Edit the `emit_<event>` function signature in `harness/src/tla_trace.rs`. Add the new parameter and embed it in the JSON format string.
2. Update all call sites that emit that event in `artifact/papaya/src/raw/mod.rs` to pass the new value.
3. Re-generate the patch:
   ```sh
   cd artifact/papaya
   git diff src/raw/mod.rs > ../../.specula-output/harness/patches/round2_mod_rs.patch
   ```
4. Update `harness/INSTRUMENTATION.md` (this file).
5. Re-run `bash harness/run.sh` to regenerate traces.

### Add a new event type

1. Add a new `emit_<event>` function in `harness/src/tla_trace.rs`.
2. Add the event name to `KNOWN_EVENTS` in `harness/src/preprocess_trace.py`.
3. Add a `MatchEvent` arm in `spec/Trace.tla`.
4. Insert the `emit_<event>` call at the appropriate code site in `artifact/papaya/src/raw/mod.rs`.
5. Re-generate the patch and run.

### Move a capture point (before → after or vice versa)

1. Move the `emit_<event>` call in `artifact/papaya/src/raw/mod.rs`.
2. Adjust `start = timestamp_ns()` and the `end` capture to match the new interval.
3. Re-generate the patch.

### Rebuild and re-run

```sh
cd .specula-output && bash harness/run.sh
```

This re-applies the patch, re-runs the four scenarios, and re-emits traces.

## Capture Levels

All round-2 events capture at the **slot-state** level: the slot that the
action operates on (`table`, `slot`, `key`, etc.). Full table-tensor capture
is intentionally *not* used — the Trace.tla validator only consults
slot-local state via post-state checks like `tableEntry'[t][s]`.

For events whose action only modifies global state (`alloc_next`,
`try_promote`, `abort_resize`, `init_table`), the captured fields are
sufficient to validate `nextTable'[t]`, `rootTable'`, `resizeStatus'[at]`.

## Notes

* **Iter key formatting**: `Iter::next` uses a thread-local closure (`ITER_KEY_FMT`) registered by tests. Without it, `iter_yield` emits `key="?"`, which causes Trace.tla's `ValidateIterYield` to fail to match `seenKeys`. Tests covering iter MUST call `papaya::tla_trace::set_iter_key_fmt(...)` after `thread_init()`.
* **Yield window**: `raw/mod.rs:1047` deliberately spins 100 `yield_now()` calls between the winner CAS and the meta store to widen the Family 7 race window. Do NOT remove during validation.
* **Parker routing**: The `abort_resize` event records the buggy parker target (source table id) in both `parker_used` and `key_used`. PR #92's fix would change these to the aborted table id. Trace.tla currently models the buggy upstream-master behavior; if validating the patched fork, swap the buggy `AbortResize` body in `base.tla`.

## Coverage Notes (current scenarios)

The four scenarios produce **15/18** spec event types. The events not yet exercised in any trace are:

| Event | Why not yet exercised |
|---|---|
| `abort_resize` | Requires the next-table allocation to fail (full or OOM). Our scenarios don't push hard enough; consider a stress scenario that fills tables until allocation fails. |
| `copy_mark_copied` | Incremental-mode only and fires after a successful entry copy with the SeqCst store. The current incremental scenario stays in capacity 2 with just 2 keys; doesn't trigger a full copy. |
| `park` | Requires a thread to lose the resize race AND spin past `SPIN_WAIT` before parking. Brief tests rarely linger long enough; a longer-running blocking-mode scenario would help. |

These events should be addressed in Phase 3 if the validation pipeline reveals gaps. To add a scenario, copy the pattern of `trace_blocking_resize_parkers` and increase contention (more threads, more keys, longer loops).

## Validation Quick-Reference

The current Trace.cfg uses string thread/key/value identifiers (`"t1"`, `"k1"`, ...) and integer slot indices (0..3) to match the JSON-deserialized trace format. If you change the trace's slot indexing, you must update `Slot` in Trace.cfg accordingly.

## Trace Output Format

Each scenario produces one merged JSON file at
`.specula-output/traces/<scenario>.ndjson`:

```json
{
  "threads": {
    "t1": [
      {"event":"init_table","start":1,"end":2,"table":1,"capacity":2},
      {"event":"insert_cas","start":3,"end":4,"table":1,"slot":0,"key":"k1","value":"v1","pre_meta":"META_EMPTY","pre_entry":0},
      ...
    ],
    "t2": [...],
    "t3": [...]
  }
}
```

Timestamps are dense integers (1..N) preserving the partial order of the raw
nanosecond rdtsc-equivalent clock.
