------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for Aeron Cluster consensus protocol.
\* Replays implementation traces (NDJSON) against the base spec to verify
\* that observed state transitions are consistent with the specification.
\*
\* Key concepts:
\*   - Cursor variable `l` walks through trace events
\*   - Action wrappers: match event → call base action → validate post-state → l' = l + 1
\*   - Silent actions: base spec actions without trace events (tightly constrained)
\*
\* Trace file location: ../traces/<name>.ndjson (override via IOEnv.JSON)

EXTENDS base, TLCExt, IOUtils, Json, Sequences, Naturals, FiniteSets, Bags

----
\* Trace loading
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load all lines from NDJSON file
JsonLog == ndJsonDeserialize(JsonFile)

\* Filter to consensus-relevant events (skip debug/info lines)
TraceLog == SelectSeq(JsonLog, LAMBDA x : "action" \in DOMAIN x)

----
\* Cursor variable
----

VARIABLE l       \* Current position in TraceLog (1..Len(TraceLog)+1)

traceVars == <<vars, l>>

----
\* Helpers
----

logline == TraceLog[l]

\* Check if current event matches a given action name
IsEvent(name) == l <= Len(TraceLog) /\ logline.action = name

\* Check if current event is for a specific node
IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.node = i

\* Check if current event is a message event between two nodes
IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

\* Server set extracted from trace
TraceServer == {TraceLog[k].node : k \in 1..Len(TraceLog)}

----
\* Role/type mapping
----

\* Map implementation election state strings to spec constants
MapElectionState(s) ==
    CASE s = "INIT"             -> ES_Init
      [] s = "CANVASS"          -> ES_Canvass
      [] s = "NOMINATE"         -> ES_Nominate
      [] s = "CANDIDATE_BALLOT" -> ES_CandidateBallot
      [] s = "FOLLOWER_BALLOT"  -> ES_FollowerBallot
      [] s = "LEADER_READY"     -> ES_Leader
      [] s = "LEADER_INIT"      -> ES_Leader
      [] s = "LEADER_REPLAY"    -> ES_Leader
      [] s = "LEADER_LOG_REPLICATION" -> ES_Leader
      [] s = "FOLLOWER_READY"   -> ES_Follower
      [] s = "FOLLOWER_REPLAY"  -> ES_Follower
      [] s = "FOLLOWER_LOG_REPLICATION" -> ES_Follower
      [] s = "FOLLOWER_CATCHUP_INIT"   -> ES_Follower
      [] s = "FOLLOWER_CATCHUP_AWAIT"  -> ES_Follower
      [] s = "FOLLOWER_CATCHUP"        -> ES_Follower
      [] s = "FOLLOWER_LOG_INIT"       -> ES_Follower
      [] s = "FOLLOWER_LOG_AWAIT"      -> ES_Follower

----
\* Post-state validation
----

\* Strong validation: check all core state fields
ValidatePostState(i) ==
    /\ IF "candidateTermId" \in DOMAIN logline
       THEN candidateTermId'[i] = logline.candidateTermId
       ELSE TRUE
    /\ IF "leadershipTermId" \in DOMAIN logline
       THEN leadershipTermId'[i] = logline.leadershipTermId
       ELSE TRUE
    /\ IF "electionState" \in DOMAIN logline
       THEN electionState'[i] = MapElectionState(logline.electionState)
       ELSE TRUE
    /\ IF "commitPosition" \in DOMAIN logline
       THEN commitPosition'[i] = logline.commitPosition
       ELSE TRUE
    /\ IF "appendPosition" \in DOMAIN logline
       THEN Len(log'[i]) = logline.appendPosition
       ELSE TRUE

\* Weak validation: only check term + state (for async/partial events)
ValidatePostStateWeak(i) ==
    /\ IF "candidateTermId" \in DOMAIN logline
       THEN candidateTermId'[i] = logline.candidateTermId
       ELSE TRUE
    /\ IF "electionState" \in DOMAIN logline
       THEN electionState'[i] = MapElectionState(logline.electionState)
       ELSE TRUE

\* Validation skipping electionState (for events where harness captures pre-transition state)
ValidatePostStateNoElection(i) ==
    /\ IF "candidateTermId" \in DOMAIN logline
       THEN candidateTermId'[i] = logline.candidateTermId
       ELSE TRUE
    /\ IF "leadershipTermId" \in DOMAIN logline
       THEN leadershipTermId'[i] = logline.leadershipTermId
       ELSE TRUE
    /\ IF "commitPosition" \in DOMAIN logline
       THEN commitPosition'[i] = logline.commitPosition
       ELSE TRUE
    /\ IF "appendPosition" \in DOMAIN logline
       THEN Len(log'[i]) = logline.appendPosition
       ELSE TRUE

----
\* Trace Init
----

\* TraceInit matches the implementation's initial state, which may differ from
\* the base spec's Init (e.g., non-zero initial terms from persisted state).
TraceInit ==
    /\ l = 1
    /\ IF Len(TraceLog) > 0 /\ "init" \in DOMAIN TraceLog[1]
       THEN \* Use initial state from first trace event
            /\ candidateTermId = [s \in Server |->
                   IF s \in DOMAIN TraceLog[1].init.candidateTermId
                   THEN TraceLog[1].init.candidateTermId[s] ELSE 0]
            /\ leadershipTermId = [s \in Server |->
                   IF s \in DOMAIN TraceLog[1].init.leadershipTermId
                   THEN TraceLog[1].init.leadershipTermId[s] ELSE 0]
            /\ log = [s \in Server |-> <<>>]
            /\ commitPosition = [s \in Server |-> 0]
            /\ electionState = [s \in Server |-> ES_Init]
            /\ currentLeader = [s \in Server |-> Nil]
            /\ votesReceived = [s \in Server |-> [t \in Server |-> Nil]]
            /\ memberLogTerm = [s \in Server |-> [t \in Server |-> 0]]
            /\ memberLogPosition = [s \in Server |-> [t \in Server |-> 0]]
            /\ messages = EmptyBag
            /\ notifiedCommitPosition = [s \in Server |-> 0]
            /\ memberActive = [s \in Server |-> TRUE]
            /\ nextSessionId = [s \in Server |-> 0]
            /\ persistedCandidateTermId = [s \in Server |->
                   IF s \in DOMAIN TraceLog[1].init.candidateTermId
                   THEN TraceLog[1].init.candidateTermId[s] ELSE 0]
       ELSE Init  \* Fall back to base Init

----
\* Action wrappers
----

\* Each wrapper: match event → call base action → validate → advance cursor

TraceEnterCanvass ==
    /\ IsNodeEvent("EnterCanvass", logline.node)
    /\ EnterCanvass(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

TraceSendCanvassPosition ==
    /\ IsMsgEvent("SendCanvassPosition", logline.from, logline.to)
    /\ SendCanvassPosition(logline.from, logline.to)
    /\ l' = l + 1

TraceHandleCanvassPosition ==
    /\ IsMsgEvent("HandleCanvassPosition", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = CanvassPositionMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ HandleCanvassPosition(logline.to, m)
    /\ ValidatePostStateWeak(logline.to)
    /\ l' = l + 1

TraceNominate ==
    /\ IsNodeEvent("Nominate", logline.node)
    /\ Nominate(logline.node)
    /\ ValidatePostState(logline.node)
    /\ l' = l + 1

TraceHandleRequestVote ==
    /\ IsMsgEvent("HandleRequestVote", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ HandleRequestVote(logline.to, m)
    /\ ValidatePostState(logline.to)
    /\ l' = l + 1

TraceHandleRequestVoteResponse ==
    /\ IsMsgEvent("HandleRequestVoteResponse", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteResponseMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ HandleRequestVoteResponse(logline.to, m)
    /\ ValidatePostStateWeak(logline.to)
    /\ l' = l + 1

TraceBecomeLeader ==
    /\ IsNodeEvent("BecomeLeader", logline.node)
    /\ BecomeLeader(logline.node)
    /\ ValidatePostState(logline.node)
    /\ l' = l + 1

TraceHandleNewLeadershipTerm ==
    /\ IsMsgEvent("HandleNewLeadershipTerm", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = NewLeadershipTermMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ HandleNewLeadershipTerm(logline.to, m)
    \* Use NoElection validator: harness captures pre-transition electionState
    /\ ValidatePostStateNoElection(logline.to)
    /\ l' = l + 1

TraceClientRequest ==
    /\ IsNodeEvent("ClientRequest", logline.node)
    /\ ClientRequest(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

TraceLeaderAppendSessionOpen ==
    /\ IsNodeEvent("LeaderAppendSessionOpen", logline.node)
    /\ LeaderAppendSessionOpen(logline.node)
    /\ ValidatePostState(logline.node)
    /\ l' = l + 1

TraceFollowerReplicateLog ==
    /\ IsNodeEvent("FollowerReplicateLog", logline.node)
    /\ FollowerReplicateLog(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

TraceSendAppendPositionUpdate ==
    /\ IsMsgEvent("SendAppendPositionUpdate", logline.from, logline.to)
    /\ SendAppendPositionUpdate(logline.from)
    /\ l' = l + 1

TraceHandleAppendPositionUpdate ==
    /\ IsMsgEvent("HandleAppendPositionUpdate", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = AppendPositionUpdateMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ HandleAppendPositionUpdate(logline.to, m)
    /\ l' = l + 1

TraceLeaderAdvanceCommitPosition ==
    /\ IsNodeEvent("LeaderAdvanceCommitPosition", logline.node)
    /\ LeaderAdvanceCommitPosition(logline.node)
    /\ ValidatePostState(logline.node)
    /\ l' = l + 1

TracePublishCommitPosition ==
    /\ IsNodeEvent("PublishCommitPosition", logline.node)
    /\ PublishCommitPosition(logline.node)
    /\ l' = l + 1

TraceFollowerReceiveCommitPosition ==
    /\ IsMsgEvent("FollowerReceiveCommitPosition", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = CommitPositionMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        /\ FollowerReceiveCommitPosition(logline.to, m)
    /\ ValidatePostState(logline.to)
    /\ l' = l + 1

TraceElectionReceiveCommitPosition ==
    /\ IsMsgEvent("ElectionReceiveCommitPosition", logline.from, logline.to)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = CommitPositionMsg
        /\ m.msource = logline.from
        /\ m.mdest = logline.to
        \* Implementation routes through Election.onCommitPosition even during
        \* FOLLOWER_REPLAY (mapped to ES_Follower). Use FollowerReceiveCommitPosition
        \* as fallback when server already transitioned to ES_Follower.
        /\ \/ ElectionReceiveCommitPosition(logline.to, m)
           \/ (/\ electionState[logline.to] = ES_Follower
               /\ FollowerReceiveCommitPosition(logline.to, m))
    /\ l' = l + 1

TraceTimeout ==
    /\ IsNodeEvent("Timeout", logline.node)
    /\ Timeout(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

TraceCrash ==
    /\ IsNodeEvent("Crash", logline.node)
    /\ Crash(logline.node)
    /\ l' = l + 1

----
\* Silent actions
----
\* These fire base spec actions without consuming a trace event.
\* Each is tightly constrained to prevent state space explosion.

\* Silent: follower replicates log entry (may happen between observed events)
\* Constrained: only fire if next event requires the follower to have more entries
SilentFollowerReplicateLog(i) ==
    /\ l <= Len(TraceLog)
    /\ electionState[i] = ES_Follower
    /\ currentLeader[i] # Nil
    \* Only replicate if next event expects more entries
    /\ IF "appendPosition" \in DOMAIN logline /\ logline.node = i
       THEN Len(log[i]) < logline.appendPosition
       ELSE FALSE
    /\ FollowerReplicateLog(i)
    /\ UNCHANGED l

\* Silent: send canvass position (infrastructure, not always observed)
SilentSendCanvassPosition(i, j) ==
    /\ l <= Len(TraceLog)
    /\ electionState[i] \in {ES_Canvass, ES_Leader, ES_Follower}
    /\ i # j
    \* Only fire if next event is a HandleCanvassPosition from i to j
    /\ logline.action = "HandleCanvassPosition"
    /\ logline.from = i
    /\ logline.to = j
    /\ SendCanvassPosition(i, j)
    /\ UNCHANGED l

\* Silent: send append position update (periodic, not always observed)
SilentSendAppendPositionUpdate(i) ==
    /\ l <= Len(TraceLog)
    /\ electionState[i] = ES_Follower
    /\ currentLeader[i] # Nil
    \* Only fire if next event is HandleAppendPositionUpdate from i
    /\ logline.action = "HandleAppendPositionUpdate"
    /\ logline.from = i
    /\ SendAppendPositionUpdate(i)
    /\ UNCHANGED l

\* Silent: publish commit position (periodic, may not be individually traced)
\* Uses trace's mcommitPosition when available to bridge gaps where leader's
\* commitPosition advanced through untraced intermediate events.
SilentPublishCommitPosition(i) ==
    /\ l <= Len(TraceLog)
    /\ electionState[i] = ES_Leader
    \* Only fire if next event is a FollowerReceiveCommitPosition from i
    /\ logline.action \in {"FollowerReceiveCommitPosition", "ElectionReceiveCommitPosition"}
    /\ logline.from = i
    /\ LET mcp == IF "mcommitPosition" \in DOMAIN logline
                  THEN logline.mcommitPosition
                  ELSE commitPosition[i]
       IN SendAll({[mtype            |-> CommitPositionMsg,
                    msource          |-> i,
                    mdest            |-> j,
                    mleadershipTermId |-> leadershipTermId[i],
                    mcommitPosition  |-> mcp] : j \in Server \ {i}})
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars, l>>

\* Silent: leader advance commit position (may happen between observed events)
SilentLeaderAdvanceCommitPosition(i) ==
    /\ l <= Len(TraceLog)
    /\ electionState[i] = ES_Leader
    \* Only fire if next event expects higher commit
    /\ IF "commitPosition" \in DOMAIN logline /\ logline.node = i
       THEN commitPosition[i] < logline.commitPosition
       ELSE FALSE
    /\ LeaderAdvanceCommitPosition(i)
    /\ UNCHANGED l

\* Silent: drop stale message (cleanup, never observed)
\* Constrained: only drop messages NOT needed by current or future trace events
SilentDropStaleMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        \* Don't drop messages that match any future trace event's expected message
        /\ \A k \in l..Len(TraceLog) :
            LET ev == TraceLog[k] IN
            ~ (/\ "from" \in DOMAIN ev /\ "to" \in DOMAIN ev
               /\ m.msource = ev.from /\ m.mdest = ev.to
               /\ \/ (ev.action = "HandleCanvassPosition" /\ m.mtype = CanvassPositionMsg)
                  \/ (ev.action = "HandleRequestVote" /\ m.mtype = RequestVoteMsg)
                  \/ (ev.action = "HandleRequestVoteResponse" /\ m.mtype = RequestVoteResponseMsg)
                  \/ (ev.action = "HandleNewLeadershipTerm" /\ m.mtype = NewLeadershipTermMsg)
                  \/ (ev.action = "HandleAppendPositionUpdate" /\ m.mtype = AppendPositionUpdateMsg)
                  \/ (ev.action = "FollowerReceiveCommitPosition" /\ m.mtype = CommitPositionMsg)
                  \/ (ev.action = "ElectionReceiveCommitPosition" /\ m.mtype = CommitPositionMsg))
        /\ DropStaleMessage(m)
    /\ UNCHANGED l

\* Silent: lose message (network, never observed)
\* Constrained: only lose messages NOT needed by current or future trace events
SilentLoseMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        \* Don't lose messages that match any future trace event's expected message
        /\ \A k \in l..Len(TraceLog) :
            LET ev == TraceLog[k] IN
            ~ (/\ "from" \in DOMAIN ev /\ "to" \in DOMAIN ev
               /\ m.msource = ev.from /\ m.mdest = ev.to
               /\ \/ (ev.action = "HandleCanvassPosition" /\ m.mtype = CanvassPositionMsg)
                  \/ (ev.action = "HandleRequestVote" /\ m.mtype = RequestVoteMsg)
                  \/ (ev.action = "HandleRequestVoteResponse" /\ m.mtype = RequestVoteResponseMsg)
                  \/ (ev.action = "HandleNewLeadershipTerm" /\ m.mtype = NewLeadershipTermMsg)
                  \/ (ev.action = "HandleAppendPositionUpdate" /\ m.mtype = AppendPositionUpdateMsg)
                  \/ (ev.action = "FollowerReceiveCommitPosition" /\ m.mtype = CommitPositionMsg)
                  \/ (ev.action = "ElectionReceiveCommitPosition" /\ m.mtype = CommitPositionMsg))
        /\ LoseMessage(m)
    /\ UNCHANGED l

----
\* TraceNext
----

TraceNext ==
    \/ TraceEnterCanvass
    \/ TraceSendCanvassPosition
    \/ TraceHandleCanvassPosition
    \/ TraceNominate
    \/ TraceHandleRequestVote
    \/ TraceHandleRequestVoteResponse
    \/ TraceBecomeLeader
    \/ TraceHandleNewLeadershipTerm
    \/ TraceClientRequest
    \/ TraceLeaderAppendSessionOpen
    \/ TraceFollowerReplicateLog
    \/ TraceSendAppendPositionUpdate
    \/ TraceHandleAppendPositionUpdate
    \/ TraceLeaderAdvanceCommitPosition
    \/ TracePublishCommitPosition
    \/ TraceFollowerReceiveCommitPosition
    \/ TraceElectionReceiveCommitPosition
    \/ TraceTimeout
    \/ TraceCrash
    \* Silent actions
    \/ \E i \in Server : SilentFollowerReplicateLog(i)
    \/ \E i, j \in Server : i # j /\ SilentSendCanvassPosition(i, j)
    \/ \E i \in Server : SilentSendAppendPositionUpdate(i)
    \/ \E i \in Server : SilentPublishCommitPosition(i)
    \/ \E i \in Server : SilentLeaderAdvanceCommitPosition(i)
    \* SilentDropStaleMessage and SilentLoseMessage removed:
    \* they cause spurious deadlocks by draining messages needed for future trace events.
    \* Stale messages in the bag are harmless — they just sit without blocking progress.

----
\* Spec and properties
----

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* Temporal property: entire trace was consumed
\* Violation means some event could not be matched.
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Use deadlock checking as completion signal:
\* TLC reports "deadlock" when l = Len(TraceLog) + 1 and no action is enabled.
\* This is expected — it means the trace was fully consumed.
TraceComplete == l <= Len(TraceLog)

====
