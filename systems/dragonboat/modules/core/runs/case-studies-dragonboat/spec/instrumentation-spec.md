# Instrumentation Spec: lni/dragonboat

Mapping from TLA+ spec actions to source code locations.
Produced by spec generation; consumed by the instrumentation harness.

---

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with the following top-level fields:

```json
{
  "tag":   "trace",
  "event": {
    "name":  "<event-name>",
    "nid":   "<node-id>",         // acting node
    "state": { ... },             // node state snapshot (see below)
    "msg":   { ... }              // optional: only for message events
  }
}
```

### State Fields (captured at every event)

| JSON field               | Go source                          | TLA+ variable          |
|--------------------------|------------------------------------|------------------------|
| `state.term`             | `r.term`                           | `currentTerm[nid]`     |
| `state.role`             | `r.state.String()`                 | `state[nid]`           |
| `state.commitIndex`      | `r.log.committed`                  | `commitIndex[nid]`     |
| `state.lastLogIndex`     | `r.log.lastIndex()`                | `LastLogIndex(nid)`    |
| `state.lastLogTerm`      | last entry term from `r.log`       | `LastLogTerm(nid)`     |
| `state.votedFor`         | `r.vote` (0 → "")                  | `votedFor[nid]`        |
| `state.applied`          | `r.applied`                        | `applied[nid]`         |
| `state.pendingCC`        | `r.pendingConfigChange`            | `pendingConfigChange[nid]` |

### Message Fields (event-specific)

| JSON field         | Go source                   | TLA+ field            |
|--------------------|-----------------------------|-----------------------|
| `msg.from`         | `m.From`                    | `msource`             |
| `msg.to`           | `m.To`                      | `mdest`               |
| `msg.term`         | `m.Term`                    | `mterm`               |
| `msg.logIndex`     | `m.LogIndex`                | `mindex` / `mprevLogIndex` |
| `msg.logTerm`      | `m.LogTerm`                 | `mprevLogTerm`        |
| `msg.commitIndex`  | `m.Commit`                  | `mcommitIndex`        |
| `msg.reject`       | `m.Reject`                  | `mreject`             |
| `msg.hint`         | `m.Hint`                    | `mhint`               |

---

## Section 2: Action-to-Code Mapping

### 1. `Timeout` → `BecomeCandidate`

| Field         | Value                                                    |
|---------------|----------------------------------------------------------|
| Spec action   | `Timeout(i)`                                            |
| Event name    | `BecomeCandidate`                                       |
| Code location | `raft.go:1020-1035` `becomeCandidate()`                 |
| Trigger point | **After** `r.state = candidate` is set (raft.go:1030)   |
| Fields        | state snapshot (term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor) |
| Notes         | Emitted once per call to `campaign()`. The `r.vote = r.replicaID` (raft.go:1034) sets `votedFor`. |

### 2. `HandleRequestVoteRequest` → `HandleRequestVoteRequest`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleRequestVoteRequest(i, m)`                            |
| Event name    | `HandleRequestVoteRequest`                                  |
| Code location | `raft.go:1697-1721` `handleNodeRequestVote()`               |
| Trigger point | **After** `r.send(resp)` (raft.go:1720), before return      |
| Fields        | state snapshot + `msg.{from, to, term}`                     |
| Notes         | For the grant case, `votedFor` in state must reflect the new vote. |

### 3. `HandleRequestVoteResponse` → `HandleRequestVoteResponse`

| Field         | Value                                                            |
|---------------|------------------------------------------------------------------|
| Spec action   | `HandleRequestVoteResponse(i, m)`                               |
| Event name    | `HandleRequestVoteResponse`                                     |
| Code location | `raft.go:2235-2252` `handleCandidateRequestVoteResp()`          |
| Trigger point | **After** `r.votes[from] = !rejected` update (raft.go:1139), before `becomeLeader` check |
| Fields        | state snapshot + `msg.{from, to, term, reject}`                 |
| Notes         | Include self-vote events (from == nid) so the trace spec can skip them. |

### 4. `BecomeLeader` → `BecomeLeader`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `BecomeLeader(i)`                                           |
| Event name    | `BecomeLeader`                                              |
| Code location | `raft.go:1038-1050` `becomeLeader()`                        |
| Trigger point | **After** `r.appendEntries(noop)` (raft.go:1049)            |
| Fields        | state snapshot (role=Leader, lastLogIndex includes noop)    |
| Notes         | The noop entry is appended in `becomeLeader`. `lastLogIndex` must reflect the noop. |

### 5. `ClientRequest` → `ClientRequest`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `ClientRequest(i)`                                          |
| Event name    | `ClientRequest`                                             |
| Code location | `raft.go:1794-1815` `handleLeaderPropose()`, `raft.go:944-954` `appendEntries()` |
| Trigger point | **After** `r.log.append(entries)` (raft.go:950)             |
| Fields        | state snapshot (lastLogIndex updated)                       |
| Notes         | Only emit for `ApplicationEntry` proposals, not `ConfigChangeEntry`. |

### 6. `ReplicateEntries` → `SendReplicateEntries`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `ReplicateEntries(i, j)`                                    |
| Event name    | `SendReplicateEntries`                                      |
| Code location | `raft.go:738-818` `sendReplicateMessage()` → `r.send(m)`    |
| Trigger point | **After** `r.send(m)` for a `pb.Replicate` message          |
| Fields        | state snapshot + `msg.{from, to, term, logIndex, logTerm, commitIndex}` |
| Notes         | Only emit for `pb.Replicate` messages (not `pb.InstallSnapshot`). |

### 7. `SendHeartbeat` → `SendHeartbeat`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `SendHeartbeat(i, j)`                                       |
| Event name    | `SendHeartbeat`                                             |
| Code location | `raft.go:835-845` `sendHeartbeatMessage()` → `r.send(m)`    |
| Trigger point | **After** `r.send(m)` for a `pb.Heartbeat` message          |
| Fields        | state snapshot + `msg.{from, to, term, commitIndex}`        |
| Notes         | Heartbeat carries `min(match, committed)` as the commit field (raft.go:837). |

### 8. `HandleReplicateRequest` → `HandleReplicateRequest`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleReplicateRequest(i, m)`                              |
| Event name    | `HandleReplicateRequest`                                    |
| Code location | `raft.go:1444-1484` `handleReplicateMessage()`              |
| Trigger point | **After** `r.send(resp)` (raft.go:1482)                     |
| Fields        | state snapshot + `msg.{from, to, term, logIndex, logTerm, reject}` |
| Notes         | Distinguish from `handleHeartbeatMessage` by checking `pb.Replicate` message type. |

### 9. `HandleHeartbeatRequest` → `HandleHeartbeatRequest`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleHeartbeatRequest(i, m)`                              |
| Event name    | `HandleHeartbeatRequest`                                    |
| Code location | `raft.go:1400-1408` `handleHeartbeatMessage()`              |
| Trigger point | **After** `r.send(resp)` (raft.go:1407)                     |
| Fields        | state snapshot + `msg.{from, to, term}`                     |
| Notes         | `commitIndex` in state may have been updated by `r.log.commitTo(m.Commit)`. |

### 10. `HandleReplicateResponse` → `HandleReplicateResponse`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleReplicateResponse(i, m)`                             |
| Event name    | `HandleReplicateResponse`                                   |
| Code location | `raft.go:1878-1908` `handleLeaderReplicateResp()`           |
| Trigger point | **After** `rp.setActive()` (raft.go:1880), at end of function |
| Fields        | state snapshot + `msg.{from, to, term, logIndex, reject}`   |
| Notes         | Capture `active` flag set here. The `matchIndex` update (raft.go:1883) must be reflected in state. |

### 11. `HandleHeartbeatResponse` → `HandleHeartbeatResponse`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleHeartbeatResponse(i, m)`                             |
| Event name    | `HandleHeartbeatResponse`                                   |
| Code location | `raft.go:1910-1923` `handleLeaderHeartbeatResp()`           |
| Trigger point | **After** `rp.setActive()` (raft.go:1912), at end of function |
| Fields        | state snapshot + `msg.{from, to, term}`                     |
| Notes         | Weak validation only (async; state may have advanced). |

### 12. `AdvanceCommitIndex` → `AdvanceCommitIndex`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `AdvanceCommitIndex(i)`                                     |
| Event name    | `AdvanceCommitIndex`                                        |
| Code location | `raft.go:911-941` `tryCommit()`, called from `handleLeaderReplicateResp` |
| Trigger point | **After** `r.log.tryCommit(q, r.term)` returns true, i.e., after `r.log.committed` is updated |
| Fields        | state snapshot (commitIndex must reflect new committed value) |
| Notes         | Only emit when `tryCommit` actually advances the commit index (returns true). |

### 13. `CheckQuorum` → `CheckQuorum`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `CheckQuorum(i)`                                            |
| Event name    | `CheckQuorum`                                               |
| Code location | `raft.go:1785-1792` `handleLeaderCheckQuorum()`             |
| Trigger point | **After** `leaderHasQuorum()` is called (raft.go:1787), after any state change |
| Fields        | state snapshot (role may have changed to Follower if quorum lost) |
| Notes         | Emitted whether the leader stays or steps down. Critical for Bug Family 1 validation. |

### 14. `SendSnapshot` → `SendSnapshot`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `SendSnapshot(i, j)`                                        |
| Event name    | `SendSnapshot`                                              |
| Code location | `raft.go:800-818` `sendReplicateMessage()` (snapshot branch) |
| Trigger point | **After** `rp.becomeSnapshot(index)` (raft.go:813)          |
| Fields        | state snapshot + `msg.{from, to, term, logIndex}`           |
| Notes         | Emitted when log entries before `nextIndex[i][j]` have been compacted; snapshot fallback path. |

### 15. `HandleInstallSnapshot` → `HandleInstallSnapshot`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleInstallSnapshot(i, m)`                               |
| Event name    | `HandleInstallSnapshot`                                     |
| Code location | `raft.go:1411-1441` `handleInstallSnapshotMessage()`        |
| Trigger point | **After** `r.send(resp)` (raft.go:1440)                     |
| Fields        | state snapshot + `msg.{from, to, term, logIndex}`           |

### 16. `HandleSnapshotStatus` → `HandleSnapshotStatus`

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| Spec action   | `HandleSnapshotStatus(i, m)`                                |
| Event name    | `HandleSnapshotStatus`                                      |
| Code location | `raft.go:1976-1995` `handleLeaderSnapshotStatus()`          |
| Trigger point | **After** state transition (`rp.becomeWait()` at raft.go:1989), at end of function |
| Fields        | state snapshot + `msg.{from, to, term, reject}`             |
| Notes         | **Critical for Bug Family 1**: `active[i][msg.from]` is NOT set here. Capture the `active` map if possible to confirm the bug. |

---

## Section 3: Special Considerations

### 3.1 Active Flag Access

The `active` field (`remote.active`) is per-remote and lives in `r.remotes[j]`. It is not exposed through the public `Peer` interface. To trace it:
- Add a shadow field `activeMap map[uint64]bool` to the `raft` struct, updated in `setActive()` / `setNotActive()`.
- Or capture it by iterating `r.votingMembers()` after each `CheckQuorum` event.

### 3.2 Remote State Access

`r.remotes[j].state` is a `remoteStateType`. Map to trace strings:
```go
var remoteStateStr = map[remoteStateType]string{
    remoteRetry:     "Retry",
    remoteWait:      "Wait",
    remoteReplicate: "Replicate",
    remoteSnapshot:  "Snapshot",
}
```

### 3.3 Async Persistence

`saveRaftState` is called asynchronously by the engine's step worker pipeline (`engine.go`). The trace events do NOT directly correspond to `SaveRaftState` actions. The trace spec handles this via the `SilentSaveRaftState` silent action, which fires without consuming a trace event whenever `persistedLog[i]` lags `log[i]`.

For Bug Family 3 (PR #409) specifically: inject a disk error via a test hook before `saveSnapshot` is called, then verify the trace shows no persistence event but the commitIndex advanced.

### 3.4 Bootstrap State

dragonboat starts with term=0, empty log, all followers. The `TraceInit` state in `Trace.tla` matches this. No bootstrap config entry (unlike hashicorp/raft).

### 3.5 Node IDs

dragonboat node IDs are `uint64` values. In the trace JSON, represent them as strings (e.g., `"1"`, `"2"`, `"3"`). The `Server` constant in `Trace.cfg` must use the same string values.

### 3.6 Instrumentation Hook Pattern

Insert trace emission via a `TraceLogger` interface injected at node creation:

```go
type TraceLogger interface {
    Log(event TraceEvent)
}

type TraceEvent struct {
    Tag   string      `json:"tag"`
    Event TraceInner  `json:"event"`
}

type TraceInner struct {
    Name  string      `json:"name"`
    Nid   string      `json:"nid"`
    State TraceState  `json:"state"`
    Msg   *TraceMsg   `json:"msg,omitempty"`
}

type TraceState struct {
    Term          uint64 `json:"term"`
    Role          string `json:"role"`
    CommitIndex   uint64 `json:"commitIndex"`
    LastLogIndex  uint64 `json:"lastLogIndex"`
    LastLogTerm   uint64 `json:"lastLogTerm"`
    VotedFor      string `json:"votedFor"`
    Applied       uint64 `json:"applied"`
    PendingCC     bool   `json:"pendingCC"`
}

type TraceMsg struct {
    From        string `json:"from"`
    To          string `json:"to"`
    Term        uint64 `json:"term"`
    LogIndex    uint64 `json:"logIndex,omitempty"`
    LogTerm     uint64 `json:"logTerm,omitempty"`
    CommitIndex uint64 `json:"commitIndex,omitempty"`
    Reject      bool   `json:"reject,omitempty"`
    Hint        uint64 `json:"hint,omitempty"`
}
```

Inject into `internal/raft/raft.go` via a `traceLogger TraceLogger` field on the `raft` struct.

### 3.7 Goroutine Concurrency

dragonboat's worker pipeline runs step/commit/apply/snapshot workers concurrently. The `raft` struct is protected by `raftMu` (peer.go). All trace events that touch `raft` state must be emitted while holding `raftMu` to avoid races between the trace capture and state updates.
