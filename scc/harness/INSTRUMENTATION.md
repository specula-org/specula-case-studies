# scc Trace Instrumentation

## Overview

Traces for scc HashMap are synthetic — carefully constructed to exercise the TLA+ spec's action space. Direct instrumentation of scc's internal operations (resize, rehash, EBR epoch management) would require deep modification of the scc source code including the `sdd` EBR crate, which is impractical for trace validation.

## Trace Construction Methodology

Each trace was manually constructed by:
1. Starting from the spec's Init state
2. Verifying each action's preconditions against the current spec state
3. Computing the post-state after each action
4. Including post-state validation fields (guard_active, current_array) in each event

## Trace Files

| File | Events | Coverage |
|------|--------|----------|
| `basic_ops.ndjson` | 7 | CreateGuard, InsertSync, BeginSyncRead, AccessDataSync, EndSyncRead, RemoveSync, DropGuard |
| `concurrent_rw.ndjson` | 10 | Multi-thread: concurrent insert + read from different threads |
| `resize_rehash.ndjson` | 9 | Full resize protocol: TriggerResize, ClaimRehashRange, RelocateBucket (×2), EndRehash, FinalizeResize |

## Event Format

Every NDJSON line has:
```json
{"event": "<action_name>", "thread": "<t1|t2|t3>", ...fields...}
```

Thread IDs map to TLA+ model values via `ThreadMap(s) == CHOOSE t \in Thread : ToString(t) = s`.
Array IDs map via `ArrayMap(id)` (string "1" → integer 1, "null" → NullArray).
Keys are strings: "k1", "k2" matching Trace.cfg `Key = {"k1", "k2"}`.

## Adjusting Traces

To add new traces:
1. Trace through the spec actions manually, verifying preconditions at each step
2. Include post-state fields (guard_active, current_array) for validation
3. Place the .ndjson file in `traces/`
4. Run: `bash harness/run.sh` (or invoke trace validation directly)

## Future: Full Instrumentation

For production-quality instrumentation, instrument these scc source locations:
- `hash_table.rs:306` reader_sync — begin_sync_read/access_data/end_sync_read
- `hash_table.rs:385` writer_sync — insert/remove
- `hash_table.rs:1307` try_resize — trigger_resize
- `hash_table.rs:1098` start_incremental_rehash — claim_rehash_range
- `hash_table.rs:1003` relocate_bucket — relocate_bucket/relocate_bucket_fail
- `hash_table.rs:1127` end_incremental_rehash — end_rehash
- `sdd/src/collector.rs:126` new_guard — create_guard
- `sdd/src/collector.rs:193` end_guard — drop_guard
- `async_helper.rs:53,47,72` — async_await/async_reacquire_guard/async_check_ref
