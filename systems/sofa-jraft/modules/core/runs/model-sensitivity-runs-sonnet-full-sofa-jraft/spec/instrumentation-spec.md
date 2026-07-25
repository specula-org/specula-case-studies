# Instrumentation Spec: sofa-jraft

Action-to-code mapping for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single NDJSON line with these top-level fields:

```json
{
  "event":  "<event-name>",
  "node":   "<server-id>",          // e.g. "s1", "node-0"
  "ts":     <monotone-counter>,     // logical clock — not wall time
  ... event-specific fields ...
}
```

### State Fields (captured at every event)

| Trace field | TLA+ variable | Java source | Notes |
|---|---|---|---|
| `currentTerm` | `currentTerm[s]` | `NodeImpl.currTerm` | Read under node lock |
| `role` | `role[s]` | `NodeImpl.state.name()` | "Leader" / "Candidate" / "Follower" |
| `commitIndex` | `commitIndex[s]` | `BallotBox.lastCommittedIndex` | |
| `lastApplied` | `lastApplied[s]` | `FSMCallerImpl.lastAppliedIndex` | AtomicLong; read without lock |
| `lastLogIndex` | `LastLogIndex(s)` | `LogManagerImpl.lastLogIndex` | `getLastLogIndex()` |
| `persistedTerm` | `persistedTerm[s]` | `LocalRaftMetaStorage.term` | After `setTermAndVotedFor` / `setVotedFor` |
| `persistedVotedFor` | `persistedVotedFor[s]` | `LocalRaftMetaStorage.votedFor.id` | "nil" if empty peer |
| `snapshotIndex` | `snapshotIndex[s]` | `SnapshotExecutorImpl.lastSnapshotIndex` | |
| `pendingReadCount` | `Cardinality(pendingReadIndex[s])` | `ReadOnlyServiceImpl.pendingNotifyStatus.size()` | |
| `lastLeaderContact` | `lastLeaderContact[s]` | `NodeImpl.lastLeaderTimestamp` | `Utils.monotonicMs()` mapped to logical clock |

### Message Fields (event-specific)

For vote and AppendEntries messages, capture the key envelope fields:

| Field | Java | Notes |
|---|---|---|
| `srcNode` | `request.getServerId().toString()` | |
| `dstNode` | `request.getPeerId().toString()` | |
| `msgTerm` | `request.getTerm()` | |
| `granted` | `response.getGranted()` | RequestVote only |
| `success` | `response.getSuccess()` | AppendEntries / InstallSnapshot |
| `prevLogIndex` | `request.getPrevLogIndex()` | AppendEntries |
| `prevLogTerm` | `request.getPrevLogTerm()` | AppendEntries |
| `entriesCount` | `request.getEntriesCount()` | |
| `commitIndex` | `request.getCommittedIndex()` | AppendEntries |
| `lastIncludedIndex` | `request.getMeta().getLastIncludedIndex()` | InstallSnapshot |
| `lastIncludedTerm` | `request.getMeta().getLastIncludedTerm()` | InstallSnapshot |
| `responseTerm` | `response.getTerm()` | All response handlers |

---

## Section 2: Action-to-Code Mapping

### 1. ElectionTimeout

| Field | Value |
|---|---|
| **Spec action** | `ElectionTimeout` |
| **Event name** | `"ElectionTimeout"` |
| **Code location** | `NodeImpl.java:1101` — `handleElectionTimeout()` |
| **Trigger point** | After `electSelf()` sends RequestVote RPCs, before returning |
| **Fields** | state snapshot: `currentTerm`, `role`, `persistedTerm`, `persistedVotedFor` |
| **Notes** | Capture after `setTermAndVotedFor(term, self)` to ensure persist is complete before event |

---

### 2. HandleRequestVoteRequestDeny

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequestDeny` |
| **Event name** | `"HandleRequestVoteRequestDeny"` |
| **Code location** | `NodeImpl.java:1820–1838` — `handleRequestVoteRequest()` rejection branch |
| **Trigger point** | After sending the denied response |
| **Fields** | state snapshot + `msgTerm`, `srcNode`, `granted=false` |

---

### 3. HandleRequestVoteRequestGrantSameTerm

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequestGrantSameTerm` |
| **Event name** | `"HandleRequestVoteRequestGrantSameTerm"` |
| **Code location** | `NodeImpl.java:1838–1855` — same-term grant branch |
| **Trigger point** | After `setVotedFor(candidateId)` returns and response is sent |
| **Fields** | state snapshot + `persistedVotedFor`, `srcNode`, `granted=true` |
| **Notes** | Same-term path is a single write; capture after `setVotedFor` completes |

---

### 4. PersistTermEmptyVote (Family 1 — Write 1 of 2)

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequestHigherTermStep1` |
| **Event name** | `"PersistTermEmptyVote"` |
| **Code location** | `NodeImpl.java:1856` — inside `stepDown()`: after `setTermAndVotedFor(term, emptyPeer)` returns |
| **Trigger point** | Immediately after the first disk write completes; BEFORE `setVotedFor(candidateId)` |
| **Fields** | `currentTerm`, `role`, `persistedTerm`, `persistedVotedFor` (should be "nil"), `srcNode` |
| **Notes** | This is the crash-window event for Family 1. Capture state BETWEEN the two disk writes. If a crash occurs here, the node restarts with `persistedVotedFor=nil` at the higher term, allowing a re-vote. |

---

### 5. PersistActualVote (Family 1 — Write 2 of 2)

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequestHigherTermStep2` |
| **Event name** | `"PersistActualVote"` |
| **Code location** | `NodeImpl.java:1860` — after `setVotedFor(candidateId)` returns |
| **Trigger point** | After second disk write; BEFORE response is sent |
| **Fields** | `persistedTerm`, `persistedVotedFor` (should equal `srcNode`), `srcNode` |

---

### 6. SendVoteGranted (Family 1 — Response)

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteRequestHigherTermStep3` |
| **Event name** | `"SendVoteGranted"` |
| **Code location** | `NodeImpl.java:1861` — immediately after response is sent |
| **Trigger point** | After `done.sendResponse(response)` with `granted=true` |
| **Fields** | state snapshot, `msgTerm`, `srcNode`, `granted=true` |

---

### 7. HandleRequestVoteResponse

| Field | Value |
|---|---|
| **Spec action** | `HandleRequestVoteResponse` |
| **Event name** | `"HandleRequestVoteResponse"` |
| **Code location** | `NodeImpl.java:1774–1815` — `handleRequestVoteResponse()` |
| **Trigger point** | After processing the response (state update + possible BecomeLeader) |
| **Fields** | state snapshot, `msgTerm`, `srcNode`, `granted` |

---

### 8. Crash

| Field | Value |
|---|---|
| **Spec action** | `Crash` |
| **Event name** | `"Crash"` |
| **Code location** | Test harness — before `Process.destroy()` or `node.shutdown()` |
| **Trigger point** | Immediately before killing the process |
| **Fields** | state snapshot |
| **Notes** | Emitted by test harness, not application code. Node ID must match the node being killed. |

---

### 9. RestartFromPersisted

| Field | Value |
|---|---|
| **Spec action** | `RestartFromPersisted` |
| **Event name** | `"RestartFromPersisted"` |
| **Code location** | `NodeImpl.java:init()` — after `raftOptions.getRaftMetaStorage().loadMeta()` returns |
| **Trigger point** | After durable state is loaded, before any RPCs are sent |
| **Fields** | `currentTerm`, `role` (should be "Follower"), `persistedTerm`, `persistedVotedFor` |
| **Notes** | Validates that in-memory term/votedFor were correctly restored from disk. |

---

### 10. ClientRequest

| Field | Value |
|---|---|
| **Spec action** | `ClientRequest` |
| **Event name** | `"ClientRequest"` |
| **Code location** | `NodeImpl.java:590–640` — `apply(Task task)` after leader appends |
| **Trigger point** | After `logManager.appendEntries(entries, callback)` |
| **Fields** | `lastLogIndex`, `commitIndex`, `lastApplied` |

---

### 11. HandleAppendEntriesRequest

| Field | Value |
|---|---|
| **Spec action** | `HandleAppendEntriesRequest` |
| **Event name** | `"HandleAppendEntriesRequest"` |
| **Code location** | `NodeImpl.java:1956–2062` — `handleAppendEntriesRequest()` |
| **Trigger point** | After applying entries and updating commitIndex; before sending response |
| **Fields** | state snapshot, `lastLogIndex`, `commitIndex`, `lastApplied`, `lastLeaderContact`, `prevLogIndex`, `entriesCount`, `success` |
| **Notes** | `lastLeaderContact` captures `Utils.monotonicMs()` value. Map to logical clock in preprocessor. |

---

### 12. HandleInstallSnapshotRequest (Family 3 + Family 5)

| Field | Value |
|---|---|
| **Spec action** | `HandleInstallSnapshotRequest` |
| **Event name** | `"HandleInstallSnapshotRequest"` |
| **Code location** | `NodeImpl.java:3355–3422` — `handleInstallSnapshotRequest()` |
| **Trigger point** | After snapshot metadata is accepted; before sending response |
| **Fields** | state snapshot, `snapshotIndex`, `lastIncludedIndex`, `lastIncludedTerm`, `lastLeaderContact` |
| **Notes** | Family 5 bug: `lastLeaderContact` is NOT updated here. Capture its value to confirm it is unchanged (same as before the call). Family 3 bug: `pendingReadCount` should NOT decrease here (notification missing). |

---

### 13. HandleInstallSnapshotResponseNormal (Family 2)

| Field | Value |
|---|---|
| **Spec action** | `HandleInstallSnapshotResponseNormal` |
| **Event name** | `"HandleInstallSnapshotResponseNormal"` |
| **Code location** | `Replicator.java:711–761` — `onInstallSnapshotReturned()` |
| **Trigger point** | After processing the response (no term check in this path) |
| **Fields** | state snapshot (`role` should still be "Leader"), `responseTerm`, `success` |
| **Notes** | Family 2 bug: even if `responseTerm > currentTerm`, `role` stays "Leader". Capture `responseTerm` to show the missing check. |

---

### 14. ServeReadIndex (Family 4)

| Field | Value |
|---|---|
| **Spec action** | `ServeReadIndex` |
| **Event name** | `"ServeReadIndex"` |
| **Code location** | `NodeImpl.java:1580–1640` — `readIndex()` / `readLeader()` |
| **Trigger point** | After read request is added to `ReadOnlyServiceImpl.pendingNotifyStatus` |
| **Fields** | state snapshot, `readIndex`, `pendingReadCount` |
| **Notes** | Single-node clusters reach the fast-path at lines 1599–1607, skipping the no-op guard. Capture `currentTerm` at time of issue (maps to `readIssuedTerm`). |

---

### 15. ApplyCommittedEntries (Families 3, 4)

| Field | Value |
|---|---|
| **Spec action** | `ApplyCommittedEntries` |
| **Event name** | `"ApplyCommittedEntries"` |
| **Code location** | `FSMCallerImpl.java:578–584` — `setLastApplied()` which calls `notifyLastAppliedIndexUpdated()` |
| **Trigger point** | After `notifyLastAppliedIndexUpdated(lastAppliedIndex)` returns |
| **Fields** | `lastApplied`, `commitIndex`, `pendingReadCount` |
| **Notes** | This is the NORMAL apply path (not snapshot). Pending reads at indices ≤ `lastApplied` should be resolved. Capture `pendingReadCount` before and after to validate notification. |

---

### 16. StepDown (Family 4)

| Field | Value |
|---|---|
| **Spec action** | `StepDown` |
| **Event name** | `"StepDown"` |
| **Code location** | `NodeImpl.java:1301–1360` — `stepDown()` |
| **Trigger point** | After `replicatorGroup.stopAll()` and `ballotBox.clearPendingTasks()` |
| **Fields** | state snapshot, `pendingReadCount` |
| **Notes** | Family 4 bug: `pendingReadCount` should remain non-zero (ReadOnlyService NOT cleared). Capture to confirm pending reads survive step-down. |

---

## Section 3: Special Considerations

### 3.1 Two-Write Crash Window Instrumentation (Family 1)

The Family 1 bug requires instrumenting BETWEEN two disk writes in `handleRequestVoteRequest`. The instrumentation must:

1. Insert a probe after `LocalRaftMetaStorage.setTermAndVotedFor(term, emptyPeer)` (Write 1) — emits `"PersistTermEmptyVote"`.
2. Insert a probe after `LocalRaftMetaStorage.setVotedFor(candidateId)` (Write 2) — emits `"PersistActualVote"`.
3. To reproduce the crash scenario in tests: use a `Semaphore` or `CountDownLatch` in the storage implementation to pause between the two writes, then inject a crash.

The test harness should exercise this path by:
- Starting a 3-node cluster
- Partitioning the candidate's RequestVote so it reaches a peer at a higher term
- Injecting a kill signal between the two disk writes (using the semaphore)
- Restarting the node and checking if it votes again

### 3.2 ReadIndex Pending-Closure Lifecycle (Families 3, 4)

`ReadOnlyServiceImpl.pendingNotifyStatus` is a concurrent map. The `pendingReadCount` field in trace events must be captured under the service's internal lock or as an AtomicInteger snapshot. The count should:
- Increase on `readIndex()` call (ServeReadIndex event)
- Decrease on `ApplyCommittedEntries` (normal path)
- NOT decrease on `HandleInstallSnapshotRequest` (Family 3 bug)
- NOT decrease on `StepDown` (Family 4 bug)

### 3.3 lastLeaderContact Mapping

`NodeImpl.lastLeaderTimestamp` is a volatile long (wall clock in milliseconds). The trace spec uses a logical monotone counter. The harness preprocessor must:
- Assign logical timestamps by order of events (monotone increment)
- Map `lastLeaderTimestamp` to logical clock increments
- Alternatively, capture the raw ms value and compare relative ordering

### 3.4 EBUSY Response Instrumentation (Family 2)

`Replicator.onAppendEntriesReturned` EBUSY path (lines 1454–1466) does not have its own dedicated response message in the normal flow. To instrument:
- Override `RaftServiceImpl` to return `EBUSY` with an elevated term in the response
- Instrument the early-return path at line 1466 to emit `"HandleAppendEntriesResponseBusy"` with `responseTerm`, `ebusy=true`, `role` (should be "Leader" — the bug)

### 3.5 Server ID Mapping

sofa-jraft uses `PeerId` objects (host:port or string IDs). The trace must normalize these to the set `{s1, s2, s3}` used in the spec. The preprocessor should maintain a mapping table built from the first events in the trace where each node ID appears as `node`.

### 3.6 Bootstrap State

On fresh cluster start, `NodeImpl.init()` sets `currentTerm=0`, `votedFor=Nil`, `role=Follower`. The spec's `Init` matches this. If the test scenario starts from a snapshot, the `RestartFromPersisted` event must appear before any other events for that node.
