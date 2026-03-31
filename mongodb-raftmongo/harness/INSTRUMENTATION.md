# RaftMongo Instrumentation Guide

## Architecture

```
3-node MongoDB RS (Docker) → LOGV2 structured JSON logs → parse_repl_logs.py → NDJSON traces
```

No C++ source modification is needed. MongoDB's LOGV2 structured logging already emits all replication state transitions at appropriate verbosity levels.

## Log Verbosity

All nodes run with `logComponentVerbosity='{replication: {verbosity: 3}}'` to capture:
- Commit point updates (log ID 21826, verbosity 2)
- Vote grants (log ID 5972100, verbosity 1)
- All other replication events (verbosity 0)

## Trace Event → Log ID Mapping

| Trace Event | Log ID(s) | Source File | Verbosity |
|---|---|---|---|
| StartElection | 21444, 4615652, 4615660 | elect_v1.cpp, heartbeat.cpp | 0 |
| VoteGranted | 5972100 | topology_coordinator.cpp:3792 | 1 |
| ElectionWon | 21450 | elect_v1.cpp:462 | 0 |
| TransitionToPrimary | 21331 | repl_coord_impl.cpp:1542 | 0 |
| Stepdown | 21402, 21475 | repl_coord_impl.cpp, heartbeat.cpp | 0 |
| UpdateTerm | 21827 | topology_coordinator.cpp:3308 | 0 |
| AdvanceCommitPoint | 21826, 6795400 | topology_coordinator.cpp | 0-2 |
| RollbackOplog | 21607 | rollback_impl.cpp:1220 | 0 |
| Crash | 501401 | repl_coord_impl.cpp:614 | 0 |

## Silent Actions (Not Traced)

These spec actions have no dedicated log event and are handled by Trace.tla silent wrappers:

| Silent Action | Reason |
|---|---|
| SilentPersistOplog | Journal flushes are async, no individual log |
| SilentApplyOplog | Follower apply is captured implicitly |
| SilentAppendOplog | Oplog sync may not have discrete events |
| SilentUpdateTerm | Some term updates come without 21827 |
| SilentRequestVote | Vote grants between traced events |

## State Tracking

The parser tracks per-node state from log context:
- **Term**: from `term`/`currentTerm` attributes
- **State**: from `newState`/`memberState` (mapped: PRIMARY→Leader, SECONDARY→Follower)
- **Commit point**: from `_lastCommittedOpTimeAndWallTime`/`committedOpTime`
- **lastWritten/lastApplied/lastDurable**: from corresponding optime attributes

State is updated from additional log IDs (21334, 21335, 21337) that report optime changes.

## How to Add a New Field

1. In `parse_repl_logs.py`, find the `update_state_from_context()` function
2. Add extraction for the new field from MongoDB log attributes
3. Add the field to `NodeState.snapshot()` return dict
4. Update `Trace.tla` validators to check the new field

## How to Add a New Event

1. Find the MongoDB log ID (grep LOGV2 in the source)
2. Add the log ID to `EVENT_LOG_IDS` dict in `parse_repl_logs.py`
3. Write a `handle_<event>()` function following existing patterns
4. Add the event name to `Trace.tla` as a new `Trace<Event>` action
5. Re-run: `bash harness/run.sh`

## How to Move a Capture Point

The capture points are determined by when MongoDB emits the LOGV2 event — they are inherent to the MongoDB source code and cannot be moved without recompiling. If a different capture timing is needed:

1. Find a different log ID that fires at the desired point
2. Or: add state context extraction from surrounding log events

## How to Rebuild and Re-run

```bash
# Re-run everything
cd case-studies/mongodb-raftmongo && bash harness/run.sh

# Re-parse only (no cluster restart)
python3 harness/src/parse_repl_logs.py harness/logs/ traces/basic_consensus.ndjson --after "2024-01-01T00:00:00"

# Run trace validation
cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg Trace.tla -deadlock
```

## ClientWrite Tracing

MongoDB doesn't produce a LOGV2 event for each client write. The current harness does NOT emit `ClientWrite` trace events — these are handled by the Trace spec's silent `SilentAppendOplog` which covers the log growth. If explicit ClientWrite tracing is needed, add test-harness-driven synthetic events by:

1. Capturing optime before/after each write in the test JS
2. Emitting a synthetic trace line from a post-processing step

## Differentiating Heartbeat vs Sync Source Commit Points

Both paths produce log ID 21826. The current parser emits all 21826 events as `AdvanceCommitPoint`. To differentiate:
- Check surrounding log context for heartbeat response logs vs oplog fetcher logs
- Or merge into a single `LearnCommitPoint` event and let Trace.tla try both actions
