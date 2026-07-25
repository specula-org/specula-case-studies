# Instrumentation Spec: MongoDB Raft Reconfig

**Target**: mongodb-raftreconfig  
**Source root**: `src/mongo/db/repl/`  
**Trace format**: NDJSON (one JSON object per line)  
**Trace location**: `../traces/` (relative to `spec/`)

---

## Section 1: Trace Event Schema

### Common Event Envelope

Every trace event is a JSON object with these mandatory top-level fields:

```json
{
  "event": "<event_name>",
  "node":  "<node_id>",       // e.g. "rs0:27017" or a short alias
  "post":  { ... },           // post-action state snapshot (see State Fields below)
  "ts":    <uint64>,          // logical timestamp (monotone counter, not wall clock)

  // Optional fields present only on message events:
  "from":    "<node_id>",     // sender (for HandleRequestVote etc.)
  "to":      "<node_id>",     // recipient (redundant with "node", for clarity)
  "msgTerm": <int>            // term from incoming message
}
```

### Post-Action State Fields

These fields appear inside `post` whenever the action modifies the corresponding variable.
Fields are **omitted** when the action does not modify them (harness must not capture them then).

| JSON field | TLA+ variable | Implementation getter | Notes |
|---|---|---|---|
| `currentTerm` | `currentTerm[n]` | `_topCoord->getTerm()` | Nat |
| `role` | `role[n]` | `_topCoord->getMemberState().toString()` | "PRIMARY", "SECONDARY", "CANDIDATE", "STARTUP2" |
| `configVersion` | `configVersion[n]` | `_rsConfig.getConfigVersion()` | Nat |
| `configTerm` | `configTerm[n]` | `_rsConfig.getConfigTerm()` | -1 maps to UNINITIALIZED |
| `configState` | `configState[n]` | `_configState.load()` enum string | "kConfigSteady", "kConfigReconfiguring", "kConfigHBReconfiguring", "PostSwap" |
| `commitIndex` | `commitIndex[n]` | `_lastCommittedOpTimeAndWallTime.opTime.getSecs()` | use opTime.getSecs() or global oplog index |
| `lastCommittedInPrevConfig` | `lastCommittedInPrevConfig[n]` | `_topCoord->getLastCommittedInPrevConfig()` | Nat (oplog index) |
| `inMemVoteTerm` | `inMemVote[n].term` | `_topCoord->getLastVote().getTerm()` | read from in-memory _lastVote field |
| `durableVoteTerm` | `durableVote[n].term` | stable storage (`local.replset.election`) | requires shadow field; see §3 |
| `autoReconfigPending` | `autoReconfigPending[n]` | `_pendingReconfigFuture.has_value()` | bool |
| `logLen` | `Len(log[n])` | `getMyLastAppliedOpTime().getSecs()` | approximation; use actual log length if accessible |

### Message-Event Fields (per action)

See per-action entries in Section 2 for which fields are captured in each event.

---

## Section 2: Action-to-Code Mapping

### 1. Timeout

| Field | Value |
|---|---|
| **Spec action** | `Timeout(n)` |
| **Event name** | `"Timeout"` |
| **Code location** | `replication_coordinator_impl_elect_v1.cpp:140` — `_startElection` |
| **Trigger point** | After `_topCoord->processWinElection` increments term, before vote requests are sent |
| **Post fields** | `currentTerm`, `role` |
| **Notes** | Self-vote is modeled atomically with Timeout; no separate event needed for self-grant |

### 2. RequestVotes

| Field | Value |
|---|---|
| **Spec action** | `RequestVotes(candidate)` |
| **Event name** | `"RequestVotes"` |
| **Code location** | `vote_requester.cpp:83` — `Algorithm::prepareRequests` |
| **Trigger point** | After all VoteRequest messages are enqueued to the network layer |
| **Post fields** | `currentTerm`, `role` |
| **Notes** | `vote_requester.cpp:96-112` — when `configTerm = UNINITIALIZED`, configTerm is omitted from the outgoing message; trace should capture `mconfigVAT` fields to verify this |

### 3. HandleRequestVote

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVote(voter, m)` |
| **Event name** | `"HandleRequestVote"` |
| **Code location** | `topology_coordinator.cpp:3747` — `TopologyCoordinator::processReplSetRequestVotes` |
| **Trigger point** | After in-memory `_lastVote` is updated (line 3789), before `storeLocalLastVoteDocument` is called |
| **Msg fields** | `from` (candidate node), `msgTerm` (request term) |
| **Post fields** | `currentTerm`, `role`, `inMemVoteTerm` |
| **Notes** | Captures the **in-memory** vote update (Family 5 race window: durable write comes later via PersistVote). `voted` bool in post would help validate `inMemVote[n].for`. |

### 4. PersistVote

| Field | Value |
|---|---|
| **Spec action** | `PersistVote(n)` |
| **Event name** | `"PersistVote"` |
| **Code location** | `replication_coordinator_impl.cpp:5340` — after `storeLocalLastVoteDocument` completes |
| **Trigger point** | After durable write to `local.replset.election` succeeds |
| **Post fields** | `durableVoteTerm` |
| **Notes** | This is the only event that advances `durableVote`. If the process crashes between `HandleRequestVote` and `PersistVote`, `durableVote` remains at the old term. Requires reading back from stable storage for the post-state capture — use a shadow field (see §3). |

### 5. BecomeLeader

| Field | Value |
|---|---|
| **Spec action** | `BecomeLeader(n)` |
| **Event name** | `"BecomeLeader"` |
| **Code location** | `replication_coordinator_impl_elect_v1.cpp` — `_onVoteRequestComplete` after quorum confirmed |
| **Trigger point** | After `_topCoord->processWinElection`, before drain mode begins |
| **Post fields** | `currentTerm`, `role`, `autoReconfigPending` |

### 6. AutoReconfig

| Field | Value |
|---|---|
| **Spec action** | `AutoReconfig(n)` |
| **Event name** | `"AutoReconfig"` |
| **Code location** | `replication_coordinator_impl.cpp:1484` — inside `_reconfigToCSRSIfNeeded` or the draining completion callback |
| **Trigger point** | After `_doReplSetReconfig` completes with the new configTerm = electionTerm |
| **Post fields** | `configVersion`, `configTerm`, `configState`, `autoReconfigPending` |

### 7. AutoReconfigPreempted

| Field | Value |
|---|---|
| **Spec action** | `AutoReconfigPreempted(n)` |
| **Event name** | `"AutoReconfigPreempted"` |
| **Code location** | `replication_coordinator_impl.cpp:1504-1512` — error path when `ConfigurationInProgress` |
| **Trigger point** | On receiving non-fatal preemption error; flag cleared |
| **Post fields** | `autoReconfigPending`, `configState` |
| **Notes** | Non-fatal; configTerm NOT updated in this path (Family 6 bug scenario) |

### 8. ForceReconfig

| Field | Value |
|---|---|
| **Spec action** | `ForceReconfig(n, newCfg, newVer)` |
| **Event name** | `"ForceReconfig"` |
| **Code location** | `replication_coordinator_impl.cpp:3425` — force=true branch of `_doReplSetReconfig` |
| **Trigger point** | After new config is applied with configTerm = kUninitializedTerm (-1) |
| **Extra fields** | `newConfigVersion` (the version value set) |
| **Post fields** | `configVersion`, `configTerm`, `configState`, `lastCommittedInPrevConfig` |
| **Notes** | `configTerm` will be -1 in the trace; harness must map -1 → UNINITIALIZED (Family 1) |

### 9. SafeReconfigStart

| Field | Value |
|---|---|
| **Spec action** | `SafeReconfigStart(n, newCfg)` |
| **Event name** | `"SafeReconfigStart"` |
| **Code location** | `replication_coordinator_impl.cpp:3412` — entry of `_doReplSetReconfig` (force=false) |
| **Trigger point** | After `configState` transitions to `kConfigReconfiguring` |
| **Post fields** | `configState` |

### 10. SafeReconfigSwap

| Field | Value |
|---|---|
| **Spec action** | `SafeReconfigSwap(n, newCfg)` |
| **Event name** | `"SafeReconfigSwap"` |
| **Code location** | `replication_coordinator_impl.cpp:3997` — `_setCurrentRSConfig` call site |
| **Trigger point** | Immediately after `_setCurrentRSConfig` returns (config installed, PostSwap state) |
| **Post fields** | `configVersion`, `configTerm`, `configState` |
| **Notes** | In `base.tla`, this transitions configState to `PostSwap` (synthetic state). The harness should emit `"PostSwap"` as the configState string at this point. The implementation has no explicit intermediate state — instrument at the line just after `_setCurrentRSConfig` returns (line 3997). |

### 11. SafeReconfigCaptureBarrier

| Field | Value |
|---|---|
| **Spec action** | `SafeReconfigCaptureBarrier(n)` |
| **Event name** | `"SafeReconfigCaptureBarrier"` |
| **Code location** | `replication_coordinator_impl.cpp:4003` — `updateLastCommittedInPrevConfig` call site |
| **Trigger point** | After `updateLastCommittedInPrevConfig` returns |
| **Post fields** | `configState`, `lastCommittedInPrevConfig` |
| **Notes** | This is the CR1 race window: between `SafeReconfigSwap` (line 3997) and this event (line 4003), `AdvanceCommitIndex` can fire under the new config. Harness must instrument both sites to capture the gap. |

### 12. HBReconfigSchedule

| Field | Value |
|---|---|
| **Spec action** | `HBReconfigSchedule(n, newCfg, v, t)` |
| **Event name** | `"HBReconfigSchedule"` |
| **Code location** | `replication_coordinator_impl_heartbeat.cpp:689` — `_scheduleHeartbeatReconfig` |
| **Trigger point** | After `configState` set to `kConfigHBReconfiguring` |
| **Post fields** | `configState` |
| **Notes** | The `pendingHBConfig` fields (cfg, ver, trm) should also be captured if accessible. The check at line 698 for `kConfigReconfiguring` — if this silently drops, emit a `"HBReconfigDropped"` event (no base action for it; trace silently ignores). |

### 13. HBReconfigFinish

| Field | Value |
|---|---|
| **Spec action** | `HBReconfigFinish(n)` |
| **Event name** | `"HBReconfigFinish"` |
| **Code location** | `replication_coordinator_impl_heartbeat.cpp:_heartbeatReconfigFinish` |
| **Trigger point** | After new config is installed and configState returns to Steady |
| **Post fields** | `configVersion`, `configTerm`, `configState` |

### 14. AppendEntry

| Field | Value |
|---|---|
| **Spec action** | `AppendEntry(n)` |
| **Event name** | `"AppendEntry"` |
| **Code location** | `replication_coordinator_impl.cpp` — `_appendOplogEntryCallback` or equivalent |
| **Trigger point** | After entry appended to local log |
| **Post fields** | `logLen` |

### 15. AdvanceCommitIndex

| Field | Value |
|---|---|
| **Spec action** | `AdvanceCommitIndex(n)` |
| **Event name** | `"AdvanceCommitIndex"` |
| **Code location** | `replication_coordinator_impl.cpp:updateLastCommittedOpTimeAndWallTime` |
| **Trigger point** | After `commitIndex` advances to new value |
| **Post fields** | `commitIndex` |
| **Notes** | Quorum now computed against `config[n]` (potentially the new config if in PostSwap). This is the action that can fire in the race window between SafeReconfigSwap and SafeReconfigCaptureBarrier (MC3). |

---

## Section 3: Special Considerations

### 3.1 Durable Vote Shadow Field (Family 5)

The durable vote is stored in `local.replset.election` collection. Reading it on every trace event is expensive. Recommended approach: maintain a shadow field `_durableVoteTerm` in `ReplicationCoordinatorImpl` that is set to `lastVote.getTerm()` inside `storeLocalLastVoteDocument` callback, and read this shadow field for the `durableVoteTerm` post-state capture in `PersistVote` events.

### 3.2 PostSwap as Synthetic State

The implementation has no `kConfigPostSwap` state. The `PostSwap` configState string is synthetic — emitted by the harness at the instrumentation point immediately after `_setCurrentRSConfig` (line 3997) returns. The harness should use a thread-local flag (`inPostSwap = true`) that is set after line 3997 and cleared after line 4003 to correctly emit `configState = "PostSwap"` in the `SafeReconfigSwap` event's `post`.

### 3.3 UNINITIALIZED Mapping

`configTerm = -1` in the implementation maps to `UNINITIALIZED` in the spec. The NDJSON harness should emit the raw `-1` value; the Trace.tla `ToConfigTerm` function handles the mapping.

### 3.4 Concurrent Event Interleaving

The MongoDB replication coordinator uses a mutex-guarded state machine. Events within the same `rwMutex` critical section are linearizable. Heartbeat events run on a separate executor. For trace ordering, use a monotonically incrementing global counter (not wall-clock time) to timestamp events; the harness should increment this counter under the replica set mutex to preserve ordering.

### 3.5 Node Identity

Node IDs in traces should use the replica set member's `HostAndPort` (e.g., `"rs0:27017"`). The `Server` set in `Trace.cfg` should be set to match the traced cluster's node IDs.

### 3.6 Config Member Set Capture

For `ForceReconfig`, `SafeReconfigSwap`, and `HBReconfigFinish`, the `newCfg` member set should be captured as an array of node IDs in the trace event (e.g., `"newConfig": ["rs0:27017", "rs0:27018", "rs0:27019"]`). The Trace.tla wrappers then find the matching `newCfg \in SUBSET Server` — which works for small Server sets (≤ 4 nodes).
