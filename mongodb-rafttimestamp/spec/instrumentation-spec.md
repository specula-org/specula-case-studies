# Instrumentation Spec: MongoDB RaftMongoReplTimestamp

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<ISO8601 timestamp>",
  "event": {
    "name": "<ActionName>",
    "node": "<server_id>",
    "from": "<source_server_id>",  // optional, for pairwise actions
    "state": {
      "term": <int>,
      "state": "<PRIMARY|SECONDARY|DOWN>",
      "lastApplied": {"term": <int>, "index": <int>},
      "lastDurable": {"term": <int>, "index": <int>},
      "lastWritten": {"term": <int>, "index": <int>},
      "commitPoint": {"term": <int>, "index": <int>},
      "logLen": <int>
    },
    // action-specific fields below
  }
}
```

### State Fields Mapping

| Implementation getter | TLA+ variable | Capture timing |
|----------------------|---------------|----------------|
| `_topCoord->getTerm()` | `currentTerm` | Every event |
| `_getMemberState()` | `state` | Every event |
| `_getMyLastAppliedOpTime()` | `lastApplied` | After action |
| `_getMyLastDurableOpTime()` | `lastDurable` | After action |
| `_getMyLastWrittenOpTime()` | `lastWritten` | After action |
| `_topCoord->getLastCommittedOpTime()` | `commitPoint` | After action |
| oplog collection count | `Len(log[s])` | After action |

### Approach: Log Parsing (NOT C++ Instrumentation)

Per `mongodb-shared-harness.md`, MongoDB's LOGV2 structured logs contain state transition events. We parse existing logs into NDJSON traces. Some events require new LOGV2 calls where MongoDB doesn't already log.

---

## Section 2: Action-to-Code Mapping

### 2.1 AppendOplog

- **Spec action**: `AppendOplog(i, j)`
- **Code location**: `oplog_applier_impl.cpp` — batch application completion
- **Existing LOGV2**: ID `21230` ("Applied op") — one per applied op
- **Alternative**: Log at batch end with final optime
- **Trigger point**: After oplog entries are appended to secondary's oplog
- **Event name**: `"AppendOplog"`
- **Fields**: `node`, `from` (sync source), `state` (post-state)
- **Notes**: The sync source identity comes from `SyncSourceResolver`. May need to extract from `_syncSourceHost` in `BackgroundSync`.

### 2.2 PersistOplog

- **Spec action**: `PersistOplog(i)`
- **Code location**: `replication_coordinator_impl.cpp:1740-1746` (`_setMyLastDurableOpTimeAndWallTimeForward`)
- **Existing LOGV2**: ID `21324` ("Updating lastDurable") — logged when durable advances
- **Trigger point**: After `lastDurable` is updated
- **Event name**: `"PersistOplog"`
- **Fields**: `node`, `state` (full post-state including lastDurable)

### 2.3 ApplyOplog

- **Spec action**: `ApplyOplog(i)`
- **Code location**: `replication_coordinator_impl.cpp:1710-1737` (`_setMyLastAppliedOpTimeAndWallTimeForward`)
- **Existing LOGV2**: ID `21330` ("Advancing lastApplied") — logged on advancement
- **Trigger point**: After `lastApplied` is updated
- **Event name**: `"ApplyOplog"`
- **Fields**: `node`, `state` (full post-state including lastApplied)

### 2.4 LearnCommitPoint

- **Spec action**: `LearnCommitPointWithTermCheck(i, j)` or `LearnCommitPointFromSyncSource(i, j)`
- **Code location**: `topology_coordinator.cpp` — `advanceLastCommittedOpTimeAndWallTime`
- **Existing LOGV2**: ID `21340` ("Updating commit point")
- **Trigger point**: After commit point is updated
- **Event name**: `"LearnCommitPoint"`
- **Fields**: `node`, `from` (heartbeat source or sync source), `state` (post-state with commitPoint)

### 2.5 RollbackOplog

- **Spec action**: `RollbackOplog(i, j)`
- **Code location**: `rollback_impl.cpp:700-769` (`_runPhaseFromAbortToReconstructPreparedTxns`)
- **Existing LOGV2**: ID `21600` ("Marking to truncate all oplog entries with timestamps greater than common point")
- **Trigger point**: After rollback truncation
- **Event name**: `"RollbackOplog"`
- **Fields**: `node`, `from` (sync source used for rollback), `state` (weak: term + state)
- **Notes**: Rollback truncates multiple entries; spec models one at a time. Trace wrapper should handle by allowing multiple spec RollbackOplog steps.

### 2.6 BecomePrimary

- **Spec action**: `BecomePrimaryByMagic(i, ayeVoters)`
- **Code location**: `replication_coordinator_impl.cpp` — `_postWonElectionUpdateMemberState`
- **Existing LOGV2**: ID `21358` ("Transition to PRIMARY")
- **Trigger point**: After state transitions to PRIMARY
- **Event name**: `"BecomePrimary"`
- **Fields**: `node`, `state` (post-state: term, state="PRIMARY")
- **Notes**: Voters are not directly observable from logs; trace wrapper uses existential quantification.

### 2.7 Stepdown

- **Spec action**: `Stepdown(i)`
- **Code location**: `step_up_step_down.cpp:234-246` (RSTL release during stepdown)
- **Existing LOGV2**: ID `21359` ("Transition to SECONDARY")
- **Trigger point**: After state transitions to SECONDARY from PRIMARY
- **Event name**: `"Stepdown"`
- **Fields**: `node`, `state` (post-state: state="SECONDARY")

### 2.8 UpdateTerm

- **Spec action**: `UpdateTermThroughHeartbeat(i, j)`
- **Code location**: `replication_coordinator_impl.cpp` — `updateTerm`
- **Existing LOGV2**: ID `21353` ("Updating term")
- **Trigger point**: After term is updated
- **Event name**: `"UpdateTerm"`
- **Fields**: `node`, `from` (heartbeat source), `state` (post-state: new term)

### 2.9 ClientWrite

- **Spec action**: `ClientWrite(i)`
- **Code location**: `oplog.cpp:588` (`getNextOpTimes` reserves slot)
- **Existing LOGV2**: None directly for slot reservation
- **Suggested**: Add LOGV2 after `oplogEntry->setOpTime(slot)` at oplog.cpp:592
- **Trigger point**: After oplog entry is written
- **Event name**: `"ClientWrite"`
- **Fields**: `node`, `state` (weak: term, state), `slot` (reserved optime)

### 2.10 CloseOplogHole

- **Spec action**: `CloseOplogHole(i)`
- **Code location**: Storage engine visibility thread — `_updateOplogVisibilityTimestamp`
- **Existing LOGV2**: None directly
- **Suggested**: Add LOGV2 when oplog visibility timestamp advances
- **Trigger point**: After hole is closed (write transaction committed)
- **Event name**: `"CloseOplogHole"`
- **Fields**: `node`, `state` (weak), `slot` (closed optime)
- **Notes**: This is the most challenging event to capture. The storage engine tracks "all durable" which effectively represents hole closure. Monitor `getAllDurableTimestamp()` advancement.

### 2.11 AdvanceCommitPoint

- **Spec action**: `AdvanceCommitPoint`
- **Code location**: `topology_coordinator.cpp` — `_advanceLastCommittedOpTimeAndWallTime` (on primary)
- **Existing LOGV2**: ID `21340` ("Updating commit point") — same as LearnCommitPoint
- **Trigger point**: After commit point is advanced on the leader
- **Event name**: `"AdvanceCommitPoint"`
- **Fields**: `node`, `state` (post-state with new commitPoint)
- **Notes**: Distinguish from LearnCommitPoint by checking if node is PRIMARY.

### 2.12 JournalFlusherCapture

- **Spec action**: `JournalFlusherCapture(i)`
- **Code location**: `journal_flusher.cpp` — beginning of flush cycle
- **Existing LOGV2**: None (internal to journal flusher thread)
- **Suggested**: Add LOGV2 at start of `JournalFlusher::_flush()` capturing `lastApplied`
- **Trigger point**: When journal flusher reads lastApplied
- **Event name**: `"JournalFlusherCapture"`
- **Fields**: `node`, `state` (weak: term, state), `capturedOpTime` (the lastApplied value read)

### 2.13 JournalFlusherFlush

- **Spec action**: `JournalFlusherFlush(i)`
- **Code location**: `replication_coordinator_impl.cpp:1740-1746` (`_setMyLastDurableOpTimeAndWallTimeForward`)
- **Existing LOGV2**: ID `21324` ("Updating lastDurable")
- **Trigger point**: After lastDurable is set by the journal flusher
- **Event name**: `"JournalFlusherFlush"`
- **Fields**: `node`, `state` (full post-state including new lastDurable)
- **Notes**: Disambiguate from direct PersistOplog by checking if called from journal flusher context. May need to add a "source" field.

### 2.14 ClientWriteWithWC

- **Spec action**: `ClientWriteWithWC(i)`
- **Code location**: `service_entry_point_common.cpp` or command-level handlers
- **Existing LOGV2**: Write concern is logged at command level
- **Trigger point**: After write is performed and before awaitReplication
- **Event name**: `"ClientWriteWithWC"`
- **Fields**: `node`, `state` (weak), `opTime` (the write's optime), `writeConcern` ("majority")

### 2.15 WriteConcernSatisfied

- **Spec action**: `WriteConcernSatisfied(i)`
- **Code location**: `replication_coordinator_impl.cpp:2222-2292` (`_doneWaitingForReplication`)
- **Existing LOGV2**: None directly when WC is satisfied
- **Suggested**: Add LOGV2 when `_doneWaitingForReplication` returns true
- **Trigger point**: After write concern is satisfied
- **Event name**: `"WriteConcernSatisfied"`
- **Fields**: `node`, `state` (full post-state), `opTime` (the satisfied write's optime)

### 2.16 PrepareTransaction

- **Spec action**: `PrepareTransaction(i)`
- **Code location**: `transaction_participant.cpp` — `TransactionParticipant::Participant::prepareTransaction`
- **Existing LOGV2**: ID `22521` ("Prepared transaction")
- **Trigger point**: After transaction is prepared
- **Event name**: `"PrepareTransaction"`
- **Fields**: `node`, `state` (weak), `prepareTimestamp` (the prepare optime)

### 2.17 CommitPreparedTxn

- **Spec action**: `CommitPreparedTxn(i)`
- **Code location**: `transaction_participant.cpp` — `TransactionParticipant::Participant::commitPreparedTransaction`
- **Existing LOGV2**: ID `22522` ("Committed prepared transaction")
- **Trigger point**: After prepared transaction is committed
- **Event name**: `"CommitPreparedTxn"`
- **Fields**: `node`, `state` (weak), `commitTimestamp`

### 2.18 Crash / Recovery Events

- **Spec actions**: `Crash(i)`, `RecoverTruncateOplog(i)`, `RecoverReplayOplog(i)`, `RecoverSetTimestamps(i)`
- **Code location**: `replication_recovery.cpp:472-548` (recoverFromOplog)
- **Existing LOGV2**:
  - Crash: mongod shutdown (ID `23138`)
  - Recovery start: ID `21542` / `21543`
  - Oplog truncation: ID `21545` ("Truncating oplog")
  - Replay: ID `21549` ("Replaying oplog entries")
  - Timestamps set: ID `21557` ("Setting timestamps")
- **Event names**: `"Crash"`, `"RecoverTruncateOplog"`, `"RecoverReplayOplog"`, `"RecoverSetTimestamps"`
- **Fields**: `node`, recovery-specific state
- **Notes**: Recovery events are logged at startup. Parse startup logs for these events. Crash is detected by monitoring mongod process exit.

---

## Section 3: Special Considerations

### 3.1 Log Parsing Approach

MongoDB emits structured JSON logs (LOGV2). Most events can be captured by parsing existing log IDs. The `log_ids.json` mapping should include:

```json
{
  "21324": {"event": "PersistOplog", "fields": {"lastDurable": "opTime"}},
  "21330": {"event": "ApplyOplog", "fields": {"lastApplied": "opTime"}},
  "21340": {"event": "LearnCommitPoint", "fields": {"commitPoint": "newCommitPoint"}},
  "21358": {"event": "BecomePrimary", "fields": {}},
  "21359": {"event": "Stepdown", "fields": {}},
  "21353": {"event": "UpdateTerm", "fields": {"term": "newTerm"}},
  "21600": {"event": "RollbackOplog", "fields": {}},
  "22521": {"event": "PrepareTransaction", "fields": {"prepareTimestamp": "prepareOpTime"}},
  "22522": {"event": "CommitPreparedTxn", "fields": {"commitTimestamp": "commitOpTime"}},
  "21542": {"event": "RecoverStart", "fields": {}},
  "21545": {"event": "RecoverTruncateOplog", "fields": {}},
  "21549": {"event": "RecoverReplayOplog", "fields": {}},
  "23138": {"event": "Crash", "fields": {}}
}
```

### 3.2 Events Requiring New LOGV2 Calls

These events are NOT currently logged by MongoDB and would require source patches:

1. **ClientWrite** (oplog slot reservation) — add LOGV2 at oplog.cpp:592
2. **CloseOplogHole** (visibility advancement) — add LOGV2 in visibility thread
3. **JournalFlusherCapture** (flusher reads lastApplied) — add LOGV2 at journal flusher start
4. **WriteConcernSatisfied** (WC check passes) — add LOGV2 in _doneWaitingForReplication
5. **ClientWriteWithWC** (write with WC) — add LOGV2 before awaitReplication call

### 3.3 Node Identity

Each mongod in a replica set has a hostname:port. Map these to spec server IDs (`n1`, `n2`, `n3`) based on the replica set config. The log parser should:
1. Parse the `rs.conf()` output to get member ordering
2. Assign `n1`, `n2`, `n3` in config order

### 3.4 OpTime Serialization

MongoDB OpTimes in logs appear as `Timestamp(term, index)` or `{t: <term>, ts: Timestamp(<sec>, <inc>)}`. The log parser must convert MongoDB timestamps to spec-compatible `{term, index}` pairs. The "index" in the spec corresponds to the oplog sequence number (1-based position), not the MongoDB Timestamp increment.

For trace validation, map:
- MongoDB `lastApplied.ts` → count of oplog entries up to that timestamp
- This requires maintaining a mapping from timestamps to oplog positions

### 3.5 Concurrent Event Ordering

Multiple servers emit logs independently. Merge by wall-clock timestamp. For events on the same server, preserve log order. Cross-server ordering is inherently approximate — the trace spec's silent actions handle any reordering.

### 3.6 Docker Compose Template

Use the replica set template from `mongodb-shared-harness.md`:
- 3-node RS with `--setParameter enableTestCommands=1`
- `--setParameter logComponentVerbosity='{replication: {verbosity: 3}}'`
- Enable journal flusher logging: `--setParameter logComponentVerbosity='{storage: {journal: {verbosity: 2}}}'`

### 3.7 Test Scenarios

| Scenario | Commands | Expected trace events |
|----------|----------|----------------------|
| Basic consensus | `rs.initiate()`, insert documents | ClientWrite, AppendOplog, PersistOplog, ApplyOplog, AdvanceCommitPoint |
| Stepdown + rollback | Insert, `rs.stepDown()`, insert on new primary | Stepdown, BecomePrimary, RollbackOplog |
| Write concern loss | Insert with `w:majority`, concurrent stepdown | ClientWriteWithWC, WriteConcernSatisfied or Stepdown |
| Prepared txn + hole | Start txn, prepare, insert other docs, commit | PrepareTransaction, ClientWrite, CloseOplogHole, CommitPreparedTxn |
| Crash + recovery | Kill mongod, restart | Crash, RecoverTruncateOplog, RecoverReplayOplog, RecoverSetTimestamps |
| Journal flusher race | High write throughput + stepdown | JournalFlusherCapture, JournalFlusherFlush, Stepdown |
