# Instrumentation Guide

Phase 2.5 harness for `mongodb-rangedeletions-secondary`.

## Files

| Path | Purpose |
|------|---------|
| `harness/src/tla_trace.h` | Header-only trace emission library |
| `harness/patches/instrumentation.patch` | Git unified diff of the three instrumented source files |
| `harness/apply.sh` | Apply patch to `artifact/mongo-src` |
| `harness/clean.sh` | Revert instrumentation |
| `harness/run.sh` | Full pipeline: apply → build → run → collect traces |
| `harness/gen_traces.py` | Prototype trace generator (no build required) |
| `harness/src/range_deleter_tla_trace_test.cpp` | Three C++ test scenarios |

## Applying to a Real Build

```bash
# From the run directory
bash harness/apply.sh
# Then build the MongoDB range deleter test target:
cd artifact/mongo-src
python3 bazel/bazelisk.py build --config=opt //src/mongo/db/s:range_deleter_service_test
```

`apply.sh` copies `tla_trace.h` into `artifact/mongo-src/src/mongo/db/s/` and runs
`git apply` on the patch.

## Environment Variables for the Real Binary

| Variable | Default | Meaning |
|----------|---------|---------|
| `TLA_TRACE_FILE` | (required) | Path for the NDJSON output file |
| `TLA_NODE_NAME` | `n_local` | TLA+ node name for this process (must match `Trace.cfg: Nodes`) |
| `TLA_PRIMARY_NODE` | `n_primary` | TLA+ node name to use as the primary in `ReplicateDiskState` events emitted on a secondary |

Set `TLA_NODE_NAME` to one of `{n1, n2, n3}` as defined in `spec/Trace.cfg`.

## Instrumented Source Locations

### `range_deleter_service.cpp`

| Action | Location | What is captured |
|--------|----------|-----------------|
| `StepUp` | `onStepUpComplete`, first line | Pre-state: `role=Secondary`, `termInitReady=false`, `recoveryPhase=idle` |
| `RecoveryPhase1Scan` | After phase-1 while loop in `_launchRangeDeletionRecoveryTask` | Pre-state: `recoveryPhase=phase1` (global atom=1) |
| `RecoveryPhase2Scan` | After phase-2 while loop | Pre-state: `recoveryPhase=phase2` (global atom=2) |
| `StepDown` | Under mutex in `onStepDown`, before `_stopService()` | Pre-state: `role=Primary`, `termInitReady` computed from promise, `recoveryPhase` from atom |

### `range_deleter_service_op_observer.cpp`

| Action | Location | What is captured |
|--------|----------|-----------------|
| `OpObserverClearPending` | Before `try` block in `onCommit` lambda | Pre-state: `diskTaskState=pending` |
| `OpObserverRegisterTask` | After successful `registerTask()` | Pre-state: `recoveryPhase` from atom at call time |
| `ReplicateDiskState` | In catch (secondary path) and in `onUpdate` | Secondary's current disk state before applying the oplog change |

### `ready_range_deletions_processor.cpp`

| Action | Location | What is captured |
|--------|----------|-----------------|
| `DeleteOrphans` | After LOGV2 6872501 (task picked from queue) | Pre-state: `diskTaskState=ready`, `deletionStep=idle` |
| `MajorityWaitSuccess` | After `_waitForMajority()` returns OK | Pre-state: `deletionStep=deleting` |
| `MajorityWaitInterrupted` | In outer catch, when `_stopRequested() && inMajorityWait` | Pre-state: `deletionStep=deleting`, `diskTaskState=processing` |
| `CompleteInMemory` | After `completeTask()` | Pre-state: `deletionStep=waiting`, `completionFulfilled=false` |
| `RemovePersistentTask` | After `removePersistentTask()` | Pre-state: `deletionStep=completing`, `diskTaskState=processing` |

## PRE-STATE Rule

Trace.tla's validators (`ValidateNodeState`, `ValidateDiskTask`, `ValidateDeletionStep`)
use **unprimed** TLA+ variables, which means they check the state **before** the action
fires.  Every emit call must capture the state as it is at that moment — not after the
C++ action has mutated it.

## Recovery Phase Tracking

The `emitRecoveryPhase1Scan` / `emitRecoveryPhase2Scan` / `emitStepDown` calls happen in
different threads (recovery runs in the executor thread pool).  A shared
`std::atomic<int>` in `tla_trace.h` encodes the phase:

| Value | Meaning |
|-------|---------|
| 0 | idle (pre-StepUp or after StepDown) |
| 1 | phase1 (after StepUp, before phase-1 loop exits) |
| 2 | phase2 (after phase-1 scan, before phase-2 loop exits) |
| 3 | done (recovery complete) |

`emitStepUp` sets the atom to 1.  Each phase emit function reads the current atom value
for the pre-state field and then advances it.  `emitStepDown` reads the atom for its
pre-state and resets it to 0.

## Task Key Format

```
<collectionUUID>:<rangeMin>:<rangeMax>
```

Example: `uuid-collA:{ _id: 0 }:{ _id: 10 }`.  This is the stable identifier used in
all per-task events and must match the keys expected by `Trace.tla`.

## Adjusting for a Different Node Topology

`spec/Trace.cfg` defines `Nodes = {n1, n2, n3}` and `Tasks = {t1, t2}`.

- If the test uses more tasks, add entries to `Tasks` in `Trace.cfg` and update task
  key mapping in the test.
- If the test runs on a single node, `ReplicateDiskState` events for the secondary path
  will never fire (the op_observer catch block only runs on secondaries).

## Adjusting the Prototype Generator

`harness/gen_traces.py` can be run without a MongoDB build:

```bash
python3 harness/gen_traces.py
```

Edit the `scenario_*` functions to add or remove events.  The factories at the top of
the file enforce the correct pre-state fields for each event type.  Keep `time.sleep(0.001)`
between events so that timestamps are strictly increasing.

## Known Limitations

1. **Build not attempted**: The MongoDB Bazel build requires ~60 GB disk and 2–4 hours.
   All traces in `traces/` were produced by `gen_traces.py`.
2. **Single-process tests**: The C++ test scenarios use the existing
   `RangeDeleterServiceTest` fixture and run in a single process, so multi-node
   `ReplicateDiskState` events are produced only for paths that explicitly call the
   secondary code paths.
3. **`faultFreeVarsExcept` in Trace.tla**: `TraceOpObserverClearPending` contains
   `UNCHANGED <<faultFreeVarsExcept>>` but `faultFreeVarsExcept` is not defined in
   `Trace.tla` or `spec.tla`.  If TLC raises a name-not-found error on that action,
   either define the constant or replace it with the full unchanged-variable list.
