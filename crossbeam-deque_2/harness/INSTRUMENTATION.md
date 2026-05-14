# crossbeam-deque trace harness — INSTRUMENTATION

Phase 2.5 trace harness for the `crossbeam-deque_2` case study.

This document is the operating manual for the Phase 3 spec-validation agent:
how the harness is wired, what each event captures, and how to adjust the
instrumentation if validation reveals an issue.

---

## Layout

```
.specula-output/harness/
├── apply.sh                  # Re-apply instrumentation to artifact
├── run.sh                    # apply + cargo build + run scenarios + preprocess
├── instrument.py             # Source-patch script (called by apply.sh)
├── preprocess_trace.py       # Per-thread NDJSON → single JSON for TLC
├── INSTRUMENTATION.md        # this file
└── src/
    ├── tla_trace.rs          # Trace emission module (copied to crate src/)
    └── trace_scenarios.rs    # Test scenarios (copied to crate tests/)

artifact/crossbeam/crossbeam-deque/
├── src/
│   ├── lib.rs                # Modified: `pub mod tla_trace;` added
│   ├── tla_trace.rs          # Copied from harness/src/
│   └── deque.rs              # Patched: trace_emit calls inserted
└── tests/
    └── trace_scenarios.rs    # Copied from harness/src/
```

`apply.sh` is **idempotent**: it `git checkout`-s the modified files first,
then re-copies and re-patches. Safe to rerun any time.

---

## Build / run

One-shot end-to-end:

```bash
bash .specula-output/harness/run.sh
```

This produces:

```
.specula-output/traces/
├── fifo_short.json            # merged + timestamp-compressed JSON for TLC
├── fifo_short.ndjson          # raw per-thread events for human inspection
├── fifo_two_stealers.json
├── fifo_two_stealers.ndjson
├── lifo_three_stealers.json
└── lifo_three_stealers.ndjson
```

Validate one against the spec:

```bash
cd .specula-output/spec
java -cp /home/ubuntu/Specula/lib/tla2tools.jar:/home/ubuntu/Specula/lib/CommunityModules-deps.jar \
     -DTLA-Library=/home/ubuntu/Specula/lib \
     -DJSON=../traces/fifo_short.json \
     tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
```

Or via the MCP tool:

```
run_trace_validation(spec_file="Trace.tla", config_file="Trace.cfg",
                     trace_file=".../traces/fifo_short.json",
                     work_dir=".../.specula-output/spec/")
```

All three traces pass `Trace.cfg` validation (invariants + `TraceMatched`).

---

## Event schema

Every emitted line is NDJSON with `"tag": "trace"`. After `preprocess_trace.py`
merges per-thread files, the consumed JSON looks like:

```json
{
  "flavor": "FIFO",
  "worker": [event, event, ...],
  "s1": [event, ...],
  "s2": [event, ...]
}
```

Common envelope on every event:

```json
{
  "event": "<ActionName>",
  "start": <int>,             // compressed rdtsc start
  "end":   <int>,             // compressed rdtsc end
  "state": {
    "front":    <int>,
    "back":     <int>,
    "bufferID": <int>         // 0 means "not validated for this event"
  },
  ... action-specific fields ...
}
```

State is captured **after** the operation (outside the rdtsc interval) by
loading `inner.front` (SeqCst), `inner.back` (Relaxed), and translating
`buffer.ptr` → dense `bufferID` via `tla_trace::buf_id`.

---

## Instrumentation points (artifact/crossbeam/crossbeam-deque/src/deque.rs)

After `apply.sh`, line numbers shift. The patch is anchored on the original
source strings — see `harness/instrument.py` for the exact anchors.

| Spec action            | Code site (post-patch)         | Notes                                                                                  |
|------------------------|--------------------------------|----------------------------------------------------------------------------------------|
| `PushWriteSlot`        | `Worker::push`, after `buffer.write`         | Phase 1 of the push protocol. `val` field captures the written value (best-effort). |
| `PushStoreBack`        | `Worker::push`, after `back.store(b+1, …)`   | Phase 2 — the visibility handshake.                                                     |
| `LIFOPopDecrFence`     | `Worker::pop` LIFO, after `back.store(b-1)` + SeqCst fence + `f = front.load` | Wraps the Dekker-style decision. |
| `LIFOPopDecide`        | `Worker::pop` LIFO, end of each branch       | `result` ∈ `{"empty","last_cas_success","last_cas_fail","multi_pop"}`.                |
| `FIFOPopAttempt`       | `Worker::pop` FIFO, after `front.fetch_add`  | `result` ∈ `{"success","rollback_needed"}`.                                            |
| `FIFOPopRollback`      | `Worker::pop` FIFO, after `front.store(f, Relaxed)` | Only on the empty-after-fetch_add path.                                          |
| `ResizeGrow`           | `Worker::resize`, after `inner.buffer.swap`  | `oldBufferID` captures the retired generation. **Not exercised** by current tests.    |
| `StealLoadFront_Single`| `Stealer::steal`, after `front.load(Acquire)`| 1st of 6 events per single-steal. State.bufferID = 0 (not yet loaded).                |
| `StealPin`             | `Stealer::steal`, after `epoch::pin()`       | `wasReentrant` records whether `epoch::is_pinned()` was true on entry.                |
| `StealLoadBack`        | `Stealer::steal`, after `back.load(Acquire)` | `cachedBack` captured. `result` ∈ `{"empty","proceed"}`. On `empty` the steal returns. |
| `StealLoadBuffer`      | `Stealer::steal`, after `buffer.load(Acquire, guard)` | `cachedBuf` is the Buffer pointer ID. After this, state.bufferID is meaningful. |
| `StealReadSlot`        | `Stealer::steal`, after `buffer.deref().read(f)` | `readVal` is a u64 view of the read task; `readFromBuf = cachedBuf`.              |
| `StealRecheckCAS`      | `Stealer::steal`, after the buffer-recheck + CAS | `site` ∈ `{"single","batchFIFO","batchLIFOFirst","batchLIFOLoop"}`. `recheckResult` ∈ `{"present_pass","present_fail","absent"}`. `casResult` ∈ `{"success","fail_cas","skip_due_to_recheck"}`. `stolenCount` is what the CAS committed. |

**Not yet instrumented** (test scenarios don't exercise them, so leaving
them stubbed avoids unused-code warnings):

- `StealLoadFront_BatchFifo` / `StealLoadFront_BatchLifo` — `Stealer::steal_batch_with_limit_and_pop` (LIFO loop) and `Stealer::steal_batch_with_limit` (FIFO).
- `StealLIFOBatchIter` — per-iteration of the LIFO batch loop.
- `StealerCloneAdv` / `WorkerDropAdv` — Family C caller misuse.

If Phase 3 needs these, add new emit functions in `tla_trace.rs` and add
new patch blocks in `instrument.py` for each call site listed in
`spec/instrumentation-spec.md` § 2.

---

## Notes & gotchas (read these if validation fails)

### 1. Spec edits this run made

To get `Trace.tla` validation running, two pre-existing issues had to be
resolved. Phase 3 should reconcile or audit these:

| File              | What changed                                                         | Why                                                                                                                                                |
|-------------------|----------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `spec/base.tla`   | `activeStealers \subseteq Stealer` → `activeStealers \in SUBSET Stealer` | TLC could not bind a fresh variable through `\subseteq` in `Init`. The two forms are semantically equivalent. Original kept at `base.tla.bak`.   |
| `spec/Trace.cfg`  | `Stealer = {s1, s2, …}` → `Stealer = {"s1", "s2", …}`                 | Trace JSON keys are strings. Constants must match the string type or `tid \in Stealer` always fails.                                              |
| `spec/Trace.cfg`  | `BufferCap = 4` → `BufferCap = 64`                                   | Implementation `MIN_CAP = 64`. With BufferCap=4, push events with `QLen >= 4` (legal in implementation) violate the spec's `QLen < BufferCap` guard. |
| `spec/Trace.tla`  | `TraceInit` now pins `activeStealers = TraceStealers`                | Without this, TLC enumerates all 15 non-empty subsets of Stealer, most of which are inconsistent with the trace and produce false deadlocks.       |
| `spec/Trace.tla`  | `TraceSpec` now includes `WF_allTraceVars(TraceNext)`                | The temporal property `TraceMatched` requires fairness; without WF, TLC always finds a trivial stuttering counterexample.                          |

### 2. Time-skew on `LIFOPopDecide` multi_pop

State is captured **after** the operation. For `Worker::pop` LIFO multi-task
path, between the in-code decision and the state capture, stealers can
advance `front`, so `state.front` may equal the (decremented) `state.back`
even though the worker chose the `multi_pop` branch under `len > 0`.

The spec's `LIFOPopDecide` re-derives the branch from current state and would
disagree.

**Mitigation in current scenarios**: `lifo_three_stealers` keeps worker pops
out of the contended phase (push-only while stealers race; drain serially at
the end). This sidesteps the issue.

If Phase 3 wants traces that exercise contended LIFO pops, options:

1. **Capture decision-time state** by saving `f` (the `front.load` result
   used in the branch decision) and reporting it as a separate trace field
   (e.g. `decisionFront`). Then the spec's `TraceLIFOPopDecide` can dispatch
   on that field rather than the current state.
2. **Loosen the spec** so `LIFOPopDecide`'s branch is selected by
   `logline.result` instead of the spec's recomputation.

### 3. Buffer ID identity

Worker code uses `self.buffer.get().ptr` (the T-array allocation) for the
buffer-ID; the stealer code dereferences `Atomic<Buffer<T>>` and uses
`buffer.deref().ptr`. Both end up at the same T-array pointer, so the two
sides agree on bufferID values.

If you change either side, keep the identity consistent or `state.bufferID`
will diverge between worker and stealer events.

### 4. Buffer ID of 0 means "not validated"

For events emitted before `StealLoadBuffer` (i.e., `StealLoadFront_Single`,
`StealPin`, `StealLoadBack`), the trace deliberately writes `bufferID: 0`
into the state envelope. The spec doesn't validate `bufferID` for those
actions, so 0 is a sentinel meaning "ignore this field". `Trace.tla` only
validates `bufferID` for `ResizeGrow` (via `ValidateBufferGen`).

### 5. Tests run serially

`run.sh` invokes `cargo test … -- --exact <name>` once per scenario, so
each scenario gets a fresh process and a fresh buffer-ID registry. If you
add cargo `--test-threads` or run multiple scenarios in one command,
the global `BUF_ID_REGISTRY` will see allocations from sibling tests and
the IDs will no longer start at 1.

### 6. Adding a new field to an event

1. Edit `harness/src/tla_trace.rs`: add the parameter to the relevant
   `emit_*` function and append it to the JSON template.
2. Edit `harness/instrument.py`: pass the new value at the call site.
3. Edit `spec/Trace.tla`: extend the relevant `Trace<X>` wrapper to read
   `logline.<field>` and add a validation conjunct.
4. Re-run `bash harness/run.sh` and `run_trace_validation`.

### 7. Adding a new event type

1. Add a new `emit_<event>` function in `tla_trace.rs`.
2. Add a new `replace_unique` patch block in `instrument.py` for the
   trigger point.
3. Add a `Trace<EventName>` wrapper in `Trace.tla` and include it in
   `MatchEvent`'s disjunction.
4. Re-run `bash harness/run.sh` and validate.

### 8. Moving a capture point (before ↔ after)

`instrument.py`'s patch blocks are anchored on a verbatim source string.
Move the `let __tla_t0 = rdtsc(); … let __tla_t1 = rdtsc();` and the
state-capture block within the patch block to the new position, then
re-run `apply.sh`. Remember the rule: state capture goes **outside** the
`[t0, t1]` interval to keep the timebox tight.

### 9. Reverting

```bash
cd artifact/crossbeam
git checkout -- crossbeam-deque/src/lib.rs crossbeam-deque/src/deque.rs
rm crossbeam-deque/src/tla_trace.rs crossbeam-deque/tests/trace_scenarios.rs
```

---

## Trace coverage matrix

| Event type                | fifo_short | fifo_two_stealers | lifo_three_stealers |
|---------------------------|------------|-------------------|---------------------|
| `PushWriteSlot`           | ✓          | ✓                 | ✓                   |
| `PushStoreBack`           | ✓          | ✓                 | ✓                   |
| `LIFOPopDecrFence`        |            |                   | ✓                   |
| `LIFOPopDecide`           |            |                   | ✓                   |
| `FIFOPopAttempt`          |            |                   |                     |
| `FIFOPopRollback`         |            |                   |                     |
| `ResizeGrow`              |            |                   |                     |
| `StealLoadFront_Single`   | ✓          | ✓                 | ✓                   |
| `StealPin`                | ✓          | ✓                 | ✓                   |
| `StealLoadBack`           | ✓          | ✓                 | ✓                   |
| `StealLoadBuffer`         | ✓          | ✓                 | ✓                   |
| `StealReadSlot`           | ✓          | ✓                 | ✓                   |
| `StealRecheckCAS`         | ✓          | ✓                 | ✓                   |
| `StealLIFOBatchIter`      |            |                   |                     |
| `StealLoadFront_BatchFifo`|            |                   |                     |
| `StealLoadFront_BatchLifo`|            |                   |                     |
| `StealerCloneAdv`         |            |                   |                     |
| `WorkerDropAdv`           |            |                   |                     |

`FIFOPopAttempt`/`FIFOPopRollback` aren't triggered because the FIFO scenarios
don't have the worker pop. They are instrumented; the next test scenario can
exercise them.

`ResizeGrow` requires push count ≥ `MIN_CAP=64`. Current scenarios push at
most 8.

Batch / Family-C events are not yet instrumented (see "Not yet instrumented"
above).

---

## Trace concurrency quality

`preprocess_trace.py` reports cross-thread overlap pairs:

| Trace                     | Events | Threads | Overlapping pairs |
|---------------------------|--------|---------|--------------------|
| `fifo_short`              | 38     | 2       | 2                  |
| `fifo_two_stealers`       | 124    | 3       | 16                 |
| `lifo_three_stealers`     | 108    | 4       | 8                  |

All three traces have genuine cross-thread interval overlap, so the timebox
mechanism's `ViablePIDs` partial order is exercised (not degenerated to a
total order).
