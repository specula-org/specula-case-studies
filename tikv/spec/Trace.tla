------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for tikv/raft-rs.
\* Replays NDJSON traces against the base spec to verify implementation
\* matches specification behavior.
\*
EXTENDS base, Json, IOUtils, Sequences, Naturals, FiniteSets, TLC

----
\* Trace loading
----

\* Trace file path: override via IOEnv.JSON for per-run selection
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and deserialize the trace
TraceLog ==
    ndJsonDeserialize(JsonFile)

----
\* Cursor variable
----

VARIABLE l      \* Current position in trace (1-indexed)

trace_vars == <<vars, l>>

----
\* Role/type mapping: implementation strings to spec constants
----

MapRole(r) ==
    CASE r = "Follower"     -> Follower
      [] r = "Candidate"    -> Candidate
      [] r = "PreCandidate" -> PreCandidate
      [] r = "Leader"       -> Leader

MapEntryType(t) ==
    CASE t = "normal"     -> ValueEntry
      [] t = "config"     -> ConfigEntry
      [] t = "noop"       -> NoopEntry
      [] OTHER            -> ValueEntry

----
\* Server extraction from trace
----

\* Derive Server set from all node IDs seen in the trace
TraceServers ==
    LET ids == {TraceLog[i].node : i \in 1..Len(TraceLog)}
    IN ids

----
\* Event predicates
----

\* Current log line
logline == TraceLog[l]

\* Is event of given type?
IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* Is event for a specific node?
IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.node = i

\* Is event for a message from one node to another?
IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

----
\* Post-state validation helpers
----

\* Strong validation: check term, state, commitIndex, lastLogIndex, lastLogTerm
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = MapRole(logline.state.role)
    /\ commitIndex'[i] = logline.state.commit
    /\ LastLogIndex(i)' = logline.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.state.lastLogTerm

\* Weak validation: check only term + role (for async operations)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = MapRole(logline.state.role)

\* Commit-only validation: check term + role + commitIndex
ValidatePostStateCommit(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = MapRole(logline.state.role)
    /\ commitIndex'[i] = logline.state.commit

----
\* Action wrappers: each matches a trace event, calls base action, validates, advances cursor
----

\* TraceTimeout: election timeout
TraceTimeout(i) ==
    /\ IsNodeEvent("Timeout", i)
    /\ Timeout(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceClientRequest: leader appends entry
TraceClientRequest(i) ==
    /\ IsNodeEvent("ClientRequest", i)
    /\ ClientRequest(i)
    /\ ValidatePostState(i)
    /\ l' = l + 1

\* TraceSendHeartbeat: leader sends heartbeat
TraceSendHeartbeat(i, j) ==
    /\ IsMsgEvent("SendHeartbeat", i, j)
    /\ SendHeartbeat(i, j)
    /\ l' = l + 1

\* TraceHandleAppendEntriesRequest: follower receives AppendEntries
TraceHandleAppendEntriesRequest(i, m) ==
    /\ IsNodeEvent("HandleAppendEntriesRequest", i)
    /\ logline.from = m.msource
    /\ HandleAppendEntriesRequest(i, m)
    /\ ValidatePostState(i)
    /\ l' = l + 1

\* TraceHandleAppendEntriesResponse: leader receives AppendEntries response
\* Only process the response with the HIGHEST mindex for this source
\* (skip stale orphaned responses from commit notifications)
TraceHandleAppendEntriesResponse(i, m) ==
    /\ IsNodeEvent("HandleAppendEntriesResponse", i)
    /\ logline.from = m.msource
    /\ m.mtype = AppendEntriesResponse
    /\ ~m.mreject
    /\ m.mterm = currentTerm[i]
    /\ ~\E m2 \in DOMAIN messages :
        /\ m2.mtype = AppendEntriesResponse
        /\ m2.mdest = i
        /\ m2.msource = m.msource
        /\ ~m2.mreject
        /\ m2.mterm = currentTerm[i]
        /\ m2.mindex > m.mindex
    /\ HandleAppendEntriesResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleHeartbeatRequest: follower receives heartbeat
TraceHandleHeartbeatRequest(i, m) ==
    /\ IsNodeEvent("HandleHeartbeatRequest", i)
    /\ logline.from = m.msource
    /\ HandleHeartbeatRequest(i, m)
    /\ ValidatePostStateCommit(i)
    /\ l' = l + 1

\* TraceHandleHeartbeatResponse: leader receives heartbeat response
TraceHandleHeartbeatResponse(i, m) ==
    /\ IsNodeEvent("HandleHeartbeatResponse", i)
    /\ logline.from = m.msource
    /\ HandleHeartbeatResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleRequestPreVoteRequest: node receives PreVote request
TraceHandleRequestPreVoteRequest(i, m) ==
    /\ IsNodeEvent("HandleRequestPreVoteRequest", i)
    /\ logline.from = m.msource
    /\ HandleRequestPreVoteRequest(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleRequestPreVoteResponse: pre-candidate receives PreVote response
TraceHandleRequestPreVoteResponse(i, m) ==
    /\ IsNodeEvent("HandleRequestPreVoteResponse", i)
    /\ logline.from = m.msource
    /\ HandleRequestPreVoteResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleRequestVoteRequest: node receives Vote request
TraceHandleRequestVoteRequest(i, m) ==
    /\ IsNodeEvent("HandleRequestVoteRequest", i)
    /\ logline.from = m.msource
    /\ HandleRequestVoteRequest(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleRequestVoteResponse: candidate receives Vote response
TraceHandleRequestVoteResponse(i, m) ==
    /\ IsNodeEvent("HandleRequestVoteResponse", i)
    /\ logline.from = m.msource
    /\ HandleRequestVoteResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceHandleTimeoutNowRequest: follower receives TimeoutNow
TraceHandleTimeoutNowRequest(i, m) ==
    /\ IsNodeEvent("HandleTimeoutNowRequest", i)
    /\ logline.from = m.msource
    /\ HandleTimeoutNowRequest(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceCheckQuorum: leader checks quorum
TraceCheckQuorum(i) ==
    /\ IsNodeEvent("CheckQuorum", i)
    /\ CheckQuorum(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* TraceTransferLeadership: leader begins transfer
TraceTransferLeadership(i, j) ==
    /\ IsNodeEvent("TransferLeadership", i)
    /\ logline.target = j
    /\ TransferLeadership(i, j)
    /\ l' = l + 1

\* TracePersistEntries: persistence completes
TracePersistEntries(i) ==
    /\ IsNodeEvent("PersistEntries", i)
    /\ PersistEntries(i)
    /\ l' = l + 1

\* TraceAdvanceCommitIndex: leader advances commit
TraceAdvanceCommitIndex(i) ==
    /\ IsNodeEvent("AdvanceCommitIndex", i)
    /\ AdvanceCommitIndex(i)
    /\ ValidatePostStateCommit(i)
    /\ l' = l + 1

\* TraceCrash: server crashes
TraceCrash(i) ==
    /\ IsNodeEvent("Crash", i)
    /\ Crash(i)
    /\ l' = l + 1

----
\* Silent actions: base spec actions that fire without consuming trace events
\* Must be tightly constrained to prevent state space explosion
----

\* SilentAdvanceCommitIndex: leader advances commit between trace events
\* Guard: only when next event is NOT AdvanceCommitIndex (that's handled by TraceAdvanceCommitIndex)
SilentAdvanceCommitIndex(i) ==
    /\ l <= Len(TraceLog)
    /\ state[i] = Leader
    /\ logline.event /= "AdvanceCommitIndex"
    \* Only allow if next event requires higher commitIndex
    /\ logline.node = i
    /\ "state" \in DOMAIN logline
    /\ logline.state.commit > commitIndex[i]
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED l

\* SilentPersistEntries: persistence completes between trace events
\* Guard: don't fire when next event IS PersistEntries for same node
SilentPersistEntries(i) ==
    /\ l <= Len(TraceLog)
    /\ persisted[i] < LastLogIndex(i)
    /\ logline.node = i
    /\ logline.event /= "PersistEntries"
    /\ PersistEntries(i)
    /\ UNCHANGED l

\* SilentSendAppendEntries: leader sends AE to a follower without consuming a trace event
\* Required because bcast_append (raft.rs:1849-1851) sends AE messages after commit advance,
\* but this is not a separate trace event — the messages just appear in the network.
SilentSendAppendEntries(i, j) ==
    /\ l <= Len(TraceLog)
    /\ state[i] = Leader
    /\ j \in AllVoters(i) \ {i}
    \* Only fire when next event is HandleAppendEntriesRequest for this pair
    /\ logline.event = "HandleAppendEntriesRequest"
    /\ logline.node = j
    /\ logline.from = i
    \* Only fire if no matching AE already in the bag (prevent duplicates)
    /\ ~\E msg \in DOMAIN messages :
        /\ msg.mtype = AppendEntriesRequest
        /\ msg.msource = i
        /\ msg.mdest = j
    /\ Send([mtype        |-> AppendEntriesRequest,
             mterm        |-> currentTerm[i],
             msource      |-> i,
             mdest        |-> j,
             mprevLogIndex |-> nextIndex[i][j] - 1,
             mprevLogTerm  |-> LogTerm(i, nextIndex[i][j] - 1),
             mentries      |-> SubSeq(log[i], nextIndex[i][j], LastLogIndex(i)),
             mcommitIndex  |-> commitIndex[i]])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars, l>>

\* SilentDropStaleMessage: discard zombie messages that can never usefully be processed
SilentDropStaleMessage(m) ==
    /\ l <= Len(TraceLog)
    /\ \* Vote/prevote responses for a node that's already Leader (can't process)
       \/ (m.mtype \in {RequestPreVoteResponse, RequestVoteResponse}
           /\ state[m.mdest] = Leader)
       \* AE responses whose mindex is already reflected in matchIndex (redundant)
       \/ (m.mtype = AppendEntriesResponse
           /\ ~m.mreject
           /\ state[m.mdest] = Leader
           /\ m.mterm = currentTerm[m.mdest]
           /\ m.mindex <= matchIndex[m.mdest][m.msource])
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars, l>>

----
\* TraceInit
----

\* Derive Server set from trace
ASSUME TraceServers /= {}

TraceInit ==
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ leaderId          = [s \in Server |-> Nil]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ readIndex         = [s \in Server |-> 0]
    /\ leaseValid        = [s \in Server |-> FALSE]
    /\ readRequestPending = [s \in Server |-> FALSE]
    /\ transferTarget    = [s \in Server |-> Nil]
    /\ recentlyActive    = [s \in Server |-> {}]
    /\ priority          = [s \in Server |-> 1]
    /\ config            = [s \in Server |-> Server]
    /\ newConfig         = [s \in Server |-> Nil]
    /\ pendingConfIndex  = [s \in Server |-> 0]
    /\ persisted         = [s \in Server |-> 0]
    /\ l = 1

----
\* TraceNext
----

TraceNext ==
    \* Traced actions (consume a trace event)
    \/ \E i \in Server :
        \/ TraceTimeout(i)
        \/ TraceClientRequest(i)
        \/ TraceCheckQuorum(i)
        \/ TracePersistEntries(i)
        \/ TraceAdvanceCommitIndex(i)
        \/ TraceCrash(i)
    \/ \E i, j \in Server :
        \/ TraceSendHeartbeat(i, j)
        \/ TraceTransferLeadership(i, j)
    \/ \E m \in DOMAIN messages :
        \/ TraceHandleAppendEntriesRequest(m.mdest, m)
        \/ TraceHandleAppendEntriesResponse(m.mdest, m)
        \/ TraceHandleHeartbeatRequest(m.mdest, m)
        \/ TraceHandleHeartbeatResponse(m.mdest, m)
        \/ TraceHandleRequestPreVoteRequest(m.mdest, m)
        \/ TraceHandleRequestPreVoteResponse(m.mdest, m)
        \/ TraceHandleRequestVoteRequest(m.mdest, m)
        \/ TraceHandleRequestVoteResponse(m.mdest, m)
        \/ TraceHandleTimeoutNowRequest(m.mdest, m)
    \* Silent actions (don't consume trace events)
    \/ \E i \in Server :
        \/ SilentAdvanceCommitIndex(i)
        \/ SilentPersistEntries(i)
    \/ \E m \in DOMAIN messages :
        \/ SilentDropStaleMessage(m)
    \/ \E i, j \in Server :
        \/ SilentSendAppendEntries(i, j)

----
\* TraceSpec
----

TraceSpec == TraceInit /\ [][TraceNext]_trace_vars /\ WF_trace_vars(TraceNext)

----
\* TraceMatched: temporal property — entire trace was consumed
----

TraceMatched == <>(l > Len(TraceLog))

====
