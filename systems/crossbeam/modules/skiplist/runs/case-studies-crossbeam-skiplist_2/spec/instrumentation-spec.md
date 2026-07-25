# Instrumentation Spec — crossbeam-skiplist

This document maps TLA+ spec actions to source code locations and trace event
fields. It is the single source of truth used by the harness-generation phase.

The implementation already ships a `tla-trace` cargo feature
(`artifact/crossbeam/crossbeam-skiplist/src/tla_trace.rs`, 518 LOC) that emits
NDJSON traces matching the schema below. The instrumentation in `base.rs` is
gated on `#[cfg(feature = "tla-trace")]` so production builds incur zero cost.

## 1. Trace Event Schema

### Envelope

Every event is a single JSON object on its own line (NDJSON):

```json
{
  "tag": "trace",
  "event": "<EventName>",
  "thread": "t<N>",
  "start": <rdtsc_at_start>,
  "end":   <rdtsc_at_end>,
  "state": { ...captured state... },
  ...event-specific fields...
}
```

- `tag` is always `"trace"` (filter-safe constant).
- `thread` is a sequential per-process id (tla_trace.rs:65-74).
- `start`/`end` are rdtsc readings (x86_64) or ns timestamps elsewhere
  (tla_trace.rs:93-110). The Trace.tla spec uses `[start, end]` for the
  ViablePIDs partial-order constraint.
- `state` carries fields captured at the trigger point (post-action).

### State fields (captured per event when relevant)

| Field | TLA+ variable | Captured by |
|---|---|---|
| `len` | `lenCounter` | `self.hot_data.len.load(Ordering::Relaxed)` (base.rs:519-525) |
| `refcount` | `nRefcount[node]` | `n.refs_and_height.load(Relaxed) >> HEIGHT_BITS` (base.rs:213) |
| `marked0` | `nMark[node][0]` | `n.is_removed()` / `tag()==1` on level-0 ptr (base.rs:355-364) |

### Per-event fields

- `node` — stable node id (tla_trace.rs:115-133, mapped from raw pointer).
- `key`, `value` — typed primitive (set via `tt::set_current_op` from harness).
- `level` — tower level integer.
- `height` — tower height of the inserted/removed node.
- `mark_won` — boolean from `mark_tower()` (base.rs:330-351).
- `top_level_marked` — boolean from `n.tower[h-1].tag()==1` (base.rs:1356).
- `result` — `"some"` / `"none"`.
- `cas_ok` — boolean: did the CAS in this UnlinkLevel iter succeed?
- `iter_kind` — `"iter"` or `"range"`.
- `iter_id` — sequential id (tla_trace.rs:151-156).
- `prev_state` — string indicating prior iter state (`"Fresh"`, `"Yielded"`, etc).

## 2. Action-to-Code Mapping

Every spec action gets exactly one trace event type; every trace event
maps to exactly one spec action. The boundary lines below quote the
implementation's exact source lines for the trigger point.

### Insert lifecycle (`fn insert_internal`, base.rs:1018-1370)

| Spec action | Code location | Trigger point | Trace event | Fields |
|---|---|---|---|---|
| `Insert_Begin` | base.rs:1042-1052 | After `search_position` returns; before any state mutation | `Insert_Begin` | `state.len`, `key`, `value`, `found_node` |
| `Insert_AllocCASLevel0` | base.rs:1095-1121 (the `if … compare_exchange(…).is_ok() {` win branch) | Immediately after the level-0 CAS succeeds | `Insert_AllocCASLevel0` | `state.len`, `state.refcount`, `node`, `height` |
| `Insert_MarkOld` | base.rs:1125-1144 (inside the mark_tower(old) block) and 1145-1161 (no-op when found=NULL) | After `r.mark_tower()` returns (or immediately when found = NULL) | `Insert_MarkOld` | `state.len`, `state.marked0`, `node`, `mark_won` |
| `Insert_BuildLevel(L)` | base.rs:1207-1322 (`'build:` loop body) | Each iteration: emit on early-break (1239) and on successful install (1290-1305); also a "completed" terminator (1335-1342) | `Insert_BuildLevel` | `state.refcount`, `node`, `level`, `result` ∈ {"early_break", "installed", "completed"} |
| `Insert_PostBuildCheck` | base.rs:1355-1359 | After loading top-level pointer's tag (and after the optional `search_bound` call) | `Insert_PostBuildCheck` | `node`, `top_level_marked` |
| `Insert_Done` | After `insert_internal` returns and the harness drops the returned `RefEntry` | Test wrapper hook (after `release(&guard)`) | `Insert_Done` | `state.refcount`, `node` |

### Get (`fn get`, base.rs:572-590)

| Spec action | Code location | Trigger point | Trace event | Fields |
|---|---|---|---|---|
| `Get` | base.rs:572-590 | Test wrapper around the call (the trace event is emitted from the harness, not inside `get`, because the typed-key/value setup happens there) | `Get` | `state.len`, `key`, `result`, `node` |

### Remove (`fn remove`, base.rs:1406-1607)

| Spec action | Code location | Trigger point | Trace event | Fields |
|---|---|---|---|---|
| `Remove_Begin` | base.rs:1422-1440 | After `search_position` returns; before `try_acquire` | `Remove_Begin` | `state.len`, `key`, `target_node` |
| `Remove_Acquire` | base.rs:1448-1469 | After `try_acquire` returns (both branches) | `Remove_Acquire` | `state.refcount`, `node`, `acquired` |
| `Remove_MarkTower` | base.rs:1474-1496 (mark_won) and 1582-1602 (mark_lost) | After `n.mark_tower()` returns | `Remove_MarkTower` | `state.len`, `state.refcount`, `state.marked0`, `node`, `mark_won` |
| `Remove_UnlinkLevel(L)` | base.rs:1503-1560 (per-level `for level in (0..n.height()).rev()`) and the terminator at 1561-1580 | Each iteration: emit on CAS success (1521-1538) and CAS failure (1540-1555) | `Remove_UnlinkLevel` | `state.refcount`, `node`, `level`, `cas_ok` |
| `Remove_Done` | After remove returns and harness releases the entry | Test wrapper hook | `Remove_Done` | `state.refcount`, `node`, `result` |

### Iterator (`Iter::next`, `Iter::next_back`, etc.)

| Spec action | Code location | Trigger point | Trace event | Fields |
|---|---|---|---|---|
| `Iter_Begin` | `iter()` / `range()` factories (base.rs:654-693) | Test wrapper sets `iter_kind` and `iter_id` then emits before first `next()` call | `Iter_Begin` | `iter_kind`, `iter_id` |
| `Iter_Next` | `Iter::next` (base.rs:2098-2120); also `Range::next` (base.rs:2287-2320) | After the `match self.head` and the cross-over check; before returning the entry | `Iter_Next` | `state.refcount` (if RefIter), `iter_id`, `node`, `result`, `prev_state` |
| `Iter_NextBack` | `Iter::next_back` (base.rs:2126-2147); `Range::next_back` (base.rs:2329-2361) | Same shape as `Iter_Next` but for the reverse direction | `Iter_NextBack` | same as `Iter_Next` |
| `Iter_Drop` | `RefIter::drop_impl` (base.rs:2253-2261); `Iter` Drop is implicit (no refs to release) | After both `head.take()` and `tail.take()` decrement | `Iter_Drop` | `iter_id`, `head_decremented`, `tail_decremented`, `head_refcount`, `tail_refcount` |

### PopFront (`fn pop_front`, base.rs:1610-1622)

PopFront is a thin loop around `front + pin + remove`; we model it as a
single spec action. The harness emits one `PopFront` event at the call
site (typed-key context unavailable because pop_front discovers the key
during iteration). The instrumentation should still emit the
underlying `Remove_*` events when the inner remove fires.

| Spec action | Code location | Trigger point | Trace event | Fields |
|---|---|---|---|---|
| `PopFront` | Test wrapper around the call | After `pop_front` returns | `PopFront` | `state.len`, `result`, `node` |

## 3. Special Considerations

### State capture timing

Every event captures `state.*` AFTER the operation's mutation. The Trace.tla
validators (`ValidateLen`, `ValidateRefcount`, `ValidateMark`) call `lenCounter'`,
`nRefcount'`, etc. — primed (post-action) values.

### Pointer→NodeId mapping

The harness maintains a global `usize → u64` map (tla_trace.rs:115-133) so
that pointer addresses are stable across events. Test scenarios use small
totals so the map fits in a few hundred entries.

### Typed key/value bridging

`base.rs::insert_internal` is generic over `K`, `V`. The harness sets a
thread-local `CUR_KEY` / `CUR_VALUE` (tla_trace.rs:138-148) BEFORE calling
each operation, so the generic body can include the typed primitive in
`Insert_Begin` and `Insert_MarkOld` events without requiring `K: Display`
bounds.

### Race against tracing

The trace emitter (`tla_trace::write_line`) takes a per-thread BufWriter
(tla_trace.rs:175-187). State reads are `Ordering::Relaxed`. The
captured value reflects a non-deterministic moment within the
`[start, end]` interval — Trace.tla's ViablePIDs constraint accommodates
this by searching for an interleaving where the captured value is
consistent with at least one feasible global ordering of the events.

### Bootstrap state

`TraceInit == Init /\ pcCursor = [tid \in TraceThreads |-> 1]`. The
implementation's `SkipList::new` (base.rs:484-500) creates an empty list;
this matches our `Init` exactly.

### Concurrent thread coverage

Trace.cfg sets `Thread = {"t1", "t2", "t3"}`. The preprocessor maps each
thread's NDJSON file to the appropriate slot. Threads with no events
should still appear as empty arrays so DOMAIN traces is consistent.

### Iter / Range distinction

Both `Iter` and `Range` produce identical event shapes because both have
the same code structure (cross-over reset + None-arm rewind). The
`iter_kind` field on `Iter_Begin` distinguishes them; subsequent
`Iter_Next` / `Iter_NextBack` events for that iterator inherit the kind
implicitly via `iter_id`.

### Suppressed events

- `Insert_Done` and `Remove_Done`: emitted from the test wrapper, not
  from `insert_internal` / `remove`, because the typed-context handle
  release happens outside the trace-instrumented core.
- `HelpUnlink`: NOT emitted as a separate event. The base.rs:759-786
  call site is on the search/next-node path, which is not a primary spec
  action; the spec exposes HelpUnlink as a free background action that
  Trace.tla disables during replay (silent action would pre-empt the
  proper level-CAS event).
- `EpochFinalize`: NOT emitted (epoch GC is internal to crossbeam-epoch
  and asynchronous to the calling thread). Trace.tla allows it as a
  silent action so the spec's reclamation can happen between traced
  events.
