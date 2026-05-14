# Instrumentation Guide — crossbeam-skiplist trace harness

This guide is for the Phase 3 (validation) agent who needs to adjust the
trace instrumentation when validation reveals format or schema mismatches.
For the conceptual mapping (action ↔ code ↔ event), see
`spec/instrumentation-spec.md` (the upstream contract). This document is
limited to *operational* details: where the code lives, how to change it,
and how to rebuild.

## TL;DR

Run from `.specula-output/`:

```sh
bash harness/run.sh             # apply, build, run scenarios, merge traces
```

That populates `traces/<scenario>.ndjson` (one merged JSON file per scenario).
A single trace can be re-validated with:

```sh
java -DJSON=../traces/scenario_single_thread_basic.ndjson \
     -jar tla2tools.jar -config Trace.cfg Trace.tla -deadlock
```

(or via the trace-debugger MCP tool).

## Layout

```
.specula-output/
├── harness/
│   ├── INSTRUMENTATION.md   ← this file
│   ├── apply.sh             ← copies harness sources into the artifact
│   ├── run.sh               ← end-to-end driver
│   ├── preprocess_trace.py  ← merges per-thread NDJSON, compresses TS
│   └── src/
│       ├── tla_trace.rs       ← trace-emit module (canonical copy)
│       └── tla_scenarios.rs   ← test scenarios (canonical copy)
└── artifact/crossbeam/crossbeam-skiplist/
    ├── Cargo.toml             ← declares feature `tla-trace` (already wired)
    ├── src/lib.rs             ← `pub mod tla_trace;` under cfg
    ├── src/tla_trace.rs       ← (overwritten by apply.sh)
    ├── src/base.rs            ← #[cfg(feature="tla-trace")] emit calls
    └── tests/tla_scenarios.rs ← (overwritten by apply.sh)
```

The artifact tree already contains the instrumentation — `apply.sh` only
overwrites `tla_trace.rs` and `tla_scenarios.rs` with the canonical copies
in `harness/src/`. `base.rs` itself is *not* templated; treat changes to
`base.rs` as direct artifact edits and re-run `run.sh` (which calls
`apply.sh` first, so any drift between `harness/src/` and the artifact
gets resynced).

## Trace event schema (recap)

All events use the **timebox NDJSON envelope**:

```json
{"tag":"trace","event":"<EventName>","thread":"t<N>","start":<rdtsc>,"end":<rdtsc>,
 "state":{...captured fields...}, ...event-specific fields...}
```

`tag:"trace"` is mandatory (Trace.tla filters on it).
`thread` is `"t1"`, `"t2"`, ... — assigned by `tla_trace::tid()` on first
touch per OS thread. The preprocessor maps raw thread IDs to the slots
declared in `Trace.cfg`'s `Thread = {"t1","t2","t3"}`.

State fields captured (see also `spec/instrumentation-spec.md` §1):

- `len` ← `self.hot_data.len.load(Relaxed)`
- `refcount` ← `n.refs_and_height.load(Relaxed) >> HEIGHT_BITS`
- `marked0` ← `n.is_removed()` / level-0 ptr tag

## Where the emits are

All emit calls in `src/base.rs` are gated `#[cfg(feature = "tla-trace")]`
so production builds compile them out.

| Event | base.rs line | Notes |
|---|---|---|
| `Insert_Begin` | 1041–1051 | `__t_begin_start = read_tsc()` then emit after `search_position` |
| `Insert_AllocCASLevel0` | 1094–1121 | Inside the win-branch of the CAS |
| `Insert_MarkOld` | 1124–1144 (won) and 1145–1161 (no-op when found = NULL) | Both paths emit |
| `Insert_BuildLevel` | 1216–1240 (early break), 1287–1305 (installed), 1327–1342 (completed terminator) | `result` field discriminates |
| `Insert_PostBuildCheck` | 1353–1364 | After top-level pointer load |
| `Insert_Done` | tla_scenarios.rs `traced_insert` | Test-side emit (see "Why some events live in the test wrapper") |
| `Get` | tla_scenarios.rs `traced_get` | Test-side emit |
| `Remove_Begin` | 1421–1440 | After `search_position` |
| `Remove_Acquire` | 1446–1469 | Both branches emit |
| `Remove_MarkTower` | 1472–1496 (won) and 1582–1602 (lost) | Both branches emit |
| `Remove_UnlinkLevel` | 1501–1538 (success), 1540–1555 (failure), 1561–1580 (terminator) | Three emit sites in the unlink loop |
| `Remove_Done` | tla_scenarios.rs `traced_remove` | Test-side emit |
| `Iter_Begin`, `Iter_Next`, `Iter_Drop` | tla_scenarios.rs `traced_ref_iter_all` | All test-side; loop drives the iteration |

### Why some events live in the test wrapper

`Insert_Done`, `Remove_Done`, `Get`, `Iter_*` are emitted from
`tla_scenarios.rs`, not `base.rs`, because:

1. **Typed key/value access**: `insert_internal` and `get` are generic over
   `K: Ord, V`. To emit the typed key in `Insert_Begin`/`Remove_Begin` we
   need to bridge through `tla_trace::set_current_op(k, v)` from the test,
   which is called *just before* the operation. The terminating events
   (`*_Done`, `Get`) happen on the test's side after the operation, so it's
   simplest to emit them there.
2. **Iterator lifecycle**: forward/back direction, lifetime of `Iter` /
   `Range` / `RefIter`, `Drop` semantics — all driven by the test. The
   spec-side `Iter_Begin / Iter_Next / Iter_Drop` are simple wrappers.

If a Phase 3 fix needs `Get` or `Insert_Done` emitted *inside* `base.rs`
(e.g. to pick up state under a tighter lock), feel free to copy the
`#[cfg(feature = "tla-trace")] {...}` block from a sibling event into the
right place. Mind the `'static` lifetime on `&str` literals.

## Common adjustments

### Adding a state field to an existing event

1. Edit `harness/src/tla_trace.rs` — modify the `emit_<event>` function
   signature and the JSON output.
2. Edit `src/base.rs` — pass the new value to the emit call. State reads
   should use `Ordering::Relaxed` (we don't want trace probes to alter
   memory-ordering observability).
3. Edit `harness/src/tla_scenarios.rs` if the call site is test-side.
4. Re-run `run.sh`.

### Renaming an event

1. Edit `harness/src/tla_trace.rs` — change the `envelope_open(buf, "<NewName>", ...)` literal.
2. Update the corresponding `MatchEvent` branch in `spec/Trace.tla`
   (`logline.event = "<NewName>"`).

### Adding a new event type

1. Add `pub fn emit_<name>(...)` to `harness/src/tla_trace.rs`. Use the
   existing helpers as a template (`envelope_open` then a single
   `write!` for the trailer).
2. Insert the call site in `src/base.rs` or a test wrapper.
3. Add a `TraceXxx` wrapper to `spec/Trace.tla` and a disjunct in
   `MatchEvent`.

### Moving capture point (before → after, etc.)

The state-capture timing matters: `instrumentation-spec.md` §3 says
"every event captures `state.*` AFTER the operation's mutation." If you
need to flip this for a specific event (e.g. capture `len` BEFORE rather
than AFTER `len.fetch_add`), update *both* the emit site and the validator
in `Trace.tla` (`ValidateLen` reads `lenCounter'`, the post-state).
Mismatch causes off-by-one validation failures.

### Tightening or widening the rdtsc interval

Each emit site reads `let __t_xxx_start = tt::read_tsc()` before the
critical op and `let end = tt::read_tsc()` after. To **tighten** an
interval: move `__t_xxx_start` closer to the actual atomic op (skip
preludes like search). To **widen**: move it earlier. A wider interval
allows TLC more concurrency search; a tighter one prunes faster. See
`references/concurrent-timebox-guide.md` "Tightening Intervals with
Refinement".

## Building / running

```sh
# In .specula-output/:
bash harness/run.sh
```

Or step-by-step:

```sh
cd .specula-output
bash harness/apply.sh        # idempotent — installs harness sources

cd ../artifact/crossbeam/crossbeam-skiplist
cargo build --features tla-trace
CROSSBEAM_SKIPLIST_TRACE_DIR=/tmp/cs_trace cargo test --features tla-trace \
    --test tla_scenarios -- scenario_single_thread_basic --test-threads=1

cd -
python3 harness/preprocess_trace.py /tmp/cs_trace traces/single.ndjson
```

The `tla-trace` feature is OFF by default, so production builds get zero
trace overhead.

## Trace.tla notes (gotchas)

The trace spec lives at `spec/Trace.tla`. A few non-obvious tweaks were
needed during harness bring-up; if validation regresses these are likely
suspects:

1. **Height is non-deterministic in the spec**: `Insert_AllocCASLevel0`
   uses `\E hChoice \in 1..MaxHeight`. The trace event carries the
   actual height, and `TraceInsert_AllocCASLevel0` pins
   `pc'[tid].h = logline.height` so TLC doesn't fork on height choices
   that the trace can't satisfy. If you add a new height-recorded
   event, follow this pattern.
2. **`Remove_Begin`'s `unlinkAt` matches actual node height**: in
   `base.tla`, `unlinkAt |-> nHeight[nopt] - 1` (NOT `MaxHeight - 1`),
   matching the implementation's `0..n.height()` loop range. Reverting
   to `MaxHeight - 1` causes deadlocks because the spec walks levels
   that the impl never iterates (no trace events for them).
3. **`TraceRemove_UnlinkLevel` does NOT validate the `level` field**:
   the impl emits a "terminator" Remove_UnlinkLevel event (after the
   loop) carrying `level=0`, while the spec's terminator transition is
   `lvl < 0 → step→Done`. Making the wrapper validate `pc[tid].unlinkAt
   = logline.level` would cause the terminator event to mismatch.

## Quick health checks

After a run, confirm:

```sh
# every scenario produced events
ls -la traces/*.ndjson

# no JSON parse errors
for f in traces/*.ndjson; do python3 -c "import json; json.load(open('$f'))" && echo "$f OK"; done

# all expected event types present
python3 -c "
import json, glob
seen = set()
for f in glob.glob('traces/*.ndjson'):
    d = json.load(open(f))
    for tid, evs in d.items():
        if tid == 'meta': continue
        for e in evs: seen.add(e['event'])
print(sorted(seen))
"
# Should include at minimum: Insert_Begin, Insert_AllocCASLevel0, Insert_MarkOld,
# Insert_BuildLevel, Insert_PostBuildCheck, Insert_Done, Get, Remove_Begin,
# Remove_Acquire, Remove_MarkTower, Remove_UnlinkLevel, Remove_Done,
# Iter_Begin, Iter_Next, Iter_Drop
```

## Known limitations

- **No `Iter_NextBack` events yet**: the test scenarios use forward iteration
  only. To exercise the back-iterator code path (and the F1 rewind bug
  family), add a scenario that calls `Iter::next_back()` / `Range::next_back()`
  and emits `Iter_NextBack` events. The trace module's `emit_iter_next` is
  reused for both directions if you pass an explicit `event` field; or add
  a dedicated `emit_iter_next_back` (preferred — keeps wrappers symmetric).
- **No `PopFront` events**: `pop_front` exists on the spec side but is not
  exercised by current scenarios. Add `traced_pop_front` to
  `tla_scenarios.rs` and emit a single `PopFront` event at the test site.
- **Cross-thread interval overlap is low**: operations are nanosecond-scale,
  so even with concurrent threads `[start,end]` intervals rarely overlap
  in real time. The timebox `ViablePIDs` constraint still works (it just
  finds a unique linearization), but the search space stays small. To
  exercise more interleavings, add scenarios with longer hot loops or
  many threads.
