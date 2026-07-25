# Instrumentation Spec: MongoDB Replica Set Reconfiguration

This document describes how to instrument the MongoDB source code to emit traces compatible with `Trace.tla`.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event has this structure:
```json
{
  "eventName": "string",      // Spec action name (see Section 2)
  "nodeId": "string",         // Server identifier (n1, n2, n3, etc.)
  "timestamp": "number",      // Wall-clock milliseconds or rdtsc ticks
  "eventFields": {...}        // Action-specific fields (see below)
}
```

### State Fields (Captured at Every Event)

These fields are captured at every event to enable post-state validation:

| Implementation Field | Trace Field | Description |
|---|---|---|
| `_rsConfig.configVersion()` | `inMemoryVersion` | In-memory config version |
| `_rsConfig.configTerm()` | `inMemoryTerm` | In-memory config term (-1 if force) |
| `_rsConfigState` | `configState` | Current config state enum |
| `_topCoord->getTerm()` | `topCoordTerm` | Topology coordinator's term |
| Disk config version | `persistedVersion` | Last persisted config version |
| Disk config term | `persistedTerm` | Last persisted config term |

### Message Fields (Event-Specific)

When events involve communication or other member references:

| Event Type | Message Field | Description |
|---|---|---|
| QuorumResponse | `voter` | Member ID who responded |
| ReConfigInitiate | `newVersion` | New config version being installed |
| ReConfigInitiate | `newTerm` | New config term being installed |
| Heartbeat | `dest` | Destination server ID |
| AdvanceCommit | `optime` | Oplog entry timestamp being committed |

## Section 2: Action-to-Code Mapping

Each row specifies one spec action and where to insert instrumentation:

### Family 1: Config Version/Term Comparison

**Action**: `CompareConfigVersionAndTerm(s, other)`
- **Code location**: `src/mongo/db/repl/replication_coordinator_impl.cpp` lines 4000-4050 (heartbeat processing)
- **Trigger point**: Before comparison in `_handleHeartbeatResponse()` or similar
- **Trace event name**: `CompareConfig`
- **Fields**: `inMemoryVersion`, `inMemoryTerm`, `topCoordTerm`
- **Notes**: Model the asymmetric comparison operator from `repl_set_config.h:91-99`. The comparison ignores term field if either term is -1 (force reconfig).

### Family 2: Multi-Step Config Commit

**Action**: `DoReplSetReconfig_Initiate(s, newVersion, newTerm)`
- **Code location**: `replication_coordinator_impl.cpp` line 3626 `_setConfigState(lk, kConfigReconfiguring)`
- **Trigger point**: After state transition to kConfigReconfiguring
- **Trace event name**: `ReConfigInitiate`
- **Fields**: `newVersion`, `newTerm`, `configState`
- **Notes**: This marks the start of the reconfig operation. The scope guard is set up at this point.

**Action**: `QuorumChecker_Start(s)`
- **Code location**: `replication_coordinator_impl.cpp` line 3835 `status = checkQuorumForReconfig(...)`
- **Trigger point**: Before quorum check begins
- **Trace event name**: `QuorumStart`
- **Fields**: `configState`
- **Notes**: Initiates scatter-gather quorum check.

**Action**: `QuorumChecker_ProcessResponse(s, voter)`
- **Code location**: `check_quorum_for_config_change.cpp` lines 157-163 `processResponse()` and 238-322 `_tabulateHeartbeatResponse()`
- **Trigger point**: After each response is processed
- **Trace event name**: `QuorumResponse`
- **Fields**: `voter` (who responded), number of voters responded so far
- **Notes**: Emit an event for each response received. Capture the actual voter who responded to detect out-of-order arrivals.

**Action**: `QuorumChecker_Timeout(s)`
- **Code location**: `check_quorum_for_config_change.cpp` (timeout handler, if separate)
- **Trigger point**: When quorum check times out before sufficient responses
- **Trace event name**: `QuorumTimeout`
- **Fields**: `configState`
- **Notes**: Emit when quorum check fails due to timeout (not enough responses).

**Action**: `DoReplSetReconfig_Persist(s, newVersion, newTerm)`
- **Code location**: `replication_coordinator_impl.cpp` lines 3842-3878 `storeLocalConfigDocument()`
- **Trigger point**: Before disk write begins
- **Trace event name**: `ReConfigPersist`
- **Fields**: `newVersion`, `newTerm`, `configState`
- **Notes**: Marks start of persistence operation.

**Action**: `JournalFlush_Complete(s)`
- **Code location**: `replication_coordinator_impl.cpp` line 3878 `JournalFlusher::get(opCtx)->waitForJournalFlush()`
- **Trigger point**: After journal flush completes (durability guaranteed)
- **Trace event name**: `JournalFlush`
- **Fields**: `persistedVersion`, `persistedTerm`, `inMemoryVersion`, `inMemoryTerm`
- **Notes**: Emit when durability is guaranteed. This is the critical point where persisted state becomes stable.

**Action**: `DoReplSetReconfig_FinishInstall(s, newVersion, newTerm)`
- **Code location**: `replication_coordinator_impl.cpp` line 3882 `_finishReplSetReconfig()`
- **Trigger point**: At start of `_finishReplSetReconfig()` (before in-memory installation)
- **Trace event name**: `ReConfigInstall`
- **Fields**: `newVersion`, `newTerm`, `inMemoryVersion`, `inMemoryTerm`, `configState`
- **Notes**: Marks the in-memory installation. This is where in-memory config is updated. Capture pre-state before changes.

**Action**: `Crash_RecoverConfigFromDisk(s)`
- **Code location**: Crash handler (detect via process restart or fault injection)
- **Trigger point**: After process restart, before any other action
- **Trace event name**: `CrashRecovery`
- **Fields**: `persistedVersion`, `persistedTerm`, `inMemoryVersion`, `inMemoryTerm`
- **Notes**: Recovery from persistent state happens implicitly. Emit a trace event to mark the recovery point so spec can reset in-memory to persisted values.

### Family 3: Quorum Response Accumulation

(See `QuorumChecker_ProcessResponse` and `QuorumChecker_Timeout` above)

### Family 4: Config State Synchronization

**Action**: `Heartbeat_SendCurrentConfig(s, dest)`
- **Code location**: `replication_coordinator_impl.cpp` (heartbeat send path, lines 4000-4100)
- **Trigger point**: When sending heartbeat with current config
- **Trace event name**: `Heartbeat`
- **Fields**: `inMemoryVersion`, `inMemoryTerm`, `dest` (destination server)
- **Notes**: The heartbeat carries the current config. Model this to detect when different nodes' configs diverge.

### Family 5: Commitment Safety

**Action**: `AdvanceCommittedOptime(s, optime)`
- **Code location**: `replication_coordinator_impl.cpp` (commit advancement, ~line 4400)
- **Trigger point**: When committed optime advances
- **Trace event name**: `AdvanceCommit`
- **Fields**: `optime` (committed timestamp), `inMemoryVersion`, `inMemoryTerm`
- **Notes**: Emit when an oplog entry becomes committed. Verify that entries committed in old config remain committed in new config.

### Family 6: Config State Machine

(Transitions are captured by the other actions' state field changes)

## Section 3: Special Considerations

### 1. State Capture Timing

**Pre-action vs post-action**: For most actions, capture state **after** the action completes. This ensures post-state validation can check what changed. Exception: For `ReConfigInstall`, capture pre-state before the complex update sequence in `_setCurrentRSConfig()`.

### 2. Concurrent Threads

**ScatterGatherRunner**: The quorum checker runs concurrently. Responses can arrive out-of-order. Emit a separate `QuorumResponse` event for each response to expose the interleaving. Do not batch responses.

**Heartbeat thread**: Heartbeat processing runs on a separate thread. If it races with reconfig, emit `Heartbeat` events to make the race visible in the trace.

### 3. Bootstrap State Differences

MongoDB's initial state may differ from base.tla:
- Initial config term may be 0 instead of -1 (depends on init path)
- Initial config version is 1 (same as base)
- Topology coordinator is initialized with initial config

`TraceInit` should match the actual initial state in `TraceLog[1]` or bootstrap from server startup logs.

### 4. Force Reconfig Handling

When `force = true`:
- Config term is set to -1 (uninitialized/special)
- Config version is bumped by 10,000 + random (line 3456)
- Comparison operator ignores term field (line 94 in repl_set_config.h)

Emit events with `newTerm = -1` to distinguish force reconfigs in the trace.

### 5. Scope Guard State Reversion

Lines 3627-3631: Scope guard reverts state to `kConfigSteady` on failure/error. The state transition back is automatic (constructor at line 3627 sets it, destructor on exception reverts). Emit a separate event only if the revert is due to an explicit error path (not the success path where `dismiss()` is called at line 3881).

### 6. Serialization Notes

- Config term `-1` (uninitialized) is a valid value; do not omit it as zero
- Config version is always `>= 1`
- Optime is a tuple `(timestamp, term)` but for commit tracking, just use the comparable value
- Server IDs are strings (e.g., "n1", "n2", "n3") or integers; use consistent naming

## Section 4: Instrumentation Checklist

- [ ] Every spec action in Section 2 has a corresponding trace event
- [ ] Every trace event emits all required state fields
- [ ] State field captures match base.tla variables
- [ ] Quorum responses are individually emitted (not batched)
- [ ] Force reconfig events correctly set `newTerm = -1`
- [ ] Crash recovery is emitted as a trace event (not implicit)
- [ ] Concurrent events (heartbeats, responses) show actual interleaving order
- [ ] Pre-state captured before multi-step actions (e.g., `_setCurrentRSConfig`)
- [ ] Post-state captured after action completes
- [ ] All code locations verified in actual MongoDB source tree
