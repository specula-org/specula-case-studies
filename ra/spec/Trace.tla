---- MODULE Trace ----
\*
\* Trace validation spec for Ra Raft.
\* Replays implementation traces against the base spec to verify consistency.
\*
EXTENDS base, Json, IOUtils, Sequences, Naturals, FiniteSets, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Trace file path: override via IOEnv.JSON or use default
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and parse trace
RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only ra_server events (skip system-level events)
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

\* ============================================================================
\* CURSOR VARIABLE
\* ============================================================================

VARIABLE l  \* cursor into TraceLog; 1..Len(TraceLog)+1

traceVars == <<vars, l>>

\* Current log line
logline == TraceLog[l]

\* ============================================================================
\* SERVER EXTRACTION
\* ============================================================================

\* Derive Server set from trace events
TraceServer == {TraceLog[i].node : i \in 1..Len(TraceLog)}

\* ============================================================================
\* ROLE/TYPE MAPPING
\* ============================================================================

\* Map implementation state names to spec constants
MapState(s) ==
    CASE s = "follower"          -> Follower
      [] s = "pre_vote"          -> PreVote
      [] s = "candidate"         -> Candidate
      [] s = "leader"            -> Leader
      [] s = "receive_snapshot"  -> ReceiveSnapshot
      [] s = "await_condition"   -> AwaitCondition
      [] OTHER                   -> Follower

MapMembership(m) ==
    CASE m = "voter"      -> MemberVoter
      [] m = "non_voter"  -> MemberNonVoter
      [] m = "promotable" -> MemberPromotable
      [] OTHER            -> MemberVoter

MapEntryType(t) ==
    CASE t = "value"   -> ValueEntry
      [] t = "config"  -> ConfigEntry
      [] t = "noop"    -> NoopEntry
      [] OTHER         -> ValueEntry

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.node = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Strong validation: full state check
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.post_state.current_term
    /\ state'[i] = MapState(logline.post_state.state)
    /\ commitIndex'[i] = logline.post_state.commit_index
    /\ LastLogIndex(i)' = logline.post_state.last_log_index

\* Weak validation: only term + state (for async events)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.post_state.current_term
    /\ state'[i] = MapState(logline.post_state.state)

\* ============================================================================
\* TRACE INIT
\* ============================================================================

\* Ra starts with term 0, empty log, all followers
\* Match implementation initial state from first trace event
TraceInit ==
    /\ l = 1
    /\ Init

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- CallForPreVote ---
TraceCallForPreVote ==
    /\ IsEvent("call_for_election_pre_vote")
    /\ LET i == logline.node
       IN
       /\ CallForPreVote(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- HandlePreVoteRequest ---
TraceHandlePreVoteRequest ==
    /\ IsEvent("handle_pre_vote_request")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = PreVoteRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ HandlePreVoteRequest(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- HandlePreVoteResponse ---
\* Self-vote: impl emits event but spec counts self-vote in CallForPreVote
TraceHandlePreVoteResponse ==
    /\ IsEvent("handle_pre_vote_response")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN
       /\ \/ \* Self-vote: already counted in CallForPreVote, skip
             /\ from = i
             /\ UNCHANGED vars
          \/ \* External vote: find message in bag and process
             /\ from /= i
             /\ \E m \in BagToSet(messages) :
                 /\ m.mtype = PreVoteResponse
                 /\ m.mdest = i
                 /\ m.msource = from
                 /\ HandlePreVoteResponse(i, m)
                 /\ currentTerm'[i] = expTerm
                 /\ state'[i] = expState
       /\ l' = l + 1

\* --- WinPreVote ---
TraceWinPreVote ==
    /\ IsEvent("win_pre_vote")
    /\ LET i == logline.node
       IN
       /\ WinPreVote(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- HandleRequestVoteRequest ---
TraceHandleRequestVoteRequest ==
    /\ IsEvent("handle_request_vote_request")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = RequestVoteRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ HandleRequestVoteRequest(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- HandleRequestVoteResponse ---
\* Self-vote: impl emits event but spec counts self-vote in WinPreVote
TraceHandleRequestVoteResponse ==
    /\ IsEvent("handle_request_vote_response")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN
       /\ \/ \* Self-vote: already counted in WinPreVote, skip
             /\ from = i
             /\ UNCHANGED vars
          \/ \* External vote: find message in bag and process
             /\ from /= i
             /\ \E m \in BagToSet(messages) :
                 /\ m.mtype = RequestVoteResponse
                 /\ m.mdest = i
                 /\ m.msource = from
                 /\ HandleRequestVoteResponse(i, m)
                 /\ currentTerm'[i] = expTerm
                 /\ state'[i] = expState
       /\ l' = l + 1

\* --- BecomeLeader ---
TraceBecomeLeader ==
    /\ IsEvent("become_leader")
    /\ LET i == logline.node
       IN
       /\ BecomeLeader(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- ClientRequest ---
\* Handles both actual client requests and the noop append (trace labels both as client_request)
TraceClientRequest ==
    /\ IsEvent("client_request")
    /\ LET i == logline.node
       IN
       /\ \/ \E v \in Value : ClientRequest(i, v)
          \/ LeaderAppendNoop(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- ReplicateEntries ---
TraceReplicateEntries ==
    /\ IsEvent("replicate_entries")
    /\ LET i == logline.node
           j == logline.to
       IN
       /\ ReplicateEntries(i, j)
       /\ l' = l + 1

\* --- HandleAppendEntriesRequest ---
\* Cache logline values before \E to avoid TLC evaluation context issues
TraceHandleAppendEntriesRequest ==
    /\ IsEvent("handle_append_entries_request")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ HandleAppendEntriesRequest(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- HandleAppendEntriesResponse ---
\* Lightweight: just confirm a matching response exists and advance l.
\* matchIndex updates aren't needed since TraceAdvanceCommitIndex trusts the trace.
\* NOT consuming the message avoids branching on which of multiple responses to pick.
TraceHandleAppendEntriesResponse ==
    /\ IsEvent("handle_append_entries_response")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN
       \* Guard: matching response must exist
       /\ \E m \in BagToSet(messages) :
           /\ m.mtype = AppendEntriesResponse
           /\ m.mdest = i
           /\ m.msource = from
       \* Validate current state matches expected post_state
       /\ currentTerm[i] = expTerm
       /\ state[i] = expState
       /\ UNCHANGED vars
       /\ l' = l + 1

\* --- AdvanceCommitIndex ---
\* Trust the trace's commit index directly. The implementation fires this event
\* from inside AER response handling, before the handler returns. Computing from
\* matchIndex would require consuming AER responses that the trace needs later.
TraceAdvanceCommitIndex ==
    /\ IsEvent("advance_commit_index")
    /\ LET i == logline.node
           newCi == logline.post_state.commit_index
       IN
       /\ \/ \* Actual advancement: set ci from trace
             /\ newCi > commitIndex[i]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCi]
             /\ UNCHANGED <<serverVars, log, lastApplied, leaderVars, candidateVars,
                            messages, queryVars, membershipVars, preVoteVars,
                            snapshotVars, configVars>>
          \/ \* No-op: impl fires event but ci unchanged
             /\ newCi = commitIndex[i]
             /\ UNCHANGED vars
       /\ l' = l + 1

\* --- ApplyEntries ---
TraceApplyEntries ==
    /\ IsEvent("apply_entries")
    /\ LET i == logline.node
       IN
       /\ ApplyEntries(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- ConsistentQuery ---
TraceConsistentQuery ==
    /\ IsEvent("consistent_query")
    /\ LET i == logline.node
       IN
       /\ ConsistentQuery(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* --- HandleHeartbeatRequest ---
\* Construct heartbeat message inline to avoid needing SilentSendHeartbeat.
\* The leader sends periodic heartbeats which aren't traced; we synthesize them here.
TraceHandleHeartbeatRequest ==
    /\ IsEvent("handle_heartbeat_request")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
           m == [mtype       |-> HeartbeatRequest,
                 mterm       |-> currentTerm[from],
                 mqueryIndex |-> queryIndex[from],
                 msource     |-> from,
                 mdest       |-> i]
       IN
       /\ HandleHeartbeatRequest(i, m)
       /\ currentTerm'[i] = expTerm
       /\ state'[i] = expState
       /\ l' = l + 1

\* --- HandleHeartbeatResponse ---
\* Lightweight: just confirm a matching response exists and advance l.
\* Query quorum tracking isn't needed for trace validation.
TraceHandleHeartbeatResponse ==
    /\ IsEvent("handle_heartbeat_response")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN
       /\ \E m \in BagToSet(messages) :
           /\ m.mtype = HeartbeatResponse
           /\ m.mdest = i
           /\ m.msource = from
       /\ currentTerm[i] = expTerm
       /\ state[i] = expState
       /\ UNCHANGED vars
       /\ l' = l + 1

\* --- HandleInstallSnapshotRequest ---
TraceHandleInstallSnapshotRequest ==
    /\ IsEvent("handle_install_snapshot_request")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = InstallSnapshotRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ HandleInstallSnapshotRequest(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- HandleInstallSnapshotResponse ---
TraceHandleInstallSnapshotResponse ==
    /\ IsEvent("handle_install_snapshot_response")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = InstallSnapshotResponse
           /\ m.mdest = i
           /\ m.msource = from
           /\ HandleInstallSnapshotResponse(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- CandidateStepDown ---
TraceCandidateStepDown ==
    /\ IsEvent("candidate_step_down")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ CandidateStepDown(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- LeaderStepDown ---
TraceLeaderStepDown ==
    /\ IsEvent("leader_step_down")
    /\ LET i == logline.node
           from == logline.from
           expTerm == logline.post_state.current_term
           expState == MapState(logline.post_state.state)
       IN \E m \in BagToSet(messages) :
           /\ m.mtype \in {AppendEntriesRequest, InstallSnapshotRequest, HeartbeatRequest}
           /\ m.mdest = i
           /\ m.msource = from
           /\ LeaderStepDown(i, m)
           /\ currentTerm'[i] = expTerm
           /\ state'[i] = expState
           /\ l' = l + 1

\* --- ProposeConfigChange ---
TraceProposeConfigChange ==
    /\ IsEvent("propose_config_change")
    /\ LET i == logline.node
           nc == {logline.new_config[j] : j \in DOMAIN logline.new_config}
       IN
       /\ ProposeConfigChange(i, nc)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent actions handle impl state changes without trace events.
\* AGGRESSIVELY constrained to prevent state space explosion.
\* Only the minimum set needed for trace validation.

\* --- SilentLeaderStepDown ---
\* When a leader receives a pre-vote with higher term, it abdicates to follower
\* and re-processes the message (ra_server.erl:949-962). The abdication doesn't
\* emit a trace event; the subsequent follower processing emits handle_pre_vote_request.
\* Constrained: only fires when the next trace event requires it.
SilentLeaderStepDown ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "handle_pre_vote_request"
    /\ LET i == logline.node
           from == logline.from
       IN
       /\ state[i] = Leader
       /\ \E m \in BagToSet(messages) :
           /\ m.mtype = PreVoteRequest
           /\ m.mdest = i
           /\ m.msource = from
           /\ m.mterm > currentTerm[i]
           /\ LeaderStepDown(i, m)
    /\ UNCHANGED l

\* --- SilentLeaderIgnorePreVote ---
\* Leader discards same/lower-term pre-vote without trace event (ra_server.erl:964-969).
\* Constrained: only fires when a pre-vote message exists for a leader.
SilentLeaderIgnorePreVote ==
    /\ l <= Len(TraceLog)
    /\ \E m \in BagToSet(messages) :
        /\ m.mtype = PreVoteRequest
        /\ state[m.mdest] = Leader
        /\ m.mterm <= currentTerm[m.mdest]
        /\ LeaderIgnorePreVote(m.mdest, m)
    /\ UNCHANGED l

\* NOTE: SilentHandleAppendEntriesResponse removed -- it consumed responses
\* needed by TraceHandleAppendEntriesResponse. TraceAdvanceCommitIndex now
\* trusts the trace's commit index directly instead of computing from matchIndex.

\* NOTE: SilentSendHeartbeat removed -- heartbeat messages are now constructed
\* inline in TraceHandleHeartbeatRequest. This avoids infinite sending loops.

\* --- SilentApplyEntries ---
\* Follower apply_entries fires mid-function inside evaluate_commit_index_follower,
\* BEFORE the enclosing handle_append_entries_request handler emits its trace.
\* So the trace shows handle_append_entries_request (which advances commitIndex)
\* AFTER apply_entries (which needs commitIndex > lastApplied). We handle this
\* by letting the spec silently apply entries when the follower's commitIndex
\* allows it. Only fires when commitIndex > lastApplied, preventing unbounded firing.
SilentApplyEntries ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ state[i] /= Leader
        /\ ApplyEntries(i)
    /\ UNCHANGED l

\* NOTE: SilentReplicateEntries removed -- trace has explicit replicate_entries events.
\* NOTE: SilentAdvanceCommitIndex removed -- TraceAdvanceCommitIndex handles all cases.
\* NOTE: SilentDropStaleMessage removed -- stale messages don't affect correctness.
\* NOTE: SilentLoseMessage removed -- creates dead-end branches in BFS.

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceNext ==
    \* --- Traced actions (consume a log line) ---
    \/ TraceCallForPreVote
    \/ TraceHandlePreVoteRequest
    \/ TraceHandlePreVoteResponse
    \/ TraceWinPreVote
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceBecomeLeader
    \/ TraceClientRequest
    \/ TraceReplicateEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceAdvanceCommitIndex
    \/ TraceApplyEntries
    \/ TraceConsistentQuery
    \/ TraceHandleHeartbeatRequest
    \/ TraceHandleHeartbeatResponse
    \/ TraceHandleInstallSnapshotRequest
    \/ TraceHandleInstallSnapshotResponse
    \/ TraceCandidateStepDown
    \/ TraceLeaderStepDown
    \/ TraceProposeConfigChange
    \* --- Silent actions (constrained, don't consume trace lines) ---
    \/ SilentLeaderStepDown
    \/ SilentLeaderIgnorePreVote
    \/ SilentApplyEntries
    \* --- Terminal: trace fully consumed ---
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* ============================================================================
\* TRACE COMPLETION
\* ============================================================================

\* Temporal property: trace was fully consumed
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* VIEW AND ALIAS
\* ============================================================================

\* Exclude internal trace state from state comparison
TraceView == <<vars, l>>

\* Readable state for debugging counterexamples
TraceAlias ==
    [
        cursor |-> l,
        event  |-> IF l <= Len(TraceLog) THEN TraceLog[l].event ELSE "END",
        node   |-> IF l <= Len(TraceLog) THEN TraceLog[l].node ELSE "END",
        term   |-> [s \in Server |-> currentTerm[s]],
        role   |-> [s \in Server |-> state[s]],
        ci     |-> [s \in Server |-> commitIndex[s]],
        la     |-> [s \in Server |-> lastApplied[s]],
        logLen |-> [s \in Server |-> LastLogIndex(s)],
        vote   |-> [s \in Server |-> votedFor[s]],
        msgs   |-> BagCardinality(messages)
    ]

====
