# Instrumentation Spec: MongoDB Resharding Coordinator

## Approach: Log Parsing (not C++ instrumentation)

MongoDB's resharding coordinator already emits structured LOGV2 logs for every state transition.
We parse these logs into NDJSON traces instead of modifying C++ source code.

Key log IDs:
- `5343001`: Coordinator state transition (`newState`, `oldState`, `reshardingUUID`)
- `5093702-5093707`: Phase-specific coordinator events
- `5277000`: LOGV2_FATAL — post-commit unrecoverable error

Donor/recipient state transitions are recorded in their respective logs.

## Section 1: Trace Event Schema

### Event Envelope

```json
{"tag": "trace", "ts": "<ISO8601>", "event": {
    "name": "<ActionName>",
    "state": {
        "coordState": "<CoordinatorStateEnum value>",
        "oldState": "<previous state>",
        "abortReason": "<bool or status string>"
    }
}}
```

### State Fields

| Implementation field | TLA+ variable | Source |
|---------------------|---------------|--------|
| `newState` (log 5343001) | `coordState` | `_coordinatorDoc.getState()` |
| `oldState` (log 5343001) | previous `coordState` | `previousState` in `installCoordinatorDocOnStateTransition` |
| `abortReason` (log 5093707) | `abortReason` | `_coordinatorDoc.getAbortReason()` |

## Section 2: Action-to-Code Mapping

| Spec Action | Log ID | Trigger | Event Name | Notes |
|-------------|--------|---------|------------|-------|
| CoordInitialize | 5343001 | oldState=kUnused, newState=kInitializing | `CoordInitialize` | resharding_coordinator.inl:214 |
| CoordPrepare | 5343001 | oldState=kInitializing, newState=kPreparingToDonate | `CoordPrepare` | |
| CoordTransitionToCloning | 5343001 | oldState=kPreparingToDonate, newState=kCloning | `CoordTransitionToCloning` | |
| CoordTransitionToApplying | 5343001 | oldState=kCloning, newState=kApplying | `CoordTransitionToApplying` | |
| CoordTransitionToBlocking | 5343001 | oldState=kApplying, newState=kBlockingWrites | `CoordTransitionToBlocking` | |
| CoordCommit | 5343001 | oldState=kBlockingWrites, newState=kCommitting | `CoordCommit` | Point of no return |
| CoordAbortPersist | 5343001 | newState=kAborting | `CoordAbortPersist` | |
| CoordFinish | 5343001 | newState=kDone OR newState=kQuiesced | `CoordFinish` | |

### Silent Actions (no log event)

| Spec Action | Why Silent | Constraint |
|-------------|-----------|------------|
| CoordInitializeMajority | Majority ack is internal, no separate log | Fires between CoordInitialize and CoordPrepare |
| CoordPrepareMajority | Same | Fires between CoordPrepare and CoordTransitionToCloning |
| CoordGenericMajority | Same | Fires between any transition and its successor |
| CoordCommitMajority | Same | Fires between CoordCommit and CoordFinish |
| CoordAbortMajority | Same | Fires between CoordAbortPersist and CoordAbortFinish |
| CoordAbortRequest | abort() call, no specific log for the request | Fires before CoordAbortPersist |
| CoordCrash | Step-down, logged elsewhere | Fires when next event is from a different primary |
| CoordRecover | Step-up recovery | Fires when coordinator resumes after gap |
| ObserverCheck | Internal promise check | Fires between transitions |
| DonorAdvance/DonorDone/DonorError | Donor logs on donor shard, not config server | Need donor logs or silent |
| RecipientAdvance/RecipientDone/RecipientError | Same | Need recipient logs or silent |

## Section 3: Special Considerations

1. **Single-node test**: For simplicity, run a 1-config-server, 2-shard cluster. Coordinator is on the config server.
2. **Log format**: MongoDB structured logs are JSON objects, one per line. Parse with `jq` or Python.
3. **Coordinator crash**: Detectable from log gap + step-up message (log ID 9307800: "Starting TransactionCoordinatorService initialization").
4. **Participant states**: If using single-shard-per-participant, donor/recipient logs are on separate nodes. Either collect all logs or model participant transitions as silent.
5. **Abort reason**: The abort reason is in the coordinator doc's `abortReason` field, logged at transition to kAborting.
