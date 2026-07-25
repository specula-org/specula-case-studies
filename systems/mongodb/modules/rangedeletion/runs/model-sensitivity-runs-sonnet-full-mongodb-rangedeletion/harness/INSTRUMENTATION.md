# Instrumentation Guide — MongoDB Range Deletion Protocol

Phase 3 (trace validation) agent: use this file to adjust instrumentation when TLC reports
mismatches between trace events and spec state.

---

## 1. File Map (after apply.sh)

| Source File | Line (post-patch) | Event | TLA+ Spec Action |
|---|---|---|---|
| `src/mongo/db/s/migration_coordinator.cpp` | after `insertMigrationCoordinatorDoc` | WriteCoordDoc | `WriteCoordDoc(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `_donorRangeDeletionTask.emplace(...)` | WriteRangeDeletionTask | `WriteRangeDeletionTask(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `persistCommitDecision` | PersistCommitDecision | `PersistCommitDecision(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `deleteRangeDeletionTaskOnRecipient` | DeleteRecipientTaskOnCommit | `DeleteRecipientTaskOnCommit(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `markAsReadyRangeDeletionTaskLocally` | ActivateDonorTaskOnCommit | `ActivateDonorTaskOnCommit(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `persistAbortDecision` | PersistAbortDecision | `PersistAbortDecision(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `deleteRangeDeletionTaskLocally` | DeleteDonorTaskOnAbort | `DeleteDonorTaskOnAbort(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `markAsReadyRangeDeletionTaskOnRecipient` at line ~382 | MarkRecipientTaskReady | `MarkRecipientTaskReady(m)` |
| `src/mongo/db/s/migration_coordinator.cpp` | after `store.remove` in `forgetMigration()` | ForgetMigration | `ForgetMigration(m)` |
| `src/mongo/db/s/ready_range_deletions_processor.cpp` | before `deleteRangeInBatches` in `_runRangeDeletions()` | ExecuteRangeDeletion | `ExecuteRangeDeletion(m)` |
| `src/mongo/db/s/ready_range_deletions_processor.cpp` | after `removePersistentTask` | CompleteRangeDeletion | `CompleteRangeDeletion(m)` |
| `src/mongo/db/s/range_deleter_service.cpp` | after `notifyRecoveryJobComplete(term)` | Recovery | `Recovery` |

---

## 2. How to Add a New Field

Each emit call uses fixed positional args. To add a field (e.g., `term`):

1. Add parameter to `tla_trace::emit()` signature in `harness/src/tla_trace.h`
2. Add it to the JSON serialization in `Tracer::emit()`
3. Update every call site in the 3 instrumented files

Example: adding `"term"` field:
```cpp
// tla_trace.h — add parameter
void emit(..., long long term);
// serialization
line << R"(,"term":)" << term;
// call site
tla_trace::emit("WriteCoordDoc", ..., true, 1LL);
```

---

## 3. How to Add a New Event Type

Copy an existing emit call, change the event name string to match the new TLA+ action name.
Ensure the Trace.tla has a corresponding `TraceXxx` wrapper that calls the base spec action
and a `ValidateXxx` helper.

---

## 4. Moving a Capture Point (before → after, or vice versa)

Each emit call is tagged with a comment referencing the function it follows. Search for the
comment to locate the call site. Move the `tla_trace::emit(...)` line to the desired position.

The instrumentation-spec.md §2 specifies whether each point is "before" or "after" the key
function call. Swapping before/after changes which state is captured (pre-state vs post-state).
The Trace.tla always expects post-state (state after the action completes).

---

## 5. Known State Capture Limitations

| Event | Missing Fields | Reason |
|---|---|---|
| ForgetMigration | donorTaskState, recipientTaskState inferred | Not validated by TraceForgetMigration (ValidateCoordDoc only); inference from `getDecision()` and `_donorRangeDeletionTask` |
| ExecuteRangeDeletion | coordDocState hardcoded "absent", recipientTaskState hardcoded "absent" | Not validated by TraceExecuteRangeDeletion (ValidateDonorTask only); ForgetMigration typically precedes this |
| CompleteRangeDeletion | coordDocState, recipientTaskState hardcoded "absent" | Not validated (ValidateDonorTask only) |
| Recovery | All fields hardcoded / migrationId = "*" | Recovery is a global action (not per-migration); fields not validated by TraceRecovery |

Validation in Trace.tla only checks the fields listed in each `TraceXxx` wrapper's `ValidateXxx` call.
Hardcoded placeholder values for un-validated fields are safe.

---

## 6. Recovery Event Coverage

The `Recovery` event (range_deleter_service.cpp) is instrumented but **not exercised** by the
current synthetic trace generator. To exercise it in a real test:

1. Set up a replica set with a primary that has `ready` range deletion tasks on disk.
2. Trigger a step-down and step-up: `rs.stepDown()` followed by `rs.stepUp()` or wait for election.
3. The recovery task in `_launchRangeDeletionRecoveryTask` will fire and emit the Recovery event.

This requires a full replica-set test environment. Existing JS test at:
`jstests/sharding/internal_txns/libs/chunk_migration_test.js` exercises migration flows
but does not exercise step-up recovery specifically.

For trace validation, Recovery events are handled by `TraceRecovery` in Trace.tla and do not
require recipientTaskState / donorTaskState validation — only the `inMemoryTasks` in-spec state
is checked.

---

## 7. Silent Action Liveness Warning (commit_crash_window.ndjson)

`commit_crash_window.ndjson` exercises the Family 1 crash window via `TraceSilentCommitSkip`.
That silent action is `UNCHANGED l` AND `UNCHANGED vars` — a pure stuttering step. Under the
default `TraceSpec == TraceInit /\ [][TraceNext]_tracevars` without fairness, TLC may find a
counterexample to `TraceMatched = <>(l > Len_TraceLog)` via the infinite stuttering loop.

**Fix**: Add fairness to `Trace.tla`:
```tla
TraceFairness == WF_tracevars(TraceNext)
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ TraceFairness
```

If validation reports `TraceMatched` violated for `commit_crash_window.ndjson`, add the
`TraceFairness` conjunct to `TraceSpec`. The other three traces do NOT trigger this issue.

---

## 8. ShardNotFound / abort_stuck_pending Trace

`abort_stuck_pending.ndjson` models the Family 2 bug where
`markAsReadyRangeDeletionTaskOnRecipient` throws `ShardNotFound` (line ~382, outside try/catch).
With the default Trace.cfg (`recipientShardAlive = TRUE`), TLC validates the ForgetMigration
event directly since `ForgetMigration(m)`'s only precondition is `coordDoc[m] ∈ {"committed","aborted"}`.

To validate the `TraceSilentMarkRecipientTaskReadyFails` silent action path, override
`recipientShardAlive = FALSE` in a custom trace cfg:

```
SPECIFICATION TraceSpec
CONSTANTS
    MigrationId    = {"m1"}
    Range          = {"r1"}
    Shard          = {"donor", "recipient"}
    DonorShard     = "donor"
    RecipientShard = "recipient"
INIT TraceInitFaultPath
...
```

where `TraceInitFaultPath` sets `recipientShardAlive = FALSE` initially.

---

## 8. Rebuild After Instrumentation Changes

```bash
# Re-apply patches (idempotent)
bash harness/apply.sh

# Rebuild affected targets
bazel build //src/mongo/db/s:migration_coordinator \
            //src/mongo/db/s:ready_range_deletions_processor \
            //src/mongo/db/s:range_deleter_service

# Re-run tests
TLA_TRACE_FILE=traces/commit_path.ndjson \
bazel test //src/mongo/db/s:range_deletion_util_test --test_filter="*"

# Or regenerate via Python (no build required)
python3 harness/generate_traces.py
```
