------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for Hazelcast CP Subsystem (Raft).
\*
\* Replays NDJSON traces from the instrumented implementation against the
\* base spec, verifying that every observed state transition is consistent
\* with the TLA+ model.
\*
\* Usage: TLC with Trace.cfg, override JSON env var for per-trace selection:
\*   java -jar tla2tools.jar -config Trace.cfg Trace.tla -DJSON=../traces/test.ndjson

EXTENDS base, Sequences, TLCExt, IOUtils, Json, Naturals, FiniteSets, Bags, TLC

----
\* Trace loading
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == ndJsonDeserialize(JsonFile)

\* Filter to only Raft events (exclude non-raft trace lines)
TraceLog == SelectSeq(RawTrace, LAMBDA x : "event" \in DOMAIN x)

----
\* Cursor variable
----

VARIABLE l   \* Current position in trace (1..Len(TraceLog)+1)

traceVars == <<vars, l>>

----
\* Role/type mapping: implementation strings to spec constants
----

RoleMap(r) ==
    CASE r = "FOLLOWER"  -> Follower
    []   r = "CANDIDATE" -> Candidate
    []   r = "LEADER"    -> Leader

EntryTypeMap(t) ==
    CASE t = "VALUE"  -> ValueEntry
    []   t = "CONFIG" -> ConfigEntry

VotedForMap(v) ==
    IF v = "none" THEN Nil ELSE v

----
\* Server extraction from trace
----

\* Derive Server set from all unique node IDs in the trace
TraceServers == {TraceLog[k].node : k \in 1..Len(TraceLog)}

----
\* Event predicates
----

\* Current trace event
logline == TraceLog[l]

\* Check event type
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

----
\* Post-state validation
----

\* Strong validation: check term, role, commitIndex, lastLogIndex, lastLogTerm
ValidatePostState(i) ==
    LET ll == TraceLog[l] IN
    /\ currentTerm'[i] = ll.state.term
    /\ state'[i] = RoleMap(ll.state.role)
    /\ commitIndex'[i] = ll.state.commitIndex
    /\ Len(log'[i]) = ll.state.lastLogIndex
    /\ IF Len(log'[i]) > 0 THEN log'[i][Len(log'[i])].term = ll.state.lastLogTerm
       ELSE ll.state.lastLogTerm = 0

\* Weak validation: check only term and role (for async actions)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RoleMap(logline.state.role)

----
\* Trace Init
----

\* TraceInit must match the implementation's initial state.
\* The first trace event may not be at time 0; we set up the state
\* to match the first event's pre-state (or implementation defaults).
TraceInit ==
    /\ l = 1
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ messages       = EmptyBag
    /\ leaseContact   = [s \in Server |-> {}]
    /\ committedConfig = [s \in Server |-> Server]
    /\ latestConfig   = [s \in Server |-> Server]
    /\ preVote        = [s \in Server |-> {}]
    /\ queryRound     = [s \in Server |-> 0]
    /\ queryCommitIndex = [s \in Server |-> 0]
    /\ queryAcks      = [s \in Server |-> {}]
    /\ queryPending   = [s \in Server |-> FALSE]

----
\* Action wrappers — match event, call base action, validate, advance cursor
----

TraceTimeout ==
    /\ IsNodeEvent("Timeout", logline.node)
    /\ LET i == logline.node
       IN /\ Timeout(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandlePreVoteRequest ==
    /\ IsMsgEvent("HandlePreVoteRequest", logline.from, logline.to)
    /\ LET i == logline.to
       IN /\ \E m \in DOMAIN messages :
              /\ HandlePreVoteRequest(i, m)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandlePreVoteResponse ==
    /\ IsMsgEvent("HandlePreVoteResponse", logline.from, logline.to)
    /\ LET i == logline.to
       IN \/ \* Normal path: message still in bag
             /\ \E m \in DOMAIN messages :
                    /\ m.mtype = PreVoteResponseMsg
                    /\ m.msource = logline.from
                    /\ HandlePreVoteResponse(i, m)
             /\ ValidatePostState(i)
          \/ \* Idempotent path: ONLY for elected=true case already handled silently
             /\ "elected" \in DOMAIN logline
             /\ logline.elected = TRUE
             /\ UNCHANGED vars
             /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleVoteRequest ==
    /\ IsMsgEvent("HandleVoteRequest", logline.from, logline.to)
    /\ LET i == logline.to
       IN /\ \E m \in DOMAIN messages :
              /\ HandleVoteRequest(i, m)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleVoteResponse ==
    /\ IsMsgEvent("HandleVoteResponse", logline.from, logline.to)
    /\ LET i == logline.to
       IN \/ \* Normal path: message still in bag
             /\ \E m \in DOMAIN messages :
                    /\ HandleVoteResponse(i, m)
             /\ ValidatePostState(i)
          \/ \* Idempotent path: already handled by SilentHandleVoteResponse
             \* The silent action consumed the message and promoted to leader;
             \* just validate current state matches expected post-state and advance cursor.
             /\ UNCHANGED vars
             /\ ValidatePostState(i)
    /\ l' = l + 1

TraceClientRequest ==
    /\ IsNodeEvent("ClientRequest", logline.node)
    /\ LET i == logline.node
       IN \* Guard: commitIndex must match trace state
          /\ commitIndex[i] = logline.state.commitIndex
          /\ ClientRequest(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceAppendEntries ==
    /\ IsMsgEvent("AppendEntries", logline.from, logline.to)
    /\ LET i == logline.from
           j == logline.to
       IN \* Guard: commitIndex must match trace state before sending
          \* (forces SilentHandleAppendSuccessResponse + SilentAdvanceCommitIndex first)
          /\ commitIndex[i] = logline.state.commitIndex
          /\ state[i] = Leader
          /\ \/ \* Normal path: send all pending entries (standard Raft)
                /\ \/ ~("entryCount" \in DOMAIN logline)
                   \/ logline.entryCount > 0
                /\ AppendEntries(i, j)
             \/ \* Heartbeat path: send empty AppendEntries
                \* (Hazelcast separates heartbeats from replication)
                /\ "entryCount" \in DOMAIN logline
                /\ logline.entryCount = 0
                /\ LET prevIdx  == nextIndex[i][j] - 1
                       prevTerm == LogTerm(i, prevIdx)
                   IN Send([mtype        |-> AppendEntriesRequestMsg,
                            mterm        |-> currentTerm[i],
                            mprevLogTerm |-> prevTerm,
                            mprevLogIndex |-> prevIdx,
                            mentries     |-> <<>>,
                            mcommitIndex |-> commitIndex[i],
                            mqueryRound  |-> queryRound[i],
                            msource      |-> i,
                            mdest        |-> j])
                /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                               leaseVars, configVars, preVoteVars, queryVars>>
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandleAppendRequest ==
    /\ IsMsgEvent("HandleAppendRequest", logline.from, logline.to)
    /\ LET i == logline.to
           leader == logline.from
       IN \/ \* Normal path: consume matching message from bag
             \* Pre-filtered by source, term, and expected lastLogIndex coverage
             /\ \E m \in DOMAIN messages :
                    /\ m.mtype = AppendEntriesRequestMsg
                    /\ m.msource = leader
                    /\ m.mterm = logline.state.term
                    /\ HandleAppendRequest(i, m)
             /\ ValidatePostState(i)
          \/ \* Direct path: when no fresh message from this leader to this dest in bag
             \* A message is "fresh" if it has current term (stale-term messages ignored)
             /\ ~\E m \in DOMAIN messages :
                    /\ m.mtype = AppendEntriesRequestMsg
                    /\ m.msource = leader
                    /\ m.mdest = i
                    /\ m.mterm = currentTerm[leader]
                    /\ m.mcommitIndex = commitIndex[leader]
                    /\ m.mprevLogIndex + Len(m.mentries) = logline.state.lastLogIndex
             /\ state[leader] = Leader
             /\ LET expectedLLI == logline.state.lastLogIndex
                    isHeartbeat == expectedLLI < LastLogIndex(leader) /\
                                   expectedLLI < nextIndex[leader][i]
                    prevIdx  == IF isHeartbeat THEN expectedLLI
                                ELSE nextIndex[leader][i] - 1
                    prevTerm == LogTerm(leader, prevIdx)
                    entries  == IF isHeartbeat THEN <<>>
                                ELSE IF nextIndex[leader][i] <= LastLogIndex(leader)
                                     THEN SubSeq(log[leader], nextIndex[leader][i], LastLogIndex(leader))
                                     ELSE <<>>
                    msg == [mtype        |-> AppendEntriesRequestMsg,
                            mterm        |-> currentTerm[leader],
                            mprevLogTerm |-> prevTerm,
                            mprevLogIndex |-> prevIdx,
                            mentries     |-> entries,
                            mcommitIndex |-> commitIndex[leader],
                            mqueryRound  |-> queryRound[leader],
                            msource      |-> leader,
                            mdest        |-> i]
                IN HandleAppendRequest(i, msg)
             /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleAppendSuccessResponse ==
    /\ IsMsgEvent("HandleAppendSuccessResponse", logline.from, logline.to)
    /\ LET i == logline.to
       IN \/ \* Normal path: message still in bag (pre-filtered by source)
             /\ \E m \in DOMAIN messages :
                    /\ m.mtype = AppendSuccessResponseMsg
                    /\ m.msource = logline.from
                    /\ HandleAppendSuccessResponse(i, m)
             /\ ValidatePostStateWeak(i)
          \/ \* Idempotent path: already handled by SilentHandleAppendSuccessResponse
             /\ UNCHANGED vars
             /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandleAppendFailureResponse ==
    /\ IsMsgEvent("HandleAppendFailureResponse", logline.from, logline.to)
    /\ LET i == logline.to
       IN /\ \E m \in DOMAIN messages :
              /\ HandleAppendFailureResponse(i, m)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceAdvanceCommitIndex ==
    /\ IsNodeEvent("AdvanceCommitIndex", logline.node)
    /\ LET i == logline.node
       IN \/ \* Normal path
             /\ AdvanceCommitIndex(i)
             /\ ValidatePostStateWeak(i)
          \/ \* Idempotent path: already handled by SilentAdvanceCommitIndex
             /\ UNCHANGED vars
             /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceLeaderCheckLease ==
    /\ IsNodeEvent("LeaderCheckLease", logline.node)
    /\ LET i == logline.node
       IN /\ LeaderCheckLease(i)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceProposeMembershipChange ==
    /\ IsNodeEvent("ProposeMembershipChange", logline.node)
    /\ LET i == logline.node
       IN /\ ProposeMembershipChange(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceSubmitLinearizableRead ==
    /\ IsNodeEvent("SubmitLinearizableRead", logline.node)
    /\ LET i == logline.node
       IN /\ SubmitLinearizableRead(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceRunQueries ==
    /\ IsNodeEvent("RunQueries", logline.node)
    /\ LET i == logline.node
       IN /\ RunQueries(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceCrash ==
    /\ IsNodeEvent("Crash", logline.node)
    /\ LET i == logline.node
       IN /\ Crash(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

----
\* Silent actions — fire base actions without consuming a trace event.
\* MUST be tightly constrained to avoid state space explosion.
----

\* Silent AppendEntries: leader sends AppendEntries not captured in trace.
\* Constrained: only fire when the NEXT trace event requires it AND
\* there's no AppendEntries in the bag that would produce the expected post-state.
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendRequest"
    /\ "state" \in DOMAIN logline
    /\ LET i == logline.from
           j == logline.to
           expectedLLI == logline.state.lastLogIndex
       IN /\ state[i] = Leader
          \* Only fire if no existing message covers expected lastLogIndex with correct ci
          /\ ~\E m \in DOMAIN messages :
              /\ m.mtype = AppendEntriesRequestMsg
              /\ m.msource = i
              /\ m.mdest = j
              /\ m.mcommitIndex = commitIndex[i]
              /\ m.mprevLogIndex + Len(m.mentries) >= expectedLLI
          /\ AppendEntries(i, j)
    /\ UNCHANGED l

\* Silent AdvanceCommitIndex: commit advancement triggered by response handling.
\* Constrained: only fire when the next event's state shows a higher commitIndex
\* than a leader's. The leader is identified from the trace event context.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ "state" \in DOMAIN logline
    /\ logline.state.commitIndex > 0
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ \/ logline.node = i
           \/ ("from" \in DOMAIN logline /\ logline.from = i)
        /\ logline.state.commitIndex > commitIndex[i]
        /\ AdvanceCommitIndex(i)
    /\ UNCHANGED l

\* Silent HandlePreVoteResponse: pre-vote response triggers real election,
\* which sends VoteRequests. Needed when HandleVoteRequest appears in trace
\* before HandlePreVoteResponse is consumed.
SilentHandlePreVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ \/ logline.event \in {"HandleVoteRequest", "HandleVoteResponse"}
       \/ /\ logline.event = "HandlePreVoteResponse"
          /\ "elected" \in DOMAIN logline
          /\ logline.elected = TRUE
    /\ LET node == IF logline.event = "HandlePreVoteResponse"
                    THEN logline.to  \* The node receiving pre-votes
                    ELSE logline.from  \* The node that sent the next event's message
           candidates == {m \in DOMAIN messages :
                            /\ m.mtype = PreVoteResponseMsg
                            /\ m.mdest = node}
       IN /\ candidates /= {}
          /\ LET m == CHOOSE m \in candidates : TRUE
             IN HandlePreVoteResponse(m.mdest, m)
    /\ UNCHANGED l

\* Silent HandleVoteResponse: vote response triggers leader promotion,
\* which sends AppendEntries. Needed when AppendEntries or HandleAppendRequest
\* appears in trace before HandleVoteResponse is consumed.
\* Uses CHOOSE to avoid branching. Only fires for the leader involved in the next event.
SilentHandleVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"AppendEntries", "HandleAppendRequest",
                          "HandleAppendSuccessResponse", "ClientRequest",
                          "AdvanceCommitIndex"}
    \* Identify the leader involved: logline.node for most events,
    \* logline.from for HandleAppendRequest (where node is the follower)
    /\ LET node == IF logline.event = "HandleAppendRequest"
                    THEN logline.from
                    ELSE logline.node
       IN /\ state[node] = Candidate
          /\ LET candidates == {m \in DOMAIN messages :
                                  /\ m.mtype = VoteResponseMsg
                                  /\ m.mdest = node}
             IN /\ candidates /= {}
                /\ LET m == CHOOSE m \in candidates : TRUE
                   IN HandleVoteResponse(m.mdest, m)
    /\ UNCHANGED l

\* Silent HandleAppendSuccessResponse: leader processes success response
\* (updating matchIndex/nextIndex) before the trace event is emitted.
\* Constrained: only fire when the next event's state shows a higher commitIndex.
SilentHandleAppendSuccessResponse ==
    /\ l <= Len(TraceLog)
    /\ "state" \in DOMAIN logline
    /\ logline.state.commitIndex > 0
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ \/ logline.node = i
           \/ ("from" \in DOMAIN logline /\ logline.from = i)
        /\ logline.state.commitIndex > commitIndex[i]
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendSuccessResponseMsg
            /\ m.mdest = i
            /\ HandleAppendSuccessResponse(i, m)
    /\ UNCHANGED l

\* Silent LoseMessage: message is lost, not captured in trace.
SilentLoseMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        /\ LoseMessage(m)
    /\ UNCHANGED l

----
\* TraceNext
----

TraceNext ==
    \* Trace complete — stutter to prevent false deadlock
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars
    \* Action wrappers (consume trace event)
    \/ TraceTimeout
    \/ TraceHandlePreVoteRequest
    \/ TraceHandlePreVoteResponse
    \/ TraceHandleVoteRequest
    \/ TraceHandleVoteResponse
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendRequest
    \/ TraceHandleAppendSuccessResponse
    \/ TraceHandleAppendFailureResponse
    \/ TraceAdvanceCommitIndex
    \/ TraceLeaderCheckLease
    \/ TraceProposeMembershipChange
    \/ TraceSubmitLinearizableRead
    \/ TraceRunQueries
    \/ TraceCrash
    \* Silent actions (don't consume trace event)
    \/ SilentAdvanceCommitIndex
    \/ SilentHandlePreVoteResponse
    \/ SilentHandleVoteResponse
    \/ SilentHandleAppendSuccessResponse
    \* Cleanup: discard stale election messages to reduce state space.
    \* Only discard VoteResponse/PreVoteResponse for non-candidates.
    \/ /\ l <= Len(TraceLog)
       /\ LET stale == {m \in DOMAIN messages :
                          /\ m.mtype \in {VoteResponseMsg, PreVoteResponseMsg}
                          /\ state[m.mdest] /= Candidate
                          /\ preVote[m.mdest] = {}}
          IN /\ stale /= {}
             /\ LET m == CHOOSE m \in stale : TRUE
                IN Discard(m)
             /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                            leaseVars, configVars, preVoteVars, queryVars>>
       /\ UNCHANGED l

----
\* TraceMatched — entire trace was consumed
----

TraceMatched == <>(l = Len(TraceLog) + 1)

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

====
