# Instrumentation Guide — crossbeam-epoch trace harness

This document is for the Phase 3 (validation) agent. It explains where each
trace event is emitted, how to add or move emissions, and how to rebuild and
re-run after edits.

## Layout

```
.specula-output/harness/
├── apply.sh                      Apply instrumentation to artifact
├── run.sh                        Build + run scenarios + preprocess
├── preprocess.py                 Merge per-thread NDJSON shards
├── INSTRUMENTATION.md            This file
├── patches/
│   └── instrumentation.patch     git-diff of in-tree edits to crossbeam-epoch
└── src/
    ├── tla_trace.rs              Trace emission library (copied into artifact)
    └── tla_harness.rs            Test scenarios (copied into examples/)
```

## Category

**Category B (concurrent / lock-free)** — uses the per-thread timebox pattern:

- Per-thread NDJSON shards via `thread_local!` `BufWriter<File>`
- `rdtsc` (with mfence on both sides) for tight `[start, end]` intervals
- State captured **after** `end` so the interval stays tight
- Post-processing (`preprocess.py`) merges shards and compresses timestamps
- `Trace.tla` uses `ViablePIDs` partial-order matching against the merged JSON

## Where each event is emitted

All emit sites live in `crossbeam-epoch/src/internal.rs` (after `apply.sh`):

| Event              | Function               | Trigger                                                      |
|--------------------|------------------------|--------------------------------------------------------------|
| `PinIncGuardCount` | `Local::pin`           | After `self.guard_count.set(...)`                            |
| `PinLoadGlobal`    | `Local::pin`           | After `self.global().epoch.load(Relaxed)` (only if outer)    |
| `PinPublish`       | `Local::pin`           | After `compare_exchange` / `store + fence`                   |
| `PinMaybeCollect`  | `Local::pin`           | After `pin_count.set(...)`, before optional `collect()`      |
| `UnpinDec`         | `Local::unpin`         | After `self.guard_count.set(guard_count - 1)`                |
| `UnpinPublish`     | `Local::unpin`         | After `self.epoch.store(starting, Release)` (only if outer)  |
| `Repin`            | `Local::repin`         | After the (optional) `self.epoch.store(global_epoch, Release)` |
| `TryAdvLoadGlobal` | `Global::try_advance`  | After `self.epoch.load(Relaxed)`                             |
| `TryAdvIter`       | `Global::try_advance`  | Each iteration of the locals loop, including stalled/abort   |
| `TryAdvFinishStore`| `Global::try_advance`  | After `self.epoch.store(new_epoch, Release)`                 |
| `Defer`            | `Local::defer`         | After `bag.try_push(deferred)` succeeds                      |
| `PushBag`          | `Global::push_bag`     | After `self.queue.push(bag.seal(epoch), guard)`              |
| `Flush`            | `Local::flush`         | After optional `push_bag`, before `collect()`                |
| `CollectScan`      | `Global::collect`      | After each `try_pop_if` in the COLLECT_STEPS loop            |
| `BagDrop`          | `Bag::drop`            | One per deferred call + one finalize event                   |
| `PublishObject`    | `tla_harness.rs`       | Caller-side: after `store` makes a node reachable            |
| `UnlinkObject`     | `tla_harness.rs`       | Caller-side: after `swap` removes a node                     |
| `ReadAndDeref`     | `tla_harness.rs`       | Caller-side: after `load` + `as_ref()`                       |

## Special design decisions

1. **`Flush` event is emitted before `collect()` runs**, not at function exit.
   The spec's `Flush` action atomically does both the bag push and the
   transition into the PinCollect path, so the trace must show Flush *before*
   the TryAdv events fired by `collect()`. Since `push_bag` runs and emits
   first (when bag is non-empty), the spec's Flush takes its bag-empty branch
   and just transitions `pc=Idle → pc=PinCollect`.

2. **Suppression flag**. `tla_trace.rs` exposes a thread-local `SUPPRESS`
   used at three sites:
   - **`Bag::drop` deferred-fn invocation**: re-entrant `pin()`/`unpin()`
     inside a deferred body must not emit events — the spec models them
     via silent `InDeferCallbackPin`/`Unpin` transitions.
   - **`Global::collect`'s `try_pop_if` call**: the MS-queue's pop calls
     `guard.defer_destroy(head)` to retire the dequeued node. That's queue-
     internal cleanup the spec doesn't model; without suppression, spurious
     `Defer` events appear inside the CollectScan flow.

3. **Object IDs via thread-local**. The user code calls
   `tla_trace::set_defer_obj(id)` immediately before `g.defer_destroy(...)`.
   The Local::defer instrumentation reads the value via `take_defer_obj()`.
   Internal defers (e.g., the one suppressed above) leave the value as 0 →
   mapped to label `"o1"`; they are also suppressed so they never reach the
   trace.

4. **End barrier in test scenarios**. All multi-threaded scenarios use
   `Barrier::new(N)` at scope start AND end so threads pin at roughly the
   same time and no `LocalHandle` is dropped while another thread's
   `try_advance` is still iterating the locals list. Without this, the
   iterator's "finalize tagged element" path emits Defer events that the
   harness never asked for.

5. **Idle stand-in thread**. Single-thread scenarios (`repin_panic`,
   `nested_pin`) spawn a second thread that registers a `LocalHandle` and
   waits at the barriers but emits nothing. This makes `Cardinality(AliveLocals)`
   in the spec match the impl's iteration count (`Thread = {"t1", "t2"}`).

## Trace.tla customisations

The shipped `Trace.tla` contains several adjustments to handle non-determinism
and impl/spec ordering mismatches:

- `Thread`/`Object` constants in `Trace.cfg` are **strings** (`"t1"`, `"o1"`)
  — they must match JSON keys.
- `MatchPinMaybeCollect` constrains `pc'[tid]` based on the trace's
  `triggeredCollect` field so the spec matches the impl's collect-or-not
  decision.
- `MatchTryAdvIter` uses a CASE on the `aborted` field
  (`"none"` / `"different_epoch"` / `"stalled"`) to constrain which spec
  branch fires.
- `SilentActions` includes a `NoMatchEnabled` guard so silent transitions
  only fire when no `MatchEvent` is enabled. Without this, TLC explores
  branches that trivially deadlock.
- `SilentTryAdvIterFinish` is a new silent action for the impl's implicit
  iterator-exit transition (`pc=TryAdvIter, iterIndex >= cardinality →
  pc=TryAdvFinishStore`). The impl emits no event for the loop exit.
- `SilentPinCollectFinish` is **not** in `SilentActions`. The impl always
  exits the PinCollect path through the full TryAdv* + CollectScan flow.
- `TraceInit` overrides `base.tla`'s `Init` to start with `reachable = {}`
  (instead of `Object`). Test scenarios then drive `PublishObject` /
  `UnlinkObject` to grow and shrink it.
- `TraceSpec` adds `WF_<<allVars, traceVars>>(TraceNext)` — without
  fairness, TLC finds trivial stuttering counter-examples.

## How to rebuild + re-run after edits

```
cd .specula-output
bash harness/run.sh                    # all scenarios
bash harness/run.sh basic              # single scenario
bash harness/apply.sh --revert         # restore upstream sources
```

`run.sh` regenerates per-thread shards in `traces/<scenario>/trace-tN.ndjson`
and the merged file in `traces/<scenario>.ndjson`. Validate with:

```
mcp__tla-trace-debugger__run_trace_validation \
    spec_file=Trace.tla config_file=Trace.cfg \
    trace_file=../traces/<scenario>.ndjson \
    work_dir=.specula-output/spec
```

## Adding a new event type

1. Add `pub fn emit_<name>(start: u64, end: u64, ...)` to `harness/src/tla_trace.rs`
   following the `emit_pin_inc_guard_count` pattern (NDJSON line with
   `"tag":"trace"`, `"event"`, `"thread"`, `"start"`, `"end"`, custom fields).
2. Insert the call site in `internal.rs` (or wherever) under `#[cfg(feature
   = "std")]` with rdtsc bracketing around the operation.
3. Add a `Match<Name>` clause in `Trace.tla`'s `MatchEvent` and update the
   instrumentation patch with `git diff > harness/patches/instrumentation.patch`.

## Adding a new field to an existing event

1. Update the `emit_<event>` signature in `tla_trace.rs` and the format
   string.
2. Update the call site to capture the new field.
3. Update the relevant `Match*` clause in `Trace.tla` if the spec needs to
   read it (`FieldOf(tid, "newField")`).
4. Regenerate `instrumentation.patch`.

## Moving a capture point (before → after)

State fields (`guardCountAfter`, `localEpochAfter`, etc.) are captured
**after** the operation completes. To move a capture point to *before*, swap
the order so the read happens before the operation that mutates the
underlying state. Update the field name in `tla_trace.rs` and `Trace.tla` if
the new semantic is "before" rather than "after".
