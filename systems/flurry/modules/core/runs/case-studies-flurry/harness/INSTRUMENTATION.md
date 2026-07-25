# Flurry Instrumentation Guide

Quick reference for Phase 3 agent to adjust instrumentation when trace validation reveals issues.

## Architecture

Category B (concurrent/lock-free) harness using per-thread NDJSON files with rdtsc timebox intervals.

- **Trace module**: `harness/src/tla_trace.rs` (copied to `artifact/flurry/src/tla_trace.rs`)
- **Instrumentation patch**: `harness/patches/instrumentation.patch` (modifies `lib.rs`, `map.rs`, `node.rs`)
- **Test scenarios**: `harness/src/trace_tests.rs` (copied to `artifact/flurry/tests/trace_tests.rs`)
- **Preprocessor**: `harness/src/preprocess_trace.py` (merges per-thread files, compresses timestamps)

## Activation

Set `FLURRY_TRACE_DIR=<path>` to enable tracing. Each thread writes to `<path>/trace-thread-<N>.ndjson`.

## Instrumentation Points

### map.rs

| Event | Location (after patch) | Trigger |
|-------|----------------------|---------|
| `enter_guard` | `guard()` method | After `collector.enter()` |
| `put_empty_bin` | `put()` — CAS success path | After `add_count(1, ...)` |
| `put_node_bin` | `put()` — Node arm | After bin loop, before `drop(head_lock)` |
| `put_tree_bin` | `put()` — Tree arm | After tree op, before `drop(head_lock)` |
| `put_help_transfer` | `put()` — Moved arm | Before `help_transfer()` call |
| `treeify_bin` | `treeify_bin()` | At entry + all exit paths (converted/moved/tree/presize/changed) |
| `init_resize` | `try_presize()` + `add_count()` | After CAS `size_ctl` to `rs + 2` |
| `claim_range` | `transfer()` inner loop | After CAS `transfer_index` success |
| `claim_range_exhausted` | `transfer()` inner loop | When `next_index <= 0` |
| `transfer_bin` | `transfer()` bin processing | After each bin (empty CAS, node split, tree split) |
| `transfer_finish_check` | `transfer()` finish check | After CAS `size_ctl - 1` |
| `complete_resize` | `transfer()` finishing block | After table swap + size_ctl store |
| `help_transfer` | `help_transfer()` | After CAS `size_ctl + 1` |

### node.rs

| Event | Location (after patch) | Trigger |
|-------|----------------------|---------|
| `writer_acquire_fast` | `lock_root()` | After CAS(0, WRITER) success |
| `writer_release` | `unlock_root()` | After `store(0, Release)` |
| `writer_acquire_contended` | `contended_lock()` | After CAS(state, WRITER) success |
| `writer_set_waiter` | `contended_lock()` | After CAS(s, s\|WAITER) success |
| `reader_acquire` | `find()` | After CAS(s, s+READER) success |
| `reader_release` | `find()` | After `fetch_add(-READER)` |

## How To

### Add a new field to an existing event

1. In `tla_trace.rs`, add the parameter to the emit function and update the format string.
2. In `map.rs` or `node.rs`, pass the new value at the emit call site.
3. Regenerate the patch: `cd artifact/flurry && git diff -- src/map.rs src/node.rs src/lib.rs > ../../harness/patches/instrumentation.patch`

### Add a new event type

1. Add an `emit_<name>()` function in `tla_trace.rs`.
2. Insert the emit call in `map.rs` or `node.rs` at the appropriate location.
3. Add matching event case in `Trace.tla`'s `MatchEvent` operator.
4. Regenerate the patch.

### Move a capture point (before vs after)

Move the `tla_trace::trace_rdtsc()` and `tla_trace::emit_*()` calls to the desired position. `start` should be BEFORE the operation, `end` should be AFTER.

### Rebuild and re-run

```bash
cd case-studies/flurry
bash harness/run.sh
```

## Known Issues for Phase 3

1. **Count validation disabled**: Put events do not emit `count` in state because concurrent atomic increments make the count racy across threads. Trace.tla uses `ValidatePostStateWeak` for puts.

2. **Key abstraction gap**: The spec uses `\E k \in 0..MaxKey-1` with `BinIndex(key, tableSize) = key % tableSize`, but the implementation uses hash-based bin assignment. The spec's existential key choice may not match reality. Consider constraining `k` from `logline.bin` in Trace.tla: `BinIndex(k, tableSize) = logline.bin`.

3. **NumBins must match reality**: `HashMap::with_capacity(4)` creates a table of size 8 (due to load factor rounding). Trace.cfg must use `NumBins = 8` to match.

4. **exit_guard emission**: Guard drop events are emitted from test code (not from within the Guard's Drop impl, which is in the external `seize` crate). This means exit_guard is only traced in test scenarios.

5. **Tree-lock bin index**: Tree lock events (reader/writer acquire/release) use `tla_trace::get_current_bin()` which is set by the caller in `map.rs`. If a new call path to tree lock functions is added without setting the bin, the bin index will be stale.

6. **SilentEnterGuard constraint**: Updated to not fire for threads with pending `enter_guard` events, using `IF t \in ThreadsWithEvents THEN Logline(t).event /= "enter_guard" ELSE TRUE`.
