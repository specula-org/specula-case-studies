# scc — Trace Harness Instrumentation Guide

This document is for the Phase 3 (validation) agent. It describes how the
trace events are emitted, where the call sites live in the artifact, and how
to extend or adjust the instrumentation.

The harness is **Category B** (concurrent / lock-free): each thread writes
its own NDJSON file with rdtsc `[start, end]` intervals. Per-thread files
are merged into the JSON document Trace.tla expects.

## Repo layout

```
.specula-output/
├── harness/
│   ├── apply.sh                 # patches the artifact
│   ├── clean.sh                 # reverts the artifact
│   ├── run.sh                   # apply + build + run + preprocess
│   ├── preprocess.py            # merge per-thread NDJSON → single JSON
│   ├── patches/
│   │   └── instrumentation.patch  # unified diff (lib.rs, Cargo.toml, hash_index.rs)
│   └── src/
│       ├── tla_trace.rs         # trace emission module (copied to scc/src/)
│       └── trace_driver/        # cargo binary that runs the test scenarios
│           ├── Cargo.toml
│           └── src/main.rs
└── traces/
    ├── single_writer.ndjson     # one-line JSON document per scenario
    ├── iter_vs_writer.ndjson
    └── contended_writers.ndjson
```

## Spec events emitted

| Spec action               | Emitted by                                  | Captured fields                              |
|---------------------------|---------------------------------------------|----------------------------------------------|
| `WriterStart`             | `insert_sync`, `remove_if_sync` head        | kind, step, cachedArray, key, val            |
| `WriterMaybeRehashOK`     | same — emitted right after WriterStart      | kind, step, cachedArray                      |
| `WriterAcquireLock`       | same — after `writer_sync` returns          | kind, step, cachedArray, bucketIdx           |
| `WriterCommitInsert`      | `insert_sync` after `locked_bucket.insert`  | kind, step, cachedArray, bucketIdx, key, val, occBit, remBit |
| `WriterCommitMarkRemoved` | `remove_if_sync` after `mark_removed`       | kind, step, cachedArray, bucketIdx, key, occBit, remBit |
| `WriterRelease`           | both — at end of public API method          | kind, step, cachedArray, bucketIdx           |
| `IterStart`               | `Iter::next` lazy-init branch               | kind, step, cachedArray                      |
| `IterReadOccupied`        | `Iter::next` after `move_to_next` returns true | kind, step, cachedArray, bucketIdx, key, val |
| `IterReadEmpty`           | `Iter::next` after `move_to_next` returns false | cachedArray, bucketIdx                  |
| `IterAdvanceWithinBucket` | `Iter::next` after `self.index += 1`        | cachedArray, bucketIdx                       |
| `IterCrossArray`          | `Iter::next` after `self.bucket_array.replace` | kind, step, cachedArray                  |
| `IterFinish`              | `Iter::next` on the terminating `None`      | kind, step                                   |
| `DeallocGarbage`          | `dealloc_garbage` after drop_in_place loop  | kind, step                                   |

## Spec events NOT emitted (silent in the spec)

The following spec actions are not currently instrumented. The Phase 3 agent
will need to model them as silent actions in `Trace.tla`, or extend the
instrumentation following the patterns below:

| Spec action               | Reason it's silent                          |
|---------------------------|---------------------------------------------|
| `TryResize`               | `try_resize` is invoked transitively via `try_enlarge`/`try_shrink`. Wrap the swap site at `hash_table.rs:1426-1427`. |
| `MigrateLockOldBucket`    | `incremental_rehash_async` / `dedup_bucket_async` deep in `hash_table.rs:1177-1188`, `:828-829`. |
| `MigratePublishNew`       | `bucket.rs:341-346` (extract_from → insert into new bucket). |
| `MigrateClearOld`         | `bucket.rs:348-364` (extract_from → store on source bitmap). |
| `MigrateEmpty`            | `hash_table.rs:899-905` / `:955-958` (`old_writer.kill()` after empty len). |
| `MigrateKillOldBucket`    | `hash_table.rs:903` / `:942`. |
| `EndIncrementalRehash`    | `hash_table.rs:1192-1200` / `:1244-1251`. |

For each, read `instrumentation-spec.md` Section 2 for the trigger point,
then add an `emit_<event>` call from `crate::tla_trace`. Most of these
require threading the `bucket_array` pointer and current bucket index
through to the emit site.

## Key abstractions and limitations

### State capture and `pc[t]`

Each event's `state` field carries the post-action snapshot of the per-thread
spec PC: at minimum `{kind, step}`, plus `cachedArray` and (where relevant)
`bucketIdx`. Trace.tla's `ValidatePcState` checks `kind` and `step` against
`pc'[t]`.

### Bucket-array ID

A `*const BucketArray<...>` is interned to a `u32` via
`tla_trace::array_id(ptr as usize)`. The first observation gets id 1, the
next id 2, etc. The mapping is stable across emits within a process. See
`tla_trace.rs::array_id` for the implementation (thread-local cache + global
slow path).

### `bucketIdx` mapping

Real `BucketArray` has `array_len = capacity / BUCKET_LEN` buckets, and
`BUCKET_LEN = 32` (from `hash_table/bucket.rs:41`). The spec uses
`BucketCount = 2`. The harness emits `(real_bucket_index) % SPEC_BUCKET_COUNT`
where `SPEC_BUCKET_COUNT = 2` (defined in `tla_trace.rs`).

**Tests must use `HashIndex::with_capacity(64)`** so `array_len = 2`,
matching the spec's `BucketCount = 2` exactly. Larger capacities yield more
real buckets and the modulo collapses them, breaking spec validation
(repeating bucket indices for distinct logical entries).

### `key` / `val` strings

Trace.tla expects `key ∈ Key = {"k1","k2"}` and `val ∈ Value = {"v1"}`.
Real K/V types in scc don't implement `Display`/`Debug` by default. The
harness uses a per-thread "current op kv" thread-local set by the test
driver before each `insert_sync` / `remove_if_sync` call:

```rust
tla_trace::set_op_kv("k1", "v1");
map.insert_sync(1, 1).ok();
```

Make sure new test scenarios call `set_op_kv` before each instrumented
public-API call. Iterator events use static `"k1","v1"` placeholders since
the iterator yields the actual K/V type (which we can't introspect
generically).

## Validation status (smoke test on these traces)

After running `bash run.sh` and validating each scenario against
`spec/Trace.tla` + `Trace.cfg`:

| Scenario             | Events | TLC states | Outcome                                           |
|----------------------|-------:|-----------:|---------------------------------------------------|
| `single_writer`      |      5 |          5 | All events matched. Stuttering at end (fairness).  |
| `insert_then_remove` |     10 |         11 | **All events matched.** Both CommitInsert and CommitMarkRemoved validated. |
| `iter_vs_writer`     |     11 |          8 | First 8 events matched including t1 IterReadOccupied seeing t2 WriterCommitInsert (genuine F1 race). Deadlocks on next IterReadEmpty due to BUCKET_LEN=1 spec abstraction (see issue 1 below). |
| `contended_writers`  |     10 |          9 | First 9 events matched. Deadlocks at second insert (t1 k1 collides with t2 k2 in same real bucket). |

The harness format is valid; remaining mismatches are spec abstraction
issues, all documented below.

## Known spec/trace mismatches (Phase 3 to-do list)

These showed up during the harness smoke test (`run.sh` then
`run_trace_validation`). They are **spec abstraction issues**, not trace
correctness issues:

1. **`BUCKET_LEN = 1` in spec vs `BUCKET_LEN = 32` in scc.**
   The spec models one slot per bucket. The real implementation packs up to
   32 entries per bucket. When two test inserts collide on the same real
   bucket, they emit the same `bucketIdx`, and the spec's
   `WriterCommitInsert` precondition `~occBit[p]` fails on the second one.
   *Fix*: extend `base.tla` to model a slot index dimension, or add a
   per-array slot counter to the harness emit.

2. **`NONE = "none"` in `ArrayId ∪ {NONE}`.**
   `base.tla` line 808 (TypeOK) computes `currentArray ∈ ArrayId ∪ {NONE}`
   where `ArrayId = 1..MaxArrays` and `NONE = "none"` (a string). TLC
   refuses to mix integer intervals and strings in a heterogeneous union.
   *Workaround applied*: rewritten to
   `(currentArray ∈ ArrayId) \/ currentArray = NONE`.

3. **`Thread = {t1,t2}` model values vs JSON string keys.**
   Per JSON convention the trace uses string keys `"t1"` / `"t2"`.
   `Trace.cfg` was updated to `Thread = {"t1","t2"}` (likewise for `Key`,
   `Value`).

4. **`MigrationVisibleEverywhere` parse error.**
   `base.tla` line 861 had a precedence conflict on `=>`. Rewritten with
   explicit parentheses.

5. **`TraceMatched` temporal property without fairness.**
   Trace.tla declares `TraceMatched == <>(ThreadsWithEvents = {})` but
   `TraceSpec` has no fairness constraint, so TLC allows infinite stuttering
   from any state. This shows up as a "temporal properties violated"
   counterexample even when the trace itself is consistent.
   *Phase 3 fix*: add `WF_<<allVars,pcCursor>>(TraceNext)` to `TraceSpec`.

6. **Empty thread arrays.**
   The preprocessor pads `events.tN = []` for any thread tN ∈
   `EXPECTED_THREADS = {1, 2}` that didn't emit. Without this, Trace.tla
   fails with "Attempted to access nonexistent field 't2'" at initial
   state. If `Thread` in Trace.cfg changes, update `EXPECTED_THREADS` in
   `preprocess.py`.

## How to add a new event

1. Add an emit function to `harness/src/tla_trace.rs` (both the `imp` mod
   under `cfg(feature = "tla-trace")` and the no-op stub below it).
2. Insert the `crate::tla_trace::emit_<name>(t_start, ...)` call at the
   trigger point in the artifact (capture `t_start = crate::tla_trace::now()`
   before the action).
3. `bash apply.sh` to re-apply, then re-run `run.sh`.
4. Regenerate the patch: `cd artifact/scc && git diff > ../../.specula-output/harness/patches/instrumentation.patch`
   (the artifact lives at `case-studies/scc/artifact/scc` — both `scc/` and
   `scc_2/` symlink to the same path).

## How to add a new field

1. Modify the relevant `emit_<event>` function in `tla_trace.rs` to accept
   and serialize the new field.
2. Update the call sites in the artifact to pass the value.
3. Update `Trace.tla`'s `Validate*State` helper to check the new field.

## How to move a capture point

The trigger points were chosen to align with the linearization point of each
spec action (typically just AFTER a release-store on the relevant bitmap).
If a different point is needed:

1. Move the `emit_<event>` call to the new line in the artifact.
2. Make sure the state captured (e.g., `cachedArray`, `bucketIdx`) is read
   AFTER the linearization point so the emitted state reflects what other
   threads can observe.
3. Re-build with `bash run.sh`.

## How to add a new test scenario

Add a new `fn scenario_<name>()` in
`harness/src/trace_driver/src/main.rs` and register it in `main()`:

```rust
fn scenario_my_new_test() {
    set_scenario("my_new_test");
    let map: HashIndex<u32, u32> = HashIndex::with_capacity(64);
    let h = std::thread::spawn(move || {
        tla_trace::thread_init(1);
        with_kv("k1", "v1", || {
            map.insert_sync(1, 1).ok();
        });
        tla_trace::thread_shutdown();
    });
    h.join().unwrap();
}
```

Re-run `bash run.sh`. The new scenario produces
`traces/my_new_test.ndjson`.

## Rebuild / re-run cheat sheet

```bash
# Full pipeline (recommended):
cd .specula-output && bash harness/run.sh

# Just rebuild + rerun (skip patching if already applied):
cd .specula-output/harness/src/trace_driver && cargo build --release
SCC_TRACE_DIR=../../raw-traces ./target/release/scc_trace_driver
python3 ../../preprocess.py ../../raw-traces ../../../traces

# Revert artifact:
bash harness/clean.sh
```
