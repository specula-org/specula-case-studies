# Trace Harness — left-right (Round 2)

This harness records per-thread NDJSON trace events from real `left-right`
executions and merges them into Trace.tla-consumable JSON.  System category:
**B (Concurrent / Lock-Free)** — uses `[start, end]` timebox intervals so
TLC can search viable interleavings via `ViablePIDs`.

## Layout

```
harness/
  apply.sh              # copies instrumented files into artifact (idempotent)
  run.sh                # end-to-end: apply, build, run scenarios, preprocess
  preprocess.py         # merges per-thread NDJSON -> { threads: { tid: [...] } }
  src/
    lib.rs              # +pub mod tla_trace
    read.rs             # +emit_reader_enter / _none / _nested
    read/guard.rs       # +emit_reader_exit
    write.rs            # +emit_writer_append / _publish / _try_publish_* / _take_inner
    tla_trace.rs        # NEW: per-thread NDJSON trace module
    trace_tests.rs      # NEW: 4 scenarios (-> tests/trace_tests.rs)
  INSTRUMENTATION.md    # this file

../traces/
  sequential.ndjson           # writer-only, ends with NULL pointer
  slow_reader_overlap.ndjson  # r1 holds long, r2 spins; many overlapping intervals
  nested_enters.ndjson        # nested enter/exit on r1
  try_publish.ndjson          # try_publish success + fail paths
  raw/<scenario>/trace-thread-<tid>.ndjson   # per-thread raw output
```

## Reproduce

```bash
cd .specula-output && bash harness/run.sh
```

End-to-end: copies files into `artifact/left-right/`, builds tests,
runs each scenario, merges per-thread files, writes one `traces/<name>.ndjson`
per scenario.  Each scenario is wrapped in `timeout 60` so a deadlocked
test cannot hang the run.

## Trace event schema

Every line that gets consumed by `Trace.tla`:

```json
{"tag":"trace","event":"<Name>","tid":"<r1|r2|writer>",
 "start":<ns>, "end":<ns>, "state": {<event-specific fields>}}
```

The preprocessor strips the `tag` envelope and groups events into
`{threads: {tid: [...]}}` for the spec to load via `JsonDeserialize`.

| Event | tid | State fields | Source location |
|-------|-----|--------------|-----------------|
| `ReaderEnter` | r1, r2 | `epoch`, `enters`, `pointer` | `read.rs:177-205` (fresh, non-NULL) |
| `ReaderEnterNone` | r1, r2 | `epoch` | `read.rs:206-213` (fresh, NULL) |
| `ReaderEnterNested` | r1, r2 | `enters`, `pointer` | `read.rs:120-148` (nested, non-NULL) |
| `ReaderExit` | r1, r2 | `epoch`, `enters` | `read/guard.rs:117-130` |
| `WriterAppend` | writer | `first`, `second` | `write.rs:497-506` |
| `WriterPublish` | writer | `pointer`, `first`, `second` | `write.rs:370-391` |
| `WriterTryPublishOk` | writer | `pointer`, `first`, `second` | `write.rs:354-359` |
| `WriterTryPublishFail` | writer | `pointer`, `first`, `second` | `write.rs:342-348` |
| `WriterTakeInner` | writer | `pointer="null"`, `first`, `taken` | `write.rs:198-204` |

State fields are captured **after** the operation completes, **outside** the
`[start, end]` interval (so the interval stays tight).  See instrumentation
spec §1 for the complete mapping.

## Adjusting instrumentation

### Add a field to an existing event

1. Update the `emit_<event>` signature in
   `harness/src/tla_trace.rs` (NOT the artifact copy — apply.sh overwrites).
2. Update the `format!` literal in the same function to include the field.
3. Update every call site in `harness/src/{read,read/guard,write}.rs`
   to pass the new value (typically read from `self` after the operation).
4. Update the spec's `Validate*` helpers in `Trace.tla` to read the new
   field (`logline.state.<field>`).
5. Rerun: `bash harness/run.sh && run_trace_validation(...)`.

### Add a new event type

1. Add a new `emit_<event>` function in `harness/src/tla_trace.rs`
   following the existing pattern (check `is_active() && !is_suppressed()`,
   then `format!` + `emit_raw`).
2. Insert a call at the desired trigger point in the source file.  Pattern:
   ```rust
   let __tla_start = crate::tla_trace::now_ns();
   /* the operation */
   let __tla_end = crate::tla_trace::now_ns();
   crate::tla_trace::emit_<event>(__tla_start, __tla_end, /* state */);
   ```
3. Add a `Trace<Event>` action in `Trace.tla` mirroring the spec semantics.
4. Add a clause to `MatchEvent`:
   `\/ /\ logline.event = "<Name>" /\ Trace<Event>(tid, logline)`.
5. Rerun.

### Move a capture point (before -> after, or vice versa)

Just move the `now_ns()` call and any state reads.  The state captured must
match what `Trace.tla`'s `Validate*` helpers compare against (post-state for
the existing schema).

### Suppression

`SuppressGuard` (RAII) at `tla_trace.rs:101-122` bumps a thread-local depth
counter.  Used in two places:
- `WriteHandle::append` → suppresses `enter`/`exit` from the internal
  first-mode `extend()` path (`write.rs:500-502`).
- `WriteHandle::take_inner` → suppresses internal `publish()` calls
  (`write.rs:159`).

Note: `emit_writer_take_inner` does NOT honor `is_suppressed()` (defense in
depth — the take_inner event must always surface).

### Pointer naming

`set_pointer_mapping(l_addr, r_addr)` is called once per scenario in
`trace_tests.rs::install_pointers`, after constructing
`(WriteHandle, ReadHandle)`:
- `l_addr = r._tla_trace_inner_addr()` — initial `inner_ptr`
- `r_addr = w._tla_trace_w_handle_addr()` — initial `writerCopy`

This matches `base!Init` (`inner_ptr = "L"`, `writerCopy = "R"`).
After publish, the pointer values rotate but the L/R names stay pinned to
the original allocations, mirroring the spec's `OtherCopy` semantics.

### Thread naming

Each thread MUST call `tla_trace::set_thread_name("<r1|r2|writer>")` before
its first emission.  The names must match `Reader = {"r1","r2"}` from
`Trace.cfg` — without this, `MapReader(tid)` returns a value not in
`Reader` and the spec deadlocks.

## Run subset of scenarios

```bash
cd artifact/left-right
LEFTRIGHT_TRACE_BASE=/tmp/lr cargo test --test trace_tests \
  -- --exact trace_slow_reader_overlap --nocapture
python3 ../../.specula-output/harness/preprocess.py \
  /tmp/lr/slow_reader_overlap /tmp/slow_reader_overlap.ndjson
```

## Validation

Run from `.specula-output/`:

```bash
# via the MCP debugger:
run_trace_validation(spec_file="Trace.tla", config_file="Trace.cfg",
                     trace_file="../traces/sequential.ndjson",
                     work_dir="spec/")
```

All four scenarios pass at harness-generation time:
- `sequential` — 11 states
- `slow_reader_overlap` — 79 states (real cross-thread overlap)
- `nested_enters` — 18 states
- `try_publish` — 29 states

## Known constraints

- `ReaderEnterNested` only emits on the non-NULL branch.  The NULL branch
  panics at `read.rs:146` (F2 bug family) and never reaches the trace flush.
  The spec's `TraceReaderEnterNested` therefore models only the non-NULL case.
- `WriterPublish` and `WriterTakeInner` are bundled events — the timebox
  `[start, end]` covers all sub-actions (lock + wait + apply + swap + fence
  + per-reader snap + (for take_inner) NULL swap + drops).  The spec's
  `Trace<Event>` action validates the post-state of the bundle; sub-action
  granularity bug hunting lives in `MC.tla`, not here.
- `WriterTryPublishOk` shares the post-state shape of `WriterPublish` and
  uses the same spec action.
- `enters` field is intentionally OMITTED from `ReaderEnterNone` (and `epoch`
  from `ReaderEnterNested`) — see comments at `tla_trace.rs:204-237` for why
  (TLC evaluates conjuncts in order; emitting an UNCHANGED variable would
  force the validator to compare against `enters'`/`epoch'` before the
  UNCHANGED clause has constrained them).
