---- MODULE Trace ----
\***********************************************************************
\* Trace validation spec for willemt/raft.
\* Replays NDJSON traces from the instrumented implementation against
\* the base spec to verify consistency.
\***********************************************************************
EXTENDS base, Json, IOUtils, Sequences, TLC

\***********************************************************************
\* Trace loading
\***********************************************************************
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only protocol events (exclude debug/info lines)
TraceLog == SelectSeq(RawTraceLog, LAMBDA x : "event" \in DOMAIN x)

\***********************************************************************
\* Cursor variable: walks through trace events
\***********************************************************************
VARIABLE l

traceVars == <<l>>

\***********************************************************************
\* Role mapping: implementation strings → spec constants
\***********************************************************************
RoleMap(r) ==
    CASE r = "follower"  -> Follower
      [] r = "candidate" -> Candidate
      [] r = "leader"    -> Leader
      [] OTHER           -> Follower

\***********************************************************************
\* Server set extraction from trace
\***********************************************************************
TraceServer == {RawTraceLog[i].node : i \in {j \in 1..Len(RawTraceLog) : "node" \in DOMAIN RawTraceLog[j]}}

\***********************************************************************
\* Current log line accessor
\***********************************************************************
logline == TraceLog[l]

\***********************************************************************
\* Event predicates
\***********************************************************************
IsEvent(name) == logline.event = name

IsNodeEvent(name, i) ==
    /\ logline.event = name
    /\ logline.node = i

IsMsgEvent(name, from, to) ==
    /\ logline.event = name
    /\ logline.from = from
    /\ logline.to = to

\***********************************************************************
\* Post-state validation
\*
\* Strong: checks term, state, commitIndex, lastLogIndex, lastLogTerm
\* Weak: checks only term and state (for async events)
\***********************************************************************
ValidatePostState(i) ==
    /\ currentTerm'[i]  = logline.post.term
    /\ state'[i]        = RoleMap(logline.post.state)
    /\ commitIndex'[i]  = logline.post.commitIndex
    /\ LastLogIndex(i)' = logline.post.lastLogIndex  \* NOTE: requires primed evaluation

ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.post.term
    /\ state'[i]       = RoleMap(logline.post.state)

\* Even weaker: just term (for cases where state transition is in-flight)
ValidatePostStateTerm(i) ==
    /\ currentTerm'[i] = logline.post.term

\***********************************************************************
\* TraceInit
\*
\* Initialize from the trace's first event or from default state.
\* The implementation starts with term=0, voted_for=-1 (Nil),
\* state=follower (raft_server.c:75-87).
\***********************************************************************
TraceInit ==
    /\ Init
    /\ l = 1

\***********************************************************************
\* ACTION WRAPPERS
\* Each wrapper: matches event → calls base action → validates → l' = l + 1
\***********************************************************************

\***********************************************************************
\* TraceTimeout — election timeout fired
\***********************************************************************
TraceTimeout ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("Timeout", logline.node)
    /\ LET i == logline.node
       IN /\ Timeout(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceHandleRequestVoteRequest — received RV request
\***********************************************************************
TraceHandleRequestVoteRequest ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleRequestVoteRequest")
    /\ LET i == logline.to
           j == logline.from
       IN \E m \in BagToSet(messages) :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = j
            /\ m.mdest = i
            /\ m.mterm = logline.msg.term
            /\ HandleRequestVoteRequest(i, j, m)
            /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceHandleRequestVoteResponse — received RV response
\***********************************************************************
TraceHandleRequestVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleRequestVoteResponse")
    /\ LET i == logline.to
           j == logline.from
       IN \/ \* Standard path: message still in bag
             \E m \in BagToSet(messages) :
                /\ m.mtype = RequestVoteResponse
                /\ m.msource = j
                /\ m.mdest = i
                /\ m.mterm = logline.msg.term
                /\ HandleRequestVoteResponse(i, j, m)
                /\ ValidatePostStateWeak(i)
          \/ \* Already-processed path: vote was handled by SilentHandleRequestVoteResponse
             \* (the impl emits SendAppendEntries from raft_become_leader before the
             \* HandleRequestVoteResponse event — see raft_server.c:184, line 739)
             /\ currentTerm[i] = logline.post.term
             /\ state[i] = RoleMap(logline.post.state)
             /\ UNCHANGED <<allVars>>
    /\ l' = l + 1

\***********************************************************************
\* TraceClientRequest — leader received client entry
\***********************************************************************
TraceClientRequest ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("ClientRequest")
    /\ LET i == logline.node
           v == logline.value
       IN /\ ClientRequest(i, v)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceSendAppendEntries — leader sends AE to a peer
\***********************************************************************
TraceSendAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("SendAppendEntries")
    /\ LET i == logline.from
           j == logline.to
       IN /\ SendAppendEntries(i, j)
    /\ l' = l + 1

\***********************************************************************
\* TraceHandleAppendEntriesRequest — received AE request
\***********************************************************************
TraceHandleAppendEntriesRequest ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleAppendEntriesRequest")
    /\ LET i == logline.to
           j == logline.from
       IN \E m \in BagToSet(messages) :
            /\ m.mtype = AppendEntriesRequest
            /\ m.msource = j
            /\ m.mdest = i
            /\ m.mterm = logline.msg.term
            /\ HandleAppendEntriesRequest(i, j, m)
            /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceHandleAppendEntriesResponse — leader received AE response
\***********************************************************************
TraceHandleAppendEntriesResponse ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleAppendEntriesResponse")
    /\ LET i == logline.to
           j == logline.from
       IN \E m \in BagToSet(messages) :
            /\ m.mtype = AppendEntriesResponse
            /\ m.msource = j
            /\ m.mdest = i
            /\ m.mterm = logline.msg.term
            /\ HandleAppendEntriesResponse(i, j, m)
            /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceTakeSnapshot — server takes snapshot
\***********************************************************************
TraceTakeSnapshot ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("TakeSnapshot", logline.node)
    /\ LET i == logline.node
       IN /\ TakeSnapshot(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceSendInstallSnapshot — leader sends snapshot to peer
\***********************************************************************
TraceSendInstallSnapshot ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("SendInstallSnapshot")
    /\ LET i == logline.from
           j == logline.to
       IN /\ SendInstallSnapshot(i, j)
    /\ l' = l + 1

\***********************************************************************
\* TraceHandleInstallSnapshot — follower loads snapshot
\***********************************************************************
TraceHandleInstallSnapshot ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleInstallSnapshot")
    /\ LET i == logline.to
           j == logline.from
       IN \E m \in BagToSet(messages) :
            /\ m.mtype = InstallSnapshotRequest
            /\ m.msource = j
            /\ m.mdest = i
            /\ HandleInstallSnapshot(i, j, m)
            /\ ValidatePostStateTerm(i)
    /\ l' = l + 1

\***********************************************************************
\* TraceCrash / TraceRecover
\***********************************************************************
TraceCrash ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("Crash", logline.node)
    /\ LET i == logline.node
       IN Crash(i)
    /\ l' = l + 1

TraceRecover ==
    /\ l <= Len(TraceLog)
    /\ IsNodeEvent("Recover", logline.node)
    /\ LET i == logline.node
       IN Recover(i)
    /\ l' = l + 1

\***********************************************************************
\* SILENT ACTIONS
\*
\* Handle state changes that happen without a corresponding trace event.
\* Each is tightly constrained to prevent state space explosion.
\***********************************************************************

\* SilentSendAppendEntries: leader sends AE outside of an explicit trace event
\* This happens inside raft_become_leader (line 175) and raft_recv_appendentries_response (line 378)
SilentSendAppendEntries ==
    /\ l <= Len(TraceLog)
    \* Only fire when the next trace event is a HandleAERequest
    /\ l <= Len(TraceLog) => TraceLog[l].event \in {"HandleAppendEntriesRequest", "HandleAppendEntriesResponse"}
    /\ \E i, j \in Server :
         /\ i # j
         /\ state[i] = Leader
         /\ ~crashed[i]
         /\ SendAppendEntries(i, j)
    /\ UNCHANGED <<l>>

\* SilentSendInstallSnapshot: leader decides to send snapshot
\* Triggered inside raft_send_appendentries when NeedsSnapshot (line 901-905)
SilentSendInstallSnapshot ==
    /\ l <= Len(TraceLog)
    /\ l <= Len(TraceLog) => TraceLog[l].event = "HandleInstallSnapshot"
    /\ \E i, j \in Server :
         /\ i # j
         /\ state[i] = Leader
         /\ ~crashed[i]
         /\ SendInstallSnapshot(i, j)
    /\ UNCHANGED <<l>>

\* SilentHandleRequestVoteResponse: processes a vote response before its trace event.
\* In the implementation, raft_recv_requestvote_response → raft_become_leader →
\* raft_send_appendentries_all emits SendAppendEntries events BEFORE the
\* HandleRequestVoteResponse event (raft_server.c:723→166-185→739).
SilentHandleRequestVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event \in {"SendAppendEntries", "SendInstallSnapshot"}
    /\ \E m \in BagToSet(messages) :
         /\ m.mtype = RequestVoteResponse
         /\ m.mvoteGranted
         /\ state[m.mdest] = Candidate
         /\ HandleRequestVoteResponse(m.mdest, m.msource, m)
    /\ UNCHANGED <<l>>

\***********************************************************************
\* TraceNext: all wrappers + silent actions
\***********************************************************************
TraceNext ==
    \/ TraceTimeout
    \/ TraceClientRequest
    \/ TraceSendAppendEntries
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceTakeSnapshot
    \/ TraceSendInstallSnapshot
    \/ TraceHandleInstallSnapshot
    \/ TraceCrash
    \/ TraceRecover
    \* Silent actions
    \/ SilentSendAppendEntries
    \/ SilentSendInstallSnapshot
    \/ SilentHandleRequestVoteResponse

\***********************************************************************
\* Trace completion check
\***********************************************************************
TraceFinished == l > Len(TraceLog)

TraceMatched == <>(TraceFinished)

\***********************************************************************
\* Spec uses INIT/NEXT (not SPECIFICATION) for deadlock-based completion
\***********************************************************************
TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>

====
