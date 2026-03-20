---------------------------- MODULE Trace ----------------------------
\* Trace validation spec for goraft/raft.
\*
\* Replays implementation traces against the base spec to verify
\* that the spec can reproduce every observed state transition.
\*
\* Key adaptations for goraft:
\*   - TraceInit computes initial state for ALL servers from their first
\*     trace event (handles non-empty bootstrap logs)
\*   - ClientRequest/AppendNOP/HandleAER accept commitIndex from trace
\*     (models auto-commit at server.go:920-924 and invisible AE responses)
\*   - AdvanceCommitIndex accepts trace's ci (may differ from spec's quorum
\*     computation due to dynamic membership)
\*
EXTENDS base, Json, IOUtils, Sequences, Naturals, TLC

----
\* Trace loading
----

\* Trace file location: defaults to ../traces/trace.ndjson,
\* overridable via IOEnv.JSON
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and parse the NDJSON trace file
TraceLog == ndJsonDeserialize(JsonFile)

----
\* Cursor variable
----

\* l walks through trace events, starting at 1
VARIABLE l

traceVars == <<vars, l>>

\* Current log line
logline == TraceLog[l]

----
\* Role/type mapping
----

\* Map implementation role strings to spec constants
RoleMap(role) ==
    CASE role = "follower"     -> Follower
      [] role = "candidate"    -> Candidate
      [] role = "leader"       -> Leader
      [] role = "snapshotting" -> Snapshotting
      [] OTHER                 -> Follower

\* Map entry type strings to spec constants
EntryTypeMap(etype) ==
    CASE etype = "value" -> ValueEntry
      [] etype = "nop"   -> NOPEntry
      [] OTHER           -> ValueEntry

----
\* Server extraction
----

\* Derive Server set from trace: collect all unique node IDs
TraceServer == {TraceLog[k].node : k \in DOMAIN TraceLog}

----
\* Event predicates
----

IsEvent(name) == logline.event = name

IsNodeEvent(name, i) ==
    /\ logline.event = name
    /\ logline.node = i

IsMsgEvent(name, from, to) ==
    /\ logline.event = name
    /\ logline.from = from
    /\ logline.to = to

----
\* Initial state computation from trace
\*
\* Infer each server's initial state from its first trace event.
\* Events that don't modify the log (Timeout, RequestVote, etc.) provide
\* the initial log state directly from their post-state fields.
\* Events that modify the log (ClientRequest, AppendNOP) require adjustment.
----

\* Events that don't modify the log
NonLogEvents == {"Timeout", "RequestVote", "HandleRequestVoteRequest",
                 "HandleRequestVoteResponse", "BecomeLeader",
                 "AdvanceCommitIndex", "HandleAppendEntriesResponse",
                 "SendHeartbeat", "SendSnapshotRequest",
                 "SendSnapshotRecoveryRequest", "Crash",
                 "HandleSnapshotRequest"}

\* Find the first trace event index for server s
ServerFirstIdx(s) ==
    CHOOSE k \in DOMAIN TraceLog :
        /\ TraceLog[k].node = s
        /\ \A j \in 1..(k-1) : TraceLog[j].node /= s

\* Initial log length for server s
InitLogLen(s) ==
    LET k == ServerFirstIdx(s)
        ev == TraceLog[k]
    IN CASE ev.event \in NonLogEvents -> ev.state.lastLogIndex
         [] ev.event \in {"ClientRequest", "AppendNOP"} -> ev.state.lastLogIndex - 1
         [] ev.event = "HandleAppendEntriesRequest" ->
            IF "prevLogIndex" \in DOMAIN ev.msg
            THEN ev.msg.prevLogIndex
            ELSE 0
         [] OTHER -> 0

\* Initial last log term for server s
InitLogTerm(s) ==
    LET k == ServerFirstIdx(s)
        ev == TraceLog[k]
        logLen == InitLogLen(s)
    IN IF logLen = 0 THEN 0
       ELSE CASE ev.event \in NonLogEvents -> ev.state.lastLogTerm
              [] OTHER -> 0

\* Generate initial log entries (all with the same term)
InitLog(s) ==
    LET logLen == InitLogLen(s)
        logTerm == InitLogTerm(s)
    IN IF logLen = 0 THEN <<>>
       ELSE [k \in 1..logLen |-> [term |-> logTerm, type |-> ValueEntry]]

\* Initial term from pre-state of first event
InitTerm(s) ==
    LET k == ServerFirstIdx(s)
        ev == TraceLog[k]
    IN IF "pre" \in DOMAIN ev /\ "term" \in DOMAIN ev.pre
       THEN ev.pre.term
       ELSE 0

\* Initial role from pre-state of first event
InitRole(s) ==
    LET k == ServerFirstIdx(s)
        ev == TraceLog[k]
    IN IF "pre" \in DOMAIN ev /\ "role" \in DOMAIN ev.pre
       THEN RoleMap(ev.pre.role)
       ELSE Follower

----
\* Post-state validation
----

\* Validate term, role, log length, last log term (NO commitIndex check)
ValidatePostStateNoCI(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RoleMap(logline.state.role)
    /\ Len(log'[i]) = logline.state.lastLogIndex
    /\ (IF Len(log'[i]) > 0 THEN log'[i][Len(log'[i])].term ELSE 0) = logline.state.lastLogTerm

\* Full validation including commitIndex
ValidatePostState(i) ==
    /\ ValidatePostStateNoCI(i)
    /\ commitIndex'[i] = logline.state.commitIndex

\* Weak validation: only check term + role (for async actions)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RoleMap(logline.state.role)

----
\* TraceInit
----

\* Initialize from trace data, computing initial state for ALL servers.
TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in TraceServer |-> InitTerm(s)]
    /\ votedFor          = [s \in TraceServer |-> Nil]
    /\ log               = [s \in TraceServer |-> InitLog(s)]
    /\ state             = [s \in TraceServer |-> InitRole(s)]
    /\ commitIndex       = [s \in TraceServer |-> 0]
    /\ nextIndex         = [s \in TraceServer |->
                               [t \in TraceServer |-> InitLogLen(s) + 1]]
    /\ matchIndex        = [s \in TraceServer |-> [t \in TraceServer |-> 0]]
    /\ votesGranted      = [s \in TraceServer |-> {}]
    /\ messages          = EmptyBag
    /\ persistedTerm     = [s \in TraceServer |-> 0]
    /\ persistedVotedFor = [s \in TraceServer |-> Nil]
    /\ syncedPeer        = [s \in TraceServer |-> {}]
    /\ heartbeatTerm     = [s \in TraceServer |-> 0]
    /\ committed         = {}

----
\* Action wrappers
\*
\* Each wrapper: match event -> execute action -> validate post-state -> advance cursor
\*
\* For actions that modify commitIndex in the implementation but not in the spec
\* (ClientRequest, AppendNOP, HandleAER, AdvanceCommitIndex), we inline the
\* action logic and accept commitIndex from the trace. This handles:
\*   - Auto-commit when len(peers)==0 (server.go:920-924)
\*   - Invisible AE response processing between trace events
\*   - Dynamic membership quorum changes
----

\* TraceTimeout: follower election timeout
TraceTimeout ==
    /\ IsNodeEvent("Timeout", logline.node)
    /\ Timeout(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

\* TraceRequestVote: candidate starts election
TraceRequestVote ==
    /\ IsNodeEvent("RequestVote", logline.node)
    /\ RequestVote(logline.node)
    /\ ValidatePostStateNoCI(logline.node)
    /\ commitIndex'[logline.node] = logline.state.commitIndex
    /\ l' = l + 1

\* TraceHandleRequestVoteRequest: process RV request
TraceHandleRequestVoteRequest ==
    /\ IsNodeEvent("HandleRequestVoteRequest", logline.node)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteRequest
        /\ m.mdest = logline.node
        /\ m.msource = logline.from
        /\ HandleRequestVoteRequest(logline.node, m)
    /\ ValidatePostStateNoCI(logline.node)
    /\ commitIndex'[logline.node] = logline.state.commitIndex
    /\ l' = l + 1

\* TraceHandleRequestVoteResponse: process RV response
TraceHandleRequestVoteResponse ==
    /\ IsNodeEvent("HandleRequestVoteResponse", logline.node)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteResponse
        /\ m.mdest = logline.node
        /\ m.msource = logline.from
        /\ HandleRequestVoteResponse(logline.node, m)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

\* TraceBecomeLeader: candidate with quorum becomes leader
TraceBecomeLeader ==
    /\ IsNodeEvent("BecomeLeader", logline.node)
    /\ BecomeLeader(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

\* TraceClientRequest: leader appends value entry
\* Inlined to accept trace's commitIndex (auto-commit, server.go:920-924)
TraceClientRequest ==
    /\ IsNodeEvent("ClientRequest", logline.node)
    /\ LET i == logline.node
       IN /\ state[i] = Leader
          /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry]
                 newLog == Append(log[i], entry)
             IN /\ log' = [log EXCEPT ![i] = newLog]
                /\ syncedPeer' = [syncedPeer EXCEPT ![i] = @ \cup {i}]
                \* Accept trace's commitIndex
                /\ commitIndex' = [commitIndex EXCEPT ![i] = logline.state.commitIndex]
                /\ LET safeCI == Min(logline.state.commitIndex, Len(newLog))
                   IN committed' = committed \cup
                          {<<k, newLog[k].term>> : k \in (commitIndex[i]+1)..safeCI}
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderVars, candidateVars, messages,
                   persistVars, heartbeatVars>>
    /\ ValidatePostStateNoCI(logline.node)
    /\ l' = l + 1

\* TraceAppendNOP: leader appends NOP entry
\* Inlined to accept trace's commitIndex (auto-commit, server.go:920-924)
TraceAppendNOP ==
    /\ IsNodeEvent("AppendNOP", logline.node)
    /\ LET i == logline.node
       IN /\ state[i] = Leader
          /\ LET entry == [term |-> currentTerm[i], type |-> NOPEntry]
                 newLog == Append(log[i], entry)
             IN /\ log' = [log EXCEPT ![i] = newLog]
                /\ syncedPeer' = [syncedPeer EXCEPT ![i] = @ \cup {i}]
                \* Accept trace's commitIndex
                /\ commitIndex' = [commitIndex EXCEPT ![i] = logline.state.commitIndex]
                /\ LET safeCI == Min(logline.state.commitIndex, Len(newLog))
                   IN committed' = committed \cup
                          {<<k, newLog[k].term>> : k \in (commitIndex[i]+1)..safeCI}
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderVars, candidateVars, messages,
                   persistVars, heartbeatVars>>
    /\ ValidatePostStateNoCI(logline.node)
    /\ l' = l + 1

\* TraceReplicate: leader sends AE to peer
TraceReplicate ==
    /\ IsMsgEvent("Replicate", logline.from, logline.to)
    /\ Replicate(logline.from, logline.to)
    /\ l' = l + 1

\* TraceHandleAppendEntriesRequest: process AE
\* Inlined to accept trace's commitIndex (AE's mcommitIndex may differ from spec)
TraceHandleAppendEntriesRequest ==
    /\ IsNodeEvent("HandleAppendEntriesRequest", logline.node)
    /\ LET i == logline.node
       IN \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = i
           /\ m.msource = logline.from
           /\ \/ \* Reject: stale term
                 /\ m.mterm < currentTerm[i]
                 /\ Reply([mtype       |-> AppendEntriesResponse,
                           mterm       |-> currentTerm[i],
                           msuccess    |-> FALSE,
                           mmatchIndex |-> 0,
                           msource     |-> i,
                           mdest       |-> m.msource], m)
                 /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                                persistVars, syncVars, heartbeatVars, historyVars>>

              \/ \* Accept: valid term
                 /\ m.mterm >= currentTerm[i]
                 /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                 /\ votedFor' = [votedFor EXCEPT
                        ![i] = IF m.mterm > currentTerm[i] THEN Nil ELSE @]
                 /\ state' = [state EXCEPT
                        ![i] = IF m.mterm > currentTerm[i]
                               THEN Follower
                               ELSE IF @ = Candidate
                               THEN Follower
                               ELSE @]
                 /\ LET logOk == \/ m.mprevLogIndex = 0
                                 \/ (m.mprevLogIndex > 0
                                     /\ m.mprevLogIndex <= Len(log[i])
                                     /\ log[i][m.mprevLogIndex].term = m.mprevLogTerm)
                    IN \/ \* Log mismatch
                          /\ ~logOk
                          /\ UNCHANGED <<log, commitIndex>>
                          /\ Reply([mtype       |-> AppendEntriesResponse,
                                    mterm       |-> m.mterm,
                                    msuccess    |-> FALSE,
                                    mmatchIndex |-> 0,
                                    msource     |-> i,
                                    mdest       |-> m.msource], m)
                          /\ UNCHANGED <<leaderVars, candidateVars,
                                         persistVars, syncVars, heartbeatVars, historyVars>>

                       \/ \* Log match: truncate, append, accept trace's commitIndex
                          /\ logOk
                          /\ LET newLog == SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                             IN \* Guard: resulting log length must match trace
                                /\ Len(newLog) = logline.state.lastLogIndex
                                /\ log' = [log EXCEPT ![i] = newLog]
                                \* Accept trace's commitIndex instead of computing from message
                                /\ commitIndex' = [commitIndex EXCEPT ![i] = logline.state.commitIndex]
                                /\ LET safeCI == Min(logline.state.commitIndex, Len(newLog))
                                   IN committed' = committed \cup
                                          {<<k, newLog[k].term>> : k \in
                                               (commitIndex[i]+1)..safeCI}
                          /\ Reply([mtype       |-> AppendEntriesResponse,
                                    mterm       |-> m.mterm,
                                    msuccess    |-> TRUE,
                                    mmatchIndex |-> m.mprevLogIndex + Len(m.mentries),
                                    msource     |-> i,
                                    mdest       |-> m.msource], m)
                          /\ UNCHANGED <<leaderVars, candidateVars,
                                         persistVars, syncVars, heartbeatVars>>
    /\ ValidatePostStateNoCI(logline.node)
    /\ l' = l + 1

\* TraceHandleAppendEntriesResponse: process AE response
TraceHandleAppendEntriesResponse ==
    /\ IsNodeEvent("HandleAppendEntriesResponse", logline.node)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = AppendEntriesResponse
        /\ m.mdest = logline.node
        /\ m.msource = logline.from
        /\ HandleAppendEntriesResponse(logline.node, m)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

\* TraceAdvanceCommitIndex: leader advances commit index
\* Inlined to accept trace's commitIndex (quorum may differ from spec)
TraceAdvanceCommitIndex ==
    /\ IsNodeEvent("AdvanceCommitIndex", logline.node)
    /\ LET i == logline.node
       IN /\ state[i] = Leader
          \* Accept trace's commitIndex
          /\ logline.state.commitIndex > commitIndex[i]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = logline.state.commitIndex]
          /\ committed' = committed \cup
                 {<<k, log[i][k].term>> : k \in (commitIndex[i]+1)..logline.state.commitIndex}
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   persistVars, syncVars, heartbeatVars>>
    /\ ValidatePostStateNoCI(logline.node)
    /\ l' = l + 1

\* TraceSendSnapshotRequest: leader sends snapshot request
TraceSendSnapshotRequest ==
    /\ IsMsgEvent("SendSnapshotRequest", logline.from, logline.to)
    /\ SendSnapshotRequest(logline.from, logline.to)
    /\ l' = l + 1

\* TraceHandleSnapshotRequest: follower enters Snapshotting
TraceHandleSnapshotRequest ==
    /\ IsNodeEvent("HandleSnapshotRequest", logline.node)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = SnapshotRequest
        /\ m.mdest = logline.node
        /\ HandleSnapshotRequest(logline.node, m)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

\* TraceSendSnapshotRecoveryRequest: leader sends recovery
TraceSendSnapshotRecoveryRequest ==
    /\ IsMsgEvent("SendSnapshotRecoveryRequest", logline.from, logline.to)
    /\ SendSnapshotRecoveryRequest(logline.from, logline.to)
    /\ l' = l + 1

\* TraceHandleSnapshotRecoveryRequest: follower recovers from snapshot
TraceHandleSnapshotRecoveryRequest ==
    /\ IsNodeEvent("HandleSnapshotRecoveryRequest", logline.node)
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = SnapshotRecoveryRequest
        /\ m.mdest = logline.node
        /\ HandleSnapshotRecoveryRequest(logline.node, m)
    /\ ValidatePostState(logline.node)
    /\ l' = l + 1

\* TraceSendHeartbeat: heartbeat with possibly stale term
\* Inlined: uses currentTerm directly (handles bootstrap leader at term 0)
\* Uses Max(nextIndex, follower log length) as prevLogIndex to avoid truncation
\* from stale nextIndex (impl's peer goroutine updates prevLogIndex faster than spec)
TraceSendHeartbeat ==
    /\ IsMsgEvent("SendHeartbeat", logline.from, logline.to)
    /\ LET i == logline.from
           j == logline.to
       IN /\ i /= j
          \* Use the larger of nextIndex-1 and follower's actual log length
          \* to avoid truncating entries the follower already has
          /\ LET prevLogIndex == Max(IF nextIndex[i][j] > 0 THEN nextIndex[i][j] - 1 ELSE 0,
                                     LastLogIndex(j))
             IN Send([mtype         |-> AppendEntriesRequest,
                      mterm         |-> currentTerm[i],
                      mprevLogIndex |-> prevLogIndex,
                      mprevLogTerm  |-> LogTerm(i, prevLogIndex),
                      mentries      |-> <<>>,
                      mcommitIndex  |-> Min(commitIndex[i], LastLogIndex(i)),
                      msource       |-> i,
                      mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>
    /\ l' = l + 1

\* TraceCrash: server crash and recovery
TraceCrash ==
    /\ IsNodeEvent("Crash", logline.node)
    /\ Crash(logline.node)
    /\ ValidatePostStateWeak(logline.node)
    /\ l' = l + 1

----
\* Silent actions
\*
\* Handle implementation state changes without trace events.
\* Each must be tightly constrained to prevent state space explosion.
----

\* SilentReplicate: leader sends AE without trace event
\* Constrained: only when next trace event expects a message that isn't in the bag
SilentReplicate ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendEntriesRequest"
    /\ \E i \in TraceServer :
        /\ state[i] = Leader
        /\ \E j \in TraceServer \ {i} :
            /\ j = logline.node
            \* Only fire if no AE message already exists for this target
            /\ ~(\E m \in DOMAIN messages :
                    /\ m.mtype = AppendEntriesRequest
                    /\ m.mdest = j
                    /\ m.msource = i)
            /\ Replicate(i, j)
    /\ UNCHANGED <<l>>

\* SilentAdvanceCommitIndex: leader advances commit after AE response
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    \* Don't pre-empt an explicit AdvanceCommitIndex trace event
    /\ ~(logline.event = "AdvanceCommitIndex")
    /\ \E i \in TraceServer :
        /\ state[i] = Leader
        /\ Cardinality(syncedPeer[i]) >= QuorumSize
        /\ AdvanceCommitIndex(i)
    /\ UNCHANGED <<l>>

\* SilentAppendNOP: leader appends NOP without explicit trace event
\* Constrained: only when leader hasn't yet appended NOP in current term
SilentAppendNOP ==
    /\ l <= Len(TraceLog)
    \* Don't pre-empt an explicit AppendNOP trace event
    /\ ~(logline.event = "AppendNOP")
    /\ \E i \in TraceServer :
        /\ state[i] = Leader
        \* Only if no current-term entry exists yet (NOP not yet appended)
        /\ \/ LastLogIndex(i) = 0
           \/ LastLogTerm(i) /= currentTerm[i]
        /\ AppendNOP(i)
    /\ UNCHANGED <<l>>

\* SilentSendHeartbeat: heartbeat without trace event
\* Uses currentTerm (not heartbeatTerm) for bootstrap leader support
\* Constrained: only when no AE message already exists for the target
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendEntriesRequest"
    /\ \E i \in TraceServer :
        /\ state[i] = Leader
        /\ \E j \in TraceServer \ {i} :
            /\ j = logline.node
            \* Only fire if no AE message already exists for this target from this leader
            /\ ~(\E m \in DOMAIN messages :
                    /\ m.mtype = AppendEntriesRequest
                    /\ m.mdest = j
                    /\ m.msource = i)
            /\ LET prevLogIndex == Max(IF nextIndex[i][j] > 0 THEN nextIndex[i][j] - 1 ELSE 0,
                                       LastLogIndex(j))
               IN Send([mtype         |-> AppendEntriesRequest,
                        mterm         |-> currentTerm[i],
                        mprevLogIndex |-> prevLogIndex,
                        mprevLogTerm  |-> LogTerm(i, prevLogIndex),
                        mentries      |-> <<>>,
                        mcommitIndex  |-> Min(commitIndex[i], LastLogIndex(i)),
                        msource       |-> i,
                        mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>
    /\ UNCHANGED <<l>>

----
\* TraceNext
----

TraceNext ==
    /\ l <= Len(TraceLog)  \* guard against accessing TraceLog beyond its length
    /\ \/ TraceTimeout
       \/ TraceRequestVote
       \/ TraceHandleRequestVoteRequest
       \/ TraceHandleRequestVoteResponse
       \/ TraceBecomeLeader
       \/ TraceClientRequest
       \/ TraceAppendNOP
       \/ TraceReplicate
       \/ TraceHandleAppendEntriesRequest
       \/ TraceHandleAppendEntriesResponse
       \/ TraceAdvanceCommitIndex
       \/ TraceSendSnapshotRequest
       \/ TraceHandleSnapshotRequest
       \/ TraceSendSnapshotRecoveryRequest
       \/ TraceHandleSnapshotRecoveryRequest
       \/ TraceSendHeartbeat
       \/ TraceCrash
       \* Silent actions
       \/ SilentReplicate
       \/ SilentSendHeartbeat

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

----
\* Trace completion check
----

\* Verify the entire trace was consumed (checked as temporal property)
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alternative: check via deadlock — if TLC finds deadlock at l = Len(TraceLog) + 1,
\* the trace was fully matched. Deadlock at l < Len(TraceLog) + 1 means a mismatch.

====
