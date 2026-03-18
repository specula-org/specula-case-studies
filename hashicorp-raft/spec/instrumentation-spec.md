# Instrumentation Spec: hashicorp/raft

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single NDJSON line:
```json
{"tag": "trace", "event": {"name": "<EventName>", "nid": "<ServerID>", "state": {...}, "msg": {...}}}
```

### State Fields (captured at every event)

| Implementation Getter | TLA+ Variable | JSON Field |
|---|---|---|
| `r.getCurrentTerm()` | `currentTerm[i]` | `state.term` |
| `r.getState().String()` | `state[i]` | `state.role` |
| `r.getCommitIndex()` | `commitIndex[i]` | `state.commitIndex` |
| `r.getLastIndex()` | `LastLogIndex(i)` | `state.lastLogIndex` |
| `r.getLastEntry().Term` | `LastLogTerm(i)` | `state.lastLogTerm` |
| `r.getLastVotedFor()` | `votedFor[i]` | `state.votedFor` |

**Note**: `getLastVotedFor()` does not exist natively. Use a shadow field `traceVotedFor` set alongside `persistVote()` and `setCurrentTerm()` calls. Empty string `""` maps to `Nil`.

### Message Fields (event-specific)

| Implementation Field | TLA+ Field | JSON Field |
|---|---|---|
| `req.Term` / `resp.Term` | `mterm` | `msg.term` |
| `source server ID` | `msource` / `msg.from` | `msg.from` |
| `dest server ID` | `mdest` / `msg.to` | `msg.to` |
| `req.PrevLogEntry` | `mprevLogIndex` | `msg.prevLogIndex` |
| `req.PrevLogTerm` | `mprevLogTerm` | `msg.prevLogTerm` |
| `req.LeaderCommitIndex` | `mcommitIndex` | `msg.commitIndex` |
| `resp.Success` | `msuccess` | `msg.success` |
| `resp.LastLog` | `mmatchIndex` | `msg.matchIndex` |
| `req.LastLogIndex` | `mlastLogIndex` | `msg.lastLogIndex` |
| `req.LastLogTerm` | `mlastLogTerm` | `msg.lastLogTerm` |
| `resp.Granted` | `mvoteGranted` | `msg.granted` |

## Section 2: Action-to-Code Mapping

### 1. BecomeCandidate (→ `Timeout`)

- **Code location**: `raft.go:electSelf()` (lines 2019-2088)
- **Trigger point**: After `setCurrentTerm(newTerm)` and `persistVote()` for self (line 2064), before sending vote requests
- **Trace event name**: `BecomeCandidate`
- **Fields**: State snapshot (term, role=Candidate, votedFor=self, commitIndex, lastLogIndex, lastLogTerm)
- **Notes**: Self-vote is logged as a separate `HandleRequestVoteResponse` event with `msg.from == msg.to`

### 2. HandleRequestVoteRequest (→ `HandleRequestVoteRequestAtomic`)

- **Code location**: `raft.go:requestVote()` (lines 1632-1776)
- **Trigger point**: After all state updates (term step-down, vote persist) and before `rpc.Respond()` returns (line 1642 deferred)
- **Trace event name**: `HandleRequestVoteRequest`
- **Fields**: State snapshot + `msg.from` (candidate), `msg.to` (this server), `msg.term` (request term)
- **Notes**: The leader-check rejection (line 1691) still emits this event. Atomic variant used for trace validation.

### 3. HandleRequestVoteResponse (→ `HandleRequestVoteResponse`)

- **Code location**: `raft.go:runCandidate()` (lines 364-383)
- **Trigger point**: After processing the vote response (incrementing tally or stepping down)
- **Trace event name**: `HandleRequestVoteResponse`
- **Fields**: State snapshot + `msg.from` (voter), `msg.to` (this candidate), `msg.term`, `msg.granted`
- **Notes**:
  - Self-vote: `msg.from == msg.to`, handled by `electSelf()` line 2068. Trace spec skips this (already in Timeout).
  - Transport failure: impl logs the event even on RPC error (with granted=false). Trace spec handles missing message.

### 4. BecomeLeader (→ `BecomeLeader`)

- **Code location**: `raft.go:runCandidate()` (line 377-383) → `setState(Leader)`
- **Trigger point**: After `setState(Leader)` and `setLeader()` (line 383), before `runLeader()` starts
- **Trace event name**: `BecomeLeader`
- **Fields**: State snapshot (role=Leader)
- **Notes**: No message fields needed. Noop append happens inside `runLeader()` and is handled by `FillLogGap`.

### 5. SendReplicateEntries (→ `ReplicateEntries`)

- **Code location**: `replication.go:replicateTo()` (lines 202-323)
- **Trigger point**: After `setupAppendEntries()` builds the request, before `trans.AppendEntries()` call (line 232)
- **Trace event name**: `SendReplicateEntries`
- **Fields**: State snapshot + `msg.to` (follower), `msg.term`, `msg.prevLogIndex`, `msg.prevLogTerm`, `msg.commitIndex`
- **Notes**: Entry contents are NOT logged (too large). The spec infers entries from leader's log and nextIndex.

### 6. SendHeartbeat (→ `SendHeartbeat`)

- **Code location**: `replication.go:heartbeat()` (lines 416-483)
- **Trigger point**: Before `trans.AppendEntries()` call for heartbeat (line 454)
- **Trace event name**: `SendHeartbeat`
- **Fields**: State snapshot (weak: term + role only) + `msg.to` (follower), `msg.term`
- **Notes**: No `prevLogIndex` field in trace (Go omitempty on zero values). This is used by `HandleAppendEntriesRequestIfLogged` to distinguish heartbeat from replicate.

### 7. HandleAppendEntriesRequest (→ `HandleAppendEntriesRequest`)

- **Code location**: `raft.go:appendEntries()` (lines 1458-1610)
- **Trigger point**: After all state updates (term step-down, log append/truncate, commitIndex advance) and before `rpc.Respond()` (line 1462 deferred)
- **Trace event name**: `HandleAppendEntriesRequest`
- **Fields**: State snapshot + `msg.from` (leader), `msg.to` (this server), `msg.term`
- **Notes**:
  - For replicate: include `msg.prevLogIndex` in trace. For heartbeat: omit (zero-value omitempty).
  - Heartbeat does NOT advance commitIndex (replication.go:164-168). Trace validation uses presence/absence of `prevLogIndex` to distinguish.

### 8. HandleReplicateResponse (→ `HandleReplicateResponse`)

- **Code location**: `replication.go:replicateTo()` (lines 240-280)
- **Trigger point**: After processing response (matchIndex update or nextIndex decrement), before next loop iteration
- **Trace event name**: `HandleReplicateResponse`
- **Fields**: State snapshot (weak: term + role) + `msg.from` (follower), `msg.to` (leader), `msg.term`, `msg.success`, `msg.matchIndex`
- **Notes**:
  - `msg.matchIndex` is the follower's `resp.LastLog` on success, 0 on failure. Used by trace spec to find the right message in the bag.
  - Stale term response (replication.go:250 `handleStaleTerm`): emit before step-down.

### 9. HandleHeartbeatResponse (→ `HandleHeartbeatResponse`)

- **Code location**: `replication.go:heartbeat()` (lines 458-480)
- **Trigger point**: After `setLastContact()` call (line 462), on successful heartbeat RPC return
- **Trace event name**: `HandleHeartbeatResponse`
- **Fields**: State snapshot (weak: term + role) + `msg.from` (follower), `msg.to` (leader)
- **Notes**: This is where Bug #666 lives. No resp.Term check — just records contact.

### 10. AdvanceCommitIndex (→ `AdvanceCommitIndex`)

- **Code location**: `commitment.go:recalculate()` (lines 88-104) via `match()` call
- **Also**: `raft.go:795-859` (leaderLoop commitCh case)
- **Trigger point**: After `commitIndex` advances (commitment.go:101), when `commitCh` is notified
- **Trace event name**: `AdvanceCommitIndex`
- **Fields**: State snapshot (including new commitIndex)
- **Notes**: The commitment tracker runs asynchronously from replication goroutines. The `SilentHandleReplicateResponse` silent action in Trace.tla handles the case where matchIndex is updated before this event appears.

### 11. ProposeConfigChange (→ `ProposeConfigChange`)

- **Code location**: `raft.go:905-912` (leaderLoop configurationChangeChIfStable case)
- **Trigger point**: After config log entry is appended to leader's log
- **Trace event name**: `ProposeConfigChange`
- **Fields**: State snapshot + `msg.to` (the server being added/removed)
- **Notes**: Only fires when `latestIndex == committedIndex` (one at a time constraint). The `msg.to` field identifies the target server, not a message destination.

## Section 3: Special Considerations

### 3.1 Bootstrap State

hashicorp/raft's `BootstrapCluster` (api.go:309-370) creates initial state that differs from the base spec's `Init`:
- **Term**: Starts at 1 (not 0)
- **Log**: Contains one ConfigEntry at index 1 with term 1 and all servers
- **persistedTerm**: 1 (persisted via stable store during bootstrap)

`TraceInit` in `Trace.tla` reflects this bootstrap state.

### 3.2 Concurrent Goroutines

hashicorp/raft runs multiple goroutines whose events may interleave:
1. **Main goroutine**: Handles most state machine logic (elections, client requests, commit advancement)
2. **Per-peer replication goroutine**: Sends AppendEntries, processes responses, calls `commitment.match()`
3. **Per-peer heartbeat goroutine**: Independent heartbeat sending, `setLastContact()` on success

The trace must serialize these events. Key interleaving patterns handled by silent actions:
- **SilentTimeout**: Concurrent elections serialize vote requests before candidate's BecomeCandidate
- **SilentHandleReplicateResponse**: Replication goroutine updates matchIndex before main goroutine processes commitCh
- **FillLogGap**: Noop append in `runLeader()` or `Apply()` without explicit trace event

### 3.3 Shadow Fields

Some state is not directly accessible via public getters:
- **`votedFor`**: Use a shadow field `traceVotedFor` (string). Set it:
  - In `requestVote()` after `persistVote()` (line 1768): `traceVotedFor = string(candidateBytes)`
  - In `requestVote()` after `setCurrentTerm()` when term changes (line 1709): `traceVotedFor = ""`
  - In `electSelf()` after `persistVote()` (line 2064): `traceVotedFor = string(r.localAddr)`
- **`lastContact`**: Per-follower `followerReplication.LastContact()` — used by lease check, not needed for trace events

### 3.4 Go `omitempty` Behavior

Go's JSON marshaling with `omitempty` tag omits zero-value fields:
- `prevLogIndex: 0` → field absent in JSON
- `commitIndex: 0` → field absent in JSON
- `matchIndex: 0` → field absent in JSON

The trace spec uses field presence/absence to distinguish heartbeat from replicate messages:
- Heartbeat: `prevLogIndex` absent (zero-value omitted)
- Replicate: `prevLogIndex` present (always >= 1 in practice)

### 3.5 Node ID Encoding

hashicorp/raft uses `ServerID` (string) and `ServerAddress` (string) as separate types. For tracing:
- Use `ServerID` as the canonical node identifier (`nid`, `msg.from`, `msg.to`)
- Map to TLA+ `Server` constants: `"s1"`, `"s2"`, `"s3"` etc.
- In test harness, assign short IDs during node creation
