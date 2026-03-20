---- MODULE Trace ----
\* Trace validation spec for RethinkDB Raft implementation.
\* Replays NDJSON traces from instrumented code against the base spec.
\*
\* Approach: deadlock-based completion checking (INIT/NEXT, not SPECIFICATION).
\* The trace is fully consumed when TLC reports deadlock at traceIdx = Len(TraceLog) + 1.
\*
\* Post-state validation uses a deferred invariant: each traced action records the
\* expected post-state in _postCheck, and TracePostStateValid checks it after each step.
\* This avoids TLC's variable-in-primed-context issue with logline/traceIdx.

EXTENDS base, Json, IOUtils, Sequences, Naturals, TLC

\* ============================================================================
\* Trace Loading
\* ============================================================================

\* Trace file path: override via IOEnv.JSON
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load trace from NDJSON file
JsonLog == ndJsonDeserialize(JsonFile)

\* Filter to only raft events (tag = "raft")
TraceLog == SelectSeq(JsonLog, LAMBDA x : x.tag = "raft")

\* ============================================================================
\* Cursor Variable
\* ============================================================================

VARIABLE traceIdx   \* cursor into TraceLog; 1..Len(TraceLog)
VARIABLE _postCheck \* expected post-state record or "none"

traceVars == <<allVars, traceIdx, _postCheck>>

\* Current log line (use only in non-primed contexts: event matching, CHOOSE, etc.)
logline == TraceLog[traceIdx]

\* ============================================================================
\* Server Set Extraction
\* ============================================================================

\* Derive Server set from the trace (handles events with node, from, or to fields)
TraceServer ==
    LET nodeIds == {TraceLog[i].node : i \in {j \in 1..Len(TraceLog) : "node" \in DOMAIN TraceLog[j]}}
        fromIds == {TraceLog[i].from : i \in {j \in 1..Len(TraceLog) : "from" \in DOMAIN TraceLog[j]}}
        toIds   == {TraceLog[i].to   : i \in {j \in 1..Len(TraceLog) : "to"   \in DOMAIN TraceLog[j]}}
    IN nodeIds \cup fromIds \cup toIds

\* ============================================================================
\* Role/Type Mapping
\* ============================================================================

\* Map implementation role strings to spec state
MapRole(r) ==
    CASE r = "follower"  -> "follower"
      [] r = "candidate" -> "candidate"
      [] r = "leader"    -> "leader"

\* Map implementation log entry type to spec type
MapEntryType(t) ==
    CASE t = "regular" -> "regular"
      [] t = "config"  -> "config"
      [] t = "noop"    -> "noop"

\* ============================================================================
\* Event Predicates
\* ============================================================================

IsEvent(name) == traceIdx <= Len(TraceLog) /\ logline.event = name

\* Guard: ensure snapshot is aligned before consuming an event whose state
\* shows a snapshotIndex for this server. If the trace shows a higher
\* snapshotIndex, SilentTakeSnapshot must fire first.
SnapshotAligned(s) ==
    IF "state" \in DOMAIN logline /\ "snapshotIndex" \in DOMAIN logline.state
    THEN IF "node" \in DOMAIN logline /\ logline.node = s
         THEN snapshotIndex[s] >= logline.state.snapshotIndex
         ELSE TRUE
    ELSE TRUE

IsNodeEvent(name, s) ==
    /\ logline.event = name
    /\ logline.node = s

IsMsgEvent(name, from, to) ==
    /\ logline.event = name
    /\ logline.from = from
    /\ logline.to = to

\* ============================================================================
\* Post-State Check Helpers
\* ============================================================================

\* Build a post-state check record from a logline (evaluated in current state as assignment)
\* Note: lastLogIndex in trace is absolute (snapshotIndex + Len(log))
PostCheckFull(s, ll) ==
    [node |-> s,
     expectedTerm |-> ll.state.currentTerm,
     expectedRole |-> MapRole(ll.state.role),
     expectedCI   |-> ll.state.commitIndex,
     expectedLLI  |-> ll.state.lastLogIndex,
     weak         |-> FALSE]

PostCheckWeak(s, ll) ==
    [node |-> s,
     expectedTerm |-> ll.state.currentTerm,
     expectedRole |-> MapRole(ll.state.role),
     expectedCI   |-> 0,
     expectedLLI  |-> 0,
     weak         |-> TRUE]

NoPostCheck == [node |-> "", expectedTerm |-> 0, expectedRole |-> "",
                expectedCI |-> 0, expectedLLI |-> 0, weak |-> TRUE]

\* Invariant: verify post-state matches expectations (checked after each step)
\* Uses only current-state variables — no primed vars, no traceIdx access
\* lastLogIndex in trace is absolute (= snapshotIndex + Len(log))
TracePostStateValid ==
    _postCheck.node /= "" =>
        LET s == _postCheck.node IN
        /\ currentTerm[s] = _postCheck.expectedTerm
        /\ (_postCheck.weak \/ state[s] = _postCheck.expectedRole)
        /\ (_postCheck.weak \/ commitIndex[s] = _postCheck.expectedCI)
        /\ (_postCheck.weak \/ LastIndex(s) = _postCheck.expectedLLI)

\* ============================================================================
\* Trace Action Wrappers
\* ============================================================================

\* --- TraceTimeout: server starts election ---
TraceTimeout ==
    /\ IsEvent("timeout")
    /\ \E s \in Server :
          /\ logline.node = s
          /\ Timeout(s)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceRequestVote: candidate sends RequestVote RPC ---
TraceRequestVote ==
    /\ IsEvent("request_vote_send")
    /\ LET ll == logline
           s == ll.from
           t == ll.to
       IN /\ RequestVote(s, t)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleRequestVoteRequest: server handles RequestVote ---
TraceHandleRequestVoteRequest ==
    /\ IsEvent("request_vote_recv")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "RequestVoteRequest"
                       /\ msg.to = s
                       /\ msg.from = ll.from
                       /\ msg.term = ll.msg_term
             IN /\ HandleRequestVoteRequest(s, m)
                /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleRequestVoteResponse: candidate processes vote reply ---
TraceHandleRequestVoteResponse ==
    /\ IsEvent("request_vote_response")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "RequestVoteResponse"
                       /\ msg.to = s
                       /\ msg.from = ll.from
             IN /\ HandleRequestVoteResponse(s, m)
                /\ _postCheck' = PostCheckWeak(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceStartVirtualHeartbeat: leader sends VHB ---
TraceStartVirtualHeartbeat ==
    /\ IsEvent("virtual_heartbeat_start")
    /\ LET ll == logline
           leader == ll.from
           follower == ll.to
       IN /\ StartVirtualHeartbeat(leader, follower)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceStopVirtualHeartbeat: VHB stops ---
TraceStopVirtualHeartbeat ==
    /\ IsEvent("virtual_heartbeat_stop")
    /\ LET ll == logline
           leader == ll.from
           follower == ll.to
       IN /\ StopVirtualHeartbeat(leader, follower)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceClientRequest: leader receives client request ---
TraceClientRequest ==
    /\ IsEvent("client_request")
    /\ LET ll == logline
           s == ll.node
           v == ll.value
       IN /\ ClientRequest(s, v)
          /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceAppendEntries: leader sends AppendEntries RPC ---
TraceAppendEntries ==
    /\ IsEvent("append_entries_send")
    /\ LET ll == logline
           s == ll.from
           t == ll.to
       IN /\ AppendEntries(s, t)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleAppendEntriesRequest: server handles AE ---
TraceHandleAppendEntriesRequest ==
    /\ IsEvent("append_entries_recv")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "AppendEntriesRequest"
                       /\ msg.to = s
                       /\ msg.from = ll.from
             IN /\ HandleAppendEntriesRequest(s, m)
                /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleAppendEntriesResponse: leader processes AE reply ---
TraceHandleAppendEntriesResponse ==
    /\ IsEvent("append_entries_response")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "AppendEntriesResponse"
                       /\ msg.to = s
                       /\ msg.from = ll.from
             IN /\ HandleAppendEntriesResponse(s, m)
                /\ _postCheck' = PostCheckWeak(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceCompleteStepDown: async step-down coroutine executes ---
TraceCompleteStepDown ==
    /\ IsEvent("complete_step_down")
    /\ LET ll == logline
           s == ll.node
       IN /\ CompleteStepDown(s)
          /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceProposeConfigChange: leader proposes config change ---
TraceProposeConfigChange ==
    /\ IsEvent("propose_config_change")
    /\ LET ll == logline
           s == ll.node
           newVoters == {ll.new_config[i] : i \in DOMAIN ll.new_config}
       IN /\ ProposeConfigChange(s, newVoters)
          /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceLeaderContinueReconfiguration: phase 2 of config change ---
TraceLeaderContinueReconfiguration ==
    /\ IsEvent("continue_reconfiguration")
    /\ LET ll == logline
           s == ll.node
       IN /\ LeaderContinueReconfiguration(s)
          /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceLeaderStepDownAfterConfigChange: step-down trick ---
TraceLeaderStepDownAfterConfigChange ==
    /\ IsEvent("step_down_config_change")
    /\ LET ll == logline
           s == ll.node
       IN /\ LeaderStepDownAfterConfigChange(s)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceSendInstallSnapshot: leader sends snapshot ---
\* Guard: snapshotIndex must match trace's lastIncludedIndex
\* (SilentTakeSnapshot must have fired first to align snapshotIndex)
TraceSendInstallSnapshot ==
    /\ IsEvent("install_snapshot_send")
    /\ LET ll == logline
           s == ll.from
           t == ll.to
       IN /\ "lastIncludedIndex" \in DOMAIN ll
          /\ snapshotIndex[s] = ll.lastIncludedIndex
          /\ SendInstallSnapshot(s, t)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleInstallSnapshotRequest: follower installs snapshot ---
TraceHandleInstallSnapshotRequest ==
    /\ IsEvent("install_snapshot_recv")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "InstallSnapshotRequest"
                       /\ msg.to = s
                       /\ msg.from = ll.from
             IN /\ HandleInstallSnapshotRequest(s, m)
                /\ _postCheck' = PostCheckFull(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceHandleInstallSnapshotResponse: leader processes IS reply ---
TraceHandleInstallSnapshotResponse ==
    /\ IsEvent("install_snapshot_response")
    /\ LET ll == logline
           s == ll.node
       IN /\ LET m == CHOOSE msg \in DOMAIN messages :
                       /\ messages[msg] > 0
                       /\ msg.type = "InstallSnapshotResponse"
                       /\ msg.to = s
                       /\ msg.from = ll.from
             IN /\ HandleInstallSnapshotResponse(s, m)
                /\ _postCheck' = PostCheckWeak(s, ll)
    /\ traceIdx' = traceIdx + 1

\* --- TraceCrash: server crashes ---
TraceCrash ==
    /\ IsEvent("crash")
    /\ LET ll == logline
           s == ll.node
       IN /\ Crash(s)
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceDiscardLateVoteResponse: vote response arrives after election won ---
\* The implementation emits trace events for all vote responses, but once quorum
\* is achieved, the candidate becomes leader. Subsequent responses are no-ops.
TraceDiscardLateVoteResponse ==
    /\ IsEvent("request_vote_response")
    /\ LET ll == logline
           s == ll.node
       IN /\ state[s] = "leader"  \* Already won the election
          /\ LET m == CHOOSE msg \in DOMAIN messages :
                      /\ messages[msg] > 0
                      /\ msg.type = "RequestVoteResponse"
                      /\ msg.to = s
                      /\ msg.from = ll.from
             IN Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceDiscardStaleAESend: AE send event from a crashed/stepped-down leader ---
\* The AE was in-flight when the leader crashed — event emitted concurrently with crash.
TraceDiscardStaleAESend ==
    /\ IsEvent("append_entries_send")
    /\ LET ll == logline
           s == ll.from
       IN state[s] /= "leader"  \* No longer leader
    /\ UNCHANGED <<serverVars, logVars, leaderVars, messages, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* --- TraceDiscardStaleAEResponse: AE response arrives after leader crash/step-down ---
\* The response was in-flight when the leader crashed or stepped down.
TraceDiscardStaleAEResponse ==
    /\ IsEvent("append_entries_response")
    /\ LET ll == logline
           s == ll.node
       IN /\ state[s] /= "leader"  \* No longer leader (crashed or stepped down)
          /\ \E m \in DOMAIN messages :
                /\ messages[m] > 0
                /\ m.type = "AppendEntriesResponse"
                /\ m.to = s
                /\ m.from = ll.from
                /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>
    /\ _postCheck' = NoPostCheck
    /\ traceIdx' = traceIdx + 1

\* ============================================================================
\* Silent Actions
\* ============================================================================

\* Silent actions handle spec-internal state changes not directly observed in traces.
\* All are tightly constrained to prevent state space explosion.
\* Silent actions clear _postCheck since they may change state.

\* SilentCompleteStepDown: async step-down that was not separately traced
\* (sometimes the step-down completes atomically with the discovering action)
SilentCompleteStepDown ==
    /\ traceIdx <= Len(TraceLog)
    /\ \E s \in Server :
        /\ pendingStepDown[s]
        \* Only fire if the next trace event is for this server and expects follower state
        /\ "node" \in DOMAIN logline
        /\ logline.node = s
        /\ "state" \in DOMAIN logline
        /\ logline.state.role = "follower"
        /\ CompleteStepDown(s)
    /\ _postCheck' = NoPostCheck
    /\ UNCHANGED traceIdx

\* SilentStartVirtualHeartbeat: VHB start not explicitly traced
\* Only fire before a timeout event that needs ~watchdogBlocked (tight constraint)
SilentStartVirtualHeartbeat ==
    /\ traceIdx <= Len(TraceLog)
    /\ \E leader, follower \in Server :
        /\ state[leader] = "leader"
        /\ leader /= follower
        /\ virtualHeartbeatSender[follower] = Nil
        \* Only fire if the NEXT event is a VHB-related event for this follower,
        \* or an append_entries_recv that requires leader recognition
        /\ "event" \in DOMAIN logline
        /\ \/ (logline.event = "virtual_heartbeat_start" /\ "to" \in DOMAIN logline /\ logline.to = follower)
           \/ (logline.event = "append_entries_recv" /\ "node" \in DOMAIN logline /\ logline.node = follower)
        /\ StartVirtualHeartbeat(leader, follower)
    /\ _postCheck' = NoPostCheck
    /\ UNCHANGED traceIdx

\* SilentTakeSnapshot: snapshot taken as side effect of commit advance
\* (not separately traced — happens inside update_commit_index)
\* Implementation snapshots probabilistically (1/3 chance in debug),
\* so we snapshot to the target shown in the upcoming trace state.
\* When the next event has no state (send events), we look for any
\* event in the near future that shows the server's snapshotIndex.
SilentTakeSnapshot ==
    /\ traceIdx <= Len(TraceLog)
    /\ \E s \in Server :
        /\ commitIndex[s] > snapshotIndex[s]
        /\ commitIndex[s] <= LastIndex(s)
        \* Find the target snapshotIndex from upcoming trace events
        /\ \E futureIdx \in traceIdx..Len(TraceLog) :
           /\ "state" \in DOMAIN TraceLog[futureIdx]
           /\ "snapshotIndex" \in DOMAIN TraceLog[futureIdx].state
           \* Match only "node" — the "state" field always belongs to "node" (the receiver),
           \* never to "from" (the sender). Using "from" would incorrectly pick up
           \* the receiver's snapshotIndex as if it were the sender's.
           /\ "node" \in DOMAIN TraceLog[futureIdx]
           /\ TraceLog[futureIdx].node = s
           /\ LET targetSI == TraceLog[futureIdx].state.snapshotIndex IN
              /\ targetSI > snapshotIndex[s]
              /\ targetSI <= commitIndex[s]
              /\ targetSI <= LastIndex(s)
              /\ LET snapTerm == LogTerm(s, targetSI)
                     localSnapIdx == targetSI - snapshotIndex[s]
                     newLog == SubSeq(log[s], localSnapIdx + 1, Len(log[s]))
                 IN
                 /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = targetSI]
                 /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = snapTerm]
                 /\ log' = [log EXCEPT ![s] = newLog]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, messages, heartbeatVars,
                   asyncVars, configVars, lifecycleVars, electionVars>>
    /\ _postCheck' = NoPostCheck
    /\ UNCHANGED traceIdx

\* SilentStopVirtualHeartbeat removed: VHB stops are explicitly traced.
\* VHB sender is also cleared by Timeout, HandleRequestVoteRequest (higher term),
\* CompleteStepDown, Crash — these are all traced actions.

\* ============================================================================
\* Init and Next
\* ============================================================================

TraceInit ==
    /\ traceIdx = 1
    /\ _postCheck = NoPostCheck
    \* Initialize from trace bootstrap event if present, else standard Init
    /\ currentTerm  = [s \in Server |-> 0]
    /\ votedFor     = [s \in Server |-> Nil]
    /\ log          = [s \in Server |-> << >>]
    /\ state        = [s \in Server |-> "follower"]
    /\ commitIndex  = [s \in Server |-> 0]
    /\ currentLeader = [s \in Server |-> Nil]
    /\ nextIndex    = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex   = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages     = EmptyBag
    /\ votesGranted = [s \in Server |-> {}]
    /\ virtualHeartbeatSender = [s \in Server |-> Nil]
    /\ watchdogBlocked = [s \in Server |-> FALSE]
    /\ watchdogLeaderOnlyBlocked = [s \in Server |-> FALSE]
    /\ pendingStepDown = [s \in Server |-> FALSE]
    /\ pendingNewTerm  = [s \in Server |-> 0]
    /\ config = [s \in Server |-> [old |-> Server, new |-> Nil]]
    /\ persistentLogValid = [s \in Server |-> TRUE]
    /\ memberIdGeneration = [s \in Server |-> 1]
    /\ snapshotIndex = [s \in Server |-> 0]
    /\ snapshotTerm  = [s \in Server |-> 0]

TraceNext ==
    \* Traced actions (consume a trace event: traceIdx' = traceIdx + 1)
    \/ TraceTimeout
    \/ TraceRequestVote
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceStartVirtualHeartbeat
    \/ TraceStopVirtualHeartbeat
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceCompleteStepDown
    \/ TraceProposeConfigChange
    \/ TraceLeaderContinueReconfiguration
    \/ TraceLeaderStepDownAfterConfigChange
    \/ TraceCrash
    \/ TraceSendInstallSnapshot
    \/ TraceHandleInstallSnapshotRequest
    \/ TraceHandleInstallSnapshotResponse
    \* Late-arrival actions (consume trace event but discard the message)
    \/ TraceDiscardLateVoteResponse
    \/ TraceDiscardStaleAESend
    \/ TraceDiscardStaleAEResponse
    \* Silent actions (do NOT consume a trace event: traceIdx stays same)
    \/ SilentCompleteStepDown
    \/ SilentStartVirtualHeartbeat
    \/ SilentTakeSnapshot

\* Keep for reference; use INIT/NEXT in cfg
TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* Temporal property: the trace was fully consumed
TraceMatched == <>(traceIdx = Len(TraceLog) + 1)

====
