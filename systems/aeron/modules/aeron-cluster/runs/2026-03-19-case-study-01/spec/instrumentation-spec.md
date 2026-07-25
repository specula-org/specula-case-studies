# Instrumentation Spec: Aeron Cluster

Maps TLA+ spec actions to source code locations for trace harness generation.

**Source root**: `artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/`

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "action": "<spec action name>",
  "node": "<server ID>",
  "from": "<source server ID (message events only)>",
  "to": "<dest server ID (message events only)>",
  "candidateTermId": <int>,
  "leadershipTermId": <int>,
  "electionState": "<INIT|CANVASS|...|LEADER_READY|FOLLOWER_READY|...>",
  "commitPosition": <int>,
  "appendPosition": <int>,
  "notifiedCommitPosition": <int>,
  "nextSessionId": <int>
}
```

### State Fields (captured at every event)

| Implementation field | TLA+ variable | Getter/Access |
|---------------------|---------------|---------------|
| `Election.candidateTermId` | `candidateTermId` | `election.candidateTermId()` (package-private) |
| `Election.leadershipTermId` | `leadershipTermId` | `election.leadershipTermId()` (package-private) |
| `Election.state` | `electionState` | `election.state().name()` |
| `ConsensusModuleAgent.commitPosition` | `commitPosition` | `commitPosition.get()` (counter) |
| `ConsensusModuleAgent.logRecordingStopPosition` or archive counter | `appendPosition` | `appendPosition.get()` (counter) |
| `ConsensusModuleAgent.notifiedCommitPosition` | `notifiedCommitPosition` | field access (package-private) |
| `ConsensusModuleAgent.nextSessionId` | `nextSessionId` | `sessionManager.nextSessionId()` |

### Message Fields (event-specific)

| Implementation field | TLA+ field | Notes |
|---------------------|------------|-------|
| `candidateTermId` (in RequestVote) | `mcandidateTermId` | From consensus message |
| `leadershipTermId` (in NLT/CommitPos) | `mleadershipTermId` | From consensus message |
| `logLeadershipTermId` | `mlogLeadershipTermId` | Term of last log entry |
| `logPosition` | `mlogPosition` | Log position in message |
| `commitPosition` (in NLT/CommitPos) | `mcommitPosition` | Leader's commit position |
| `vote` (in RequestVoteResponse) | `mvote` | Boolean TRUE/FALSE |
| `nextTermBaseLogPosition` (in NLT) | `mnextTermBaseLogPosition` | Truncation point |

## Section 2: Action-to-Code Mapping

### Election Actions

#### 1. EnterCanvass
- **Code location**: `Election.java:647-692` (init state handler)
- **Trigger point**: After state transition to CANVASS (line ~690)
- **Trace event name**: `"EnterCanvass"`
- **Fields**: node, candidateTermId, electionState
- **Notes**: Fires once when election starts. Read persisted candidateTermId from NodeStateFile first.

#### 2. SendCanvassPosition
- **Code location**: `Election.java:694-724` (canvass state handler, sends to each member)
- **Trigger point**: After `consensusPublisher.canvassPosition()` call
- **Trace event name**: `"SendCanvassPosition"`
- **Fields**: from (=node), to (=target member), mlogLeadershipTermId, mlogPosition, mleadershipTermId
- **Notes**: May fire multiple times per canvass cycle (once per peer).

#### 3. HandleCanvassPosition
- **Code location**: `Election.java:290-338` (onCanvassPosition)
- **Trigger point**: After processing the canvass message (after member position update, line 310)
- **Trace event name**: `"HandleCanvassPosition"`
- **Fields**: from (=followerMemberId), to (=node), electionState, candidateTermId
- **Notes**: Three branches (non-leader, leader-send-NLT, leader-step-down). Capture electionState to distinguish.

#### 4. Nominate
- **Code location**: `Election.java:726-746` (nominate state handler)
- **Trigger point**: After `proposeMaxCandidateTermId()` and state transition (line 731)
- **Trace event name**: `"Nominate"`
- **Fields**: node, candidateTermId (new value), electionState (=CANDIDATE_BALLOT), appendPosition
- **Notes**: Self-vote is implicit. RequestVote messages sent immediately after.

#### 5. HandleRequestVote
- **Code location**: `Election.java:340-387` (onRequestVote)
- **Trigger point**: After `placeVote()` call (line 359, 366, or 384)
- **Trace event name**: `"HandleRequestVote"`
- **Fields**: from (=candidateId), to (=node), candidateTermId, electionState, mvote (TRUE/FALSE)
- **Notes**: Four cases (stale deny, log deny, grant, silent drop). Only emit for cases 1-3 (where placeVote fires). Case 4 (silent drop) is not traced.

#### 6. HandleRequestVoteResponse
- **Code location**: `Election.java:748-788` (candidateBallot, vote collection)
- **Trigger point**: After recording the vote in ClusterMember
- **Trace event name**: `"HandleRequestVoteResponse"`
- **Fields**: from (=voter), to (=node), mcandidateTermId, mvote
- **Notes**: Only fire if candidateTermId matches (stale responses are dropped).

#### 7. BecomeLeader
- **Code location**: `Election.java:752-756 or 761-764` (candidateBallot → leader transition)
- **Trigger point**: After `electionComplete()` / state transition to LEADER_*
- **Trace event name**: `"BecomeLeader"`
- **Fields**: node, candidateTermId, leadershipTermId (=candidateTermId), electionState
- **Notes**: Fires for both unanimous (line 752) and quorum (line 761) paths.

#### 8. HandleNewLeadershipTerm
- **Code location**: `Election.java:417-539` (onNewLeadershipTerm)
- **Trigger point**: After state transition (line 524 FOLLOWER_REPLAY or line 489 FOLLOWER_LOG_REPLICATION)
- **Trace event name**: `"HandleNewLeadershipTerm"`
- **Fields**: from (=leaderMemberId), to (=node), mleadershipTermId, candidateTermId, leadershipTermId, electionState, appendPosition, commitPosition
- **Notes**: Capture appendPosition AFTER truncation (if any). The truncation at lines 454-466 modifies log before state updates.

### Log Replication Actions

#### 9. ClientRequest
- **Code location**: `ConsensusModuleAgent.java:2417` (ingressAdapter poll → log append)
- **Trigger point**: After log entry is appended (after `logPublisher.appendMessage()`)
- **Trace event name**: `"ClientRequest"`
- **Fields**: node, appendPosition, leadershipTermId
- **Notes**: Only fires on leader. Each client message that creates a log entry.

#### 10. LeaderAppendSessionOpen
- **Code location**: `ConsensusModuleAgent.java` — session open processing
- **Trigger point**: After session open entry appended to log
- **Trace event name**: `"LeaderAppendSessionOpen"`
- **Fields**: node, appendPosition, nextSessionId, leadershipTermId
- **Notes**: Specifically for session-open entries. nextSessionId is incremented on append (before commit).

#### 11. FollowerReplicateLog
- **Code location**: `ConsensusModuleAgent.java:2438-2449` (logAdapter.poll in consensusWork)
- **Trigger point**: After logAdapter.poll() returns > 0 (entries replicated)
- **Trace event name**: `"FollowerReplicateLog"`
- **Fields**: node, appendPosition
- **Notes**: May replicate multiple entries per poll. appendPosition reflects final position after batch.

#### 12. SendAppendPositionUpdate
- **Code location**: `ConsensusModuleAgent.java:2455` (updateFollowerPosition)
- **Trigger point**: After `consensusPublisher.appendPosition()` call
- **Trace event name**: `"SendAppendPositionUpdate"`
- **Fields**: from (=node), to (=leader), mlogPosition (=appendPosition)
- **Notes**: Periodic. May not fire on every poll cycle.

#### 13. HandleAppendPositionUpdate
- **Code location**: `ConsensusModuleAgent.java` via `ConsensusAdapter.onAppendPosition()`
- **Trigger point**: After member position updated
- **Trace event name**: `"HandleAppendPositionUpdate"`
- **Fields**: from (=follower), to (=node/leader), mlogPosition
- **Notes**: Leader-only event.

#### 14. LeaderAdvanceCommitPosition
- **Code location**: `ConsensusModuleAgent.java:2822-2847` (updateLeaderPosition)
- **Trigger point**: After `commitPosition.proposeMaxRelease(quorumPosition)` (line 2839)
- **Trace event name**: `"LeaderAdvanceCommitPosition"`
- **Fields**: node, commitPosition (new value), appendPosition
- **Notes**: Only fires when quorumPosition > current commitPosition.

#### 15. PublishCommitPosition
- **Code location**: `ConsensusModuleAgent.java:2849-2858` (publishCommitPosition)
- **Trigger point**: After broadcast loop completes
- **Trace event name**: `"PublishCommitPosition"`
- **Fields**: node, commitPosition, leadershipTermId
- **Notes**: Broadcasts to all followers. Combine with LeaderAdvanceCommitPosition if they always co-occur.

#### 16. FollowerReceiveCommitPosition
- **Code location**: `ConsensusModuleAgent.java:1076-1083` (onCommitPosition, non-election)
- **Trigger point**: After `notifiedCommitPosition` update (line 1079)
- **Trace event name**: `"FollowerReceiveCommitPosition"`
- **Fields**: from (=leaderMemberId), to (=node), mcommitPosition, commitPosition (post-update), notifiedCommitPosition, nextSessionId
- **Notes**: Captures both notifiedCommitPosition and the resulting commitPosition advancement.

#### 17. ElectionReceiveCommitPosition
- **Code location**: `Election.java:563-594` (onCommitPosition during election)
- **Trigger point**: After `notifiedCommitPosition` update (line 576)
- **Trace event name**: `"ElectionReceiveCommitPosition"`
- **Fields**: from (=leaderMemberId), to (=node), mcommitPosition, notifiedCommitPosition
- **Notes**: Intentionally skips leadershipTermId check (MC-5).

### Fault Events

#### 18. Timeout
- **Code location**: `ConsensusModuleAgent.java:2968-3002` (enterElection)
- **Trigger point**: At start of enterElection()
- **Trace event name**: `"Timeout"`
- **Fields**: node, electionState (previous state before reset)
- **Notes**: Triggered by heartbeat timeout or leader failure detection.

#### 19. Crash
- **Code location**: N/A (simulated by test harness killing the agent)
- **Trigger point**: Before agent shutdown
- **Trace event name**: `"Crash"`
- **Fields**: node
- **Notes**: Must be emitted by the test harness, not the agent itself (agent may not get a chance). Followed by recovery event when agent restarts.

## Section 3: Special Considerations

### 1. Aeron's Event Loop Architecture
- `ConsensusModuleAgent` runs on a single thread via Agrona's `Agent` pattern
- All events are processed sequentially within `doWork()` → no concurrent interleaving within a node
- Trace events from the same node are naturally ordered
- Cross-node events may interleave arbitrarily

### 2. Election State Mapping
The implementation has 17 election states; the spec simplifies to 7. The trace must emit the FULL implementation state name (e.g., `"LEADER_READY"`, `"FOLLOWER_LOG_REPLICATION"`). The trace spec's `MapElectionState` function handles the mapping.

### 3. Archive-Based Log Replication
- Aeron replicates logs via Archive recordings, not direct message passing
- The trace harness must intercept Archive subscription events to detect when a follower replicates entries
- `FollowerReplicateLog` events may represent batch copies (multiple entries per event)
- Use `appendPosition` (from the archive counter) to track replication progress

### 4. Position vs Index
- Aeron uses byte-offset positions (not entry indices) for log positions
- The spec uses entry count (Len(log)) as position
- The trace preprocessor must convert byte positions to entry counts
- Alternatively, track entry count separately via a counter in the harness

### 5. Bootstrap State
- A fresh cluster starts with `candidateTermId = 0`, `leadershipTermId = 0`
- A recovering node reads `candidateTermId` from `NodeStateFile` and leadership terms from `RecordingLog`
- The first trace event should include an `init` field with persisted state if non-zero

### 6. Session ID Tracking (Family 5)
- Leader increments `nextSessionId` in `ConsensusModuleAgent.onOpenSession()` (on append)
- Follower increments during `LogAdapter` replay of committed session-open entries
- Trace must capture `nextSessionId` at both points to validate divergence

### 7. Message Delivery
- Aeron uses reliable IPC/UDP channels — messages are not lost in normal operation
- For trace validation, the harness should NOT inject message loss
- Silent `LoseMessage` in the trace spec handles messages that were sent but never processed (e.g., due to election state changes)

### 8. Commit Position Counter
- `commitPosition` is a `ReadableCounter` / `ReleaseableCounter`
- Read via `commitPosition.get()` (volatile read) or `getPlain()` (relaxed)
- For tracing, use `get()` for consistency
